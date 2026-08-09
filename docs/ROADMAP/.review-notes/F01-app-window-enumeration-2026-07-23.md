# Review F01: App and Window enumeration

**Everywhere pin**: 30e03e9dcfdd4247fd679828ed86e9042f32d809
**Reviewer**: agent
**Date**: 2026-07-23

## Files

openclicky (bytes):
- Capture/FrontmostAppCapture.swift — 4897
- Capture/RunningAppsCapture.swift — 3208
- Capture/FocusedWindowCapture.swift — 12354
- Capture/WindowEnumerationCapture.swift — 9898
- Capture/ScreenListCapture.swift — 6953
- Types/CaptureTypes.swift — 101862 (only F01 structs reviewed)

Everywhere (bytes):
- Mcp/Snapshot/AppKey.cs — 1160
- Mac/Interop/VisualElementContext.cs — 6180
- Mac/Interop/AXUIElement.cs — 63269 (only FreshFocusedWindowOf + Name + QueryBoundingRectangle reviewed)
- Mac/Interop/AXAttributeConstants.cs — 5745
- Mac/Interop/WindowHelper.cs — 15065
- Mac/Interop/NSScreenVisualElement.cs — 6944
- Mac/Interop/SkyLightInterop.cs — 3428

## Alignment Table

### FrontmostAppCapture.swift ↔ AppKey.cs / VisualElementContext.cs

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Header cites pin | FrontmostAppCapture.swift:1-3 | — | OK | Cites AppKey.cs, VisualElementContext.cs, MacFocusBackend.cs at pin |
| `pid <= 0` → "unknown" | FrontmostAppCapture.swift:49-51 | AppKey.cs:14-17 | OK | Byte-equivalent |
| Empty name → pid string | FrontmostAppCapture.swift:52-57 | AppKey.cs:22-23 | OK | Swift `"\(processId)"` == C# `processId.ToString()` |
| Lookup failure → pid string | FrontmostAppCapture.swift:52-57 (guard) | AppKey.cs:25-28 (catch) | OK | Guard replaces try/catch; same output |
| Name lower-cased | FrontmostAppCapture.swift:58 `.lowercased()` | AppKey.cs:23 `.ToLowerInvariant()` | WARN | Swift `.lowercased()` is Locale.current-aware; C# `ToLowerInvariant` is culture-invariant. Divergent for Turkish 'İ'/'i'. Impact: low for exe names. |
| Name source | `NSRunningApplication.executableURL.lastPathComponent` (L52-53) | `System.Diagnostics.Process.ProcessName` (AppKey.cs:22) | WARN | Divergence explicitly documented in header L17-22. Both yield "Finder" for GUI apps but can diverge for POSIX helpers with extensions. |
| MatchesQuery whitespace guard | FrontmostAppCapture.swift:65-68 | AppKey.cs:33-36 | OK | `.trimmingCharacters(...).isEmpty` mirrors `IsNullOrWhiteSpace` |
| MatchesQuery case-insensitive eq/contains | FrontmostAppCapture.swift:69-72 | AppKey.cs:38-39 | WARN | Swift `.caseInsensitiveCompare` + `.caseInsensitive` are locale/Unicode-aware; C# `StringComparison.OrdinalIgnoreCase` is byte casefold. Diverges on Unicode edge cases. |
| Frontmost source | `NSWorkspace.shared.frontmostApplication` (L88) | Not directly captured in Everywhere; VisualElementContext reads NSRunningApplication ad-hoc | N/A | openclicky-additive surface; header documents |
| Defensive `pid <= 0` after AppKit | FrontmostAppCapture.swift:91-96 | not in Everywhere | OK | Additive defensive check, safe |

### RunningAppsCapture.swift ↔ VisualElementContext.cs:97-111 (`TryFastListApps`)

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Header cites pin | RunningAppsCapture.swift:1 | — | OK | |
| Source of iteration | `NSWorkspace.shared.runningApplications` (L41) | `NSWorkspace.SharedWorkspace.RunningApplications` (L99) | OK | Identical AppKit call |
| Prohibited-policy filter | RunningAppsCapture.swift:46 | VisualElementContext.cs:103 | OK | Byte-equivalent |
| `pid <= 0` filter | RunningAppsCapture.swift:50 | VisualElementContext.cs:104-105 | OK | Byte-equivalent |
| `FreshFocusedWindowOf` gate | absent | VisualElementContext.cs:106-107 | DIVERGE | **Intentional**: header L7-12 + CaptureTypes.swift:102-105 document that this AX-round-trip belongs downstream. Consequence: openclicky's list is a strict superset of Everywhere's (includes just-launched apps with no window yet). |
| Return tuple shape | `RunningAppInfo` struct with 9 fields | `(IVisualElement Window, int ProcessId)` (L100, 108) | DIVERGE | Intentional: richer struct, header L20-32 + CaptureTypes.swift:107-132 document. Everywhere-observed fields (processId, activationPolicy) preserved verbatim. |
| Ordering | preserves `runningApplications` order (no sort) | preserves iteration order | OK | Both non-guaranteed by AppKit; both consistent |

