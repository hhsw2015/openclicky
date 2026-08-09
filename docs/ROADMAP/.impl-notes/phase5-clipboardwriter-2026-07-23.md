# Phase 5 — ClipboardWriter Port (2026-07-23)

Port target: Everywhere `src/Everywhere.Mac/Mcp/MacClipboardWriter.cs` @30e03e9d
(77 lines). Consumer reference: `src/Everywhere.Mcp/Tools/ClipboardTools.cs`
@30e03e9d.

## Everywhere source read

`MacClipboardWriter` implements `IClipboardWriter` with three surface methods:

- `IsAvailable()` — always returns `true` on macOS.
- `SetText(string)` — replaces the general pasteboard with one UTF-8 string.
  Sequence:
  1. `+[NSPasteboard generalPasteboard]`, guard non-null.
  2. `-[NSPasteboard clearContents]` (bumps changeCount, drops prior items).
  3. `-[NSPasteboard declareTypes:owner:]` with `["public.utf8-plain-text"]`
     and `nil` owner. Comment on lines 29-32 stresses this MUST precede
     `setString:forType:`, otherwise the setter returns NO and the autorelease
     pool drains the NSString before another reader can see it.
  4. `-[NSPasteboard setString:forType:]` with the caller text (or empty
     string on null) under type `public.utf8-plain-text`.
- `Clear()` — pasteboard + `clearContents` only.

NSPasteboard type constant used: literal string `"public.utf8-plain-text"`.
That is the value of `NSPasteboardTypeString` on modern macOS and matches
`NSPasteboard.PasteboardType.string.rawValue` on the Swift side.

`ClipboardTools.DoWrite` reports `bytes = text.Length` on success. C#
`string.Length` is UTF-16 code units, not UTF-8 byte count, which is a
known impedance mismatch — SPEC ab callers already treat `bytes` as an
advisory field. openclicky reports true UTF-8 byte count instead so the
number matches the payload actually placed on the pasteboard.

## OpenClicky adaptation

openclicky's MCP surface exposes 4 clipboard tools per the roadmap:

- `clipboard_read` — read (already handled by ClipboardCapture.swift)
- `clipboard_paste` — read alias in Everywhere, but openclicky diverges:
  simulates ⌘V so the frontmost app performs a paste. Rationale: SPEC ab
  browser-side `agent_browser_clipboard_paste` triggers a paste in the
  target document, so Everywhere-side parity means simulating ⌘V rather
  than aliasing read. Everywhere itself has no equivalent because it does
  not drive keystrokes from its own writer.
- `clipboard_write` — direct pasteboard replace (this port).
- `clipboard_copy` — aliased to `clipboard_write` in Everywhere; openclicky
  again diverges: simulates ⌘C so the frontmost app copies its own
  selection into the pasteboard. Same rationale as above.

Divergence documented in the file header and here so the reviewer sees
intent.

## Public API

`ClipboardWriter` — pure caseless namespace enum. Three static methods:

```swift
public enum ClipboardWriter {
    public static func writeText(_ text: String) -> ClipboardWriteResult
    public static func simulatePaste() -> Bool
    public static func simulateCopy() -> Bool
}
```

- `writeText` uses `NSPasteboard.general.clearContents()` +
  `setString(_:forType:)` under `.string` (which resolves to
  `"public.utf8-plain-text"`). Returns `ClipboardWriteResult(ok:bytes:)`
  with `bytes = text.data(using: .utf8)?.count ?? 0`.
- `simulatePaste` / `simulateCopy` post one CGEvent keydown + keyup pair
  under `.maskCommand` for `kVK_ANSI_V` (0x09) / `kVK_ANSI_C` (0x08) via
  `.cghidEventTap`. `usleep` 20ms between down and up so the frontmost app
  registers both halves of the keystroke.

Modelled on `SelectedTextCapture.sendCopyKey` (already in this package)
but simpler: no `postToPid`, no snapshot/restore — those semantics belong
to the SelectedText path.

## Types appended to CaptureTypes.swift

```swift
public struct ClipboardWriteResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let bytes: Int
    public init(ok: Bool, bytes: Int) { self.ok = ok; self.bytes = bytes }
}
```

Serialized JSON matches the ab-agent envelope used by `clipboard_write`:
`{ "ok": true, "bytes": <int> }`.

## Files touched

- Sources/OpenClickyContextService/Capture/ClipboardWriter.swift (new)
- Sources/OpenClickyContextService/Types/CaptureTypes.swift (append
  `ClipboardWriteResult`)
- Tests/OpenClickyContextServiceTests/ClipboardWriterTests.swift (new)
