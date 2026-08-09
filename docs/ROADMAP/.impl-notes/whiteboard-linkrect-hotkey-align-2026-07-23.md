# Whiteboard + LinkRect hotkey semantic alignment to Everywhere @30e03e9d

Date: 2026-07-23
Scope constraint from brief: only three files may be touched —
`cursor-buddy/OpenClickyContextHotkeys.swift`,
`cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`,
`cursor-buddy/OpenClickyLinkRectOverlayWindow.swift`.
Coordinator's expanded-scope messages (whiteboard 69KB byte-exact port,
OCR band-widening, PickStash single-slot, annotation UX) are out of
scope per the brief's explicit constraints section and are listed as
follow-ups at the bottom of this note.

## Everywhere source excerpts (canonical)

### Whiteboard: toggle semantics (NOT snapshot-driven, NOT press-hold)

`/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`
lines 137-172:

```csharp
private void OnHotkey()
{
    _logger.LogInformation("Whiteboard hotkey fired");
    Dispatcher.UIThread.Post(async () =>
    {
        try
        {
            if (_activeOverlay is not null)
            {
                _logger.LogInformation("Whiteboard re-press: committing active overlay");
                _activeOverlay.Commit();
                return;
            }
            if (Interlocked.CompareExchange(ref _opening, 1, 0) != 0)
            {
                _logger.LogInformation("Whiteboard hotkey ignored: overlay opening");
                return;
            }
            try   { await OpenOverlayAsync(); }
            finally { Interlocked.Exchange(ref _opening, 0); }
        }
        catch (Exception ex) { _logger.LogError(ex, "Whiteboard hotkey handler failed"); }
    });
}
```

Key facts confirmed by reading the source line-by-line:
- `_activeOverlay is not null` → `_activeOverlay.Commit()`. Second press
  commits.
- No `keyUp` handler exists in the file.
- Escape is handled inside the overlay itself (`WhiteboardOverlay.cs:314-318`
  `case Key.Escape: CompleteIfPending(canceled: true); Close;`).
- Overlay stays open across mouse strokes; strokes accumulate in
  `_strokes` (Everywhere `WhiteboardOverlay.cs`).
- `_activeOverlay.Commit()` (line 341-382) is the ONLY caller of Commit
  besides the overlay's own `Key.Enter`/`Key.Tab` bindings. There is NO
  cross-reference from SnapshotContextHotkeyInitializer to Whiteboard.
  Hypothesis (b) from the coordinator's mid-flight message ("Shift+Space
  triggers Whiteboard commit") is FALSE per the source.

`SnapshotContextHotkeyInitializer.cs` (all 161 lines) confirms:
`OnSnapshotPressed` only calls `_writer.CaptureAsync()`. No Whiteboard
reference anywhere in the file.

### LinkRect: single-fire (harvest inside picker → mouseUp commits)

`/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/LinkRectHotkeyInitializer.cs`
lines 111-177:

```csharp
private void OnHotkey()
{
    _logger.LogInformation("LinkRect hotkey fired");
    Dispatcher.UIThread.Post(async () =>
    {
        if (Interlocked.CompareExchange(ref _opening, 1, 0) != 0) return;
        try
        {
            var result = await _visualContext.HarvestLinksAsync(CancellationToken.None);
            var links = result.Links ?? Array.Empty<HarvestedLink>();
            if (result.Canceled) return;
            if (links.Count == 0) { _contextWriter.ActivateAgent(); return; }
            var pairs = new List<(string Title, string Url)>(links.Count);
            foreach (var h in links) pairs.Add((h.Title, h.Url));
            await _contextWriter.CaptureLinksAsync(pairs);
        }
        finally { Interlocked.Exchange(ref _opening, 0); }
    });
}
```

Key facts:
- Single-shot. Alt+L opens picker; picker's mouseUp resolves and closes;
  harvest fires; `CaptureLinksAsync` writes stash + activates agent.
- No toggle. No `keyUp`. Escape/right-click inside the picker cancels.
- `CaptureLinksAsync(pairs)` (Everywhere `ContextStashWriter.cs:130-213`)
  is the DIRECT-SHIP path that activates the agent + fires launch phrase
  on success. This is NOT the same as `CaptureAsync(links)` which flows
  through `captureCoreAsync(drainAnnotations: false)` and skips agent
  activation.

## Hotkey-semantic match table

