# Phase 2 Layer 2 - MCP Sensor Endpoint - Investigation Notes

## Existing bridge pattern (`/mcp/advisor`, `/mcp/orchestrate`)

- File: `cursor-buddy/OpenClickyExternalControlBridge.swift`
- Role enum: `fileprivate enum MCPToolRole { case all, advisor, orchestrate }` at L1608 - gated by tool-name prefix (`advisor_*`, `codex_*`)
- Response builder: `mcpJSONRPCResponse(from:role:)` at L1625 handles `initialize`, `notifications/initialized`, `tools/list`, `tools/call`
- Transport: `sendMCPStreamableHTTP(body:statusCode:on:)` at L777 - wraps JSON-RPC in `event: message\ndata:{...}\n\n` SSE frame with chunked transfer encoding, emits `Mcp-Session-Id` header
- Notifications short-circuit: any request with `method: notifications/*` or no `id` returns bare 202 with no body (L479-484 for advisor, L501-505 for orchestrate)
- Auth: `hasValidBridgeToken(request)` checks `x-openclicky-token` header (or `authorization: Bearer`) against `AppBundleConfiguration.externalControlBridgeToken()` or `OPENCLICKY_AUTOMATION_TOKEN` env var - constant-time compare
- Descriptor storage: `static var mcpToolDescriptors: [[String: Any]]` at L887 - array of `{ name, description, inputSchema }` dicts. `role.includes(toolName:)` filters at `tools/list` time
- Command mapping: `mcpToolCommand(from:)` at L1414 switches on tool name, returns `OpenClickyExternalControlCommand?`
- Response envelope: `MCPJSONRPCBridgeResponse.responseBody(result:)` at L1817 wraps handler output into `{content: [{type: "text", text: "..."}], isError}` when a command executed, or passes `staticResult` through for list/init

## Phase 1 capture public APIs (from `OpenClickyContextService`)

Module import: `import OpenClickyContextService`

- `FrontmostAppCapture.capture() -> FrontmostAppInfo?` (sync)
- `SelectedTextCapture.capture(cache:) -> SelectedTextInfo?` (sync)
- `ClipboardCapture.capture() -> ClipboardInfo?` (sync)
- `FinderSelectionCapture.capture() async -> FinderSelectionInfo?` (async, AppleScript)
- `IdleTimeCapture.capture() -> IdleTimeInfo?` (sync)
- `BrowserURLCapture.capture(processId:) async -> BrowserURLInfo?` (async)
- `FocusedWindowCapture.capture(processId:) -> FocusedWindowInfo?` (sync)
- `WorkdirProbe.probe(_ url: URL) -> WorkdirProbeResult` (sync, always returns value)

All result types are `Codable` - can JSON-encode via `JSONEncoder`.

## Design decisions

1. **New endpoint** `/mcp/sensor` follows advisor/orchestrate shape exactly - same notification short-circuit, same SSE transport, same auth gate.

2. **`.sensor` role case** added to `MCPToolRole`. Sensor tool names use `get_*` / `list_*` / `probe_*` / `sensor_*` prefixes - since these don't clash with `advisor_*` or `codex_*`, we filter by an explicit allow-list of tool names in the sensor case rather than a prefix. This keeps the role gate defensive and forbids cross-endpoint leakage.

3. **Direct execution path** - sensor tools do NOT go through `OpenClickyExternalControlCommand` (that enum is UI/agent-orchestration commands routed through the main-actor handler). Sensor tools are pure reads that don't touch the companion state machine. Instead:
   - Add a new pathway: `mcpJSONRPCResponse` returns a `MCPJSONRPCBridgeResponse` with a `sensorExecutor` closure for sensor tools
   - OR simpler: handle `/mcp/sensor` `tools/call` inline in the route handler with a dedicated dispatch function that returns `[String: Any]` (JSON-serialized capture)
   - Chose the second option - keep sensor path self-contained, no changes to the shared response builder for other endpoints

4. **Tool payload format** - each sensor tool returns MCP content envelope `{content: [{type: "text", text: "<json>"}], isError: false}`. The `text` field carries the JSON-serialized capture struct. This is the standard MCP tool call return shape.

5. **PID handling** - `get_focused_window` and `get_browser_url` need a PID. If caller omits `process_id`, fall back to `FrontmostAppCapture.capture()?.processId` (matches Everywhere's `AppKey.FromProcessId` chain).

6. **`get_focused_context`** aggregate - runs multiple captures, merges into one flat object. This is the "one-shot" tool matching Everywhere's `GetFocusedContextTool.cs`.

7. **`sensor_health`** meta - returns `{status: "ok", capture_count: 10, version: "phase1"}` for smoke testing.

## Doc reconciliation

`docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` describes the sensor endpoint with a large tool set including OCCU-backed AX tools that are Phase 3+. Phase 2 Layer 2 ships only the 10 Phase 1 captures - the doc mentions OCCU integration as a P3 concern (line 206-208), so no divergence. No doc fix needed for this phase.

## Files to modify/create

- MODIFY: `cursor-buddy/OpenClickyExternalControlBridge.swift`
  - Add `.sensor` case to `MCPToolRole`
  - Add `sensorToolNames: Set<String>` static
  - Add `sensorToolDescriptors: [[String: Any]]` static
  - Add `/mcp/sensor` route in `handleRequest`
  - Add `handleSensorToolCall(name:arguments:) async -> [String: Any]` that returns MCP content envelope
  - Merge `sensorToolDescriptors` into `mcpToolDescriptors` so role-based filter works uniformly
- CREATE: `scripts/test-mcp-sensor.sh` - smoke test
- CREATE: `docs/ROADMAP/.impl-notes/phase2-sensor-endpoint-report-2026-07-22.md` - final report
