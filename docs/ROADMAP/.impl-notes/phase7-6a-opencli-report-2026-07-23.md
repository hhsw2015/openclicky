# Phase 7.6a F30 — OpenCLI adapter landing report

- **Date**: 2026-07-23
- **Everywhere upstream pin**: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- **OpenCLI upstream pin**: `9161d99d96ec107cd77f13a30315614129179a1a` (tag `v1.8.5`)

## Summary

Ported Everywhere's `Everywhere.Mcp.Tools.OpenCliTools` 3-tool MCP surface (`opencli_list` / `opencli_describe` / `opencli_run`) to openclicky. The Swift scaffolding (subprocess manager, bridge tools, settings, autostart) mirrors the F29 open-connector shape. The Node subprocess (`boot.js`) serves list/describe directly off `cli-manifest.json` (1257 adapters across 171 sites) and implements a minimal inline pipeline interpreter (fetch/limit/map/filter/select/sort) for public/fetch adapters; browser-strategy adapters (cookie/intercept/ui) return `{ok:false, code:"BROWSER_NOT_READY", error:"opendia-not-connected"}` per SPEC §2.1, matching Everywhere's behavior when OpenDia is disconnected.

## Files created

| Path | Purpose | Lines |
|---|---|---|
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOpenCLISubprocess.swift` | Node subprocess lifecycle (start/stop/crash-restart, READY-line handshake, bearer-token HTTP wrapper). Independent from F29. | 289 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOpenCLIBridgeTools.swift` | 3 MCP tool descriptors + dispatch, byte-for-byte with `OpenCliTools.cs`. | 217 |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOpenCLISettings.swift` | UserDefaults master toggle + autostart hook + runtime status. | 82 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenCLIRuntime/boot.js` | Node subprocess entry — 4 HTTP routes + manifest loader + inline pipeline interpreter. | 372 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenCLIRuntime/opencli/` | Vendored `jackwener/opencli` tree (`clis/` + `runtime/` + `cli-manifest.json` + `UPSTREAM_SHA` + `UPSTREAM_REF`). 9.3 MB, 173 dirs (171 unique sites after filtering `_*` private modules), 1257 adapter registrations. | — |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenCLIRuntime/UPSTREAM_SHA` | Pinned OpenCLI SHA (`9161d99d96ec107cd77f13a30315614129179a1a`). | 1 |
| `/Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenCLIRuntime/README.md` | Runtime contract + install notes. | 45 |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase7-6a-opencli-2026-07-23.md` | Investigation + design decisions. | 90 |

## Files modified

| Path | Change |
|---|---|
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyExternalControlBridge.swift` | 4-point wire-up: added 3 names to `sensorToolNames`, mapped to `.core` in `sensorToolDomains`, appended `+ OpenClickyOpenCLIBridgeTools.descriptorsRaw` to `sensorToolDescriptorsRaw`, added dispatch case in `executeSensorTool` switch. |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy/cursor_buddyApp.swift` | 2 lines added: autostart call in `applicationDidFinishLaunching`, `stop()` in `applicationWillTerminate`. |
| `/Users/wowdd1/Dev/openclicky/cursor-buddy.xcodeproj/project.pbxproj` | Added `OpenCLIRuntime` to the "Copy OpenClicky App Resources" ditto list. |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/09_MIGRATION_ORDER.md` | Rewrote Phase 7.6a OpenCLI checklist with actual paths, marked deviations. |
| `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/11_REVIEW_CHECKLIST.md` | Updated F30 section with actual file paths, deviations, upstream pin. |

## 3 MCP tool descriptors (verbatim, from `OpenClickyOpenCLIBridgeTools.descriptorsRaw`)

- **`opencli_list`** — args `{site?: string, query?: string}`. No args → index; site → per-site drill; query → fuzzy match (cap 60). Envelopes: `{schema_version:"1", ok:true, mode:"index"|"site"|"query", sites|commands, total_commands|total_matches, hint, upstream_sha}`.
- **`opencli_describe`** — args `{site: string, name: string}` (both required). Envelope: `{schema_version:"1", site, name, description, strategy, browser, args, columns, access?, domain?, aliases?, upstream_sha}`.
- **`opencli_run`** — args `{site: string, name: string, arguments_json: string}` (all required). `arguments_json` must be a JSON object as a string. Envelope on success: `{schema_version:"1", ok:true, site, name, data, elapsed_ms}`. On browser strategy: `{schema_version:"1", ok:false, site, name, error:"opendia-not-connected", code:"BROWSER_NOT_READY"}`.

