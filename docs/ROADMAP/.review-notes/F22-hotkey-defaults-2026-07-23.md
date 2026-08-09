# F22 — Hotkey + Settings tab + Everywhere-parity defaults

Everywhere pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Date: 2026-07-23

## Alignment Table

### Hotkey bindings (defaults)

Everywhere source of truth = user `~/Library/Application Support/Everywhere/settings.json` (values below verified verbatim):
`{"AgentPickElement":{"Main":{"Key":"S","Modifiers":"Alt"}},"SnapshotContext":{"Main":{"Key":"Space","Modifiers":"Shift"},"IsEnabled":true},"ClearContextStash":{"Main":{"Key":"C","Modifiers":"Alt"}},"Whiteboard":{"Main":{"Key":"D","Modifiers":"Alt"}},"LinkRect":{"Main":{"Key":"L","Modifiers":"Alt"}}}`

The Everywhere `ShortcutSettings.cs:22-95` default is empty `new CompositeKeyboardShortcut()` for all five (ChatWindow is the only pre-seeded one), so parity here is against the user's *live* customised config, not the compiled `ShortcutSettings.cs` defaults.

| Action | Everywhere user setting | OpenClicky default (`cursor-buddy/OpenClickyContextAwarenessSettings.swift`) | Status |
|---|---|---|---|
| SnapshotContext | Key=Space, Modifiers=Shift, IsEnabled=true | `:222-226` `keyCode: 49 // kVK_Space`, `modifiers: CGEventFlags.maskShift.rawValue`, `enabled: true` | Match. Comment `:223` correctly cites `kVK_Space = 49`. |
| ClearContextStash | Key=C, Modifiers=Alt | `:227-231` `keyCode: 8 // kVK_ANSI_C`, `modifiers: CGEventFlags.maskAlternate.rawValue`, `enabled: true` | Match |
| AgentPickElement | Key=S, Modifiers=Alt | `:232-236` `keyCode: 1 // kVK_ANSI_S`, `modifiers: CGEventFlags.maskAlternate.rawValue`, `enabled: true` | Match |
| Whiteboard | Key=D, Modifiers=Alt | `:237-241` `keyCode: 2 // kVK_ANSI_D`, `modifiers: CGEventFlags.maskAlternate.rawValue`, `enabled: true` | Match |
| LinkRect | Key=L, Modifiers=Alt | `:242-246` `keyCode: 37 // kVK_ANSI_L`, `modifiers: CGEventFlags.maskAlternate.rawValue`, `enabled: true` | Match |

### Scalar defaults (McpServer block)

| Field | Everywhere user setting | OpenClicky default | Status |
|---|---|---|---|
| Master toggle | (implicit; SnapshotContext.IsEnabled=true) | `OpenClickyContextAwarenessSettings.swift:249` `defaultMasterEnabled = true` | Match |
| `agentAppId` | `"cmux"` | `:256` `defaultAgentAppId = "cmux"` | Match |
| `launchPhrase` | `"take a look"` | `:257` `defaultLaunchPhrase = "take a look"` | Match |
| `autoCaptureContext` | `true` | `:255` `defaultAutoCaptureContext = true` | Match |
| `openDiaEnabled` | `true` | `:258` `defaultOpenDiaEnabled = true` | Match |
| `cursorOverlayEnabled` | `false` | `:259` `defaultCursorOverlayEnabled = false` | Match |
| `knownApps` | `[{TitlePattern:"^xlinkBook",DiscoverUrl:"http://localhost:5000/.well-known/agent-skills"}]` | `:260-265` same, single-entry | Match |

### Timing constants (byte-match Everywhere)

