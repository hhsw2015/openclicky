# F31 OpenDia review fix report — 2026-07-23

Addresses all 10 findings from
`docs/ROADMAP/.review-notes/F31-opendia-integration-2026-07-23.md`.

## Files touched

- `cursor-buddy/OpenClickyOpenDiaSubprocess.swift`
- `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift` (TODO comment only)
- `cursor-buddy/OpenClickyOpenDiaSettingsSection.swift` (new file)
- `cursor-buddy/OpenClickySettingsWindowManager.swift` (add one settings group)
- `AppResources/OpenClicky/OpenDiaRuntime/boot.js`
- `AppResources/OpenClicky/OpenDiaRuntime/README.md`
- `AppResources/OpenClicky/OpenDiaRuntime/node_modules/ws/` (new vendored tree)

`OpenClickyOpenDiaSettings.swift` was NOT touched — its `@Published`
API surface already exposed everything the new SwiftUI section needed.

`cursor-buddy.xcodeproj/project.pbxproj` was NOT touched — the copy
phase at line 418 ditto's the entire `OpenDiaRuntime/` directory, so
the new `node_modules/ws/` subtree is copied automatically.

## Per-issue

### I1 — Settings pane wiring [HIGH]

Before: `OpenClickyOpenDiaSettings` shared instance existed but no
SwiftUI view read its `enabled` / `runtimeStatus` / `extensionConnected`
fields. Users could only enable via the env-var force-on or by
hand-writing the `openclicky.opendia.enabled` UserDefaults key.

After: new `OpenClickyOpenDiaSettingsSection` SwiftUI view
(`cursor-buddy/OpenClickyOpenDiaSettingsSection.swift`) with:

- Toggle bound to `settings.enabled` (row title "Enable OpenDia browser
  automation").
- Status readout ("Stopped" / "Running" / "Extension connected" /
  "Waiting for browser extension to connect").
- Endpoint readout ("http://127.0.0.1:<port>/ (WS on same port)").
- "Test connection" button that calls
  `OpenClickyOpenDiaSubprocess.testConnection()` and displays the
  human-readable summary.
- Error and last-test-result rows shown conditionally.

Rendered inside the "System & Logs" panel (renamed subtitle domain is
`.connections`) as a new `settingsGroup("Browser (OpenDia)")` block
inserted between "MCP servers" and "Workspace Actions" in
`OpenClickySettingsWindowManager.swift` (see the edit around the
previous `settingsGroup("Workspace Actions")` boundary).

The subprocess got a new `testConnection()` async method that runs the
same `/health` probe used at startup, but never throws — it packages
failures into the returned string so the UI can render them
gracefully.

### I2 — `ws` module vendored [HIGH]

Chose option (a) vendoring, matching how the rest of the runtime tree
(`opendia-mcp/node_modules/` upstream deps, `OpenCLIRuntime/opencli/`,
etc) already ships pre-populated. Rationale: no runtime `npm install`
step means no network dependency, no PATH assumption, no first-launch
latency spike, and no failure mode where an offline user cannot enable
OpenDia. The size cost is 196 KB / 19 files, negligible.

- Vendored `ws@8.21.1` at
  `AppResources/OpenClicky/OpenDiaRuntime/node_modules/ws/`. Sourced
  by copying the same version already present under
  `opendia-mcp/node_modules/ws/` (upstream sibling), so no license or
  version drift.
- `boot.js` now resolves `ws` in this order:
  1. `<runtime>/node_modules/ws` (vendored, primary)
  2. `<runtime>/opendia-mcp/node_modules/ws` (upstream sibling fallback)
  3. `require('ws')` (dev environments)
  If all three fail, `boot.js` exits 3 with a message pointing at
  reinstalling OpenClicky, replacing the previous "run npm install
  under opendia-mcp/" prose.
- `README.md` "Installing dependencies" section rewritten to describe
  the vendored reality. Removed the fabricated "Settings pane exposes
  one-click Install dependencies button" claim (that button never
  existed, and the vendored tree makes it unnecessary).
- pbxproj: no change required — line 418's `ditto` copies the whole
  `OpenDiaRuntime/` tree, so the new `node_modules/` is picked up.

### I3 — Exponential backoff for auto-restart [MEDIUM]

Before: `handleTermination` re-launched with `sleep(2s)` on every
crash, forever — a bad binary or misconfigured port could spin the
runtime indefinitely.

After (`OpenClickyOpenDiaSubprocess.swift`):

- New `restartAttempts` counter, incremented on every crash, reset to
  0 on a successful `/health` probe post-restart or on explicit
  `stop()`.
- New `maxRestartAttempts = 10` constant.
- Backoff formula: `min(2^attempt, 60)` seconds — 2, 4, 8, 16, 32,
  60, 60...
- After 10 attempts, auto-restart is disabled and a
  `subprocessFailedNotification` (`NotificationCenter`) is posted with
  `reason` and `attempts` user-info. The status message on
  `OpenClickyOpenDiaSettings` reflects the failure so the new
  Settings section renders it.

### I4 — Permissive schemas [MEDIUM]

