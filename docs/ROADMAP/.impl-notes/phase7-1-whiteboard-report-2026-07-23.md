# Phase 7.1 Whiteboard overlay — implementation report

Date: 2026-07-23
Reference: `Everywhere/src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`
and `Everywhere.Mcp/Whiteboard/WhiteboardParser.cs` @30e03e9d.

## Files created

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardStrokeClassifier.swift`
  Pure geometric classifier (`enum` namespace). Input: `[OpenClickyWhiteboardStroke]`;
  output: `[OpenClickyWhiteboardClassifiedGesture]`. No AppKit dependency,
  unit-testable.
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`
  `@MainActor`-isolated singleton. Owns one transparent `NSPanel` per
  `NSScreen`; renders semi-transparent black tint + yellow strokes; captures
  mouse events; on `end()` classifies, screenshots per-region, OCRs, and
  writes to `WhiteboardStash.shared`.
- `/Users/wowdd1/Dev/openclicky/cursor-buddyTests/OpenClickyWhiteboardStrokeClassifierTests.swift`
  Swift Testing unit tests for the classifier (circle, underline, single-
  stroke arrow, two-stroke X, two-stroke arrow, unknown, bbox).

## Files modified

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift`
  - Added `.keyUp` to `monitoredTypes`.
  - Whiteboard action skips the 180 ms modifier-release delay (opening
    the overlay must precede any keyUp).
  - New `enqueueWhiteboardKeyUp()` that fires only when the overlay is
    currently active.
  - `handleGlobalEventTap` now recognises a keyUp with matching keycode
    as a whiteboard-end signal even after modifier keys have already
    released (common release order: ⇧⌘ first, then W).
  - Replaced `performWhiteboardStub` with `performWhiteboardBegin`.

## Docs

- `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase7-1-whiteboard-2026-07-23.md`
  Investigation notes with line-referenced Everywhere behaviour and the
  openclicky port decisions.

## Classifier heuristics (verbatim thresholds vs Everywhere)

Ported from `WhiteboardParser.cs:108-147`:

| Kind | Rule |
|---|---|
| **Unknown** | `max(bbox.w, bbox.h) < 5.0` (single-stroke) |
| **Circle** | `closure = |start-end|/pathLen < 0.2 && straight < 0.5`, else `straight < 0.3` |
| **Underline** | single-stroke, `straight > 0.75` |
| **Arrow** (single) | fallthrough: neither closed nor straight |
| **Arrow** (two-stroke, `LooksLikeArrow`) | longer=axis, shorter=head, `headLen/axisLen <= 0.95`, head endpoint within `max(15, axisLen * 0.30)` of an axis endpoint |
| **X** (two-stroke, `LooksLikeX`) | chords cross AND (midpoint coincidence `midDist/avgLen <= 0.3` OR length ratio in `[0.4, 2.5]` and angle in `[35°, 145°]`) |

Where:
- `straight = chord / pathLength` (`WhiteboardParser.cs:259-269`)
- `pathLength = Σ |p_i - p_{i-1}|`

Per-kind rect selection (`WhiteboardParser.cs:287-330`):
- Circle: bbox inset by 2 px.
- Underline: `Rect(bb.x, medianY - 28, bb.w, 28)` on the median Y of all stroke points.
- Arrow: `Rect(farthestPt - (100,50), 200, 100)`.
- X: raw multi-stroke bbox.

## Multi-monitor handling

`OpenClickyWhiteboardOverlayWindow.begin()` iterates `NSScreen.screens` and
spawns one `NSPanel` per screen. Each panel:

- covers its screen exactly (`frame == screen.frame`),
- sits at `OpenClickyWindowLevels.statusSurface`,
- style `[.borderless, .nonactivatingPanel]`,
- `isOpaque=false`, `backgroundColor=.clear`, `hasShadow=false`,
- `.canJoinAllSpaces, .stationary, .fullScreenAuxiliary`,
- delegates to a single `OpenClickyWhiteboardOverlayView` in local coords.

Stroke points are converted from panel-local (Cocoa, y-up) to Quartz global
(top-left origin) at recording time (`toQuartzGlobal`). All region bboxes
stored in the stash are in Quartz global coords, matching the
`ScreenshotCaptureEverywhere.captureRegion` contract and the wire format
described in `Types/CaptureTypes.swift` (`bboxScreen` field).

The overlay tracks each stroke's origin display via `CGDirectDisplayID`
(retrievable through `NSScreen.deviceDescription["NSScreenNumber"]`) so a
future feature can rescreencapture from the correct monitor.

## Session flow (openclicky port)

1. User presses whiteboard hotkey.
2. `OpenClickyContextHotkeys.enqueueAction(.whiteboard)` marks
   `isWhiteboardOverlayActive = true` (synchronous, no 180 ms delay)
   and calls `OpenClickyWhiteboardOverlayWindow.shared.begin()`.
3. Overlay panels appear on every screen. Cursor becomes a crosshair.
4. `mouseDown` on any overlay view creates a new stroke; `mouseDragged`
   appends points; `mouseUp` finalises the stroke. Multiple strokes per
   session are allowed.
5. `Escape` cancels via `NSPanel.cancelOperation -> owner.cancel()`,
   dropping all strokes without writing to the stash.
6. User releases the hotkey. `handleGlobalEventTap` sees the keyUp,
   `enqueueWhiteboardKeyUp` schedules `OpenClickyWhiteboardOverlayWindow.shared.end()`.
7. `end()` snapshots the strokes, tears down the panels within 250 ms,
   then in the background:
   a. `OpenClickyWhiteboardStrokeClassifier.classify` produces per-gesture
      `(kind, bbox)` values.
   b. For each gesture with bbox > 1 px: `ScreenshotCaptureEverywhere.captureRegion`
      is called for the Quartz-global rect, then `OCRCapture.ocr` runs Vision.
   c. Joined OCR text is placed on the region; PNG bytes are keyed by
      `UUID` and stored in the image-bytes side-table.
   d. `WhiteboardStash.shared.set(regions:imageBytesById:)` commits the batch,
      with the 5-minute TTL clock started.

`read_whiteboard` (MCP Layer 2) reads via `WhiteboardStash.shared.take()`;
`read_whiteboard_image(id)` reads via `imageBytes(for:)`. Both continue to
work unchanged.

## Build result

`bash scripts/sign-and-install.sh` completed:

```
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=32507  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

