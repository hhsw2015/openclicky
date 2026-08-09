# F24 — LinkRect Harvest UX

Pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Standards: code-only, every claim carries file:line.

## Scope

Compare openclicky's LinkRect press-drag overlay + AX harvester + stash
writer against Everywhere's `VisualElementContext.LinkRect.HarvestLinks`
+ `ScreenSelectionSession` + `ContextStashWriter.CaptureLinksAsync`.

Files under review:

- Openclicky
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` (1-313)
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyLinkRectHarvester.swift` (1-370)
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextHotkeys.swift` (1-355)
  - `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextStashWriter.swift` (271-415)
  - `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickySanitiser.swift`
- Everywhere
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs`
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/ScreenSelectionSession.cs`
  - `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (`CaptureLinksAsync` @ line 130-213)

## Alignment Table — Overlay Behaviour

| Behaviour | Everywhere | Openclicky | Match |
|---|---|---|---|
| Trigger | `LinkRectHotkeyInitializer` -> `LinkRectSession.HarvestAsync` (`VisualElementContext.LinkRect.cs:28-72`) | `performLinkRectStub` -> `OpenClickyLinkRectOverlayWindow.present(...)` (`OpenClickyContextHotkeys.swift:305-324`) | Yes |
| Reentry guard | `_activeOverlay` field on hotkey initializer | `guard linkRectOverlay == nil` (`OpenClickyContextHotkeys.swift:308-311`) | Yes |
| Multi-screen coverage | Mask windows placed on every `NSScreen` (`ScreenSelectionSession.cs:61-80`) | One `NSWindow` per `NSScreen` (`OpenClickyLinkRectOverlayWindow.swift:62-66, 71-79`) | Yes |
| Tint colour | Dim mask via `ScreenSelectionMaskWindow` | `NSColor(white: 0.0, alpha: 0.15).cgColor` (`OpenClickyLinkRectOverlayWindow.swift:268`) | Yes (0.15 grey per spec) |
| Punch-through inside rect | Mask hides selection area | `ctx.setBlendMode(.clear); ctx.fill(localRect)` (`OpenClickyLinkRectOverlayWindow.swift:281-283`) | Yes |
| Selection outline | Mask border | `NSColor.systemGreen`, `setLineWidth(2)` (`OpenClickyLinkRectOverlayWindow.swift:286-288`) | Yes (2 px green per spec) |
| mouseDown -> begin | `OnLeftButtonDown` seeds `_dragStart` (`ScreenSelectionSession.cs:131-134` + LinkRect override `VisualElementContext.LinkRect.cs:123-131`) | `mouseDown(with:)` -> `reset(anchor: quartz); onBegin?` (`OpenClickyLinkRectOverlayWindow.swift:230-234`) | Yes |
| mouseDragged updates | `OnMove` rebuilds `_dragRect` (`VisualElementContext.LinkRect.cs:151-165`) | `mouseDragged(with:)` -> `updateEnd`; owner broadcast (`OpenClickyLinkRectOverlayWindow.swift:236-240, 89-93`) | Yes |
| mouseUp resolves | `OnLeftButtonUp` sets `_rectPromise` (`VisualElementContext.LinkRect.cs:133-149`) | `mouseUp(with:)` -> `onEnd?`; overlay dismisses immediately (`OpenClickyLinkRectOverlayWindow.swift:242-247, 95-113`) | Yes |
| Escape cancel | Esc keycode routed via `HandleCGEvent`, `OnCanceled()` (`ScreenSelectionSession.cs:147-169`) | Esc keycode 53 -> `onCancel?` (`OpenClickyLinkRectOverlayWindow.swift:253-260`) | Yes |
| Right-click cancel | `rightButton` -> `OnCanceled` (`ScreenSelectionSession.cs:124-128`) | `rightMouseDown(with:)` -> `onCancel?` (`OpenClickyLinkRectOverlayWindow.swift:249-251`) | Yes |
| Coordinate resolution | Quartz global (top-left) via `primaryScreenHeight - Cocoa.Y` (`ScreenSelectionSession.cs:244-245`; `VisualElementContext.LinkRect.cs:125-126`) | Same primary flip: `primaryHeight - global.y` (`OpenClickyLinkRectOverlayWindow.swift:297-302`) | Yes |
| Window level | `NSWindowLevel.ScreenSaver` (`ScreenSelectionSession.cs:100`) | `.screenSaver` (`OpenClickyLinkRectOverlayWindow.swift:155`) | Yes |
| Overlay retention | Session held via `LinkRectSession` instance | `strongSelf = self` until fire (`OpenClickyLinkRectOverlayWindow.swift:56, 49`, cleared on 113/122) | Yes |
| Post-drag highlight | Highlights captured link bboxes ~700 ms before close (`VisualElementContext.LinkRect.cs:58-72`) | Overlay dismissed at `ended` before harvest begins (`OpenClickyLinkRectOverlayWindow.swift:106`) | Divergent — see Issue 5 |
| Zero-drag treatment | `_dragRect.Width>0 && Height>0` -> promise; else null -> canceled (`VisualElementContext.LinkRect.cs:137-147`) | `finalRect.width > 0 && height > 0` -> `.rect`; else `.cancelled` (`OpenClickyLinkRectOverlayWindow.swift:107-111`) | Yes |