| Constant | Everywhere (`Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs`) | OpenClicky | Status |
|---|---|---|---|
| `RepeatSuppressionMs = 1500` | `:122` `private const int RepeatSuppressionMs = 1500;` | `OpenClickyContextAwarenessSettings.swift:206` `static let repeatSuppressionInterval: TimeInterval = 1.5` (1.5 s = 1500 ms), consumed by `OpenClickyContextHotkeys.swift:210` | Match |
| `MacosModifierReleaseDelayMs = 180` | `:107` `private const int MacosModifierReleaseDelayMs = 180;` | `OpenClickyContextAwarenessSettings.swift:212` `static let modifierReleaseDelay: TimeInterval = 0.180`, consumed by `OpenClickyContextHotkeys.swift:220` | Match |

Cross-check against prompt's line numbers: prompt says `.cs:122` for `RepeatSuppressionMs` and `.cs:107` for `MacosModifierReleaseDelayMs`; the file's live content confirms both (`SnapshotContextHotkeyInitializer.cs:107` for the delay comment header, `:122` for the field).

### Sentinel key

| Aspect | Everywhere | OpenClicky | Status |
|---|---|---|---|
| Sentinel default key | n/a — Everywhere reads directly from `settings.json` | `OpenClickyContextAwarenessSettings.swift:201` `static let seededDefaultsSentinelKey = "openclicky.contextAwareness.seededEverywhereDefaults"` | Present, exact string as specified in prompt |
| One-shot semantics | n/a | `:340` `alreadySeeded = defaults.bool(...)`; per-action loop `:406-417` only seeds a binding when the slot key is missing AND `!alreadySeeded`; sentinel flipped `:420-422` | Correct: after first launch, cleared bindings stay cleared |
| Reset re-arms sentinel | n/a | `:444` `defaults.set(true, forKey: Self.seededDefaultsSentinelKey)` inside `resetToEverywhereDefaults()` | Correct |

### CGEventTap plumbing

