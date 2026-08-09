# Phase 7 StashTools Report (2026-07-23)

## Deliverables

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyStashTools.swift`
  — new enum with six static methods mounting the Layer-4 UX stash tools.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  — appended `ReadPickResult`, `ReadWhiteboardResult`, `AnnotationOpResult`
  (snake_case wire, camelCase Swift via `CodingKeys`).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OpenClickyStashToolsTests.swift`
  — 11 XCTest cases covering read/consume/peek/clear + TTL-independent
  isolation via injected clocks and `NotificationCenter()`.
- Impl notes: `docs/ROADMAP/.impl-notes/phase7-stashtools-2026-07-23.md`.

## Public API

```swift
OpenClickyStashTools.readPick(mode: "auto",
                              includeTreeJson: false,
                              stash: PickStash = .shared) -> ReadPickResult
OpenClickyStashTools.addAnnotation(source: "pin",
                                   body: "…",
                                   anchorLabel: "…",
                                   anchorRef: "…"?,
                                   stash: AnnotationStash = .shared) -> AnnotationOpResult
OpenClickyStashTools.readAnnotations(stash: AnnotationStash = .shared) -> [AnnotationItem]
OpenClickyStashTools.clearAnnotations(stash: AnnotationStash = .shared) -> AnnotationOpResult
OpenClickyStashTools.readWhiteboard(stash: WhiteboardStash = .shared) -> ReadWhiteboardResult
OpenClickyStashTools.readWhiteboardImage(imageId: "…",
                                         stash: WhiteboardStash = .shared) -> Data?
```

Ready for the bridge patch to mount at `/mcp/sensor`.

## Alignment audit vs Everywhere @30e03e9d

| Everywhere tool | Wire semantic | Swift port | Fidelity |
|---|---|---|---|
| `read_pick` empty | `{pinned:false, picked_index:null, app:null, element:null}` | `ReadPickResult(pinned:false, …nil)` | 1:1 |
| `read_pick` populated | `{pinned:true, picked_index:<int>, app, mode, element:{…}}` | `ReadPickResult(pinned:true, pickedIndex:<mode>, app, element:{role,title,value,bundle_id,pid,bounds,mode[,markdown]})` | value-snapshot substitution — see Deviations |
| `mode` resolution | `auto` picks `links` when >=3 hyperlinks AND >=30% nodes | `auto → full` (no tree walk in Swift snapshot) | documented deviation |
| `include_tree_json` | `TreeJsonBuilder.Build(nodes)` | `JSONEncoder().encode(PickedElement)` (single-node) | scoped substitution |
| `add_annotation` | Trims, validates, `stash.Add`, returns `{queued}` | Same trim/validate; `stash.append`; returns `AnnotationOpResult(ok:true, count:<queued>)` | 1:1 semantics; envelope collapsed |
| `add_annotation` invalid source | `ToolErrors.Error(...)` | `ok:false, count:<current>` | non-throwing surface for bridge |
| `read_annotations` | peek-not-consume, `{count, annotations:[…]}` | `[AnnotationItem]` (bridge wraps envelope) | 1:1 |
| `clear_annotations` | pre-clear count → `{cleared}` | `AnnotationOpResult(ok:true, count:<pre-clear>)` | 1:1 |
| `read_whiteboard` empty | `{drawn:false, region_count:0, markdown:null}` | `ReadWhiteboardResult(drawn:false, regionCount:0, markdown:"", consumed:false)` | 1:1 (empty string in place of null) |
| `read_whiteboard` header | `## Region N (kind-label, N leaves[, N images], confidence X.XX)` | `## Region N (kind-label, 1 leaf)` | header shape preserved; leaf-count fixed at 1 because Swift snapshot has no per-region leaf table |
| kind label mapping | 4-way switch → strings | identical strings | 1:1 |
| empty-text fallback | `(empty-text leaf at X,Y WxH)` | identical marker | 1:1 |
| `read_whiteboard_image` | `stash.PeekImageBytes(id)` → `ImageContentBlock` | `stash.imageBytes(for: UUID)` → `Data?` | 1:1 (bridge base64-encodes for MCP) |
| image bytes survive region take | yes | yes (via `WhiteboardStash.take()` leaving side-table alone) | 1:1 |

Documented deviations from Everywhere (all captured in impl notes):
1. `readPick` operates on the `PickedElement` value snapshot rather than
   a live AX ref — no `ElementIndexer.Walk`, so `auto` collapses to
   `full` and `mode=links|text` renders a single-line skill-style
   marker instead of a full subtree walk.
2. `includeTreeJson` serialises the single-node snapshot as JSON.
3. Every method surfaces a Swift-native return struct instead of
   `CallToolResult` — the bridge (Phase 2) is responsible for the
   `TextContentBlock`/`ImageContentBlock` envelope on the wire.
4. `AnnotationOpResult` collapses `{queued:<int>}` (add) and
   `{cleared:<int>}` (clear) to one `{ok, count}` shape.
5. `consumedPin` (readPick) and `consumed` (readWhiteboard) are
   Swift-side convenience flags for tests / callers.

## Doc reconciliation

`docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` already documents the six tools
in the tool matrix (lines 44-121) and in the Core/Hidden tier lists
(lines 238-239). No doc edits required — the roadmap entries match the
signatures shipped in this patch.

## Test results

```
$ cd /Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService
$ swift test
… Executed 460 tests, with 8 tests skipped and 0 failures …
Test Suite 'OpenClickyStashToolsTests' passed at 2026-07-23 01:01:43.577
```

11/11 new tests pass, full package green (0 failures across 460).

## Files touched (delta only)

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyStashTools.swift`
  (new)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  (appended `ReadPickResult`, `ReadWhiteboardResult`, `AnnotationOpResult`)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OpenClickyStashToolsTests.swift`
  (new)
- `docs/ROADMAP/.impl-notes/phase7-stashtools-2026-07-23.md` (new)
- `docs/ROADMAP/.impl-notes/phase7-stashtools-report-2026-07-23.md` (new, this file)

Not touched (per constraints): existing capture / stash files,
`OpenClickyExternalControlBridge.swift`, `Package.swift`, route dispatcher,
stash writer, config template.
