# Parity Domain 3: AI Providers + Memory + Agent / Routing Config

Audit pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Openclicky HEAD as of 2026-07-23.

Scope: every user-facing knob for AI-provider auth, per-capability model
selection, memory persistence + freshness + rotation, intent router, and
long-running agent auto-continuation. Sources: Everywhere's
`ModelSettings.cs`, `SystemAssistantSettings.cs`, `ApiKey.cs`,
`Assistant.cs`, `CustomAssistant.cs`, `McpServerSettings.cs`, the
`MemoryStore` + `Freshness` files under
`src/Everywhere.Mcp/OpenCli/Memory/`, and the live user config at
`~/Library/Application Support/Everywhere/settings.json`. On the
openclicky side: `AppBundleConfiguration.swift`,
`OpenClickyModelCatalog.swift`, `OpenClickyProfile.swift`,
`OpenClickySettingsWindowManager.swift`, `HeyClickySecrets.swift`,
`HeyClickyChatToolCallClient.swift`, `OpenClickyRouteDispatcher.swift`,
`CompanionManager+HeyClicky.swift`, `CompanionManager.swift`,
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Memory/MemoryStore.swift`,
`ClickyCodexConfigTemplate.swift`, `CodexHomeManager.swift`,
`AppResources/OpenClicky/AGENTS-longrun-template.md`.

Verdict codes:
- **A** — parity: same setting, same semantics, exposed in openclicky UI.
- **B** — wire gap: storage/backend exists in openclicky but no UI row.
- **C** — feature gap: neither storage nor UI in openclicky.
- **D** — openclicky extra: knob absent from Everywhere, present here.
- **E** — intentionally not applicable: product/architecture difference.

## Everywhere inventory (this domain)

Providers + assistants (`Everywhere.Core/Configuration/Settings/ModelSettings.cs`,
`SystemAssistantSettings.cs`, `Everywhere.Core/AI/Assistant/Assistant.cs`,
`CustomAssistant.cs`, `Everywhere.Core/Configuration/ApiKey.cs`):

1. `ModelSettings.ApiKeys` — `ModelSettings.cs:30`. `ObservableCollection<ApiKey>`. Keychain-backed named credentials; only `{Id, Name}` persisted, secret in `OsSecretVault` (`ApiKey.cs:21,34,40,165`).
2. `ModelSettings.CustomAssistants` — `ModelSettings.cs:11`. `ObservableCollection<CustomAssistant>`.
3. `ModelSettings.SelectedCustomAssistantId` — `ModelSettings.cs:15`. Guid picker of the "default" assistant.
4. `CustomAssistant.Id/Name/Icon/Description` — `CustomAssistant.cs:19,23,29,32`.
5. `CustomAssistant.SystemPromptId` — `CustomAssistant.cs:69`. Guid pointing into Prompt Manager (empty = built-in).
6. `Assistant.Endpoint` — `Assistant.cs:14`. Provider base URL string.
7. `Assistant.ApiKey` (Guid → `ModelSettings.ApiKeys[Id]`) — `Assistant.cs:21`.
8. `Assistant.Schema` — `Assistant.cs:26`. `ModelProviderSchema` enum: `OpenAI / OpenAIResponses / Anthropic / Google`.
9. `Assistant.ModelId` — `Assistant.cs:30`. String, provider-native id.
10. `Assistant.SupportsToolCall / InputModalities / OutputModalities / ContextLimit / OutputLimit / Specializations / DeprecationDate` — `Assistant.cs:33-58`. Per-model capability tags.
11. `Assistant.ConfiguratorType` — `Assistant.cs:63`. `Official / PresetBased / Advanced` picker.
12. `Assistant.ModelProviderTemplateId` + `ModelDefinitionTemplateId` — `Assistant.cs:67-71`. Bind to preset library.
13. `Assistant.RequestTimeoutSeconds` — `Assistant.cs:93`, default 20.
14. `Assistant.OpenAIOptions` / `OpenAIResponsesOptions` / `AnthropicOptions` / `GoogleOptions` — `Assistant.cs:103,113,123,133`. Provider-specific sub-panels (e.g. `AnthropicOptions.ThinkingEffort` seen live at `settings.json:107`).
15. `SystemAssistantSettings.TitleGeneration` — `SystemAssistantSettings.cs:26`. Which assistant labels chat titles; expandable when `!AutoSelect`.
16. `SystemAssistantSettings.DefaultSubagent` — `SystemAssistantSettings.cs:33`. Assistant used for tool-call subagents.
17. `SystemAssistantSettings.ImageUnderstanding` — `SystemAssistantSettings.cs:40`. Assistant with `Modalities.Image` input.

Memory store (`Everywhere.Mcp/OpenCli/Memory/`,
`Everywhere.Mcp/OpenCli/Observation/EverywherePaths.cs`, `MemoryTools.cs`):

18. Persistence root — `EverywherePaths.cs:62-65` `~/.everywhere/`, sites subtree at `EverywherePaths.cs:38-43` `~/.everywhere/sites/`.
19. Per-domain layout — `MemoryStore.cs:33-53` `sites/<domain>/{endpoints.json, field-map.json, notes.md, verify/*.json, fixtures/*.json, metadata.json, strategy-notes/*.md}`.
20. Freshness thresholds — `Freshness.cs:9,14-16`: `<30d fresh, 30-90d stale, >=90d cold`. Hard-coded, no user knob.
21. Snapshot rotation — `MemoryStore.cs:210-212` keep last 5 per cmd, best-effort. Hard-coded.
22. Atomic-write / merge-safe writer — `MemoryStore.cs:69,74,99,127,149-150`, `MergeSafeWriter.cs`. Hard-coded.
23. `MEMORY_LOCK_TIMEOUT` — `MergeSafeWriter.cs:12,30-45,63-68`. 5 s POSIX `.lock` sentinel. Not exposed as UI setting; can be flipped via env only.
24. Path-traversal guard — `MemoryStore.cs:36-53`. Not a knob.

Router + auto-continue: Everywhere ships no such surface — Everywhere is
a capture + MCP host, not an agent shell. `[ROUTE]` tag, confidence
gate, `progressDriven`, `completionMarker`, and turn-cap concepts are
all openclicky-native (see `F26-route-parse-*.md` and
`F28-auto-continue-*.md`). They still appear in the table below because
this domain audit tracks *user-facing switches*, and openclicky exposes
(or ought to expose) them.

Ancillary MCP wire-up settings not owned by this domain
(`McpServerSettings.HttpEnabled/Port/AutoCaptureContext/OpenDia*` etc.)
are audited in `parity-domain1-hotkeys-context-2026-07-23.md`.

## Openclicky parity table

| # | Everywhere setting | Everywhere source | Openclicky storage | Openclicky UI | Verdict |
|---|---|---|---|---|---|
| 1 | Named-credential list (`ApiKeys`) | `ModelSettings.cs:30`, `ApiKey.cs:21,34,40,165` (keychain-backed, IDs persisted) | `AppBundleConfiguration.userAnthropicAPIKey/ElevenLabs/Cartesia/CodexAgent/AssemblyAI/Deepgram/…DefaultsKey` `AppBundleConfiguration.swift:12,13,15,59,60,61` — one slot per provider, plaintext `UserDefaults` (not Keychain) | Advanced Providers panel: `OpenClickySettingsWindowManager.swift:193-200,231-233,397-404,1301-1366` `secureFieldRow`s for Anthropic / OpenAI / ElevenLabs / Cartesia / AssemblyAI / Deepgram | **B/D-hybrid** — parity in intent (per-provider secret), but shape diverges: Everywhere = named-key registry keyed by Guid, openclicky = fixed slot per provider. No Keychain (see Issue 1). |
| 2 | ApiKey.Name (friendly label) | `ApiKey.cs:44-46` | none — slot is anonymous | none | **C** — Feature gap. |
| 3 | ApiKey validation (max 65,535 chars) | `ApiKey.cs:130-143` | none — plain string via `UserDefaults` | none | **C** — Feature gap; openclicky's `secureFieldRow` writes verbatim. |
| 4 | Custom-assistant list (multiple named LLMs) | `ModelSettings.cs:11` | none | none | **C** — Feature gap. Openclicky treats provider+model as a single global pick per capability, not a named-assistant collection. |
| 5 | Selected default assistant id | `ModelSettings.cs:15` | Loosely proxied by `OpenClickyProfileCatalog.activeProfileID` (`OpenClickyProfile.swift:41`) + `voiceResponseModelDefaultsKey = "selectedVoiceResponseModel"` (`:43`) | Advanced Providers > model grid (`OpenClickySettingsWindowManager.swift:959-961`) `setSelectedModel` per profile | **B** — Storage present but modelled per-lane, not per-assistant; the semantic is "profile + model", not "pick a named assistant". |
| 6 | Assistant.Endpoint (provider base URL) | `Assistant.cs:14` | Codex/agent endpoint only: `UserDefaults "clickyAgentBaseURL"` `OpenClickySettingsWindowManager.swift:403,2316,2326`; per-provider URL for HeyClicky Free proxy: `AppBundleConfiguration.heyClickyProxyBaseURLDefaultsKey` `OpenClickySettingsWindowManager.swift:1538`. No per-provider endpoint for Anthropic/ElevenLabs/Deepgram | Agent Mode endpoint field `OpenClickySettingsWindowManager.swift:1661-1664, 2321-2328`; HeyClicky Free Advanced disclosure `:1530-1573` | **B** — Wire gap for the non-Codex providers. Anthropic and ElevenLabs endpoints are compiled in. |
| 7 | Assistant.Schema (OpenAI / OpenAIResponses / Anthropic / Google) | `Assistant.cs:26` | Inferred from `OpenClickyModelOption.provider` at model-pick time `OpenClickyModelCatalog.swift:83-95, 126-181`, and switched on in `CompanionManager.analyzeVoiceResponse` (see project CLAUDE.md "Inference Routing") | Implicit via model grid; no separate schema picker | **E** — Openclicky binds schema to the model identifier catalog, so the user picks a model row and the schema follows. Different UX; same information. |
| 8 | Assistant.ModelId | `Assistant.cs:30` | `AppBundleConfiguration.voiceResponseModelDefaultsKey` = `"selectedVoiceResponseModel"` `OpenClickyProfile.swift:43`; `UserDefaults "clickyCodexModel"` `OpenClickyProfile.swift:133` for Agent Mode; `@Published selectedComputerUseModel` `CompanionManager.swift:1796` | `modelOptionGrid` at `OpenClickySettingsWindowManager.swift:959, 1370-1374, 1971-1975` | **A** — parity via per-capability picker. |
| 9 | Assistant.SupportsToolCall / InputModalities / OutputModalities / ContextLimit / OutputLimit / Specializations / DeprecationDate | `Assistant.cs:33-58` | `OpenClickyModelOption.maxOutputTokens` only `OpenClickyModelCatalog.swift:94` | none | **C** — Feature gap. Openclicky's `OpenClickyModelOption` carries only `id/label/provider/maxOutputTokens`; the rest is hard-coded in call sites (e.g. speech vs text branching at `OpenClickyModelCatalog.swift:253-256`). No user-editable capability metadata. |
| 10 | Assistant.ConfiguratorType (Official / PresetBased / Advanced) | `Assistant.cs:63` | none | none | **C** — Feature gap. Openclicky has one implicit shape per provider. |
| 11 | Assistant.ModelProviderTemplateId + ModelDefinitionTemplateId | `Assistant.cs:67-71` | none | none | **C** — Feature gap. Everywhere's `PresetBasedAssistantConfigurator.Templates.cs:66,141,236` template library has no analogue. |
| 12 | Assistant.RequestTimeoutSeconds (default 20) | `Assistant.cs:93` | Timeout constants embedded per-client: e.g. `ClaudeAgentSDKAPI.requestTimeoutNanoseconds = 120_000_000_000` `ClaudeAgentSDKAPI.swift:55` (120 s hard-coded) | none | **C** — Feature gap. Timeouts are compile-time in openclicky. |
| 13 | AnthropicOptions.ThinkingEffort (live user value `"xhigh"`) | `Assistant.cs:118-123`, present in live `settings.json:106-108` | none — Claude Agent SDK path does not surface thinking-effort as a UI setting | none | **C** — Feature gap. Openclicky wraps SDK output but does not expose extended-thinking knobs. |
| 14 | OpenAIOptions sub-panel | `Assistant.cs:98-103` | none | none | **C** — Feature gap. Same story as Anthropic thinking. |
| 15 | GoogleOptions sub-panel | `Assistant.cs:125-133` | none — openclicky's catalog has no Google provider `OpenClickyModelCatalog.swift:3-9` | none | **E** — Product choice. No Gemini path. |
| 16 | SystemAssistant.TitleGeneration model | `SystemAssistantSettings.cs:26` | none — chat titles derived by heuristics inside `CompanionManager` | none | **C** — Feature gap. |
| 17 | SystemAssistant.DefaultSubagent model | `SystemAssistantSettings.cs:33` | none — sub-agents inherit the parent Codex session model; `HeyClickyFreeTierAgentHook.swift` gates the free lane, no per-role picker | none | **C** — Feature gap. |
| 18 | SystemAssistant.ImageUnderstanding model | `SystemAssistantSettings.cs:40` | Vision automatically uses `voiceAnalysisModel(withID:)` `OpenClickyModelCatalog.swift:213-234` (falls back to `defaultVoiceAnalysisModelID` = `gpt-5.5`), not user-selectable | none | **B** — Wire gap: separate resolver exists but is not surfaced as its own picker. |
| 19 | OpenAI (Codex) API key | live user config uses one Anthropic key at `settings.json:20-23` (Assistant.ApiKey → `ModelSettings.ApiKeys[0]`); OpenAI/Google/etc use same `ApiKeys` collection | `AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey = "openClickyCodexAgentAPIKey"` `AppBundleConfiguration.swift:59`; resolver `AppBundleConfiguration.openAIAPIKey()` `:129-133` | Advanced Providers > "OpenAI / Codex" secure field (`OpenClickySettingsWindowManager.swift:397, 1301-1366`) | **A** for OpenAI. |
| 20 | Anthropic API key | same registry — see #19 | `userAnthropicAPIKeyDefaultsKey` `AppBundleConfiguration.swift:12`; resolver `:119-127` (with `sk-ant-api` prefix guard) | Advanced Providers secure field | **A** for Anthropic. |
| 21 | ElevenLabs API key | Everywhere has no TTS; not a domain-3 setting there | `userElevenLabsAPIKeyDefaultsKey` `AppBundleConfiguration.swift:13`, resolver `:236-243` | Secure field at `OpenClickySettingsWindowManager.swift:1345-1355` | **D** — openclicky-only feature (TTS). |
| 22 | Deepgram API key (STT + Voice Agent) | none in Everywhere | `userDeepgramAPIKeyDefaultsKey` `AppBundleConfiguration.swift:61`, resolver `:229-234` | Advanced Providers panel Deepgram row, and Voice Agent settings `OpenClickySettingsWindowManager.swift:985-1005` | **D**. |
| 23 | AssemblyAI API key | none in Everywhere | `userAssemblyAIAPIKeyDefaultsKey` `AppBundleConfiguration.swift:60`, resolver `:221-227` | Advanced Providers secure field | **D**. |
| 24 | Cartesia API key | none in Everywhere | `userCartesiaAPIKeyDefaultsKey` `AppBundleConfiguration.swift:15`, resolver `:251-258` | Secure field `OpenClickySettingsWindowManager.swift:1357-1366` | **D**. |
| 25 | Free lane / HeyClicky proxy Google OAuth | none in Everywhere | `HeyClickySecrets.oauthAuthorizeURL/supabaseURL/supabaseAnonKey/proxyBaseURL` `HeyClickySecrets.swift:25,29,33,38`; runtime override via `AppBundleConfiguration.heyClickyProxyBaseURLDefaultsKey` (`heyClickyOAuthAuthorizeURLDefaultsKey`) surfaced at `OpenClickySettingsWindowManager.swift:1538-1565`. HeyClicky Free profile applied by `OpenClickyProfileCatalog.heyclickyFree` (`OpenClickyProfile.swift:82-100`) | HeyClicky Free settings group `OpenClickySettingsWindowManager.swift:1424-1573` — sign-in, apply/revert, reset, sign-out, self-hosted proxy | **D** — openclicky-only lane. Explicit design choice (see project CLAUDE.md "Do not add Google login or hosted key sync"; the HeyClicky Free path is preserved as an opt-in free-tier lane, distinct from the Google-login-per-user pattern the guideline forbids). |
| 26 | Provider auto-detect (bubble/notch selector) | none in Everywhere | `OpenClickyProviderDiscovery.availability()`; families `.apple/.codex/.claude` per `OpenClickyModelCatalog.OpenClickyVoiceBackendFamily` `OpenClickyModelCatalog.swift:49-81` | `OpenClickyVoiceBackendSelector` embedded in `CompanionPanelView.swift:422`, `CompanionResponseOverlay.swift:280`, `OpenClickyNotchPanelView+Sections.swift:285` | **D** — openclicky-only three-way family switch. |
| 27 | Response-voice / dialog model picker | Everywhere: `SelectedCustomAssistantId` (single) | `voiceResponseModelDefaultsKey` per profile; UI `modelOptionGrid` at `OpenClickySettingsWindowManager.swift:959-961` | Models tab response grid | **A** (functional). Shape differs (per-lane vs single assistant). |
| 28 | Realtime / speech model picker (`gpt-realtime-2.1-mini/2.1/1.5`, `deepgram-voice-agent`, `heyclicky-free-speech`) | none | `OpenClickyModelCatalog.speechModels` `OpenClickyModelCatalog.swift:141-158`; `isSpeechModelID()` gates UI display `OpenClickySettingsWindowManager.swift:590,657,935` | Models tab (speech-mode variant) | **D**. |
| 29 | Computer-use model (screen pointing) | none | `@Published selectedComputerUseModel` `CompanionManager.swift:1796`; catalog `OpenClickyModelCatalog.computerUseModels` `OpenClickyModelCatalog.swift:162-171` | Computer-use panel `OpenClickySettingsWindowManager.swift:1967-1975` | **D**. |
| 30 | Agent Mode (Codex) model | none in Everywhere (no Codex host) | `UserDefaults "clickyCodexModel"` `OpenClickyProfile.swift:133`, applied via `session.setModel($0)` `OpenClickySettingsWindowManager.swift:1369-1374` | Agents tab > "Agent Mode Model" grid | **D**. |
| 31 | Codex `model_reasoning_effort` | none | `UserDefaults "clickyCodexReasoningEffort"` `CompanionManager.swift:3039`; consumed by `ClickyCodexConfigTemplate.reasoningEffort` `ClickyCodexConfigTemplate.swift:22,125` | none — set programmatically, no picker | **B** — Wire gap. Storage present, no settings row. |
| 32 | Codex config template regen button | none | `ClickyCodexConfigTemplate.renderTOML()` (referenced at `ClickyCodexConfigTemplate.swift:105,119-121`); regen entry `session.syncProviderConfigurationFromCurrentSettings()` and `settingsCodexHomeManager().writeCodexConfigFromSettings()` `OpenClickySettingsWindowManager.swift:2344-2372` | "Sync MCP config" action `OpenClickySettingsWindowManager.swift:2157-2159`; per-provider "Sync" on endpoint change `:2344-2356` | **D** — openclicky-only. |
| 33 | Codex working directory (per session) | none | `session.workingDirectoryPath` mirrored to `UserDefaults "clickyCodexWorkingDirectory"` `OpenClickySettingsWindowManager.swift:1380-1388` | Agents tab textFieldRow | **D**. |
| 34 | Deepgram Voice Agent "think model" | none | `userDeepgramVoiceAgentThinkModelDefaultsKey` `AppBundleConfiguration.swift:23`, default `"gpt-4o-mini"` `OpenClickySettingsWindowManager.swift:202` | textFieldRow at `OpenClickySettingsWindowManager.swift:995-1002` | **D**. |
| 35 | Language override for spoken replies | none | `userVoiceResponseLanguageDefaultsKey` `AppBundleConfiguration.swift:34-51` | Voice section (out of file range read, but bound via `AppStorage`) | **D**. |
| 36 | ExternalControlBridge / cua driver MCP toggles | Everywhere `McpServer.OpenDia*` — different bridge (Chrome ext), not directly comparable | `userMCPDeveloperDocsEnabledDefaultsKey/…ComposioConnect/…ComputerUse/…CuaDriverCommand` `AppBundleConfiguration.swift:69-72` | MCP servers group `OpenClickySettingsWindowManager.swift:2084-2151` | **D**. |
| 37 | Memory persistence root | Everywhere `~/.everywhere/` `EverywherePaths.cs:62-65`; sites subtree `EverywherePaths.cs:38-43` | Openclicky `~/Library/Application Support/OpenClicky/memory.json` (single blob) `MemoryStore.swift:65-81` | **not user-editable** — path is code-defined in both products | **A** (functional). Divergence documented in `F16-memory-2026-07-23.md:88-89`. |
| 38 | Memory storage layout (per-domain fan-out vs single blob) | `MemoryStore.cs:33-53` per-domain directories | `MemoryStore.swift:1-13` single-tenant JSON blob, snapshot subdir at `<store>/snapshots/` `MemoryStore.swift:273-276` | none (code-defined) | **E** — deliberate single-tenant re-interpretation, documented in file header. See F16 review Issue 1 for wire-level naming mismatch (`memory_snapshot` read vs write). |
| 39 | Memory freshness thresholds (`fresh <30d, stale 30-90d, cold >=90d`) | `Freshness.cs:9,14-16` hard-coded | `MemoryStore.dayMs` + `MemoryStore.classifyFreshness()` `MemoryStore.swift:137-144` — same boundaries, hard-coded | none (both) | **A** — categorical parity. Note: openclicky *also* exposes a numeric `MemoryFreshnessInfo {lastWriteAt, stalenessSeconds}` `MemoryStore.swift:115-134` alongside the categorical bucket (see F16 Issue 2 for the semantic drift). |
| 40 | Memory snapshot rotation policy (keep last 5) | `MemoryStore.cs:210-212` hard-coded 5 | `MemoryStore.writeSnapshot(keepLast: Int = 5)` `MemoryStore.swift:238-268` — same default, parametrised | none | **A** (functional). |
| 41 | `MEMORY_LOCK_TIMEOUT` cross-process lock timeout | `MergeSafeWriter.cs:12,30-45,63-68` env-driven, 5 s default | none — `NSLock` in-process, no timeout `MemoryStore.swift:48` (see F16 Issue 5) | none | **E** — deliberate simplification for single-process app; documented at `MemoryStore.swift:11-12`. |
| 42 | Persistent Codex memory file (long-term) | none | `CodexHomeManager.persistentMemoryFile = <CodexHome>/memory.md` `CodexHomeManager.swift:67-69`; archive dir at `:71-73`; hard cap `maxPersistentMemoryBytes = 120_000` `:27` | Connections panel > Persistent memory group `OpenClickySettingsWindowManager.swift:2167-2185`; Memory tools actions `:2187-2200` | **D** — openclicky-only, orthogonal to the MCP memory store above. |
| 43 | Memory archive rotation cap (bytes) | none | `maxPersistentMemoryBytes = 120_000` `CodexHomeManager.swift:27`, checked at `:608` | none — no user override | **C** — Not exposed. |
| 44 | Memory browser / archive folder actions | none | `companionManager.showMemoryWindow()` action, "Open memory archive folder" action | Connections > "Memory tools" group `OpenClickySettingsWindowManager.swift:2187-2200` | **D**. |
| 45 | Route tag `[ROUTE] {json}` opt-in / disable | none | none — `[ROUTE]` directive is always injected into Fable prompt `HeyClickyChatToolCallClient.swift:861-879`; parsed at `:1046-1060`; dispatcher `OpenClickyRouteDispatcher.swift:47-91` | none | **C** — Feature gap. Users cannot disable the ROUTE contract; it's a compile-time protocol. Design intent is that `[ROUTE]`-absent replies fall back safely via `classifyFallback` (`OpenClickyRouteDispatcher.swift:93-139`), so a user knob is arguably unneeded — but this should be a documented decision, not silent. |
| 46 | Router confidence gate (default 0.6) | none | Hard-coded `if route.confidence < 0.6` `OpenClickyRouteDispatcher.swift:65` | none | **C** — Feature gap. `F26-route-parse-2026-07-23.md` HIGH #1 also flags related integration surface gaps. |
| 47 | Route.progressDriven flag | none | `RouteParseResult.progressDriven: Bool` decoded from Fable reply `HeyClickyChatToolCallClient.swift:827,855,888`; effective marker resolver `:875-880`; logged at `OpenClickyRouteDispatcher.swift:53` | none — model-driven, no user override | **C** — Feature gap. Openclicky reads the field from the Fable reply but does not let the user force-enable or force-disable progress-driven autonomy. |
| 48 | Route.completionMarker (default `"LAST_COMPLETED: DONE"`) | none | `RouteParseResult.completionMarker: String?` `HeyClickyChatToolCallClient.swift:828,856`; fallback to `"LAST_COMPLETED: DONE"` at `:879`; template contract at `AGENTS-longrun-template.md:28-32` | none | **C** — Feature gap for user override; the default is a compile-time constant. |
| 49 | Auto-continue observer (progress-driven fire on `turn/completed`) | none | Notification wiring `CompanionManager+HeyClicky.swift:791-901`; `session.progressDriven` read at `:842,873,894,896`; auto-continue prompt at `:362-363` "Continue against PROGRESS.md — next unchecked item. Do not summarize." | none | **B** — Storage/logic exists but is gated only by the (model-supplied) `progressDriven` flag; no UI to enable/disable per user. `F28-auto-continue-2026-07-23.md` documents this as a missing feature on the observer side (progress-driven autonomy is only partially implemented). |
| 50 | Auto-continue turn cap ("no cap" per user's session choice) | none | None enforced. Only per-session failure budget = 3 consecutive no-progress replays + 300 s cooldown `heyClickyObserverStore.shouldAttemptRecovery(...)` `CompanionManager.swift:4533`; documented in `F28-auto-continue-2026-07-23.md:38`. No absolute turn ceiling — matches user directive "no cap". | none | **A** (by user decision). Explicitly no cap. `F28-auto-continue-2026-07-23.md:294` records the decision. |
| 51 | Auto-continue debounce / circuit breaker | none | `heyClickyObserverStore.isCircuitOpen()` + `shouldDispatchAutoReplay` `CompanionManager+HeyClicky.swift:879-889` | none | **D** — openclicky-only safety net. |
| 52 | Long-run agent template (`AGENTS-longrun-template.md`) path / edit | none | Bundled resource `AppResources/OpenClicky/AGENTS-longrun-template.md`; only *referenced* by comments (`CodexAgentSession.swift:336,345`, `CompanionManager+HeyClicky.swift:359`, `HeyClickyChatToolCallClient.swift:871`, `OpenClickyProgressMarkerCheck.swift:11`, `CodexProcessManager.swift:58`) — nothing copies it into the codex home or `$OPENCLICKY_TASK_DIR` | none | **C** — Feature gap. `CodexHomeManager` copies `AGENTS.md` (`CodexHomeManager.swift:134-138`) but not the long-run template. Users cannot edit the template through the app; edits to the bundled `.md` inside the app bundle would not survive an app update. |
| 53 | Long-run task working-directory env vars (`OPENCLICKY_TASK_DIR`, `OPENCLICKY_TASK_PROGRESS`) | none | Env-var contract lives in `AGENTS-longrun-template.md:9,20`; no Swift code sets them (`grep -rn "OPENCLICKY_TASK_DIR" cursor-buddy` — see F26/F28 findings) | none | **C** — Feature gap. Contract documented in bundled template only; not yet exported by the process manager. |
| 54 | Voice-profile bundle (STT + response + TTS + activation) | none | `OpenClickyProfile` value type + `OpenClickyProfileCatalog` `OpenClickyProfile.swift:19-135`. Four built-ins: default local (Claude Haiku + Edge TTS + Parakeet STT), `realtime`, `quality`, `heyclicky_free`. Applied via `OpenClickyProfileCatalog.apply(_:defaults:)` `:122-135` writing existing UserDefaults keys. | `OpenClickyProfileSelectorView` embedded in `OpenClickySettingsWindowManager.swift:330` | **D** — openclicky-only ergonomic wrapper. |
| 55 | Per-lane provider gating for the HeyClicky Free plan | none | Free lane is only available when signed in; `HeyClickyFreeTierAgentHook.swift` gates Agent Mode use; `heyclicky-free-speech` collapses STT+response+TTS into one `openAIRealtime` transport `OpenClickyProfile.swift:82-100`; free agent model = `heyclicky-free-agent` `OpenClickyModelCatalog.swift:180` | HeyClicky Free settings group `OpenClickySettingsWindowManager.swift:1424-1573` | **D**. |
| 56 | Voice-response caption toggle / font / opacity | none | `userVoiceResponseCaptionsEnabledDefaultsKey/…Font/…Opacity` `AppBundleConfiguration.swift:28-30` | Voice/UI section `OpenClickySettingsWindowManager.swift:221-223` | **D** — parity-domain-4 (UX/appearance) counted this; listed here only because it lives adjacent to the response-model picker. |

## Cross-references

- Memory internals + wire-level parity: `docs/ROADMAP/.review-notes/F16-memory-2026-07-23.md`.
- Router semantics: `docs/ROADMAP/.review-notes/F26-route-parse-2026-07-23.md`. Note HIGH Issue 1 there: `startVoiceAgentTaskPlan` does not thread `progressDriven / completionMarker` as first-class args (they exist only on `RouteParseResult`), which explains why rows 47/48/49 are B/C.
- Auto-continue observer: `docs/ROADMAP/.review-notes/F28-auto-continue-2026-07-23.md`. The observer as it stands is an error-recovery loop, not a progress-driven autonomy loop; the design gap is captured there (Issue 3 = no absolute turn cap by user decision).
- Codex config emission: `docs/ROADMAP/.review-notes/F27-codex-sensor-config-2026-07-23.md`.

## Issues surfaced by this table

### Issue 1 (HIGH) — API keys stored in plaintext UserDefaults, not Keychain

Everywhere routes every secret through `OsSecretVault` and persists only `{Id, Name}` in `settings.json` (`ApiKey.cs:34,40,165`). Openclicky writes each provider key verbatim into `UserDefaults` (`AppBundleConfiguration.swift:12-15,59-61`) via `secureFieldRow`. `~/Library/Preferences/com.jkneen.openclicky.plist` will contain readable `sk-ant-api…` and `sk-…` bytes. macOS Keychain is available and Everywhere uses it via `GnomeStack.Os.Secrets`; openclicky's equivalent (`Security`-framework Keychain APIs) is already imported at `AppBundleConfiguration.swift:9` (`import Security`) but the current resolver path does not use it for user-configured keys. This is a security regression relative to Everywhere. Fix: promote all `user*APIKeyDefaultsKey` slots to Keychain-backed accessors; keep UserDefaults for the id/name pair if openclicky adopts a named-registry (see #2).

### Issue 2 (MEDIUM) — Fixed per-provider slot, not a named-key registry

Everywhere's `ModelSettings.ApiKeys : ObservableCollection<ApiKey>` (`ModelSettings.cs:30`) lets a user hold multiple keys for the same provider and pick one per assistant. Openclicky pins one slot per provider, which forces re-typing when switching between accounts (e.g. work vs personal Anthropic key). Rows 1-4 above. This is a shape difference that also blocks parity with Everywhere's Custom-Assistant list (row 4/5/6).

### Issue 3 (MEDIUM) — No user override for router confidence gate / progressDriven / completionMarker

Rows 45-48. The `[ROUTE]` contract is a hard-coded protocol between openclicky and the Fable dialog model. There is no debug switch to disable the injection (helpful when the user wants pure chat with no dispatch), no way to raise the 0.6 confidence gate (`OpenClickyRouteDispatcher.swift:65`) if the router misclassifies, and no way to force `progressDriven=true` on a task the model tagged `chat`. Advanced-users escape hatch missing. Recommend a hidden `openClickyRouteDispatchEnabled` / `openClickyRouteConfidenceGate` pair in UserDefaults exposed under an Advanced disclosure.

### Issue 4 (MEDIUM) — Long-run template is a bundled resource, not editable and not deployed

Row 52. `AGENTS-longrun-template.md` is only referenced by comments in Swift; nothing copies it next to `AGENTS.md` when preparing the Codex home (`CodexHomeManager.swift:134-138` copies `AGENTS.md` and `OpenClickyModelInstructions.md` only). This means:
1. The env-var contract at `AGENTS-longrun-template.md:9,20` (`$OPENCLICKY_TASK_DIR`, `$OPENCLICKY_TASK_PROGRESS`) is documented but never exported by `CodexProcessManager` — the model reads a spec that the runtime does not fulfil.
2. Users who want to customise the long-run protocol have to edit the bundled `.md` inside the signed app, which does not survive an update.

Fix: either (a) copy the template into the Codex home during `prepare(bundle:)`, then read it back from disk so users can edit it; or (b) inline the contract into `AGENTS.md` and drop the standalone template.

### Issue 5 (MEDIUM) — Model-catalog rows carry no capability metadata beyond `maxOutputTokens`

Row 9. Everywhere's `Assistant.SupportsToolCall/InputModalities/OutputModalities/ContextLimit/OutputLimit/Specializations/DeprecationDate` (`Assistant.cs:33-58`) let the user reason about what a model can do without cross-referencing the vendor. Openclicky's `OpenClickyModelOption` carries only `{id, label, provider, maxOutputTokens}` (`OpenClickyModelCatalog.swift:83-95`). Capability decisions (speech vs text, computer-use eligibility) live in code branches. Impact: a user cannot see, at pick time, which models are vision-capable or which are deprecated. Also affects Row 18 (image-understanding selection).

### Issue 6 (LOW) — Codex reasoning-effort has no picker

Row 31. `UserDefaults "clickyCodexReasoningEffort"` is written by `CompanionManager.swift:3039` and read by `CodexHomeManager.swift:42` + `ClickyCodexConfigTemplate.reasoningEffort` `ClickyCodexConfigTemplate.swift:22`. Default `"medium"`. No settings row exists to change it. Users who want `"high"` or `"low"` must poke `defaults write` manually.

### Issue 7 (LOW) — Persistent-memory byte cap not user-configurable

Row 43. `maxPersistentMemoryBytes = 120_000` `CodexHomeManager.swift:27`. When the cap trips, the file rolls to the archive dir (`persistentMemoryArchivesDirectory`). The cap is invisible until it fires. Add either a status row (current bytes / cap) or a numeric setting.

### Issue 8 (INFO) — Openclicky memory-store path deliberately diverges

Row 37/38. Documented deviation: single-tenant `~/Library/Application Support/OpenClicky/memory.json` + snapshots dir vs Everywhere's `~/.everywhere/sites/<domain>/` fan-out. Code-defined in both; no user knob. Recorded as INFO because the deviation is intentional and already flagged in the file header (`MemoryStore.swift:1-13`) and in F16 Issue 8.

## Verdict summary

- **A** parity rows: 8, 19, 20, 27, 37, 39, 40, 50. (8)
- **B** wire gaps: 1 (hybrid with D), 5, 6, 18, 31, 49. (6)
- **C** feature gaps: 2, 3, 4, 9, 10, 11, 12, 13, 14, 16, 17, 43, 45, 46, 47, 48, 52, 53. (18)
- **D** openclicky extras: 21, 22, 23, 24, 25, 26, 28, 29, 30, 32, 33, 34, 35, 36, 42, 44, 51, 54, 55, 56. (20)
- **E** intentional non-parity: 7, 15, 38, 41. (4)

Domain-3 shape: openclicky trades Everywhere's rich named-assistant/named-key registry for a fixed provider-slot model plus a lane-based profile catalog, adds a large surface for voice/TTS/computer-use/free-plan/agent primitives Everywhere never had, and diverges deliberately on the memory store while keeping the freshness/rotation rules bit-for-bit. The domain's real risk lives in Issue 1 (plaintext key persistence) and Issues 3-4 (router/long-run protocol has no runtime override or updatable template).
