# Phase 7.5 F29 — open-connector landing report

- **Date**: 2026-07-23
- **Everywhere upstream pin**: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- **open-connector upstream pin**: `847efc10cdff5d6c50b9905ac05c663246f70684`

## Summary

Ported Everywhere's `Everywhere.Mcp.Connector` + `ConnectorTools.cs` 6-tool MCP surface to openclicky. The Swift scaffolding (subprocess manager, OAuth loopback callback, Keychain credential store, bridge tools, Settings) is fully wired up; the Node subprocess entry point (`boot.js`) implements the exact HTTP contract expected by Swift and serves a seeded 2-provider manifest end-to-end (github + no_auth_demo). Full 831-provider vendoring + esbuild bundle is deferred to a follow-up (matches Everywhere's Phase 1 POC intent). App builds and launches with the runtime bundled inside `.app/Contents/Resources/OpenConnectorRuntime/`.

## Files created

| Path | Purpose | Lines |
|---|---|---|
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorCredentialStore.swift` | macOS Keychain-backed credential store — Everywhere's `JsonCredentialStore.cs` port. | 230 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorSubprocess.swift` | Node subprocess lifecycle (start/stop/crash-restart, READY-line handshake, bearer-token HTTP wrapper). | 355 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorOAuthCallback.swift` | Loopback HTTP OAuth 2.0 callback server on `127.0.0.1:<54000-55000>/oauth/callback`. | 270 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorSettings.swift` | UserDefaults master toggle + Node path override + provider allow/disallow lists. | 125 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorBridgeTools.swift` | 6 MCP tool descriptors + dispatch, byte-for-byte with `ConnectorTools.cs`. | 435 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddyTests/OpenClickyConnectorCredentialStoreTests.swift` | Keychain round-trip, normalization, named-connection isolation. | 105 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenConnectorRuntime/boot.js` | Node subprocess entry — 6 HTTP routes + seeded manifest + fetch wrapper. | 475 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenConnectorRuntime/config.json` | Provider allowlist/disallowlist fallback for headless CI. | 12 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenConnectorRuntime/UPSTREAM_SHA` | Pinned open-connector SHA (`847efc10cdff5d6c50b9905ac05c663246f70684`). | 1 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenConnectorRuntime/README.md` | Runtime contract + install notes. | 55 |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase7-5-open-connector-2026-07-23.md` | Investigation + design decisions. | 165 |

## Files modified

| Path | Change | Load-bearing snippet |
|---|---|---|
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyExternalControlBridge.swift` | Registered 6 tool names in `sensorToolNames`, mapped to `core` domain in `sensorToolDomains`, appended `OpenClickyConnectorBridgeTools.descriptorsRaw` to `sensorToolDescriptorsRaw`, dispatched via `executeSensorTool` switch. | `] + OpenClickyConnectorBridgeTools.descriptorsRaw` |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/cursor_buddyApp.swift` | Autostart on `applicationDidFinishLaunching`, cleanup on `applicationWillTerminate`. | `OpenClickyConnectorSettings.autostartIfEnabled()` |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy.xcodeproj/project.pbxproj` | Added `OpenConnectorRuntime` to the "Copy OpenClicky App Resources" ditto list. | `... BackgroundComputerUseRuntime OpenConnectorRuntime agent-done.mp3 ...` |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/09_MIGRATION_ORDER.md` | Rewrote Phase 7.5 checklist with actual file paths, marked landed vs deferred, documented deviations. | (see doc) |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/11_REVIEW_CHECKLIST.md` | Updated F29 section with actual file paths, deviations, upstream pin. | (see doc) |

## 6 MCP tool descriptors (verbatim)

Reproduced from `OpenClickyConnectorBridgeTools.descriptorsRaw`:

