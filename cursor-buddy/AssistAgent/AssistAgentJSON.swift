//
//  AssistAgentJSON.swift
//  cursor-buddy
//
//  Tolerant JSON extraction — port of
//  heyclicky_agent/agent.py::_extract_json / _repair_json.
//
//  Fable-5 through the HeyClicky proxy periodically emits JSON with:
//    · fullwidth Chinese punctuation (：，"") in structural positions
//    · trailing commas before } or ]
//    · unescaped literal newlines inside string values
//    · smart quotes
//    · a ```json … ``` code fence wrapping the object
//
//  This module cheaply repairs all four before feeding to
//  JSONSerialization.
//

import Foundation

public enum AssistAgentJSON {

    /// Repair non-destructive: touches obvious syntax issues only.
    public static func repair(_ input: String) -> String {
        // Fullwidth → ASCII structural chars.
        var s = input
        s = s.replacingOccurrences(of: "：", with: ":")
        s = s.replacingOccurrences(of: "，", with: ",")
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"") // “
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"") // ”
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")  // ‘
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")  // ’

        // Strip trailing commas: `,}` and `,]` (with optional whitespace).
        if let re = try? NSRegularExpression(pattern: ",(\\s*[}\\]])") {
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }

        // Escape literal newlines/tabs inside string values. State-machine
        // walk mirroring the Python version.
        var out = ""
        out.reserveCapacity(s.count)
        var inString = false
        var escape = false
        for ch in s {
            if escape {
                out.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                out.append(ch)
                escape = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                out.append(ch)
                continue
            }
            if inString {
                switch ch {
                case "\n": out.append("\\n"); continue
                case "\r": out.append("\\r"); continue
                case "\t": out.append("\\t"); continue
                default: break
                }
            }
            out.append(ch)
        }
        return out
    }

    /// Extract the first balanced JSON object from `text`, tolerating
    /// common LLM mistakes. Returns nil when nothing parseable is
    /// present; call site should treat that as `error/empty`.
    public static func extract(from text: String) -> [String: Any]? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Code-fence unwrap ```json ... ``` or ``` ... ```.
        if let fence = extractCodeFence(from: t) { t = fence }

        if let obj = scanBalanced(t) { return obj }
        // Tolerant pass on the whole text.
        return scanBalanced(repair(t))
    }

    // MARK: - Private helpers

    private static func extractCodeFence(from t: String) -> String? {
        // ```json\n<body>\n``` or ```\n<body>\n```
        guard let re = try? NSRegularExpression(
            pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```",
            options: []
        ) else { return nil }
        let ns = t as NSString
        let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length))
        guard let match = m, match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func scanBalanced(_ src: String) -> [String: Any]? {
        var depth = 0
        var startIdx: String.Index? = nil
        var i = src.startIndex
        while i < src.endIndex {
            let c = src[i]
            if c == "{" {
                if depth == 0 { startIdx = i }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0, let s = startIdx {
                    let end = src.index(after: i)
                    let candidate = String(src[s..<end])
                    if let obj = parseOne(candidate) {
                        return obj
                    }
                    // Reset and continue searching in case there's a
                    // second, better-formed object later in the stream.
                    startIdx = nil
                }
            }
            i = src.index(after: i)
        }
        return nil
    }

    private static func parseOne(_ candidate: String) -> [String: Any]? {
        // Try strict first, then the tolerant repair pass.
        if let strict = try? JSONSerialization.jsonObject(
            with: Data(candidate.utf8), options: []
        ) as? [String: Any] {
            return strict
        }
        let repaired = repair(candidate)
        if let loose = try? JSONSerialization.jsonObject(
            with: Data(repaired.utf8), options: []
        ) as? [String: Any] {
            return loose
        }
        return nil
    }
}
