// BrowserURLBundleIDs.swift
//
// Port of the browser bundle-ID coverage matrix from retrace's
// `BrowserURLExtractor` (research/refs/retrace/Capture/Metadata/
// BrowserURLExtractor.swift:370-536). Split out from
// BrowserURLCoordinator.swift so the main file stays under 800 lines.
//
// Contents:
//   • explicitlyRecognizedBrowsers   — Safari + all Chromium family
//     (Chrome/Edge/Brave/Arc/Dia/Vivaldi/Comet/DuckDuckGo/ChatGPT/
//     Chromium/SigmaOS) plus the Firefox family (Firefox itself is
//     handled by isFirefoxFamily and intentionally disabled in the
//     coordinator).
//   • untestedBestEffortBrowsers     — Opera/GNOME Web/iCab/OmniWeb/
//     WebKit MiniBrowser/Orion/Waterfox/LibreWolf/Thorium/Zen/Floorp.
//   • chromiumAppShimPrefixes        — `com.google.Chrome.app.<id>`
//     style PWA bundle IDs. Detected by prefix match. URL extraction
//     for these routes through the host browser via AppleScript
//     because the shim's own AX tree hides the tab URL.
//   • chromiumExactBundleIDs         — Chromium hosts that use the
//     AXDocument-on-window path.
//   • firefoxBundleIDs               — Firefox family; the extractor
//     returns nil for these (retrace does the same on
//     BrowserURLExtractor.swift:555-558).
//   • appleScriptModeFallbackBundleIDs — Vivaldi + SigmaOS need
//     AppleScript URL fallback when AX returns nothing or a
//     browser-internal URL (retrace BrowserURLExtractor.swift:487-490
//     for private-mode; we reuse the same list for URL fallback
//     alongside app-shim host-browser lookup).
//
// Retrace source is read-only reference; do not import anything from
// research/refs into the module.

import Foundation

/// Static lookup tables + predicate helpers for browser bundle IDs.
/// All members are `internal` so BrowserURLCoordinator can consume
/// them without inflating the public API.
enum BrowserURLBundleIDs {

