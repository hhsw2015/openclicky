#!/usr/bin/env bash
# Probe: WHY does multi-turn shrink output? Test several hypotheses:
#   H1: Length of "prior conversation" text triggers a cap
#   H2: Presence of "tool_call" JSON in history triggers a cap
#   H3: Explicit "session_id" parameter accumulates state server-side
#   H4: Prompt style ("keep it brief") is implicit in tool-flavored history
set -euo pipefail

OUT_DIR="${OPENCLICKY_OUT_DIR:-/tmp/openclicky-poc}"
mkdir -p "$OUT_DIR"

TOKEN=$(python3 -c "
import json
d = json.load(open('$HOME/Library/Application Support/OpenClicky/heyclicky-session.json'))
print(d['openClickyHeyClickySessionAccessToken'])
")
BASE="${HEYCLICKY_PROXY_BASE:?set HEYCLICKY_PROXY_BASE, e.g. https://your-worker.workers.dev}"
PROXY_OPT="-x http://127.0.0.1:10808"

post_and_len() {
    local query="$1"
    local sessid="${2:-}"
    local body_json=$(python3 -c "
import json, sys, os
q = sys.stdin.read()
b = {'query': q, 'mimeType':'image/jpeg','screenshotBase64':'',
     'client_capabilities':[],'frontmost_app_bundle_id':'com.jkneen.poc',
     'environment':{'os_version':'15','timezone':'UTC','display_count':1}}
sid = os.environ.get('SESSID', '')
if sid:
    b['session_id'] = sid
print(json.dumps(b))" <<< "$query")

    SESSID="$sessid" bash -c "
    curl -sS --max-time 180 $PROXY_OPT \
        -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
        -X POST --data-binary @<(printf '%s' '$body_json') '$BASE/chat-tool-call' 2>&1
    " | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    t = d.get('text','')
    print(len(t))
except Exception as e:
    print(f'ERR:{e}')
"
}

TASK='请写一篇 3000 字左右的报告, 主题:如何设计一个高质量的语音助手系统, 包含:需求分析/技术选型/架构设计/关键实现/测试策略/上线运维 六个部分, 每部分 500 字左右。不要缩短。'

echo "======================================================"
echo "BASELINE: no history"
echo "======================================================"
L=$(post_and_len "$TASK" | head -1)
echo "  → $L chars"
sleep 3

echo ""
echo "======================================================"
echo "H1: history = 3000 chars of natural chat (no JSON)"
echo "======================================================"
HIST_CHAT=$(python3 -c "
lines = []
for i in range(20):
    lines.append(f'User: 我今天想聊一下天气,你觉得东京春天的樱花什么时候最漂亮?')
    lines.append(f'Assistant: 樱花通常在 3 月底到 4 月初盛开,不同品种时间略有差异。')
print(chr(10).join(lines))
")
Q_H1="Prior conversation:
$HIST_CHAT

User (current): $TASK"
echo "  history size: $(printf '%s' "$HIST_CHAT" | wc -c) chars"
L=$(post_and_len "$Q_H1" | head -1)
echo "  → $L chars"
sleep 3

echo ""
echo "======================================================"
echo "H2: history = 3000 chars of TOOL_CALL JSON"
echo "======================================================"
HIST_TOOLS=$(python3 -c "
lines = []
for i in range(10):
    lines.append('User: 帮我建文件 /tmp/f' + str(i) + '.txt')
    lines.append('Assistant: {\"action\":\"tool_call\",\"tool\":\"write_file\",\"args\":{\"path\":\"/tmp/f' + str(i) + '.txt\",\"content\":\"data\"}}')
    lines.append('Tool result: {\"success\":true}')
print(chr(10).join(lines))
")
Q_H2="Prior conversation:
$HIST_TOOLS

User (current): $TASK"
echo "  history size: $(printf '%s' "$HIST_TOOLS" | wc -c) chars"
L=$(post_and_len "$Q_H2" | head -1)
echo "  → $L chars"
sleep 3

echo ""
echo "======================================================"
echo "H3: history = SAME 3000 chars but prompted as \"NEW session, ignore above\""
echo "======================================================"
Q_H3="Prior conversation (already resolved, do NOT reference):
$HIST_TOOLS

--- END prior conversation, treat this as a fresh independent request ---

$TASK"
L=$(post_and_len "$Q_H3" | head -1)
echo "  → $L chars"
sleep 3

echo ""
echo "======================================================"
echo "H4: fresh but with session_id set (server-side state?)"
echo "======================================================"
SID="poc-loop-test-$(date +%s)"
# First seed the session
_=$(post_and_len "Hello, I want to have a conversation." "$SID" | head -1)
sleep 2
_=$(post_and_len "Great, next I need help with a technical article." "$SID" | head -1)
sleep 2
L=$(post_and_len "$TASK" "$SID" | head -1)
echo "  → $L chars (session_id=$SID)"
sleep 3

echo ""
echo "======================================================"
echo "H5: EXPLICIT unlock — tell model 'reasoning is required, output must be long'"
echo "======================================================"
Q_H5="Prior conversation:
$HIST_TOOLS

User (current): $TASK

CRITICAL: This is a fresh writing task, not a continuation. Ignore the tool_call convention above. Do NOT emit JSON. Do NOT truncate. Output the full 3000-word article as plain markdown. Aim for 2500+ characters."
L=$(post_and_len "$Q_H5" | head -1)
echo "  → $L chars"
sleep 3

echo ""
echo "======================================================"
echo "H6: multi-turn where each turn asks for LONG reasoning explicitly"
echo "======================================================"
# 5-turn buildup with LONG assistant replies inline
HIST_LONG=$(python3 -c "
turns = []
for i in range(5):
    turns.append(f'User: Turn {i+1} question: 请长篇分析 topic {i+1}')
    # Simulate 800-char assistant reply
    turns.append('Assistant: ' + ('这是详细分析内容。' * 80))
print(chr(10).join(turns))
")
Q_H6="Prior conversation:
$HIST_LONG

User (current): $TASK"
echo "  history size: $(printf '%s' "$HIST_LONG" | wc -c) chars"
L=$(post_and_len "$Q_H6" | head -1)
echo "  → $L chars"
