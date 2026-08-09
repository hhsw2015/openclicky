# OpenConnectorRuntime

OpenClicky Phase 7.5 F29 — Node.js subprocess for the open-connector
MCP tool surface.

- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- open-connector upstream pin: `847efc10cdff5d6c50b9905ac05c663246f70684`

## Layout

```
OpenConnectorRuntime/
├── boot.js               # Node entry — spawned by OpenClickyConnectorSubprocess
├── config.json           # Provider allow/disallow lists (fallback for headless runs)
├── UPSTREAM_SHA          # Pinned open-connector SHA
└── open-connector/       # (optional) Vendored `oomol-lab/open-connector` sources
    └── dist/
        ├── connector.bundle.js
        └── connector-manifest.json
```

## Runtime requirements

- macOS `node` >= 18. Recommended install: `brew install node`.
- Auto-discovery order (see `OpenClickyConnectorSubprocess.resolveNodePath`):
  1. Settings override.
  2. `/opt/homebrew/bin/node`.
  3. `/usr/local/bin/node`.
  4. `~/.nvm/versions/node/*/bin/node` (latest by mtime).
  5. `PATH` fallback (`which node`).

## Contract

- Reads env vars from parent process:
  - `OPENCLICKY_CONNECTOR_TOKEN` — required, per-launch bearer token.
  - `OPENCLICKY_CONNECTOR_PORT_MIN` / `_PORT_MAX` — port range (default `52000..53000`).
  - `OPENCLICKY_CONNECTOR_OAUTH_CALLBACK` — OAuth loopback URL from the Swift side.
- On successful bind, prints exactly `READY <port>\n` on stdout.
- All other stdout/stderr lines are diagnostic.

## Bundle-mode vs seeded-mode

`boot.js` looks for `open-connector/dist/connector-manifest.json`.
When present, it serves the full 831-provider catalog. When absent
(POC state), it serves a minimal two-provider seed manifest (`github`
+ `no_auth_demo`) so the six MCP tools are exercisable end-to-end.

Producing the real bundle requires:

```
cd open-connector
npm install
node ../../scripts/build-connector-bundle.mjs
```

(This mirrors Everywhere's Phase-5 esbuild pipeline; the build script
lives outside this directory to keep vendored upstream untouched.)
