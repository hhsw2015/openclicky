# Phase 7.1 Layer 4 UX — LinkRect report

## Files created

- `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` — transparent per-screen `NSWindow` at `.screenSaver` level. Drag rect resolved in Quartz global coordinates. Grey tint at alpha 0.15 with a 2px green outline stroked around the punched-out selection.
- `cursor-buddy/OpenClickyLinkRectHarvester.swift` — enumerates on-screen pids whose window bounds intersect the drag rect, walks each `AXUIElementCreateApplication(pid)` up to `MaxDepth = 60`, applies linkclump `majorityOverlap` selection, extracts `(url, title)` with the AXTitle → AXDescription → AXValue fallback chain, redacts credentials via `OpenClickySanitiser`, drops icon-only anchors (both axes ≤ 32 AND no title), dedups via score-based `AddOrUpgrade`, and caps at 200 links.
- `cursor-buddyTests/OpenClickyLinkRectHarvesterTests.swift` — pure geometry / dedup / cap invariants (`intersectsLoose`, `majorityOverlap`, `upgradeScore`, `addOrUpgrade`, `OpenClickyLinkRectLimits`, `OpenClickyContextStashWriter.mergeLinks`).

## Files modified

- `cursor-buddy/OpenClickyContextHotkeys.swift` — LinkRect action now presents the overlay, harvests off the main thread, and calls `stashWriter.captureLinks(...)`. Single-flight `linkRectOverlay` guard.
- `cursor-buddy/OpenClickyContextStashWriter.swift` — added public `captureLinks(_ links: [OpenClickyPickedLink]) async` entry point and internal `mergeLinks` that unions LinkRect harvest with the XLB clipboard sentinel harvest, deduped by lowercase URL and capped at 200.

## Everywhere-parity audit (LinkRect.cs @30e03e9d)

| Constant | Everywhere | OpenClicky | Match |
|---|---|---|---|
| MaxLinks | 200 (`ContextStashWriter.cs:405` / applies via merge) | 200 (`OpenClickyLinkRectLimits.maxLinks`) | yes |
| MaxUrlLen | 2048 (`LinkRect.cs:326`) | 2048 (`OpenClickyLinkRectLimits.maxUrlLen`) | yes |
| MaxTitleLen | 200 (`LinkRect.cs:357`) | 200 (`OpenClickyLinkRectLimits.maxTitleLen`) | yes |
| MaxDepth | 60 (`LinkRect.cs:242`) | 60 (`OpenClickyLinkRectLimits.maxDepth`) | yes |
| WalkBudget | 50_000 (`LinkRect.cs:224`) | 50_000 (`OpenClickyLinkRectLimits.walkBudget`) | yes |
| Icon-only drop | `≤32 && ≤32 && !title` (`LinkRect.cs:370`) | same rule | yes |
| Dedup score | `(hasTitle ? 100 : 0) + w*h` (`LinkRect.cs:478`) | same in `OpenClickyLinkRectGeometry.upgradeScore` | yes |
| Scheme allow-list | http / https / mailto (`LinkRect.cs:458`) | `OpenClickySanitiser.isAllowedScheme` (http / https / mailto) | yes |
| Pid filter | on-screen windows intersecting drag rect (`LinkRect.cs:566`) | same via `CGWindowListCopyWindowInfo` | yes |
| Majority overlap | any-horizontal AND anchor-midY-inside-dragY (`LinkRect.cs:411`) | same in `OpenClickyLinkRectGeometry.majorityOverlap` | yes |
| Diff: javascript: rescue | present (`LinkRect.cs:305-323`) | deferred (documented) | intentional |
| Diff: dump env var | `EVERYWHERE_LINKRECT_DUMP=1` | not ported (diagnostic only) | intentional |

## AX walk budget

Global `walkBudget = 50_000` nodes, drained across every candidate pid in a single harvest (matches Everywhere's `WalkBudget.Remaining`). Depth cap: 60 per subtree. `HarvestResult` reports `nodesVisited` + `budgetExhausted` so the cost signal shows up in `NSLog`.

## Rect intersection formula

Two-step, ported byte-for-byte:

- prune (`OpenClickyLinkRectGeometry.intersectsLoose`) — classic axis-aligned overlap with strict `<` (touching edges count as intersecting).
- accept (`OpenClickyLinkRectGeometry.majorityOverlap`) — any horizontal overlap AND `anchor.y + anchor.height/2` inside `[dragRect.y, dragRect.y + dragRect.height]`.

Zero-size AX subtrees are still walked (lazy children) but never accepted as links.

## Build result

`bash scripts/sign-and-install.sh`:

```
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
    ** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
[5/5] done.
```

Test bundle build has 5 pre-existing errors in `cursor_buddyTests.swift` (missing `Foundation` import — untouched by this phase). My new `OpenClickyLinkRectHarvesterTests.swift` file compiles without errors; verified by diff-count (5 errors without it, 5 errors with it — my file adds 0 new errors).

## Manual test recipe

1. Open Settings → Context Awareness. Bind the "LinkRect (press-drag)" hotkey to something free — e.g. Ctrl+Shift+L.
2. Open a browser window with a page full of anchors (e.g. Hacker News front page).
3. Press the bound hotkey. A grey-tinted full-screen overlay appears.
4. Click-drag a rectangle over several stories. Release the mouse.
5. Overlay dismisses. `NSLog` line prints `linkrect harvest picks=<N> candidates=<M> nodes=<K> budgetExhausted=false`.
6. Inspect `~/Library/Application Support/OpenClicky/context-stash.json`. The `picked_links` field carries the harvested `[{"url", "title"}]` entries. Credential-bearing query params should be stripped.
7. Cancel path: repeat step 3, then press Esc or right-click. Overlay dismisses. No stash write, no picks logged.
8. Empty-drag path: repeat step 3, click without dragging (mouseDown + mouseUp same point). Overlay dismisses, `linkrect cancelled` logs, no stash write.
