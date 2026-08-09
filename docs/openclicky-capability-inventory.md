# OpenClicky Capability Inventory

Source-of-truth audit of what the OpenClicky macOS menu-bar app already ships. Intended as a shared substrate reference before wiring additional integrations. All paths absolute under `/Users/wowdd1/Dev/openclicky/cursor-buddy/`.

Product identity: `com.jkneen.openclicky`, `LSUIElement=true`, SwiftUI + AppKit, Sparkle-updated, non-sandboxed (`com.apple.security.app-sandbox=false`, group `group.com.jkneen.openclicky`).

---

## 1. Menu-bar App Shell

### 1.1 Entry point (`cursor_buddyApp.swift`, 385 lines)

| Symbol | Role |
|---|---|
| `cursor_buddyApp` (`@main`) | SwiftUI `App`. Only `Settings { EmptyView() }` scene; real UI is AppKit-hosted. Adds top-level `CommandMenu("Tools")` with shortcuts: Visual Intelligence (`Cmd+Opt+V`), Meeting Notes (`Cmd+Opt+M`), Browser Workspace (`Cmd+Opt+B`), Memory Browser, Open Memory File, Open Skills Folder, Log Viewer, Settings. |
| `CompanionAppDelegate` | `NSApplicationDelegate` + Sparkle updater delegate. Owns lifetime. |
| `applicationDidFinishLaunching` | Boots subsystems (see below). |

Boot sequence:
1. `OpenClickyAgentsSocketServer.shared.start()`.
2. Duplicate-instance guard: terminates other PIDs with same bundle id, polls up to 150 ms.
3. If real `com.humansongs.clicky` HeyClicky.app is running, `NSApp.terminate` (they share global hotkeys and OAuth scheme).
4. `AppBundleConfiguration.registerDefaults()`.
5. `OpenClickyMessageLogStore.pruneOldMessageLogs()` + hourly re-prune timer.
6. `OpenClickyContextServiceLogBridge.install()` — forwards AX / AppleScript / CGEvent boundary logs from `OpenClickyContextService` package into in-process `HeyClickyLog` (surfaced by `/agent/log/tail`).
7. `ClickyAnalytics.configure()` + `ClickyAnalytics.trackAppOpened()`.
8. `OpenClickyDesktopNotificationCenter.shared.configure()`.
9. `OpenClickyLocaleManager.shared` (bundle-swizzle for en / zh-Hans).
10. `MenuBarPanelManager(companionManager:)` (creates status item + floating panel).
11. `CompanionManager.start()`.
12. `scheduleWidgetSnapshotPublish()`.
13. `reconcileLoginItemFromUserPreference()` (SMAppService, strict opt-in).
14. `startSparkleUpdater()` (feed `https://raw.githubusercontent.com/jasonkneen/openclicky/main/appcast.xml`, optional `OpenClickySparkleFeedURLOverride`).
15. On first launch (before onboarding), auto-open the panel after 0.4 s.
16. `OpenClickyConnectorSettings.autostartIfEnabled()` — Node open-connector subprocess (F29, opt-in).
17. `OpenClickyOpenCLISettings.autostartIfEnabled()` — Node OpenCLI subprocess (F30, opt-in).
18. `OpenClickyOpenDiaSettings.autostartIfEnabled()` — Node OpenDia subprocess (F31, port `[56000,57000)`; browser extension is user-installed).
19. `logWindowStartupSnapshot()` — diagnostic dump of every `NSWindow` for overlay-leak audits.

On `applicationWillTerminate`: `companionManager.stop()`, stop Connector / OpenCLI / OpenDia subprocesses + OAuth callback, `WhisperCppShutdown.freeAll()` (avoids ggml-metal destructor race with AppKit exit).

URL schemes registered (Info.plist): `openclicky://`, `clicky://`, `heyclicky://`. `application(_:open:)` forwards each URL to `CompanionManager.handleApplicationOpenURL`.

### 1.2 Windows/surfaces

| Surface | Class | Purpose / trigger |
|---|---|---|
| Menu-bar item + floating panel | `MenuBarPanelManager` (1589 LOC) | Status-item icon + click-to-open floating panel with settings/onboarding. |
| Per-screen overlay | `OverlayWindow` + `OverlayWindowManager` (3683 LOC total) | Cursor overlay, agent dock icons, captions, response cards, buddy pet. One `OverlayWindow` per active `NSScreen`. |
| Dynamic notch | `OpenClickyDynamicNotchKitBridge` (1464 LOC) | Uses DynamicNotchKit to reflect voice phase (`idle`/`listening`/`thinking`/`speaking`) + captions + provider chips. |
| Codex HUD | `CodexHUDWindowManager` (1932 LOC, `show(...)` / `hide()`) | Agent Mode dashboard: task progress, tool calls, output stream, transcripts, plans. |
| Chat workspace | `ChatWorkspaceView` (415 LOC) | Three-pane composer: `ConversationSidebarView` (collapsible to 0) \| chat + composer \| optional `MemoryDrawerView`. Presented via `OpenClickyManagedWindowController`. |
| Mini chat panel | `MiniChatPanelManager` (1560 LOC) — `show(session:companion:)` | Compact live chat over a running `CodexAgentSession`. |
| Settings window | `OpenClickySettingsWindowManager` | Full settings dialog, hosts Advanced Providers, Automations, Chrome Bridge, Connectors, OpenCLI, OpenDia sections. |
| Memory browser | `MemoryDrawerView` (202 LOC) | Right-slide drawer + standalone window. Reads `CodexHomeManager.persistentMemoryFile` (`memory.md`) + per-session memories directory. |
| Log viewer | `OpenClickyLogViewerWindowManager` (19.8 K) | Tail HeyClickyLog / OpenClickyContextService trace. |
| Visual Intelligence | `OpenClickyVisualIntelligenceWorkspace` | Camera + screen inspection workspace. |
| Browser workspace | `OpenClickyBrowserWorkspaceWindowManager` (external `OpenClickyBrowser` package) | Chromium-side workspace surface. |
| Whiteboard overlay | `OpenClickyWhiteboardOverlayWindow` + `OpenClickyWhiteboardStrokeClassifier` | Screen-wide freehand stash, stroke ML classification. |
| Notch-capture window | `OpenClickyNotchCaptureWindowManager` | Screenshot preview surface. |
| Link-rect overlay | `OpenClickyLinkRectOverlayWindow` + `OpenClickyLinkRectHarvester` | Numbered link overlay ala Vimium. |
| Pick-element overlay | `OpenClickyPickElementOverlay` | Passive crosshair; user click writes to `PickStash` for `read_pick`. |
| Annotation badges | `OpenClickyAnnotationBadgeOverlay` (31.8 K) | Screen-wide anchor badges. |
| SKI approve overlay | `SKIModeApproveOverlay` | Push-to-approve UI for hands-free SKI turns. |
| 3D viewer | `ThreeDViewerWindowManager` + `ThreeDViewerView` | Tripo-generated model viewer. |

### 1.3 Chat workspace + conversation sidebar

