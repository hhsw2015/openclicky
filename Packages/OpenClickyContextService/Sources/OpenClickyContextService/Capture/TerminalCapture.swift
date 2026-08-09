// Ported from Everywhere: src/Everywhere.Mcp/Tools/GetTerminalOutputTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Reads the focused terminal's visible scrollback. 1:1 semantic port of
// Everywhere's `GetTerminalOutputTool.GetTerminalOutput`:
//   1. Resolve `IVisualElementContext.FocusedElement`.
//   2. Guard with `LooksLikeTerminal` (walks parent chain to top-level,
//      inspects `AppKey.FromProcessId(pid)`, substring-matches a fixed
//      list of terminal identifiers).
//   3. Read the focused element's `AXValue` bounded by
//      `maxLines * 200` bytes (average line width cap).
//   4. Split on `\n`, take the trailing `maxLines`, join back with `\n`.
//   5. Wrap in `{is_terminal, lines_returned, text}`.
//
// Constants preserved verbatim from `GetTerminalOutputTool.cs:12-16`:
//   * `defaultLinesBack = 200`
//   * `maxLinesBack     = 10_000`
//   * `averageLineCapBytes = 200`
//
// Terminal-detection substrings preserved verbatim from
// `GetTerminalOutputTool.cs:66-74`. NOTE: the list is executable-NAME
// based, not bundle-id based; a known false-negative is Warp, whose
// binary is called `stable` and therefore never matches. Ported as-is.
//
// Deviations from Everywhere (documented, intentional):
//   * On AX failure the C# path returns an MCP error result via
//     `ToolErrors.FromException`. openclicky's capture API cannot
//     signal "error" through its return shape by design, so any AX
//     read failure surfaces as `nil` here. Callers who need Everywhere's
//     exact JSON envelope on failure can synthesise it downstream.
//   * The Swift port's `String.count` is grapheme-cluster count while
//     C#'s `.Length` is UTF-16 units. This only matters for the
//     text-length cap, and Swift's slicing keeps grapheme cluster
//     boundaries intact - preferred over C#'s UTF-16 slicing which
//     can split a surrogate pair mid-code-point.
//   * Method is `async` for parity with sibling capture APIs
//     (`BrowserURLCapture`, `SelectedTextCapture`); the body currently
//     does not `await` but the shape is stable for future work
//     (main-actor AX hops, off-main text processing).

import Foundation
import AppKit
import ApplicationServices

/// Reads the currently-focused terminal's visible scrollback text.
///
/// See file header for parity notes vs
/// `src/Everywhere.Mcp/Tools/GetTerminalOutputTool.cs`.
public enum TerminalCapture {

    // MARK: - Constants (verbatim from GetTerminalOutputTool.cs:12-16)

    /// `DefaultLinesBack = 200` (GetTerminalOutputTool.cs:13).
    public static let defaultLinesBack: Int = 200

    /// `MaxLinesBack = 10_000` (GetTerminalOutputTool.cs:12).
    public static let maxLinesBack: Int = 10_000

    /// `AverageLineCapBytes = 200` (GetTerminalOutputTool.cs:16). Used
    /// to bound the AX text read so we do not materialise multi-megabyte
    /// scrollback strings for a small `linesBack` request.
    public static let averageLineCapBytes: Int = 200

    /// Substrings that identify a terminal emulator by executable name.
    /// Order and case preserved from `GetTerminalOutputTool.cs:66-74`.
    /// Matching is case-insensitive.
    private static let terminalKeyNeedles: [String] = [
        "term",       // Terminal, iTerm2 (also matches), gnome-terminal, Windows Terminal
        "iterm",      // redundant vs "term" but preserved verbatim
        "ghostty",
        "warp",       // NB: Warp's binary is `stable`; this needle rarely fires
        "alacritty",
        "kitty",
        "konsole",
        "xterm",
    ]

    // MARK: - Public API

