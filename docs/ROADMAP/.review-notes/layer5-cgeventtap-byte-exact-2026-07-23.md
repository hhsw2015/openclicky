# Layer 5 CGEventTap byte-exact audit — 2026-07-23

Audit of the openclicky global CGEvent tap that dispatches the five Layer 4
Context Awareness hotkeys, compared byte-exact against Everywhere at pin
`30e03e9dcfdd4247fd679828ed86e9042f32d809`.

Scope: read-only comparison plus low-noise debug logging. No behaviour
changes.

## Everywhere reference files consulted

- `Everywhere.Mac/Interop/CGEventListener.cs` — base CGEvent tap install
- `Everywhere.Mac/Interop/CGEventShortcutListener.cs` — dispatch, swallow
  policy, capture scope
- `Everywhere.Mac/Interop/KeyMapping.cs` — flag → KeyModifiers reduction
- `Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs` — repeat window
  + macos modifier release delay
- `Everywhere.Mcp/ClearContextStashHotkeyInitializer.cs` — dispose dance
- `Everywhere.Mcp/WhiteboardHotkeyInitializer.cs` — toggle semantics
- `Everywhere.Mcp/LinkRectHotkeyInitializer.cs` — reentrancy guard
- `Everywhere.Core/Initialization/ChatWindowInitializer.cs` — the actual
  home of the AgentPickElement handler (there is no separate
  `AgentPickElementHotkeyInitializer.cs`; the audit checklist name was
  wrong)
- `Everywhere.Core/Configuration/Settings/ShortcutSettings.cs` — five
  `CompositeKeyboardShortcut` slots
- `Everywhere.Core/Interop/KeyboardShortcut.cs` — record struct + IsValid

## openclicky files audited

- `cursor-buddy/OpenClickyContextHotkeys.swift`
- `cursor-buddy/OpenClickyContextAwarenessSettings.swift`
- `cursor-buddy/HeyClickyLog.swift`

The audit checklist mentioned
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
"for the KeyboardShortcut struct". That file exists (109 KB) but does not
own a KeyboardShortcut struct — openclicky's binding type is
`OpenClickyHotkeyBinding` in
`OpenClickyContextAwarenessSettings.swift:98`.

## Byte-exact checklist verdict

| # | Item | Everywhere | openclicky | Match |
|---|------|------------|------------|-------|
| 1 | Tap location | `CGEventTapLocation.HID` (`CGEventListener.cs:70`) | `.cghidEventTap` (`OpenClickyContextHotkeys.swift:152`) | Match |
| 2 | Tap options | `CGEventTapOptions.ListenOnly` static factory (`CGEventListener.cs:23`); `CGEventShortcutListener` uses `CGEventListener.Default` which is `CGEventTapOptions.Default` (`CGEventShortcutListener.cs:26`, `CGEventListener.cs:18`) | `.listenOnly` (`OpenClickyContextHotkeys.swift:154`) | **DIVERGENT — see finding D1** |
| 3 | Event mask | `KeyDown \| KeyUp \| FlagsChanged \| LeftMouseDown \| LeftMouseUp \| RightMouseDown \| RightMouseUp \| OtherMouseDown \| OtherMouseUp` (`CGEventListener.cs:63-67`), but the shortcut dispatcher only acts on `KeyDown` for registered chords (`CGEventShortcutListener.cs:33-51`, `:80-93`); `KeyUp` / `FlagsChanged` only feed capture scope | `[.keyDown]` only (`OpenClickyContextHotkeys.swift:105`) | **DIVERGENT — see finding D2** |
| 4 | Placement | `CGEventTapPlacement.HeadInsert` (`CGEventListener.cs:71`) | `.headInsertEventTap` (`OpenClickyContextHotkeys.swift:153`) | Match |
| 5 | Callback thread → handler queue | CGEvent callback runs on dedicated `CGEventListenerThread` (`CGEventListener.cs:39-46`); matched handler is dispatched via `ThreadPool.QueueUserWorkItem` (`CGEventShortcutListener.cs:82`) | `DispatchQueue.main.async` (`OpenClickyContextHotkeys.swift:229`); with a `DispatchQueue.main.asyncAfter` for the 180ms release delay (`:245-249`) | **DIVERGENT — see finding D3** |
| 6 | Consumed return on match | `cgEventRef = 0` swallows (`CGEventShortcutListener.cs:84`); requires `CGEventTapOptions.Default` | callback returns `nil` from Swift closure (`OpenClickyContextHotkeys.swift:127`) but `.listenOnly` ignores the return, so the event passes through | **DIVERGENT — see finding D1** (comment @ `:143-150` documents it) |
| 7 | Repeat suppression window | `RepeatSuppressionMs = 1500` (`SnapshotContextHotkeyInitializer.cs:122`) | `repeatSuppressionInterval = 1.5` s (`OpenClickyContextAwarenessSettings.swift:206`) | Match (1500 ms byte-exact) |
| 8 | Modifier release delay | `MacosModifierReleaseDelayMs = 180` (`SnapshotContextHotkeyInitializer.cs:107`) | `modifierReleaseDelay = 0.180` s (`OpenClickyContextAwarenessSettings.swift:212`) | Match (180 ms byte-exact) |
| 9 | Match logic (modifier bit mask) | `flags.ToAvaloniaKeyModifiers()` reduces to `Shift`/`Control`/`Alt`/`Meta` (`KeyMapping.cs:15-27`), silently dropping numpad / capslock / function bits | `significantModifierMask = Command \| Shift \| Alternate \| Control` (`OpenClickyContextAwarenessSettings.swift:107-114`); binding + incoming both masked before compare (`:123-128`) | Match (semantic equivalent: 4-bit user-visible mask, drop everything else) |
| 10 | Composite Main + Alternative | `CompositeKeyboardShortcut` exposes `Main` + `Alternative` and registers both when valid (`SnapshotContextHotkeyInitializer.cs:79-83`, `WhiteboardHotkeyInitializer.cs:110-114`, `LinkRectHotkeyInitializer.cs:82-88`, `ChatWindowInitializer.cs:110-114`) | Single `OpenClickyHotkeyBinding` per action (`OpenClickyContextAwarenessSettings.swift:328`) | **Divergent by design** (`hotkey-path-audit-2026-07-23.md`, Round 1). Not a regression: openclicky already documented the choice. |
| 11 | Master toggle default | `Shortcut.IsEnabled` defaults true when a slot has any Main/Alternative bound (implicit via `if (shortcut.IsEnabled) RegisterAll()` after property init) | `defaultMasterEnabled = true` (`OpenClickyContextAwarenessSettings.swift:249`), seeded on first launch (`:343-348`) | Match |
| 12 | Default bindings | Live user settings.json: Shift+Space / Alt+C / Alt+S / Alt+D / Alt+L | keyCode 49/8/1/2/37 + `.maskShift` / `.maskAlternate` (`OpenClickyContextAwarenessSettings.swift:222-246`) | Match (F22 seeded from real Everywhere config) |

