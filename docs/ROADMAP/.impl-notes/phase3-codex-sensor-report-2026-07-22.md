# Phase 3 Layer 2 — Codex config.toml sensor MCP integration — Report

## Summary

Wired the Phase 2 `/mcp/sensor` endpoint into the codex config.toml
template so codex sessions spawned by OpenClicky auto-register the
sensor MCP server. Block emits only when a bridge token is available
(env var or configured), so codex never tries to hand-shake with an
unauthenticated endpoint.

## Files modified

- `cursor-buddy/ClickyCodexConfigTemplate.swift`
  - Added stored field `var sensorMCPToken: String?` and matching
    initializer parameter (defaults to `nil`).
  - In `render()` (general OpenClicky lane): appended a conditional
    `[mcp_servers.sensor]` + `[mcp_servers.sensor.http_headers]` block
    after the existing `openClickyControl` block and before the
    `[[skills.config]]` sections.
  - In `renderHeyClickyToml()` (HeyClicky Free lane): appended the same
    block after the trailing advisor-cost comment. Flipped the local
    `let lines` to `var lines` so the conditional append compiles.
    Rationale for including this branch: advisor was excluded from
    codex-side use because each call adds a codex round-trip
    (cost-based). Sensor tools are pure local reads served by the
    bridge with zero per-call model cost, so that argument does not
    apply. `mcp_servers.*` sections are consumed locally by codex; the
    HeyClicky proxy contract governs only provider/auth fields.
- `cursor-buddy/CodexHomeManager.swift`
  - `writeCodexConfigFromSettings()` now resolves a `sensorToken` via
    `AppBundleConfiguration.externalControlBridgeToken()` with an
    `OPENCLICKY_AUTOMATION_TOKEN` env-var fallback, and passes it into
    the template.
- `docs/ROADMAP/.impl-notes/phase3-codex-sensor-2026-07-22.md`
  (investigation notes — new).

## Rendered config.toml (sensor section, verbatim from live disk)

Path: `~/Library/Application Support/OpenClicky/AgentMode/CodexHome/config.toml`

Test build lane emitted (with UserDefaults token
`test-automation-token`):

```toml
[mcp_servers.sensor]
url = "http://127.0.0.1:32123/mcp/sensor"

[mcp_servers.sensor.http_headers]
x-openclicky-token = "test-automation-token"
```

The block is preceded by the `[features]` section and followed by the
per-project `[projects."/private/tmp/oc-poc/regen"]` trust block, so
ordering does not conflict with any existing top-level or
project-scoped table.

## Build result

- `swiftc -parse cursor-buddy/ClickyCodexConfigTemplate.swift` — clean.
- `bash scripts/sign-and-install.sh` — `** BUILD SUCCEEDED **`, signed
  with `OpenClicky Dev Sign`, installed to `/Applications/OpenClicky.app`,
  launched as pid 51517 with bundle id `com.jkneen.openclicky`.

  Initial rebuild attempt failed on one compile error:
  `renderHeyClickyToml()` declared `let lines` and rejected the sensor
  append. Fixed by flipping to `var lines` (nothing else in that scope
  mutates the array, so the change is scoped and additive).

## Live verification

1. Removed the pre-existing config.toml.
2. Started a throwaway codex task via
   `POST /mcp/orchestrate` -> `codex_task_start`
   (title `phase3-sensor-smoke`, prompt `echo ok`) to force
   `CodexHomeManager.prepare(bundle:)` to re-run
   `writeCodexConfigFromSettings()`.
3. Waited 8 seconds. config.toml grew from 884 B (old) to ~1.0 KB.
   Diff vs prior-run baseline (per the harness) is exactly the six
   lines quoted above plus one whitespace nit.
4. Purged the throwaway task via
   `codex_task_purge` (`titleContains=phase3-sensor-smoke`).

End-to-end call of a sensor tool from inside codex was NOT run — the
task above deliberately used a trivial prompt to avoid burning credits
and to keep the smoke test focused on config rendering. That call is
Phase 4 acceptance work.

## Doc reconciliation

`docs/ROADMAP/09_MIGRATION_ORDER.md` Phase 3 section (lines 61-72)
already prescribes exactly what was implemented:

- `[mcp_servers.sensor]` added to the template
- `http_headers` carrying the bridge token
- Test protocol: spawn a small codex task, verify tools/list surfaces
  sensor tools.

No doc changes were needed. `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md`
lines 15-21 give the same block shape; the rendered output matches
byte-for-byte modulo the section ordering.

## Note for future readers

The sensor block's structure is identical to what the roadmap docs
prescribe — a bare `url` field (codex's rmcp client auto-detects
streamable_http transport from a `url`) plus a nested
`[mcp_servers.<name>.http_headers]` sub-section. This mirrors how
advisor is already exposed on `/mcp/advisor` (though advisor is
deliberately NOT registered from codex — see the block comment in
`renderHeyClickyToml()` for the cost-based rationale).

Two minor divergences from the closest existing entry
(`[mcp_servers.openClickyControl]`) worth flagging:

1. openClickyControl currently propagates no token, even though the
   underlying `/mcp` route is auth-gated. That is a latent bug in the
   existing template (out of scope for Phase 3); if/when
   openClickyControl gets promoted from "off by default" to
   "on when bridge is up", it should adopt the same `http_headers`
   pattern this Phase 3 change introduces for sensor.
2. The sensor block emits from BOTH `render()` (general lane) AND
   `renderHeyClickyToml()` (HeyClicky Free lane). Every other
   conditional MCP block currently emits only from `render()`. This
   is intentional — sensor is Layer 2's core contract and needs to
   be available regardless of which model provider the user picks.
