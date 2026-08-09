# Phase 5 - BrowserTabsCapture port report

Date: 2026-07-23
Source: `Everywhere/src/Everywhere.Mac/Mcp/MacBrowserTabsReader.cs` @30e03e9dcfdd4247fd679828ed86e9042f32d809
Roadmap row: `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 10 (P1)

## Files touched

- ADDED `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/BrowserTabsCapture.swift` (280 lines)
- APPENDED to `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`:
  - `public struct BrowserTab: Codable, Equatable, Sendable { title, url, isActive }`
  - `public struct BrowserTabsInfo: Codable, Equatable, Sendable { app, tabs }`
- ADDED `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/BrowserTabsCaptureTests.swift`
- ADDED `docs/ROADMAP/.impl-notes/phase5-browsertabs-2026-07-22.md` (investigation notes)

No other files modified. Every other Capture/ file untouched per constraint list.

## Public API

```swift
public static func BrowserTabsCapture.capture(app: String? = nil) async -> BrowserTabsInfo?
```

- `app == nil`: infer from `NSWorkspace.frontmostApplication` (tries `localizedName`, then bundle id last-component, then full bundle id). Returns nil when frontmost is not a supported browser.
- Explicit `app`: any case-insensitive alias from Everywhere's allow-list (`safari`, `arc`, `chrome`, `google chrome`, `brave`, `brave browser`, `edge`, `microsoft edge`, `chromium`, `vivaldi`, `opera`).
- Returns `BrowserTabsInfo` on runner `.ok`; nil on `.permissionDenied` / `.notSupported` / `.failed` (Layer 0 collapse pattern shared with FinderSelection / BrowserURL).
- Non-mac browser bundle -> nil (unknown alias).

## Parity vs Everywhere

Byte-identical AppleScript templates for Safari, Arc, and the Chromium
family template. Verified by three `_matchesEverywhereVerbatim` tests
that pin the exact template strings. Chromium template's
`{canonicalAppName}` slot is filled ONLY from the allow-list values
(never caller-supplied), matching Everywhere's `BuildChromiumScript`.

Allow-list (`chromiumApps` dictionary) is pinned to Everywhere's set
by `test_chromiumApps_matchesEverywhereAllowListExactly`. Arc routing
precedes the chromium branch (Everywhere line 79-83) — covered by
`test_scriptFor_arcAliases_selectArcScript`.

Wire-format parser (`parseTabs`) mirrors `MacBrowserTabsReader.ParseTabs`
byte-for-byte: split on RS (`\u{1E}`), trim `\r`/`\n`/space, split
each remainder on US (`\u{1F}`) with `maxParts = 3` (mirrors C#
`Split('\x1F', 3)` semantics — third part absorbs any additional US
bytes verbatim, covered by
`test_parseTabs_extraUSByteInURLIsPreservedInThirdField`).

Deliberate deviations (matches sibling captures, documented in file
header):
- Status collapse: Everywhere returns `BrowserTabsResult(Status, Tabs,
  ErrorMessage)`. Layer 0 in openclicky returns `BrowserTabsInfo?`
  where any non-Ok status collapses to nil. C#'s deliberate
  `Failed -> PermissionDenied` remap (line 47) is preserved as a
  code comment because both collapse to nil.
- Public struct field `app` uses the canonical AppleScript name
  (`Safari`, `Google Chrome`, `Arc`, ...), matching what was actually
  `tell`d — richer than Everywhere's C# API which returns tabs
  without echoing the app name (that lives in the MCP tool wrapper).

## Test results

```
swift test  ->  272 tests, 4 skipped, 0 failures (11.6 s)
```

BrowserTabs-specific tests (34 total, all passed):
- `BrowserTabsParserTests` (10) — pure parser.
- `BrowserTabsScriptTests` (4) — byte-identical AppleScript templates.
- `BrowserTabsRouterTests` (5) — alias resolution + allow-list parity.
- `BrowserTabsCaptureStubbedTests` (7) — status collapse via
  `AppleScriptRunning` stub.
- `BrowserTabsInfoJSONTests` (1) — JSON round-trip.
- `BrowserTabsCaptureLiveTests` (3) — live osascript against Safari:
  - `test_capture_completesUnderRunnerTimeout` (2.276 s)
  - `test_capture_nonBrowserApp_returnsNil` (Finder -> nil)
  - `test_capture_safariReachable_returnsNonNil` — Safari present with
    tabs, returns non-nil with `app == "Safari"` and every tab has
    a non-empty URL.

## App integration check

```
bash scripts/sign-and-install.sh
    [3/5] kill running + swap /Applications/OpenClicky.app
    [4/5] open ... com.jkneen.openclicky  Authority=OpenClicky Dev Sign
    [5/5] done.
```

Full app archive signed and installed cleanly — SPM package compiles
against the openclicky bundle context without touching any other
capture, matching the "do NOT touch other capture files" constraint.

## Follow-ups (out of scope for this phase)

- MCP tool port `GetBrowserTabsTool.swift` (row belongs to Layer 2)
  will need the finer tri-state status. When done, expose an
  additional API returning `BrowserTabsResult` alongside the current
  Info-based one. The stub-friendly `capture(app:runner:)` overload
  is the seam.
- Callers wanting to know which of the Arc-reported tabs is active
  should pair `BrowserTabsCapture` with `BrowserURLCapture` — Arc
  emits every row with `isActive == false` because its AppleScript
  dictionary lacks `active tab index`.
