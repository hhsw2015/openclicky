# Phase 5 — WhiteboardStash + LinkRectStash port report (2026-07-23)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/WhiteboardStash.swift`
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/WhiteboardStashTests.swift`
- `docs/ROADMAP/.impl-notes/phase5-whiteboard-linkrect-stash-2026-07-23.md`
- `docs/ROADMAP/.impl-notes/phase5-whiteboard-linkrect-stash-report-2026-07-23.md` (this file)

## Files modified

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Appended `WhiteboardRegion`, `WhiteboardImageEntry`, `PickedLinkStashItem`.
  - No existing struct touched.

## Files NOT created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/LinkRectStash.swift`
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/LinkRectStashTests.swift`

## LinkRect stash decision

Grep across `Everywhere/src/` for `LinkRectStash` yielded exactly one hit —
a comment in `ContextStashWriter.cs`: `"CaptureLinksAsync; nothing to drain
from a LinkRectStash"`. **No `LinkRectStash` class exists in Everywhere.**
The LinkRect harvest path lives in `Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs`
as `LinkRectSession`, which is the overlay + harvest UI. Its output is a
`HarvestResult` that flows straight into `ContextStashWriter` and is
serialised to `context-stash.json` `picked_links[]`.

Consequence: the Swift port has no `LinkRectStash.swift` (matching source
truth). The wire-format record for the on-disk stash is instead materialised
as `PickedLinkStashItem` in `CaptureTypes.swift`, ready for the Phase 6
context-stash-writer agent to consume when it serialises `picked_links[]`.

## Everywhere TTL / semantics matched

| Everywhere source | Swift port |
| --- | --- |
| `DefaultTtl = TimeSpan.FromMinutes(5)` (`WhiteboardStash.cs:14`) | `defaultTtl: TimeInterval = 300` |
| `_current` single-slot most-recent-wins (`cs:18`) | `pendingRegions: [WhiteboardRegion]?` |
| `_imageBytesById` side-table (`cs:23`) | `imageBytesById: [UUID: WhiteboardImageEntry]` |
| `_imageBytesExpiresAtUtc` shared TTL (`cs:24`) | Per-entry `expiresAtUnix` set from same clock+TTL at `set()` time |
| `Take()` clears regions only (`cs:169-178`) | `take()` clears `pendingRegions` and `pendingExpiresAtUnix`, leaves image cache alone |
| `PeekImageBytes` lazy expiry (`cs:145-164`) | `imageBytes(for:)` removes the entry on TTL expiry, returns nil |
| `Peek()` non-consuming, TTL-checked (`cs:183-190`) | `peek()` same |
| `Clear()` drops both (`cs:203-210`) | Rolled into `clearWithEvent()` since brief only asks for that method |
| `ClearWithEvent()` fires event when non-empty (`cs:217-227`) | Posts `NSNotification.openClickyWhiteboardStashCleared` when either slot was populated |
| `HasFreshWhiteboard` (`cs:192-201`) | `hasPending` |
| `TimeProvider` clock injection (`cs:17, 28`) | Designated init takes `clock: () -> Date` and optional `NotificationCenter`, mirroring `SelectionCache` |

## `_imageBytesById` side-table — Take does NOT clear image cache

Verified with unit test `test_imageBytes_survivesTake`:

```
set(regions: [r], imageBytesById: [id: pngBytes])
take()                                  // consumes regions
imageBytes(for: id) == pngBytes         // still returns bytes
```

This is the load-bearing detail from doc 05 line 27. `take()` deliberately
inspects only the regions slot; the image cache is only replaced by a
subsequent `set()`, by explicit `clearWithEvent()`, or by lazy per-entry TTL
expiry inside `imageBytes(for:)`.

## Public API surface

```swift
WhiteboardStash.shared
WhiteboardStash.defaultTtl                                  // 300
func set(regions: [WhiteboardRegion], imageBytesById: [UUID: Data])
func peek() -> [WhiteboardRegion]?
func take() -> [WhiteboardRegion]?
func imageBytes(for id: UUID) -> Data?
func clearWithEvent()
var hasPending: Bool

// Test-only ctor (public for the test target):
init(clock: @escaping () -> Date, ttl: TimeInterval = defaultTtl,
     notificationCenter: NotificationCenter = .default)
```

