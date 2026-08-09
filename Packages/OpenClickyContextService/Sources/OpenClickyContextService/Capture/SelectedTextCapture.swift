// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Three-strategy fallback that answers "what did the user just highlight
// anywhere on macOS?". The port covers `GetTextViaAXAPI` (lines 234-268)
// and `GetTextViaClipboardAsync` (lines 270-316) from the reference file,
// plus the `SelectionCache` cache-hit path from `GetSelectedTextTool.cs`.
//
// The mouse-hook `TextSelectionDetector` (the OTHER content of the source
// file, lines 60-231) is NOT ported — openclicky pulls on demand rather
// than streaming. The cache is written manually on every successful
// non-cache read, giving the same "survives focus change" behaviour a
// mouse-hook-driven cache would.
//
// Strategy order (verbatim from `GetTextViaAXAPI` at lines 244-259 and
// `BeginDetect` at lines 208-216):
//   1. AX on focused element     — `AXSelectedText` of `AXFocusedUIElement`
//                                    (with `AXFocusedWindow` fallback).
//   2. AX on immediate children  — walk `AXChildren` of focused element,
//                                    check `AXSelectedText` on each.
//   3. Clipboard via Cmd-C       — synthesize Cmd+C, poll `changeCount`
//                                    up to 10x10ms=100ms, restore clipboard.
//
// Cache short-circuit: BEFORE the three strategies, if `SelectionCache`
// holds a fresh (< 2 min) non-empty entry, return it with source `.cache`.
// After any successful non-cache read the result is written back.
//
// Divergences from Everywhere (documented, intentional):
//   * Password-field skip: source does NOT guard secure text fields.
//     `AXSelectedText` returns nil for them so Strategies 1/2 are no-ops
//     anyway, but Strategy 3 (Cmd-C) would leak the password. openclicky
//     detects `AXSecureTextField` on the focused element and short-circuits
//     to nil before touching the clipboard.
//   * Clipboard restore fidelity: source snapshots only the string type
//     (`ReadClipboard` -> `WriteClipboard(originalString)`). openclicky
//     snapshots ALL pasteboard items (every type + data) and restores them
//     verbatim, so mixed image-plus-text clipboards survive Cmd-C. When
//     the deeper snapshot fails we fall back to the source's
//     string-only path so we never leave the user with a wiped clipboard.
//   * `_clipboardSequence` pre-mousedown snapshot check (line 277):
//     source checks whether the user already Ctrl-C'd during the gesture
//     and reads the existing clipboard directly. openclicky is not driven
//     by a mouse hook so there is no meaningful pre-value; we skip that
//     early-exit and always synthesize Cmd+C in Strategy 3.
//   * `AXEnhancedUserInterface` / `AXManualAccessibility` opt-in flips
//     (lines 261-266): flipping these is an APP-WIDE side effect (Chrome,
//     Electron) and belongs in a dedicated quirks installer, not in a
//     read-only capture. openclicky's roadmap tracks the flip as its own
//     component (`AXQuirksInstaller.swift`). This port does NOT flip them.

import Foundation
import AppKit
import ApplicationServices

/// Reads the user's current selected text via the three-strategy
/// fallback ported from Everywhere plus a 2-minute cache short-circuit.
public enum SelectedTextCapture {

    // MARK: - Public API

