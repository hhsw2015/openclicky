#!/usr/bin/env python3
"""跑单个精心设计 case, 用 LLM-judge 评分, 输出流程改进建议.
Usage: python3 single-case.py [--case NAME]
"""
import argparse, json, os, re, sys, time
import urllib.request as u

TOKEN = os.environ.get("OPENCLICKY_BRIDGE_TOKEN", "test-automation-token")
BRIDGE = os.environ.get("OPENCLICKY_BRIDGE_URL", "http://127.0.0.1:32123/mcp/sensor")
LOG_FILE = os.path.expanduser(
    "~/Library/Application Support/OpenClicky/Logs/messages-"
    + time.strftime("%Y-%m-%d") + ".jsonl")


# — CASE catalog. Each is a multi-turn scenario probing DIFFERENT axes.
CASES = {
    "memory-plus-web": {
        "description": "记忆 + 联网融合. seed 一个技术栈, 后追问结合外部知识的问题.",
        "seed": "记住:我在用 Rust 1.75 + tokio 1.35 + sqlx 0.7 做一个 API 服务, 目标 QPS 5000.",
        "query": "Rust 1.75 里有个新特性 async fn in trait, 结合我的技术栈能优化哪里?",
        "why_hard": "需要:(1)拉出 seed 记忆里的技术栈, (2)可能联网确认 async fn in trait 语义, (3)推理哪个组件受益.",
    },
    "cross-turn-negation": {
        "description": "多轮记忆修正. 用户先说A, 后改成B, 再问该记什么.",
        "seed": "我用 vim 编辑代码.",
        "noise": ["更正下, 其实我用 neovim 加 lazyvim.", "vim 是很久前的事了."],
        "query": "我现在用什么编辑器? 你之前的记忆需要更新吗?",
        "why_hard": "需要抓最新版本的记忆, 不能只回第一个 seed.",
    },
    "self-aware-tool-choice": {
        "description": "该拉历史时拉, 不该拉时不拉. 问一个明显世界知识问题.",
        "query": "水的沸点在海平面是多少摄氏度?",
        "why_hard": "AI 不该浪费工具去查历史, 应直接答 100°C.",
    },
    "screenshot-referral": {
        "description": "指代当前屏幕上的东西.",
        "query": "我现在屏幕上正在开的窗口是什么? 里面有几个 tab?",
        "why_hard": "需要 screenshot / focused_window / current app 三条工具.",
    },
    "compound-reasoning": {
        "description": "综合过去+现在+推理.",
        "seed": "我记住:我这周任务是重构 LTM 检索管线, 目标周五上线.",
        "query": "今天周几?按剩余时间, 我如果 3 天写完代码, 应该几号开始上线测试?",
        "why_hard": "需要:(1)记 seed 的任务, (2)get 当前日期, (3)算差值.",
    },
}


def call_tool(name: str, args: dict, timeout: int = 120) -> dict:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": args}
    }).encode()
    req = u.Request(BRIDGE, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {TOKEN}"},
                    data=payload)
    raw = u.urlopen(req, timeout=timeout).read().decode()
    m = re.search(r'data:\s*(\{.*)', raw)
    if not m:
        return {"ok": False, "error": "no sse"}
    d = json.loads(m.group(1))
    for c in d.get("result", {}).get("content", []):
        if c.get("type") == "text":
            try:
                return json.loads(c["text"])
            except Exception:
                return {"ok": True, "text": c["text"]}
    return d


def log_offset() -> int:
    try: return os.path.getsize(LOG_FILE)
    except FileNotFoundError: return 0


def log_since(offset: int) -> list:
    try:
        with open(LOG_FILE, "rb") as f:
            f.seek(offset)
            data = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return []
    out = []
    for line in data.splitlines():
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except: pass
    return out


