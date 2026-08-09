# Phase 5 — PickStash + AnnotationStash port (investigation)

**Everywhere sources @30e03e9dcfdd4247fd679828ed86e9042f32d809**
- `src/Everywhere.Core/Interop/PickStash.cs`
- `src/Everywhere.Core/Interop/AnnotationStash.cs`
- Consumers: `src/Everywhere.Mcp/Tools/{ReadPickTool,AddAnnotationTool,ReadAnnotationsTool,ClearAnnotationsTool}.cs`

## PickStash — extract

| Aspect | Everywhere | openclicky port |
|--|--|--|
| TTL | `DefaultTtl = TimeSpan.FromMinutes(5)` (line 14) | `PickStash.defaultTtl: TimeInterval = 300` |
| Storage | `Entry?` (single slot) with `IVisualElement` | Single-slot with lightweight `PickedElement` value snapshot |
| Lock | `Lock _gate = new()` | `NSLock` |
| Clock | `TimeProvider _clock` | `() -> Date` closure |
| Set semantics | overwrite prior slot, then fire `Pinned` handler | overwrite prior slot, then post `pickStashDidChange` |
| Take | atomic read+clear; if entry existed, fire `Cleared`; TTL-expired take returns nil but still fires because slot transitioned from non-nil to nil | same |
| HasFreshPin | non-expired presence probe under lock | same |
| ClearWithEvent | drops slot, fires `Cleared` only if it had a value | same |
| Clear (silent) | drops slot silently | preserved as `clear()` |

Notification model in Everywhere is two separate `event Action`s (`Pinned`, `Cleared`). Task brief pins us to a single `didChange` NotificationCenter event, so the Swift port funnels both transitions through `pickStashDidChange`. Observers get the stash as `object:` and can `peek()` / read `hasFreshPin` to discriminate the fill-vs-clear direction.

## AnnotationStash — extract

| Aspect | Everywhere | openclicky port |
|--|--|--|
| TTL | `DefaultTtl = TimeSpan.FromMinutes(10)` (line 57) | `AnnotationStash.defaultTtl = 600` |
| Caps | `MaxBodyLength = 8_000`, `MaxAnchorLabelLength = 400`, `MaxAnchorRefLength = 200`, `MaxQueueDepth = 200` (lines 63-66) | verbatim static constants |
| Storage | `List<Entry>` (item + expiry) | `[Entry]` |
| Lock | `Lock _gate = new()` | `NSLock` |
| Clock | `TimeProvider _clock` | `() -> Date` closure |
| Add | validate lengths, prune expired, enforce depth cap, append, then fire `Changed` and `Added` per item | same; single `annotationStashDidChange` per append |
| Peek | prune + snapshot `ImmutableArray<AnnotationItem>` without consuming | `[AnnotationItem]` |
| Drain | atomic read + clear; fires `Changed` only when non-empty | same, retained for parity |
| Consume | remove items previously peeked (reference identity in Everywhere; value identity in Swift port because `AnnotationItem` is an immutable value type and `capturedAt` gives a de-facto unique key) | descending single-remove per hit, event fires only when at least one removed |
| Clear | silent bulk drop, then optional `Changed` when entries existed | `clearWithEvent()` matches Everywhere's `Clear` + `Changed?.Invoke()`; `clear()` is the silent shutdown variant |
| Count | prune + return live count | same |

Everywhere throws `ArgumentException` on cap violation. openclicky port throws typed `AnnotationStashError` so callers upstream can produce parity error strings without string-matching English messages.

## Consumer verification

- `ReadPickTool` (line 30): `stash.Take()` → agent consumes the pin, next call sees empty. Confirmed the port's `take()` matches.
- `AddAnnotationTool` (line 42): `annotations.Add(new AnnotationItem(...))` → returns int queued count. Confirmed the port's `append(_:) -> Int`.
- `ReadAnnotationsTool` (line 21): `annotations.Peek()` → non-consuming snapshot. Wire strings for `AnnotationSource` mapped to `pin | whiteboard | selected | linkrect`; the Swift enum's raw values match verbatim (with `linkRect = "linkrect"` for the one case with camelCase collision).
- `ClearAnnotationsTool` (line 18-19): reads `Count` then calls `Clear()`. Both semantics preserved.

## Thread-safety and event ordering

Everywhere fires events **after** the lock is released. The Swift port does the same: mutation under `gate.lock()/unlock()`, then `notificationCenter.post(...)` on the caller thread. NotificationCenter's default queue is nil so observers run synchronously on the same thread — matches Everywhere's "Handlers run synchronously on the caller thread; keep them lightweight" contract.

## Types added to `CaptureTypes.swift`

- `PickedElement` (Codable/Sendable/Equatable) — value snapshot of a pinned AX element. Not `IVisualElement`: Everywhere stores the live AX object because it re-walks it at `read_pick` time via `ElementIndexer.Walk`. openclicky's AX layer is provided by OCCU; the stash only needs to carry enough to (a) identify the app + pid + bounds for the UI overlay's ➕ badge follow-along, and (b) hand the pid to OCCU when the MCP tool re-hydrates. Anything richer is captured live via OCCU at consume time.
- `AnnotationItem` (Codable/Sendable/Equatable) — 1:1 with Everywhere's `AnnotationItem` record.
- `AnnotationSource` (String-raw enum, Codable/Sendable/CaseIterable) — 1:1 with Everywhere's `AnnotationSource`. Raw values chosen so `Codable` output matches `ReadAnnotationsTool.SourceToWire` verbatim (`pin | whiteboard | selected | linkrect`).

Appended only — no existing struct renamed or deleted.
