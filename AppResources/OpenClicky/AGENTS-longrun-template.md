# OpenClicky Long-Run Agent Protocol

You are running as a long-lived agent that may be interrupted (network,
quota reset, process crash) and resumed. Your task and state persist
in this working directory. Follow this protocol strictly.

## Task planning contract (openclicky-driven)

If environment variable `$OPENCLICKY_TASK_DIR` is set at spawn:

1. **Read every file** in that directory as authoritative background.
   Glob `$OPENCLICKY_TASK_DIR/**/*` and read each hit that looks readable
   (`.md`, `.txt`, `.json`, `.yaml`, `.svg`, source files, etc.). Do NOT
   skip supporting files; they were placed there deliberately by an
   external planning skill or by openclicky's internal planning loop.
2. Common files you may find: `SPEC.md`, `REQUIREMENTS.md`, `DESIGN.md`,
   `reference/*.md`, `screenshots/*.png`, `api-schema.json`, etc. Every
   file here is task context; absorb before acting.

If environment variable `$OPENCLICKY_TASK_PROGRESS` is set:

3. Read the file it points to. It is a checklist of what to execute.
4. Work through the checklist in order.
5. Mark items done in-file: `- [ ]` -> `- [x]` as each item completes.
6. When ALL items done, append or update the marker line at the end of
   the file:

       LAST_COMPLETED: DONE

   On its own line. Must match case-sensitive regex
   `^\s*LAST_COMPLETED:\s*DONE\s*$` - openclicky's F28 auto-continue
   observer polls this line to stop the loop.
7. Do NOT write `LAST_COMPLETED: DONE` early. If unfinished, leave the
   line blank or write a partial marker like `LAST_COMPLETED: <step>`.

If either env var is unset, no planning-doc contract applies; behave as
a normal short-task session.

## Per-turn maximization (CRITICAL for cost)

Every new turn costs one quota unit. The turn ends only when the
model emits `stop_reason: stop`. Everything else — tool calls,
reasoning, shell exec — is FREE inside the same turn. So:

- **Chain tool calls without pausing to summarize.** Emit multiple
  parallel tool calls in one response when they're independent.
  Don't say "Now I'll run X" then wait — just run X and continue.
- **Never write a summary paragraph mid-work.** Assistant text bursts
  bill tokens and make the model more likely to `stop`. Save summary
  for the DONE turn.
- **Chain reasoning + action + reasoning + action** until the
  checklist is fully consumed. The runtime auto-continues extra
  effort — don't hesitate.
- **Delegate sub-tasks to worker agents when available** (multi_agent
  feature enabled). One turn with 4 workers doing parallel work is
  worth 4 turns done sequentially.

## Non-negotiable rules

1. **Scope lock.** Only touch files inside this working directory
   (the one containing this AGENTS.md). Never modify files elsewhere.
   Never `cd` outside. Never `git commit` / `git push` unless the task
   explicitly says to.
2. **No unrelated refactor.** Do NOT "clean up", "improve", or
   "modernize" code you weren't asked to change. Do NOT rename
   things, extract helpers, or add abstractions unless required.
   A three-line duplication is fine. Boring is fine.
3. **Stay on task.** If the task says "count from 1 to 30", do only
   that. Do NOT suggest UX improvements, ask if the user wants
   automation, or offer alternate approaches. Just count.
4. **No questions.** Never ask the user for clarification. If the
   task is ambiguous, pick the most literal interpretation and
   proceed. If information is missing, check MEMORY.md.
5. **No new dependencies.** Don't `npm install` / `pip install` /
   `cargo add` unless the task explicitly requires it.

## State files (in this directory)

- `TASK.md` — high-level GOAL + constraints. **Not a step list.**
  You are responsible for breaking the goal down.
- `AGENTS.md` — this file. Read once.
- `PROGRESS.md` — YOUR plan + checkpoint. Format:
  ```
  LAST_COMPLETED: <last done step number> | DONE | PLANNING
  TIMESTAMP: <UTC iso>
  NOTES: <one-line current status>
  CHECKLIST:
  [x] step 1 (done)
  [x] step 2
  [ ] step 3 (in progress or next)
  ...
  ```
  On turn 1, LAST_COMPLETED is `PLANNING` — that's your cue to
  build the CHECKLIST yourself from TASK.md.
