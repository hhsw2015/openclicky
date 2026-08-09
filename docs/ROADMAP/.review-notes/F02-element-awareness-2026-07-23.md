# Review F02: Element awareness (focused / at-point / semantic path)

**Everywhere pin**: 30e03e9dcfdd4247fd679828ed86e9042f32d809
**openclicky files**:
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FocusedElementCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/CursorCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ElementUnderCursorCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/SemanticExtractor.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (types `FocusedElementInfo` L1477, `CursorPosition` L1349, `ElementUnderCursorInfo` L1384, `SemanticNode` L2154, `SemanticFocusPath` L2208)

**Everywhere files**:
- `src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs`
- `src/Everywhere.Mcp/Snapshot/SnapshotActionFilter.cs`
- `src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs`
- `src/Everywhere.Mcp/Snapshot/UpstreamConstants.cs`
- `src/Everywhere.Mcp/Tools/Schemas/SemanticItem.cs`
- `src/Everywhere.Mac/Interop/AXUIElement.cs`
- `src/Everywhere.Mac/Interop/AXAttributeConstants.cs`
- `src/Everywhere.Mac/Interop/VisualElementContext.cs`
- `src/Everywhere.Core/Interop/IVisualElement.cs` (`VisualElementStates` enum L61-84)

**Reviewer**: agent (F02 review)
**Date**: 2026-07-23

---

## Alignment Table

### A. Focused element (`FocusedElementCapture.swift` vs `AXUIElement.cs` / `SnapshotRenderer.cs`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Resolution: `AXFocusedUIElement` on `AXUIElementCreateApplication(pid)` | `FocusedElementCapture.swift:79-82` | `VisualElementContext.cs:12` (SystemWide) + per-pid variant via `AXUIElement.cs:1147` `ElementFromPid` | ⚠️ | Swift scopes to pid; Everywhere ships both SystemWide (`VisualElementContext.FocusedElement`) and per-pid (used by AppKey/FreshFocusedWindowOf). Semantic diff — per-pid vs system. Documented in Swift header. |
| pid guard `pid > 0` | L77 | `AXUIElement.cs:467` (`ProcessId` returns 0 sentinel) | ✅ | |
| Missing role → return nil | L84-89 | Everywhere's `Role` getter always populates (`AXUIElement.cs:494-495`; falls back to `AXRoleAttribute.AXUnknown`), never nil-returns the element | ⚠️ | Swift is stricter; empty role yields nil struct. Deviation but safer. |
| Name cascade: Title → Description → Help → (label-bearing) Value → TitleUIElement.Value → TitleUIElement.Title → first-AXStaticText-child → Identifier | L132-160 | `AXUIElement.cs:257-315` (compressed transcript; L268-311) | ✅ | Order and label-bearing gate identical. |
| `IsLabelBearingRole` whitelist: AXButton, AXMenuButton, AXPopUpButton, AXCheckBox, AXRadioButton, AXMenuItem, AXMenuBarItem, AXLink, AXImage, AXDisclosureTriangle, AXCell, AXRow | L163-175 | `AXUIElement.cs:325-335` | ✅ | Exact set match. |
| `TryFirstChildStaticTextValue` — raw AXChildren, max 12 immediate children | L180-206 | `AXUIElement.cs:337-363` (raw `AXChildren`, `seen < 12`) | ✅ | |
| AXCheckBox value coercion: numeric 0 → "false", else "true" (also handled inside `readValueString`) | L214-243 (`readValueString`) | `AXUIElement.cs:549-556` (`GetText`) | ⚠️ | See A.a below — cross-context reuse. |
| Password guard: `subrole == "AXSecureTextField"` → `value = nil` | L91, L98 | `AXUIElement.cs:242` (adds `Password` flag; does NOT null out `Value` — snapshot writer elides downstream) | ⚠️ | Intentional deviation, documented in file header (L28-32) and `CaptureTypes.swift:1465-1468`. Stricter than Everywhere. |
| `SnapshotActionFilter` whitelist: Press, Confirm, Open, ShowMenu, Increment, Decrement, Pick, Cancel, Delete, Raise | L296-299 | `SnapshotActionFilter.cs:17-21` + `AXUIElement.cs:541-547` (`IsMeaningful`) | ✅ | Byte-exact 10-entry set. |
| Action filter: strip `"AX"` prefix, skip empty, dedup order-preserving | L301-321 | `SnapshotActionFilter.cs:27-41` | ✅ | |
| Bounds: `AXPosition` + `AXSize` via `AXValueGetValue(cgPoint/cgSize)`, missing → `.zero` | L328-348 | `AXUIElement.cs:448-465` (`QueryBoundingRectangle`, `return default`) | ✅ | |
| `readBool` accepts both CFBoolean and CFNumber-as-bool | L386-403 | `GetAttribute<NSNumber>(...)?.BoolValue` (NSNumber wraps both) | ✅ | |

