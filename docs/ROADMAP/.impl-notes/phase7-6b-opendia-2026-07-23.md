# Phase 7.6b F31 — OpenDia integration investigation notes

- Date: 2026-07-23
- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenDia upstream (MIT): `aaronjmars/opendia` — local checkout at `/Users/wowdd1/Dev/opendia/`
- Everywhere fork referenced in task text: `hhsw2015/opendia` (branch `experiment/replace-ab`).
  Not vendored locally; PARITY_MATRIX.md is the authoritative source of the
  tool surface we need to expose.

## Ground truth for the tool list

The task brief claims "85 WS ops". The PARITY_MATRIX.md at Everywhere pin
above (rendered from `parity-matrix.json` sha
`ed2e10598c9064aecfaeb7cf21b540684db4be2c`) contains **120** `browser_*`
tools whose ownership is either `opendia` or `universal` and whose status
is `in-progress` (one `blocked` — `browser_read`).

The "85" in the task brief corresponds to a subset of that matrix (the
non-`universal` core opendia tools). To keep zero-drift with Everywhere
we register **all 120** `browser_*` tools that Everywhere plans to route
through OpenDia + universal handling. `browser_read` is included in the
list even though its status is `blocked` upstream — the extension will
return an error for it, matching upstream shape.

The registered list is captured in `OpenClickyOpenDiaBridgeTools.swift`
as a single static array.

## LICENSE

Upstream `aaronjmars/opendia` is **MIT** (`LICENSE` header:
`Copyright (c) 2025 OpenDia Team`). Vendoring is straightforward — we
duplicate `LICENSE` and `README.md` into `OpenDiaRuntime/THIRD_PARTY/`
and record the pinned SHA in `UPSTREAM_SHA`.

The Everywhere fork was mentioned in the task brief but is not required
for compliance — we route the tool surface (protocol + tool names)
through the MIT upstream extension. Tools that only exist in the
Everywhere fork will return
`{ok:false, code:"UNKNOWN_TOOL", ...}` from the extension. The MCP
`tools/list` still advertises them for parity with Everywhere's
`tools/list`.

## Architecture

Mirrors F29/F30:

```
Swift  --HTTP--> Node (boot.js) <--WS--> Chrome/Firefox extension
```

The Chrome extension itself connects as a WebSocket **client** to the
Node server on `ws://127.0.0.1:<port>`. Swift never talks WS — it goes
through the local HTTP shim exposed by `boot.js`. That gives us:

- Same auth-token pattern as F29/F30 (Authorization: Bearer <token>).
- Same subprocess lifecycle (`READY <port>` on stdout, SIGTERM on stop).
- One place to serialize concurrent tool calls before they hit the
  extension.

Port range: `[56000, 57000)` (F29 uses 52000-53000, F30 uses 54000-55000
per convention — F31 gets the next slot).

## Files planned

- `AppResources/OpenClicky/OpenDiaRuntime/boot.js`
- `AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA`
- `AppResources/OpenClicky/OpenDiaRuntime/README.md`
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/server.js` (upstream MIT server, vendored)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/package.json` (upstream)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/LICENSE` (MIT)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md` (install pointer to
  releases zip; the multi-hundred-MB extension source is intentionally
  NOT bundled — user downloads the pre-built extension zip from
  upstream)
- `cursor-buddy/OpenClickyOpenDiaSubprocess.swift`
- `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift`
- `cursor-buddy/OpenClickyOpenDiaSettings.swift`

Bridge wire (`OpenClickyExternalControlBridge.swift`):
1. Append 120 names to `sensorToolNames`.
2. Add domain map entries: 120 -> `OpenClickyMetaDomain.browser`.
3. Append descriptors to `sensorToolDescriptorsRaw`.
4. Dispatch case (prefix match `browser_`).

App wire (`cursor_buddyApp.swift`):
- `OpenClickyOpenDiaSettings.autostartIfEnabled()` in `applicationDidFinishLaunching`.
- `OpenClickyOpenDiaSubprocess.shared.stop()` in `applicationWillTerminate`.

Pbxproj wire:
- Append `OpenDiaRuntime` to the resource-copy shell script.

## Why not bundle the full extension source

The upstream `opendia-extension/` directory ships with a 544 MB
`node_modules/` tree. Even after pruning, the built extension is 11 MB
per browser. The pre-built extension zip is already available upstream
at `releases/opendia-chrome-1.0.6.zip`; we point users to it via
`README.md` + a first-launch prompt (Settings copy). That keeps our
`.app` bundle lean.