## Alignment Table — Harvester Logic

| Rule | Everywhere | Openclicky | Match |
|---|---|---|---|
| Pid enumeration source | `CGWindowListCopyWindowInfo(OnScreenOnly, 0)` (`VisualElementContext.LinkRect.cs:570-573`) | `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` (`OpenClickyLinkRectHarvester.swift:345-347`) | Semantic-equal; openclicky adds `excludeDesktopElements` |
| Filter to intersecting windows | Bounds-intersect drag rect (`VisualElementContext.LinkRect.cs:582-587`) | Same, tolerates missing bounds (`OpenClickyLinkRectHarvester.swift:353-363`) | Yes |
| Frontmost-only mode | No — enumerates every on-screen pid | Same — enumerates every intersecting on-screen pid (`OpenClickyLinkRectHarvester.swift:344, 348-365`) | Yes |
| MaxDepth | `MaxDepth = 60` (`VisualElementContext.LinkRect.cs:242`) | `maxDepth = 60` (`OpenClickyLinkRectHarvester.swift:44`) | Yes |
| Walk budget | `Remaining = 50_000` (`VisualElementContext.LinkRect.cs:224`) | `walkBudget = 50_000` (`OpenClickyLinkRectHarvester.swift:45`) | Yes |
| Zero-size descent | Descends into 0/0 nodes (comment L263-265) | `if let bounds, w>0,h>0, !intersectsLoose { return }`; nil / zero-size fall through (`OpenClickyLinkRectHarvester.swift:157-160`) | Yes |
| Intersect helper | `IntersectsLoose` half-open Right/Bottom (`VisualElementContext.LinkRect.cs:400-403`) | `intersectsLoose` uses `origin+size` half-open compares (`OpenClickyLinkRectHarvester.swift:54-63`) | Yes |
| Majority overlap | Horizontal-any-overlap + anchor mid-Y in drag rect Y span (`VisualElementContext.LinkRect.cs:411-422`) | Same (`OpenClickyLinkRectHarvester.swift:69-79`) | Yes |
| Icon-only drop | Untitled AND `Width <= 32 && Height <= 32` (`VisualElementContext.LinkRect.cs:370-372`) | `!hasTitle && smallW && smallH` where each ≤32 (`OpenClickyLinkRectHarvester.swift:195-197`) | Yes |
| Title fallback chain | Name -> AXDescription -> `GetText(200)` -> ancestor row text (`VisualElementContext.LinkRect.cs:349-357`) | `axTitle` -> `axDescription` -> `axValueText`; **no ancestor-row fallback** (`OpenClickyLinkRectHarvester.swift:186-188`) | Divergent — see Issue 3 |
| Scheme allow-list | `http|https|mailto` (`VisualElementContext.LinkRect.cs:458-463`) | `OpenClickySanitiser.isAllowedScheme` (see below) | See Issue 6 |
| URL length cap | `<= 2048` (`VisualElementContext.LinkRect.cs:325-327`) | `<= 2048` (`OpenClickyLinkRectHarvester.swift:180`) | Yes |
| Title length cap | `<= 200` (`VisualElementContext.LinkRect.cs:357`) | `<= 200` (`OpenClickyLinkRectHarvester.swift:189-191`) | Yes |
| MaxLinks cap | `MaxLinks = 200` (`ContextStashWriter.cs:159`) | `maxLinks = 200`, `finalise()` caps (`OpenClickyLinkRectHarvester.swift:41, 215`) | Yes |
| AddOrUpgrade score | `(hasTitle ? 100 : 0) + Width * Height` (`VisualElementContext.LinkRect.cs:474-488`) | `titleBonus (100) + width * height` (`OpenClickyLinkRectHarvester.swift:82-88, 228-251`) | Yes |
| Dedup key | Dict keyed on `Url` with `StringComparer.OrdinalIgnoreCase` (`VisualElementContext.LinkRect.cs:187-188`) | `url.lowercased()` dictionary key (`OpenClickyLinkRectHarvester.swift:236`) | Yes |
| `javascript:` rescue | Multi-channel probe -> `ExtractAllHttpUrls`, `@owner/repo` fallback (`VisualElementContext.LinkRect.cs:303-323, 471-511, 534-563`) | Not implemented; unallowed scheme drops (`OpenClickyLinkRectHarvester.swift:181-184`) | Divergent — see Issue 2 |
| `EVERYWHERE_LINKRECT_DUMP` env-var diagnostic | Present (`VisualElementContext.LinkRect.cs:171-214`) | Not implemented | Divergent — see Issue 2 |
| AXURL type handling | `NSObject` bridging on `AXURL` -> both string and NSURL sources | Handles both `CFURL` and `CFString` return types (`OpenClickyLinkRectHarvester.swift:265-276`) | Yes |
| Bounds attr | `AXPositionAttribute` + `AXSizeAttribute` unpacked | Same (`OpenClickyLinkRectHarvester.swift:322-337`) | Yes |
| Redaction on the harvest boundary | Not done in harvester — Everywhere leaves the URL raw and only redacts in `TryReadXlbMultiPick` clipboard path (`ContextStashWriter.cs:429`) | `OpenClickySanitiser.redactCredentials(parsed)` applied inside harvest per link (`OpenClickyLinkRectHarvester.swift:181-184`) | Divergent — see Issue 4 |

