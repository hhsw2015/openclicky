# Phase 5 Terminal - port report (2026-07-22 / 2026-07-23)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/TerminalCapture.swift`
  - Public `enum TerminalCapture` with `static func capture(linesBack: Int = 200) async -> TerminalOutputInfo?`.
  - Ported constants: `defaultLinesBack=200`, `maxLinesBack=10_000`, `averageLineCapBytes=200`.
  - Ported terminal substring list verbatim (term / iterm / ghostty / warp / alacritty / kitty / konsole / xterm).
  - Reuses `AppKeyResolver.fromProcessId` for the terminal heuristic guard.
  - Reads `AXValue` on the two-step-resolved focused element (same pattern as sibling captures).
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/TerminalCaptureTests.swift`
  - 17 XCTest cases: 10 for `looksLikeTerminal(appKey:)` matrix, 1 constants-parity, 3 JSON round-trip / wire-key stability, 2 `capture()` headless-safe behaviour, 1 gated live-terminal probe.

## Files modified

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Appended `TerminalOutputInfo` (Codable, Equatable, Sendable) with snake_case wire keys `is_terminal` / `lines_returned` / `text` matching Everywhere's C# JSON envelope.

## Notes files

- `docs/ROADMAP/.impl-notes/phase5-terminal-2026-07-22.md` - investigation.
- `docs/ROADMAP/.impl-notes/phase5-terminal-report-2026-07-22.md` - this report.

## Ground-truth alignment audit

`GetTerminalOutputTool.cs @30e03e9d` side-by-side:

| C# behaviour | Swift port |
| --- | --- |
| `Math.Clamp(lines_back ?? 200, 1, 10_000)` | `max(1, min(linesBack, 10_000))` |
| `focused is null || !LooksLikeTerminal(focused)` -> `{is_terminal:false, lines_returned:0, text:""}` | Same envelope emitted; `nil` reserved for no-frontmost-app case. |
| `focused.GetText(maxLength: maxLines*200) ?? ""` | `readAXText(focused, maxLength: maxLines*200) ?? ""` |
| `text.Split('\n')` -> `[""]` for empty text | `split(separator:"\n", omittingEmptySubsequences:false)` on empty -> `[""]` |
| `lines[^maxLines..]` when overflow | `Array(allLines.suffix(maxLines))` |
| `{is_terminal:true, lines_returned: slice.Length, text: join}` | Same fields via `TerminalOutputInfo` + snake_case CodingKeys. |
| `LooksLikeTerminal` walks parent chain then `AppKey.FromProcessId(top.ProcessId)` | Simplified: reads pid off frontmost app and calls `AppKeyResolver.fromProcessId(pid)` - equivalent because AppKey resolves purely from pid, not from the AX element. |
| Substring needles: `term`, `iterm`, `ghostty`, `warp`, `alacritty`, `kitty`, `konsole`, `xterm` (case-insensitive) | Same array, same case-insensitive `contains` match. |
| Exception path -> `ToolErrors.FromException` (MCP error result) | Any AX failure -> `nil` (documented deviation; capture APIs cannot signal error through envelope by design). |

Explicit deviations (documented in file header):

1. Error signalling: nil instead of MCP error envelope (mandated by capture API convention).
2. Text-length cap uses `String.count` (grapheme clusters) not UTF-16 units. Safer against splitting inside a grapheme; only differs for terminals with emoji / RTL / combining marks.
3. Empty-string cap edge case: when AX returns "" the port returns nil from `readAXText`, but `capture()` still emits `{is_terminal:true, lines_returned:1, text:""}` because C# `"".Split('\n').Length == 1` is preserved by the split-on-`""` step upstream.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 12:

> 12 | TerminalScrollback | `GetTerminalOutputTool.cs` | `Capture/TerminalCapture.swift` | P1

Source path, target file, priority all match. No doc edit needed.

## Test result

```
cd Packages/OpenClickyContextService && swift test --filter TerminalCaptureTests
...
Test Suite 'TerminalCaptureTests' passed
Executed 17 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.005 seconds
```

Full package regression:

```
cd Packages/OpenClickyContextService && swift test
...
Test Suite 'All tests' passed
Executed 272 tests, 4 tests skipped and 0 failures (0 unexpected) in 12.619 seconds
```

All 272 tests pass (17 new + 255 pre-existing).

## Build result

```
cd /Users/wowdd1/Dev/openclicky && bash scripts/sign-and-install.sh
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
** BUILD SUCCEEDED **
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=99837  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Signed and installed cleanly.

## Constraints met

- Target file present at `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/TerminalCapture.swift`.
- Tests file present at `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/TerminalCaptureTests.swift`.
- File header contains `// Ported from Everywhere: src/Everywhere.Mcp/Tools/GetTerminalOutputTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809`.
- `TerminalOutputInfo` appended to `Types/CaptureTypes.swift` (only that file touched besides the new capture + tests).
- No other capture files modified.
- Public API is `TerminalCapture.capture(linesBack: Int = 200) async -> TerminalOutputInfo?` exactly.
- `AppleScriptRunner` reuse: the C# implementation itself does NOT use AppleScript (it reads AX), so this port also does not - matches source, and no runner invocation is needed.
