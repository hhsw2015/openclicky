# Phase 5 — Meta tools port (report, 2026-07-23)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift`
  (new single-file port; `MetaToolRegistry`, `OpenClickyBM25Index`, gates,
  `MetaToolDispatchDelegate`, `MetaToolError`).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/OpenClickyMetaToolsTests.swift`
  (19 XCTest cases; all passing).
- Appended value types to
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`:
  `MetaToolDescriptor`, `DomainInfo`, `ScoredToolMatch`, `BatchStep`,
  `BatchResult`, `StrategyNote`.
- `docs/ROADMAP/.impl-notes/phase5-metatools-2026-07-23.md` (investigation
  notes).

## Tool count + domain enumeration

Domain roster (9 domains, per task spec + `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md`):
`core`, `browser`, `terminal`, `finder`, `whiteboard`, `doc_readers`,
`web`, `memory`, `orchestrate`. `core` is always active
(parallel to Everywhere's `SearchTierTools`).

Registered meta-tool surface (7 primary + 2 utilities):
- `list_more_tools(category?)`
- `search_tools(query, top_k?)`
- `activate_domain(name)`
- `list_domains`
- `call_tool(name, arguments_json?)`
- `batch(steps)` (returns `[BatchResult]`; wire envelope is bridge concern)
- `strategy_note_write` / `strategy_note_get` (validation exposed via
  `validateStrategyNote(_:)`; persistence lives in the memory store per
  Everywhere `GateTools.cs`).

Registry has no hardcoded roster of concrete sensor tools — the bridge
registers descriptors at boot. Tests exercise a 20-tool sample covering
every domain to prove BM25 + gate behaviour.

## BM25 parameters (Everywhere parity)

- `k1 = 1.5`, `b = 0.75`.
- IDF = `log(1 + (N - df + 0.5) / (df + 0.5))`.
- Tokenizer: lowercase then split on non-alphanumeric via
  `Character.isLetter || .isNumber` (matches
  `Bm25Index.cs:60-71` `IsLetterOrDigit` semantics for the
  ASCII + BMP range used by tool names).
- No stemming, no stop-words.
- Score sums per query token over `posting[docIdx]`; docs with zero
  matches are excluded (Everywhere behaviour — `scores` dict only
  populated on posting hit).

## Env var mapping

| Everywhere | Openclicky | Semantics |
|---|---|---|
| `EVERYWHERE_MCP_FULL=1` | `OPENCLICKY_MCP_FULL=1` | Disable core-tool gate (all tools visible in `tools/list`) |
| `EVERYWHERE_MCP_SELFEXPAND=0` | `OPENCLICKY_MCP_SELFEXPAND=0` | Force self-expand tools to return `SELFEXPAND_DISABLED` |
| `EVERYWHERE_MCP_OPENCLI=0` | (not ported) | OpenCLI adapter runtime — not applicable to openclicky sensor |

Both gates read env on every access (Everywhere caches via `Lazy<bool>`
but Openclicky avoids the cache so tests can override via `setenv` in
the same process without a special test hook). SelfExpandGate default
is ON; only the literal `"0"` opts out — parity with
`SelfExpandGate.Enabled` (`OpenCli/Observation/SelfExpandGate.cs:14-22`).

## Session activation persistence

Everywhere keeps per-HTTP-session state in
`ConcurrentDictionary<string, ConcurrentDictionary<string, byte>>`
keyed by session id (`SessionActivations.cs`). Openclicky's sensor
bridge is single-session per process, so activations persist to
`UserDefaults.standard` under key
`openclicky.meta.activatedDomains` (JSON-encoded sorted string array).
`core` is always included in `activatedDomains()` regardless of the
persisted set.

## Test result

`cd Packages/OpenClickyContextService && swift test --filter OpenClickyMetaToolsTests`

```
Test Suite 'OpenClickyMetaToolsTests' passed
    Executed 19 tests, with 0 failures (0 unexpected) in 0.026 (0.030) seconds
```

Coverage:
- BM25 tokenizer parity (`test_bm25_tokenizer_matches_everywhere_alphanumeric_split`).
- BM25 top-K ranked search (`test_search_tools_returns_topK_ranked_results`).
- BM25 known-query -> known-result (`test_search_tools_known_query_returns_known_top_result`).
- BM25 no-match -> empty (`test_search_tools_returns_empty_for_no_match`).
- `list_more_tools` category filter + hidden-only default
  (`test_list_more_tools_filters_by_category`,
  `test_list_more_tools_hides_core_tier_by_default`).
- `activate_domain` unknown -> false / known persists across registry
  instances (2 tests).
- `list_domains` counts + activation state
  (`test_list_domains_reflects_registered_counts_and_activation`).
- Env-var gates: `FULL=1` exposes all, `SELFEXPAND=0` disables,
  default enabled (3 tests).
- `batch` sequential order + stop-on-error + `call_tool` unknown
  (3 tests).
- `StrategyNote` completeness + mutation-verb G7 (3 tests).

## Notes

- `scripts/sign-and-install.sh` referenced in the task instructions does
  not exist in the repository (`scripts/` contains
  `automation-longrun-test.sh`, `bump-version.sh`, `release.sh`, etc.).
  This meta-tools port is a pure Swift package change with no bundle
  build artifact, so app-signing/install validation is not applicable —
  the `swift test` pass is the load-bearing check.
- No other Capture/*.swift files were touched.
- `OpenClickyExternalControlBridge.swift` (concurrent Phase 2 agent) was
  not modified — bridge wiring is a separate task.
- `MetaToolDispatchDelegate` is the injection point for the bridge; the
  bridge will register itself as delegate and forward `call_tool` /
  `batch` steps to the MCP dispatcher.
