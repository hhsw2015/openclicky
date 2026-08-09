# Task Planning Pipeline — review notes (2026-07-23)

Scope: 2026-07-23 landing of `OpenClickyTaskDirectoryResolver`,
`OpenClickyPlanningLoop`, `RouteDispatcher` unification, session/process
env threading, `AGENTS-longrun-template.md` update, `OPENCLICKY_TASK_SPEC.md`
rewrite. Openclicky-native; no Everywhere counterpart.

Standard: every claim carries a `file:line`. Only what the code shows.

## Alignment Table

| Feature | Design (spec doc) | Code (file:line) | Verdict |
|---|---|---|---|
| Variant A path `<workdir>/.openclicky/task/` | `docs/OPENCLICKY_TASK_SPEC.md:11` | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:37-47` | MATCH |
| Variant B path `~/OpenClicky/<slug>/` (uses `homeDirectoryForCurrentUser`, no hard-coded `/Users`) | `docs/OPENCLICKY_TASK_SPEC.md:19` | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:53-56` | MATCH |
| Slug sanitizer: lowercase, `[a-z0-9-]`, collapse runs, trim, cap 64 | spec:21-22 | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:82-105` | MATCH |
| Fallback slug `yyyy-MM-dd-HHmm-<random6>` | spec:22 | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:69-78` | MATCH |
| Directory `mkdir -p` w/ intermediates, error swallowed intentionally | resolver header:107-114 | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:109-114` | MATCH |
| PROGRESS.md existence probe returned as `progressExists` | spec:74-77 | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:45,61` | MATCH |
| Resolution struct: taskDir + progressPath + progressExists + anchor enum | task expectation | `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:20-26` | MATCH |
| PlanningLoop: 3 rounds, distinct prompts | impl-notes:132-144 | `cursor-buddy/OpenClickyPlanningLoop.swift:49-104` | MATCH |
| PlanningLoop returns `String`; never throws | impl-notes:38-40 | `cursor-buddy/OpenClickyPlanningLoop.swift:43,144-155,205-209` | MATCH |
| Provider preference: free planning lane only (money rule) | CLAUDE.md inference-routing rule 2 + impl-notes:146-149 | `cursor-buddy/OpenClickyPlanningLoop.swift:124-132` (uses `HeyClickyFreePlanningClient`, msgs-quota) | MATCH |
| Round-3 output validated + fallback to minimal PROGRESS.md on any error | impl-notes:143-144 | `cursor-buddy/OpenClickyPlanningLoop.swift:106-113, 191-209` | MATCH |
| Session cleanup after run (`clearSession` in `defer`) | loop file header | `cursor-buddy/OpenClickyPlanningLoop.swift:45` | MATCH |
| 60s per-round timeout | task expectation | `cursor-buddy/OpenClickyPlanningLoop.swift:128` (`timeoutSeconds: 60`) | MATCH |
| Round-2 result unused (only cached as history in `HeyClickyFreePlanningClient` internal sessions) | impl-notes:137 | `cursor-buddy/OpenClickyPlanningLoop.swift:82-86` (`_ = await runRound(...)`) | MATCH (round 2 output is consumed only via the session-history repack in `HeyClickyFreePlanningClient.generatePlan`, line 91-100) |
| Dispatch: `chat`/`ambiguous` → no spawn | design | `cursor-buddy/OpenClickyRouteDispatcher.swift:58-60` | MATCH |
| Dispatch: unified `task`/`short_task`/`long_task_new`/`long_task_existing` → same path | spec:83-88 | `cursor-buddy/OpenClickyRouteDispatcher.swift:61,85` | MATCH |
| Workdir resolution priority: route.workdir → project_ref → preflight folder → nil | dispatcher docstring | `cursor-buddy/OpenClickyRouteDispatcher.swift:182-201` | MATCH |
| `preflight.selectedFolder` accessor exists | task expectation | `cursor-buddy/HeyClickyChatToolCallClient.swift:806, 997` | MATCH |
| Missing PROGRESS.md → PlanningLoop → atomic write → spawn | design/impl-notes:2 | `cursor-buddy/OpenClickyRouteDispatcher.swift:233-259` (`atomically: true`, line 242) | MATCH |
| Present PROGRESS.md → skip planning, direct spawn | resume-friendly | `cursor-buddy/OpenClickyRouteDispatcher.swift:261-268` | MATCH |
| `performSpawn` always sets `progressDriven=true` | impl-notes:34 | `cursor-buddy/OpenClickyRouteDispatcher.swift:291` | MATCH |
| taskDir + taskProgressPath threaded through CompanionManager | impl-notes:3 | `cursor-buddy/CompanionManager.swift:14444-14446,14470-14471,14503-14504,14521-14522,14536-14538,14554-14555,14730-14741` | MATCH |
| `CodexAgentSession.taskDir` + `taskProgressPath` are `@Published` | task expectation | `cursor-buddy/CodexAgentSession.swift:349-350` | MATCH |
| Env injection: only when non-nil non-empty | task expectation | `cursor-buddy/CodexProcessManager.swift:60-65` | MATCH |
| Env keys: `OPENCLICKY_TASK_DIR` / `OPENCLICKY_TASK_PROGRESS` | spec:64-66 | `cursor-buddy/CodexProcessManager.swift:61,64` | MATCH |
| No collision with `OPENCLICKY_BRIDGE_TOKEN` (F27) | task expectation | `cursor-buddy/ClickyCodexConfigTemplate.swift:19` vs `CodexProcessManager.swift:61,64` (different names) | MATCH |
| AGENTS template: glob $OPENCLICKY_TASK_DIR/**/* | spec:69 | `AppResources/OpenClicky/AGENTS-longrun-template.md:9-15` | MATCH (text present, but see HIGH #1) |
| AGENTS template: drive $OPENCLICKY_TASK_PROGRESS to DONE | spec:68-70 | `AppResources/OpenClicky/AGENTS-longrun-template.md:20-32` | MATCH (text present, but see HIGH #1) |
| AGENTS template: warn not to write DONE early | task expectation | `AppResources/OpenClicky/AGENTS-longrun-template.md:33-34` | MATCH |
| AGENTS template: case-sensitive regex documented | spec:31 | `AppResources/OpenClicky/AGENTS-longrun-template.md:30-32` | MATCH |
| F28 progress observer reads PROGRESS.md from resolved task dir | task expectation | `cursor-buddy/CodexAgentSession.swift:2021-2030`, `cursor-buddy/CompanionManager+HeyClicky.swift:445-456` | **BROKEN** (see HIGH #2) |
| F28 lane gate (heyclicky-free-only) still fires when progressDriven=true | task expectation | `cursor-buddy/CodexAgentSession.swift:2023`, `CompanionManager+HeyClicky.swift:414` | MATCH — but interacts with HIGH #2 |
| Preserves F26 progressDriven / completionMarker semantics | design | `cursor-buddy/OpenClickyRouteDispatcher.swift:291-292` + `CompanionManager.swift:14711-14717` | MATCH |
| Preserves F27 bearer_token_env_var / port drift | design | untouched (only added new env keys) | MATCH |

## Issues

### HIGH #1 — `AGENTS-longrun-template.md` not shipped into app bundle, never reaches codex home

- **File**: `cursor-buddy.xcodeproj/project.pbxproj:418` (copy-resources shell phase).
- **File**: `cursor-buddy/CodexHomeManager.swift:134-135` (only `AGENTS.md` is copied into the codex home).
- The copy-resources script enumerates: `SOUL.md`, `OpenClickyModelInstructions.md`, `AGENTS.md`, … — `AGENTS-longrun-template.md` is **not in the list**. `CodexHomeManager.prepare` never references the template file. `AppResources/OpenClicky/AGENTS.md` (2026-07-23 checked) does not contain `OPENCLICKY_TASK` or "Task planning contract" — verified via `grep -n "OPENCLICKY_TASK\|Task planning contract" AppResources/OpenClicky/AGENTS.md → 0 matches`.
- **Failure scenario**: on codex spawn, the child reads only `$CODEX_HOME/AGENTS.md`, which has zero instructions about globbing `$OPENCLICKY_TASK_DIR` or driving `$OPENCLICKY_TASK_PROGRESS`. The env vars set by `CodexProcessManager.swift:60-65` land in the process but the agent has no session-level instruction to consume them. The updated `AGENTS-longrun-template.md` (+31 lines per impl-notes:23) is dead documentation until either (a) it is added to the pbxproj copy list AND `CodexHomeManager` inlines it into `AGENTS.md`, or (b) the OpenClicky user prompt is patched to reference the contract explicitly.
- The impl-notes claim (line 107) that "codex reads AGENTS-longrun-template, globs the task dir, and drives PROGRESS.md" is unsupported by the code.

### HIGH #2 — F28 auto-continue observer reads PROGRESS.md from wrong path for variant A

- **File**: `cursor-buddy/CodexAgentSession.swift:2025-2026` and `cursor-buddy/CompanionManager+HeyClicky.swift:448-449`.
  Both fire-sides compute the poll path as:

      let progressPath = (workingDirectoryPath as NSString).appendingPathComponent("PROGRESS.md")

  which yields `<workingDirectoryPath>/PROGRESS.md`.
- **File**: `cursor-buddy/OpenClickyRouteDispatcher.swift:285` sets `workingDirectoryOverride = workdir ?? resolution.taskDir`. For variant A, `workdir = "/Users/x/Dev/openclicky"` and `resolution.taskDir = "/Users/x/Dev/openclicky/.openclicky/task"`. `performSpawn` passes `workingDirectoryOverride = workdir` to `CompanionManager.dispatchRoutedAgentTask` (line 288), which sets `agentSession.workingDirectoryPath = /Users/x/Dev/openclicky` (`CompanionManager.swift:14694`).
- The observer therefore polls `/Users/x/Dev/openclicky/PROGRESS.md` — but PROGRESS.md was written by the PlanningLoop / codex to `/Users/x/Dev/openclicky/.openclicky/task/PROGRESS.md` (see `OpenClickyRouteDispatcher.swift:242` writing to `resolution.progressPath`, and the codex-side contract in the template).
- **Failure scenario (variant A)**: the observer never sees the DONE marker, `OpenClickyProgressMarkerCheck.isDone` returns false forever (file missing = false, `OpenClickyProgressMarkerCheck.swift:46-48`), and every `.completed` turn fires `.heyClickyRequestAutoContinueReplay` (`CodexAgentSession.swift:2042-2051`). Codex is auto-restarted after writing DONE to the real PROGRESS.md. This is exactly the "runaway loop" pattern F28 was supposed to prevent.
- The session already carries `taskProgressPath` (`CodexAgentSession.swift:350`) — but it is **only read to inject env** (`CodexAgentSession.swift:1422,1428`), never used by the marker observer. The `taskProgressPath` field is available at both fire sites; the observer just needs to prefer it over `workingDirectoryPath+PROGRESS.md` when set.
- Variant B accidentally works because `workingDirectoryOverride = workdir ?? resolution.taskDir` (`OpenClickyRouteDispatcher.swift:285`) — when `workdir` is nil, `workingDirectoryPath` becomes the standalone `~/OpenClicky/<slug>` and PROGRESS.md lives at its root. So this bug only bites variant A.

### HIGH #3 — Confidence-gate fallback path can silently do nothing on high-confidence chat, but the confidence-gate downgrade re-runs classifier fallback that may match to same result

- **File**: `cursor-buddy/OpenClickyRouteDispatcher.swift:65-84`. When `confidence < 0.6`, the code re-runs `classifyFallback`. If that returns `chat`, no action — but the model already said `task` with confidence 0.55. If Fable's own TTS reply had NOT yet been spoken (see `dispatch` caller HeyClickyChatToolCallClient), the user sees nothing happen. Only preserved because the caller unconditionally speaks a TTS reply first — this is documented at `OpenClickyRouteDispatcher.swift:59` ("Fable's TTS reply already covered the user") but is a footgun for callers that don't. **Note**, not a defect in this landing.

### MEDIUM #1 — Round-2 planning output discarded from control flow, but re-consumed only via `HeyClickyFreePlanningClient` internal session history

- **File**: `cursor-buddy/OpenClickyPlanningLoop.swift:82-86`. `_ = await runRound(...)` for round 2. The critique output has no direct effect on round-3's prompt — round 3's prompt only says "Now emit the final PROGRESS.md" without referencing round 2 output.
- The critique reaches round 3 only through `HeyClickyFreePlanningClient.generatePlan` which internally repacks session history (`HeyClickyFreePlanningClient.swift:91-100`, prepends "Continuing a multi-part document. Prior turns: ..."). This works, but is implicit — a future refactor that drops the session-history repack would silently degrade the loop to "brainstorm + format", skipping critique. Consider making round-3's prompt reference the critique explicitly.
- **Failure scenario**: `HeyClickyFreePlanningClient.clearSession` is called in `defer` (`OpenClickyPlanningLoop.swift:45`); if that defer fires before round 3 (it does not on any current path — deferred to function exit), critique context would be lost. Guard is correct but tightly coupled to library internals.

### MEDIUM #2 — Slug collision on variant B silently resumes a prior task

- **File**: `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:52-63`. When the model emits the same slug twice ("async migration" → `async-migration`), the second `resolve()` returns the same `~/OpenClicky/async-migration/` path. If PROGRESS.md still exists from the first task, the dispatcher's "present PROGRESS.md → skip planning, direct spawn" branch (`OpenClickyRouteDispatcher.swift:261-268`) fires against the stale checklist.
- **Failure scenario**: user asks "plan an async migration" (task A completes with `LAST_COMPLETED: DONE`). Weeks later, user asks "start an async migration on this new codebase" without a Finder folder. Variant B resolves to the same dir, finds the DONE-marked PROGRESS.md, spawns codex against it, and the observer sees DONE immediately — codex exits without doing anything. There is no collision detection or timestamp check.
- Follow-up (per task): ephemeral dir cleanup is intentionally not addressed here, but slug-collision-on-DONE is worse than accumulating dirs; the dir grows but at least the semantics are consistent, whereas collision-on-DONE is a silent no-op.

### MEDIUM #3 — Task cancellation mid-planning leaves an orphan write

- **File**: `cursor-buddy/OpenClickyRouteDispatcher.swift:239-257`. The `Task { @MainActor in ... }` is fire-and-forget. If the user hits "stop" while planning is in flight, there is no cancellation check between `generate` returning and the `write(to:atomically:encoding:)` at line 242. `Task` handle is not retained; there is no way to cancel it.
- **Failure scenario**: user says a task, immediately says "cancel" or closes the app. `generate` finishes ~5-10s later, writes PROGRESS.md, calls `performSpawn` → codex spawns despite the cancel. Cascade: two codex instances, or a resurrected task the user thought they killed.
- Minor mitigation: `HeyClickyFreePlanningClient.generatePlan` is not cancellable either (its `postJSON` is not Task.cancel-aware — see `HeyClickyFreePlanningClient.swift:139`). Full fix requires threading a cancellation source; documenting as MEDIUM because the top-level Stop button semantics were not part of this landing.

### MEDIUM #4 — Concurrent variant-B planning races on directory creation, but writes are separate — safe by accident

- **File**: `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:109-114`. `createDirectory(atPath:withIntermediateDirectories:true)` is idempotent under macOS (`EEXIST` is not returned when `withIntermediateDirectories:true`). Two concurrent `resolve()` calls with the same slug both succeed to the same dir. Progress.md writes race, last-writer-wins. In practice, two calls with the same slug come from two adjacent user turns and one PlanningLoop would clobber the other's PROGRESS.md — minor because the collision-on-slug case (MEDIUM #2) is the real risk. Two DIFFERENT slugs never race because they use different subdirectories.

### LOW #1 — Round-3 prompt allows model to skip `## Checklist` heading

- **File**: `cursor-buddy/OpenClickyPlanningLoop.swift:191-198`. `isValidProgressMarkdown` checks only for `- [ ]` substring and `LAST_COMPLETED:` presence. If the model omits the `## Checklist` heading (e.g., emits `# Plan` or nothing), the validator passes but the file diverges from the spec (`OPENCLICKY_TASK_SPEC.md:35`). Codex is instructed to read the file as a checklist regardless, so it still works, but F28 observer + user-facing UI that pattern-matches `## Checklist` (none currently exist) would misbehave. Consider making the check stricter to force the heading.

### LOW #2 — Fallback slug quality: `Array.randomElement()!` on a static 36-char alphabet

- **File**: `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:75-77`. `randomElement` on `String.randomElement` uses `SystemRandomNumberGenerator` (cryptographically strong on Darwin) — actually random. 6 chars × 36 = 36^6 ≈ 2.2B combinations. Combined with the minute-resolution date stamp, collision within a single user's session is astronomically unlikely. Meets the "not seeded, actually random" bar. Just noting: `randomElement()!` force-unwraps but the alphabet is a literal non-empty string, so the unwrap is safe.

### LOW #3 — Unicode / non-ASCII input to slug sanitizer

- **File**: `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:82-105`. The sanitizer iterates `lowered.unicodeScalars` and keeps only `a-z0-9`. Chinese input like "异步迁移" produces an empty string after filtering (all Han scalars are dropped), which then triggers the empty-slug branch (`sanitize` returns "") → `finalSlug = generateFallbackSlug()` (line 52). This is safe (no garbage bytes on disk) but silently discards user intent — the resulting directory has no relation to what the user asked for. Consider transliteration or preserving Unicode letters via `CharacterSet.letters` union with digits.

### LOW #4 — `.openclicky` naming is not gitignore-safe by default

- **File**: `cursor-buddy/OpenClickyTaskDirectoryResolver.swift:37-40`. Variant A writes to `<workdir>/.openclicky/task/`. If the workdir is a git repo without `.openclicky/` in `.gitignore`, the checkbox mutations and DONE marker would be visible in `git status`. Not this landing's responsibility to auto-append gitignore, but the spec doesn't warn users either. Consider one-shot gitignore append on first write.

### LOW #5 — Race between PlanningLoop write and codex spawn read is minimal but exists

- **File**: `cursor-buddy/OpenClickyRouteDispatcher.swift:242,249`. `write(to:atomically:true,encoding:.utf8)` uses atomic-swap semantics on Darwin (writes to temp file, `rename(2)`). By the time `performSpawn` is called on line 249, the swap is complete and any subsequent open() sees the final content. No race. Verified via `atomically: true`.

## Money-Rule Verification

- Grep `ClaudeAPI` in `cursor-buddy/OpenClickyPlanningLoop.swift` → 0 matches.
- Grep `OpenAI` / `ChatCompletion` / `OpenAIAPI` in `OpenClickyPlanningLoop.swift` → 0 matches.
- The only outbound path is `HeyClickyFreePlanningClient.generatePlan` (`OpenClickyPlanningLoop.swift:132`), which routes through the msgs-quota channel per `HeyClickyFreePlanningClient.swift:2-11,131-138` (client header: "Zero agent-credit consumption — consumes the msgs quota lane").
- **Money rule: MATCH.** No paid API is touched during planning. When the free lane fails (`generatePlan` throws), the code returns "" (line 154) and the loop's fallback returns the minimal PROGRESS.md stub (lines 205-209). No fallback to Claude / OpenAI direct.

## Env-Leak Analysis

- `OPENCLICKY_TASK_DIR` / `OPENCLICKY_TASK_PROGRESS` are injected into codex's env at `CodexProcessManager.swift:61,64`. Codex child processes inherit the parent env by default on POSIX; any tool codex spawns (bash, python, git) will see the vars. This is intended (the AGENTS template glob is executed via `codex` running a shell). No secret content — the vars are paths that the child already has read access to. No leak concern.

## F28 Interaction

- F28 fire site (`CodexAgentSession.swift:2021-2052`) fires only when `progressDriven == true` AND `model.hasPrefix("heyclicky-free-")` AND working-dir-based marker check fails. `RouteDispatcher.performSpawn` sets `progressDriven = true` (`OpenClickyRouteDispatcher.swift:291`). So F28 does fire on the new pipeline — **but** it polls the wrong path (see HIGH #2), so it effectively fires on every `.completed`.
- Observer-side gate in `CompanionManager+HeyClicky.swift:445-456` has the identical wrong-path bug.

## Final Verdict

**FAIL** — two HIGH-severity bugs block the pipeline from working end-to-end on variant A (the primary path per Scenario 1 in impl-notes:92-109). Variant B works by coincidence (workdir=nil path).

### Top 3 Priority Fixes

1. **Fix F28 marker path** (HIGH #2). At both fire sites (`CodexAgentSession.swift:2025-2026` and `CompanionManager+HeyClicky.swift:448-449`), prefer `session.taskProgressPath` when set:

       let progressPath: String
       if let tp = taskProgressPath, !tp.isEmpty {
           progressPath = tp
       } else {
           progressPath = (workingDirectoryPath as NSString).appendingPathComponent("PROGRESS.md")
       }

   The field already exists on the session (`CodexAgentSession.swift:350`) and is set by `CompanionManager.swift:14734`. Zero new plumbing needed.

2. **Ship the AGENTS-longrun-template.md contract to codex** (HIGH #1). Two options:
   - Add `AGENTS-longrun-template.md` to the `for rel in …` list in `cursor-buddy.xcodeproj/project.pbxproj:418`, then extend `CodexHomeManager.swift:134-141` to append the template's "Task planning contract" section to `$CODEX_HOME/AGENTS.md` (matching the existing SOUL.md inlining pattern at `inlinePersonaIntoHomeInstructions`, `CodexHomeManager.swift:674`).
   - OR: inline the contract text into `AppResources/OpenClicky/AGENTS.md` directly so the existing copy path (`CodexHomeManager.swift:134-135`) already delivers it.

   Without this, `OPENCLICKY_TASK_DIR` / `OPENCLICKY_TASK_PROGRESS` are set in the child env but the agent has no instruction to act on them, so PROGRESS.md drive is agent-model-dependent and unreliable.

3. **Guard slug collision on variant B** (MEDIUM #2). In `OpenClickyTaskDirectoryResolver.resolve` (`OpenClickyTaskDirectoryResolver.swift:52-63`), when `progressExists && anchor == .standalone`, either:
   - Read PROGRESS.md, check for `LAST_COMPLETED: DONE`, and if present, append a suffix (`-2`, `-3`, …) to the slug before creating the dir; OR
   - Include a shortened timestamp in the slug when the caller explicitly requests a "new" task (requires threading a `kind` hint into the resolver).
   Otherwise a user asking twice for the same slug silently no-ops on the second request.

## Notes preserved

- Money rule: MATCH.
- F26 route parsing preserved: MATCH (`OpenClickyRouteDispatcher.swift:57-91` unchanged behaviour for chat/ambiguous).
- F27 codex config: untouched.
- F28 fire semantics preserved (aside from HIGH #2 pathing).
- SPM package untouched (per impl-notes:168).
