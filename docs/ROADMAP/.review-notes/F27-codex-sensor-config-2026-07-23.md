# F27 Codex config.toml `[mcp_servers.sensor]` injection - Review 2026-07-23

**Scope**: openclicky-native. Everywhere pin `30e03e9dcfdd4247fd679828ed86e9042f32d809` does not run Codex; `grep -rn 'codex\|Codex\|mcp_servers\|sensor'` under `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/` returns no matching source (only upstream comments in `open-codex-computer-use` ports and bin/obj artefacts). No byte parity required. This review evaluates correctness and robustness of the openclicky integration only.

## Alignment Table

| Concern | Location | Status |
|---|---|---|
| Sensor block schema | `cursor-buddy/ClickyCodexConfigTemplate.swift:181-186` (general lane), `:300-305` (HeyClicky lane) | Emits `[mcp_servers.sensor]` with `url`, plus sub-table `[mcp_servers.sensor.http_headers]` with `x-openclicky-token`. Matches roadmap `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` shape. |
| Endpoint URL | `ClickyCodexConfigTemplate.swift:182, 301` | Hardcoded `http://127.0.0.1:32123/mcp/sensor`. Matches route dispatch `OpenClickyExternalControlBridge.swift:543`. |
| Auth header name | `ClickyCodexConfigTemplate.swift:185, 304` | `x-openclicky-token`. Matches bridge acceptance `OpenClickyExternalControlBridge.swift:672, 677`. |
| Emission gate | `ClickyCodexConfigTemplate.swift:178, 297` via `normalizedOptionalString` | Block only emitted when `sensorMCPToken` non-nil and non-empty. Prevents 401 handshake failures when no token is configured. |
| Token resolution | `CodexHomeManager.swift:183-184` | `AppBundleConfiguration.externalControlBridgeToken()` first; falls back to `ProcessInfo.processInfo.environment["OPENCLICKY_AUTOMATION_TOKEN"]`. Mirrors bridge auth ladder `OpenClickyExternalControlBridge.swift:669-681`. |
| Token source ladder inside `externalControlBridgeToken()` | `AppBundleConfiguration.swift:206-211` | UserDefaults `openClickyExternalControlBridgeToken` -> Info.plist `OpenClickyExternalControlBridgeToken` / env `OPENCLICKY_BRIDGE_TOKEN` -> local dev env. |
| TOML escaping | `ClickyCodexConfigTemplate.swift:321-332` | Backslash + quote escaped; raw `\n`/`\r` replaced with space; other U+0000..U+001F control chars filtered. Safe for TOML basic string of the token value. |
| Config file path | `CodexHomeManager.swift:198`, `CodexHomeManager.swift:758-764` | `~/Library/Application Support/OpenClicky/AgentMode/CodexHome/config.toml`. |
| Atomic write | `CodexHomeManager.swift:199` | `write(to:atomically:true, encoding:.utf8)`. Full-file replace each call (no merge). |
| CODEX_HOME env at spawn | `CodexProcessManager.swift:174` | `environment["CODEX_HOME"] = codexHome.path`. Ensures Codex loads the openclicky config, not the user's `~/.codex/`. |
| Config re-render triggers | `CodexHomeManager.prepare(bundle:)` (`CodexHomeManager.swift:143`) called from `CodexAgentSession.swift:1391`, `CodexPointDetector.swift:152`, `CodexVoiceSession.swift:273`; manual re-render from `OpenClickySettingsWindowManager.swift:2367`. | Config regenerated on every new agent session start. |
| Bridge startup ordering | `CompanionManager.swift:2429` -> `startExternalControlBridgeIfNeeded()` (`:2611-2621`) -> `server.start()` (`OpenClickyExternalControlBridge.swift:190-193`). This runs during main-actor startup. Codex sessions are only started later via user action or auto-resume. | Bridge is typically up before any codex spawn. |
| Bridge port fallback | `OpenClickyExternalControlBridge.swift:198-241` walks up to 10 sibling ports on bind failure. | See Issue #1. |
| Bridge `/health` echo | `OpenClickyExternalControlBridge.swift:310` `"bridgeTokenConfigured": AppBundleConfiguration.externalControlBridgeToken() != nil` | Diagnostic only. |

