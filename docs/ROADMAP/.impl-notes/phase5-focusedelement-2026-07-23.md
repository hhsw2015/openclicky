# Phase 5 — FocusedElement investigation notes (2026-07-23)

## Everywhere source of truth

Snapshot @ `30e03e9dcfdd4247fd679828ed86e9042f32d809`.

Primary:
- `src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs` (esp L119-220 per-node label / text / states / actions extraction).
- `src/Everywhere.Mac/Interop/AXUIElement.cs`:
  - `Name` cascade — L257-315
  - `States` — L218-251
  - `Description` / `AccessibleDescription` — L369-380
  - `Placeholder` — L374
  - `BoundingRectangle` — L430-465
  - `SupportedActions` — L507+
  - `GetText` — L549-574
  - `Subrole` / `AXSecureTextField` — L242
- `src/Everywhere.Mac/Interop/AXAttributeConstants.cs` — constant names.
- `src/Everywhere.Mac/Interop/VisualElementContext.cs:12` — `SystemWide.ElementByAttributeValue(AXFocusedUIElement)` is Everywhere's actual live entrypoint. Task pins us to the pid-based variant (`AXUIElementCreateApplication(pid) → AXFocusedUIElement`), which is equivalent for a per-pid MCP call.
- `src/Everywhere.Mcp/Snapshot/SnapshotActionFilter.cs` — action whitelist + `AX`-prefix strip.

## Semantics extracted

### Focused element resolution (per pid)
1. Guard `pid > 0`.
2. `AXUIElementCreateApplication(pid) → app`.
3. `AXUIElementCopyAttributeValue(app, "AXFocusedUIElement") → element`.
4. Nil element or any AX error → return `nil`.

### Name cascade (1:1 `AXUIElement.Name`, AXUIElement.cs:257-315)
1. `AXTitle` (non-whitespace).
2. `AXDescription`.
3. `AXHelp`.
4. If role is label-bearing: `AXValue` (as string).
5. If role is label-bearing: `AXTitleUIElement` → its `AXValue`, then its `AXTitle`.
6. If role is label-bearing: first `AXStaticText` child (up to 12 scanned) — its `AXValue` then `AXTitle`.
7. `AXIdentifier` fallback (SwiftUI test hooks).

Label-bearing roles: `AXButton`, `AXMenuButton`, `AXPopUpButton`, `AXCheckBox`, `AXRadioButton`, `AXMenuItem`, `AXMenuBarItem`, `AXLink`, `AXImage`, `AXDisclosureTriangle`, `AXCell`, `AXRow`.

### Value
- Read `AXValue`, coerce to string.
- `AXCheckBox` maps `"0"` → `"false"`, else `"true"` (matches GetText).
- **Secure text field**: if `AXSubrole == "AXSecureTextField"`, return `nil`. Never leak keystrokes.

### States (Everywhere `VisualElementStates`, AXUIElement.cs:218-251)
Emit lowercase strings, order matches Everywhere's flag enum order:
- `disabled` — `AXEnabled == false`.
- `selected` — `AXSelected == true`.
- `expanded` — `AXExpanded == true`.
- `focused` — `AXFocused == true`.
- `offscreen` — `AXHidden == true`.
- `password` — `Subrole == "AXSecureTextField"`.
- `checked` — `AXCheckBox | AXRadioButton` and numeric `AXValue > 0`.

### Actions (1:1 `SnapshotActionFilter.Filter`)
- Query `AXUIElementCopyActionNames`.
- Strip `AX` prefix.
- Whitelist: `Press`, `Confirm`, `Open`, `ShowMenu`, `Increment`, `Decrement`, `Pick`, `Cancel`, `Delete`, `Raise`.
- Dedup, order-preserving.

### Bounds
`AXPosition` + `AXSize`, unwrapped via `AXValueGetValue(.cgPoint / .cgSize)`. Missing either → `.zero` (matches `QueryBoundingRectangle` `return default;`).

### Attributes carried directly (no cascade)
- `title` = raw `AXTitle`.
- `subrole` = raw `AXSubrole`.
- `help` = raw `AXHelp`.
- `description` = raw `AXDescription`.
- `placeholder` = raw `AXPlaceholderValue` (Everywhere's `Placeholder`).

## Roadmap row reconciliation

Row 4 in `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
```
Capture/FocusedElementCapture.swift, SnapshotRenderer.cs, P1, FocusedElement (role/name/value/states/actions)
```
Fields covered: role + subrole + name (cascade) + title + value + placeholder + help + description + states + actions + bounds + isSecure + pid. Everywhere-parity + `isSecure` promoted to top-level flag so downstream tools can gate without re-parsing states.

## Deviations from Everywhere
- Password value returns `nil` (Everywhere's `GetText` returns raw AXValue; the caller elides it via secure-field UI). We eliminate the leak at the boundary — the task rule "never leak" is stricter than Everywhere's implicit behaviour.
- We surface `title` (raw AXTitle) *and* `name` (cascaded label). Everywhere fuses these in `Name`; splitting lets the consumer see whether the label came from `AXTitle` or a fallback.
- No caching. Everywhere reuses AXUIElement lifetime for BoundingRectangle memoisation; we're a one-shot capture.
