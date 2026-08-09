# Layer 2 (Stash + Notification) — Byte-exact audit vs Everywhere

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Reviewer: byte-exact, file:line for every diff. Read-only audit; no
behaviour changes. Added `HeyClickyLog.log` / `CaptureLog.log`
instrumentation only.

## Files under review

| Openclicky | Everywhere |
|---|---|
| `cursor-buddy/OpenClickyContextStashWriter.swift` (586 lines) | `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (1001 lines) |
| `cursor-buddy/OpenClickyAppActivator.swift` (373 lines) | `src/Everywhere.Mac/Mcp/MacAppActivator.cs` (297 lines) |
| `Packages/…/Capture/PickStash.swift` (164 lines) | `src/Everywhere.Core/Interop/PickStash.cs` (106 lines) |
| `Packages/…/Capture/AnnotationStash.swift` (291 lines) | `src/Everywhere.Core/Interop/AnnotationStash.cs` (266 lines) |
| `Packages/…/Capture/WhiteboardStash.swift` (238 lines) | `src/Everywhere.Core/Interop/Whiteboard/WhiteboardStash.cs` (232 lines) |
| `Packages/…/Stash/OpenClickyContextSnapshotPayload.swift` (464 lines) | (part of ContextStashWriter.cs, lines 618-735, 963-1001) |
| `Packages/…/Stash/OpenClickySanitiser.swift` (153 lines) | (part of ContextStashWriter.cs, lines 30, 448-481, 798-864) |

## Audit checklist result matrix

| # | Item | Everywhere ref | Openclicky ref | Verdict |
|---|---|---|---|---|
| 1 | `Pinned` fired AFTER lock release on `Set` | `PickStash.cs:47-51` | `PickStash.swift:89-92` | MATCH |
| 1 | `Cleared` fired AFTER lock release on `Take` | `PickStash.cs:60-69` | `PickStash.swift:104-112` | MATCH |
| 1 | `Cleared` fires only when transition (fireCleared / hadEntry) | `PickStash.cs:63,68` | `PickStash.swift:106,110` | MATCH |
| 1 | `Cleared` fires on `ClearWithEvent` only if had | `PickStash.cs:88-94` | `PickStash.swift:146-153` | MATCH |
| 1 | Annotation `Changed` fired OUTSIDE lock on `Add` | `AnnotationStash.cs:118-125` | `AnnotationStash.swift:126-128` | MATCH (single unified notif) |
| 1 | Annotation `Changed` UNCONDITIONAL on `Consume` non-empty | `AnnotationStash.cs:220-232` | `AnnotationStash.swift:184-196` | MATCH (F14 HIGH #1 persists) |
| 1 | Annotation `Changed` conditional on `Drain` (had entries) | `AnnotationStash.cs:154-167` | `AnnotationStash.swift:155-163` | MATCH |
| 1 | Whiteboard `Cleared` fired OUTSIDE lock, conditional | `WhiteboardStash.cs:217-226` | `WhiteboardStash.swift:201-213` | MATCH |
| 1 | Whiteboard `Drawn` event on `Set` | `WhiteboardStash.cs:64` | (absent — documented divergence) | DIV-3 documented |
| 1 | ManualCaptureCompleted fired AFTER Activate call | `ContextStashWriter.cs:340-344` (Activate; Fire) | `OpenClickyContextStashWriter.swift:227-243` (Fire; Task { activate }) | **DIV-1 (LOW)** — order swapped |
| 1 | LinkRect ManualCaptureCompleted fired AFTER Activate | `ContextStashWriter.cs:206-207` (Activate; Fire) | `OpenClickyContextStashWriter.swift:399-406` (Fire; Task { activate }) | **DIV-2 (LOW)** — order swapped |
| 2 | Lock scope: mutation inside, notify outside | `PickStash.cs:46-50, 60-68, 88-94` | `PickStash.swift:89-93, 104-112, 146-154` | MATCH (NSLock non-reentrant safe) |
| 2 | Annotation lock scope | `AnnotationStash.cs:109-118, 156-166, 183-191, 222-232, 238-243` | `AnnotationStash.swift:118-129, 155-163, 188-196, 212-221, 234-244, 255-262` | MATCH |
| 2 | Whiteboard lock scope | `WhiteboardStash.cs:58-64, 171-178, 219-227` | `WhiteboardStash.swift:125-138, 155-165, 201-213` | MATCH |
| 3 | Consume on empty short-circuits with NO notification | `AnnotationStash.cs:221` `IsDefaultOrEmpty return;` | `AnnotationStash.swift:184` `if items.isEmpty { return }` | MATCH |
| 4 | TTL-expired `Take` still fires `Cleared` (had-entry semantics) | `PickStash.cs:63,66` (fireCleared before TTL check) | `PickStash.swift:106,110-114` | MATCH |
| 4 | TTL-expired `PruneExpired` is SILENT (no notif) | `AnnotationStash.cs:259-263` | `AnnotationStash.swift:288-290` | MATCH |
| 4 | TTL-expired `PeekImageBytes` lazy-drops silently | `WhiteboardStash.cs:157-160` | `WhiteboardStash.swift:178-186` | MATCH |
| 5 | writeAtomic: mkdir → sweep → tmp write → chmod 0600 → rename | `ContextStashWriter.cs:901-926` | `OpenClickyContextStashWriter.swift:539-568` | MATCH |
| 5 | Uses POSIX `rename(2)` overwrite semantics | `File.Move(tmp, StashPath, overwrite: true)` line 926 | `Darwin.rename(tmpPath, stashPath.path)` line 559 | MATCH |
| 5 | Sweep stale `.consumed-*.json` >10min | `ContextStashWriter.cs:929-949` | `OpenClickyContextStashWriter.swift:571-584` | MATCH |
| 6 | Non-blocking single-flight lock | `SemaphoreSlim(1,1).WaitAsync(0)` line 219 | `writeLock.try()` line 120, 335 | MATCH |
| 7 | `_phraseInFlight` interlock atomic set / clear | `ContextStashWriter.cs:519,606` (Interlocked.CompareExchange/Exchange) | `OpenClickyAppActivator.swift:210-232` (NSLock + defer) | MATCH |
| 7 | `_phraseInFlight` cleared on every exit path | Line 604-607 try/finally | Line 228-232 defer | MATCH |
| 8 | Envelope byte-exact header prefix | `[everywhere-ctx] ` line 621 | `[openclicky-ctx] ` payload:341 | MATCH (rebrand-only) |
| 8 | Envelope field order: app title url selection pin_pending whiteboard_pending regions picked_links annotations \n | Lines 622-642 | Payload:342-368 | MATCH |
| 8 | JSON before hint block, trailing \n on JSON line | Lines 677-679 | Payload:402-404 | MATCH |
| 8 | Field caps: app=64 title=80 url=256 selection=200 link.url=512 link.title=120 anno.source=32 anno.anchor=200 anno.ref=96 anno.body=800 | Lines 622,625,629,633,652,654,668-672 | Payload:343,346,349,352,374,376,386,387,389,391 | MATCH |
| 9 | 17-param redact denylist byte-match | Lines 448-455 | Sanitiser:119-124 | MATCH (verified byte-for-byte) |
| 9 | Scheme allowlist http/https/mailto | Lines 824-829 | Sanitiser:149-152 | MATCH |
| 9 | Strip userinfo | Line 461 UriBuilder{UserName="",Password=""} | Sanitiser:134-135 `comps.user=nil; comps.password=nil` | MATCH |
| 9 | IPv6 `[` `]` intentional strip preserved | Line 843 (in SanitiseTokenValue) | Sanitiser:76 | MATCH |
| 10 | Grapheme-safe truncate with `…` suffix | Lines 849-864 `StringInfo.GetTextElementEnumerator` | Sanitiser:88-103 `for c in s` (Swift Character = grapheme) | MATCH |
| 11 | SanitiseTokenValue strips ' ' + '\t' + control + `[` + `]` | Line 842-843 | Sanitiser:75-76 | MATCH (F19 HIGH #1 fix persists) |
| 12 | Settle loop 16 × 150ms with 2 stable ticks | Lines 543,547,553 | AppActivator:238-251,365-372 | MATCH |
| 12 | Pre-TypeText frontmost recheck | Lines 574-580 | AppActivator:289-297 | MATCH |
| 12 | Pre-Return frontmost recheck | Lines 590-596 | AppActivator:305-313 | MATCH |
| 12 | `NSApp.activate` flags `[activateAllWindows, activateIgnoringOtherApps]` | `MacAppActivator.cs:102` | AppActivator:103 | MATCH |
| 13 | Carbon shim actually invoked | `MacAppActivator.cs:113-123, 264-296` | `OpenClickyOverlayObjCBridge.m:68` called at AppActivator:149 | MATCH (F20 stub → shim persists) |
| 14 | Phrase whitespace guard trims BEFORE empty check | Line 512 `IsNullOrWhiteSpace(phrase)` | AppActivator:198-199 `.trimmingCharacters(...)` then `.isEmpty` | MATCH |

## Issues found

### DIV-1 (LOW) — ManualCaptureCompleted notification ORDER vs Activate

**Everywhere** (`ContextStashWriter.cs:340-344`):

```csharp
if (drainAnnotations)
{
    ActivateAgentApp();          // <-- activate + phrase FIRST
    ManualCaptureCompleted?.Invoke();  // <-- badge fan-out SECOND
}
```

The C# `ManualCaptureCompleted` is a synchronous event. Because
`ActivateAgentApp()` internally kicks the phrase pipeline via
`Task.Run(async () => ...)` (line 527), the `.Invoke()` call runs after
the fire-and-forget dispatch. Semantically: the badge overlay sees the
event AFTER the activation task has already been scheduled.

**Openclicky** (`OpenClickyContextStashWriter.swift:227-243`):

```swift
if wrote && drainAnnotations {
    NotificationCenter.default.post(
        name: .openClickyManualCaptureCompleted,   // <-- FIRST
        object: self
    )
    Task { await activateAgentAndFirePhrase() }    // <-- SECOND
}
```

Notification posts BEFORE the Task is scheduled. Since
`NotificationCenter.default.post` is synchronous but the observer
work is trivial, and `Task { }` schedules on the current actor, the
observable ordering diverges from Everywhere by roughly one runloop
tick.

Impact: Downstream observers (annotation badge overlay) receive the
"you may tear down" signal marginally BEFORE the activation task
starts, whereas Everywhere delivers it AFTER activation is scheduled.
No functional bug, but the annotation overlay could theoretically
observe a "still-frontmost source app" snapshot before Openclicky's
activator has kicked off. Log-only — no behaviour change requested.

### DIV-2 (LOW) — Same ordering divergence in `captureLinks` path

**Everywhere** (`ContextStashWriter.cs:205-207`):

```csharp
_logger.LogInformation("Context stash captured {Count} links from {App}.", picked.Count, appKey);
ActivateAgentApp();
ManualCaptureCompleted?.Invoke();
```

**Openclicky** (`OpenClickyContextStashWriter.swift:395-406`): fires
`ManualCaptureCompleted` FIRST, then dispatches Task for activation.
Same impact as DIV-1.

### DIV-3 (INFO, documented) — `WhiteboardStash.Set` has no `Drawn` event

**Everywhere** (`WhiteboardStash.cs:37-38, 64`):

```csharp
public event Action<IReadOnlyList<WhiteboardRegion>>? Drawn;
...
Drawn?.Invoke(regions);
```

**Openclicky** (`WhiteboardStash.swift:113-139`): no `Drawn`
notification is emitted on `.set(...)`. The file header (lines 30-32)
documents this intentional divergence — Phase 7 overlay does its own
region assembly and calls `set()` once per commit, no external
listener needs the `Drawn` signal. Only `Cleared` is preserved.

Impact: an external consumer that wanted to react to a fresh
whiteboard write (mirroring Everywhere's `ContextStashWriter`
auto-capture hook at `WhiteboardHotkeyInitializer.cs:735`) would not
receive a notification. This branch is unreachable in current
openclicky because auto-capture on whiteboard commit is a Phase 7
TODO. Log-only.

### DIV-4 (INFO, documented) — Unified `didChange` notification vs separate `Pinned`/`Cleared`, `Added`/`Changed`

**Everywhere**: distinct events (`Pinned` on Set, `Cleared` on Take/
ClearWithEvent, `Added` per item + `Changed` for count transitions).

**Openclicky**: single `pickStashDidChange` / `annotationStashDidChange`
notification; observers query state via `.peek()` / `.hasFreshPin`.

Mechanically different but functionally equivalent. Openclicky's
`PickStash.swift:29-42` and `AnnotationStash.swift:24-28` document
the unification. Log-only.

### DIV-5 (INFO, documented) — `WhiteboardStash.set(regions: [])` accepts empty vs Everywhere throws

**Everywhere** (`WhiteboardStash.cs:49-50`):

```csharp
if (regions.Count == 0)
    throw new ArgumentException("At least one region required", nameof(regions));
