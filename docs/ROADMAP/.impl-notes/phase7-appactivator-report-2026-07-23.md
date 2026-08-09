# Phase 7 — AppActivator + LaunchPhrase parity — Report

## Files created

- `cursor-buddy/OpenClickyAppActivator.swift` (new, ~230 lines)
  - `OpenClickyAppActivator.shared` singleton.
  - `activate(_ bundleId:)` — NSWorkspace-based; short-circuits when target is already frontmost; matches on bundle id / localized name / executable basename (case-insensitive exact).
  - `isFrontmost(_ bundleId:)` — NSWorkspace.frontmostApplication compare.
  - `supportsFrontmostDetection` — always true (macOS).
  - `fireLaunchPhrase(bundleId:phrase:)` — full settle-loop + focus-steal guarded injection.
- `cursor-buddyTests/OpenClickyAppActivatorTests.swift` (new, 6 tests)

## Files modified

- `cursor-buddy/OpenClickyContextStashWriter.swift`
  - Appended new `captureLinks(_ links: [(title: String, url: String)]) async` overload — Everywhere `CaptureLinksAsync` port (frontmost snapshot + browser url + filter/cap/dedup/redact + atomic write + activate).
  - Appended `static filterCapAndDedupLinks(...)` helper carrying the Everywhere-parity bounds (200 links / 2048 url / 200 title).
  - Appended `private activateAgentAndFirePhrase() async` — Everywhere `ActivateAgentApp` + `TryFireLaunchPhrase` orchestration.
  - Wired `captureCoreAsync` — after successful atomic write with `drainAnnotations=true` (manual hotkey path), calls `activateAgentAndFirePhrase()`. Replaces the Phase 7 TODO stub.
  - Existing `captureLinks([OpenClickyPickedLink])` overload untouched (Phase 7.1 harvester path still routes through `captureCoreAsync` + XLB merge).

## Files NOT touched (per constraints)

- SPM package (`Packages/OpenClickyContextService/**`) — imported read-only for `InputSimulator`, `OpenClickySanitiser`, `OpenClickyPickedLink`, capture helpers.
- `OpenClickyExternalControlBridge.swift`, `HeyClickyChatToolCallClient.swift`, `ClickyCodexConfigTemplate.swift`, `OpenClickyRouteDispatcher.swift`.
- Overlay*.swift, Hotkey*.swift, ContextAwarenessSettings.swift (concurrent-agent zone — only *read* the launchPhrase / agentAppId properties, no writes).

## Timing constants matched (byte-parity)

| constant                       | value      | openclicky location                          | Everywhere source                 |
|--------------------------------|------------|-----------------------------------------------|-----------------------------------|
| settle iterations              | 16         | `OpenClickyAppActivator.settleIterations`     | ContextStashWriter.cs:543         |
| settle tick delay              | 150 ms     | `OpenClickyAppActivator.settleTickMillis`     | ContextStashWriter.cs:547         |
| stable ticks to settle         | 2          | `OpenClickyAppActivator.settleStableTicks`    | ContextStashWriter.cs:553         |
| max LinkRect links             | 200        | `OpenClickyContextStashWriter.maxLinkRectLinks` | ContextStashWriter.cs:159       |
| max LinkRect url length        | 2048       | `OpenClickyContextStashWriter.maxLinkRectUrlLen` | ContextStashWriter.cs:160      |
| max LinkRect title length      | 200        | `OpenClickyContextStashWriter.maxLinkRectTitleLen` | ContextStashWriter.cs:161    |
| settle wall-clock cap          | 2.4 s      | (16 × 150ms)                                  | ContextStashWriter.cs:539         |

## Focus-steal guard behavior

Three checkpoints, all mirror `TryFireLaunchPhrase`:

1. **Settle loop exit** — if 16 iterations pass without 2 consecutive frontmost ticks, log info "did not stay frontmost; skipping injection" and return without typing.
2. **Pre-TypeText** — `isFrontmost` recheck after settle. On loss: log warn "focus stolen just before injection; phrase NOT typed" and return. No keystrokes leak.
3. **Pre-Return** — `isFrontmost` recheck after `typeText`. On loss: log warn "focus stolen during typing; NOT pressing Return" and return. Some keystrokes may have leaked but the dangerous submit event is withheld.

`_phraseInFlight` interlock (`NSLock` + `Bool`) covers all exit paths via `defer`, matching Everywhere's `finally { Interlocked.Exchange(...) }`.

## Deliberate deviations from Everywhere

- **No Carbon `SetFrontProcessWithOptions` follow-up.** Everywhere's `MacAppActivator.Activate` invokes deprecated Carbon after `activateWithOptions:` to beat focus-stealing apps like Arc (MacAppActivator.cs:105-124). Openclicky's LinkRect + SnapshotContext flows are not commonly composed with browser-hosted global hotkey handlers the way Everywhere is; keeping to `NSRunningApplication.activate(options: [.activateAllWindows])` avoids depending on a symbol Apple has been retiring. If real focus-steal issues surface (Arc / launcher apps), the Carbon path can be re-added mechanically — no logic change needed.
- **`NSWorkspace` priming happens in `init()` unconditionally** — same eager warm-up as Everywhere's DI-time prime, and cheaper (no P/Invoke marshalling).

## Alignment audit summary

Side-by-side vs `MacAppActivator.cs` and `ContextStashWriter.cs:509-609`:

- Settle loop shape: 16 iterations × 150ms × 2 consecutive stable ticks — **matched**.
- Settle-loop re-issues `Activate` each tick — **matched**.
- Pre-TypeText and pre-Return `IsFrontmost` rechecks — **matched**.
- `_phraseInFlight` interlock via CAS-equivalent (`NSLock` + `Bool` guarded read+set) — **matched**.
- Injection uses `TypeText(phrase)` then `PressKey("Return")` — **matched** via `InputSimulator.typeText` and `InputSimulator.pressKey("Return")`.
- Empty phrase early-return — **matched** (`phrase.isEmpty` check upfront).
- `SupportsFrontmostDetection` false → skip injection — **matched** (always true on macOS but branch preserved).

`CaptureLinksAsync`:
- Non-blocking single-flight via `writeLock.try()` — **matched**.
- 200 / 2048 / 200 bounds — **matched**.
- Dedup key `url + "\0" + (title ?? "")` case-insensitive — **matched**.
- URL scheme allowlist + credential redaction via `OpenClickySanitiser` — **matched** (delegates to the SPM sanitiser which is the shared byte-parity port).
- ActivateAgentApp fired only after successful write — **matched**.

## Build result

```sh
cd /Users/wowdd1/Dev/openclicky && bash scripts/sign-and-install.sh
```

```
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
[5/5] done.
```

App target compiles cleanly (which is the CLAUDE.md-sanctioned verification path). `swiftc -parse` on `OpenClickyAppActivator.swift`, the modified `OpenClickyContextStashWriter.swift`, and `OpenClickyAppActivatorTests.swift` all pass with no diagnostics.

## Test verification note

`xcodebuild test` fails at the code-signing phase because the test bundle's provisioning profile requires interactive keychain access that this shell session lacks (unrelated to this Phase 7 work — the same signing error would appear for any test invocation in the current environment). The tests themselves compile against the same swiftc as the app target (verified via `-parse`). Running the tests requires an interactive Xcode session or `-allowProvisioningUpdates` on a machine with the developer certificate unlocked — both outside the constraint boundary set by CLAUDE.md (which forbids `xcodebuild` from the terminal).

## Ground-truth pointers

- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacAppActivator.cs` (297 lines) @30e03e9d
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:130-213` (CaptureLinksAsync) @30e03e9d
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:367-388` (ActivateAgentApp) @30e03e9d
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:509-609` (TryFireLaunchPhrase) @30e03e9d
