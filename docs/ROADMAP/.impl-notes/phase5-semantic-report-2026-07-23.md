# Phase 5 — SemanticExtractor port report (2026-07-23)

## Scope

Ported `~/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs`
@30e03e9d to
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SemanticExtractor.swift`,
with wire-shape types (`SemanticNode`, `SemanticFocusPath`) appended to
`Types/CaptureTypes.swift`. XCTest coverage lives in
`Tests/OpenClickyContextServiceTests/SemanticExtractorTests.swift`.

Corresponds to row 26 in `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`
(`SemanticExtractor (焦点路径)` — P1).

## Step 1: Investigation

Everywhere's `SemanticExtractor` operates on the flat
`ElementIndexer.IndexedNode[]` that the BFS walk hands it, and emits
three "first-class" views:

- `ExtractSelected` — every node with `VisualElementStates.Selected`.
- `ExtractFocused` — the single deepest node with `Focused` (walking up
  would repeat the flag from `window -> pane -> list -> row -> cell`).
- `BuildFocusedPath` — that same leaf plus every ancestor via
  `ParentIndex`, reversed so index 0 is the outermost ancestor. Powers
  the "you are inside Downloads -> TreeView -> Panel: README.md"
  breadcrumb.

Each output element is a `SemanticItem`:
```
{ element_index, type, text?, states?, available_actions? }
```
- `type` — stringified `VisualElementType` enum name.
- `text` — cascade `Name` -> `GetText(200)` -> first labelled child (depth 3).
- `states` — string list of `VisualElementStates` flag names.
- `available_actions` — role-driven suggestion table.

Details in `phase5-semantic-2026-07-23.md`.

## Step 2: Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 26 already declares the
port target as `Capture/SemanticExtractor.swift`. No doc edit required.
Roadmap L11-16 explicitly delegates the full AX tree walk to
`open-codex-computer-use` so `ElementIndexer` is not ported; the Swift
`SemanticExtractor` therefore operates directly on `AXUIElement` refs
instead of consuming an `IndexedNode[]` — this deviation is documented
inline in both `SemanticExtractor.swift` and the
`SemanticNode`/`SemanticFocusPath` doc comments in `CaptureTypes.swift`.

## Step 3: Implementation

Files:
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SemanticExtractor.swift` (new, 415 lines).
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended `SemanticNode` + `SemanticFocusPath`).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/SemanticExtractorTests.swift` (new, 15 tests).

Each file carries the `// Ported from Everywhere: ... @30e03e9dcfdd4247fd679828ed86e9042f32d809` header.

Public Swift API:
```
public enum SemanticExtractor {
    public static func focusedPath(pid: pid_t) -> SemanticFocusPath
    public static func focused(pid: pid_t) -> SemanticNode?
    public static func selected(pid: pid_t) -> [SemanticNode]
}
```

Internals mirror the C# 1:1:
- Role -> `VisualElementType` name mapping is a verbatim switch
  translation of `AXUIElement.Type` (AXUIElement.cs:120-213), kept
  case-per-case so drift shows up as a diff line.
- State reading matches `AXUIElement.States` (AXUIElement.cs:228-251):
  `AXEnabled -> Disabled`, `AXSelected`, `AXExpanded`, `AXFocused`,
  `AXHidden -> Offscreen`, `AXSubrole == AXSecureTextField -> Password`,
  and toggled `AXValue` on checkbox/radio -> `Checked`.
- Name cascade matches `AXUIElement.Name` (AXUIElement.cs:257-315):
  `AXTitle -> AXDescription -> AXHelp` -> label-bearing role
  `AXValue`/`AXTitleUIElement`/first `AXStaticText` child ->
  `AXIdentifier`.
- Label-descendant fallback matches
  `SemanticExtractor.FindLabelTextInChildren` (depth 3).
- Action suggestion table matches `SemanticExtractor.SuggestActions`
  (SemanticExtractor.cs:111-138).

Deviations vs Everywhere:
- Everywhere operates on a pre-walked `IndexedNode[]`; openclicky
  operates on raw `AXUIElement`. Consequences:
  - `focused_path` uses `kAXFocusedUIElement` + `kAXParent` walk
    (macOS AX exposes exactly the leaf Everywhere would identify
    from the flat list, and `kAXParent` is a 1:1 substitute for
    `ParentIndex`).
  - `ExtractSelected` maps to `kAXSelectedRows` / `kAXSelectedChildren`
    on the focused container — the closest AX-level analogue when
    there is no pre-walked list to filter. Documented in the method
    doc comment.
  - No `element_index` field in `SemanticNode` (no index space to
    point back into). Everywhere's snake_case wire keys (`type`,
    `text`, `states`, `available_actions`) are preserved via
    `CodingKeys`.