- `ChatWorkspaceView` composes: `ConversationSidebarView` on the left (history, drill-through), a chat pane embedding `CodexHUDView` body with the top header bar and bottom composer (`ChatHeaderBar`, ChatGPT-style composer), and `MemoryDrawerView` on the right.
- Live agent tasks are surfaced via `agentTeamStrip` at the top of the chat pane, driven by `AgentDockStore`.
- The sidebar hides fully at width 0 (single collapse toggle in the header bar).

---

## 2. Voice Pipeline

Push-to-talk trigger → STT → provider switch → TTS. End-to-end owned by `CompanionManager` (19 119 LOC) with three key extensions.

### 2.1 Push-to-talk

`GlobalPushToTalkShortcutMonitor.swift` (268 LOC).

- `start()` installs a **listen-only** `CGEventTap` on `.flagsChanged | .keyDown | .keyUp` (main run loop). Restart-guarded so permission-polling doesn't reset live state.
- Emits `shortcutTransitionPublisher: BuddyPushToTalkShortcut.ShortcutTransition`.
- Also detects `shiftDoubleTap` (`≤240 ms`, standalone hold `≤180 ms`) → `PassthroughSubject<CGPoint, Never>` and `escapeKey` events.
- `@Published isShortcutCurrentlyPressed` drives waveform overlay directly.

### 2.2 STT — `BuddyTranscriptionProvider` protocol

Enum `BuddyTranscriptionProviderID` cases: `.automatic`, `.parakeet`, `.whisperLocal`, `.appleSpeech`, `.assemblyAI`, `.deepgram`, `.openAI` (Whisper), `.heyclickyFree`. Factory `BuddyTranscriptionProviderFactory` in the same file:

- `providerIDsForSelectionGrid()` filters to only-installed providers (Parakeet/Whisper model files + HeyClicky sign-in).
- `resolveProviderSelection(preferredProvider:)` fallback order when preferred is unavailable: Parakeet → Whisper (offline zh) → AssemblyAI → Deepgram → OpenAI → Apple Speech.
- Concrete providers:
  - `OpenClickyParakeetTranscriptionProvider` (`OpenClickyParakeetTranscriptionProvider.swift`)
  - `WhisperLocalTranscriptionProvider` (`WhisperLocalTranscriptionProvider.swift`) + `WhisperLocalModelManager`
  - `AppleSpeechTranscriptionProvider` (`AppleSpeechTranscriptionProvider.swift`)
  - `AssemblyAIStreamingTranscriptionProvider` (17.6 K)
  - `DeepgramStreamingTranscriptionProvider` (14.4 K)
  - `OpenAIAudioTranscriptionProvider` (10.6 K)
  - `HeyClickyProxyTranscriptionProvider` (3.9 K)

Sessions conform to `BuddyStreamingTranscriptionSession { appendAudioBuffer / requestFinalTranscript / cancel }`.

Dictation runtime: `BuddyDictationManager.swift` (51.6 K) owns the AVAudioEngine tap, silence VAD (`SileroVADTrim`), and stream lifecycle.

### 2.3 Voice → LLM entry point

`CompanionManager+AIResponsePipeline.swift` — `_analyzeVoiceResponseCore` at line 556.

Provider switch at line 734 dispatches on `selectedVoiceResponseModel.provider` (`OpenClickyModelProvider`):

| Provider | Path |
|---|---|
| `.apple` | `AppleFoundationModelsVoiceClient.analyzeVoiceResponse` (`AppleFoundationModelsVoiceClient.swift`, macOS 26 on-device, text-only, no images). |
| `.anthropic` | `analyzeClaudeResponse` → `ClaudeAgentSDKAPI` first (local Claude Code sign-in reuse per "money rule"), fallback `ClaudeAPI.swift` HTTP. |
| `.openAI` | `analyzeOpenAIOrCodexVoiceResponse` → Codex app-server first, then `OpenAIAPI.swift`. |
| `.deepgram` | Throws — Deepgram Voice Agent handles live mic turns directly; text/screenshot fallback must not land here. |
| `.codex` | `analyzeCodexVoiceResponse` → `CodexAgentSession` / `CodexVoiceSession`. |
| `.heyclickyFree` | `HeyClickyChatToolCallClient.shared.analyzeVoiceResponse`. Injects the `[ROUTE]` directive block consumed by `OpenClickyRouteDispatcher`. |

The element-pointing path at line 1309 also switches on provider (`.anthropic` / `.codex` / `.openAI` only — `CodexPointDetector.swift` for Codex).

### 2.4 TTS layer

`OpenClickyTTSProvider` enum (defined in `ElevenLabsTTSClient.swift:1790`):

| Case | rawValue | Client |
|---|---|---|
| `.openAIRealtime` | `openai_realtime` | `OpenAIRealtimeSpeechClient.swift` (83.1 K, WebSocket bidi) |
| `.elevenLabs` | `elevenlabs` | `ElevenLabsTTSClient.swift` (75.4 K, streaming SSE + WS) |
| `.cartesia` | `cartesia` | `CartesiaTTSClient.swift` (14.2 K) |
| `.deepgram` | `deepgram` | `DeepgramTTSClient.swift` (20.2 K, Aura) |
| `.microsoftEdge` | `microsoft_edge` | `MicrosoftEdgeTTSClient.swift` (16.6 K, uses `MicrosoftEdgeVoiceOption` recommended list) |

`CompanionManager.voiceTTSClient: any OpenClickyTTSClient` returns whichever concrete client matches settings; used via `.speakText`, `.stopPlayback`, `.warmUpConnection`, `.cancelBidirectionalVoiceTurn`, `.isPlaying`. `FillerPhraseLibrary.shared.prepare(client:)` primes short "Hmm…" prerolls to hide first-audio latency.

Streaming playback core: `TTSStreamingPlaybackEngine.swift`.

---

## 3. Model Catalog & Provider Routing

### 3.1 `OpenClickyModelCatalog` (`OpenClickyModelCatalog.swift`, 281 LOC)

Six providers: `apple`, `anthropic`, `openAI`, `codex`, `deepgram`, `heyclickyFree`.

Coarse voice backend family (`OpenClickyVoiceBackendFamily`): `apple`, `codex`, `claude`. Deepgram + HeyClicky Free are outside the tri-family selector.

Model IDs registered:

| Purpose | Models |
|---|---|
| `voiceResponseModels` (text/vision) | `apple-foundation`, `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-opus-4-6`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`, `heyclicky-free-chat` |
| `speechModels` (realtime speech-to-speech) | `gpt-realtime-2.1-mini` (default), `gpt-realtime-2.1`, `gpt-realtime-1.5`, `deepgram-voice-agent`, `heyclicky-free-speech` |
| `computerUseModels` | `claude-sonnet-4-6`, `claude-opus-4-6`, `gpt-realtime-2.1-mini`, `gpt-realtime-2.1`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2` |
| `codexActionsModels` | `gpt-5.5` (default), `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.2-codex`, `gpt-5.2`, `heyclicky-free` |

