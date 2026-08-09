# Phase 1 SelectedText — investigation notes (2026-07-22)

## Sources
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs` @30e03e9d — 416 lines
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/SelectionCache.cs`
- `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetSelectedTextTool.cs`

## What `VisualElementContext.TextSelection.cs` actually contains

Two responsibilities coexist in one file:

1. `TextSelectionDetector` (lines 60-416): a reactive mouse-hook monitor
   that fires `SelectionDetected` when the user completes a selection
   gesture (drag / double-click / shift-click while cursor is I-beam).
   NOT ported in openclicky Phase 1 — openclicky pulls on demand.
2. Static helpers `GetTextViaAXAPI` (234-268) and
   `GetTextViaClipboardAsync` (270-316): the actual three-strategy
   selected-text extraction. THIS is what openclicky ports.

## Three strategies, verbatim from source

### Strategy 1 — AX on focused element
Lines 244-249:
```csharp
// Strategy 1: Try to get selected text from the focused element
var text = focusElement.GetSelectionText();
if (!string.IsNullOrEmpty(text)) return text;
```
`GetSelectionText()` reads `AXSelectedText` on the focused UI element.
Focus lookup is `AXFocusedUIElement` on the app AX element, falling
back to `AXFocusedWindow` (lines 238-242).

### Strategy 2 — walk immediate children
Lines 251-259:
```csharp
// Strategy 2: If the focused element doesn't have selected text,
// try to traverse child elements
foreach (var child in focusElement.Children)
{
    text = child.GetSelectionText();
    if (!string.IsNullOrEmpty(text)) return text;
}
```
NOTE: single-level children only, no recursion. Reads AXChildren
attribute of the focused element.

Also lines 261-267 flip Chrome/Chromium's `AXEnhancedUserInterface`
and Electron's `AXManualAccessibility` to `true` before returning
null (side-effect that lets the NEXT invocation see the AX tree).

### Strategy 3 — clipboard Cmd-C fallback
`GetTextViaClipboardAsync` (270-316):
1. Read current `NSPasteboard.changeCount` (line 273).
2. If `changeCount` already differs from the pre-mousedown snapshot
   (`_clipboardSequence`), user just copied — read directly and return.
   In openclicky's on-demand port we don't have a pre-mousedown
   snapshot to compare against, so we skip this early-exit.
3. Snapshot original clipboard string (line 286).
4. `SendCopyKeyAsync(pid)` (318-338): synthesize Cmd+C key down,
   sleep 5ms, key up. Uses `CGEvent.PostToPid(pid)` when pid>0,
   else `CGEvent.Post` at `.hid`.
5. Poll loop (299-307): 10 iterations, 10ms each = **max 100ms**.
   Each iteration reads `changeCount`; when it changes vs. the value
   captured at line 273, read pasteboard string, break.
6. Restore original clipboard content (309-313) via `WriteClipboard`
   which uses `NSPasteboard.clearContents` + `setString`.

Restoration is a plain `if !string.IsNullOrEmpty(original) WriteClipboard(original)`.
No item-level type preservation — only the string type is snapshotted
and restored. If clipboard had e.g. image + text, restore keeps only
the text component. openclicky should IMPROVE this by round-tripping
all pasteboard items, since the Swift `NSPasteboardItem` API supports
it cleanly.

## Cache — `SelectionCache.cs`

- TTL: `TimeSpan.FromMinutes(2)` (line 14, `public static readonly TimeSpan Ttl`)
- Single-slot cache: `_text`, `_appKey`, `_capturedAtUtc`.
- Populated by `IObserver<TextSelectionData>.OnNext` from the mouse
  hook Subject in `VisualElementContext.TextSelection.cs`. Not keyed
  by anything — most recent non-empty selection wins.
- Key composition for consumers: `AppKey.FromProcessId(element.ProcessId)`
  captured alongside text; consumers do not hash text, they just return
  the stored (Text, AppKey) tuple.
- Emitted with `source = "cache"` in `GetSelectedTextTool.cs:31`.
- Emitted with `source = "focused"` in `GetSelectedTextTool.cs:42`
  for the live path.

Task-spec deviation: task says "keyed by (app, selection text hash)".
Source does not do this. Match the source — single-slot most-recent.

## Password field detection

Source does NOT skip password fields explicitly. `AXSecureTextField`
does not expose `AXSelectedText`, so Strategy 1 already returns nil
for it. However Strategy 3 (Cmd-C) would still fire and reveal the
password to the clipboard. openclicky ADDS an explicit skip for
`AXRole == AXSecureTextField` before Strategy 3.

## RTL / emoji

No special handling in source. Returned string is passed through as
UTF-16 from CFString. Swift port also passes through as `String`
(UTF-8 semantics, grapheme-safe). No truncation, no normalisation.

## Threading

Everywhere invokes `GetTextViaAXAPI` from a `Task.Run` continuation
(line 202). macOS AX API is thread-safe (documented in
`AXUIElement.h`), so it works. openclicky uses `MainActor.run` for
the AX calls per project-CLAUDE.md constraint ("AX API MUST be on
main thread"). Cmd-C poll sleeps happen off-main via `Task.sleep`.

## Nil / empty return

Source returns:
- `null` if focus lookup fails
- `null` from AX strategies if all three yield empty
- The captured text (may be `""` per line 286 semantics) on success

openclicky lifts `""` to `nil` because SelectedTextInfo's `text`
field is non-optional String, and reporting an empty selection as a
valid capture makes no semantic sense.

## Openclicky API shape

```swift
public enum SelectedTextCapture {
    public static func capture() async -> SelectedTextInfo?
}
```

Async because Strategy 3 sleeps up to 100ms. Callers already do
`await frontmostApp()` etc. so parity across capture APIs.

`SelectedTextInfo` (already in doc 01, keep matching):
```swift
public struct SelectedTextInfo {
    let text: String
    let source: SelectedTextSource   // .ax | .child | .clipboardCmdC | .cache
    let sourceApp: String?           // AppKey.FromProcessId output
    let length: Int                  // text.count (grapheme-cluster count)
}
```
