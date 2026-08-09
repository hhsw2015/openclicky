# Phase 5 - AXQuirksInstaller port report (2026-07-22)

Ports Everywhere's `SetAppBoolAttribute` primitive + the private-
attribute quirk-install call site to Swift as
`AXQuirksInstaller.swift`. Covers roadmap rows 20 and 21 of
`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`.

## Deliverables

| Path | Kind | Lines |
|------|------|------|
| `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AXQuirksInstaller.swift` | NEW | 272 |
| `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/AXQuirksInstallerTests.swift` | NEW | 253 |
| `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` | append `AXQuirkInfo` | +58 |
| `docs/ROADMAP/.impl-notes/phase5-axquirks-2026-07-22.md` | investigation notes | 175 |
| `docs/ROADMAP/.impl-notes/phase5-axquirks-report-2026-07-22.md` | this file | - |

## Public API

Matches the task spec exactly:

```swift
public enum AXQuirksInstaller {
    public static let manualAccessibility: String
    public static let enhancedUserInterface: String

    public static func installIfNeeded(pid: Int32) throws
    public static func setBoolAttribute(pid: Int32, attribute: String, value: Bool) throws
}
```

Plus:
- `AXQuirksError` (thrown type): `.invalidPid(Int32)`, `.setAttributeFailed(status: Int32)` — Equatable, Sendable.
- `AXQuirkInfo` (in `CaptureTypes.swift`): Codable per-pid record for router / stash callers.
- Two test-only hooks with `internal` access: `installedPidsSnapshot()`, `resetInstalledPidsForTesting()`.

## Ground truth traced

- `AXUIElement.cs:1178-1203` — `SetAppBoolAttribute`. 1:1 port including the CFBoolean-singleton contract (comment L1181-1184).
- `AXAttributeConstants.cs:30-31` — attribute-name strings, byte-identical.
- `VisualElementContext.cs:113-130` — `TryEnableBestEffortAccessibility`. Same order (`AXManualAccessibility` first, `AXEnhancedUserInterface` second), same "no bundle-id branching" contract.
- `AppResolver.cs:12-53` — per-pid memoisation via `ConcurrentDictionary<int,bool>`, plus the 1500 ms bounded-wait wrapper. Memoisation is inside the installer; the timeout stays at the caller as in Everywhere.
- `VisualElementContext.TextSelection.cs:261-265` — provenance comment (Chromium needs Enhanced, Electron needs Manual).
- `SnapshotRenderer.cs:241-252` — `DisplayRole`: NOT a per-app quirks table. Per-element-TYPE remap that belongs inside the snapshot renderer, not the installer. Roadmap row 21 is therefore effectively covered by the SnapshotRenderer port (out of Layer-0 scope). Documented in the investigation notes.

## Deviations from Everywhere (with rationale)

| # | Everywhere | This port | Rationale |
|---|-----------|-----------|-----------|
| 1 | Returns `bool` on failure | Throws `AXQuirksError` | Task spec hard constraint |
| 2 | Success is `AXError.Success` only | `.success` OR `.noValue` | Private attrs return `.noValue` when the app hasn't preloaded them; the flip still lands. Task-spec skeleton widening. |
| 3 | `manualOk \|\| enhancedOk` | Both must succeed for cache | Simpler contract: partial install is not cached, can be retried. Matches the "throws first" order in the file header. |
| 4 | `ConcurrentDictionary<int,bool>` | `Set<Int32>` + `NSLock` | Same guarantees, Swift-idiomatic |
| 5 | 1500 ms bounded-wait at caller (`AppResolver`) | Same separation — not in installer | Preserves the caller-controls-timeout contract |

## Alignment audit

- Attribute strings byte-identical (`AXManualAccessibility`, `AXEnhancedUserInterface`).
- Call order identical (manual first, enhanced second) — matches `VisualElementContext.cs:127-128`.
- CFBoolean singleton path preserved (Swift bridging via `kCFBooleanTrue` / `kCFBooleanFalse`) — matches the L1181-1184 comment's requirement that `NSNumber` is rejected.
- `pid <= 0` short-circuit preserved (returns before touching AX).
- Memoisation semantic preserved (per-pid, once per process lifetime).

## Tests

`swift test --filter AXQuirksInstallerTests` — 12 tests, 1 correctly skipped:

- `test_attributeConstants_matchEverywhere` — constants byte-check.
- `test_installIfNeeded_negativePid_throwsInvalidPid`.
- `test_installIfNeeded_zeroPid_throwsInvalidPid`.
- `test_setBoolAttribute_zeroPid_throwsInvalidPid`.
- `test_setBoolAttribute_negativePid_throwsInvalidPid`.
- `test_installIfNeeded_forOwnPid_doesNotTrap` — consent-agnostic: accepts either success or `.setAttributeFailed`.
- `test_installIfNeeded_isIdempotent_afterSuccess` — installed-set size unchanged on repeat call after a successful first install.
- `test_installIfNeeded_failedInstallIsNotCached` — bogus pid never poisons the cache (this is the throw-then-retry contract).
- `test_setBoolAttribute_unknownAttribute_doesNotTrap` — no crash on unknown attribute.
- `test_installIfNeeded_cacheHit_shortCircuitsAX` — SKIPPED on runners without AX consent (`XCTSkip`, expected outcome; documented in the test itself).
- `test_axQuirkInfo_roundTripsJSON` — JSON encode/decode.
- `test_axQuirksError_equality`.

Full suite: `swift test` → 243 tests, 3 skipped, 0 failures.

## What was NOT touched

- No other Capture/*.swift file.
- No changes to `Package.swift`.
- The main app project (`cursor-buddy/*.swift`) — nothing wired to the installer yet; the roadmap makes this a Phase-5 primitive that later Layer-1 / Layer-2 code will consume.

## Follow-ups (out of scope for this phase)

- Wire `installIfNeeded` into whichever Layer-1 entry point picks the pid to walk (mirrors Everywhere's `AppResolver.EnsureA11yEnabledOnce` — will need the 1500 ms `Task { try? ... }` + timeout wrapper on the caller side).
- Roadmap row 21 (per-app quirks / `DisplayRole`) will be picked up when `SnapshotRenderer.cs` is ported; that is not an accessibility-quirks concern.
