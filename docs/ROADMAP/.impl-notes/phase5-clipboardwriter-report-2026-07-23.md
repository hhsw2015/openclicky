# Phase 5 — ClipboardWriter Port Report (2026-07-23)

Port of Everywhere `src/Everywhere.Mac/Mcp/MacClipboardWriter.cs` @30e03e9d
to Swift. Delivers the write side of the MCP `clipboard_write` /
`clipboard_copy` / `clipboard_paste` tools.

## Files added / modified

- **NEW** `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/ClipboardWriter.swift`
- **NEW** `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/ClipboardWriterTests.swift`
- **APPEND ONLY** `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
  - added `ClipboardWriteResult` struct
  - all existing types untouched
- **NEW** `docs/ROADMAP/.impl-notes/phase5-clipboardwriter-2026-07-23.md`

## Public API

```swift
public enum ClipboardWriter {
    @discardableResult
    public static func writeText(_ text: String) -> ClipboardWriteResult
    @discardableResult
    public static func simulatePaste() -> Bool  // ⌘V via CGEvent
    @discardableResult
    public static func simulateCopy() -> Bool   // ⌘C via CGEvent
}

public struct ClipboardWriteResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let bytes: Int  // UTF-8 byte count
}
```

## Alignment audit vs Everywhere source

| Everywhere `MacClipboardWriter.cs` | Swift `ClipboardWriter.swift` | Match |
|---|---|---|
| `+[NSPasteboard generalPasteboard]` | `NSPasteboard.general` | ✓ |
| `-[NSPasteboard clearContents]` | `pasteboard.clearContents()` | ✓ |
| type string `"public.utf8-plain-text"` (line 23) | `.string` (rawValue = same UTI) | ✓ |
| `declareTypes:owner:` then `setString:forType:` (invariant on lines 29-32) | `setString(_:forType:)` (AppKit handles declareTypes internally) | ✓ (semantic) |
| null input → `text ?? string.Empty` | Swift `String` is non-nullable | n/a |
| No return value (silent no-op) | `ClipboardWriteResult(ok:bytes:)` — surfaces AppKit's `Bool` return | tightened |
| `bytes = text.Length` (UTF-16 code units in `ClipboardTools.DoWrite`) | `bytes = text.utf8.count` (true wire byte count) | tightened |

Two tightenings called out in the file header + impl-notes:

1. `ok` field — Everywhere's `SetText` returns void and silently no-ops on
   failure. The Swift port surfaces `setString(_:forType:)`'s `Bool` result
   so `ClipboardWriteResult.ok` accurately reflects whether the pasteboard
   accepted the write.
2. `bytes` semantics — Everywhere's C# `ClipboardTools.DoWrite` reports
   `text.Length` (UTF-16 code units). Swift reports UTF-8 byte count so the
   number matches what actually went on the pasteboard.

## Divergences from Everywhere (documented)

Everywhere's `ClipboardTools.cs` aliases `clipboard_paste` to `clipboard_read`
and `clipboard_copy` to `clipboard_write`. openclicky diverges:

- `clipboard_paste` → `ClipboardWriter.simulatePaste()` (⌘V to frontmost app)
- `clipboard_copy` → `ClipboardWriter.simulateCopy()` (⌘C to frontmost app)

Rationale: SPEC ab browser-side `agent_browser_clipboard_paste` triggers the
active document's paste handler, and `agent_browser_clipboard_copy` copies
the current selection. Everywhere-side parity requires driving real
keystrokes rather than aliasing to read/write. Documented in the file
header block comment and in the impl-notes.

## Implementation details

- `simulatePaste` / `simulateCopy` post keydown + keyup CGEvent pairs under
  `.maskCommand` for virtual keycodes `0x09` (V) / `0x08` (C) via
  `.cghidEventTap`, with a 20ms `usleep` between the two events. Same
  pattern as `SelectedTextCapture.sendCopyKey` already in this package.
- Empty string is a valid payload: `writeText("")` returns
  `ClipboardWriteResult(ok: true, bytes: 0)`.

## Test results

10 new tests, all passing:

```
Test Suite 'ClipboardWriterTests' passed
    Executed 10 tests, with 0 failures (0 unexpected) in 0.122 (0.124) seconds
```

Coverage:

- `test_writeText_placesTextOnPasteboard`
- `test_writeText_replacesPriorContents`
- `test_writeText_bumpsChangeCount`
- `test_writeText_emptyString_isOKWithZeroBytes`
- `test_writeText_bytesReportsUTF8Length_ascii` (5 chars → 5 bytes)
- `test_writeText_bytesReportsUTF8Length_multibyte` ("日本語" → 9 bytes)
- `test_writeText_bytesReportsUTF8Length_emoji` (U+1F600 → 4 bytes)
- `test_writeText_oneMegabytePayload_isOK` (1 MiB round trip)
- `test_simulatePaste_postsWithoutCrashing` (CGEvent dry-run)
- `test_simulateCopy_postsWithoutCrashing` (CGEvent dry-run)

Plus 2 `ClipboardWriteResult` JSON envelope tests:

- `test_clipboardWriteResult_roundTripsJSON`
- `test_clipboardWriteResult_jsonKeys_matchEnvelope` — verifies
  `{ "ok": bool, "bytes": int }` matches Everywhere's `ClipboardTools.DoWrite`
  envelope keys.

Both `simulate*` tests XCTSkip when CGEvent allocation is denied (headless
CI / TCC Input Monitoring denied); the actual test host was able to
allocate and post the events, so they ran to completion.

Existing ClipboardCapture / SelectedTextCapture tests continue to pass —
`ClipboardWriter` shares no state with those paths.

## Non-goals

- No `IsAvailable()` surface — Swift binds `ClipboardWriter` at compile time,
  the AppKit calls cannot be absent at runtime. The C# equivalent existed
  because `IClipboardWriter` was DI-injected and could theoretically be a
  null-provider on a non-macOS host.
- No `Clear()` surface — no MCP tool calls it; `writeText("")` covers the
  "empty pasteboard" case Everywhere's `Clear()` served.
- Did NOT modify `ClipboardCapture.swift`, other capture files,
  `Package.swift`, stash / bridge / config-template / meta-tools / doc-readers
  / memory-store per the constraints.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 13 tracks the clipboard
capability at P0 (text) / P1 (other types). It scopes only the READ side
(`MacClipboardReader.cs`) — the writer surface is a Layer 2 MCP sensor
concern, not a Layer 0 capture concern. No row edits needed. The doc's
`ClipboardWriter.swift` mention would live under `03_LAYER_2_MCP_SENSOR.md`
if we ever grow a per-file index there; for now the file header comment
plus impl-notes are the source of truth.