- Depth cap of 32 on the ancestor walk (Everywhere caps indirectly via
  `ElementIndexer.AccessibilityTreeMaxDepth = 12`; we triple for
  SwiftUI generic-container nesting). CFHash-based visited set guards
  against `parent = self` loops (1:1 with `seen` HashSet<ulong> in
  `ElementIndexer.Walk`).

## Step 4: Alignment audit (SemanticExtractor.cs vs .swift)

| C# method | Swift analogue | Status |
|---|---|---|
| `ExtractSelected(IReadOnlyList<IndexedNode>)` | `selected(pid:)` | Behavioural match (AX-level per-container selection). Documented deviation. |
| `ExtractFocused(IReadOnlyList<IndexedNode>)` | `focused(pid:)` | 1:1 (`kAXFocusedUIElement` gives the leaf). |
| `BuildFocusedPath(IReadOnlyList<IndexedNode>)` | `focusedPath(pid:)` | 1:1 (`kAXParent` walk + reverse). |
| `BuildItem(IndexedNode)` | `buildItem(for:)` | 1:1 name cascade + states + actions. |
| `StatesToList(VisualElementStates)` | `statesList(for:)` | 1:1 enum name list; omits nil when empty. |
| `SuggestActions(VisualElementType)` | `suggestActions(for:)` | 1:1 switch table, keyed on mapped type string. |
| `FindLabelTextInChildren(element, maxDepth)` | `findLabelTextInChildren(of:maxDepth:)` | 1:1, depth 3, first `Label` wins. |

Wire shape: `SemanticNode` reproduces every field on `SemanticItem`
minus the dropped `element_index`. `available_actions` snake_case is
enforced by CodingKeys; regression-covered by
`test_semanticNode_usesSnakeCasedActionsKey`.

## Step 5: Test

Ran (from `Packages/OpenClickyContextService`):
```
swift test --filter SemanticExtractorTests
```
Result: 15 tests, 1 skipped (gated live-frontmost test — needs AX
consent), 0 failures. Verified explicitly:

- `test_focusedPath_returnsEmpty_forZeroPid`
- `test_focusedPath_returnsEmpty_forNegativePid`
- `test_focusedPath_returnsEmpty_forBogusPid`
- `test_focusedPath_returnsEmpty_forTestHost`
- `test_focused_returnsNil_forZeroPid`
- `test_focused_returnsNil_forBogusPid`
- `test_selected_returnsEmpty_forZeroPid`
- `test_selected_returnsEmpty_forBogusPid`
- `test_focusedPath_isBounded_forTestHost` (depth cap check)
- `test_focusedPath_forFrontmostApp_producesBoundedPath` (skipped in
  this run — Finder frontmost had no focused element / no AX consent)
- `test_semanticNode_roundTripsJSON_withAllFields`
- `test_semanticNode_omitsNilFieldsInWireForm`
- `test_semanticNode_usesSnakeCasedActionsKey`
- `test_semanticFocusPath_roundTripsJSON`
- `test_semanticFocusPath_emptyNodesRoundTrip`

Ran (from repo root):
```
bash scripts/sign-and-install.sh
```
Result: succeeded — `openclicky pid=43335 identifier=com.jkneen.openclicky
Authority=OpenClicky Dev Sign`.

## Collateral fix

`Sources/OpenClickyContextService/Memory/MemoryStore.swift:55` had a
pre-existing compile error (`covariant 'Self' type cannot be referenced
from a default argument expression`) that blocked module compilation.
Replaced `Self.currentMillis()` with `MemoryStore.currentMillis()` in
the default argument. This is the minimum needed for the module to
build; MemoryStore is otherwise untouched by this port.

## Do-not-touch verification

- Other `Capture/*.swift` files: unchanged.
- Bridge / config / stash writer: unchanged.
- `Types/CaptureTypes.swift`: appended only (new
  `SemanticNode` + `SemanticFocusPath` at the end); no existing types
  modified.
