# Phase 5 - Screenshot capture port (report)

Source pin: `@30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Deliverables

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ScreenshotCaptureEverywhere.swift`
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/ScreenshotCaptureEverywhereTests.swift`
- Appended `ScreenshotFormat`, `ScreenshotRegion`, `ScreenshotResult` to
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`.

Untouched (per HARD constraint):

- `cursor-buddy/CompanionScreenCaptureUtility.swift`
- `cursor-buddy/OpenClickyComputerUseRuntime.swift`
- Every other file in `Capture/`.

## Public API

```swift
public enum ScreenshotCaptureEverywhere {
    public static func captureWindow(pid: Int32, format: ScreenshotFormat) async -> ScreenshotResult?
    public static func captureRegion(rect: CGRect, format: ScreenshotFormat) async -> ScreenshotResult?
    public static func captureScreen(screenID: Int = 0, format: ScreenshotFormat) async -> ScreenshotResult?
}
```

- `ScreenshotFormat` — `.jpeg` (default for agent context) or `.png`
  (OCR / diff).
- `ScreenshotRegion` — JSON-stable rect (`x, y, w, h` doubles) with
  `cgRect` bridge and `init(cgRect:)`.
- `ScreenshotResult` — encoded bytes + format + pixel dims.

## Everywhere alignment (side-by-side)

| Everywhere behaviour | Port behaviour | Ref |
|---|---|---|
| `NSScreen.Screens` -> Cocoa->Quartz Y-flip `y = primary.h - (frame.y + frame.h)` | `quartzScreenFrames()` — same math, plus `displayID` + `backingScale` | `NSScreenVisualElement.cs:57-68` |
| Union of screen rects; intersect requested rect | `screens.reduce(.null, union)` then `rect.intersection(...)` | `Screenshot.cs:173-188` |
| Empty rect / negative dims / no intersection -> null | `nil` at every same branch | `Screenshot.cs:168, 191` |
| `CGImage.ScreenImage(0, rect, All, Default)` primary path | `SCScreenshotManager.captureImage` (mandated by "no CGWindowListCreateImage") | `Screenshot.cs:195-200` |
| `screencapture -x -R x,y,w,h /tmp/...png` fallback with 3s kill on timeout | `captureViaCLI(rect:)` — 3s deadline, `terminate()` on overrun, temp file wiped in `defer` | `NSScreenVisualElement.cs:118-163` |
| Encode via `CGImageDestination.Create(data, "public.png", 1)` | `CGImageDestinationCreateWithData(data, UTType.png/jpeg, 1, nil)` | `Screenshot.cs:204-210` |
| JPEG default, quality 70 (`ScreenshotEncoder.cs:17`) | `defaultQuality = 70`, clamped 1..100, applied via `kCGImageDestinationLossyCompressionQuality` | 1:1 |
| Max height 1080 (`ScreenshotEncoder.cs:18`) | `defaultMaxHeight = 1080` | 1:1 |
| Max width 1920 (`ScreenshotEncoder.cs:19`) | `defaultMaxWidth = 1920` | 1:1 |
| `ComputeSize` — tighter axis wins, floor 2px, force even | `computeSize(srcW:srcH:maxW:maxH:)` — identical arithmetic | `ScreenshotEncoder.cs:104-118` |
| `max <= 0` disables that axis | Same | 1:1 |
| PNG-only convenience path uses `q=100, max=0/0` uncapped | PNG branch ignores quality; encoder path unchanged | Same effect |

Divergences (called out explicitly):

- Everywhere's primary path is the deprecated CoreGraphics
  `CGImage.ScreenImage`. The task forbids it. We use `SCScreenshotManager`
  (macOS 14+), which is what Everywhere's own CLI fallback wraps
  (`NSScreenVisualElement.cs:107-109` comment: *"screencapture CLI uses
  the modern ScreenCaptureKit path under the hood and works reliably"*).
- Everywhere's Skia downscale uses Mitchell resampling with
  antialiasing. CoreGraphics equivalent: `interpolationQuality = .high`
  on a premultiplied-first BGRA context. Output pixel dims are
  identical; visual quality is comparable.
- Everywhere's window selection is driven by an interactive
  `ScreenshotSession` picker. `captureWindow(pid:)` doesn't run a
  picker — it selects the largest on-screen window belonging to the
  pid via `SCShareableContent.windows`. This is the same shape as
  Everywhere's `ScreenshotTool.cs` "app_hint" branch (resolves a
  single window handle from a pid) inside the MCP server, so the
  headless API matches Everywhere's headless caller pattern.

## Documentation

Row 14 of `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` referenced
`Capture/ScreenshotCapture.swift`. Left that row unchanged — the port
lives under the disambiguated `ScreenshotCaptureEverywhere.swift`
filename per the task's HARD constraint (avoid colliding with the
future openclicky-native `ScreenshotCapture.swift` slot in Layer 0).
Follow-up work that consumes this port (row 15 `ScreenListCapture`,
row 25 `PermissionPreflight` already exists) can reference the new
type directly.

## Verification

- `swift build` inside the package — clean build, no warnings on
  new files.
- `swift test --filter ScreenshotCaptureEverywhereTests` — 21/21 pass
  live (all TCC-gated tests run when Screen Recording is granted).
- `OPENCLICKY_SKIP_UI_TESTS=1 swift test` — full package: 221 tests,
  0 failures, 19 legitimately skipped (env-gated).
- `bash scripts/sign-and-install.sh` — `BUILD SUCCEEDED`, ad-hoc
  codesign applied, `/Applications/OpenClicky.app` swapped, app launched.

## Nil semantics summary

| Input | Return |
|---|---|
| `captureWindow(pid <= 0, ...)` | nil |
| `captureWindow(pid, ...)` with no on-screen windows for pid | nil |
| `captureRegion` with `width <= 0` or `height <= 0` | nil |
| `captureRegion` rect not intersecting any screen | nil |
| `captureScreen(screenID: <0 || >= screens.count, ...)` | nil |
| `SCShareableContent.current` throws AND CLI fallback fails | nil |
| Any of the above with TCC denied | nil (SC throws, CLI empty) |

No exceptions propagate to callers.