### FocusedWindowCapture.swift ↔ AXUIElement.cs (FreshFocusedWindowOf + Name + QueryBoundingRectangle) + NSScreenVisualElement.cs

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Header cites pin | FocusedWindowCapture.swift:1-5 | — | OK | Cites AXUIElement.cs, AXAttributeConstants.cs, NSScreenVisualElement.cs, ContextStashWriter.cs, SnapshotRenderer.cs |
| `pid <= 0` → nil | FocusedWindowCapture.swift:101 | AXUIElement.cs:1163 | OK | Byte-equivalent |
| App element creation | `AXUIElementCreateApplication(processId)` (L103) | `ElementFromPid` → `CreateApplication(pid)` (AXUIElement.cs:1147-1150, 1164) | OK | Swift skips the `!= 0` null check; `AXUIElementCreateApplication` is documented non-null-returning, so equivalent |
| AXFocusedWindow first | L133 via `copyElementAttribute(app, attrFocusedWindow)` | AXUIElement.cs:1166 `CopyAttributeValue(...FocusedWindow...)` | OK | Same attribute string `"AXFocusedWindow"` (AXAttributeConstants.cs:27) |
| AXMainWindow fallback | L136 | AXUIElement.cs:1171-1173 | OK | Comment L131 preserves Everywhere's "Some apps don't have a focused window after launch" (AXUIElement.cs:1169-1170) |
| Both miss → nil | L105-107 | AXUIElement.cs:1173 | OK | |
| Title cascade attributes | AXTitle → AXDescription → AXHelp (L164) | AXUIElement.cs:268-273 | OK | Matches step 1-3 |
| Cascade truncated (no IsLabelBearingRole branch) | L157-159 explanation | AXUIElement.cs:279-311 | DIVERGE | **Intentional**: AXWindow is never a label-bearing role, so downstream branches are unreachable. Documented in header L14-17 and inline L157-159. |
| IsNullOrWhiteSpace equivalent | `.trimmingCharacters(...).isEmpty` (L166) | `IsNullOrWhiteSpace(t)` (AXUIElement.cs:269-273) | OK | |
| Frame from AXPosition + AXSize | L198-219 | AXUIElement.cs:448-465 (QueryBoundingRectangle) | OK | Attribute constants match AXAttributeConstants.cs:16-17 |
| Missing/unwrap fail → `.zero` | L207, 216 | AXUIElement.cs:455, 461-464 (`return default;`) | OK | `CGRect.zero` matches C# `default(PixelRect)` |
| Frame precision | CGFloat throughout | AXUIElement.cs:459 truncates to `(int)` | DIVERGE | **Intentional** (see ScreenListCapture.swift:59-60 rationale carried over): Swift preserves sub-pixel origins on Retina. Rects will differ from Everywhere-emitted PixelRects by fractional pixels. Acceptable — Everywhere's PixelRect widens back to CGFloat at rendering time anyway. |
| AXMinimized attr | `"AXMinimized"` (L82) | AXAttributeConstants.cs:82 `MinimizedAttr` = `"AXMinimized"` | OK | |
| AXMain attr | `"AXMain"` (L83) | AXAttributeConstants.cs:81 `MainTrait` = `"AXMain"` | OK | |
| Bool missing → false | L189-192 | Implicit throughout AXUIElement.cs | OK | Header L184-185 documents |
| Y-flip formula | `y = primaryHeight - (cocoa.y + cocoa.height)` (L251) | NSScreenVisualElement.cs:64 `y = primaryFrame.Height - (frame.Y + frame.Height)` | OK | Byte-exact |
| Primary reference `screens[0]` | L242 | NSScreenVisualElement.cs:62 | OK | Same AppKit invariant |
| Largest-intersection tiebreak | L244-262 | NSScreenVisualElement.cs:37-42 uses `.Intersects` (any overlap) | DIVERGE | Swift picks largest-area intersection for multi-display overlap; Everywhere returns all-matching. Only matters when a window spans multiple displays; Swift's choice is what a "which screen owns this window" API should return. Header L235 documents. |

