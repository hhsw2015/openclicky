# F31 OpenDia integration review — 2026-07-23

- Everywhere pin under review: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenDia (MIT) vendored SHA: `304345754cc99b24c07a3289a2e27abd5a5c19bb`
  (`AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA:3`)
- Parity matrix consulted: `Everywhere/docs/specs/PARITY_MATRIX.md`
  (json sha `ed2e10598c9064aecfaeb7cf21b540684db4be2c`)
- Scope: subprocess manager, boot.js runtime, MCP bridge dispatch,
  settings, extension bundling policy, LICENSE.

Methodology: byte-diff of the openclicky tool set vs the parity matrix
tool set, cross-read against `Everywhere.Mcp.OpenDia.OpenDiaBridge.cs`
for wire-protocol parity, and static-audit of the Swift/Node
subprocess sources.

## Alignment table

| Claim (task brief / landing report) | Actual | Evidence |
|---|---|---|
| 120 `browser_*` tools registered | 120 unique names in `toolList` | `OpenClickyOpenDiaBridgeTools.swift:33-154`, `wc -l /tmp/openclicky_tools.txt = 120` |
| Byte-exact match against parity matrix | Zero-diff after stripping the 4 `everywhere.clipboard_*` rows that live in the everywhere ownership column | `diff /tmp/parity_browser_tools.txt /tmp/openclicky_tools.txt` returned empty |
| All prefixed `browser_` per `OpenDiaToolListBuilder.Prefix` | Every entry starts with `browser_` | `OpenClickyOpenDiaBridgeTools.swift:34-153`; matches `Everywhere/src/Everywhere.Mcp/OpenDia/OpenDiaToolListBuilder.cs:14` |
| No extras beyond parity matrix | None | diff run above |
| Subprocess shape mirrors F29/F30 | Same `stateQueue`, `READY <port>` handshake, `terminationHandler`, health probe, auto-restart | `OpenClickyOpenDiaSubprocess.swift:60-208`, cf. `OpenClickyConnectorSubprocess.swift:113,204-209,315` |
| Port range `[56000, 57000)` non-overlapping | Configured, no collision with F29 `[52000,53000)` (`OpenClickyConnectorSubprocess.swift:156-157`) or F30 `[55000,56000)` (`OpenClickyOpenCLISubprocess.swift:137-138`) | `OpenClickyOpenDiaSubprocess.swift:134-135`, `boot.js:72-73` |
| `OPENCLICKY_OPENDIA_TOKEN` bearer on all non-health | Swift sets header on every request; Node exempts only `/health` | `OpenClickyOpenDiaSubprocess.swift:242`, `boot.js:115-118,144-155` |
| READY handshake + 20s keepalive + replace-on-reconnect | Present; matches Everywhere semantics | `boot.js:236-239` (keepalive), `boot.js:229-232` (replace), `boot.js:281-294` (stale-close guard). Compare `OpenDiaBridge.cs:164-188` and `:196-221` |
| HTTP shim endpoints `/health`, `/tools`, `/call` | Implemented, shapes documented | `boot.js:144-218` |
| Bridge wire: 120 names added to `sensorToolNamesBase.union` | Union in place | `OpenClickyExternalControlBridge.swift:1807-1809` |
| All 120 pinned to `OpenClickyMetaDomain.browser` (hidden until `activate_domain name=browser`) | Loop pins every entry | `OpenClickyExternalControlBridge.swift:1940-1946`, domain constant `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift:73` |
| Prefix-based dispatch, no per-tool switch | Single `default:` prefix + set-membership check | `OpenClickyExternalControlBridge.swift:3088-3092` |
| App lifecycle hooked | Autostart in `applicationDidFinishLaunching`, stop in `applicationWillTerminate` | `cursor_buddyApp.swift:140-144,152` |
| MIT `aaronjmars/opendia` vendored, Everywhere fork NOT vendored | `opendia-mcp/LICENSE` MIT; no Everywhere fork tree on FS; parity matrix used as source of truth | `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/LICENSE`, `UPSTREAM_SHA:1-11` |
| Extension NOT bundled; user sideloads | Directory holds only `README.md` with install steps | `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md:1-53` |
| Unknown tools return `{ok:false, code:"UNKNOWN_TOOL"}` | Yes at the Swift bridge; Node forwards whatever the extension replies for tools the ext does not implement | `OpenClickyOpenDiaBridgeTools.swift:189-193` |
| Independent Node process from F29 | Own binary/port/token | see port + token env vars above |

## Issues

