# Assist Agent Swift-vs-Python parity audit

Reference: `/Users/wowdd1/Dev/heyclicky-agent/heyclicky_agent/`
Port:      `/Users/wowdd1/Dev/openclicky/cursor-buddy/AssistAgent/`

Line refs use `<repo-relative-file>:<line>`. Constants call out both values when they differ. This is a factual diff, not a rewrite plan.

---

## Priority fix list (top 5 highest-impact gaps)

1. **`MICROCOMPACT_KEEP_RECENT` value drift** — Python: `4` (`agent.py:465`). Swift: `6` (`AssistAgentCompaction.swift:25`). Swift keeps 50% more recent bodies before microcompact touches them, so the trigger fires later and prior grows longer than Python. Task description explicitly asks for `MICROCOMPACT_KEEP_RECENT=6`, but the reference is `4` — the Swift value matches the task brief, not the actual Python source.

2. **`_CN_TO_TOOL` table missing 3 entries + all `_TYPE_ALIAS` synonyms** — Python `_CN_TO_TOOL` (`agent.py:131-156`) has 17 keys including `重新获取图片`, `分派并行`, `存记忆`, `读记忆`, `查历史`. Swift `mapCNToTool` (`AssistAgentLoop.swift:256-275`) has 17 too but different set: adds `批量替换`, `URL 内容`, `web_search`, `存记忆`, `读记忆`, `钉记忆`, `历史查询`, `待办列表`; misses `重新获取图片` (image reupload signal), `分派并行` (parallel dispatch — this alone blocks the whole parallel path from working from a canonical CN reply), and `查历史` (renamed to `历史查询`). Also the entire `_TYPE_ALIAS` table (`agent.py:161-188`, 30+ synonyms Fable-5 emits) and `_ARG_ALIAS` table (`agent.py:193-207`, 25+ arg-key aliases) are not implemented in Swift, so any reply using `写入文件` / `编辑文件` / `执行命令` / `读文件` / `path` etc. will fail to dispatch.

3. **Circuit-breaker threshold mismatch and prior-based tracking missing** — Python `_circuit_bump` (`agent.py:1914`) keys on `(round_no, op_kind, err[:80])` and tracks a same-error streak that only trips after evidence-based bumping. Swift (`AssistAgentLoop.swift:210-223`) uses `sameErrorGiveUp = 3` and keys the signature on `kind:summary.prefix(80)`, but Python's threshold in `_circuit_check` is documented to run against a session-wide counter with different reset rules. Consequence: Swift trips 3-in-a-row on almost anything; Python allows richer recovery. Also Swift throws `circuitBreakerTripped` and aborts, while Python emits a nudge round and only aborts after an emergency-hop fails.

4. **Empty-response threshold mismatch + no account hop on empty** — Python (`agent.py:2404-2621`) runs `_try_account_hop` on every empty-response classification of `ceiling` / `cold_start` / `model_stall`, rotates X-Clicky-Session-Id, and only gives up after the hop also comes back empty. Swift (`AssistAgentLoop.swift:97, 138-148`) has `consecutiveEmptyGiveUp = 10` and just retries in place — no session rotation, no account hop, no empty-cause classifier. Any empty run of 10 aborts with `emptyResponseGaveUp`, without exercising the whole self-healing machinery.

5. **Prior builder is a naive concat — no compaction ladder actually applied per-round** — Python `_build_prior` / `_build_prior_with_offload` (`agent.py:963, 1466`) run the full ladder: dedup stale reads, per-step tier assignment (full/medium/oneline), digest injection, microcompact triggers at 30k, hard-budget cascade, factsheet/atlas image offload. Swift `AssistAgentLoop.buildPrior` (`AssistAgentLoop.swift:230-248`) just concatenates `userTask + digest + pinnedMemory + all uncompacted steps`. All the machinery in `AssistAgentCompaction.swift` and `AssistAgentPriorImage.swift` exists but the loop never invokes it. This is the largest behavioural gap — long dialogs will run out of context long before Python does.

---

## agent.py — `AgentSession` dataclass  vs  `AssistAgentSession.swift`

Python `agent.py:301-350`, Swift `AssistAgentSession.swift:17-181`.

