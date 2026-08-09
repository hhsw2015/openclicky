# Phase 5 - BrowserTabsCapture porting notes

Target: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/BrowserTabsCapture.swift`
Source: `Everywhere/src/Everywhere.Mac/Mcp/MacBrowserTabsReader.cs` @30e03e9dcfdd4247fd679828ed86e9042f32d809 (147 lines)
Result contract: `Everywhere/src/Everywhere.Mcp/Snapshot/IBrowserTabsReader.cs` (BrowserTab / BrowserTabsStatus / BrowserTabsResult).
Consumer: `Everywhere/src/Everywhere.Mcp/Tools/GetBrowserTabsTool.cs` — surfaces `{app, status, error, tabs}` JSON.

## 1. Supported browsers (allow-list, case-insensitive)

Two script families:

- **Safari** (single key: `safari`).
- **Arc** (single key: `arc`; special script, no active-tab support).
- **Chromium-derivatives** (share the same scripting dictionary; canonical AppleScript app name in RHS):

```
chrome            -> Google Chrome
google chrome     -> Google Chrome
arc               -> Arc                (handled via BuildArcScript, NOT chromium branch)
brave             -> Brave Browser
brave browser     -> Brave Browser
edge              -> Microsoft Edge
microsoft edge    -> Microsoft Edge
chromium          -> Chromium
vivaldi           -> Vivaldi
opera             -> Opera
```

Note: `arc` also lives in the ChromiumApps dictionary in the C# code, but the
`ScriptFor` router intercepts `lower == "arc"` **before** the chromium branch —
so Arc actually uses `BuildArcScript` in practice. Preserve this ordering.

App key is `IsNullOrWhiteSpace` -> `NotSupported`.
App key not in map -> `NotSupported`.

## 2. AppleScript templates (verbatim, byte-identical)

### Safari
```
tell application "Safari"
    set out to ""
    set US to (ASCII character 31)
    set RS to (ASCII character 30)
    repeat with w in windows
        set ct to current tab of w
        repeat with t in tabs of w
            set isActive to (t is ct)
            set flag to "0"
            if isActive then set flag to "1"
            set out to out & flag & US & (name of t) & US & (URL of t) & RS
        end repeat
    end repeat
    return out
end tell
```

### Chromium (Chrome/Brave/Edge/Vivaldi/Opera/Chromium)
Template with `{canonicalAppName}` substitution (validated by allow-list, no interpolation of user data):

```
tell application "{canonicalAppName}"
    set out to ""
    set US to (ASCII character 31)
    set RS to (ASCII character 30)
    repeat with w in windows
        set ai to active tab index of w
        set i to 0
        repeat with t in tabs of w
            set i to i + 1
            set isActive to (i is equal to ai)
            set flag to "0"
            if isActive then set flag to "1"
            set out to out & flag & US & (title of t) & US & (URL of t) & RS
        end repeat
    end repeat
    return out
end tell
```

### Arc
Arc has no `active tab index` — all rows emitted with flag `"0"`:

```
tell application "Arc"
    set out to ""
    set US to (ASCII character 31)
    set RS to (ASCII character 30)
    repeat with w in windows
        repeat with t in tabs of w
            set out to out & "0" & US & (title of t) & US & (URL of t) & RS
        end repeat
    end repeat
    return out
end tell
```

## 3. Wire format

Each record `flag<US>title<US>url<RS>` where US=\x1F, RS=\x1E.
Parser: split on RS, trim `\r \n `, drop empty; split each on US with `maxSplit=3`; require 3 parts; `IsActive := parts[0] == "1"`.
Titles cannot contain \x1E or \x1F (allocated as separators).

## 4. Return shape

C# `BrowserTabsResult(Status, Tabs, ErrorMessage?)` with statuses:

- `Ok` on runner success (tabs may be empty).
- `PermissionDenied` on runner `PermissionDenied` (TCC) OR on `Failed` (script threw). Note the deliberate collapse of `Failed -> PermissionDenied` at line 47.
- `NotSupported` when app_key is empty/unmapped OR runner reports `NotSupported`.

Consumer maps to JSON: `Ok -> "ok"`, `PermissionDenied -> "permission_denied"`, `_ -> "not_supported"`, tabs projected to `{title, url, active}`.

## 5. Timeout / concurrency

Everywhere's C# `MacAppleScriptRunner` uses 15 s. Our `AppleScriptRunner.timeoutMilliseconds = 15_000` already matches. Comment on Arc: ~15-20 ms/tab, 266 tabs ~= 4.5 s — well under budget.

## 6. openclicky adaptation

- Public API: `BrowserTabsCapture.capture(app: String? = nil) async -> BrowserTabsInfo?`
  - `app == nil` -> resolve from NSWorkspace frontmost application (bundle id or localized name); if unresolvable/unmapped -> nil.
  - Non-mac browser bundle -> nil (matches Everywhere `NotSupported`).
  - Runner permission_denied/failed -> nil (Layer 0 collapse pattern, matches sibling captures Finder/BrowserURL).
  - Runner ok -> return `BrowserTabsInfo(app: canonicalKey, tabs: [...])`.
- Append `BrowserTab`, `BrowserTabsInfo` to `Types/CaptureTypes.swift`. Both `Codable, Sendable, Equatable`.
- Reuse `AppleScriptRunner.shared`; provide `internal static func capture(app:runner:)` overload for stub tests.
- Preserve script template byte-identical (verified by `test_appleScriptSource_matches...Verbatim`).

## 7. Test plan

Parser tests (pure, no osascript):
- Empty raw -> empty tabs.
- Single tab, active flag 1.
- Multi-tab preserves order.
- Records with < 3 parts skipped.
- Trailing \r\n around records trimmed.

Script templates:
- Byte-identical assertions for Safari + Arc + Chromium template rendered against each canonical name.

Stubbed capture:
- `permissionDenied` -> nil.
- `failed` -> nil.
- `notSupported` -> nil.
- unknown app key -> nil (never invoked runner).

Live tests (skipped under `OPENCLICKY_SKIP_UI_TESTS`):
- Probe `tell application "Safari" to name`; if unreachable skip.
- capture(app: "safari") returns non-nil when Safari reachable.
- capture bound under 16 s.
- Non-browser bundle (e.g. "finder") -> nil.
