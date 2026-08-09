//
//  OpenClickyScreenRedactionGate.swift
//  cursor-buddy
//
//  Decides whether a captured frame is safe to hand to a model.
//
//  This is not a hypothetical. Building the screen-history gate
//  (docs/parlor-integration-research/05-integration-plan.md §12.13),
//  the FIRST attempt at enumerating real windows on this machine turned up
//  two that should never have been sent anywhere:
//
//    · a window whose TITLE contained a live Cloudflare tunnel token
//    · a Finder window listing `client_secret_....json` among the downloads
//
//  An OCR pass with a credential-shaped grep caught both before any
//  inference ran. Under today's architecture — attach the whole screen or
//  nothing — both would have been uploaded verbatim.
//
//  Vision OCR already runs over captured frames (ContextExtractor,
//  PTTScreenshotArchive), so the marginal cost here is a regex sweep over
//  text the app has computed anyway.
//
//  Deliberately NOT a redactor. It does not blur, mask or edit pixels —
//  partial redaction invites "the secret was only half visible" reasoning.
//  It answers one question: send this frame, or refuse it.
//

import Foundation

/// Why a frame was refused. Surfaced to the user so a block is explicable
/// rather than a silent capability failure.
enum OpenClickyScreenRedactionVerdict: Equatable {
    case allow
    case blocked(reason: String)

    var isAllowed: Bool { self == .allow }
}

enum OpenClickyScreenRedactionGate {

    /// Patterns for credential VALUES, not credential-adjacent words.
    ///
    /// Every entry requires a high-entropy run, not just a keyword. The
    /// distinction matters: `AppBundleConfiguration.anthropicAPIKey()`
    /// appears in ordinary source on screen all day, and a gate that fires
    /// on the word "key" would refuse every code editor — which trains the
    /// user to switch the feature off, and then it protects nothing.
    private static let secretValuePatterns: [(name: String, pattern: String)] = [
        // JWT / Cloudflare tunnel tokens. The concrete case observed.
        ("JWT or tunnel token", #"\beyJ[A-Za-z0-9_-]{20,}"#),
        ("OpenAI-style key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
        ("Slack token", #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#),
        ("Google API key", #"\bAIza[A-Za-z0-9_-]{30,}"#),
        ("AWS access key", #"\bAKIA[A-Z0-9]{16}\b"#),
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        // `password: hunter2` — an assignment with a value, not the bare
        // word. Bounded length so a paragraph mentioning passwords is fine.
        ("credential assignment",
         #"(?i)\b(?:password|passwd|secret|api[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*\S{8,}"#)
    ]

    /// Filenames that give away what a file IS even without its contents.
    /// The Finder case: no secret was visible, but the listing announced
    /// exactly which file holds one.
    private static let secretFilenamePatterns: [(name: String, pattern: String)] = [
        ("credentials file", #"(?i)\bclient_secret[A-Za-z0-9_.-]*\.json\b"#),
        ("key file", #"(?i)\b[A-Za-z0-9_.-]*(?:private[_-]?key|id_rsa|id_ed25519)[A-Za-z0-9_.-]*\b"#),
        ("environment file", #"(?i)(?:^|[/\s])\.env(?:\.[a-z]+)?\b"#),
        ("keystore", #"(?i)\b[A-Za-z0-9_.-]+\.(?:pem|p12|pfx|keystore|jks)\b"#)
    ]

    /// Inspect OCR text for a frame.
    ///
    /// - Parameter recognizedText: what Vision read off the frame. Pass the
    ///   joined lines; ordering does not matter.
    /// - Returns: `.allow`, or `.blocked` naming what matched. The reason
    ///   never quotes the match — echoing a secret into a log or a caption
    ///   to explain that it must not be sent is self-defeating.
    static func evaluate(recognizedText: String) -> OpenClickyScreenRedactionVerdict {
        guard !recognizedText.isEmpty else { return .allow }

        for (name, pattern) in secretValuePatterns {
            if recognizedText.range(of: pattern, options: .regularExpression) != nil {
                return .blocked(reason: "a visible \(name)")
            }
        }
        for (name, pattern) in secretFilenamePatterns {
            if recognizedText.range(of: pattern, options: .regularExpression) != nil {
                return .blocked(reason: "a visible \(name) name")
            }
        }
        return .allow
    }

    /// Convenience for callers holding OCR lines rather than one blob.
    static func evaluate(recognizedLines: [String]) -> OpenClickyScreenRedactionVerdict {
        evaluate(recognizedText: recognizedLines.joined(separator: "\n"))
    }

    /// User-facing sentence for a refusal. Says what was withheld and why,
    /// so the user can move the window and retry rather than concluding the
    /// feature is broken.
    static func explanation(for verdict: OpenClickyScreenRedactionVerdict) -> String? {
        guard case .blocked(let reason) = verdict else { return nil }
        return "I did not send that screen — it showed \(reason)."
    }
}