## Issues

### Issue 1 — Port drift breaks sensor MCP silently (MEDIUM)

`ClickyCodexConfigTemplate.swift:182` and `:301` hardcode `http://127.0.0.1:32123/mcp/sensor`. But the bridge can bind on a different port under two conditions:

1. Env override `OPENCLICKY_MCP_PORT` (`OpenClickyExternalControlBridge.swift:161-167`).
2. Bind-conflict fallback ladder walking `port + 1` up to 10 times (`:225-226, :237-238`).

When either occurs, Codex will try to connect to `127.0.0.1:32123/mcp/sensor`, get ECONNREFUSED, and fail MCP handshake at startup (visible in `mcpServer/startupStatus/updated` diagnostics logged at `CodexProcessManager.swift:577-601`). The template has no way to know the resolved port because the bridge never exposes it back to `CodexHomeManager` and `resolveDefaultPort()` is not called from the template.

Fix: pass the bridge's resolved port (from `OpenClickyExternalControlBridgeServer.port` after `.ready` at `:214-216`) through to `ClickyCodexConfigTemplate` when rendering, or at minimum have the template consume `OpenClickyExternalControlBridgeServer.resolveDefaultPort()` for the env-var case. Fallback-ladder case still requires a runtime hand-off.

### Issue 2 — No `startup_timeout_sec`; race window when bridge is still binding (LOW/MEDIUM)

Codex's `rmcp` config schema accepts `startup_timeout_sec` (confirmed by roadmap note `docs/ROADMAP/.impl-notes/phase3-codex-sensor-2026-07-22.md:69` which lists it as a bundled-binary-known key). The template emits neither `startup_timeout_sec` nor any wait. Under a cold-start where the bridge is still walking `tryStart` retries (`OpenClickyExternalControlBridge.swift:198-241`), a codex session started via auto-resume immediately after `CompanionManager.swift:2425 startRelaunchableAgentAutoResumeChecks()` (which runs before `startExternalControlBridgeIfNeeded()` at `:2429`) could beat the bridge to ready state. Rare but not impossible; the template gives Codex no explicit tolerance.

Fix: append `startup_timeout_sec = 10` (or similar) after each `url` line, and swap the ordering in `CompanionManager.swift:2415-2429` so the bridge starts before auto-resume.

### Issue 3 — Token stored plaintext on disk (LOW)

The bridge token is embedded verbatim in `config.toml` at `~/Library/Application Support/OpenClicky/AgentMode/CodexHome/config.toml` (`CodexHomeManager.swift:198-199`). Any process with the user's UID can read it. Codex's rmcp schema supports `bearer_token_env_var = "..."` per the same `phase3-codex-sensor-2026-07-22.md:64` schema listing, which would let openclicky write only the env-var name in the toml and inject the value into the spawn env (`CodexProcessManager.baseEnvironment` already carries an environment dict). `CodexProcessManager.swift:48` doesn't currently pass the bridge token into the codex child env, so the switch would need matching env injection.

Fix: switch to `bearer_token_env_var = "OPENCLICKY_BRIDGE_TOKEN"` in the template and set `environment["OPENCLICKY_BRIDGE_TOKEN"] = sensorToken` in `CodexProcessManager.baseEnvironment` (`:172-208`). Note this also gives free token rotation: change env at next spawn, no config re-render needed.

### Issue 4 — Token change does not propagate to running codex sessions (LOW)

