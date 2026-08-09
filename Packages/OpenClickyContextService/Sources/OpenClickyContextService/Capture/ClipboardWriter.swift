// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacClipboardWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Write side of the macOS general pasteboard for the MCP
// `clipboard_write` / `clipboard_copy` / `clipboard_paste` tools.
//
// Everywhere reaches NSPasteboard through libobjc `msgSend` from C#. The
// Swift port funnels the same three Objective-C selectors
//   (`+[NSPasteboard generalPasteboard]`,
//    `-[NSPasteboard clearContents]`,
//    `-[NSPasteboard declareTypes:owner:]`,
//    `-[NSPasteboard setString:forType:]`)
// through AppKit directly. Wire format on the pasteboard is identical:
// one item under `public.utf8-plain-text`, prior contents cleared.
//
// Everywhere's `MacClipboardWriter` exposes exactly one write method
// (`SetText`) because its MCP `clipboard_paste` tool is an alias for
// `clipboard_read`. openclicky diverges: `clipboard_paste` /
// `clipboard_copy` here simulate the ⌘V / ⌘C keystrokes to the frontmost
// app so that the SPEC ab browser-side semantics (a paste triggers the
// active document's paste handler; a copy asks the active app to copy
// its own selection) are preserved on the Everywhere-side. See
// docs/ROADMAP/.impl-notes/phase5-clipboardwriter-2026-07-23.md for the
// full rationale.
//
// The Objective-C sequence Everywhere is careful to preserve is
// documented on lines 29-32 of MacClipboardWriter.cs:
//   "declareTypes:owner: must precede setString:forType: or the setter
//    returns NO and the pasteboard silently keeps prior (post-clear
//    empty) state."
// `NSPasteboard.clearContents()` in AppKit already handles the
// declare-types step for the writer under `.string`, so the Swift path
// is `clearContents` + `setString(_:forType:.string)` and the
// invariant Everywhere manually enforced is preserved automatically.

import Foundation
import AppKit

/// Write side of the macOS general pasteboard.
///
/// 1:1 semantic port of Everywhere's `MacClipboardWriter.SetText`, plus
/// two openclicky extensions (`simulatePaste`, `simulateCopy`) that
/// implement the SPEC ab `clipboard_paste` / `clipboard_copy` browser
/// verbs on the Everywhere-side. Everywhere itself aliases those two
/// verbs to read / write; openclicky drives real keystrokes so the
/// active document participates.
public enum ClipboardWriter {

    // MARK: - writeText

    /// Replace the general pasteboard with `text` as UTF-8 plain text.
    ///
    /// Mirrors Everywhere `MacClipboardWriter.SetText`:
    ///   * calls `-[NSPasteboard clearContents]` first — bumps
    ///     changeCount, drops prior items;
    ///   * writes one item under `NSPasteboard.PasteboardType.string`
    ///     (raw value `"public.utf8-plain-text"`, matching the literal
    ///     Everywhere passes on `MacClipboardWriter.cs:23`);
    ///   * empty string is a valid payload — `writeText("")` yields
    ///     `ClipboardWriteResult(ok: true, bytes: 0)`.
    ///
    /// - Parameter text: the string to place on the pasteboard.
    /// - Returns: `ClipboardWriteResult(ok:bytes:)` where `bytes` is the
    ///   UTF-8 byte count of `text`. On failure `ok == false` and
    ///   `bytes == 0` — Everywhere never fails visibly (its `SetText`
    ///   returns void), so this is a Swift-side tightening for the MCP
    ///   `{ok, bytes}` envelope.
    @discardableResult
    public static func writeText(_ text: String) -> ClipboardWriteResult {
        let pasteboard = NSPasteboard.general

        // clearContents mirrors `-[NSPasteboard clearContents]` on
        // MacClipboardWriter.cs:27. It bumps changeCount and drops any
        // previous items. AppKit's `setString(_:forType:)` also handles
        // the `declareTypes:owner:` step under the hood, so the
        // "declare-before-set" invariant Everywhere manually enforced
        // (lines 29-32 of the C# source) is preserved automatically.
        pasteboard.clearContents()

        // NSPasteboard.PasteboardType.string.rawValue ==
        // "public.utf8-plain-text" — the same literal Everywhere passes
        // to `stringWithUTF8String:` on line 23.
        let ok = pasteboard.setString(text, forType: .string)
        guard ok else {
            CaptureLog.log("openclicky.clipboard.write_failed",
                           direction: "error",
                           ["text_len": "\(text.count)"])
            return ClipboardWriteResult(ok: false, bytes: 0)
        }
        CaptureLog.log(
            "openclicky.clipboard.write",
            ["bytes": "\(text.utf8.count)", "change_count": "\(pasteboard.changeCount)"]
        )

        // Byte count is UTF-8 length of the payload actually written.
        // Everywhere reports `text.Length` (UTF-16 code units) as an
        // advisory number; the Swift side reports true UTF-8 bytes so
        // the value matches the wire format Everywhere placed on the
        // pasteboard.
        let bytes = text.utf8.count
        return ClipboardWriteResult(ok: true, bytes: bytes)
    }

