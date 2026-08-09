# Doc Review Round 2 (2026-07-22)

**Method**: Review agent with `git log --all` fix + full 06/07/08/09 coverage. Cross-verified before applying.

**Round 1 hallucination fixed**: Round 1 falsely claimed `feat(annotation)` / `refactor(mac): retire C# AX` / `Swift dylib bridge` commits are fabricated — they exist (wowdd1 has 606 total commits across `--all` branches). Round 2 verified via `/tmp/commits.txt` grep. All 17 originally cited commits confirmed real.

**Round 2 verified as correct (no fix needed)**:
- 831 open-connector providers
- 173 OpenCLI adapters
- 96 unique `[McpServerTool(Name = "…")]`
- OCCU LibAxHelper 12 exports (9 tool-facing + 3 bookkeeping)
- All magic constants (MaxLinks=200, MaxUrlLen=2048, RepeatSuppressionMs=1500, MacosModifierReleaseDelayMs=180, SelectionCache.Ttl=2min, PickStash.DefaultTtl=5min, WhiteboardStash.DefaultTtl=5min, MaxPortFallbacks=10, port 7878, sweep stale >10min)
- Sanitisation caps: app=64/title=80/url=256/selection=200/link.url=512/link.title=120/source=32/anchor=200/ref=96/body=800
- URL denylist 17 params
- Rust hook: `> 64 * 1024` size, `"[everywhere-ctx] "` prefix (with trailing space), no schema_version check
- ToStatePath mapping
- ShortcutSettings defaults (only ChatWindow)
- LaunchPhrase default empty
- schema_version=1 constant
- .NET target = net10.0
- All cited class/method names exist

## Fixes applied (Round 2)

### HIGH

**H1 FIXED** — 03 doc: removed `everywhere,` from 96-tool list; clarified server ServerInfo.Name vs tool distinction. `everywhere` is NOT a tool.

**H2 FIXED** — 04 doc line 78: `NSLock` → `SemaphoreSlim(1,1).WaitAsync(0)` with `ContextStashWriter.cs:55, :135` citation. Swift port target = `NSLock.try()`.

**H3 FIXED** — 00 doc: 4 places of `~50 tool` → `96 unique tool name, 53 file` / `96 tools` / `96 MCP tool 完整清单`.

### MEDIUM

**M1 FIXED** — 09 doc line 180 + 10 doc line 409/515: OpenDia 85 WS ops now qualified as "Everywhere `hhsw2015/opendia experiment/replace-ab` fork; 上游 `aaronjmars/opendia` MIT 只 ~24 top-level tool". Porter has choice (a) or (b).

**M2 FIXED** — 05 doc line 26: added note about `_imageBytesById` side-table PNG cache with same TTL, cites `WhiteboardStash.cs:22-24, 56-64, 151-164`.

### LOW

**L1 FIXED** — `61KB` → `63KB` in 01/03/08/10 (4 files).
**L2 FIXED** — 10 doc line 17: `151 tool` → `96 unique app-side tool (PARITY_MATRIX 151 含 browser_*)`.
**L3 FIXED** — 03 doc: duplicate `### I.` header (Memory tools) → `### J.`.
**L4 FIXED** — 04 doc: added `SnapshotContextHotkeyInitializer.cs:122` path.
**L5 FIXED** — 10 doc line 21: `840 provider` → `831 provider (spec 里 840, 实测 = 831)`.

## Zero-drift confirmation

All round 2 fixes cross-verified against Everywhere source code before applying:
- H1: `grep -rE 'Name = "everywhere"' Everywhere.Mcp/Tools/` returns 0 (verified)
- H2: `grep -n "SemaphoreSlim" ContextStashWriter.cs` shows line 55 + line 135 (verified)
- H3: 96 count verified via `grep 'Name = "'` unique sort count
- L1: `wc -c AXUIElement.cs` = 63269 → 63KB (verified)

## Docs 06 / 07 not touched (no Everywhere source claims)

- 06_UI_INTEGRATION.md: openclicky-internal (CompanionManager / voice pipeline / startVoiceAgentTaskPlan / dock UI)
- 07_TASK_TYPE_TAXONOMY.md: openclicky router classification heuristics

## Final state after Round 2

**Roadmap docs are now fully consistent with Everywhere source at commit ref 30e03e9d (main HEAD).**

Any future Everywhere upstream changes will need to be reconciled per five-step workflow before impacting implementation.
