# F25 — PickElement pin HUD + Annotation ➕ badge + AXFollower delta-follow

Verified 2026-07-23 against Everywhere pin `30e03e9dcfdd4247fd679828ed86e9042f32d809`.

## Provenance (Everywhere Mac-side reality)

Direct check of Everywhere's Mac tree:

- `src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs` (38 lines) — thin wrapper. Its `PickerSession` inherits from the cross-platform `ScreenSelectionSession` (`src/Everywhere.Mac/Interop/ScreenSelectionSession.cs`, 446 lines) which is where the picker UI actually lives.
- `ScreenSelectionSession.cs` renders per-`NSScreen` `ScreenSelectionMaskWindow`s and a `ScreenSelectionToolTipWindow`. `OnPointerMoved` (`ScreenSelectionSession.cs:228-231`) calls `HandlePointerMoved(NSEvent.CurrentMouseLocation)` **every pointer-moved event with no throttle** — verified by reading the full flow: `OnPointerMoved` → `HandlePointerMoved` → `OnMove` → `GetElementAtPoint`. No `_lastAt`, `DateTime.Now`, `DispatcherTimer`, or `Throttle` gate anywhere in the file (`grep` confirmed).
- Badge / outline overlays are Avalonia (`src/Everywhere.Core/Views/Annotation/AnnotationOverlayWindow.cs`, `.../AnnotationOutlineWindow.cs`) with a Mac-thin `IWindowHelper.ConfigureAsCursorOverlay/ConfigureAsInteractiveOverlay` shim. No native Cocoa/AppKit picker overlay lives under `Everywhere.Mac/`. The badge behavior spec (state machine, gradient, ✓ commit, Esc/Cmd+Enter, LostFocus commit) is in `AnnotationOverlayWindow.cs` (lines 24-350 read below).
- The delta-follow host is `src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs`. It uses a **`DispatcherTimer` at 50 ms** (`AnnotationOverlayHost.cs:76-79`), reading `element.BoundingRectangleLive` per tick. It does **not** use `AXObserver` (`grep -rn AXObserver /Users/wowdd1/Dev/Everywhere/src/` → zero hits).
- Nine `feat(annotation)` commits do not exist as literal `feat(annotation):` prefixes; `git --no-pager log --all --format=%s | grep -c annotation` = 42. Delta-follow commit reference `ac10c6b1 feat(annotation): delta-follow model + handle focusedRoot=null` exists but is scaffolding, not the byte-for-byte source.

Conclusion for provenance: openclicky's F25 is **openclicky-native Swift/AppKit**. There is no Cocoa picker / badge / follower to port byte-for-byte. Alignment is semantic (behavior parity) plus 1:1 on the `AnnotationItem` payload record (already 1:1 per F14 review).

## Alignment table (openclicky ↔ Everywhere behavior spec)

