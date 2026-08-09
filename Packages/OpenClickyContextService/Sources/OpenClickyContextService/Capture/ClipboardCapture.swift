// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacClipboardReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// macOS clipboard reader via NSPasteboard. Reads the first
// `public.utf8-plain-text` value from the general pasteboard. Doesn't touch
// changeCount, doesn't write — purely observational.
//
// Everywhere reaches NSPasteboard through libobjc msgSend from C#; on the
// Swift side we go through AppKit directly, which resolves to the same
// underlying Objective-C selectors (`+[NSPasteboard generalPasteboard]`
// and `-[NSPasteboard stringForType:]`). The behavioural contract is
// preserved 1:1:
//   * pasteboard yields nil -> `text` is nil
//   * `stringForType:` yields nil -> `text` is nil
//   * any failure caught -> `text` is nil
//   * empty pasteboard or non-text content (image / file / rtf without a
//     text representation) -> `text` is nil
//
// The comment from `MacClipboardReader.cs:25-26` is preserved below:
// "NSPasteboardTypeString is the constant @\"public.utf8-plain-text\" but
//  historically NSStringPboardType also resolves; pass the modern UTI."
// `NSPasteboard.PasteboardType.string.rawValue == "public.utf8-plain-text"`
// so the modern UTI is used automatically.
//
// P0 = text only (per docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 13).
// The `ClipboardInfo` struct exposes P1 fields (filePaths / imageData /
// rtfData) that are not yet populated; see TODO(P1) markers on the type.

import Foundation
import AppKit

/// Captures the current contents of the macOS general pasteboard.
///
/// 1:1 semantic port of Everywhere's `MacClipboardReader.GetText()`:
/// observational read of `NSPasteboard.generalPasteboard`, no
/// changeCount tracking, no writes.
public enum ClipboardCapture {

    /// Returns a snapshot of the general pasteboard's text content, or
    /// `nil` when there is nothing readable to report.
    ///
    /// Return semantics mirror Everywhere's `GetText()` (which returns
    /// `string?`), lifted into an optional struct so we can grow P1
    /// fields without breaking the call site:
    ///   * empty pasteboard -> `nil`
    ///   * non-text content only (image / file / rtf without any
    ///     text representation) -> `nil`
    ///   * text present -> `ClipboardInfo(text: "...", ...)`
    ///
    /// P1 fields (`filePaths`, `imageData`, `rtfData`) are always `nil`
    /// today; see TODO(P1) markers on `ClipboardInfo`.
    public static func capture() -> ClipboardInfo? {
        // NSPasteboard.general is always non-nil in practice — the
        // property is nonnull in AppKit — but Everywhere's C# path
        // explicitly checks for `pb == nint.Zero`, so we mirror the
        // "defensive nil-check" via the do-catch wrapper below.
        let pasteboard = NSPasteboard.general

        // NSPasteboardTypeString / NSStringPboardType / "public.utf8-plain-text"
        // all resolve to the same UTI; `.string` uses the modern one.
        guard let text = pasteboard.string(forType: .string) else {
            CaptureLog.log("openclicky.clipboard.read_empty")
            return nil
        }
        CaptureLog.log(
            "openclicky.clipboard.read",
            ["text_len": "\(text.count)", "change_count": "\(pasteboard.changeCount)"]
        )
        return ClipboardInfo(
            text: text,
            filePaths: nil,   // TODO(P1)
            imageData: nil,   // TODO(P1)
            rtfData: nil      // TODO(P1)
        )
    }
}
