#!/usr/bin/env bash
# Long-run + drift + auto-recovery test for OpenClicky HeyClicky Free lane.
# Fully headless. Cleans up every session it creates on exit.
#
# Env:
#   OPENCLICKY_AUTOMATION_TOKEN   required, matches app env
#   OPENCLICKY_BRIDGE_URL         default http://127.0.0.1:32123
#   AUTOTEST_TITLE_TAG            marker prefix used to sweep sessions (default: [AUTOTEST])
#   AUTOTEST_DURATION_SECONDS     how long to keep the task alive (default: 900 = 15 min)
#   AUTOTEST_INJECT_FAULTS        1 to inject kill/creds/428 mid-run (default: 1)
set -euo pipefail
BASE="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
TOKEN="${OPENCLICKY_AUTOMATION_TOKEN:?set OPENCLICKY_AUTOMATION_TOKEN before running}"
TAG="${AUTOTEST_TITLE_TAG:-[AUTOTEST]}"
DURATION="${AUTOTEST_DURATION_SECONDS:-900}"
INJECT="${AUTOTEST_INJECT_FAULTS:-1}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="/tmp/openclicky-autotest-$STAMP"
mkdir -p "$OUT_DIR"
LOG_TAIL="$OUT_DIR/log-tail.jsonl"
STATE_DIR="$OUT_DIR/states"; mkdir -p "$STATE_DIR"
SID=""

cleanup() {
  echo ""; echo "=== cleanup ==="
  if [ -n "$SID" ]; then
    curl -sS --max-time 5 -X POST "$BASE/agent/task/stop" \
      -H "x-openclicky-token: $TOKEN" -H "Content-Type: application/json" \
      -d "{\"sessionID\":\"$SID\"}" > /dev/null 2>&1 || true
  fi
  # Sweep every session whose title carries our marker.
  curl -sS --max-time 8 -X POST "$BASE/agent/sessions/purge" \
    -H "x-openclicky-token: $TOKEN" -H "Content-Type: application/json" \
    -d "{\"titleContains\":\"$TAG\"}" 2>&1 | python3 -m json.tool 2>&1 | head -8 || true
  echo "artifacts: $OUT_DIR"
}
trap cleanup EXIT INT TERM

api() {
  curl -sS --max-time 15 -H "x-openclicky-token: $TOKEN" "$@"
}
post() {
  api -X POST "$BASE$1" -H "Content-Type: application/json" -d "$2"
}
state() {
  post /agent/session/state "{\"sessionID\":\"$SID\"}"
}
field() {
  local key="$1"
  state | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('sessions',[{}])[0]; print(s.get('$key',''))"
}
snapshot() {
  local tag="$1"
  state > "$STATE_DIR/$(date +%H%M%S)-$tag.json"
}

echo "=== bridge health ==="
api "$BASE/health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok=", d["ok"], "port=", d["port"])'

echo "=== pre-purge stale AUTOTEST sessions ==="
post /agent/sessions/purge "{\"titleContains\":\"$TAG\"}" | python3 -m json.tool | head -5

echo "=== start long-running agent ==="
TITLE="$TAG longrun 七里香 $STAMP"
PROMPT=$(python3 -c "print('请在 /tmp/openclicky-autotest-$STAMP 目录下做一件长时间的事：1) mkdir 工作目录 2) 建 index.html 骨架 3) 写 Canvas 逐帧动画 JavaScript 4) 加 CSS 呼吸背景 5) 生成占位音频 (用 sox 或 python 都行) 6) 每一步都用 sleep 3-5 秒来模拟耗时 7) 报告完成。始终围绕原始任务，绝不切换。请开始，别中途停止。')")
BODY=$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"prompt":sys.argv[2]}))' "$TITLE" "$PROMPT")
RESP=$(post /agent/task/start "$BODY")
echo "$RESP"
SID=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionID"])')
echo "sessionID: $SID"
echo "expectedTitle: $TITLE"

start=$(date +%s)

echo "=== live monitor loop (${DURATION}s) ==="
ITER=0
NEXT_FAULT=$((start + 90))
FAULT_IDX=0
FAULTS=("kill_codex" "expire_credentials" "trigger_428")
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  if [ "$elapsed" -ge "$DURATION" ]; then break; fi
  ITER=$((ITER + 1))
  status=$(field status || echo "?")
  stage=$(field progressStage || echo "?")
  entries=$(field entryCount || echo "?")
  title=$(field title || echo "?")
  short_title="$(echo "$title" | cut -c1-40)"
  printf "[%3ds] status=%-30.30s stage=%-12.12s entries=%s\n" "$elapsed" "$status" "$stage" "$entries"

  # Detect title drift
  if [ "$title" != "$TITLE" ]; then
    echo "  !! TITLE DRIFT: got '$short_title...'"
    snapshot "drift-detected"
  fi

  # Fault injection every ~2 min if enabled
  if [ "$INJECT" = "1" ] && [ "$now" -ge "$NEXT_FAULT" ] && [ "$FAULT_IDX" -lt "${#FAULTS[@]}" ]; then
    kind="${FAULTS[$FAULT_IDX]}"
    echo "  >> INJECT $kind"
    post /agent/fault/inject "{\"kind\":\"$kind\",\"sessionID\":\"$SID\"}" | python3 -m json.tool | head -4
    snapshot "before-$kind"
    FAULT_IDX=$((FAULT_IDX + 1))
    NEXT_FAULT=$((now + 120))
  fi

  # Pull incremental log tail
  api "$BASE/agent/log/tail" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for line in d.get('lines', [])[-8:]:
    try:
        e=json.loads(line)
        ev=e.get('event','?')
        lane=e.get('lane','?')
        if ev in ('codex.rpc.message','codex.heartbeat_ok'):
            continue
        ts=e.get('timestamp','')
        print(f'  log> {ts[-10:-1]} [{lane}] {ev}')
    except: pass
" 2>/dev/null | tail -5

  sleep 10
done

echo ""
echo "=== final verify ==="
snapshot "final"
FINAL_TITLE=$(field title)
FINAL_STATUS=$(field status)
FINAL_STAGE=$(field progressStage)
FINAL_LAST=$(field lastEntry)
echo "title:  $FINAL_TITLE"
echo "status: $FINAL_STATUS"
echo "stage:  $FINAL_STAGE"
echo "last:   ${FINAL_LAST:0:200}"

# Assertions
FAIL=0
if [ "$FINAL_TITLE" != "$TITLE" ]; then
  echo "FAIL: title drift ($FINAL_TITLE)"; FAIL=1
else
  echo "PASS: title stable"
fi

# On-topic check
python3 - "$FINAL_LAST" <<'PY'
import sys
text = sys.argv[1].lower()
keywords = ["七里香","canvas","index.html","html","css","可视化","目录","工作目录","openclicky-autotest"]
hits = [k for k in keywords if k.lower() in text]
print(f"on-topic hits: {hits}")
if not hits:
    print("WARN: no on-topic keywords in last entry (may still be OK if last entry is a command)")
PY

echo ""
echo "artifacts at $OUT_DIR"
echo "exit=$FAIL"
exit $FAIL