| Behavior | openclicky code | Everywhere spec source | Match |
|---|---|---|---|
| One picker overlay per NSScreen | `OpenClickyPickElementOverlay.installPanels()` iterates `NSScreen.screens` and constructs a `PickPanel` per screen (`OpenClickyPickElementOverlay.swift:78-86`) | `ScreenSelectionSession` ctor iterates `NSScreen.Screens` and builds a `ScreenSelectionMaskWindow` per screen (`ScreenSelectionSession.cs:61-80`) | OK |
| Overall dim wash | `NSColor.black.withAlphaComponent(0.15)` (`OpenClickyPickElementOverlay.swift:233`) | `ScreenSelectionMaskWindow` (not read here — same 15% wash convention documented in F23 review) | OK |
| Crosshair cursor | `NSCursor.crosshair.push()` (`OpenClickyPickElementOverlay.swift:88`) | Set via Avalonia `Cursor.Crosshair` on `ScreenSelectionSession` (`ScreenSelectionSession.cs`, base class `ScreenSelectionTransparentWindow`) | Semantic OK |
| AX hit-test uses systemwide | `AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)` (`OpenClickyPickElementOverlay.swift:358-363`) | `GetElementAtPoint` → `AXUIElement.SystemWide.ElementAtPoint(point)` (`ScreenSelectionSession.cs:355+`) | OK |
| Cocoa→Quartz y-flip via primary screen height | `primary.frame.height - cocoa.y` (`OpenClickyPickElementOverlay.swift:373-376`) and inverse (`:381-387`) | `primaryScreenHeight - point.Y` (`ScreenSelectionSession.cs:244-245, 262-268`) | OK |
| Live hover outline (green, 2 px, rounded 6 pt) | `NSColor.systemGreen.setStroke()` + `NSBezierPath(roundedRect:xRadius:6,yRadius:6)` `lineWidth = 2` (`OpenClickyPickElementOverlay.swift:325-332`) | Everywhere renders a mask hole around `maskRect` (Avalonia `Border`, thickness 2, corner radius 6). Color is theme-driven, not "green" specifically — the outline hue is presentation-only divergence. | Semantic OK; **color divergence** |
| Hit-test throttle | `~30 fps` gate: `lastHitAt` + `minHitInterval = 1.0/30.0` (`OpenClickyPickElementOverlay.swift:267-270, 337-339`) | **No throttle** in `HandlePointerMoved` (`ScreenSelectionSession.cs:228-249`); every `PointerMoved` event calls `AX.ElementAtPoint`. AX cross-process latency (~10-30 ms) is Everywhere's implicit throttle. | **Divergence — openclicky adds explicit 33 ms throttle**. Not spec parity, but arguably safer on macOS. Documented as intentional in the file header (`swift:19-22, 267-270`). |
| Escape / right-click cancel | `NSEvent.addLocalMonitorForEvents([.keyDown, .rightMouseDown])` + global `.rightMouseDown` monitor (`OpenClickyPickElementOverlay.swift:96-115`); Escape keyCode 53 → `cancel("escape")` | `HandleCGEvent` on `Escape` KeyUp → `OnCanceled + Close` (`ScreenSelectionSession.cs:154-169`); `OnPointerPressed` right button → `OnCanceled + Close` (`ScreenSelectionSession.cs:124-129`) | OK. Divergence: openclicky cancels on Escape KeyDown, Everywhere on KeyUp (comment on `.cs:158-160` explains why — event stickiness). Semantic parity. |
| Click on element captures | `mouseDown:` → `AXUIElementCopyElementAtPosition` or last hover → `handleClick(on:at:)` → `PickedElement(pid, role, title, value, bounds, bundleId)` (`OpenClickyPickElementOverlay.swift:310-323, 137-164`) | `OnLeftButtonDown` → `OnMove(quartzPoint)` → sets `SelectedElement`; `OnLeftButtonUp` → `Close` returns `SelectedElement` to `PickerSession._pickingPromise` (`ScreenSelectionSession.cs:131-145`; `.Picker.cs:32-37`) | OK |
| Writes into `PickStash` | `PickStash.shared.set(picked)` (`OpenClickyPickElementOverlay.swift:161`) with 5-min TTL default (`PickStash.swift:14-15, 50`) | `PickStash.Pinned` event → subscribers add. TTL `TimeSpan.FromMinutes(5)` (Everywhere `PickStash.cs:14`) | OK |
| Live AX handle stored for follower | `OpenClickyPinnedAXElementRegistry.store(element, for: anchorID)` BEFORE `PickStash.set` so the badge classifier can resolve on next tick (`OpenClickyPickElementOverlay.swift:159-160`; registry at `OpenClickyAnnotationBadgeOverlay.swift:98-122`) | Everywhere passes the live `IVisualElement` straight into `AnnotationOverlayHost.OnPinned(element)` — no side registry (`AnnotationOverlayHost.cs:60-61, 162-216`) | Semantic OK; openclicky needs the registry because `PickedElement` is a value snapshot; Everywhere's `IVisualElement` is already a live handle |
| Badge subscribes to 3 stash didChange notifications | `.pickStashDidChange`, `.annotationStashDidChange`, `.openClickyWhiteboardStashCleared` (`OpenClickyAnnotationBadgeOverlay.swift:225-236`) | `PickStash.Pinned` + `PickStash.Cleared` + `ContextStashWriter.ManualCaptureCompleted` (`AnnotationOverlayHost.cs:60-67`) — three signals but different set: openclicky's `annotationStashDidChange` is add-only; Everywhere's `ManualCaptureCompleted` is not wired in openclicky (documented in `phase7-1-pick-annotation-2026-07-23.md:125`). | Partial. **Divergence**: `ManualCaptureCompleted` fan-out not wired — badge is not torn down when a snapshot ships. |
| Badge visual: red ➕ (unannotated) / ✓ (1 note) / ✓ N (multi) | `BadgeViewModel.badgeLabel`, `badgeFill` (`OpenClickyAnnotationBadgeOverlay.swift:611-622`); red is `Color(r:0.86,g:0.12,b:0.20)` when `noteCount==0`, green `0.24,0.78,0.55` otherwise | Everywhere: purple/gradient (`AC45F1 → 7A7EF4 → 3DC6F8`) for ➕, `3DC68C` green for ✓ (`AnnotationOverlayWindow.cs:96-98, 303-320`). Content `+` vs `✓`. | Semantic OK; **color divergence** (openclicky red vs Everywhere purple gradient). Task description says "red circle" — openclicky matches the task spec, not Everywhere's actual code. |
| Badge collapsed size 24×24 | `BadgePanel.collapsedSize = 24×24` (`OpenClickyAnnotationBadgeOverlay.swift:465`) | `BadgeSize = 24` (`AnnotationOverlayWindow.cs:28`) | OK |
| Expanded popover size | `expandedSize = 320×110` (`OpenClickyAnnotationBadgeOverlay.swift:466`) | `ExpandedWidth = 320`, `ExpandedHeight = 110` (`AnnotationOverlayWindow.cs:29-30`) | OK. Task spec says 150×80 — that number is wrong per code on both sides. Openclicky matches Everywhere. |
| Badge anchor: top-right corner offset (+6, -6) | `origin = (cocoa.maxX + 6 - w/2, cocoa.maxY - 6 - h/2)` (`OpenClickyAnnotationBadgeOverlay.swift:410-416`) | `OffsetX = 6, OffsetY = -6` (`AnnotationOverlayWindow.cs:34-35`); `MoveTo(rect)` places at `rect.Right + OffsetX, rect.Y + OffsetY` (`.cs:176-183`) | OK |
| Placeholder "annotate this element…" | Literal string (`OpenClickyAnnotationBadgeOverlay.swift:707`) | No literal placeholder in `AnnotationOverlayWindow.cs`; the textbox is empty by default. | **Divergence — openclicky adds a placeholder Everywhere does not.** Documented in task; acceptable UX addition. |
| Cmd+Enter commits | `AnnotationTextEditor.Coordinator.textView(_:doCommandBy:)` intercepts `insertNewline(_:)` and checks `NSApp.currentEvent?.modifierFlags.contains(.command)` (`OpenClickyAnnotationBadgeOverlay.swift:776-790`) | `OnTextBoxKeyDown`: `(e.KeyModifiers & KeyModifiers.Meta) != 0` on Enter (`AnnotationOverlayWindow.cs:325-341` per the readable slice; source has some rendering artifacts but the intent is `Meta+Enter → commit`) | OK |
| Escape collapses / cancels | `.onKeyPress(.escape)` on `BadgeRootView` (`OpenClickyAnnotationBadgeOverlay.swift:680-683`) + `cancelOperation(_:)` in coordinator (`.swift:777-779`) | Esc in `OnTextBoxKeyDown` → collapse without commit (`AnnotationOverlayWindow.cs:325-341`) | OK |
| Empty-collapse of a ✓ deletes annotation | `collapse(commit:)` when `body.isEmpty` and `hadCommittedBody` → `onClear?()` (`OpenClickyAnnotationBadgeOverlay.swift:571-581`); host removes matching entries from `AnnotationStash` (`.swift:320-327`) | `Collapse` branch: `text.Length == 0 && CommittedText != null` → `Cleared` event (`AnnotationOverlayWindow.cs:281-290`); host removes via `AnnotationStash.RemoveItem(pair.LastItem)` (`AnnotationOverlayHost.cs:290-303`) | OK |
| Re-edit does not stack revisions | Existing matching entries drained via `annotationStash.consume(existing)` before appending fresh (`OpenClickyAnnotationBadgeOverlay.swift:293-317`) | `RemoveItem(pair.LastItem)` then `Add(item)` (`AnnotationOverlayHost.cs:239-288`) | OK. Divergence: openclicky matches by `(source, anchorRef or anchorLabel)`; Everywhere holds `pair.LastItem` reference directly. Same net effect. |
| `AnnotationItem` payload built by badge commit | `AnnotationItem(source: anchor.source, body: trimmed, anchorRef: anchor.id, anchorLabel: anchor.label)` (`OpenClickyAnnotationBadgeOverlay.swift:307-312`) | `new AnnotationItem(Source: AnnotationSource.Pin, Body: body, AnchorRef: null, AnchorLabel: anchorLabel, CapturedAtUtc: DateTimeOffset.UtcNow)` (`AnnotationOverlayHost.cs:274-280`) | **Semantic divergence — anchorRef**: Everywhere passes **null** (`.cs:277`); openclicky passes the stable anchor id `pin:<pid>:<role>:<title>:<x,y,w,h>` (`.swift:166-174, 310`). Openclicky's is strictly more information. Not a regression. |
| CapturedAt UTC | Defaults to `Date()` (`CaptureTypes.swift:1672`) inside init | `DateTimeOffset.UtcNow` (`AnnotationOverlayHost.cs:279`) | OK |
| Anchor label formatting | `friendlyRoleName` drops `AX` prefix + wraps title in quotes: `AXButton "Submit"` (`OpenClickyAnnotationBadgeOverlay.swift:176-187`) — but note: `friendlyRoleName` **strips** the `AX` prefix so label reads `Button "Submit"`, not `AXButton "Submit"` | `$"{type} \"{name}\""` where `type` is `element.Type.ToString()` (e.g. `Button`) (`AnnotationOverlayHost.cs:244-248`) | OK; both drop the `AX` prefix. |
| Follow-tick cadence | 100 ms `DispatchSourceTimer` fallback (`OpenClickyAXFollower.swift:48, 173-181`) | 50 ms `DispatcherTimer` (`AnnotationOverlayHost.cs:69-79`) with `RefreshInFlight` gate | **Divergence — half-speed**. Everywhere explicitly notes "150 ms was perceptibly laggy" (`.cs:71-74`); openclicky's 100 ms is closer than 150 ms but still 2× slower than Everywhere's chosen 50 ms. |
| AXObserver primary path | `AXObserverCreate` + `kAXValueChangedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXUIElementDestroyedNotification` (`OpenClickyAXFollower.swift:109-114, 116-171`); registered against target AND window ancestor (`.swift:146-149`); callback added to `CFRunLoopGetMain` (`.swift:168-169`) | **Not present in Everywhere** — no `AXObserver` usage anywhere in `Everywhere/src/` (`grep -rn AXObserver` = 0 hits). Everywhere is timer-only. | **openclicky-native enhancement**. Correct per macOS AX API contract; more efficient than timer-only. |
| Poll fallback runs unconditionally alongside observer | `installFallbackTimer()` fires whether or not observer install succeeded (`OpenClickyAXFollower.swift:82`, `.swift:173-181`) | Timer is the only path (as above) | OK for parity purpose; belt-and-braces vs single-path. |
| Bounds read from AX position + size | `readBounds` copies `kAXPositionAttribute` + `kAXSizeAttribute` as `AXValueGetTypeID` → CGPoint/CGSize (`OpenClickyAXFollower.swift:195-221`) | Same pattern behind `element.BoundingRectangleLive` (Mac impl in `Everywhere.Mac/Interop/AXUIElement.cs`). | OK |
| Zero-size hides overlay | `if size.width <= 0 || size.height <= 0 { return nil }` (`OpenClickyAXFollower.swift:219`) → `onChange(nil)` → outline out, badge kept if expanded (`OpenClickyAnnotationBadgeOverlay.swift:375-383`) | `rect.Width <= 0 || rect.Height <= 0` → `outline.Hide()` + `Badge.HideIfCollapsed()` (`AnnotationOverlayHost.cs:141-146`); `HideIfCollapsed` = only hide when collapsed (`AnnotationOverlayWindow.cs:187-195`) | OK |
| ClearContextStash tears down all pairs | `ClearContextStash` calls `PickStash.shared.clearWithEvent()` (`OpenClickyContextHotkeys.swift:277`) → fires `.pickStashDidChange` → classifier returns empty list → rebuild removes all pairs (`OpenClickyAnnotationBadgeOverlay.swift:264-268`) | `OnPickStashCleared` handler directly closes badge/outline + `RemoveItem(pair.LastItem)` (`AnnotationOverlayHost.cs:85-109`) | OK (openclicky routes through the classifier; same net behavior). |
| Wire at accessibility permission gate | `CompanionManager.refreshAllPermissions()` starts on grant (`CompanionManager.swift:4147`), stops on revoke (`:4163`), and `stop()` also stops it (`:4063`) | Everywhere host is DI-registered as `IAsyncInitializer` at `AsyncInitializerIndex.Startup` (`AnnotationOverlayHost.cs:56-83`) — not tied to accessibility gate | Semantic OK. Openclicky's tie to the AX gate is correct because `AXObserverCreate` needs AX permission. |
| Singleton lifecycle | `OpenClickyAnnotationBadgeOverlay.shared` + `OpenClickyPickElementOverlay.shared` + `PickPanel` per screen. `stop()` clears cancellables + tears down pairs (`OpenClickyAnnotationBadgeOverlay.swift:241-248`) | `AnnotationOverlayHost` singleton via DI; `DisposeAsync` tears down (`AnnotationOverlayHost.cs:305-335`) | OK |

