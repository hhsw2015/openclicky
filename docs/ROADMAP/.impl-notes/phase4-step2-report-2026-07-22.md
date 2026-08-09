# Phase 4 Step 2 report — Route dispatch + context-signal fallback

Date: 2026-07-22

## Files created

- `cursor-buddy/OpenClickyRouteDispatcher.swift` (new)
  - `@MainActor final class RouteDispatcher` with `.shared` singleton and `weak var companionManager`.
  - `dispatch(_:userTranscript:preflight:)` — routes explicit [ROUTE] results into codex spawn or short-circuits for chat / ambiguous.
  - `classifyFallback(userTranscript:preflight:)` — WorkdirProbe + ProjectRegistry only, no utterance keyword tables.
  - `composeAgentPrompt(...)` — prepends scene context + intent hint so the spawned codex agent sees what Fable saw.
  - `sanitizedSlug(from:)` — regex slugifier used for ephemeral task dirs.

## Files modified

- `cursor-buddy/HeyClickyChatToolCallClient.swift`
  - Hoisted `preflightSnapshot: FablePreflightContext?` above the context-directive prepend so it survives to the response-tail dispatch.
  - Replaced the Phase 4 Step 1 log-only [ROUTE] block with:
    - success -> `RouteDispatcher.shared.dispatch(...)`
    - miss -> `RouteDispatcher.shared.classifyFallback(...)` -> if kind != "chat" -> dispatch; else no-op.
  - Both branches log `openclicky.route_parsed` / `openclicky.route_missing` / `openclicky.route_fallback` / `openclicky.route_dispatch`.