## Test recipe (manual)

1. Open Settings -> Context Awareness. Enable the master toggle.
2. Bind the "Whiteboard (press-hold)" row to a hotkey (e.g. `⌃⇧W`).
3. Grant Accessibility + Screen Recording permission if not yet granted.
4. Open `Console.app` and filter for `openclicky.whiteboard`.
5. Press and hold the bound hotkey. Screen dims (~15% black), cursor
   becomes a crosshair, all monitors show the overlay.
6. Draw one of: circle around some text, underline under a line, an X
   over an image, or an arrow pointing at something.
7. Release the hotkey. Overlay fades within 250 ms.
8. Watch Console for `openclicky.whiteboard.overlay: end (strokes=N)`
   followed by `stashing K region(s), M image(s)`.
9. The bound MCP `read_whiteboard` tool now sees the regions with the
   correct `gestureKind` + OCR text.

## Notes for future phases

- No `Continue` / `Append` semantics in the Swift port yet — each
  `end()` overwrites the stash entirely (which is what `WhiteboardStash.set`
  provides). If the roadmap calls for cross-screen accumulation, add
  `Append` to the stash then have the overlay call it instead of `set`.
- No live preview of classified overlays during the session. The
  Everywhere overlay shows a chip near each stroke while the user is
  still drawing; we skip that for the MVP.
- No prewarmed a11y tree walk — openclicky's stash record is minimal
  (`bboxScreen`, `gestureKind`, `ocrText`), so the AnnotationSnapper /
  ImageLeaf logic in Everywhere isn't ported.
- Fallback region image is implicit: we always attempt a region PNG
  crop (not just when a11y leaves are empty).