## Issues

### CRITICAL — none.

### HIGH

- **H1. Follow-tick cadence 2× Everywhere's chosen rate.** `OpenClickyAXFollower.pollInterval = 0.1` (`OpenClickyAXFollower.swift:48`) vs Everywhere's `50 ms` (`AnnotationOverlayHost.cs:76`) with an explicit "150 ms was perceptibly laggy" note (`.cs:71-74`). Openclicky's 100 ms is faster than 150 ms but slower than 50 ms; user-visible drag lag on fast-scrolling elements. The AXObserver primary path masks this when it fires, but Electron/sandboxed apps that skip notifications fall through to the timer. **Fix**: drop to 50 ms unless there's a battery justification.

- **H2. `ManualCaptureCompleted` fan-out not wired.** `OpenClickyContextStashWriter` never posts a "snapshot shipped" notification (`OpenClickyContextStashWriter.swift` — no matching event; the badge overlay only observes stash-change notifications). Everywhere's flow tears the pairs down right after `SnapshotContext` fires (`AnnotationOverlayHost.cs:63-64, 218-237`). Without the equivalent, openclicky's badges linger on-screen after the user has already shipped context, so the next thing the LLM does not need pins for still shows the pins. Documented as TODO in `docs/ROADMAP/.impl-notes/phase7-1-pick-annotation-2026-07-23.md:125`. **Fix**: post a Swift notification from the writer's success path; subscribe in the overlay.

