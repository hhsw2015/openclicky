# Whiteboard + PickStash + AnnotationBadge Round-2 alignment to Everywhere @30e03e9d

Date: 2026-07-23
Follow-up to `whiteboard-linkrect-hotkey-align-2026-07-23.md`. Round 2 covers
the items the Round-1 three-file allowlist could not touch:

1. Whiteboard byte-exact underline OCR band widening + nearest-line filter +
   auto contextWriter capture on commit.
2. Round-2 debug logs across the Whiteboard, LinkRect, Pick, and
   AnnotationBadge surfaces.
3. Verification that `PickStash` and `AnnotationBadge` are already
   single-slot / anchored-to-current-pin (no refactor needed).

## Everywhere source citations (all @30e03e9d)

### Whiteboard OCR band widening + nearest-line filter

`src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`:

- Lines 596-602 — Underline OCR band widening (happy path):
  `X - 60`, `Y - 50`, `W + 120`, `H + 20`.
- Lines 609-624 — Nearest-line filter: after OCR, keep only the line
  whose vertical mid-Y is closest to the stroke mid-Y.
- Lines 533-538, 542-555 — Same widening + filter on the rejected /
  fallback path (kept out of scope in this round; openclicky's whiteboard
  path currently has one shared OCR call per gesture that already handles
  both happy and rejected sub-paths).
- Line 735 — `await _contextWriter.CaptureAsync()` fires unconditionally
  once regions are stashed on a final commit.

### PickStash single-slot

`src/Everywhere.Core/Interop/PickStash.cs`:

- Line 18 — `private Entry? _current;` (single-slot storage).
- Line 42-51 — `Set` replaces the previous slot.
- Line 56-70 — `Take` reads and clears atomically.
- Line 105 — `Entry(IVisualElement Element, DateTimeOffset ExpiresAtUtc)`.

### AnnotationBadge single-badge tied to current pin

`src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs`:

- Line 76 — `DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) }`
  20fps follow (already ported to `OpenClickyAXFollower` in F25).
- Line 111-119 — `OnFollowTick` iterates `_overlays` and refreshes each pair.
- Line 162-216 — `OnPinned` creates ONE outline+badge pair per pin.

### LinkRect harvest

`src/Everywhere.Core/Interop/VisualElementContext.LinkRect.LinkRectSession`
already reviewed byte-parity in F24. Round-2 adds only a debug log.

## Ported / verified deltas

### 1. Whiteboard

File: `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`.

Before: `processAndStash` called OCR on the raw gesture bbox. Underline
gestures under a text row missed the row entirely because the stroke
bbox was `H ~ 3-10px` and the row sat 30-50px above/below.

After: byte-exact Everywhere port of the underline widening block:

```swift
if gesture.kind == .underline {
    widenedL = 60; widenedR = 60; widenedT = 50; widenedB = 20
    ocrRect = CGRect(
        x: max(0, quartzBbox.origin.x - 60),
        y: max(0, quartzBbox.origin.y - 50),
        width: quartzBbox.width + 120,
        height: quartzBbox.height + 20
    )
} else {
    ocrRect = quartzBbox
}
```

Nearest-line filter (single line kept when OCR returns >1 for an
underline). Stroke mid-Y is in Quartz coords; the OCR line bounds are in
image-local pixel coords (per `OCRCapture.swift` header), so the port
recovers `backingScale = image_h / ocrRect_h` and translates the stroke
midpoint into image space before comparing:

```
strokeMidImage = (strokeMidQuartz - ocrRect.origin.y) * backingScale
```

Matches Everywhere `WhiteboardHotkeyInitializer.cs:1319-1320` where the
same `scaleY = pxH / DIP_h` factor is applied for the OCR crop.

Auto-capture: previously `if !regions.isEmpty { await
OpenClickyContextStashWriter.shared.captureAsync() }` — this already
matched Everywhere `cs:735`. Round-2 only adds the debug log around it.

Debug logs added (all `HeyClickyLog.log` lane=`system`):

