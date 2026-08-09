# Whiteboard AX-snap port plan (Everywhere @30e03e9d -> OpenClicky)

Design report only. No code changes yet. Everywhere pin `30e03e9dcfdd4247fd679828ed86e9042f32d809`.

## 1. `SnapAsync` (actually `Snap`) algorithm — inputs, output, AX attributes

Entry point is `AnnotationSnapper.Snap` at `Everywhere.Mcp/Whiteboard/AnnotationSnapper.cs:39-53`. It is synchronous (no `Async` suffix in the C#). Signature:

```
static SnapResult Snap(
    Annotation ann,             // kind + parser-derived boundingRect
    IVisualElement root,        // focusedRoot (top-level app AX element)
    IReadOnlyList<Stroke> strokes, // this annotation's strokes only, NOT session strokes
    PrewarmedTree? prewarmed = null)
```

Return is `SnapResult` (`Everywhere.Core/Interop/Whiteboard/SnapResult.cs:11-22`): `Rect` (union of chosen leaves, padded), `Leaves` (Label/Hyperlink/Image AX nodes captured), `Rejected` + `RejectReason`, `Confidence` in [0.3, 1.0], `Diagnostics` string.

AX attributes/fields the walk reads (via `IVisualElement`):
- `Type` (mapped role: `Label`, `Hyperlink`, `Image` — see `AXUIElement.cs:126-183` role table).
- `BoundingRectangle` (Quartz `AXPosition` + `AXSize` -> `PixelRect`, `AXUIElement.cs:448-465`).
- `Children` (raw `AXChildren`, `AXUIElement.cs:27-90`).
- `GetText(maxLength)` (name cascade: `AXTitle` -> `AXDescription` -> `AXHelp` -> role-gated `AXValue` -> `AXTitleUIElement` -> first `AXStaticText` child -> `AXIdentifier`, `AXUIElement.cs:257-315`).

`LeafTextRoles = { Label, Hyperlink }` (`AnnotationSnapper.cs:20-24`). `LeafTextOrImageRoles = { Label, Hyperlink, Image }` (`:32-37`) is used by Circle/X only.

## 2. Per-kind branches inside `AnnotationSnapper.cs`

| Kind | Branch | Range | Core rule |
|------|--------|-------|-----------|
| Arrow | `SnapArrow` | `:67-213` | Identify tip by geometry (2-stroke: axis endpoint nearest head-V midpoint, `IdentifyArrowTip :223-241`); prefer leaf AT tip via `LeafAtPoint`, else `NearestLeaf` within 100px; row-slice a tall multi-line leaf via `TightenLeafToTip :250-260`; reject if bestDist > 100. |
| Underline | `SnapUnderline` | `:280-380` | Compute stroke top/bottom + x-span; call `CollectUnderlineCandidatesV` above (:305) then below fallback (:326) — 80px vertical gap max, 15px jitter tolerance, x-overlap ≥50% of stroke OR (short-leaf case) ≥50% of leaf; pick nearest gap band. |
| Circle / X | `SnapCircleOrX` | `:445-547` | Three passes: strict containment (:463) -> ≥50% vertical overlap (:479) -> ≥50% total overlap ratio (:499). Falls through to `NearestLeaf` within 120px. Sanity gate: leafArea (excluding Images) must not exceed 4× gesture area with >8 leaves (:531-542). |

Kinds are dispatched by `Annotation.Kind` (`AnnotationKind` enum: `Circle`, `Underline`, `Arrow`, `X`, `Unknown`). Everywhere reuses the Circle branch for X (`:49-50`).

## 3. AX walk budget / breadth control

Three defenses stacked (`AnnotationSnapper.cs`):

- **Rect-pruned DFS.** `DescendantsInRect` (`:820-868`) skips subtrees whose own bbox has non-zero size and doesn't intersect `query` expanded by `slack` (default 8 px, 2 px for `LeafAtPoint`, 0 for `NearestLeaf`). Empty-bbox nodes (Chromium wrappers) still recurse; leaf-role nodes never recurse (`:844-846`) — this alone kills the "million per-glyph child" walk explosion.
- **Per-call visit caps.** Every hot loop has `if (walked > 5000) break;` (`:454`, `:481`, `:502`, `:566`, `:600`, `CollectUnderlineCandidatesV` totalWalked>5000 at `:405`).
- **`PrewarmedTree` snapshot** (`:647-812`). Built once when the overlay appears via `PrewarmedTree.Build(root, ct)` capped at 25 000 total visited nodes (`:703`). Emits only leaf-role nodes (`:727-729`) plus two `HashSet<IVisualElement>` sidecars (`HyperlinkHasImage`, `HyperlinkHasText`) for the image-collect phase. Query time is a linear scan of `Nodes` filtered by bbox intersection (`QueryRect :786-811`, yield cap 5 000). When prewarm returns empty for a specific point, Snap falls back to a live rect-pruned walk over the same small query rect ("prewarm-miss fallback", e.g. `:142-146`).

The prewarm is scheduled on `WhiteboardHotkeyInitializer.cs` around line 440-458 with an 8 s safety await; if it exceeds, snap runs against the live tree.

## 4. Merge policy (AX leaves vs OCR lines)

Both channels are kept side-by-side, not merged — see `WhiteboardHotkeyInitializer.cs:596-688`:

1. Run `AnnotationSnapper.Snap` -> `snap.Leaves` (text) + optional `imageLeavesFromSnap`.
2. Run OCR on a per-kind cropped bitmap (`:596-603`; Underline widens +60L/+60R/+50T/+20B).
3. For Underline, if OCR returned >1 line, keep only the row whose vertical mid is nearest the stroke's mid Y (`:609-624`).
4. Filter Image-type nodes out of `textLeaves` (`:641`) so downstream text join isn't polluted.
5. Emit `new WhiteboardRegion(kind, ann.BoundingRect, textLeaves, snap.Confidence, ocrLines, imageLeaves)` (`:686-688`).

**AX wins as the primary text channel** — `textLeaves` is what the read tool concatenates. OCR is kept in the region so the downstream `HybridSlicer` can slice a giant multi-line Label by user gesture rect and so agents that need per-row bboxes have them. When AX rejects with zero leaves (`:509-568`), the fallback path is a cropped screenshot image + OCR-on-gesture-rect; even then it does not attempt to reconstruct AX leaves.

## 5. Coordinate contract

All coordinates in the snap pipeline are **Quartz screen points, top-left origin** — i.e. AppKit-flipped, same space that `AXPosition`/`AXSize` return natively on macOS. `ToRect(pr)` at `AnnotationSnapper.cs:637` is `new Rect(pr.X, pr.Y, pr.Width, pr.Height)`, no transform. Strokes come in the same space (see `WhiteboardHotkeyInitializer` capture path). OCR bboxes are in bitmap pixel space but the "nearest line" filter (:611-618) re-projects the stroke mid via the bitmap-to-region backing scale before comparing.

OpenClicky already agrees: `OpenClickyWhiteboardSessionStroke.quartzPoints` are Quartz global, and `OpenClickyWhiteboardOverlayWindow.processAndStash` already treats `gesture.boundingBox` as Quartz global (see `:606-619`). No unit conversion needed.

## 6. Reusable OpenClicky code

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ElementUnderCursorCapture.swift` — has `readBounds(from:)` (`:235-257`) which is a 1:1 port of `QueryBoundingRectangle` — reuse directly.
- `FocusedElementCapture.swift:225-251` — has raw `AXChildren` reader that skips the Rows/VisibleChildren fan-out (matches what Everywhere's snapper needs).
- `FocusedElementCapture.swift` `readString`/`readValueRaw` — reuse for `GetText` cascade.
- `SemanticExtractor.swift` role-mapping switch (constants at :103, mapping around Everywhere's `AXUIElement.cs:126-183`) — reuse to derive a `VisualElementType`-shaped Swift enum (only need Label/Hyperlink/Image/other).
- `OpenClickyWhiteboardStrokeClassifier.swift` — already ports `WhiteboardParser`, emits Quartz bboxes; feeds the new snapper unchanged.
- `OCRCapture.swift`, `ScreenshotCaptureEverywhere.swift`, `WhiteboardStash.swift` — the OCR fallback path is already there; keep as post-snap merge, not primary.
- `FocusedWindowCapture.swift:100` — gives us the focused-window AX element that becomes `focusedRoot`.

## 7. Estimated LOC and file plan

Files to create under `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Whiteboard/` (new dir):

- `AXVisualElement.swift` — thin wrapper around `AXUIElement` exposing `type: VisualElementType`, `boundingRect: CGRect`, `children: [AXVisualElement]`, `getText(maxLength:)`. ~180 LOC.
- `PrewarmedTree.swift` — Everywhere `AnnotationSnapper.PrewarmedTree` (`:647-812`). ~180 LOC.
- `AnnotationSnapper.swift` — full port of `AnnotationSnapper.cs` (881 lines). Idiomatic Swift with tuples reduces slightly. ~700 LOC.
- `SnapResult.swift`, `Annotation.swift`, `Stroke.swift` structs. ~80 LOC total.
- `WhiteboardSnapOrchestrator.swift` — port of the `WhiteboardHotkeyInitializer.cs` snap-then-OCR loop (:461-700 relevant slice). ~250 LOC.

Files to edit:

- `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` — replace `processAndStash` body (`:588-783`) with a call into `WhiteboardSnapOrchestrator`. Net delta ~-120 / +40 LOC.
- `Packages/.../Types/CaptureTypes.swift` — extend `WhiteboardRegion` with `Leaves: [WhiteboardLeaf]` (text + optional AX id) so downstream stash tools can distinguish snap-hits from OCR-only. ~30 LOC.

**Total new LOC ~1400, deletions ~120, one new package sub-module.** Two test fixtures required: (a) circle-over-Label, (b) arrow-into-multiline-Label, driven by a fake `AXVisualElement` protocol implementation (mirrors Everywhere's `whiteboard-sandbox` tests). No `xcodebuild` from CLI (project rule) — verify via `swiftc -parse` on the new files.