### WindowEnumerationCapture.swift ↔ WindowHelper.cs:272-292

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Header cites pin | WindowEnumerationCapture.swift:1 | — | OK | Also explicitly disclaims SkyLight port at L14-20 |
| Default options | onScreenOnly=true, excludeDesktopElements=true, relativeToWindow=0 (L58-66, 69) | WindowHelper.cs:272-274 | OK | 1:1 |
| CG option composition | `buildOptionMask` OR-combines `.optionOnScreenOnly` / `.excludeDesktopElements` (L123-134) | `CGWindowListOption.OnScreenOnly \| CGWindowListOption.ExcludeDesktopElements` (WindowHelper.cs:273) | OK | Additive: openclicky offers `.optionAll` when `onScreenOnly=false`. Everywhere never uses that path. |
| CGWindowListCopyWindowInfo call | L91 | WindowHelper.cs:272 (CGInterop.CGWindowListCopyWindowInfo) | OK | |
| nil / non-array → `[]` | L91-99 | WindowHelper.cs implicitly skips (arr Count check, L278) | OK | |
| pid required (kCGWindowOwnerPID) | L150-153 (returns nil, `continue`) | WindowHelper.cs:287 (`continue`) | OK | |
| wid required (kCGWindowNumber) | L156-159 | WindowHelper.cs:288 (`continue`) | OK | |
| layer (kCGWindowLayer) | L194 (default 0) | WindowHelper.cs:290 | OK | Same key, same fallback semantics |
| Ordering | preserves CG-native front-to-back | WindowHelper.cs:291 "CGWindowList returns front-to-back order" | OK | |
| pid Int32 bridge via NSNumber | L150-153 | `ownerObj.Int32Value` (WindowHelper.cs:287) | OK | |
| wid UInt32 bridge via NSNumber | L156-159 | `idObj.UInt32Value` (WindowHelper.cs:289) | OK | |
| Richer payload (title/ownerName/bounds/isOnScreen/alpha) | L162-197 | NOT in WindowHelper — Everywhere only reads pid/wid/layer here | DIVERGE | **Intentional**: header L22-27 documents. Fields materialised from CoreGraphics documented keys; downstream tools consume them. |
| Bounds via `CGRect(dictionaryRepresentation:)` | L176-180 | Not read in WindowHelper.cs:272-292; equivalent read in ScreenSelectionSession.cs | OK | Canonical bridge |
| Bounds malformed → `.zero` | L175-180 | N/A | OK | Documented at L173-175 |
| Screen-index Y-flip | L226-239 | NSScreenVisualElement.cs:62-64 | OK | Same formula reused |

### ScreenListCapture.swift ↔ NSScreenVisualElement.cs

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Header cites pin | ScreenListCapture.swift:1 | — | OK | |
| Source | `NSScreen.screens` (L65) | `NSScreen.Screens` (implicit) / `NSScreen.Screens[0]` (L62) | OK | |
| Empty screens → `[]` | L66 | N/A | OK | Header L25 documents |
| Y-flip formula | `primaryHeight - (cocoaFrame.origin.y + cocoaFrame.height)` (L112) | `primaryFrame.Height - (frame.Y + frame.Height)` (L64) | OK | Byte-exact |
| Primary = `screens[0]` | L66-71, L133 | NSScreenVisualElement.cs:62 | OK | |
| displayID from NSScreenNumber | L149-156 | NSScreenVisualElement.cs:165-168 `GetScreenNumber` | OK | |
| displayID type | `UInt32` (`uint32Value`) | `Int32` (`Int32Value`) | DIVERGE | **Intentional**: `CGDirectDisplayID` is unsigned. Header L145-148 documents. |
| Missing NSScreenNumber → skip | L100-102 | NSScreenVisualElement.cs:167 `?? 0` | DIVERGE | **Intentional**: Everywhere returns id=0 sentinel; openclicky skips entry so downstream never sees 0. Header L56-57 documents. |
| Name source | `NSScreen.localizedName` (L123) | NSScreenVisualElement.cs:51 | OK | |
| Name normalization (whitespace → nil) | L163-166 | Not applied by Everywhere | DIVERGE | Header L158-162 documents; safety net for headless bridges. |
| Frame precision (CGFloat, no int truncation) | L110-121 | NSScreenVisualElement.cs:63-66 truncates via `(int)` | DIVERGE | **Intentional**: header L58-61 documents. Preserves sub-pixel origins. |
| visibleFrame (extra) | L105, L116-121 | Not exposed by NSScreenVisualElement | N/A | Additive; documented in header L17 |
| backingScaleFactor (extra) | L132 | Not exposed | N/A | Additive; documented header L18 |
| Mirrored displays coalescing | none | none | OK | Both surface each mirrored NSScreen separately (header L29-32) |

