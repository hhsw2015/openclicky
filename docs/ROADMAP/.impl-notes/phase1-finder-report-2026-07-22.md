# Phase 1 — Finder selection port (report)

## Files created

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FinderSelectionCapture.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AppleScriptRunner.swift` (new — reusable by later browser / terminal ports)
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/FinderSelectionCaptureTests.swift`
- `docs/ROADMAP/.impl-notes/phase1-finder-2026-07-22.md` (investigation notes)

## Files modified

- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - Added public `FinderItem` (Codable/Sendable/Equatable) matching doc row 11.
  - Added public `FinderSelectionInfo` (Codable/Sendable/Equatable).

## Files intentionally NOT touched (other agents)

`FrontmostAppCapture.swift`, `FrontmostAppCaptureTests.swift`, `ClipboardCapture.swift`, `IdleTimeCapture.swift`.

## AppleScript source (verbatim, unit-test enforced)

```applescript
tell application "Finder"
            set NUL to (ASCII character 0)
            set RS to (ASCII character 30)
            set sel to selection
            set out to ""
            repeat with i in sel
                set out to out & POSIX path of (i as alias) & NUL
            end repeat
            try
                set fp to POSIX path of ((target of front window) as alias)
            on error
                set fp to ""
            end try
            return out & RS & fp
        end tell
```

Byte-identical to `Everywhere/src/Everywhere.Mac/Mcp/MacFinderReader.cs` `Source`. Enforced by `test_appleScriptSource_matchesEverywhereVerbatim`.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` (lines 114-124) already specified:

- `FinderSelectionInfo.currentFolder: String?`, `selectedFiles: [FinderItem]`
- `FinderItem.path: String`, `name: String`, `isDirectory: Bool`, `kindHint: String?`

Everywhere's core `FinderItem` record omits `kindHint`; the mapping lives in the MCP tool layer (`GetFinderSelectionTool.KindHintFromExtension`). Decision: keep the doc as-is and eagerly populate `kindHint` at capture time. Rationale documented in `phase1-finder-2026-07-22.md`. No doc edits needed — the spec already matched what the port would produce.

## Public API

```swift
public enum FinderSelectionCapture {
    public static func capture() async -> FinderSelectionInfo?
}
```

Nil return covers: TCC/Apple-Events denial, osascript spawn failure, `NotSupported`, 15 s timeout. Non-nil with empty `selectedFiles` covers "Finder reachable but nothing selected" (still legit context).

Internal `capture(runner:)` overload accepts any `AppleScriptRunning` for DI/testing.

## AppleScriptRunner

Companion type (`AppleScriptRunner` + `AppleScriptRunning` protocol + `AppleScriptResult` + `AppleScriptStatus` enum). Contract mirrors `MacAppleScriptRunner`:

- `/usr/bin/osascript -e <source>` subprocess (not `NSAppleScript` — keeps TCC scope identical to Everywhere's runtime prompt).
- 15 000 ms timeout, matching the C# constant.
- Concurrent stdout / stderr drain avoiding the >64KB PIPE deadlock.
- Permission sniffing: `-1743`, `not allowed assistive access`, `not authorized to send Apple events`.

Next agents porting `BrowserURLReader` / `BrowserTabsReader` / `TerminalScrollback` should reuse `AppleScriptRunner.shared` rather than re-implementing.

## Alignment audit

| Concern | Everywhere behavior | Swift port | Match |
|---|---|---|---|
| AppleScript source | verbatim string | verbatim string (test-enforced) | yes |
| Separator bytes | NUL between items, RS before folder | same | yes |
| Folder empty -> null | yes | yes | yes |
| Split on NUL | yes | yes | yes |
| Trim `\r` then `\n` | `TrimEnd('\r').TrimEnd('\n')` | Unicode-scalar loop preserving that order (test-covered — the CR/LF quirk is asserted) | yes |
| Reject empty entries | yes | yes | yes |
| Reject non-`/`-prefixed entries | yes | yes | yes |
| `isDir` from trailing `/` | yes | yes | yes |
| `isDir` filesystem fallback | `Directory.Exists`, swallow errors | `FileManager.fileExists(_:isDirectory:)`, swallow errors | yes |
| Name fallback | filename → path | filename → path | yes |
| Failed status mapping | `Failed` maps to `PermissionDenied` in Reader; both bubble as no-data at MCP surface | `.failed` returns nil (no permission distinction at public surface) | acceptable — internal path preserves the distinction for the future MCP port |
| Runner timeout | 15 000 ms | 15 000 ms | yes |
| Permission sniff strings | `-1743`, `not allowed assistive access`, `not authorized to send Apple events` | same | yes |
| Empty script guard | `IsNullOrWhiteSpace` -> Failed | same | yes |

## Test results

`cd Packages/OpenClickyContextService && swift test` — **passed**.

- FinderSelectionParserTests: 22 tests (parser + kindHint + JSON round-trip). All pass.
- FinderSelectionCaptureStubbedTests: 4 tests (permissionDenied → nil, failed → nil, ok+empty, ok+selection).
- FinderSelectionCaptureLiveTests: 2 tests (skips gracefully when TCC blocks the probe; passes here — osascript prompt already granted).
- AppleScriptRunnerTests: 5 tests including `test_run_largeOutput_doesNotDeadlock` (128 KB stdout — verifies the pipe drain).

Total across the package: **57 passed / 0 failed** after the CR/LF grapheme fix.

## `sign-and-install.sh` result

```
** BUILD SUCCEEDED **
codesign with OpenClicky Dev Sign
open
  openclicky pid=21780  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
done.
```

Full end-to-end build passes with the new package additions.

## Notes for next agents

- `AppleScriptRunner` is public and safe to share. `AppleScriptRunning` protocol is the DI seam.
- `FinderSelectionCapture.parse` and `.kindHintFromName` are `internal` — test-visible via `@testable import`. Not part of the public capture API.
- The `.failed` → `nil` collapse loses the `permission_denied` distinction. When the MCP surface is ported (`GetFinderSelectionTool`), route through the `AppleScriptResult.status` directly rather than `FinderSelectionCapture.capture()`.
- The C# `TrimEnd('\r').TrimEnd('\n')` quirk that leaves a trailing `\r` when the input ends in `\r\n` is preserved and unit-test-asserted. Do not "fix" it without matching upstream.
- Grapheme-cluster gotcha: Swift's `String.hasSuffix("\n")` returns false when the last grapheme is `"\r\n"`. The port uses `unicodeScalars` to sidestep this.
