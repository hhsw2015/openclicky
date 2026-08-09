# Phase 1 — Clipboard port investigation (2026-07-22)

## Ground truth

- Source: `~/Dev/Everywhere/src/Everywhere.Mac/Mcp/MacClipboardReader.cs`
- Rev: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- Line count: **59 lines**
- Consumers:
  - `~/Dev/Everywhere/src/Everywhere.Mcp/Tools/GetClipboardTool.cs`
  - `~/Dev/Everywhere/src/Everywhere.Mcp/Tools/ClipboardTools.cs`

## Semantics extracted from MacClipboardReader.cs

The class implements `IClipboardReader` with a single method:

```csharp
public string? GetText()
```

Behavior contract:

1. Gets `NSPasteboard.generalPasteboard` via libobjc msgSend.
2. Calls `stringForType:@"public.utf8-plain-text"`.
   - Comment at line 25-26: "NSPasteboardTypeString is the constant @\"public.utf8-plain-text\" but historically NSStringPboardType also resolves; pass the modern UTI."
3. Marshals the returned NSString's UTF8String to a C# string.
4. Returns `null` when:
   - `generalPasteboard` returns nil (never happens in practice)
   - Constructing the type NSString fails
   - `stringForType:` returns nil (empty pasteboard OR content is not stringable, e.g. image-only or file-only)
   - `UTF8String` returns nil
   - Any exception thrown (caught silently, returns null)
5. Purely observational — never touches `changeCount`, never writes.
6. **No caching / no changeCount tracking.** Each call is an independent read.

## Fields returned

Everywhere only returns **plain text** (`string?`). It does NOT read:

- File paths (would be `public.file-url` / `NSFilenamesPboardType`)
- Image data (would be `public.tiff` / `public.png`)
- RTF data (would be `public.rtf`)

The doc row 13 lists `text/file/image/rtf` and marks the non-text pieces P1. This matches the Everywhere state (only text is implemented) and openclicky's intent to extend later.

## NSPasteboard type constants used

Only `public.utf8-plain-text`. In Swift/AppKit this is `NSPasteboard.PasteboardType.string` (whose rawValue is `"public.utf8-plain-text"`).

## Null / empty behavior

- `null` for empty pasteboard or non-text content
- `null` for any error
- Consumer `GetClipboardTool` maps `null` -> `text=""`, `has_text=false`

## changeCount tracking

**None.** Not in this class. If any changeCount-based caching exists elsewhere in Everywhere, it is not in the reader.

## Swift port plan

- Public struct `ClipboardInfo` in `Types/CaptureTypes.swift`:
  - `text: String?` (P0, mirrors `GetText()`)
  - `filePaths: [String]?` (P1 stub, `TODO(P1)`)
  - `imageData: Data?` (P1 stub, `TODO(P1)`)
  - `rtfData: Data?` (P1 stub, `TODO(P1)`)
  - Codable, Sendable, Equatable
- Public enum `ClipboardCapture` (namespace) with static `capture() -> ClipboardInfo?`
  - Returns `nil` when the pasteboard yields no readable content (parity with `GetText()` returning null for empty).
  - Populates `text` from `NSPasteboard.general.string(forType: .string)`.
  - Wraps in do-catch semantics (defensive; AppKit call itself does not throw, but preserve the "return null on any failure" guarantee).

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 13:

> Clipboard (text/file/image/rtf) | `MacClipboardReader.cs` | `Capture/ClipboardCapture.swift` | P0 (text), P1 (others)

Doc lists richer field set than Everywhere implements. This is not a divergence — the doc is describing openclicky's target surface; the Everywhere reference only implements the P0 portion. The P1 fields are legitimate openclicky-side extensions. No doc edit needed.