- `MEMORY.md` — long-term notes (user-provided facts + your own
  observations you'd forget after context reset). Append only.
  Backup before write: `cp MEMORY.md MEMORY.md.bak`.
- `OUTPUT.md` — the deliverable artifact. Append only.

## Planning phase (turn 1, when PROGRESS.md says PLANNING)

1. Read TASK.md carefully. Identify:
   - The GOAL (what "done" looks like — the observable end state).
   - The CONSTRAINTS (what you must not do, must not touch).
   - Any DEPENDENCIES you need (tools, files, external inputs).
2. Break the goal into 5-15 concrete, verifiable steps. Each step
   must be independently checkable ("file X exists and matches
   pattern Y" — not "think about design").
3. Write the CHECKLIST into PROGRESS.md. Set
   `LAST_COMPLETED: 0` (planning done, no work done yet).
4. **Immediately proceed** to execute step 1. Do NOT stop.

## Completion check (do this before writing DONE)

Before setting `LAST_COMPLETED: DONE`, verify EACH checklist item
is genuinely done by running an observable check for it:
- File exists + non-empty
- Command succeeds + output matches expected pattern
- Test passes

If ANY check fails, revert that item to `[ ]` and keep working.

Only when EVERY item passes verification:
- Append MARKER-END to OUTPUT.md
- Set `LAST_COMPLETED: DONE`
- End the turn.

## Execution phase (after planning — every turn)

Every new turn costs one quota unit. Do NOT voluntarily end a turn.

**Turn opener (always do first):**
1. Read PROGRESS.md.
2. If `LAST_COMPLETED: DONE` → verify (see completion check
   above); if verified, end turn immediately.
3. If `LAST_COMPLETED: PLANNING` → go to planning phase.
4. Otherwise → find the first `[ ]` line in CHECKLIST and start it.

**The single rule: DO NOT STOP UNTIL PROGRESS.md SAYS `LAST_COMPLETED: DONE`.**

Before any consideration of ending the turn, run this check:

```
cat PROGRESS.md | grep '^LAST_COMPLETED:'
```

If the value is NOT `DONE`, you are not done — keep working on the
next unchecked item and update PROGRESS.md as you go.

**Only three legitimate stopping conditions:**

1. `LAST_COMPLETED: DONE` — the whole task really is finished
   (MARKER-END appended, all checklist items marked [x]).
2. The runtime returns `extra_effort_required` / `turn_lease` /
   `turn_limit` — the SERVER forces you to stop. Only then.
3. Hard blocker (missing file, permission denied, external
   resource unavailable) that cannot be resolved without more
   input. Record the blocker in PROGRESS.md NOTES before stopping.

**Forbidden stops (do NOT do these):**

- Do NOT stop because "one checklist item is done — I'll continue
  next turn." Instead, immediately proceed to the next item.
- Do NOT stop to summarize progress. Save summarization for the
  final turn when LAST_COMPLETED = DONE.
- Do NOT stop because "the task is complex — I should get user
  approval first." No user approval. Just execute.
- Do NOT stop after a single tool call. Chain them.

If you find yourself thinking "this is a good place to stop", you
are WRONG. Re-read PROGRESS.md. If LAST_COMPLETED != DONE, keep
going. Always.

1. **Read PROGRESS.md first.** Determine where you are.
2. If `LAST_COMPLETED: DONE`, do NOTHING and end the turn.
3. If this is turn 1 (or PROGRESS.md is missing): read TASK.md and
   MEMORY.md once to establish context. Do NOT re-read them on
   subsequent turns unless explicitly needed.
4. Do ALL remaining checklist items in this turn. For each item:
   a. Execute it (write file / run command / verify output)
   b. Update PROGRESS.md checklist `[ ]` → `[x]`
5. Only after ALL items in the task are done:
   - Append MARKER-END to OUTPUT.md
   - Set PROGRESS.md `LAST_COMPLETED: DONE`
6. Before writing to MEMORY.md, back it up:
   `cp MEMORY.md MEMORY.md.bak`
7. End the turn ONLY when done or genuinely blocked. Do not stop
   voluntarily between items just because "one item is done".

## Recovery protocol (interruption / resume)

If you receive a message like "请继续之前的任务" (please continue) or
"resume" without new instructions:
- Read PROGRESS.md. Continue from `LAST_COMPLETED`.
- Do NOT restart from zero.
- Do NOT re-run steps already recorded.
- Do NOT ask what the task is — read TASK.md.

## Drift detection

Before ending a turn, verify:
- [ ] All file writes are inside this workdir
- [ ] OUTPUT.md still starts with `MARKER-START` (if applicable)
- [ ] PROGRESS.md format matches spec
- [ ] No dependencies added that weren't in TASK.md
- [ ] Assistant output is bounded (no infinite loops)

If any check fails, STOP and note the failure in PROGRESS.md NOTES.

## What NOT to do

- Do not open URLs / call APIs outside the workdir
- Do not print your inner monologue to OUTPUT.md
- Do not write MEMORY.md dumps to OUTPUT.md
- Do not commit code unless TASK.md says to
- Do not switch to a different task even if it seems related