Constants: `defaultSpeechModelID = "gpt-realtime-2.1-mini"`, `defaultCodexActionsModelID = "gpt-5.5"`, `defaultDelegationModelID = "claude-sonnet-4-6"`, `appleFoundationModelID = "apple-foundation"`.

`normalizedModelID` aliases legacy `gpt-realtime-2` → `defaultSpeechModelID`. Local MLX models are intentionally NOT in `codexActionsModels` (Codex requires Responses API; local mlx_lm only speaks Chat Completions).

### 3.2 Bubble/notch selector

`OpenClickyVoiceBackendSelector` (`OpenClickyVoiceBackendSelector.swift`, 99 LOC): three chips (`Apple`/`Codex`/`Claude`) with dot-color state. Availability from `OpenClickyProviderDiscovery.availability()`:

- `.apple` → `#if canImport(FoundationModels)` + `SystemLanguageModel.default.isAvailable` on macOS 26+, else "macOS 26+".
- `.codex` → `CodexRuntimeLocator.codexExecutableCandidates(...)` non-empty OR `AppBundleConfiguration.openAIAPIKey() != nil`.
- `.claude` → PATH-scan `claude` binary (`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `OPENCLICKY_CLAUDE_EXECUTABLE`) OR `AppBundleConfiguration.anthropicAPIKey() != nil`.

Selection persisted via `CompanionManager.setSelectedVoiceBackendFamily`; family's `defaultModelID` (apple → `apple-foundation`, codex → `gpt-5.5`, claude → `claude-haiku-4-5`) becomes the response model.

### 3.3 Money-rule ordering (see project CLAUDE.md)

- Anthropic branch: `ClaudeAgentSDKAPI.swift` (32.3 K, PRIMARY — reuses local Claude Code sign-in, no per-token cost) → `ClaudeAPI.swift` (19.4 K, direct HTTP fallback ONLY). Do not delete `ClaudeAPI.swift`.
- OpenAI/Codex branch: Codex app-server first, then `OpenAIAPI.swift` key fallback.
- Apple: always free, on-device.
- Exemption: realtime speech models (`gpt-realtime-*`) go direct through Realtime API path only.

---

## 4. Profile System

`OpenClickyProfile.swift` (171 LOC).

```swift
nonisolated struct OpenClickyProfile: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let sttProvider: String        // BuddyTranscriptionProviderID rawValue
    let responseModelID: String    // OpenClickyModelCatalog id
    let ttsProvider: String        // OpenClickyTTSProvider rawValue
    let activationMode: String     // OpenClickyVoiceActivationMode rawValue
    let ttsVoiceID: String?
    let agentModelID: String?      // clickyCodexModel key
}
```

Built-in profiles (`OpenClickyProfileCatalog`):

| id | STT | Response model | TTS | Activation | Notes |
|---|---|---|---|---|---|
| `local` (default) | `parakeet` | `claude-haiku-4-5` | `microsoft_edge` | `push_to_talk` | Anthropic → SDK-first; cheapest cloud combo. |
| `realtime` | `openai` | `gpt-realtime-2.1-mini` | `openai_realtime` | `push_to_talk` | Owns STT+reasoning+audio in one WS turn. |
| `quality` | `deepgram` | `claude-sonnet-4-6` | `elevenlabs` | `push_to_talk` | Premium tier. |
| `heyclicky_free` | `heyclicky_free` | `heyclicky-free-speech` | `openai_realtime` | `push_to_talk` | `agentModelID=heyclicky-free`. Proxy-minted ephemeral. |
| `ski_mode` | `whisper_local` | `claude-haiku-4-5` | `microsoft_edge` | `push_to_talk` | Local zh whisper.cpp large-v3-turbo. |

Keys written by `OpenClickyProfileCatalog.apply` (UserDefaults):
- `openClickyActiveProfileID`
- `AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey`
- `selectedVoiceResponseModel`
- `AppBundleConfiguration.userTTSProviderDefaultsKey`
- `AppBundleConfiguration.userVoiceActivationModeDefaultsKey`
- provider-specific voice key (`elevenLabs`/`cartesia`/`openAIRealtime`/`microsoftEdge`/`deepgram`)
- `clickyCodexModel` (if `agentModelID` set)

Live application: `CompanionManager+Profiles.swift` (`applyProfile(_:)`, 74 LOC):
1. Records switch direction (into / out of `heyclicky_free`).
2. Persists new active id.
3. `stopHeyClickyFreeSubsystems()` when leaving HeyClicky Free (tears down WebSocket, plan poller, session-token refresh, chrome bridge). `startHeyClickyFreeSubsystems()` when entering.
4. `SKIModeHandsFreeSession.shared.reconcile()` — SKI hotkey monitor + hands-free VAD self-guard on `activeProfile.id == "ski_mode"`.
5. Applies STT (`setVoiceTranscriptionProvider`), response model (`setSelectedModel`), TTS (`setTTSProvider`), activation (`setVoiceActivationMode`).
6. Optional agent model override written to `clickyCodexModel`.

`OpenClickyVoiceActivationMode` (`OpenClickyWakeWordManager.swift:16`): `pushToTalk`, `toggleWakeWord`, `alwaysWakeWord`. Wake word feature owned by `OpenClickyWakeWordManager` (uses `SFSpeechRecognizer` per `NSSpeechRecognitionUsageDescription`).

---

## 5. Overlay & Cursor System

### 5.1 `CursorOverlayState` (`CompanionManager.swift:57-99`, `@MainActor final class`)

| Field | Type | Meaning |
|---|---|---|
| `voiceState` | `CompanionVoiceState` | Idle/listening/thinking/speaking. |
| `currentAudioPowerLevel` | `CGFloat` | Waveform amplitude. |
| `detectedElementScreenLocation` | `CGPoint?` | Pointing target (screen coords). |
| `detectedElementDisplayFrame` | `CGRect?` | Bounding rect of pointed element. |
| `detectedElementBubbleText` | `String?` | Bubble caption. |
| `detectedElementReturnsImmediately` | `Bool` | Auto-dismiss hint. |
| `agentTaskBubbleText` | `String?` | Agent progress caption. |
| `externalPrimaryCaptionText` | `String?` | External caption via bridge `/caption`. |
| `externalPrimaryCaptionAccentHex` | `String?` | Caption tint. |
| `externalSecondaryCursors` | `[OpenClickyExternalProxyCursor]` | Multi-cursor drawing. |
| `visualGuidanceOverlays` | `[OpenClickyVisualGuidanceOverlay]` | Walkthrough beats. |
| `circleSelectLivePoints` | `[CGPoint]` | PTT freehand trail. |
| `circleSelectSnappedRect` | `CGRect?` | Snap-resolved rectangle. |
| `circleSelectSnapLabel` | `String?` | Label of snap target. |
| `activeControlGlowRect` | `CGRect?` | Element focus glow. |
| `activeControlGlowLabel` | `String?` | Focus label. |
| `heyClickyStatusCaption` / `heyClickyStatusSeverity` | `String?` | Recovery caption ("续期额度中…") mirrored into `StatusCaptionStore`. |

### 5.2 Per-screen `OverlayWindow` (`OverlayWindow.swift`)

- `OverlayWindow: NSWindow` — one per active display, transparent, click-through unless a state demands input.
- `OverlayWindowManager` (line 3515) reconciles the set on `NSApplication.didChangeScreenParameters`.
- Owns cursor sprite, buddy pet, response cards (`CompanionResponseOverlay.swift`), agent dock icons (`AgentDockStore`), circle-select live trail + snapped highlight, external secondary cursors, visual guidance beats, whiteboard passthrough.

### 5.3 Cursor pet / sprites

- `ClickyBuddyPet.swift` — nonisolated `ClickyBuddyPet` value type + `ClickyBuddyPetLibrary` (observable, catalog of pet identities).
- `ClickyPetSpriteView.swift` — sprite renderer.
- `ClickyPetHatchCoordinator.swift` — first-encounter hatch flow.
- `OpenPetsCatalogService.swift` — catalog service.
- 3D sibling: `ThreeDChatBubbleView.swift`, `ThreeDViewerView.swift`, `ThreeDViewerWindowManager.swift`, `ThreeDGenerationService.swift`, `TripoThreeDProvider.swift`. Text→3D via `ThreeDGenerationTool.swift`.

### 5.4 Notch (`OpenClickyDynamicNotchKitBridge.swift`, 1464 LOC)

- Wraps DynamicNotchKit. `OpenClickyDynamicNotchKitModel: ObservableObject` at line 65 with published voice-phase, caption, and provider-chip fields.
- `OpenClickyDynamicNotchKitBridge` singleton (line 426) drives `showNotch` / `hideNotchBounded` / `hideNotchIfNeeded`.

### 5.5 HUD (`CodexHUDWindowManager.swift`, 1932 LOC)

- Codex Agent Mode dashboard window. `show(...)` at line 68 / `hide()` at line 112.
- Renders per-task pipeline: instruction, tool calls, streamed stdout/stderr, plan diff, verification results.

### 5.6 Follower + placement

- `OpenClickyAXFollower.swift` — AX-driven element follower.
- `WindowPositionManager.swift` — position persistence.
- `OpenClickyOverlayLayerHost.swift` + `OpenClickyOverlayObjCBridge.{h,m}` — CALayer host bridging.
- `AICursorAgent*` — not present in current source (referenced only historically).

---

## 6. Agent Mode (Codex)

### 6.1 Session lifecycle

`CodexAgentSession.swift` (172.7 K). `final class CodexAgentSession: ObservableObject, Identifiable, BrowserWorkspace…` at line 233. Injects `CodexProcessManager` (`CodexProcessManager.swift`, 29.9 K).

- Constructor: `init(processManager: CodexProcessManager? = nil, ...)` line 631. Defaults to fresh `CodexProcessManager()`.
- `startPromptTurn(_:screenContext:)` line 996 — spawns codex process, injects `OPENCLICKY_TASK_DIR` env var.
- `stop(reason:)` line 1149.
- SKI shim bypass path: line 301 forwards prompts without spawning codex.
- Companion extension: `CodexAgentSession+HeyClicky.swift` (14.7 K) — HeyClicky Free tier integration for Codex-shaped work.

Supporting types:
- `CodexRuntimeLocator.swift` (14.2 K) — probes for local Codex binary.
- `CodexRPCRequest.swift` (3.8 K).
- `CodexHomeManager.swift` (37.4 K) — bakes local Codex home from `AppResources/OpenClicky`; owns `persistentMemoryFile` (`memory.md`), `learnedSkillsDirectory`, config/runtime map.
- `ClickyCodexConfigTemplate.swift` (22.9 K) — renders Codex config for Agent Mode.
- `CodexVoiceSession.swift` (27.0 K) — voice-turn variant.
- `CodexPointDetector.swift` (12.6 K) — pointing model.

### 6.2 Codex task bridge tools (10 + 1 aux)

Registered in `OpenClickyExternalControlBridge.swift:1702-1745`:

| Tool | Payload | Bridge command |
|---|---|---|
| `codex_task_start` | `title`, `prompt`, `workingDir?`, `reasoningEffort?` | `.automationStartAgent` |
| `codex_task_followup` | `sessionID`, `prompt` | `.automationFollowUpAgent` |
| `codex_task_stop` | `sessionID` | `.automationStopAgent` |
| `codex_task_state` | `sessionID?` | `.automationSessionState` |
| `codex_task_list` | — | `.automationListSessions` |
| `codex_task_delete` | `sessionID` | `.automationDeleteSession` |
| `codex_task_purge` | `titleContains` | `.automationDeleteSessionsByTitleContains` |
| `codex_log_tail` | `count` (1–5000, default 200) | `.automationLogTail` |
| `codex_fault_inject` | `kind`, `sessionID?` | `.automationInjectFault` (unit-test hook) |
| `codex_reset_account` | `reason?` | `.automationAccountReset` (HeyClicky account reset) |
| `codex_auth_status` | — | `.automationAuthStatus` |

Also exposed via `/agent/*` REST routes on the local socket server: `/agent/task/start`, `/agent/task/stop`, `/agent/task/followup`, `/agent/session/state`, `/agent/sessions`, `/agent/session/delete`, `/agent/sessions/purge`, `/agent/plan/generate`, `/agent/plan/clear`, `/agent/fault/inject`, `/agent/log/tail`, `/heyclicky/auth/status`, `/heyclicky/auth/login`, `/heyclicky/account/reset`, `/heyclicky/raw/thread-launch`.

### 6.3 SKI Mode dock mirror

`CompanionManager+SKIModeDockMirror.swift` (9.1 K): mirrors Codex agent dock into the SKI hands-free surface so voice-only users see the same task queue as chat-workspace users. `SKIModeHandsFreeSession` (`SKIModeHandsFreeSession.swift`, 357 LOC) at line 32 is the singleton; `SKIModeHotkeyMonitor.swift`, `SKIModeConversationStore.swift`, `SKIModeApproveOverlay.swift`, `SKIModeWorkspacesBar.swift` complete the surface.

Auxiliary: `CompanionManager+SelfDrivingCodexDispatch.swift` (3.4 K) — planning-loop dispatch. `OpenClickyPlanningLoop.swift` (planning orchestrator).

---

## 7. External Control Bridge — Full Tool Registry

`OpenClickyExternalControlBridge.swift` — 5651 LOC, HTTP + MCP `tools/list` + `tools/call` on a local socket. Reachable at `/mcp/openclicky`, `/mcp/sensor`, `/mcp/orchestrate`. Tool count 100+.

Below groups every advertised tool. "Backing" = concrete Swift call site or helper class. `Bridge` = `OpenClickyExternalControlBridge.swift`.

### 7.1 Computer control / overlay drawing

| Tool | Aliases | Backing |
|---|---|---|
| `openclicky_point` | `point`, `show_cursor`, `openclicky_show_cursor` | `cursorCommand` → paints `CursorOverlayState.detectedElementScreenLocation`. |
| `openclicky_point_many` | `point_many`, `show_cursors`, `openclicky_show_cursors` | `cursorsCommand` → `externalSecondaryCursors`. |
| `show_caption` | `openclicky_show_caption` | `captionCommand` → `externalPrimaryCaptionText`. |
| `show_scribble` | `openclicky_show_scribble`, `scribble` | `scribbleCommand`. |
| `show_highlight` | `show_rectangle`, `openclicky_show_highlight`, `highlight`, `rectangle` | `rectangleCommand`. |
| `screenshot` | `screenshots`, `capture_screenshot`, `openclicky_screenshot` | `.captureScreenshot(focused:)` via `CompanionScreenCaptureUtility.swift` (ScreenCaptureKit). |
| `openclicky_click` | `click`, `left_click`, `mouse_click` | `clickCommand` → CGEvent post via `OpenClickyComputerUseRuntime.click(at:)`. |
| `clear` | `openclicky_clear` | Clears overlay state. |
| `speak` | `openclicky_speak` | Queues text through `voiceTTSClient`. |
| `notify` | `notification`, `openclicky_notify` | `OpenClickyDesktopNotificationCenter`. |
| `openclicky_simulate_voice_turn` | — | Injects transcript into voice pipeline (test). |
| `openclicky_simulate_ski_utterance` | — | Injects SKI transcript. |
| `openclicky_realtime_text_probe` | — | Realtime WS diagnostic ping. |
| `openclicky_purge_automation_conversations` | — | Deletes automation-injected LTM rows. |

### 7.2 Sensor / focused context (10)

Base set in `sensorToolNamesBase`:

| Tool | Backing capture struct |
|---|---|
| `sensor_health` | Inline (returns `capture_count`, version). |
| `get_focused_context` | Combines FrontmostAppCapture + SelectedTextCapture + ClipboardCapture + FinderSelectionCapture + BrowserURLCapture + FocusedWindowCapture. |
| `list_apps` | `FrontmostAppCapture` (frontmost-only). |
| `get_selected_text` | `SelectedTextCapture` (AX). |
| `get_clipboard` | `ClipboardCapture` (NSPasteboard). |
| `get_finder_selection` | `FinderSelectionCapture` (AppleScript to Finder). |
| `get_browser_url` | `BrowserURLCapture` (AppleScript to Safari/Chrome/Edge/Arc). |
| `get_idle_time` | `IdleTimeCapture` (CGEventSourceSecondsSinceLastEventType). |
| `probe_workdir` | `WorkdirProbe`. |
| `get_focused_window` | `FocusedWindowCapture` (AX per pid). |
| `screenshot` (sensor) | `handleSensorScreenshot` → ScreenCaptureKit; supports screen/window/region, PNG/JPEG. |
| `get_browser_tabs` | `BrowserTabsCapture` (AppleScript per browser). |
| `get_terminal_output` | `TerminalCapture` (AppleScript to Terminal/iTerm/Ghostty). |
| `ocr_image` | `OCRCapture` (Vision framework, base64 in). |
| `check_permission` | `PermissionPreflight.check(kind:)` for `accessibility` / `screenRecording` / `inputMonitoring` / `microphone` / `automation`. |
| `install_ax_quirks` | `AXQuirksInstaller.installIfNeeded(pid:)` sets `AXManualAccessibility` + `AXEnhancedUserInterface` (private AX flags). |
| `list_windows` | `WindowEnumerationCapture.enumerateAll`. |
| `cursor_position` | `CursorCapture`. |
| `element_under_cursor` | `ElementUnderCursorCapture` (AX hit-test). |
| `recent_agent_sessions` | `RecentSessionsCapture`. |
| `project_registry_lookup` | `ProjectRegistry.shared.lookup`. |
| `git_awareness` | `GitAwarenessCapture`. |
| `get_app_context` | `handleSensorGetAppContext` — fuzzy `app_hint` match against frontmost. |
| `get_app_state` | `handleSensorGetAppState`. |
| `strategy_note_get` / `strategy_note_write` | `handleSensorStrategyNote{Get,Write}` (`GateTools.cs`-parity). |
| `opendia_smoke_check` | `handleSensorOpendiaSmokeCheck`. |
| `app_hint` | Argument used by `get_app_context`/`get_app_state` (not a standalone tool). |
| `discover_url` | Field on OpenCLI-scaffold responses (not a standalone tool). |

### 7.3 Doc readers (7) — MCP prefix

| Tool | Class |
|---|---|
| `doc_read_pdf` | `DocReadPdf.read(path:maxPages:)` (PDFKit). |
| `doc_read_docx` | `DocReadDocx.read`. |
| `doc_read_xlsx` | `DocReadXlsx.read`. |
| `doc_read_pptx` | `DocReadPptx.read`. |
| `doc_read_epub` | `DocReadEpub.read`. |
| `doc_read_html` | `DocReadHtml.read`. |
| `doc_read_txt` | `DocReadTxt.read`. |

### 7.4 Memory tools (8)

Class: `OpenClickyMemoryTools` (Packages/OpenClickyContextService).

| Tool | Behavior |
|---|---|
| `memory_read` | Returns all entries; optional `key` filter. |
| `memory_read_endpoint` | Reads one endpoint entry `{fields, notes, updated_at, verify_fixture}`. Nil returns `value: null`. |
| `memory_write_endpoint` | Writes `{fields, notes, force}` under `endpoint`. Force skips staleness check. |
| `memory_write_field_map` | Bulk `{k: v}` upsert. |
| `memory_append_note` | Appends a note; optional endpoint scope. |
| `memory_snapshot` | Whole memory doc snapshot. |
| `memory_freshness` | `{last_write_unix, staleness_seconds}`. |
| `memory_write_verify_fixture` | Records `{cmd, fixture_json}` under endpoint. |

Persistent memory file: `CodexHomeManager.persistentMemoryFile` = `<codexHome>/memory.md`. `appendPersistentMemoryEvent(userRequest:agentResponse:)` line 226. Sessions memory dir: `learnedSkillsDirectory`.

### 7.5 Meta tools (6)

| Tool | Backing |
|---|---|
| `list_more_tools` | `sensorMetaRegistry.listMoreTools(category:)`. |
| `search_tools` | `sensorMetaRegistry.searchTools(query:topK:)`. |
| `activate_domain` | Enables a domain-scoped surface. |
| `list_domains` | Enumerates registered domains. |
| `call_tool` | Reflectively dispatches an inner tool (rejects `call_tool` / `batch` for recursion). |
| `batch` | Executes multiple tool calls in one request. |

### 7.6 Stash-read (7) — Everywhere parity

| Tool | Class |
|---|---|
| `read_pick` | `OpenClickyStashTools.readPick(mode:includeTreeJson:)`. |
| `read_whiteboard` | `OpenClickyStashTools.readWhiteboard()`. |
| `read_whiteboard_image` | `OpenClickyStashTools.readWhiteboardImage(imageId:)` — 5-minute TTL PNG. |
| `add_annotation` | `OpenClickyStashTools.addAnnotation(source:body:anchorLabel:anchorRef:)`. |
| `read_annotations` | `OpenClickyStashTools.readAnnotations()`. |
| `clear_annotations` | `OpenClickyStashTools.clearAnnotations()`. |
| `pick_element` | Arms `OpenClickyPickElementOverlay.shared.begin()`; caller polls `read_pick`. |

### 7.7 Connector (F29) — 6

Delegated to `OpenClickyConnectorBridgeTools.execute(name:arguments:)` (Node subprocess). Names: `connector_list`, `connector_describe`, `connector_run`, `connector_connect`, `connector_disconnect`, `connector_list_connections`.

### 7.8 OpenCLI (F30) — 3

`OpenClickyOpenCLIBridgeTools.execute`: `opencli_list`, `opencli_describe`, `opencli_run` (site adapters via Node).

### 7.9 Chat bus (F32) — 6

`OpenClickyChatBridgeTools.execute`: `chat_send`, `chat_subscribe`, `chat_list`, `chat_read`, `chat_create`, `chat_delete`.

### 7.10 Clipboard (4)

Inline in `Bridge`:

| Tool | Action |
|---|---|
| `clipboard_read` | `ClipboardCapture.capture()` → `{has_text, text}`. |
| `clipboard_paste` | Read + `ClipboardWriter.simulatePaste()` (CGEvent `⌘V` into frontmost). |
| `clipboard_write` | `ClipboardWriter.writeText(text)`. |
| `clipboard_copy` | `ClipboardWriter.simulateCopy()` (CGEvent `⌘C` — asks frontmost to copy). |

### 7.11 Web (F34) — 2

`OpenClickyWebBridgeTools.execute`: `web_search` (via `OpenClickyWebSearchClient`) and `web_fetch_url` (via `OpenClickyWebFetchClient`). Provider selection in `OpenClickyWebSearchProvider`.

### 7.12 Adapter authoring (F33) — 8

`OpenClickyAdapterAuthoringBridgeTools.execute`: `adapter_scaffold`, `adapter_save`, `adapter_verify`, `adapter_list_local`, `adapter_drift_check`, `adapter_delete_local`, `adapter_regenerate`, `adapter_lint`.

### 7.13 Page tools (F35) — 6

`OpenClickyPageBridgeTools.execute`: `page_extract_by_rule`, `page_save_extraction_rule`, `page_read`, `page_summarise`, `page_inspect`, `page_actions`.

### 7.14 Capture authoring (F36) — 9

`OpenClickyCaptureAuthoringBridgeTools.execute`: `capture_start`, `capture_stop`, `capture_current`, `capture_export`, `capture_draft`, `capture_publish`, `capture_list`, `capture_delete`, `capture_run`.

### 7.15 OpenDia browser control (F31) — 120

Prefix dispatch on `browser_*` matching `OpenClickyOpenDiaBridgeTools.toolNames` — sent to Node OpenDia subprocess. WebSocket back-channel to user-installed Chrome/Firefox extension.

### 7.16 OpenRewind (Screen History) — 9 `openrewind.*`

Handled in `Bridge` default via `handleSensorAskRewind` and companions. Names include `openrewind.frame`, `openrewind.recap`, `openrewind.showFrame`, `openrewind.timeline`, etc. Retired duplicates: `openrewind.aiContext`, `openrewind.summary`, `openrewind.resolveCitation`.

### 7.17 Advisor (8) — automation-free consult

Each is a `.automationFreeConsult` command with a specialised system prompt:

| Tool | Requires | System prompt gist |
|---|---|---|
| `advisor_consult` | `query` | Direct concise advisor to Codex. |
| `advisor_read_image` | `question`, `imagePath` | Vision analysis of screenshot. |
| `advisor_locate_ui` | `description`, `imagePath` | Returns `{x,y,width,height,label}` JSON. |
| `advisor_web_search` | `query` | Cited web summary. |
| `advisor_places_lookup` | `query` | Places data. |
| `advisor_stock_quote` | `ticker` | Price + 30-day trend. |
| `advisor_walkthrough` | `goal`, `imagePath` | Ordered walkthrough with point/highlight/arrow beats. |
| `advisor_memory_save` | `fact` | Persist to LTM. |

### 7.18 Gmail stubs

`gmail_list_messages`, `gmail_read_message`, `gmail_draft_reply` → `gmailUnavailableCommand`. No local OAuth/gog backend wired; feature gated by `AppBundleConfiguration.gmailOAuthToolsEnabled()`.

### 7.19 MCP endpoints (JSON-RPC 2.0)

`initialize`, `notifications/initialized`, `tools/list`, `tools/call` on `/mcp/openclicky`, `/mcp/sensor`, `/mcp/orchestrate` (`handleSensorRequest` line 3075). SSE/streamable HTTP.

---

## 8. Memory System — Detailed

### 8.1 Storage layout

- `CodexHomeManager` (`CodexHomeManager.swift`, 37.4 K):
  - `codexHomeDirectory` = bundled + user Codex home.
  - `persistentMemoryFile` = `codexHomeDirectory/memory.md`.
  - `learnedSkillsDirectory` — per-session memories.
  - `persistentMemoryFiles(includeArchived:)` — active + archives.
  - `appendPersistentMemoryEvent(userRequest:agentResponse:)` line 226 — appends turn to `memory.md`.
  - `writeCodexConfigFromSettings()` line 170 — writes Codex config.
  - Auto-archive when the file grows past a threshold (line 597).

- `OpenClickyMessageLogStore` (`OpenClickyMessageLogStore.swift`, 600 LOC): daily rotating JSONL logs. Long-lived per-day `FileHandle` cache (perf fix 2026-08-01). Public API:
  - `append(lane:direction:event:fields:)`
  - `appendConversationTurn(...)`
  - `appendReviewComment(...)`
  - `ensureAgentReviewCommentsFile()`
  - `pruneOldMessageLogs(olderThanDays:)` (default retention; runs on launch + hourly).
  - `availableMessageLogFiles()`
  - `reviewCommentsFile` (`log-review-comments.jsonl`), `agentReviewCommentsFile` (`agent-review-comments.md`), `currentLogFile` (dated).
  - Redaction helpers: `privacySanitizedReviewEntry`, `markdownReviewEntry`, `redactedReviewExcerpt`, `sanitizedJSONObject`, `isSensitiveKey`, `redactedSensitiveValues`.

### 8.2 Bridge tool semantic differences

| Tool | Reads/Writes | Notes |
|---|---|---|
| `memory_read` | All entries (or by `key`). | Bulk snapshot. |
| `memory_read_endpoint` | One endpoint. | Returns `null` value if absent. |
| `memory_write_endpoint` | One endpoint. | Accepts `fields` + `notes` + `force` (bypass staleness check). |
| `memory_write_field_map` | Bulk. | Flat `{k: v}` upsert; converts non-string values via `String(describing:)`. |
| `memory_append_note` | Text only. | Optional `endpoint` scope. |
| `memory_snapshot` | Read-only. | Whole memory doc. |
| `memory_freshness` | Read-only. | Last write unix + staleness seconds. |
| `memory_write_verify_fixture` | Fixture. | `{cmd, fixture_json}` — records deterministic verification snapshots. |

### 8.3 UI

- `MemoryDrawerView.swift` — right-side drawer reading persistent memory + per-conversation references. Menu-item "Open Memory File" jumps to `memory.md`; "Open Skills Folder" opens `learnedSkillsDirectory`.

---

## 9. Computer Use Runtime

`OpenClickyComputerUseRuntime.swift` (1230 LOC / 50 K).

Two controllers:

### 9.1 `OpenClickyNativeComputerUseController` (line 21, `@ObservableObject`)

In-process CGEvent-based control.

| Method | Notes |
|---|---|
| `setEnabled(_:)` | Master toggle. |
| `refreshStatus()` | Recomputes availability. |
| `refreshFocusedTarget() -> OpenClickyComputerUseWindowInfo?` | Frontmost focus target. |
| `runningApps() -> [OpenClickyComputerUseAppInfo]` | `NSWorkspace.shared.runningApplications`. |
| `visibleWindows()` / `allWindows()` | CGWindow listing. |
| `captureFocusedWindowAsJPEG()` (async throws) | ScreenCaptureKit. |
| `pressKey(_:modifiers:toPid:)` | CGEvent keyDown/keyUp; optional pid targeting via `CGEventPostToPid`. |
| `typeText(_:delayMilliseconds:toPid:)` | Character-by-character CGEvent. |
| `click(at:)` throws | `CGEventCreateMouseEvent` at global point. |

### 9.2 `OpenClickyBackgroundComputerUseController` (line 130, `@ObservableObject`)

Delegates to a bundled companion app process (`bundledRuntimeRootURL` line 150, `bundledAppURL(in:)`, `installedAppURL` line 159). Communicates over local HTTP (`runtimeBaseURL()` line 441).

| Method | Notes |
|---|---|
| `startRuntime()` / `stopRuntime()` | Spawns/tears down the runtime helper. |
| `ensureRuntimeReady(timeoutSeconds:)` | Waits for HTTP ready. |
| `captureFrontmostWindowAsJPEG()` | Delegated screenshot (isolated). |
| `pressKey(_:modifiers:targetAppName:stateToken:)` | HTTP call. |
| `typeText(_:targetAppName:stateToken:)` | HTTP call. |
| `click(at:window:targetAppName:stateToken:)` | HTTP call. |

Backend enum: `OpenClickyComputerUseBackendID` (`OpenClickyComputerUseModels.swift:4`) `String, CaseIterable, Identifiable, Sendable` — selects native vs background at runtime.

Errors: `OpenClickyComputerUseError` (line 379): permission denied, runtime unavailable, timeout, etc.

Permission dependency: Accessibility (`NSAccessibilityUsageDescription`) + Input Monitoring (`NSInputMonitoringUsageDescription`) + Screen Recording (`NSScreenCaptureUsageDescription`) + Automation (per `NSAppleEventsUsageDescription`).

---

## 10. Permission Model

### 10.1 Info.plist declarations

| Key | Purpose |
|---|---|
| `NSAccessibilityUsageDescription` | AX reads for focused-text / window titles. |
| `NSAppleEventsUsageDescription` | AppleScript automation (Finder, browsers, Terminal). |
| `NSMicrophoneUsageDescription` | Push-to-talk + wake word. |
| `NSSpeechRecognitionUsageDescription` | On-device Hey Clicky detection. |
| `NSScreenCaptureUsageDescription` | ScreenCaptureKit. |
| `NSInputMonitoringUsageDescription` | Kbd/mouse event capture (Screen History). |
| `NSCameraUsageDescription` | Visual intelligence / meeting notes. |
| `NSCalendarsUsageDescription` + `NSCalendarsFullAccessUsageDescription` | EventKit calendar sync (screen-history timelines). |
| `NSAppTransportSecurity` | `NSAllowsLocalNetworking=true` for local HTTP bridges. |
| `NSUserNotificationAlertStyle` | `alert`. |

Entitlements (`cursor-buddy.entitlements`):
- `com.apple.security.app-sandbox = false` (unsandboxed).
- App group `group.com.jkneen.openclicky`.
- `com.apple.security.device.audio-input = true`.
- `com.apple.security.device.camera = true`.
- `com.apple.security.network.client = true`.
- `com.apple.security.temporary-exception.mach-lookup.global-name = com.apple.screencapturekit.picker`.

### 10.2 Runtime request flow

- `PermissionPreflight.check(kind:automationTargetBundleId:)` used by `check_permission` bridge tool. `PermissionKind` = `accessibility` / `screenRecording` / `inputMonitoring` / `microphone` / `automation`.
- Onboarding flow (`CompanionManager+Onboarding.swift`, 35.3 K) walks user through permissions before enabling voice.
- `OpenClickyContextHotkeys.swift` (23.9 K) manages global hotkey installation.

### 10.3 AX quirks

`AXQuirksInstaller` (via `install_ax_quirks` tool) sets the private `AXManualAccessibility=true` and `AXEnhancedUserInterface=true` attributes on a target pid so its AX tree becomes richer (Electron / Chromium primarily). Side effects persist for the app's lifetime.

---

## 11. Existing Integration Gaps

Confirmed NOT present in current `Bridge` tool set (no `case` matches):

| Missing capability | Notes |
|---|---|
| `spotify_*` | No Spotify integration. |
| `gmail_*` | Only stubs (`gmail_list_messages`, `gmail_read_message`, `gmail_draft_reply`) that error out. No real OAuth/gog mailbox backend. |
| `calendar_*` / `eventkit_*` | Calendar permission declared, but no MCP tool exposed — only Screen-History timeline consumes EventKit internally. |
| `contacts_*` | No Contacts integration. |
| `messages_*` / `imessage_*` | No Messages/iMessage integration. |
| `facetime_*` | Not present. |
| `reminders_*` | Not present. |
| `shortcuts_*` | Not present. |
| `safari_open_url` / `browser_open_url` | Not present (browser control goes through OpenDia `browser_*` prefix). |
| `spotlight_search` | Not present. |
| `mail_*` (macOS Mail.app) | Not present. |
| `notes_*` (Apple Notes) | Not present. |
| `maps_*` (Apple Maps) | Not present. |
| `music_*` (Apple Music) | Not present. |
| `weather_*` | Not present. |
| `find_my` | Not present. |
| `system_settings_*` | Not present. |

Clipboard has the 4 alias tools (`clipboard_read` / `write` / `paste` / `copy`) but no finer-grained UI hover / press-and-hold tools — only `openclicky_click` (single click), `pick_element`, `element_under_cursor`. No `right_click`, `double_click`, `drag`, `hover`, `press_and_hold`, `mouse_move_absolute` at MCP surface (though `OpenClickyComputerUseRuntime` supports lower-level primitives internally).

---

## 12. HeyClicky Proxy Client — Reusability Notes

`HeyClickyProxyClient.swift` (334 LOC). Concrete shape:

| Concern | Implementation |
|---|---|
| Base URL | `AppBundleConfiguration.heyClickyProxyBaseURL()` (Info.plist `HeyClickyProxyBaseURL`). Path appended with normalized leading-slash strip. |
| Session | Custom `URLSessionConfiguration`: `timeoutIntervalForRequest=20`, `timeoutIntervalForResource=120`, `waitsForConnectivity=true`, `httpShouldUsePipelining=true`, `httpMaximumConnectionsPerHost=6`, `Accept-Encoding: gzip, br` default header. Reuses HTTP/2 socket across all HeyClicky calls. |
| Auth | Bearer token from `AppBundleConfiguration.heyClickySessionAccessToken()`. `HeyClickyHeaderBuilder.shared.apply(to:includeDictationReceipt:)` adds X-Clicky-* headers. |
| Body encoding | Manual gzip helper (`static gzip(_:) -> Data?`) with 10-byte gzip header + 8-byte CRC32/ISIZE trailer prepended around `COMPRESSION_ZLIB`. Currently skipped for outbound (Worker rejects `Content-Encoding: gzip` on inbound). |
| Multipart | `postMultipart(path:body:boundary:includeDictationReceipt:)` line 85. |
| GET | `getJSON(path:includeDictationReceipt:)` line 64. |
| POST | `postJSON(path:body:includeDictationReceipt:)` line 50. |
| Retry (single-shot) | `sendWithRefresh` line 102. On 401: `HeyClickySessionAuthenticator.shared.refresh()` then retry once. On Cloudflare `403 "Country/region"`: retries with a fresh ephemeral `URLSession` to force new Anycast edge. On refresh failure: posts `NotificationCenter .clickyHeyClickySessionExpired`. |
| Retry (backoff) | `postJSONWithBackoff(maxAttempts:5)` line 217 with 1s / 2s / 5s / 15s / 30s. Retries `upstreamUnavailable` + `transportError`; fail-fast on `unauthorized` / `quotaExhausted` / `malformedResponse` / `leaseNeedsContinue`. |
| Error taxonomy | `HeyClickyProxyError`: `unauthorized`, `quotaExhausted` (402/429), `upstreamUnavailable` (5xx), `malformedResponse`, `transportError`, `leaseNeedsContinue`. `mapError(status:)` line 280. |
| Health signal | Any 2xx → `NotificationCenter.postHeyClickyStatus(.ready)` to clear stale recovery captions. |
| Streaming SSE | Not implemented here — `HeyClickyChatToolCallClient.swift` (65.4 K) handles SSE + tool-call framing. `HeyClickyRealtimeWarmConnection.swift` handles WS ephemerals for realtime speech. |
| Logging | Every request/response through `HeyClickyLog.log(..., lane: "system", direction: ...)` with response body peek for `record-agent-launch` / `turn-lease` endpoints and error/geo-block cases. |

Companion HeyClicky components (all present, reusable as pattern refs): `HeyClickySessionAuthenticator.swift` (18.3 K), `HeyClickySessionTokenClient.swift` (19.1 K), `HeyClickyTurnLeaseClient.swift` (19.0 K), `HeyClickyAgentMessagesClient.swift`, `HeyClickyAgentNotificationsClient.swift`, `HeyClickyChromeBridgeServer.swift`, `HeyClickyFreePlanningClient.swift`, `HeyClickyFreeTierAgentHook.swift`, `HeyClickyPlanClient.swift`, `HeyClickyHeaderBuilder.swift`, `HeyClickyLog.swift`, `HeyClickyAccountResetManager.swift`, `HeyClickyAccountSwitcher.swift`, `HeyClickyGuidedClickManager.swift`, `HeyClickyScreenAnnotationOverlay.swift`, `HeyClickyWidgetSlotView.swift`, `HeyClickyProxyTranscriptionProvider.swift`, `HeyClickySecrets.swift`.

Boot for HeyClicky subsystems: `startHeyClickyFreeSubsystems()` (`CompanionManager+HeyClicky.swift:1101`) / `stopHeyClickyFreeSubsystems()` (line 1003) called by `applyProfile` on profile transitions. `CompanionManager+HeyClicky.swift` is 80.7 K on its own.

---

## Appendix A — File size cheat sheet (largest 15)

```
CompanionManager.swift                        881.2K
OpenClickyExternalControlBridge.swift         275.3K
CodexAgentSession.swift                       172.7K
CompanionManager+AIResponsePipeline.swift     110.8K
OpenAIRealtimeSpeechClient.swift               83.1K
CompanionManager+HeyClicky.swift               80.7K
CodexHUDWindowManager.swift                    77.1K
ElevenLabsTTSClient.swift                      75.4K
HeyClickyChatToolCallClient.swift              65.4K
MenuBarPanelManager.swift                      64.7K
OpenClickyDynamicNotchKitBridge.swift          56.9K
CompanionPanelView.swift                       54.9K
BuddyDictationManager.swift                    51.6K
OpenClickyComputerUseRuntime.swift             50.0K
CodexAgentModePanelSection.swift               45.2K
```

## Appendix B — Node subprocess integrations (opt-in)

| Feature (Phase) | Settings class | Subprocess | Port range | Tools |
|---|---|---|---|---|
| open-connector (7.5 F29) | `OpenClickyConnectorSettings` | `OpenClickyConnectorSubprocess` | dynamic | 6 `connector_*` |
| OpenCLI (7.6a F30) | `OpenClickyOpenCLISettings` | `OpenClickyOpenCLISubprocess` | dynamic | 3 `opencli_*` |
| OpenDia (7.6b F31) | `OpenClickyOpenDiaSettings` | `OpenClickyOpenDiaSubprocess` | `[56000,57000)` | 120 `browser_*` |

## Appendix C — Local socket server routes

`OpenClickyExternalControlBridge` HTTP surface (bound by `OpenClickyAgentsSocketServer`):

```
GET  /agent/sessions
GET  /agent/session/state
GET  /agent/log/tail
GET  /heyclicky/auth/status
POST /cursor            /cursors
POST /scribble
POST /highlight | /rectangle
POST /caption
POST /screenshot | /screenshots
POST /click
POST /clear
POST /speak
POST /notify | /notification
POST /agent/task/start | /agent/task/stop | /agent/task/followup
POST /agent/plan/generate | /agent/plan/clear
POST /agent/session/delete | /agent/sessions/purge
POST /agent/fault/inject
POST /heyclicky/auth/status | /heyclicky/auth/login
POST /heyclicky/account/reset | /heyclicky/raw/thread-launch
POST /mcp/call | /tools/call | /mcp/calls | /tools/calls
POST /mcp/openclicky | /mcp/sensor | /mcp/openclicky-sensor | /mcp/orchestrate | /mcp/openclicky-orchestrate
```