### I1 — [HIGH] `OpenClickyOpenDiaSettings` has no SwiftUI consumer, so the master toggle is unreachable from the shipping UI

`grep -rn OpenClickyOpenDiaSettings /Users/wowdd1/Dev/openclicky --include="*.swift"` returns
only the definition, `cursor_buddyApp.swift:144`, and one self-lookup for
the node-path override. Nothing in
`OpenClickySettingsWindowManager.swift`, `CompanionPanelView.swift`, or
`OpenClickyNotchPanelView.swift` reads `enabled` / `runtimeStatus` /
`extensionConnected`. Users cannot turn OpenDia on except via
`OPENCLICKY_MCP_OPENDIA=1` (env override in
`OpenClickyOpenDiaSettings.swift:49`) or by hand-writing the
`openclicky.opendia.enabled` UserDefaults key. The landing report and
the extension README (`opendia-extension/README.md:15`) both talk about
"Enable OpenDia in OpenClicky Settings", so shipping without the pane
breaks that documented flow.

### I2 — [HIGH] `boot.js`'s "install deps on first launch" contract is not implemented

`AppResources/OpenClicky/OpenDiaRuntime/README.md:66-75` promises a
"Settings pane exposes one-click Install dependencies button", but no
such code exists (see I1) and `boot.js:52-68` hard-exits with code 3
when `ws` is missing. The vendored tree currently contains
`opendia-mcp/node_modules/` (verified via `ls`), so the exit path
happens only if the bundle is trimmed before shipping — but there is no
build-time check enforcing that `node_modules/ws` ships inside the
`.app`. The pbxproj resource-copy shell script at
`cursor-buddy.xcodeproj/project.pbxproj:418` copies the whole
`OpenDiaRuntime/` tree, so today it happens to work; if anyone ever
adds `node_modules` to a `.gitignore` (recommended) and drops the
directory, `boot.js` will exit code 3 with no in-app recovery path.

### I3 — [MEDIUM] Unbounded auto-restart loop with a fixed 2s cool-down

`OpenClickyOpenDiaSubprocess.swift:302-307` unconditionally retries
`start()` after 2s whenever the subprocess terminates while
`desiredEnabled == true`. A crashing Node (missing `ws`, corrupt
bundle, port range exhausted, EPERM on sandboxed Node binary) will
spin-loop process launches every 2s forever. Compare F29
(`OpenClickyConnectorSubprocess.swift:315` — same pattern; if F29
already accepts the risk, at least document the shared decision in
this file). Suggested fix: capped exponential backoff + max-attempt
counter.

### I4 — [MEDIUM] `descriptorsRaw` advertises identical permissive schemas for all 120 tools, not the extension-provided schemas

