# Phase 7 — First-launch defaults matching Everywhere

Date: 2026-07-23
Owner: openclicky (this session)

## Goal

Make OpenClicky feel seamless for users migrating from Everywhere: on
first launch, the five Context Awareness hotkeys, the master toggle, the
Agent target app, the launch phrase, the known-apps list, and the two
overlay toggles must reproduce what the user already has configured in
`~/Library/Application Support/Everywhere/settings.json`.

Values (verbatim from user's Everywhere JSON):

- SnapshotContext = Shift+Space, enabled=true
- ClearContextStash = Alt+C, enabled=true
- AgentPickElement = Alt+S, enabled=true
- Whiteboard = Alt+D, enabled=true
- LinkRect = Alt+L, enabled=true
- AutoCaptureContext = true
- AgentAppId = "cmux"
- LaunchPhrase = "take a look"
- OpenDiaEnabled = true
- CursorOverlayEnabled = false
- KnownApps = [{ TitlePattern: "^xlinkBook",
                 DiscoverUrl: "http://localhost:5000/.well-known/agent-skills" }]

## Constraints

- Only touch `cursor-buddy/OpenClickyContextAwarenessSettings.swift`.
- Do not touch other files listed as belonging to concurrent agents
  (`OpenClickyContextHotkeys.swift`, `OpenClickyExternalControlBridge.swift`,
  `HeyClickyChatToolCallClient.swift`, `ClickyCodexConfigTemplate.swift`,
  `OpenClickyRouteDispatcher.swift`, `OpenClickyContextStashWriter.swift`,
  `OpenClickyContextAwarenessPanel.swift`,
  `OpenClickyWhiteboardOverlayWindow.swift`,
  `OpenClickyLinkRectOverlayWindow.swift`, `OpenClickyPickElementOverlay.swift`,
  `OpenClickyAnnotationBadgeOverlay.swift`, SPM files).
- Preserve existing structure of `OpenClickyHotkeyBinding` (keyCode as
  UInt16, modifiers as raw UInt64 CGEventFlags mask). Add default values
  layered on top; do not change JSON encoding.
- First-launch detection: if the UserDefaults key does not exist
  (`defaults.object(forKey:) == nil`), seed the Everywhere default.
  Once a user has stored a value (including "not set"), respect it.

## Existing shape (read from source)

- `OpenClickyHotkeyBinding { keyCode: UInt16, modifiers: UInt64, enabled: Bool }`
- Modifiers stored as raw CGEventFlags rawValue bits (masked by
  `significantModifierMask` which covers Cmd/Shift/Alt/Ctrl).
- Master toggle key: `openclicky.contextAwareness.hotkeysEnabled`
- Auto selection observer key: `openclicky.contextAwareness.autoSelectionObserverEnabled`
- Per-action key: `openclicky.contextAwareness.hotkey.<rawValue>`
- No `OpenClickyKnownApp` type yet — introduce here.

## Design

1. Add static `defaultBinding_<Action>` values on
   `OpenClickyContextAwarenessSettings` using CGEventFlags rawValue for
   modifiers.
2. Introduce `defaultMasterEnabled = true` and use "key missing" logic
   in `init` so an existing user with the key set to false is respected.
3. In `init`, for each action, if the persisted data is absent, seed
   with the Everywhere default (in-memory only — do not write until
   user takes action; this preserves the "explicit user override wins"
   semantic while still surfacing the pre-bound state).
   - Detail: we DO persist a copy to defaults on first read so restart
     behaviour matches. Reset-to-Everywhere convenience method clears
     stored keys and reloads.
4. Add new fields:
   - `autoCaptureContext: Bool` (default true)
   - `agentAppId: String` (default "cmux")
   - `launchPhrase: String` (default "take a look")
   - `openDiaEnabled: Bool` (default true)
   - `cursorOverlayEnabled: Bool` (default false)
   - `knownApps: [OpenClickyKnownApp]` (default single xlinkBook entry)
5. Add `OpenClickyKnownApp` value type (`Codable, Sendable, Equatable,
   Identifiable`), stored as JSON array under
   `openclicky.contextAwareness.knownApps`.
6. UserDefaults keys (all under `openclicky.contextAwareness.`):
   - `autoCaptureContext`
   - `agentAppId`
   - `launchPhrase`
   - `openDiaEnabled`
   - `cursorOverlayEnabled`
   - `knownApps`
7. Ship a `resetToEverywhereDefaults()` method the Settings panel can
   call from a "Reset to Everywhere defaults" button (panel wiring is a
   later agent's problem — we expose the method here).

## Everywhere → openclicky byte-parity table

| Everywhere field | openclicky default | keyCode | mod raw |
|---|---|---|---|
| SnapshotContext = Shift+Space | keyCode 49, mods maskShift | 49 | 0x00020000 |
| ClearContextStash = Alt+C | keyCode 8, mods maskAlternate | 8 | 0x00080000 |
| AgentPickElement = Alt+S | keyCode 1, mods maskAlternate | 1 | 0x00080000 |
| Whiteboard = Alt+D | keyCode 2, mods maskAlternate | 2 | 0x00080000 |
| LinkRect = Alt+L | keyCode 37, mods maskAlternate | 37 | 0x00080000 |

macOS virtual keycodes verified against Carbon `Events.h`: kVK_Space=49,
kVK_ANSI_C=8, kVK_ANSI_S=1, kVK_ANSI_D=2, kVK_ANSI_L=37.

## Test plan

`OpenClickyContextAwarenessDefaultsTests` (new file
`cursor-buddyTests/OpenClickyContextAwarenessDefaultsTests.swift`):

1. Fresh UserDefaults suite → binding(for: .snapshotContext) matches
   Shift+Space, enabled=true; ditto the other four.
2. Master toggle defaults to true when key is missing.
3. autoCaptureContext / openDiaEnabled default true;
   cursorOverlayEnabled default false.
4. agentAppId default "cmux"; launchPhrase default "take a look".
5. knownApps defaults to a single entry with pattern "^xlinkBook" and
   the localhost discover URL.
6. User override persists: setBinding(...) then re-init on the same
   suite → the override wins.
7. Clearing a binding (`setBinding(nil, ...)`) yields the unbound
   state — the "Everywhere seed" only fires when no stored value has
   ever existed.
8. `resetToEverywhereDefaults()` restores every field to the Everywhere
   values even after user overrides.

## Build verification

`bash /Users/wowdd1/Dev/openclicky/scripts/sign-and-install.sh` (result
appended to phase7-defaults-report-2026-07-23.md).