**A.a. Value coercion cross-context issue (MEDIUM)** — `FocusedElementCapture.readValueString` (L214-243) is called from *both* `readName` (which mirrors Everywhere's `Name`, `AXUIElement.cs:281` = `NSObject.ToString()` with **no** checkbox transform) *and* from the top-level `capture` flow's `value` field (which mirrors `GetText` behaviour, `AXUIElement.cs:549-556`, checkbox transform applies). Swift applies the checkbox `"0"→"false"` mapping unconditionally when `role == "AXCheckBox"`, so a focused checkbox whose `AXValue` is numeric will emit `name = "true"` while Everywhere's `Name` would emit `"1"` verbatim. Impact minor (checkboxes normally carry a real AXTitle earlier in the cascade), but the two contexts should not share one helper. Fix: split into `readNameValueString` (no checkbox transform) and `readValueTextString` (with transform).

### B. State bag (`readStates` in FocusedElementCapture / `statesList` in SemanticExtractor vs `AXUIElement.States` + `SemanticExtractor.StatesToList`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Enum probed: Disabled, Selected, Expanded, Focused, Offscreen (AXHidden), Password (AXSecureTextField), Checked (AXCheckBox/AXRadioButton, numeric AXValue > 0) | FocusedElementCapture L251-288, SemanticExtractor L450-479 | `AXUIElement.cs:218-251` | ✅ | Same 7 flags. |
| `VisualElementStates` numeric ordering: Offscreen(1) → Disabled(2) → Focused(4) → Selected(8) → Password(32) → Expanded(64) → Checked(8192) | Swift emits: Disabled → Selected → Expanded → Focused → Offscreen → Password → Checked | `IVisualElement.cs:63-83` + `SemanticExtractor.cs:100` uses `Enum.GetValues<VisualElementStates>()` (numeric-sorted) | ❌ | See B.a. Real JSON-order divergence. |
| Casing | `FocusedElementCapture` lowercase (`"disabled"`); `SemanticExtractor` PascalCase (`"Disabled"`) | Enum `.ToString()` → PascalCase (`"Disabled"`) | ⚠️ | `SemanticExtractor` matches; `FocusedElementInfo` deliberately differs (openclicky-shaped envelope). |
| CFNumber bool tolerance | FocusedElementCapture L395-401 accepts CFNumber-as-bool; SemanticExtractor L552-558 only CFBoolean | Everywhere uses `NSNumber.BoolValue` — accepts both | ❌ | See B.b. `SemanticExtractor.readBool` rejects apps that expose Enabled/Selected/Expanded/Focused/Hidden as CFNumber. |
| Password state derivation | Reads `AXSubrole == "AXSecureTextField"` inside `statesList` (L467-470) | `AXUIElement.cs:242` | ✅ | |
| Checked: only for AXCheckBox / AXRadioButton, numeric AXValue > 0 (skip CFBoolean) | SemanticExtractor L471-477, FocusedElementCapture L276-286 | `AXUIElement.cs:247-250` (`NSNumber`, `Int32Value > 0`) | ✅ | |

**B.a. State-list order divergence (MEDIUM)** — Everywhere's `SemanticExtractor.StatesToList` iterates `Enum.GetValues<VisualElementStates>()` which returns values sorted by unsigned numeric value (Offscreen, Disabled, Focused, Selected, Password, Expanded, Checked). Both Swift state emitters produce a hand-coded order (Disabled, Selected, Expanded, Focused, Offscreen, Password, Checked). Fix: reorder the probe/emit sequence in both `FocusedElementCapture.readStates` and `SemanticExtractor.statesList` to match Everywhere's numeric enum order.

**B.b. `SemanticExtractor.readBool` CFNumber gap (HIGH)** — `SemanticExtractor.swift:552-558` only accepts `CFBooleanGetTypeID()`. Everywhere reads via `GetAttribute<NSNumber>(...)?.BoolValue == true`, and CoreFoundation-typed AX values come across as NSNumber wrapping either CFBoolean **or** CFNumber. Real apps (Electron, some SwiftUI internals) expose `AXEnabled`/`AXSelected` as CFNumber(0|1). `FocusedElementCapture.readBool` handles both branches correctly (L386-403) but `SemanticExtractor.readBool` does not. Result: `statesList` will drop Disabled/Selected/Expanded/Focused/Offscreen for those apps. Fix: mirror `FocusedElementCapture.readBool`'s CFNumber fallback.

### C. Cursor position (`CursorCapture.swift` vs `VisualElementContext.ElementFromPointer`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Read `NSEvent.mouseLocation` (Cocoa bottom-left, unified space) | `CursorCapture.swift:53` | `VisualElementContext.cs:53` (`NSEvent.CurrentMouseLocation`) | ✅ | |
| Cocoa → Quartz flip formula | `y = primary.frame.height - cocoaPoint.y` (global-Quartz, primary anchor); `x = cocoaPoint.x` unchanged (L70-74) | `y = screen.Frame.Height - (mouseLocation.Y - screen.Frame.Y); x = mouseLocation.X - screen.Frame.X` (screen-local, `VisualElementContext.cs:61-63`) | ⚠️ | Intentional deviation per checklist L40 "ElementUnderCursor multi-display bug 修正 (openclicky 修, Everywhere 有 bug)". Documented in `CursorCapture.swift:12-19` header. Everywhere's formula yields per-screen-local coords, which is incorrect input to `AXUIElementCopyElementAtPosition` on non-primary displays. |
| Headless / no screens fallback | Emits raw Cocoa point with `displayIndex = -1` (L56-64) | `VisualElementContext.cs:58` returns null when `screen is null` | ⚠️ | Documented deviation (header L21-27). Swift chooses "always emit" so caller can distinguish "no cursor" vs "no display map". |
| Multi-display index calc | `displayIndex(for:screens:)` L92-110 with per-screen Cocoa→Quartz flip | Not exposed in Everywhere (no equivalent field on `PixelPoint`) | ⚠️ | Additive openclicky-only enrichment. |

### D. Element under cursor (`ElementUnderCursorCapture.swift` vs `AXUIElement.ElementAtPosition`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Hit test entry: `AXUIElementCopyElementAtPosition(SystemWide, x, y)` | L141-148 | `AXUIElement.cs:1135-1139` + `VisualElementContext.cs:24` | ✅ | |
| SystemWide singleton | Lazy `AXUIElementCreateSystemWide()` at L136 | `AXUIElement.cs:1133` `SystemWide` static + `AXUIElement.cs:471-475` `SetMessagingTimeout(1f)` on it | ❌ | See D.a. Swift port omits messaging timeout. |
| pid from `AXUIElementGetPid` | L151-155 | `AXUIElement.cs:467` (`ProcessId` getter) | ✅ | |
| Attribute fan-out: role/subrole/title/value/bounds | L111-127 | `AXUIElement.cs:494,496`, `AXUIElement.cs:281`, `AXUIElement.cs:448-465` | ⚠️ | See D.b. Narrow port — title only (not full `Name` cascade). Documented in header L23-30. |
| `AXValue` coercion: CFString / CFNumber (numeric string) / CFBoolean ("true"/"false") | L176-191 | `AXUIElement.cs:281` `NSObject.ToString()` on `AXValue` attribute | ⚠️ | For CFBoolean, Everywhere's `NSObject.ToString()` on NSNumber-wrapped bool yields `"1"`/`"0"`, not `"true"`/`"false"`. Minor deviation in edge case. |
| Bounds fallback `.zero` | L197-219 | `AXUIElement.cs:448-465` `return default` | ✅ | |
| bundleId via `NSRunningApplication(processIdentifier:)` | L116-118 | Not present in Everywhere (openclicky-only enrichment) | ⚠️ | Additive; harmless. |

**D.a. Missing `AXUIElementSetMessagingTimeout(SystemWide, 1f)` (MEDIUM)** — Everywhere sets a 1-second messaging timeout on the SystemWide element in a static constructor (`AXUIElement.cs:471-475`) to override the 6-second default AX timeout. Absent this, any AX call that stalls (unresponsive app) will hang the capture path for up to 6s. openclicky's SystemWide (`ElementUnderCursorCapture.swift:136`) and per-app elements do not set the timeout anywhere. Fix: add `AXUIElementSetMessagingTimeout(systemWide, 1.0)` on lazy init (and mirror for `AXUIElementCreateApplication` refs in `FocusedElementCapture`/`SemanticExtractor`).

**D.b. Hit-test `title` field is narrow-port (LOW)** — `ElementUnderCursorCapture` reads raw `AXTitle` only, not the full `Name` cascade. Documented in header comment (L23-30) as intentional because Everywhere's hit-test callers (screen picker, hover overlay) only read `Role`/`BoundingRectangle`. Acceptable given the documented rationale.

### E. Semantic extraction (`SemanticExtractor.swift` vs `SemanticExtractor.cs`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| `focusedPath(pid:)` — walk leaf → root via `AXParent`, reverse | `SemanticExtractor.swift:127-149` | `SemanticExtractor.cs:49-70` (walk indexed nodes via ParentIndex, reverse) | ⚠️ | Approach diverges — Everywhere reads a pre-walked indexed list; Swift walks live AX. Documented header L18-25. |
| Cycle guard via `CFHash` | L136-141 (`elementHash` = `CFHash` wrapped Int) | `AXUIElement.cs:15,21` `IdentityKey = CFHash(Handle)` + `ElementIndexer.cs:67` `HashSet<ulong>` | ✅ | Matches OCCU parity comment. |
| Ancestor depth cap | `kMaxPathDepth = 32` (L75) | `UpstreamConstants.AccessibilityTreeMaxDepth = 64` (`UpstreamConstants.cs:11`) | ❌ | See E.a. Cap is half of Everywhere. |
| `focused(pid:)` — deepest focused leaf via `kAXFocusedUIElement` | L159-166 | `SemanticExtractor.cs:33-42` (deepest node with Focused flag) | ✅ | Live-AX shortcut yields the same leaf. |
| `selected(pid:)` — enumerate selection | L186-205 — only walks AXSelectedRows/AXSelectedChildren on focused element | `SemanticExtractor.cs:13-24` iterates every indexed node with Selected flag | ⚠️ | Documented deviation (Swift lacks pre-walked list). Narrower than Everywhere. |
| `BuildItem` cascade: Name.Trim → GetText(200).Trim → FindLabelTextInChildren(maxDepth:3) | L218-243 | `SemanticExtractor.cs:72-94` | ✅ | Order matches. |
| `kMaxOwnTextLength = 200` | L83 | `SemanticExtractor.cs:79` `maxLength: 200` | ✅ | |
| `kLabelSearchMaxDepth = 3` | L79 | `SemanticExtractor.cs:83` `maxDepth: 3` | ✅ | |
| AX role → `VisualElementType` mapping (28 role cases + 9 subrole fallback cases → `Unknown`) | L251-326 | `AXUIElement.cs:120-213` | ✅ | Case-by-case audit passes. `AXCell → Panel`, `AXRow → TableRow`, `AXSearchField → TextEdit`, `AXToggle/AXSwitch → CheckBox`, etc. |
| `SuggestActions` table (7 branches → 9 verbs) | L487-507 | `SemanticExtractor.cs:111-138` | ✅ | Byte-exact incl. fallthrough groups. |
| `states` output casing | PascalCase (`"Disabled"`) | Enum `.ToString()` → PascalCase | ✅ | |
| `states` output order | Fixed order: Disabled/Selected/Expanded/Focused/Offscreen/Password/Checked | `Enum.GetValues<VisualElementStates>()` numeric order: Offscreen/Disabled/Focused/Selected/Password/Expanded/Checked | ❌ | See B.a. |
| `states` returns `null` when empty | L478 `flags.isEmpty ? nil : flags` | `SemanticExtractor.cs:98,108` returns null | ✅ | |
| `availableActions` returns `null` when unknown type | L505 `default: return nil` | `SemanticExtractor.cs:137` `_ => null` | ✅ | |
| `SemanticNode` JSON keys: `type`, `text`, `states`, `available_actions` | `CaptureTypes.swift:2188-2193` | `SemanticItem.cs:12-32` (`element_index`, `type`, `text`, `states`, `available_actions`) | ⚠️ | `element_index` deliberately dropped — no pre-walked index space. Documented `CaptureTypes.swift:2149-2153`. |
| `WhenWritingNull` semantics: text/states/availableActions omitted when nil | Swift `Codable` writes `null` for nil `Optional` unless customized; no `encodeIfPresent` overrides in `SemanticNode` | Everywhere `[JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]` on Text/States/AvailableActions | ❌ | See E.b. Wire shape divergence. |

**E.a. Ancestor path depth cap 32 vs Everywhere 64 (MEDIUM)** — `SemanticExtractor.swift:75 kMaxPathDepth = 32`, but Everywhere caps the walk indirectly at `UpstreamConstants.AccessibilityTreeMaxDepth = 64` (`UpstreamConstants.cs:11`). The Swift comment (L68-73) incorrectly claims Everywhere caps at 12 — actual constant is 64. Deep SwiftUI hierarchies (Xcode, Safari devtools) genuinely produce path chains > 32. Fix: raise `kMaxPathDepth` to 64 to match `UpstreamConstants.AccessibilityTreeMaxDepth`, and correct the comment.

**E.b. `SemanticNode` Codable does not honor `WhenWritingNull` (MEDIUM)** — `SemanticItem.cs` marks `text`/`states`/`available_actions` with `JsonIgnoreCondition.WhenWritingNull`, so nil fields are omitted from JSON entirely. Swift's default `Codable` synthesis emits `null` for nil `Optional`s. Callers that pattern-match on presence-of-key (Everywhere's `focused_items` / `selected_items` / `focused_path` schemas do) will see semantic differences. Fix: add explicit `encode(to:)` on `SemanticNode` using `encodeIfPresent` for the three optional fields.

