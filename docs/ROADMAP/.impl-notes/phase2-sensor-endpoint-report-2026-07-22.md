# Phase 2 Layer 2 - MCP Sensor Endpoint - Implementation Report

## Files modified

- `cursor-buddy/OpenClickyExternalControlBridge.swift`
  - Added `import OpenClickyContextService`
  - Added `.sensor` case to `fileprivate enum MCPToolRole` with allow-list lookup against `sensorToolNames`
  - Added new `case "/mcp/sensor":` route in `handle(_:on:)` that short-circuits notifications (202) and delegates the rest to `handleSensorRequest(_:on:)`
  - Added static `sensorToolNames: Set<String>` allow-list
  - Added static `sensorToolDescriptors: [[String: Any]]` (10 tools)
  - Added `handleSensorRequest(_:on:)` - MCP JSON-RPC dispatcher (initialize, notifications/initialized, tools/list, tools/call) using the same SSE Streamable HTTP transport as `/mcp/advisor` and `/mcp/orchestrate`
  - Added `executeSensorTool(name:arguments:)` async static that dispatches to the ten Phase 1 captures
  - Added helper functions `sensorTextEnvelope(from:)`, `sensorJSONObject(_:)`, `sensorFocusedWindowDict(from:)`, `sensorInt32(_:)`

## Files created

- `scripts/test-mcp-sensor.sh` - self-contained smoke test (auth check, initialize, notifications/initialized, tools/list count, sensor_health, get_idle_time, probe_workdir, and cross-endpoint isolation)
- `docs/ROADMAP/.impl-notes/phase2-sensor-endpoint-2026-07-22.md` - investigation notes

## Design decisions

1. Sensor tools bypass `OpenClickyExternalControlCommand`. They are pure Foundation/AppKit reads; the existing command enum is for UI/agent orchestration commands that route through the `@MainActor` handler. Instead, `handleSensorRequest` executes them directly in a `Task` and marshals the result back on `queue.async`.

2. Cross-endpoint isolation is enforced by the `MCPToolRole.sensor.includes(toolName:)` check plus the fact that sensor tool names are not in `mcpToolCommand`'s switch. Attempting `get_idle_time` against `/mcp/advisor` returns a JSON-RPC error (verified by the test script).

3. When `process_id` is omitted for `get_browser_url` or `get_focused_window`, we fall back to `FrontmostAppCapture.capture()?.processId`. This matches Everywhere's implicit "current frontmost app" semantics.

4. `get_focused_context` runs frontmost + selected + clipboard + finder + browser + focused_window in one call and returns a merged object with `NSNull` placeholders for captures that fail. This mirrors Everywhere's `GetFocusedContextTool.cs`.

5. `FocusedWindowInfo.frame` is hand-serialised into `{x, y, width, height}` rather than relying on `CGRect`'s default `Codable` (which encodes as a nested `[[x, y], [w, h]]` array). Everything else uses `JSONEncoder` -> `JSONSerialization` round-trip.

## The ten tool descriptors

