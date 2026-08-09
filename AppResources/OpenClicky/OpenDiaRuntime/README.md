# OpenDiaRuntime

OpenClicky Phase 7.6b F31 — Node.js subprocess for the OpenDia browser
control MCP tool surface.

- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenDia upstream (MIT) pin: see `UPSTREAM_SHA`
- Parity matrix: `Everywhere/docs/specs/PARITY_MATRIX.md`
  (parity-matrix.json sha `ed2e10598c9064aecfaeb7cf21b540684db4be2c`)

## Layout

```
OpenDiaRuntime/
├── boot.js                     # Node entry — spawned by OpenClickyOpenDiaSubprocess
├── UPSTREAM_SHA                # Pinned OpenDia upstream commit
├── node_modules/
│   └── ws/                     # Vendored (MIT) — WebSocket server used by boot.js
├── opendia-mcp/                # Vendored upstream MIT server
│   ├── server.js               #   (unmodified from aaronjmars/opendia)
│   ├── package.json
│   ├── LICENSE                 #   MIT
│   └── node_modules/           #   Vendored opendia-mcp deps
└── opendia-extension/
    └── README.md               # Sideload install instructions
```

## Runtime requirements

- macOS `node` >= 18. Recommended install: `brew install node`.
- Auto-discovery order matches F29 (`OpenClickyOpenDiaSubprocess.resolveNodePath`):
  1. Settings override.
  2. `/opt/homebrew/bin/node`.
  3. `/usr/local/bin/node`.
  4. `~/.nvm/versions/node/*/bin/node` (latest by mtime).
  5. `PATH` fallback (`which node`).

## Contract with the Swift subprocess manager

`boot.js` reads these env vars:

- `OPENCLICKY_OPENDIA_TOKEN` — required, per-launch bearer token.
- `OPENCLICKY_OPENDIA_PORT_MIN` / `_PORT_MAX` — port range (default `56000..57000`).

On successful bind, prints exactly `READY <port>\n` on stdout. All other
stdout/stderr lines are diagnostic.

## HTTP shim (Swift <-> Node)

- `GET /health` (auth-free) — liveness + extension-connected flag.
- `POST /tools` (bearer auth) — list of tools the connected extension registered.
- `POST /call` (bearer auth) — body `{name, arguments, timeout_ms?}`;
  forwards to the extension over WS and returns the matched-id response.

## WebSocket server (Node <-> extension)

Same port as HTTP. The Chrome/Firefox extension connects as a WS client
on `ws://127.0.0.1:<port>/`. Wire protocol matches Everywhere
`OpenDiaBridge.cs` 1:1:

- Register: `{type:"register", tools:[...]}`
- Tool call out: `{id, method, params}`
- Tool response: `{id, result}` or `{id, error}` (or `{id, error:{message}}`)
- Server keepalive: `{type:"ping", timestamp}` every 20s

## Installing dependencies

Dependencies are vendored — no first-launch install step is required:

- `node_modules/ws/` holds the WebSocket server that `boot.js` needs.
- `opendia-mcp/node_modules/` holds the upstream MIT server's deps.

Both trees ship with the .app bundle via the "Copy OpenClicky App
Resources" build phase. If either tree goes missing (e.g. a partial
`git clone` skipped them) reinstall OpenClicky rather than running
`npm install` at runtime — the app expects the vendored trees to be
present and does not spawn `npm` on your behalf.

## Extension install

See `opendia-extension/README.md`. Short version: download the
pre-built extension zip from upstream releases and load unpacked in
Chrome or Firefox — it will discover the local WS port via
extension-side auto-discovery (or manual config).
