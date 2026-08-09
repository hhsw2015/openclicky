# Phase 1 — FrontmostApp Port: Completion Report

Date: 2026-07-22
Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Files created

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/ContextService/Types/CaptureTypes.swift`
  - Defines `FrontmostActivationPolicy` (Codable enum wrapper) and
    `FrontmostAppInfo` (Codable, Equatable, Sendable struct).
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/ContextService/Capture/FrontmostAppCapture.swift`
  - `enum AppKeyResolver` — 1:1 port of `AppKey.FromProcessId` and
    `AppKey.MatchesQuery`.
  - `enum FrontmostAppCapture` — `capture() -> FrontmostAppInfo?`
    using `NSWorkspace.shared.frontmostApplication`.
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/ContextService/Tests/FrontmostAppCaptureTests.swift`
  - `AppKeyResolverTests` (7 cases): zero pid, negative pid, non-existent
    pid, current process, matchesQuery empty / equality / substring.
  - `FrontmostAppCaptureTests` (6 cases): non-nil-when-frontmost, Finder
    activation match, positive pid, non-empty appKey, JSON round-trip,
    bogus-activation-doesn't-crash. UI-touching cases skipped via
    `OPENCLICKY_SKIP_UI_TESTS` env flag.
- `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase1-frontmost-2026-07-22.md`
  - Full Step-1 investigation notes (source citations, field mapping,
    edge-case reasoning).

Existing openclicky files: untouched.

## Everywhere source references

All lifted from git sha `30e03e9dcfdd4247fd679828ed86e9042f32d809`:

- `src/Everywhere.Mcp/Snapshot/AppKey.cs` (lines 12-29, 31-40)
- `src/Everywhere.Mac/Interop/VisualElementContext.cs` (lines 82-111 for
  the NSRunningApplication field harvest pattern)
- `src/Everywhere.Mac/Mcp/MacFocusBackend.cs` (lines 44-53 confirming
  `NSRunningApplication` as the macOS bridge — used for activation, not
  for frontmost detection, so cited but not directly ported).
- `src/Everywhere.Mcp/Tools/ListAppsTool.cs` (lines 12-17 for the tool
  contract that consumes AppKey strings).

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 24 was inspected. The row
already documents the richer `FrontmostAppInfo` (bundle_id / pid / name);
the cited source `AppKey.FromProcessId` covers the string-key portion,
and the NSRunningApplication-derived fields are the openclicky superset.
No doc edit committed — the doc row is not inaccurate, just a partial
citation. The full source list is captured in the port's file-header
comments and in the investigation note.

## Intentional Swift-specific deviations

1. `AppKeyResolver.fromProcessId` uses
   `NSRunningApplication.executableURL.lastPathComponent` instead of
   `System.Diagnostics.Process.ProcessName`. On macOS these yield the
   same result for GUI apps (executable filename minus extension). The
   `.lowercased()` step is preserved verbatim.
2. `FrontmostAppInfo` bundles NSRunningApplication fields into a struct.
   Everywhere reads them ad-hoc, never as a struct. This is an
   openclicky superset — necessary because openclicky snapshots need a
   Codable payload for Layer 3 stash / IPC. The `appKey` field preserves
   Everywhere-compatibility.
3. `FrontmostAppCapture.capture()` deliberately does NOT filter apps
   whose `activationPolicy == .prohibited`. Everywhere filters Prohibited
   apps only inside `TryFastListApps` / `TryFastResolveByName`, which are
   RunningApps enumerations — not a frontmost-lookup. Our capture
   reports the policy on the struct instead; downstream consumers filter.
4. `capture()` returns `nil` when `pid <= 0` (see NSRunningApplication
   docs on transient states). Everywhere never has this branch because
   it queries pid directly; we're wrapping a distinct API.

## Verification performed

- `swiftc -parse` on `CaptureTypes.swift` + `FrontmostAppCapture.swift`:
  clean (no output, exit 0).
- `xcrun swiftc -parse -sdk macosx` with XCTest framework path on the
  test file: clean.
- No references to unresolved symbols; all imports (`Foundation`,
  `AppKit`, `XCTest`) are macOS stdlib / SDK.
- No modifications to existing openclicky sources (respects Phase 1 =
  new files only constraint).
- No `xcodebuild` invocation (respects CLAUDE.md rule).

## Alignment audit checklist

- [x] All AppKey semantic branches represented (pid<=0, resolvable,
  fallback).
- [x] `fromProcessId` returns `String`, matching C# return type.
- [x] `matchesQuery` handles whitespace-only query as false (matches
  `IsNullOrWhiteSpace` in C#).
- [x] Case-insensitive comparison for both equality and substring
  (matches `StringComparison.OrdinalIgnoreCase`).
- [x] Everywhere's warnings/comments carried over in port file header.
- [x] No `Prohibited` policy leakage; policy exposed as data.

## Known limitations

- **macOS-only**. Everywhere's `AppKey.cs` is cross-platform in intent
  (its doc-comment mentions Win exe path, Linux WM_CLASS); the Swift
  port covers macOS only. openclicky itself is macOS-only, so this is
  consistent with the product surface.
- **No RunningApps enumeration**. `TryFastListApps` / `TryFastResolveByName`
  are separate captures (see doc row 25 = `RunningAppsCapture.swift`).
  This phase does not port them.
- **No FocusedWindow / AX walk**. `AXUIElement.FreshFocusedWindowOf(pid)`
  is out of scope; that's row 26 (`FocusedWindowCapture.swift`) and will
  ride on OCCU per the doc's translation policy.
- **UI-touching tests require live user session**. XCTest cases that
  activate Finder skip automatically when `OPENCLICKY_SKIP_UI_TESTS` is
  set. AppKeyResolver tests are fully headless-safe.
- **No wiring** into `OpenClickyContextService.shared`. That singleton
  is defined in the Layer 0 API-shape but does not exist yet; a later
  phase will wire captures in.

## Recommended next capture

`Capture/ClipboardCapture.swift` (doc row 13, P0 text tier).

Rationale:
- Fully independent of AX permissions, so it can land without waiting
  on the OCCU integration path.
- Text-only tier is a very small port from `MacClipboardReader.cs` and
  exercises the same "return nil vs. return empty" edge-case discipline
  established here.
- Golden-diff testable trivially: set pasteboard via NSPasteboard, read
  through both Everywhere and openclicky captures, diff.

Alternate candidate: `Capture/FocusedWindowCapture.swift` (doc row 26).
Prefer this if the OCCU dependency lands first, since it needs
`AXUIElement.FreshFocusedWindowOf(pid)` which OCCU wraps. Otherwise
Clipboard is the lower-risk next step.
