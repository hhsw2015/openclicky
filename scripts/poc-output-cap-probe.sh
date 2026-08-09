#!/usr/bin/env bash
# Probe: single-turn output cap vs multi-turn shrinkage.
# 4 tests:
#   1. First turn, long content task (creative writing)
#   2. First turn, "output as much as possible" task
#   3. Multi-turn: 3rd turn of a conversation asking for long output
#   4. Multi-turn with large transcript: 6th turn after 5 tool calls
set -euo pipefail

OUT_DIR="${OPENCLICKY_OUT_DIR:-/tmp/openclicky-poc}"
mkdir -p "$OUT_DIR"

SESSION_JSON="$HOME/Library/Application Support/OpenClicky/heyclicky-session.json"
TOKEN=$(python3 -c "import json; print(json.load(open('$SESSION_JSON'))['openClickyHeyClickySessionAccessToken'])")
BASE="${HEYCLICKY_PROXY_BASE:?set HEYCLICKY_PROXY_BASE, e.g. https://your-worker.workers.dev}"
PROXY_OPT="-x http://127.0.0.1:10808"

post_and_len() {
    local query="$1"
    local body=$(python3 -c "
import json, sys
print(json.dumps({'query': sys.stdin.read(),'mimeType':'image/jpeg','screenshotBase64':'',
                   'client_capabilities':[],'frontmost_app_bundle_id':'com.jkneen.poc',
                   'environment':{'os_version':'15','timezone':'UTC','display_count':1}}))" <<< "$query")
    local resp
    resp=$(curl -sS --max-time 180 $PROXY_OPT \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -X POST --data-binary @<(printf '%s' "$body") "$BASE/chat-tool-call")
    printf '%s' "$resp" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
t = d.get('text','')
print(len(t))
print(t[:200].replace(chr(10), ' | '))
"
}

echo "======================================================"
echo "T1: First turn, creative writing (2000+ words expected)"
echo "======================================================"
Q1='请写一篇 2500 字左右的完整技术文章,主题是"macOS 上如何用 Swift 实现一个 Push-to-Talk 语音助手"。要包含:概念介绍/权限申请/CGEventTap 全局快捷键/AVAudioRecorder 录音/WebSocket 实时传输/UI 集成/性能优化 六个章节,每章 300-400 字。不要缩短,不要用 [NEXT] 标记,一次性写完。'
LEN1=$(post_and_len "$Q1" | head -1)
echo "len=$LEN1 chars"
sleep 3

echo ""
echo "======================================================"
echo "T2: First turn, minimal task"
echo "======================================================"
Q2='用中文写 5000 字关于 Rust 异步编程的教程。'
LEN2=$(post_and_len "$Q2" | head -1)
echo "len=$LEN2 chars"
sleep 3

echo ""
echo "======================================================"
echo "T3: 3rd turn of dialog, asking for long output"
echo "======================================================"
Q3='Prior conversation:

User: 你好
Assistant: 你好!有什么可以帮你的?
User: 什么是异步编程?
Assistant: 异步编程是一种编程范式,允许程序在等待 I/O 时执行其他任务。
User (current): 请详细展开异步编程,写 3000 字的完整文章,涵盖概念/优势/实现/常见坑/最佳实践 五个部分。'
LEN3=$(post_and_len "$Q3" | head -1)
echo "len=$LEN3 chars"
sleep 3

echo ""
echo "======================================================"
echo "T4: 6th turn after 5 fake tool_call rounds"
echo "======================================================"
Q4='Prior conversation:

User: 帮我建 5 个文件
Assistant: {"action":"tool_call","tool":"write_file","args":{"path":"/tmp/a1.txt","content":"x"}}
Tool result: {"success":true}
Assistant: {"action":"tool_call","tool":"write_file","args":{"path":"/tmp/a2.txt","content":"x"}}
Tool result: {"success":true}
Assistant: {"action":"tool_call","tool":"write_file","args":{"path":"/tmp/a3.txt","content":"x"}}
Tool result: {"success":true}
Assistant: {"action":"tool_call","tool":"write_file","args":{"path":"/tmp/a4.txt","content":"x"}}
Tool result: {"success":true}
Assistant: {"action":"tool_call","tool":"write_file","args":{"path":"/tmp/a5.txt","content":"x"}}
Tool result: {"success":true}
User (current): 好的, 现在请写一篇 3000 字的详细报告, 总结你刚才做的所有事情, 包含每个文件的创建时间、内容、意义。'
LEN4=$(post_and_len "$Q4" | head -1)
echo "len=$LEN4 chars"
sleep 3

echo ""
echo "======================================================"
echo "T5: FRESH first-turn with same 3000-word request (no dialog history)"
echo "======================================================"
Q5='请写一篇 3000 字的报告, 主题:如何设计一个高质量的语音助手系统, 包含:需求分析/技术选型/架构设计/关键实现/测试策略/上线运维 六个部分, 每部分 500 字左右。不要缩短。'
LEN5=$(post_and_len "$Q5" | head -1)
echo "len=$LEN5 chars"

echo ""
echo "======================================================"
echo "SUMMARY"
echo "======================================================"
echo "T1 (fresh 2500-word article):     $LEN1 chars"
echo "T2 (fresh 5000-word tutorial):    $LEN2 chars"
echo "T3 (3rd turn 3000-word article):  $LEN3 chars"
echo "T4 (6th turn after 5 tool calls): $LEN4 chars"
echo "T5 (fresh 3000-word report):      $LEN5 chars"
