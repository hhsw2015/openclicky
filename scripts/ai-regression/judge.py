#!/usr/bin/env python3
"""LLM-as-judge 评分器. Takes a case + AI answer, asks advisor_consult
to score on:
  1. relevance     — did it address the intent?
  2. tool_use      — did it USE the right tool (history/web/nothing)?
  3. honesty       — no fabrication when data missing?
  4. depth         — reasoning steps, synthesis, extras?
  5. hallucination — cited things that don't exist?
Score 1-5 each. Also asks 'if bad, what pipeline improvement?'.
"""
import argparse, json, os, re, sys, time
import urllib.request as u

TOKEN = os.environ.get("OPENCLICKY_BRIDGE_TOKEN", "test-automation-token")
BRIDGE = os.environ.get("OPENCLICKY_BRIDGE_URL", "http://127.0.0.1:32123/mcp/sensor")

JUDGE_PROMPT_TEMPLATE = """你是一个严苛的 AI 智能评估专家. 给下面的 (用户问题, AI 回答) 对打分.
背景: 这个 AI 有以下工具可用:
  - rewind_search / rewind_ask (查用户的屏幕历史 + 过去对话)
  - advisor_web_search (联网查最新事实)
  - screenshot / focused_context (看当前屏幕)
  - conversation history (最近几轮 seed 会作为上下文注入)

用户问题:
```
{query}
```

期望背景 (只是我给的参考, 你要独立判断):
{expected}

AI 的回答:
```
{answer}
```

请打分 1-5 (5 是最好, 1 是最差), 严格苛刻:

- relevance: AI 是否真正理解并回答了问题?
- tool_use: AI 是否**在应该**用工具时用了 (拉历史/联网/看屏幕),不该用时也没滥用?
- honesty: 无信息时诚实说不知道, 还是编造?
- depth: 有推理/综合/超预期的信息?
- hallucination: 引用了不存在的 frame / 编造的记忆? (5=完全不虚构)

如果**质量不够好**, 给一条**具体的流程改进建议** (改哪个环节: LTM/prompt/工具选择/等).

只输出 JSON, 一个对象, 无 markdown:
{{"relevance": <1-5>, "tool_use": <1-5>, "honesty": <1-5>, "depth": <1-5>, "hallucination": <1-5>, "overall": <1-5>, "improvement": "<一句话建议, 或 'none' 若无>", "reason": "<10-40 字打分理由>"}}
"""


def call_advisor(prompt: str) -> str:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "advisor_consult",
                   "arguments": {"query": prompt}}
    }).encode()
    req = u.Request(BRIDGE, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {TOKEN}"},
                    data=payload)
    raw = u.urlopen(req, timeout=90).read().decode()
    m = re.search(r'data:\s*(\{.*)', raw)
    if not m:
        return ""
    d = json.loads(m.group(1))
    for c in d.get("result", {}).get("content", []):
        if c.get("type") == "text":
            return c["text"]
    return ""


def judge_one(case: dict, answer: str) -> dict:
    expected = "\n".join([
        f"- expect_include: {case.get('expect_include', [])}",
        f"- expect_exclude: {case.get('expect_exclude', [])}",
        f"- category: {case.get('category', '?')}",
        f"- honesty required: {case.get('expect_min_honesty', False)}",
    ])
    prompt = JUDGE_PROMPT_TEMPLATE.format(
        query=case["query"], expected=expected, answer=answer)
    raw = call_advisor(prompt)
    # Strip anything before first { and after last }
    a = raw.find("{")
    b = raw.rfind("}")
    if a < 0 or b < a:
        return {"error": "no json in judge output", "raw": raw[:200]}
    try:
        return json.loads(raw[a:b+1])
    except Exception as e:
        return {"error": f"parse:{e}", "raw": raw[a:b+1][:400]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="/tmp/ai-regression-results.json",
                    help="regression results.json from run.py")
    ap.add_argument("--cases", default=None,
                    help="cases.json (default: results-adjacent auto-detect)")
    ap.add_argument("--out", default="/tmp/ai-regression-judged.json")
    args = ap.parse_args()

    with open(args.results) as f:
        results = json.load(f)

    if args.cases:
        with open(args.cases) as f:
            cases = json.load(f)
        by_name = {c["name"]: c for c in cases}
    else:
        by_name = {}

    judged = []
    for r in results:
        cname = r["name"]
        # Grab first non-empty iteration's answer
        answer = ""
        for it in r.get("iterations", []):
            if it.get("answer"):
                answer = it["answer"]
                break
        # Build a minimal case dict from result if no cases file
        case_stub = by_name.get(cname, {
            "name": cname, "query": r.get("query", ""),
            "category": r.get("category", "?"),
        })
        print(f"\njudging {cname} ({r.get('category','?')})")
        print(f"  Q: {case_stub.get('query','')[:100]}")
        print(f"  A: {answer[:120]}")
        j = judge_one(case_stub, answer)
        print(f"  score: {j}")
        judged.append({"name": cname, "category": r.get("category"),
                       "query": case_stub.get("query"),
                       "answer": answer[:400],
                       "judge": j})
        time.sleep(2)

    with open(args.out, "w") as f:
        json.dump(judged, f, ensure_ascii=False, indent=2)

    # Summary
    scores = [j["judge"] for j in judged if isinstance(j.get("judge"), dict)
              and "overall" in j["judge"]]
    print("\n" + "=" * 60)
    if scores:
        for dim in ["relevance", "tool_use", "honesty", "depth",
                    "hallucination", "overall"]:
            vals = [s.get(dim, 0) for s in scores if isinstance(s.get(dim), (int, float))]
            if vals:
                avg = sum(vals) / len(vals)
                print(f"  {dim:15s}: avg={avg:.2f} min={min(vals)} max={max(vals)}")
    print(f"\n  judged: {args.out}")

    # Print improvements
    print("\nImprovements suggested by judge:")
    for j in judged:
        imp = j.get("judge", {}).get("improvement", "")
        if imp and imp.lower() != "none":
            print(f"  - {j['name']} ({j['category']}): {imp}")


if __name__ == "__main__":
    main()