- ✅ Core fields match: `user_task`, `steps`, `digest`, `compacted_before`, `pinned_memory`, `server_synced_steps`, `rounds_since_full_baseline`, `force_full_next_round`, `adaptive_resync_interval`, `consecutive_delta_successes`, `resync_history`, `consecutive_empty_at_floor`, `recent_reply_lens`, `last_error_signature`, `same_error_streak`, `total_rotations`.
- ✅ AIMD tuning constants match — Python `agent.py:296-299` (`INCREMENTAL_MIN_RESYNC=2 / MAX=30 / START=3`) = Swift `AssistAgentSession.swift:153-155`.
- ✅ Pinned-memory cap 32 (Python `agent.py:2283`, Swift `AssistAgentSession.swift:118`).
- ✅ Model context table (`_MODEL_CTX_TOKENS`) copied verbatim (Python `agent.py:365-372`, Swift `AssistAgentSession.swift:174-180`).
- ✅ Output-reserve + system-overhead constants match (`_OUTPUT_RESERVE_TOKENS=16_000`, `_SYSTEM_OVERHEAD_TOKENS=12_000`, `_CHARS_PER_TOKEN=4`).
- ⚠️ Swift AIMD helpers `recordDeltaSuccess` (`AssistAgentSession.swift:129`) and `recordDeltaFailure` (`AssistAgentSession.swift:138`) implement the same additive-increase / multiplicative-decrease logic, but the failure branch multiplies by 1/2. Python's failure branch (per doc comment `agent.py:288-292`) also halves — so this matches, however Python's `resync_history` entries are `(interval, outcome_reason_string)` tuples where the reason maps to specific classifier tags (`empty_ceiling` / `refusal` / `memory_loss`). Swift stores whatever `recordDeltaFailure(reason:)` gets called with — but no caller currently invokes it, so the history stays empty in practice.
- ❌ **`plan_task_dir`, `plan_progress_path`, `plan_completion_marker`** — Python `agent.py:345-349`. Swift session comment (`AssistAgentSession.swift:8`) states "no plan-file self-drive markers — that's Stage 7"; the fields are omitted deliberately. This means plan-driven `[free-agent-longrun]` runs cannot be persisted or resumed via Swift.
- ❌ **`AgentEvent.data` kind alignment** — Python events use keys `msg`, `text`, `error`, `round`, `hard_cap`, `marker`, `task_dir`, `steps_kept`, `digest_chars`, plus event kinds `agent.turn_start / turn_end / auto_extend / cap_hit_exit / plan_driven_enter / plan_driven_marker_reached / plan_hard_cap_hit / new_task / plan_driven_fabricate_error`. Swift `AssistAgentEvent` (`AssistAgentEvent.swift:16-25`) only defines 8 kinds (`turn_start / tool_call / tool_result / info / session_hop / compact_boundary / done / error`). All the `plan_*` and `auto_extend / cap_hit_exit` telemetry is absent.

## agent.py — `run()` multi-round loop  vs  `AssistAgentLoop.swift`

Python `agent.py:3083-4542` (~1460 lines), Swift `AssistAgentLoop.swift:117-296` (~180 lines).

- ✅ Basic dispatch skeleton (round loop → transport ask → JSON parse → tool call → append step → done detection) is present.
- ✅ `步骤 == "完成"` exit branch matches (`AssistAgentLoop.swift:162`, Python `agent.py:3720` region).
- ✅ Circuit-breaker signature keyed on kind + short err (`AssistAgentLoop.swift:210-223`).
- ⚠️ **`max_rounds` default** — Python `agent.py:3087` `max_rounds: int = 6`. Swift `AssistAgentLoop.swift:106` `maxRounds: Int = 15`. Different defaults; whichever caller invokes matters, but default-arg behaviour differs.
- ⚠️ Auto-extend semantics — Python (`agent.py:3222-3225`) doubles `cap = max_rounds * 2` on first would-be exit when the last step wasn't `_reminder`, emits `agent.auto_extend` info. Swift has no equivalent; when `maxRounds` hits it throws `.maxRoundsExhausted` (`AssistAgentLoop.swift:225`).
- ⚠️ Consecutive-empty threshold — Python treats 1-2 empties as recoverable via `_try_account_hop` (`agent.py:2404, 2890+`), and only aborts when the emergency hop also fails. Swift (`AssistAgentLoop.swift:97, 144`) uses a fixed count of 10 and has no hop.
- ❌ **`_extract_plan_header` / plan-driven loop** — Python `agent.py:3092, 3097-3145, 3208-3244, 3238` handles `[free-agent-longrun]` header, auto-fabricates OpenSpec bundle via `ensure_plan_files`, reads PROGRESS.md at top of each round, marks steps done, exits on `LAST_COMPLETED` marker, has 500-round `PLAN_DRIVEN_HARD_CAP`. Zero Swift equivalent.
- ❌ **`_try_account_hop`** (`agent.py:2404-2621`) — cross-account rotation on `ceiling` / `cold_start` / `model_stall` / `refusal`. Missing in Swift.
- ❌ **`_try_context_cascade`** (`agent.py:2688`) — micro → digest-trim → deep-microcompact cascade invoked when input_chars nears hard budget. Swift has `assistCompactionCascade` (`AssistAgentCompaction.swift:391`) but the loop never calls it.
- ❌ **`_classify_empty_cause`** (`agent.py:540-599`) — 6-way classifier (`ceiling / network / refusal / cold_start / model_stall / unknown`). Missing.
- ❌ **`_looks_like_memory_loss`** / `_MEMORY_LOSS_PATTERNS` (`agent.py:487, 480-486`) — regex triggers forced-full baseline. Missing.
- ❌ **`_looks_like_refusal`** / `_REFUSAL_PATTERNS` (`agent.py:601-614`, `agent.py:471-478`). Missing.
- ❌ **`_model_proposing_dup`** (`agent.py:493`) — dedup detection for models proposing an already-run step. Missing.
- ❌ **`_persist_step_to_history`, `_persist_session_meta`, `load_session_from_disk`, `list_saved_sessions`** (`agent.py:2116-2237`) — on-disk session log for resumption. Missing.
- ❌ **`_menu_with_mcp`, `_build_query`, `_workspace_block`** — prompt-composition helpers (`agent.py:1707, 1717, 2068`). The Swift transport calls `analyzeVoiceResponse` with `prior + systemPrompt` only; there's no equivalent of the built prompt structure (workspace preamble, MCP tool list injection, plan-status block, delta vs baseline framing).
- ❌ **`_build_prior_with_offload`** — image-offload path (`agent.py:1466`). Swift has `AssistAgentPriorImage` but the loop never sets `priorImage:` on the transport call (`AssistAgentLoop.swift:129`).
- ❌ **`_auto_pin_from_step`** (`agent.py:2301`) — heuristic auto-pin on successful writes/commands. Missing.
- ❌ **`_build_handoff_briefing`** (`agent.py:2332`) — briefing text for account-hop or resumption. Missing.
- ❌ **`_safe_chunk_size`** (`agent.py:1932`) — adaptive write-chunk sizing from `output_budget_hint`. Missing.
- ❌ Turn telemetry — Python emits `agent.turn_start` / `agent.turn_end` / `agent.new_task` / `agent.auto_extend` / `agent.cap_hit_exit` / `agent.cap_exhausted` / `agent.plan_hard_cap_hit`. Swift emits only `turnStart` / `done` / `error` / `info` / `toolCall` / `toolResult`.

