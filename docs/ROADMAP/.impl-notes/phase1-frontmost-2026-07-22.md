# Phase 1 — FrontmostApp Port Investigation

Date: 2026-07-22
Everywhere git sha: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Step 1 — Facts extracted from Everywhere source

### `src/Everywhere.Mcp/Snapshot/AppKey.cs` (all 41 lines)

- Namespace: `Everywhere.Mcp.Snapshot`
- Type: `public static class AppKey` (STATIC class, not a data struct)
- API surface:
  - `static string FromProcessId(int processId)` — lines 12-29
  - `static bool MatchesQuery(string appKey, string query)` — lines 31-40
- `FromProcessId` return contract (line 12-29):
  - `processId <= 0` -> returns literal string `"unknown"` (line 16)
  - Uses `System.Diagnostics.Process.GetProcessById(processId)` (line 21) then reads `ProcessName`
  - Empty/null name -> falls back to `processId.ToString()` (line 23)
  - Non-empty name -> `name.ToLowerInvariant()` (line 23)
  - Any exception -> `processId.ToString()` (line 27)
- File-level doc comment (lines 5-9):
  > "Resolves a stable per-process key used to scope SessionStore snapshots.
  > Matches upstream behavior: bundle id (mac), exe path (win), WM_CLASS (linux); falls back
  > to lowercase process name when the OS-specific signal is unavailable."
- CRITICAL: the C# implementation is **NOT platform-aware**. The doc comment claims
  "bundle id (mac)" but the code path uses `Process.ProcessName` on all platforms.
  On macOS via .NET's System.Diagnostics, `ProcessName` yields the executable name
  (e.g. "Finder", "Safari"), NOT the bundle id.

### `src/Everywhere.Mac/Interop/VisualElementContext.cs`

- Frontmost detection: **not centralised**. There is no single `Frontmost()` method.
- App enumeration uses `NSWorkspace.SharedWorkspace.RunningApplications`
  (lines 82-95 in `TryFastResolveByName`, 97-111 in `TryFastListApps`)
- Filters (lines 85, 103):
  - `app.ActivationPolicy == NSApplicationActivationPolicy.Prohibited` -> skip
  - `pid <= 0` -> skip (line 105)
- Per-app fields read: `LocalizedName` (line 86), `BundleIdentifier` (line 87),
  `ProcessIdentifier` (line 91, 104).
- Focused window per pid uses `AXUIElement.FreshFocusedWindowOf(pid)` (line 91, 106).

### `src/Everywhere.Mac/Mcp/MacFocusBackend.cs`

- Does NOT determine the frontmost app. It only *activates* apps by pid via
  `-[NSRunningApplication runningApplicationWithProcessIdentifier:]` + `activateWithOptions:`
  (lines 44-53).
- Confirms macOS approach: `NSRunningApplication` is the canonical bridge.

### `src/Everywhere.Mcp/Tools/ListAppsTool.cs`

- Consumes AppKey indirectly. Tool returns raw text from `IAxBridgeBackend.ListApps()`.
- Doc-string (lines 13-17) confirms tool contract: each entry has
  `"app"` (process key = AppKey output), `"title"`, `"process_id"`.
- So `AppKey` in Everywhere = a **string identifier**, not a struct.

## Key finding: doc <-> code divergence

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 24 says
`FrontmostApp (bundle_id/pid/name)` ported from `AppKey.FromProcessId`.

But `AppKey.FromProcessId` returns a single `string` (lowercase process name).
The `bundle_id/pid/name` tuple is an openclicky-specific **enrichment** —
Everywhere itself does not model FrontmostApp as a struct anywhere.

Resolution: the doc's spec is a superset. The Swift port should:
1. Preserve `AppKey.FromProcessId` semantics as a helper (produces the stable key).
2. Wrap it plus richer NSRunningApplication fields into `FrontmostAppInfo`.

No doc rewrite needed — the current row already documents the richer struct as
the target; only the source citation is a hint, not a literal one-to-one.
Adding a clarifying reference to `NSRunningApplication` is worthwhile though.

## Step 2 — Doc reconciliation decision

Doc line 24 references `AppKey.FromProcessId` as the primary source. The full
truth is: FrontmostApp on macOS = `NSWorkspace.shared.frontmostApplication`
(NSRunningApplication) enriched by `AppKey.FromProcessId`-style stable key.
`MacFocusBackend.cs` is not the source of frontmost detection — that lives
implicitly in NSWorkspace usage across the codebase.

Minimal doc tweak needed: append the actual macOS source. Doing this inline
in the file header comment of the port keeps the doc row untouched (row 24 is
already accurate in shape). No commit-level doc edit required.

## Fields for `FrontmostAppInfo`

Following Everywhere's `NSRunningApplication` usage in
`VisualElementContext.cs:82-111`:

| Swift field | Type | Source | Nullability rationale |
|---|---|---|---|
| `processId` | `Int32` | `NSRunningApplication.processIdentifier` | Always present when app is running; `pid_t` == Int32 |
| `bundleId` | `String?` | `NSRunningApplication.bundleIdentifier` | Nil for pure command-line procs / anonymous helpers |
| `localizedName` | `String?` | `NSRunningApplication.localizedName` | Rare nil (helper procs) |
| `executablePath` | `String?` | `NSRunningApplication.executableURL?.path` | Rare nil |
| `appKey` | `String` | Everywhere's `AppKey.FromProcessId` port | Never nil — fallback chain guarantees value |
| `activationPolicy` | enum | `NSRunningApplication.activationPolicy` | Preserved for downstream filtering (Prohibited apps) |

## `AppKey.FromProcessId` Swift semantics

Direct 1:1 port:

```
if pid <= 0 { return "unknown" }
let p = NSRunningApplication(processIdentifier: pid)
guard let name = p?.executableURL?.lastPathComponent, !name.isEmpty else {
    return "\(pid)"
}
return name.lowercased()
```

Rationale: `.NET`'s `Process.GetProcessById(pid).ProcessName` on macOS returns
the executable filename minus extension. Swift closest analog:
`NSRunningApplication(processIdentifier:)` + `executableURL.lastPathComponent`.
Then lowercase per the C# path. Catch-all -> pid string.

## Edge cases to preserve

- `pid <= 0`: return `"unknown"` (matches C# line 16)
- Missing NSRunningApplication (very rare — race with process exit):
  return `"\(pid)"` (matches C# lines 22-24 fallback)
- No frontmost application (NSWorkspace returns nil during transition):
  `capture()` returns `nil`. Everywhere never asserts frontmost exists.
- LSUIElement / Prohibited activation policy: this is our own app
  (`com.jkneen.openclicky`, `LSUIElement=true`). If openclicky itself is
  "frontmost" briefly, we should still report it (do NOT filter Prohibited
  at this layer — filtering happens in `RunningAppsCapture`).

## Files to create

1. `cursor-buddy/ContextService/Types/CaptureTypes.swift`
2. `cursor-buddy/ContextService/Capture/FrontmostAppCapture.swift`
3. `cursor-buddy/ContextService/Tests/FrontmostAppCaptureTests.swift`

## Non-goals (Phase 1)

- Not touching any existing openclicky file.
- Not wiring `OpenClickyContextService` singleton yet (Layer 0 API surface
  lives in a later phase). Just static-function capture.
- No Windows / Linux ports; macOS only.
- No AX / focused-window logic — that's a separate capture.
