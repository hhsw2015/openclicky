# Phase 1 — FocusedWindow port report (2026-07-22)

## Summary

Ported Everywhere's focused-window derivation into
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FocusedWindowCapture.swift`
and added `FocusedWindowInfo` to `Types/CaptureTypes.swift`. Tests in
`Tests/OpenClickyContextServiceTests/FocusedWindowCaptureTests.swift`.

## Investigation outcome

Everywhere has no single "MacFocusedWindowReader" — the notion is composed from:

- `AXUIElement.FreshFocusedWindowOf(int pid)` (`AXUIElement.cs:1153-1176`) — the
  two-step `AXFocusedWindow -> AXMainWindow` resolution;
- `AXUIElement.Name` (`AXUIElement.cs:257-283`) — the title cascade; the port
  narrows to AXTitle/AXDescription/AXHelp because AXWindow is never
  label-bearing;
- `AXUIElement.BoundingRectangle` (`AXUIElement.cs:430-465`) — AXPosition +
  AXSize unwrap via `AXValueGetValue(.cgPoint / .cgSize)`;
- `AXAttributeConstants.MinimizedAttr` / `MainTrait`
  (`AXAttributeConstants.cs:81-82`) — bool state;
- `NSScreenVisualElement.Children` / `BoundingRectangle`
  (`NSScreenVisualElement.cs:22-67`) — Cocoa->Quartz Y-flip
  `y = primaryFrame.Height - (frame.Y + frame.Height)`, used here to compute
  `displayIndex`.

Full notes: `docs/ROADMAP/.impl-notes/phase1-focusedwindow-2026-07-22.md`.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 3 already lists
"title/geometry/display" as the three fields and cites
`FreshFocusedWindowOf(pid)`. No doc edit required — the port matches the
existing spec.

## Public API

```swift
public struct FocusedWindowInfo: Codable, Equatable, Sendable {
    let processId: Int32
    let title: String?
    let frame: CGRect          // Quartz top-left global coords
    let displayIndex: Int?     // Index into NSScreen.screens
    let isMinimized: Bool
    let isMainWindow: Bool
}

public enum FocusedWindowCapture {
    public static func capture(processId: Int32) -> FocusedWindowInfo?
}
```

## Alignment audit vs Everywhere

| Everywhere behaviour | Port location |
|---|---|
| `pid <= 0 -> null` (AXUIElement.cs:1163) | `capture` guard, L94 |
| `AXFocusedWindow` first, `AXMainWindow` fallback (AXUIElement.cs:1166-1174) | `resolveWindow`, L119-124 |
| Empty/whitespace title -> next cascade level (AXUIElement.cs:269+, `IsNullOrWhiteSpace`) | `readTitle`, L142-149 |
| Missing AXPosition/AXSize -> `default` PixelRect (AXUIElement.cs:461-464) | `readFrame`, L166-183 -> `.zero` |
| Missing bool attr -> falsey (implicit throughout AXUIElement.cs) | `readBool`, L155-161 |
| Cocoa->Quartz Y-flip for screen membership (NSScreenVisualElement.cs:57-67) | `displayIndex(for:)`, L200-224 |

All AX attribute names match Everywhere's constants (`AXFocusedWindow`,
`AXMainWindow`, `AXTitle`, `AXDescription`, `AXHelp`, `AXPosition`, `AXSize`,
`AXMinimized`, `AXMain`).

## Test results

`cd /Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService && swift test`

- Full suite: **95 tests, 0 failures, 2 skipped**.
- FocusedWindowCaptureTests: **7 pass, 1 skip**
  (`test_capture_returnsFocusedWindow_forFinder` skipped — Finder was frontmost
  but had no window open at test time; this is legitimate nil behaviour, not a
  test failure).

`cd /Users/wowdd1/Dev/openclicky && bash scripts/sign-and-install.sh`

- BUILD SUCCEEDED, codesign OK, installed, launched pid=30240.

Both required verifications green on first attempt; no retries needed.

## Files touched

- Created: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FocusedWindowCapture.swift`
- Appended `FocusedWindowInfo` + `import CoreGraphics` to:
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
- Created: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/FocusedWindowCaptureTests.swift`
- Created: `docs/ROADMAP/.impl-notes/phase1-focusedwindow-2026-07-22.md`

Not touched (per HARD constraints): `FrontmostAppCapture.swift`,
`ClipboardCapture.swift`, `IdleTimeCapture.swift`, `FinderSelectionCapture.swift`,
`BrowserURLCapture.swift`, `AppleScriptRunner.swift`, and every existing type in
`CaptureTypes.swift`.
