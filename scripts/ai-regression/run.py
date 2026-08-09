#!/usr/bin/env python3
"""AI 流程稳定性 + 覆盖回归. 每 case 跑 N 次, 多数通过才算 PASS.

Extras vs v1:
  * noise turns — seed 后掺入无关话, 测抗干扰
  * honesty 断言 — 检查 answer 不含 "根据记录/frame_id=" 类幻觉
  * 重复运行 (default N=3) — 抗 LLM 抖动
  * per-category 汇总 + p50/p95 延迟
"""
import argparse, json, os, re, statistics, sys, time
import urllib.request as u

TOKEN = os.environ.get("OPENCLICKY_BRIDGE_TOKEN", "test-automation-token")
BRIDGE = os.environ.get("OPENCLICKY_BRIDGE_URL", "http://127.0.0.1:32123/mcp/sensor")
LOG_FILE = os.path.expanduser(
    "~/Library/Application Support/OpenClicky/Logs/messages-"
    + time.strftime("%Y-%m-%d") + ".jsonl")
CASES_FILE = os.path.join(os.path.dirname(__file__), "cases.json")
RESULTS_FILE = "/tmp/ai-regression-results.json"

HONESTY_HALLUCINATIONS = [
    "根据历史记录", "根据屏幕历史", "记录显示",
    "frame_id=1", "F#1 ",
]


def call_sim(transcript: str, timeout: int = 120) -> dict:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "openclicky_simulate_voice_turn",
                   "arguments": {"transcript": transcript}}
    }).encode()
    req = u.Request(BRIDGE, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {TOKEN}"},
                    data=payload)
    try:
        raw = u.urlopen(req, timeout=timeout).read().decode()
    except Exception as e:
        return {"ok": False, "error": f"http:{e}"}
    m = re.search(r'data:\s*(\{.*)', raw)
    if not m:
        return {"ok": False, "error": "no sse payload"}
    d = json.loads(m.group(1))
    for c in d.get("result", {}).get("content", []):
        if c.get("type") == "text":
            try:
                return json.loads(c["text"])
            except Exception:
                return {"ok": False, "error": "parse", "raw": c["text"][:200]}
    if "error" in d:
        return {"ok": False, "error": str(d["error"])}
    return {"ok": False, "error": "empty"}


def log_offset() -> int:
    try:
        return os.path.getsize(LOG_FILE)
    except FileNotFoundError:
        return 0


def log_since(offset: int) -> list:
    try:
        with open(LOG_FILE, "rb") as f:
            f.seek(offset)
            data = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return []
    events = []
    for line in data.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except Exception:
            pass
    return events


def evt_count(events, name):
    return sum(1 for e in events if e.get("event") == name)


def evaluate_answer(case: dict, answer: str) -> list:
    """Return list of reasons for FAIL. Empty list = pass."""
    reasons = []
    if not answer:
        reasons.append("empty_answer")
        return reasons
    for needle in case.get("expect_include", []):
        if needle.lower() not in answer.lower():
            reasons.append(f"missing:{needle}")
    for needle in case.get("expect_exclude", []):
        if needle in answer:
            reasons.append(f"forbidden:{needle}")
    if case.get("expect_min_honesty"):
        for phrase in HONESTY_HALLUCINATIONS:
            if phrase in answer:
                reasons.append(f"hallucination:{phrase}")
        # Honest answers typically say "没有/没" or ask for details.
        honesty_signals = ["没有", "无", "不知道", "没找到", "no record",
                            "没有相关", "没能查到", "not sure", "cannot",
                            "找不到", "请提供", "告诉我", "记不清"]
        if not any(sig in answer.lower() for sig in [s.lower() for s in honesty_signals]):
            reasons.append("no_honesty_signal")
    return reasons


