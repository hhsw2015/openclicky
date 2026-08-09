# F23 — Whiteboard Drawing UX

Pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Standards: code-only, every claim carries file:line.

## Scope

Compare openclicky's press-hold whiteboard gesture overlay + geometric classifier
against Everywhere's `WhiteboardHotkeyInitializer.cs` + `WhiteboardParser.cs`
pipeline. The Openclicky port is deliberately scoped to the parser+overlay+OCR+stash
pipeline; Everywhere's `AnnotationSnapper` (a11y leaf snap + text/image collection)
is out of scope on the Openclicky side and remains an Everywhere-only stage.

Files under review:

- Openclicky
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` (1-496)
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardStrokeClassifier.swift` (1-365)
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift` (1-355)
  - `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/WhiteboardStash.swift`
  - `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/OCRCapture.swift`
  - `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ScreenshotCaptureEverywhere.swift`
- Everywhere
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Whiteboard/WhiteboardParser.cs`
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SemanticEnricher.cs`

## Alignment Table — Classifier Thresholds (`WhiteboardParser.cs` vs `OpenClickyWhiteboardStrokeClassifier.swift`)

| Rule | Everywhere | Openclicky | Match |
|---|---|---|---|
| Empty stroke reject | `if (strokes is null || strokes.Count == 0) return ([], []);` (`WhiteboardParser.cs:43`) | `guard !filtered.isEmpty else { return [] }` (`OpenClickyWhiteboardStrokeClassifier.swift:65`) | Yes |
| Degenerate size gate | `if (Math.Max(bb.Width, bb.Height) < 5.0) return AnnotationKind.Unknown;` (`WhiteboardParser.cs:128`) | `if max(bb.width, bb.height) < 5.0 { return .unknown }` (`OpenClickyWhiteboardStrokeClassifier.swift:155`) | Yes |
| Circle (closed loop) | `if (closure < 0.2 && straight < 0.5) return AnnotationKind.Circle;` (`WhiteboardParser.cs:138`) | `if closure < 0.2, straight < 0.5 { return .circle }` (`OpenClickyWhiteboardStrokeClassifier.swift:168`) | Yes |
| Circle (curvy fallback) | `if (straight < 0.3) return AnnotationKind.Circle;` (`WhiteboardParser.cs:139`) | `if straight < 0.3 { return .circle }` (`OpenClickyWhiteboardStrokeClassifier.swift:169`) | Yes |
| Underline | `if (straight > 0.75) return AnnotationKind.Underline;` (`WhiteboardParser.cs:145`) | `if straight > 0.75 { return .underline }` (`OpenClickyWhiteboardStrokeClassifier.swift:170`) | Yes |
| Arrow (single stroke fallback) | `return AnnotationKind.Arrow;` (`WhiteboardParser.cs:146`) | `return .arrow` (`OpenClickyWhiteboardStrokeClassifier.swift:171`) | Yes |
| Group merge order | Arrow before X (`WhiteboardParser.cs:93`, comment L82-86) | Arrow before X (`OpenClickyWhiteboardStrokeClassifier.swift:126`) | Yes |
| Two-stroke classify order | Arrow, then X, else Circle sentinel (`WhiteboardParser.cs:117-119`) | Arrow, then X, else Circle sentinel (`OpenClickyWhiteboardStrokeClassifier.swift:146-148`) | Yes |
| X: midpoint coincidence | `midDist / avgLen <= 0.3` (`WhiteboardParser.cs:175`) | `midDist / avgLen <= 0.3` (`OpenClickyWhiteboardStrokeClassifier.swift:193`) | Yes |
| X: length parity gate | `if (ratio < 0.4 || ratio > 2.5) continue;` (`WhiteboardParser.cs:182`) | `if ratio < 0.4 || ratio > 2.5 { continue }` (`OpenClickyWhiteboardStrokeClassifier.swift:196`) | Yes |
| X: angle band | `angle >= 35 && angle <= 145` (`WhiteboardParser.cs:184`) | `angle >= 35 && angle <= 145` (`OpenClickyWhiteboardStrokeClassifier.swift:198`) | Yes |
| X: chord crossing | `if (!SegmentsCross(a[0], a[^1], b[0], b[^1])) continue;` (`WhiteboardParser.cs:157`) | `if !segmentsCross(a[0], a[a.count - 1], b[0], b[b.count - 1]) { continue }` (`OpenClickyWhiteboardStrokeClassifier.swift:180`) | Yes |
| X: min chord length | `if (lenA < 5 || lenB < 5) continue;` (`WhiteboardParser.cs:160`) | `if lenA < 5 || lenB < 5 { continue }` (`OpenClickyWhiteboardStrokeClassifier.swift:183`) | Yes |
| Arrow: head/axis cap | `if (headLen / axisLen > 0.95) return false;` (`WhiteboardParser.cs:210`) | `if headLen / axisLen > 0.95 { return false }` (`OpenClickyWhiteboardStrokeClassifier.swift:216`) | Yes |
| Arrow: proximity threshold | `Math.Max(15, axisLen * 0.30)` (`WhiteboardParser.cs:215`) | `max(15.0, axisLen * 0.30)` (`OpenClickyWhiteboardStrokeClassifier.swift:217`) | Yes |
| Arrow: axis picking | `lenA >= lenB ? (a, b) : (b, a)` (`WhiteboardParser.cs:203`) | `lenA >= lenB ? a : b` / `... b : a` (`OpenClickyWhiteboardStrokeClassifier.swift:214-215`) | Yes |
| Circle rect | `bb.Inflate(-2)` (`WhiteboardParser.cs:293`) | `bb.insetBy(dx: 2, dy: 2)` (`OpenClickyWhiteboardStrokeClassifier.swift:236`) | Yes |
| Underline rect | `baseline = median(y); Rect(bb.X, baseline - 28, bb.Width, 28)` (`WhiteboardParser.cs:301-313`) | Same, `lineH = 28.0` (`OpenClickyWhiteboardStrokeClassifier.swift:246-259`) | Yes |
| Arrow rect | `Rect(bestX - 100, bestY - 50, 200, 100)` (`WhiteboardParser.cs:329`) | `CGRect(x: bestX - 100, y: bestY - 50, width: 200, height: 100)` (`OpenClickyWhiteboardStrokeClassifier.swift:278`) | Yes |
| X rect | `bb` (unmodified) (`WhiteboardParser.cs:296`) | `bb` (unmodified) (`OpenClickyWhiteboardStrokeClassifier.swift:242`) | Yes |
| `straightness()` | `chord / len`, min-length guard 1.0 (`WhiteboardParser.cs:259-269`) | `chord / len`, min-length guard 1.0 (`OpenClickyWhiteboardStrokeClassifier.swift:313-320`) | Yes |
| `SegmentsCross` | Strict-inequality cross-product (`WhiteboardParser.cs:248-257`) | Strict-inequality cross-product (`OpenClickyWhiteboardStrokeClassifier.swift:335-348`) | Yes |

## Alignment Table — Session Flow (`WhiteboardHotkeyInitializer.cs` vs Openclicky overlay + hotkey)

| Behaviour | Everywhere | Openclicky | Match |
|---|---|---|---|
| Hotkey binding | `Settings.Shortcut.Whiteboard` via `IShortcutListener.Register` (`WhiteboardHotkeyInitializer.cs:128`) | CGEvent tap keyDown/keyUp routed to `enqueueAction(.whiteboard)` / `enqueueWhiteboardKeyUp` (`OpenClickyContextHotkeys.swift:168-190`) | Yes (semantic) |
| Press starts session | `_activeOverlay = new WhiteboardOverlay(...)` inside `OpenOverlayAsync` (`WhiteboardHotkeyInitializer.cs:272-274`) | `performWhiteboardBegin` -> `OpenClickyWhiteboardOverlayWindow.shared.begin()` (`OpenClickyContextHotkeys.swift:294-298`) | Yes |
| Release commits | Overlay closes on `Enter`/re-press; `_activeOverlay.Commit()` (`WhiteboardHotkeyInitializer.cs:146-148`) | keyUp -> `end()` (`OpenClickyContextHotkeys.swift:240-244`) | Semantic (keyup vs press-again to commit); openclicky uses press-hold as spec'd |
| Multi-screen overlay | Chooses one screen (targetScreen focused-window heuristic) (`WhiteboardHotkeyInitializer.cs:238-247`) | One `NSPanel` per `NSScreen`, shared stroke session (`OpenClickyWhiteboardOverlayWindow.swift:275-288`) | Openclicky broader (multi-monitor) |
| Cancel path | Esc / `Result.Canceled == true` -> no stash (`WhiteboardHotkeyInitializer.cs:387-397`) | Esc keycode 53 -> `owner?.cancel()` (`OpenClickyWhiteboardOverlayWindow.swift:73-86`, 342-350) | Yes |
| Stroke draw | `WhiteboardOverlay` (Avalonia) collects `Stroke` list | `mouseDown/Dragged/Up` update per-screen strokes + session-global list (`OpenClickyWhiteboardOverlayWindow.swift:170-210`, 354-378) | Yes |
| Coordinate space | Screen px passed straight into parser | Cocoa view local -> Quartz global (primary flip) (`OpenClickyWhiteboardOverlayWindow.swift:384-401`) | Yes |
| Fade-out on end | Overlay closes immediately | 250 ms preview sleep (`OpenClickyWhiteboardOverlayWindow.swift:321`) | Openclicky adds preview per spec |
| Stroke tint | `WhiteboardOverlay` (Avalonia) | Alpha 0.15 black tint filled every screen (`OpenClickyWhiteboardOverlayWindow.swift:117`) | Matches doc constraint |
| Stroke stroke width / colour | Avalonia canvas | `NSBezierPath.lineWidth = 3`, RGB 255/235/59 (yellow) (`OpenClickyWhiteboardOverlayWindow.swift:120-128,129`) | Matches doc constraint |
| Classifier invocation | `WhiteboardParser.ParseGrouped(strokes)` (`WhiteboardHotkeyInitializer.cs:461`) | `OpenClickyWhiteboardStrokeClassifier.classify(strokes:)` (`OpenClickyWhiteboardOverlayWindow.swift:434`) | Yes |
| Post-classify snap | `AnnotationSnapper.Snap(...)` per region (`WhiteboardHotkeyInitializer.cs:504`) | Not ported (Openclicky pipeline is OCR-only, no a11y leaf snap) | Divergent — see Issue 3 |
| Per-region OCR | `RunOcrForRegion(...)` on cropped screenshot (`WhiteboardHotkeyInitializer.cs:603`) | `ScreenshotCaptureEverywhere.captureRegion` -> `OCRCapture.ocr(image:)` per region (`OpenClickyWhiteboardOverlayWindow.swift:461-482`) | Yes (parity in spirit) |
| Underline OCR widening | 60 px L/R, 50 px above, 20 px below (`WhiteboardHotkeyInitializer.cs:596-602`) | Not implemented (`OpenClickyWhiteboardOverlayWindow.swift:463-464`) | Divergent — see Issue 4 |
| Nearest-line filter | Post-OCR keep nearest-Y line for Underline (`WhiteboardHotkeyInitializer.cs:609-624`) | Not implemented | Divergent — see Issue 4 |
| Stash commit | `_whiteboardStash.Append(regions)` (`WhiteboardHotkeyInitializer.cs:707,727`) | `WhiteboardStash.shared.set(regions: regions, imageBytesById: imageMap)` (`OpenClickyWhiteboardOverlayWindow.swift:494`) | Semantic (set vs append) — see Issue 5 |
| Post-commit auto snapshot | `_contextWriter.CaptureAsync()` (`WhiteboardHotkeyInitializer.cs:735`) | Not called (end() only writes to WhiteboardStash) | Divergent — see Issue 6 |
| Idempotent re-fire | `Interlocked.CompareExchange(ref _opening, 1, 0)` guard (`WhiteboardHotkeyInitializer.cs:150-165`) | `if isActive { return }` in `begin()` (`OpenClickyWhiteboardOverlayWindow.swift:270`), `isActive` flip on `end/cancel` | Yes (same intent) |

## Overlay Visuals

| Constraint | Value in code | Reference |
|---|---|---|
| Tint alpha | `NSColor.black.withAlphaComponent(0.15).setFill(); bounds.fill()` | `OpenClickyWhiteboardOverlayWindow.swift:117-118` |
| Yellow stroke width | `path.lineWidth = 3` | `OpenClickyWhiteboardOverlayWindow.swift:128` |
| Yellow stroke color | `NSColor(calibratedRed: 1.0, green: 235/255, blue: 59/255, alpha: 1.0)` | `OpenClickyWhiteboardOverlayWindow.swift:121-126` |
| Classified bbox stroke | `NSColor.orange.setStroke(); bp.lineWidth = 1; setLineDash([4,3], ...)` | `OpenClickyWhiteboardOverlayWindow.swift:141-147` |
| Region label | System font 11pt semibold orange drawn 4pt above bbox top | `OpenClickyWhiteboardOverlayWindow.swift:150-160` |
| Fade-out | `try? await Task.sleep(nanoseconds: 250_000_000)` before `orderOut` | `OpenClickyWhiteboardOverlayWindow.swift:321-324` |

Constraint check: alpha 0.15 ✓, yellow 3 px ✓, orange dashed 1 px bbox ✓, region label ✓.

`classifyByScreen(strokes:)` currently returns `[]` intentionally, so the classified
overlay is never painted before fade-out (`OpenClickyWhiteboardOverlayWindow.swift:411-418`).
The `showClassifiedOverlay` renderer is wired but never fed. See Issue 2.

## Post-session Pipeline

Per-stroke pipeline in `processAndStash(strokes:...)` (`OpenClickyWhiteboardOverlayWindow.swift:426-495`):

1. Convert session strokes to `OpenClickyWhiteboardStroke` (line 431-433).
2. `OpenClickyWhiteboardStrokeClassifier.classify(strokes:)` (line 434).
3. Skip empty result set (line 435-438).
4. For each classified gesture:
   - Reject `width <= 1 || height <= 1` bboxes as a bare region with `ocrText == nil` (line 448-456). Matches Everywhere's "region rejected" fallback shape but Everywhere still keeps the region — see Issue 7.
   - `captureOverride ?? ScreenshotCaptureEverywhere.captureRegion(rect: quartzBbox, format: .png)` (line 460-468).
   - If bytes present, `OCRCapture.ocr(image:)` — join non-empty lines with `"\n"` (line 469-483).
   - Append `WhiteboardRegion(id, bboxScreen: quartzBbox, gestureKind: gesture.kind.rawValue, ocrText: ...)` (line 485-490).
5. `WhiteboardStash.shared.set(regions: regions, imageBytesById: imageMap)` (line 494).

Cancellation: `cancel()` clears panels, view list, and `sessionStrokes` before any
processing (`OpenClickyWhiteboardOverlayWindow.swift:342-350`). No stash write.

Escape from panel-level `keyDown`: keycode 53 -> `owner?.cancel()`
(`OpenClickyWhiteboardOverlayWindow.swift:73-86`).

## Issues

### Issue 1 — Classifier is byte-for-byte parity (positive finding)

`OpenClickyWhiteboardStrokeClassifier` reproduces every threshold from
`WhiteboardParser.Classify` / `LooksLikeArrow` / `LooksLikeX` / `KindToRect`,
including the wide-flat-X midpoint-coincidence branch and the 30 % axis
proximity for Arrow. The single-file table above covers every gate.

### Issue 2 — Preview overlay renderer is wired but always empty

`classifyByScreen(strokes:)` returns `[]` unconditionally
(`OpenClickyWhiteboardOverlayWindow.swift:411-418`, comment: "No-op placeholder"),
so `OpenClickyWhiteboardOverlayView.showClassifiedOverlay` — the dashed orange
bbox + label renderer at lines 216-219 and the draw code at 140-161 — never
runs at the end of a real session. The overlay constraint "orange dashed 1 px
classified bbox + region label next to bbox" is implemented but effectively
dead code until `classifyByScreen` is populated.

Everywhere doesn't have this preview either (its overlay closes on commit),
so this is an Openclicky-specific spec item that is only half-delivered.

### Issue 3 — No `AnnotationSnapper` port (deliberate omission, must be documented)

Everywhere runs `AnnotationSnapper.Snap` after `WhiteboardParser.ParseGrouped`
(`WhiteboardHotkeyInitializer.cs:504`) to project each gesture onto a11y
leaves in the focused root. Openclicky skips this entirely and relies on
per-region OCR to recover the intended text. Behaviour diverges when the
target text is a11y-exposed but not visually captured (canvas / off-screen
scroll / Unicode fonts Vision mis-recognises). Not a bug per the spec —
Openclicky's spec calls out only stroke -> region -> OCR -> stash — but
worth logging so the divergence isn't lost.

### Issue 4 — Underline OCR band + nearest-line filter absent

Everywhere widens the OCR crop for Underline gestures (60 px L/R, 50 px above,
20 px below) and filters the resulting OcrLines to the row whose vertical
centre is closest to the stroke centre-Y
(`WhiteboardHotkeyInitializer.cs:596-624`). Openclicky OCR uses the raw
`quartzBbox` for every gesture kind (`OpenClickyWhiteboardOverlayWindow.swift:463-464`)
and joins every returned line with newline (`OpenClickyWhiteboardOverlayWindow.swift:476-480`).
Underline gestures, whose stroke bbox is 3-10 px tall, will produce 0 OCR
lines or the wrong row on real screens.

### Issue 5 — `WhiteboardStash.set` overwrites; Everywhere `Append` unions

`WhiteboardStash.shared.set(regions:, imageBytesById:)` clobbers prior
contents (`OpenClickyWhiteboardOverlayWindow.swift:494`). Everywhere calls
`_whiteboardStash.Append(regions)` unconditionally, both for Continue-session
appends and final commits (`WhiteboardHotkeyInitializer.cs:707,727`, comment
L719-726 explicitly warns "Set would silently overwrite prior batches"). If
Openclicky ever wires a Continue-style follow-up, the older regions will be
lost. Openclicky spec is one-shot per session, so this only bites when the
UX changes.

### Issue 6 — Post-commit context-stash auto-snapshot not fired

Everywhere calls `_contextWriter.CaptureAsync()` after a final (non-continue)
commit so the agent's next prompt sees the whiteboard (`WhiteboardHotkeyInitializer.cs:735`).
Openclicky's `processAndStash` ends at `WhiteboardStash.shared.set(...)` and
never invokes `OpenClickyContextStashWriter.captureAsync()`
(`OpenClickyWhiteboardOverlayWindow.swift:494`). The user has to press
SnapshotContext manually to ship the whiteboard to the ctx envelope.

Cross-check: `OpenClickyContextStashWriter` already knows how to include
`whiteboard_pending` / `whiteboard_region_count`, but only when the writer
peeks the stash and those fields are wired
(`OpenClickyContextStashWriter.swift:136-138` explicitly leave them nil with
a Phase 7 TODO), so today an auto-fire wouldn't do the right thing either.

### Issue 7 — Empty-bbox regions written with `ocrText == nil` instead of dropped

For degenerate bboxes (`width <= 1 || height <= 1`), Openclicky writes a
region with no OCR text and no image bytes
(`OpenClickyWhiteboardOverlayWindow.swift:448-456`). Everywhere's equivalent
"rejected" path either drops the region (single-tap Unknown) or emits a
crop-based fallback (Circle/X/Underline with OCR of the region rect,
`WhiteboardHotkeyInitializer.cs:509-568`). The Openclicky path yields
regions that carry only a gesture kind + coord tuple.

### Issue 8 — Multi-monitor global coord flip is correct

`toQuartzGlobal(localPoint:view:)` computes
`primary = NSScreen.screens.first?.frame.maxY` and returns
`CGPoint(x: cocoaGlobal.x, y: primary - cocoaGlobal.y)`
(`OpenClickyWhiteboardOverlayWindow.swift:384-401`). This matches
Everywhere `ScreenSelectionSession`'s convention
(`ScreenSelectionSession.cs:66-74`, `ScreenSelectionSession.cs:243-245`)
and produces Quartz top-left globals from Cocoa bottom-left panels.
Positive finding.

## Verdict

Classifier logic is byte-for-byte parity with the pinned `WhiteboardParser`.
Overlay session lifecycle (press-hold begin, keyUp end, Esc cancel,
one panel per NSScreen, 250 ms fade-out, alpha 0.15 tint, 3 px yellow strokes,
Quartz global coords) matches the F23 spec.

Divergences from Everywhere that matter for behavioural parity, not spec
compliance:

- Issue 4 (Underline OCR band + nearest-line filter): high impact, the OCR
  step will return the wrong text or nothing on Underline strokes.
- Issue 6 (no auto ContextStashWriter fire): user-visible — SnapshotContext
  must be pressed a second time.
- Issue 2 (empty classified preview): stated spec constraint but rendered dead.

Divergences that are deliberate:

- Issue 3 (`AnnotationSnapper` omitted): matches the openclicky spec.
- Issue 5 (`set` vs `Append`): scoped to one-shot sessions.

Ship status: acceptable for the "record gestures, OCR crops, stash regions"
contract. Not yet at Everywhere behavioural parity. Follow up with issues 2,
4, 6 before promoting to the SnapshotContext / agent flow.