- `cursor-buddy/CompanionManager.swift`
  - `init(runtimeMode:)` wires `RouteDispatcher.shared.companionManager = self` after `OpenClickyAgentStore.shared.seedBuiltinsFromBundleIfNeeded()`.
  - `startVoiceAgentTaskPlan(...)` and `startVoiceAgentTask(...)` gained a trailing `workingDirectoryOverride: String? = nil` (backwards compatible).
  - Added `dispatchRoutedAgentTask(instruction:workingDirectoryOverride:voiceContextUserTranscript:)` — public bridge used by `RouteDispatcher`. Uses route `agent.route_dispatch`, no spoken ack, no voice interrupt (Fable's TTS reply already ran).
  - Inside `startVoiceAgentTask`, after `createAndSelectNewCodexAgentSession(...)` returns, the override is applied to `agentSession.workingDirectoryPath` iff the path exists and is a directory. Logs `openclicky.route_workdir_applied` / `openclicky.route_workdir_invalid`.

## Route dispatcher flow

```
finalText (Fable reply)
      |
      v
parseRouteJSON(finalText)
      |
   +--+---------------- success ---------------+
   |                                            |
   | miss                                       v
   v                                    RouteDispatcher.dispatch
classifyFallback(preflight)                   |
      |                                        |
      | WorkdirProbe(selected_folder)          |
      |   empty  -> long_task_new              |
      |   proj   -> long_task_existing         |
      |                                        |
      | ProjectRegistry.lookup(transcript)     |
      |   score >= 0.75 -> long_task_existing  |
      |                                        |
      | else -> {kind: "chat"} (no-op)         |
      v                                        v
     kind=="chat"? -----yes-> return           |
      |                                        |
      v                                        |
 RouteDispatcher.dispatch <----------------- (same path)
      |
      | chat / ambiguous -> return
      | short_task / long_task_* -> spawnCodex
      v
CompanionManager.dispatchRoutedAgentTask
  -> startVoiceAgentTaskPlan (workdir override)
  -> startVoiceAgentTask
  -> createAndSelectNewCodexAgentSession
  -> session.workingDirectoryPath = override (if valid)
  -> submitAgentPrompt
```

## Fallback classifier signals (no keyword tables)

Fallback consults only preflight context signals — never the utterance
verbs / imperative words. Precedence:

1. `preflight.selectedFolder` non-nil:
   - `WorkdirProbe.probe(url).exists && isDirectory && isEmpty` -> `long_task_new`, confidence 0.6, slug from transcript head.
   - `probe.exists && isDirectory && detectedProjectType != .unknown` -> `long_task_existing`, confidence 0.65, slug = folder lastPathComponent.
2. `ProjectRegistry.shared.lookup(userTranscript, limit: 1)` then, if empty, `lookup(windowTitle)`. Score >= 0.75 -> `long_task_existing`, confidence = `min(score, 0.7)`.
3. Nothing matched -> `{kind: "chat", confidence: 0.5}` (no-op — safe default).

## Build result

`bash scripts/sign-and-install.sh 2>&1 | tail -12`:

```
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=686  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Warnings unchanged from baseline (existing `HeyClickyAccountResetManager` / `HeyClickyChromeBridgeServer` Sendable warnings). No new errors.

## Manual test recipe

1. Launch OpenClicky (already reinstalled by sign-and-install).
2. In Finder, open an empty directory (e.g. create `~/Desktop/dispatch-empty-test/`) and select it.
3. Press the voice hotkey, say something intentionally under-specified so Fable's `[ROUTE]` might land as `long_task_new` (e.g. "start a small project here"). Watch logs for:
   - `openclicky.preflight_context` (with `has_folder=true`)
   - `openclicky.route_parsed` OR `openclicky.route_missing` -> `openclicky.route_fallback` (with `kind=long_task_new` if fallback triggered on the empty folder).
   - `openclicky.route_dispatch`, then `openclicky.route_spawn_codex` and `openclicky.route_workdir_applied`.
4. Verify a new codex dock item appeared. Open the HUD; confirm the running session's `workingDirectoryPath` matches the selected folder (visible in HUD title or the `cwd` field of `codex.request` log entries).
5. Repeat with an existing project folder (e.g. select `/Users/wowdd1/Dev/openclicky` in Finder, say "let's add a small feature"). Expect fallback to route `long_task_existing` with the same workdir.
6. Pure chat turn: no Finder selection, ask "what time is it?". Fable should emit `[ROUTE] {"kind":"chat"...}`; no codex spawn should occur (`openclicky.route_dispatch` logged with kind=chat, no `route_spawn_codex`).

Log tail command:
```
log stream --style compact --predicate 'subsystem == "com.jkneen.openclicky" AND (composedMessage CONTAINS "openclicky.route_" OR composedMessage CONTAINS "openclicky.preflight_context")'
```

## Known limitations

- Fallback confidence for the WorkdirProbe/registry paths is capped at 0.7 by design; downstream heuristics that gate on `>= 0.9` will not fire on fallback-only turns. Acceptable — model-driven high-confidence routes should always be preferred.
- Ephemeral task dir (when neither `route.workdir` nor `preflight.selectedFolder` is present) is `~/Library/Application Support/OpenClicky/EphemeralTasks/<slug>`. Best-effort mkdir; failure falls through to whatever `CodexAgentSession.workingDirectoryPath` defaults to.
- `composeAgentPrompt` does not include `RecentSessionsCapture.recent(...)` — the codex agent reads that itself via MCP sensor tools once running. Keeps the initial prompt token-cheap.
- Kind `short_task` currently routes through the same spawn path as `long_task_*`. If the taxonomy later grows a distinct short-task executor, wire it here.
- No unit tests. The dispatcher is thin glue and its behaviour is asserted by the manual recipe above. Adding SPM-side tests would require lifting `RouteParseResult` / `FablePreflightContext` out of `HeyClickyChatToolCallClient` — declined for zero-drift.

## Alignment audit

- Dispatch semantics: `chat` / `ambiguous` no-op; `short_task` / `long_task_new` / `long_task_existing` -> spawn. Any other kind logs `openclicky.route_unknown_kind` and is dropped. Verified in `dispatch(_:userTranscript:preflight:)` switch.
- Fallback: only reads `preflight.selectedFolder`, `preflight.windowTitle`, and the transcript slug function. No verb / keyword tables. Verified by reading `classifyFallback` end-to-end.
- Preflight reuse: `preflightSnapshot` is captured once inside the context-awareness block and reused by both the success and miss branches; no second Layer-0 roundtrip. Verified by the `preflightSnapshot` binding hoisted above the `contextEnabled` block.
- Constraints observed: no changes to `Packages/OpenClickyContextService/`, `OpenClickyExternalControlBridge.swift`, `ClickyCodexConfigTemplate.swift`. No new deps.
