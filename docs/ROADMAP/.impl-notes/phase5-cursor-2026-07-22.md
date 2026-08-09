# Phase 5 - Cursor + ElementUnderCursor investigation notes (2026-07-23)

Row 8 in `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
- Ability: `CursorPosition + ElementAtPoint` (P1).
- Everywhere source: `VisualElementContext.ElementFromPoint*`.
- Target: `Capture/CursorCapture.swift`.

Port target is split into two files per the task brief:
- `Capture/CursorCapture.swift`         - point-only (`CursorPosition`).
- `Capture/ElementUnderCursorCapture.swift` - AX hit-test (`ElementUnderCursorInfo`).

## Everywhere ground truth @30e03e9dcfdd4247fd679828ed86e9042f32d809

### `VisualElementContext.cs`

Two entry points (grep hits confirmed):

```
IVisualElement? ElementFromPoint(PixelPoint point, ScreenSelectionMode mode)
    -> AXUIElement.SystemWide.ElementAtPosition(point.X, point.Y)   // .Element mode

IVisualElement? ElementFromPointer(ScreenSelectionMode mode = Element)  // L48-67
    var mouseLocation = NSEvent.CurrentMouseLocation;                   // Cocoa (bottom-left)
    var screen = NSScreen.Screens.FirstOrDefault(s => s.Frame.Contains(mouseLocation))
                    ?? NSScreen.MainScreen;
    if (screen is null) return null;
    var y = screen.Frame.Height - (mouseLocation.Y - screen.Frame.Y);   // Cocoa -> Quartz
    var x = mouseLocation.X - screen.Frame.X;                           // strip screen origin
    return new PixelPoint((int)x, (int)y);
```

Coordinate convention: point handed to `AXUIElementCopyElementAtPosition` is a
**global Quartz coordinate** (top-left origin), NOT a screen-local one. Everywhere
subtracts `screen.Frame.X/Y` (which is the screen's own Cocoa origin) so on the
primary display X/Y match Quartz global; on non-primary displays Everywhere is
actually collapsing multi-display global coords into per-screen local pixels.
That is a bug/quirk we do NOT need to reproduce - AX hit-test accepts native
Quartz global coords directly on macOS. We port the primary-display path
faithfully (`x = mouseLocation.X`, `y = primaryFrame.height - mouseLocation.y`),
which is what NSEvent.mouseLocation -> global-Quartz conversion is on macOS.

### `AXUIElement.cs`

```
[LibraryImport(AppServices, EntryPoint = "AXUIElementCopyElementAtPosition")]
private static partial AXError CopyElementAtPosition(nint application, float x, float y,
                                                      out nint element);

public AXUIElement? ElementAtPosition(float x, float y)
{
    var error = CopyElementAtPosition(Handle, x, y, out var element);
    return error == AXError.Success && element != 0 ? new AXUIElement(element) : null;
}
```

Called on `AXUIElement.SystemWide` (a systemwide element from `AXUIElementCreateSystemWide`).

### Attribute extraction on the hit element

Everywhere's `AXUIElement` exposes these getters used downstream:

- `Role`      -> `AXAttributeConstants.Role`     -> "AXRole"      (string)
- `Subrole`   -> `AXAttributeConstants.Subrole`  -> "AXSubrole"   (string)
- `Name`      -> cascade: AXTitle -> AXDescription -> AXHelp -> ... (see `AXUIElement.cs:257-283`)
- `Value`     -> `AXAttributeConstants.Value`    -> "AXValue"     (any -> string)
- `BoundingRectangle` -> AXPosition + AXSize -> CGRect            (both wrapped in AXValue)
- `ProcessId` -> `AXUIElementGetPid`

For `ElementUnderCursorInfo` we adopt the same order (matches
`Types/CaptureTypes.swift` conventions already used by other captures):

1. pid    - `AXUIElementGetPid`
2. role   - "AXRole"
3. subrole- "AXSubrole"
4. title  - "AXTitle" (narrow, matches other ports; full cascade adds cost + is
            not called by Everywhere on the hit-test path directly)
5. value  - "AXValue" -> string coercion
6. bounds - "AXPosition" + "AXSize" -> CGRect (fall through to `.zero`)
7. bundleId - via `NSRunningApplication(processIdentifier:)` (Everywhere reaches
              through `NSWorkspace.RunningApplications`, same effect)

## Nil / error paths

- No mouse (no HID / server session): `NSEvent.mouseLocation` returns `.zero`.
  We treat point (0,0) at start as legitimate but still emit a `CursorPosition`.
- Bogus point (negative, off all displays): AX call returns `.success` with a
  nil element on most macOS builds; on some builds `.cannotComplete`. Both map
  to nil, matching Everywhere's `element != 0` guard.
- Missing role/title/value: individual reads return nil; struct field is
  `Optional` so absence is normal.
- Missing bounds: fall through to `.zero` (mirrors `QueryBoundingRectangle` /
  `return default;` at `AXUIElement.cs:461`).

## Coordinate system decision

`CursorPosition.point` is **global Quartz** (top-left origin, matches Everywhere's
`ElementFromPoint` argument). This is what feeds `AXUIElementCopyElementAtPosition`.

Conversion: `NSEvent.mouseLocation` is Cocoa (bottom-left of primary display).
Flip via `primary.frame.height - mouseLocation.y`. Do NOT use screen-local flip -
we want global coords so hit-test works on non-primary displays too.

## Display index

Same algorithm as `FocusedWindowCapture.displayIndex(for:)`:
convert each `NSScreen.frame` (Cocoa) to Quartz, intersect with a 1x1 rect at
the cursor point, largest area wins. Reuse the existing helper if easy; if not,
inline the same code (kept local per Everywhere's per-file layout).

## Test plan (headless-safe)

- `CursorCapture.capture()` returns non-nil on any macOS session; point coords
  must be finite and displayIndex >= 0 when at least one screen exists.
- Fallback: when `NSScreen.screens` is empty (never true on a live session),
  `displayIndex` may be nil / test asserts `>= 0`.
- `ElementUnderCursorCapture.capture(at: CGPoint(x: -1e6, y: -1e6))` must not
  crash and returns either nil or a screen-level element (some macOS builds
  return the top-level `AXApplication` for `com.apple.WindowManager`).
- JSON round-trip on both structs.
