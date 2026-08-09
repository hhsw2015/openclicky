# Phase 1 BrowserURL — implementation notes (2026-07-22)

Source: `~/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacBrowserUrlReader.cs` @30e03e9dcfdd4247fd679828ed86e9042f32d809 (135 lines).

## Step 1 — investigation findings

### Detection strategy

Everywhere's `MacBrowserUrlReader` is **browser-agnostic**. There is no
bundle-id allow-list; it never introspects the app identity at all. The
reader works on **any** pid whose AX tree exposes an `AXURL` attribute
somewhere along the focused-element -> ancestor chain. Practically that
means Safari / Chrome / Chromium-family (Chrome, Edge, Brave, Arc,
Vivaldi, Opera) / Firefox (with `AXManualAccessibility` opt-in) all
work through the same code path; non-browser apps whose focused element
carries a `AXURL` (e.g. some Electron apps with hyperlinks focused)
also match — Everywhere considers that acceptable because the callers
of the tool already filter on browser identity externally.

Confirmed by grep: no `com.apple.Safari` / `com.google.Chrome` /
`company.thebrowser.Browser` / `com.brave.Browser` / `com.microsoft.edgemac`
/ `org.mozilla.firefox` string literals anywhere under
`~/Dev/Everywhere/src/`.

### Algorithm (135 line source, condensed)

```
input: pid (Int32)
guard pid > 0
app = AXUIElementCreateApplication(pid)
focused = CopyAttribute(app, "AXFocusedUIElement")
if focused == 0:
    mainWin = CopyAttribute(app, "AXMainWindow")
    focused = CopyAttribute(mainWin, "AXFocusedUIElement")
if focused == 0: return null
cur = focused
for i in 0..<16:
    url = CopyAttributeAsString(cur, "AXURL")
    if !isNullOrEmpty(url): return url
    cur = CopyAttribute(cur, "AXParent")
    if cur == 0: break
return null
```

The `AXURL` attribute returns a `CFURLRef` on hyperlink / web-area
elements, so Everywhere calls `CFURLGetString` to unwrap; if the
attribute is actually a `CFStringRef` (some browsers publish it as a
plain string), it uses it directly. All errors are swallowed and become
`return null`.

### Return shape

`string?` only. No bundle id, no title, no tab index, no favicon. The
consumer `GetBrowserUrlTool.GetBrowserUrl` in
`Everywhere.Mcp/Tools/GetBrowserUrlTool.cs` pairs the URL with
`AppKey.FromProcessId(pid)` separately for its JSON envelope.

### Empty / nil behaviour

* `pid <= 0` -> nil.
* App has no focused UI element and no main window -> nil.
* Focused chain has no `AXURL` within 16 hops -> nil.
* AXURL attribute empty string -> nil (`IsNullOrEmpty` check).
* New tab / start page / private mode -> whatever the browser publishes
  through AXURL. Chrome / Safari expose `chrome://newtab/` /
  `favorites://` respectively; Everywhere returns those as-is.

### Timeout / fallback

**None.** All calls are pure synchronous CFCoreFoundation +
ApplicationServices API. No AppleScript fallback whatsoever. The port
still exposes an `async` signature per task spec (future-proofing hook
for later AppleScript augmentation), but today the body does no
`await` work.

### Bundle-id list

**Empty.** Nothing to port. Any browser-vs-non-browser filtering that
callers want must live at the caller layer (Layer 1 intent router
already tracks the frontmost bundle-id independently).

## Step 2 — doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 9 currently reads:

> | 9 | BrowserURL (AX AXURL walk) | `MacBrowserUrlReader.cs` | `Capture/BrowserURLCapture.swift` | P0 |

Diff vs source: **row is accurate**. The parenthetical "AX AXURL walk"
correctly describes the algorithm. No doc fix needed for row 9.

The `RouterContext` sketch on line 108 uses `browserURL: URLInfo?`; the
Swift return type this port introduces is `BrowserURLInfo?` (mirrors
the sibling `FrontmostAppInfo` / `ClipboardInfo` naming). RouterContext
is not implemented yet, so rewiring the field name there is a later
concern — flag only, no doc change this phase.

## Step 3 — implementation plan

* `Capture/BrowserURLCapture.swift` — new file, `enum BrowserURLCapture`
  with static `capture(processId: Int32?) async -> BrowserURLInfo?`.
* Append `BrowserURLInfo` (processId + url) to
  `Types/CaptureTypes.swift`. Do not touch the other structs.
* Use `import ApplicationServices`. AX API is Swift-bridged:
  `AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`,
  `kAXFocusedUIElementAttribute`, `kAXMainWindowAttribute`,
  `kAXURLAttribute`, `kAXParentAttribute`.
* CFType casts via `CFGetTypeID(value) == AXUIElementGetTypeID()` for
  safety instead of forced `as?` on Swift-imported opaque types.
* AXURL value: cast to `NSURL` (toll-free `CFURLRef`) first, fall back
  to `String` (rare, but Everywhere handles it).

## Step 4 — alignment audit (planned)

* 16-hop ancestor limit — same magic number.
* Empty-string treatment (`IsNullOrEmpty`) — same, Swift `isEmpty`.
* Fallback order: `AXFocusedUIElement` first, then
  `AXMainWindow -> AXFocusedUIElement`. Identical.
* No bundle-id filter (there isn't one to align).

## Step 5 — test plan

XCTest bundle `BrowserURLCaptureTests`:
* `capture(processId: nil)` -> nil.
* `capture(processId: 0)` -> nil (mirrors `pid <= 0` guard).
* `capture(processId: <bogus pid>)` -> nil.
* `capture(processId: <current test pid>)` -> nil (Swift test host has
  no browser web area focused).
* Optional Safari-attached test: `XCTSkipIf` when Safari is not
  running or when `OPENCLICKY_SKIP_UI_TESTS` is set.
* `BrowserURLInfo` JSON round-trip.
