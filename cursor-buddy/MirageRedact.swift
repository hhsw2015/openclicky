//
//  MirageRedact.swift
//  cursor-buddy
//
//  Port of peeky/src/routelet/redact.rs `preprocess`. Same normalization
//  the Peeky routelet applied at training time — running it at inference
//  eliminates train/serve skew so the shipped 5x384 head keeps its
//  calibrated accuracy.
//
//  Rules (order matters — earlier rules consume text later rules never
//  see):
//   1. Lowercase (training corpus is all lowercase).
//   2. Strip trailing whitespace + terminal `.!?` from STT noise. If the
//      trimmed tail had a `?`, append exactly one `?` at the end — the
//      training augmenter used a bare `?` as the "question register"
//      signal.
//   3. Secret keyword tail: after "password" / "token" / "api key" /
//      etc., replace everything after the keyword with " <SECRET>".
//   4. Email addresses → "<EMAIL>".
//   5. Runs of 4+ digits (PINs, cards, phone numbers) → "<NUM>".
//
//  Over-redaction is acceptable; under-redaction is not.

import Foundation

enum MirageRedact {

    /// Compiled once. Force-unwrapped: every pattern is a static literal,
    /// and any typo would fail deterministically on first use.
    private static let secretKeyword: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passcode|pin|ssn|secret|token|api\s*key|api\s*secret|credit card|card number)\b.*$"#,
        options: []
    )
    private static let email: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#,
        options: []
    )
    private static let digitRun: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\b\d{4,}\b"#,
        options: []
    )

    /// Intent-independent normalization for the routelet input. Matches
    /// Peeky's `preprocess` byte-for-byte.
    static func preprocess(_ text: String) -> String {
        // Rule 1: lowercase.
        let lowered = text.lowercased()

        // Rule 2: trim trailing whitespace + terminal .!? while remembering
        // whether the trimmed tail held a `?`.
        let trimSet = CharacterSet(charactersIn: ".!? \t\n\r")
        // Find where the trimming boundary starts.
        var end = lowered.endIndex
        while end > lowered.startIndex {
            let prev = lowered.index(before: end)
            let ch = lowered[prev]
            if let scalar = ch.unicodeScalars.first, trimSet.contains(scalar) {
                end = prev
            } else {
                break
            }
        }
        let normalized = String(lowered[..<end])
        let tail = lowered[end...]
        let isQuestion = tail.contains("?")

        // Rule 3: secret keyword tail → keep keyword, "$1 <SECRET>".
        var s = normalized
        s = replaceFirst(regex: secretKeyword, in: s, template: "$1 <SECRET>")

        // Rule 4: emails.
        s = replaceAll(regex: email, in: s, template: "<EMAIL>")

        // Rule 5: 4+ digit runs.
        s = replaceAll(regex: digitRun, in: s, template: "<NUM>")

        if isQuestion { s += "?" }
        return s
    }

    // MARK: - Regex helpers

    private static func replaceFirst(regex: NSRegularExpression, in s: String, template: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range) else {
            return s
        }
        return regex.replacementString(for: match, in: s, offset: 0, template: template).isEmpty
            ? regex.stringByReplacingMatches(in: s, options: [], range: match.range, withTemplate: template)
            : {
                // NSMutableString-based replace of just the first match.
                let m = NSMutableString(string: s)
                regex.replaceMatches(in: m, options: [], range: match.range, withTemplate: template)
                return String(m)
            }()
    }

    private static func replaceAll(regex: NSRegularExpression, in s: String, template: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
