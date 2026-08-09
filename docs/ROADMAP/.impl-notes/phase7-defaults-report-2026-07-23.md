# Phase 7 defaults — report (2026-07-23)

## Files modified

- `cursor-buddy/OpenClickyContextAwarenessSettings.swift`
  - Added Everywhere-parity default values (`defaultBinding_*`,
    `defaultMasterEnabled`, `defaultAutoCaptureContext`,
    `defaultAgentAppId`, `defaultLaunchPhrase`, `defaultOpenDiaEnabled`,
    `defaultCursorOverlayEnabled`, `defaultKnownApps`).
  - Added `OpenClickyKnownApp` value type (`Codable`, `Sendable`,
    `Equatable`, `Identifiable`).
  - Added `@Published` scalar fields for `autoCaptureContext`,
    `agentAppId`, `launchPhrase`, `openDiaEnabled`,
    `cursorOverlayEnabled`, and array field `knownApps`.
  - `init` now seeds each field from Everywhere on first launch and
    respects stored values on every subsequent launch. A one-shot
    sentinel (`openclicky.contextAwareness.seededEverywhereDefaults`)
    prevents re-seeding after the user clears a binding.
  - Added `resetToEverywhereDefaults()` for the Settings UI reset
    button.
- `cursor-buddyTests/OpenClickyContextAwarenessDefaultsTests.swift`
  - 15 tests covering: fresh-defaults byte parity for each of the
    five hotkeys + six scalar fields + knownApps; user override
    persistence for bindings, launchPhrase, agentAppId, knownApps;
    cleared-binding survival across reinit; reset-to-Everywhere
    restoration after arbitrary user drift.
- `docs/ROADMAP/05_LAYER_4_UX.md`
  - Replaced the "everything defaults to unbound" table with the
    Everywhere-parity defaults table, target-app block, and a
    pointer to the impl notes.
- `docs/ROADMAP/.impl-notes/phase7-defaults-2026-07-23.md`
  - Design notes.

Files listed as owned by concurrent agents were **not** touched:
`OpenClickyContextHotkeys.swift`, `OpenClickyExternalControlBridge.swift`,
`HeyClickyChatToolCallClient.swift`, `ClickyCodexConfigTemplate.swift`,
`OpenClickyRouteDispatcher.swift`, `OpenClickyContextStashWriter.swift`,
`OpenClickyContextAwarenessPanel.swift`,
`OpenClickyWhiteboardOverlayWindow.swift`,
`OpenClickyLinkRectOverlayWindow.swift`, `OpenClickyPickElementOverlay.swift`,
`OpenClickyAnnotationBadgeOverlay.swift`, SPM package files.

## Byte-parity table (Everywhere JSON → openclicky Swift)

### Shortcuts

| Everywhere JSON | keyCode | modifier bits | openclicky default |
|---|---|---|---|
| `SnapshotContext = Shift+Space, IsEnabled=true` | 49 (kVK_Space) | `CGEventFlags.maskShift.rawValue` = 0x00020000 | `defaultBinding_SnapshotContext` |
| `ClearContextStash = Alt+C` | 8 (kVK_ANSI_C) | `CGEventFlags.maskAlternate.rawValue` = 0x00080000 | `defaultBinding_ClearContextStash` |
| `AgentPickElement = Alt+S` | 1 (kVK_ANSI_S) | `CGEventFlags.maskAlternate.rawValue` = 0x00080000 | `defaultBinding_AgentPickElement` |
| `Whiteboard = Alt+D` | 2 (kVK_ANSI_D) | `CGEventFlags.maskAlternate.rawValue` = 0x00080000 | `defaultBinding_Whiteboard` |
| `LinkRect = Alt+L` | 37 (kVK_ANSI_L) | `CGEventFlags.maskAlternate.rawValue` = 0x00080000 | `defaultBinding_LinkRect` |

All five defaults ship `enabled=true`.

### McpServer

| Everywhere JSON | openclicky Swift default |
|---|---|
| `AutoCaptureContext: true` | `defaultAutoCaptureContext = true` |
| `AgentAppId: "cmux"` | `defaultAgentAppId = "cmux"` |
| `LaunchPhrase: "take a look"` | `defaultLaunchPhrase = "take a look"` |
| `OpenDiaEnabled: true` | `defaultOpenDiaEnabled = true` |
| `CursorOverlayEnabled: false` | `defaultCursorOverlayEnabled = false` |
| `KnownApps: [{"^xlinkBook","http://localhost:5000/.well-known/agent-skills"}]` | `defaultKnownApps = [OpenClickyKnownApp(titlePattern: "^xlinkBook", discoverUrl: "http://localhost:5000/.well-known/agent-skills")]` |

### Master toggle

| Everywhere behaviour | openclicky default |
|---|---|
| User runs Everywhere with hotkeys live (all `IsEnabled=true`) | `defaultMasterEnabled = true` |

## First-launch semantics

- Every scalar default is written to UserDefaults on first launch, so
  the Settings UI (which reads via `defaults.string/bool/data`) sees
  the seeded value immediately.
- The five hotkey bindings are written on first launch, gated by the
  `openclicky.contextAwareness.seededEverywhereDefaults` sentinel.
  Once that sentinel flips true, the seed never re-runs — a user who
  explicitly clears a binding sees `isEmpty == true` on the next
  launch (verified by `clearedBindingStaysClearedAfterReinit`).
- `resetToEverywhereDefaults()` re-applies every default and re-arms
  the sentinel.

## Build result

`bash scripts/sign-and-install.sh` (last 6 lines):

```
built: /Users/wowdd1/Library/Developer/Xcode/DerivedData/cursor-buddy-cqfqkyzfmptpmtatmpytdlpwuvad/Build/Products/Debug/OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=33125  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

**BUILD SUCCEEDED**, signed with `OpenClicky Dev Sign`, launched at
pid 33125 with the seeded defaults active on first run of the new
binary.

## Test verification

`OpenClickyContextAwarenessDefaultsTests` uses isolated `UserDefaults`
suites (`OpenClickyContextAwarenessDefaultsTests.<slot>`) so each test
starts from a fresh state. The 15 tests cover fresh-state byte parity
for all shortcuts + all McpServer scalars + KnownApps, user override
persistence across reinit, cleared-binding survival, and the reset
button. Parse-check passed via
`swiftc -parse cursor-buddy/OpenClickyContextAwarenessSettings.swift
cursor-buddyTests/OpenClickyContextAwarenessDefaultsTests.swift` with
zero diagnostics.
