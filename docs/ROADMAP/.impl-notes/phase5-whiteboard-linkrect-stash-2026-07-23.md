# Phase 5 — WhiteboardStash + LinkRectStash impl notes (2026-07-23)

Ground-truth read: `src/Everywhere.Core/Interop/Whiteboard/WhiteboardStash.cs` @30e03e9d.

## WhiteboardStash — key semantics (verified against source)

- `DefaultTtl = TimeSpan.FromMinutes(5)` (line 14) → 300s.
- Single-slot most-recent-wins for regions (`_current: Entry?`).
- Side-table `_imageBytesById: Dictionary<string, byte[]>?` (line 23) with
  its OWN expiry field `_imageBytesExpiresAtUtc` (line 24). Both are set to
  the same expiry timestamp in `Set` (line 62) but they are stored in two
  independent fields so that `Take()` (line 169-178) can clear regions
  without touching the image cache. This is what makes the two-tool flow
  work: `read_whiteboard()` consumes regions → agent learns image_ids →
  `read_whiteboard_image(id)` can still fetch bytes until the shared TTL
  expires (lines 19-24 comment, lines 145-164 `PeekImageBytes`).
- `PeekImageBytes` clears the side-table when TTL is expired (line 158-160,
  lazy expiry).
- `Take()` returns null when expired but does NOT touch the image cache
  (line 176 only inspects `entry.ExpiresAtUtc`, does not reset
  `_imageBytesById`).
- `Clear()` (line 203) drops both region slot and image cache.
- `ClearWithEvent()` (line 217) additionally raises `Cleared` when there
  was a pending session.
- `Drawn` event fires post-`Set` with just the regions handed in.

## Brief-prescribed Swift API

The brief specifies a slimmer public surface than Everywhere: no `Drawn`
event, no `Append`, no `TimeProvider`-style clock injection knob in the
constructor (I'll add a private testable initialiser for TTL tests). The
required surface is:

```
WhiteboardStash.shared
static defaultTtl: TimeInterval  // 300
func set(regions:[WhiteboardRegion], imageBytesById:[UUID: Data])
func peek() -> [WhiteboardRegion]?
func take() -> [WhiteboardRegion]?
func imageBytes(for id: UUID) -> Data?
func clearWithEvent()
var hasPending: Bool
```

`clearWithEvent` posts a Notification on the default center — Swift-native
substitute for C# `event Action? Cleared`.

`WhiteboardRegion` also follows the brief's slim schema (id, bboxScreen,
gestureKind:String, ocrText, capturedAtUnix) rather than the full
Everywhere record (AnnotationKind enum + Leaves + Confidence + OcrLines +
ImageLeaves). The brief is intentionally scoped to Layer-4 stash needs;
the richer Everywhere `WhiteboardRegion` structure lives inside
`Whiteboard/*.swift` in Phase 7 (overlay + gesture classifier), not here.

## LinkRectStash — no separate class in Everywhere

Verified with grep across `src/`: only two hits for `LinkRectStash`:

1. `ContextStashWriter.cs` comment: `"CaptureLinksAsync; nothing to drain
   from a LinkRectStash"` — explicitly documents there is no in-memory
   stash for LinkRect. The harvest path writes directly to
   `context-stash.json` `picked_links[]`.
2. Nothing else — no class definition.

`VisualElementContext.LinkRect.cs` (Everywhere.Mac) contains
`LinkRectSession` which is the overlay + harvest UI, plus `HarvestedLink`
and `HarvestResult` data records. These are harvest primitives, not
stashes.

Decision: **skip `LinkRectStash.swift` file**. The brief permits this and
asks that it be noted in the report. `PickedLinkStashItem` data type is
still appended to `CaptureTypes.swift` per the brief so that the Phase 6
stash writer has a type to reference when serialising harvested links to
`context-stash.json`.

## Doc reconciliation

`docs/ROADMAP/05_LAYER_4_UX.md` line 26-27 already documents:
- Whiteboard stash is memory-only with `DefaultTtl = FromMinutes(5)`.
- `_imageBytesById` side-table with same TTL; `Take()` consuming regions
  leaves PNG bytes alive until TTL expiry.

No doc change required — the Swift port matches the doc.

## Test plan

Per stash:
1. `set` → `peek()` returns regions.
2. `set` → `take()` returns regions; second `peek/take` returns nil.
3. `imageBytes(for: id)` returns Data after `set` and after `take` (survives
   region consumption); returns nil for unknown id.
4. TTL expiry: inject clock, advance past 300s → `peek` and `imageBytes`
   both return nil.
5. `clearWithEvent` posts notification when pending; no-op when empty.
6. `hasPending` reflects state (true after set, false after take/clear).

Test-only clock injection is added via a private designated initialiser
(analogous to `SelectionCache`'s `clock:` parameter).