Chose option (B, interim). Added a multi-line TODO block above
`descriptorsRaw` in `OpenClickyOpenDiaBridgeTools.swift` (around the
old comment for the permissive schema) that:

- Cites the source-of-truth builder
  `Everywhere/src/Everywhere.Mcp/OpenDia/OpenDiaToolListBuilder.cs`
  lines 21-42.
- Cites the caller `OpenDiaBridge.cs:333-343`.
- Describes the intended future flow: subprocess caches the
  extension's `tools/register` frame and returns real schemas from
  the cache, falling back to permissive shape only when the cache is
  empty.

No functional change — this unblocks landing while marking the debt
clearly for the follow-up.

### I5 — Server-push frames [MEDIUM]

Before (`boot.js:260-262`): frames with a `type` but no `id` were
silently dropped.

After: kept the drop (Phase 7.6b intentionally doesn't surface them
yet) but now emits `[opendia] dropping server-push frame type=<t>`
to stderr, and left a TODO block pointing at Everywhere's
`OpenDiaBridge.cs` push-frame subscribers and openclicky's F32/chat-bus
work. The stderr line will be prefixed and redacted by the Swift
subprocess's readabilityHandler in the usual way.

### I6 — Hand-authored descriptions [LOW]

Not addressed in this pass. The Everywhere `PARITY_MATRIX.md` does
not include per-tool description strings, so there is no upstream
source to sync against. Covered indirectly by the I4 TODO — once
schemas are pulled from the register frame, descriptions can be too
if the extension supplies them.

### I7 — Token in stderr [LOW]

Before: `stderrPipe.readabilityHandler` forwarded raw text to
`FileHandle.standardError`. `boot.js` doesn't currently log the
token, but there was no defence in depth if that ever changed.

After: the readability handler captures the current `authToken` in a
local constant and replaces any occurrence with `<redacted-token>`
before writing to stderr. Grep-safe — a future accidental
`process.stderr.write(token)` will no longer leak into Console.app.

### I8 — WS bind path [LOW]

Before (`boot.js`): `new WebSocketServer({ server, path: '/' })` —
extension could only connect at exactly `/`.

After: `WebSocketServer({ noServer: true })` plus a manual
`server.on('upgrade', …)` that accepts any path, matching Everywhere's
`OpenDiaBridge.cs` broad-listen behaviour. Extension can now discover
via `/opendia`, `/`, or any custom path.

### I9 — /health retry [LOW]

Before: `probeHealth()` hit `/health` once; a single transient
connection-refused killed the subprocess.

After: new `probeHealthWithRetry()` internal helper. Up to 3 attempts,
500ms Task.sleep between attempts. Used by both the startup probe and
the new `testConnection()` UI method.

### I10 — `Thread.sleep` in `stop()` [LOW]

Before: `stop()` polled `proc.isRunning` on the caller thread with
`Thread.sleep(forTimeInterval: 0.05)` — up to 3s stall on the main
actor (which is where `applyEnabledChange` calls it).

After: the terminate + wait + SIGKILL block now runs on
`DispatchQueue.global(qos: .utility)`. `handleTermination` is still
called synchronously so the state-machine transitions happen without
observable delay. The main actor is never blocked; the background
queue can spin its 50ms poll harmlessly.

## Verification

- `swiftc -parse cursor-buddy/OpenClickyOpenDiaSubprocess.swift
   cursor-buddy/OpenClickyOpenDiaSettings.swift
   cursor-buddy/OpenClickyOpenDiaBridgeTools.swift
   cursor-buddy/OpenClickyOpenDiaSettingsSection.swift
   cursor-buddy/OpenClickySettingsWindowManager.swift` — exit 0.
- `node --check AppResources/OpenClicky/OpenDiaRuntime/boot.js` — OK.
- `grep -c '^        (name: "browser_'
   cursor-buddy/OpenClickyOpenDiaBridgeTools.swift` — 120.
- `grep -oE 'name: "browser_[a-z0-9_]+'
   cursor-buddy/OpenClickyOpenDiaBridgeTools.swift | sort -u | wc -l` —
   120 unique names, byte-exact vs PARITY_MATRIX. No dispatch or name
   changes.
- I1 grep sanity: `Toggle("", isOn: Binding(
    get: { settings.enabled }, ... ))` present in
   `OpenClickyOpenDiaSettingsSection.swift`. New section referenced
   from `OpenClickySettingsWindowManager.connectionsPanel`.
- I2 grep sanity:
   `ls AppResources/OpenClicky/OpenDiaRuntime/node_modules/ws/package.json`
   returns the file.
- I3 grep sanity: `restartAttempts` and `maxRestartAttempts` defined
   in `OpenClickyOpenDiaSubprocess.swift`, backoff formula
   `pow(2.0, ...)` capped at 60.0 seconds present in
   `handleTermination`.

No `xcodebuild` invoked (per project rule — Xcode owns app builds).

## Out of scope

- F31 tool names / dispatch: unchanged (byte-exact per review).
- Extension source (`/Users/wowdd1/Dev/opendia/`): separate repo, not
  touched.
- F32-F36 files, task planning pipeline, SPM package: not touched.