## agent.py — `_extract_json` / `_repair_json`  vs  `AssistAgentJSON.swift`

Python `agent.py:615-720`, Swift `AssistAgentJSON.swift:21-144`.

- ✅ Fullwidth punctuation swap — 6-char set exact match (`agent.py:626-633` = `AssistAgentJSON.swift:27-32`): `：` `，` `“` `”` `‘` `’`.
- ✅ Trailing-comma regex `,(\s*[}\]])` identical (`agent.py:637` = `AssistAgentJSON.swift:35`).
- ✅ Escape-newlines state machine: same logic, mirrored exactly (`agent.py:643-671` = `AssistAgentJSON.swift:44-72`).
- ✅ Code-fence unwrap regex ``` ```(?:json)?\s*(.*?)\s*``` ``` (`agent.py:684` = `AssistAgentJSON.swift:93`).
- ✅ Balanced-brace scan with strict pass first, then tolerant on the whole text (`agent.py:687-712` = `AssistAgentJSON.swift:102-127`).
- ⚠️ Error signalling — Python raises `ValueError` with a 200-char preview (`agent.py:718`); Swift returns `nil` and the loop emits an `.error` event with `preview` (`AssistAgentLoop.swift:154-158`). Behavioural parity, different surface.
- ⚠️ Swift `scanBalanced` resets `startIdx` on decode failure of a candidate and continues (`AssistAgentJSON.swift:118-122`); Python `_scan` resets `depth=0; start=-1` and continues the outer loop (`agent.py:707-710`). Both continue searching for a later object, but Swift's loop uses `parseOne` which internally already tried the repair pass on the CANDIDATE, then the tolerant outer pass repairs the whole string — Python only tries `_repair_json(candidate)` and then `_repair_json(text)`. Same effective coverage.

## agent.py — compaction helpers  vs  `AssistAgentCompaction.swift`

Python `agent.py:946-2762` (dispersed), Swift `AssistAgentCompaction.swift:1-411`.

- ✅ `_compact_json_string(budget=2000)` — Python `agent.py:1077`, Swift `AssistAgentCompaction.swift:58`. Depth cap 6, 100-char string threshold, 5-item array threshold, `head_n=0.7*budget, tail_n=0.25*budget` — all match.
- ✅ `_compact_diff(budget=2000)` — matches; keeps `@@`, `---`, `+++`, `+`, `-` lines; head 0.6 / tail 0.3 on overflow.
- ✅ `_compact_stdout(budget=3000)` — `NOISE_PATTERNS_ALL` (`^\s*$`, `^\x1b\[`) and full `NOISE_BY_TOOL` dict (pytest 10 patterns, xcodebuild 11, npm 3, cargo 4, git 2) match line-for-line (`agent.py:1153-1191` = `AssistAgentCompaction.swift:128-147`).
- ✅ Timestamp / UUID / addr regexes match verbatim.
- ✅ `_compact_source(budget=4000)` — `_SKELETON_BY_EXT` regex sets match for js/ts/rs/go/py/swift. Swift maps jsx→js, tsx→ts (`AssistAgentCompaction.swift:281-285`) same as Python `agent.py:1264-1265` `tsx: None → same as ts`.
- ✅ `_dedup_stale_reads` — Python (`agent.py:946-960`) picks the newest read per path. Swift (`AssistAgentCompaction.swift:36-51`) does the same, additionally counts `file_outline` alongside `read_file`.
- ✅ `_microcompact_session` — Python (`agent.py:2721`) clears old tool_result bodies while keeping last-N; skips `EDIT_KINDS`. Swift (`AssistAgentCompaction.swift:322-349`) mirrors.
- ✅ `_trim_digest_if_bloated` — snap-to-newline within 200 chars matches (Python `agent.py:2650-2687`, Swift `AssistAgentCompaction.swift:368-384`).
- ✅ `_compute_digest_keep_target` — same bounds `[3000, 15000]`, same hard-cap `0.06 * priorCharBudget`, same additive formula `6000 + min(3000, task*8) + min(4000, steps*300) - min(2000, pinned*100)`.
- ⚠️ **`MICROCOMPACT_KEEP_RECENT`** — Python `agent.py:465` = `4`. Swift `AssistAgentCompaction.swift:25` = `6`. Delta.
- ⚠️ **`EDIT_KINDS`** — Python `agent.py:450` = `{"写入完成", "局部替换", "差量应用"}` (3 kinds). Swift `AssistAgentCompaction.swift:28` = 5 kinds (adds `追加片段`, `批量替换`). This is a behavioural improvement but a divergence; edit-body preservation is broader in Swift.
- ⚠️ **`DIGEST_MAX_CHARS`** — matches at 20_000 (`agent.py:437`, `AssistAgentCompaction.swift:24`) ✅. `DIGEST_FOLD_TARGET=8000` (`agent.py:438`) — no Swift counterpart because the "fold-of-folds" summariser (`_compact_session` Python `agent.py:2763`) isn't ported.
- ⚠️ **`KEEP_RECENT_MIN`** — matches at 3 ✅.
- ⚠️ **`SOFT_BUDGET / HARD_BUDGET`** — Python `agent.py:432-433` = `20_000 / 42_000`. Swift computes via `AssistAgentBudget.priorCharBudget` (`AssistAgentSession.swift:168-172`) using `(200_000 − 16_000 − 12_000) * 4 = 688_000` chars. These are different concepts — Python's is a measured probe-based ceiling, Swift's is model-window-derived. Consequence: `assistCompactionComputeDigestKeepTarget` (`AssistAgentCompaction.swift:354`) computes a `hardCap = 0.06 * 688000 ≈ 41_280` which happens to be close to Python's `hard=42000`, so the ceiling roughly agrees; but downstream Swift never uses the Python `SOFT_BUDGET=20_000` micro-trigger threshold.
- ⚠️ **`MICROCOMPACT_TRIGGER = 30_000`** — Python `agent.py:464`. Not present in Swift; the loop never calls `assistCompactionCascade`. Trigger threshold is defined nowhere in Swift.
- ⚠️ `_compact_python_via_ast` (`agent.py:1312`) — AST-based Python skeletonizer. Swift has no AST path; falls through to the regex skeleton in `_SKELETON_BY_EXT["py"]`. Consequence: less-precise skeletons on Python files, but still valid output.
- ❌ **`_compact_session`** (`agent.py:2763`) — model-summarisation compaction (asks the LLM to summarise the head of `steps` into `digest`). Missing in Swift. Without this, `digest` can never actually grow — only the microcompact clears bodies, but no summarisation ever fills `digest`.
- ❌ **`_blobify_result`** (`agent.py:1418`) — extracts big blobs and re-writes summaries. Missing.
- ❌ **`_build_local_rotation_digest`** (`agent.py:2238`) — pre-hop briefing. Missing.