`Notification.Name.openClickyWhiteboardStashCleared` is posted by
`clearWithEvent()` when either slot was populated.

## Test results

`WhiteboardStashTests` — 17 test cases, all pass in isolation:

```
Test Suite 'WhiteboardStashTests' passed at 2026-07-23 00:23:04.525.
Executed 17 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
```

Cases:
- `test_defaultTtl_isFiveMinutes`
- `test_set_thenPeek_returnsRegions`
- `test_peek_isNonConsuming`
- `test_set_replacesPreviousSession`
- `test_take_returnsRegionsAndClearsSlot`
- `test_imageBytes_survivesTake` (load-bearing side-table check)
- `test_imageBytes_returnsNilForUnknownId`
- `test_imageBytes_returnsNilBeforeAnySet`
- `test_peek_returnsNil_afterTtlExpiry`
- `test_take_returnsNil_afterTtlExpiry`
- `test_imageBytes_returnsNil_afterTtlExpiry`
- `test_peek_stillReturnsBeforeExpiry`
- `test_clearWithEvent_dropsBothSlots`
- `test_clearWithEvent_postsNotification_whenPending`
- `test_clearWithEvent_isSilent_whenEmpty`
- `test_hasPending_reflectsLifecycle`
- `test_whiteboardRegion_codableRoundTrip`

## Build / global-test status

- `swiftc -parse` on the two touched Swift files: clean.
- `swift test --filter WhiteboardStashTests` first run (00:23:04): 17/17 pass.
- Subsequent `swift test` invocations at 00:24 and 00:26 hit **unrelated
  compile failures** in concurrent-agent work:
  - `Sources/OpenClickyContextService/Memory/MemoryStore.swift:55` —
    `Self.currentMillis()` in a default arg (concurrent Memory-stash agent).
  - `Sources/OpenClickyContextService/Memory/OpenClickyMemoryTools.swift:371` —
    async-context `NSLock.unlock` warning-as-error.
  - `Tests/OpenClickyContextServiceTests/FocusedElementCaptureTests.swift:85` —
    uses `FocusedElementInfo.processId` that has since been renamed.

  Timestamps (`stat -f`) confirm those files were being edited by other
  agents at 00:23:32, 00:24:05, and later — my Phase 5 files (WhiteboardStash
  written at 00:22:13, tests at 00:23:00) are unaffected. Not in scope per
  the brief's "Do not touch other Capture/*.swift (concurrent agents)"
  guardrail.

- `bash scripts/sign-and-install.sh`: fails at `xcodebuild` step with two
  unrelated errors:
  1. `Package.swift` was edited by a concurrent agent to add an
     `openclicky-context-hook` executable target with an empty source
     directory (`main.swift` did appear a moment later at 00:27:02, but
     the package resolver had already been invoked).
  2. `No profiles for 'com.jkneen.openclicky' were found` — provisioning
     profile issue independent of Swift source changes.

  Both are environmental / concurrent-agent state, not caused by the
  Phase 5 port. My added files parse cleanly under
  `swiftc -parse -sdk macosx` (verified).

## Doc reconciliation

`docs/ROADMAP/05_LAYER_4_UX.md` lines 26-27 already describe:
- Memory-only stash with `DefaultTtl = FromMinutes(5)`.
- `_imageBytesById` side-table with same TTL, surviving `Take()` for the
  `read_whiteboard_image(id)` second query.

No doc update required — the port matches the doc verbatim.

## Not-in-scope untouched

- Any other `Sources/OpenClickyContextService/Capture/*.swift`.
- Any `Memory/*.swift` (concurrent agents actively editing).
- `Package.swift`, `sign-and-install.sh`, provisioning config.
- `Types/CaptureTypes.swift` existing types (only appended new ones).
- Route dispatcher (Phase 4), stash writer (Phase 6), overlay/gesture
  UI (Phase 7).
