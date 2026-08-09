# Parity Domain 1: Hotkeys + Context Awareness + Stash + Hook

Audit pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Openclicky HEAD as of 2026-07-23.

Scope: Everywhere settings surfaces that a user can flip in the app or in
`~/Library/Application Support/Everywhere/settings.json` for the
Snapshot/Clear/Pick/Whiteboard/LinkRect hotkey family, the MCP-server
block that decorates capture (agent app id, launch phrase, auto-capture,
known-apps table), and the stash file / hook binary the writer produces.

## Everywhere inventory (this domain)

Hotkey slots (`Everywhere.Core/Configuration/Settings/ShortcutSettings.cs`,
each is a `CompositeKeyboardShortcut` = `IsEnabled + Main + Alternative`
per `Everywhere.Core/Configuration/CompositeKeyboardShortcut.cs:10-35`):

1. `ShortcutSettings.ChatWindow` — `ShortcutSettings.cs:26`, default `Ctrl+Shift+E`. Opens the Everywhere chat window (not context awareness proper, but lives on the same Shortcut settings page).
2. `ShortcutSettings.PickVisualElement` — `ShortcutSettings.cs:32`, default unbound. UI-element picker for chat.
3. `ShortcutSettings.TakeScreenshot` — `ShortcutSettings.cs:38`, default unbound. Screenshot into chat.
4. `ShortcutSettings.AgentPickElement` — `ShortcutSettings.cs:47`. Pins UI element (`read_pick` slot) without opening chat. User's live config: `Alt+S`.
5. `ShortcutSettings.SnapshotContext` — `ShortcutSettings.cs:~60`. Writes context-stash.json. User's live config: `Shift+Space`.
6. `ShortcutSettings.ClearContextStash` — `ShortcutSettings.cs:~71`. Wipes stash + pin/whiteboard/annotation stashes. User's live config: `Alt+C`.
7. `ShortcutSettings.Whiteboard` — `ShortcutSettings.cs:83`. Press-hold gesture stash. User's live config: `Alt+D`.
8. `ShortcutSettings.LinkRect` — `ShortcutSettings.cs:94`. Press-drag hyperlink rect harvest. User's live config: `Alt+L`.
9. `CompositeKeyboardShortcut.IsEnabled` — `CompositeKeyboardShortcut.cs:13-17`. Per-slot enable toggle.
10. `CompositeKeyboardShortcut.Main` — `CompositeKeyboardShortcut.cs:20-25`. Primary chord.
11. `CompositeKeyboardShortcut.Alternative` — `CompositeKeyboardShortcut.cs:28-33`. Second chord for the same action.

McpServer block (`Everywhere.Core/Configuration/Settings/McpServerSettings.cs`):

12. `McpServer.HttpEnabled` — `McpServerSettings.cs:40`, default `true`. Bind the MCP loopback server.
13. `McpServer.HttpPort` — `McpServerSettings.cs:48`, default `7878`. Loopback port (1..65535, no slider).
14. `McpServer.AutoCaptureContext` — `McpServerSettings.cs:54`, default `false`. Auto-fire SnapshotContext on pin. User's live config: `true`.
15. `McpServer.OpenDiaEnabled` — `McpServerSettings.cs:68`, default `false`. OpenDia browser bridge (WebSocket for Chrome/Firefox ext). User's live config: `true`.
16. `McpServer.OpenDiaPort` — `McpServerSettings.cs:76`, default `5555`. Bridge port.
17. `McpServer.AgentAppId` — `McpServerSettings.cs:83`, default `""` (placeholder `com.github.cmux`). Target activated after write. User's live config: `cmux`.
18. `McpServer.LaunchPhrase` — `McpServerSettings.cs:97`, default `""` (placeholder `take a look`). Text typed + Return after activation. User's live config: `take a look`.
19. `McpServer.KnownApps` — `McpServerSettings.cs:109`, `ObservableCollection<KnownApp>`, `[SettingsItemIgnore]` — persisted but NOT rendered on the auto-generated Settings page. User's live config: one row `^xlinkBook -> http://localhost:5000/.well-known/agent-skills`.
20. `KnownApp.TitlePattern` — `McpServerSettings.cs:17`. Case-insensitive regex against frontmost window title.
21. `KnownApp.DiscoverUrl` — `McpServerSettings.cs:18`. Well-known agent-skills endpoint.
22. `McpServer.CursorOverlayEnabled` — `McpServerSettings.cs:126`, `[SettingsItemIgnore]`, default `false`. Software-cursor overlay. Explicitly hidden from Settings UI on macOS (comment `:114-119`); only editable via `settings.json`.

