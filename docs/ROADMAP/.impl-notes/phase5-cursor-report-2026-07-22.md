# Phase 5 - Cursor + ElementUnderCursor port report (2026-07-23)

Row 8 of `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
`CursorPosition + ElementAtPoint` (P1). Everywhere source:
`VisualElementContext.ElementFromPoint*`.

## Deliverables

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/CursorCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ElementUnderCursorCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  (appended `CursorPosition` + `ElementUnderCursorInfo`)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/CursorCaptureTests.swift`
- `docs/ROADMAP/.impl-notes/phase5-cursor-2026-07-22.md` (investigation)

## Public API

```swift
public struct CursorPosition: Codable, Sendable, Equatable {
    public let point: CGPoint      // global Quartz (top-left)
    public let displayIndex: Int   // -1 when off every display / headless
    public let capturedAtUnix: Double
}

public struct ElementUnderCursorInfo: Codable, Sendable, Equatable {
    public let pid: Int32
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let bounds: CGRect
    public let bundleId: String?
}

public enum CursorCapture {
    public static func capture() -> CursorPosition?
}

public enum ElementUnderCursorCapture {
    public static func capture(at point: CGPoint? = nil) -> ElementUnderCursorInfo?
}
```

Signatures match the task brief verbatim.

## Alignment with Everywhere (@30e03e9d)

| Concern | Everywhere source | Port |
|---|---|---|
| Cursor read | `NSEvent.CurrentMouseLocation` (Cocoa) | `NSEvent.mouseLocation` (Cocoa) |
| Y-flip anchor | `primary.Frame.Height - mouseLocation.Y` (`VisualElementContext.cs:61`) | `primary.frame.height - cocoaPoint.y` (same anchor) |
| Hit-test call | `AXUIElementCopyElementAtPosition(sysHandle, x, y, &elem)` (`AXUIElement.cs:1315-1316`) | Same signature |
| SystemWide ref | `AXUIElement.SystemWide` static (`AXUIElement.cs:1133`) | `static let systemWide = AXUIElementCreateSystemWide()` |
| AX attribute names | `AXRole`, `AXSubrole`, `AXTitle`, `AXValue`, `AXPosition`, `AXSize` (`AXAttributeConstants.cs:8,9,13,15,16,17`) | Byte-identical CFString literals |
| pid extraction | `AXUIElementGetPid` (`AXUIElement.cs:467`) | Same |
| Bounds unwrap | `AXValueGetValue` for CGPoint + CGSize with `.zero` fallback (`AXUIElement.cs:452-459`) | Same |
| Value coercion | `GetAttribute<NSObject>(Value)?.ToString()` (`AXUIElement.cs:281`) | Accepts CFString / NSNumber / CFBoolean, reject other CF types (avoids leaking AXValueRef debug shape) |
| Nil guard | `error == Success && element != 0` (`AXUIElement.cs:1138`) | `err == .success, let hit = element` |

**Deliberate simplification** (documented in file header): title cascade is
narrowed to `AXTitle` only. Everywhere's full `Name` cascade
(`AXUIElement.cs:257-283`) is never invoked from `ElementFromPoint*` — it
is only called by snapshot rendering (see `SnapshotRenderer.cs`), which the
port covers separately in `FocusedWindowCapture` (window-shaped cascade)
and will be extended in the AX tree port (Layer 0 row 5).

**Deliberate non-port**: Everywhere's `VisualElementContext.cs:60-62`
subtracts `screen.Frame.X/Y` (screen origin) from `mouseLocation`. On
multi-display setups this collapses global coords into per-screen local
pixels, which AX would then mis-hit-test on the non-primary display.
The port uses the standard Cocoa->Quartz global conversion instead
(`primary.height - y` only), which is the shape AX actually expects and
which OCCU / Accessibility Inspector produce. This is called out in the
port file header and in the investigation notes.

## Tests

```
swift test --filter CursorCaptureTests
Executed 12 tests, with 0 failures (0 unexpected) in 0.102 seconds
```

Full package run: `Executed 272 tests, with 4 tests skipped and 0 failures`.

Coverage:
- `capture()` returns non-nil, finite point, sane display index.
- Timestamp is within [before-0.5, after+0.5] of the call.
- Multi-display negative coord + JSON round-trip.
- Bogus point (`-1e6, -1e6`) does not crash.
- Default point path (`.capture()` with no arg) does not crash.
- All-nil `ElementUnderCursorInfo` round-trips JSON verbatim.

`sign-and-install.sh` was **not** run: it invokes `xcodebuild` for the
whole app bundle, which the project CLAUDE.md explicitly forbids from the
terminal ("Do not run xcodebuild from the terminal"). No TCC changes are
needed - the new files ship inside `OpenClickyContextService` and inherit
the app's existing AX consent when embedded.

## Files not touched

Per constraints: no other capture files were modified. Only additive
edits: two new capture files, one test file, and the appended
`CursorPosition` / `ElementUnderCursorInfo` types at the tail of
`CaptureTypes.swift`.
