#!/usr/bin/env bash
# POC 2 — Contract-based long-output continuation over
# HeyClicky Free /chat-tool-call.
#
# Protocol: model self-manages segmentation. It outputs as much as its
# per-turn output cap allows, then decides:
#   - Append [NEXT] on the last line → client sends another turn
#   - Append [DONE] on the last line → client stops
# No per-round char budget is imposed. Model uses its full output
# capacity each turn → minimal total round count → fastest completion.
#
# Usage:
#   bash scripts/poc-higher-model-continuation.sh "task description here"
#
# Env vars:
#   OPENCLICKY_MAX_PARTS   safety cap on rounds (default 12)
#   OPENCLICKY_OUT_DIR     output directory (default /tmp/openclicky-poc)
set -euo pipefail

TASK="${1:-输出《狂人日记》的前 800 字}"
MAX_PARTS="${OPENCLICKY_MAX_PARTS:-12}"
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
PATH_="/chat-tool-call"
PROXY_OPT="-x http://127.0.0.1:10808"

RUN_ID=$(date +%s)
LOG="$OUT_DIR/run-$RUN_ID.log"
FULL="$OUT_DIR/run-$RUN_ID-full.txt"
: > "$FULL"

echo "== POC 2: model-self-segmented continuation ==" | tee "$LOG"
echo "task: $TASK" | tee -a "$LOG"
echo "max_parts=$MAX_PARTS" | tee -a "$LOG"
echo "out: $FULL" | tee -a "$LOG"
echo "" | tee -a "$LOG"

build_query() {
    local part_num="$1"
    local prior="$2"
    if [ "$part_num" = "1" ]; then
        cat <<EOF
$TASK

Protocol for this response:
- Output as much as your per-turn output capacity allows. Do NOT
  artificially shorten. Do NOT insert filler summaries.
- If you are still writing when you approach your output limit, end
  the response with the literal line:
    [NEXT]
- If your response is complete and nothing else remains to be written,
  end with the literal line:
    [DONE]
- Either marker MUST be on its own last line, never mid-content.
- Never repeat content across turns.

Begin now.
EOF
    else
        cat <<EOF
Continuing multi-part response. Prior parts below:

$prior

--- End of prior parts ---

Continue writing where you left off. Same protocol:
- Output as much as your capacity allows.
- End with [NEXT] if more remains, [DONE] if complete.
- Do not repeat anything from prior parts.
EOF
    fi
}

extract_marker() {
    local text="$1"
    local last_line=$(printf '%s' "$text" | tail -1)
    if printf '%s' "$last_line" | grep -q '^\[DONE\]$'; then
        echo "DONE"
    elif printf '%s' "$last_line" | grep -q '^\[NEXT\]$'; then
        echo "NEXT"
    else
        echo "MISSING"
    fi
}

strip_marker() {
    python3 -c "
import sys
text = sys.stdin.read()
lines = text.rstrip('\n').split('\n')
if lines and lines[-1] in ('[NEXT]', '[DONE]'):
    lines.pop()
sys.stdout.write('\n'.join(lines))
"
}

PRIOR=""
for part in $(seq 1 "$MAX_PARTS"); do
    echo "=== Part $part ===" | tee -a "$LOG"
    QUERY=$(build_query "$part" "$PRIOR")

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
" <<< "$QUERY")

    RESP_FILE="$OUT_DIR/run-$RUN_ID-part-$part.json"
    echo "  → posting (query=${#QUERY} chars)" | tee -a "$LOG"

    # Try up to 2x: if 401, hot-reload token from session.json (App
    # keeps refreshing it in the background) and retry once.
    attempt=1
    while [ $attempt -le 2 ]; do
        HTTP_CODE=$(curl -sS -o "$RESP_FILE" -w "%{http_code}" \
            --max-time 90 \
            $PROXY_OPT \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            --data-binary @<(printf '%s' "$BODY") \
            "$BASE$PATH_" 2>&1 || echo "curl_fail")
        [ "$HTTP_CODE" = "401" ] || break
        echo "  ← HTTP 401, reloading token from session.json and retry" | tee -a "$LOG"
        sleep 2
        ACCESS_TOKEN=$(read_token)
        attempt=$((attempt + 1))
    done

    RESP_BYTES=$(wc -c < "$RESP_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    echo "  ← HTTP $HTTP_CODE, resp bytes: $RESP_BYTES" | tee -a "$LOG"

    if [ "$HTTP_CODE" != "200" ]; then
        echo "!! non-200; body:" | tee -a "$LOG"
        head -c 500 "$RESP_FILE" | tee -a "$LOG"
        echo "" | tee -a "$LOG"
        exit 1
    fi

    TEXT=$(python3 -c "
import json
with open('$RESP_FILE') as f:
    d = json.load(f)
print(d.get('text', ''))
")

    MARKER=$(extract_marker "$TEXT")
    echo "  marker: $MARKER   text_len: ${#TEXT}" | tee -a "$LOG"

    STRIPPED=$(printf '%s' "$TEXT" | strip_marker)

    if [ "$part" != "1" ]; then
        printf '\n' >> "$FULL"
    fi
    printf '%s' "$STRIPPED" >> "$FULL"

    PRIOR="$PRIOR

--- Part $part ---
$STRIPPED"

    if [ "$MARKER" = "DONE" ] || [ "$MARKER" = "MISSING" ]; then
        echo "" | tee -a "$LOG"
        echo "== stopped at part $part (marker=$MARKER) ==" | tee -a "$LOG"
        break
    fi
done

TOTAL=$(wc -c < "$FULL" | tr -d ' ')
echo "" | tee -a "$LOG"
echo "== final concatenated output: $TOTAL bytes at $FULL ==" | tee -a "$LOG"
