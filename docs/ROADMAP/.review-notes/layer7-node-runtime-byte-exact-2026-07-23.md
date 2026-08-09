# Layer 7 — Node subprocess runtimes: byte-exact audit against Everywhere

**Everywhere pin**: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
**Audit scope**: F29 open-connector / F30 OpenCLI / F31 OpenDia
**Model divergence**: Everywhere runs ClearScript V8 in-process; openclicky
runs an out-of-process Node subprocess per subsystem. Runtime model differs
BY DESIGN — the audit target is the *API contract* (tool names, argument
schemas, response envelope, error codes).

Findings are labeled `OK` (matches), `DIFF-BY-DESIGN` (documented
divergence, no action), or `GAP` (unintended divergence worth surfacing).
This file is REPORT-ONLY — no bugfixes.

---

## F29 open-connector

### Provider bundle count
- **Everywhere upstream**: `3rd/open-connector/dist/connector-manifest.json`
  → **829 services** (verified: `python3 -c "import json;
  m=json.load(open('.../dist/connector-manifest.json')); print(len(m['services']))"`).
  Not "831" — the spec doc may be stale.
- **Openclicky bundle**: `AppResources/OpenClicky/OpenConnectorRuntime/boot.js`
  seeds **2 providers** (`github` + `no_auth_demo`) when no `dist/`
  manifest is present (`boot.js:74-136`).
- **Verdict**: `DIFF-BY-DESIGN` — F29 impl notes call this out as POC
  (`phase7-5-open-connector-2026-07-23.md`). Real bundle production is
  a follow-up. **Doc GAP**: the `upstream_sha` constant
  `847efc10cdff5d6c50b9905ac05c663246f70684` in both boot.js and
  `OpenClickyConnectorBridgeTools.swift:30` is a **connector-repo SHA**,
  not the Everywhere pin. Retain, but do not confuse in future
  cross-checks.

### Six-tool contract
Everywhere `Everywhere.Mcp/Tools/ConnectorTools.cs`:

| tool | args | Everywhere | Openclicky | verdict |
|---|---|---|---|---|
| `connector_list` | `service?`, `query?` | Cap 60 fuzzy `ConnectorTools.cs:95-115` | Same cap in `boot.js:302` and `OpenClickyConnectorBridgeTools.swift:34` | OK |
| `connector_describe` | `service`, `name` | required both `ConnectorTools.cs:164-167` | Same in swift descriptor `.swift:80-88` | OK |
| `connector_run` | `service`, `name`, `arguments_json`, `connection?` | required 3 `ConnectorTools.cs:205-210` | Same in `.swift:98-113` | OK |
| `connector_connect` | `service`, `api_key?`, `display_name?`, `connection?` | only `service` required `ConnectorTools.cs:258-262` | Same in `.swift:124-142` | OK |
| `connector_disconnect` | `service`, `connection?` | required 1 `ConnectorTools.cs:293-295` | Same `.swift:146-156` | OK |
| `connector_list_connections` | (none) | `ConnectorTools.cs:321-323` | Same `.swift:161-166` | OK |

Envelope key order (Everywhere `ConnectorTools.cs:28-40`): `schema_version, ok, service?, name?, error?, code?, data?`. Openclicky matches at `OpenClickyConnectorBridgeTools.swift:483-491`. **OK**.

### Auth token env var
- Everywhere docstring: `EVERYWHERE_CONNECTOR_<SERVICE>_PAT` (per-service
  API-key fallback for JSON store — `ConnectorHostShim.cs:158`,
  `ConnectorTools.cs:200`).
- Openclicky boot.js reads **one** subprocess auth token
  `OPENCLICKY_CONNECTOR_TOKEN` (`boot.js:43`) — Bearer header for the
  loopback HTTP shim. That is a different concept: it authenticates
  Swift→Node HTTP, not Node→SaaS. Everywhere has no analog because V8
  is in-process.
- **Verdict**: `DIFF-BY-DESIGN`. If a caller needs the
  Everywhere-style per-service env var (`EVERYWHERE_CONNECTOR_<SERVICE>_PAT`)
  the openclicky path is `connector_connect(service, api_key=...)` →
  Keychain. **Doc GAP**: tool description still cites the Everywhere env
  var (`OpenClickyConnectorBridgeTools.swift:93`); intentional, matches
  Everywhere line-for-line, but the runtime does not honor that env var
  — only stored credentials. Users may be misled.

