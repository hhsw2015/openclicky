//
//  AssistAgentFactsheet.swift
//  cursor-buddy
//
//  Cheap factsheet: pull paths/URLs/hashes so exact identifiers are
//  preserved in text even if the model misreads a pixel in the JPEG
//  prior. Same idea as pxpipe.py::_extract_factsheet.
//

import Foundation

public enum AssistAgentFactsheet {

    private static let regex: NSRegularExpression = {
        // Unix path | Win path | URL | hash-ish | filename with common ext.
        let pattern =
            "/[A-Za-z0-9._+\\-/]+" +
            "|[A-Za-z]:\\\\[A-Za-z0-9._+\\\\\\-]+" +
            "|https?://[^\\s'\"]+" +
            "|[a-f0-9]{7,40}" +
            "|[A-Za-z_][A-Za-z0-9_]*\\.(?:py|swift|ts|js|md|toml|yaml|json)"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Return up to 60 unique identifiers found in `text`, joined by `·`.
    public static func extract(from text: String, maxItems: Int = 60) -> String {
        let ns = text as NSString
        var seen: [String] = []
        var seenSet: Set<String> = []
        regex.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) { match, _, stop in
            guard let m = match else { return }
            let s = ns.substring(with: m.range)
            if s.count > 200 || seenSet.contains(s) { return }
            seenSet.insert(s)
            seen.append(s)
            if seen.count >= maxItems { stop.pointee = true }
        }
        return seen.joined(separator: " · ")
    }
}
