# Phase 2 Sensor MCP Extension - Implementation Report

Date: 2026-07-23
Scope: extended `/mcp/sensor` from 10 to 22 tools by wiring Phase 5 Layer 0
captures (`OCRCapture`, `ScreenshotCaptureEverywhere`, `PermissionPreflight`,
`AXQuirksInstaller`, `WindowEnumerationCapture`, `TerminalCapture`,
`BrowserTabsCapture`, `CursorCapture`, `ElementUnderCursorCapture`,
`RecentSessionsCapture`, `ProjectRegistry`, `GitAwarenessCapture`) already
available through `import OpenClickyContextService`.

## Files touched (exactly two, per constraints)

- `cursor-buddy/OpenClickyExternalControlBridge.swift`
  - Added 12 entries to `sensorToolNames`.
  - Added 12 descriptors to `sensorToolDescriptors`.
  - Added 12 dispatch cases + one `handleSensorScreenshot` helper to
    `executeSensorTool`.
  - Added helpers: `sensorInt`, `sensorCGRectDict`, `sensorEnumeratedWindowDict`,
    `sensorElementUnderCursorDict`, `sensorCursorPositionDict`,
    `sensorScreenshotResultDict`, `sensorOCRResultDict`.
- `scripts/test-mcp-sensor.sh`
  - Updated tool-count assertions from 10 -> 22 (three sites).
  - Added smoke tests for the 12 new tools.

SPM package (`Packages/OpenClickyContextService/`) NOT touched.
Other Phase 2/3/4 sensor files NOT touched.
Existing 10 sensor / `advisor_*` / `codex_*` tools NOT modified.

## 12 new tool descriptors (verbatim)

```
- screenshot                { scope: "screen"|"window"|"region",
                              pid?:int, rect?:{x,y,w,h},
                              format?:"jpeg"|"png", quality?:int }
- get_browser_tabs          { app?:string }
- get_terminal_output       { lines_back?:int (1..10000) }
- ocr_image                 { image_base64:string, languages?:[string] }
- check_permission          { kind:"accessibility"|"screenRecording"|
                                    "inputMonitoring"|"microphone"|"automation",
                              automation_target_bundle_id?:string }
- install_ax_quirks         { pid:int32 }
- list_windows              { only_on_screen?:bool (default true),
                              exclude_desktop?:bool  (default true) }
- cursor_position           { }
- element_under_cursor      { x?:double, y?:double }
- recent_agent_sessions     { limit?:int }
- project_registry_lookup   { query:string, limit?:int }
- git_awareness             { path:string }
```

Full descriptor JSON (including descriptions and input schemas) is embedded
in `OpenClickyExternalControlBridgeServer.sensorToolDescriptors`.

## Alignment audit

- `sensorToolNames.count == 22`  ✓
- Descriptor array length == 22  ✓ (verified via `grep -c "\"name\":"` of
  the descriptor block plus a python regex sanity check)
- Every new tool respects the `sensorToolNames` allowlist gate in
  `handleSensorRequest` and the cross-endpoint `MCPToolRole.sensor.includes`
  check.
- Auth (`x-openclicky-token`) enforced upstream on the POST route (unchanged);
  negative test in the script still returns 401 for token-less requests.

## Build

`bash scripts/sign-and-install.sh` — final tail:

```
[1/5] xcodebuild
    ...
    ** BUILD SUCCEEDED **

  built: .../DerivedData/.../Debug/OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=41568  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Note: initial run failed with a stale `SourcePackages/checkouts` cache
(unrelated to this change) referencing the placeholder
`openclicky-context-hook` target. Purging
`~/Library/Developer/Xcode/DerivedData/cursor-buddy-*` resolved it and the
next build succeeded. One trivial code fix during the first pass: the SPM
type is top-level `EnumerateOptions`, not
`WindowEnumerationCapture.EnumerateOptions` (module-scope, not nested);
corrected in the initial patch.

## Test

`OPENCLICKY_BRIDGE_TOKEN=test-automation-token bash scripts/test-mcp-sensor.sh` — tail:

```
PASS tools/list returned 22 sensor tools
  - get_focused_context
  - list_apps
  - get_selected_text
  - get_clipboard
  - get_finder_selection
  - get_browser_url
  - get_idle_time
  - probe_workdir
  - get_focused_window
  - sensor_health
  - screenshot
  - get_browser_tabs
  - get_terminal_output
  - ocr_image
  - check_permission
  - install_ax_quirks
  - list_windows
  - cursor_position
  - element_under_cursor
  - recent_agent_sessions
  - project_registry_lookup
  - git_awareness
PASS sensor_health returned {status:ok, capture_count:22}
PASS get_idle_time returned seconds field
PASS probe_workdir /tmp reported exists+isDirectory
PASS get_terminal_output returned is_terminal+text
PASS list_windows returned windows array
PASS check_permission accessibility returned known status
PASS cursor_position returned point+displayIndex
PASS project_registry_lookup returned matches array
PASS git_awareness returned repoRoot or info fallback
PASS recent_agent_sessions returned sessions array
PASS element_under_cursor returned pid or element:null
PASS get_browser_tabs returned tabs field
PASS screenshot rejects missing scope arg
PASS ocr_image rejects missing image_base64 arg
PASS install_ax_quirks rejects missing pid arg
PASS advisor endpoint correctly rejects sensor tools

ALL SENSOR MCP TESTS PASSED
```

## Doc reconciliation

`docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` mentions tool names conceptually and
uses drafting placeholders (e.g. `list_recent_agent_sessions`,
`get_browser_tabs { app_hint }`). The task spec is authoritative and names
`recent_agent_sessions` + `get_browser_tabs { app }`; those are what shipped.
The design doc predates the concrete port; no in-file amendments were required
to describe the wire — the Swift descriptors are now the source of truth for
argument names.

## Response envelope shape

Every new tool returns the standard sensor envelope:

```json
{
  "jsonrpc":"2.0",
  "id": <id>,
  "result": {
    "content": [{"type":"text","text":"<compact JSON payload>"}],
    "isError": false
  }
}
```

Payload JSON keys per tool (summarised):

- `screenshot` -> `{ screenshot_base64, format, width, height, byte_length }`
- `get_browser_tabs` -> Codable `BrowserTabsInfo` (`{ app, tabs:[{title,url,isActive}] }`)
- `get_terminal_output` -> Codable `TerminalOutputInfo` (snake_case:
  `{ is_terminal, lines_returned, text }`)
- `ocr_image` -> `{ count, lines:[{ text, bbox:{x,y,w,h}, confidence }] }`
- `check_permission` -> `{ kind, status, automation_target_bundle_id }`
- `install_ax_quirks` -> `{ ok, pid, note|error }`
- `list_windows` -> `{ count, windows:[EnumeratedWindow-flat] }` where
  `bounds` is `{x,y,width,height}`
- `cursor_position` -> `{ point:{x,y}, displayIndex, capturedAtUnix }`
- `element_under_cursor` -> `{ pid, role, subrole, title, value, bounds:{x,y,width,height}, bundleId }`
- `recent_agent_sessions` -> `{ count, sessions:[AgentSessionRef] }`
- `project_registry_lookup` -> `{ query, count, matches:[ProjectMatch] }`
- `git_awareness` -> Codable `GitAwarenessInfo` or `{ path, info:null, note }`

## Follow-ups (not in scope)

- Screenshot descriptor accepts `quality` for wire-compat but currently
  ignored (the SPM encoder uses `ScreenshotEncoder`'s hard-coded defaults).
  If callers need to tune JPEG quality, expose an encoder parameter in a
  future SPM revision.
- `install_ax_quirks` has global side effects on the target app; the tool
  description carries a warning but there is no confirmation step. Callers
  should gate invocation on user consent.
