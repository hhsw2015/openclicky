# Phase 5 — SemanticExtractor port (2026-07-23)

Source: `~/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs`
Revision: `30e03e9dcfdd4247fd679828ed86e9042f32d809`

## Purpose

Everywhere's `SemanticExtractor` runs *after* the ElementIndexer BFS walk
and pulls three "first class" views out of the flat list of
`ElementIndexer.IndexedNode`:

1. `ExtractSelected` — every node with `VisualElementStates.Selected`.
2. `ExtractFocused` — the deepest node with `Focused` (walking up the
   ancestor chain would repeat the flag from `window -> pane -> list ->
   row -> cell`, so leaf-only is emitted).
3. `BuildFocusedPath` — that same deepest focused node, plus every
   parent hop by `ParentIndex`, reversed so `[0]` is the root. Powers
   the "you are inside Downloads -> TreeView -> Panel: README.md"
   breadcrumb the agent uses for orientation.

Each output element is a `SemanticItem`:
```
{ element_index, type, text?, states?, available_actions? }
```

- `type` is the stringified `VisualElementType` enum name.
- `text` cascade: `Name` -> `GetText(200)` -> nested label descendant
  (`FindLabelTextInChildren`, depth 3, first `Label` child wins).
- `states` is the list of enum flag names on
  `VisualElementStates`.
- `available_actions` is a role-driven suggestion table (Button/Link
  -> click, TextEdit -> set_value, ListView -> scroll+expand, …).

## Port shape in Swift

openclicky does NOT port `ElementIndexer` — per
`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` L11-16 the full AX tree
walk is delegated to `open-codex-computer-use`. That means we can't
consume `IndexedNode` directly.

Instead the Swift port operates against raw `AXUIElement` refs and
uses the native AX APIs Everywhere would have consumed one level lower:

- `kAXFocusedUIElementAttribute` on the app AX element supplies the
  deepest-focused leaf directly (macOS AX guarantees this — the same
  value Everywhere's ElementIndexer would have identified as
  "deepest with Focused flag").
- `kAXParentAttribute` walks the ancestor chain, one hop per call,
  mirroring the `ParentIndex` dictionary lookup in
  `BuildFocusedPath`.
- `kAXChildrenAttribute` supplies the labelled-descendant fallback
  (`FindLabelTextInChildren`, depth 3).

The `SemanticNode` struct carries the same field shape as
`SemanticItem`, minus `element_index` — openclicky has no index space
because there is no pre-walked flat list. Callers that need to
cross-reference back into an AX tree hold their own `AXUIElement`
handle; the struct is Codable so a downstream JSON envelope can
map `type` / `text` / `states` / `available_actions` verbatim.

### Public API

```
public enum SemanticExtractor {
    // Everywhere: BuildFocusedPath(IReadOnlyList<IndexedNode>)
    // -> single call, walks kAXFocusedUIElement + kAXParent chain.
    public static func focusedPath(pid: pid_t) -> [SemanticNode]

    // Everywhere: ExtractFocused(IReadOnlyList<IndexedNode>)
    // -> just the leaf, top of the chain returned above.
    public static func focused(pid: pid_t) -> SemanticNode?

    // Selection extraction is not directly exposed by AX at the
    // "walk a tree and pick nodes with .Selected" grain we would
    // need. Everywhere's ExtractSelected consumes the flat list; on
    // openclicky the equivalent capability lives on the AX children
    // of the focused element (AXSelectedRows / AXSelectedChildren
    // / AXSelectedText). Ship as a nil-return stub that documents
    // the deviation; callers already have SelectedTextCapture for
    // the primary use case.
    public static func selected(pid: pid_t) -> [SemanticNode]
}
```

### Behavioural parity

| Everywhere step | Swift port |
|---|---|
| `VisualElementStates.Focused` on IndexedNode | `kAXFocusedAttribute` bool on the AX element |
| `deepest` node with Focused | `kAXFocusedUIElement` from `AXUIElementCreateApplication(pid)` |
| Walk `ParentIndex` back to root | Walk `kAXParent` back to app / systemwide sentinel |
| `Reverse()` before returning | Same |
| `Element.Type.ToString()` | AX role -> VisualElementType-name string via 1:1 mapping table copied from `AXUIElement.cs:120-213` |
| `StatesToList` | Read AX bool attributes -> string list. Names match `VisualElementStates.ToString()` |
| `SuggestActions(type)` | Identical switch table, keyed on the mapped type string |
| `BuildItem.Name` cascade | AXTitle -> AXDescription -> AXHelp -> label-bearing role AXValue -> first `AXStaticText` descendant (depth 3) |

### Depth / safety guards

- Chain length capped at 32 (Everywhere never sets an explicit cap
  but ElementIndexer's `AccessibilityTreeMaxDepth` default is 12; we
  triple it so nested SwiftUI generic containers don't get truncated).
- Per-element `visited` set on the underlying element handle keyed by
  `AXUIElementCreateApplication`-scoped identity via `CFHash`, to
  guard against AX wrappers that hand out parent=self loops (matches
  Everywhere's `seen` HashSet in `ElementIndexer.Walk` L67-69).

## Files touched

- `Sources/OpenClickyContextService/Capture/SemanticExtractor.swift` (new)
- `Sources/OpenClickyContextService/Types/CaptureTypes.swift` (append
  `SemanticNode` + `SemanticFocusPath`)
- `Tests/OpenClickyContextServiceTests/SemanticExtractorTests.swift` (new)

No other capture files touched. Per project rules the header of each
new Swift file carries the `// Ported from Everywhere: ... @<rev>`
marker.