### F. AX attribute constant literals

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Focused element AX attribute names redeclared per-file | Each capture file declares its own `attr...: CFString` constants | `AXAttributeConstants.cs:8-100` central declaration but per-file usage same shape | ✅ | Style deviation only; wire strings match byte-for-byte across all captures. |
| `AXPlaceholderValue` (not `AXPlaceholder`) | `FocusedElementCapture.swift:56` | `AXAttributeConstants.cs:72` | ✅ | |
| `AXHelp` name | `FocusedElementCapture.swift:54`, `SemanticExtractor.swift:95` | `AXAttributeConstants.cs:71` | ✅ | |

### G. Doc-header comment preservation

| Aspect | openclicky | Everywhere | Match |
|---|---|---|---|
| Header cites Everywhere pin + file:line | All 4 capture files carry `@30e03e9d...` pin + `// Ported from Everywhere: ...` | n/a | ✅ |
| Intentional deviation flags documented in headers | Password null (FocusedElementCapture L28-32), CursorCapture flip (L12-27), narrow title cascade in ElementUnderCursor (L23-30), semantic-vs-indexed shift in SemanticExtractor (L18-25), Selected fallback (L168-185) | n/a | ✅ |
| OCCU/Everywhere "WARNING/HACK" prose preserved | `AXUIElement.cs`'s OCCU comparison prose is partially preserved via header pointers to source line numbers; specific WARNING/HACK lines not reproduced verbatim | Substantive perf/IPC comments in `AXUIElement.cs:218-251,270-315,337-363` | ⚠️ | Line-number pointers included, textual warnings mostly not carried across. Acceptable per checklist L35 (translated OK). |

