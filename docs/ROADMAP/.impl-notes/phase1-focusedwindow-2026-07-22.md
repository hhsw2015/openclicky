# Phase 1 — FocusedWindow investigation notes (2026-07-22)

## Everywhere source of truth

Everywhere does not have a single `MacFocusedWindowReader`. "Focused window" is derived
by combining primitives from `AXUIElement.cs` and window-walk helpers in the snapshot
writer. Files inspected @ `30e03e9dcfdd4247fd679828ed86e9042f32d809`:

- `src/Everywhere.Mac/Interop/AXUIElement.cs` — `FreshFocusedWindowOf(int pid)` at
  L1153-1176, plus `Name` cascade (L257+) and `BoundingRectangle` (L430-465).
- `src/Everywhere.Mac/Interop/AXAttributeConstants.cs` — `AXFocusedWindow`,
  `AXMainWindow`, `AXTitle`, `AXDescription`, `AXHelp`, `AXPosition`, `AXSize`.
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` — how the writer consumes
  `topLevel?.Name` (L143-193, L228-333) and `WalkToTopLevel` at L951-960.
- `src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs` — L34 renders
  `Window: "<title>", App: <name>`.
- `src/Everywhere.Mac/Interop/NSScreenVisualElement.cs` — Cocoa->Quartz flip
  (`primaryFrame.Height - (frame.Y + frame.Height)`) for multi-display coords.

## Semantics extracted

### Resolution algorithm (per pid)
1. Guard: `pid <= 0` -> return `null`.
2. `AXUIElementCreateApplication(pid)` -> `app`.
3. `AXUIElementCopyAttributeValue(app, kAXFocusedWindow)` -> focused window.
4. If step 3 misses (error != .success OR value == 0), retry with `kAXMainWindow`.
5. If both miss -> return `null`.

### Fields Everywhere exposes on the resulting element (AXUIElement)
- `Name` (title) — cascade: `AXTitle` -> `AXDescription` -> `AXHelp` -> role-gated
  `AXValue` -> `AXTitleUIElement.AXValue` -> `AXIdentifier` -> first
  `AXStaticText` child value. For windows the first two entries always suffice;
  the port narrows to `AXTitle` -> `AXDescription` -> `AXHelp` because windows
  don't have the label-bearing role variants that need `AXValue`.
- `BoundingRectangle` — from `AXPosition` (CGPoint) + `AXSize` (CGSize), both
  wrapped in `AXValue` and unwrapped via `AXValueGetValue`. Origin is Quartz
  top-left global coords (multi-display: negative x/y is legal for a window on
  a display to the left of / above the primary).
- `ProcessId` — from `AXUIElementGetPid`, matches the pid we passed in.

### Nil semantics (verified)
- App has no window (freshly launched TextEdit with no untitled doc) — `AXFocusedWindow`
  is `.noValue`; `AXMainWindow` fallback also `.noValue` -> return nil.
- Window minimised — `AXFocusedWindow` still returns the ref, `AXMinimized` reads
  true. Everywhere does not skip minimised; the port preserves that.
- Hidden app — AX still returns a ref; caller decides.
- Non-consented pid (Accessibility permission denied for target) — returns
  `.apiDisabled`; wrapper returns nil.

### Multi-display handling
Everywhere never computes "which display is this window on" inside
`FreshFocusedWindowOf`. It reports raw Quartz-top-left rect and lets the caller
match against `NSScreen.Frame` (converted from Cocoa-bottom-left via the flip in
`NSScreenVisualElement.cs:57-67`). We do the same: expose `frame` in Quartz coords
plus a best-effort `displayIndex` computed by intersecting the window rect against
each `NSScreen.frame` after applying the same flip. `displayIndex` is nil when the
window has no positive-area intersection with any screen (window on a display that
was just unplugged, or degenerate zero-size rect).

### AX constants used (all documented in AXAttributeConstants.cs)
- `AXFocusedWindow` (`kAXFocusedWindowAttribute`)
- `AXMainWindow` (`kAXMainWindowAttribute`)
- `AXTitle` (`kAXTitleAttribute`)
- `AXDescription` (`kAXDescriptionAttribute` — CoreServices constant is `kAXDescription`)
- `AXHelp` (`kAXHelpAttribute`)
- `AXPosition` (`kAXPositionAttribute`)
- `AXSize` (`kAXSizeAttribute`)
- `AXMinimized` (`kAXMinimizedAttribute`)
- `AXMain` (`kAXMainAttribute`) — bool, "is this the app's main window?"

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 3:
> FocusedWindow (title/geometry/display) — `AXUIElement.FreshFocusedWindowOf(pid)`
>  — `Capture/FocusedWindowCapture.swift` — P0

The three fields (title / geometry / display) match what the port surfaces. The
"reference source" cite is correct (`FreshFocusedWindowOf` is the entry point).
The API sketch on L77 says `func focusedWindow() -> FocusedWindowInfo?` — no
`processId` argument. That's the service-level convenience wrapper; the raw
capture takes a pid (matching Everywhere's `FreshFocusedWindowOf(int)`). No doc
edit needed — the low-level capture always takes pid, the service composes it.

## Swift port surface

```
public struct FocusedWindowInfo: Codable, Equatable, Sendable {
    let processId: Int32
    let title: String?         // Name cascade result. nil when window has no textual label.
    let frame: CGRect          // Quartz top-left global coords. .zero if geometry unreadable.
    let displayIndex: Int?     // Index into NSScreen.screens, nil if not on any screen.
    let isMinimized: Bool
    let isMainWindow: Bool
}

public enum FocusedWindowCapture {
    public static func capture(processId: Int32) -> FocusedWindowInfo?
}
```

Rationale for including `isMinimized` / `isMainWindow`: Everywhere reads both
attributes elsewhere (`ContextStashWriter` and `WalkToTopLevel` implicitly, via
`VisualElementType.TopLevel`). Callers filtering "user is actively working in
this window" need `isMinimized`; the router uses `isMainWindow` to prefer the
main window over a floating panel. Both attributes are single AX round-trips on
the resolved window ref; no extra cost.
