# F20 — AppActivator + LaunchPhrase

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Reviewer: code-only, file:line for every claim.

Openclicky files under review:
- `cursor-buddy/OpenClickyAppActivator.swift` (252 lines, git:untracked)
- `cursor-buddy/OpenClickyContextStashWriter.swift` (`activateAgentAndFirePhrase()`, :422-438)

Everywhere counterparts:
- `src/Everywhere.Mac/Mcp/MacAppActivator.cs` (297 lines)
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (`TryFireLaunchPhrase` region, :509-609)

---

## Alignment table

| Aspect | Everywhere (file:line) | Openclicky (file:line) | Status |
|---|---|---|---|
| SupportsFrontmostDetection = true | MacAppActivator.cs:56 | OpenClickyAppActivator.swift:74 | OK |
| NSWorkspace priming at init | MacAppActivator.cs:28-53 (calls sharedWorkspace, runningApplications, frontmostApplication) | OpenClickyAppActivator.swift:65-68 (runningApplications, frontmostApplication) | OK |
| Empty-id no-op → false | MacAppActivator.cs:60 `IsNullOrWhiteSpace ⇒ false` | OpenClickyAppActivator.swift:86-87 | OK |
| Already-frontmost short-circuit → true | MacAppActivator.cs:79-81 | OpenClickyAppActivator.swift:89-92 | OK |
| Case-insensitive exact match on bundleId ∥ localizedName ∥ executable basename | MacAppActivator.cs:98-100,193-218 | OpenClickyAppActivator.swift:223-237 | OK |
| Activate flags: ActivateAllWindows \| ActivateIgnoringOtherApps | MacAppActivator.cs:102 (`0x01 \| 0x02`) | OpenClickyAppActivator.swift:100 `[.activateAllWindows]` | Partial — see Issue 1 |
| Carbon `SetFrontProcessWithOptions` follow-up for focus-race apps (Arc etc.) | MacAppActivator.cs:117-123,264-296 | Absent | **DIVERGES** — see Issue 2 |
| IsFrontmost(agentAppId) via NSWorkspace.frontmostApplication | MacAppActivator.cs:148-179 | OpenClickyAppActivator.swift:112-117 | OK |
| Empty phrase → no-op | ContextStashWriter.cs:512 `IsNullOrWhiteSpace(phrase) ⇒ return` | OpenClickyAppActivator.swift:139-140 `phrase.isEmpty` | Partial — see Issue 3 |
| supportsFrontmostDetection guard | ContextStashWriter.cs:513-518 | OpenClickyAppActivator.swift:141-144 | OK (always true on mac) |
| `_phraseInFlight` interlock | ContextStashWriter.cs:507,519-523 `Interlocked.CompareExchange` | OpenClickyAppActivator.swift:56-57,148-155 `NSLock` + Bool | OK — semantically equivalent |
| finally-clear the interlock on every exit path | ContextStashWriter.cs:604-607 `Interlocked.Exchange` | OpenClickyAppActivator.swift:160-164 `defer` | OK |
| Fire-and-forget dispatch | ContextStashWriter.cs:527 `Task.Run(async …)` | OpenClickyContextStashWriter.swift:200-202 `await activateAgentAndFirePhrase()` inside `captureCoreAsync` | **DIVERGES** — see Issue 4 |
| Settle loop cap: 16 iterations | ContextStashWriter.cs:543 `for (var i = 0; i < 16; i++)` | OpenClickyAppActivator.swift:170,243 `settleIterations = 16` | OK |
| Settle tick delay: 150 ms | ContextStashWriter.cs:547 `Task.Delay(150)` | OpenClickyAppActivator.swift:172,246 `settleTickMillis = 150` (× 1e6 ns) | OK |
| Consecutive-frontmost required: 2 ticks | ContextStashWriter.cs:553 `++stable >= 2` | OpenClickyAppActivator.swift:176,250 `settleStableTicks = 2` | OK |
| Re-issue Activate() each tick | ContextStashWriter.cs:545 | OpenClickyAppActivator.swift:171 | OK |
| Reset `stable` on non-frontmost tick | ContextStashWriter.cs:557 `stable = 0` | OpenClickyAppActivator.swift:181 `stable = 0` | OK |
| Settle timeout log + return | ContextStashWriter.cs:560-566 | OpenClickyAppActivator.swift:184-187 | OK |
| Pre-TypeText frontmost recheck | ContextStashWriter.cs:574-580 `IsFrontmostSafe` | OpenClickyAppActivator.swift:192-195 `isFrontmost(bundleId)` | Partial — see Issue 5 |
| TypeText | ContextStashWriter.cs:581 `_input.TypeText(phrase)` | OpenClickyAppActivator.swift:197 `InputSimulator.typeText(trimmedPhrase)` | OK |
| Pre-Return frontmost recheck | ContextStashWriter.cs:590-596 | OpenClickyAppActivator.swift:203-206 | Partial — Issue 5 same |
| PressKey("Return") | ContextStashWriter.cs:597 | OpenClickyAppActivator.swift:209 `try InputSimulator.pressKey("Return")` | OK |
| Skip-Return on focus loss between TypeText and Return | ContextStashWriter.cs:590-596 | OpenClickyAppActivator.swift:203-206 | OK |
| Exception in loop-body swallowed | ContextStashWriter.cs:546,549-550 try/catch around Activate + IsFrontmost | OpenClickyAppActivator.swift:171,173 — `_ = activate(bundleId)` cannot throw; `isFrontmost` cannot throw (returns Bool from NSWorkspace) | OK (Swift API doesn't throw here) |
| ActivateAgentApp: empty AgentAppId → skip, log | ContextStashWriter.cs:369-374 | OpenClickyContextStashWriter.swift:424-425 (silent skip, no log) | Minor cosmetic — Issue 6 |
| Raise called only after successful stash write | ContextStashWriter.cs:328,342 (drainAnnotations && wrote) | OpenClickyContextStashWriter.swift:200-202 (`wrote && drainAnnotations`) | OK |
| Auto-capture paths (pin/whiteboard) DO NOT raise | ContextStashWriter.cs:335-344 | OpenClickyContextStashWriter.swift:196-202 (drainAnnotations flag) | OK — Phase 7 stub still uses drainAnnotations correctly |
| Raise call flow: Activator.Activate → if !raised return → TryFireLaunchPhrase | ContextStashWriter.cs:367-388 | OpenClickyContextStashWriter.swift:422-438 | OK |

---

## Issues

### Issue 1 — `.activate` flags don't include `.activateIgnoringOtherApps` on Sonoma+

`OpenClickyAppActivator.swift:98-100`:
```
app.activate(options: [.activateAllWindows])
```

Comment (:97-99) claims: *"`.activate(options:)` in modern AppKit already implies 'ignoring other apps' for the caller-initiated case."*

That is partially true — since macOS 14, Apple deprecated `.activateIgnoringOtherApps`. On macOS 14+ the option is a no-op but the behavior is implicit only when the requesting app is either frontmost or has a valid `NSApplicationActivationPolicy`. Openclicky is `LSUIElement=true` (menu-bar app) so `NSApp.activationPolicy` is `.accessory`. For accessory apps, `.activate(options: [.activateAllWindows])` on Sonoma/Sequoia has been observed to lose the race against a browser's own hotkey handler.

Everywhere `MacAppActivator.cs:17-18,102` explicitly ORs both `ActivateAllWindows | ActivateIgnoringOtherApps = 0x01 | 0x02`. Even if `IgnoringOtherApps` is a no-op on the newest OS, Everywhere covers older macOS versions and the redundant flag is harmless.

Impact: focus-steal probability rises modestly against sticky-focus apps. Combined with Issue 2 below, LaunchPhrase reliability against Arc / Firefox with global-hotkeys may drop.

Recommend: `app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])`.

---

### Issue 2 — No Carbon `SetFrontProcessWithOptions` follow-up

`MacAppActivator.cs:113-123,264-296`: after `NSRunningApplication.activate`, C# resolves the app's PID and calls `SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly)` via `/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices`. The rationale is documented in-file (`:107-112`): *"NSRunningApplication.activate is 'polite' — apps that continuously self-reactivate (Arc / some launchers) win the focus war within milliseconds… Re-issue through Carbon's SetFrontProcessWithOptions."*

`OpenClickyAppActivator.swift`: no Carbon fallback. Only `NSRunningApplication.activate` (:100).

Impact: for the exact class of apps the Everywhere port was written to handle (Arc, custom launchers, apps with global hotkey handlers that re-front themselves), openclicky will settle-loop for 2.4s and log *"agent did not stay frontmost"*. Real-world reliability regression on Arc/Firefox-with-Vimium/similar.

Recommend: port the Carbon fallback. Swift is fine calling deprecated Carbon symbols — they're still exported on macOS 26. See `MacAppActivator.cs:250-296` for the exact P/Invoke shape (`ProcessSerialNumber` struct, `GetProcessForPID`, `SetFrontProcessWithOptions`, `SetFrontProcessFrontWindowOnly = 1`).

---

### Issue 3 — Empty-phrase guard uses `.isEmpty`, not `IsNullOrWhiteSpace`

`OpenClickyAppActivator.swift:139-140`:
```
let trimmedPhrase = phrase
guard !trimmedPhrase.isEmpty else { return }
```

C# `ContextStashWriter.cs:512`: `if (string.IsNullOrWhiteSpace(phrase)) return;`

`IsNullOrWhiteSpace` returns true for `"  \t"`, `"\n"`, etc. Swift's `.isEmpty` does not. So a user who leaves `launchPhrase = "  "` in settings would get the whitespace typed + Return pressed — potentially firing an empty submit into the agent.

Note: the openclicky caller (`OpenClickyContextStashWriter.swift:431-432`) does `let phrase = settings.launchPhrase; guard !phrase.isEmpty else { return }` — same bug. Also `bundleId` is trimmed with `.trimmingCharacters` at :424 but `phrase` is not.

Recommend: `phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` (both call sites) OR trim on write in settings.

Also naming inconsistency: `trimmedPhrase` is not actually trimmed — the identifier misleads.

---

### Issue 4 — LaunchPhrase pipeline is NOT fire-and-forget

`ContextStashWriter.cs:527`:
```
_ = Task.Run(async () => { ... });
```

The launch-phrase pipeline runs on a background task; `CaptureCoreAsync` returns immediately after firing the raise.

`OpenClickyContextStashWriter.swift:200-202`:
```
if wrote && drainAnnotations {
    await activateAgentAndFirePhrase()
}
```

`activateAgentAndFirePhrase` (:422-438) then `await`s `fireLaunchPhrase(...)`. The `await` blocks the caller for up to 2.4s (settle timeout) + typing time (`30ms/char × phrase.length`) before `captureCoreAsync` returns. Because `captureCoreAsync` holds `writeLock` for its entire body (`:97 guard writeLock.try(); defer writeLock.unlock()`), a hotkey re-fire during those seconds is dropped by the non-blocking single-flight guard.

Impact:
- Everywhere: re-hitting SnapshotContext ~500ms after a first press would attempt a new capture; the second capture's own `WaitAsync(0)` fails and drops (because the first is still awaiting typing). Same drop behaviour.
- Openclicky: same drop behaviour, but for a longer window (whole settle + type duration, not just the capture pipeline).

Not a correctness bug, but Everywhere-parity requires spawning `fireLaunchPhrase` off a detached Task so the capture single-flight is released the moment the write finishes. Otherwise the capture lock stays held while we're settle-looping — which the code header at `OpenClickyContextStashWriter.swift:194-199` clearly did not intend.

Recommend: `Task.detached { await OpenClickyAppActivator.shared.fireLaunchPhrase(...) }` inside `activateAgentAndFirePhrase`, or release the writeLock before the await.

Same issue in the LinkRect direct-ship path: `OpenClickyContextStashWriter.swift:350-352` also `await`s `activateAgentAndFirePhrase` while holding `writeLock`.

---

### Issue 5 — Frontmost recheck lacks an exception-safe wrapper

C# `ContextStashWriter.cs:574,590` calls `IsFrontmostSafe(agentAppId)` (defined :483-493), which wraps `_appActivator.IsFrontmost` in a try/catch and treats **any** thrown exception as `false` — "typing into an unknown window is the failure mode we cannot allow" (:571-573).

Swift `OpenClickyAppActivator.swift:192,203`: calls `isFrontmost(bundleId)` directly. The Swift implementation (`:112-117`) doesn't throw — it returns `false` for empty ids or missing frontmost. So the guard is unnecessary in practice.

However, if `NSWorkspace.shared.frontmostApplication` ever crashes or produces an unexpected nil after a `.activate` call (which the Everywhere comment implies has been observed cross-platform), the Swift code has no defensive layer.

Not a functional bug today; documentation drift from the source. Consider a `try/catch`-equivalent wrapper if the Swift APIs ever move to throwing accessors.

---

### Issue 6 — Missing informational log when AgentAppId is empty

`ContextStashWriter.cs:370-374`:
```
if (string.IsNullOrWhiteSpace(id)) {
    _logger.LogInformation("Agent app id is empty; skipping activation.");
    return;
}
```

`OpenClickyContextStashWriter.swift:424-425`:
```
let bundleId = settings.agentAppId.trimmingCharacters(in: .whitespacesAndNewlines)
guard !bundleId.isEmpty else { return }
```

Silent skip. If a user has misconfigured settings, they get no signal in `Console.app`. Trivial `NSLog` add.

---

## Verdict

**Structurally correct, focus-race parity gap.**

- Settle loop constants (16 × 150ms = 2.4s cap, 2 stable ticks): byte-exact match.
- `_phraseInFlight` interlock via `NSLock`+Bool is a faithful port of `Interlocked.CompareExchange`; `defer` clears on every exit path.
- Pre-TypeText and pre-Return frontmost rechecks are both present.
- InputSimulator wiring uses `typeText` + `pressKey("Return")` — matches the two-step submit semantics.
- Auto-capture paths (pin/whiteboard, deferred to Phase 7) correctly won't activate — controlled by `drainAnnotations` flag.

**Focus-reliability gaps against Everywhere:**
1. **Missing Carbon `SetFrontProcessWithOptions` fallback** (Issue 2) — the entire reason Everywhere's activator exists in its current form. Arc / focus-stealing apps will fail settle-loop more often on openclicky than on Everywhere. Highest-impact issue in this batch.
2. **`.activateIgnoringOtherApps` flag absent** (Issue 1) — combined with Carbon absence, LSUIElement openclicky loses more focus races than Everywhere.
3. **Blocking `await` holds the capture single-flight** (Issue 4) — capture lock stays held for up to ~3s during settle + typing, so rapid re-fire hotkeys are silently dropped for that window. Should be `Task.detached`.
4. **Whitespace-only phrase not treated as empty** (Issue 3) — one-line trim fix.

**Recommended before merge:**
1. Port Carbon fallback (Issue 2). Non-trivial but small; direct P/Invoke shape available in `MacAppActivator.cs:250-296`.
2. Add `.activateIgnoringOtherApps` (Issue 1). One-line.
3. Dispatch `fireLaunchPhrase` off `Task.detached` at the writer call site (Issue 4). Two-line.
4. Trim the phrase before `.isEmpty` check (Issue 3). One-line.
5. Nice-to-have: log skip reason on empty AgentAppId (Issue 6).