`OpenClickyOpenDiaBridgeTools.swift:168-181` returns
`{type:"object", properties:{}, additionalProperties:true}` for every
tool. Everywhere builds the descriptor at the point the extension
registers (`OpenDiaBridge.cs:333-343` → `OpenDiaToolListBuilder.cs:21-42`)
so its `tools/list` reflects real schemas — this openclicky path does
not. Functionally the wire accepts anything (extension is source of
truth), but LLMs consuming `tools/list` for arg planning will not see
per-tool constraints. The landing report calls this out ("Input
schemas are intentionally permissive") — surface it in a follow-up
before mid-tier LLMs start guessing arg shapes.

### I5 — [MEDIUM] Server-push frames dropped silently instead of forwarded

`boot.js:260-262` drops any message with `type` and no `id`, and no
matching push channel is exposed on the HTTP shim. Everywhere's
`OpenDiaBridge.cs:357-365` fans these frames out to `PushFrame`
subscribers (used by `OpenDiaChatBus`). openclicky's landing note calls
this a Phase 7.6b deferral, so treat this as a documented divergence
rather than a bug — but it needs a TODO reference in `boot.js` back to
the F32/chat-bus work so it does not get lost.

### I6 — [LOW] Tool descriptions in `toolList` are hand-authored, not sourced from Everywhere

The parity matrix does not include descriptions, so openclicky invented
its own one-line copy. That is fine as a stopgap; call it out in the
review notes so downstream maintainers do not think a `git diff` of
Everywhere source will regenerate them. Recommend documenting the
authoring rules for these strings in `OpenClickyOpenDiaBridgeTools.swift`
so future updates stay consistent (imperative mood, no marketing copy,
mention of `ref` semantics, etc.).

### I7 — [LOW] Node subprocess env token is echoed into stderr on ws-send failure

`boot.js:98-101` logs `ws send failed: <err message>` to stderr — the
Node `ws` package's error messages never include the auth token, so
today this is safe, but the openclicky side prefixes stderr with
`[opendia]` and pipes to the app's own stderr (`OpenClickyOpenDiaSubprocess.swift:158-163`).
If a future upstream `ws` bump ever starts including request headers
in errors, the bearer token would surface in Console.app. Consider
prepending a sanitiser to the stderr handler.

### I8 — [LOW] `boot.js` accepts the WS upgrade on `path: '/'` only

`boot.js:317` binds the WS server to `path: '/'` on the same HTTP
port. Everywhere's `OpenDiaBridge.cs:63-65` binds to both
`http://127.0.0.1:<port>/` and `http://localhost:<port>/` prefixes,
and the extension is documented (`opendia-extension/README.md:24`) to
"discover the local WS server automatically". If discovery uses
`localhost` rather than `127.0.0.1`, Node's `server.listen(port,
'127.0.0.1', …)` (`boot.js:331`) will reject it. If discovery only ever
tries `127.0.0.1`, this is a non-issue — worth confirming against the
upstream extension source.

### I9 — [LOW] Race window: `/health` probe fires immediately after `READY`

`OpenClickyOpenDiaSubprocess.swift:190-206` awaits the `READY <port>`
line, then hits `/health`. `READY` is written from inside the
`server.listen(...)` callback (`boot.js:331-332`), so by the time the
Swift side reads it, `server` is already listening. In practice this
races on nothing, but there is no retry on a 5xx / connection-refused
from `/health` — a single transient failure fatally stops the runtime
(`Subprocess.swift:203-206`). One retry with 100 ms backoff would harden
this without changing the contract.

### I10 — [LOW] `stop()` waits up to 3 s spinning on `Thread.sleep`

`OpenClickyOpenDiaSubprocess.swift:219-225` polls `proc.isRunning` in
50 ms increments on whatever queue calls `stop()`. That queue is the
main actor in practice (see `applyEnabledChange` in
`OpenClickyOpenDiaSettings.swift:71-84`), so up to 3 s of main-thread
stall on shutdown. Prefer `DispatchQueue.global()` off-loading or
`Process.waitUntilExit()` on a detached Task.

## Divergences (declared, non-bugs)

- Swift bridge uses HTTP shim -> Node WS instead of the .NET
  `System.Net.WebSockets` path Everywhere ships. Rationale is stated in
  `boot.js:8-40` and the landing note; keeps Swift out of the WS
  handshake entirely.
- Server-push frames are silently dropped (see I5).
- `browser_read` is registered even though the parity matrix status is
  `blocked` — matches upstream shape and returns whatever error the
  extension emits (documented in
  `OpenClickyOpenDiaBridgeTools.swift:110`).
- Descriptions self-authored (I6).

## Bugs hunted — negative results

- Auth token leak in error responses: none of the HTTP error paths in
  `boot.js` echo the request headers or the token
  (`boot.js:106-113,144-218`). Swift's `requestFailed` message copies
  the body only (`Subprocess.swift:257-258`); the body is
  `{ok:false, error:message}`.
- Extension disconnect mid-call: `boot.js:281-294` rejects pending
  promises with an "extension disconnected mid-call" error; the timeout
  path at `:200-206` covers the "extension connected but silent" case.
- NSNotification / bridge shutdown clean teardown: `applicationWillTerminate`
  (`cursor_buddyApp.swift:147-153`) invokes `stop()` which terminates the
  Process. Followed by a `SIGKILL` at
  `OpenClickyOpenDiaSubprocess.swift:224` after a 3 s grace period.
- Typos in tool names: none — 120 diff empty against the parity matrix.

## Verdict

**Ready with follow-ups.** The tool surface is byte-exact against the
Everywhere parity matrix, the wire protocol tracks
`OpenDiaBridge.cs` for the pieces we forward, subprocess plumbing
matches the F29/F30 shape, and the vendored MIT tree is properly
license-recorded.

Blockers before this is user-facing:

1. Ship the Settings pane wiring for the master toggle (I1). Without
   it, no shipping build can actually turn OpenDia on.
2. Decide the `node_modules/ws` shipping story and either
   guarantee-bundle it via the pbxproj copy phase or ship the
   "Install dependencies" button (I2).

Non-blocking follow-ups: I3 (backoff), I4 (real schemas from
register), I5 (push-frame TODO reference), I9 (health retry), I10
(async stop).