## Findings

### D1 — `.listenOnly` cannot swallow (documented tradeoff)

Everywhere installs its shortcut tap via `CGEventListener.Default` which
is a `CGEventTapOptions.Default` tap (`CGEventListener.cs:18`), and its
handler writes `cgEventRef = 0` to swallow a matched hotkey
(`CGEventShortcutListener.cs:84`). openclicky uses `.listenOnly`
(`OpenClickyContextHotkeys.swift:154`).

The comment at `OpenClickyContextHotkeys.swift:143-150` is accurate:
`.listenOnly` was picked because macOS 26 silently requires Input
Monitoring for `.defaultTap`, and Accessibility alone won't get the tap
installed. The comment's claim that this "matches Everywhere baseline
behaviour" is imprecise — Everywhere uses `Default`, not `ListenOnly`,
for shortcuts. But the F22 fix note is clear that on macOS 26 the
`.listenOnly` fallback is the only practical choice today. Consequence:
matched hotkeys are NOT swallowed by openclicky on macOS 26, so
Shift+Space leaks a literal space into the frontmost text field. That is
an accepted regression documented in F22 and the existing comment.

The callback still returns `nil` from Swift when it decides a match
occurred (`:127`). Under `.listenOnly` CoreGraphics discards that return
value — the event goes through unmodified. Keeping the `return nil`
branch is harmless and lets an upgrade to `.defaultTap` (once Input
Monitoring is confirmed) restore swallow semantics with a single
`options:` change.

**No action** — behaviour intentionally divergent, already logged.

### D2 — Event mask does not include KeyUp / FlagsChanged

Everywhere's tap monitors `KeyDown | KeyUp | FlagsChanged | ...mouse` at
the listener level (`CGEventListener.cs:63-67`). openclicky monitors
only `[.keyDown]` (`OpenClickyContextHotkeys.swift:105`).

For the five hotkey actions this is fine: Everywhere's
`CGEventShortcutListener.HandleKeyDown` (`CGEventShortcutListener.cs:53-93`)
is the only place that fires registered handlers. `HandleKeyUp` and
`HandleFlagsChanged` (`:95-103`, `:105-135`) exclusively drive the
in-app shortcut capture UI (`_currentCaptureScope`), which openclicky
implements with a completely different mechanism (a SwiftUI recorder
row in `OpenClickyContextAwarenessSettings.swift`; see the
`OpenClickyHotkeyLabel` block starting `:493`, plus whatever
`.onKeyPress` SwiftUI wiring lives in the settings view).

Semantically equivalent. openclicky's narrower mask is actually a small
performance win: no wake for every mouse click, every modifier toggle.

**No action** — semantic parity holds; narrower mask is fine.

### D3 — Handler dispatch queue: main vs ThreadPool