| Aspect | Everywhere (`Everywhere.Mac/Interop/CGEventListener.cs`) | OpenClicky (`cursor-buddy/OpenClickyContextHotkeys.swift`) | Status |
|---|---|---|---|
| Tap location | `:70` `CGEventTapLocation.HID` (= `.cghidEventTap`) | `:106` `tap: .cgSessionEventTap` | **Divergence.** See Issue 1. |
| Placement | `:71` `CGEventTapPlacement.HeadInsert` | `:107` `place: .headInsertEventTap` | Match |
| Options | `_options` field (call-site injected; used for either listen-only or default). Everywhere's `CGEventShortcutListener` uses the tap to *swallow* keys during capture (`:73` `cgEventRef = 0`), which requires non-listen-only mode. | `:108` `options: .listenOnly` — OpenClicky can never swallow (fine, since we do not swallow); recorder sheet uses `NSEvent.addLocalMonitorForEvents` (`OpenClickyContextAwarenessPanel.swift:359`) instead | Divergent by design |
| Event types | `CGEventListener.cs:63-67` KeyDown+KeyUp+FlagsChanged+all 6 mouse types | `OpenClickyContextHotkeys.swift:89` `[.keyDown, .keyUp]` only | Reduced set (no FlagsChanged, no mouse) — acceptable if hotkeys are keyboard-only, but see Issue 3 |
| Tap disabled re-enable | `CGEventListener.cs:85-89` re-enables on `TapDisabledByTimeout / ByUserInput` | `OpenClickyContextHotkeys.swift:143-148` same handling | Match |
| Repeat suppression | `SnapshotContextHotkeyInitializer.cs:124-141` per-shortcut via `Interlocked` on `_lastAcceptedPressTicks` (SnapshotContext only) | `OpenClickyContextHotkeys.swift:208-213` per-action via `lastFireByAction[action]` dict, main-queue serialised | Semantically equivalent, coverage broader (all 5 actions vs Everywhere's SnapshotContext-only) — **improvement over Everywhere** |
| Modifier release delay | `SnapshotContextHotkeyInitializer.cs:146-152` `await Task.Delay(180)` before capture, macOS-only guard | `OpenClickyContextHotkeys.swift:219-223` `DispatchQueue.main.asyncAfter(deadline: .now() + 0.180)`, applied to all actions except whiteboard (`:214-218` skips delay to open overlay synchronously). | Correct + reasoned whiteboard carve-out. |

### Settings tab wiring

| Item | Everywhere | OpenClicky | Status |
|---|---|---|---|
| Panel present | Avalonia settings screen | `cursor-buddy/OpenClickyContextAwarenessPanel.swift` (383 lines) | Present |
| Registered in Settings window | Avalonia routing | `cursor-buddy/OpenClickySettingsWindowManager.swift:143` `case contextAwareness`; `:157` title `"Context Awareness"`; `:171` icon `"eye"`; `:477`, `:547-548` panel dispatch; `:2454-2459` panel builder passes `OpenClickyContextAwarenessSettings.shared` + `companionManager.contextAwarenessHotkeys` | Wired |
| Master toggle | Avalonia setting | `OpenClickyContextAwarenessPanel.swift:61-80` master toggle group binds to `$settings.masterEnabled` | Present |
| Change-binding recorder | Avalonia `KeyboardShortcutInputBox` | `OpenClickyContextAwarenessPanel.swift:310-382` `OpenClickyHotkeyRecorderSheet` — `NSEvent.addLocalMonitorForEvents(.keyDown)` (`:359`), Escape cancels (`:363-366`), requires at least one modifier before Save enables (`:349`) | Present |
| Reset-to-Everywhere-defaults button | n/a | `OpenClickyContextAwarenessSettings.swift:427-445` `resetToEverywhereDefaults()` method exists — but grep for callers finds **zero UI wiring**. `OpenClickyContextAwarenessPanel.swift` has masterToggleGroup / hotkeyBindingsGroup / autoCaptureGroup / stashFileGroup / hookBinaryGroup / sanityChecksGroup only. See Issue 2. | **Missing UI wire** |

### CompanionManager wire

| Aspect | Location | Status |
|---|---|---|
| Singleton instance | `cursor-buddy/CompanionManager.swift:605` `let contextAwarenessHotkeys = OpenClickyContextHotkeys()` | Present |
| Start on accessibility grant | `CompanionManager.swift:4141` `contextAwarenessHotkeys.start()` inside `currentlyHasAccessibility` branch (`:4136`) | Correct — matches PTT monitor gate (`:4137`) |
| Stop on revoke | `CompanionManager.swift:4162` `contextAwarenessHotkeys.stop()` in else branch; `:4062` also stopped alongside PTT teardown | Present |

## Issues

1. **Tap location divergence: `.cgSessionEventTap` vs Everywhere's `.cghidEventTap`.** `OpenClickyContextHotkeys.swift:106` uses `.cgSessionEventTap`; `Everywhere.Mac/Interop/CGEventListener.cs:70` uses `CGEventTapLocation.HID` (= `.cghidEventTap`). Practical difference: `.cghidEventTap` sees events before OS input processing (higher priority, catches key repeats and remapped keys earlier); `.cgSessionEventTap` sees events after session-level filtering. For read-only shortcut detection either works, but Everywhere-parity strictly requires `.cghidEventTap`. Prompt explicitly asks to "verify which Everywhere uses" — answer: **HID**, and OpenClicky diverges.

2. **`resetToEverywhereDefaults()` implemented but not surfaced in UI.** `OpenClickyContextAwarenessSettings.swift:427-445` implements the reset; `OpenClickyContextAwarenessPanel.swift` never calls it. Grep `resetToEverywhereDefaults` returns exactly one hit (the definition). Prompt requires a "Reset-to-Everywhere-defaults button" in the settings panel. **Missing.**

3. **No `FlagsChanged` in the event mask.** `OpenClickyContextHotkeys.swift:89` monitors `.keyDown` + `.keyUp` only. Everywhere adds `.flagsChanged` (`CGEventListener.cs:64`). For pure keyboard-shortcut dispatch on modifier+letter chords this is fine, but any future feature that binds a pure-modifier chord (e.g. double-tap Shift) or needs to observe modifier state independently will need it. Not a parity blocker for the five current actions.

4. **Prompt claim "5 actions default = unbound" contradicts code.** The prompt's checklist header says defaults are byte-matched to Everywhere's user config (all five bound), but a comment inside `OpenClickyContextHotkeys.swift:17-19` still reads: *"All five default UNBOUND (verbatim parity with Everywhere's `ShortcutSettings.cs` @30e03e9d where only `ChatWindow` is bound)."* This stale comment contradicts `OpenClickyContextAwarenessSettings.swift:222-246`, which does bind all five. The runtime behaviour is correct (bindings seed); the comment is misleading. Minor docs bug.

5. **`OpenClickyContextAwarenessPanel.swift:68` master-toggle subtitle says "Off by default."** Contradicts the actual default (`defaultMasterEnabled = true`, `:249`). Minor copy bug.

6. **`OpenClickyContextAwarenessSettings.swift:391-399` seeds `knownApps` independent of the sentinel.** Distinct from bindings which respect `alreadySeeded` (`:410`); knownApps re-populates whenever the JSON key is missing. If the user clears via the UI, the array is stored as JSON `[]` (`:322-325`), so the row does not re-populate. Only relevant if the UserDefaults data key is deleted externally.

7. **`OpenClickyKnownApp` lives in `cursor-buddy/`, not `Types/CaptureTypes.swift`.** Prompt-provided file path claim ("Types/CaptureTypes.swift: OpenClickyKnownApp") is unfounded — grep of that file returns zero matches. The type sits in `OpenClickyContextAwarenessSettings.swift:142-154`, not the shared package. Documented under F21 as well; noted here since prompt implicated F22 alignment.

## Verdict

**Partially ready.**

Solid:
- All five default bindings byte-match the user's live Everywhere `settings.json` (keyCode, modifier flag, enabled).
- All seven scalar McpServer defaults match (`masterEnabled`, `agentAppId`, `launchPhrase`, `autoCaptureContext`, `openDiaEnabled`, `cursorOverlayEnabled`, `knownApps` seed).
- Timing constants `RepeatSuppressionMs = 1500` and `MacosModifierReleaseDelayMs = 180` byte-match Everywhere source (`SnapshotContextHotkeyInitializer.cs:122` and `:107`).
- Sentinel key exact string match; one-shot semantics correct; cleared bindings stay cleared on re-launch.
- Repeat suppression + release delay actually applied per-action (broader coverage than Everywhere's SnapshotContext-only guard).
- Settings tab registered in the window manager (`OpenClickySettingsWindowManager.swift:143,157,171,477,547,2454`).
- Change-binding recorder + Escape cancel + modifier requirement all present.
- CompanionManager start/stop gated on Accessibility grant, symmetrical (start `:4141`, stop `:4062,4162`).

Blockers:
- **Tap location wrong:** must switch `OpenClickyContextHotkeys.swift:106` from `.cgSessionEventTap` to `.cghidEventTap` to match Everywhere.
- **Reset button missing from panel UI:** `resetToEverywhereDefaults()` (`OpenClickyContextAwarenessSettings.swift:430`) has no caller. Add a footer/menu action in `OpenClickyContextAwarenessPanel.swift`.

Minor:
- Fix stale comments in `OpenClickyContextHotkeys.swift:17-19` and `OpenClickyContextAwarenessPanel.swift:68` (both claim defaults are off/unbound, contradicting the seeded values).

Files reviewed:
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextAwarenessSettings.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextAwarenessPanel.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickySettingsWindowManager.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CompanionManager.swift` (lines 600-610, 4130-4170)
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Configuration/Settings/ShortcutSettings.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Configuration/Settings/McpServerSettings.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/CGEventListener.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/CGEventShortcutListener.cs`
- `~/Library/Application Support/Everywhere/settings.json` (user's live config)
