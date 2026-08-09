#!/usr/bin/env bash
# Probe: what model is actually serving /chat-tool-call?
# Also measure:
#   - Max output tokens per turn
#   - Context window (send progressively larger payloads until fail)
#   - Structured output stability (50 samples of same JSON task)
set -euo pipefail

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
TOKEN=$(read_token)
BASE="${HEYCLICKY_PROXY_BASE:?set HEYCLICKY_PROXY_BASE, e.g. https://your-worker.workers.dev}"
PATH_="/chat-tool-call"
PROXY_OPT="-x http://127.0.0.1:10808"

post() {
    local query="$1"
    local body=$(python3 -c "
import json, sys
print(json.dumps({'query': sys.stdin.read(), 'mimeType':'image/jpeg','screenshotBase64':'',
                   'client_capabilities':[],'frontmost_app_bundle_id':'com.jkneen.poc',
                   'environment':{'os_version':'15','timezone':'UTC','display_count':1}}))
" <<< "$query")
    curl -sS --max-time 60 $PROXY_OPT \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -X POST --data-binary @<(printf '%s' "$body") "$BASE$PATH_"
}

echo "======================================================"
echo "PROBE 1: model self-identification"
echo "======================================================"
for q in \
    "What model are you? Give your exact model name and provider." \
    "Are you Claude, GPT, Gemini, or something else? Answer only with model name." \
    "You are running on which LLM backend? Company + model version." ; do
    echo "--- Q: $q ---"
    R=$(post "$q")
    printf '%s' "$R" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('TEXT:', d.get('text','')[:400])"
    echo ""
    sleep 2
done

echo ""
echo "======================================================"
echo "PROBE 2: max output tokens per turn"
echo "======================================================"
# Ask model to output "1234567890" repeated forever until it can't
R=$(post 'Output the digit sequence "1234567890" repeated as many times as your output allows. Do NOT stop until you literally cannot output more. No preamble. Start immediately.')
LEN=$(printf '%s' "$R" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d.get('text','')))")
echo "single-turn output length: $LEN chars"
echo "first 100 chars: $(printf '%s' "$R" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('text','')[:100])")"

echo ""
echo "======================================================"
echo "PROBE 3: structured output stability (10 runs)"
echo "======================================================"
JSON_TASK='Output EXACTLY this JSON on ONE line, nothing else, no markdown fences:
{"action":"tool_call","tool":"write_file","args":{"path":"/tmp/test.txt","content":"hello world"},"thought":"creating a test file"}'
FAILS=0
for i in $(seq 1 10); do
    R=$(post "$JSON_TASK")
    RAW=$(printf '%s' "$R" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('text',''))" | head -c 500)
    # Try to parse as JSON
    OK=$(printf '%s' "$RAW" | python3 -c "
import json, sys, re
t = sys.stdin.read().strip()
m = re.search(r'\`\`\`(?:json)?\s*(.*?)\s*\`\`\`', t, re.DOTALL)
if m: t = m.group(1)
try:
    d = json.loads(t)
    if d.get('action') == 'tool_call':
        print('OK')
    else:
        print(f'WRONG_ACTION:{d.get(\"action\",\"?\")}')
except Exception as e:
    print(f'PARSE_FAIL:{type(e).__name__}')
")
    if [ "$OK" = "OK" ]; then
        printf "  [%2d] ✅\n" "$i"
    else
        FAILS=$((FAILS + 1))
        printf "  [%2d] ❌ %s | raw: %s\n" "$i" "$OK" "$(printf '%s' "$RAW" | head -c 120)"
    fi
    sleep 1
done
echo "  fail rate: $FAILS/10"

echo ""
echo "======================================================"
echo "PROBE 4: context window (input size limit)"
echo "======================================================"
# Progressively larger inputs
for SIZE in 5000 20000 50000 100000 200000; do
    FILLER=$(python3 -c "print('. ' * ($SIZE // 2))")
    Q="Read the following text and reply with only 'OK N' where N is the number of periods you see:
$FILLER"
    START=$(python3 -c "import time; print(time.time())")
    R=$(post "$Q")
    DUR=$(python3 -c "import time; print(round(time.time() - $START, 1))")
    STATUS=$(printf '%s' "$R" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    t = d.get('text','')
    print(f'ok: text_len={len(t)}, preview=\"{t[:60]}\"')
except Exception as e:
    print(f'FAIL: {e}')
")
    echo "  input=${SIZE} chars → ${DUR}s → $STATUS"
    sleep 2
done
