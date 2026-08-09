# Task Planning + Drive Pipeline — implementation notes (2026-07-23)

Unified openclicky task-planning pipeline. Openclicky-native, no Everywhere
byte-parity counterpart (Everywhere pin `30e03e9dcfdd4247fd679828ed86e9042f32d809`
is informational only).

## Files created

| Path | Lines |
|---|---|
| `cursor-buddy/OpenClickyTaskDirectoryResolver.swift` | 115 |
| `cursor-buddy/OpenClickyPlanningLoop.swift` | 210 |
| `docs/ROADMAP/.impl-notes/task-planning-pipeline-2026-07-23.md` | this file |

## Files modified

| Path | Before | After | Delta |
|---|---:|---:|---:|
| `cursor-buddy/OpenClickyRouteDispatcher.swift` | 323 | 410 | +87 |
| `cursor-buddy/CompanionManager.swift` | 17714 | 17758 | +44 |
| `cursor-buddy/CodexProcessManager.swift` | 664 | 682 | +18 |
| `cursor-buddy/CodexAgentSession.swift` | 3585 | 3601 | +16 |
| `AppResources/OpenClicky/AGENTS-longrun-template.md` | 185 | 216 | +31 |
| `docs/OPENCLICKY_TASK_SPEC.md` | 74 | 88 | +14 |

## Wiring summary

1. **`OpenClickyRouteDispatcher.spawnCodex`** now resolves the task directory
   via `OpenClickyTaskDirectoryResolver.resolve(workdir:slug:)` instead of the
   old ephemeral `~/Library/Application Support/OpenClicky/EphemeralTasks/…`
   fallback. Variant A anchors to `<workdir>/.openclicky/task/`; variant B
   drops into `~/OpenClicky/<slug>/`. Both variants force
   `progressDriven=true` on the codex spawn so the F28 auto-continue observer
   drives to `LAST_COMPLETED: DONE`.
2. If `PROGRESS.md` is missing at the resolved path, an async
   `OpenClickyPlanningLoop.generate` call runs 3 rounds against the HeyClicky
   free planning channel (msgs quota, no agent credit) and writes the
   returned text atomically to `PROGRESS.md`. On any failure a minimal
   `## Checklist\n- [ ] <transcript>\n\nLAST_COMPLETED:\n` stub is used —
   `generate` never throws.
3. Both branches call the extracted `performSpawn` which packages the
   `taskDir` / `taskProgressPath` (plus `progressDriven=true`) onto
   `CompanionManager.dispatchRoutedAgentTask`. That threads through
   `startVoiceAgentTaskPlan` -> `startVoiceAgentTask` -> the new
   `CodexAgentSession.taskDir` / `taskProgressPath` fields.
4. **`CodexProcessManager.start`** accepts new optional `taskDir` /
   `taskProgressPath` params and injects them as `OPENCLICKY_TASK_DIR` /
   `OPENCLICKY_TASK_PROGRESS` in the child process env.
5. **`CodexAgentSession.startProcess`** passes the session's stored task
   fields into `processManager.start(...)`, keeping the manager free of a
   session dependency.
6. **`AGENTS-longrun-template.md`** gains a top-of-file "Task planning
   contract" section instructing codex to glob `$OPENCLICKY_TASK_DIR/**/*`
   and drive `$OPENCLICKY_TASK_PROGRESS` to
   `LAST_COMPLETED: DONE` (matching the F28 regex).

## Grep verification

- `OPENCLICKY_TASK_DIR` appears in:
  - `cursor-buddy/CodexProcessManager.swift` (env inject)
  - `cursor-buddy/CodexAgentSession.swift` (docstring)
  - `cursor-buddy/CompanionManager.swift` (docstring)
  - `AppResources/OpenClicky/AGENTS-longrun-template.md` (contract, 2x)
  - `docs/OPENCLICKY_TASK_SPEC.md` (contract, 2x)
- `OPENCLICKY_TASK_PROGRESS` appears in:
  - `cursor-buddy/CodexProcessManager.swift` (env inject)
  - `cursor-buddy/CodexAgentSession.swift` (docstring)
  - `cursor-buddy/CompanionManager.swift` (docstring)
  - `AppResources/OpenClicky/AGENTS-longrun-template.md` (contract, 2x)
  - `docs/OPENCLICKY_TASK_SPEC.md` (contract, 2x)
- `.openclicky/task` present in
  `OpenClickyRouteDispatcher.swift`, `OpenClickyTaskDirectoryResolver.swift`,
  `docs/OPENCLICKY_TASK_SPEC.md`, `AGENTS-longrun-template.md` (via context).
- `homeDirectoryForCurrentUser.appendingPathComponent("OpenClicky"` present
  in `OpenClickyTaskDirectoryResolver.swift`; `~/OpenClicky/` documented in
  `OPENCLICKY_TASK_SPEC.md`.

## `swiftc -parse` results

Clean on all touched files (no output):
- `OpenClickyTaskDirectoryResolver.swift`
- `OpenClickyPlanningLoop.swift`
- `OpenClickyRouteDispatcher.swift`
- `CodexAgentSession.swift`
- `CodexProcessManager.swift`
- `CompanionManager.swift`

