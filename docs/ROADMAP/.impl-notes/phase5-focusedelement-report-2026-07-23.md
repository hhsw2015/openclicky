# Phase 5 — FocusedElement port report (2026-07-23)

## Scope
Roadmap row 4 in `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`:
`Capture/FocusedElementCapture.swift, SnapshotRenderer.cs, P1, FocusedElement (role/name/value/states/actions)`.

## Files produced
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FocusedElementCapture.swift` — public `FocusedElementCapture.capture(pid: Int32) -> FocusedElementInfo?`.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` — appended `FocusedElementInfo` (existing types untouched).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/FocusedElementCaptureTests.swift` — 9 tests (5 guard + 1 gated live Finder + 3 wire-shape).
- `docs/ROADMAP/.impl-notes/phase5-focusedelement-2026-07-23.md` — investigation notes.

## Alignment with Everywhere @30e03e9d

| Field / behaviour | Everywhere source | Port location |
|---|---|---|
| Resolution: `AXUIElementCreateApplication(pid) → AXFocusedUIElement` | `AXAttributeConstants.cs:23`, `AXUIElement.cs:1147-1151`, `VisualElementContext.cs:12` | `capture(pid:)` |
| Name cascade: Title → Description → Help → (label-bearing) Value → TitleUIElement → first AXStaticText child → Identifier | `AXUIElement.cs:257-315` | `readName` |
| Label-bearing role whitelist | `AXUIElement.cs:325-335` | `isLabelBearingRole` |
| First-child AXStaticText scan (≤12) | `AXUIElement.cs:337-363` | `firstChildStaticTextValue` |
| Value coercion + AXCheckBox 0/1 → false/true | `AXUIElement.cs:552-556` (GetText) | `readValueString` |
| States: disabled / selected / expanded / focused / offscreen / password / checked | `AXUIElement.cs:218-251` | `readStates` |
| Actions: `AX`-strip + meaningful whitelist + dedup | `SnapshotActionFilter.cs:17-40` | `readMeaningfulActions` + `meaningfulActions` |
| Bounds: AXPosition + AXSize via AXValueGetValue, missing → .zero | `AXUIElement.cs:448-465` | `readBounds` |
| Secure text-field flag: `Subrole == "AXSecureTextField"` | `AXUIElement.cs:242` | `secureTextFieldSubrole` |

Attribute strings byte-identical: `AXFocusedUIElement`, `AXRole`, `AXSubrole`, `AXTitle`, `AXDescription`, `AXHelp`, `AXValue`, `AXPlaceholderValue`, `AXIdentifier`, `AXTitleUIElement`, `AXChildren`, `AXPosition`, `AXSize`, `AXEnabled`, `AXSelected`, `AXExpanded`, `AXFocused`, `AXHidden`.

## Deviations
1. Password value is nil at capture boundary (Everywhere returns raw AXValue and elides in writer). Stricter, matches task rule.
2. `title` (raw AXTitle) and `name` (cascade result) are split. Everywhere fuses into `Name`; splitting lets consumers see the source.
3. `bool` reader accepts NSNumber as well as CFBoolean because a few apps (older WebKit) report `AXEnabled` as a number.
4. No AX caching (Everywhere memoises BoundingRectangle on the element for hit-test reuse).

## Tests
`swift test --filter FocusedElementCapture` — 8 passed, 1 skipped (live Finder test skipped because Swift test host has no AX consent; expected on the local run).

## Blocked / out-of-scope observations
- `scripts/sign-and-install.sh` fails at the Xcode step with a pre-existing error in `cursor-buddy/OpenClickyExternalControlBridge.swift:2162` (`WindowEnumerationCapture` has no `EnumerateOptions`). That file is Phase 2 concurrent-agent territory and outside this task's touch list; my package builds and tests clean in isolation. Flagging so the Bridge agent can rebase.
- Ancillary one-line fix already in place from another agent: `MemoryStore.swift:55` (`Self.currentMillis()` → `MemoryStore.currentMillis()`); no action required.
