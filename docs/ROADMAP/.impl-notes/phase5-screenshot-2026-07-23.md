# Phase 5 - Screenshot capture port

Source pin: `@30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Everywhere reference surfaces

### `src/Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs` (213 LOC)

- Interactive picker session (`ScreenshotSession`), not a headless
  capture API. What we need from it is the private
  `CaptureScreen(CGRect rect)` at L166-212:
  - Uses `CGImage.ScreenImage(0, rect, CGWindowListOption.All,
    CGWindowImageOption.Default)` (deprecated CoreGraphics API,
    `CGWindowListCreateImage` under the hood).
  - Encodes with `CGImageDestination.Create(data, "public.png", 1)`
    then wraps in an `Avalonia.Bitmap` -> caller receives a PNG bytestream.
  - Intersects the requested rect against the union of every screen's
    Quartz-flipped frame (L173-188) before hitting the CG API.
    Returns `null` on empty/degenerate rects.

### `src/Everywhere.Mac/Interop/NSScreenVisualElement.cs` (206 LOC)

- Screen enumeration (`NSScreen.Screens`, `LocalizedName`,
  `DeviceDescription["NSScreenNumber"]`).
- `BoundingRectangle` (L53-68) performs the Cocoa->Quartz Y-flip:
  `y = primary.Height - (frame.Y + frame.Height)`.
- `CaptureAsync` (L84-116):
  - First tries `CGImage.ScreenImage(0, rect)`.
  - On null return, falls back to `/usr/sbin/screencapture -x -R x,y,w,h /tmp/...png`.
    (Comment explicitly notes CGImage.ScreenImage has been observed
    returning null even with Screen Recording granted on macOS 14+/27.)
  - The CLI path uses ScreenCaptureKit under the hood and works
    reliably. This is the fallback we replicate.

### `src/Everywhere.Mcp/Snapshot/ScreenshotEncoder.cs`

- `ScreenshotFormat = { Jpeg, Png }`.
- `ScreenshotEncodeOptions(Format=Jpeg, Quality=70, MaxHeight=1080,
  MaxWidth=1920)` - the default cap agent tools use.
- Encode pipeline:
  - Compute size: preserve aspect, pick the tighter axis, force even
    dimensions (yuv420p downstream needs even), floor to >= 2px.
  - JPEG default, quality clamped 1..100.
  - PNG-only convenience method uses quality=100, max=0/0 (uncapped).

### `src/Everywhere.Mcp/Tools/ScreenshotTool.cs`

- Public-API defaults for the agent screenshot tool: jpeg / 70 /
  1920x1080. PNG@100@uncapped only when caller asks for OCR/diff.

## Openclicky port constraints

- Target file: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ScreenshotCaptureEverywhere.swift`.
- Tests: `.../Tests/OpenClickyContextServiceTests/ScreenshotCaptureEverywhereTests.swift`.
- Must NOT touch existing `CompanionScreenCaptureUtility.swift` or
  `OpenClickyComputerUseRuntime.swift` (App-side native screenshot code).
- Suffix `Everywhere` to avoid the name collision.
- No `CGWindowListCreateImage` / `CGImage.ScreenImage`. Use
  `ScreenCaptureKit` (`SCShareableContent` +
  `SCScreenshotManager.captureImage(contentFilter:configuration:)`)
  which is what Everywhere's `screencapture` CLI wraps anyway.
- Preserve Everywhere's encoder defaults:
  - jpeg default, quality 70, max 1920x1080, even dims, floor 2px.
  - png forces quality 100 uncapped.
- Public API (fixed by task spec):
  - `captureWindow(pid: Int32, format: ScreenshotFormat) async -> ScreenshotResult?`
  - `captureRegion(rect: CGRect, format: ScreenshotFormat) async -> ScreenshotResult?`
  - `captureScreen(screenID: Int = 0, format: ScreenshotFormat) async -> ScreenshotResult?`

## Implementation strategy

1. Add public types to `Types/CaptureTypes.swift`:
   - `ScreenshotFormat` enum (jpeg/png), Codable+Sendable.
   - `ScreenshotRegion` struct (x/y/w/h, Quartz coords), Codable+Sendable.
   - `ScreenshotResult` struct (Data + format + pixel w/h), Sendable.

2. New file `ScreenshotCaptureEverywhere.swift`:
   - Enumerate displays via `SCShareableContent.current` (async).
   - `captureScreen(screenID:)` -> `SCContentFilter(display:excludingWindows:[])`
     -> `SCScreenshotManager.captureImage(...)`.
   - `captureWindow(pid:)` -> find matching `SCWindow.owningApplication.processID`,
     prefer the frontmost/on-screen window, use
     `SCContentFilter(desktopIndependentWindow:)`.
   - `captureRegion(rect:)` -> intersect rect against union of screen
     Quartz frames (mirrors L173-188 of the C# source), pick the
     display with the largest intersection, capture that display then
     crop to rect via `sourceRect` on `SCStreamConfiguration`.
   - Fallback path if SC fails (mirrors L110-115 fallback in
     NSScreenVisualElement.cs): shell out to
     `/usr/sbin/screencapture -x -R x,y,w,h /tmp/...png`, read PNG,
     decode via ImageIO.
   - Encode with `CGImageDestination` (png UTI or jpeg UTI + kCGImageDestinationLossyCompressionQuality).

3. Tests (XCTest, gated on TCC permission):
   - `captureScreen(0, .jpeg)` yields non-nil bytes when permission
     is granted; `XCTSkipIf` when we detect denial (`SCShareableContent.current`
     throws or yields zero displays).
   - `captureRegion` on a small valid rect yields bytes.
   - `captureRegion` on an inverted / zero rect returns nil.
   - `captureWindow` on a bogus pid returns nil.
   - Round-trip encoding: decoding the returned data yields an image
     of the reported width/height.

## Alignment checklist vs Everywhere

| Everywhere behaviour | Port behaviour |
|---|---|
| `CGImage.ScreenImage(0, rect, All, Default)` primary path | `SCScreenshotManager.captureImage` (task-mandated modern replacement) |
| Cocoa->Quartz Y-flip for screen union | Same math in `unionOfScreensQuartz()` |
| Rect intersected against screen union; empty -> nil | Same |
| PNG encoding via ImageIO (`public.png`, count=1) | Same for png path |
| Jpeg default, q=70, max 1920x1080, even, min 2px | Same constants |
| `screencapture` CLI fallback with `-x -R x,y,w,h` | Same, only when SC returns nil / throws |
| CLI temp file wiped in finally block | Same |
