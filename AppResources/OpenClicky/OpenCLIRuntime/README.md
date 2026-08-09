# OpenCLI Runtime (Phase 7.6a F30)

Vendored copy of [`jackwener/opencli`](https://github.com/jackwener/opencli) plus
the OpenClicky-side `boot.js` HTTP loopback that backs the three
`opencli_*` MCP tools.

- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenCLI upstream pin: see `UPSTREAM_SHA` (matches `Everywhere/3rd/opencli/UPSTREAM_SHA`).
- OpenCLI upstream tag: see `opencli/UPSTREAM_REF`.

## Layout

- `opencli/clis/` — 173 site adapters (12306, bilibili, arxiv, hackernews, ...). Read-only at runtime; refresh through the Everywhere `scripts/sync-opencli.mjs` script and re-vendor.
- `opencli/runtime/` — the upstream pipeline runner (JavaScript). Not currently exercised by the openclicky POC (`boot.js` implements a minimal inline pipeline interpreter for public/`fetch`-only adapters). Bundled for parity + future upgrade path.
- `opencli/cli-manifest.json` — 1256 adapter registrations, denormalised. `boot.js` reads this once at startup for `opencli_list` / `opencli_describe`.

## Runtime contract with Swift

The Swift side (`OpenClickyOpenCLISubprocess`) spawns `node boot.js` with:

- `OPENCLICKY_OPENCLI_TOKEN` — per-launch UUID, sent as `Authorization: Bearer <token>` on every request.
- `OPENCLICKY_OPENCLI_PORT_MIN` / `_PORT_MAX` — random port in `[55000, 56000)`.
- `OPENCLICKY_OPENCLI_ROOT` — absolute path to this directory.

`boot.js` announces on stdout with a single `READY <port>\n` line as soon as the loopback HTTP server is bound.

### Endpoints

- `GET /health` — no auth. Returns `{ok: true, sites: 173, adapters: 1256, upstream_sha: "..."}`.
- `POST /list` — args `{site?, query?}`. Bearer-auth. Returns `mode: "index" | "site" | "query"` envelope.
- `POST /describe` — args `{site, command}`. Bearer-auth. Returns full adapter description.
- `POST /run` — args `{site, command, arguments_json?}`. Bearer-auth. Executes public/fetch adapters inline; browser-strategy adapters return `{ok:false, code:"BROWSER_NOT_READY"}` until F31 (OpenDia) lands.

## Deviations from Everywhere

- Everywhere embeds V8 (`Microsoft.ClearScript.V8`) in-process. OpenClicky spawns Node as a subprocess (same divergence as F29 open-connector). Node is discovered via the same 5-path lookup as F29 and is not bundled in the `.app`.
- The full pipeline runner in `opencli/runtime/` is not executed by `boot.js` in this phase; adapter-side pipelines are interpreted inline for the `public` subset only. Extending to the full step registry is a follow-up.
