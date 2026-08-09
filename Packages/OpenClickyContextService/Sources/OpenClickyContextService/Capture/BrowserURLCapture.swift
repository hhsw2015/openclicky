// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacBrowserUrlReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Reads the focused web area's URL via macOS Accessibility. Walks the
// AX tree of the target process starting at `AXFocusedUIElement` (with
// an `AXMainWindow -> AXFocusedUIElement` fallback) and looks for
// `AXURL` on the focused element itself or any ancestor, up to 16 hops.
//
// Design fidelity notes vs Everywhere:
//   * Browser-agnostic — Everywhere's C# reader does NOT filter by
//     bundle id. It works on any pid whose AX tree publishes `AXURL`
//     somewhere along the focused-ancestor chain (Safari, Chrome,
//     Chromium-family, Firefox with AXManualAccessibility opt-in, and
//     even some Electron apps with hyperlinks focused). Any
//     browser-vs-non-browser filtering is the caller's problem; see
//     `GetBrowserUrlTool.GetBrowserUrl` for the Everywhere convention.
//   * 16-hop ancestor limit — verbatim from
//     `MacBrowserUrlReader.cs:39`.
//   * AXURL unwrap — the attribute value is a `CFURLRef` on hyperlink
//     / web-area elements. Everywhere calls `CFURLGetString` first
//     and falls back to treating the value as a `CFStringRef`. Swift
//     achieves the same via toll-free bridging: try `NSURL` then
//     `String`.
//   * Empty-string check — Everywhere skips empty AXURL strings via
//     `IsNullOrEmpty`. openclicky keeps the equivalent
//     `!isEmpty` guard so `chrome://newtab/` / `favorites://` / etc.
//     are returned as-is but a literal empty string is treated as "no
//     match" and the walk continues up the ancestor chain.
//   * No AppleScript fallback. The Everywhere source is pure
//     ApplicationServices + CoreFoundation. `capture(processId:)` is
//     still marked `async` per phase spec so a future AppleScript
//     augmentation can slot in without a signature change; today the
//     body performs no `await` work.
//
// Deliberate deviations:
//   * ARC / Swift toll-free bridging replaces the C# manual
//     `CFRelease` bookkeeping. `AXUIElementCopyAttributeValue` returns
//     a retained CoreFoundation object which Swift's `CFTypeRef`
//     bindings drop automatically at scope exit.
//   * `capture(processId:)` accepts `Int32?` so callers can pass the
//     result of a chained lookup without a manual nil check. Nil / <=0
//     produces `nil` immediately — matches Everywhere's `pid <= 0`
//     guard.
//   * Returns a `BrowserURLInfo` (pid + url tuple) instead of a bare
//     `String?`. Everywhere's MCP tool composes the tuple at the JSON
//     envelope layer; wrapping it here keeps sibling capture APIs
//     shape-consistent (`FrontmostAppInfo`, `ClipboardInfo`, ...).

import Foundation
import ApplicationServices

/// Reads the focused browser URL for a given process via
/// `AXFocusedUIElement` -> ancestor `AXURL` walk.
///
/// See file header for parity notes with `MacBrowserUrlReader.cs`.
public enum BrowserURLCapture {

    /// Ancestor-walk limit. Identical magic number to
    /// `MacBrowserUrlReader.cs:39` (`for (var i = 0; i < 16; i++)`).
    /// 16 hops is enough to walk from a deeply-nested focused element
    /// (text field inside a form inside a web area) up to the AXWebArea
    /// / AXWindow that carries `AXURL`, but short enough to bound the
    /// worst-case AX round-trip cost on a hostile app.
    private static let maxAncestorHops: Int = 16

    /// Return the URL exposed by the focused element (or one of its
    /// ancestors, up to `maxAncestorHops`) of the app with the given
    /// pid.
    ///
    /// * `processId == nil` or `<= 0` -> `nil` (mirrors Everywhere's
    ///   `if (processId <= 0) return null` guard).
    /// * No focused UI element and no main window -> `nil`.
    /// * No `AXURL` within `maxAncestorHops` -> `nil`.
    /// * Empty AXURL string -> treated as "no match", walk continues.
    /// * Any AX call failing / throwing -> caught, returns `nil`.
    ///
    /// The method is `async` for phase-1 API stability but does no
    /// `await` work today. It is safe to call from the main actor.
    public static func capture(processId: Int32?) async -> BrowserURLInfo? {
        guard let pid = processId, pid > 0 else { return nil }

        AXQuirksInstaller.ensureAXBootstrap()

        let app = AXUIElementCreateApplication(pid)

        guard let focused = focusedElement(of: app) else {
            CaptureLog.log("openclicky.browser_url.no_focus",
                           direction: "error",
                           ["pid": "\(pid)"])
            return nil
        }

        var current: AXUIElement? = focused
        for hop in 0..<maxAncestorHops {
            guard let element = current else { break }
            if let url = readURL(from: element), !url.isEmpty {
                CaptureLog.log(
                    "openclicky.browser_url.capture",
                    [
                        "pid": "\(pid)",
                        "url_len": "\(url.count)",
                        "hops": "\(hop)"
                    ]
                )
                return BrowserURLInfo(processId: pid, url: url)
            }
            current = copyElementAttribute(element, kAXParentAttribute as CFString)
        }
        CaptureLog.log("openclicky.browser_url.no_url_in_ancestors",
                       direction: "error",
                       ["pid": "\(pid)", "hops_walked": "\(maxAncestorHops)"])
        return nil
    }

    // MARK: - AX walk helpers

    /// Resolves the focused UI element for an app-level AXUIElement.
    ///
    /// Two-step lookup, matching `MacBrowserUrlReader.cs:23-32`:
    /// 1. Try `AXFocusedUIElement` on the app itself.
    /// 2. If that is absent, look up `AXMainWindow` and read its
    ///    `AXFocusedUIElement`.
    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        if let focused = copyElementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            return focused
        }
        guard let mainWindow = copyElementAttribute(app, kAXMainWindowAttribute as CFString) else {
            return nil
        }
        return copyElementAttribute(mainWindow, kAXFocusedUIElementAttribute as CFString)
    }

    /// Read an AX attribute that is expected to be another
    /// `AXUIElement` (focused element, main window, parent, ...).
    /// Returns `nil` if the attribute is absent, mistyped, or the
    /// underlying call reports any non-success status.
    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let raw = value else { return nil }
        // AXUIElement is a CFType; toll-free bridging via CFTypeID.
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Read `AXURL` on the given element and coerce it to a Swift
    /// `String`. Handles both the common `CFURLRef` case and the
    /// rarer `CFStringRef` case (some browsers publish AXURL as a
    /// plain string). Anything else returns `nil`. Matches
    /// `MacBrowserUrlReader.cs:CopyAttributeAsString`.
    private static func readURL(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value)
        guard result == .success, let raw = value else { return nil }

        let typeId = CFGetTypeID(raw)
        if typeId == CFURLGetTypeID() {
            let url = raw as! CFURL
            return (url as NSURL).absoluteString
        }
        if typeId == CFStringGetTypeID() {
            return raw as? String
        }
        return nil
    }
}