## tools.py — full built-in tool set  vs  `AssistAgentTools.swift`

Python `tools.py:1-956`, Swift `AssistAgentTools.swift:1-674`.

- ✅ `read_file` — `OUTLINE_THRESHOLD_BYTES=8000` (`tools.py:31` = `AssistAgentTools.swift:24`), `OUTLINE_HEAD_LINES=25` (`tools.py:32` = `AssistAgentTools.swift:25`), offset/length slicing, outline hint text.
- ✅ `file_outline`, `list_dir`, `glob` (via `/usr/bin/find`), `grep` (via `/usr/bin/grep -rn`).
- ✅ `write_file` cap 1500 chars (`tools.py:142, 156, 184` = `AssistAgentTools.swift:26, 186-189`). Message wording matches ("use append_chunk").
- ✅ `edit_file` — unique-match requirement; ambiguous-hit error; hits=0 error (Python `tools.py:189-224`, Swift `AssistAgentTools.swift:215-247`).
- ✅ `append_chunk` — 30 s content-hash dedup window (Python `tools.py:222-268`, Swift `AssistAgentTools.swift:27, 261-273`). Sha1(chunk) sig; per-path bucket; identical-chunk-within-window returns success no-op.
- ✅ `apply_diff` via `/usr/bin/patch -p0`.
- ✅ `run_shell` via `/bin/zsh -lc`, default timeout 60s (Python `tools.py:384-468`, Swift `AssistAgentTools.swift:298-309`). Python uses 60s default; Swift default matches.
- ✅ `http_get` — 20s timeout, custom User-Agent.
- ✅ `web_search` — returns marker/hint, no local backend (matches Python `_builtin_search` semantic `tools.py:751-774`).
- ✅ `save_memory` / `read_memory` — JSONL append at a per-user memory file. Swift uses `Application Support/OpenClicky/heyclicky-agent-memory.jsonl` (`AssistAgentTools.swift:28-30`); Python uses `~/.heyclicky-agent/memory.jsonl` (see `tools.py:660-682`). Path differs but semantic matches.
- ✅ `multi_edit` — atomic multi-edit with rollback on any failure, `replace_all` flag, ambiguous-hit rollback (Python `tools.py:613-658`, Swift `AssistAgentTools.swift:440-500`).
- ✅ `query_history` — reads `~/.heyclicky-agent-history/*.jsonl`, case-insensitive substring, limit 5 default. Matches Python `tools.py:683-750`.
- ✅ `todo_write` — parses JSON, stores in-memory list, rewritten wholesale (Python `tools.py:776-805` matches Swift `AssistAgentTools.swift:596-616`).
- ⚠️ `web_fetch` — Python has separate `_web_fetch` (`tools.py:487-518`) that returns simplified prose (curl+trafilatura pipeline). Swift aliases `web_fetch` to `handleHttpGet` (`AssistAgentTools.swift:62`). Consequence: Swift returns raw HTML; Python returns text-extracted body.
- ⚠️ `pin_memory` — Swift returns a signal (`AssistAgentTools.swift:373-381`) but the loop doesn't inspect `raw` to call `session.pinMemory(fact:)`. Python (`tools.py:579-604`) uses `PENDING_PINS` module-global consumed by `_auto_pin_from_step`. So `pin_memory` is dispatched but not effective.
- ❌ **`dispatch_parallel`** — Python `tools.py:806-857` wires the CN kind and calls `run_parallel`. Swift `AssistAgentTools.swift:69-72` returns `unknown_tool: dispatch_parallel`. Cross-agent parallelism cannot be invoked from a model reply.
- ❌ **`ask_user`** — Python `tools.py:556-577` prints a question and blocks on stdin. Swift `AssistAgentTools.swift:69` returns unknown. No `ask_user` dispatch route in the App (would need UI wiring anyway).
- ❌ **`_reupload_image`** — Python treats `重新获取图片` as a marker (see `_CN_TO_TOOL` `agent.py:145`). No Swift dispatch.
- ❌ Chinese-alias tool names — Python `tools.py:860-887` registers `写待办 / 批量编辑 / 获取网页 / 搜索网络 / 问用户 / 钉住记忆`. Swift dispatcher (`AssistAgentTools.swift:49-72`) has no CN keys; the CN→EN translation happens exclusively in `mapCNToTool` at the loop level, so a canonical Swift call always uses EN tool names. Python has both surface paths open.
- ⚠️ `pin_memory` cap — Python `tools.py:579` caps at 32 pins via `PENDING_PINS` list. Swift `AssistAgentSession.swift:118-125` also caps at 32. ✅
- ⚠️ `_dispatch_parallel` args unmarshalling — Python parses `tasks_json` string into typed `SubTask` list (`tools.py:806-857`). No Swift path.