Stash writer + hook (no user-settable knobs, but part of the domain surface):

23. Stash path — `Everywhere.Mcp/Snapshot/StashPaths.cs:13-41`, `~/Library/Application Support/Everywhere/context-stash.json` on macOS.
24. Hook binary — `tools/everywhere-context-hook/` (Rust); path is fixed by convention, not a setting.
25. Repeat suppression window — `SnapshotContextHotkeyInitializer.cs:122` `RepeatSuppressionMs = 1500` (hard-coded).
26. macOS modifier-release delay — `SnapshotContextHotkeyInitializer.cs:107` `MacosModifierReleaseDelayMs = 180` (hard-coded).
27. LinkRect cap — `ContextStashWriter.cs:159` `MaxLinks = 200` (hard-coded).
28. LinkRect URL cap — `ContextStashWriter.cs:160` `MaxUrlLen = 2048` (hard-coded).
29. LinkRect title cap — `ContextStashWriter.cs:161` `MaxTitleLen = 200` (hard-coded).
30. Clipboard XLB link cap — `ContextStashWriter.cs:395` `MaxClipboardLinks = 200` (hard-coded).
31. Clipboard XLB URL cap — `ContextStashWriter.cs:396` `MaxClipboardUrlLen = 2048` (hard-coded).
32. Sanitiser caps — `ContextStashWriter.cs:622-641`: app_key 64, title 80, url 256, selection 200, anchor 200, body 800 (hard-coded).
33. URL redact param denylist — `ContextStashWriter.cs:448-455`: token/access_token/id_token/refresh_token/api_key/apikey/key/secret/client_secret/auth/authentication/password/pwd/sig/signature/session/sessionid (hard-coded).
34. Known-app regex timeout — `ContextStashWriter.cs:754` `100ms` (hard-coded).
35. Text-selection observer — **not present**. Auto-selection/clipboard auto-capture was intentionally removed (`AutoCaptureService.cs:11-15`). AutoCapture is now pin-only.

## Openclicky parity table