---

## Issues Found

- **HIGH — B.b**: `SemanticExtractor.readBool` (`SemanticExtractor.swift:552-558`) only recognises CFBoolean, silently dropping Disabled/Selected/Expanded/Focused/Offscreen for apps that expose those attributes as CFNumber(0|1). Fix: mirror `FocusedElementCapture.readBool`'s CFNumber fallback (L395-401).
- **MEDIUM — A.a**: `FocusedElementCapture.readValueString` conflates `Name`-cascade context (no AXCheckBox transform) with `GetText`-context (apply transform). Split into two helpers.
- **MEDIUM — B.a**: State-list order in both `FocusedElementCapture.readStates` and `SemanticExtractor.statesList` diverges from Everywhere's numeric `Enum.GetValues<VisualElementStates>()` order. Reorder to Offscreen → Disabled → Focused → Selected → Password → Expanded → Checked.
- **MEDIUM — D.a**: No `AXUIElementSetMessagingTimeout(_, 1.0)` on any AX handle (SystemWide, per-app). Everywhere sets 1s (`AXUIElement.cs:471-475`); openclicky inherits the 6s default and will hang capture on unresponsive apps.
- **MEDIUM — E.a**: `SemanticExtractor.kMaxPathDepth = 32` truncates deep hierarchies; Everywhere's real cap is `UpstreamConstants.AccessibilityTreeMaxDepth = 64`. Raise to 64 and fix stale comment (which claims Everywhere caps at 12).
- **MEDIUM — E.b**: `SemanticNode` default `Codable` emits `null` for missing fields; Everywhere's `SemanticItem` uses `WhenWritingNull` to omit them. Add explicit `encode(to:)` with `encodeIfPresent`.
- **LOW — Header comment L20-23 of `FocusedElementCapture`**: description states `AXTitle -> AXDescription -> AXHelp -> (if label-bearing) AXValue -> AXTitleUIElement -> first AXStaticText child -> AXIdentifier` — verified matches implementation and `AXUIElement.cs:257-315`. No fix needed; noted for record.
- **LOW — D.b**: `ElementUnderCursorInfo.title` narrow-port (AXTitle only, not full Name cascade). Intentional; documented.
- **INFO — Coordinate diff (C.2)**: `CursorCapture.swift` uses `primary.frame.height - cocoaPoint.y` (global-Quartz). Everywhere uses screen-local `(screen.Frame.Height - (mouseLocation.Y - screen.Frame.Y), mouseLocation.X - screen.Frame.X)`. This is an intentional multi-display bug fix documented in the file header and in `docs/ROADMAP/11_REVIEW_CHECKLIST.md:40`. No change needed.
- **INFO — `FocusedElementCapture.states` casing** is lowercase (openclicky-shaped envelope, does not exist on Everywhere side). `SemanticExtractor.statesList` PascalCase — matches Everywhere. Split intentional.