## parallel.py  vs  `AssistAgentParallel.swift`

Python `parallel.py:1-336`, Swift `AssistAgentParallel.swift:1-160`.

- ✅ Nested-dispatch guard — Python `parallel.py:40-49` uses threading.local `_IN_DISPATCH`; Swift uses `TaskLocal AssistAgentParallelContext.inDispatch` (`AssistAgentParallel.swift:81-83, 103`). Same effect.
- ✅ Account-rotation cadence — Python `parallel.py:293-297` `accounts[i % len(accounts)]`; Swift `AssistAgentParallel.swift:120-122` `pool[i % pool.count]`.
- ✅ Cooldown-aware sort before allocation — Python `parallel.py:279-286` sorts by `(last_used ASC, -exported_at)`. Swift `AssistAgentParallel.swift:109` uses `AssistAgentAccounts.loadAll()` without the pre-sort — the loop's own credential rotation just walks the list in filesystem order (plus primary), no last-used weighting.
- ✅ `mark_account_used` before running (Python `parallel.py:290-295`, Swift `AssistAgentParallel.swift:137`).
- ⚠️ Concurrency cap — Python has no explicit cap; it spawns one thread per task without limit (`parallel.py:293-308`). Task prompt in `agent.py:55` says "最多 8 个并行任务". Swift enforces `maxConcurrent = 8` (`AssistAgentParallel.swift:91, 117`). Swift is stricter; Python relies on caller not exceeding 8.
- ⚠️ SubTask/SubResult field names — Python `parallel.py:60-77` uses `task_id, elapsed_sec, files_touched, final_text, error`. Swift `AssistAgentParallel.swift:20-43` uses `id, elapsedSec, filesTouched, finalText, errorText`. Same shape, camelCase.
- ⚠️ `_snapshot_files` — Python `parallel.py:246-266` snapshots workdir mtimes before + after run to compute `files_touched`. Swift's runner protocol just returns `filesTouched` — the concrete implementation would need to do this snapshotting. No implementation is present.
- ❌ **Per-account client rotation of `X-Clicky-Session-Id`** — Python `parallel.py:104-118` `make_client(account, rotate_session=True)`. Swift has no client factory; the runner protocol `AssistAgentSubagentRunner.run(task:credential:)` is abstract and no concrete implementation exists in the repo.
- ❌ **Sub-agent workdir thread-local** — Python `parallel.py:51-58` `current_workdir()` reads `_SUBAGENT_WORKDIR.value` so tools resolve paths against sub-agent's cwd. Swift has no equivalent; tools resolve against process cwd via `NSString.expandingTildeInPath`. If the App eventually implements parallel dispatch, absolute paths must be used in every sub-task.
- ❌ **`_emit` observability** — Python emits `parallel.dispatch.begin` / `parallel.dispatch.end`. Swift emits nothing.
- ❌ **`_short_display_name`** — Python `parallel.py:234-244` builds a `<taskid>[email]` label. Swift doesn't compute one.

## planner.py  vs  `AssistAgentPlanner.swift`

Python `planner.py:1-453`, Swift `AssistAgentPlanner.swift:1-272`.

