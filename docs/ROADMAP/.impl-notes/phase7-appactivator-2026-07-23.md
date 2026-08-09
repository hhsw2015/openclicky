# Phase 7 — AppActivator + LaunchPhrase parity

Source of truth (@30e03e9d):
- `src/Everywhere.Mac/Mcp/MacAppActivator.cs` (297 lines)
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:509-609` (TryFireLaunchPhrase)
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:130-213` (CaptureLinksAsync)
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:367-388` (ActivateAgentApp)

## Extracted invariants

### AppActivator

- `Activate(appIdentifier)`:
  1. Resolve `NSWorkspace.sharedWorkspace`; return false on failure.
  2. Short-circuit success if already frontmost (returns true without any activation call — noisy focus blink otherwise).
  3. Enumerate `runningApplications`; match on `bundleIdentifier` OR `localizedName` OR `executableURL.lastPathComponent`, case-insensitive exact.
  4. `activateWithOptions:` with `ActivateAllWindows | ActivateIgnoringOtherApps`.
  5. Best-effort `SetFrontProcessWithOptions` (Carbon) follow-up to beat focus-stealing apps. Skip on failure — the ObjC activate is baseline.
- `IsFrontmost(id)`: `NSWorkspace.frontmostApplication` bundleIdentifier / localizedName / executable basename equals `id` (case-insensitive exact).
- `SupportsFrontmostDetection` = true (macOS).
- Priming: constructor calls `NSWorkspace.sharedWorkspace.runningApplications` + `.frontmostApplication` eagerly to warm AppKit for the first LSUIElement invocation.

### TryFireLaunchPhrase (ContextStashWriter.cs:509-609)

- Skip when `LaunchPhrase` is null/whitespace.
- Skip when `!SupportsFrontmostDetection`.
- `Interlocked.CompareExchange(ref _phraseInFlight, 1, 0) != 0` → skip; concurrent fires collapse.
- Fire-and-forget task; `finally { _phraseInFlight = 0 }` regardless of return path.
- **Settle loop**: `for i in 0..<16`:
  - `_appActivator.Activate(agentAppId)` each tick (swallow throw).
  - `await Task.Delay(150)`.
  - `IsFrontmost` check (swallow throw → false).
  - If front: `stable++`; when `stable >= 2` → `settled = true` and break.
  - If not front: `stable = 0`.
- 16 × 150ms = **2.4s cap**. If unsettled → log info and return.
- **Pre-type frontmost recheck** (`IsFrontmostSafe`). If lost → log warn and return before typing.
- `_input.TypeText(phrase)`.
- **Pre-Return frontmost recheck**. If lost → log warn, DO NOT press Return (keystrokes may have leaked but Return submits, so withhold).
- `_input.PressKey("Return")`.
- Log info on success.

### CaptureLinksAsync (ContextStashWriter.cs:130-213)

- Empty/null links → return.
- Non-blocking single-flight via `_writeLock.WaitAsync(0)`. Held → drop.
- Snapshot: FocusedElement → topLevel → pid → appKey → browser URL.
- Filter: `MaxLinks=200`, `MaxUrlLen=2048`, `MaxTitleLen=200`.
  - Reject empty url, oversize url, disallowed scheme (`IsAllowedScheme`).
  - Dedup by `url + "\0" + (title ?? "")` (case-insensitive).
  - Trim title to `MaxTitleLen` graphemes.
- `PeekAnnotationsForPayload()` — include queued annotations without consuming.
- `WriteAtomicAsync(FormatForHook(payload))`.
- `_annotationStash.Consume(annoSource)` **after** successful write.
- `ActivateAgentApp()` → fires LaunchPhrase pipeline.
- `ManualCaptureCompleted?.Invoke()` — even though not "manual", LinkRect surfaces UI feedback.

### ActivateAgentApp (ContextStashWriter.cs:367-388)

- Guard `string.IsNullOrWhiteSpace(id)` → log info, return.
- `_appActivator.Activate(id)` try/catch. Log warn on throw and return.
- If `!raised` → return (no phrase).
- `TryFireLaunchPhrase(id)`.

## Openclicky port plan

### New file: `cursor-buddy/OpenClickyAppActivator.swift`

- Singleton `OpenClickyAppActivator.shared`.
- `activate(_ bundleId: String) -> Bool`:
  - Trim, empty → false.
  - `NSWorkspace.shared.frontmostApplication` short-circuit: if bundleId matches → true.
  - `NSWorkspace.shared.runningApplications` filter on `bundleIdentifier` OR `localizedName` OR `executableURL.lastPathComponent`, case-insensitive exact.
  - `.activate(options: [.activateAllWindows])` (modern signature; ignoringOtherApps deprecated in macOS 14+ but the flag is still accepted — use `.activate(options: [])` where deprecation warns, or fall back to raw).
  - Skip Carbon follow-up — NSWorkspace on macOS 14+ is polite too, but the openclicky flow is not hit by Arc-style focus stealers as much as Everywhere (different UX). If needed later, port `SetFrontProcessWithOptions` as second pass. Note in doc.
- `isFrontmost(_ bundleId: String) -> Bool`:
  - `NSWorkspace.shared.frontmostApplication` → compare bundleIdentifier / localizedName / executableURL basename, case-insensitive.
- `supportsFrontmostDetection: Bool` → true.
- `fireLaunchPhrase(bundleId:phrase:) async`:
  - `NSLock` guard around `phraseInFlight` bool. Skip when already in-flight.
  - Settle loop: 16 iterations × 150ms, 2 consecutive frontmost ticks required.
  - Pre-type isFrontmost gate. Skip on lost focus.
  - `InputSimulator.typeText(phrase)`.
  - Pre-Return isFrontmost gate. Skip Return on lost focus.
  - `try? InputSimulator.pressKey("Return")`.
  - Always release phraseInFlight in `defer`.

### Extension to `cursor-buddy/OpenClickyContextStashWriter.swift`

- Append (do NOT rewrite existing) two methods:
  - `public func captureLinks(_ links: [(title: String, url: String)]) async` — new snapshot + link filter/cap/dedup + atomic write + activate.
  - `private func activateAgentAndFirePhrase() async` — reads settings, calls activator.

Wait — task says LinkRect entry is direct (Everywhere `CaptureLinksAsync`), but existing writer already has a `captureLinks([OpenClickyPickedLink])` that goes through captureCoreAsync. We should add a **new** entry that mirrors `CaptureLinksAsync` semantics: snapshots frontmost+url+topLevel but does NOT include selectionText/pinPending/whiteboard. This is the correct byte-for-byte port. The existing `captureLinks(links: [OpenClickyPickedLink])` on the writer is not the same shape; task hands us `(title, url)` tuples. Consider re-namespacing.

Decision: existing `captureLinks([OpenClickyPickedLink])` stays (Phase 7.1 harvester feeds pre-normalised picks). Add a new distinct entry that takes raw `(title, url)` — call it `captureLinks(fromRawTuples:)` OR overload the signature. Task spec calls it `captureLinks(_ links: [(title: String, url: String)]) async` — that's a different tuple shape from the existing `[OpenClickyPickedLink]` overload so overload works cleanly.

Wait — task instruction is "Extend openclicky's context stash writer with two Everywhere-parity flows" and specifies `captureLinks(_ links: [(title: String, url: String)])`. Existing method has same name but different signature. Swift disambiguates by parameter label / type. Both can coexist.

Confirmed plan:
- **Keep** existing `captureLinks(_ links: [OpenClickyPickedLink])`.
- **Add** new `captureLinks(_ links: [(title: String, url: String)])` that mirrors Everywhere `CaptureLinksAsync` exactly (filter, redact, cap, dedup, snapshot, write, activate).
- Both call `activateAgentAndFirePhrase()` after successful write.

### Settings read

- `OpenClickyContextAwarenessSettings.shared.agentAppId`
- `OpenClickyContextAwarenessSettings.shared.launchPhrase`

These are @Published on a non-@MainActor ObservableObject — reading String properties from a background Task is safe (Swift 5.5+ String has no isolation).

## Timing constants (must match)

| constant                       | value      | source                              |
|--------------------------------|------------|-------------------------------------|
| settle iterations              | 16         | ContextStashWriter.cs:543           |
| settle tick delay              | 150 ms     | ContextStashWriter.cs:547           |
| stable-ticks-required-to-settle| 2          | ContextStashWriter.cs:553           |
| MaxLinks                       | 200        | ContextStashWriter.cs:159           |
| MaxUrlLen                      | 2048       | ContextStashWriter.cs:160           |
| MaxTitleLen                    | 200        | ContextStashWriter.cs:161           |

## Test plan (XCTest, cursor-buddyTests)

- `test_activate_emptyBundleId_returnsFalse`
- `test_activate_unknownBundleId_returnsFalse`
- `test_isFrontmost_unknownBundleId_returnsFalse`
- `test_supportsFrontmostDetection_isTrue`
- `test_fireLaunchPhrase_emptyPhrase_isNoOp` — no throw, phraseInFlight cleared
- `test_fireLaunchPhrase_concurrent_onlyOneRuns` — spawn 2 tasks; only first acquires phraseInFlight; second returns immediately

Skip real-app activate (`com.apple.finder`) — headless CI would flake. Keep only invariants that don't require actual UI focus.
