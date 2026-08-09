# Openclicky Regression Audit vs Everywhere Port — 2026-07-23

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809` (informational; openclicky-native features do not have byte-parity targets).
Standard: only trust code, `file:line` for every claim, no code changes.

Scope: verify pre-port core (voice, agent-mode, chrome-bridge, HeyClicky-free lane, auto-continue error recovery, cursor overlay + response cards, menu bar + notch, mini chat, memory browser, ProjectRegistry/WorkdirProbe) still functional after Everywhere-port enhancements (F26 route parse, F27 codex sensor config, F28 progress-driven auto-continue, task planning pipeline, F31 OpenDia, F23/F24/F25 whiteboard/linkrect/pick overlays).

---

## Original openclicky features — verified intact

### 1. Voice pipeline
- Provider dispatch preserved: `cursor-buddy/CompanionManager+AIResponsePipeline.swift:376-443` switches on `selectedVoiceResponseModel.provider` across `.apple / .anthropic / .openAI / .deepgram / .codex / .heyclickyFree` exactly as CLAUDE.md prescribes.
- `.heyclickyFree` arm (Fable + `[ROUTE]`) at `CompanionManager+AIResponsePipeline.swift:422-442` — scope-note comment at :422-434 explicitly states `[ROUTE]` directive is Fable-only by design (F26 Issue L3), which is why the other four arms (Apple/Claude/OpenAI/Codex direct) do not carry the directive block. Fallback classifier in `OpenClickyRouteDispatcher.classifyFallback` covers those turns via preflight signals only.
- Wake-word / push-to-talk / activation surface intact: `wakeWordManager` field at `CompanionManager.swift:597`, wake-word wiring at `:1776`, PTT stop reasons at `:2389`, mic-permission stop at `:4257`.
- Circle-while-talking: `CompanionScreenCaptureUtility` calls at `CompanionManager.swift:2405, 3858-3859, 5588, 5693` unchanged; sealed-stroke plumbing comment at `:668` preserved.
- HeyClickyChatToolCallClient chat happy path: text response returned via `onTextChunk(finalText)` at `HeyClickyChatToolCallClient.swift:523` unconditionally, AFTER the optional `[ROUTE]` parse/dispatch at `:478-521`. Parse failure is a soft no-op (:495-521) — the reply is always spoken, no accidental swallow.

### 2. Agent Mode long-run
- `CodexAgentSession` field surface: `workingDirectoryPath`, `taskDir`, `taskProgressPath`, `progressDriven`, `completionMarker` all `@Published` (per task-planning-pipeline review `docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md:35-37` and `.impl-notes/task-planning-pipeline-fix-report-2026-07-23.md:70-73`).
- `turn/completed` handler `CodexAgentSession.swift:1983-2005` keeps every pre-port responsibility: `flushPendingAssistantDeltas`, `persistCompletedTurnMemoryIfNeeded`, lease-release, `queuedFollowUpPrompts` drain. The F28 progress-driven fire at `:2006-2063` is additive and gated by `progressDriven && !workingDirectoryPath.isEmpty && model.hasPrefix("heyclicky-free-")` (`:2021-2023`) — non-progress-driven turns fall through the block untouched.
- `RouteDispatcher.shared.companionManager = self` wired once at `CompanionManager.swift:1787`.
- Codex spawn env vars additive: `CodexProcessManager.swift:60-65` only sets `OPENCLICKY_TASK_DIR / OPENCLICKY_TASK_PROGRESS` when non-nil-non-empty; other spawns (voice session, point detector) skip them cleanly. F27 `OPENCLICKY_BRIDGE_TOKEN` in `ClickyCodexConfigTemplate.swift:214, 243, 369` is a separate env key — no collision.

### 3. Chrome bridge (port 3011)
- `HeyClickyChromeBridgeServer.swift:26` binds fixed port 3011. Endpoints preserved:
  - `GET /health` at `:270-272` returns `{"ok": true, "extAlive": …}` verbatim.
  - `GET /cmd` long-poll at `:273-274` -> `handleCmdPoll` at `:286-301` with 25 s timeout unchanged.
  - `POST /event` at `:275-276` -> `handleEvent` at `:303-311` unchanged.
- OpenDia is on a dynamically-allocated port with `READY <port>` handshake (`OpenClickyOpenDiaSubprocess.swift:410-413`, `:188-200`) — no fixed-port clash with Chrome bridge 3011. Also OpenDia is WebSocket ext ↔ node, whereas the Chrome bridge is HTTP long-poll ext ↔ Swift; contracts are orthogonal.
- Bridge start/stop still routed through `stopHeyClickyFreeSubsystems` at `CompanionManager+HeyClicky.swift:1005-1014` (calls `.stop()` on the bridge) — no lifecycle regression.

### 4. HeyClicky Free lane
- `HeyClickySecrets.swift:22-39` remains empty-by-default template (proxyBaseURL, supabase URL, anon key, oauth URL). Never a raw paid API key. Money-rule preserved.
- Planning loop uses only the free lane: `OpenClickyPlanningLoop.swift:124-132` constructs `HeyClickyFreePlanningClient.PlanRequest` (msgs-quota channel) — never a Claude / OpenAI / Codex direct call.
- Codex config bearer indirection preserved: `ClickyCodexConfigTemplate.swift:200, 214, 243, 369` still emits `bearer_token_env_var = "\(bridgeTokenEnvVarName)"` in `[mcp_servers.*]` — no direct key path landed.
- Codex ephemeral vs raw JWT branching preserved at `CodexProcessManager.swift:70-79` (config-first `OPENAI_API_KEY`, then codex ephemeral, then raw supabase JWT). F27 fix reference at `:38` still cited.

### 5. Auto-continue observer (both paths coexist)
- Path A (error recovery, pre-port): `CompanionManager+HeyClicky.swift:791-900` observer body handles 402 (`CodexAgentSession.swift:1629-1634`), 428 (`CodexAgentSession.swift:2158`), auto-fault trigger (`CompanionManager.swift:3272`), cooldown/failed/zombie (`CompanionManager.swift:4553, 4563, 4666`), plus wake-from-sleep (`CompanionManager+HeyClicky.swift:918-943`), codex-crash relaunch (`:750-786`), credential-refresh flow (fires the same notification).
- Path B (F28 progress-driven, port-era): sole poster at `CodexAgentSession.swift:2053-2062`. The `userInfo` carries `"source": "f28_progress_driven"` for observability.
- Coexistence gate at `CompanionManager+HeyClicky.swift:834-848`: `.completed` is auto-replay-skipped UNLESS `session.progressDriven == true` — i.e. F28-eligible sessions bypass the skip, all other completed sessions still bail. Non-progress-driven sessions preserve the "completed means intentionally done" invariant.
- `hasInterruptedInFlightTurn` gate at `:413-468`: F28 fix inverted `.completed` return only when `progressDriven && !workingDirectoryPath.isEmpty && marker absent` (`:445-465`). For every other `.completed` case, the branch still falls through to `return false` at `:466`. Non-progress-driven flow correctly returns `false` — invariant preserved.
- Shared safety net (`shouldDispatchAutoReplay` 3 s debounce, `isCircuitOpen`, 3-attempt / 300 s cooldown) at `:269-321` used by BOTH paths — no path-specific bypass.
- User-initiated stop gate at `:441-456` (`isUserInitiatedStop`) still filters both paths (`:416, 855-859`) — Stop button remains Stop.

### 6. UI overlays
- Cursor overlay + response cards use `OpenClickyWindowLevels.cursorOverlay = statusSurface = draggingWindow - 1` at `OpenClickyWindowInfrastructure.swift:26-31`. Applied in `OverlayWindow.swift:151, 3208`.
- New whiteboard overlay uses `OpenClickyWindowLevels.statusSurface` (`OpenClickyWhiteboardOverlayWindow.swift:64`) — SAME level as cursor overlay. Whiteboard is user-hotkey-gated (comment at `:13`), only shows during begin()->end() lifecycle (`:284, 323, 346`), and does not permanently sit above overlay.
- Link-rect overlay uses `.screenSaver` (`OpenClickyLinkRectOverlayWindow.swift:23, 155`) — above overlay but again hotkey-transient and ignoresMouseEvents. No permanent draw-order stealing.
- Pick-element overlay uses distinct window; no evidence of always-on placement.
- Cursor overlay logic in `OverlayWindow.swift` (agent dock icons, captions, response cards) untouched by port — voice-turn state still drives `cursorState = companionManager.cursorOverlayState` (`:504`).

### 7. Menu bar / MiniChatPanel
- `MenuBarPanelManager.swift`: statusItem plumbing at `:39, 133-143`, click at `:245-251`, toggle at `:254`, `showPanel` at `:350`, positioning at `:477-505`. No port-era edits (no `HeyClicky` / `OpenDia` / route symbols referenced).
- `MiniChatPanelManager.swift`: modified in git status but the surface (mini chat panel) still exists per file listing — not directly cross-referenced by dispatcher / F28.

### 8. Codex Home management, ProjectRegistry, WorkdirProbe
- `CodexHomeManager.swift:134-135` copies `AGENTS.md` verbatim into `$CODEX_HOME`. The task-planning contract was inlined into `AGENTS.md:33-63` (see `AppResources/OpenClicky/AGENTS.md:33-64`) so it reaches every spawn without pbxproj changes.
- `ProjectRegistry` and `WorkdirProbe` live in `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/` and are imported by `OpenClickyRouteDispatcher.swift` (via `import OpenClickyContextService`) — pre-port fuzzy-match plus workdir emptiness / project-type probe still available at `OpenClickyRouteDispatcher.swift:108-166` (fallback classifier).
- Persistent memory: `MemoryDrawerView.swift` and `OpenClickyMemory*` references in `CompanionManager.swift, CodexHomeManager.swift, CompanionManager+AIResponsePipeline.swift, CompanionManager+Onboarding.swift, CodexAgentSession.swift` still present — surface not touched by port.

### 9. HeyClickyAccountResetManager (chrome bridge consumer)
- `HeyClickyAccountResetManager.swift` still present (20.3K). No port-era rewrites.

---

## Enhancements — verified integrated

### Chat (no side effects)
Trace, chat kind (dialog reply only):
1. User voice turn -> `CompanionManager.analyzeVoiceResponse` -> `.heyclickyFree` arm -> `HeyClickyChatToolCallClient.analyzeVoiceResponse` at `HeyClickyChatToolCallClient.swift:135` (non-streaming POST).
2. Full reply materialised, then `parseRouteJSON(finalText)` at `:478` (anchored end-of-line pattern at `:1116`, loose backup at `:1117`, last-wins at `:1127`).
3. If parsed and `route.kind == "chat"` or `"ambiguous"` -> `RouteDispatcher.dispatch` at `OpenClickyRouteDispatcher.swift:83-86` explicit no-op comment ("dialog TTS reply already covers the user"). No codex spawn, no `dispatchRoutedAgentTask`, no `startVoiceAgentTaskPlan`.
4. If parse fails or missing -> `classifyFallback` at `HeyClickyChatToolCallClient.swift:499-502`; when fallback returns `chat` (safe default at `OpenClickyRouteDispatcher.swift:159-165`), the inner `if fallback.kind != "chat"` guard at `HeyClickyChatToolCallClient.swift:503` skips dispatch entirely — no-op.
5. `onTextChunk(finalText)` at `:523` always fires downstream, so the TTS/UI pipeline still receives the reply.

Verdict: chat path unchanged. No PROGRESS.md, no codex, no F28 fire (no session created).

### Short task (in-app PlanningLoop)
Trace, kind ∈ {task, short_task, long_task_new, long_task_existing} WITHOUT pre-existing PROGRESS.md:
1. `parseRouteJSON` decodes `RouteParseResult` at `HeyClickyChatToolCallClient.swift:1119-1133` (fields at `:813-827`: kind, projectRef, slug, workdir, confidence + progressDriven/completionMarker per F26 substrate).
2. `RouteDispatcher.dispatch` at `OpenClickyRouteDispatcher.swift:83-93`. Confidence gate at `:91-98` (F26 Issue L1). `spawnCodex` at `:87`.
3. `spawnCodex` resolves workdir: `route.workdir` (tilde-expanded at `:188`, F26 Issue #2), then `projectRef` via `ProjectRegistry.shared.lookup` (F26 Issue L2 at `:189-200`), then `preflight.selectedFolder`, else nil (standalone variant).
4. `OpenClickyTaskDirectoryResolver.resolve(workdir:, slug:)` at `:208-217`:
   - Variant A `<workdir>/.openclicky/task/PROGRESS.md` (`OpenClickyTaskDirectoryResolver.swift:35-48`).
   - Variant B `~/OpenClicky/<slug>/PROGRESS.md` with slug-collision resolution (`:50-64`, `:73-103`).
5. If `resolution.progressExists == false` (this branch = short task, no external SPEC.md): `OpenClickyPlanningLoop.generate` at `OpenClickyRouteDispatcher.swift:242` runs 3-round loop against `HeyClickyFreePlanningClient` (msgs-quota lane).
6. PROGRESS.md written atomically at `:244` (`OpenClickyRouteDispatcher.swift:243-244`).
7. `performSpawn` at `:263` -> `companion.dispatchRoutedAgentTask` at `:288`.
8. `dispatchRoutedAgentTask` at `CompanionManager.swift:14514-14540` -> `startVoiceAgentTaskPlan` at `:14433-14507` -> `startVoiceAgentTask` at `:14542+`, threading `taskDir`, `taskProgressPath`, `progressDriven=true`, `completionMarker`.
9. `CodexProcessManager.baseEnvironment` + injected `OPENCLICKY_TASK_DIR` / `OPENCLICKY_TASK_PROGRESS` at `CodexProcessManager.swift:60-65`.
10. Agent reads `AGENTS.md:33-64` "Task planning contract" section at spawn time (inlined by CodexHomeManager copy), globs `$OPENCLICKY_TASK_DIR`, drives `$OPENCLICKY_TASK_PROGRESS` toward `LAST_COMPLETED: DONE`.
11. `turn/completed` -> F28 fire at `CodexAgentSession.swift:2021-2062` if marker missing -> `.heyClickyRequestAutoContinueReplay` -> observer at `CompanionManager+HeyClicky.swift:791-900` -> new steer or new turn until marker written.

Verdict: intact end-to-end.

### Long task (external SPEC.md)
Trace, kind = task with Finder folder + pre-existing `.openclicky/task/PROGRESS.md`:
1-4. Same as short task; step 4 selects Variant A anchored to the Finder folder.
5. `resolution.progressExists == true` -> `OpenClickyRouteDispatcher.swift:262-268` skips PlanningLoop, calls `performSpawn` directly.
6-11. Same env / spawn / F28 loop path as short task; agent picks up the externally-authored SPEC.md via the AGENTS.md contract's "read every file" glob step (`AGENTS.md:37-44`).

Verdict: intact.

---

## Regressions found

### CRITICAL
None.

### HIGH
None. Every pre-port entry point that was audited still routes through unchanged code, with additive gates only.

### MEDIUM

#### M1 — Chat provider drift for non-Fable models is intentional but silent
Direct Claude / OpenAI / Codex arms in `CompanionManager+AIResponsePipeline.swift:385-421` do not inject the `[ROUTE]` directive block. F26 review Issue L3 (`docs/ROADMAP/.review-notes/F26-route-parse-2026-07-23.md:142-148`) explicitly punted this. The comment at `:422-434` documents the intent. Not a regression — pre-port behaviour was "Claude/OpenAI/Codex reply is spoken", still true — but any user who switches provider will see fallback-classifier-only dispatch for task turns. Flag for docs, not code.

#### M2 — New overlay windows do not explicitly yield to voice turns
`OpenClickyWhiteboardOverlayWindow`, `OpenClickyLinkRectOverlayWindow`, `OpenClickyPickElementOverlay` show no `isVoiceTurn`-style gate (grep returned 0). They are user-hotkey-gated, so a user cannot see both simultaneously unless they mash keys, but there is no defensive hide-on-voice hook. Cursor overlay + response cards use the same `statusSurface` level as the whiteboard (`OpenClickyWindowInfrastructure.swift:26-31`, `OpenClickyWhiteboardOverlayWindow.swift:64`), so a mid-voice whiteboard invocation would draw on top of a response card until the user releases the hotkey. Ordering restored on release (`:323, 346`). Flag for polish, not a functional break.

### LOW

#### L1 — F26 confidence-gate coverage nuance
`OpenClickyRouteDispatcher.swift:91-98` enforces `route.confidence < confidenceGate` before dispatching task kinds — good. But if a model self-reports high confidence (>=0.6) on a task that context signals disagree with, the model wins. Design decision, not regression.

#### L2 — F28 fire scoped to `heyclicky-free-` prefix
`CodexAgentSession.swift:2023` and `CompanionManager+HeyClicky.swift:414` restrict F28 to Fable lane. If a user picks Anthropic / OpenAI codex for a long task, progress-driven loop no-ops (F28 review Issue L1). Documented behaviour, not a regression.

#### L3 — Wake-observer resume path uses heavy `buildContextfulResumePrompt`
`CompanionManager+HeyClicky.swift:940-942` still uses `buildContextfulResumePrompt` on wake-from-sleep replays. Progress-driven sessions get the lightweight prompt only via the auto-continue observer (`:874, 897`) and via crash relaunch (`:783`, still heavy — same fallback). Not a regression but an inconsistency: a wake or crash on a progress-driven session sends the heavier `请继续之前的任务…` prompt rather than the F28 lightweight variant. F28 Issue #7 addressed the primary observer only.

---

## Openclicky-native features possibly at risk from port

None found broken. Below are functional surfaces that are adjacent to port changes and deserve a smoke test:

- **Voice happy path with Fable + `[ROUTE]` missing**: fallback classifier defaults to `chat` (`OpenClickyRouteDispatcher.swift:159-165`), TTS still plays via `onTextChunk` at `HeyClickyChatToolCallClient.swift:523`. Verify manually that Fable reply spoken end-to-end when the model omits the tail.
- **Codex Turn Limit (402) auto-continue**: existing path fires `.heyClickyRequestAutoContinueReplay` from `CodexAgentSession.swift:1629-1633`; ensure it still hits the observer body branches that skip `.completed` for non-progress-driven sessions (`CompanionManager+HeyClicky.swift:842-847`). Non-progress-driven means `if !session.progressDriven { return }` — matches pre-port behaviour.
- **Chrome bridge `/health`**: `curl http://127.0.0.1:3011/health` should return `{"ok":true,"extAlive":<bool>}` per `HeyClickyChromeBridgeServer.swift:270-272`.
- **Voice model switch across `.apple / .anthropic / .openAI / .codex / .heyclickyFree`**: routing table at `CompanionManager+AIResponsePipeline.swift:376-443` — every provider still lands in a `throws`-safe branch, no accidental `.heyclickyFree`-only assumption elsewhere.
- **Menu bar / MiniChatPanel invocation**: `MenuBarPanelManager.swift:245-254` still toggles main panel; MiniChatPanelManager modified per git status but no dispatcher reference — verify quick-chat still opens.
- **HeyClicky Free planning loop failure fallback**: `OpenClickyPlanningLoop.swift:106-112, 205-209` writes a minimal PROGRESS.md when the free lane fails — codex still spawns rather than blocking. Confirm the fallback content parses as valid via `isValidProgressMarkdown` at `:191-199`.

---

## Verdict

Port is coherent with pre-existing feature surface. Every pre-port entry point verified above still routes through unchanged code, with all new behaviour gated behind additive predicates (`progressDriven`, `heyclicky-free-` model prefix, `taskProgressPath`-preferred fallback). No regressions found at CRITICAL or HIGH severity. Two MEDIUM items are documented design trade-offs, not defects. Three LOW items are inconsistencies worth polishing.

Files central to the audit (absolute paths):
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CompanionManager.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CompanionManager+HeyClicky.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CompanionManager+AIResponsePipeline.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CodexAgentSession.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CodexProcessManager.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/HeyClickyChatToolCallClient.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/HeyClickyChromeBridgeServer.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/HeyClickySecrets.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyRouteDispatcher.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyTaskDirectoryResolver.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyPlanningLoop.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyProgressMarkerCheck.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyWindowInfrastructure.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/ClickyCodexConfigTemplate.swift`
- `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/AGENTS.md`
