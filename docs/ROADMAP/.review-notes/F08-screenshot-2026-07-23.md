# F08 Screenshot Review — 2026-07-23

Scope: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ScreenshotCaptureEverywhere.swift`
Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Everywhere sources:
- `src/Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs` (Screenshot.cs)
- `src/Everywhere.Mac/Interop/NSScreenVisualElement.cs` (NSScreen.cs)
- `src/Everywhere.Mcp/Snapshot/ScreenshotEncoder.cs` (Encoder.cs)
- `src/Everywhere.Mcp/Tools/ScreenshotTool.cs`

---

## 1. Primary path: SCScreenshotManager

**Task claim:** "byte match to Everywhere's ScreenCaptureKit branch."

**Fact:** Everywhere has **no direct ScreenCaptureKit branch** on the primary path. Screenshot.cs:195-199 calls the deprecated `CGImage.ScreenImage(0, rect, CGWindowListOption.All, CGWindowImageOption.Default)`. NSScreen.cs:90 uses the same deprecated call for the `CaptureAsync` path.

OpenClicky (`ScreenshotCaptureEverywhere.swift:192-195`) instead calls `SCScreenshotManager.captureImage(contentFilter:configuration:)`. This is an **intentional documented divergence** stated in the file header (lines 26-29): "Our port replaces step 3 with `SCScreenshotManager.captureImage` directly (macOS 14+) — the same modern backend `screencapture` wraps." So there is no possible byte match; the primary path is a **conscious substitution** of the deprecated Quartz call for the modern SCK entry point. This is correct given openclicky's constraints but the task acceptance criterion "byte match to Everywhere's ScreenCaptureKit branch" is not literally satisfied — Everywhere has no such branch.

**Verdict:** Divergence, but documented and justified. No action.

---

## 2. CLI fallback: `/usr/sbin/screencapture -x -R x,y,w,h`

Verified against NSScreen.cs:118-163.

| Item | Everywhere | openclicky (Screenshot`Everywhere`.swift) | Match |
|------|-----------|-------------------------------------------|-------|
| Executable | `/usr/sbin/screencapture` (NSScreen.cs:124) | line 217 | yes |
| `-x` silent flag | line 130 | line 219 | yes |
| `-R x,y,w,h` | lines 131-135 `int` cast | line 220 `Int(...)` cast | yes |
| Rect stringify | `{0},{1},{2},{3}` invariant | `"\(Int(x)),\(Int(y)),\(Int(w)),\(Int(h))"` | yes |
| Temp path prefix | `ev-cap-{guid:N}.png` (line 120) | `openclicky-cap-{uuid-no-dashes}.png` (line 213) | cosmetic diff (namespace) |
| Wait deadline | `WaitForExit(3_000)` (line 141) | 3.0s poll loop (lines 234-241) | yes semantically |
| Overrun action | `p.Kill(entireProcessTree: true)` (line 143) | `proc.terminate()` (line 237) | **divergence**: SIGKILL vs SIGTERM |
| Non-zero exit / missing file → nil | line 146 | lines 243-249 | yes |
| Temp file wiped | `finally { File.Delete(tmp) }` (line 161) | `defer { try? FileManager.default.removeItem(at: tmp) }` (line 214) | yes |
| CGImageSource decode | `CGImageSource.FromUrl` + `CreateImage(0, ...)` (lines 148-152) | `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex` (lines 245-247) | yes |
| Image count guard | `src.ImageCount == 0` (line 150) | `CGImageSourceGetCount(src) > 0` (line 246) | yes |

**Finding:** `proc.terminate()` sends SIGTERM (`Process.terminate()` on Foundation is `SIGTERM`); Everywhere uses `Process.Kill(entireProcessTree: true)` which is SIGKILL to the whole tree. On a 3-second overrun for `screencapture`, this is likely not user-observable, but strictly speaking not a byte match. If exact overrun behavior parity matters, replace `proc.terminate()` with either `proc.interrupt()` or a direct `kill(proc.processIdentifier, SIGKILL)` call.

Small quibble: openclicky also creates a `Pipe()` for `standardOutput` (line 225) that Everywhere does not; Everywhere only redirects stderr (`RedirectStandardError = true`, line 126). Harmless.

**Verdict:** Match on wire behavior. Signal used for termination is SIGTERM instead of SIGKILL — flag but non-blocking.

---

## 3. Encoder constants

Verified against Encoder.cs:15-19 and ComputeSize (Encoder.cs:104-118).

| Constant | Everywhere | openclicky | Match |
|----------|-----------|------------|-------|
| Default format | `Jpeg` (Encoder.cs:16) | `.jpeg` chosen by callers of `captureRegion`/`captureScreen`; `ScreenshotFormat` enum lives in CaptureTypes.swift:1023-1026 | yes (enum shape 1:1) |
| Default quality | `Quality = 70` (Encoder.cs:17) | `defaultQuality: Int = 70` (line 52) | yes |
| Max height | `MaxHeight = 1080` (Encoder.cs:18) | `defaultMaxHeight: Int = 1080` (line 54) | yes |
| Max width | `MaxWidth = 1920` (Encoder.cs:19) | `defaultMaxWidth: Int = 1920` (line 56) | yes |
| Floor at 2px | `Math.Max(2, ...)` (Encoder.cs:112-113) | `max(2, ...)` (lines 314-315) | yes |
| Force even dims | `if (w % 2 != 0) w--;` (Encoder.cs:115-116) | `if w % 2 != 0 { w -= 1 }` (lines 316-317) | yes |
| Quality clamp | `Math.Clamp(opts.Quality, 1, 100)` (Encoder.cs:74) | `max(1, min(100, defaultQuality))` (line 290) | yes |
| Ratio pick | `Math.Min(ratioW, ratioH)` (Encoder.cs:109) | `min(ratioW, ratioH)` (line 312) | yes |
| Ratio disable | `maxWidth > 0 && srcW > maxWidth` (Encoder.cs:107-108) | `(maxW > 0 && srcW > maxW)` (lines 310-311) | yes |
| Rounding | `Math.Round(srcW * ratio)` (Encoder.cs:112) — banker's | `Double.rounded()` default rule = `.toNearestOrEven` (banker's) | yes |

**Verdict:** Full match on encoder defaults and `ComputeSize` semantics.

---

## 4. Cocoa→Quartz Y-flip union math

Verified against NSScreen.cs:57-68 and Screenshot.cs:173-188.

**Y-flip (NSScreen.cs:57-64):**
```
var primaryFrame = NSScreen.Screens[0].Frame;
var x = (int)frame.X;
var y = (int)(primaryFrame.Height - (frame.Y + frame.Height));
```

openclicky `quartzScreenFrames()` (lines 358-380):
```swift
let primaryHeight = primary.frame.height
let quartz = CGRect(
    x: cocoa.origin.x,
    y: primaryHeight - (cocoa.origin.y + cocoa.height),
    width: cocoa.width,
    height: cocoa.height
)
```

**Divergence:** Everywhere truncates x/y/w/h to `int` at this step (line 63-66: `(int)frame.X`, `(int)frame.Width`, etc.). openclicky keeps them as `CGFloat`. For displays whose Cocoa frame is fractionally offset (unusual but possible with certain configurations of mixed-DPI setups), this changes the intersection math by up to 1 pt. Everywhere's integer truncation happens because `PixelRect` is `int`-based; openclicky uses `CGRect`, so the port is arguably more correct here. Byte match: **no**, but the divergence is a strict improvement.

**Union+intersect (Screenshot.cs:173-188):**
```
allScreensRect = CGRect.Union(allScreensRect, screenRect) // seeded from Empty
rect = CGRect.Intersect(rect, allScreensRect);
if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0) return null;
```

openclicky (lines 111-114):
```swift
let union = screens.reduce(CGRect.null) { $0.union($1.quartzFrame) }
let clipped = rect.intersection(union)
guard !clipped.isNull, !clipped.isEmpty, clipped.width > 0, clipped.height > 0 else { return nil }
```

- `CGRect.null` seed → `CGRect.Union` handles first-element edge case (Everywhere line 184: `if (allScreensRect.IsEmpty) allScreensRect = screenRect`; openclicky uses `CGRect.null` which `.union` treats as absorbing element). Semantically equivalent.
- Intersection: matches.
- Empty/null/zero-dim guard: matches (openclicky adds explicit `.isNull` check, Everywhere relies on `.IsEmpty`).

**Verdict:** Semantic match; strictly speaking openclicky avoids the integer truncation Everywhere does at the CGFloat→int boundary, which is a minor improvement.

---

## 5. Nil on failure (no throws) — matches Everywhere's `Bitmap?`

All three entry points return `ScreenshotResult?`:
- `captureWindow` (line 72): nil on pid ≤ 0, `SCShareableContent.current` throw, no matching window.
- `captureRegion` (line 103): nil on ≤0 dims, empty screen list, empty intersection.
- `captureScreen` (line 156): nil on out-of-range index; delegates to CLI on SC failure, CLI returns nil on failure.
- Encoder `encode` (line 263): nil on `CGImageDestinationCreateWithData` / `Finalize` failure.

No `throws` on public API. Matches Everywhere's `Bitmap?` return via `CaptureScreen` (Screenshot.cs:161-212) which returns null on any failure branch.

`captureViaSC` (line 190) catches `SCScreenshotManager.captureImage` throw and delegates to `captureViaCLI`. That mirrors NSScreen.cs:93-115 (deprecated call returns null → try CLI; CLI throws → return null via task exception). openclicky's public API surface is uniformly `nil`, not `throws`; that is stricter than Everywhere's inner `CaptureAsync` which throws `InvalidOperationException` when both paths fail (NSScreen.cs:114-115), but the outer `Screenshot.cs:161` `CaptureScreen(rect)` never surfaces those throws to callers. The task-level contract ("no throws") is met.

---

## Summary

| Criterion | Result |
|-----------|--------|
| Primary SCScreenshotManager path | Documented divergence (Everywhere's primary is deprecated `CGImage.ScreenImage`, not SCK). Justified. |
| CLI fallback shape | Match, except **SIGTERM vs SIGKILL** on 3s overrun. |
| Encoder constants | Full match. |
| ComputeSize (2px floor, even dims) | Full match. |
| Y-flip formula | Semantic match; openclicky avoids `int` truncation (minor improvement). |
| Union + intersect | Match. |
| Nil on failure, no throws | Match. |

**Optional follow-up:** replace `proc.terminate()` at line 237 with `kill(proc.processIdentifier, SIGKILL)` if strict parity with Everywhere's `Kill(entireProcessTree: true)` is desired. Otherwise F08 is accepted.