| # | Everywhere setting | Everywhere source | Openclicky storage | Openclicky UI | Verdict |
|---|---|---|---|---|---|
| 1 | Hotkey: ChatWindow | `ShortcutSettings.cs:26` | none | none | E — openclicky does not have an Everywhere-style chat window; product is a menu-bar overlay. Voice PTT hotkey lives in `GlobalPushToTalkShortcutMonitor.swift` (separate domain). |
| 2 | Hotkey: PickVisualElement | `ShortcutSettings.cs:32` | none | none | E — openclicky's element-pointing flow is voice-driven; there is no equivalent picker hotkey. |
| 3 | Hotkey: TakeScreenshot | `ShortcutSettings.cs:38` | none | none | E — openclicky uses in-app help/screen-capture flow, not a global hotkey. |
| 4 | Hotkey: AgentPickElement | `ShortcutSettings.cs:47` | `OpenClickyContextAwarenessSettings.swift:232-236` `defaultBinding_AgentPickElement` + `.agentPickElement` enum case | `OpenClickyContextAwarenessPanel.swift:84-93,95-138` `hotkeyBindingsGroup` row | A |
| 5 | Hotkey: SnapshotContext | `ShortcutSettings.cs:~60` | `OpenClickyContextAwarenessSettings.swift:222-226` `defaultBinding_SnapshotContext` | `OpenClickyContextAwarenessPanel.swift:84-138` | A |
| 6 | Hotkey: ClearContextStash | `ShortcutSettings.cs:~71` | `OpenClickyContextAwarenessSettings.swift:227-231` `defaultBinding_ClearContextStash` | `OpenClickyContextAwarenessPanel.swift:84-138` | A |
| 7 | Hotkey: Whiteboard | `ShortcutSettings.cs:83` | `OpenClickyContextAwarenessSettings.swift:237-241` `defaultBinding_Whiteboard` | `OpenClickyContextAwarenessPanel.swift:84-138` | A |
| 8 | Hotkey: LinkRect | `ShortcutSettings.cs:94` | `OpenClickyContextAwarenessSettings.swift:242-246` `defaultBinding_LinkRect` | `OpenClickyContextAwarenessPanel.swift:84-138` | A |
| 9 | Per-hotkey IsEnabled | `CompositeKeyboardShortcut.cs:13-17` | `OpenClickyContextAwarenessSettings.swift:101` `enabled` on binding; `setEnabled(_:for:)` at `:482-486` | `OpenClickyContextAwarenessPanel.swift:107-116` per-row `Toggle` | A |
| 10 | Per-hotkey Main chord | `CompositeKeyboardShortcut.cs:20-25` | `OpenClickyContextAwarenessSettings.swift:99-100` `keyCode`+`modifiers` | `OpenClickyContextAwarenessPanel.swift:118-127` "Change" -> `OpenClickyHotkeyRecorderSheet` (`:382-454`) | A |
| 11 | Per-hotkey Alternative chord | `CompositeKeyboardShortcut.cs:28-33` | none — single chord per action | none | **C** — Feature gap. openclicky's `OpenClickyHotkeyBinding` records exactly one `(keyCode, modifiers)` pair. No Alternative slot in storage or UI. |
| 12 | Master enable (context awareness) | none in Everywhere — every hotkey is individually toggleable | `OpenClickyContextAwarenessSettings.swift:168` `masterEnabledDefaultsKey` @ line 278 | `OpenClickyContextAwarenessPanel.swift:63-82` `masterToggleGroup` | D — Openclicky extra; useful ergonomic knob. Everywhere achieves same effect via each `IsEnabled`. |
| 13 | McpServer.HttpEnabled | `McpServerSettings.cs:40` | none | none | E — openclicky does not run its own MCP HTTP server surface. Voice/agent bridge is handled by CodexProcess / HeyClickyChromeBridgeServer, whose enable/disable lives elsewhere (out of this domain per task scope). Should be documented as intentional. |
| 14 | McpServer.HttpPort | `McpServerSettings.cs:48` | none | none | E — same. |
| 15 | McpServer.AutoCaptureContext | `McpServerSettings.cs:54` | `OpenClickyContextAwarenessSettings.swift:176` key, `:290-294` `@Published`, default `true` (`:255`) | `OpenClickyContextAwarenessPanel.swift:168-178` toggle inside `launchPhraseGroup` | A — note default differs (Everywhere default `false`; openclicky seeds `true` deliberately to match user's live Everywhere config — F22-hotkey-defaults-2026-07-23.md documents the choice). |
| 16 | McpServer.OpenDiaEnabled | `McpServerSettings.cs:68` | `OpenClickyContextAwarenessSettings.swift:188` key, `:308-312`, default `true` (`:258`) | **none** — no row in `OpenClickyContextAwarenessPanel.swift` (only mentioned in Everywhere-parity default seed) | **B** — Wire gap. Storage present, panel does not surface it. |
| 17 | McpServer.OpenDiaPort | `McpServerSettings.cs:76` | none | none | **C** — Feature gap. Openclicky's OpenDia bridge (see chrome-ext/) uses a hard-coded port (out of scope for exact confirmation here). |
| 18 | McpServer.AgentAppId | `McpServerSettings.cs:83` | `OpenClickyContextAwarenessSettings.swift:180` key, `:296-300`, default `"cmux"` (`:256`) | `OpenClickyContextAwarenessPanel.swift:148-155` `TextField` in `launchPhraseGroup` | A |
| 19 | McpServer.LaunchPhrase | `McpServerSettings.cs:97` | `OpenClickyContextAwarenessSettings.swift:184` key, `:302-306`, default `"take a look"` (`:257`) | `OpenClickyContextAwarenessPanel.swift:157-164` `TextField` | A |
| 20 | McpServer.KnownApps (collection) | `McpServerSettings.cs:109` | `OpenClickyContextAwarenessSettings.swift:196` key, `:320-326` `@Published var knownApps`, default one row (`:260-265`) | **none** — no add/edit/remove rows anywhere in `OpenClickyContextAwarenessPanel.swift` | **B** — Wire gap, CRITICAL. Storage exists and is honoured by the writer (`OpenClickyContextStashWriter.swift:522-530` `currentKnownAppRules()`), but the user cannot register a new local app from the UI. Everywhere itself also does not render this — `[SettingsItemIgnore]` — but the user must be able to edit `settings.json` by hand in both; openclicky users have no equivalent `settings.json` fallback. Openclicky must ship a proper editor because it is the only avenue. |
| 21 | KnownApp.TitlePattern | `McpServerSettings.cs:17` | `OpenClickyContextAwarenessSettings.swift:143` | none | **B** — Depends on row 20 editor. |
| 22 | KnownApp.DiscoverUrl | `McpServerSettings.cs:18` | `OpenClickyContextAwarenessSettings.swift:144` | none | **B** — Depends on row 20. |
| 23 | McpServer.CursorOverlayEnabled | `McpServerSettings.cs:126` (SettingsItemIgnore) | `OpenClickyContextAwarenessSettings.swift:192` key, `:314-318`, default `false` (`:259`) | none | E — Everywhere deliberately hides this on macOS (`McpServerSettings.cs:114-119` — OCCU Swift bridge owns cursor overlay). Openclicky mirrors the hide. Storage present for diagnostic parity only. |
| 24 | Stash file path | `StashPaths.cs:13-41` | `OpenClickyStashPaths.contextStash()` (referenced `OpenClickyContextStashWriter.swift:75`, `OpenClickyContextAwarenessPanel.swift:208`) — `~/Library/Application Support/OpenClicky/context-stash.json` | `OpenClickyContextAwarenessPanel.swift:206-230` `stashFileGroup` with Reveal | D — Openclicky extra: Everywhere has no Reveal-in-Finder UI. Nice-to-have addition. |
| 25 | Hook binary path/status | none surfaced in Everywhere UI (Rust binary lives in `tools/everywhere-context-hook`; user copies manually) | `OpenClickyContextAwarenessPanel.swift:232-257` `hookBinaryGroup` derived path + install-instructions modal | D — Openclicky extra. |
| 26 | "Fire test snapshot" | none in Everywhere (there is no such button on the Shortcut settings page) | `OpenClickyContextAwarenessPanel.swift:259-281` `sanityChecksGroup` calling `hotkeys.fireTestSnapshot()` | D — Openclicky extra. |
| 27 | "Reset to Everywhere defaults" | none | `OpenClickyContextAwarenessPanel.swift:283-306` `defaultsGroup` calling `settings.resetToEverywhereDefaults()` (`OpenClickyContextAwarenessSettings.swift:430-445`) | D — Openclicky extra. |
| 28 | Text-selection observer toggle | none — Everywhere removed passive selection capture (`AutoCaptureService.cs:11-15`) | `OpenClickyContextAwarenessSettings.swift:172` `autoSelectionObserverDefaultsKey`, `:284-288` `@Published`, default `false` (`:253`) | `OpenClickyContextAwarenessPanel.swift:185-204` `autoCaptureGroup` toggle | D — Openclicky extra; stub for a future observer (comment `OpenClickyContextAwarenessPanel.swift:192` notes wiring is deferred). Everywhere intentionally lacks this. |
| 29 | Repeat-suppression window (1500ms) | `SnapshotContextHotkeyInitializer.cs:122` (hard-coded) | `OpenClickyContextAwarenessSettings.swift:206` `repeatSuppressionInterval = 1.5` (hard-coded) | none in either | A — both hard-coded, byte-match. Not user-settable. |
| 30 | macOS modifier-release delay (180ms) | `SnapshotContextHotkeyInitializer.cs:107` | `OpenClickyContextAwarenessSettings.swift:212` `modifierReleaseDelay = 0.180` | none in either | A — hard-coded, byte-match. |
| 31 | Max LinkRect links (200) | `ContextStashWriter.cs:159` | `OpenClickyContextStashWriter.swift:414` `maxLinkRectLinks = 200` | none in either | A — hard-coded, byte-match. |
| 32 | Max LinkRect URL length (2048) | `ContextStashWriter.cs:160` | `OpenClickyContextStashWriter.swift:415` `maxLinkRectUrlLen = 2048` | none | A — byte-match. |
| 33 | Max LinkRect title length (200) | `ContextStashWriter.cs:161` | `OpenClickyContextStashWriter.swift:416` `maxLinkRectTitleLen = 200` | none | A — byte-match. |
| 34 | Max clipboard XLB links (200) | `ContextStashWriter.cs:395` | `OpenClickyContextStashWriter.swift:249` `maxClipboardLinks = 200` | none | A — byte-match. |
| 35 | Max clipboard XLB URL length (2048) | `ContextStashWriter.cs:396` | `OpenClickyContextStashWriter.swift:250` `maxClipboardUrlLen = 2048` | none | A — byte-match. |
| 36 | Sanitise caps (app 64, title 80, url 256, selection 200, anchor 200, body 800) | `ContextStashWriter.cs:622-673` | Lives in SPM package `OpenClickyContextService.OpenClickyStashFormatter.formatForHook` (see `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickyContextSnapshotPayload.swift:328+`) | none | A — byte-match, hard-coded. |
| 37 | URL redact query-param denylist | `ContextStashWriter.cs:448-455` | `OpenClickySanitiser.redactCredentials` in SPM package (called at `OpenClickyContextStashWriter.swift:140,272,357,440`) | none in either | A — hard-coded set, mirrored (see `Packages/OpenClickyContextService/...`). Not user-editable in Everywhere either. |
| 38 | Known-app regex timeout (100ms) | `ContextStashWriter.cs:754` | Lives in SPM `OpenClickyKnownAppResolver.resolveDiscoveryUrl` (`Packages/.../OpenClickyContextSnapshotPayload.swift:203-289`) | none | A — hard-coded parity. |
| 39 | Sentinel: first-launch seed guard | none | `OpenClickyContextAwarenessSettings.swift:201` `seededDefaultsSentinelKey` | none (implicit) | D — Openclicky extra for one-shot seeding. |

## Gap priority ordering

### CRITICAL wire gaps (storage exists, UI missing, user cannot reach)

- **Row 20/21/22 — KnownApps editor**. `OpenClickyContextAwarenessSettings.swift:320-326` holds `[OpenClickyKnownApp]` and the writer honours it (`OpenClickyContextStashWriter.swift:522-530`), but the panel has no add-row / edit / remove UI. Everywhere users can edit `~/Library/Application Support/Everywhere/settings.json` by hand; openclicky users cannot (the `com.jkneen.openclicky` UserDefaults store is opaque). This is the biggest asymmetry. Required for the xlinkBook `[openclicky-discover]` hint branch to be usable beyond the seeded default. Panel additions: table with `TitlePattern` and `DiscoverUrl` columns, `+ Add`, `- Remove`, regex validator preview mirroring `ResolveDiscoveryUrl` semantics (Uri.TryCreate + http/https only + 100ms timeout).

- **Row 16 — OpenDia enabled toggle**. `openDiaEnabled` @Published is present (`:308-312`) and defaults `true`, but there is no row in the panel to flip it. Users who want to disable the OpenDia bridge must clear UserDefaults from Terminal.

### MEDIUM wire gaps

None — every other openclicky @Published has a panel row.

### Feature gaps (both storage and UI missing in openclicky)

- **Row 11 — Per-hotkey Alternative chord**. Everywhere's `CompositeKeyboardShortcut` carries `Main` + `Alternative`; openclicky's `OpenClickyHotkeyBinding` is single-slot. Low-priority (user's live Everywhere config uses only `Main` for every action), but note it for future.

- **Row 17 — OpenDia port**. Everywhere lets the user override port `5555`. Openclicky bridge port is (presumably) hard-coded. Add if a user reports a conflict.

- **Row 13/14 — MCP HTTP server enable + port**. Out of this domain per the task's own scoping; flagging so it appears exactly once in the fleet audit.

### Openclicky extras (verify intentional)

- **Row 12 — masterEnabled toggle**. Ergonomic single kill-switch; Everywhere achieves the same with five individual `IsEnabled`. Keep.
- **Row 24 — Reveal-in-Finder for stash**. Nice UX. Keep.
- **Row 25 — Hook binary install instructions**. Everywhere users just read docs. Keep.
- **Row 26 — Fire test snapshot**. Debug affordance. Keep.
- **Row 27 — Reset to Everywhere defaults**. Sensible.
- **Row 28 — Text-selection observer toggle**. Marked as stub for a future observer (`OpenClickyContextAwarenessPanel.swift:190-193`). Everywhere deliberately removed this pathway (`AutoCaptureService.cs:11-15`). Decide: (a) delete the toggle until the observer is actually wired, or (b) document as "not-yet-wired preview". Currently the toggle persists a preference nothing reads.
- **Row 39 — Seed sentinel**. Internal detail, invisible; intentional.

### Intentional drops

- Rows 1, 2, 3 (ChatWindow / PickVisualElement / TakeScreenshot hotkeys). Openclicky is a voice/menubar-first product with a different UI shape; no equivalent hotkey action. Document in a top-level parity note if not already.
- Row 23 (CursorOverlayEnabled). Both Everywhere and openclicky hide this on macOS by design; the OCCU Swift bridge / openclicky overlay owns the cursor overlay.

## Notes on defaults vs. Everywhere upstream vs. user's live config

Openclicky seeds its first-launch defaults from the **user's live Everywhere `settings.json`**, NOT from Everywhere source-code defaults. Documented at `OpenClickyContextAwarenessSettings.swift:7-16` and `docs/ROADMAP/.impl-notes/phase7-defaults-2026-07-23.md`. Consequences for byte-match:

- `AutoCaptureContext`: upstream default `false` (`McpServerSettings.cs:54`), user's live `true`, openclicky default `true`. Deliberate.
- `OpenDiaEnabled`: upstream `false`, user's live `true`, openclicky `true`. Deliberate.
- `AgentAppId`: upstream `""`, user's live `"cmux"`, openclicky `"cmux"`. Deliberate.
- `LaunchPhrase`: upstream `""`, user's live `"take a look"`, openclicky `"take a look"`. Deliberate.
- `KnownApps`: upstream `[]`, user's live one xlinkBook row, openclicky one xlinkBook row (`OpenClickyContextAwarenessSettings.swift:260-265`). Deliberate.
- Five hotkey chords: match user's live config (`Shift+Space`, `Alt+C/S/D/L`).

If parity is judged against upstream Everywhere defaults instead, rows 15, 16, 18, 19, 20 all diverge — but that would defeat the drop-in-replacement intent.

## Files inspected

- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Configuration/Settings/ShortcutSettings.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Configuration/Settings/McpServerSettings.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Configuration/CompositeKeyboardShortcut.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/StashPaths.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/AutoCaptureService.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs`
- `~/Library/Application Support/Everywhere/settings.json` (user's live config)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextAwarenessSettings.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextAwarenessPanel.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextStashWriter.swift`
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickyContextSnapshotPayload.swift`

No code modified. Read-only audit.
