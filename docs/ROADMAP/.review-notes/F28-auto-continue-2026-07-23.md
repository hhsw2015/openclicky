# F28 — Auto-continue observer for progress-driven Codex tasks

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809` (informational only; Everywhere is capture+MCP, not agent orchestration).
Standard: only trust code, every claim `file:line`.

Scope of this review: the "keep going till PROGRESS.md says DONE" loop as described in `docs/ROADMAP/09_MIGRATION_ORDER.md:83` and `docs/ROADMAP/06_UI_INTEGRATION.md:127-145` — i.e. a Swift-side observer that, on each `turn/completed`, checks `<workdir>/PROGRESS.md` for the `LAST_COMPLETED: DONE` / `MARKER-END` marker and, if absent, fires a "continue" turn. (Note: the `11_REVIEW_CHECKLIST.md:342` block labelled F28 is a different scope — hotkey→stash→hook e2e; the task brief here targets the auto-continue loop, so this review addresses that.)

Openclicky files inspected:
- `cursor-buddy/CodexAgentSession.swift`
- `cursor-buddy/CodexProcessManager.swift`
- `cursor-buddy/CompanionManager.swift`
- `cursor-buddy/CompanionManager+HeyClicky.swift`
- `cursor-buddy/CompanionManager+AIResponsePipeline.swift`
- `cursor-buddy/OpenClickyRouteDispatcher.swift`
- `cursor-buddy/HeyClickyChatToolCallClient.swift`
- `AppResources/OpenClicky/AGENTS-longrun-template.md`
- `cursor-buddy/HeyClickyTypes.swift`

Everywhere counterpart: **none.** Everywhere does not run Codex; there is no equivalent long-run auto-continue loop to cross-check. Byte-parity not applicable.

---

## Alignment table (design vs code)

| Feature | Design (`06_UI_INTEGRATION.md`, `09_MIGRATION_ORDER.md`, `AGENTS-longrun-template.md`) | Openclicky (file:line) | Status |
|---|---|---|---|
| `CodexAgentSession.progressDriven: Bool` field | `06_UI_INTEGRATION.md:120` | not present. `grep -rn "progressDriven" cursor-buddy/*.swift` → **0 matches** | **MISSING** |
| `CodexAgentSession.completionMarker: String?` field | `06_UI_INTEGRATION.md:121` | not present. `grep -rn "completionMarker" cursor-buddy/*.swift` → **0 matches** | **MISSING** |
| `CodexAgentSession.watchdogNudgeEnabled: Bool` field | `06_UI_INTEGRATION.md:122` | not present. `grep -rn "watchdogNudge" cursor-buddy/*.swift` → **0 matches** | **MISSING** |
| `startVoiceAgentTaskPlan` gains `progressDriven` / `completionMarker` params | `06_UI_INTEGRATION.md:98-110` | actual signature at `CompanionManager.swift:14396-14403` has only `workingDirectoryOverride`. See F26 review Issue 1 | **MISSING** |
| Observer subscribes to Codex `turn/completed` and checks PROGRESS.md | `06_UI_INTEGRATION.md:127-144`, `09_MIGRATION_ORDER.md:83` | `CodexAgentSession.swift:1951-1969` handles `turn/completed` only for lease-release / queued-follow-up / persistCompletedTurnMemoryIfNeeded — **no PROGRESS.md read, no marker check** | **MISSING** |
| PROGRESS.md marker `LAST_COMPLETED: DONE` / `MARKER-END` recognised by observer | `AGENTS-longrun-template.md:52, 92-94, 107, 112` | agent-side contract only. No Swift call site reads or parses `LAST_COMPLETED` — `grep "LAST_COMPLETED" cursor-buddy/*.swift` → **0 matches**. `grep "MARKER-END" cursor-buddy/*.swift` → **0 matches** | **MISSING** |
| Fires next turn when marker absent | `06_UI_INTEGRATION.md:144` | not present | **MISSING** |
| Marker written by agent via file tool (not observer) | `AGENTS-longrun-template.md:81-94` | agent-side, correct — this half is honoured by the template. Observer half absent, so nothing consumes it | Partial (template only) |
| Existing `.heyClickyRequestAutoContinueReplay` observer | `HeyClickyTypes.swift:37` (Notification.Name) | wired at `CompanionManager+HeyClicky.swift:753-847` | Present, but purpose is **error recovery** (turn-limit / 428 / codex-exit / creds-refresh / zombie-completion), not progress-driven autonomy |
| Auto-replay gate: only fire when session was INTERRUPTED | `06_UI_INTEGRATION.md:132-142` | `CompanionManager+HeyClicky.swift:404-430` `hasInterruptedInFlightTurn` explicitly returns `false` for `progressStage == .completed` | **Inverse of what F28 requires**: F28 wants firing precisely when task cleanly completed but PROGRESS.md is not DONE; existing code refuses to fire in that case |
| Debounce / breaker for auto-replay | `06_UI_INTEGRATION.md` (implicit — safety net) | `CompanionManager+HeyClicky.swift:269-279` (3s debounce) and `:288-321` (3-attempt no-progress budget + 300s cooldown) and `:140-144` (circuit-breaker via `isCircuitOpen`) | Present for existing error-recovery path only |
| Max-turns cap / hard turn ceiling | not specified in design | not present. There is a per-session **failure budget** of 3 consecutive no-progress replays before 300s cooldown (`CompanionManager+HeyClicky.swift:288-321`), but no absolute turn cap | **MISSING** — see Issue 3 |
| Manual abort cancels observer | `06_UI_INTEGRATION.md` (implicit) | `CompanionManager+HeyClicky.swift:441-456` (`isUserInitiatedStop`) → `:407` early return in `hasInterruptedInFlightTurn` | Present for existing path; would carry over cleanly to a new progress-driven path if wired the same way |
| Watchdog nudge via 0-quota `turn/steer` when idle | `AGENTS-longrun-template.md:98`, `06_UI_INTEGRATION.md:122` implies via `watchdogNudgeEnabled` | `CodexAgentSession.swift:790-804` `nudgeActiveTurn(reason:)` sends "[runtime nudge — …] Read PROGRESS.md and continue…" via `turn/steer`; invoked by watchdog ticker at `CompanionManager+HeyClicky.swift:1022-1028` after `recordProgressAndCheckTimeout` fires | Present, but triggered by **idle-time watchdog** (15 min no assistant advance, `:197-217`), **not** by a PROGRESS.md marker check on `turn/completed` |
| Turn firing on new prompt: 0-quota steer if turn active, otherwise new turn | Everywhere design (money rule) | `CodexAgentSession.swift:665-687` (`submitPromptFromUI` routes to `steerActiveTurn` when `activeTurnID` set, else `startPromptTurn`) | OK — the primitives F28 would need are already in place |
| PROGRESS.md path derived from `workingDirectoryPath` | design implies `<workdir>/PROGRESS.md` | `session.workingDirectoryPath` exists (`CodexAgentSession.swift:324`) and can be overridden by `dispatchRoutedAgentTask` → `startVoiceAgentTaskPlan` → `startVoiceAgentTask` at `CompanionManager.swift:14612-14628`. No PROGRESS.md reader wired against it | **MISSING** — path is available, reader is not |
| App restart mid-task — session persisted? | design silent | `CodexAgentSession.swift:585-594` explicitly **nulls** `activeTurnID` on restore, `:255-269` persists `activeLeaseID` + `leaseExpiresAt`, `CompanionManager.swift:4694-…` `resumeRestoredAgentTasksIfNeeded` re-fires resume prompts | Existing resume path works for error-recovery; would apply to a progress-driven path unchanged |
| Codex crash → auto-restart | `CompanionManager+HeyClicky.swift:712-748` (`.heyClickyCodexProcessExited` observer + `clearActiveThreadForRelaunch` + `submitAgentPrompt(buildContextfulResumePrompt(...))`) | Present for error-recovery path | OK |
| `[ROUTE]` `progressDriven=true` → observer wire | `docs/ROADMAP/02_LAYER_1_INTENT_ROUTER.md:301-310` | `RouteParseResult` at `HeyClickyChatToolCallClient.swift:813-827` has **no `progressDriven` / `completionMarker` fields** — schema only carries `kind / projectRef / slug / workdir / confidence`. Dispatcher (`OpenClickyRouteDispatcher.swift:143-192`) never sets any progress-driven flag on `CodexAgentSession` | **MISSING** (integration surface absent) |
| Default `completionMarker="DONE"` overridable | design shows `"MARKER-END"` default | not present | **MISSING** |
| No `[ROUTE]` → chat mode, observer never activates | `docs/ROADMAP/06_UI_INTEGRATION.md:127-144` | Trivially true because the observer does not exist. `RouteDispatcher.dispatch` `OpenClickyRouteDispatcher.swift:55-58` returns early for `kind == chat/ambiguous`, so no session is created at all — the "observer never activates" clause is vacuously satisfied | OK (vacuous) |

---

## Detailed findings

### The Swift-side progress-driven auto-continue observer does not exist

Grepped `progressDriven`, `completionMarker`, `LAST_COMPLETED`, `MARKER-END` across `cursor-buddy/*.swift` — **zero matches** in production code:

- `progressDriven` — 0 matches in `.swift` files. Present only in `docs/ROADMAP/*.md`.
- `completionMarker` — 0 matches in `.swift` files. Present only in `docs/ROADMAP/*.md`.
- `LAST_COMPLETED` — 0 matches in `.swift` files. Present only in `AppResources/OpenClicky/AGENTS-longrun-template.md:52,78,93,102-104,107,112`, and `docs/E2E_LONGRUN_VERIFICATION.md:41,110`.
- `MARKER-END` — 0 matches in `.swift` files. Present only in `AGENTS-longrun-template.md:92,121,151`, `docs/E2E_LONGRUN_VERIFICATION.md:54,110`, and the design docs.

The only Swift references to `PROGRESS.md` are prose reminders in prompts, not readers:
- `CodexAgentSession.swift:795` — nudge string tells the agent "Read PROGRESS.md and continue the next unchecked item." Sent via `turn/steer` (0-quota).
- `CompanionManager+HeyClicky.swift:363-365` — Chinese hint appended to the resume prompt: "工作目录里有 PROGRESS.md 记录了断点。只读 PROGRESS.md 确认进度…".
- `CompanionManager.swift:4558` — comment only.
- `OpenClickyExternalControlBridge.swift:1185` — tool-description text.

Consequence: the "check `<workdir>/PROGRESS.md` for `LAST_COMPLETED: DONE` on every `turn/completed`, fire a continuation if absent" loop is **not implemented in Swift**. The DONE contract is enforced entirely by the AGENTS-longrun template steering the agent to *voluntarily* keep going and only stop when it has written DONE itself. There is no runtime supervisor.

This matches what the F26 review (`docs/ROADMAP/.review-notes/F26-route-parse-2026-07-23.md:69`) already flagged as HIGH Issue 1.

### The `heyClickyRequestAutoContinueReplay` observer is an error-recovery loop, not a progress-driven loop

Site of the existing observer: `CompanionManager+HeyClicky.swift:753-847`. Triggering call sites:
- `CodexAgentSession.swift:1597-1601` — 402 `agent_turn_limit_exceeded` teardown (`handle402MidChat`).
- `CodexAgentSession.swift:2067-2071` — 428 `agent_turn_lease_required` teardown.
- `CompanionManager.swift:3234-3238` — automation `/inject_fault trigger_turn_limit` (test hook).
- `CompanionManager.swift:4515-4519` — cooldown wake replay.
- `CompanionManager.swift:4525-4529` — status `.failed` direct replay for heyclicky-free.
- `CompanionManager.swift:4628-4632` — zombie-completion replay (assistant produced no output).

Gate at `:787` requires `hasInterruptedInFlightTurn(session) == true` before firing (`CompanionManager+HeyClicky.swift:404-430`). Inside that helper:
- `:405` — restricts to `heyclicky-free-*` model prefix only.
- `:427-428` — **explicitly returns `false` for `progressStage == .completed`**.
- `:796-800` — same rule at the observer body: "on `.completed`, log `codex.auto_replay_skipped_completed` and return."

That is the **opposite** of the F28 semantic: F28 needs to fire *precisely* when the turn cleanly completed but PROGRESS.md is not DONE. The current observer refuses to fire in that state and logs `auto_replay_skipped_completed`. Repurposing this observer for F28 would require inverting that gate for progress-driven sessions.

### The watchdog "nudge" path is close to what F28 needs, but keyed off idle time, not PROGRESS.md

The ticker at `CompanionManager+HeyClicky.swift:994-1043` runs every 60 s, calls `recordProgressAndCheckTimeout` (`:197-217`, 15 min timeout on assistant-entry advance for any active-stage session), and on timeout tries `session.nudgeActiveTurn(reason:)` (`CodexAgentSession.swift:790-804`). That nudge sends a `turn/steer` (0-quota) with the exact "Read PROGRESS.md and continue the next unchecked item" text. Fallback if no `activeTurnID` is `session.stop(reason: "turn_watchdog_timeout")` + post `heyClickyCodexProcessExited` (`:1029-1039`).

So the *nudge machinery* exists and even mentions PROGRESS.md — but:
- Trigger is **elapsed idle time**, not a PROGRESS.md marker check on `turn/completed`.
- Nudge only fires on an **active** turn (`stage.starting/planning/executing/composing`, `:1000-1006`) — after `turn/completed` the session moves to `.completed`, `isActive == false`, ticker skips it, no nudge fires.
- The nudge does not read PROGRESS.md; it merely tells the model to read it.

### `turn/completed` handler at `CodexAgentSession.swift:1951-1969`

The relevant code:
```
case "turn/completed":
    flushPendingAssistantDeltas()
    currentAssistantEntryID = nil
    status = .ready
    progressStage = .completed
    persistCompletedTurnMemoryIfNeeded()
    logLifecycle(...)
    activeTurnID = nil
    Task { await OpenClickyAgentFileLeaseCoordinator.shared.releaseLeases(for: id) }
    currentLeasePaths = []
    if !queuedFollowUpPrompts.isEmpty {
        let nextPrompt = queuedFollowUpPrompts.removeFirst()
        startPromptTurn(nextPrompt, ...)
    }
```

No PROGRESS.md read, no marker check, no auto-continue post. `queuedFollowUpPrompts` is a caller-populated FIFO used for user-typed follow-ups sent while a turn was mid-flight — it is not fed by a progress-driven supervisor.

### `RouteParseResult` has no fields for progressDriven / completionMarker

`HeyClickyChatToolCallClient.swift:813-827`:
```
struct RouteParseResult: Codable, Sendable {
    let kind: String
    let projectRef: String?
    let slug: String?
    let workdir: String?
    let confidence: Double
    ...
}
```

The directive block at `:861-879` teaches Fable only these five keys. There is no `progressDriven` bit on the wire and no defaulting of `progressDriven=true` for `kind == long_task_new/long_task_existing`. The dispatcher at `OpenClickyRouteDispatcher.swift:143-192` never sets any progress-driven state on `CodexAgentSession`.

---

## Issues

### CRITICAL

#### Issue 1 — F28's core feature (progress-driven auto-continue observer) is not implemented

Design (`06_UI_INTEGRATION.md:127-144`) specifies: on `turn/completed`, if `session.progressDriven`, read `<workdir>/PROGRESS.md`; if `LAST_COMPLETED: DONE` (or the configured `completionMarker`) is absent, fire a continuation. **None of that Swift code exists.** No fields, no reader, no fire path, no `[ROUTE]` schema plumbing. The DONE contract is currently enforced only by the agent following the AGENTS-longrun template (`AppResources/OpenClicky/AGENTS-longrun-template.md:107` "DO NOT STOP UNTIL PROGRESS.md SAYS `LAST_COMPLETED: DONE`"), i.e. the model polices itself.

Impact: if the model voluntarily ends a turn *without* setting DONE (e.g. drift, quota-mid-work, or the run just being too big for one turn) there is no runtime guard that forces another turn. The observed successful run in `docs/E2E_LONGRUN_VERIFICATION.md` (a 12-item checklist finished in one lease) worked because the model stayed on-task inside one turn — not because a Swift supervisor forced it to.

**Fix**: land the three fields (`progressDriven`, `completionMarker`, `watchdogNudgeEnabled`) on `CodexAgentSession`, plumb them through `RouteParseResult` (default `progressDriven=true` when `kind ∈ {long_task_new, long_task_existing}`), and add a `turn/completed`-time reader in the RPC dispatch (`CodexAgentSession.swift:1951-1969`) that:
1. Bails immediately if `!progressDriven` (existing behaviour).
2. Reads `<workingDirectoryPath>/PROGRESS.md`.
3. Checks for the configured marker (default `"LAST_COMPLETED: DONE"` per template; the design proposes the raw `"MARKER-END"` string — see Issue 2).
4. If absent, posts `.heyClickyRequestAutoContinueReplay` with the session id.
5. Extends `hasInterruptedInFlightTurn` (`CompanionManager+HeyClicky.swift:404-430`) so `.completed` returns `true` when `session.progressDriven && marker not found` — inverts the current guard for this specific mode.

### HIGH

#### Issue 2 — Design ambiguity: `MARKER-END` vs `LAST_COMPLETED: DONE` — no single source of truth

`06_UI_INTEGRATION.md:108, 116, 175, 187` and `02_LAYER_1_INTENT_ROUTER.md:302, 309` show `completionMarker: "MARKER-END"`. `AGENTS-longrun-template.md:92, 107, 112, 121, 151` says the agent appends `MARKER-END` to `OUTPUT.md` **and** sets `LAST_COMPLETED: DONE` in `PROGRESS.md`. Two different markers in two different files. The design doc says "PROGRESS.md"; the marker in the doc is "MARKER-END" (which the template writes to OUTPUT.md, not PROGRESS.md).

Without disambiguation there is a real risk of the future implementation checking the wrong file. Concrete recommendation: use `LAST_COMPLETED: DONE` in `PROGRESS.md` as the authoritative marker (this is the checklist state field the agent already maintains, `AGENTS-longrun-template.md:52`) and treat `MARKER-END` in `OUTPUT.md` as a secondary artifact-side signal (nice-to-have). Make the observer's default `completionMarker = "LAST_COMPLETED: DONE"`.

#### Issue 3 — No absolute turn cap in the auto-continue loop

Existing `HeyClickyObserverStore.shouldAttemptRecovery` (`CompanionManager+HeyClicky.swift:288-321`) has a 3-attempt-without-progress budget then a 300 s cooldown. That is a **progress-conditioned** budget — as long as the session keeps producing new entries, the counter resets (`:307-309`) and it will keep re-firing indefinitely.

For a legitimately long task (say 50-item checklist) that is arguably correct. For a runaway loop (marker never gets written but new entries keep flowing) it is unbounded. Design (`06_UI_INTEGRATION.md`) does not specify a hard ceiling. Task brief asks: "Max turns cap (safety net — e.g., 20 turns hard limit)?".

**Fix**: add a per-session `autoContinueTurnCount: Int` counter, initialised to 0 on task start, incremented on each progress-driven fire, and hard-capped (design does not specify — 20 or a settings-configurable value both defensible). At the cap, force `.stopped` and surface a user-visible notice.

#### Issue 4 — Off-by-one / firing ordering not specified

Design (`06_UI_INTEGRATION.md:144`): "在 `turn/completed` 事件里, 若 `progressDriven` 且 progress.md 未 DONE, 主动 fire." That is the correct order — check *after* turn ends. But `06_UI_INTEGRATION.md:136-141` shows a gate inside the existing interrupted-turn observer, i.e. checked *before* firing. Both are potentially firing sites and could double-fire on the same turn if not de-duplicated.

Current de-dup: `shouldDispatchAutoReplay(owner:)` (`CompanionManager+HeyClicky.swift:269-279`) is a 3 s per-owner debounce; that would prevent double-fire on the same `turn/completed`, but 3 s is coarse — a genuinely fast next-turn latency could be trimmed. This is a design-time decision, not a bug yet.

**Fix**: put the sole trigger at `CodexAgentSession.swift:1951-1969` inside the `turn/completed` handler; keep the existing interrupted-turn observer strictly for error paths. Do not add a second progress-driven fire from `progressStage.sink` — that duplicates.

### MEDIUM

#### Issue 5 — Marker match strategy underspecified: substring vs whole-line

Task brief bug-hunt asks: "Marker 'DONE' false-positive in log content (e.g., 'task is not DONE') — verify substring vs whole-line". Design does not specify. `AGENTS-longrun-template.md:52` shows the line format `LAST_COMPLETED: <last done step number> | DONE | PLANNING`, and `:112` proposes `cat PROGRESS.md | grep '^LAST_COMPLETED:'` — i.e. anchor to start-of-line.

If the future implementation uses a naive `contains("DONE")` it will match e.g. `NOTES: not DONE yet, working on step 4` or `[x] step 7 (done — but DONE marker to be set)`.

**Fix**: implement as a line-oriented scan matching the regex `^LAST_COMPLETED:\s*DONE\s*$` (case-sensitive). Reject substring matching.

#### Issue 6 — File-missing / file-unreadable semantics not specified

Task brief bug-hunt asks: "File missing → assume incomplete, fire continue" vs "File unreadable → error state?".

Missing → incomplete → fire continue is the safe default (matches the template's "if PROGRESS.md is missing … turn 1 planning phase" at `AGENTS-longrun-template.md:143-145`).

Unreadable (permissions, disk error) is ambiguous — either fire (risk infinite loop if the failure is persistent) or abort (risk user-visible failure on a transient FS blip). Design silent.

**Fix (recommended when the feature is implemented)**: missing → fire. Unreadable → count as a `noteReplayProgress` failure in the existing 3-attempt budget (`CompanionManager+HeyClicky.swift:311-320`) so a persistent read failure eventually trips the cooldown rather than looping.

#### Issue 7 — Prompt text for the auto-fire is not specified

Task brief asks: "What text does the observer inject as user turn? 'continue'? Empty? Fixed prompt template?"

The existing error-recovery path uses `buildContextfulResumePrompt(_:)` (`CompanionManager+HeyClicky.swift:359-397`) which bundles title + last user prompt + last assistant excerpt + a Chinese "请继续之前的任务" line. That is reasonable for error recovery but heavy for a progress-driven fire where the model just needs "keep going against PROGRESS.md".

Design silent. `CodexAgentSession.swift:795` nudge uses a lighter prompt: `"[runtime nudge — <reason>] You appear to be idle. Read PROGRESS.md and continue the next unchecked item. Chain tool calls. Do NOT summarize; do NOT ask questions; do NOT stop."` — that reads more appropriate for the progress-driven case.

**Fix**: use `nudgeActiveTurn(reason: "progress_not_done")` first if `activeTurnID` is set (0-quota `turn/steer`); if the turn already ended (which is the case at `turn/completed`), start a fresh turn with a short prompt like `"Continue against PROGRESS.md — next unchecked item. Do not summarize."` (English, single line). Avoid duplicating the heavier resume prompt.

### LOW

#### Issue L1 — Model-lane gate: existing observer is heyclicky-free-only

`CompanionManager+HeyClicky.swift:405` restricts `hasInterruptedInFlightTurn` to `session.model.hasPrefix("heyclicky-free-")`. A progress-driven fire on a session running under Anthropic / OpenAI / Codex-direct would need to bypass that gate or the feature will silently no-op for non-Fable providers. Design silent on lane restriction.

#### Issue L2 — Race between marker write and observer read

Once the observer is implemented, ordering is: agent finishes work → writes `LAST_COMPLETED: DONE` to PROGRESS.md → assistant text stream flushes → daemon emits `turn/completed`. If the daemon buffers the notification and delivers it before the FS write is durable, the observer would miss the marker and fire an extra turn. Not currently exploitable (feature absent), but the fix is to double-check on the *next* `turn/completed` after any progress-driven fire — if two consecutive polls both show non-DONE, take that as the truth. Cheap belt-and-braces.

#### Issue L3 — Cancel signal path

Task brief bug-hunt: "SIGINT → codex → observer stops? Or observer keeps firing?"

Existing `isUserInitiatedStop` (`CompanionManager+HeyClicky.swift:441-456`) recognises: `agent_panel_stop`, `agent.stop_button`, `agent.stop_button_pressed`, `agent_dock_stop`, `agent_hud_stop`, `agent_task_cancelled`, `user_stop`, `user_cancel`, `session_stopped`, `chat_workspace_archived`, `manual_stop`. Terminal user gestures set one of these on `session.stopReason` and `hasInterruptedInFlightTurn` returns `false`. Any new progress-driven fire path must consult the same list (or equivalent), otherwise the Stop button stops meaning "stop".

---

## Bug-hunt checklist against the task brief

Since the feature is absent, most bug-hunt items are N/A. Verdicts against each:

- **Observer wiring / subscribes to `turn/completed`** — No. `CodexAgentSession.swift:1951-1969` handles `turn/completed` but does not check PROGRESS.md.
- **Reads target file after each turn** — No. No PROGRESS.md reader in Swift.
- **Marker match case-sensitive / trim + lowercase** — N/A (no reader).
- **Fires next turn if marker absent** — No.
- **Stops on marker match** — Trivially: no fire happens either way.
- **File path derived from `workingDirectoryHint` + slug** — `session.workingDirectoryPath` is set (`CodexAgentSession.swift:324, 349`, overridden by `CompanionManager.swift:14617`); slug is not appended (design implies `<workdir>/PROGRESS.md` directly, no slug segment).
- **Full file scan vs last-N-lines** — N/A. Recommended when implemented: line-oriented scan (see Issue 5).
- **File missing → fire continue** — N/A (Issue 6).
- **What text does the observer inject** — N/A (Issue 7). Existing `buildContextfulResumePrompt` is available but heavy.
- **Marker match → stop** — Trivial.
- **Max turns cap** — Missing (Issue 3).
- **Manual abort cancels observer** — Would work via `isUserInitiatedStop` if wired correctly (Issue L3).
- **Timeout between turns** — Debounce exists (3 s, `CompanionManager+HeyClicky.swift:269-279`) but is per-owner not per-session.
- **Session state machine** — `CodexAgentProgressStage` at `CodexAgentSession.swift:210-217` covers `idle/starting/planning/executing/composing/completed/failed`. `CodexAgentSessionStatus` at earlier lines covers `stopped/starting/ready/running/failed`.
- **Race: observer fires next turn while previous still processing → guard** — In the existing error-recovery path, `submitPromptFromUI` at `CodexAgentSession.swift:665-687` steers instead of firing new when `activeTurnID` is set. For F28 the observer would trigger at `turn/completed`, at which point `activeTurnID = nil` (`:1967`), so the race is naturally sidestepped — but the debounce (`shouldDispatchAutoReplay`) is still needed for the multi-observer fan-out.
- **Observer lives on main actor / async task cancellation** — `CompanionManager` observers run `queue: .main`; the observer itself is `@MainActor`. Would carry over cleanly.
- **App restart mid-task — session persisted** — Yes, `CodexAgentSession.swift:583-624` persists thread + lease and re-fires resume prompts via `CompanionManager.resumeRestoredAgentTasksIfNeeded`. `activeTurnID` is intentionally nulled on restore (`:585-594`) so no stale steer is attempted.
- **Codex crash → auto-restart** — `CompanionManager+HeyClicky.swift:712-748` handles `.heyClickyCodexProcessExited` and re-fires resume prompt.
- **Off-by-one: fire before / after check** — N/A; when implemented, fire *after* `turn/completed` (Issue 4).
- **Race: file written between check and next-turn dispatch** — Issue L2.
- **Marker false-positive in log content** — Issue 5.
- **Cancel signal path** — Issue L3.
- **Integration with F26 `[ROUTE]`** — Missing at every level: `RouteParseResult` (`HeyClickyChatToolCallClient.swift:813-827`) has no `progressDriven` bit, dispatcher (`OpenClickyRouteDispatcher.swift`) never sets one, `startVoiceAgentTaskPlan` never accepts one, `CodexAgentSession` never stores one. `progressDriven=true` from `[ROUTE]` triggers nothing today.
- **`completionMarker` default / overridable** — Neither. Feature absent.
- **No `[ROUTE]` → chat mode, observer never activates** — Vacuously true (observer does not exist).

---

## Verdict

**NOT IMPLEMENTED.**

F28's progress-driven auto-continue observer, as specified in `06_UI_INTEGRATION.md:127-144` and `09_MIGRATION_ORDER.md:83`, exists only in prose. No Swift field, no reader, no fire path, no schema plumbing to `[ROUTE]`. The DONE contract is enforced entirely by the AGENTS-longrun template steering the agent to voluntarily keep going — self-policing, no runtime supervisor.

Adjacent pieces that would form the substrate for a future implementation:
- `session.workingDirectoryPath` reachable and overridable (`CodexAgentSession.swift:324, 349`, `CompanionManager.swift:14612-14628`).
- `turn/completed` handler exists at `CodexAgentSession.swift:1951-1969` — one hook point.
- 0-quota steer available via `nudgeActiveTurn(reason:)` (`CodexAgentSession.swift:790-804`) and `steerActiveTurn(with:...)` (`:806-852`) — the money-rule-preserving primitives.
- `.heyClickyRequestAutoContinueReplay` (`HeyClickyTypes.swift:37`) + observer body at `CompanionManager+HeyClicky.swift:753-847` — reusable notification bus, but the gate at `hasInterruptedInFlightTurn` (`:404-430`) refuses to fire on `.completed` and would need inversion for progress-driven mode.
- Debounce (`shouldDispatchAutoReplay`, 3 s) and progress-conditioned failure budget (3 attempts / 300 s cooldown) already implemented (`:269-321`) — reusable but no absolute turn cap (Issue 3).
- `isUserInitiatedStop` guard (`:441-456`) — reusable for the manual-abort clause.

Recommended landing order (smallest-change-first):
1. Add fields to `CodexAgentSession` (`progressDriven`, `completionMarker`, `watchdogNudgeEnabled`, defaults false / nil / true).
2. Add fields to `RouteParseResult` and default `progressDriven=true` on `long_task_new / long_task_existing`; propagate through `RouteDispatcher.spawnCodex` and `dispatchRoutedAgentTask` into the created session.
3. Extend `startVoiceAgentTaskPlan` with `progressDriven` / `completionMarker` args (deprecate the design's proposed `workingDirectoryHint` in favour of the existing `workingDirectoryOverride`, or rename — pick one).
4. In `CodexAgentSession.swift:1951-1969` `turn/completed` handler, add: if `progressDriven`, read `<workingDirectoryPath>/PROGRESS.md`, line-scan for `^LAST_COMPLETED:\s*DONE\s*$`, if absent post `.heyClickyRequestAutoContinueReplay`.
5. In `CompanionManager+HeyClicky.swift:404-430`, extend `hasInterruptedInFlightTurn` so `progressStage == .completed && session.progressDriven && !markerFound` returns `true`.
6. Add an absolute turn cap counter and Issue 5 line-oriented scan defensively at the same time. Reuse the existing debounce and failure-budget.

Once landed, the E2E in `docs/E2E_LONGRUN_VERIFICATION.md` should still pass unchanged (marker gets written → no re-fire) and additionally cover the "model stops mid-task without DONE" case which is currently unhandled.

---

## LANDED — 2026-07-23 (Task #204 follow-up)

Implementation report: `docs/ROADMAP/.impl-notes/f28-landing-report-2026-07-23.md`.

Files touched:
- `cursor-buddy/OpenClickyProgressMarkerCheck.swift` (new) — line-anchored marker check helper.
- `cursor-buddy/CodexAgentSession.swift` — `turn/completed` handler posts `.heyClickyRequestAutoContinueReplay` when `progressDriven && !markerFound && model.hasPrefix("heyclicky-free-")`. Sole trigger site for the F28 dispatch path.
- `cursor-buddy/CompanionManager+HeyClicky.swift` — `hasInterruptedInFlightTurn` returns `true` for `.completed` iff progress-driven and marker absent; observer body relaxes the `.completed` skip for progress-driven sessions; new lightweight prompt used on both steer and new-turn paths.

User decisions honoured (no absolute turn cap; heyclicky-free lane only; missing PROGRESS.md fires continue; unreadable file falls through the existing 3-attempt / 300s cooldown budget via `noteReplayProgress` on subsequent misses). Issues 5, 6, 7, 4, L1 addressed. Issues 3 (no cap) and L2 (marker/read race) deliberately deferred per user decision.