    /// Return the focused terminal's trailing scrollback, or `nil` if the
    /// frontmost application cannot be resolved.
    ///
    /// - Parameter linesBack: max trailing lines to return. Defaults to
    ///   `defaultLinesBack` (200). Clamped to `[1, maxLinesBack]` -
    ///   matches `Math.Clamp(lines_back ?? DefaultLinesBack, 1, MaxLinesBack)`
    ///   at `GetTerminalOutputTool.cs:27`.
    ///
    /// Return-envelope semantics (matches Everywhere's JSON output):
    ///   * No frontmost app / pid <= 0                    -> `nil`
    ///   * Frontmost is not a terminal                     -> `TerminalOutputInfo(isTerminal: false, linesReturned: 0, text: "")`
    ///   * Frontmost is a terminal with an empty buffer    -> `TerminalOutputInfo(isTerminal: true,  linesReturned: 1, text: "")`
    ///     (mirrors C# `"".Split('\n').Length == 1`)
    ///   * Frontmost is a terminal with visible buffer     -> `TerminalOutputInfo(isTerminal: true,  linesReturned: N, text: joined)`
    ///
    /// Method is `async` for parity with sibling capture APIs; the current
    /// body does not `await`. Safe to call from any thread - AX APIs are
    /// documented thread-safe (`AXUIElement.h`).
    public static func capture(linesBack: Int = defaultLinesBack) async -> TerminalOutputInfo? {
        // Clamp exactly like C# does at GetTerminalOutputTool.cs:27.
        let maxLines = max(1, min(linesBack, maxLinesBack))

        // Resolve the frontmost app. Everywhere's `context.FocusedElement`
        // uses AppKit's frontmost app plus AX; if there's no frontmost
        // app we return nil (matches C#'s `focused is null` branch below).
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        if pid <= 0 { return nil }

        // Terminal-heuristic guard. Uses the SAME AppKeyResolver that
        // Everywhere reads via `Snapshot.AppKey.FromProcessId` on the
        // top-level element - equivalent because AppKey resolves purely
        // from the pid, not the AX ref (see phase5 investigation notes).
        let appKey = AppKeyResolver.fromProcessId(pid)
        if !looksLikeTerminal(appKey: appKey) {
            CaptureLog.log("openclicky.terminal.not_terminal",
                           ["pid": "\(pid)", "app_key": appKey])
            // Non-error, non-terminal case. Everywhere returns
            // `{is_terminal:false, lines_returned:0, text:""}`.
            return TerminalOutputInfo(isTerminal: false, linesReturned: 0, text: "")
        }

        // Focused-element resolution using the standard two-step lookup
        // (matches `focusedElement(of:)` in BrowserURLCapture/SelectedTextCapture).
        AXQuirksInstaller.ensureAXBootstrap()
        let appElement = AXUIElementCreateApplication(pid)
        guard let focused = focusedElement(of: appElement) else {
            // Terminal frontmost but no focused element - treat as empty
            // buffer, which is what the C# path effectively produces
            // (GetText returns null -> "" -> Split('\n') -> [""]).
            CaptureLog.log("openclicky.terminal.no_focused",
                           direction: "error",
                           ["pid": "\(pid)", "app_key": appKey])
            return TerminalOutputInfo(isTerminal: true, linesReturned: 1, text: "")
        }

        // Read AXValue, bounded by maxBytes for the cheap case.
        // C#: `focused.GetText(maxLength: maxBytes) ?? string.Empty`.
        let maxBytes = maxLines * averageLineCapBytes
        let raw = readAXText(focused, maxLength: maxBytes) ?? ""

        // Split on '\n' preserving empty subsequences so an empty buffer
        // produces `[""]` - matches C# `"".Split('\n')`.
        let allLines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Trailing slice (C# `lines[^maxLines..]`).
        let slice: [String] = allLines.count > maxLines
            ? Array(allLines.suffix(maxLines))
            : allLines

        let joined = slice.joined(separator: "\n")
        CaptureLog.log(
            "openclicky.terminal.capture",
            [
                "pid": "\(pid)",
                "app_key": appKey,
                "lines_returned": "\(slice.count)",
                "text_len": "\(joined.count)"
            ]
        )
        return TerminalOutputInfo(
            isTerminal: true,
            linesReturned: slice.count,
            text: joined
        )
    }

    // MARK: - Terminal heuristic

    /// Case-insensitive substring match against the fixed terminal list.
    /// Ported verbatim from `GetTerminalOutputTool.LooksLikeTerminal`
    /// (lines 59-75) with the loop unrolled into a single `contains(where:)`.
    internal static func looksLikeTerminal(appKey: String) -> Bool {
        // `AppKey.FromProcessId` already lowercases the executable name, so
        // a plain `contains` is enough. Guard with lowercased() anyway so
        // custom app-key sources (tests, future callers) still work.
        let lower = appKey.lowercased()
        return terminalKeyNeedles.contains { lower.contains($0) }
    }

    // MARK: - AX helpers

    /// Two-step focused-UI-element resolution:
    /// 1. `AXFocusedUIElement` on the app AX element.
    /// 2. If absent, `AXFocusedWindow -> AXFocusedUIElement`.
    ///
    /// Same pattern as `SelectedTextCapture.focusedElement(of:)` and
    /// `BrowserURLCapture.focusedElement(of:)`.
    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        if let focused = copyElementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            return focused
        }
        guard let window = copyElementAttribute(app, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        return copyElementAttribute(window, kAXFocusedUIElementAttribute as CFString)
    }

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

    /// Ported from `AXUIElement.GetText(int maxLength)` in
    /// `src/Everywhere.Mac/Interop/AXUIElement.cs:549-574`, restricted to the
    /// AXValue-only path that terminals actually use. Terminals do not
    /// carry AXRow children so the descendant-text flattening branch
    /// (AXRow / AXTableRow / AXOutlineRow) is not needed.
    ///
    /// `maxLength <= 0` means "no cap" (matches C# default parameter).
    private static func readAXText(_ element: AXUIElement, maxLength: Int) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        guard result == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let text = raw as! CFString as String
        if text.isEmpty { return nil }
        if maxLength > 0 && text.count > maxLength {
            return String(text.prefix(maxLength))
        }
        return text
    }
}