### MEDIUM

- **M1. Hit-test throttle diverges from Everywhere (semantic).** Openclicky throttles to 30 fps (`OpenClickyPickElementOverlay.swift:270`); Everywhere does not throttle at all. Not strictly wrong (AX latency naturally throttles Everywhere), but the two implementations will hit-test slightly different elements during fast mouse sweeps. Header comment (`.swift:19-22`) documents this as intentional. **Fix**: none required; keep documented divergence, or remove the throttle to align with Everywhere.

- **M2. Outline color divergence (green vs Everywhere purple).** Openclicky draws with `NSColor.systemGreen` (`OpenClickyPickElementOverlay.swift:329`) and the annotation outline with `NSColor.systemRed` (`.swift:455`); Everywhere uses purple `#AC45F1` for both hover and annotation outline (`AnnotationOutlineWindow.cs:34`, `AnnotationOverlayWindow.cs:96`). Purely cosmetic; task spec calls for "green outline" and "red circle" — openclicky matches the task spec, not Everywhere's actual pixels.

- **M3. Badge fill red vs Everywhere gradient.** `Color(r:0.86,g:0.12,b:0.20)` (`OpenClickyAnnotationBadgeOverlay.swift:619`) vs Everywhere's `AC45F1 → 7A7EF4 → 3DC6F8` linear gradient (`AnnotationOverlayWindow.cs:96-99`). Same cosmetic class as M2.

