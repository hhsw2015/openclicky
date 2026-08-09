# Phase 7 Layer 4 UX — Report (2026-07-23)

## Deliverables

Settings tab "Context Awareness" + 5 hotkey plumbing shipped. All five
hotkeys default UNBOUND (verbatim parity with Everywhere
`ShortcutSettings.cs` @30e03e9d where only `ChatWindow` is bound and the
other 7 slots use `new()`). No overlay drawing UI in this phase.

## Files created

- `cursor-buddy/OpenClickyContextAwarenessSettings.swift`
  - `OpenClickyContextHotkeyAction` enum (5 actions).
  - `OpenClickyHotkeyBinding` (keyCode + modifiers + enabled) with
    JSON persistence and a significant-modifier mask so numpad /
    caps-lock bits do not break matching.
  - `OpenClickyContextAwarenessSettings` (ObservableObject, singleton)
    with master toggle, auto text-selection toggle, and per-action
    binding storage. Constants pinned to Everywhere:
      - `repeatSuppressionInterval = 1.5s` (`RepeatSuppressionMs = 1500`)
      - `modifierReleaseDelay = 0.18s` (`MacosModifierReleaseDelayMs = 180`)
  - `OpenClickyHotkeyLabel.describe(_:)` → "⌃⌥⇧⌘K" style formatting.
- `cursor-buddy/OpenClickyContextHotkeys.swift`
  - `OpenClickyContextHotkeys` class: `.cgSessionEventTap`, `.listenOnly`
    tap mirroring `GlobalPushToTalkShortcutMonitor` shape.
  - Reads `settings.masterEnabled` on each keystroke (cheap early-out).
  - Repeat suppression per-action + 180ms modifier-release delay before
    performing action.
  - Actions:
      1. `snapshotContext` → `OpenClickyContextStashWriter().captureAsync()`
      2. `clearContextStash` → writer `.clearStash()` +
         `PickStash.shared.clearWithEvent()` +
         `AnnotationStash.shared.clearWithEvent()` +
         `WhiteboardStash.shared.clearWithEvent()`
      3. `agentPickElement` → `AXUIElementCopyElementAtPosition` at
         `NSEvent.mouseLocation` (converted to top-left), extracts role /
         title / value / bounds / bundleId, calls
         `PickStash.shared.set(picked)`.
      4. `whiteboard` → stub log + `WhiteboardStash.shared.set(regions:
         [], imageBytesById: [:])`. Empty regions intentionally leaves
         `hasPending == false` per stash contract.
      5. `linkRect` → stub log only.
  - Public `fireTestSnapshot()` used by the Settings "Fire" button.
- `cursor-buddy/OpenClickyContextAwarenessPanel.swift`
  - `OpenClickyContextAwarenessPanel` SwiftUI view (master toggle,
    hotkey bindings, auto capture, stash file, hook binary, sanity
    checks).
  - `OpenClickyHotkeyRecorderSheet` — modal sheet that installs a
    local `NSEvent.addLocalMonitorForEvents` monitor and captures the
    next keyDown. Requires at least one modifier before Save enables;
    Escape cancels.

## Files modified

- `cursor-buddy/OpenClickySettingsWindowManager.swift`
  - Added `case contextAwareness` to `OpenClickySettingsSection`.
  - Title "Context Awareness", subtitle noting defaults are unbound,
    system icon `eye`.
  - `contextAwarenessPanel` slot in `selectedPanel` switch delegates
    to `OpenClickyContextAwarenessPanel`.
- `cursor-buddy/CompanionManager.swift`
  - New property `let contextAwarenessHotkeys = OpenClickyContextHotkeys()`.
  - Started inside the accessibility permission gate alongside
    `globalPushToTalkShortcutMonitor.start()`.
  - Stopped in the else-branch of that gate AND in `stop()`.

## 5 hotkey action mapping

| Action | Trigger effect |
|---|---|
| `SnapshotContext` | `OpenClickyContextStashWriter.captureAsync()` → writes `~/Library/Application Support/OpenClicky/context-stash.json` |
| `ClearContextStash` | Deletes stash file + `.tmp` sidecar + clears `PickStash` / `AnnotationStash` / `WhiteboardStash` (all `clearWithEvent`, so observers wake up) |
| `AgentPickElement` | `AXUIElementCopyElementAtPosition` at cursor → serialises to `PickedElement` → `PickStash.shared.set(...)` (5-minute TTL from the stash default) |
| `Whiteboard` | Stub log + `WhiteboardStash.shared.set(regions: [], imageBytesById: [:])`. Drawing overlay lands with Phase 7.1 |
| `LinkRect` | Stub log only. Drag-rect overlay lands with Phase 7.1 |

## Behaviour audit

- Fresh install: no `openclicky.contextAwareness.hotkey.*` keys in
  UserDefaults → `activeBindings` returns empty → tap callback exits
  early after the master-toggle check. Verified by construction (no
  binding is written until the user hits Save in the recorder sheet).