def run_one_iteration(case: dict) -> dict:
    """One case iteration: seed → noise → query."""
    if case.get("seed"):
        call_sim(case["seed"])
        time.sleep(0.5)
    for n in case.get("noise", []):
        call_sim(n)
        time.sleep(0.5)
    offset = log_offset()
    t0 = time.time()
    resp = call_sim(case["query"])
    elapsed = int((time.time() - t0) * 1000)
    answer = (resp.get("assistantText") or "").replace("\n", " ")
    events = log_since(offset)
    reasons = evaluate_answer(case, answer)
    if case.get("expect_wrote") and evt_count(events, "conversation_logger.wrote") < case["expect_wrote"]:
        reasons.append(
            f"wrote={evt_count(events, 'conversation_logger.wrote')}<{case['expect_wrote']}")
    if not resp.get("ok"):
        reasons.append(f"resp.ok=false:{resp.get('error','')}")
    if case.get("expect_min_ltm_injection") and evt_count(events, "ltm.injected") == 0:
        reasons.append("ltm.injected=0")
    return {
        "answer": answer,
        "elapsedMs": elapsed,
        "hits_built": evt_count(events, "ltm.query_hits.built"),
        "hits_empty": evt_count(events, "ltm.query_hits.empty"),
        "ltm_injected": evt_count(events, "ltm.injected"),
        "wrote": evt_count(events, "conversation_logger.wrote"),
        "reasons": reasons,
    }


def run_case(case: dict, idx: int, total: int, n_runs: int) -> dict:
    name = case.get("name", f"case_{idx}")
    cat = case.get("category", "misc")
    print(f"\n----[ {idx+1}/{total} | {cat} ] {name} ----")
    print(f"  Q: {case['query']}")
    iters = []
    for r in range(n_runs):
        it = run_one_iteration(case)
        status = "pass" if not it["reasons"] else "fail"
        print(f"  run{r+1} {status} ({it['elapsedMs']} ms) "
              f"answer[:120]={it['answer'][:120]} "
              + (("reasons=" + ",".join(it["reasons"])) if it["reasons"] else ""))
        iters.append(it)
        time.sleep(1)
    pass_count = sum(1 for it in iters if not it["reasons"])
    fail_count = n_runs - pass_count
    latencies = [it["elapsedMs"] for it in iters]
    status = "PASS" if pass_count > fail_count else "FAIL"
    print(f"  → {status} ({pass_count}/{n_runs} passed) "
          f"p50={statistics.median(latencies)} ms "
          f"max={max(latencies)} ms")
    return {
        "name": name, "category": cat, "status": status,
        "pass_count": pass_count, "n_runs": n_runs,
        "p50_ms": statistics.median(latencies),
        "p95_ms": max(latencies) if len(latencies) < 20 else statistics.quantiles(latencies, n=20)[18],
        "iterations": iters,
        "query": case["query"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3, help="repetitions per case")
    ap.add_argument("--filter", help="only run cases with this substring in name")
    ap.add_argument("--file", default=CASES_FILE, help="cases file path")
    args = ap.parse_args()

    with open(args.file) as f:
        cases = json.load(f)
    if args.filter:
        cases = [c for c in cases if args.filter in c.get("name", "")]

    print(f"== AI regression — {len(cases)} cases × {args.runs} runs ==")
    results = []
    for i, c in enumerate(cases):
        results.append(run_case(c, i, len(cases), args.runs))
        time.sleep(1)

    pass_n = sum(1 for r in results if r["status"] == "PASS")
    fail_n = len(results) - pass_n
    print("\n" + "=" * 60)
    print(f"  overall: {pass_n}/{len(results)} PASS")
    # per-category
    from collections import defaultdict
    by_cat = defaultdict(list)
    for r in results:
        by_cat[r["category"]].append(r)
    for cat, rows in sorted(by_cat.items()):
        p = sum(1 for r in rows if r["status"] == "PASS")
        print(f"    {cat}: {p}/{len(rows)}")
    all_lat = [it["elapsedMs"] for r in results for it in r["iterations"]]
    if all_lat:
        print(f"  latency p50={statistics.median(all_lat)} ms "
              f"p95={statistics.quantiles(all_lat, n=20)[18] if len(all_lat) >= 20 else max(all_lat)} ms")
    print("=" * 60)

    # Detailed failures
    fails = [r for r in results if r["status"] == "FAIL"]
    if fails:
        print("\nFAILURES:")
        for r in fails:
            print(f"  - {r['name']} ({r['pass_count']}/{r['n_runs']})")
            for j, it in enumerate(r["iterations"]):
                if it["reasons"]:
                    print(f"      run{j+1}: reasons={it['reasons']}")
                    print(f"              answer={it['answer'][:200]}")

    with open(RESULTS_FILE, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\nresults: {RESULTS_FILE}")
    sys.exit(0 if fail_n == 0 else 1)


if __name__ == "__main__":
    main()