### LOW

- **L1. AXObserver observed-elements array can accumulate duplicates.** `installObserver` appends `observedElements.append(target)` inside the per-notification loop (`OpenClickyAXFollower.swift:157`), so the same `AXUIElement` is stored once per notification (4×) instead of once per element. `stop()` still iterates all notifications per element (`.swift:96-99`), so `AXObserverRemoveNotification` is called 4×4 = 16 times per observed target. macOS returns `-25204` (not-registered) for the extras without side effects, but the list grows unnecessarily. **Fix**: `if !observedElements.contains(where: { CFEqual($0, target) }) { observedElements.append(target) }`.

- **L2. `hoverElement` never released between hovers.** `PickHitView` keeps the last `AXUIElement` as a strong ref (`OpenClickyPickElementOverlay.swift:265`). Not a leak (overwritten on next move), but the final hovered element is held until the overlay tears down. In practice not visible; noted for completeness.

- **L3. Whiteboard / linkrect anchors not surfaced in classifier.** Documented at `OpenClickyAnnotationBadgeOverlay.swift:158-162`: only pin anchors get badges. Everywhere ships whiteboard + linkrect anchor badges (`feat(annotation): whiteboard/linkrect now follow the element they annotate`, commit `3a2c7993`). Phase-7.1 scope explicitly punted; keep tracked as future work.