### HTTP loopback port range
- Everywhere: **no HTTP** (in-process V8).
- Openclicky: **`[52000, 53000)`** — `OpenClickyConnectorSubprocess.swift:167-168`,
  `boot.js:44-45`. Random pick inside range, retry 10 times on `EADDRINUSE`
  (`boot.js:527-547`).
- **Verdict**: `DIFF-BY-DESIGN`.

### OAuth callback URL scheme
- Everywhere: `OAuthFlowService` — an in-process handler (out of scope
  of this file, in `Connector/OAuthFlowService.cs`). Uses HTTP loopback
  too but on a single server, not per-subprocess.
- Openclicky: separate loopback listener on **`[54000, 55000)`**
  (`OpenClickyConnectorOAuthCallback.swift:68-69`) via `NWListener` with
  `acceptLocalOnly=true` (line 71-73). State TTL 10 min
  (`OpenClickyConnectorOAuthCallback.swift:47`). State passed to Node
  subprocess in `OAUTH_STATES` (`boot.js:226,438-453`) — no TTL enforced
  on Node side, expiration is Swift-owned.
- **Verdict**: `DIFF-BY-DESIGN`. State validation is constant-time
  string compare (`if (!pending)`) on both sides.

### Credential store
- Everywhere: **JSON file** `~/.everywhere/connector/connections.json`
  with AES-256-GCM secret encryption (`JsonCredentialStore.cs:9-33`,
  keyring at `keyring.bin` alongside).
- Openclicky: **macOS Keychain**
  (`OpenClickyConnectorCredentialStore.swift`, referenced from
  `OpenClickyConnectorBridgeTools.swift:299-303`).
- **Verdict**: `DIFF-BY-DESIGN`. Openclicky decrypts in Swift and forwards
  the plaintext credential inline in the `/run` POST body — the Node
  subprocess never sees the Keychain.

### Subprocess crash backoff
- Constants in `OpenClickyConnectorSubprocess.swift:347-361`:
  `maxRestartAttempts = 10`, powers-of-2 capped at 60s. `restartAttempts`
  reset after a successful health probe (`.swift:244`) and after
  explicit `stop()` (`.swift:258`).
- Matches identical shape in F30 (`OpenClickyOpenCLISubprocess.swift:316-329`)
  and F31 (`OpenClickyOpenDiaSubprocess.swift:371-385`).
- **Verdict**: `OK` — perf-fix already landed.

### Node autodiscovery order
Everywhere doesn't ship its own Node — irrelevant. Openclicky order at
`OpenClickyConnectorSubprocess.swift:404-456`:
1. `OpenClickyConnectorSettings.nodePathOverride` (Settings) — line 405-408
2. `/opt/homebrew/bin/node` — line 410
3. `/usr/local/bin/node` — line 411
4. `~/.nvm/versions/node/*/bin/node` sorted by mtime desc — line 417-432
5. `which node` fallback — line 434-451
6. Throw `.nodeNotFound` — line 455

F31 duplicates this ladder at `OpenClickyOpenDiaSubprocess.swift:422-472`.
F30 reuses F29's `resolveNodePath` (`OpenClickyOpenCLISubprocess.swift:127`)
— documented intent: one Node-discovery UX.
**Verdict**: `OK`.

---

## F30 OpenCLI

### Adapter / site count
- Everywhere upstream manifest (`3rd/opencli/cli-manifest.json`): **1257
  adapters, 171 unique sites, 0 private (`_`-prefixed)**.
- Openclicky vendored copy
  (`AppResources/OpenClicky/OpenCLIRuntime/opencli/cli-manifest.json`):
  identical — **1257 adapters, 171 sites, 0 private**.
- **`boot.js:74-80` filters out `_`-prefixed sites** but the current
  upstream manifest ships zero of them, so the runtime advertises the
  full 171/1257.
- **Verdict**: `OK`. The claim "openclicky vendored 171" in the audit
  brief is accurate; the "173 sites" figure in the brief and "F30
  documented 171 (2 privates filtered)" are inconsistent with the actual
  data on both sides (both are 171/0-privates). Retain the filter — it
  is defensive against a future upstream that ships privates.