```

**Openclicky** (`WhiteboardStash.swift:126-132`): silently accepts
`regions.isEmpty` and stores nil-session (no pending regions). File
header (lines 106-112) documents the intentional divergence.

Impact: caller passing an empty region list gets `hasPending == false`
in Swift but an `ArgumentException` in C#. Openclicky's callers
(Phase 7 overlay) filter upstream, so the branch is unreachable in
practice. Log-only.

### DIV-6 (INFO, documented) — Annotation `removeItem` value vs reference identity

**Everywhere** (`AnnotationStash.cs:186`):

```csharp
var idx = _entries.FindIndex(e => ReferenceEquals(e.Item, item));
```

**Openclicky** (`AnnotationStash.swift:214`):

```swift
let idx = entries.firstIndex(where: { $0.item == item })
```

Value equality on a Swift struct with a `capturedAt` timestamp is
de-facto identity. Documented at `AnnotationStash.swift:199-208`.
Log-only.

## Non-issues (verified byte-exact)

- Lock discipline: notification calls are ALWAYS outside `NSLock`.
  Non-reentrant deadlock risk audited; no reentrant call sites exist.
- `writeAtomic` sequence: `mkdir → sweep → tmp write → chmod 0600 →
  rename(2)`. Byte-exact to Everywhere.
- `writeLock.try()` non-blocking pattern matches SemaphoreSlim(1,1).
- 17-param URL redact denylist byte-match, scheme allowlist byte-match,
  userinfo strip.
- Grapheme-safe truncate via Swift `Character` iteration (never split
  surrogate pairs / emoji ZWJ). Ellipsis `…` suffix matches C#.
- Space-terminated envelope grammar: `sanitiseTokenValue` correctly
  strips space + tab + controls + `[` + `]` (F19 HIGH #1 fix persists).
- IPv6 bracket strip is intentional Everywhere behaviour, preserved
  verbatim (F19 flagged).
- Settle-loop constants (16 × 150ms = 2.4s, 2 stable ticks) byte-match.
- Focus-steal rechecks between Activate/TypeText and TypeText/Return
  are present.
- `NSRunningApplication.activate(options: [.activateAllWindows,
  .activateIgnoringOtherApps])` byte-match.
- Carbon shim `OpenClickyCarbonSetFrontProcess` at
  `OpenClickyOverlayObjCBridge.m:68` invoked by
  `OpenClickyAppActivator.swift:149` (F20 stub replaced).
- `_phraseInFlight` NSLock+Bool interlock matches
  `Interlocked.CompareExchange`; `defer` clears on every exit path.
- Phrase `IsNullOrWhiteSpace` semantics matched via
  `.trimmingCharacters(in: .whitespacesAndNewlines)` before
  `.isEmpty`.

## Instrumentation added

All log points below emit through `HeyClickyLog.log` (main app) or
`CaptureLog.log` (SPM package — sink installed by main app at startup,
forwarded into HeyClickyLog). All new log calls are additive; no
behaviour change.

Package-side (Stash lane):
- `openclicky.stash.pick.set` — role/title/pid/replaced_prev/ttl_seconds
- `openclicky.stash.pick.take` — was_empty/entry_age_seconds
- `openclicky.stash.pick.cleared` — reason=take|clear_with_event|ttl_expired
- `openclicky.stash.annotation.push` — source/count_before/count_after
- `openclicky.stash.annotation.consume` — input_batch/kept/drained
- `openclicky.stash.whiteboard.set` — region_count/has_image_bytes
- `openclicky.stash.whiteboard.clear_with_event` — regions_gated/images_gated

App-side (Writer lane):
- `openclicky.stash.writer.acquire_lock` / `release_lock` — caller/duration_ms
- `openclicky.stash.writer.phrase_in_flight_set` — from_state
- `openclicky.stash.writer.phrase_in_flight_reset` — reason
- `openclicky.stash.writer.atomic_write` — bytes/path_hash/ok/errno_if_fail
- `openclicky.stash.writer.envelope_composed` — section_bytes/hint_kind/links_count/annotations_count

AppActivator (existing + expanded):
- `openclicky.app_activator.attempt` — target/target_bundle/target_pid
- `openclicky.app_activator.settle_tick` — i/actual_bundle
- `openclicky.app_activator.settle_ok` — ticks_used
- `openclicky.app_activator.settle_failed` — actual_bundle (already
  present at `settle_frontmost_snapshot` / `settle_failed`)
