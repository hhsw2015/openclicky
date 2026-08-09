// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacBrowserTabsReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Reads every tab across every window of a supported browser via
// AppleScript. Two script families:
//   * Safari — uses `current tab of w` for the active-tab test.
//   * Chromium-derivatives (Chrome / Brave / Edge / Chromium / Vivaldi /
//     Opera) — share one scripting dictionary using `active tab index`.
//   * Arc — Chromium fork but ships a stripped dictionary that lacks
//     `active tab index`; every row is emitted with `active=false`. Pair
//     with `BrowserURLCapture` when the caller needs the actually-focused
//     tab.
//
// The AppleScript templates are byte-identical to Everywhere. Do not
// reformat: the parity-audit test compares against literal strings.
//
// Design fidelity notes vs Everywhere:
//   * Closed allow-list of canonical AppleScript app names — never
//     interpolate caller-supplied strings into the template. Same set
//     the C# `ChromiumApps` dictionary holds.
//   * Wire format `flag<US>title<US>url<RS>` where US=\u{1F} (Unit
//     Separator) and RS=\u{1E} (Record Separator). ASCII control bytes
//     were picked so titles containing tabs/newlines don't misalign.
//   * Parser rules exactly mirror `MacBrowserTabsReader.ParseTabs`:
//     split on RS, trim `\r \n `, drop empty lines, split each on US
//     with max 3 pieces, require 3 pieces.
//
// Public API deliberately narrower than the C# `BrowserTabsResult`:
//   * `capture(app:)` returns `BrowserTabsInfo?`.
//     * `nil` — app_key unmapped, AppleScript denied/failed, or timed
//       out (Everywhere's `NotSupported` / `PermissionDenied` both
//       collapse here, matching sibling captures).
//     * non-nil with empty `tabs` — browser is running but has no open
//       tabs (or all windows were closed between the two loops).
//   * The richer status is still recoverable via the stub-friendly
//     `capture(app:runner:)` overload for a future MCP tool port that
//     needs to surface `permission_denied` to end users.

import Foundation
import AppKit

/// Captures every open tab of a supported macOS browser via AppleScript.
///
/// Mirrors Everywhere's `MacBrowserTabsReader` — same allow-list, same
/// AppleScript templates, same parser. Do not reformat the script
/// constants; the parity audit compares them verbatim.
public enum BrowserTabsCapture {

    // MARK: - Allow-list (closed set — never interpolate user data)

    /// Canonical AppleScript app names indexed by every accepted alias.
    /// Case-insensitive lookup: keys are stored lowercase and callers
    /// lower their `appKey` before probing. Mirrors `ChromiumApps` in
    /// `MacBrowserTabsReader.cs:16-28`. Arc is ALSO listed here for
    /// parity with the C# dictionary, but the `scriptFor` router
    /// intercepts `"arc"` before it reaches the chromium branch (see
    /// `MacBrowserTabsReader.cs:79-83`).
    internal static let chromiumApps: [String: String] = [
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "arc": "Arc",
        "brave": "Brave Browser",
        "brave browser": "Brave Browser",
        "edge": "Microsoft Edge",
        "microsoft edge": "Microsoft Edge",
        "chromium": "Chromium",
        "vivaldi": "Vivaldi",
        "opera": "Opera",
    ]

    // MARK: - AppleScript templates (byte-identical to Everywhere)

