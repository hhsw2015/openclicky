# OpenClicky Task Planning Contract

Openclicky spawns codex to drive a task to completion. This doc defines the
files openclicky expects at a fixed path so external planning skills (in
Claude Code or elsewhere) can hand off cleanly.

## Task directory (two variants)

**A. Workdir-anchored (long-running, project-scoped)**

    <workdir>/.openclicky/task/

Where <workdir> is:
- A folder the user has selected in Finder, OR
- The frontmost app's project root (auto-detected via ProjectRegistry).

**B. Standalone (short-running, no workdir context)**

    ~/OpenClicky/<slug>/

Where <slug> is a kebab-case name the openclicky dialog model picks based on
the user's request. Falls back to `yyyy-MM-dd-HHmm-<random6>` if no slug.

One workdir has ONE active long task at a time (variant A). Standalone tasks
(variant B) can coexist, each in its own subdirectory of ~/OpenClicky/.

## Required file

**PROGRESS.md** - openclicky's F28 auto-continue observer polls this file
for the completion marker `LAST_COMPLETED: DONE` on its own line, matching
the case-sensitive regex `^\s*LAST_COMPLETED:\s*DONE\s*$`.

Recommended layout:

    ## Checklist
    - [ ] step 1
    - [ ] step 2
    ...
    - [ ] step N

    LAST_COMPLETED:

Codex is expected to:
- Work through the checklist in order.
- Update `- [ ]` -> `- [x]` as items complete.
- Append `LAST_COMPLETED: DONE` when finished.

## Optional files (all read by codex as background)

Anything else in the task directory is fair game. Codex globs the whole
directory on spawn. Examples:

    SPEC.md            - canonical task specification
    REQUIREMENTS.md    - original user requirements
    DESIGN.md          - architecture / decisions
    reference/*.md     - supporting notes
    screenshots/*.png  - UI mockups
    api-schema.json    - interface contract
    diagrams/*.svg     - architectural diagrams

Every file here is task context; codex absorbs before acting.

## Environment openclicky sets on codex spawn

    OPENCLICKY_TASK_DIR       absolute path to the task directory
    OPENCLICKY_TASK_PROGRESS  absolute path to PROGRESS.md

Codex is instructed to:
1. Glob $OPENCLICKY_TASK_DIR/**/* and read all readable files.
2. Drive $OPENCLICKY_TASK_PROGRESS to completion.

## Auto-generated planning

If openclicky decides a task is warranted but no PROGRESS.md exists at the
resolved path, it runs an internal 3-round dialog-model loop to fabricate
PROGRESS.md (plus a lightweight SPEC.md). The user never sees this loop -
it's a background API cycle, not part of the voice conversation.

External planning skills override this fallback by pre-writing PROGRESS.md
(plus any supporting files) to the resolved path before the user asks
openclicky to run.

## Short tasks

There is no separate "short_task" pipeline. `kind == task` always runs the
same drive loop; the two entry paths (workdir-anchored vs standalone) differ
only in the resolved task directory. Users can pre-plan with a Claude Code
skill (variant A) or let openclicky fabricate on demand (variant B).