`OpenClickySanitiser.isAllowedScheme` / `redactCredentials` are the openclicky
port of Everywhere's `IsAllowedScheme` + `RedactCredentials` — same
`http|https|mailto` allow-list, same 17-param denylist. Redaction is applied
at the harvest boundary in Openclicky where Everywhere applies it in the
clipboard sentinel branch only.

## Alignment Table — Stash Write Path

| Step | Everywhere `CaptureLinksAsync` (`ContextStashWriter.cs:130-213`) | Openclicky `captureLinks((title,url))` (`OpenClickyContextStashWriter.swift:293-362`) | Match |
|---|---|---|---|
| Single-flight | `SemaphoreSlim.WaitAsync(0)` (`ContextStashWriter.cs:135`) | `NSLock.try()` (`OpenClickyContextStashWriter.swift:300-304`) | Yes |
| Snapshot frontmost | `_context.FocusedElement` + `WalkToTopLevel` (`ContextStashWriter.cs:142-145`) | `FrontmostAppCapture.capture()` (`OpenClickyContextStashWriter.swift:308-310`) | Semantic |
| Browser URL | `_browserUrl.GetUrl(pid)` (`ContextStashWriter.cs:149`) | `BrowserURLCapture.capture(processId: pid)?.url` + `OpenClickySanitiser.redactCredentials` (`OpenClickyContextStashWriter.swift:317-325`) | Yes |
| MaxLinks | `MaxLinks = 200` (`ContextStashWriter.cs:159`) | `maxLinkRectLinks = 200` (`OpenClickyContextStashWriter.swift:368`) | Yes |
| MaxUrlLen | `MaxUrlLen = 2048` (`ContextStashWriter.cs:160`) | `maxLinkRectUrlLen = 2048` (`OpenClickyContextStashWriter.swift:369`) | Yes |
| MaxTitleLen | `MaxTitleLen = 200` (`ContextStashWriter.cs:161`) | `maxLinkRectTitleLen = 200` (`OpenClickyContextStashWriter.swift:370`) | Yes |
| Empty URL skip | `IsNullOrWhiteSpace(linkUrl)` (`ContextStashWriter.cs:167`) | Same (`OpenClickyContextStashWriter.swift:389-390`) | Yes |
| Scheme filter | `IsAllowedScheme` (`ContextStashWriter.cs:169`) | `OpenClickySanitiser.isAllowedScheme` (`OpenClickyContextStashWriter.swift:392-393`) | Yes |
| Credential redaction | Not applied in `CaptureLinksAsync` (`ContextStashWriter.cs:165-181`) | `OpenClickySanitiser.redactCredentials` (`OpenClickyContextStashWriter.swift:394-395`) | Divergent — see Issue 4 |
| Dedup key | `linkUrl + "\0" + (title ?? "")` case-insensitive (`ContextStashWriter.cs:170-171`) | `redacted.lowercased() + "\u{0}" + title.lowercased()` (`OpenClickyContextStashWriter.swift:397-398`) | Yes |
| Title trim (empty → nil) | Ternary null trim (`ContextStashWriter.cs:172-174`) | Whitespace trim + empty → nil (`OpenClickyContextStashWriter.swift:400-408`) | Yes (openclicky trims whitespace first, Everywhere doesn't) |
| Cap early break | `if picked.count >= MaxLinks { capped = ...; break }` (`ContextStashWriter.cs:176-180`) | `if picked.count >= maxLinkRectLinks { break }` (`OpenClickyContextStashWriter.swift:411`) | Yes |
| No writes if empty | `if picked.count == 0 return` (`ContextStashWriter.cs:186`) | `if filtered.isEmpty return` (`OpenClickyContextStashWriter.swift:329`) | Yes |
| Payload build | `ContextSnapshotPayload(...)` (`ContextStashWriter.cs:188-199`) | `OpenClickyContextSnapshotPayload(...)` with `pinPending / whiteboardPending / annotations = nil` (`OpenClickyContextStashWriter.swift:331-345`) | Yes |
| Annotation peek+consume | `PeekAnnotationsForPayload()` + `_annotationStash.Consume(annoSource)` (`ContextStashWriter.cs:187, 204`) | Not wired; `annotations: nil` and no consume (`OpenClickyContextStashWriter.swift:344`) | Divergent — see Issue 7 |
| Atomic write | `WriteAtomicAsync(FormatForHook(payload), ...)` (`ContextStashWriter.cs:200`) | `Self.writeAtomic(stashPath:, payload:)` (`OpenClickyContextStashWriter.swift:347-353`) | Yes |
| Agent activate + phrase | `ActivateAgentApp()` (`ContextStashWriter.cs:206`), `TryFireLaunchPhrase` chain | `Task { await activateAgentAndFirePhrase() }` after successful write (`OpenClickyContextStashWriter.swift:356-361`) | Yes |
| `ManualCaptureCompleted` fan-out | `ManualCaptureCompleted?.Invoke()` (`ContextStashWriter.cs:207`) | Not implemented | Divergent — see Issue 8 |

Openclicky writer entry from hotkey:
`harvestAndPersistLinkRect(dragRect:)` runs the harvester off main via
`Task.detached(priority: .userInitiated)`, then hops back to the main
actor for `stashWriter.captureLinks(result.picks)`
(`OpenClickyContextHotkeys.swift:326-341`).

## Issues

### Issue 1 — Overlay + harvester + writer meet the F24 spec

- Grey 0.15 tint ✓ (`OpenClickyLinkRectOverlayWindow.swift:268`).
- 2 px green outline ✓ (`OpenClickyLinkRectOverlayWindow.swift:286-288`).
- Single rect drag from `mouseDown`/`mouseUp` ✓.
- Escape / right-click cancel ✓.
- Per-pid AX walk with MaxDepth=60, WalkBudget=50_000 ✓.
- `AXLink` role filter ✓ (`OpenClickyLinkRectHarvester.swift:255-263`).
- Majority-overlap rule (horizontal any + mid-Y inside rect) ✓ — matches
  Everywhere's linkclump-plus behaviour, not a strict > 50 % area rule.
- Caps 200 links / 2048 URL / 200 title ✓.
- 17-param credential denylist via `OpenClickySanitiser.redactCredentials`
  applied per pick ✓.
- AddOrUpgrade score `(hasTitle ? 100 : 0) + w*h` ✓.
- Insertion order preserved in `finalise()` ✓.

### Issue 2 — Deferred pieces per spec are still deferred

- `javascript:` URL rescue path: harvester scheme filter drops any non-http/
  https/mailto anchor (`OpenClickyLinkRectHarvester.swift:181-184`).
  Everywhere's rescue (`VisualElementContext.LinkRect.cs:303-323, 471-563`)
  probes AXName/AXDescription/AXValue/`@owner/repo` for a hidden real URL.
  Sites like xlinkBook popups will contribute zero anchors on Openclicky.
- `EVERYWHERE_LINKRECT_DUMP` diagnostic env var
  (`VisualElementContext.LinkRect.cs:171-214`) has no Openclicky counterpart.

The spec explicitly lists both as deferred; note them so they aren't lost.

### Issue 3 — Ancestor row-text fallback missing

Everywhere climbs up to 3 parents looking for AXName/AXDescription/GetText
to give svg-icon anchors a human label (`VisualElementContext.LinkRect.cs:353-357, 424-454`).
Openclicky stops at `axTitle -> axDescription -> axValueText`
(`OpenClickyLinkRectHarvester.swift:186-188`). Impact: label-less icon anchors
that would have been rescued by an ancestor row are dropped by the icon-only
guard (`OpenClickyLinkRectHarvester.swift:195-197`).

### Issue 4 — Openclicky redacts credentials in the harvest path; Everywhere does not

`OpenClickyLinkRectHarvester.acceptLink` runs `OpenClickySanitiser.redactCredentials`
before caching (`OpenClickyLinkRectHarvester.swift:181-184`), and
`OpenClickyContextStashWriter.captureLinks((title,url))` runs it again on the
writer boundary (`OpenClickyContextStashWriter.swift:394-395`).

`ContextStashWriter.CaptureLinksAsync` does NOT redact
(`ContextStashWriter.cs:165-181` filters, dedups, caps — no `RedactCredentials`
call). Everywhere redaction lives only in `TryReadXlbMultiPick`
(`ContextStashWriter.cs:429`) — the clipboard sentinel path.

Verdict on this divergence: task description explicitly permits Openclicky to
either match `redactCredentials` (which it does via `OpenClickySanitiser`) or
match `RedactCredentials` — Openclicky picks the safer of the two. Positive
finding for defence-in-depth; note that Openclicky's on-disk payload is
strictly more redacted than Everywhere's.

### Issue 5 — Post-drag flash + highlight not implemented

Everywhere paints an aqua outline around each captured anchor for ~700 ms
before closing the overlay so the user sees which anchors landed
(`VisualElementContext.LinkRect.cs:58-72, 75-92`). Openclicky dismisses the
overlay immediately in `ended(atQuartz:)` (`OpenClickyLinkRectOverlayWindow.swift:106`)
and harvest runs on a detached task afterwards. No user feedback on
"how many links were caught".

### Issue 6 — Scheme allow-list is correct via `OpenClickySanitiser`

`OpenClickyLinkRectHarvester.acceptLink` gates on
`OpenClickySanitiser.isAllowedScheme` (`OpenClickyLinkRectHarvester.swift:182`).
`OpenClickyContextStashWriter.captureLinks((title,url))` gates on the same
helper (`OpenClickyContextStashWriter.swift:392-393`). Everywhere's
`IsAllowedScheme` accepts `http|https|mailto`
(`VisualElementContext.LinkRect.cs:458-463` and `ContextStashWriter.cs:824-829`).
Positive finding — no `data:` / `javascript:` / `file:` can leak into the
picked_links payload.

### Issue 7 — Annotation queue not drained on the LinkRect path

Everywhere's `CaptureLinksAsync` peeks the annotation stash into the payload
and consumes it on success (`ContextStashWriter.cs:187, 204`). Openclicky's
LinkRect-direct entry sets `annotations: nil` and never touches the stash
(`OpenClickyContextStashWriter.swift:344`, comment "Phase 7 TODO"). Same
gap exists in the general `captureCoreAsync` path
(`OpenClickyContextStashWriter.swift:161-162`), so LinkRect isn't uniquely
regressed — but the F24 spec still calls this a divergence.

### Issue 8 — `ManualCaptureCompleted` event fan-out missing

Everywhere fires `ManualCaptureCompleted?.Invoke()` after a successful
LinkRect write (`ContextStashWriter.cs:207`) so annotation-badge overlays
clean up their floating state. Openclicky has no equivalent event; UI
overlays keyed on "user just shipped" won't refresh after LinkRect.

## Verdict

Overlay press-drag UX and harvester core logic (pid intersect, MaxDepth 60,
walk budget 50 000, majority-overlap rule, icon-only drop, AddOrUpgrade,
dedup by URL, 200 / 2048 / 200 caps, insertion-order emit) are at
Everywhere parity. Stash writer path (single-flight, scheme filter, redact,
cap, dedup, atomic write, agent activate + phrase) is at parity or stricter.

Openclicky is safer on one axis (credential redaction runs both at harvest
and at write) and weaker on three axes:

- Issue 3: no ancestor row-text fallback for icon-only anchors.
- Issue 5: no post-drag captured-links flash.
- Issue 7 + 8: annotation stash + `ManualCaptureCompleted` event not wired
  (Phase 7 TODO across the codebase, not LinkRect-specific).

Explicitly deferred per spec: `javascript:` rescue (Issue 2) and
`EVERYWHERE_LINKRECT_DUMP` env-var diagnostic (Issue 2).

Ship status: acceptable for the primary drag-select-and-write contract on
web anchors that expose an `http(s)`/`mailto` `AXURL`. Sites relying on the
`javascript:` void anchor pattern (xlinkBook, some GitHub rows) will
under-harvest until Issue 2 lands.
