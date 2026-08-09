# Phase 5 — PickStash + AnnotationStash port (report)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PickStash.swift`
  - `// Ported from Everywhere: src/Everywhere.Core/Interop/PickStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809`
  - Public API: `PickStash.shared`, `defaultTtl`, `set(_:ttl:)`, `take() -> PickedElement?`, `peek() -> PickedElement?`, `hasFreshPin: Bool`, `clearWithEvent()`, `clear()`.
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AnnotationStash.swift`
  - `// Ported from Everywhere: src/Everywhere.Core/Interop/AnnotationStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809`
  - Public API: `AnnotationStash.shared`, `defaultTtl`, cap constants (`maxBodyLength=8_000`, `maxAnchorLabelLength=400`, `maxAnchorRefLength=200`, `maxQueueDepth=200`), `append(_:ttl:) throws -> Int`, `peek() -> [AnnotationItem]`, `drain() -> [AnnotationItem]`, `consume(_:)`, `clearWithEvent()`, `clear()`, `count`.
  - `AnnotationStashError` typed error for cap violations.
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/PickStashTests.swift` — 12 cases.
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/AnnotationStashTests.swift` — 18 cases.
- `docs/ROADMAP/.impl-notes/phase5-pickstash-annotationstash-2026-07-23.md` — investigation notes.

## Files modified

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Appended (no existing types renamed/removed):
    - `PickedElement` (Codable/Sendable/Equatable) — lightweight value snapshot of the pinned AX element (pid, role, title, value, bounds, bundleId, capturedAt). Chosen over storing a live AX handle because openclicky's AX layer is OCCU; the stash only needs enough to identify the app + geometry for the ➕ badge overlay and to re-hydrate at MCP `read_pick` time.
    - `AnnotationSource` (String-raw enum) — cases `pin`, `whiteboard`, `selected`, `linkRect = "linkrect"`. Raw values chosen to match `ReadAnnotationsTool.SourceToWire` verbatim.
    - `AnnotationItem` (Codable/Sendable/Equatable) — 1:1 with Everywhere's `AnnotationItem` record.

## TTL constants matched

| Constant | Everywhere | openclicky | Match |
|--|--|--|--|
| `PickStash.DefaultTtl` | `TimeSpan.FromMinutes(5)` | `PickStash.defaultTtl = 300s` | yes |
| `AnnotationStash.DefaultTtl` | `TimeSpan.FromMinutes(10)` | `AnnotationStash.defaultTtl = 600s` | yes |
| `MaxBodyLength` | `8_000` | `8_000` | yes |
| `MaxAnchorLabelLength` | `400` | `400` | yes |
| `MaxAnchorRefLength` | `200` | `200` | yes |
| `MaxQueueDepth` | `200` | `200` | yes |

## Notification names used

- `Notification.Name.pickStashDidChange` (raw: `com.openclicky.contextservice.PickStashDidChange`) — posted after `set`, non-empty `take` (including TTL-expired), and `clearWithEvent` when a value was present. `object` is the `PickStash` instance so observers can filter by identity.
- `Notification.Name.annotationStashDidChange` (raw: `com.openclicky.contextservice.AnnotationStashDidChange`) — posted after `append`, non-empty `drain`, `consume` when at least one entry was removed, and `clearWithEvent` when the queue was non-empty. `object` is the `AnnotationStash` instance.

Both declarations live in `PickStash.swift` inside a single `public extension Notification.Name` block so overlay code can `import OpenClickyContextService` and observe both without extra glue.

## Alignment audit vs Everywhere

