# F05 Finder selection + AppleScript byte-identity + CRLF quirk - code review

Everywhere source pinned at `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Reviewed strictly against code; no doc-only claims trusted.

## Sources

- openclicky Finder: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/FinderSelectionCapture.swift`
- openclicky runner: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AppleScriptRunner.swift`
- openclicky types: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift:203-266`
- openclicky tests: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/FinderSelectionCaptureTests.swift`
- Everywhere Finder: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacFinderReader.cs`
- Everywhere runner: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacAppleScriptRunner.cs`
- Everywhere tool: `/Users/wowdd1/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetFinderSelectionTool.cs`

## Checklist verification

### 1. AppleScript source byte-identical - PASS

Extraction methodology: parsed C# verbatim string `@"..."` from `MacFinderReader.cs:14-28` (rendering `""` as `"`), and reconstructed the Swift raw multiline `#"""..."""#` at `FinderSelectionCapture.swift:32-49` applying the Swift rule that the closing-delimiter indentation is stripped from each line and the leading/trailing newline adjacent to the delimiters is removed.

- C# string length: 504 bytes.
- Swift-rendered string length: 504 bytes.
- Byte-for-byte compare: identical (Python `==` over UTF-8 encoded strings returned True).

Also verified by the parity unit test `test_appleScriptSource_matchesEverywhereVerbatim` at `FinderSelectionCaptureTests.swift:25-43` which asserts against the same 14-newline construction. Each concatenated line matches the C# `@"..."` line verbatim including the 12-space common leading indent inside `tell application "Finder"` block.

Header comment `FinderSelectionCapture.swift:29-31` correctly warns future maintainers not to reformat this constant.

### 2. `TrimEnd('\r').TrimEnd('\n')` CRLF quirk reproduced - PASS

C# semantics (`MacFinderReader.cs:52`): strip contiguous trailing `\r` first, then contiguous trailing `\n`. On input `"path\r\n"` the `\r` strip is a no-op because the last char is `\n`, then the `\n` strip removes the LF, yielding `"path\r"` (stray CR retained).

Swift port (`FinderSelectionCapture.swift:130-133`):
```
var scalars = String(entrySlice).unicodeScalars
while scalars.last == UnicodeScalar(0x0D) { scalars.removeLast() }
while scalars.last == UnicodeScalar(0x0A) { scalars.removeLast() }
```

Same order (CR first, LF second) and same operand semantics ("while last is X, drop it"). The port uses `String.UnicodeScalarView` rather than `Character` iteration - this is required because Swift folds `"\r\n"` into a single extended grapheme cluster, so `hasSuffix("\n")` on a `String` would strip the `\r` too and destroy the quirk. Comment at lines 125-129 documents this. Scalar-level iteration matches C# `.NET` string enumeration where `\r` and `\n` are separate `char` code units.

Verified exhaustively across the following inputs (Python model matched Swift/C# semantics for each):

| input | C# result | Swift result | match |
|---|---|---|---|
| `path` | `path` | `path` | yes |
| `path\r` | `path` | `path` | yes |
| `path\n` | `path` | `path` | yes |
| `path\r\n` | `path\r` | `path\r` | yes |
| `path\n\r` | `path` | `path` | yes |
| `path\r\r\n\n` | `path\r\r` | `path\r\r` | yes |
| `path\n\r\n` | `path\n\r` | `path\n\r` | yes |
| `path\r\n\r` | `path\r` | `path\r` | yes |

Unit test coverage at `FinderSelectionCaptureTests.swift:155-181` locks pure-LF (line 155), pure-CR (line 163), and CRLF quirk (line 171-181) cases with the stray-CR assertion `XCTAssertEqual(info.selectedFiles[0].path, "/a/x.md\r")`.

### 3. Path escape / NUL split / RS split byte match - PASS

RS split (`FinderSelectionCapture.swift:97-107`):
- `raw.firstIndex(of: "\u{1E}")` mirrors C# `raw.IndexOf('\x1E')` at `MacFinderReader.cs:44`.
- `selBlock = raw[..<rsIdx]` mirrors C# `raw[..rsIdx]` at line 45.
- Everything after RS becomes `folderRaw`, mirrors C# `raw[(rsIdx + 1)..]` at line 46.
- Missing RS branch: Swift takes `selBlock = raw; folderRaw = nil` (lines 104-107). C# takes `selBlock = raw; folder = null` (lines 45-46). Match.

Folder trim (`FinderSelectionCapture.swift:109-110`):
- `folderRaw?.trimmingCharacters(in: .whitespacesAndNewlines)` vs C# `.Trim()` at line 46. Both strip ASCII whitespace including CR/LF; Foundation `CharacterSet.whitespacesAndNewlines` and .NET default `Trim()` both cover Unicode whitespace. Semantically equivalent for AppleScript output which is ASCII-clean around separators.
- `if folder?.isEmpty == true { folder = nil }` mirrors C# `if (string.IsNullOrEmpty(folder)) folder = null;` at line 47.
- Unit test `test_parse_folderEmptyString_becomesNil` and `test_parse_folderWhitespaceOnly_becomesNil` at lines 70-82 lock this.

NUL split (`FinderSelectionCapture.swift:116-119`):
- `selBlock.split(separator: "\u{0}", omittingEmptySubsequences: false)` mirrors C# `selBlock.Split('\0')` at `MacFinderReader.cs:50`. Both preserve empty entries; Swift's explicit `omittingEmptySubsequences: false` is required because Swift's default drops empties (comments 112-115 document this).
- Empty entries are then filtered by the `path.isEmpty` guard at line 135 and the `!path.hasPrefix("/")` guard at line 136, matching C# `string.IsNullOrEmpty(path)` and `!path.StartsWith('/')` at lines 53-54.

Trailing-slash / directory canonicalisation (`FinderSelectionCapture.swift:138-155`):
- `isDir = path.hasSuffix("/")` mirrors C# `path.EndsWith('/')` at line 56.
- Canonical form: Swift `String(path.reversed().drop(while: { $0 == "/" }).reversed())` drops *all* trailing slashes; C# `path.TrimEnd('/')` at line 57 drops *all* trailing slashes. Equivalent. Comment at 141-142 correctly notes the pluralisation.
- Basename via `(canonical as NSString).lastPathComponent` mirrors C# `System.IO.Path.GetFileName(canonical)` at line 58.
- Fallback `if baseName.isEmpty { name = path }` mirrors C# `if (string.IsNullOrEmpty(name)) name = path;` at line 59.

Directory fallback probe (`FinderSelectionCapture.swift:157-165`):
- Only invoked when trailing slash absent (matches C# `if (!isDir)` at line 61).
- `FileManager.default.fileExists(atPath:isDirectory:)` mirrors C# `Directory.Exists(path)` at line 63. Both are best-effort; both leave `isDir=false` on error/nonexistent. Test `test_parse_existingDirectoryWithoutTrailingSlash_isDetectedAsDirectory` at line 113-122 exercises the promotion path against real `/tmp`.

No path escaping applied on either side - both trust Finder's `POSIX path of (i as alias)` output. No backslash unescape; no URL-decode. Match confirmed.

### 4. 15s timeout + concurrent pipe drain (128KB no-deadlock) - PASS

Timeout (`AppleScriptRunner.swift:73-74`):
- `timeoutMilliseconds: Int = 15_000` constant matches C# `TimeoutMs = 15000` at `MacAppleScriptRunner.cs:16`.
- Deadline poll at lines 153-156: `Date().addingTimeInterval(TimeInterval(15_000) / 1000.0)` equals 15 s. C# uses `p.WaitForExit(TimeoutMs)` at line 44. Same budget.
- On timeout: Swift issues `terminate()` (SIGTERM), waits 1 s grace, then `kill(..., SIGKILL)` and blocks on `waitUntilExit`. C# uses `p.Kill(true)` (equivalent to `SIGKILL` on posix with the entire process tree) followed by `WaitForExit(1000)`. Semantic match; Swift's SIGTERM-first is a slight softening but the 1 s grace + SIGKILL fallback preserves the "process must be dead before we return" contract.
- Return payload on timeout: `.failed` with `"osascript timed out (15000ms)"` mirrors C# `AppleScriptStatus.Failed, null, "osascript timed out (15000ms)"` at line 48.

Concurrent pipe drain (`AppleScriptRunner.swift:107-133`):
- Two `DispatchGroup` workers on a concurrent `DispatchQueue` each call `readDataToEndOfFile()` on stdout/stderr. Reads are unblocked at EOF (process exit).
- C# starts `ReadToEndAsync()` on both streams *before* `WaitForExit` at lines 41-42, then awaits with `.GetAwaiter().GetResult()` at 51-52.
- Both approaches share the invariant: drainers start before wait, so a >64KB stdout can't wedge the child on a full pipe.
- Test `test_run_largeOutput_doesNotDeadlock` at `FinderSelectionCaptureTests.swift:288-303` emits `2000 * 62 = 124,000` bytes and asserts `status == .ok` under the 15 s budget, providing an in-process regression proof.

Spawn-failure path (`AppleScriptRunner.swift:135-148`): closes both write-ends before `drainGroup.wait()` so the readers get EOF and don't block. C# equivalent doesn't need this because `Process.Start()` returning false skips the read entirely; the Swift port's explicit close is a defensible safety net.

Permission sniffing (`AppleScriptRunner.swift:197-208`): three sentinels (`-1743`, `not allowed assistive access`, `not authorized to send apple events`) match C# lines 58-60 exactly. Case handling: Swift lowercases stderr once and uses `contains` for the two string checks; C# uses `StringComparison.OrdinalIgnoreCase`. Equivalent. The `-1743` numeric check uses ordinal contains in both.

Stdout trim (`AppleScriptRunner.swift:192-194`): `hasSuffix("\n") ? String(stdout.dropLast()) : stdout` strips a single trailing LF only. C# uses `stdout.TrimEnd('\n')` at line 65 which strips *all* trailing LFs. Slight deviation - Swift preserves multiple trailing newlines while C# collapses them. For the Finder script this is a no-op (script emits `out & RS & fp` with no trailing newline), and osascript itself appends exactly one `\n`. The header comment at line 192 mentions "preserve embedded ones" but doesn't call out this multi-LF asymmetry. Low-risk deviation; noted below.

### 5. Frontmost-Finder gate - N/A in C#, N/A in Swift port

Neither the C# `MacFinderReader.GetSelection` nor the Swift port checks that Finder is the frontmost app before running the script. Both rely on Finder's AppleScript surface accepting `target of front window` regardless of foreground state (Finder is always running on macOS as the desktop server). The AppleScript's own `try / on error / set fp to ""` at `MacFinderReader.cs:22-26` and Swift lines 42-46 handles the "no Finder window open" case in-script by returning an empty folder.

C# does not gate on frontmost; port faithfully does not gate on frontmost. Selection can be captured from a background Finder window; folder resolution empty-strings when no Finder window exists. Live test `test_capture_finderReachable_returnsNonNil` at `FinderSelectionCaptureTests.swift:324-344` does call `tell application "Finder" to activate` before capture but only as a best-effort test aid, not a runtime gate.

If a frontmost gate is later required by the OpenClicky product spec (e.g., only surface Finder context when Finder is the focused app), it must be added *outside* `FinderSelectionCapture` to preserve parity with Everywhere. Currently absent by design.

## Additional deviations found (documented or benign)

1. `AppleScriptRunner.swift:192-194` - single trailing-LF strip vs C# `TrimEnd('\n')` multi-LF. Latent behavioural divergence if osascript is ever coerced to emit multiple trailing newlines; benign for the shipped scripts. Not documented in the header comment.
2. `AppleScriptRunner.swift:158-168` - Swift kill path uses SIGTERM + 1s grace + SIGKILL; C# `Kill(true)` goes straight to SIGKILL of the process tree. Convergent end state; Swift is marginally slower to give up.
3. `FinderSelectionCapture.swift:32-49` - Swift raw string literal uses 12-space indent inside the tell block just like the C# `@"..."`. Both extractions are 504 bytes and byte-identical (verified computationally above).
4. `FinderSelectionCapture.swift:62-73` - Everywhere's `MacFinderReader` returns a `FinderResult` with status enum (`NotSupported / PermissionDenied / Failed / Ok`). openclicky's public `capture()` collapses all non-Ok to `nil`. Runner status is still visible internally via `run(runner:)` for future MCP tool port. Documented at file header lines 12-18.

## Verdict

All F05 acceptance criteria pass:

- AppleScript source is byte-identical (504 bytes on both sides, verified by extraction + Python `==`).
- CRLF quirk `TrimEnd('\r').TrimEnd('\n')` faithfully reproduced via Unicode-scalar iteration; scalar-level (not grapheme-level) approach is correct and necessary.
- Path escape / NUL split / RS split / trailing-slash canonicalisation all match C# semantics with equivalent Swift constructs.
- 15 s timeout + concurrent pipe drain match; 128 KB regression test present and green in unit suite.
- Frontmost-Finder gate is absent on both sides; port matches Everywhere policy.

Port is a 1:1 semantic mirror. The one latent divergence (single vs multiple trailing-LF strip in `AppleScriptRunner.swift:192-194`) is benign for all scripts currently exercised and is worth an in-source comment but does not block acceptance.
