# Phase 2 sensor extend v2 — report (2026-07-23)

## Files modified

- `cursor-buddy/OpenClickyExternalControlBridge.swift`
  - Extended `sensorToolNames` from 22 → 43 entries (added 7 doc reader,
    8 memory, 6 meta tool names).
  - Added `sensorToolDomains` static map assigning each of the 43 tools
    to one of `core` / `doc_readers` / `memory`.
  - Added static `sensorMetaDispatchDelegate` and `sensorMetaRegistry`
    (`OpenClickyMetaToolRegistry`) bootstrap: registers all 43 descriptors
    with their domain + `isHidden` flag, wires the dispatch delegate
    back to `executeSensorTool` via
    `OpenClickyExternalControlBridgeServer.invokeSensorToolForMeta`.
  - Renamed the previous `sensorToolDescriptors` var to
    `sensorToolDescriptorsRaw` (full 43-entry list) and added a new
    gated `sensorToolDescriptors` that returns only visible tools —
    core-tier always, hidden tiers only after `activate_domain` or when
    `OPENCLICKY_MCP_FULL=1`.
  - Added 21 new descriptors (doc readers × 7, memory × 8, meta × 6).
  - Added 21 new `executeSensorTool` cases plus helpers
    `handleDocRead`, `docReaderErrorMessage`, `memoryErrorMessage`,
    `metaErrorMessage`.
  - Added `SensorMetaDispatchDelegate` class conforming to
    `MetaToolDispatchDelegate`; guards against recursive `call_tool` /
    `batch` invocations.
- `scripts/test-mcp-sensor.sh`
  - Updated visible-tool count assertion from 22 → 28 (22 core sensors
    + 6 always-visible meta tools; the 15 hidden doc/memory tools are
    gated behind `activate_domain`).
  - Updated `sensor_health` `capture_count` expectation to 43.
  - Added smoke tests for `list_domains`, `search_tools`,
    `list_more_tools`, `call_tool`, `batch`, `doc_read_txt`,
    `memory_read`, `memory_append_note` → `memory_snapshot`,
    `activate_domain memory` unlocking `memory_read` in `tools/list`.

## 21 new descriptors + domain assignment

| Tool                          | Domain       | Hidden by default |
| ----------------------------- | ------------ | ----------------- |
| doc_read_pdf                  | doc_readers  | yes               |
| doc_read_docx                 | doc_readers  | yes               |
| doc_read_xlsx                 | doc_readers  | yes               |
| doc_read_pptx                 | doc_readers  | yes               |
| doc_read_epub                 | doc_readers  | yes               |
| doc_read_html                 | doc_readers  | yes               |
| doc_read_txt                  | doc_readers  | yes               |
| memory_read                   | memory       | yes               |
| memory_read_endpoint          | memory       | yes               |
| memory_write_endpoint         | memory       | yes               |
| memory_write_field_map        | memory       | yes               |
| memory_append_note            | memory       | yes               |
| memory_snapshot               | memory       | yes               |
| memory_freshness              | memory       | yes               |
| memory_write_verify_fixture   | memory       | yes               |
| list_more_tools               | core         | no                |
| search_tools                  | core         | no                |
| activate_domain               | core         | no                |
| list_domains                  | core         | no                |
| call_tool                     | core         | no                |
| batch                         | core         | no                |

## Meta registry integration

Approach:

1. Two static properties on `OpenClickyExternalControlBridgeServer`:
   - `sensorMetaDispatchDelegate: SensorMetaDispatchDelegate` — strong
     retention (registry holds delegates weakly).
   - `sensorMetaRegistry: OpenClickyMetaToolRegistry` — lazy static let
     that registers every one of the 43 descriptors with its assigned
     domain + `isHidden` flag on first access.
2. `SensorMetaDispatchDelegate` parses `arguments_json`, calls
   `invokeSensorToolForMeta(name:arguments:)`, and returns the tool's
   raw JSON text envelope. Recursive calls to `call_tool` / `batch`
   are blocked at the entry to prevent runaway loops.
3. `sensorToolDescriptors` filters `sensorToolDescriptorsRaw` through
   `OpenClickyMetaCoreToolGate.filterEnabled` + the registry's
   `activatedDomains()` set, so `tools/list` reflects the current
   activation state.

## Curl smoke output (excerpt)

```
PASS tools/list returned 28 core-tier sensor tools (22 sensor + 6 meta)
PASS sensor_health returned {status:ok, capture_count:43}
PASS list_domains returned 9 domains including core+doc_readers+memory
PASS search_tools top hit for get_focused_context is get_focused_context
PASS list_more_tools category=doc_readers returned 7 readers
PASS call_tool get_idle_time returned seconds
PASS batch dispatched cursor_position + get_idle_time
PASS doc_read_txt returned text envelope for temp file
PASS memory_read returned entries dict
PASS memory_append_note round-tripped through memory_snapshot
PASS activate_domain memory returned ok+activated names
PASS tools/list includes memory_read after activate_domain
PASS advisor endpoint correctly rejects sensor tools
ALL SENSOR MCP TESTS PASSED
```

## Build result

`bash scripts/sign-and-install.sh` → success. `OpenClicky.app` rebuilt,
codesigned with `OpenClicky Dev Sign`, installed under
`/Applications/OpenClicky.app`, and launched (`pid=70870`).

## Alignment audit

- All 43 tools present in `sensorToolNames` allowlist.
- All 43 tools registered with the meta registry.
- All 43 tools reachable via `executeSensorTool` (no unknown-tool
  path).
- Gate: default `tools/list` returns 28 (22 core sensors + 6 meta);
  `activate_domain memory` promotes 8 more; `activate_domain
  doc_readers` promotes 7 more; total exposed = 43 once both hidden
  domains are activated (or `OPENCLICKY_MCP_FULL=1`).
- Cross-endpoint isolation preserved: `/mcp/advisor` still rejects
  sensor tools.
- Existing 22 sensor tool dispatch cases unchanged.
