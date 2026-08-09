# Phase 5 - Window enumeration port

Source pin: `@30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Everywhere reference surfaces

### `src/Everywhere.Mac/Interop/WindowHelper.cs` (384 LOC)

- Only enumeration site in this file is `RaiseOverlayAboveTarget`
  (L251-313). It walks the on-screen window list to find the front
  window that belongs to a given target pid, so it can pin its own
  overlay `Above` that window at that window's layer.
- Enumeration call (L272-274):
  - `CGInterop.CGWindowListCopyWindowInfo(CGWindowListOption.OnScreenOnly | CGWindowListOption.ExcludeDesktopElements, relativeToWindow: 0)`
  - Returned array is CFArray of CFDictionary; treated as NSArray of
    NSDictionary via ObjCRuntime.
- Fields read per window (L280-290):
  - `kCGWindowOwnerPID` -> `NSNumber.Int32Value`
  - `kCGWindowNumber` -> `NSNumber.UInt32Value` (window ID)
  - `kCGWindowLayer` -> `NSNumber.Int32Value`
- Comment on ordering (L291): "CGWindowList returns front-to-back
  order." The first entry matching the target pid is the front window.
- Cleanup: `using var arr = Runtime.GetNSObject<NSArray>(listPtr, owns: true)`
  transfers ownership of the CFArray, ARC/managed disposal handles
  CFRelease.

### `src/Everywhere.Mac/Interop/ScreenSelectionSession.cs` L393-446

- Second enumeration site: `GetWindowOwnerPidsAtLocation` /
  `WindowOwnerPidsBelowOurProcess`.
- Call: `CGWindowListCopyWindowInfo(CGWindowListOption.OnScreenBelowWindow, relativeToWindow)`.
- Fields read (L412-433):
  - `kCGWindowOwnerPID` -> Int32
  - `kCGWindowBounds` -> NSDictionary with `X`, `Y`, `Width`, `Height`
    (all NSNumber -> Double)
- Rect built as `CGRect(x, y, w, h)`, tested with `Contains(point)`.
- Explicit `CFInterop.CFRelease(pArray)` in `finally`.

### `src/Everywhere.Mac/Interop/CGInterop.cs`

- P/Invoke declaration only:
  `[LibraryImport(CoreGraphics)] partial nint CGWindowListCopyWindowInfo(CGWindowListOption option, uint relativeToWindow)`.

### `src/Everywhere.Mac/Interop/SkyLightInterop.cs` (106 LOC)

- Actual content: `CGSMainConnectionID`,
  `CGSCaptureWindowsContentsToRectWithOptions`, `CGSHWCaptureWindowList`
  and the `CGSWindowCaptureOptions` flag enum. All screenshot-focused.
- Does NOT contain `SLSGetActiveSpace` or `SLSCopyWindowsWithOptions`
  despite what `docs/ROADMAP/10_OVERLAP_ANALYSIS.md` row 242 claims.
  Verified by full-file read + grep. That doc row is aspirational.
- Verdict: Everywhere's window enumeration path is CoreGraphics
  `CGWindowListCopyWindowInfo` only. No private SkyLight fallback to
  port because there is no such call to mirror.

## Aggregate: fields, filters, order

Fields Everywhere actually reads off a CGWindowInfo dict:

| Field key | Type | Everywhere reader |
|---|---|---|
| `kCGWindowOwnerPID` | Int32 | WindowHelper L287, ScreenSelectionSession L424 |
| `kCGWindowNumber` | UInt32 | WindowHelper L288 |
| `kCGWindowLayer` | Int32 | WindowHelper L290 |
| `kCGWindowBounds` | Dict {X,Y,W,H doubles} | ScreenSelectionSession L429-433 |

Fields that CGWindowListCopyWindowInfo also emits and callers
routinely want (documented on Apple's CGWindow.h, not read by
Everywhere itself but part of the standard payload):

- `kCGWindowName` -> CFString title (may be nil / requires Screen
  Recording permission on macOS 15+ for windows outside caller pid).
- `kCGWindowIsOnscreen` -> CFBoolean.
- `kCGWindowAlpha` -> CFNumber double.
- `kCGWindowMemoryUsage` -> CFNumber long long.
- `kCGWindowOwnerName` -> CFString.

The port materialises these so downstream tools (intent classifier,
task router) can filter windows by app name / occluded state without
a second AX round-trip.

Filter options in use:

- `CGWindowListOption.OnScreenOnly | .ExcludeDesktopElements` in
  RaiseOverlayAboveTarget - used to find real user windows above the
  desktop wallpaper element and menu bar decorations.
- `CGWindowListOption.OnScreenBelowWindow` in the pid hit-test path
  with `relativeToWindow=0` (= every on-screen window; the "below"
  anchor is the sentinel top-of-list).

Order: CGWindowListCopyWindowInfo is documented and Everywhere-
observed to return front-to-back (L291).

## Openclicky port constraints

- Target file: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/WindowEnumerationCapture.swift`.
- Tests: `.../Tests/OpenClickyContextServiceTests/WindowEnumerationCaptureTests.swift`.
- File header: `// Ported from Everywhere: src/Everywhere.Mac/Interop/WindowHelper.cs @30e03e9d + SkyLightInterop.cs`.
- Append `EnumeratedWindow` to `Types/CaptureTypes.swift` (only).
- Public API (fixed by task spec):
  - `WindowEnumerationCapture.enumerateAll(options: EnumerateOptions = .default) -> [EnumeratedWindow]`