- ✅ `FILE_SEP = "---FILE-SEPARATOR---"` (`planner.py:28` = `AssistAgentPlanner.swift:20`).
- ✅ `PLAN_SYSTEM` prompt body — matches paragraph-for-paragraph including the "5-15 tasks total", "grouped meaningfully", "End with a verification group", "PROGRESS.md Steps ... same wording — the two views must never drift", "Do NOT wrap in code fences" rules.
- ✅ `strip_bundle_header` — Python `planner.py:180-194` strips ``` fences and `=== <filename>` prefix; Swift `AssistAgentPlanner.swift:108-125` mirrors exactly.
- ✅ `validate_bundle` — all 8 checks match (proposal sections, tasks `## `, tasks checkbox count ≥3, tasks numbering, progress `# Task` / `## Steps` / `LAST_COMPLETED`, progress checkbox count ≥3, progress numbering, tasks-vs-progress numbering equality with missing/extra diff).
- ✅ `_TASK_NUMBER_RE = -\s*\[\s\]\s*(\d+(?:\.\d+)*)` (`planner.py:30` = `AssistAgentPlanner.swift:146-148`).
- ✅ `fallback_bundle` — Python `planner.py:259-293` verbatim = Swift `AssistAgentPlanner.swift:209-251`. Same 3 groups (Understand / Execute / Verify), same numbering.
- ✅ `looks_like_openspec_change` — proposal.md AND (tasks.md OR specs/) — matches (`planner.py:100-111` = `AssistAgentPlanner.swift:88-104`).
- ✅ `codex_task_dir` returns `<cwd>/.openclicky/task/` — matches.
- ❌ **`collect_goal_payload`** (`planner.py:114-170`) — file / dir / OpenSpec-change / multi-md-concatenation with 50_000-char cap. Swift has no equivalent — planner cannot ingest directory-style goals.
- ❌ **`fabricate_openspec_bundle`** (`planner.py:296-359`) — 1 planner call + 1 retry with `_retry_prompt`, falls back to `fallback_bundle` on failure. Swift has `fallback` and `splitBundle` but no fabricator that actually calls the LLM. `AssistAgentPlanner.write` writes to disk, but nothing invokes the model.
- ❌ **`write_openspec_bundle`** (`planner.py:366-410`) — writes `SOURCE_INPUT.md` and mirrors `specs/` from source dir. Swift `write` (`AssistAgentPlanner.swift:257-271`) writes only the 3 core files. `SOURCE_INPUT.md` and `specs/` mirror are missing.
- ❌ **`ensure_plan_files`** (`planner.py:417-453`) — the auto-fabricate-on-boot entry called by `agent.run()` when plan-driven mode starts. Missing.
- ❌ **`_retry_prompt`** (`planner.py:248-256`). Missing.
- ⚠️ `Bundle` split — Swift requires exactly 3 parts (`AssistAgentPlanner.swift:137`); Python is more lenient and re-prompts on wrong segment count (`planner.py:333-343`).

## native_render.py + _atlas_data.py + pxpipe.py  vs  Atlas/PriorImage/Factsheet

Python `native_render.py:1-281`, `pxpipe.py:1-190`, `_atlas_data.py` (data blob). Swift `AssistAgentAtlas.swift:1-156`, `AssistAgentPriorImage.swift:1-234`, `AssistAgentFactsheet.swift:1-42`.

- ✅ Geometry constants — `CELL_W=5`, `CELL_H=8`, `ASCENT=7` (Python `native_render.py:19-21`, Swift `AssistAgentAtlas.swift:45`). ✅
- ✅ `MAX_HEIGHT_PX=728`, `PAD_X=4`, `PAD_Y=4`, `COLS=312`, `PAGE_WIDTH_PX = 4 + 2 + 312*5 = 1568` (Python `native_render.py:40-44`, Swift `AssistAgentPriorImage.swift:21-27`).
- ✅ JPEG quality 0.65 (Python `native_render.py:206, 232, 251, 256`, Swift `AssistAgentPriorImage.swift:83`).
- ✅ Newline glyph fallback U+21B5 else `<` (Python `native_render.py:59-64`, Swift `AssistAgentPriorImage.swift:186-190`).
- ✅ Section cache with 12 entries LRU (Python `_SECTION_CACHE_MAX = 12` `native_render.py:161`, Swift `cacheMax = 12` `AssistAgentPriorImage.swift:34`).
- ✅ Binary-search `rank_of` with fallback to `-1`. Swift `AssistAgentAtlas.swift:110-118` mirrors Python `native_render.py:31-38` — same algorithm and edge cases.
- ✅ Wide-flag bit-packed MSB-first (Python `native_render.py:75-89`, Swift `AssistAgentAtlas.swift:121-126`).
- ✅ Factsheet regex — 5-branch alternation for unix path / win path / URL / hash-ish / filename with common ext (Python `pxpipe.py:87-94`, Swift `AssistAgentFactsheet.swift:16-22`) — matches character-class-for-character-class.
- ✅ Factsheet cap: 60 items, dedup, 200-char length skip (Python `pxpipe.py:100-102`, Swift `AssistAgentFactsheet.swift:26, 35, 38`).
- ⚠️ Atlas source — Python uses `_atlas_data.py` (11 653 lines of Python literals, `NUM_GLYPHS len(_atlas.CODEPOINTS) // 4`). Swift loads a binary file `assist_agent_atlas.bin` with magic `OCATLAS1` (`AssistAgentAtlas.swift:44`). Build step to generate the `.bin` from the Python data is referenced in comments but must be verified — if the bin isn't generated, `AssistAgentAtlas.loaded == false` and every rendered section falls through to an 8-byte placeholder.
- ⚠️ Placeholder on empty pages — Swift emits `Data(repeating: 0xFF, count: pageWidthPx * 8)` (`AssistAgentPriorImage.swift:65`); Python `native_render.py:200+` short-circuits to no image. Cosmetic.
- ❌ **`pxpipe.py::_find_cli` / Node fallback path** (`pxpipe.py:39-49, 105+`) — Python attempts a `pxpipe` Node CLI when the native renderer fails. Swift has no CLI fallback; native-only.
- ❌ **`is_available`** helper (`pxpipe.py:175`) — Swift equivalent is `AssistAgentAtlas.shared.loaded` but there's no top-level `AssistAgentPriorImage.isAvailable()` accessor.