```json
[
  {
    "name": "get_focused_context",
    "description": "Bundle the currently-focused macOS context: frontmost app, focused window, selected text, browser URL (if applicable), and Finder selection. One-shot read for agents that want everything about 'what the user is looking at' without chaining multiple calls.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "list_apps",
    "description": "Return the frontmost macOS application (bundle id, localized name, pid, executable path, activation policy). Phase 1 exposes the frontmost app only; the full running-app roster is a Phase 3 TODO.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "get_selected_text",
    "description": "Return the user's current text selection anywhere on macOS. Uses a three-strategy fallback: AXSelectedText on focused element, AXSelectedText on child elements, and synthesized Cmd+C into the pasteboard. Returns text plus source (ax/child/clipboardCmdC/cache), source app key, and grapheme-cluster length.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "get_clipboard",
    "description": "Return the current macOS general pasteboard text (public.utf8-plain-text). Text-only in P0; file paths / images / RTF are P1 additions.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "get_finder_selection",
    "description": "Return the current Finder selection: the folder shown in the frontmost Finder window plus every selected item (path, filename, isDirectory, kindHint). Uses AppleScript against Finder.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "get_browser_url",
    "description": "Return the AXURL published by an AX-accessible app (typically a browser tab). If process_id is omitted, defaults to the frontmost app's pid. Returns null if the pid has no AXURL in its focus chain (up to 16 ancestor hops).",
    "inputSchema": {
      "type": "object",
      "properties": {"process_id": {"type": "integer", "description": "Optional pid to query. Defaults to the frontmost app's pid."}},
      "required": []
    }
  },
  {
    "name": "get_idle_time",
    "description": "Return seconds since the user last touched any input device, via CGEventSourceSecondsSinceLastEventType.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  },
  {
    "name": "probe_workdir",
    "description": "Probe an on-disk folder path for OpenClicky's project-type classifier: exists, isDirectory, isEmpty, fileCount, detectedProjectType, hasGit, hasOpenClickyState, hasAgentsMd. OpenClicky-unique (no Everywhere equivalent) - used to decide how to hand a folder to an agent.",
    "inputSchema": {
      "type": "object",
      "properties": {"path": {"type": "string", "description": "Absolute POSIX path to probe."}},
      "required": ["path"]
    }
  },
  {
    "name": "get_focused_window",
    "description": "Return the AX-focused window of a pid: title, frame (Quartz top-left global coords), displayIndex, isMinimized, isMainWindow. If process_id is omitted, defaults to the frontmost app's pid.",
    "inputSchema": {
      "type": "object",
      "properties": {"process_id": {"type": "integer", "description": "Optional pid to query. Defaults to the frontmost app's pid."}},
      "required": []
    }
  },
  {
    "name": "sensor_health",
    "description": "Meta tool for smoke testing. Returns {status, capture_count, version} without touching AppKit or AX APIs.",
    "inputSchema": {"type": "object", "properties": {}, "required": []}
  }
]
```

## Build result

`bash scripts/sign-and-install.sh` output tail:

```
[0/5] verify cert exists in login keychain
[1/5] xcodebuild

** BUILD SUCCEEDED **

  built: /Users/wowdd1/Library/Developer/Xcode/DerivedData/cursor-buddy-.../Build/Products/Debug/OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=42888  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

## curl smoke-test result

`OPENCLICKY_BRIDGE_TOKEN=test-automation-token bash scripts/test-mcp-sensor.sh`:

```
PASS bridge is reachable
PASS unauthenticated request returns 401
PASS initialize handshake ok
PASS notifications/initialized returns 202
PASS tools/list returned 10 sensor tools
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
PASS sensor_health returned {status:ok, capture_count:10}
PASS get_idle_time returned seconds field
PASS probe_workdir /tmp reported exists+isDirectory
PASS advisor endpoint correctly rejects sensor tools

ALL SENSOR MCP TESTS PASSED
```

Additional real-world probe against the repo root:

```
curl -X POST http://127.0.0.1:32123/mcp/sensor \
  -H 'Content-Type: application/json' \
  -H 'x-openclicky-token: test-automation-token' \
  -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"probe_workdir","arguments":{"path":"/Users/wowdd1/Dev/openclicky"}}}'

=> {"content":[{"text":"{\"detectedProjectType\":\"xcode\",\"exists\":true,\"fileCount\":32,\"hasAgentsMd\":true,\"hasGit\":true,\"hasOpenClickyState\":false,\"isDirectory\":true,\"isEmpty\":false,\"path\":\"/Users/wowdd1/Dev/openclicky\"}","type":"text"}],"isError":false}
```

## Doc reconciliation

Reviewed `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md`. The doc already scopes Phase 2 Layer 2 to the Phase 1 captures and defers OCCU-backed AX / action tools to Phase 3 (see L206-208 in that doc). No divergence between plan and implementation; no doc edit needed.

## Alignment audit vs `/mcp/advisor`

| Aspect | `/mcp/advisor` | `/mcp/sensor` | Match |
|---|---|---|---|
| Auth gate | `hasValidBridgeToken(request)` | same | yes (shared gate before switch) |
| Notification short-circuit | 202 + text/event-stream + Mcp-Session-Id | same | yes |
| Transport | `sendMCPStreamableHTTP` (SSE frame + chunked) | same | yes |
| Role gate | `MCPToolRole.advisor` (prefix `advisor_`) | `MCPToolRole.sensor` (allow-list of 10 names) | intentional diff - allow-list is stricter |
| Response envelope | `{content:[{type:"text",text:...}], isError}` | same | yes |
| Command routing | `mcpToolCommand` -> `OpenClickyExternalControlCommand` -> main-actor handler | direct `executeSensorTool` (no command enum, no main-actor hop) | intentional diff - sensor reads are pure and side-effect-free |
| Broadcast on completion | `broadcast(event: "command", ...)` on `queue.async` | same | yes |
