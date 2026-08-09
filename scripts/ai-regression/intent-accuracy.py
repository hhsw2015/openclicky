#!/usr/bin/env python3
"""Realtime intent-classifier accuracy suite.

Sends 30+ test utterances through `openclicky_realtime_text_probe`,
each labelled with its expected `intent` category. After each probe
we wait for the intent to land in the message log (event
`realtime.tool_call.intent`) and score correctness. No microphone,
no TTS — pure text into the realtime session.

Categories tested: world_knowledge, past_memory, live_context,
recent_conv, other.

Result: per-category precision, overall accuracy, and a table of
mis-classifications for prompt-tuning.
"""
import argparse, json, os, re, sys, time
import urllib.request as u

TOKEN = os.environ.get("OPENCLICKY_BRIDGE_TOKEN", "test-automation-token")
BRIDGE = os.environ.get("OPENCLICKY_BRIDGE_URL",
                        "http://127.0.0.1:32123/mcp/sensor")
LOG_FILE = os.path.expanduser(
    "~/Library/Application Support/OpenClicky/Logs/messages-"
    + time.strftime("%Y-%m-%d") + ".jsonl")

CASES = [
    # world_knowledge
    ("光速是多少",                          "world_knowledge"),
    ("苹果公司哪年成立",                    "world_knowledge"),
    ("水的沸点是多少",                      "world_knowledge"),
    ("牛顿三大定律是什么",                  "world_knowledge"),
    ("太阳系有几颗行星",                    "world_knowledge"),
    ("Who wrote Hamlet",                    "world_knowledge"),
    ("What is the speed of light",          "world_knowledge"),
    ("Explain quantum entanglement",        "world_knowledge"),
    # past_memory
    ("我上次问过 kafka 的什么",             "past_memory"),
    ("刚才那个项目代号叫什么",              "past_memory"),
    ("上周那个 bug 是怎么修的",             "past_memory"),
    ("我之前告诉你的 API key 是什么",       "past_memory"),
    ("我最近在读的那本书是啥",              "past_memory"),
    ("What did I tell you about my stack",  "past_memory"),
    ("Remind me what we agreed last time",  "past_memory"),
    ("Show me the file I was editing",      "past_memory"),
    # live_context
    ("我现在屏幕上是什么",                  "live_context"),
    ("这个报错是什么意思",                  "live_context"),
    ("这段代码有问题吗",                    "live_context"),
    ("当前窗口标题是啥",                    "live_context"),
    ("帮我点亮那个保存按钮",                "live_context"),
    ("What is on my screen right now",      "live_context"),
    ("Read the text visible here",          "live_context"),
    ("Point at the login field",            "live_context"),
    # recent_conv
    ("接着刚才说",                          "recent_conv"),
    ("再详细讲一下",                        "recent_conv"),
    ("换种方式说",                          "recent_conv"),
    ("总结下我们刚才聊的",                  "recent_conv"),
    ("Continue from where we left off",     "recent_conv"),
    ("Rephrase that please",                "recent_conv"),
]


def call_probe(text: str) -> dict:
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "openclicky_realtime_text_probe",
                   "arguments": {"text": text}}
    }).encode()
    req = u.Request(BRIDGE, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": f"Bearer {TOKEN}"},
                    data=payload)
    try:
        raw = u.urlopen(req, timeout=15).read().decode()
    except Exception as e:
        return {"ok": False, "error": f"http:{e}"}
    m = re.search(r"data:\s*(\{.*)", raw)
    if not m:
        return {"ok": False, "error": "no sse"}
    d = json.loads(m.group(1))
    for c in d.get("result", {}).get("content", []):
        if c.get("type") == "text":
            try:
                return json.loads(c["text"])
            except Exception:
                return {"ok": True}
    return d


def log_size() -> int:
    try: return os.path.getsize(LOG_FILE)
    except FileNotFoundError: return 0


def wait_for_intent(offset: int, text_prefix: str,
                    timeout: float = 12.0) -> str | None:
    """Poll log until an `intent` event matching this prompt shows up."""
    prefix = text_prefix[:60]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(LOG_FILE, "rb") as f:
                f.seek(offset)
                data = f.read().decode("utf-8", errors="replace")
        except FileNotFoundError:
            data = ""
        for line in data.splitlines()[::-1]:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
            except:
                continue
            if d.get("event") != "realtime.tool_call.intent":
                continue
            f_ = d.get("fields", {})
            preview = str(f_.get("transcript_preview", ""))
            if preview.startswith(prefix) or prefix.startswith(preview):
                return f_.get("intent")
        time.sleep(0.3)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="filter cases containing this substring")
    args = ap.parse_args()

    cases = CASES
    if args.only:
        cases = [c for c in cases if args.only in c[0]]

    print(f"== intent classifier test — {len(cases)} cases ==\n")
    results = []
    for i, (text, expected) in enumerate(cases):
        off = log_size()
        r = call_probe(text)
        if not r.get("ok"):
            print(f"  [{i+1}/{len(cases)}] SKIP: probe failed ({r.get('error')})")
            results.append((text, expected, None, "probe_failed"))
            continue
        got = wait_for_intent(off, text)
        status = "PASS" if got == expected else "FAIL"
        print(f"  [{i+1}/{len(cases)}] {status}  expected={expected:<15}"
              f" got={str(got):<15}  '{text}'")
        results.append((text, expected, got, status))
        time.sleep(0.5)

    # Summary
    from collections import Counter, defaultdict
    total = len(results)
    passed = sum(1 for r in results if r[3] == "PASS")
    per_cat: dict = defaultdict(lambda: [0, 0])
    misclass = Counter()
    for _, exp, got, s in results:
        per_cat[exp][1] += 1
        if s == "PASS": per_cat[exp][0] += 1
        elif got and got != exp:
            misclass[(exp, got)] += 1

    print("\n" + "=" * 60)
    print(f"  accuracy: {passed}/{total} ({100*passed/max(total,1):.1f}%)")
    for cat, (p, n) in sorted(per_cat.items()):
        print(f"    {cat:15s}: {p}/{n}")
    if misclass:
        print("\n  misclassifications:")
        for (exp, got), n in misclass.most_common():
            print(f"    {exp:15s} → {got:15s}  ×{n}")
    print("=" * 60)

    with open("/tmp/intent-accuracy.json", "w") as f:
        json.dump({"results": results,
                    "accuracy": passed / max(total, 1)}, f,
                   ensure_ascii=False, indent=2)
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