### Three-tool contract
| tool | Everywhere | Openclicky | verdict |
|---|---|---|---|
| `opencli_list` | `OpenCliTools.cs:41-121`, cap 60 line 72 | boot.js `routeList` cap 60 line 47; bridge descriptor `OpenClickyOpenCLIBridgeTools.swift:46-64` | OK |
| `opencli_describe` | `OpenCliTools.cs:128-145` | boot.js `routeDescribe` `.js:215-236`; swift `.swift:66-79` | OK |
| `opencli_run` | `OpenCliTools.cs:151-250`, `arguments_json` required `MaxDepth=16` line 172 | boot.js `routeRun` `.js:238-317`; swift `.swift:82-98`. **Note**: openclicky does NOT enforce MaxDepth=16 — `JSON.parse` in Node uses default nesting cap. Swift-side does a first-pass validate via `JSONSerialization` (`.swift:191-197`) which has no depth cap. | GAP (documented divergence — MaxDepth guard absent) |

Envelope shape `envelope(ok, site, name, error, code, data)` matches
Everywhere `OpenCliTools.cs:21-34` at `boot.js:105-113`. **OK**.

### Runtime pipeline
- Everywhere: full V8 pipeline runner via `OpenCliRuntime.cs`
  (60KB) + `HostShim.cs` (58KB).
- Openclicky: **6-step inline interpreter**: `fetch, limit, map, filter,
  select, sort` (`boot.js:319-443`). Any other pipeline step throws
  `pipeline step '<op>' not supported by POC interpreter` — sent as
  `RUNTIME_HOST_ERROR`.
- **Verdict**: `DIFF-BY-DESIGN`. Documented as POC in the phase notes.

### `BROWSER_NOT_READY`
- Openclicky boot.js `.js:275-278`: `envelope(false, site, name,
  'opendia-not-connected', 'BROWSER_NOT_READY')` — matches Everywhere
  `OpenCliTools.cs:214` verbatim (message + code). **OK**.
- Openclicky routing: any strategy in `{cookie, intercept, ui}` **or**
  `browser === true` short-circuits before touching the pipeline
  (`boot.js:275-278`). Everywhere applies the same predicate at
  `OpenCliTools.cs:211-214`. **OK**.

### Manifest source
Both sides load `cli-manifest.json`. Openclicky reads from
`OPENCLICKY_OPENCLI_ROOT/opencli/cli-manifest.json` (boot.js:46). **OK**.

### Port range
`[55000, 56000)` — `OpenClickyOpenCLISubprocess.swift:148-149`,
`boot.js:41-42`. No overlap with F29 `[52000, 53000)` /
OAuth `[54000, 55000)` / F31 `[56000, 57000)`. **OK**.

---

## F31 OpenDia

### Tool count vs PARITY_MATRIX
Verified in-repo:
- `docs/specs/PARITY_MATRIX.md` — total 151 rows, distinct
  `our_tool=browser_*` names: **120**
  (`grep 'browser_' PARITY_MATRIX.md | awk '{for(i=1;i<=NF;i++) if($i ~ /^browser_/) print $i}' | sort -u | wc -l`).
- `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift` `toolList` (line 33
  onward): **120** distinct names — exact same set (`comm -23` and
  `comm -13` both produce empty output).
- **Verdict**: `OK`, no regression.

### WS server: `noServer: true` + upgrade handler
- `boot.js:332-337` — `new WebSocketServer({ noServer: true })` with
  `server.on('upgrade', …)` that forwards *any* path to
  `wss.handleUpgrade`. Matches Everywhere `OpenDiaBridge.cs:120-137`
  where the C# `HttpListener` accepts on `/` and `/localhost/` and
  passes the WS upgrade through unfiltered.
- **Verdict**: `OK` (F31 fix I8).

### HTTP shim + auth
- `boot.js:117-120` `authenticate` — string compare `Bearer <TOKEN>`.
  Not constant-time (`===`), but Node's `===` on short strings is not
  a practical timing-attack surface for a locally-bound loopback
  listener. Everywhere has no analog (in-process).
- Swift-side header: `OpenClickyOpenDiaSubprocess.swift:290` sets
  `Authorization: Bearer <authToken>`. **OK**.
- **Verdict**: `DIFF-BY-DESIGN`. Openclicky uses `===` on the token;
  since the check is CPU-local and behind loopback, timing leakage is
  not exploitable. Everywhere skips this class of check entirely.

### READY handshake + 20s keepalive + replace-on-reconnect
- `boot.js:352` `READY <port>\n` on stdout — parsed at
  `.subprocess.swift:352-353,406-417` (three files). **OK**.
