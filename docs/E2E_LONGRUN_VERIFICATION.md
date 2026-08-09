# OpenClicky HeyClicky Free-Tier Long-Run: End-to-End Verification

Date: 2026-07-22
Objective: prove the three targets — 省配额 / 不跑偏 / 长时间不中断 — with log-level evidence.

## Test infrastructure

- OpenClicky app running as `com.jkneen.openclicky` (build pid varied through session).
- External Control Bridge on `127.0.0.1:32123`.
- Automation token via `openClickyExternalControlBridgeToken` UserDefaults.
- All evidence pulled from `/agent/log/tail` — the same log stream that ships with the app.

## T1 — 省配额 (single credit reused across turns)

- Task: build a working Rust `jq-lite` CLI (503 lines, 11 tests, zero-dep). Workdir `/tmp/oc-verify/real-task`.
- Launch: `POST /agent/task/start` with `reasoningEffort=xhigh`.
- Result: DONE with all 12 checklist items ticked, `cargo test` = 11 passed.
- Duration: 4:35 min.

Credit timeline (from log):

```
02:58:02  agents=0/25 msgs=0/25   ← baseline
02:58:38  codex.thread_launch_dispatch                                (free per IDA)
02:58:42  codex.lease_acquired credits_used=1 lease=0239c7aa          (+1 credit)
02:58:43  codex.turn_start_dispatch lease=0239c7aa turn=B4940D3E
02:58:49  agents=1/25 msgs=0/25   ← +1 seen server-side
...
03:02:17  codex.turn_start_dispatch lease=0239c7aa (SAME!) turn=B4940D3E (SAME!) task=DEB22A78 (NEW)
03:02:37  thread_status idle
(entire run agents stays at 1/25)
```

Evidence: **turn 2 reused the same lease + same turn** → codex daemon internally
routed the continuation as a steer, no additional lease acquired, no
`plan.refresh_ok` reported an agents-count increase. Full project done for
one agent credit.

## T2 — 不跑偏 (checklist adherence)

- Same task's `PROGRESS.md` shows `LAST_COMPLETED: DONE` with a 12-item CHECKLIST all `[x]`.
- Cargo.toml `[dependencies]` empty (constraint held).
- Only files inside workdir modified; no writes outside.
- Zero questions posted back to the user (autonomous run).

## T3 — 长时间不中断 (autonomous drive through completion)

Same run.

- Total wall-clock 4:35 min.
- `thread_status active → idle → active → idle` transitions show the daemon
  drove the work to completion inside one lease.
- No watchdog kill, no user prompt, no auto-restart triggered.
- MARKER-END appended to `OUTPUT.md`.

## T4 — 自动错误恢复 (account reset)

- Pre-test credits: `agents=24/25`.
- Triggered `POST /heyclicky/account/reset` with reason `real_dev_task_test`.
- Log timeline:
  ```
  reset.callback_seen  → reset.drive_finished  → reset.completed  → reset.barrier_end
  ```
  all within 1 second.
- Post-reset credits: `agents=0/25 msgs=0/25`.
- Barrier held the pending Codex spawn while the sign-out+in cycle
  completed; no user-visible error surfaced.

## T5 — Free-Tier planning integration (Fable 5 / msgs lane)

New endpoint: `POST /agent/plan/generate`.

- Body: `{ query, systemContext?, saveToPath?, sessionName?, appendToFile? }`
- Returns the model's textual response + optional on-disk save.
- Server routes to whichever free reasoning model the msgs lane exposes.

Single-call test — `query_len=481` → `text_len=2228`:
```
03:11:29  free_planning.request  cost_channel=msgs  query_len=481
03:11:49  free_planning.response text_len=2228
03:11:55  plan.refresh_ok agents=1/25 msgs=0/25    ← no msgs charge either
```

Chained multi-turn test (sessionName threads prior turns into query prefix):
```
03:19:24  free_planning.request  query_len=86    (part 1 — Overview)
03:19:38  free_planning.response text_len=1198  session=tinygrep-arch-1784690364
03:19:38  free_planning.request  query_len=1582  (part 2 — same session, history prepended)
03:19:49  free_planning.response text_len=1428  session=tinygrep-arch-1784690364
03:19:56  plan.refresh_ok agents=2/25 msgs=0/25    ← agents count unchanged; msgs still 0/25
```

Combined DOC.md: 2628 chars, coherent architecture (part 2 correctly
references SQLite/requests/BeautifulSoup named in part 1).

## Integrated flow — Fable plan → Codex build → complete project

`INT-tinygrep` — full pipeline:

1. `/agent/plan/generate` produced a 2.2 KB TASK.md with a 15-item CHECKLIST (0 agent credit, 0 msgs).
2. `/agent/task/start` (workdir contains the Fable-authored TASK.md).
3. Codex daemon copied the CHECKLIST into `PROGRESS.md` verbatim and executed
   each item, `cargo test` = 5 passed.

Timeline:
```
03:13:09  launch INT-tinygrep
03:14:23  agents=2/25 msgs=0/25   ← +1 credit for the Codex lease
03:15:53  agents=2/25 msgs=0/25   ← still 2 mid-run
03:16:54  LAST_COMPLETED: DONE, MARKER-END, 15/15 checklist done
```

Total budget for plan+build+test: **1 agent credit**, 0 msgs, ~3:45 min execution.

## Fixes landed during verification

1. `heyClickyFreePreamble` was calling `setThreadGoal` before the codex
   daemon had spawned. The `hasInitializedProcess` guard made this a silent
   no-op. Moved the `thread/goal/set` dispatch into `ensureThread`, right
   before `turn/start`, where the daemon is guaranteed alive and
   `activeThreadID` is already committed.
2. `extractGoalFromWorkdir` only accepted the plain `GOAL:` prefix. Widened
   it to also accept markdown headers (`# GOAL`, `## GOAL`, `# GOAL:`) and
   stop at either the next markdown header or the next uppercase label.
3. Added the free planning client (`HeyClickyFreePlanningClient`) plus
   bridge endpoints:
   - `POST /agent/plan/generate` — one-shot or session-continuation.
   - `POST /agent/plan/clear` — reset a session.

## Reproducibility

All commands are `curl` against `127.0.0.1:32123` with header
`x-openclicky-token: <token>`. Logs come from `POST /agent/log/tail`
`{ "count": <N> }`. State comes from `POST /agent/session/state`
`{ "sessionID": "<uuid>" }`.