## Constant Cross-Check

Grepped Everywhere source for magic constants relevant to F01:

- AXAttributeConstants.cs:27 `FocusedWindow = "AXFocusedWindow"` ↔ FocusedWindowCapture.swift:61 — MATCH
- inline literal `"AXMainWindow"` (AXUIElement.cs:1171) ↔ FocusedWindowCapture.swift:65 — MATCH
- AXAttributeConstants.cs:13 `Title = "AXTitle"` ↔ L72 — MATCH
- AXAttributeConstants.cs:14 `Description = "AXDescription"` ↔ L73 — MATCH
- AXAttributeConstants.cs:71 `Help = "AXHelp"` ↔ L74 — MATCH
- AXAttributeConstants.cs:16 `Position = "AXPosition"` ↔ L78 — MATCH
- AXAttributeConstants.cs:17 `Size = "AXSize"` ↔ L79 — MATCH
- AXAttributeConstants.cs:82 `MinimizedAttr = "AXMinimized"` ↔ L82 — MATCH
- AXAttributeConstants.cs:81 `MainTrait = "AXMain"` ↔ L83 — MATCH
- WindowHelper.cs:280 `"kCGWindowOwnerPID"` ↔ WindowEnumerationCapture.swift:150 (`kCGWindowOwnerPID`) — MATCH
- WindowHelper.cs:281 `"kCGWindowNumber"` ↔ L156 — MATCH
- WindowHelper.cs:282 `"kCGWindowLayer"` ↔ L194 — MATCH
- NSScreenVisualElement.cs:167 `"NSScreenNumber"` ↔ ScreenListCapture.swift:150 — MATCH
- AXUIElementSetMessagingTimeout `1f` (AXUIElement.cs:474) — not used in F01 files; NOT ported into FocusedWindowCapture. OK (openclicky uses default 6s AX timeout for these calls).

## Comment / Warning Preservation

- "Some apps don't have a focused window after launch" (AXUIElement.cs:1169-1170) → FocusedWindowCapture.swift:131 — PRESERVED
- "CGWindowList returns front-to-back order" (WindowHelper.cs:291) → WindowEnumerationCapture.swift:77-78, 924-925 (CaptureTypes) — PRESERVED
- "NSScreen.Screens[0] is the primary screen" cocoa/quartz explanation (NSScreenVisualElement.cs:58-61) → ScreenListCapture.swift:41-44, FocusedWindowCapture.swift:240-241 — PRESERVED
- "bundle id (mac), exe path (win), WM_CLASS (linux)" doc (AppKey.cs:5-9) → NOT verbatim, but semantics folded into FrontmostAppCapture.swift:17-22 divergence note
- `TryFastListApps` third filter (FreshFocusedWindowOf) is documented as DELIBERATELY dropped (RunningAppsCapture.swift:7-12) rather than silently preserved — GOOD

## Issues Found

- **LOW**: `AppKeyResolver.matchesQuery` (FrontmostAppCapture.swift:69-72) uses locale-aware Swift case-folding while `AppKey.MatchesQuery` (AppKey.cs:38-39) uses `StringComparison.OrdinalIgnoreCase`. For ASCII exe/bundle strings identical; diverges on Unicode edge cases (Turkish 'İ'/'i', German ß). → Fix (if strict): swap to `.compare(query, options: [.caseInsensitive, .diacriticInsensitive])` is worse; better: use `String.compare(_:options:range:locale:)` with `locale: nil` OR bridge to `NSString.compare(_:options:)` with `.caseInsensitive` and `range: nil, locale: nil`. Actual best match: `left.lowercased() == right.lowercased()` uses default locale — still not Ordinal. True Ordinal parity: compare UTF-8 byte arrays after ASCII lowercase folding. Impact is low in practice.

- **LOW**: `AppKeyResolver.fromProcessId` uses `NSRunningApplication.executableURL.lastPathComponent` (FrontmostAppCapture.swift:52-53) rather than `.NET Process.ProcessName` semantics. Documented divergence (header L17-22); for well-formed macOS `.app` bundles both yield the same string. Diverges for CLI processes whose executables carry an extension (e.g. `foo.sh`). → No fix needed unless a downstream key mismatch is observed.

- **LOW**: `FocusedWindowCapture.readFrame` returns `CGRect` in floats; Everywhere's `QueryBoundingRectangle` truncates to `int` (AXUIElement.cs:459). Deliberate; consumers who serialize cross-implementation may see fractional drift on Retina.

