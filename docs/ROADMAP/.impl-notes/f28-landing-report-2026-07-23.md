# F28 landing report — progress-driven auto-continue observer

Date: 2026-07-23
Pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809` (informational; Everywhere does not run Codex, no byte parity applies — openclicky-native feature).
Feature status prior to this landing: NOT IMPLEMENTED (review verdict at `.review-notes/F28-auto-continue-2026-07-23.md:261`).
Substrate: Task #204 (F26 fix) already landed `progressDriven` / `completionMarker` / `routeProjectRef` / `routeSlug` fields on `CodexAgentSession`, extended `RouteParseResult` with JSON snake_case keys, and propagated through `OpenClickyRouteDispatcher` and `startVoiceAgentTaskPlan`. This landing consumes that substrate.

## Files modified

### New: `cursor-buddy/OpenClickyProgressMarkerCheck.swift` (72 lines)
Line-anchored, case-sensitive marker reader with a single public function `isDone(path:marker:) -> Bool`. Header comment cites `AppResources/OpenClicky/AGENTS-longrun-template.md:52,107,112` for the agent-side contract. Semantics:
- Missing file -> `false` (fire continue).
- Unreadable file -> `false` + `HeyClickyLog` warning event `openclicky.f28.progress_read_failed`.
- Regex compile failure -> `false` (defensive; treats as not done).
- Match rule: `^\s*<escaped marker>\s*$` with `.anchorsMatchLines` — whole-line match tolerating leading/trailing whitespace, no substring false-positive (F28 Issue #5).

### `cursor-buddy/CodexAgentSession.swift`
Added inside `case "turn/completed":` handler at approximately `:1995-2038` (previously `:1951-1969` in the review; F26 substrate widened the switch since). After lease release and follow-up queue drain, before the completion chime comment, the handler now:
- Bails if `!progressDriven`, workdir empty, or model is not `heyclicky-free-*` (lane gate matches `CompanionManager+HeyClicky.swift:405`).
- Computes marker (uses `completionMarker` if set, else `"LAST_COMPLETED: DONE"`).
- Reads `<workingDirectoryPath>/PROGRESS.md` via `OpenClickyProgressMarkerCheck.isDone`.
- Logs `openclicky.f28.progress_check` with session prefix, path, marker, and result.
- Posts `.heyClickyRequestAutoContinueReplay` with `userInfo: ["session_id": ..., "source": "f28_progress_driven"]` iff marker absent. Sole trigger site for the progress-driven dispatch path (F28 Issue #4).

### `cursor-buddy/CompanionManager+HeyClicky.swift`
Three edits:

1. `hasInterruptedInFlightTurn` at approximately `:404-430`: the `.completed` branch (previously an unconditional `return false`) now performs an in-line marker re-check when `session.progressDriven && !workingDirectoryPath.isEmpty`, returning `true` iff `OpenClickyProgressMarkerCheck.isDone(...)` returns `false`. Belt-and-braces: `turn/completed` was the sole poster, but any future notifier still gets a safe verdict. Non-progress-driven sessions preserve the existing "completed means done" behaviour.
2. Observer body at approximately `:787-806`: the explicit `session.progressStage == .completed` skip that logged `codex.auto_replay_skipped_completed` now only fires when `!session.progressDriven`. Progress-driven completed sessions pass through and use the normal steer / new-turn dispatch below.
3. Prompt selection at the two dispatch sites (steer via `submitPromptFromUI` and new-turn via `submitAgentPrompt`): when `session.progressDriven == true`, use the new lightweight constant `progressDrivenAutoContinuePrompt = "Continue against PROGRESS.md — next unchecked item. Do not summarize."`. Otherwise use the existing heavier `buildContextfulResumePrompt(session)` for error recovery. Log event `codex.auto_continue_replay_dispatched` gained a `progress_driven` field.

## Marker check test results — 6 required cases + 2 extras

Test harness: `/tmp/f28_marker_test.swift` (temporary; wrote real files under `NSTemporaryDirectory()`; ran with `swift`).

| # | Case | Expected | Got | Verdict |
|---|------|----------|-----|---------|
| 1 | PROGRESS.md missing | false | false | PASS |
| 2 | `LAST_COMPLETED: DONE` on its own line | true | true | PASS |
| 3 | `NOTES: not DONE yet` (substring guard) | false | false | PASS |
| 4 | `LAST_COMPLETED: 5 | PLANNING` (numeric progress) | false | false | PASS |
| 5 | `  LAST_COMPLETED: DONE  ` (whitespace tolerated) | true | true | PASS |
| 6 | `last_completed: done` (case-sensitive reject) | false | false | PASS |
| extra | Single line, no trailing newline | true | true | PASS |
| extra | `prefix LAST_COMPLETED: DONE suffix` (mid-line rejected) | false | false | PASS |

All 8/8 pass.

## Grep sentinels

Before this landing (per review at `.review-notes/F28-auto-continue-2026-07-23.md`):
- `LAST_COMPLETED` in `cursor-buddy/*.swift` -> 0 hits (matches review's "MISSING").
- `MARKER-END` in `cursor-buddy/*.swift` -> 0 hits.

After landing:
- `LAST_COMPLETED` in `cursor-buddy/*.swift` -> 8 hits across 4 files. Reader sites at `CodexAgentSession.swift:2009` and `CompanionManager+HeyClicky.swift:447` are the new active enforcement points; helper doc at `OpenClickyProgressMarkerCheck.swift:12,42`; type doc at `CodexAgentSession.swift:336`; router doc + fallback at `HeyClickyChatToolCallClient.swift:817,872,879` (from Task #204 F26 substrate).
- `MARKER-END` in `cursor-buddy/*.swift` -> 0 hits. Design ambiguity in Issue #2 resolved in favour of `LAST_COMPLETED: DONE` per user decision.

## Non-regression audit

The F28 addition is strictly additive on the `.completed` case for progress-driven heyclicky-free sessions. All existing paths preserved:
- Error-recovery replay from 402 `agent_turn_limit_exceeded` (`CodexAgentSession.swift:1615`) still targets `.failed` sessions; the extended `.completed` clause never enters that path.
- 428 `agent_turn_lease_required` replay (`CodexAgentSession.swift:2085`) unchanged.
- Automation `/inject_fault trigger_turn_limit`, cooldown wake, zombie-completion, and creds-refresh replays in `CompanionManager.swift` untouched.
- Existing debounce (`shouldDispatchAutoReplay`, 3 s) and progress-conditioned failure budget (3 attempts / 300 s cooldown) apply unchanged — persistent read failures or a stubborn model that never writes DONE will still hit the cooldown eventually. This satisfies F28 Issue #6 (unreadable file falls through the same budget).
- Non-heyclicky-free lanes: `CodexAgentSession` gate at the `turn/completed` handler AND the observer body's existing `session.model.hasPrefix("heyclicky-free-")` check at :405 both hold, so Anthropic / OpenAI / Codex-direct sessions never fire progress-driven auto-continues (LOW Issue L1 respected).

## Parse verification

`swiftc -parse` succeeded on all touched files:
- `cursor-buddy/OpenClickyProgressMarkerCheck.swift`
- `cursor-buddy/CodexAgentSession.swift`
- `cursor-buddy/CompanionManager+HeyClicky.swift`

Per `CLAUDE.md`, no `xcodebuild` invocation from terminal; Xcode remains the build path for TCC-sensitive builds.

## Deferred / out of scope

- Issue #3 (absolute turn cap): user chose unbounded. Existing progress-conditioned budget is the only ceiling.
- Issue L2 (marker write / observer read race): not exploitable pre-landing; if it ever surfaces, the double-poll idea in the review remains available.
- AGENTS-longrun template unchanged (agent-side contract already correct).
- SPM package `Packages/OpenClickyContextService` not touched — the marker check helper lives in the main app because `HeyClickyLog` (used for the unreadable-file warning) is app-scope.

## Everywhere byte parity

N/A. F28 is openclicky-native; Everywhere does not orchestrate Codex. Pin `30e03e9dcfdd4247fd679828ed86e9042f32d809` recorded for auditability only.