    /// Return the current selected text, or `nil` if nothing is selected
    /// (or the user's context makes selection unsafe to capture — see
    /// password-field skip below).
    ///
    /// Order of operations (matches `VisualElementContext.TextSelection.cs`
    /// with the cache short-circuit from `GetSelectedTextTool.cs`):
    ///   0. Cache hit          -> `SelectedTextInfo(source: .cache)`
    ///   1. Strategy 1 (AX)    -> `SelectedTextInfo(source: .ax)`
    ///   2. Strategy 2 (child) -> `SelectedTextInfo(source: .child)`
    ///   3. Password field?    -> `nil` (skip Strategy 3, do NOT Cmd-C)
    ///   4. Strategy 3 (Cmd-C) -> `SelectedTextInfo(source: .clipboardCmdC)`
    ///   5. otherwise          -> `nil`
    ///
    /// Method is synchronous: Strategy 3 sleeps up to 100ms on the calling
    /// thread. Callers must invoke off the main thread when they want the
    /// UI to remain responsive during the Cmd-C poll. AX calls themselves
    /// are documented thread-safe (`AXUIElement.h`) so this is safe from
    /// any thread; the SelectionCache guards writes with an NSLock.
    public static func capture(cache: SelectionCache = .shared) -> SelectedTextInfo? {
        AXQuirksInstaller.ensureAXBootstrap()
        // Cache short-circuit (highest priority, matches GetSelectedTextTool.cs:23-32).
        if let cached = cache.getFresh() {
            CaptureLog.log(
                "openclicky.selection.attempt",
                ["method": "cache", "ok": "true", "text_len": "\(cached.text.count)"]
            )
            return SelectedTextInfo(
                text: cached.text,
                source: .cache,
                sourceApp: cached.appKey,
                length: cached.text.count
            )
        }

        // Resolve frontmost app + its AX element.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            CaptureLog.log("openclicky.selection.attempt",
                           direction: "error",
                           ["method": "frontmost", "ok": "false"])
            return nil
        }
        let pid = frontApp.processIdentifier
        if pid <= 0 { return nil }

        // Never Cmd-C ourselves — matches the `pid == Environment.ProcessId`
        // guard at `VisualElementContext.TextSelection.cs:196`.
        if pid == ProcessInfo.processInfo.processIdentifier {
            CaptureLog.log("openclicky.selection.attempt",
                           ["method": "self_guard", "ok": "false", "pid": "\(pid)"])
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        let appKey = AppKeyResolver.fromProcessId(pid)

        guard let focused = focusedElement(of: appElement) else {
            CaptureLog.log("openclicky.selection.attempt",
                           direction: "error",
                           ["method": "ax_focused", "ok": "false",
                            "pid": "\(pid)", "reason": "no_focused_element"])
            return nil
        }

        // Strategy 1: AX on focused element.
        if let text = readSelectedText(focused), !text.isEmpty {
            CaptureLog.log("openclicky.selection.attempt",
                           ["method": "ax_focused", "ok": "true",
                            "text_len": "\(text.count)", "pid": "\(pid)"])
            let info = makeInfo(text: text, source: .ax, appKey: appKey)
            cache.store(text: text, appKey: appKey)
            return info
        }

        // Strategy 2: AXChildren walk (single level, matches source loop).
        for child in copyChildren(focused) {
            if let text = readSelectedText(child), !text.isEmpty {
                CaptureLog.log("openclicky.selection.attempt",
                               ["method": "ax_child", "ok": "true",
                                "text_len": "\(text.count)", "pid": "\(pid)"])
                let info = makeInfo(text: text, source: .child, appKey: appKey)
                cache.store(text: text, appKey: appKey)
                return info
            }
        }

        // Password field skip — openclicky-side safeguard. Do NOT synthesize
        // Cmd-C when the focused element is a secure text field, or the
        // password would leak into the pasteboard even after we "restore".
        if isSecureField(focused) {
            CaptureLog.log("openclicky.selection.attempt",
                           ["method": "clipboard_cmd_c", "ok": "false",
                            "reason": "secure_field", "pid": "\(pid)"])
            return nil
        }

        // Terminal / TUI skip — the Cmd-C synthesis leaks a literal 'c'
        // into terminal apps (Ink/React TUIs like Claude Code interpret
        // the synthesised Cmd+C keystroke as a bare 'c' after consuming
        // the Cmd modifier). Bail out for any known terminal bundleID
        // rather than pollute the user's prompt on every PTT.
        let bid = appKey.lowercased()
        if !bid.isEmpty, isTerminalLikeBundleID(bid) {
            CaptureLog.log("openclicky.selection.attempt",
                           ["method": "clipboard_cmd_c", "ok": "false",
                            "reason": "terminal_tui_leak_guard",
                            "app": bid, "pid": "\(pid)"])
            return nil
        }

        // Strategy 3: clipboard Cmd-C fallback.
        if let text = clipboardCmdCFallback(pid: pid), !text.isEmpty {
            CaptureLog.log("openclicky.selection.attempt",
                           ["method": "clipboard_cmd_c", "ok": "true",
                            "text_len": "\(text.count)", "pid": "\(pid)"])
            let info = makeInfo(text: text, source: .clipboardCmdC, appKey: appKey)
            cache.store(text: text, appKey: appKey)
            return info
        }

        CaptureLog.log("openclicky.selection.attempt",
                       ["method": "all_failed", "ok": "false", "pid": "\(pid)"])
        return nil
    }

    // MARK: - Info assembly

    private static func makeInfo(
        text: String,
        source: SelectedTextSource,
        appKey: String?
    ) -> SelectedTextInfo {
        SelectedTextInfo(
            text: text,
            source: source,
            sourceApp: appKey,
            length: text.count
        )
    }

    // MARK: - AX helpers
    //
    // Same helper style as `BrowserURLCapture.swift`. Kept file-local so
    // this port stays self-contained.

    /// Two-step focus lookup: `AXFocusedUIElement` on the app AX element,
    /// falling back to the `AXFocusedUIElement` of `AXFocusedWindow`.
    /// Matches `GetTextViaAXAPI` (lines 238-242).
    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        if let focused = copyElementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            return focused
        }
        guard let window = copyElementAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        return copyElementAttribute(window, kAXFocusedUIElementAttribute as CFString)
    }

    /// Read a child AXUIElement attribute (focused, window, ...). Nil on
    /// any AX error, absent value, or type mismatch.
    private static func copyElementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Read `AXSelectedText` from an element. Empty string is returned as
    /// nil, matching `!string.IsNullOrEmpty` short-circuits at lines 246
    /// and 255 of the reference file.
    private static func readSelectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let text = raw as! CFString as String
        return text.isEmpty ? nil : text
    }

    /// Copy `AXChildren` as `[AXUIElement]`. Empty array on any failure.
    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        )
        guard result == .success, let raw = value else { return [] }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = raw as! CFArray
        let count = CFArrayGetCount(array)
        var out: [AXUIElement] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { continue }
            let element = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            out.append(element)
        }
        return out
    }

    /// Password / secure field detection. macOS surfaces secure text
    /// fields via `AXSubrole == AXSecureTextField` on an `AXTextField`
    /// role (see `HIServices/AXRoleConstants.h:kAXSecureTextFieldSubrole`).
    /// We also match when the ROLE itself is that literal, which some
    /// third-party UI toolkits (Electron, older AppKit shims) publish.
    private static func isSecureField(_ element: AXUIElement) -> Bool {
        let secureLiteral = kAXSecureTextFieldSubrole as String
        if let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString),
           subrole == secureLiteral {
            return true
        }
        if let role = copyStringAttribute(element, kAXRoleAttribute as CFString),
           role == secureLiteral {
            return true
        }
        return false
    }

    private static func copyStringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as! CFString as String
    }

    // MARK: - Strategy 3: Cmd-C fallback
    //
    // Ports `GetTextViaClipboardAsync` (270-316) + `SendCopyKeyAsync`
    // (318-338). Poll geometry (10 iterations x 10ms = 100ms max) is
    // verbatim from lines 299-307.

    /// Poll interval — 10ms per iteration, matches `Task.Delay(10)` at
    /// line 301 of the source.
    private static let clipboardPollIntervalMs: UInt32 = 10

    /// Poll iterations — 10, matches `for (var i = 0; i < 10; i++)` at
    /// line 299 of the source. Total max wait = 100ms.
    private static let clipboardPollIterations: Int = 10

    /// Delay between Cmd-C keyDown and keyUp — 5ms, matches
    /// `Task.Delay(5)` at line 329 of `SendCopyKeyAsync`.
    private static let cmdKeyDelayMs: UInt32 = 5

    /// Virtual keycode for the `C` key on macOS. Matches
    /// `CGKeyCode.C == 0x08` used at line 320 of the source.
    private static let keyCodeC: CGKeyCode = 0x08

    /// Bundle IDs whose focused input is a raw terminal / TUI. The
    /// synthesised Cmd+C event leaks a literal 'c' into these apps
    /// (Ink/React TUIs consume the Cmd modifier and pass the 'c' key
    /// through to stdin). Confirmed: cmux (Claude Code / Codex TUI),
    /// Terminal.app, iTerm2, Ghostty, Warp, Alacritty, kitty.
    private static func isTerminalLikeBundleID(_ bid: String) -> Bool {
        let terminals: [String] = [
            "com.cmuxterm.app",
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.warpmac",
            "co.zeit.hyper",
            "io.alacritty",
            "net.kovidgoyal.kitty",
            "org.kde.konsole",
            "com.microsoft.vscode",       // integrated terminal
            "com.microsoft.vscodeinsiders",
            "dev.zed.zed",
            "com.google.android.studio",
            "com.jetbrains.intellij",
        ]
        return terminals.contains(where: { bid.contains($0) })
    }

    private static func clipboardCmdCFallback(pid: pid_t) -> String? {
        let pasteboard = NSPasteboard.general
        let preSequence = pasteboard.changeCount

        // Snapshot full pasteboard so mixed image/file/text clipboards
        // survive restoration. See file header divergence note.
        let snapshot = snapshotPasteboard(pasteboard)

        // Fallback snapshot for the source-parity restore path.
        let originalString = pasteboard.string(forType: .string)

        // Synthesize Cmd+C.
        guard sendCopyKey(pid: pid) else {
            return nil
        }

        // Poll for changeCount to move. 10 iterations x 10ms = up to 100ms.
        var text: String?
        for _ in 0..<clipboardPollIterations {
            usleep(clipboardPollIntervalMs * 1_000)
            if pasteboard.changeCount != preSequence {
                text = pasteboard.string(forType: .string)
                break
            }
        }

        // Restore. Prefer the item-level snapshot; fall back to the
        // string-only path Everywhere uses if the deeper restore fails.
        if !restorePasteboard(pasteboard, items: snapshot) {
            if let original = originalString, !original.isEmpty {
                pasteboard.clearContents()
                _ = pasteboard.setString(original, forType: .string)
            }
        }

        return text
    }

    /// Post `Cmd+C` key-down and key-up to the target pid. `CGEvent.postToPid`
    /// targets the app precisely so a background app can be Cmd-C'd only
    /// if it is genuinely frontmost; matches `SendCopyKeyAsync` at
    /// lines 318-338 of the source (which prefers `PostToPid` when
    /// pid != 0 and falls back to `.hid` otherwise).
    private static func sendCopyKey(pid: pid_t) -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCodeC,
            keyDown: true
        ) else { return false }
        down.flags = .maskCommand

        guard let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCodeC,
            keyDown: false
        ) else { return false }
        up.flags = .maskCommand

        if pid > 0 {
            down.postToPid(pid)
            usleep(cmdKeyDelayMs * 1_000)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            usleep(cmdKeyDelayMs * 1_000)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - Pasteboard snapshot / restore

    /// Item-level snapshot: (type -> data) pairs per item. Used to restore
    /// the user's clipboard after our Cmd-C round trip so a copied image /
    /// file URL / RTF is not lost.
    fileprivate struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshotPasteboard(
        _ pasteboard: NSPasteboard
    ) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        var out: [[NSPasteboard.PasteboardType: Data]] = []
        out.reserveCapacity(items.count)
        for item in items {
            var slot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    slot[type] = data
                }
            }
            if !slot.isEmpty {
                out.append(slot)
            }
        }
        return PasteboardSnapshot(items: out)
    }

    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        items snapshot: PasteboardSnapshot?
    ) -> Bool {
        guard let snapshot else { return false }
        pasteboard.clearContents()
        var replacements: [NSPasteboardItem] = []
        replacements.reserveCapacity(snapshot.items.count)
        for entry in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                _ = item.setData(data, forType: type)
            }
            replacements.append(item)
        }
        if replacements.isEmpty { return true }
        return pasteboard.writeObjects(replacements)
    }
}