- `boot.js:238-241` 20s keepalive `setInterval` — matches
  `OpenDiaBridge.cs:197-221`. **OK**.
- `boot.js:231-233` `extSocket.close(1000, 'replaced')` — matches
  `OpenDiaBridge.cs:164-188`. **OK**.

### Extension bundling
- Everywhere / openclicky: neither bundles. User sideloads from upstream
  releases. `README.md` in `OpenDiaRuntime/` points to `aaronjmars/opendia`.
- **Verdict**: `DIFF-BY-DESIGN` (identical to Everywhere).

### Server-push frames
- `boot.js:264-273`: `if (msg.type && !msg.id)` drops the frame with a
  `process.stderr.write` diagnostic.
- **Everywhere `OpenDiaBridge.cs:357-364` fires `PushFrame` event** —
  wires to `OpenDiaChatBus` (Phase 4 chat sync). Openclicky drops
  silently.
- **Verdict**: `GAP-BY-DESIGN`. F31 impl notes acknowledge this is a
  deferred TODO (`boot.js:264-267`). Chat sync depends on it — future
  F32/F33 work. Log line already present at `boot.js:269-271`.

---

## Cross-cutting audits (all 3 subsystems)

### Autostart default
- All three settings singletons default `enabled = true` when the
  UserDefaults key has never been written:
  - F29 `OpenClickyConnectorSettings.swift:72-78`
  - F30 `OpenClickyOpenCLISettings.swift:38-46`
  - F31 `OpenClickyOpenDiaSettings.swift:52-58`
- Env var force-on: `OPENCLICKY_MCP_{CONNECTOR,OPENCLI,OPENDIA}=1`.
- Autostart hooks fire from `cursor_buddyApp.swift:134,138,144`.
- **Verdict**: `OK`.

### Env injection
- Token env keys:
  - `OPENCLICKY_CONNECTOR_TOKEN` — `OpenClickyConnectorSubprocess.swift:166`,
    read `boot.js:43`
  - `OPENCLICKY_OPENCLI_TOKEN` — `.swift:147`, read `boot.js:40`
  - `OPENCLICKY_OPENDIA_TOKEN` — `.swift:144`, read `boot.js:73`
- Each token is minted per-launch from `UUID().uuidString` at
  `authToken = UUID().uuidString` (all 3 subprocess files line ~150).
  **Not derived from** `AppBundleConfiguration.externalControlBridgeToken()`
  (which reads `OPENCLICKY_BRIDGE_TOKEN` from Keychain, unrelated —
  see `AppBundleConfiguration.swift:206-210`).
- **Verdict**: `OK` — each subprocess is independently authenticated,
  matching the crash-isolation guarantee stated in
  `OpenClickyOpenCLISubprocess.swift:10-16`.

### stderr redaction
- **F31 does redact**: `OpenClickyOpenDiaSubprocess.swift:169-179`
  substitutes token substring with `<redacted-token>` before writing
  to `FileHandle.standardError`.
- **F29 does NOT redact**: `OpenClickyConnectorSubprocess.swift:197-203`
  writes stderr with only a `[connector]` prefix.
- **F30 does NOT redact**: `OpenClickyOpenCLISubprocess.swift:173-178`
  same shape as F29.
- Practical exposure: both boot.js scripts write `process.stderr` only
  in error paths and never include the token, so exposure is
  theoretical. **F31's redaction is defense-in-depth**.
- **Verdict**: `GAP` — F29/F30 should adopt the same redaction pattern.
  Report-only; not fixing in this audit pass.

### stop() teardown
- All three use `DispatchQueue.global(qos: .utility)` for the wait-loop:
  - F29 `OpenClickyConnectorSubprocess.swift:268-278`
  - F30 `OpenClickyOpenCLISubprocess.swift:241-251`
  - F31 `OpenClickyOpenDiaSubprocess.swift:263-273`
- All three drain the readabilityHandlers before checking `isRunning`.
- **Verdict**: `OK` — perf-fix landed uniformly.

### /health endpoint
- F31 has retry 3× × 500ms via `probeHealthWithRetry`
  (`OpenClickyOpenDiaSubprocess.swift:231-244`).
- F29 does **single-shot** health probe
  (`OpenClickyConnectorSubprocess.swift:235`).
