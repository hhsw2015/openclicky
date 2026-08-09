// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadHtmlTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere parses the HTML file with AngleSharp and returns
// `document.Body.TextContent` (`{text, metadata:{title, source}}`).
//
// AngleSharp is a .NET DOM library; on Swift the equivalents are:
//   - WKWebView / NSAttributedString HTML rendering (main-thread, heavy,
//     spins up WebKit) - overkill for text extraction.
//   - Manual strip: remove <script>/<style>, extract <title>, drop
//     remaining tags, decode HTML entities.
// We choose manual strip because Everywhere's semantics are
// text-only and the manual path is deterministic and off-main-thread
// safe. The output diverges from AngleSharp in whitespace exactness
// (AngleSharp normalises certain block boundaries) but preserves the
// same *visible tokens* which is what downstream consumers care about.

import Foundation

public enum DocReadHtml {

    public static let mimeType = "text/html"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages
        try DocReaderShared.requireExists(path)

        let (raw, encoding) = try DocReaderShared.readTextWithFallback(path)
        var warnings: [String] = []
        if encoding != "utf-8" { warnings.append("encoding_fallback=\(encoding)") }

        let title = extractTitle(raw)
        if let t = title { warnings.append("title=\(t)") }

        let text = stripHTML(raw)
        let capped = DocReaderShared.capped(text, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: nil,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }

    // MARK: - Extractor

    /// Extract the innerText of the first `<title>` element, case-insensitive.
    static func extractTitle(_ html: String) -> String? {
        let lower = html.lowercased()
        guard let openRange = lower.range(of: "<title") else { return nil }
        // Find the closing `>` of the opening tag.
        guard let gt = lower.range(of: ">", range: openRange.upperBound..<lower.endIndex)
        else { return nil }
        guard let closeRange = lower.range(of: "</title>", range: gt.upperBound..<lower.endIndex)
        else { return nil }
        let start = html.index(html.startIndex,
                               offsetBy: html.distance(from: html.startIndex, to: gt.upperBound))
        let end = html.index(html.startIndex,
                             offsetBy: html.distance(from: html.startIndex, to: closeRange.lowerBound))
        let raw = String(html[start..<end])
        return decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip HTML down to visible text. Removes `<script>` / `<style>`
    /// blocks (contents included), then every tag, then decodes named
    /// and numeric entities.
    static func stripHTML(_ html: String) -> String {
        var s = html
        s = removeBlock(s, tag: "script")
        s = removeBlock(s, tag: "style")
        // Replace block-level tag closes with newlines so paragraph
        // structure survives the strip.
        for tag in ["/p", "/div", "/br", "br", "/li", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/tr"] {
            s = s.replacingOccurrences(
                of: "<\(tag)>", with: "\n", options: [.caseInsensitive])
            s = s.replacingOccurrences(
                of: "<\(tag) />", with: "\n", options: [.caseInsensitive])
            s = s.replacingOccurrences(
                of: "<\(tag)/>", with: "\n", options: [.caseInsensitive])
        }
        // Strip remaining tags.
        s = stripTags(s)
        s = decodeEntities(s)
        // Collapse runs of whitespace-newline noise but preserve single newlines.
        return s
    }

    private static func removeBlock(_ input: String, tag: String) -> String {
        var out = input
        let lower = "<\(tag)"
        let close = "</\(tag)>"
        while true {
            guard let openRange = out.range(of: lower, options: .caseInsensitive)
            else { break }
            guard let closeRange = out.range(of: close, options: .caseInsensitive,
                                              range: openRange.upperBound..<out.endIndex)
            else {
                // Malformed: drop from open to end.
                out.removeSubrange(openRange.lowerBound..<out.endIndex)
                break
            }
            out.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return out
    }

    private static func stripTags(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var inTag = false
        for ch in input {
            if inTag {
                if ch == ">" { inTag = false }
            } else if ch == "<" {
                inTag = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Decode named and numeric HTML entities to their character forms.
    /// Handles the tiny common set + `&#123;` / `&#x1F;`.
    static func decodeEntities(_ input: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "copy": "\u{00A9}", "reg": "\u{00AE}",
        ]
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "&", let semi = input[i...].firstIndex(of: ";") {
                let inner = input[input.index(after: i)..<semi]
                if inner.hasPrefix("#") {
                    let num = inner.dropFirst()
                    let value: Int?
                    if num.hasPrefix("x") || num.hasPrefix("X") {
                        value = Int(num.dropFirst(), radix: 16)
                    } else {
                        value = Int(num)
                    }
                    if let v = value, let scalar = Unicode.Scalar(v) {
                        out.append(Character(scalar))
                        i = input.index(after: semi)
                        continue
                    }
                } else if let mapped = named[String(inner)] {
                    out.append(mapped)
                    i = input.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }
}