## Node bundling strategy (chosen)

**System Node via auto-discovery** — same shape as F29 (reuses `OpenClickyConnectorSubprocess.resolveNodePath()` verbatim):

1. Settings override (`OpenClickyConnectorSettings.nodePathOverride`, shared with F29).
2. `/opt/homebrew/bin/node`.
3. `/usr/local/bin/node`.
4. `~/.nvm/versions/node/*/bin/node` (most-recent by mtime).
5. `PATH` fallback (`which node`).

Missing Node triggers a clear `OpenClickyOpenCLISubprocessError.nodeNotFound` with an actionable message pointing at `brew install node`.

## Alignment audit vs `OpenCliTools.cs` (byte-level)

| Item | `OpenCliTools.cs` | `OpenClickyOpenCLIBridgeTools` | boot.js |
|---|---|---|---|
| Tool names | `opencli_list`, `opencli_describe`, `opencli_run` | same | same |
| Arg keys | `site`, `name`, `query`, `arguments_json` | same | same |
| `schema_version` | `"1"` | `"1"` (defaulted) | `"1"` |
| Query cap | `60` | `60` (`queryCap` constant) | `60` (`QUERY_CAP` constant) |
| List `mode` values | `"index"`, `"query"`, plus per-site drill | mirrored via subprocess | `"index"`, `"query"`, `"site"` |
| List sort | `OrderBy(g => g.Key, StringComparer.Ordinal)` | pass-through | `sort((a,b)=>a[0].localeCompare(b[0]))` (ordinal-ish, adequate for ASCII site keys) |
| Describe missing site → `RUNTIME_NOT_FOUND` | yes | pass-through | yes |
| Describe missing action → `RUNTIME_NOT_FOUND` | yes | pass-through | yes |
| Run bad `arguments_json` → `BAD_ARGS` | yes | yes (`BAD_ARGS`) | yes |
| Run browser strategy w/o OpenDia | `{ok:false, error:"opendia-not-connected", code:"BROWSER_NOT_READY"}` | pass-through | exact match |
| Run success envelope keys | `schema_version, ok, data, site, name, elapsed_ms` | pass-through | exact match |
| `local` strategy | not supported (SPEC §2.4 #7) | pass-through | `RUNTIME_NOT_IMPLEMENTED` |

## Site count logged at boot

`boot.js` writes to stderr on startup:
```
[opencli] serving 1257 adapters across 171 sites on 127.0.0.1:<port>
```
Site count differs from spec's "173" because the vendored tree includes two `_`-prefixed private modules (`_atlassian`, `_shared`) which the manifest loader filters out — they are shared library dirs, not user-facing sites. Adapter registrations: 1257 total.

## Manual test recipe (verified 2026-07-23)

Run `boot.js` directly with a test token (bypasses Swift for a fast round-trip):

```sh
export OPENCLICKY_OPENCLI_TOKEN=testtok
node /Users/wowdd1/Dev/openclicky/AppResources/OpenClicky/OpenCLIRuntime/boot.js &
# READY <port> is printed to stdout, e.g. "READY 55807"
PORT=55807  # substitute the printed value

# 1. Health (no auth)
curl -s "http://127.0.0.1:$PORT/health"
# => {"ok":true,"sites":171,"adapters":1257,"upstream_sha":"9161d99d..."}

# 2. Index list
curl -s -H "Authorization: Bearer testtok" -H "Content-Type: application/json" \
     -X POST -d '{}' "http://127.0.0.1:$PORT/list" | head -c 300
# => {"schema_version":"1","ok":true,"mode":"index","sites":[{"site":"12306","count":9,...}, ...

# 3. Site drill
curl -s -H "Authorization: Bearer testtok" -H "Content-Type: application/json" \
     -X POST -d '{"site":"12306"}' "http://127.0.0.1:$PORT/list"
# => {"schema_version":"1","ok":true,"mode":"site","site":"12306","commands":[{...login...},...]}

# 4. Describe
curl -s -H "Authorization: Bearer testtok" -H "Content-Type: application/json" \
     -X POST -d '{"site":"12306","name":"login"}' "http://127.0.0.1:$PORT/describe"
# => {"schema_version":"1","site":"12306","name":"login","description":"Open 12306 login and wait...","strategy":"cookie","browser":true,"args":[{...timeout...}],"columns":[...],"access":"write","domain":"12306.cn","upstream_sha":"..."}

# 5. Run (browser adapter -> BROWSER_NOT_READY)
curl -s -H "Authorization: Bearer testtok" -H "Content-Type: application/json" \
     -X POST -d '{"site":"12306","name":"login","arguments_json":"{}"}' \
     "http://127.0.0.1:$PORT/run"
# => {"schema_version":"1","ok":false,"site":"12306","name":"login","error":"opendia-not-connected","code":"BROWSER_NOT_READY"}
```

All five roundtrips returned the expected shapes during the 2026-07-23 landing session.

## Swift parse-check

```sh
swiftc -parse \
  cursor-buddy/OpenClickyOpenCLISubprocess.swift \
  cursor-buddy/OpenClickyOpenCLIBridgeTools.swift \
  cursor-buddy/OpenClickyOpenCLISettings.swift \
  cursor-buddy/OpenClickyExternalControlBridge.swift \
  cursor-buddy/cursor_buddyApp.swift
```
All files parse without diagnostics.

## Known limitations

1. **No Xcode build attempted**. Per CLAUDE.md, `xcodebuild` from the terminal is prohibited; run `bash scripts/sign-and-install.sh` from Xcode or run the app to confirm the runtime is bundled. All new Swift files pass `swiftc -parse`; the four-point wire-up mirrors F29 which is known-good.
2. **Xcode file registrations**: the `.xcodeproj` uses a synthesized Swift-source list (no per-file `PBXBuildFile` entries for `.swift`), so the three new Swift files are picked up automatically on next Xcode index sweep. `OpenCLIRuntime` is added to the resource-copy shell script (parity with `OpenConnectorRuntime`).
3. **Browser-strategy adapters**: every adapter with `strategy` in `{cookie, intercept, ui}` (majority of the 1257) returns `BROWSER_NOT_READY` until F31 (OpenDia bridge) lands. This is intentional and matches SPEC §2.1.
4. **`local` strategy**: forbidden per SPEC §2.4 #7; returns `RUNTIME_NOT_IMPLEMENTED`.
5. **Inline pipeline interpreter**: only 6 step ops supported (`fetch`, `limit`, `map`, `filter`, `select`, `sort`). Adapters that rely on upstream-only steps (`intercept`, `evaluate`, `download`, `tap`, `press`, etc.) return `RUNTIME_NOT_IMPLEMENTED`. The full step registry lives under `opencli/runtime/pipeline/` and can be wired into `boot.js` in a follow-up without changing the Swift or bridge surface.
6. **Adapter modules are ES modules that `import` from `@jackwener/opencli/registry`** — that npm package is not shipped in the runtime bundle. Because `boot.js` synthesises pipeline execution from `cli-manifest.json` rather than executing the raw `.js`, the missing registry package is not a blocker for the listable / describable subset; adapters where the manifest denormalises the pipeline are runnable. When a manifest entry lacks a `pipeline` array, `opencli_run` returns `RUNTIME_NOT_IMPLEMENTED` with a clear diagnostic (SPEC §2.4 #1 forbids re-executing the pipeline runner in-tree, so this is compliant).
7. **macOS sandbox**: OpenClicky today ships with the sandbox off (no App Store distribution); Node child-process + loopback HTTP work as expected. If sandboxing is enabled in a future revision, the runtime will need `com.apple.security.network.client` and `com.apple.security.temporary-exception.files.absolute-path.read-only` for `~/.nvm` (see F29 report).

## Zero-drift check

- Everywhere pin `30e03e9dcfdd4247fd679828ed86e9042f32d809` recorded in every new file header.
- OpenCLI pin `9161d99d96ec107cd77f13a30315614129179a1a` recorded in `UPSTREAM_SHA`, `boot.js` header, and Swift file headers.
- Vendored `3rd/opencli/UPSTREAM_SHA` copied verbatim into `AppResources/OpenClicky/OpenCLIRuntime/UPSTREAM_SHA`.
- Vendored `3rd/opencli/UPSTREAM_REF` (`v1.8.5`) preserved under `opencli/UPSTREAM_REF`.
