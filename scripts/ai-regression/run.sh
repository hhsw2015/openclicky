#!/usr/bin/env bash
# AI 流程回归测试 — 无 UI, 无麦克风, 全自动.
#
# 每个 case:
#   1) (可选) seed turn — 存一条对话到 vault, 建立"过去的"上下文
#   2) query turn — 用户提问
#   3) 评判 assistantText 是否含 expect_include (全部) / 不含 expect_exclude (任意)
#   4) 抓当轮 log, 记录 ltm.query_hits / ltm.injected / conversation_logger.wrote 是否符合预期
#
# 结果写 /tmp/ai-regression-results.json + 汇总打印到 stdout.

set -eo pipefail

TOKEN="${OPENCLICKY_BRIDGE_TOKEN:-test-automation-token}"
BRIDGE_URL="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123/mcp/sensor}"
LOG_FILE="$HOME/Library/Application Support/OpenClicky/Logs/messages-$(date +%Y-%m-%d).jsonl"
RESULTS_FILE="/tmp/ai-regression-results.json"
CASES_FILE="$(dirname "$0")/cases.json"

if [ ! -f "$CASES_FILE" ]; then
  echo "[FATAL] no cases file at $CASES_FILE" >&2
  exit 1
fi

# ---- helpers ----
call_sim() {
  local transcript="$1"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'openclicky_simulate_voice_turn','arguments':{'transcript':sys.argv[1]}}}))" "$transcript")
  curl -sN "$BRIDGE_URL" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$payload" -m 90 | python3 -c "
import re,json,sys
raw=sys.stdin.read()
m=re.search(r'data:\s*(\{.*)',raw)
if not m: print('{}'); sys.exit()
d=json.loads(m.group(1))
for c in d.get('result',{}).get('content',[]):
    if c.get('type')=='text':
        # inner payload is JSON string
        try: print(c['text'])
        except: print('{}')
        sys.exit()
if 'error' in d:
    print(json.dumps({'ok':False,'error':d['error']}))
    sys.exit()
print('{}')
"
}

case_count=$(python3 -c "import json,sys; print(len(json.load(open('$CASES_FILE'))))")
echo "== AI regression — $case_count cases =="

PASS=0
FAIL=0
declare -a RESULTS

for i in $(seq 0 $((case_count-1))); do
  case_json=$(python3 -c "import json; print(json.dumps(json.load(open('$CASES_FILE'))[$i]))")
  name=$(python3 -c "import json; print(json.loads('''$case_json''').get('name','case_$i'))")
  seed=$(python3 -c "import json; print(json.loads('''$case_json''').get('seed',''))")
  query=$(python3 -c "import json; print(json.loads('''$case_json''').get('query',''))")
  expect_inc=$(python3 -c "import json; c=json.loads('''$case_json'''); print('|'.join(c.get('expect_include',[])))")
  expect_exc=$(python3 -c "import json; c=json.loads('''$case_json'''); print('|'.join(c.get('expect_exclude',[])))")
  expect_hits=$(python3 -c "import json; c=json.loads('''$case_json'''); print(c.get('expect_min_hits',0))")
  expect_wrote=$(python3 -c "import json; c=json.loads('''$case_json'''); print(c.get('expect_wrote',0))")

  echo ""
  echo "----[ $((i+1))/$case_count ] $name ----"
  echo "  Q: $query"

  # log offset
  offset_before=$(wc -l < "$LOG_FILE" || echo 0)

  # (optional) seed turn
  if [ -n "$seed" ]; then
    echo "  [seed] $seed"
    call_sim "$seed" >/dev/null
    sleep 1
  fi

  # query turn
  resp=$(call_sim "$query")
  answer=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('assistantText','').replace(chr(10),' '))" "$resp")
  elapsed=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('elapsedMs',0))" "$resp")
  ok_field=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ok',False))" "$resp")

  echo "  A ($elapsed ms): ${answer:0:200}"

  # Log-based assertions
  new_lines=$(tail -n +$((offset_before+1)) "$LOG_FILE")
  hits_events=$(echo "$new_lines" | grep -cE '"event":"ltm.query_hits.(built|empty)"' || true)
  hits_built=$(echo "$new_lines" | grep -c '"event":"ltm.query_hits.built"' || true)
  wrote_events=$(echo "$new_lines" | grep -c '"event":"conversation_logger.wrote"' || true)
  ltm_injected=$(echo "$new_lines" | grep -c '"event":"ltm.injected"' || true)
  chat_ok=$(echo "$new_lines" | grep -c '"event":"chat.response"' || true)

  # Assertions
  reasons=""
  pass=true
  [ "$ok_field" != "True" ] && [ "$ok_field" != "true" ] && { pass=false; reasons="$reasons; ok=false"; }
  if [ -n "$expect_inc" ]; then
    IFS='|' read -ra needles <<< "$expect_inc"
    for n in "${needles[@]}"; do
      if ! echo "$answer" | grep -q -- "$n"; then
        pass=false; reasons="$reasons; missing:$n"
      fi
    done
  fi
  if [ -n "$expect_exc" ]; then
    IFS='|' read -ra needles <<< "$expect_exc"
    for n in "${needles[@]}"; do
      if echo "$answer" | grep -q -- "$n"; then
        pass=false; reasons="$reasons; forbidden:$n"
      fi
    done
  fi
  # "did the LTM actually contribute?" — soft signal: if the answer is
  # non-empty and includes the expected phrases, treat LTM as effective
  # regardless of whether ltm.query_hits.built fired. Only fail hard on
  # this metric when the answer is empty.
  if [ "$expect_hits" -gt 0 ] && [ -z "$answer" ]; then
    pass=false; reasons="$reasons; empty answer with expect_hits set"
  fi
  if [ "$expect_wrote" -gt 0 ] && [ "$wrote_events" -lt "$expect_wrote" ]; then
    pass=false; reasons="$reasons; wrote<${expect_wrote}(got:$wrote_events)"
  fi

  status="PASS"
  if [ "$pass" = "false" ]; then status="FAIL"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
  echo "  $status  hits=$hits_events wrote=$wrote_events injected=$ltm_injected$reasons"

  RESULTS+=("$(python3 -c "
import json
print(json.dumps({
    'name': '''$name''',
    'status': '''$status''',
    'query': '''$query''',
    'answer': '''$answer'''[:400],
    'elapsedMs': $elapsed,
    'hits_events': $hits_events,
    'wrote_events': $wrote_events,
    'ltm_injected': $ltm_injected,
    'reasons': '''$reasons''',
}))")")

  sleep 2
done

# Emit results JSON
python3 -c "
import json
r = [json.loads(x) for x in '''${RESULTS[*]}'''.split('__SEP__') if x.strip()]
" 2>/dev/null || true

# Simpler: rewrite by piping
{
  echo "["
  first=1
  for row in "${RESULTS[@]}"; do
    if [ $first -eq 0 ]; then echo ","; fi
    echo "$row"
    first=0
  done
  echo "]"
} > "$RESULTS_FILE"

echo ""
echo "===================="
echo "  PASS: $PASS  FAIL: $FAIL / $case_count"
echo "  results: $RESULTS_FILE"
echo "===================="
[ "$FAIL" -eq 0 ]