- `repeatSuppressionInterval = 1.5` (`OpenClickyContextAwarenessSettings.repeatSuppressionInterval`) — matches Everywhere `RepeatSuppressionMs = 1500` (`SnapshotContextHotkeyInitializer.cs` @30e03e9d).
- `modifierReleaseDelay = 0.180` (`OpenClickyContextAwarenessSettings.modifierReleaseDelay`) — matches Everywhere `MacosModifierReleaseDelayMs = 180`.
- All 5 hotkeys share one CGEvent tap installed by
  `CompanionManager.setupAccessibilityPermissionGate` (only when the
  system-wide accessibility permission is granted, same gate as PTT).
- Master toggle defaults false; user must explicitly enable in the
  Settings tab before any binding fires.
- Recorder sheet blocks Save until the chord has at least one modifier
  key (prevents accidental "letter-eats-typing" bindings).

## Settings tab layout (ASCII)

```
Context Awareness
[card] Enable context-awareness hotkeys                     [ off ]
       Master switch for the five hotkeys below. Off by default.

Hotkey bindings
[card] Snapshot Context          [switch] Not set   [Change] [Clear]
       ---
       Clear Context Stash       [switch] Not set   [Change] [Clear]
       ---
       Agent Pick Element        [switch] Not set   [Change] [Clear]
       ---
       Whiteboard (press-hold)   [switch] Not set   [Change] [Clear]
       ---
       LinkRect (press-drag)     [switch] Not set   [Change] [Clear]

Auto capture
[card] Enable auto text-selection observer (passive)        [ off ]

Stash file
[card] context-stash.json
       ~/Library/Application Support/OpenClicky/context-stash.json  [Reveal]

Hook binary
[card] openclicky-context-hook
       Copy this binary onto your Claude Code / cmux hook path.    [Show install steps]

Sanity checks
[card] Fire a test snapshot                                       [Fire]
```

## Build / verification

- `swiftc -parse` over the two new + two modified files: clean
  (`OpenClickyContextAwarenessSettings.swift`,
  `OpenClickyContextHotkeys.swift`,
  `OpenClickyContextAwarenessPanel.swift`,
  `CompanionManager.swift`,
  `OpenClickySettingsWindowManager.swift`,
  plus `OpenClickyContextStashWriter.swift` for cross-file symbol resolution — all parse together with no warnings).
- Full Xcode build intentionally NOT run from the terminal — per
  `CLAUDE.md`, `xcodebuild` is forbidden and the build happens in
  Xcode. `bash scripts/sign-and-install.sh` was NOT invoked for the
  same reason; the script wraps `xcodebuild archive` + notarisation.

## Manual test recipe

1. Open Xcode, build & run OpenClicky.
2. Grant Accessibility permission (Menu bar → Settings → Permissions
   → Accessibility) if not already.
3. Open Settings → sidebar shows the new "Context Awareness" row
   below "Models".
4. Flip the "Enable context-awareness hotkeys" master switch on.
5. Click "Change" on the "Snapshot Context" row → recorder sheet
   appears → press e.g. `⌃⌥⇧S` → Save.
6. Toggle the per-row switch on if it isn't already (auto-enabled by
   the recorder).
7. Move to any other app (Finder, Safari, etc.) and press the chord.
8. In Finder navigate to `~/Library/Application Support/OpenClicky/`
   and confirm `context-stash.json` was written with fresh
   `capturedAtUtc` and the active app / window / URL fields populated.
9. Bind another chord to "Clear Context Stash", press it, and confirm
   the stash file disappears.
10. Bind another chord to "Agent Pick Element", hover over any UI
    element in another app, press the chord. Nothing visual happens
    (overlay is deferred), but a follow-up `read_pick` MCP call (Phase
    5 tool) will surface the pinned element.

## Known limitations

- **Whiteboard / LinkRect are stubs.** The hotkey path fires, logs a
  line to `NSLog`, and (for Whiteboard) touches the stash with an
  empty regions list. Full drawing / drag-rect overlays are Phase 7.1.
- **Auto text-selection observer toggle is UI-only.** The passive
  observer that watches mouse-up over I-beam cursors is not wired yet
  — the toggle persists so users can find the switch, but nothing
  reads it. Follow-up phase.
- **Hook binary "Show install steps" is documentation only.** It
  points the user at the target directory but doesn't copy /
  self-test the binary; that plumbing lands with the hook binary
  ship.
- **Recorder cannot bind chords the OS captures first** (e.g.
  `⌘Space`, `⌘⇥`). The sheet accepts them, but the tap never sees
  the down-edge. No mitigation in this phase — surface a warning to
  the user later if the binding never fires.
- **`AgentPickElement` gives no visual feedback.** The overlay
  ("Pin element..." highlight) is deferred; the pin still lands in
  `PickStash` and downstream MCP tools see it, but the user has to
  trust the hotkey worked. HUD confirmation lands with Phase 7.1.
