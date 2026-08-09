# Phase 7 StashTools Impl Notes (2026-07-23)

## Ground truth

Everywhere source pinned @ 30e03e9dcfdd4247fd679828ed86e9042f32d809:
- `src/Everywhere.Mcp/Tools/ReadPickTool.cs`
- `src/Everywhere.Mcp/Tools/AddAnnotationTool.cs`
- `src/Everywhere.Mcp/Tools/ReadAnnotationsTool.cs`
- `src/Everywhere.Mcp/Tools/ClearAnnotationsTool.cs`
- `src/Everywhere.Mcp/Tools/ReadWhiteboardTool.cs`
- `src/Everywhere.Mcp/Tools/ReadWhiteboardImageTool.cs`

## Everywhere semantics per tool

### ReadPickTool

- `stash.Take()` on `PickStash` (consuming read).
- If nil -> return `{pinned:false, picked_index:null, app:null, element:null}`.
- Else walks AX subtree via `ElementIndexer.Walk(picked)`, resolves mode
  (`auto|links|text|full`) via `ResolveMode`:
  - `auto` picks `links` when hyperlink count >= 3 AND >= 30 percent nodes,
    else `full`.
  - Explicit `links|text|full` respected.
- For `links|text` renders markdown inline in `element` dict alongside
  `app`, `window_title`, `mode`, `markdown`.
- For `full` returns `FocusedContextResult` with `TreeText` +
  optional `TreeJson` when `include_tree_json=true`.
- Envelope: `{pinned:true, picked_index:<int>, app:<key>, mode:<resolved>, element:{...}}`.

### AddAnnotationTool

- Args `source` (string), `body`, `anchor_label`, optional `anchor_ref`.
- Validates `source` against `AnnotationSource` enum (pin|whiteboard|selected|linkrect).
- `body`/`anchor_label`/`anchor_ref` trimmed; empty strings rejected.
- `stash.Add(new AnnotationItem(...))` — throws on oversize / queue depth.
- Returns `{queued:<int>}` = post-insert live count.

### ReadAnnotationsTool

- Peek (does NOT consume). Each entry `{source, body, anchor_label, anchor_ref, captured_at}`.
- Wire `source` via `SourceToWire`: `Pin->pin`, `Whiteboard->whiteboard`,
  `Selected->selected`, `LinkRect->linkrect`.
- Returns `{count, annotations:[...]}`.

### ClearAnnotationsTool

- Reads `annotations.Count`, calls `Clear()`.
- Returns `{cleared:<int>}` (pre-clear count).

### ReadWhiteboardTool

- `stash.Take()` on `WhiteboardStash` — consumes regions but leaves image
  side-table untouched (image_ids survive TTL).
- If nil -> `{drawn:false, region_count:0, markdown:null}`.
- Else builds markdown with one `## Region N (kind, N leaves, [N images,]
  confidence X.XX)` header per region, followed by de-duped leaf text.
- Kind label mapping: `Circle="circle = emphasis"`, `Underline="underline
  = focus on a single line"`, `Arrow="arrow = pointing at this leaf"`,
  `X="x = strike-through / exclude"`.
- Envelope: `{drawn:true, region_count, app, markdown}`.

### ReadWhiteboardImageTool

- Looks up by `image_id` via `stash.PeekImageBytes(image_id)`.
- Returns raw PNG bytes wrapped in `ImageContentBlock.FromBytes(bytes, "image/png")`.
- Bytes live 5 minutes after `set()` (shared TTL).

## Swift port design

### File placement

Public surface: `Meta/OpenClickyStashTools.swift`. Enum with static methods
in the same style as `OpenClickyMemoryTools` — every method takes optional
trailing stash parameters defaulting to the `.shared` singletons so tests
can inject their own instances without touching global state.

Return types added to `Types/CaptureTypes.swift`:
- `ReadPickResult(pinned, pickedIndex, app, element, treeJson, consumedPin)`
- `ReadWhiteboardResult(drawn, regionCount, markdown, consumed)`
- `AnnotationOpResult(ok, count)`

All three `Codable, Sendable`. Field names camelCase Swift-side; wire
snake_case (`picked_index`, `region_count`, `consumed_pin`) via `CodingKeys`.

### Deviations vs Everywhere

- `PickedElement` in the Swift port is a lightweight value snapshot (no
  live AX ref), so `ElementIndexer.Walk` / `SnapshotRenderer` / semantic
  enricher are unavailable at `read_pick` time. The `element` dict
  surfaces the fields the snapshot already carries: `role`, `name`,
  `value`, `bounds`, `app` (bundleId). Mode resolution collapses to
  "return whatever the snapshot has"; no subtree walk to count
  hyperlinks. `mode` still round-trips in the returned struct so the
  bridge layer can echo it to callers.
- `include_tree_json` — when true, emit a JSON encoding of the single
  `PickedElement` as `treeJson`. No pre-walked node list to serialise.
- `consumedPin` — surfaced explicitly in the return struct so callers
  (and tests) can differentiate empty-stash reads from consumed reads
  without a second `hasFreshPin` probe. Not present in Everywhere; it is
  an artifact of the boolean-returning `Take()` semantics.
- `readAnnotations` returns `[AnnotationItem]` directly (peek-not-consume).
  Callers wanting the wire envelope `{count, annotations:[...]}` build it
  themselves; the pure-value surface makes tests independent of
  JSON encoding.
- `clearAnnotations` returns `AnnotationOpResult(ok:true, count:<cleared>)`.
- `readWhiteboardImage(imageId:)` parses the string as `UUID` and returns
  `nil` on unparseable or missing bytes. Everywhere keys by string; the
  Swift stash keys by `UUID` (see `WhiteboardStash.swift` header).

### Rendering rules

- Markdown per region: `"## Region N (kind-label, N leaf(-es)[, N
  image(-s)], confidence X.XX)\n\n"` + de-duped OCR text (leaf text is
  not available in the Swift stash snapshot; we fall back to
  `ocrText` when present).
- If a region carries `ocrText == nil` and no dedicated leaf table, we
  emit only the header (mirrors Everywhere's `(empty-text leaf ...)`
  fallback semantically — the agent still knows the region exists).

### Tests (Tests/OpenClickyContextServiceTests/OpenClickyStashToolsTests.swift)

1. `test_readPick_emptyStash_returnsPinnedFalse`
2. `test_setPick_thenReadPickAuto_returnsElement_andConsumes`
3. `test_addAnnotation_appendsOne_readAnnotationsReturnsOne`
4. `test_clearAnnotations_dropsAll`
5. `test_readWhiteboard_threeRegions_returnsThreeMarkdownBlocks_andConsumes`
6. `test_readWhiteboardImage_unknownId_returnsNil`

Every test builds fresh stash instances (never touches `.shared`) using
injectable clocks and `NotificationCenter()` isolation.
