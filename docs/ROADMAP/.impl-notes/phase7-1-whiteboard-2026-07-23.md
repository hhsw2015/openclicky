# Phase 7.1 Whiteboard overlay — investigation notes

Reference: `Everywhere/src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs` +
`Everywhere/src/Everywhere.Mcp/Whiteboard/WhiteboardParser.cs` @30e03e9d.

## Everywhere session flow (line-referenced)

1. Hotkey fires (`OnHotkey`, L138-172). Dispatcher hops to UI thread. If an
   overlay is already active a re-press triggers `_activeOverlay.Commit()`
   (L146-148). A reentry guard `_opening` (L45, L150-165) prevents a second
   overlay while the first is mid-await.
2. `OpenOverlayAsync` (L174):
   - Reads the focused element + a11y root BEFORE the overlay steals focus
     (L182-231). Openclicky skips this branch — the port does not snap
     against a11y trees; it stores raw stroke+OCR regions.
   - Determines which screen the focused window's center lives on
     (L233-249). If nothing focused, falls back to first screen.
   - Peek any existing stash (`_whiteboardStash.Peek()`) — surfaces a
     one-line summary of prior regions inside a session so the user
     remembers what they were adding to (L257-264, `SummarizeRegion`
     L1360-1392). Openclicky skips this — no continue-session UI yet.
3. Opens a single `WhiteboardOverlay` (Avalonia Window) covering the whole
   screen. **One overlay per screen** — user gestures on the screen that
   contained the focused window. Multi-monitor: only the target screen is
   dimmed; user must trigger again on the other screen if desired.
4. Background: starts a screencapture task (`captureTask`, L291-329) that
   runs in parallel with the user's drawing — captures the focused
   window, else the screen, and stores an Avalonia bitmap for OCR later.
   Bounded to 2 s (L400).
5. User draws strokes. Each stroke is a `[]StrokePoint(X, Y, T)`. Overlay
   commits either via re-press, an explicit "Done" click, or Enter.
6. On commit, `overlay.ResultTask` yields `{ Strokes[], Canceled,
   ContinueSession, WindowPosition, ScreenBounds }` (L376-397).
7. `WhiteboardParser.ParseGrouped(strokes)` (L461):
   - `GroupStrokes` (L73-102): starts every stroke as its own group,
     then tries to merge each pair into an Arrow (`LooksLikeArrow`,
     L189-220) or X (`LooksLikeX`, L149-187). Arrow is tried FIRST because
     X's fallback is permissive enough to consume shaft+barb arrows.
   - `Classify` (L108-147):
     - Two-stroke groups: `LooksLikeArrow` -> Arrow, `LooksLikeX` -> X, else Circle.
     - Single-stroke: reject when `max(width, height) < 5.0`.
     - Compute `Straightness = chord / pathLength` (L259-269).
     - Compute `closure = |startPt - endPt| / pathLength` (L134-137).
     - `closure < 0.2 && straight < 0.5` -> Circle.
     - `straight < 0.3` -> Circle.
     - `straight > 0.75` -> Underline.
     - Otherwise Arrow.
   - `KindToRect` (L287-299):
     - Circle: `bbox.Inflate(-2)`.
     - Underline: `Rect(bb.X, medianY - 28, bb.Width, 28)` (L301-313).
     - Arrow: `Rect(farthestPt - (100,50), 200, 100)` (L315-330).
     - X: raw bbox.
8. For each annotation:
   - `AnnotationSnapper.Snap` matches against the a11y tree. **Openclicky
     port skips this** — we only need bbox + OCR text.
   - `RunOcrForRegion` (L1284-1357): crops the pre-captured bitmap to the
     region rect, hands to `_ocrEngine.Recognize`. Underline widens the
     Y-band by (-60, -50, +120, +20) so text above/below the thin stroke
     is included. Multi-line OCR result on Underline is filtered to the
     nearest line to the stroke's midY.
   - Optional per-region image crop for canvas-rendered content (fallback
     path). Openclicky always attempts a region PNG crop so
     `read_whiteboard_image` still works.
9. Regions land in `WhiteboardStash.Append` (L707, L727). `ContextStashWriter.CaptureAsync`
   is called on the final commit only (L735).

## Cancel/escape semantics
- `result.Canceled || result.Strokes.Count == 0` -> silently drop the
  session, cancel OCR capture (L387-397).
- `_sessionFocusedRoot` is cleared on cancel so a later Continue doesn't
  reuse a stale AX ref (L394).

## Openclicky port decisions
- **Press-hold semantics** (per task): keyDown -> begin overlay,
  keyUp -> finalize. This differs from Everywhere (persistent overlay
  until re-press). Rationale: `OpenClickyContextHotkeys` today only
  observes `.keyDown` on the CGEvent tap; extend to observe `.keyUp`
  too, dispatched only when we're in whiteboard mode (to avoid
  polluting normal typing).
- Escape key inside the overlay = cancel.
- Multi-monitor: one transparent `NSPanel` per `NSScreen`, all glued
  through a shared session. Points captured on any screen's overlay
  are converted to Quartz global coords before storage. The
  `WhiteboardStash` holds a single flat list of regions.
- Classifier heuristics: **thresholds match Everywhere byte-for-byte**
  (0.2 closure, 0.3/0.5/0.75 straightness cuts, 5 px min extent).
- Arrow/X grouping: single-stroke only in the first port. Two-stroke
  grouping (Arrow=axis+head, X=two chords) is implemented so future
  users drawing multi-stroke arrows/Xs classify correctly.
- OCR: always attempt per-region OCR using `OCRCapture.ocr` on a
  `ScreenshotCaptureEverywhere.captureRegion` result. Underline gets
  the same widened band as Everywhere (screen-space, not rotated).
- PNG bytes: same region crop returned by `captureRegion` is stored
  in `WhiteboardStash.imageBytesById[UUID]` so `read_whiteboard_image`
  works. One PNG per region.

## Files
- Create `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` —
  `@MainActor` singleton, spawns one `NSPanel` per screen.
- Create `cursor-buddy/OpenClickyWhiteboardStrokeClassifier.swift` —
  pure `enum` gate; input `[[CGPoint]]`, output `[(kind, bbox)]`.
- Modify `cursor-buddy/OpenClickyContextHotkeys.swift` — add
  press-hold logic (subscribe to `.keyUp` too, only when in
  whiteboard session) and replace `performWhiteboardStub`.
- Add unit test alongside existing `cursor-buddyTests/`.

## Roadmap doc reconciliation
`docs/ROADMAP/05_LAYER_4_UX.md` section A (Whiteboard 手势) already
covers the design. Only the wire between `OpenClickyContextHotkeys`
and the overlay window is Phase 7.1's delta — no doc update needed.
