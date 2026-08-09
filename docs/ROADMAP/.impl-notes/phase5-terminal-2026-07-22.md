# Phase 5 Terminal - investigation notes (2026-07-22)

## Ground truth

- Primary source: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetTerminalOutputTool.cs`
- Rev: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Line count: 83 lines
- Supporting: `src/Everywhere.Mac/Interop/AXUIElement.cs::GetText(maxLength)` (lines 549-574)
- Supporting: `src/Everywhere.Mcp/Snapshot/AppKey.cs::FromProcessId`

## What the tool does (in one paragraph)

Given a `lines_back` int (defaults 200, clamped to [1, 10_000]), it resolves
the focused UI element, guards with `LooksLikeTerminal`, reads the focused
element's text (bounded by `maxLines * 200` bytes), splits it by `\n`,
returns the trailing `maxLines` slice joined back with `\n`, wrapped in
`{is_terminal, lines_returned, text}`.

## Terminal detection heuristic (`LooksLikeTerminal`, lines 59-75)

1. Walk `element.Parent` chain up to the top-level element.
2. `key = AppKey.FromProcessId(top.ProcessId)` -> lowercased executable name.
3. Return `true` iff `key` case-insensitively contains ANY of:
   - `term`      (catches Terminal, gnome-terminal, Windows Terminal, iTerm2)
   - `iterm`     (redundant given `term` but preserved verbatim)
   - `ghostty`
   - `warp`
   - `alacritty`
   - `kitty`
   - `konsole`
   - `xterm`

Important: this is executable-NAME-based, NOT bundle-id-based. On macOS
`NSRunningApplication.executableURL.lastPathComponent.lowercased()` yields:
- Terminal.app -> `terminal` -> matches `term` ✓
- iTerm.app    -> `iterm2` or `iterm`  -> matches `term`/`iterm` ✓
- Ghostty.app  -> `ghostty` -> matches `ghostty` ✓
- Warp.app     -> `stable` (Warp's binary is called `stable`) -> DOES NOT match

Deviation note: the Warp case is a known false-negative in Everywhere.
Ported verbatim.

## The five-field return envelope (via `Json` helper, lines 46-51 & 77-81)

```json
{ "is_terminal": bool, "lines_returned": int, "text": string }
```

C# emits this via `JsonSerializer.Serialize`. openclicky's Swift port
carries the same three fields on `TerminalOutputInfo`, spelled
`isTerminal` / `linesReturned` / `text` at the Swift level and wired to
the C# JSON names via `Codable` `CodingKeys` for wire-level parity.

## `GetText(maxLength:)` semantics from AXUIElement.cs

`AXValue` on the focused terminal element carries the visible-buffer
text as a `CFString`. If `AXValue` is empty:
- C# returns null.
- On terminals with a genuinely empty buffer (freshly opened tab) the
  returned string is `""`; `String.IsNullOrEmpty("") == true` so C#
  returns null there too.

The `maxLength` bound is applied AFTER the read: `text.Length > maxLength ?
text[..maxLength] : text`. Note: C# `Length` is UTF-16 units, Swift's
`String.count` is grapheme clusters. For a scrollback that will typically
be ASCII this matches; for terminal buffers that carry emoji / RTL /
combining marks it differs by a few characters. openclicky uses
`String.count` (grapheme) so we do not slice inside a grapheme cluster.
Everywhere's byte / UTF-16 slicing is unsafe in this respect anyway.

## Empty-text edge case

C#: `"".Split('\n')` returns `[""]` (length 1). So an empty focused
terminal produces:
```json
{ "is_terminal": true, "lines_returned": 1, "text": "" }
```
NOT `lines_returned: 0`. openclicky must replicate this (verified in the
alignment audit and in the empty-terminal XCTest).

## Error handling

C# wraps the AX read in a try/catch that funnels to `ToolErrors.FromException`
(which builds an MCP error result). openclicky's `capture()` cannot signal
"error" through the return shape by design (per project convention that
capture APIs return `Optional`), so we surface any AX failure as `nil`.

## `LooksLikeTerminal` first-arg contract

`focused` is `IVisualElementContext.FocusedElement`. In Everywhere that
resolves to the app-level AX focused-UI-element with the standard two-step
lookup (`AXFocusedUIElement`, falling back to `AXMainWindow ->
AXFocusedUIElement`). openclicky replicates this exactly using the same
helper we already have for `BrowserURLCapture` / `SelectedTextCapture`.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 12:

> 12 | TerminalScrollback | `GetTerminalOutputTool.cs` | `Capture/TerminalCapture.swift` | P1

Source path, target file, and priority all match. No doc edit needed.

## Openclicky API shape

```swift
public struct TerminalOutputInfo: Codable, Equatable, Sendable {
    public let isTerminal: Bool     // json: "is_terminal"
    public let linesReturned: Int   // json: "lines_returned"
    public let text: String         // json: "text"
}

public enum TerminalCapture {
    public static func capture(linesBack: Int = 200) async -> TerminalOutputInfo?
}
```

`async` for parity with the rest of the capture APIs even though the
current body does not `await`. Future work can push AX reads through the
main-actor without an API break.

`nil` return: only when no frontmost app is resolvable (no login session /
loginwindow transition). "Frontmost is not a terminal" returns a non-nil
`TerminalOutputInfo` with `isTerminal: false`, matching Everywhere's
non-error JSON envelope contract.

## Testing plan (per task spec)

XCTest, all safe under `swift test`:

1. `linesBack` default & clamping: 200 default, `<= 0` clamps to 1, `> 10_000`
   clamps to 10_000. Assertions on the return-envelope invariant when a
   terminal is present.
2. Skip when no terminal running (`OPENCLICKY_SKIP_UI_TESTS` or when no
   `term|iterm|ghostty|...` process is found).
3. Empty Terminal buffer: `isTerminal == true`, `linesReturned == 1`,
   `text == ""` (matches `"".Split('\n').Length == 1` C# quirk).
4. Non-terminal frontmost: `capture()` returns a non-nil value with
   `isTerminal == false`, `linesReturned == 0`, `text == ""` (or `nil`,
   per task spec allowance).
5. `TerminalOutputInfo` JSON round-trip using snake_case wire keys.
6. `TerminalOutputInfo` snake_case wire keys are stable
   (`is_terminal`/`lines_returned`/`text`).
