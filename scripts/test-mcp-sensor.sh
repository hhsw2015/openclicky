#!/usr/bin/env bash
# test-mcp-sensor.sh - Smoke-test /mcp/sensor endpoint.
#
# Assumes OpenClicky is running (menu-bar app) with the external
# control bridge on 127.0.0.1:32123.
#
# Auth token resolution order:
#   1. OPENCLICKY_BRIDGE_TOKEN env var
#   2. OPENCLICKY_AUTOMATION_TOKEN env var
#   3. Query the app via /health to detect if the app is up
#
# usage: bash scripts/test-mcp-sensor.sh
set -euo pipefail

BASE_URL="${OPENCLICKY_BRIDGE_URL:-http://127.0.0.1:32123}"
TOKEN="${OPENCLICKY_BRIDGE_TOKEN:-${OPENCLICKY_AUTOMATION_TOKEN:-}}"

pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

if [[ -z "${TOKEN}" ]]; then
  fail "Set OPENCLICKY_BRIDGE_TOKEN (or OPENCLICKY_AUTOMATION_TOKEN) so the bridge accepts the request."
fi

# Health check first so we fail fast if the app is not running.
if ! curl -sSf -o /dev/null "${BASE_URL}/health"; then
  fail "OpenClicky bridge not reachable at ${BASE_URL}. Is the app running?"
fi
pass "bridge is reachable"

# --- Auth negative: no token should get 401 on a POST endpoint.
NOAUTH_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
if [[ "${NOAUTH_STATUS}" != "401" ]]; then
  fail "expected 401 without token, got ${NOAUTH_STATUS}"
fi
pass "unauthenticated request returns 401"

# --- initialize handshake
INIT_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')

# Strip SSE framing: extract "data:" line.
INIT_JSON=$(printf '%s' "${INIT_RESP}" | sed -n 's/^data: //p' | head -n1)
if ! printf '%s' "${INIT_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["result"]["serverInfo"]["name"], d' >/dev/null 2>&1; then
  fail "initialize did not return expected shape: ${INIT_RESP}"
fi
pass "initialize handshake ok"

# --- notifications/initialized should return 202 with empty body
NOTIF_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
if [[ "${NOTIF_STATUS}" != "202" ]]; then
  fail "expected 202 for notifications/initialized, got ${NOTIF_STATUS}"
fi
pass "notifications/initialized returns 202"