| Scenario              | Everywhere behaviour               | Openclicky before | Openclicky after (this change) |
| --------------------- | ---------------------------------- | ----------------- | ------------------------------ |
| Alt+D press #1        | open overlay, no stash             | open overlay      | open overlay (unchanged)       |
| Alt+D press #2 (active) | `_activeOverlay.Commit()`        | `end()` via local `isWhiteboardOverlayActive` flag; but the flag went stale after Escape-cancel because the overlay closed independently | reads `OpenClickyWhiteboardOverlayWindow.shared.isActive` live, so Escape-cancel is honoured before the next press |
| Alt+D + Esc           | `CompleteIfPending(canceled:true); Close` | `overlay.cancel()` via NSEvent monitor keyDown 53 | unchanged; still `overlay.cancel()` |
| Alt+D keyUp           | not observed (`OnHotkey` has no keyUp path) | tapped `.keyUp` on the CGEvent tap and called `enqueueWhiteboardKeyUp()` | `.keyUp` no longer monitored (`monitoredTypes = [.keyDown]`); the `enqueueWhiteboardKeyUp` helper was removed |
| Alt+L press           | open picker, wait for mouseUp      | open overlay      | unchanged                      |
| Alt+L drag            | picker paints selection rect       | `.needsDisplay = true` set but drag rect intermittently didn't repaint on macOS 26 | `displayIfNeeded()` forces sync redraw after each `updateEnd()`; added `linkrect_overlay.rect_updated` log per drag |
| Alt+L mouseUp         | `CaptureLinksAsync(pairs)` — DIRECT-SHIP path, activates agent + phrase | called the `captureLinks([OpenClickyPickedLink])` overload which routes through `captureCoreAsync(drainAnnotations: false)` — never fires launch phrase | now calls the `(title, url)` overload → `captureLinks(pairs)` = direct-ship, `activateAgentAndFirePhrase()` runs |
| Alt+L + Esc           | picker cancels                     | overlay cancels   | unchanged                      |

## Diff summary (Openclicky before → after)

### 1. `cursor-buddy/OpenClickyContextHotkeys.swift`

Before:
- Monitored `[.keyDown, .keyUp]` in the CGEvent tap
  (`monitoredTypes` at line 106).
- `handleGlobalEventTap` had two arms: keyDown → enqueue; keyUp → look
  up whiteboard action and call `enqueueWhiteboardKeyUp` even when the
  modifier bits had been dropped.
- `enqueueWhiteboardKeyUp` was a comment-only no-op body plus an orphan
  `}` line at 288 (broken parser state from the coordinator's prior
  edit).
- `performWhiteboardBegin` read/wrote a local `isWhiteboardOverlayActive`
  Bool. That flag went stale after Esc-cancel because the overlay
  window's own `cancel()` doesn't touch it.
- `harvestAndPersistLinkRect` called
  `OpenClickyContextStashWriter.shared.captureLinks(result.picks)` —
  the `[OpenClickyPickedLink]` overload, which routes through
  `captureCoreAsync(drainAnnotations: false)`. `activateAgentAndFirePhrase`
  only runs when `wrote && drainAnnotations`, so no launch phrase ever
  fired on the LinkRect path.

After:
- `monitoredTypes = [.keyDown]` (line 106). All actions fire on keyDown
  only; toggle semantics do not need keyUp.
- `handleGlobalEventTap` reduces to a single loop: for each binding
  matching the current keycode+flags, enqueue and swallow.
- `enqueueWhiteboardKeyUp` deleted along with its doc block. The
  orphan `}` at 288/289 is gone.
- `performWhiteboardBegin` now reads
  `OpenClickyWhiteboardOverlayWindow.shared.isActive` (newly promoted
  from `private` to `private(set)`) so Esc-cancel resets state
  transparently.
- `harvestAndPersistLinkRect` maps `[OpenClickyPickedLink]` →
  `[(title, url)]` and calls the `(title, url)` overload of
  `captureLinks` (Everywhere-parity `CaptureLinksAsync`,
  `ContextStashWriter.cs:130-213`). That overload calls
  `activateAgentAndFirePhrase()` on success.

### 2. `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift`

Before: `private var isActive: Bool = false` (line 289).

After: `private(set) var isActive: Bool = false` with an
Everywhere-cited doc comment. No behavioural change to the overlay
itself.

### 3. `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift`

Before:
- `reset(anchor:)` and `updateEnd(_:)` set `needsDisplay = true`.
- No per-drag log event to confirm the paint tick.

After:
- `reset(anchor:)` and `updateEnd(_:)` call `displayIfNeeded()` after
  `needsDisplay = true` — belt-and-braces sync redraw so the 2px green
  outline paints on borderless non-key windows on macOS 26.
- `handleMouseDragged` emits
  `openclicky.linkrect_overlay.rect_updated {w, h}` per event so the
  log tail confirms the draw path is ticking.

## Build result

