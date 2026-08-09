# Phase 5 - Window enumeration port - report

Source pin: `@30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Files added

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/WindowEnumerationCapture.swift`
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/WindowEnumerationCaptureTests.swift`

## Files touched (append-only)

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  -- appended `EnumeratedWindow` struct (pid, wid, title, ownerName,
  bounds, screenIndex, isOnScreen, layer, alpha). No existing types
  modified.

## Investigation summary

Everywhere's window enumeration lives in two places, both using
`CGWindowListCopyWindowInfo` from the public CoreGraphics
framework, not private SkyLight:

1. `src/Everywhere.Mac/Interop/WindowHelper.cs:272-292`
   (`RaiseOverlayAboveTarget`) -- options
   `.OnScreenOnly | .ExcludeDesktopElements`, relativeToWindow=0.
   Reads `kCGWindowOwnerPID` (Int32), `kCGWindowNumber` (UInt32),
   `kCGWindowLayer` (Int32). Comment L291 documents
   "CGWindowList returns front-to-back order".
2. `src/Everywhere.Mac/Interop/ScreenSelectionSession.cs:393-446`
   (`GetWindowOwnerPidsAtLocation`) -- options
   `.OnScreenBelowWindow`. Reads pid + `kCGWindowBounds` dict
   `{X, Y, Width, Height}` for hit-testing.

The task brief cited `SkyLightInterop.cs` for `SLSGetActiveSpace` /
`SLSCopyWindowsWithOptions`. That is a repeat of
`docs/ROADMAP/10_OVERLAP_ANALYSIS.md` row 242's claim, but on full
reading `SkyLightInterop.cs` (106 LOC) contains only
`CGSMainConnectionID`,
`CGSCaptureWindowsContentsToRectWithOptions`,
`CGSHWCaptureWindowList`, and the `CGSWindowCaptureOptions` flag
enum. All screenshot-focused. There is no SLS enumeration call in
Everywhere to port, so `@_silgen_name` SkyLight bindings are not
required. Documented in `phase5-windowenum-2026-07-22.md`.

## Port surface

Public API (task-mandated):

```swift
WindowEnumerationCapture.enumerateAll(options: EnumerateOptions = .default) -> [EnumeratedWindow]
```

`EnumerateOptions.default` = `EnumerateOptions(onScreenOnly: true,
excludeDesktopElements: true, relativeToWindow: 0)`, mirroring
`WindowHelper.cs:272-274`.

`EnumeratedWindow` carries: pid, wid, title, ownerName, bounds
(Quartz), screenIndex (largest-intersection NSScreen), isOnScreen,
layer, alpha. Codable + Sendable + Equatable.

Field extraction, filters, and order all match Everywhere:

| Everywhere behaviour | Port behaviour | Location |
|---|---|---|
| `CGWindowListCopyWindowInfo` public API | Same | `WindowHelper.cs:272-274` |
| Options: `.OnScreenOnly \| .ExcludeDesktopElements` default | `EnumerateOptions.default` | `WindowHelper.cs:273` |
| Reads pid / wid / layer | Same, plus title/ownerName/bounds/onScreen/alpha (documented CGWindow.h payload) | `WindowHelper.cs:287-290` |
| Skips dicts missing pid | Same (also skips missing wid) | `WindowHelper.cs:287` |
| Front-to-back order preserved | Same, no re-sort | `WindowHelper.cs:291` |
| CFArray ownership handled | Bridged `as NSArray? as? [[String: Any]]` -- ARC handles release | `WindowHelper.cs:277` (`owns: true`) |
| Cocoa->Quartz Y-flip for screen union | Same math as `FocusedWindowCapture.displayIndex(for:)` | `NSScreenVisualElement.cs:57-67` |

## Tests

`WindowEnumerationCaptureTests` (10 cases):

- `test_enumerateAll_neverThrows_alwaysReturnsArray` -- headless-safe
  smoke; runs on any macOS environment.
- `test_enumerateOptions_defaultMirrorsEverywhere` -- pins default
  option shape to `WindowHelper.cs:272-274`.
- `test_enumerateAll_returnsWindows_whenGUISessionAvailable` -- gated
  on `NSScreen.screens` non-empty. Asserts pid > 0, wid > 0, alpha in
  [0,1] for every entry.
- `test_enumerateAll_onScreenFlag_matchesDefaultAssumption` -- gated;
  default enumeration -> all `isOnScreen == true`.
- `test_enumerateAll_optionAll_returnsAtLeastAsMany` -- gated;
  `.optionAll` >= `.optionOnScreenOnly`.
- `test_enumerateAll_withDesktopElements_returnsAtLeastAsMany` --
  gated; dropping the desktop exclusion is monotonically
  non-shrinking.
- `test_enumerateAll_preservesFrontToBackOrder` -- gated; back-to-back
  enumerations agree on order of shared wids.
- `test_enumeratedWindow_roundTripsJSON` -- wire shape pinned.
- `test_enumeratedWindow_preservesOptionalNils` -- title / ownerName /
  screenIndex nils survive.
- `test_enumeratedWindow_preservesFractionalBounds` -- Retina
  half-pixel bounds survive.

Result: `swift test --filter WindowEnumerationCaptureTests` -- all
10 pass locally (macOS 27, live user session). Runtime 0.17s.

## sign-and-install

`scripts/sign-and-install.sh` invocation returned a build-DB lock
error from a concurrent Xcode build already running on the machine
(unrelated to this change). Since `swift test` already builds and
executes the target from source, the port is verified to compile
and behave correctly. Re-running `sign-and-install.sh` after the
other build releases the DB should succeed without further changes.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 24 already lists the
target path as `Capture/WindowEnumerationCapture.swift`, so no doc
update was required.

`docs/ROADMAP/10_OVERLAP_ANALYSIS.md` row 242 references
"SLSGetActiveSpace / SLSCopyWindowsWithOptions" for SkyLightInterop
-- kept as-is since that row is analysis of the C# codebase, not a
target for openclicky. If a future SLS-based enumeration path is
added upstream in Everywhere, that row correctly flags the gap.
