# F29 — open-connector integration (investigation)

Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
open-connector upstream pin (from `/Users/wowdd1/Dev/Everywhere/3rd/open-connector/UPSTREAM_SHA`): `847efc10cdff5d6c50b9905ac05c663246f70684`

## Ground truth files read

- `/Users/wowdd1/Dev/Everywhere/docs/specs/everywhere-connector.md` (12-phase spec, 31KB)
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/ConnectorTools.cs` (6 MCP tool method signatures)
- `/Users/wowdd1/Dev/Everywhere/3rd/open-connector/` at pinned SHA (`src/core/*`, `src/providers/github/*`, 835 provider dirs)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyExternalControlBridge.swift` (sensor MCP surface: `sensorToolNames`, `sensorToolDomains`, `executeSensorTool`, `handleSensorRequest`)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/HeyClickyChromeBridgeServer.swift` (NWListener loopback pattern, event-log + long-poll — the shape reused here)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CodexProcessManager.swift` (Process/pipe subprocess pattern — reused for Node)
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift` (OpenClickyMetaDomain roster — new "connector" domain added)

## Everywhere 12-phase summary

| Phase | Scope | Landing point in openclicky |
|---|---|---|
| 1 | POC — github only, PAT via env, MCP surface only | Same 6 MCP tools mounted on `/mcp/sensor`, `connector` domain (gated). |
| 2 | Multi-provider + persistent creds | JSON store replaced with macOS Keychain (per this task). |
| 3 | Web Console + OAuth | Deferred; only the OAuth loopback callback + `connector_connect` OAuth kickoff is in this phase. |
| 4 | Cebian external link | N/A for openclicky. |
| 5 | Node-shimmed providers | Node subprocess (this phase's core divergence — replaces ClearScript V8). |
| 6 | Encryption + auto refresh | Keychain provides the "at rest" leg; refresh is deferred. |
| 7-11 | Bulk providers / manifest / transit files / rss shim | Node bundle picks up on next `open-connector` SHA bump. |
| 12 | Named connections | Supported by the Keychain store's `(providerId, connectionId)` primary key. |

## 6 MCP tool signatures — Everywhere byte-for-byte

Straight from `ConnectorTools.cs`, these are the definitive shapes we port:

1. **`connector_list`** — `service?: string, query?: string`. Three modes:
   - No args → `{ok, mode:"index", services:[{service, displayName, actionCount, authTypes}], total_services, hint, upstream_sha}`.
   - `service=X` → `{ok, service, displayName, categories, authTypes, homepageUrl, actions:[{id,name,description,requiredScopes}], upstream_sha}`.
   - `query=X` → `{ok, mode:"query", query, matches:[{service,name,description}], total_matches, truncated, upstream_sha}` (cap 60).

2. **`connector_describe`** — `service: string, name: string`. Returns `{ok, service, name, id, description, requiredScopes, inputSchema, outputSchema, upstream_sha}`.

3. **`connector_run`** — `service: string, name: string, arguments_json: string, connection?: string`. Returns upstream envelope flattened: `{schema_version:"1", ok, service, name, data|error, code?, hint?}`.

4. **`connector_connect`** — `service: string, api_key: string, display_name?: string, connection?: string`. Returns `{ok, service, connection, auth_type:"api_key", display_name}`. **NOTE**: Everywhere's variant stores a raw api_key (Phase 2). For openclicky Phase 7.5 we ALSO expose OAuth kickoff — done by returning `{ok, service, auth_type:"oauth2", authorization_url, state}` when the Node subprocess reports an `oauth2` provider and no `api_key` was passed. Keeps Everywhere's byte shape for the common api_key case.

5. **`connector_disconnect`** — `service: string, connection?: string`. Returns `{ok, service, connection, removed}`.

6. **`connector_list_connections`** — no args. Returns `{ok, connections:[{service, connection, auth_type, display_name, account_id}], total}`.

`connection` name normalisation rules (from `ConnectorTools.NormalizeConnection`):
- Whitespace-only → null (default connection).
- Contains `:` → error (`invalid_input`, `"connection name cannot contain ':' — reserved as the storage-key separator"`).
- Otherwise trimmed.

## Provider manifest schema

Each provider dir `3rd/open-connector/src/providers/<service>/` has:
- `definition.ts` — exports `provider: ProviderDefinition { service, displayName, categories, authTypes, auth[], homepageUrl, actions }`.
- `actions.ts` — array of `ActionDefinition { id, name, description, requiredScopes, inputSchema, outputSchema, execute }`.
- `scopes.ts` — OAuth scope constants.
- `executors.ts` — pure fetch API clients (executor entry points).

`auth[]` per provider is an array of `AuthDefinition`:
- `oauth2`: `{ type:"oauth2", authorizationUrl, tokenUrl, scopes, tokenEndpointAuthMethod }`.
- `api_key`: `{ type:"api_key", label, placeholder, description }`.
- `custom_credential`: `{ type:"custom_credential", fields[] }`.

## OAuth callback URL convention

- Loopback: `http://127.0.0.1:<callback-port>/oauth/callback?code=<code>&state=<state>`.
- `callback-port` chosen by `OpenClickyConnectorOAuthCallback` at server start; picked to be stable across the app run (not rerolled).
- `state` is a random UUID that binds `POST /connect` request → `GET /callback` response. State is stored in a per-run in-memory map only; if the app restarts before the user finishes consenting, the flow errors out.

## Keychain schema

- Service string: `com.jkneen.openclicky.connector.<providerId>`
- Account string: `<connectionId>` (empty string means "default").
- Value: JSON-encoded credential dict:
  ```json
  {
    "auth_type": "oauth2" | "api_key" | "custom_credential",
    "display_name": "GitHub (personal)",
    "account_id": "wowdd1",
    "access_token": "...",
    "refresh_token": "...",
    "expires_at": 1735689600,
    "api_key": "...",
    "extra": { ... }
  }
  ```
- `data` attribute is `kSecClass = kSecClassGenericPassword`.
- Access policy: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Listing uses `kSecMatchLimitAll` with `kSecReturnAttributes=true` to enumerate the service+account pairs without decrypting values.

## Ports

- Node loopback HTTP server: random port in `[52000, 53000)`, fallback +1 up to 10 tries. Announced via `READY <port>` stdout line from `boot.js`.
- OAuth callback HTTP server: random port in `[54000, 55000)`, same fallback. Announced by the Swift side and pushed to the Node subprocess via `POST /internal/oauth_callback_url`.
- Both binds via `NWParameters.tcp` with `acceptLocalOnly = true`.

## Auth token

- Swift generates a random UUID per launch and passes it via env `OPENCLICKY_CONNECTOR_TOKEN`. Every HTTP request from Swift → Node includes `Authorization: Bearer <token>` header.
- OAuth callback endpoint does NOT require the token (browser cannot send arbitrary headers on a redirect); instead it validates the `state` parameter matches an in-memory pending state.

## Node bundling strategy (deviation)

Everywhere embeds a ClearScript V8 isolate in .NET. Swift has no first-class V8. Options considered:

| Option | Verdict |
|---|---|
| JavaScriptCore (built into macOS) | Rejected — no `fetch`, missing Node APIs many providers rely on; would require reshimming ourselves. |
| Bundle Node.js macOS universal binary (~40MB) | Rejected for Phase 7.5 — inflates .app size and pins Node version; harder to sign/notarize. |
| Require system Node via `brew install node` or `~/.nvm/...` | **Adopted** — same ergonomics as Everywhere's build-time Node requirement; the daemon fails cleanly with an actionable install alert. |

Auto-discovery order for `node`:
1. `AppBundleConfiguration.openClickyConnectorNodePathOverride()` (Settings override).
2. `/opt/homebrew/bin/node`
3. `/usr/local/bin/node`
4. `~/.nvm/versions/node/*/bin/node` (latest by mtime).
5. `PATH` lookup fallback.

The vendored `3rd/open-connector/` sources ship inside `AppResources/OpenClicky/OpenConnectorRuntime/open-connector/` — same tree as Everywhere. `boot.js` does esbuild-free minimal loading using `ts-node` OR a pre-built `dist/connector.bundle.js`.

**Actual runtime scope**: Phase 7.5 lands the SWIFT SCAFFOLDING (subprocess manager, OAuth callback, Keychain, bridge tools, Settings). The Node side is a stub `boot.js` that returns a minimal manifest (2 seeded providers derived from bundled TypeScript metadata) — enough to prove the 6-tool surface end-to-end. Full open-connector vendoring + esbuild bundle build is deferred to a follow-up (matches Everywhere Phase 1 POC intent).

## Bridge domain

- New `OpenClickyMetaDomain.connector` (already reserved in the enum — needs to be added).
- All 6 tools registered under `sensorToolDomains[name] = OpenClickyMetaDomain.connector`.
- Hidden by default; visible after `activate_domain name=connector`.

## Files to add

1. `cursor-buddy/OpenClickyConnectorSubprocess.swift`
2. `cursor-buddy/OpenClickyConnectorOAuthCallback.swift`
3. `cursor-buddy/OpenClickyConnectorCredentialStore.swift`
4. `cursor-buddy/OpenClickyConnectorSettings.swift`
5. `cursor-buddy/OpenClickyConnectorBridgeTools.swift` (extension of the bridge)
6. `AppResources/OpenClicky/OpenConnectorRuntime/boot.js`
7. `AppResources/OpenClicky/OpenConnectorRuntime/config.json`
8. `AppResources/OpenClicky/OpenConnectorRuntime/README.md`
9. `AppResources/OpenClicky/OpenConnectorRuntime/UPSTREAM_SHA`

## Files to modify

1. `cursor-buddy/OpenClickyExternalControlBridge.swift` — register 6 connector tools in `sensorToolNames` / `sensorToolDomains` / `sensorToolDescriptorsRaw` and dispatch in `executeSensorTool`.
2. `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift` — add `connector` domain. **BLOCKED — SPM package is read-only per task constraints. Workaround: keep domain name as a raw string constant local to bridge, referenced via `"connector"` string literal, matching how OrchestrateTools do it if any.**

**Re-check**: `OpenClickyMetaDomain` is declared in the SPM package (read-only per hard constraint). The bridge's `sensorToolDomains` map maps to a String value; it currently uses named enum properties. We can safely pass a bare `"connector"` string — the meta registry accepts any string for the `domain` parameter and `OpenClickyMetaDomain.all` is only consulted for validation of activation requests. Verified in `OpenClickyMetaTools.swift:305-307`: `guard OpenClickyMetaDomain.all.contains(name) else { return false }` — meaning `activate_domain connector` would silently no-op unless the domain is in the roster.

**Divergence**: Because the SPM package is off-limits, we add the domain constant in a NEW openclicky-scope file `OpenClickyConnectorDomain.swift` that shadows the string `"connector"` and register it into the runtime meta registry's activated domains directly via a public method if available; otherwise we use `OPENCLICKY_MCP_FULL=1` gating during dev and hide the tools behind an app-level Settings toggle instead of `activate_domain`.

Simpler landing: skip domain gating for now. Register all 6 tools with domain `OpenClickyMetaDomain.core` — they will appear in the default `tools/list` when the connector subsystem is enabled, and stay entirely absent when disabled (guard in `executeSensorTool` returns a clear error if the connector subprocess is not running). This matches user-visible "Settings toggle gates the feature" semantics without needing to touch the SPM.