---

## Verdict

- [ ] BYTE_MATCH
- [ ] SEMANTIC_MATCH
- [x] DIVERGENT — has intentional deviations documented in file header (password null, cursor global-Quartz flip, narrow hit-test title, live-AX semantic walk, selected-fallback)
- [ ] BROKEN

The port is **DIVERGENT with unresolved unintentional deviations**. All the intentional deviations (C, D.b, E's structural reshaping, password guard) are properly documented in headers. However there are 6 unintentional deviations (1 HIGH, 4 MEDIUM, 1 LOW+INFO) that need fix before F02 can be marked SEMANTIC_MATCH.

---

## Recommendations

Priority order for follow-up:

1. **B.b (HIGH)** — Fix `SemanticExtractor.readBool` to accept CFNumber in addition to CFBoolean; add a regression test with a fake AXUIElement that returns `Enabled=CFNumber(0)`.
2. **D.a (MEDIUM)** — Add `AXUIElementSetMessagingTimeout(systemWide, 1.0)` inside a `static let` init block in `ElementUnderCursorCapture` and mirror on per-app refs in `FocusedElementCapture` / `SemanticExtractor` (or centralise in a shared helper).
3. **B.a (MEDIUM)** — Reorder state emission in `FocusedElementCapture.readStates` and `SemanticExtractor.statesList` to numeric enum order (Offscreen, Disabled, Focused, Selected, Password, Expanded, Checked).
4. **A.a (MEDIUM)** — Split `readValueString` into `readNameString` (no AXCheckBox transform) and `readValueString` (with transform); wire the `name` cascade to the former.
5. **E.a (MEDIUM)** — Bump `kMaxPathDepth` to 64; correct the stale header comment (Everywhere caps at 64 via `UpstreamConstants.AccessibilityTreeMaxDepth`, not 12).
6. **E.b (MEDIUM)** — Add an explicit `encode(to:)` on `SemanticNode` using `encodeIfPresent` for `text`/`states`/`availableActions` to match Everywhere's `WhenWritingNull` wire semantic.