`writeCodexConfigFromSettings` snapshots the token at render time (`CodexHomeManager.swift:183-184`). If the user rotates the bridge token via UserDefaults or Info.plist while a codex session is running, the running session keeps the old value baked into the header the client already established. New sessions get the new token. Bridge auth check `hasValidBridgeToken` at `OpenClickyExternalControlBridge.swift:663-684` uses the current `AppBundleConfiguration.externalControlBridgeToken()` at request time, so the running session's sensor calls start 401'ing.

Mitigation: the same env-var indirection from Issue 3 would fix this because rmcp re-reads the env var per request (unverified against `codex` binary — worth a runtime check). Alternative: restart running codex sessions on token change; `OpenClickySettingsWindowManager.swift:2367` already advises "Restart active agents to pick up changes" but only for MCP settings, not token rotation.

### Issue 5 — `openClickyControl` block is missing the token header (KNOWN, out of scope)

`ClickyCodexConfigTemplate.swift:163-169` emits `[mcp_servers.openClickyControl]` with `url = "http://127.0.0.1:32123/mcp"` and NO `http_headers`. That endpoint requires the same bridge token (path `/mcp` is auth-gated by the same `hasValidBridgeToken` check `OpenClickyExternalControlBridge.swift:323-329`), so if `includeOpenClickyControlMCP` is toggled on, codex will 401 on every call. Called out already in `docs/ROADMAP/.impl-notes/phase3-codex-sensor-2026-07-22.md:50-54` and `phase3-codex-sensor-report-2026-07-22.md:115-120` as a latent bug outside F27's scope. Flagged again here for tracking; fix pattern is identical to what F27 landed for `sensor`.

### Issue 6 — `sensorMCPToken: sensorToken` is passed uninspected; empty-string tokens gated only at render time (LOW/informational)

`AppBundleConfiguration.externalControlBridgeToken()` returns `String?` where empty-string keys are already filtered by `userDefaultsValue` / `stringValue` (assumed — not verified in this pass). The env-var fallback via `ProcessInfo.processInfo.environment["OPENCLICKY_AUTOMATION_TOKEN"]` at `CodexHomeManager.swift:184` however is NOT trimmed before being handed to the template. It relies on `normalizedOptionalString` in the template (`ClickyCodexConfigTemplate.swift:315-319, 178, 297`) to strip whitespace and drop empties. That is defensive today but couples correctness to a template invariant. Minor; leaves the design intact.

## Verification Notes

- End-to-end sensor call from inside codex: NOT executed in this review (would require a live codex process and burn credits). The Phase 3 impl report `docs/ROADMAP/.impl-notes/phase3-codex-sensor-report-2026-07-22.md:71-86` explicitly deferred this to Phase 4 acceptance. `scripts/test-mcp-sensor.sh` covers the transport shape from outside codex.
- `swiftc -parse` not re-run; only the sensor render lines changed since last review and their shape is trivial.
- TOML validity: values quoted, escape helper strips control chars (`ClickyCodexConfigTemplate.swift:321-332`), header keys are TOML-legal bare keys (`x-openclicky-token` matches `[A-Za-z0-9_-]+`).

## Verdict

**PASS with caveats.**

The F27 injection lands the sensor block correctly in both lanes (general + HeyClicky Free), gates on token availability, mirrors the bridge's auth header exactly, and plumbs the config through Codex home write + `CODEX_HOME` env propagation. The design is coherent and matches roadmap intent byte-for-byte.

The remaining issues are all robustness fences, not correctness holes:

- Port drift (Issue 1) is the highest-impact concern because both an env override and a bind-conflict fallback can silently desync the config from the actual bridge port. Recommend surfacing the resolved bridge port to the template.
- Startup timeout absence (Issue 2), plaintext token on disk (Issue 3), and no token rotation for running sessions (Issue 4) are all solvable by switching to `bearer_token_env_var` and injecting `OPENCLICKY_BRIDGE_TOKEN` into the codex spawn env; do those together.
- Issue 5 is a pre-existing sibling bug (openClickyControl block missing token) that this review keeps flagging as noise until it's fixed.
