# Adversarial review — multi-pin PickStash + LinkRectStash + voice-prompt stash bridge

Scope: seven files listed in the task. Findings ordered by severity.

## CRITICAL

### C1. `currentStashContextForVoicePrompt` blocks main thread up to 250 ms
`CompanionManager` is `@MainActor`, and this fn is called synchronously from
`beginBidirectionalVoiceTurn`'s system-prompt argument (CompanionManager.swift:5987,5995).
Line 17484 `_ = sem.wait(timeout: .now() + .milliseconds(250))` is a hard
main-thread block. This wedges the run loop long enough for jitter (voice-turn
start latency, missed vsync, deferred notifications, `pickStashDidChange`
observers wait, spinner freezes). Everywhere never blocks main here — its
capture pipeline is fully async.

Fix: make `currentRealtimeVoiceSystemPrompt() async` and just `await
BrowserURLCapture.capture(...)`. Removes the box + semaphore + leaked task
entirely.

### C2. `UrlBox` write races the main-thread read on timeout
`UrlBox` is `@unchecked Sendable` with a plain `var value: String?`.
Sequence when semaphore times out:
1. Main reads `box.value` at line 17485 (no signal → no happens-before with any write).
2. Task later executes `box.value = info?.url` (line 17481).

Under strict Swift concurrency, `box.value` has NO synchronisation with the read;
this is a data race on an optional String (retain + tag + pointer store are not
one atomic op). TSan will fire. In practice mostly benign because after the
timeout the read has already returned, but any future refactor that re-reads
`box.value` (e.g. retry path, logging) will hit torn state.

Fix (if C1 not adopted): use `OSAllocatedUnfairLock`-guarded value, or better
still `CheckedContinuation` with a timeout wrapper. Do not lie with
`@unchecked Sendable`.

### C3. `pending = links` in `LinkRectStash.set` silently drops prior batch
`LinkRectStash.set` REPLACES. `PickStash.set` ACCUMULATES. Two Alt+L drags
without a Shift+Space between them drop the first drag's harvest with zero user
feedback — no log line here, no notification about the lost payload. Given
`PickStash` was explicitly redesigned to accumulate, this is an inconsistent
mental model and a real data-loss path.

Repro: Alt+L over link block A (5 links) → wait 2 s → Alt+L over link block B
(3 links) → Shift+Space → envelope carries 3 links, not 8.

Fix: append + dedup by lowercase url (same policy as `filterCapAndDedupLinks`),
cap 200. OR log a `linkrect_batch_replaced` event with the dropped count so at
least the loss is observable.

## HIGH

### H1. TTL expiry leaves stale annotation badges on-screen
`peekAll()` filters by TTL, so classifier stops seeing expired pins. But
`OpenClickyAnnotationBadgeOverlay.rebuild()` only runs on
`pickStashDidChange` / `annotationStashDidChange` /
`openClickyWhiteboardStashCleared` / `openClickyManualCaptureCompleted`. TTL
expiry is time-based; nothing fires a notification when a pin ages out. The
badge / outline panels for the expired pin persist until an unrelated event
happens.

Repro: Alt+S → wait 5 min 1 s → badge still hovering over now-stale bounds.

Fix: schedule a `DispatchQueue.main.asyncAfter(deadline: earliest TTL)` timer
on set, whose fire triggers `rebuild()`. Or add a `NotificationCenter` fire in
a background timer inside `PickStash`.

### H2. Alt+S twice on same element accumulates duplicate `PickStash` entries but overlay silently dedupes
`AnnotationBadgeOverlayClassifier.pinAnchorID` is deterministic on
`pid:role:title:bounds`. Two identical Alt+S presses append two `Entry`s in
PickStash. `readPick` returns them both in `elements[]` (identical dicts). The
overlay dedupes (dict key collision at `pairs[anchor.id]`) so user sees one
badge but their agent sees the SAME element listed twice.

Design intent unclear — the task prompt flags this. Either dedupe at `set()`
time (drop if last entry's anchor id matches), or keep the duplicate at the
stash but dedupe in `OpenClickyStashTools.readPick` before building
`elementsList`. The current split (accumulate at stash, dedupe at overlay,
duplicate at MCP) is the worst of both worlds.

### H3. `readPick` drains even in `mode="auto"` — every call consumes
`stash.takeAll()` unconditionally drains. Everywhere's `ReadPickTool` also
takes (comment at PickStash.swift:5-7 says "consumes the slot"), so this
matches wire semantics — BUT Swift's new `elements[]` field is not in
Everywhere. If any external tool calls `read_pick` twice back-to-back with the
assumption "auto = peek, full = consume" (which the docstrings at :47-53
suggest), the multi-pin set is lost on the first call.

Verify against `ReadPickTool.cs:22-101` byte-parity — I don't have it in-tree
to check. If Everywhere peeks on `auto`, this is a divergence.

### H4. `readPick` returns `ReadPickResult` with `elements: nil` when unpinned, encoded as JSON `null`
Synthesised Swift `Codable` on optional emits `"elements": null` on the wire.
Everywhere `System.Text.Json` typically ships with `WhenWritingNull = Ignore`
so the field is absent. MCP consumers that check `"elements" in obj` (rather
than value truthiness) will get a false positive. Add a custom `encode(to:)`
that uses `encodeIfPresent` for every optional, or set an encoder-level
`.omitNullValues` policy at the boundary.

## MEDIUM

### M1. `LinkRectStash.take()` doesn't fire `didChange`
`take()` clears `pending` + `updatedAt` silently. `clearWithEvent()` fires. If
a future consumer starts calling `take()` (currently no callers do), observers
miss the transition. Either drop `take()` (not used) or make it fire the
event for consistency with `PickStash.take()`.

### M2. `PickStash.set` `prevCount` logging misleads
Line 98 reads `prevCount = entries.count` BEFORE `entries.append(...)`. That's
actually correct (pre-append). But the field is later logged alongside
`new_count` (post-cap). Recommend renaming to `pre_append_count` and adding
`post_cap_count` to make the truncation observable in logs.

### M3. Auto-capture path never drains LinkRectStash — same links re-shipped forever until Shift+Space
`captureAutoPin()` → `drainAnnotations: false` → the `linkRectLinks != nil`
drain at line 319 is gated on `drainAnnotations`. So Alt+L, Alt+S, Alt+S,
Alt+S produces 3 envelopes that all carry the same picked_links. Since the
agent watches the envelope file, it may issue the same "here are your links"
message three times.

Intent may be correct (Alt+L survives until user commits with Shift+Space) but
should be explicitly documented and possibly dedup'd inside the envelope
formatter via mtime.

### M4. Voice-prompt reads `ClipboardCapture.capture()` synchronously — double-Cmd-C hazard
If any downstream call path polls Cmd+C on `ClipboardCapture` (old-macOS
branch), reading clipboard during a voice-hotkey press could clobber a
selection the user was about to paste. Check that `ClipboardCapture.capture()`
here is pasteboard-read-only, not Cmd+C-poll.

## LOW

- `LinkRectStash.peek()` returns `nil` if stale — but `updatedAt` isn't
  cleared, so next `set()` still overwrites correctly. Fine but confusing.
- `readPick` mode `"auto"` collapses to `"full"` (line 253). Everywhere's
  auto-branch counts hyperlinks; Swift always emits full. Documented, low risk.
- Multi-pin ordering: `takeAll` returns `oldest → newest`; `element = all.last`
  is newest. `elements[]` is oldest→newest. Consumers expecting "elements[0]
  is the latest" will be wrong. Doc explicitly.

Word count: ~780.
