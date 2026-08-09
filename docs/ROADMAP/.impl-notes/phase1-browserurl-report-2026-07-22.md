# Phase 1 BrowserURL — port report (2026-07-22)

## Files

Created:
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/BrowserURLCapture.swift`
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/BrowserURLCaptureTests.swift`
* `/Users/wowdd1/Dev/openclicky/docs/ROADMAP/.impl-notes/phase1-browserurl-2026-07-22.md`

Modified:
* `/Users/wowdd1/Dev/openclicky/Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  — appended `BrowserURLInfo` struct at end of file. Existing types
  (`FrontmostAppInfo`, `ClipboardInfo`, `IdleTimeInfo`,
  `FinderSelectionInfo`, `FinderItem`, `FrontmostActivationPolicy`)
  untouched.

Untouched (per task constraint):
* `FrontmostAppCapture.swift`
* `ClipboardCapture.swift`
* `IdleTimeCapture.swift`
* `FinderSelectionCapture.swift`
* `AppleScriptRunner.swift` — inspected only, not called by this port
  because Everywhere's source uses no AppleScript.

## Everywhere reference

* Source: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacBrowserUrlReader.cs`
  @30e03e9dcfdd4247fd679828ed86e9042f32d809
* Line count: 135
* Consumer: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetBrowserUrlTool.cs`

## Bundle_id list ported

**None.** `MacBrowserUrlReader.cs` performs no bundle-id filtering.
Verified with a grep across the whole Everywhere source tree — no
occurrences of any browser bundle identifier (`com.apple.Safari`,
`com.google.Chrome`, `com.brave.Browser`, `company.thebrowser.Browser`,
`com.microsoft.edgemac`, `org.mozilla.firefox`, etc.). The port is
therefore browser-agnostic: it works on any pid whose AX tree publishes
`AXURL` along the focused-ancestor chain. Any callers that need
browser-vs-non-browser filtering must do it themselves; Everywhere's
own `GetBrowserUrlTool` similarly delegates that concern to callers.

Quoted parity with source (`MacBrowserUrlReader.cs:38-51`):

> ```csharp
> // Walk up looking for AXURL.
> var cur = focused;
> var owns = false;
> for (var i = 0; i < 16 && cur != nint.Zero; i++)
> {
>     var url = CopyAttributeAsString(cur, "AXURL");
>     if (!string.IsNullOrEmpty(url))
>     {
>         if (owns) CFRelease(cur);
>         return url;
>     }
>     var parent = CopyAttribute(cur, "AXParent");
> ```

The Swift port preserves: the 16-hop limit, the `AXFocusedUIElement`
first / `AXMainWindow -> AXFocusedUIElement` fallback lookup, the
`IsNullOrEmpty` skip (as `!url.isEmpty`), and the CFURLRef-then-
CFStringRef decode order in `readURL`.

## Test results

`swift test` from `Packages/OpenClickyContextService`:

* Total: 67 tests, 0 failures, 1 skipped (the live-Safari probe skips
  because Safari is not running under the CI harness).
* Time: ~2.94 s.
* New `BrowserURLCaptureTests` suite: 8 cases, 7 pass, 1 skip
  (`test_capture_returnsURL_whenSafariIsFrontmostWithPage` skipped by
  design — `XCTSkipIf` gates on Safari runtime state and the
  `OPENCLICKY_SKIP_UI_TESTS` env var).

Cases exercised:
* Nil / 0 / negative / `Int32.max` pids -> nil.
* Current test-host pid -> nil (walk terminates cleanly on a real
  non-browser process).
* `BrowserURLInfo` JSON round-trip.
* Verbatim URL preservation for `chrome://newtab/`, `favorites://`,
  URLs with credentials, and `file://` URLs with fragments — matches
  Everywhere's no-normalisation contract.

## sign-and-install result

`bash scripts/sign-and-install.sh` last five lines:

```
** BUILD SUCCEEDED **

  built: .../DerivedData/.../OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
  .../OpenClicky.app: replacing existing signature
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=23264  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Xcode-driven build + codesign path succeeds. The package builds cleanly
inside the app target with the new `BrowserURLCapture.swift` and the
appended `BrowserURLInfo` type.

## Doc fix

None required. `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 9
already reads:

> | 9 | BrowserURL (AX AXURL walk) | `MacBrowserUrlReader.cs` | `Capture/BrowserURLCapture.swift` | P0 |

which matches source, target path, and algorithm exactly. Nothing to
update in the roadmap for this phase.

One future-facing note flagged but not acted on: the `RouterContext`
sketch on line 108 of the roadmap uses `browserURL: URLInfo?`; this
port names the return type `BrowserURLInfo` (parity with sibling
`FrontmostAppInfo` / `ClipboardInfo`). RouterContext is not yet
implemented, so no doc change is due until it lands.

## Known limitations

Browsers that `MacBrowserUrlReader.cs` does **not** cover, but that we
may want to support later:

* **Firefox** without `AXManualAccessibility` opt-in. Firefox hides its
  full AX tree by default; users must set the accessibility service
  attribute per-app before `AXURL` is exposed. Row 20 of the layer 0
  roadmap already tracks `AXManualAccessibility flip` as a P1 capture
  under `AXQuirksInstaller.swift`; once that lands, Firefox will start
  returning URLs automatically through the code we just ported.
* **AppleScript-only tab enumeration**. Some browsers (Arc, older
  Vivaldi builds) publish `AXURL` inconsistently but expose their
  active tab via AppleScript. The dedicated `BrowserTabsCapture.swift`
  (roadmap row 10, P1) will cover that path — it is not the concern of
  BrowserURL.
* **Private / incognito windows** in Chrome and Safari usually still
  publish `AXURL`, but in Guest Session mode Chrome sometimes reports
  `chrome://newtab/` even when a real URL is loaded. Everywhere
  inherits that behaviour; the port does too. No workaround exists at
  the AX layer.
* **Password auto-fill overlays** may briefly focus a system UI element
  outside the browser's process; the walk correctly returns nil in
  that transient state instead of falsely reporting the previous
  page's URL.