| Event | Fields |
|-------|--------|
| `openclicky.whiteboard_overlay.stroke_captured` | `stroke_index`, `first_pt_x`, `first_pt_y`, `last_pt_x`, `last_pt_y`, `point_count`, `screen_index` |
| `openclicky.whiteboard_overlay.stroke_bbox_quartz` | `stroke_index`, `quartz_x`, `quartz_y`, `quartz_w`, `quartz_h` |
| `openclicky.whiteboard_overlay.stroke_classified` | `stroke_index`, `kind`, `confidence` (placeholder 1.0 — Everywhere sets true confidence in Snap) |
| `openclicky.whiteboard_overlay.ocr_band` | `stroke_index`, `band_x`, `band_y`, `band_w`, `band_h`, `widened_l`, `widened_r`, `widened_t`, `widened_b` |
| `openclicky.whiteboard_overlay.screenshot_captured` | `stroke_index`, `image_w`, `image_h`, `backing_scale` |
| `openclicky.whiteboard_overlay.ocr_result` | `stroke_index`, `text_len`, `first_line` |
| `openclicky.whiteboard_overlay.nearest_line_filter` | `stroke_index`, `lines_input`, `lines_kept`, `kept_first` |
| `openclicky.whiteboard_overlay.auto_capture_fired` | `region_count` |

Coord conversion mapping (unchanged from earlier rounds, verified this
round):

- `session_stroke_began` converts local NSView point -> Quartz global
  via `Self.toQuartzGlobal(localPoint:view:)` at stroke start. Every
  subsequent point in the same stroke goes through the same helper —
  storage is Quartz global (top-left Y-down) from the moment the point
  hits the classifier.
- Gesture bbox from the classifier is already Quartz global.
- OCR crop (`ScreenshotCaptureEverywhere.captureRegion`) takes a Quartz
  rect and returns a PNG at physical pixel dimensions; NSImage.size
  reports those physical dims, so the backing scale is derived from the
  ratio at OCR time — matches Everywhere `cs:1311-1314`.

### 2. Classifier thresholds (verified, no change)

File: `cursor-buddy/OpenClickyWhiteboardStrokeClassifier.swift`.

All F23-flagged thresholds sit at byte parity with `WhiteboardParser.cs`:

- Min extent `max(w, h) < 5.0 -> .unknown` (parser.cs:128; classifier.swift:155).
- `closure < 0.2 && straight < 0.5 -> .circle` (cs:138; swift:168).
- `straight < 0.3 -> .circle` (cs:139; swift:169).
- `straight > 0.75 -> .underline` (cs:145; swift:170).
- Arrow `headLen / axisLen > 0.95` reject (cs:210; swift:216).
- Arrow `thr = max(15, axisLen * 0.30)` (cs:215; swift:217).
- X mid-coincidence `midDist / avgLen <= 0.3` (cs:175; swift:193).
- X length-ratio band `0.4..2.5` (cs:182; swift:196).
- X angle band `35..145°` (cs:184; swift:198).

No regression introduced by Round 2.

### 3. PickStash (verified, no change)