## mcp.py  vs  `AssistAgentMCP.swift`

Python `mcp.py:1-407`, Swift `AssistAgentMCP.swift:1-247`.

- ✅ Protocol version `2025-06-18` (Python `mcp.py:68, 195`, Swift `AssistAgentMCP.swift:72`).
- ✅ `clientInfo.name` = openclicky-assist-agent / heyclicky-agent respectively; version 0.1.
- ✅ `notifications/initialized` sent post-init.
- ✅ `tools/list` and `tools/call` used with same JSON-RPC 2.0 framing.
- ✅ Config path — Python uses env-var/default, Swift reads `~/.heyclicky-agent/mcp.json` (`AssistAgentMCP.swift:196`). Python `mcp.py:324-370` registry initializes from the same file layout `{"servers": {...}}`.
- ⚠️ Transport — Python has both `MCPServerHTTP` (`mcp.py:51-160`) and `MCPServerProc` (stdio) (`mcp.py:161-322`). Swift has stdio only (`AssistAgentMCP.swift:40-178`). File comment (`AssistAgentMCP.swift:16`) states this deliberately. HTTP MCP servers cannot be attached.
- ⚠️ Newline framing — Python `MCPServerProc._read` reads Content-Length-framed frames per MCP spec (see `mcp.py:290-320`). Swift `ingest()` (`AssistAgentMCP.swift:162-177`) reads raw newline-delimited JSON. If a server sends `Content-Length` headers per MCP official spec, Swift parsing will fail on the first frame. Real-world MCP stdio servers vary — many use line-delimited JSON, but strict spec-compliant ones use LSP-style headers.
- ⚠️ Read loop — Swift `readLoop` (`AssistAgentMCP.swift:153-159`) polls `availableData` in a busy loop with 20 ms sleep; Python uses blocking `readline`. Cosmetic perf difference.
- ❌ **Tool schema translation to menu** — Python `mcp.get_registry().all_tools()` composes a menu block used inside `_menu_with_mcp` (`agent.py:1707`). Swift registry has `allTools()` (`AssistAgentMCP.swift:224`) but no consumer calls it — the loop never injects MCP tools into the system prompt or dispatch table.

## registry.py  vs  `AssistAgentRegistry.swift`

Python `registry.py:1-225`, Swift `AssistAgentRegistry.swift:1-127`.

- ✅ Main + sub distinction. Swift `Entry.label` maps to Python `display_name`.
- ✅ Event ingestion updates `tool_uses` counter (Python `registry.py:125-127`, Swift `AssistAgentRegistry.swift:59-64`).
- ✅ Event log bounded — Python caps events at 500 (`registry.py:152-153`); Swift compacts by age with `keepSec=300` (`AssistAgentRegistry.swift:80-85`). Different mechanism, similar goal.
- ⚠️ Swift uses `UUID` keys; Python uses string `agent_id` ("main" or sub `task_id`). Cross-cutting: Swift can't refer to sub-agents by their `SubTask.id` — the parallel dispatcher would have to bridge that.
- ❌ **`archived_ids`** (`registry.py:49, 105`) — separate archive list so `/attach <id>` can page back into finished sub logs. Swift lumps everything into `agents` and drops via `compact()`.
- ❌ **`focused_id` / focus API** (`registry.py:50, 159-188`) — TUI-only concept, N/A for the App UI. Cosmetic omission.
- ❌ **Per-event body accumulation** — Python stores full event history per entry (`registry.py:37, 116-121`); Swift only stores `lastMessage`. No paging back into a sub-agent's transcript.
- ❌ **`tokens` counter** — Python approximates tokens as `chars/4` per event (`registry.py:127, 144-147`). Swift has `toolsRun` but no token estimate.
- ❌ **Thread-safety** — Python uses `threading.Lock`. Swift is `@MainActor`-isolated. Equivalent in effect.

## self-test loop — `AssistAgentTestRunner.swift`

New module (no Python counterpart file). Task brief calls it out as "(new) self-test loop".

- No corresponding Python module — cannot diff.
- Swift `AssistAgentTestRunner.swift:54` uses `sameFailureGiveUp = 3` — matches the Python `circuit_breaker` threshold in `agent.py:2900+` area.
- Parses pytest / swift / go / npm test output (`AssistAgentTestRunner.swift:139-200`) — no Python analogue.
- ⚠️ Not invoked from `AssistAgentLoop` — this is a standalone helper the App can call, not part of the tool dispatcher.

## main-dialog wiring — `AssistAgentPrompt.swift` + `AssistAgentBridge.swift`

New wiring modules — task brief calls this out as "(new) main-dialog wiring".

