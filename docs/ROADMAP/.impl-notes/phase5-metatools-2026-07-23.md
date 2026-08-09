# Phase 5 — Meta tools port (2026-07-23)

Port Everywhere's self-expanding MCP meta tools to Swift.

Source refs @30e03e9dcfdd4247fd679828ed86e9042f32d809:
- `src/Everywhere.Mcp/Tools/MetaTools.cs`
- `src/Everywhere.Mcp/Tools/GateTools.cs`
- `src/Everywhere.Mcp/Tools/BatchTool.cs`
- `src/Everywhere.Mcp/Tools/SearchTools.cs`
- `src/Everywhere.Mcp/Meta/Bm25Index.cs`
- `src/Everywhere.Mcp/Meta/SessionActivations.cs`
- `src/Everywhere.Mcp/Meta/TierGate.cs`
- `src/Everywhere.Mcp/OpenCli/Observation/SelfExpandGate.cs`
- `src/Everywhere.Mcp/CoreToolGate.cs`
- `src/Everywhere.Mcp/OpenCli/Memory/Schemas.cs` (`StrategyNote`)

## Investigation

### Signatures + return shapes
- `list_more_tools(category?: string) -> string` — human-readable markdown catalog
  filtered by category. openclicky returns `[MetaToolDescriptor]` (typed) instead of
  a markdown blob so callers can render or forward as they need. Categories in
  Everywhere: `action_browser | action_macos | perception_active | perception_content
  | debug | config | opencli`. openclicky uses the domain enumeration below.
- `call_tool(name: string, arguments_json?: string) -> string` — reflective dispatch.
  openclicky delegates via `MetaToolDispatchDelegate`.
- `search_tools(query: string, top_k?: int) -> JSON array` — BM25 over tool docs.
- `activate_domain(name: string) -> JSON` — set-add on the session's active domain set.
- `list_domains() -> JSON array` — `[{name, tool_count, active}]`.
- `batch(steps_json) -> {ok, count, results, [error, step_index]}` — sequential.
- `strategy_note_write(site, name, note_json) -> {path}` or error envelope.
- `strategy_note_get(site, name) -> note JSON` or `{ok:true, note:null}`.

### Env vars
- Everywhere: `EVERYWHERE_MCP_FULL=1` disables the gate; `EVERYWHERE_MCP_SELFEXPAND=0`
  disables all self-expand tools (returns `SELFEXPAND_DISABLED`).
- Openclicky: `OPENCLICKY_MCP_FULL=1` and `OPENCLICKY_MCP_SELFEXPAND=0` — same
  semantics. Read from `ProcessInfo.processInfo.environment`. Not cached across
  calls (tests override via env; parity with `SelfExpandGate.Enabled`).

### BM25 tokenizer
- Lowercase, tokenize on non-alphanumeric via `Character.isLetter || .isNumber`.
- No stemming, no stopwords.
- k1 = 1.5, b = 0.75.
- IDF = `log(1 + (N - df + 0.5) / (df + 0.5))`.
- Score per query token = `idf * (tf * (k1+1)) / (tf + k1 * (1 - b + b * len/avgLen))`.
- Sum across query tokens; top-K by score desc.

### Batch semantics
- Sequential; stops at first error; returns `results` up to (excluding) the failing
  step and sets `error`, `step_index`.
- openclicky `batch(_ steps: [BatchStep]) async -> [BatchResult]` returns per-step
  results (with error on the failing entry). Wire-level `{ok,count,results,...}`
  envelope is the bridge's responsibility.

### Domain enumeration (openclicky roster)
Per task spec + roadmap doc 03/05:
- `core` (always active — the always-visible search tier)
- `browser`
- `terminal`
- `finder`
- `whiteboard`
- `doc_readers`
- `web`
- `memory`
- `orchestrate`

Everywhere ships `browser_core / web_analysis / memory / gates / generator / chat`
+ an `observation` alias. openclicky's domains are aligned to the openclicky sensor
surface (per doc 03 rows) rather than Everywhere's OpenDia/adapter world.

### Persistence
Everywhere keeps per-session activations in memory (SessionActivations dict). For
openclicky the bridge is single-session per process, so we persist the activated set
under `UserDefaults.standard` key `openclicky.meta.activatedDomains` (JSON string
array). Test suite uses `UserDefaults(suiteName:)` to isolate state.

## Reconciliation with docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md

- Row I aligns: `list_more_tools`, `call_tool`, `search_tools`, `list_domains`,
  `activate_domain`, `batch(steps_json)`.
- Doc calls out `OPENCLICKY_MCP_FULL=1` and `OPENCLICKY_MCP_SELFEXPAND=0` as env
  kill switches. Implementation honours both.
- BM25 params (k1=1.5, b=0.75) match Everywhere `Bm25Index.cs`.
- StrategyNote validation: evidence >= 3 * >= 20 chars, replay >= 50 chars,
  strategy in {public,cookie,intercept,ui}, contract in {stable,visible-ui,
  internal-unstable} — copied from Everywhere `Schemas.cs`.

## Types appended to CaptureTypes.swift

- `MetaToolDescriptor` — { name, description, domain, isHidden }.
- `DomainInfo` — { name, toolCount, isActive }.
- `StrategyNote` — { strategy, contract, evidence, replay, mutation, createdAt } +
  `isComplete(missing:) -> Bool`.
- `BatchStep` — { tool, arguments }.
- `BatchResult` — { tool, ok, resultJson?, errorMessage? }.
- `ScoredToolMatch` — { name, description, score, domain }.

## Files
- `Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift` (new; sole meta file)
- `Tests/OpenClickyContextServiceTests/OpenClickyMetaToolsTests.swift`
- Appended types to `Types/CaptureTypes.swift`.