File: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PickStash.swift`.

Already byte-parity single-slot:

- Line 68 — `private var current: Entry?` (single `Entry`).
- Line 86 — `set` replaces slot; posts `.pickStashDidChange`.
- Line 102 — `take()` reads + clears; posts change.
- Line 134 — `hasFreshPin` honours TTL.
- Line 52 — `defaultTtl: TimeInterval = 5 * 60` matches `TimeSpan.FromMinutes(5)`.
- No `items` array, no accumulator. `grep -r 'PickStash.shared.items'` returns 0.

Notification funnels both Everywhere `Pinned` + `Cleared` events through
one `.pickStashDidChange` posting — matches the roadmap contract for
"fire didChange on write" and keeps the overlay subscriber simple. No
downstream caller depends on distinguishing them (the annotation
overlay's `subscribePickStash` handler queries `hasFreshPin` /
`peek()` on every post).

### 4. AnnotationBadge overlay (verified, no change to structure)

File: `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift`.

Already ties one outline+badge pair to `PickStash.peek()` via
`subscribePickStash`. Because PickStash is single-slot, this
automatically enforces "single badge attached to current pin". No
accumulator to refactor.

- Escape / Cmd+Enter / textarea popup are already routed through
  `BadgePanel.expand()` + `viewModel.commit()` — matches Everywhere
  `AnnotationOverlayWindow.cs` UX.
- Delta-follow via `OpenClickyAXFollower` (F25) — matches the 50ms /
  20fps poll `AnnotationOverlayHost.cs:76`.
- Annotation history accumulates in `AnnotationStash` even as the badge
  hops to a new pinned element — same as Everywhere.

Debug logs added:

| Event | Fields |
|-------|--------|
| `openclicky.annotation_badge.attached` | `anchor_role`, `anchor_title`, `x`, `y` |
| `openclicky.annotation_badge.detached` | `reason` |
| `openclicky.annotation_badge.expanded` | (empty payload) |
| `openclicky.annotation_badge.commit` | `body_len`, `total_annotations` |

### 5. LinkRect harvester debug log

File: `cursor-buddy/OpenClickyLinkRectHarvester.swift`.

Anchor / drag / majority-overlap rule already at byte parity with
`VisualElementContext.LinkRect.LinkRectSession` (F24). Round-2 only adds
one debug log after the walk resolves:

| Event | Fields |
|-------|--------|
| `openclicky.linkrect_harvest.debug` | `drag_quartz_x`, `drag_quartz_y`, `drag_w`, `drag_h`, `candidates_scanned`, `candidates_kept`, `first_link_bounds_x`, `first_link_bounds_y`, `first_link_bounds_w`, `first_link_bounds_h` |

`candidates_scanned` reads `result.candidatesSeen` (walk total);
`candidates_kept` reads `result.picks.count` (post-filter survivors);
`first_link_bounds_*` reads from `session.byUrlBounds.values.first` —
the first surviving link's Quartz bbox.

### 6. Pick overlay hit debug log

File: `cursor-buddy/OpenClickyPickElementOverlay.swift`.

Overlay hit-test logic already stable — Round 2 only adds a debug log
emitted alongside the existing `ax_hit_ok`:

| Event | Fields |
|-------|--------|
| `openclicky.pick_overlay.hit_debug` | `cursor_x`, `cursor_y`, `ax_frame_x`, `ax_frame_y`, `ax_frame_w`, `ax_frame_h`, `panel_frame_x`, `panel_frame_y`, `panel_frame_w`, `panel_frame_h` |

Cursor coords are in Quartz global (as fed into `axPoint`); AX frame is
in AX coords (same origin space); panel frame is in AppKit Cocoa
bottom-left (from `panel?.frame`). Log tail lets us verify the panel
paints at the AX-resolved frame rather than a stale/off-by-flip coord
mismatch.

## Build result

`bash scripts/sign-and-install.sh` -> `** BUILD SUCCEEDED **`. App
installed and reloaded (pid=36644 signed by "OpenClicky Dev Sign").
`swiftc -parse` over each edited file cleared before the full build.

## Constraints observed

- No touch to F27/F28/F26/F31/F32-F36/sensor bridge/hotkey CGEvent tap.
- All macOS 26 SIGABRT guards intact (`canBecomeKey=false`,
  `OpenClickySafeMakeKeyAndOrderFront`, global NSEvent monitors).
- Round-1 whiteboard toggle semantics preserved.
- All overlays keep `NSApp.activate(ignoringOtherApps: true)` on show.

## Follow-ups

1. Region-label positioning offset (Everywhere `AnnotationOverlayWindow.cs`
   badge dx/dy relative to element rect). Openclicky currently positions
   the badge at the top-right of `outline` — visual parity was reviewed
   in F25 and left as-is; a byte-exact port would need
   `AnnotationOverlayWindow.MoveTo` (`AnnotationOverlayWindow.cs:73-140`)
   reproduced in `BadgePanel.moveTo(axRect:)`.
2. Rejected-region / empty-leaf underline widening (Everywhere lines
   531-555). Openclicky's whiteboard path uses one shared OCR call per
   gesture regardless of snap outcome, so the widening happens once and
   both the happy and fallback sub-paths see the widened rect. Byte
   parity of the two code paths independently would require duplicating
   the OCR call; deferred until a specific bug forces it.
3. `stroke_classified.confidence` field is a placeholder (1.0). Real
   parity would come from `AnnotationSnapper.Snap` output; the snapper
   port doesn't yet expose per-gesture confidence back into
   `processAndStash`.
