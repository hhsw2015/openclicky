# Phase 1 — Clipboard port report (2026-07-22)

## Files created / modified

- **Created**: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ClipboardCapture.swift`
- **Created**: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/ClipboardCaptureTests.swift`
- **Modified**: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift` (appended `ClipboardInfo`; existing `FrontmostAppInfo` untouched)
- **Created (notes)**: `docs/ROADMAP/.impl-notes/phase1-clipboard-2026-07-22.md`

Files intentionally NOT touched (owned by other agents): `Capture/FrontmostAppCapture.swift`, `Tests/…/FrontmostAppCaptureTests.swift`.

## Everywhere reference

- Path: `~/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacClipboardReader.cs`
- Rev: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Line count: 59
- Consumers reviewed: `GetClipboardTool.cs`, `ClipboardTools.cs` (both call `IClipboardReader.GetText()` and treat `null` as empty).

## Alignment audit (side-by-side)

| Concern | Everywhere (MacClipboardReader.cs) | openclicky port |
|---|---|---|
| Pasteboard source | `+[NSPasteboard generalPasteboard]` via msgSend | `NSPasteboard.general` (same underlying selector) |
| Type constant | `"public.utf8-plain-text"` | `NSPasteboard.PasteboardType.string` (rawValue == same UTI) |
| Read method | `-[NSPasteboard stringForType:]` | `pasteboard.string(forType: .string)` (same selector) |
| changeCount | Never read | Never read |
| Writes | None | None |
| Null / empty return | `null` for empty / non-text / any failure | `ClipboardInfo?` -> `nil` for empty / non-text; text-only present -> non-nil info with `text` populated |
| Empty-string case | Returns `""` when pasteboard has `.string` = `""` | Returns `ClipboardInfo(text: "")` (test `test_capture_reflectsUpdates_betweenCalls` asserts) |
| Error handling | try/catch, return null | AppKit call has no `throws`; nil-guard mirrors C# `return null` path |
| Comment preserved | "NSPasteboardTypeString is the constant @\"public.utf8-plain-text\" but historically NSStringPboardType also resolves; pass the modern UTI." | Preserved verbatim in file header |

Signature semantics: Everywhere exposes `string?`; openclicky exposes `ClipboardInfo?` where `text` carries the same information. The optional-of-struct shape leaves room for the P1 fields without breaking the P0 contract.

## Test results

`cd Packages/OpenClickyContextService && swift test`

- Exit: 0
- Suites executed: 4 (AppKeyResolverTests, ClipboardCaptureTests, ClipboardInfoTests, FrontmostAppCaptureTests)
- Cases executed: **19**, failures: **0**, skipped: 0
- New cases in this port: 6 (ClipboardCaptureTests x4, ClipboardInfoTests x2)

Output tail:

```
Test Suite 'All tests' passed at 2026-07-22 22:23:48.565.
	 Executed 19 tests, with 0 failures (0 unexpected) in 1.316 (1.323) seconds
```

Test coverage:
- Empty pasteboard -> `nil`
- Text-only round trip -> `ClipboardInfo.text` matches
- Content changes between calls (including empty-string case)
- Non-string content only (TIFF blob) -> `nil`
- `ClipboardInfo` JSON round trip (text-only and nil-text variants)

Tests self-guard via a sentinel probe (`requireLivePasteboard`) so headless CI skips instead of failing. Each test saves and restores the developer's original pasteboard in `setUp`/`tearDown`.

## sign-and-install.sh result

Passed. Tail:

```
[0/5] verify cert exists in login keychain
[1/5] xcodebuild

** BUILD SUCCEEDED **

  built: …/Debug/OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=18616  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Main app builds cleanly with the new module additions.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 13 lists the target as
"Clipboard (text/file/image/rtf) -> P0 (text), P1 (others)". Everywhere's
reader only implements the text portion; the P1 fields are legitimate
openclicky-side extensions. **No divergence, no doc edit required.**

## Known deferrals (P1 fields not yet implemented)

All three P1 fields are declared on `ClipboardInfo` with `TODO(P1)` markers and are always emitted as `nil` today:

- `filePaths: [String]?` — will read `NSPasteboard.PasteboardType.fileURL`
- `imageData: Data?` — will read `.tiff` / `.png`
- `rtfData: Data?` — will read `.rtf`

Everywhere itself does not implement these — porting them is a strict openclicky extension. Callers can rely on them being `nil` until a follow-up phase turns them on.
