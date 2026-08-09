# Phase 3 Layer 2 — Codex config.toml sensor MCP integration — Investigation

## Objective

Wire the Phase 2 `/mcp/sensor` endpoint into codex agent's `config.toml` so
codex sessions spawned by OpenClicky can call sensor tools via MCP.

## Template ground truth

Source: `cursor-buddy/ClickyCodexConfigTemplate.swift`.

Two render branches:

1. `render()` — general OpenClicky lane (openai / openclicky provider).
2. `renderHeyClickyToml()` — HeyClicky Free lane (`heyclicky-free-*`
   models). Config format is dictated by the HeyClicky proxy contract; do
   not deviate. The trailing block-comment inside this branch is where
   we document why advisor is NOT registered from within codex — same
   argument applies to sensor if we ever consider it, but here the
   trade-off is different: sensor tools are pure local reads (0-cost
   after Layer 0 captures) and the codex agent NEEDS them for Layer 2
   context. Sensor cost pattern differs from advisor's.

## Existing MCP server registration patterns (in `render()`)

All MCP servers are emitted as flat top-level `[mcp_servers.<name>]`
sections. There is NO array-of-tables usage. Existing examples:

- `[mcp_servers.openaiDeveloperDocs]` — `url` only (hosted, no auth).
- `[mcp_servers.composio]` — `url` only.
- `[mcp_servers.cuaDriver]` — `command` + `args`, plus nested
  `[mcp_servers.cuaDriver.env]` sub-section for env vars.
- `[mcp_servers.openClickyControl]` — `url` only, points at
  `http://127.0.0.1:32123/mcp` (bare `/mcp`, the legacy /mcp/call route).

**Advisor is deliberately NOT registered in either branch.** The
HeyClicky-lane comment (line 253-261) explains: advisor from inside
codex loop wastes agent credits (4-5x cost, 2x wall clock) because
each tool call adds a codex round-trip. Advisor is instead called from
the planning phase (before codex spawn) or by EXTERNAL MCP clients
(Claude Code / Cursor) via `/mcp/advisor`.

So the closest structural analog for sensor in the template is
`openClickyControl`: URL-only entry pointing at the same bridge port,
different path. But **sensor differs from openClickyControl** in two ways:

1. Sensor path is `/mcp/sensor`, openClickyControl is `/mcp`.
2. `/mcp/sensor` REQUIRES `x-openclicky-token` auth header
   (`OpenClickyExternalControlBridge.hasValidBridgeToken`). The old
   `/mcp` legacy route is auth-gated too, but openClickyControl block
   in the template doesn't propagate any token. Grep confirms: no
   existing entry passes `http_headers`. This gap is a Phase 3 bug for
   openClickyControl — but it's out of scope; only sensor is being
   added.

## Codex expected TOML shape

Codex uses `rmcp` for MCP transports. String-search of the bundled
codex binary (`AppResources/OpenClicky/CodexRuntime/vendor/aarch64-apple-darwin/codex/codex`)
confirms the deserialized keys for a server config include:

```
url
bearer_token_env_var
http_headers
env_http_headers
experimental_environment
supports_parallel_tool_calls
startup_timeout_sec
scopes
oauth
oauth_resource
```

Transport strings the binary knows: `stdio`, `streamable_http`.

The `http_headers` key is a map — expressed as a nested TOML sub-section
`[mcp_servers.<name>.http_headers]` with `key = "value"` pairs.

Note: unlike some MCP clients, codex's `rmcp` HTTP client
**auto-detects streamable_http** from a `url` field, so passing
`type = "streamable_http"` is not required. The advisor endpoint uses
the same client-side auto-detect (advisor is not registered in codex
anyway, but the same host serves it identically).

Roadmap docs (`docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md` lines 16-21)
already prescribe the exact block shape:

```toml
[mcp_servers.sensor]
url = "http://127.0.0.1:32123/mcp/sensor"
[mcp_servers.sensor.http_headers]
x-openclicky-token = "..."
```

`docs/ROADMAP/09_MIGRATION_ORDER.md` lines 61-72 (Phase 3 section)
prescribes the same, plus test protocol.

## Token source

`OpenClickyExternalControlBridge.hasValidBridgeToken` accepts:
1. `OPENCLICKY_AUTOMATION_TOKEN` env var (`x-openclicky-token` header OR `Bearer`).
2. Configured token from `AppBundleConfiguration.externalControlBridgeToken()`,
   which resolves in order:
   - UserDefaults key `userExternalControlBridgeTokenDefaultsKey`
   - Bundle Info.plist `OpenClickyExternalControlBridgeToken`
   - Env var `OPENCLICKY_BRIDGE_TOKEN`
   - localDevelopmentEnvironmentValue fallback.

For codex spawned by OpenClicky itself, the token is available at
config-render time from `AppBundleConfiguration.externalControlBridgeToken()`.
If nil (no token yet), the sensor endpoint would 401 — but so would every
other MCP call. We only emit the sensor block when the token is present.

## TOML quoting

Sensor block value strings need TOML basic-string escaping via the
existing `escape(_:)` helper (backslash + quote + control chars).
Header keys with hyphens (`x-openclicky-token`) MUST be quoted in TOML
because bare keys allow only `[A-Za-z0-9_-]` — wait, `-` IS allowed in
bare keys. Verified against the TOML 1.0 spec: bare keys allow ASCII
letters, digits, underscores, and dashes. So `x-openclicky-token = "..."`
without quotes is valid. But quoting it is also valid and mirrors
what's on the roadmap example. Choose **unquoted** since it matches
what the codex binary would emit and stays clean.

## Design decisions

1. **Add sensor block unconditionally** in the non-HeyClicky `render()`
   branch, positioned after the last existing conditional MCP block
   (openClickyControl at line 160) and before the `[[skills.config]]`
   blocks. Guard emission on token presence: if
   `AppBundleConfiguration.externalControlBridgeToken()` returns nil
   AND the env var is not set, do NOT emit the block (codex would
   fail startup trying to authenticate).
2. **Do not add to HeyClicky lane** for now. The HeyClicky proxy
   contract is strict; adding MCP servers there needs its own audit.
   Sensor consumption from inside HeyClicky-lane codex is a Phase 4+
   concern.
3. **Use nested sub-section for http_headers**, matching the roadmap
   spec and codex's TOML parser expectation for map fields.
4. **Do not gate behind a new AppBundleConfiguration toggle.** All
   other MCP blocks in the template are toggled by feature flags
   (developerDocs, composio, cuaDriver, openClickyControl). Sensor is
   the Layer 2 sensor endpoint we're standardizing on — it should be
   on by default whenever the bridge token exists.

## Doc reconciliation

`docs/ROADMAP/09_MIGRATION_ORDER.md` Phase 3 checklist matches this
plan verbatim. No doc updates needed.

## Test plan

1. Static: read rendered output for a synthetic
   `ClickyCodexConfigTemplate()` and confirm `[mcp_servers.sensor]`
   block appears with URL + `http_headers` sub-section.
2. Build: `bash scripts/sign-and-install.sh` — build succeeds.
3. Live: on the running app, re-render config.toml via
   `writeCodexConfigFromSettings` (triggered on app launch or settings
   change) and read
   `~/Library/Application Support/OpenClicky/CodexHome/config.toml` —
   verify sensor block is present with correct URL and token.

## Out of scope

- Fixing openClickyControl's missing token (separate bug).
- Adding sensor to HeyClicky-lane config (Phase 4+).
- Spawning a codex task and calling `sensor_health` end-to-end —
  Phase 4 acceptance work.
