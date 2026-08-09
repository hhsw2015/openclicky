# Task Planning Pipeline Fix Report (2026-07-23)

Fixes for audit findings in
`docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md`.

Scope: HIGH #1 (AGENTS contract not shipped), HIGH #2 (F28 marker path
wrong for variant A), MEDIUM #2 (variant B slug collision silent
resume). No F28 observer changes; no OpenDia; no bridge tools; no SPM;
no pbxproj (chose review-recommended "Option A" inlining).

## HIGH #1 — F28 marker path wrong for variant A

Review cite: `docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md`
lines 59-71 (HIGH #2 in the review, renumbered as HIGH #1 in the fix task).

### Before

Both fire sites built the progress path from `workingDirectoryPath +
"/PROGRESS.md"`, ignoring the already-threaded
`session.taskProgressPath` (set by RouteDispatcher at
`CompanionManager.swift:14734`).

- `cursor-buddy/CodexAgentSession.swift:2025-2026`
  ```swift
  let progressPath = (workingDirectoryPath as NSString)
      .appendingPathComponent("PROGRESS.md")
  ```
- `cursor-buddy/CompanionManager+HeyClicky.swift:448-449`
  ```swift
  let progressPath = (session.workingDirectoryPath as NSString)
      .appendingPathComponent("PROGRESS.md")
  ```

Failure: variant A writes PROGRESS.md to
`<workdir>/.openclicky/task/PROGRESS.md`, but
`workingDirectoryPath = <workdir>`. Observer polled the wrong file,
`OpenClickyProgressMarkerCheck.isDone` returned false forever, F28
auto-continue looped indefinitely.

### After

Both sites prefer the threaded field; workdir fallback preserved for
legacy sessions that never had `taskProgressPath` set.

- `cursor-buddy/CodexAgentSession.swift` (F28 fire block, around
  line 2025):
  ```swift
  let progressPath: String
  if let tp = taskProgressPath, !tp.isEmpty {
      progressPath = tp
  } else {
      progressPath = (workingDirectoryPath as NSString)
          .appendingPathComponent("PROGRESS.md")
  }
  ```
- `cursor-buddy/CompanionManager+HeyClicky.swift` (`hasInterruptedInFlightTurn`,
  around line 448):
  ```swift
  let progressPath: String
  if let tp = session.taskProgressPath, !tp.isEmpty {
      progressPath = tp
  } else {
      progressPath = (session.workingDirectoryPath as NSString)
          .appendingPathComponent("PROGRESS.md")
  }
  ```

### Rationale

`taskProgressPath` is already `@Published` on `CodexAgentSession`
(`CodexAgentSession.swift:350`) and populated during spawn plumbing
(`CodexAgentSession.swift:1422,1428`). Fix cost: zero new plumbing,
zero observer changes. `OpenClickyProgressMarkerCheck.isDone` regex is
untouched — only the path handed to it now points at the actual write
location. Variant B was accidentally correct before (workdir==taskDir
when workdir is nil), and remains correct via the same field.

## HIGH #2 — AGENTS long-run template not shipped

Review cite: `docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md`
lines 51-58 (HIGH #1 in the review).

### Before

- `AGENTS-longrun-template.md` had a fresh "Task planning contract
  (openclicky-driven)" section (template lines 7-37).
- Neither the pbxproj copy-resources phase
  (`cursor-buddy.xcodeproj/project.pbxproj:418`) nor
  `CodexHomeManager.swift:134-135` copied it into the codex home.
- `grep -n "OPENCLICKY_TASK\|Task planning contract"
  AppResources/OpenClicky/AGENTS.md` returned zero matches.
- `OPENCLICKY_TASK_DIR` / `OPENCLICKY_TASK_PROGRESS` env vars landed in
  child process env (`CodexProcessManager.swift:61,64`) but codex had
  no session-level instruction telling it to consume them.

### After (Option A — inline into AGENTS.md)

Appended the "Task planning contract (openclicky-driven)" section
verbatim to `AppResources/OpenClicky/AGENTS.md` (new lines 33-64):

```
## Task planning contract (openclicky-driven)

If environment variable `$OPENCLICKY_TASK_DIR` is set at spawn:

1. **Read every file** in that directory as authoritative background.
   ... (glob rules)
2. Common files you may find: SPEC.md, REQUIREMENTS.md, ...

If environment variable `$OPENCLICKY_TASK_PROGRESS` is set:

3. Read the file it points to. It is a checklist of what to execute.
4. Work through the checklist in order.
5. Mark items done in-file: `- [ ]` -> `- [x]`.
6. When ALL items done, append or update:
       LAST_COMPLETED: DONE
   Case-sensitive regex ^\s*LAST_COMPLETED:\s*DONE\s*$
7. Do NOT write DONE early ...

If either env var is unset, no planning-doc contract applies.
```

`AGENTS-longrun-template.md` retained as reference documentation
(still cited in comments: `HeyClickyChatToolCallClient.swift:871`,
`CodexProcessManager.swift:58`, `CodexAgentSession.swift:336,345`,
`OpenClickyProgressMarkerCheck.swift:11`). Deletion would leave dead
comment refs; keeping the file has zero shipping cost.

### Rationale

Option A matches how existing sections (SOUL persona, etc.) live in
`AGENTS.md`. Zero pbxproj change, zero `CodexHomeManager` change:
`CodexHomeManager.swift:134-135` already copies `AGENTS.md` verbatim
into `$CODEX_HOME`, so the new section reaches every spawned codex
session immediately. Env-var wiring on the Swift side
(`CodexProcessManager.swift:60-65`) now has a matching instruction on
the agent side, closing the loop the review flagged as broken.

## MEDIUM — Variant B slug collision silent resume

Review cite: `docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md`
lines 83-87 (MEDIUM #2 in the review).

### Before

`cursor-buddy/OpenClickyTaskDirectoryResolver.swift:52-63` had no
collision check for the variant-B branch (`~/OpenClicky/<slug>/`). If a
prior task on the same slug had left `PROGRESS.md` marked
`LAST_COMPLETED: DONE`, `RouteDispatcher.performSpawn`
(`OpenClickyRouteDispatcher.swift:261-268`) skipped planning, spawned
codex against the stale plan, and F28 saw DONE immediately — codex
exited with no work done. User expected new task, got silent no-op.

### After

Introduced private helper `resolveNonCollidingSlug(baseSlug:root:)` in
the resolver (variant-B only). Logic:

1. Start with `baseSlug`, attempt=1.
2. Check `<root>/<slug>/PROGRESS.md`:
   - Missing → return this slug (fresh).
   - Present but NOT `LAST_COMPLETED: DONE` (regex
     `^\s*LAST_COMPLETED:\s*DONE\s*$`, multi-line) → return this slug
     (resume-friendly).
   - Present AND DONE → increment attempt, try `<baseSlug>-<attempt>`.
3. Safety cap at 100 attempts to prevent runaway loop.
4. Unreadable PROGRESS.md → reuse slug (bias toward resume rather than
   dead-slug proliferation).

Regex compiles once outside the loop.

Variant A (`.workdir` anchor) unchanged — the user's workdir is the
authoritative anchor and cannot silently alias.

### Rationale

Matches review recommendation verbatim
(`docs/ROADMAP/.review-notes/task-planning-pipeline-2026-07-23.md`
lines 143-159 pseudocode). Uses the same `LAST_COMPLETED: DONE` marker
semantics the F28 observer and template contract already share, so
"done" definition stays canonical. Not-done PROGRESS.md still resumes
(preserves existing resume-friendly behavior in
`RouteDispatcher.swift:261-268`).

## Verification

- `swiftc -parse cursor-buddy/OpenClickyTaskDirectoryResolver.swift` →
  exit 0.
- `swiftc -parse cursor-buddy/CodexAgentSession.swift` → exit 0.
- `swiftc -parse cursor-buddy/CompanionManager+HeyClicky.swift` →
  exit 0.
- Grep sanity:
  - `session.taskProgressPath` / `taskProgressPath` present at both F28
    fire sites (was absent before): confirmed in
    `CodexAgentSession.swift:2032` and
    `CompanionManager+HeyClicky.swift:453`.
  - `OPENCLICKY_TASK_DIR` reference now in `AGENTS.md`
    (`AppResources/OpenClicky/AGENTS.md:35`): confirmed via
    `grep -n "OPENCLICKY_TASK" AppResources/OpenClicky/AGENTS.md`.
  - Variant B collision loop: confirmed in
    `OpenClickyTaskDirectoryResolver.swift:55` (`finalSlug =
    resolveNonCollidingSlug(...)`) and helper at line 73.

### Regression walk-through

1. **Variant A** — dialog produces `[ROUTE] task workdir=/Users/x/repo
   slug=refactor-auth`. Resolver returns
   `taskDir=/Users/x/repo/.openclicky/task`,
   `progressPath=/Users/x/repo/.openclicky/task/PROGRESS.md`.
   RouteDispatcher spawns codex with
   `workingDirectoryPath=/Users/x/repo` and
   `taskProgressPath=/Users/x/repo/.openclicky/task/PROGRESS.md`. On
   `turn/completed`, F28 fire in `CodexAgentSession.swift` now reads
   `taskProgressPath` first → observer polls the actual write
   location. Marker found on real completion → no auto-continue loop.
2. **Variant B, existing DONE task** — user says "start async-migration"
   with no Finder folder, and `~/OpenClicky/async-migration/PROGRESS.md`
   already has `LAST_COMPLETED: DONE`. Resolver reads the file, matches
   the regex, increments to `async-migration-2`. If the new candidate is
   fresh (no PROGRESS.md), returns it. RouteDispatcher plans into the
   new directory. No silent no-op.
3. **Variant B, unfinished task** — same slug but PROGRESS.md has
   `LAST_COMPLETED: 3` (no DONE). Resolver returns the existing slug
   without suffix. RouteDispatcher's `progressExists` branch
   (`OpenClickyRouteDispatcher.swift:261-268`) fires, codex resumes at
   the checkpoint. Preserves existing resume-friendly behavior.

## Files touched

- `cursor-buddy/CodexAgentSession.swift` (F28 fire path: prefer
  `taskProgressPath` over workdir fallback)
- `cursor-buddy/CompanionManager+HeyClicky.swift`
  (`hasInterruptedInFlightTurn`: same prefer-then-fallback)
- `cursor-buddy/OpenClickyTaskDirectoryResolver.swift` (new
  `resolveNonCollidingSlug` helper; variant B branch calls it)
- `AppResources/OpenClicky/AGENTS.md` (appended "Task planning
  contract" section, 32 new lines)

## Files intentionally NOT touched

- `cursor-buddy/OpenClickyProgressMarkerCheck.swift` — regex works,
  only the fire-site path changes.
- `cursor-buddy.xcodeproj/project.pbxproj` — Option A avoids
  pbxproj/copy-phase changes.
- `cursor-buddy/CodexHomeManager.swift` — Option A avoids the inlining
  hook here; existing `AGENTS.md` copy already delivers the new
  section.
- `AppResources/OpenClicky/AGENTS-longrun-template.md` — kept as
  reference documentation; comments in Swift sources still cite it by
  line number.
- F31 OpenDia files, F32-F36 bridge tools, SPM package — per fix-task
  constraints.