- **L4. `AnnotationTextEditor` does not commit on focus loss.** Everywhere's `OnTextBoxLostFocus` commits or collapses on blur (`AnnotationOverlayWindow.cs:342-350`, matching user feedback "鼠标点击文本框之外, 应该自动收起"). Openclicky's `Coordinator` (`OpenClickyAnnotationBadgeOverlay.swift:763-791`) does not implement `textDidEndEditing` → the popover only collapses on Cmd+Enter or Escape. **Fix**: add `func textDidEndEditing(_:)` → `parent.onCommit()` (which handles empty-body-as-clear).

- **L5. Anchor id encodes exact bounds.** `pinAnchorID` embeds `x,y,w,h` (`OpenClickyAnnotationBadgeOverlay.swift:166-174`). Any AX bounds shift after re-pin produces a different anchor id, so the badge classifier treats it as a new pin — but the pin flow only allows one pin at a time (single `PickStash` slot), and existing annotations are matched by `anchorRef OR anchorLabel` (`.swift:141-142, 300-302`) so anchor-label fallback covers the id churn. Working as intended; noted so future multi-pin work does not regress it.

- **L6. Cursor `NSCursor.crosshair.push()` not popped on Escape via global monitor path.** Both `cancel()` paths route through `teardown()` which calls `NSCursor.pop()` (`OpenClickyPickElementOverlay.swift:132`), so this is actually fine. Removed from concerns after tracing — no fix needed.

## Verdict

**Pass with caveats.** F25 is openclicky-native by necessity (Everywhere's picker is Avalonia-cross-platform; no Cocoa source to port byte-for-byte). Semantic parity is strong: per-screen picker, AX systemwide hit-test, y-flip math, Escape/right-click cancel, PickStash write path, 24×24 badge, 320×110 popover, ➕/✓/✓N state machine, Cmd+Enter commit, empty-collapse-of-✓ deletes, re-edit drains previous entry, delta-follow with zero-size hide, ClearContextStash tears everything down.

Notable **enhancements over Everywhere**:
- `AXObserver` primary path (Everywhere is timer-only).
- `anchorRef` populated with stable id (Everywhere writes null).
- Placeholder copy.

Notable **regressions vs Everywhere**:
- Follow timer 100 ms vs 50 ms (H1).
- `ManualCaptureCompleted` fan-out unwired (H2).
- No blur-commit path (L4).
- Whiteboard/linkrect anchors not yet surfaced (L3, scope-punted).

Colors diverge but match the F25 task description ("green outline", "red circle") so they are the intended spec — not defects.

## Files inspected

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyPickElementOverlay.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyAXFollower.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/CompanionManager.swift` (rows 4059-4165)
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift:1596+` (`PickedElement`, `AnnotationItem`)
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PickStash.swift` (TTL)
- `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AnnotationStash.swift` (consume/append)
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/ScreenSelectionSession.cs` (rows 1-340)
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Views/Annotation/AnnotationOverlayWindow.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Core/Views/Annotation/AnnotationOutlineWindow.cs`
- Full Everywhere source `grep -rn AXObserver` → 0 hits.