- No direct Python counterpart. The Python CLI drives the loop directly; the Swift App inserts a `[ASSIST] {...}` marker into the main dialog reply and post-processes it in `AssistAgentBridge.handleModelReply` (`AssistAgentBridge.swift:58`).
- ✅ Marker + JSON schema `{"goal", "workdir", "max_rounds"}` (`AssistAgentPrompt.swift:51`).
- ✅ `max_rounds` clamped to `[1, 15]` (`AssistAgentPrompt.swift:110`).
- ✅ Barge-in cancellation via `cancelActive()` (`AssistAgentBridge.swift:73`).
- ⚠️ Effective system prompt gate on `AppBundleConfiguration.assistAgentEnabled()` (`AssistAgentPrompt.swift:72, AssistAgentBridge.swift:61`). No Python parallel.
- ⚠️ Bridge passes an empty tool set / no plan header — the assist agent is spawned with the default `AssistAgentBuiltInTools()` and a manually-written system prompt (`AssistAgentBridge.swift:150-155`). It bypasses the Python `_menu_with_mcp` / `_build_query` full-context prompt construction.

---

## Constants reference table

| Constant                       | Python (`agent.py` / other) | Swift                                            | Status |
|---                             |---                          |---                                               |---     |
| `DIGEST_MAX_CHARS`             | 20_000 (`agent.py:437`)     | 20_000 (`AssistAgentCompaction.swift:24`)        | ✅     |
| `DIGEST_FOLD_TARGET`           | 8_000 (`agent.py:438`)      | —                                                | ❌     |
| `MICROCOMPACT_KEEP_RECENT`     | 4 (`agent.py:465`)          | 6 (`AssistAgentCompaction.swift:25`)             | ⚠️     |
| `MICROCOMPACT_TRIGGER`         | 30_000 (`agent.py:464`)     | —                                                | ❌     |
| `KEEP_RECENT_MIN`              | 3 (`agent.py:418`)          | 3 (`AssistAgentCompaction.swift:26`)             | ✅     |
| `SOFT_BUDGET`                  | 20_000 (`agent.py:432`)     | derived per-model                                | ⚠️     |
| `HARD_BUDGET`                  | 42_000 (`agent.py:433`)     | derived per-model (`≈41 280` for 200k)           | ⚠️     |
| `INCREMENTAL_MIN_RESYNC`       | 2 (`agent.py:296`)          | 2 (`AssistAgentSession.swift:153`)               | ✅     |
| `INCREMENTAL_MAX_RESYNC`       | 30 (`agent.py:297`)         | 30 (`AssistAgentSession.swift:154`)              | ✅     |
| `INCREMENTAL_START_RESYNC`     | 3 (`agent.py:298`)          | 3 (`AssistAgentSession.swift:155`)               | ✅     |
| `EMPIRICAL_EMPTY_CEILING_CHARS`| 45_000 (`agent.py:445`)     | —                                                | ❌     |
| `EMPIRICAL_EMPTY_WARN_CHARS`   | 42_000 (`agent.py:446`)     | —                                                | ❌     |
| `MEDIUM_RESULT_CHARS`          | 500 (`agent.py:457`)        | —                                                | ❌     |
| `FULL_RESULT_CHARS`            | 3000 (`agent.py:458`)       | —                                                | ❌     |
| `COMPACT_KEEP_RECENT`          | 5 (`agent.py:459`)          | —                                                | ❌     |
| `OUTLINE_THRESHOLD_BYTES`      | 8_000 (`tools.py:31`)       | 8_000 (`AssistAgentTools.swift:24`)              | ✅     |
| `OUTLINE_HEAD_LINES`           | 25 (`tools.py:32`)          | 25 (`AssistAgentTools.swift:25`)                 | ✅     |
| `write_file` cap               | 1500 (`tools.py:142, 156`)  | 1500 (`AssistAgentTools.swift:26`)               | ✅     |
| `_APPEND_DEDUP_WINDOW_SEC`     | 30.0 (`tools.py:222`)       | 30 (`AssistAgentTools.swift:27`)                 | ✅     |
| CELL_W / CELL_H / ASCENT       | 5 / 8 / 7                   | 5 / 8 / 7 (`AssistAgentAtlas.swift:45` default)  | ✅     |
| `MAX_HEIGHT_PX`                | 728                         | 728 (`AssistAgentPriorImage.swift:21`)           | ✅     |
| `COLS`                         | 312                         | 312 (`AssistAgentPriorImage.swift:24`)           | ✅     |
| `PAD_X` / `PAD_Y`              | 4 / 4                       | 4 / 4 (`AssistAgentPriorImage.swift:22-23`)      | ✅     |
| JPEG quality                   | 0.65                        | 0.65 (`AssistAgentPriorImage.swift:83`)          | ✅     |
| Section cache max              | 12                          | 12 (`AssistAgentPriorImage.swift:34`)            | ✅     |
| Factsheet cap                  | 60 items / 200 chars        | 60 / 200 (`AssistAgentFactsheet.swift:26, 35`)   | ✅     |
| `default max_rounds`           | 6 (`agent.py:3087`)         | 15 (`AssistAgentLoop.swift:106`)                 | ⚠️     |
| Plan-driven hard cap           | 500 (`agent.py:3237`)       | —                                                | ❌     |
| MCP protocol version           | 2025-06-18                  | 2025-06-18 (`AssistAgentMCP.swift:72`)           | ✅     |
| `AssistAgentParallelDispatcher.maxConcurrent` | none (advisory 8) | 8 (`AssistAgentParallel.swift:91`)         | ⚠️     |
| Pinned-memory cap              | 32                          | 32 (`AssistAgentSession.swift:118`)              | ✅     |
| MCP config path                | `~/.heyclicky-agent/mcp.json` | `~/.heyclicky-agent/mcp.json`                  | ✅     |