- Swift + AppKit + CoreGraphics only. No `@_silgen_name` SkyLight
  bindings because Everywhere doesn't use SLS for enumeration.

## Implementation strategy

1. Append `EnumeratedWindow` to `Types/CaptureTypes.swift`:
   - `pid: Int32`
   - `wid: CGWindowID` (== UInt32)
   - `title: String?`
   - `ownerName: String?`
   - `bounds: CGRect` (Quartz coords, top-left origin)
   - `screenIndex: Int?` (largest-intersection screen, Everywhere's
     `NSScreenVisualElement.Children` logic)
   - `isOnScreen: Bool`
   - `layer: Int`
   - `alpha: Double`
   - Codable + Sendable + Equatable.

2. `WindowEnumerationCapture.swift`:
   - `EnumerateOptions` struct with:
     - `onScreenOnly: Bool` (default true; corresponds to
       `.OnScreenOnly`)
     - `excludeDesktopElements: Bool` (default true; corresponds to
       `.ExcludeDesktopElements`)
     - `relativeToWindow: CGWindowID` (default 0; passthrough)
     - static `default` mirrors the WindowHelper L272-274 combination.
   - Build `CGWindowListOption` bitmask from options; call
     `CGWindowListCopyWindowInfo(option, relativeToWindow)`.
   - Cast to `[[CFString: Any]]` via `as? [[String: Any]]` with the
     kCGWindow* constants (they are CFStrings but bridge to Swift
     String).
   - Extract per-dict:
     - pid: `kCGWindowOwnerPID` as Int32
     - wid: `kCGWindowNumber` as UInt32 (`CGWindowID`)
     - title: `kCGWindowName` as String? (may be missing)
     - ownerName: `kCGWindowOwnerName` as String?
     - bounds dict: `kCGWindowBounds` -> unpack via
       `CGRect(dictionaryRepresentation: dict as CFDictionary)`
     - isOnScreen: `kCGWindowIsOnscreen` as Bool (default true when
       `.OnScreenOnly` selected)
     - layer: `kCGWindowLayer` as Int
     - alpha: `kCGWindowAlpha` as Double
   - Skip dicts missing pid / wid (matches Everywhere's `continue`).
   - Compute screenIndex via NSScreen union with Cocoa->Quartz Y-flip
     (same math already in FocusedWindowCapture).
   - Preserve returned array order (front-to-back per L291); no sort.

3. Tests:
   - `enumerateAll()` returns non-empty when a GUI session exists;
     `XCTSkipIf` when running headless (env probe: NSScreen.screens
     empty or ProcessInfo detects ssh).
   - Every returned window has `pid > 0` and `wid > 0`.
   - `EnumerateOptions(onScreenOnly: false)` returns >= count of
     default; and options with `excludeDesktopElements: false` returns
     >= count of default.
   - Order is preserved (first entry's layer >= or ~= second entry;
     smoke check that we don't sort).
   - JSON round-trip on `EnumeratedWindow`.
   - Handles headless env: `enumerateAll()` returns `[]` gracefully,
     never crashes / throws.

## Alignment checklist vs Everywhere

| Everywhere behaviour | Port behaviour |
|---|---|
| `CGWindowListCopyWindowInfo` primary path | Same |
| Options: `.OnScreenOnly | .ExcludeDesktopElements` default | `EnumerateOptions.default` sets both true |
| Read pid / wid / layer per dict | Same, plus bounds/title/onscreen/alpha/ownerName |
| Skip dicts missing pid | Same (also skip missing wid) |
| Front-to-back order preserved | Same, no re-sort |
| CFArray released after read | Bridged via `as NSArray?` / ARC in Swift, no explicit CFRelease needed |
| No SLS calls in enumeration path | No `@_silgen_name` SkyLight bindings |
