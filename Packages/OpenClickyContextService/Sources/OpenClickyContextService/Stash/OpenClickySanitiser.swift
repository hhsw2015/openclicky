// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Pure sanitisation + URL redaction helpers extracted from
// `ContextStashWriter.cs` so the writer surface AND the openclicky-context-hook
// binary AND the unit tests can share exactly one implementation.
//
// `SanitiseUserText`, `SanitiseTokenValue`, `TruncateGraphemes`,
// `RedactCredentials`, `IsAllowedScheme` are 1:1 semantic ports. Byte-for-byte
// output parity is asserted by `StashWriterTests` against a fixture payload.

import Foundation

public enum OpenClickySanitiser {

    /// Ported from `ContextStashWriter.cs:30` — `ControlCharsToStrip`.
    /// These are always mapped to space by `SanitiseUserText` (independent
    /// of `char.IsControl` — some of them ARE control chars, but this
    /// explicit list keeps the C# behaviour deterministic).
    static let controlCharsToStrip: Set<Character> = [
        "\0", "\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{08}",
    ]

    // MARK: - SanitiseUserText

    /// Ported from `SanitiseUserText` (`ContextStashWriter.cs:798-817`).
    /// Truncates to `maxChars` grapheme clusters, strips control chars to
    /// space, neutralises envelope brackets + double-quote.
    ///
    /// The port preserves the C# behaviour of iterating post-truncate
    /// characters and applying two transforms (control-strip THEN bracket
    /// neutralise). We iterate by grapheme cluster (Swift's `Character`),
    /// same as Everywhere's `StringInfo.GetTextElementEnumerator`.
    public static func sanitiseUserText(_ s: String, maxChars: Int) -> String {
        let truncated = truncateGraphemes(s, maxGraphemes: maxChars)
        var out = ""
        out.reserveCapacity(truncated.count)
        for c in truncated {
            if controlCharsToStrip.contains(c) {
                out.append(" ")
                continue
            }
            if isControlCharacter(c) {
                out.append(" ")
                continue
            }
            switch c {
            case "[": out.append("(")
            case "]": out.append(")")
            case "\"": out.append("'")
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - SanitiseTokenValue

    /// Ported from `SanitiseTokenValue` (`ContextStashWriter.cs:836-847`).
    /// Truncates to `maxChars` grapheme clusters, then drops (skips) all
    /// control chars, tab, `[`, and `]`. NB: the `[` / `]` drop strips
    /// literal IPv6 brackets from URLs — this is Everywhere's intentional
    /// behaviour and is preserved verbatim so the openclicky envelope stays
    /// byte-parity with Everywhere for the same URL input.
    public static func sanitiseTokenValue(_ s: String, maxChars: Int) -> String {
        let truncated = truncateGraphemes(s, maxGraphemes: maxChars)
        var out = ""
        out.reserveCapacity(truncated.count)
        for c in truncated {
            // Space MUST be stripped alongside control chars + tab — the
            // envelope grammar uses ` ` as the terminator between
            // `key=value` pairs (`app=... title=... url=...`). Everywhere
            // (ContextStashWriter.cs:842) explicitly drops it. Missing this
            // meant an app exec-basename like "My App" or a URL with an
            // unencoded space could split the header line mid-token.
            if isControlCharacter(c) || c == " " || c == "\t" { continue }
            if c == "[" || c == "]" { continue }
            out.append(c)
        }
        return out
    }

    // MARK: - TruncateGraphemes

    /// Ported from `TruncateGraphemes` (`ContextStashWriter.cs:849-864`).
    /// Iterates by grapheme cluster (Swift `Character`), never splits emoji
    /// ZWJ / surrogate pairs / RTL runs mid-cluster. Ellipsis `…` appended
    /// on truncation, matching C#.
    public static func truncateGraphemes(_ s: String, maxGraphemes: Int) -> String {
        if s.isEmpty || maxGraphemes <= 0 { return "" }
        var out = ""
        var count = 0
        var truncated = false
        for c in s {
            if count >= maxGraphemes {
                truncated = true
                break
            }
            out.append(c)
            count += 1
        }
        if truncated { out.append("…") }
        return out
    }

    /// Detect any control-scalar payload inside a grapheme cluster. Matches
    /// C# `char.IsControl(c)` semantics: any scalar in Unicode
    /// GeneralCategory `.control`, plus the ASCII 0x00-0x1F / 0x7F range.
    static func isControlCharacter(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return true }
        }
        return false
    }

    // MARK: - URL redaction

    /// Case-insensitive denylist — 17 entries, matches Everywhere's
    /// `_redactQueryParams` (`ContextStashWriter.cs:448-455`) verbatim.
    public static let redactQueryParams: Set<String> = [
        "token", "access_token", "id_token", "refresh_token",
        "api_key", "apikey", "key", "secret", "client_secret",
        "auth", "authentication", "password", "pwd",
        "sig", "signature", "session", "sessionid",
    ]

    /// Ported from `RedactCredentials` (`ContextStashWriter.cs:457-481`).
    /// Strips userinfo (`user:pass@`), filters denylisted query params
    /// (case-insensitive after URL-unescape), and returns `AbsoluteUri`
    /// (Swift: `URLComponents.string`, which preserves percent-encoding).
    public static func redactCredentials(_ u: URL) -> String {
        guard var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else {
            return u.absoluteString
        }
        comps.user = nil
        comps.password = nil
        if let items = comps.queryItems, !items.isEmpty {
            let kept = items.filter { item in
                let name = item.name.removingPercentEncoding ?? item.name
                return !redactQueryParams.contains(name.lowercased())
            }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        return comps.string ?? u.absoluteString
    }

    /// Ported from `IsAllowedScheme` (`ContextStashWriter.cs:824-829`).
    /// `http | https | mailto` — the trust boundary for what an
    /// agent-context artefact is allowed to link to.
    public static func isAllowedScheme(_ u: URL) -> Bool {
        guard let scheme = u.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }
}
