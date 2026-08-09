# Phase 7.6a F30 — OpenCLI site adapter port investigation

- Date: 2026-07-23
- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenCLI upstream: `9161d99d96ec107cd77f13a30315614129179a1a` (tag `v1.8.5`, sourced from `Everywhere/3rd/opencli/UPSTREAM_SHA`)

## Sources consulted

1. `Everywhere/docs/specs/everywhere-opencli-adapters.md` — 3 tool contract, IPage surface, phase 1 / phase 2 strategy split.
2. `Everywhere/src/Everywhere.Mcp/Tools/OpenCliTools.cs` — the 3 tool signatures and response envelopes we mirror byte-for-byte:
   - `opencli_list(site?, query?)` → index / drill / query modes.
   - `opencli_describe(site, name)` → full describe envelope.
   - `opencli_run(site, name, arguments_json)` → execute; `BROWSER_NOT_READY` when strategy in {cookie,intercept,ui} and no OpenDia.
3. `Everywhere/src/Everywhere.Mcp/OpenCli/AdapterDef.cs` — `ToListEntry` and `ToDescribeJson` shapes we replicate on the Node side directly from `cli-manifest.json`.
4. `Everywhere/3rd/opencli/clis/12306/*.js` — every adapter is a `cli({...})` registration with metadata + a `pipeline` YAML-ish array (or `func`). All metadata is already denormalised into `cli-manifest.json` (1256 entries).
5. F29 pattern re-used verbatim: `OpenClickyConnectorSubprocess.swift` (Node discovery, READY-line handshake, bearer token), `OpenClickyConnectorBridgeTools.swift` (envelope helpers, dispatch), `OpenClickyConnectorSettings.swift`.

## Design decisions / divergences

1. **ClearScript V8 isolate → Node subprocess** (documented divergence — same rationale as F29). No V8 embedding in Swift. Adapters are ES modules; a full pipeline interpreter is out of scope for F30; we ship the vendored `clis/` + `runtime/` for future work and serve `list` / `describe` off `cli-manifest.json`.
2. **`opencli_run` behavior** (Phase 7.6a POC scope):
   - `strategy=public` (no browser): attempt inline execution against a minimal built-in pipeline interpreter supporting `fetch` / `limit` / `map` / `filter` / `select` / `sort` steps. Adapters that require more (e.g. `intercept`, `evaluate` in a real page) → `{ok:false, code:"RUNTIME_NOT_IMPLEMENTED"}`.
   - `strategy` in `{cookie, intercept, ui}` OR `browser=true`: return `{ok:false, code:"BROWSER_NOT_READY", error:"opendia-not-connected"}` (matches SPEC §2.1). F31 (OpenDia) will fill this.
3. **Port range**: F29 owns `[52000, 53000)`; F30 uses `[55000, 56000)`. Auth token env var `OPENCLICKY_OPENCLI_TOKEN` (F29 uses `OPENCLICKY_CONNECTOR_TOKEN`). Independent subprocess — do not share with F29.
4. **Meta domain**: the SPM meta-domain roster is off-limits per phase constraints. Tools live in `core` at registry-registration time (same shape F29 used).
5. **Site listing**: sorted by `site` ascending (matches `OpenCliTools.cs` `OrderBy(g => g.Key, StringComparer.Ordinal)`). Total commands count comes from manifest length (1256). Site count comes from unique-site set (173, plus a `_shared` pseudo-entry — filter out entries whose site starts with `_`).
6. **Fuzzy cap**: 60 matches (SPEC §4 / `Cap = 60`).
7. **Description contains PUBLIC vs browser hint**: preserved in tool descriptions.
8. **JSON envelope**: `schema_version: "1"` + `ok` + `site`/`name`/`error`/`code`/`data` (matches `OpenCliTools.Envelope`).

## Wire-up map

- Bridge extension points (bytewise mirror F29):
  1. Add `opencli_list` / `opencli_describe` / `opencli_run` to `sensorToolNames` (line ~1707 in `OpenClickyExternalControlBridge.swift`).
  2. Add same to `sensorToolDomains` mapping to `.core` (same rationale as F29).
  3. Append `+ OpenClickyOpenCLIBridgeTools.descriptorsRaw` to the return of `sensorToolDescriptorsRaw` (line ~2325).
  4. Add dispatch cases before `default:` in `executeSensorTool` switch (line ~2850).
- Autostart: piggyback onto F29 pattern — `OpenClickyOpenCLISettings.autostartIfEnabled()` from `applicationDidFinishLaunching`; `.stop()` from `applicationWillTerminate`.
- Xcode: extend the "Copy OpenClicky App Resources" ditto list to include `OpenCLIRuntime`.

## File plan

- `AppResources/OpenClicky/OpenCLIRuntime/boot.js` — HTTP loopback, token auth, `/list`, `/describe`, `/run`, `/health`, minimal inline pipeline interpreter.
- `AppResources/OpenClicky/OpenCLIRuntime/opencli/` — vendored copy of `Everywhere/3rd/opencli/` (`clis/`, `runtime/`, `cli-manifest.json`, `UPSTREAM_SHA`, `UPSTREAM_REF`).
- `AppResources/OpenClicky/OpenCLIRuntime/UPSTREAM_SHA` — pinned opencli sha (`9161d99d96ec107cd77f13a30315614129179a1a`).
- `AppResources/OpenClicky/OpenCLIRuntime/README.md` — runtime contract + install notes.
- `cursor-buddy/OpenClickyOpenCLISubprocess.swift` — Node subprocess (clone of F29, different env vars + port range).
- `cursor-buddy/OpenClickyOpenCLIBridgeTools.swift` — 3 tool descriptors + dispatch.
- `cursor-buddy/OpenClickyOpenCLISettings.swift` — master enable toggle + autostart hook + runtime status.
- `cursor-buddy/OpenClickyExternalControlBridge.swift` — 4 extension points only.
- `cursor-buddy/cursor_buddyApp.swift` — 2 lines (autostart + stop).
- `cursor-buddy.xcodeproj/project.pbxproj` — extend ditto list with `OpenCLIRuntime`.

## Alignment matrix vs `OpenCliTools.cs`

| Field | Everywhere | openclicky |
|---|---|---|
| Tool name | `opencli_list` | `opencli_list` |
| List no-args → `mode` | `"index"` | `"index"` |
| Site drill → carries `commands` array of `ToListEntry()` | yes | yes (from manifest) |
| Query cap | 60 | 60 |
| `schema_version` | `"1"` | `"1"` |
| `upstream_sha` echoed | yes | yes |
| `RUNTIME_NOT_FOUND` code on missing site/name | yes | yes |
| Describe envelope keys | site,name,description,strategy,browser,args,columns,access?,domain?,aliases? | same |
| Run failure `BROWSER_NOT_READY` message | `"opendia-not-connected"` | `"opendia-not-connected"` |

Note: Everywhere's `ToDescribeJson` emits `access` / `domain` conditionally (only when non-null); we mirror that with a manifest-driven emit filter.
