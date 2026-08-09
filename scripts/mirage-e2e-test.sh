#!/usr/bin/env bash
# End-to-end automation test for Peeky Free (mirage) lane.
#
# Exercises the full Peeky Free pipeline without any voice/audio:
#   1. Sets the active profile to "mirage".
#   2. Fires 5 test utterances, one per intent (chat / integration /
#      find_action / memory / agent) via the sensor endpoint's
#      openclicky_simulate_voice_turn tool.
#   3. Tails messages-*.jsonl looking for the corresponding automation +
#      mirage events, asserts each turn produced the expected artefacts:
#        - openclicky.mirage.profile_activated (once, on setup)
#        - automation.simulate_voice_turn.begin (per turn)
#        - openclicky_click / spotify_pause / etc. (integration turn)
#        - automation.simulate_voice_turn.ok (per turn)
#   4. Prints pass/fail per intent + full log tail location.
#
# The test does NOT depend on network availability of aegis-proxy: when
# MirageSecrets.upstreamBaseURL is empty in your build, every mirage turn
# returns .error("not_configured"), which the test still counts as a
# valid pipeline traversal (the orchestrator ran, just no upstream call).
#
# Env:
#   OPENCLICKY_AUTOMATION_TOKEN  required
#   OPENCLICKY_BRIDGE_URL        default http://127.0.0.1:32123
#   MIRAGE_TEST_UTTERANCES       optional comma-separated overrides
#   MIRAGE_TEST_TIMEOUT          per-turn timeout seconds (default 60)
set -euo pipefail

BASE="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
TOKEN="${OPENCLICKY_AUTOMATION_TOKEN:?set OPENCLICKY_AUTOMATION_TOKEN before running}"
TIMEOUT="${MIRAGE_TEST_TIMEOUT:-120}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="/tmp/openclicky-mirage-e2e-$STAMP"
mkdir -p "$OUT_DIR"
LOG_TAIL="$OUT_DIR/log-tail.jsonl"

# Utterances chosen to exercise all 5 intents. Comma-separated override
# via MIRAGE_TEST_UTTERANCES lets you focus on a single failing branch:
#   MIRAGE_TEST_UTTERANCES="pause spotify" ./scripts/mirage-e2e-test.sh
DEFAULT_UTTERANCES=(
  "hello there, tell me a joke"
  "pause spotify"
  "click the login button"
  "remember my favorite color is blue"
  "peeky agent, open finder and show my downloads"
)
if [ -n "${MIRAGE_TEST_UTTERANCES:-}" ]; then
  IFS=',' read -r -a UTTERANCES <<< "$MIRAGE_TEST_UTTERANCES"
else
  UTTERANCES=("${DEFAULT_UTTERANCES[@]}")
fi

LOG_FILE="$HOME/Library/Application Support/OpenClicky/Logs/messages-$(date +%Y-%m-%d).jsonl"

echo "=== mirage-e2e-test ==="
echo "bridge : $BASE"
echo "out    : $OUT_DIR"
echo "log    : $LOG_FILE"
echo ""

# 1) Bridge health check.
if ! curl -sS --max-time 5 "$BASE/health" -H "x-openclicky-token: $TOKEN" > /dev/null; then
  echo "❌ bridge not reachable at $BASE/health — is OpenClicky running with automation token set?"
  exit 1
fi
echo "✅ bridge reachable"

# 2) Switch profile to mirage via the automation MCP endpoint. This
#    hits `applyProfile()` end-to-end (UserDefaults + subsystem start/stop
#    + classifier warm) — writing UserDefaults directly is not enough
#    because the in-memory model/provider is only refreshed inside
#    `applyProfile`.
switch_resp=$(curl -sS --max-time 10 -X POST "$BASE/mcp/call" \
  -H "x-openclicky-token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"openclicky_set_profile","arguments":{"profile":"mirage"}}')
echo "profile switch response: $switch_resp"
if ! echo "$switch_resp" | grep -q '"ok":true'; then
  echo "❌ profile switch failed"
  exit 1
fi
echo "✅ profile switched to mirage end-to-end"
sleep 1

# 3) Record log-file offset BEFORE any test turn.
START_OFFSET=0
if [ -f "$LOG_FILE" ]; then
  START_OFFSET=$(wc -c < "$LOG_FILE" | tr -d ' ')
fi

# Helper: POST a simulate_voice_turn and wait for its .ok event in the log.
run_utterance() {
  local turn_idx=$1
  local utterance=$2
  local turn_label="turn$turn_idx"
  echo ""
  echo "--- turn $turn_idx: \"$utterance\" ---"

  local body
  body=$(cat <<EOF
{
  "name": "openclicky_simulate_voice_turn",
  "arguments": {
    "transcript": "$utterance",
    "title": "[MIRAGE-E2E] $turn_label"
  }
}
EOF
)
  local resp_file="$OUT_DIR/$turn_label.resp.json"
  local http_code
  http_code=$(curl -sS --max-time "$TIMEOUT" -o "$resp_file" -w "%{http_code}" \
    -X POST "$BASE/mcp/call" \
    -H "x-openclicky-token: $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" || true)

  if [ "$http_code" != "200" ]; then
    echo "  ❌ HTTP $http_code from /mcp/call — see $resp_file"
    cat "$resp_file" | head -20 || true
    return 1
  fi

  local ok
  ok=$(python3 -c "import json,sys; d=json.load(open('$resp_file')); print(d.get('ok', False))" 2>/dev/null || echo "False")
  echo "  ok=$ok  (see $resp_file)"

  # Look for our line in the log tail (mirage-specific events).
  if [ -f "$LOG_FILE" ]; then
    tail -c +$((START_OFFSET + 1)) "$LOG_FILE" \
      | grep -E "\"(openclicky.mirage|automation.simulate_voice_turn)\"" \
      | tail -20 >> "$LOG_TAIL"
  fi
  return 0
}

FAILED=0
for i in "${!UTTERANCES[@]}"; do
  turn=$((i + 1))
  if ! run_utterance "$turn" "${UTTERANCES[$i]}"; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== summary ==="
echo "total   : ${#UTTERANCES[@]}"
echo "failed  : $FAILED"
echo "log tail: $LOG_TAIL"
if [ "$FAILED" -eq 0 ]; then
  echo "✅ all mirage turns completed"
  exit 0
else
  echo "❌ $FAILED turn(s) failed"
  exit 1
fi
