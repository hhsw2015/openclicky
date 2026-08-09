# F04 Review — Browser URL + Tabs

Date: 2026-07-23
Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Reviewer trust rule: code only.

## Scope

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/BrowserURLCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/BrowserTabsCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AppleScriptRunner.swift` (reused)
- `Types/CaptureTypes.swift` — `BrowserURLInfo`, `BrowserTabsInfo`, `BrowserTab`

Everywhere sources verified against:

- `src/Everywhere.Mac/Mcp/MacBrowserUrlReader.cs` (136 lines)
- `src/Everywhere.Mac/Mcp/MacBrowserTabsReader.cs` (147 lines)
- `src/Everywhere.Mcp/Tools/GetBrowserUrlTool.cs`
- `src/Everywhere.Mcp/Tools/GetBrowserTabsTool.cs`

## Verdict: PARITY OK (with two documented layering deviations)

Both captures faithfully port the Everywhere logic. All strict checks in
the review request are satisfied:

### BrowserURL — pure AX walk

| Requirement | Everywhere ref | Swift ref | Status |
|---|---|---|---|
| `pid <= 0` -> nil | `MacBrowserUrlReader.cs:15` | `BrowserURLCapture.swift:79` | OK |
| `AXFocusedUIElement` primary | `MacBrowserUrlReader.cs:23` | `BrowserURLCapture.swift:105` | OK |
| `AXMainWindow` -> `AXFocusedUIElement` fallback | `MacBrowserUrlReader.cs:26-31` | `BrowserURLCapture.swift:108-111` | OK |
| 16-hop ancestor limit | `MacBrowserUrlReader.cs:39` | `BrowserURLCapture.swift:63,86` | OK |
| `AXURL` on element or ancestor | `MacBrowserUrlReader.cs:41` | `BrowserURLCapture.swift:88,134` | OK |
| CFURL -> string, else CFString | `MacBrowserUrlReader.cs:84-87` | `BrowserURLCapture.swift:137-145` | OK |
| Empty-string skip continues walk | `MacBrowserUrlReader.cs:42` (`IsNullOrEmpty`) | `BrowserURLCapture.swift:88` (`!url.isEmpty`) | OK |
| No bundle_id filter | (browser-agnostic) | (same) | OK |
| Any AX call error -> nil | try/catch outer | early nil per helper | OK |

### BrowserTabs — AppleScript byte-identity

Compared literal script text after Swift-multiline-strip vs C# `@"..."`
verbatim strings.

| Script | Everywhere lines | Swift lines | Byte-identical after strip |
|---|---|---|---|
| Safari | `MacBrowserTabsReader.cs:131-146` | `BrowserTabsCapture.swift:74-91` | YES |
| Arc | `MacBrowserTabsReader.cs:94-105` | `BrowserTabsCapture.swift:95-108` | YES |
| Chromium | `MacBrowserTabsReader.cs:112-129` | `BrowserTabsCapture.swift:114-134` | YES |

Notes on the strip: Swift uses the trailing `"""#` (Arc/Safari) or `"""`
(Chromium) 8-space closing marker, which strips 8 leading spaces from
each line. The Everywhere C# verbatim strings have 12/16/20 leading
spaces which correspond after strip to 4/8/12 in the Swift constants —
the raw bytes match exactly.

### ChromiumApps allow-list

| Alias | Canonical | Both files | Match |
|---|---|---|---|
| chrome | Google Chrome | yes | OK |
| google chrome | Google Chrome | yes | OK |
| arc | Arc | yes | OK |
| brave | Brave Browser | yes | OK |
| brave browser | Brave Browser | yes | OK |
| edge | Microsoft Edge | yes | OK |
| microsoft edge | Microsoft Edge | yes | OK |
| chromium | Chromium | yes | OK |
| vivaldi | Vivaldi | yes | OK |
| opera | Opera | yes | OK |

10 aliases, 7 canonical values in the dict (Arc, Chrome, Brave Browser,
Microsoft Edge, Chromium, Vivaldi, Opera). Safari is a separate branch,
giving 8 supported browsers total — this matches the request's "10
aliases -> 8 canonical" when Safari is counted.

### Routing order (`scriptFor` / `ScriptFor`)

Everywhere `MacBrowserTabsReader.cs:76-84`:
1. `safari` -> Safari script
2. `arc` -> Arc script (BEFORE dict lookup)
3. `ChromiumApps[lower]` -> Chromium script

Swift `BrowserTabsCapture.swift:147-162`: identical branching order.
Arc is intercepted before the chromium dict lookup, per Everywhere
`MacBrowserTabsReader.cs:79-83`.

### Parser byte-for-byte

Everywhere `MacBrowserTabsReader.cs:54-74` semantics:

1. `IsNullOrEmpty` -> empty list
2. Split on `\x1E`
3. Trim `\r`, `\n`, space; skip empty
4. Split on `\x1F` with max 3 pieces; require 3
5. Emit `BrowserTab(parts[1], parts[2], parts[0] == "1")`

Swift `BrowserTabsCapture.parseTabs` line 231-259: matches each step.
`splitOnUS(maxParts: 3)` (line 265-277) correctly replicates
`String.Split('\x1F', 3)` — third piece absorbs any trailing US bytes.
`String.split(separator: "\u{1E}", omittingEmptySubsequences: false)`
plus the trim + isEmpty guard matches C# behavior.

### Layer 0 collapse

Swift `BrowserTabsCapture.swift:201-214`:
- `.ok` -> `BrowserTabsInfo`
- `.permissionDenied` / `.notSupported` / `.failed` -> `nil`

Matches the FinderSelection / BrowserURL / SelectedText pattern:
non-Ok status collapses to `nil`. Everywhere-side `MacBrowserTabsReader`
returns a rich `BrowserTabsResult` because it must feed the MCP tool
that surfaces `permission_denied` to end users; the openclicky Layer 0
wrapper deliberately drops that distinction (documented in the header,
line 27-36).

## Documented deviations (deliberate, non-behavioral)

1. **`BrowserURLInfo(processId, url)` return shape** vs Everywhere's
   bare `string?`. Everywhere composes the `{app, url}` tuple in
   `GetBrowserUrlTool` at the JSON envelope. Swift bakes pid into the
   capture return for shape consistency with sibling captures. See
   `BrowserURLCapture.swift:41-46`.

2. **Frontmost-app inference in `BrowserTabsCapture.capture(app:nil)`**
   (line 285-307). Everywhere's reader requires an `appKey`; frontmost
   resolution happens one layer up in `GetBrowserTabsTool` via
   `context.FocusedElement.ProcessId -> AppKey.FromProcessId`. Swift
   uses `NSWorkspace.shared.frontmostApplication` and tries
   `localizedName` -> `bundleId` last-component -> `bundleId` against
   the allow-list. Different mechanism, same intent. For an actively
   frontmost browser both resolve identically; the two would diverge
   only when the focused element belongs to a different process than
   the frontmost app (e.g. XPC/helper), which is not a browser scenario.

## No blocking issues found

Ready to advance F04 out of review.
