#!/usr/bin/env bash
# POC 6 — Parallel tool calls per turn.
#
# Extends POC 3 with a schema variant:
#   {"action":"tool_calls","calls":[{"tool":...,"args":...},...]}
# Client executes ALL calls concurrently, batches results into one
# reply on the next turn.
#
# Test: creating 3 files in parallel should complete in 1 tool round
# instead of 3.
set -euo pipefail

TASK="${1:-在 /tmp/agent-parallel 目录下创建三个文件 a.txt b.txt c.txt, 内容分别为 alpha beta gamma. 如果可能, 请一次性并发调用. 完成后 done.}"
MAX_ROUNDS="${OPENCLICKY_MAX_ROUNDS:-6}"
OUT_DIR="${OPENCLICKY_OUT_DIR:-/tmp/openclicky-poc}"
mkdir -p "$OUT_DIR"

SESSION_JSON="$HOME/Library/Application Support/OpenClicky/heyclicky-session.json"
read_token() {
    python3 -c "
import json
with open('$SESSION_JSON') as f:
    print(json.load(f).get('openClickyHeyClickySessionAccessToken', ''))
"
}
ACCESS_TOKEN=$(read_token)

BASE="${HEYCLICKY_PROXY_BASE:?set HEYCLICKY_PROXY_BASE, e.g. https://your-worker.workers.dev}"
API_PATH="/chat-tool-call"
PROXY_OPT="-x http://127.0.0.1:10808"
RUN_ID=$(date +%s)
LOG="$OUT_DIR/parallel-$RUN_ID.log"
SANDBOX="/tmp/agent-parallel"
mkdir -p "$SANDBOX"

execute_one() {
    local tool="$1"
    local args_json="$2"
    python3 <<PYEOF
import json, subprocess, os
tool = "$tool"
args = json.loads("""$args_json""")
try:
    if tool == "write_file":
        os.makedirs(os.path.dirname(args["path"]), exist_ok=True)
        with open(args["path"], "w") as f: f.write(args["content"])
        print(json.dumps({"success": True, "path": args["path"], "bytes": len(args["content"])}))
    elif tool == "read_file":
        with open(args["path"], "r") as f: c = f.read()
        print(json.dumps({"success": True, "content": c}))
    elif tool == "run_shell":
        r = subprocess.run(args["cmd"], shell=True, capture_output=True, text=True, timeout=10)
        print(json.dumps({"success": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr, "exit": r.returncode}))
    else:
        print(json.dumps({"success": False, "error": f"unknown tool: {tool}"}))
except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYEOF
}

SYSTEM='You are an autonomous agent with a tool set.

Tools available:
- read_file(path) → {success, content}
- write_file(path, content) → {success, path, bytes}
- run_shell(cmd) → {success, stdout, stderr, exit}

Response format — output EXACTLY ONE JSON object per turn:

Single tool call:
{"action":"tool_call","tool":"<name>","args":{...},"thought":"..."}

Multiple tool calls (executed CONCURRENTLY on the client side):
{"action":"tool_calls","calls":[{"tool":"...","args":{...}},{"tool":"...","args":{...}}],"thought":"..."}

Finished:
{"action":"done","text":"..."}

Rules:
- ONE json per turn, no code fences, no preamble.
- Use "tool_calls" array when calls are independent (parallel).
- Use single "tool_call" when the next call depends on the previous result.

Task:
'"$TASK"

TRANSCRIPT="$SYSTEM"

for round in $(seq 1 "$MAX_ROUNDS"); do
    echo "=== Round $round ===" | tee -a "$LOG"

    BODY=$(python3 -c "
import json, sys
body = {'query': sys.stdin.read(), 'mimeType':'image/jpeg', 'screenshotBase64':'',
        'client_capabilities':[], 'frontmost_app_bundle_id':'com.jkneen.openclicky.poc',
        'environment':{'os_version':'15.0','timezone':'UTC','display_count':1}}
sys.stdout.write(json.dumps(body))
" <<< "$TRANSCRIPT")

    RESP="$OUT_DIR/parallel-$RUN_ID-r$round.json"
    HTTP=$(curl -sS -o "$RESP" -w "%{http_code}" --max-time 90 $PROXY_OPT \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
        -X POST --data-binary @<(printf '%s' "$BODY") "$BASE$API_PATH")

    if [ "$HTTP" != "200" ]; then
        echo "HTTP $HTTP"; cat "$RESP"; exit 1
    fi

    RAW=$(python3 -c "import json; print(json.load(open('$RESP')).get('text',''))")
    CLEANED=$(printf '%s' "$RAW" | python3 -c "
import sys, re
t = sys.stdin.read().strip()
m = re.search(r'\`\`\`(?:json)?\s*(.*?)\s*\`\`\`', t, re.DOTALL)
if m: t = m.group(1)
d=0; s=-1; e=-1
for i,c in enumerate(t):
    if c == '{':
        if d==0: s=i
        d += 1
    elif c == '}':
        d -= 1
        if d==0: e=i+1; break
print(t[s:e] if s>=0 else t)
")

    echo "  model: $(printf '%s' "$CLEANED" | head -c 300)" | tee -a "$LOG"

    ACTION=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('action','?'))")

    case "$ACTION" in
    "done")
        FINAL=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('text',''))")
        echo "== DONE ==" | tee -a "$LOG"
        echo "$FINAL" | tee -a "$LOG"
        exit 0
        ;;
    "tool_call")
        TOOL=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('tool',''))")
        ARGS=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read()).get('args',{})))")
        echo "  serial: $TOOL" | tee -a "$LOG"
        RESULT=$(execute_one "$TOOL" "$ARGS")
        echo "  ← $(printf '%s' "$RESULT" | head -c 150)" | tee -a "$LOG"
        TRANSCRIPT="$TRANSCRIPT

Prior turn result of $TOOL:
$RESULT

Next JSON:"
        ;;
    "tool_calls")
        # Parallel execution
        COUNT=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('calls',[])))")
        echo "  PARALLEL: $COUNT calls" | tee -a "$LOG"
        BATCH_RESULT="["
        START=$(python3 -c "import time; print(time.time())")
        PIDS=()
        TMP="$OUT_DIR/parallel-$RUN_ID-r$round-batch"
        mkdir -p "$TMP"
        for i in $(seq 0 $((COUNT - 1))); do
            TOOL_i=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['calls'][$i]['tool'])")
            ARGS_i=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['calls'][$i].get('args',{})))")
            ( execute_one "$TOOL_i" "$ARGS_i" > "$TMP/r$i.json" ) &
            PIDS+=($!)
        done
        for pid in "${PIDS[@]}"; do wait "$pid"; done
        DURATION=$(python3 -c "import time; print(round(time.time() - $START, 3))")
        # Assemble batch result
        BATCH_RESULT=$(python3 -c "
import json, os
tmp = '$TMP'
files = sorted(os.listdir(tmp), key=lambda x: int(x[1:-5]))
results = []
for fn in files:
    with open(os.path.join(tmp, fn)) as f:
        results.append(json.load(f))
print(json.dumps(results))
")
        echo "  ← $COUNT calls done in ${DURATION}s" | tee -a "$LOG"
        echo "  results: $(printf '%s' "$BATCH_RESULT" | head -c 200)" | tee -a "$LOG"
        TRANSCRIPT="$TRANSCRIPT

Prior turn — you issued $COUNT parallel tool calls. Results in order:
$BATCH_RESULT

Next JSON:"
        ;;
    *)
        echo "!! unexpected: $ACTION" | tee -a "$LOG"
        exit 1
        ;;
    esac
done

echo "!! max_rounds reached"