## Scenario walkthroughs

**Scenario 1 — User has a Finder folder selected**

1. User says "在这个项目里加个截屏工具". Layer-0 preflight sets
   `preflight.selectedFolder = /Users/wowdd1/Dev/openclicky`.
2. Dialog model returns `[ROUTE] {"kind":"long_task_new","slug":"screenshot-tool",...}`.
3. `RouteDispatcher.spawnCodex` derives `workdir = /Users/wowdd1/Dev/openclicky`,
   calls `OpenClickyTaskDirectoryResolver.resolve(workdir: workdir, slug: "screenshot-tool")`.
   Resolver returns `taskDir = /Users/wowdd1/Dev/openclicky/.openclicky/task`,
   creates the directory, probes `PROGRESS.md` — not present.
4. `OpenClickyPlanningLoop.generate` runs 3 rounds; final PROGRESS.md is
   written atomically to that path.
5. `performSpawn` calls `dispatchRoutedAgentTask(...)` with
   `workingDirectoryOverride = /Users/wowdd1/Dev/openclicky`,
   `taskDir = .../.openclicky/task`, `taskProgressPath = .../PROGRESS.md`,
   `progressDriven = true`, `completionMarker = "LAST_COMPLETED: DONE"`.
6. `CodexProcessManager.start` injects `OPENCLICKY_TASK_DIR` /
   `OPENCLICKY_TASK_PROGRESS` into the child env; codex reads
   AGENTS-longrun-template, globs the task dir, and drives PROGRESS.md.
   F28 observer polls PROGRESS.md for `LAST_COMPLETED: DONE` and stops
   auto-continue once codex writes it.

**Scenario 2 — Standalone task, no Finder / project context**

1. User says "帮我搞个每日汇率提醒". Layer-0 has no selected folder and no
   project match. Preflight `selectedFolder = nil`.
2. Dialog model returns `[ROUTE] {"kind":"long_task_new","slug":"daily-fx-alert",...}`.
3. `RouteDispatcher.spawnCodex` leaves `workdir = nil`. Resolver takes
   variant B: sanitizes `slug` -> `daily-fx-alert`, resolves
   `taskDir = /Users/wowdd1/OpenClicky/daily-fx-alert`, creates directory,
   probes PROGRESS.md — missing.
4. Planning loop fabricates PROGRESS.md and writes it. If the model produced
   no valid slug, `generateFallbackSlug()` yields
   `yyyy-MM-dd-HHmm-<random6>` and the standalone dir uses that.
5. `performSpawn` uses `workingDirectoryOverride = taskDir` (the resolved
   `~/OpenClicky/<slug>` — codex needs a real cwd; workdir was nil).
6. Env vars and F28 behaviour identical to Scenario 1.

## Planning-loop prompt decisions

Three rounds, single session id `openclicky.planning.<uuid8>` cleared after
use so no history leaks across tasks:

- **Round 1** — take the raw voice transcript + Layer-0 digest, ask the model
  to emit 5–12 numbered, verifiable execution steps. No markdown yet — just
  numbered sentences to avoid the model prematurely locking a schema.
- **Round 2** — critique the checklist for verifiability, dependency order,
  missing setup/teardown/validation, and step-splitting. Emit the revised
  numbered list. This second pass is deliberately budget-neutral (still on
  the free lane) and catches obvious gaps from Round 1.
- **Round 3** — format the final list as `## Checklist\n- [ ] ...\n\n` +
  trailing empty `LAST_COMPLETED:` marker. Prompt explicitly forbids code
  fences and any preamble; a defensive `stripCodeFences` + validation pass
  in Swift catches models that still wrap output. If the round-3 payload
  lacks a checkbox or the marker, we fall back to
  `## Checklist\n- [ ] <intent>\n\nLAST_COMPLETED:\n`.

Provider selection: the free HeyClicky planning channel is the only lane
exercised — it consumes msgs quota, never agent credit, never a raw paid
API key. This matches the money-rule and is invoked via the existing
`HeyClickyFreePlanningClient` (used elsewhere for automation free-plan).

## Openclicky-native note

There is no Everywhere counterpart for this pipeline; the design is unique
to openclicky (Layer-0 finder anchoring + F28 progress-marker driver +
free-lane planning fallback). The Everywhere pin
`30e03e9dcfdd4247fd679828ed86e9042f32d809` remains informational only —
no code was ported from that revision.

## What was deliberately preserved

- **F27** — `OPENCLICKY_BRIDGE_TOKEN` env / `bearer_token_env_var` untouched.
- **F28** — `OpenClickyProgressMarkerCheck`, the `turn.completed` handler in
  `CodexAgentSession`, and `hasInterruptedInFlightTurn` in
  `CompanionManager+HeyClicky` all unchanged. Setting `progressDriven = true`
  in `performSpawn` is the same substrate F26/F28 already threaded.
- **F32–F36** tools untouched.
- SPM package untouched.
- Workdir variant A always uses the fixed `.openclicky/task/` path — no
  per-task subdir under a workdir.