JUDGE_TMPL = """你是苛刻的 AI 智能评估专家. 给下面的对答严格打分.

场景: {desc}
为什么难: {why_hard}

用户问题:
{query}

AI 回答:
```
{answer}
```

pipeline log 摘要 (关键事件):
{log_summary}

打分 (每维 1-5, 5 最好):
- intent_understanding: 是否听懂用户真实意图?
- tool_orchestration: 是否**在恰当时机**用了合适工具? (拉历史/联网/看屏幕/什么都不用)
- honesty: 无数据时诚实说不知道 / 有数据时准确引用?
- depth_and_synthesis: 是否融会贯通 (从多源综合)?
- would_impress_user: 回答是否**超出用户预期**?
- overall: 综合分.

然后给一段"如果不完美, pipeline 具体哪里可改进" (指到具体环节: LTM query 生成 / 工具 prompt / 判断逻辑 / 等). 若已完美写 "none".

只输出一个 JSON, 无 markdown:
{{"intent_understanding": <1-5>, "tool_orchestration": <1-5>, "honesty": <1-5>, "depth_and_synthesis": <1-5>, "would_impress_user": <1-5>, "overall": <1-5>, "improvement": "<改进建议或 none>", "reason": "<10-40 字打分理由>"}}
"""


def judge(desc, why_hard, query, answer, events) -> dict:
    interesting = [e for e in events if any(e.get("event", "").startswith(p) for p in [
        "ltm.", "conversation_logger.", "chat.re", "realtime.tool_call",
        "openclicky.voice.stash", "openclicky.preflight",
        "advisor_", "assist_agent."
    ])]
    log_lines = []
    for e in interesting[-30:]:
        f = e.get("fields", {})
        keys = ["queryPreview","hitCount","topFrame","hitsLen","ltmChars",
                "text_len","has_typing","has_point","name","args_preview"]
        val = {k: f[k] for k in keys if k in f}
        log_lines.append(f"  {e.get('timestamp','')[11:19]} {e.get('event','')} {val}")
    log_summary = "\n".join(log_lines) if log_lines else "(no relevant events)"
    prompt = JUDGE_TMPL.format(desc=desc, why_hard=why_hard, query=query,
                                answer=answer, log_summary=log_summary)
    # advisor_consult lives on /tools/calls (not /mcp/sensor)
    endpoint = BRIDGE.replace("/mcp/sensor", "/tools/calls")
    payload = json.dumps({"tools": [{"name": "advisor_consult",
                                      "arguments": {"query": prompt}}]}).encode()
    req = u.Request(endpoint, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {TOKEN}"},
                    data=payload)
    try:
        raw = u.urlopen(req, timeout=90).read().decode()
        d = json.loads(raw)
        txt = d.get("results", [{}])[0].get("body", {}).get("text", "")
    except Exception as e:
        return {"error": f"advisor:{e}"}
    a = txt.find("{"); b = txt.rfind("}")
    if a < 0 or b < a:
        return {"error": "no json", "raw": txt[:300]}
    try: return json.loads(txt[a:b+1])
    except Exception as e:
        return {"error": f"parse:{e}", "raw": txt[a:b+1][:400]}


def run_case(name: str):
    c = CASES[name]
    print(f"\n=== {name} ===")
    print(f"desc: {c['description']}")
    print(f"why_hard: {c['why_hard']}")
    if "seed" in c:
        print(f"[seed] {c['seed']}")
        call_tool("openclicky_simulate_voice_turn", {"transcript": c["seed"]})
        time.sleep(0.5)
    for n in c.get("noise", []):
        print(f"[noise] {n}")
        call_tool("openclicky_simulate_voice_turn", {"transcript": n})
        time.sleep(0.5)
    offset = log_offset()
    print(f"[Q] {c['query']}")
    t0 = time.time()
    resp = call_tool("openclicky_simulate_voice_turn", {"transcript": c["query"]})
    elapsed = int((time.time() - t0) * 1000)
    answer = (resp.get("assistantText") or "").replace("\n", " ")
    print(f"[A ({elapsed} ms)] {answer[:400]}")
    events = log_since(offset)
    j = judge(c["description"], c["why_hard"], c["query"], answer, events)
    print(f"\n[judge] {json.dumps(j, ensure_ascii=False, indent=2)}")
    return {"case": name, "answer": answer, "elapsedMs": elapsed, "judge": j, "event_count": len(events)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", default="memory-plus-web", choices=list(CASES.keys()))
    ap.add_argument("--all", action="store_true", help="run every case")
    args = ap.parse_args()
    if args.all:
        results = []
        for k in CASES:
            results.append(run_case(k))
            time.sleep(2)
        with open("/tmp/single-case-results.json", "w") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
    else:
        run_case(args.case)


if __name__ == "__main__":
    main()