Everywhere hops matched handlers to `ThreadPool.QueueUserWorkItem`
(`CGEventShortcutListener.cs:82`), then each initializer hops **again**
onto `Dispatcher.UIThread.Post` at the top of its own `OnHotkey`
(`SnapshotContextHotkeyInitializer.cs:146`,
`WhiteboardHotkeyInitializer.cs:140`,
`LinkRectHotkeyInitializer.cs:114`,
`ChatWindowInitializer.cs:175`).

The observable behaviour is:
1. return from the CGEvent tap immediately (don't hold the tap thread)
2. run the action body on the UI thread

openclicky collapses those two hops into one `DispatchQueue.main.async`
(`OpenClickyContextHotkeys.swift:229`), then delays 180 ms via
`DispatchQueue.main.asyncAfter` for non-whiteboard actions
(`:245-249`).

Consequence: the CGEvent tap thread is released as fast as, or faster
than, Everywhere. The action runs on main, matching Everywhere's
`Dispatcher.UIThread`.

There is one subtle difference: Everywhere's initializers apply the
180 ms `Task.Delay(MacosModifierReleaseDelayMs)` **inside** the
Dispatcher.UIThread action body
(`SnapshotContextHotkeyInitializer.cs:150-151`); openclicky applies it
as an outer `asyncAfter`. The end-to-end wall-clock is identical. The
inner-vs-outer distinction does not affect correctness because both
sides are single-actor.

**No action** — semantic parity holds.

### D4 — Missing debug telemetry

The tap install path had no structured log for success/failure, and the
per-callback path only NSLog'd when a hotkey ACTUALLY fired. Nothing
distinguished "tap installed but no key matched" from "tap silently
failed to install" — precisely the failure mode the F22 macOS 26 fix
targets.

**Action** — added six `HeyClickyLog.log` calls (see next section). All
gated so they don't spam per-keystroke unless the raw event failed to
match a binding.

## Debug logs added

Per the audit's "Debug logs to add" list. Each log call routes through
`HeyClickyLog.log` so it lands in the existing Settings → Logs viewer
alongside every other openclicky event.

| Event key | Fires when | Payload keys |
|-----------|------------|--------------|
| `openclicky.hotkey.tap_installed` | Tap successfully created and attached to the main run loop | `location`, `options`, `event_mask` |
| `openclicky.hotkey.tap_install_failed` | `CGEvent.tapCreate` returned nil, or `CFMachPortCreateRunLoopSource` failed | `reason` |
| `openclicky.hotkey.raw_event` | keyDown callback fired but NO binding matched (so log volume stays sane; matched fires are already logged) | `keycode`, `flags_raw`, `flags_masked` |
| `openclicky.hotkey.matched_binding` | keyDown matched a registered binding — precedes `enqueueAction` | `action`, `keycode`, `modifiers` |
| `openclicky.hotkey.repeat_suppressed` | Action dropped inside `enqueueAction` because of the 1500 ms window | `action`, `elapsed_ms` |
| `openclicky.hotkey.modifier_release_delay_start` | Non-whiteboard action about to be delayed by 180 ms | `action`, `delay_ms` |

The pre-existing per-action `openclicky.hotkey.snapshot_context.fired`
(`OpenClickyContextHotkeys.swift:278`) and
`openclicky.hotkey.agent_pick_element.fired` (`:300`) are unchanged.
These already served the "matched_binding" role for SnapshotContext and
AgentPickElement respectively; the new `matched_binding` event is a
single, uniform key across all five actions and fires strictly earlier
in the pipeline (before repeat suppression / release delay), so both are
retained.

`raw_event` is placed on the no-match branch specifically to avoid
per-keystroke noise. When a user types normally, the tap will still see
every keydown, but only unmatched ones are logged. This matches the
audit checklist guidance ("consider only when NO binding matches").

## Behavioural assertion (unchanged)

No semantic behaviour changed. The tap is still `.cghidEventTap` +
`.listenOnly` + `[.keyDown]`. Matched bindings still dispatch via main
queue with the 180 ms release delay. Whiteboard still toggles via the
overlay's `.isActive` check. LinkRect still guards with
`linkRectOverlay == nil`.

## Follow-ups (not done here)

1. **Composite Main + Alternative parity** (checklist item 10). Adding
   a second binding slot per action is a Domain-1 review item, not a
   layer-5 concern. Deferring to that domain's own PRD.
2. **`.defaultTap` upgrade path**. Once Input Monitoring TCC probing
   lands (F11 exposes `checkPermission` for `inputMonitoring`), we can
   switch to `.defaultTap` when permission is granted, restoring the
   swallow semantic (Shift+Space no longer leaks a space). The
   `return nil` branch in the callback is already wired for that.
3. **`tap_recovered` event**. `handleGlobalEventTap` re-enables the tap
   on `tapDisabledByTimeout` / `tapDisabledByUserInput`
   (`OpenClickyContextHotkeys.swift:192-196`) silently. Adding a
   telemetry event here would surface tap-disable events in the log
   viewer. Not in-scope for this audit.
