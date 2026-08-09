#!/usr/bin/env bash
# POC 3 — Client-orchestrated agent loop.
#
# Protocol: pure client design. The higher-model is instructed to
# output ONE JSON object per turn describing either a tool call or
# a final answer. Client parses, executes the tool locally (fs, shell,
# http, etc.), feeds the result back on the next turn, until the
# model outputs {"action":"done"}. Server needs zero modification.
#
# Tools implemented for this POC:
#   read_file  {"path"}
#   write_file {"path", "content"}
#   run_shell  {"cmd"}
#   list_dir   {"path"}
#
# Usage:
#   bash scripts/poc-higher-model-agent-loop.sh "task"
#
# Env:
#   OPENCLICKY_MAX_ROUNDS  safety cap (default 10)
set -euo pipefail

TASK="${1:-创建 /tmp/openclicky-poc-agent/hello.txt 内容为 'hello from agent',然后读回来验证}"
MAX_ROUNDS="${OPENCLICKY_MAX_ROUNDS:-10}"
OUT_DIR="${OPENCLICKY_OUT_DIR:-/tmp/openclicky-poc}"
mkdir -p "$OUT_DIR"

SESSION_JSON="$HOME/Library/Application Support/OpenClicky/heyclicky-session.json"
[ -f "$SESSION_JSON" ] || { echo "!! session not found" >&2; exit 1; }

read_token() {
    python3 -c "
import json
with open('$SESSION_JSON') as f:
    d = json.load(f)
print(d.get('openClickyHeyClickySessionAccessToken', ''))
"
}
ACCESS_TOKEN=$(read_token)
[ -n "$ACCESS_TOKEN" ] || { echo "!! no token" >&2; exit 1; }

BASE="${HEYCLICKY_PROXY_BASE:?set HEYCLICKY_PROXY_BASE, e.g. https://your-worker.workers.dev}"
API_PATH="/chat-tool-call"
PROXY_OPT="-x http://127.0.0.1:10808"

RUN_ID=$(date +%s)
LOG="$OUT_DIR/agent-$RUN_ID.log"
TRANSCRIPT="$OUT_DIR/agent-$RUN_ID-transcript.txt"
: > "$TRANSCRIPT"

echo "== POC 3: client-orchestrated agent loop ==" | tee "$LOG"
echo "task: $TASK" | tee -a "$LOG"
echo "max_rounds=$MAX_ROUNDS" | tee -a "$LOG"
echo "transcript: $TRANSCRIPT" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Sandboxed working directory for shell/file tools
SANDBOX="/tmp/openclicky-poc-agent"
mkdir -p "$SANDBOX"

execute_tool() {
    local tool="$1"
    local args_json="$2"
    python3 <<PYEOF
import json, subprocess, os, urllib.request
tool = "$tool"
args = json.loads("""$args_json""")
sandbox = "$SANDBOX"

def result(**kw):
    print(json.dumps(kw))

try:
    if tool == "read_file":
        path = args["path"]
        if not path.startswith(sandbox + "/") and not path.startswith("/tmp/"):
            result(success=False, error=f"path outside sandbox: {path}")
        else:
            with open(path, "r") as f:
                result(success=True, content=f.read())
    elif tool == "write_file":
        path = args["path"]
        content = args["content"]
        if not path.startswith(sandbox + "/") and not path.startswith("/tmp/"):
            result(success=False, error=f"path outside sandbox: {path}")
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(content)
            result(success=True, bytes=len(content), path=path)
    elif tool == "run_shell":
        cmd = args["cmd"]
        # Sandbox: only allow certain commands
        allowed = ["ls", "cat", "echo", "date", "pwd", "wc", "grep", "head", "tail", "find", "mkdir"]
        first = cmd.strip().split()[0] if cmd.strip() else ""
        if first not in allowed:
            result(success=False, error=f"command not allowed: {first}")
        else:
            out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10, cwd=sandbox)
            result(success=out.returncode == 0, stdout=out.stdout[:2000], stderr=out.stderr[:500], exit=out.returncode)
    elif tool == "list_dir":
        path = args.get("path", sandbox)
        result(success=True, entries=os.listdir(path))
    elif tool == "http_get":
        req = urllib.request.Request(args["url"])
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read(4000).decode("utf-8", "replace")
        result(success=True, body=body)
    else:
        result(success=False, error=f"unknown tool: {tool}")
except Exception as e:
    result(success=False, error=str(e))
PYEOF
}

SYSTEM_PROMPT='You are an autonomous agent. The user gave you a task.
You have these tools available:

- read_file(path: string) → {success, content}
- write_file(path: string, content: string) → {success, bytes, path}
- run_shell(cmd: string) → {success, stdout, stderr, exit}   [only ls/cat/echo/date/pwd/wc/grep/head/tail/find/mkdir allowed]
- list_dir(path: string) → {success, entries}
- http_get(url: string) → {success, body}

Response protocol — output EXACTLY ONE JSON object per turn, no markdown fences, no preamble:

If you need to run a tool:
{"action":"tool_call","tool":"<tool_name>","args":{...},"thought":"why you are running this"}

If you have finished the task:
{"action":"done","text":"final answer to the user"}

Rules:
- ONE json per turn, nothing else in the response.
- No code fences around the JSON.
- After each tool call, you will see the tool result in the next turn.
- If a tool errors, decide whether to retry with different args or abort with action=done.
- Paths must be under /tmp/ for safety.

Task:
'"$TASK"

TRANSCRIPT_TEXT="$SYSTEM_PROMPT"

for round in $(seq 1 "$MAX_ROUNDS"); do
    echo "=== Round $round ===" | tee -a "$LOG"

    BODY=$(python3 -c "
import json, sys
body = {
    'query': sys.stdin.read(),
    'mimeType': 'image/jpeg',
    'screenshotBase64': '',
    'client_capabilities': [],
    'frontmost_app_bundle_id': 'com.jkneen.openclicky.poc',
    'environment': {'os_version': '15.0', 'timezone': 'UTC', 'display_count': 1}
}
sys.stdout.write(json.dumps(body))
" <<< "$TRANSCRIPT_TEXT")

    RESP_FILE="$OUT_DIR/agent-$RUN_ID-round-$round.json"

    attempt=1
    while [ $attempt -le 2 ]; do
        HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
            --max-time 90 \
            $PROXY_OPT \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            --data-binary @<(printf '%s' "$BODY") \
            "$BASE$API_PATH" 2>&1 || echo "curl_fail")
        [ "$HTTP_CODE" = "401" ] || break
        sleep 2
        ACCESS_TOKEN=$(read_token)
        attempt=$((attempt + 1))
    done

    if [ "$HTTP_CODE" != "200" ]; then
        echo "!! HTTP $HTTP_CODE" | tee -a "$LOG"
        head -c 500 "$RESP_FILE" | tee -a "$LOG"
        exit 1
    fi

    RAW_TEXT=$(python3 -c "
import json
with open('$RESP_FILE') as f:
    d = json.load(f)
print(d.get('text', ''))
")

    echo "  model output:" | tee -a "$LOG"
    printf '    %s\n' "$RAW_TEXT" | tee -a "$LOG"

    # Strip common wrappers (```json ... ```)
    CLEANED=$(printf '%s' "$RAW_TEXT" | python3 -c "
import sys, re
t = sys.stdin.read().strip()
# strip ```json ... ``` or ``` ... ```
m = re.search(r'\`\`\`(?:json)?\s*(.*?)\s*\`\`\`', t, re.DOTALL)
if m:
    t = m.group(1)
# take first {..} balanced object
depth = 0; start = -1; end = -1
for i, c in enumerate(t):
    if c == '{':
        if depth == 0: start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: end = i + 1; break
if start >= 0 and end > start:
    t = t[start:end]
print(t)
")

    ACTION=$(printf '%s' "$CLEANED" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('action', 'invalid'))
except Exception as e:
    print(f'parse_fail:{e}')
")

    case "$ACTION" in
        "done")
            FINAL=$(printf '%s' "$CLEANED" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d.get('text', ''))
")
            echo "" | tee -a "$LOG"
            echo "== DONE ==" | tee -a "$LOG"
            echo "final: $FINAL" | tee -a "$LOG"
            printf '\n\nRound %d (assistant):\n%s\n' "$round" "$CLEANED" >> "$TRANSCRIPT"
            exit 0
            ;;
        "tool_call")
            TOOL=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('tool',''))")
            ARGS=$(printf '%s' "$CLEANED" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get('args',{})))")
            echo "  → tool: $TOOL, args: $ARGS" | tee -a "$LOG"

            TOOL_RESULT=$(execute_tool "$TOOL" "$ARGS")
            echo "  ← result: $(printf '%s' "$TOOL_RESULT" | head -c 200)" | tee -a "$LOG"

            printf '\n\nRound %d (assistant):\n%s\n\nRound %d (tool_result):\n%s\n' \
                "$round" "$CLEANED" "$round" "$TOOL_RESULT" >> "$TRANSCRIPT"

            TRANSCRIPT_TEXT="$TRANSCRIPT_TEXT

Prior turn — you called tool $TOOL. Result:
$TOOL_RESULT

Now respond with the next JSON object (tool_call or done)."
            ;;
        parse_fail:*)
            echo "!! parse failed: $ACTION" | tee -a "$LOG"
            echo "  raw cleaned: $CLEANED" | tee -a "$LOG"
            TRANSCRIPT_TEXT="$TRANSCRIPT_TEXT

Prior turn — your response could not be parsed as JSON. Emit exactly ONE JSON object next turn."
            ;;
        *)
            echo "!! unexpected action: $ACTION" | tee -a "$LOG"
            exit 1
            ;;
    esac
done

echo "" | tee -a "$LOG"
echo "!! hit max_rounds=$MAX_ROUNDS without done" | tee -a "$LOG"