- `PickStash.take()` fires `pickStashDidChange` on every filled-to-empty transition, matching Everywhere's `fireCleared = entry is not null` guard even for TTL-expired reads (PickStash.cs:62-68).
- `PickStash.clearWithEvent()` is silent on an already-empty stash, matching Everywhere's `fire = _current is not null` guard (PickStash.cs:86-95).
- `AnnotationStash.append` prunes expired entries before enforcing the depth cap, matching AnnotationStash.cs:113-116.
- `AnnotationStash.consume` treats each `items` entry as a single removal request (descending single-remove per hit), matching Everywhere's reverse-index loop at AnnotationStash.cs:219-233. Consume fires `annotationStashDidChange` only when at least one entry was removed (Swift diverges from Everywhere's unconditional `Changed?.Invoke()` because a "consume that removed nothing" is not a state change worth waking observers for; noted here for reviewers).
- `AnnotationStash.peek` returns a materialised array without holding the lock, matching AnnotationStash.cs:133-144.
- `AnnotationStash.drain` returns the snapshot and clears atomically, matching AnnotationStash.cs:151-168.
- Peek-vs-Take semantics preserved: Peek never advances state, Take advances (PickStash), Consume removes exactly the peeked batch after a downstream write succeeds (AnnotationStash).

## Test result

- `swift test` from `Packages/OpenClickyContextService`: **437 tests, 0 failures, 8 skipped, 16.2s**. Includes the 30 new stash cases.
  - `PickStashTests`: 12/12 pass.
  - `AnnotationStashTests`: 18/18 pass.

Tests cover: set/peek/take/hasFreshPin state machine; overwrite of unread pin; injectable clock TTL expiry on peek and take; custom TTL override; clearWithEvent notification fires only on non-empty transition; silent `clear()` never fires; observer add/remove lifecycle; per-cap rejection with typed error; queue-depth overflow; expired-then-append prune path; drain returns all + clears; consume removes the peeked batch and is silent on unknown items.

Gotcha discovered while writing tests: `PickStash.take() -> PickedElement?` collides with the Swift stdlib `Optional.take()` when the test stores the stash in a `PickStash!` implicitly-unwrapped ivar — Swift resolves the call to `Optional.take()` and returns the *stash instance* while setting the ivar to nil. Tests use a non-optional `lazy var stash: PickStash` with a comment explaining why. Documented inline so future edits do not reintroduce the footgun.

## Build result

- `bash scripts/sign-and-install.sh`:
  - `[1/5] xcodebuild` — clean build succeeded (persistent self-signed cert).
  - `[2/5] codesign` — Authority `OpenClicky Dev Sign` applied.
  - `[3/5] swap /Applications/OpenClicky.app` — done.
  - `[4/5] open` — `pid=43885  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign`.
  - `[5/5] done.`

Build clean, app installed, launched.

## Known follow-ups

- **Phase 7 UI overlay** will subscribe to `pickStashDidChange` / `annotationStashDidChange` to drive the red ➕ badge, persistent ✓ badge, and delta-follow behaviour spec'd in `docs/ROADMAP/05_LAYER_4_UX.md` sections B.5 / C.
- **AX capture wiring**: `PickStash.shared.set(_:)` is not called yet — the Agent Pick hotkey handler + the `AXUIElementCopyElementAtPosition` bridge (via OCCU) will populate it in a later phase. The stash itself is thread-safe and ready.
- **MCP tool port**: Layer 2 will port `ReadPickTool.cs`, `AddAnnotationTool.cs`, `ReadAnnotationsTool.cs`, `ClearAnnotationsTool.cs` on top of these stashes. Wire strings for `AnnotationSource` are already aligned so no translation layer is required.
- **Consume semantics divergence**: Swift `consume` value-matches on the immutable `AnnotationItem` (safe because `capturedAt` gives a de-facto unique key); Everywhere reference-matches. If a future test generates two annotations with byte-identical fields including `capturedAt`, both would be considered matches; add a tie-breaker (or bump `capturedAt` to `Date.now`) at the AX capture call site to keep the invariant.
- **Silent-consume-no-op divergence**: Swift's `consume` skips firing `annotationStashDidChange` when no entries matched, while Everywhere always fires `Changed?.Invoke()` in that branch. If the overlay ever needs to react to a "we attempted a consume" event, revisit.