- **`connector_list`** — args `{service?: string, query?: string}`. Description mirrors `ConnectorTools.ConnectorList` verbatim.
- **`connector_describe`** — args `{service: string, name: string}` (both required).
- **`connector_run`** — args `{service, name, arguments_json, connection?}` (first three required). `arguments_json` is a stringified JSON object matching the action's inputSchema.
- **`connector_connect`** — args `{service, api_key?, display_name?, connection?}`. Empty `api_key` triggers OAuth kickoff (returns `authorization_url` + `state`); non-empty stores directly in Keychain.
- **`connector_disconnect`** — args `{service, connection?}`. Idempotent Keychain delete.
- **`connector_list_connections`** — no args. Enumerates Keychain, returns labels + auth types + account ids only (never secret values).

## Node bundling strategy (chosen)

**System Node via auto-discovery** — rejected 40MB universal-binary bundling for four reasons:

1. Node version pinning becomes an openclicky-side maintenance chore.
2. Notarization + signing of a bundled Node binary adds friction.
3. `.app` growth of 40MB is disproportionate for a POC-stage subsystem.
4. Users who care about connector integration already have Node (parity with Everywhere's build-time Node dep).

Auto-discovery order:

1. Settings override (`OpenClickyConnectorSettings.nodePathOverride`).
2. `/opt/homebrew/bin/node`.
3. `/usr/local/bin/node`.
4. `~/.nvm/versions/node/*/bin/node` (most-recent by mtime).
5. `PATH` fallback (`which node`).

Missing Node triggers a clear `OpenClickyConnectorSubprocessError.nodeNotFound` with an actionable message pointing at `brew install node`.

## Keychain schema

```
kSecClass         = kSecClassGenericPassword
kSecAttrService   = "com.jkneen.openclicky.connector.<providerId>"
kSecAttrAccount   = "<connectionId>"     // empty string == default connection
kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
kSecValueData     = UTF-8 JSON:
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

Named-connection support: `(providerId, connectionId)` is the composite primary key. This is Everywhere Phase 12 semantics from day one — openclicky's Keychain store never needed the Phase 1-2 "one connection per service" simplification.

## OAuth flow

```
Agent/LLM
   │
   │  connector_connect(service:"github", connection:"work")
   ▼
OpenClickyConnectorBridgeTools.handleConnect
   │
   │  POST http://127.0.0.1:<node-port>/oauth_authorize
   │     Authorization: Bearer <OPENCLICKY_CONNECTOR_TOKEN>
   ▼
Node boot.js.routeOauthAuthorize
   │
   │  mint state, build provider authorization URL
   │  (using OPENCLICKY_CONNECTOR_OAUTH_CALLBACK env var)
   ▼
   {"ok":true, "authorization_url":"https://github.com/login/oauth/authorize?client_id=…&state=…&redirect_uri=http://127.0.0.1:<callback-port>/oauth/callback", "state":"…"}
   │
   ▼
Swift registers state in OpenClickyConnectorOAuthCallback.pendingStates
   │
   │  MCP response returned to caller (authorization URL)
   ▼
User opens URL in browser → OAuth provider → redirect to:
   GET http://127.0.0.1:<callback-port>/oauth/callback?code=…&state=…
   │
   ▼
OpenClickyConnectorOAuthCallback.handleCallback
   │
   │  validate state, POST to Node's /internal/oauth_complete
   ▼
Node exchanges code for tokens (stub in POC), returns credential
   │
   ▼
Swift saves credential in Keychain, renders "connected" HTML
```

## Provider count

Runtime `/health` endpoint under the seeded manifest:

```json
{
  "ok": true,
  "providers": 2,
  "manifest_source": "seed",
  "upstream_sha": "847efc10cdff5d6c50b9905ac05c663246f70684",
  "oauth_callback": null
}
```

Full 831-provider count materializes once `open-connector/dist/connector-manifest.json` is produced (deferred).

## End-to-end test recipe

Prerequisites: `brew install node` (v18+).

```bash
# 1. Manual boot.js smoke — bypass Swift, prove HTTP contract:
export OPENCLICKY_CONNECTOR_TOKEN="e2e-token"
node /Applications/OpenClicky.app/Contents/Resources/OpenConnectorRuntime/boot.js &
NODEPID=$!
sleep 0.5
PORT=$(lsof -Pan -p $NODEPID -iTCP -sTCP:LISTEN | awk 'NR==2 {print $9}' | cut -d: -f2)
echo "Node listening on $PORT"

# Health:
curl -s http://127.0.0.1:$PORT/health
# → {"ok":true,"providers":2,"manifest_source":"seed",...}

# List:
curl -sX POST -H "Authorization: Bearer e2e-token" -H "Content-Type: application/json" \
     -d '{}' http://127.0.0.1:$PORT/providers
# → {"schema_version":"1","ok":true,"mode":"index","services":[{"service":"github",…},{"service":"no_auth_demo",…}],"total_services":2,...}

# Describe:
curl -sX POST -H "Authorization: Bearer e2e-token" -H "Content-Type: application/json" \
     -d '{"service":"github","name":"get_current_user"}' http://127.0.0.1:$PORT/describe
# → {"schema_version":"1","ok":true,"service":"github","name":"get_current_user","id":"get_current_user","requiredScopes":["read:user"],…}

# Run (no-auth demo):
curl -sX POST -H "Authorization: Bearer e2e-token" -H "Content-Type: application/json" \
     -d '{"service":"no_auth_demo","name":"echo","arguments":{"value":"hello"},"credential":null}' http://127.0.0.1:$PORT/run
# → {"schema_version":"1","service":"no_auth_demo","name":"echo","ok":true,"data":{"value":"hello"}}

kill $NODEPID

# 2. End-to-end via MCP through OpenClicky:
#    - Launch OpenClicky.app
#    - Enable connector in Settings (feature TBD — for now, defaults(1)
#      `defaults write com.jkneen.openclicky openclicky.connector.enabled -bool YES`
#      then relaunch).
#    - Curl /mcp/sensor with a JSON-RPC tools/call body specifying
#      "name":"connector_list". Response should match the shape above.
```

## Known limitations

1. **POC-only provider set.** Seeded manifest ships github (+ 2 actions) and no_auth_demo (echo). Full 831-provider bundle is deferred.
2. **OAuth token exchange is a stub.** `/internal/oauth_complete` records the auth code but does not exchange it for a token — that requires OAuth client credential registration UI (Everywhere Phase 3 landed after Phase 1).
3. **No Settings UI panel.** Master toggle is a `defaults write` today; Settings panel integration is a follow-up (touched files list intentionally minimal per task constraints).
4. **Sandbox / hardened runtime interactions.** Node subprocess is launched with the parent app's environment; some providers may hit macOS sandbox restrictions on filesystem or network access when OpenClicky runs under a hardened profile. Not tested in POC.
5. **`activate_domain` gating.** The 6 tools currently live in the `core` meta-domain (visible in default `tools/list`) rather than a hidden `connector` domain. Adding a new domain requires editing the SPM package roster — off-limits per task constraints. Runtime gate: dispatch returns a `RUNTIME_HOST_ERROR` with actionable text if the subprocess isn't running, so agents get a clear failure mode without the tool actually needing to be hidden.

## Verification

- `swiftc -parse` clean on all 5 new Swift files and the test file.
- `bash scripts/sign-and-install.sh` succeeds; `BUILD SUCCEEDED`; `.app` signed and installed to `/Applications/OpenClicky.app`.
- `ls /Applications/OpenClicky.app/Contents/Resources/OpenConnectorRuntime/` shows `boot.js`, `config.json`, `README.md`, `UPSTREAM_SHA` — runtime bundled correctly via the extended "Copy OpenClicky App Resources" build phase.
- Node boot.js smoke-tested locally: `/health`, `/providers` (index + query modes), `/describe`, `/run`, error paths all return the byte-for-byte envelope shape Everywhere's `ConnectorTools.cs` produces.
