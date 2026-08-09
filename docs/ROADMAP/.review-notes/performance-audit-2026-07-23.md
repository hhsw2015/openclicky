# Openclicky Performance Audit — 2026-07-23

Scope: Everywhere port surface only (pin `30e03e9dcfdd4247fd679828ed86e9042f32d809`, informational).
Read-only static analysis + live process snapshot. Every claim carries a `file:line` citation.

## Idle footprint measurement

At the time of this audit the app was NOT running:

```
$ ps auxm | grep -i openclicky
(no results)

$ ps aux | grep -i node
(no results)

$ lsof -i :3011-3021,32123,55000-57000
(no results — only unrelated xray/v2rayN sockets)
```

The audit therefore relies on static analysis of the touched code paths. No live RSS numbers are attributable to the port. Runtime measurement should be repeated once the user has the app running with the F29/F30/F31 toggles enabled to confirm the estimates below.

## Per-component idle behavior

### Layer 0 capture — event-driven, no idle cost
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/*.swift` (30 files).
Every capture is an `async` function called from a snapshot request. No captor installs a `Timer`, `DispatchSourceTimer`, or `CFRunLoop` observer.
Only sleep in the whole capture package is a bounded polling loop inside a subprocess wait:
- `AppleScriptRunner.swift:154-155` and `:162-163` — `Thread.sleep(0.02)` while polling `process.isRunning` with a deadline. Runs on `DispatchQueue.global(qos: .userInitiated)` (dispatched at `AppleScriptRunner.swift:88`), not the main actor.
- `ScreenshotCaptureEverywhere.swift:240` — `Task.sleep(25 ms)` polling `screencapture` subprocess with a 3-second deadline; only exercised when the screenshot fallback path runs.

No idle cost from Layer 0.

### F28 auto-continue observer — fires on `turn/completed` only
`CodexAgentSession.swift:1983-2062` is the sole trigger site. `progressStage = .completed` then the marker check runs. `OpenClickyProgressMarkerCheck.isDone` (`OpenClickyProgressMarkerCheck.swift:45-71`) reads PROGRESS.md synchronously via `String(contentsOfFile:)`. Called from `handleNotification` (`CodexAgentSession.swift:1838`), which runs on `@MainActor` (class annotated at `CodexAgentSession.swift:232`). See "Main-actor risks" below.

Not a polling observer — it's a one-shot per turn end. Idle cost is zero.

### F29/F30/F31 Node subprocesses — always-on if toggled
Autostart wired at `cursor_buddyApp.swift:134/138/144` behind `.enabled` flags (`OpenClickyConnectorSettings.autostartIfEnabled` etc. at `OpenClickyConnectorSettings.swift:120-126`, `OpenClickyOpenCLISettings.swift:83-88`, `OpenClickyOpenDiaSettings.swift:96-101`). Each `autostartIfEnabled` dispatches into a `Task { @MainActor ... }`; the `applyEnabledChange()` call inside launches `Process.run()`, which is non-blocking.

Node boot scripts:
- OpenConnector `AppResources/OpenClicky/OpenConnectorRuntime/boot.js` — no `setInterval`; only `setTimeout` at `:536` for bind retry.
- OpenCLI `AppResources/OpenClicky/OpenCLIRuntime/boot.js` — same, `:518`.
- OpenDia `AppResources/OpenClicky/OpenDiaRuntime/boot.js:238-241` — `setInterval(ping, 20000)` while an extension is connected (the `if (!extConnected()) return` guard means CPU cost when no ext is attached is essentially the interval fire itself). Cleared on socket close (`:294`).

Runtime disk footprints (bundle side):
```
4.3M   AppResources/OpenClicky/OpenDiaRuntime/
9.4M   AppResources/OpenClicky/OpenCLIRuntime/
36K    AppResources/OpenClicky/OpenConnectorRuntime/
```
Idle Node RSS is not measurable here (app not running); typical Node 20 idle is 40-70 MB per process; if the user has all three enabled expect ~150-200 MB of Node overhead on top of the openclicky.app itself. Recommend the user re-run `ps auxm` with the app up.

### F31 OpenDia WS keepalive
20-second interval, extension-connected gated (`boot.js:238-241`). Emits one `ping` frame; no busy loop. When no extension is connected, the interval callback returns early on the first line (`:239`).

### F31 subprocess crash recovery — exponential backoff
`OpenClickyOpenDiaSubprocess.swift:368-391`. Exponential: 2, 4, 8, 16, 32, 60, 60... s, capped at 60. `maxRestartAttempts = 10` (`:99`) then a `NotificationCenter.default.post` on `subprocessFailedNotification` (`:102-104`). Reset to 0 after a healthy `/health` probe (`:221`). Good.

### F29 subprocess crash recovery — 2-second fixed retry, unbounded
`OpenClickyConnectorSubprocess.swift:320-327` (in the compressed view of the file — same shape as F30). Comment says "One retry attempt" but there's no attempt counter: every crash produces a new `Task { try? await Task.sleep(2s); try? await start() }`, and a fresh crash re-arms another. No max-attempts guard. Under a hard failure mode (bad node path, missing boot.js after a partial install) this becomes a 0.5 Hz respawn loop. F31 has the fix. F29 and F30 do not.

Same shape in F30: `OpenClickyOpenCLISubprocess.swift:287-292` — unconditional 2-second re-`start`.

### F32 chat_bus — bounded, TTL-pruned, self-cleaning
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Chat/OpenClickyChatBus.swift`. Prune runs inline on every `send` and every `subscribe` (`:94, :134`). Bound `maxQueue = 200` (`:35`) applied on every `send`. TTL 5 min (`:31`).
No background timer — the prune is opportunistic. If nobody calls `send` or `subscribe` for a long time, expired messages stay resident but capped at 200 × ~1 KB = ~200 KB. Acceptable.

### F34 web_search + web_fetch_url — bounded
`OpenClickyWebFetchClient.swift:37-38`: `defaultTimeout = 15s`, `defaultMaxBytes = 1_000_000`. Per-request `req.timeoutInterval = timeout` at `:93`. Enforced truncation at `:125-127`. No idle cost.

### F17 BM25 index — bounded, one-shot build
`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyMetaTools.swift:105-228`.
`OpenClickyMetaToolRegistry.register` (`:297-304`) de-dupes by name via `indexByName` (`:141-157`). One-shot build at process start via lazy static:
`OpenClickyExternalControlBridge.swift:1958-1974` — `sensorMetaRegistry` is `static let`, populated once with 43 sensor descriptors.
Duplicate registrations replace in place; no unbounded growth. Idle memory ~fixed at ~10 KB for the descriptor table + postings.

### G7 mutation-verb regex — compiled once
`OpenClickyMetaTools.swift:253-259` — file-level `let` with `try!`. Not per-call recompiled. Applied per strategy-note validation only (not per snapshot).

### Sensor MCP bridge :32123 — SSE, no server heartbeat
`OpenClickyExternalControlBridge.swift:152` `defaultPort: UInt16 = 32123`. Bind ladder walks +1..+10 on failure (`:231-273`). `attachSSE` at `:828-835` sends one `event: ready` frame then leaves the connection open; no server-side keepalive interval. Broadcasts happen only when the app posts (`broadcast`, `:837-841`). Idle cost: zero fanout when nothing is happening. Fine.

### Chrome bridge :3011 — HTTP long-poll, bounded
`HeyClickyChromeBridgeServer.swift:26` — hardcoded port 3011 (no ladder). Long-poll window 25 s (`:294`). `handleCmdPoll` (`:286-301`) queues waiters, releases them when a command arrives or the 25 s timer fires with `204 No Content`. No timer runs unless a poll is in-flight.

Two unbounded-growth risks:
- `eventLog: [[String: Any]]` (`:42`) — `append`-only at `:160`, never trimmed. `closeTabsMatching` and `waitForEvent` scan the whole log. Every browser event that arrives while the extension is connected accumulates. Over a long OpenClicky session this grows without bound.
- `eventListeners` and `listenerContinuations` (`:43-44`) — appended at `:193-195`, only removed on match or timeout (`:167-173, :200-207`). Bounded in practice by the number of concurrent `waitForEvent` callers, but no defensive cap.

### AXFollower — 50 ms poll but only while annotation overlay is up
`OpenClickyAXFollower.swift:51` `pollInterval = 0.05`. Installed at `:187-195` inside `start()`. `start()` is only called from `OpenClickyAnnotationBadgeOverlay.swift:408`, which owns the follower via `follower: OpenClickyAXFollower?` (`:374`). When the badge overlay is dismissed the follower is torn down. Zero idle cost when overlay is not shown.

The `DispatchSourceTimer` fires on `.main` (`OpenClickyAXFollower.swift:188`) at 20 Hz while the overlay is up. Each fire calls `refresh()` which does two `AXUIElementCopyAttributeValue` calls (`:212-213`). AX calls can block for 100+ ms on slow apps; 50 ms fire cadence combined with sync AX reads on main could stack up on a hung app. Not new — inherited pattern — but worth noting.

## Main-actor risks

### MEDIUM — Synchronous PROGRESS.md read on main after every `turn/completed`
`CodexAgentSession` is `@MainActor` (`CodexAgentSession.swift:232`).
Every `turn/completed` calls `OpenClickyProgressMarkerCheck.isDone` (`CodexAgentSession.swift:2038`), which does `String(contentsOfFile:)` (`OpenClickyProgressMarkerCheck.swift:51`) on the main thread. Typical PROGRESS.md is <5 KB — fine. A pathological PROGRESS.md (10 MB) blocks the main actor for the read + `NSRegularExpression.firstMatch` (`:70`).

Also called from the observer body: `CompanionManager+HeyClicky.swift:459-464` — same file read, same actor context. If both the session and the observer body run for the same turn (design says the observer inspects the state after the notification fan-out), the file is read twice.

Recommendation: move `isDone` behind `Task.detached { }` or a nonisolated helper. Or cap the file size explicitly (e.g. read first 32 KB and search there).

### LOW — `TaskDirectoryResolver.resolveNonCollidingSlug` up to 100 sync PROGRESS.md reads
`OpenClickyTaskDirectoryResolver.swift:73-103`. Called from `OpenClickyRouteDispatcher.swift:234`, which runs on `@MainActor` (`:26`). Only exercised when a new task is being resolved; bounded to 100 candidates. Practically fine but theoretically 100 sync reads on main. Rare hot path.

### LOW — `HeyClickyChromeBridgeServer` 25-second long-poll timer fires on main
`HeyClickyChromeBridgeServer.swift:293-300` — the `Task { @MainActor ... try? await Task.sleep(25s) ...}` for every incoming `/cmd` poll. Each concurrent poller allocates one Task on the main queue. Under normal single-extension usage there's exactly one in-flight poller. Fine.

### None found — `DispatchQueue.main.sync`, `while true { }`
Grep across the whole port surface produces zero `DispatchQueue.main.sync` calls. No unbounded `while true`. The `while proc.isRunning && Date() < deadline` loops in `OpenClickyOpenDiaSubprocess.swift:265-269` and `OpenClickyConnectorSubprocess.swift:249-251` are bounded by a `Date()` deadline. F31's `stop()` was already refactored (`:263-274`) to run the deadline poll on `DispatchQueue.global(qos: .utility)` so the caller (which may be `@MainActor`) doesn't stall.

F29's `stop()` still runs the 3-second poll on the caller's thread (`OpenClickyConnectorSubprocess.swift:249-251`), which is `@MainActor`. Same in F30 (`OpenClickyOpenCLISubprocess.swift:220-225`). On a well-behaved node process this returns in <100 ms after SIGTERM, so users won't notice; on a wedged node process the main actor is stuck for up to 3 s.

## Memory concerns

### Long-lived accumulators

1. `HeyClickyChromeBridgeServer.eventLog` (`HeyClickyChromeBridgeServer.swift:42`) — append-only, unbounded. Every `tab-navigated`, `click-result`, `hello`, `tab-opened`, `tab-closed` event stays forever. Recommend a rolling window (e.g. last 500 events, or last 5 min).

2. `HeyClickyFreePlanningClient.sessions` history (`HeyClickyFreePlanningClient.swift:174-178`) — appended per round. PlanningLoop invokes 3 rounds per task (`OpenClickyPlanningLoop.swift:66-104`) and calls `clearSession` in the `defer` block (`:45`). So per-task history is bounded and cleaned. Good.

3. `OpenClickyChatBus.history` — capped at 200 and TTL-pruned. Good.

4. `OpenClickyBM25Index.postings` — bounded by unique tokens across 43 sensor descriptors + any tools registered later. In-memory dict of small strings. Static.

5. `MemoryStore.rotateSnapshots` (`Packages/OpenClickyContextService/Sources/OpenClickyContextService/Memory/MemoryStore.swift:282-294`) — keepLast=5 default; scans directory each write. Fine.

### SwiftUI body-storm risks (post-fix verify)

Chrome bridge settings section was refactored earlier this session — verified: `OpenClickyChromeBridgeSettingsSection.swift:40-46` is a one-shot `onAppear` refresh, no `Timer.publish`, comment at `:41-44` documents why the polling was removed. No regression.

`OpenClickyOpenDiaSettings`/`OpenClickyOpenCLISettings`/`OpenClickyConnectorSettings` publish 3-4 `@Published` fields each (`OpenClickyOpenDiaSettings.swift:28-68` etc.). `syncRuntimeSnapshot` (`:71-91`, `:58-78`, `:94-115`) writes all of them at once from `applyEnabledChange`. Only invoked on toggle change or startup autostart — not per-frame. Fine.

`CodexHUDWindowManager.swift:462` — `.onReceive(Timer.publish(every: 30, ...))` — 30 s poll, only alive while the HUD window is open. Pre-existing, low cost.

## Startup impact estimate

### Time-to-first-UI

`cursor_buddyApp.swift:120-144` order:
1. `ClickyAnalytics.configure` / `trackAppOpened`
2. `OpenClickyDesktopNotificationCenter.shared.configure()`
3. `menuBarPanelManager = MenuBarPanelManager(...)`
4. `companionManager.start()`
5. `scheduleWidgetSnapshotPublish`
6. `registerAsLoginItemIfNeeded`
7. `startSparkleUpdater`
8. `autostartIfEnabled × 3`

Each `autostartIfEnabled` returns immediately by dispatching a `Task { @MainActor in await applyEnabledChange() }`. The `Process.run()` itself does not block the caller. Node boot handshake waits for `READY <port>` line — but that waits inside the task, not the launch method. Time-to-first-UI is not gated on node startup.

Estimated cold start (best case): dominated by `CompanionManager.start()` (out of port scope) + one round-trip to spawn each Node process. Node cold start is typically 200-400 ms per process; three in parallel share CPU but complete in ~500-700 ms real time. Not visible to user because the tasks are detached.

### Blocking sequences

None found in the port-touched paths. Every subprocess spawn goes through `Task { @MainActor ... }` and `async/await`.

## Recommendations

Priority order for user-visible impact:

1. **F29/F30 unbounded 2-second respawn (HIGH).** Add exponential backoff + max-attempts cap mirroring F31.
   - `OpenClickyConnectorSubprocess.swift:320-327`
   - `OpenClickyOpenCLISubprocess.swift:287-292`
   A misconfigured node path or missing boot.js turns this into a persistent 0.5 Hz spawn/kill loop that will show as steady 2-3% CPU + churning process IDs in Activity Monitor.

2. **`HeyClickyChromeBridgeServer.eventLog` unbounded (MEDIUM).** Long-running sessions with the Chrome extension attached accumulate every navigation event forever. Cap to last 500 or last 5 minutes.
   - `HeyClickyChromeBridgeServer.swift:42, :160`.

3. **`OpenClickyProgressMarkerCheck.isDone` on main actor (MEDIUM).** Move file read off-main, or cap the read size. Impact only visible with pathological PROGRESS.md files but the fix is trivial (`Task.detached { }` or an `async` variant).
   - `OpenClickyProgressMarkerCheck.swift:45-71`, called at `CodexAgentSession.swift:2038` and `CompanionManager+HeyClicky.swift:459`.

4. **F29/F30 `stop()` synchronous 3-second poll on main (LOW).** Copy F31's `DispatchQueue.global(qos: .utility).async` wrapper (`OpenClickyOpenDiaSubprocess.swift:263-274`) into F29 (`:249-251`) and F30 (`:220-225`) so a wedged node doesn't stall the settings toggle.

5. **Node RSS baseline measurement (INFO).** Once the app is running with the F29/F30/F31 toggles as the user has them configured, re-run:
   ```
   ps -o pid,rss,command -p <opendia_pid> <opencli_pid> <connector_pid>
   ```
   to establish the real memory footprint. Static analysis can't tell us this.

6. **Consider a shared subprocess-manager superclass (INFO).** F29/F30/F31 share ~80% of their code (Process/Pipe wiring, READY parsing, path resolution, health probe). The divergence between F31's fixed recovery loop and F29/F30's broken one is exactly the kind of drift a shared base class would prevent.
