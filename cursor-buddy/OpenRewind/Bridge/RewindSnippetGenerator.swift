//
//  RewindSnippetGenerator.swift
//  cursor-buddy
//
//  Snippet + highlight generator for Ask Rewind search results.
//  Fills the gap retrace's README references but ships as a stub:
//  when the FTS snippet() function returns an empty string (because
//  the matched tile is empty text), synthesise a snippet by scanning
//  the concatenated frame OCR for the query term(s).
//
//  Output uses `[]` brackets around matches (matching Rewind's own
//  snippet format), letting downstream UI treat them as highlight
//  spans if it wants pretty rendering.
//

import Foundation

public enum RewindSnippetGenerator {

    /// Build a highlighted snippet from full-frame OCR text.
    /// - Parameters:
    ///   - fullText: concatenated OCR from `Reader.ocr(for:)`
    ///   - queryTerms: whitespace-split query keywords (already lower)
    ///   - phrases: quoted phrases the user asked for (case-insensitive)
    ///   - windowChars: how many characters of context to keep around
    ///       the first match. Default 160 matches Rewind's tuning.
    ///   - maxSnippets: return up to N distinct snippet windows joined
    ///       by " … ". Rewind returns 1; retrace suggests up to 3.
    public static func generate(fullText: String,
                                queryTerms: [String],
                                phrases: [String] = [],
                                windowChars: Int = 160,
                                maxSnippets: Int = 3) -> String {
        guard !fullText.isEmpty else { return "" }
        let lower = fullText.lowercased()

        // Collect all match ranges (phrase matches first, then terms).
        var ranges: [(Range<String.Index>, String)] = []
        for phrase in phrases {
            let needle = phrase.lowercased()
            var searchStart = lower.startIndex
            while let r = lower.range(of: needle,
                                       range: searchStart..<lower.endIndex) {
                ranges.append((r, phrase))
                searchStart = r.upperBound
            }
        }
        for term in queryTerms {
            let needle = term.lowercased()
            guard !needle.isEmpty else { continue }
            var searchStart = lower.startIndex
            while let r = lower.range(of: needle,
                                       range: searchStart..<lower.endIndex) {
                ranges.append((r, term))
                searchStart = r.upperBound
            }
        }
        guard !ranges.isEmpty else {
            // No literal match — return leading text as a fallback so
            // caller isn't left with empty string.
            return String(fullText.prefix(windowChars))
                .replacingOccurrences(of: "\n", with: " ")
        }

        // Sort ranges by position, then merge overlapping windows.
        let sorted = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
        var windows: [(start: String.Index, end: String.Index)] = []
        for (r, _) in sorted {
            let winStart = fullText.index(r.lowerBound,
                                          offsetBy: -windowChars / 2,
                                          limitedBy: fullText.startIndex)
                ?? fullText.startIndex
            let winEnd = fullText.index(r.upperBound,
                                        offsetBy: windowChars / 2,
                                        limitedBy: fullText.endIndex)
                ?? fullText.endIndex
            if let last = windows.last, winStart <= last.end {
                // Overlap → extend previous window.
                windows[windows.count - 1] = (last.start, max(last.end, winEnd))
            } else {
                windows.append((winStart, winEnd))
            }
            if windows.count >= maxSnippets { break }
        }

        // Render windows, bracketing every match that falls inside them.
        let matchSet = ranges.map { $0.0 }
        var out: [String] = []
        for (winStart, winEnd) in windows {
            let winText = String(fullText[winStart..<winEnd])
            let winOffset = fullText.distance(from: fullText.startIndex,
                                              to: winStart)
            var result = ""
            var cursor = winText.startIndex
            for r in matchSet where r.lowerBound >= winStart && r.upperBound <= winEnd {
                let localStart = winText.index(winText.startIndex,
                                               offsetBy: fullText.distance(from: fullText.startIndex,
                                                                            to: r.lowerBound) - winOffset)
                let localEnd = winText.index(winText.startIndex,
                                             offsetBy: fullText.distance(from: fullText.startIndex,
                                                                          to: r.upperBound) - winOffset)
                if cursor < localStart {
                    result += winText[cursor..<localStart]
                }
                result += "["
                result += winText[localStart..<localEnd]
                result += "]"
                cursor = localEnd
            }
            if cursor < winText.endIndex {
                result += winText[cursor..<winText.endIndex]
            }
            out.append(result.replacingOccurrences(of: "\n", with: " "))
        }
        return out.joined(separator: " … ")
    }
}
