//
//  RewindQueryParser.swift
//  cursor-buddy
//
//  Ported from retrace/Search/QueryParser/QueryParser.swift. Parses a
//  free-text query into structured filters so the caller (AskRewind
//  pipeline OR raw user typed query) can express:
//
//    kafka error                       → search terms
//    "exact phrase"                    → phrase match
//    -deprecated                       → exclude term
//    -"machine learning"               → exclude phrase
//    app:com.cmuxterm.app              → bundleID filter
//    site:github.com                   → URL host filter
//    after:2026-07-29                  → start date
//    before:2026-07-30                 → end date
//    after:yesterday / after:week      → relative date
//
//  Combined with the LLM Stage-1 output: LLM can emit either JSON
//  (Rewind-style) OR this string syntax (retrace-style) — parse handles
//  both. String syntax is more robust because it maps 1:1 to SQL/FTS.
//

import Foundation

public struct ParsedRewindQuery: Sendable {
    public var searchTerms: [String] = []      // BM25 terms
    public var phrases: [String] = []          // FTS phrase queries
    public var excluded: [String] = []         // BM25 excludes
    public var apps: [String] = []             // bundleID substrings
    public var websites: [String] = []         // URL host substrings
    public var startDate: Date?
    public var endDate: Date?

    /// True when the parsed query has enough signal to actually run a
    /// search. Rejects "-only exclusions", empty, or "filters only
    /// without any positive term" (retrace parity).
    public var isSearchable: Bool {
        !searchTerms.isEmpty || !phrases.isEmpty ||
        !apps.isEmpty || !websites.isEmpty ||
        startDate != nil || endDate != nil
    }

    /// True when the raw query contained retrace-style operators
    /// (`app:`, `site:`, `after:`, `before:`, quoted phrases, or
    /// `-exclude`). Signals that the pipeline can skip the LLM
    /// decomposition step because the user already gave structured
    /// filters.
    public var hasStructuredHints: Bool {
        !phrases.isEmpty || !excluded.isEmpty ||
        !apps.isEmpty || !websites.isEmpty ||
        startDate != nil || endDate != nil
    }

    /// Concatenate positive terms + phrases into an FTS5 MATCH
    /// expression. Excludes translate to `NOT` sub-clauses.
    public func toFTSMatch() -> String {
        var parts: [String] = []
        for t in searchTerms { parts.append(escapeFTS(t)) }
        for p in phrases     { parts.append("\"\(p)\"") }
        var expr = parts.joined(separator: " OR ")
        for e in excluded {
            expr += " NOT \(escapeFTS(e))"
        }
        return expr.trimmingCharacters(in: .whitespaces)
    }

    private func escapeFTS(_ s: String) -> String {
        // FTS5 tokens: strip characters that would parse as operators.
        s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

public enum RewindQueryParser {

    public static func parse(_ raw: String, now: Date = Date()) -> ParsedRewindQuery {
        var q = ParsedRewindQuery()
        var i = raw.startIndex
        while i < raw.endIndex {
            // Skip whitespace
            if raw[i].isWhitespace { i = raw.index(after: i); continue }

            // Negation prefix
            var negated = false
            if raw[i] == "-" {
                negated = true
                i = raw.index(after: i)
                if i >= raw.endIndex { break }
            }

            // Quoted phrase
            if raw[i] == "\"" {
                let start = raw.index(after: i)
                if let end = raw[start...].firstIndex(of: "\"") {
                    let phrase = String(raw[start..<end])
                    if !phrase.isEmpty {
                        if negated { q.excluded.append(phrase) }
                        else { q.phrases.append(phrase) }
                    }
                    i = raw.index(after: end)
                } else {
                    i = raw.endIndex
                }
                continue
            }

            // Bare token until next space
            let tokStart = i
            while i < raw.endIndex && !raw[i].isWhitespace { i = raw.index(after: i) }
            let tok = String(raw[tokStart..<i])
            if tok.isEmpty { continue }

            // Prefix operators
            let lower = tok.lowercased()
            if lower.hasPrefix("app:") {
                let v = String(tok.dropFirst(4)); if !v.isEmpty { q.apps.append(v) }
            } else if lower.hasPrefix("site:") {
                let v = String(tok.dropFirst(5)); if !v.isEmpty { q.websites.append(v) }
            } else if lower.hasPrefix("after:") {
                if let d = parseDate(String(tok.dropFirst(6)), now: now) { q.startDate = d }
            } else if lower.hasPrefix("before:") {
                if let d = parseDate(String(tok.dropFirst(7)), now: now) { q.endDate = d }
            } else {
                if negated { q.excluded.append(tok) } else { q.searchTerms.append(tok) }
            }
        }
        return q
    }

    // MARK: - Date parsing

    private static func parseDate(_ raw: String, now: Date) -> Date? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }
        let cal = Calendar.current

        // Relative keywords
        switch lower {
        case "today":     return cal.startOfDay(for: now)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        case "week":      return cal.date(byAdding: .day, value: -7, to: now)
        case "month":     return cal.date(byAdding: .month, value: -1, to: now)
        default: break
        }

        // Absolute yyyy-MM-dd
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone.current
        if let d = iso.date(from: lower) { return d }

        // MM-dd-yyyy HH:mm (Rewind Stage-1 emit format)
        let us = DateFormatter()
        us.dateFormat = "MM-dd-yyyy HH:mm"
        us.timeZone = TimeZone.current
        if let d = us.date(from: lower) { return d }

        // ISO8601
        if let d = ISO8601DateFormatter().date(from: lower) { return d }
        return nil
    }
}