# --- tools/list returns the core-tier sensor tools plus any tools
# activated by the current session (connector_*, OpenCLI, etc). The
# exact count grows as more tools mount (F31 OpenDia, F32-F36...), so
# we assert on a lower bound instead of a fixed number. Prior fixed
# assertion (28) drifted below runtime once connectors + OpenCLI
# landed.
LIST_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
LIST_JSON=$(printf '%s' "${LIST_RESP}" | sed -n 's/^data: //p' | head -n1)
TOOL_COUNT=$(printf '%s' "${LIST_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["result"]["tools"]))')
if [[ "${TOOL_COUNT}" -lt 28 ]]; then
  fail "expected >=28 visible sensor tools (22 core sensors + 6 meta at minimum), got ${TOOL_COUNT}"
fi
pass "tools/list returned ${TOOL_COUNT} visible sensor tools (>=28 core-tier minimum)"

# Emit the tool names so the caller can eyeball them.
printf '%s' "${LIST_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for t in d["result"]["tools"]:
    print("  -", t["name"])
'

# --- sensor_health smoke test
HEALTH_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sensor_health","arguments":{}}}')
HEALTH_JSON=$(printf '%s' "${HEALTH_RESP}" | sed -n 's/^data: //p' | head -n1)
if ! printf '%s' "${HEALTH_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["status"] == "ok", inner
# capture_count is dynamically derived from sensorToolDescriptorsRaw
# (native + connector + OpenCLI). Was hard-coded to 43 which drifted
# below the real exposed surface once connectors landed. Assert a
# lower bound instead so future tool mounts (F31 OpenDia, F32-F36...)
# do not require touching this test.
count = inner["capture_count"]
assert isinstance(count, int) and count >= 43, f"expected capture_count>=43, got {count}"
' >/dev/null; then
  fail "sensor_health returned unexpected payload: ${HEALTH_JSON}"
fi
CAPTURE_COUNT=$(printf '%s' "${HEALTH_JSON}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.loads(d["result"]["content"][0]["text"])["capture_count"])')
pass "sensor_health returned {status:ok, capture_count:${CAPTURE_COUNT}}"

# --- get_idle_time smoke test
IDLE_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_idle_time","arguments":{}}}')
IDLE_JSON=$(printf '%s' "${IDLE_RESP}" | sed -n 's/^data: //p' | head -n1)
if ! printf '%s' "${IDLE_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "seconds" in inner, inner
' >/dev/null; then
  fail "get_idle_time returned unexpected payload: ${IDLE_JSON}"
fi
pass "get_idle_time returned seconds field"

# --- probe_workdir /tmp smoke test
PROBE_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/sensor" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"probe_workdir","arguments":{"path":"/tmp"}}}')
PROBE_JSON=$(printf '%s' "${PROBE_RESP}" | sed -n 's/^data: //p' | head -n1)
if ! printf '%s' "${PROBE_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["exists"] is True, inner
assert inner["isDirectory"] is True, inner
' >/dev/null; then
  fail "probe_workdir /tmp returned unexpected payload: ${PROBE_JSON}"
fi
pass "probe_workdir /tmp reported exists+isDirectory"

# --- Phase 5 Layer 0 smoke tests --------------------------------------------

# Helper: hit a sensor tool, extract inner JSON payload (SSE-framed).
sensor_call() {
  local id="$1"; local body="$2"
  curl -sS -X POST "${BASE_URL}/mcp/sensor" \
    -H 'Content-Type: application/json' \
    -H "x-openclicky-token: ${TOKEN}" \
    -d "${body}" | sed -n 's/^data: //p' | head -n1
}

# get_terminal_output: is_terminal + text keys must exist.
TERM_JSON=$(sensor_call 20 '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"get_terminal_output","arguments":{"lines_back":5}}}')
if ! printf '%s' "${TERM_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "is_terminal" in inner, inner
assert "text" in inner, inner
' >/dev/null; then
  fail "get_terminal_output shape wrong: ${TERM_JSON}"
fi
pass "get_terminal_output returned is_terminal+text"

# list_windows: {count, windows} envelope.
WIN_JSON=$(sensor_call 21 '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"list_windows","arguments":{}}}')
if ! printf '%s' "${WIN_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner["windows"], list), inner
assert inner["count"] == len(inner["windows"]), inner
' >/dev/null; then
  fail "list_windows shape wrong: ${WIN_JSON}"
fi
pass "list_windows returned windows array"

# check_permission accessibility: status field must exist.
PERM_JSON=$(sensor_call 22 '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"check_permission","arguments":{"kind":"accessibility"}}}')
if ! printf '%s' "${PERM_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["kind"] == "accessibility", inner
assert inner["status"] in ("granted","denied","notDetermined","restricted","unknown"), inner
' >/dev/null; then
  fail "check_permission shape wrong: ${PERM_JSON}"
fi
pass "check_permission accessibility returned known status"

# cursor_position: point.x/y + displayIndex.
CUR_JSON=$(sensor_call 23 '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"cursor_position","arguments":{}}}')
if ! printf '%s' "${CUR_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "point" in inner and "x" in inner["point"] and "y" in inner["point"], inner
assert "displayIndex" in inner, inner
' >/dev/null; then
  fail "cursor_position shape wrong: ${CUR_JSON}"
fi
pass "cursor_position returned point+displayIndex"

# project_registry_lookup: matches array.
PROJ_JSON=$(sensor_call 24 '{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"project_registry_lookup","arguments":{"query":"openclicky"}}}')
if ! printf '%s' "${PROJ_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner.get("matches"), list), inner
assert inner["query"] == "openclicky", inner
' >/dev/null; then
  fail "project_registry_lookup shape wrong: ${PROJ_JSON}"
fi
pass "project_registry_lookup returned matches array"

# git_awareness on the openclicky repo itself (a known git working tree).
GIT_JSON=$(sensor_call 25 '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"git_awareness","arguments":{"path":"/Users/wowdd1/Dev/openclicky"}}}')
if ! printf '%s' "${GIT_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
# Either the probe returned an info block, or path/info NSNull note fallback.
assert "repoRoot" in inner or "info" in inner, inner
' >/dev/null; then
  fail "git_awareness shape wrong: ${GIT_JSON}"
fi
pass "git_awareness returned repoRoot or info fallback"

# recent_agent_sessions: envelope with count+sessions.
SESS_JSON=$(sensor_call 26 '{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"recent_agent_sessions","arguments":{"limit":3}}}')
if ! printf '%s' "${SESS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner["sessions"], list), inner
assert inner["count"] == len(inner["sessions"]), inner
' >/dev/null; then
  fail "recent_agent_sessions shape wrong: ${SESS_JSON}"
fi
pass "recent_agent_sessions returned sessions array"

# element_under_cursor: element field present (may be null on empty).
ELEM_JSON=$(sensor_call 27 '{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"element_under_cursor","arguments":{}}}')
if ! printf '%s' "${ELEM_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
# Either {pid, bounds, ...} or {element:null, note:...}
assert "pid" in inner or "element" in inner, inner
' >/dev/null; then
  fail "element_under_cursor shape wrong: ${ELEM_JSON}"
fi
pass "element_under_cursor returned pid or element:null"

# get_browser_tabs: tabs list must exist (may be empty).
TABS_JSON=$(sensor_call 28 '{"jsonrpc":"2.0","id":28,"method":"tools/call","params":{"name":"get_browser_tabs","arguments":{}}}')
if ! printf '%s' "${TABS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "tabs" in inner, inner
' >/dev/null; then
  fail "get_browser_tabs shape wrong: ${TABS_JSON}"
fi
pass "get_browser_tabs returned tabs field"

# Screenshot + ocr_image + install_ax_quirks require permissions or intrusive
# side effects — skip by default but exercise the arg-validation path.
BAD_SHOT=$(sensor_call 29 '{"jsonrpc":"2.0","id":29,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}')
if ! printf '%s' "${BAD_SHOT}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "error" in inner, inner
' >/dev/null; then
  fail "screenshot missing-arg validation failed: ${BAD_SHOT}"
fi
pass "screenshot rejects missing scope arg"

BAD_OCR=$(sensor_call 30 '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"ocr_image","arguments":{}}}')
if ! printf '%s' "${BAD_OCR}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "error" in inner, inner
' >/dev/null; then
  fail "ocr_image missing-arg validation failed: ${BAD_OCR}"
fi
pass "ocr_image rejects missing image_base64 arg"

BAD_QUIRK=$(sensor_call 31 '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"install_ax_quirks","arguments":{}}}')
if ! printf '%s' "${BAD_QUIRK}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "error" in inner, inner
' >/dev/null; then
  fail "install_ax_quirks missing-arg validation failed: ${BAD_QUIRK}"
fi
pass "install_ax_quirks rejects missing pid arg"

# --- Phase 2 v2 smoke tests --------------------------------------------------

# list_domains — should return the 9 known meta domains.
DOMAINS_JSON=$(sensor_call 40 '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"list_domains","arguments":{}}}')
if ! printf '%s' "${DOMAINS_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner["domains"], list), inner
assert inner["count"] == 9, inner
names = {x["name"] for x in inner["domains"]}
assert "core" in names and "doc_readers" in names and "memory" in names, inner
' >/dev/null; then
  fail "list_domains shape wrong: ${DOMAINS_JSON}"
fi
pass "list_domains returned 9 domains including core+doc_readers+memory"

# search_tools — top hit for "get_focused_context" is that tool.
SEARCH_JSON=$(sensor_call 41 '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"search_tools","arguments":{"query":"get_focused_context","top_k":3}}}')
if ! printf '%s' "${SEARCH_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["matches"], inner
assert inner["matches"][0]["name"] == "get_focused_context", inner
' >/dev/null; then
  fail "search_tools returned unexpected top hit: ${SEARCH_JSON}"
fi
pass "search_tools top hit for get_focused_context is get_focused_context"

# list_more_tools category=doc_readers should return 7 hidden readers.
MORE_JSON=$(sensor_call 42 '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"list_more_tools","arguments":{"category":"doc_readers"}}}')
if ! printf '%s' "${MORE_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["count"] == 7, inner
names = {t["name"] for t in inner["tools"]}
assert names == {"doc_read_pdf","doc_read_docx","doc_read_xlsx","doc_read_pptx","doc_read_epub","doc_read_html","doc_read_txt"}, inner
' >/dev/null; then
  fail "list_more_tools doc_readers wrong: ${MORE_JSON}"
fi
pass "list_more_tools category=doc_readers returned 7 readers"

# call_tool reflectively invokes get_idle_time.
CALL_JSON=$(sensor_call 43 '{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"call_tool","arguments":{"name":"get_idle_time"}}}')
if ! printf '%s' "${CALL_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert "seconds" in inner, inner
' >/dev/null; then
  fail "call_tool get_idle_time wrong: ${CALL_JSON}"
fi
pass "call_tool get_idle_time returned seconds"

# batch — two-step sequence.
BATCH_JSON=$(sensor_call 44 '{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"batch","arguments":{"steps":[{"tool":"cursor_position","arguments":{}},{"tool":"get_idle_time","arguments":{}}]}}}')
if ! printf '%s' "${BATCH_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["count"] == 2, inner
assert all(r["ok"] for r in inner["results"]), inner
' >/dev/null; then
  fail "batch two-step failed: ${BATCH_JSON}"
fi
pass "batch dispatched cursor_position + get_idle_time"

# doc_read_txt — write a temp file the sandboxed app can read.
TXT_TMP=$(mktemp -t openclicky-sensor-txt.XXXXXX)
printf 'hello openclicky sensor v2\n' >"${TXT_TMP}"
chmod 644 "${TXT_TMP}"
TXT_JSON=$(sensor_call 45 "{\"jsonrpc\":\"2.0\",\"id\":45,\"method\":\"tools/call\",\"params\":{\"name\":\"doc_read_txt\",\"arguments\":{\"path\":\"${TXT_TMP}\"}}}")
rm -f "${TXT_TMP}"
if ! printf '%s' "${TXT_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner["text"], str), inner
assert "warnings" in inner, inner
' >/dev/null; then
  fail "doc_read_txt failed: ${TXT_JSON}"
fi
pass "doc_read_txt returned text envelope for temp file"

# memory_read — always succeeds even when store is empty.
MEM_JSON=$(sensor_call 46 '{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"memory_read","arguments":{}}}')
if ! printf '%s' "${MEM_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert isinstance(inner["entries"], dict), inner
' >/dev/null; then
  fail "memory_read failed: ${MEM_JSON}"
fi
pass "memory_read returned entries dict"

# memory_append_note then memory_snapshot should observe the note.
NOTE_TEXT="phase2-sensor-extend-v2 smoke $(date +%s)"
_=$(sensor_call 47 "{\"jsonrpc\":\"2.0\",\"id\":47,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_append_note\",\"arguments\":{\"text\":\"${NOTE_TEXT}\"}}}")
SNAP_JSON=$(sensor_call 48 '{"jsonrpc":"2.0","id":48,"method":"tools/call","params":{"name":"memory_snapshot","arguments":{}}}')
if ! printf '%s' "${SNAP_JSON}" | python3 -c "
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d['result']['content'][0]['text'])
assert any('${NOTE_TEXT}' in note for note in inner['notes']), inner
" >/dev/null; then
  fail "memory_snapshot did not observe appended note: ${SNAP_JSON}"
fi
pass "memory_append_note round-tripped through memory_snapshot"

# activate_domain memory should unlock memory_* tools in tools/list.
ACT_JSON=$(sensor_call 49 '{"jsonrpc":"2.0","id":49,"method":"tools/call","params":{"name":"activate_domain","arguments":{"name":"memory"}}}')
if ! printf '%s' "${ACT_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
inner = json.loads(d["result"]["content"][0]["text"])
assert inner["ok"] is True, inner
assert "memory_read" in inner["activated"], inner
' >/dev/null; then
  fail "activate_domain memory failed: ${ACT_JSON}"
fi
pass "activate_domain memory returned ok+activated names"

# After activation, memory_read should appear in tools/list.
POST_LIST_JSON=$(sensor_call 50 '{"jsonrpc":"2.0","id":50,"method":"tools/list"}')
if ! printf '%s' "${POST_LIST_JSON}" | python3 -c '
import json,sys
d = json.load(sys.stdin)
names = {t["name"] for t in d["result"]["tools"]}
assert "memory_read" in names, sorted(names)
' >/dev/null; then
  fail "tools/list did not include memory_read after activate_domain: ${POST_LIST_JSON}"
fi
pass "tools/list includes memory_read after activate_domain"

# --- Cross-endpoint isolation: sensor tool should be rejected from
# /mcp/openclicky (the unified openclicky-native endpoint that replaced
# the retired /mcp and /mcp/advisor routes).
XREJ_RESP=$(curl -sS -X POST "${BASE_URL}/mcp/openclicky" \
  -H 'Content-Type: application/json' \
  -H "x-openclicky-token: ${TOKEN}" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_idle_time","arguments":{}}}')
XREJ_JSON=$(printf '%s' "${XREJ_RESP}" | sed -n 's/^data: //p' | head -n1)
if ! printf '%s' "${XREJ_JSON}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "error" in d, d
' >/dev/null; then
  fail "openclicky endpoint accepted a sensor tool: ${XREJ_JSON}"
fi
pass "openclicky endpoint correctly rejects sensor tools"

printf '\nALL SENSOR MCP TESTS PASSED\n'