`bash scripts/sign-and-install.sh` → `** BUILD SUCCEEDED **` (twice,
after each of the two edits above). Ran `swiftc -parse` over the three
touched files first; exit 0 both times.

## Expected log event ordering after this change

Whiteboard success (Alt+D → draw → Alt+D):

```
openclicky.contextAwareness.hotkey: whiteboard hotkey -> begin()
openclicky.whiteboard_overlay.begin              {panel_count}
openclicky.whiteboard_overlay.mouse_down         {screen_index, x, y}
openclicky.whiteboard_overlay.mouse_up           {stroke_point_count, stroke_count}
openclicky.contextAwareness.hotkey: whiteboard hotkey (already active) -> end() commit
openclicky.whiteboard_overlay.commit             {stroke_count, regions}
… (regions stashed, then)
openclicky.launch_phrase.fired                   (via captureAsync → activateAgentAndFirePhrase)
```

Whiteboard cancel (Alt+D → Esc):

```
openclicky.contextAwareness.hotkey: whiteboard hotkey -> begin()
openclicky.whiteboard_overlay.begin
openclicky.whiteboard_overlay.cancel             {reason: "escape"}
```

LinkRect success (Alt+L → drag → mouseUp):

```
openclicky.contextAwareness.hotkey: linkrect hotkey pressed
openclicky.linkrect_overlay.begin                {panel_count}
openclicky.linkrect_overlay.mouse_down           {cocoa_x, cocoa_y, quartz_x, quartz_y}
openclicky.linkrect_overlay.rect_updated         {w, h}  (per drag event)
… (many rect_updated)
openclicky.linkrect_overlay.mouse_up             {quartz_x, quartz_y, rect_w, rect_h}
openclicky.linkrect_overlay.commit               {rect_w, rect_h}
openclicky.contextAwareness.hotkey: linkrect drag=… — harvesting
openclicky.contextAwareness.hotkey: linkrect harvest picks=N candidates=M nodes=P
… (captureLinks pairs overload → filterCapAndDedup → writeAtomic)
openclicky.launch_phrase.fired                   (via activateAgentAndFirePhrase)
```

If `rect_updated` never appears in the log tail during a drag, the
`isDragging` guard in `handleMouseDragged` didn't flip — probably
means `handleMouseDown` didn't run, which points at the NSEvent global
monitor's Accessibility/Input Monitoring permission gate rather than
the draw path.

## Follow-up scope not included in this change (coordinator's expanded scope)

The coordinator's mid-task messages requested additional work outside
the three-file constraint. Documented here so it isn't lost:

1. Whiteboard 69KB byte-exact port. Everywhere's
   `WhiteboardHotkeyInitializer.cs` handles the OCR/snap pipeline, not
   the hotkey. Porting parity for underline OCR band-widening (60px L/R,
   50px above, 20px below — Everywhere lines 596-602), the per-region
   OCR crop scale-recovery (lines 1284-1357), the annotation snap +
   prewarm tree (lines 344-374), etc. lives in files like
   `OpenClickyWhiteboardStrokeClassifier.swift`, `OCRCapture.swift`,
   `ScreenshotCaptureEverywhere.swift`, and the `AnnotationSnapper`
   equivalent — none of which are in the three-file allowlist.
2. PickStash single-slot alignment
   (`Everywhere.Core/Interop/PickStash.cs` — single `_current` slot,
   Take-semantics, 5-minute TTL). Openclicky's
   `Packages/OpenClickyContextService/.../PickStash.swift` is outside
   the allowlist.
3. AnnotationBadge overlay UX alignment
   (`AnnotationOverlayHost.cs` + `AnnotationOverlayWindow.cs` @30e03e9d).
   Openclicky's `OpenClickyAnnotationBadgeOverlay.swift` is outside the
   allowlist.
4. Additional whiteboard accuracy debug logs
   (`stroke_captured`, `stroke_bbox_quartz`, `ocr_band`,
   `screenshot_captured`). These need edits inside
   `OpenClickyWhiteboardOverlayWindow.processAndStash` — technically
   file #3 in the allowlist, but each log call requires new intermediate
   variables that expose stroke → bbox → OCR-rect conversions currently
   hidden inside the classifier + `ScreenshotCaptureEverywhere.captureRegion`.
   That plumbing needs the classifier/capture files, which are not in
   the allowlist. A minimal `commit` event carries `stroke_count` +
   `regions` today; the deeper per-stroke instrumentation is a
   follow-up task in its own right.

Recommend a new brief that widens the file allowlist to cover the
classifier/OCR/PickStash/AnnotationBadge files if the coordinator wants
these landed.
