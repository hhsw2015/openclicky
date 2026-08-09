# Phase 2 Sensor MCP Extension - Investigation Notes

Date: 2026-07-23
Target: extend `/mcp/sensor` in `cursor-buddy/OpenClickyExternalControlBridge.swift` with 12 new Layer 0 capture tools.

## Existing pattern (10 tools, unchanged)

Descriptor layout in `sensorToolDescriptors` (fileprivate static var):
- Array of `[String: Any]` dicts.
- Each dict: `name`, `description`, `inputSchema` where `inputSchema` is
  `{"type":"object", "properties": [...], "required": [...]}`.

Dispatch in `executeSensorTool(name:arguments:)` (private static async):
- Single `switch name` covering all 10 tools.
- Each case builds a JSON dict, wraps via `sensorTextEnvelope(from:)` -> `{"type":"text","text":"<json>"}`.
- Returns `([String: Any], Bool)` tuple = (content envelope, isError).
- Structs that already conform to `Codable` are converted with the helper
  `sensorJSONObject<T: Encodable>(_ value: T?) -> [String: Any]?`.
- `sensorFocusedWindowDict(from:)` is a hand-serialiser because CGRect JSON
  round-trip is not stable; the new tools that carry CGRect will follow the
  same pattern (regions, screenshot dims, element bounds, window bounds).

Allow-list `sensorToolNames: Set<String>` gates which tools can be dispatched
from `/mcp/sensor`. Cross-endpoint role gate `MCPToolRole.sensor` reads this
same allow-list.

`handleSensorRequest(_:on:)` handles `initialize`, `notifications/initialized`,
`tools/list`, and `tools/call`, enforcing `sensorToolNames.contains(name)`
before dispatch. Auth (`x-openclicky-token`) is enforced upstream on the
POST route.

## New Layer 0 captures available from `import OpenClickyContextService`

Confirmed public API surface (see `Packages/OpenClickyContextService/Sources/...`):
- `OCRCapture.ocr(image: NSImage, languages: [String]) async -> OCRResult?`
- `PermissionPreflight.check(_ kind: PermissionKind, automationTargetBundleId: String?) -> PermissionStatus`
- `AXQuirksInstaller.installIfNeeded(pid: Int32) throws`
- `ScreenshotCaptureEverywhere.captureScreen(screenID: Int, format: ScreenshotFormat) async -> ScreenshotResult?`
- `ScreenshotCaptureEverywhere.captureWindow(pid: Int32, format: ScreenshotFormat) async -> ScreenshotResult?`
- `ScreenshotCaptureEverywhere.captureRegion(rect: CGRect, format: ScreenshotFormat) async -> ScreenshotResult?`
- `WindowEnumerationCapture.enumerateAll(options: WindowEnumerationCapture.EnumerateOptions) -> [EnumeratedWindow]`
- `TerminalCapture.capture(linesBack: Int) async -> TerminalOutputInfo?`
- `BrowserTabsCapture.capture(app: String?) async -> BrowserTabsInfo?`
- `CursorCapture.capture() -> CursorPosition?`
- `ElementUnderCursorCapture.capture(at: CGPoint?) -> ElementUnderCursorInfo?`
- `RecentSessionsCapture.recent(limit: Int) -> [AgentSessionRef]`
- `ProjectRegistry.shared.lookup(_ query: String, limit: Int) -> [ProjectMatch]`
- `GitAwarenessCapture.probe(_ url: URL) -> GitAwarenessInfo?`

## Constraints

- Modify ONLY `cursor-buddy/OpenClickyExternalControlBridge.swift`.
- SPM package is READ-ONLY; work with published API as-is.
- Keep existing 10 sensor + `advisor_*` + `codex_*` untouched.
- Serialize CGRects to `{x,y,width,height}` sub-dicts.
- `ScreenshotResult.data` -> base64. `NSImage` decoded via `NSImage(data:)`.
- All async captures dispatched under existing `Task { ... }` block.

## Plan

1. Add 12 new tool names to `sensorToolNames`.
2. Add 12 new descriptors to `sensorToolDescriptors` in the return array.
3. Add 12 new `case` branches to `executeSensorTool`.
4. Add helper serialisers where CGRect is on the wire:
   - `sensorCGRectDict(_:)` (reused for element bounds and window bounds)
   - `sensorEnumeratedWindowDict(_:)`
   - `sensorElementUnderCursorDict(_:)`
   - `sensorCursorPositionDict(_:)`
   - `sensorScreenshotResultDict(_:)`
   - `sensorOCRResultDict(_:)`
5. Extend `scripts/test-mcp-sensor.sh` count-check to 22 and add benign smoke calls.

## Doc check

`docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` mentions many tools conceptually; the
concrete params surface being added here matches the Layer 0 capture module
signatures, no divergences to reconcile at this stage.
