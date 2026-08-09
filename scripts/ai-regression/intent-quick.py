#!/usr/bin/env python3
"""3-case probe: only necessarily-tool scenarios so we see the intent.
"""
import json, os, re, sys, time
import urllib.request as u

TOKEN = os.environ.get("OPENCLICKY_BRIDGE_TOKEN", "test-automation-token")
BRIDGE = "http://127.0.0.1:32123/mcp/sensor"
LOG_FILE = os.path.expanduser(
    "~/Library/Application Support/OpenClicky/Logs/messages-"
    + time.strftime("%Y-%m-%d") + ".jsonl")

# Only prompts where realtime MUST hand off to chat model.
CASES = [
    ("我刚才问过 kafka 的什么", "past_memory"),
    ("这个报错什么意思", "live_context"),
    ("我上次讨论的那个方案是啥",  "past_memory"),
]

def probe(text):
    p = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
        "params":{"name":"openclicky_realtime_text_probe","arguments":{"text":text}}}).encode()
    req = u.Request(BRIDGE, method="POST",
        headers={"Content-Type":"application/json","Authorization":f"Bearer {TOKEN}"},
        data=p)
    u.urlopen(req, timeout=15).read()

def logsize():
    try: return os.path.getsize(LOG_FILE)
    except: return 0

def wait_intent(off, txt, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with open(LOG_FILE, "rb") as f:
                f.seek(off); data = f.read().decode("utf-8", errors="replace")
        except: data = ""
        for line in data.splitlines()[::-1]:
            try: d = json.loads(line)
            except: continue
            if d.get("event") == "realtime.tool_call.intent":
                pv = d.get("fields",{}).get("transcript_preview","")
                if pv and (pv.startswith(txt[:20]) or txt.startswith(pv[:20])):
                    return d.get("fields",{}).get("intent")
        time.sleep(0.4)
    return None

for i,(t,exp) in enumerate(CASES):
    off = logsize()
    probe(t)
    got = wait_intent(off, t)
    status = "PASS" if got == exp else "FAIL"
    print(f"[{i+1}/{len(CASES)}] {status}  expected={exp} got={got}  '{t}'")
    # realtime serialises turns; give the previous response.create
    # room to finish before we queue the next one, otherwise the
    # tool_call for turn N lands 30s after we asked for turn N+1.
    time.sleep(4)