    /// Browser bundle IDs with explicit extraction coverage.
    /// Source: retrace BrowserURLExtractor.swift:375-393.
    static let explicitlyRecognizedBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.dev",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",       // Arc
        "company.thebrowser.dia",           // Dia
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.vivaldi.Vivaldi",
        "com.openai.chat",                  // ChatGPT desktop app
        "ai.perplexity.comet",              // Comet Browser
        "org.chromium.Chromium",            // Chromium
        "com.sigmaos.sigmaos.macos",        // SigmaOS
        "com.nicklockwood.Duckduckgo",      // DuckDuckGo
        "com.duckduckgo.macos.browser",     // DuckDuckGo (alternate)
    ]

    /// Recognized but untested; best-effort via generic AX fallback.
    /// Source: retrace BrowserURLExtractor.swift:397-412 plus extra
    /// niche builds (Wavebox, Ghost, Sidekick) mentioned in the
    /// review's coverage matrix at
    /// docs/review-2026-07-29/17-retrace-comparison.md.
    static let untestedBestEffortBrowsers: Set<String> = [
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",       // Opera Beta
        "com.operasoftware.OperaDeveloper",  // Opera Developer
        "com.operasoftware.OperaGX",         // Opera GX
        "com.nickvision.browser",            // GNOME Web
        "com.nicklockwood.iCab",             // iCab
        "de.icab.iCab",                      // iCab (alternate)
        "com.nicklockwood.OmniWeb",          // OmniWeb
        "org.webkit.MiniBrowser",            // WebKit MiniBrowser
        "com.nicklockwood.Orion",            // Orion
        "com.nicklockwood.Waterfox",         // Waterfox
        "net.nicklockwood.Waterfox",         // Waterfox (alternate)
        "org.nicklockwood.LibreWolf",        // LibreWolf
        "io.nicklockwood.librewolf",         // LibreWolf (alternate)
        "com.nicklockwood.Thorium",          // Thorium
        "com.nicklockwood.Zen",              // Zen Browser
        "com.nicklockwood.Floorp",           // Floorp
        "yandex.ru.Yandex",                  // Yandex Browser
        "ru.yandex.desktop.yandex-browser",  // Yandex (alternate)
        "com.pushplaylabs.sidekick",         // Sidekick
        "com.wavebox.Wavebox",               // Wavebox
        "com.wavebox.io.Wavebox",            // Wavebox (alternate)
        "com.ghostbrowser.Ghost",            // Ghost Browser
    ]

    /// All matched-exactly browser bundle IDs.
    static let knownBrowsers: Set<String> =
        explicitlyRecognizedBrowsers.union(untestedBestEffortBrowsers)

    /// Chromium app-shim bundle IDs (PWAs / installed web apps).
    /// Source: retrace BrowserURLExtractor.swift:420-433.
    static let chromiumAppShimPrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.google.Chrome.canary.app.",
        "com.microsoft.edgemac.app.",
        "com.brave.Browser.app.",
        "com.vivaldi.Vivaldi.app.",
        "com.operasoftware.Opera.app.",
        "org.chromium.Chromium.app.",
        "ai.perplexity.comet.app.",
        "company.thebrowser.dia.app.",
        "com.sigmaos.sigmaos.macos.app.",
        "com.openai.chat.app.",
        "com.nicklockwood.Thorium.app.",
    ]

    /// Exact IDs that should use the Chromium AXDocument extraction path.
    /// Source: retrace BrowserURLExtractor.swift:436-449.
    static let chromiumExactBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.dev",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaGX",
        "org.chromium.Chromium",
        "com.sigmaos.sigmaos.macos",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "com.openai.chat",
        "com.nicklockwood.Thorium",
        "com.duckduckgo.macos.browser",
        "com.nicklockwood.Duckduckgo",
    ]

    /// Firefox family — URL extraction intentionally disabled.
    /// Source: retrace BrowserURLExtractor.swift:491-496.
    static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    /// Bundle IDs that ship AppleScript hooks for URL + private-mode
    /// lookup when the AX tree is unhelpful. Source: retrace
    /// BrowserURLExtractor.swift:487-490.
    static let appleScriptModeFallbackBundleIDs: Set<String> = [
        "com.vivaldi.Vivaldi",
        "com.sigmaos.sigmaos.macos",
    ]

    /// Bundle ID for Finder — we route to `getFinderTargetURL` for it.
    /// Source: retrace BrowserURLExtractor.swift:551-553.
    static let finderBundleID = "com.apple.finder"

    // MARK: - Predicates (retrace BrowserURLExtractor.swift:506-536)

    /// Is this bundle ID any recognized browser (exact + shim)?
    static func isBrowser(_ bundleID: String) -> Bool {
        if knownBrowsers.contains(bundleID) { return true }
        return chromiumAppShimPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Should this bundle ID use the Chromium AXDocument extraction path?
    static func isChromiumBrowser(_ bundleID: String) -> Bool {
        if chromiumExactBundleIDs.contains(bundleID) { return true }
        return chromiumAppShimPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Is this bundle ID a Chromium app-shim (PWA)?
    static func isChromiumAppShim(_ bundleID: String) -> Bool {
        chromiumAppShimPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func isFirefoxFamily(_ bundleID: String) -> Bool {
        firefoxBundleIDs.contains(bundleID)
    }

    /// Map `com.vendor.Browser.app.<id>` to `com.vendor.Browser`.
    /// Source: retrace BrowserURLExtractor.swift:530-536.
    static func hostBrowserBundleID(forChromiumAppShim bundleID: String)
        -> String?
    {
        for prefix in chromiumAppShimPrefixes where bundleID.hasPrefix(prefix) {
            guard prefix.hasSuffix(".app.") else { continue }
            return String(prefix.dropLast(5))
        }
        return nil
    }

    // MARK: - URL string sanitizers (retrace :1344-1413)

    /// Trim + normalize a value that might come in as String / URL / NSURL.
    /// Source: retrace BrowserURLExtractor.swift:1344-1364.
    static func normalizedAXURLValue(from value: Any?) -> String? {
        let raw: String?
        switch value {
        case let s as String: raw = s
        case let u as URL:    raw = u.absoluteString
        case let n as NSURL:  raw = n.absoluteString
        default:              raw = nil
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Cheap URL heuristic (retrace BrowserURLExtractor.swift:1407-1413).
    static func looksLikeURL(_ string: String) -> Bool {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://")
            || t.hasPrefix("https://")
            || t.hasPrefix("file://")
            || (t.contains(".") && !t.contains(" ") && t.count > 4)
    }

    /// chrome://, chrome-extension://, devtools://, vivaldi:// — reject
    /// as candidates so they don't leak into the DB.
    /// Source: retrace BrowserURLExtractor.swift:1375-1392.
    static func isBrowserInternalURL(_ url: String, for bundleID: String)
        -> Bool
    {
        let n = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !n.isEmpty else { return false }
        if n.hasPrefix("chrome-extension://")
            || n.hasPrefix("chrome://")
            || n.hasPrefix("devtools://") {
            return true
        }
        if bundleID == "com.vivaldi.Vivaldi", n.hasPrefix("vivaldi://") {
            return true
        }
        return false
    }

    /// Trim + reject browser-internal URLs. Returns the sanitized URL
    /// or nil. Source: retrace BrowserURLExtractor.swift:1366-1373.
    static func sanitizedBrowserURLCandidate(_ url: String?, for bundleID: String)
        -> String?
    {
        guard let value = normalizedAXURLValue(from: url),
              looksLikeURL(value),
              !isBrowserInternalURL(value, for: bundleID)
        else { return nil }
        return value
    }
}