    /// Safari AppleScript — verbatim `MacBrowserTabsReader.BuildSafariScript()`.
    /// Indentation and quoting MUST match exactly.
    internal static let safariScript: String =
        #"""
        tell application "Safari"
                    set out to ""
                    set US to (ASCII character 31)
                    set RS to (ASCII character 30)
                    repeat with w in windows
                        set ct to current tab of w
                        repeat with t in tabs of w
                            set isActive to (t is ct)
                            set flag to "0"
                            if isActive then set flag to "1"
                            set out to out & flag & US & (name of t) & US & (URL of t) & RS
                        end repeat
                    end repeat
                    return out
                end tell
        """#

    /// Arc AppleScript — verbatim `MacBrowserTabsReader.BuildArcScript()`.
    /// Arc lacks `active tab index`, so every row is `flag=0`.
    internal static let arcScript: String =
        #"""
        tell application "Arc"
                    set out to ""
                    set US to (ASCII character 31)
                    set RS to (ASCII character 30)
                    repeat with w in windows
                        repeat with t in tabs of w
                            set out to out & "0" & US & (title of t) & US & (URL of t) & RS
                        end repeat
                    end repeat
                    return out
                end tell
        """#

    /// Chromium-family AppleScript template. The `{canonicalAppName}` is
    /// substituted with an allow-listed constant from `chromiumApps`
    /// values only — never caller-supplied. Verbatim
    /// `MacBrowserTabsReader.BuildChromiumScript(canonicalAppName)`.
    internal static func chromiumScript(canonicalAppName: String) -> String {
        return """
        tell application "\(canonicalAppName)"
                    set out to ""
                    set US to (ASCII character 31)
                    set RS to (ASCII character 30)
                    repeat with w in windows
                        set ai to active tab index of w
                        set i to 0
                        repeat with t in tabs of w
                            set i to i + 1
                            set isActive to (i is equal to ai)
                            set flag to "0"
                            if isActive then set flag to "1"
                            set out to out & flag & US & (title of t) & US & (URL of t) & RS
                        end repeat
                    end repeat
                    return out
                end tell
        """
    }

    // MARK: - Router (mirrors ScriptFor in MacBrowserTabsReader.cs:76-84)

    /// Router return: the script to run plus the canonical app name we
    /// will report back to callers. `nil` means no script maps.
    internal struct ScriptChoice: Equatable {
        let source: String
        let canonicalApp: String
    }

    /// Resolve `appKey` (any accepted alias) to the pair `(script, canonicalApp)`.
    /// Case-insensitive. Returns `nil` for empty/whitespace/unknown keys.
    internal static func scriptFor(app appKey: String) -> ScriptChoice? {
        let trimmed = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "safari" {
            return ScriptChoice(source: safariScript, canonicalApp: "Safari")
        }
        if lower == "arc" {
            return ScriptChoice(source: arcScript, canonicalApp: "Arc")
        }
        guard let canonical = chromiumApps[lower] else { return nil }
        return ScriptChoice(
            source: chromiumScript(canonicalAppName: canonical),
            canonicalApp: canonical
        )
    }

    // MARK: - Public API

    /// Capture all tabs from a supported browser.
    ///
    /// - Parameter app: an accepted alias (e.g. `"safari"`, `"chrome"`,
    ///   `"Google Chrome"`, `"brave"`, `"arc"`). Case-insensitive.
    ///   If `nil`, the frontmost NSRunningApplication is probed and its
    ///   localized name / bundle id are tried against the allow-list.
    /// - Returns: `BrowserTabsInfo` on success (`tabs` may be empty);
    ///   `nil` when the app is not a supported browser, or when
    ///   AppleScript was denied / failed / timed out.
    public static func capture(app: String? = nil) async -> BrowserTabsInfo? {
        await capture(app: app, runner: AppleScriptRunner.shared)
    }

    /// Overload for tests / DI. Accepts any `AppleScriptRunning`.
    internal static func capture(
        app: String?,
        runner: AppleScriptRunning
    ) async -> BrowserTabsInfo? {
        // Resolve the app key. Nil -> frontmost NSRunningApplication.
        let resolvedKey: String
        if let explicit = app {
            resolvedKey = explicit
        } else if let inferred = frontmostAppAlias() {
            resolvedKey = inferred
        } else {
            return nil
        }

        guard let choice = scriptFor(app: resolvedKey) else {
            // Not a supported browser — matches Everywhere's
            // `BrowserTabsStatus.NotSupported` short-circuit.
            return nil
        }

        let result = await runner.run(source: choice.source)
        switch result.status {
        case .ok:
            let tabs = parseTabs(result.output ?? "")
            CaptureLog.log(
                "openclicky.browser_tabs.capture",
                [
                    "app": choice.canonicalApp,
                    "tab_count": "\(tabs.count)",
                    "raw_len": "\(result.output?.count ?? 0)"
                ]
            )
            return BrowserTabsInfo(
                app: choice.canonicalApp,
                tabs: tabs
            )
        case .permissionDenied, .notSupported, .failed:
            // Layer 0 collapse: any non-Ok status becomes nil. Note
            // that Everywhere's C# reader deliberately maps runner
            // `Failed -> PermissionDenied` (see MacBrowserTabsReader.cs:47);
            // we do not need that distinction here because both
            // collapse to the same nil.
            CaptureLog.log(
                "openclicky.browser_tabs.applescript_failed",
                direction: "error",
                [
                    "app": choice.canonicalApp,
                    "status": result.status.rawValue
                ]
            )
            return nil
        }
    }

    // MARK: - Parser (mirrors MacBrowserTabsReader.ParseTabs byte-for-byte)

    /// Deterministic pure function. Exposed `internal` so tests can
    /// exercise it without spawning osascript. Semantics MUST NOT drift
    /// from the C# reference.
    ///
    /// Rules (from `MacBrowserTabsReader.cs:54-74`):
    ///   1. Empty or nil input -> empty list.
    ///   2. Split on `\u{1E}` (RS).
    ///   3. Trim `\r`, `\n`, and space from each line; skip empty.
    ///   4. Split remainder on `\u{1F}` (US) with max 3 pieces; skip
    ///      when < 3 pieces.
    ///   5. Emit `BrowserTab(title: parts[1], url: parts[2],
    ///      isActive: parts[0] == "1")`.
    internal static func parseTabs(_ raw: String) -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        if raw.isEmpty { return tabs }

        // `String.split(separator:)` skips trailing empties by default,
        // matching C#'s `raw.Split('\x1E')` -> empties then filtered
        // by the trim + isEmpty guard below.
        for line in raw.split(separator: "\u{1E}", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(
                in: CharacterSet(charactersIn: "\r\n ")
            )
            if trimmed.isEmpty { continue }

            // C#: `trimmed.Split('\x1F', 3)` — at most 3 pieces, third
            // absorbs any embedded US bytes past the second one. Swift
            // has no direct maxSplits variant of split that keeps the
            // Split(count:) semantics against non-regex separators, so
            // we implement it explicitly.
            let parts = splitOnUS(trimmed, maxParts: 3)
            if parts.count < 3 { continue }

            tabs.append(BrowserTab(
                title: parts[1],
                url: parts[2],
                isActive: parts[0] == "1"
            ))
        }
        return tabs
    }

    /// Split `input` on U+001F, yielding at most `maxParts` pieces.
    /// Beyond `maxParts - 1` separators, the remainder (including any
    /// further US bytes) is packed into the final piece — matching
    /// C#'s `Split('\x1F', 3)` behavior.
    private static func splitOnUS(_ input: String, maxParts: Int) -> [String] {
        precondition(maxParts > 0)
        var parts: [String] = []
        parts.reserveCapacity(maxParts)
        var current = input.startIndex
        while parts.count < maxParts - 1,
              let idx = input[current...].firstIndex(of: "\u{1F}") {
            parts.append(String(input[current..<idx]))
            current = input.index(after: idx)
        }
        parts.append(String(input[current...]))
        return parts
    }

    // MARK: - Frontmost-app inference

    /// Probe `NSWorkspace.frontmostApplication` for an alias the
    /// allow-list accepts. Tries bundle id last-path-component, then
    /// bundle id itself, then localized name. Returns `nil` when no
    /// alias hits `scriptFor` — caller treats that as "not a browser".
    private static func frontmostAppAlias() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        // Try each candidate against the allow-list until one hits.
        var candidates: [String] = []
        if let localized = frontmost.localizedName {
            candidates.append(localized)
        }
        if let bundleId = frontmost.bundleIdentifier {
            // e.g. `com.google.Chrome` -> `Chrome`
            let lastComponent = bundleId
                .split(separator: ".")
                .last
                .map(String.init) ?? bundleId
            candidates.append(lastComponent)
            candidates.append(bundleId)
        }
        for candidate in candidates where scriptFor(app: candidate) != nil {
            return candidate
        }
        return nil
    }
}