    // MARK: - simulatePaste (⌘V)

    /// Post ⌘V to the frontmost app so it pastes the current pasteboard
    /// contents into its focused element.
    ///
    /// This is an openclicky extension of Everywhere's writer surface —
    /// Everywhere aliases `clipboard_paste` to a pasteboard read. We
    /// keep SPEC ab parity (browser-side `agent_browser_clipboard_paste`
    /// triggers the active document's paste handler) by driving the
    /// keystroke instead.
    ///
    /// - Returns: `true` if both keydown and keyup were successfully
    ///   allocated and posted; `false` when the CGEvent could not be
    ///   created (typically because Input Monitoring TCC is denied).
    @discardableResult
    public static func simulatePaste() -> Bool {
        return postCommandKey(keyCode: keyCodeV)
    }

    // MARK: - simulateCopy (⌘C)

    /// Post ⌘C to the frontmost app so it copies its current selection
    /// to the pasteboard.
    ///
    /// Distinct from `writeText`: `writeText` replaces the pasteboard
    /// with a caller-supplied string, whereas `simulateCopy` asks the
    /// active application to place whatever it currently has selected
    /// onto the pasteboard. Matches SPEC ab
    /// `agent_browser_clipboard_copy` semantics on the Everywhere-side.
    ///
    /// - Returns: `true` if both keydown and keyup were successfully
    ///   allocated and posted; `false` on CGEvent allocation failure.
    @discardableResult
    public static func simulateCopy() -> Bool {
        return postCommandKey(keyCode: keyCodeC)
    }

    // MARK: - CGEvent internals

    /// `kVK_ANSI_V` — the ANSI keyboard virtual keycode for the V key.
    /// Constant lives in `<Carbon/HIToolbox/Events.h>`; hard-coded here
    /// because openclicky avoids the Carbon dependency in this package.
    private static let keyCodeV: CGKeyCode = 0x09

    /// `kVK_ANSI_C` — same treatment as `keyCodeV`. Matches
    /// `SelectedTextCapture.keyCodeC` (0x08) already established in
    /// this package.
    private static let keyCodeC: CGKeyCode = 0x08

    /// Delay between keydown and keyup so the frontmost app registers
    /// both halves of the chord. `SelectedTextCapture` uses 20 ms via
    /// `cmdKeyDelayMs`; same value here for consistency.
    private static let commandKeyDelayMicros: useconds_t = 20_000

    /// Post a Command-modified key chord to the HID event tap. Two
    /// events (down + up), 20 ms apart, `.maskCommand` on both.
    private static func postCommandKey(keyCode: CGKeyCode) -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ) else {
            CaptureLog.log("openclicky.input.cgevent_alloc_failed",
                           direction: "error",
                           ["stage": "cmd_down", "key": "\(keyCode)"])
            return false
        }
        down.flags = .maskCommand

        guard let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            CaptureLog.log("openclicky.input.cgevent_alloc_failed",
                           direction: "error",
                           ["stage": "cmd_up", "key": "\(keyCode)"])
            return false
        }
        up.flags = .maskCommand

        // .cghidEventTap is the system-wide HID tap — same target
        // `SelectedTextCapture.sendCopyKey` uses when the pid is
        // unknown. We do not have a target pid at this call site, so
        // routing through the HID tap is the correct match.
        down.post(tap: .cghidEventTap)
        usleep(commandKeyDelayMicros)
        up.post(tap: .cghidEventTap)
        CaptureLog.log(
            "openclicky.input.cmd_chord",
            ["key": "\(keyCode)"]
        )
        return true
    }
}