- F30 does **single-shot** health probe
  (`OpenClickyOpenCLISubprocess.swift:209`).
- **Verdict**: `GAP` — F29 and F30 lack the same retry policy. The race
  probeHealthWithRetry protects against (HTTP listener bound but not
  accepting) applies identically to F29/F30. Not fixing in this pass;
  report-only.

### Envelope shape (F32-F36 wrap)
- All three bridge-tool files wrap the JSON body in
  `{"type": "text", "text": <json string>}`:
  - F29 `OpenClickyConnectorBridgeTools.swift:475-480`
  - F30 `OpenClickyOpenCLIBridgeTools.swift:222-226`
  - F31 `OpenClickyOpenDiaBridgeTools.swift` (compressed view — the
    file shows same shape).
- Every non-error path defaults `schema_version = "1"` if the boot.js
  reply omits it. Every path defaults `ok = false` on unknown.
- **Verdict**: `OK`.

---

## Summary table

| ID | Subsystem | Class | Finding |
|---|---|---|---|
| 1 | F29 | DIFF-BY-DESIGN | Provider count 2 seeded vs Everywhere 829 (upstream count is 829, not 831 as the brief states) |
| 2 | F29 | OK | 6-tool contract byte-for-byte |
| 3 | F29 | DIFF-BY-DESIGN | Env var name divergence documented (openclicky uses Keychain) |
| 4 | F29 | DIFF-BY-DESIGN | HTTP loopback port [52000,53000) |
| 5 | F29 | DIFF-BY-DESIGN | OAuth callback listener on [54000,55000) |
| 6 | F29 | DIFF-BY-DESIGN | Credential store: Keychain vs ~/.everywhere JSON |
| 7 | F29 | OK | Exponential backoff constants (max 60s, cap 10) match F31 |
| 8 | F29 | OK | Node autodiscovery 5-step ladder |
| 9 | F29 | GAP | stderr redaction absent |
| 10 | F29 | GAP | /health single-shot, no 3×500ms retry |
| 11 | F30 | OK | 171 sites / 1257 adapters (brief mentioned 173/171 — both figures inconsistent with the actual manifest) |
| 12 | F30 | OK | 3-tool contract byte-for-byte |
| 13 | F30 | GAP | MaxDepth=16 JSON guard absent on Node side |
| 14 | F30 | DIFF-BY-DESIGN | Pipeline interpreter minimal 6-step vs full V8 |
| 15 | F30 | OK | BROWSER_NOT_READY code+message |
| 16 | F30 | OK | Port [55000,56000) no collision |
| 17 | F30 | GAP | stderr redaction absent |
| 18 | F30 | GAP | /health single-shot, no 3×500ms retry |
| 19 | F31 | OK | 120 browser_* tools — exact match with PARITY_MATRIX |
| 20 | F31 | OK | WS noServer+upgrade any-path |
| 21 | F31 | OK | Bearer token auth (loopback) |
| 22 | F31 | OK | 20s keepalive + replace-on-reconnect |
| 23 | F31 | DIFF-BY-DESIGN | Server-push dropped with stderr diagnostic (deferred, TODO in boot.js) |
| 24 | F31 | OK | stderr redaction present |
| 25 | F31 | OK | /health 3×500ms retry |
| 26 | ALL | OK | Autostart default-on |
| 27 | ALL | OK | Independent per-launch token envs |
| 28 | ALL | OK | stop() teardown off @MainActor |
| 29 | ALL | OK | Envelope wrap `{type:text, text:<json>}` |

**GAP count**: 5 (F29-redaction, F29-health-retry, F30-MaxDepth,
F30-redaction, F30-health-retry). None urgent; all defense-in-depth.
Not fixed in this audit pass per constraints.

## Debug log surface added

Each subsystem got these `os_log` emitters (subsystem
`com.jkneen.openclicky`, category `Layer7-<Connector|OpenCLI|OpenDia>`):

- `subprocess.start_attempt` — node path, port range, attempt index
- `subprocess.ready` — bound port, boot elapsed ms
- `subprocess.crash` — exit code, attempt index, computed backoff seconds
- `subprocess.health_probe` — status + retry count
- `subprocess.stop` — reason
- `tool_call` — tool name, arg byte length, ok flag, latency ms

Logs are structured (key=value) so `log stream --predicate 'subsystem
== "com.jkneen.openclicky"'` picks them up in Console.app.