- **LOW / OK**: `RunningAppsCapture.list()` omits the `FreshFocusedWindowOf(pid) is null` gate (VisualElementContext.cs:106-107). Deliberate; callers who need Everywhere-parity should intersect with `FocusedWindowCapture.capture(processId:)`. Header + Types docstring both call this out.

- **LOW / OK**: `WindowEnumerationCapture.buildOptionMask` synthesises `.optionAll` when `onScreenOnly=false` (L127-129). Everywhere never uses this branch. Not a bug — capability superset.

- **INFO**: `WindowEnumerationCapture.largestIntersectionIndex` selects the display with the largest positive-area intersection. `NSScreenVisualElement.Children` (NSScreenVisualElement.cs:37-42) uses any-intersection membership. Different semantics — Swift's choice is defensible for a "which screen owns this window" ID, but a caller expecting "list of screens that touch this window" would be surprised. Header L235 acknowledges.

- **INFO**: Neither Everywhere nor openclicky sets `AXUIElementSetMessagingTimeout` in the F01 code paths (Everywhere sets it once globally in the AXUIElement static ctor, AXUIElement.cs:471-475, at 1s). openclicky's `FocusedWindowCapture` runs with the default 6s AX timeout, which is 6× longer than Everywhere for the same operation. → **Consider** applying a matching per-call `AXUIElementSetMessagingTimeout(app, 1.0)` on the app element after `AXUIElementCreateApplication` if snapshot latency matters.

- **INFO**: `FocusedWindowCapture.capture(processId:)` is synchronous. Everywhere's `FreshFocusedWindowOf` is also synchronous. On denial / hung apps this blocks up to the AX timeout (currently 6s per note above). No async wrapper offered by openclicky yet. Not a regression — matches Everywhere shape.

## Intentional Divergences

All documented in file headers or CaptureTypes docstrings:

1. **FrontmostAppCapture**: source of process name is `executableURL.lastPathComponent` (Swift) vs `Process.ProcessName` (.NET). Header L17-22.
2. **RunningAppsCapture**: drops `FreshFocusedWindowOf` gate; returns richer struct. Header L7-12; CaptureTypes.swift:87-105.
3. **FocusedWindowCapture**: title cascade stops after `AXTitle → AXDescription → AXHelp` (label-bearing-role branches unreachable for AXWindow). Header L14-17.
4. **FocusedWindowCapture / ScreenListCapture / WindowEnumerationCapture**: `CGFloat` precision throughout, no `int` truncation. Header L58-61 in ScreenListCapture, comment L107-109.
5. **ScreenListCapture**: `displayID` typed as `UInt32` (matches `CGDirectDisplayID`); entries with missing `NSScreenNumber` are skipped rather than emitted with `id=0`. Header L56-57.
6. **ScreenListCapture**: adds `visibleFrameQuartz`, `backingScaleFactor`, `index`, `isPrimary`. Header L17-19.
7. **WindowEnumerationCapture**: adds `title / ownerName / bounds / isOnScreen / alpha` (Everywhere only reads pid/wid/layer at the parallel call site). Header L22-27.
8. **WindowEnumerationCapture**: `.optionAll` code path added for `onScreenOnly=false`. Not a semantic change to default behaviour.
9. **Screen membership**: openclicky uses largest-area intersection tiebreak; Everywhere uses `.Intersects` (any overlap).
10. **F01 files explicitly disclaim porting `SLSGetActiveSpace` / `SLSCopyWindowsWithOptions`** (WindowEnumerationCapture.swift:14-20) — grep of SkyLightInterop.cs confirms no such API exists in Everywhere. `docs/ROADMAP/10_OVERLAP_ANALYSIS.md` row 242 is incorrect per this file's disclaimer.

## Verdict

- [ ] BYTE_MATCH
- [x] SEMANTIC_MATCH — logic identical modulo documented Swift-idiomatic reshaping (richer payloads, CGFloat precision, unsigned display id, skip-vs-sentinel, deferred AX gate)
- [ ] DIVERGENT
- [ ] BROKEN

No blocking issues. Two low-severity items worth considering before ship:

1. Switch `AppKeyResolver.matchesQuery` to a byte-Ordinal comparison to eliminate Turkish/Unicode edge-case skew vs Everywhere.
2. Apply `AXUIElementSetMessagingTimeout(app, 1.0)` after `AXUIElementCreateApplication` in `FocusedWindowCapture` to match Everywhere's 1s AX timeout (currently defaulting to 6s).

All other deviations are deliberate, documented at the file-header level, and preserve or extend Everywhere's semantics.
