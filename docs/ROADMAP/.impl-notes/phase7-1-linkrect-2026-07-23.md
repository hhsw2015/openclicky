# Phase 7.1 Layer 4 UX — LinkRect press-drag harvest (impl notes)

Source of truth: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs` @30e03e9d, 608 lines.

## Bundle-id filter

None. Everywhere harvests from every on-screen pid whose window bounds intersect the drag rect:
`CollectAllOnScreenPids` reads `CGWindowListCopyWindowInfo(OnScreenOnly, 0)` and adds every pid whose window rect intersects the drag (best-effort — missing bounds fall through and include the pid). No app-bundle filter, no "browsers only" branch.

## AX walk budget

`WalkBudget.Remaining = 50_000` **total** across all pids in the harvest. Consumed globally in the recursion (`budget.Remaining-- <= 0` returns early). `MaxDepth = 60` per subtree.

## Rect intersection

Two-step check:

1. **Prune (`IntersectsLoose`, cs:400)** — classic axis-aligned rectangle overlap. Used to short-circuit subtree descent when a node's bounds miss the drag rect entirely. Zero-size nodes bypass this so lazy AX subtrees still get walked.

2. **Accept (`MajorityOverlap`, cs:411)** — the anchor is "selected" when:
   - horizontal: **any** overlap (`!(a.Right < b.X || a.X > b.Right)`)
   - vertical: anchor's mid-Y (`anchor.Y + anchor.Height/2`) lies **inside** the drag rect's Y span (`>= dragRect.Y && <= dragRect.Bottom`)

Linkclump-plus semantics: user swept a row → row's mid-Y crossed the rect → grab it, even if the anchor is wider than the drag horizontally.

## Redaction

Reuse `OpenClickySanitiser.redactCredentials(URL)` for the URL. Everywhere does not run credential-redaction inside LinkRect per se — it applies `IsAllowedScheme` gate (http | https | mailto) and length cap. OpenClicky redacts eagerly so the same URL landing via SnapshotContext.browser URL branch and LinkRect branch reach the stash in the same form.

## Cap logic (byte-match Everywhere)

| Constant | Value | Location |
|---|---|---|
| `MaxLinks` | 200 | `ContextStashWriter.cs:405` `MaxClipboardLinks = 200` (LinkRect uses same limit — enforced downstream when merging into the payload) |
| `MaxUrlLen` | 2048 | `LinkRect.cs:326` `url!.Length <= 2048` |
| `MaxTitleLen` | 200 | `LinkRect.cs:357` `title = title[..200]` |

Dedup by URL via `AddOrUpgrade`: keeps whichever entry has higher score = `(hasTitle ? 100 : 0) + width*height`. So the larger, labelled anchor wins over the tiny icon that points to the same URL.

## Immediate-ship vs stash-then-snapshot

Immediate. `HarvestAsync` returns the harvested list and the caller writes it. In Everywhere the downstream perception path (`xlinkBook /url_cache/get_bulk`) consumes the list directly.

OpenClicky-side: we do **not** currently route through a separate perception service, so `captureLinks(links:)` on `OpenClickyContextStashWriter` writes the list directly into `picked_links[]` of `context-stash.json` — same on-disk shape as `tryReadXlbMultiPick` already produces. This matches the roadmap doc `05_LAYER_4_UX.md` §B: "Stash: 加入到 context-stash.json 的 picked_links[] 字段".

## Icon-only anchor drop

`isUntitledIcon = title.isEmpty && bounds.Width <= 32 && bounds.Height <= 32` → dropped. Both axes small AND no title. Prevents copy/share icons on row-click sites polluting the harvest. **Both axes**, not either — a text breadcrumb of 220x18 must survive.

## javascript: URL rescue

Skipped for the OpenClicky port in this pass. The rescue path expands sites like xlinkBook popup where `href="javascript:void(0)"` is paired with the real URL in `aria-label`. Adding this doubles the code volume and touches ancestor-walk logic; not required for parity with roadmap §B. TODO in a follow-up if a real user site trips it.

## Files planned

Create:
- `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` — transparent full-screen `NSWindow` (`.screenSaver` level, `NSTrackingArea`), draws single drag rect from mouseDown→mouseUp. Alpha 0.15 grey tint, 2px green outline. Delegate reports rect back on completion or ESC-cancel.
- `cursor-buddy/OpenClickyLinkRectHarvester.swift` — enumerates on-screen pids, walks each `AXUIElementCreateApplication(pid)` up to `MaxDepth=60` with global `WalkBudget=50_000`, collects `AXLink` role elements passing `majorityOverlap`, extracts `(url, title)` with fallback chain, dedups by URL, caps at 200/2048/200.

Modify:
- `cursor-buddy/OpenClickyContextHotkeys.swift` — LinkRect case starts overlay; on rect-complete, calls harvester + `captureLinks(links:)`.
- `cursor-buddy/OpenClickyContextStashWriter.swift` — add `captureLinks(_ links: [OpenClickyPickedLink])` public method that runs the standard `captureCoreAsync` but pre-seeds `pickedLinks` with the harvested list (unions with any XLB clipboard picks so nothing gets lost).

Test:
- `cursor-buddyTests/OpenClickyLinkRectHarvesterTests.swift` — pure geometry: `majorityOverlap`, `intersectsLoose`, dedup add-or-upgrade, cap enforcement, allowed-scheme filter integration. AX walk itself is not mocked (`AXUIElement` is opaque C-ref) — geometry + selection rules are the meaningful invariants.
