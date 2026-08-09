//
//  OpenClickyWebFetchClient.swift
//  cursor-buddy
//
//  F34 landing — direct HTTP fetch for the `web_fetch_url` MCP tool.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Source: src/Everywhere.Mcp/Tools/WebSearchTool.cs (WebFetchUrl handler)
//
//  Everywhere proxies through `r.jina.ai` (a free Markdown reader). We
//  ship a plain URLSession fetch instead because:
//    - No hosted routing constraint means we do not need Jina;
//    - OpenClicky already has DocReadHtml.stripHTML() for HTML->text;
//    - Depending on Jina would introduce a third-party dependency for
//      every fetch, contradicting CLAUDE.md's local-first stance.
//
//  Contract:
//    - Timeout 15s (matches Everywhere's HttpClient default);
//    - Follows redirects (URLSession default);
//    - Cap response at `max_bytes` (default 1MB);
//    - Text extraction: HTML -> minimal inline stripHTML (DocReadHtml's
//      internal helpers are not `public` and task constraints forbid
//      widening them from this diff);
//    - URL redaction on outbound query string via
//      OpenClickyContextService.OpenClickySanitiser.redactCredentials
//      so credentials in `?token=...` do not leak into logs.
//

import Foundation
import OpenClickyContextService

/// Free-lane HTTP fetch client used by the `web_fetch_url` MCP tool.
enum OpenClickyWebFetchClient {

    // Timeout matches Everywhere's HttpClient default so behaviour is
    // predictable across identical requests.
    static let defaultTimeout: TimeInterval = 15
    static let defaultMaxBytes: Int = 1_000_000

    enum FetchError: Error, LocalizedError {
        case invalidURL
        case disallowedScheme
        case httpError(status: Int)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "invalid URL"
            case .disallowedScheme: return "scheme not allowed (must be http/https)"
            case .httpError(let s): return "upstream returned status \(s)"
            case .network(let m): return "network error: \(m)"
            }
        }
    }

    struct FetchResult {
        let title: String?
        let text: String
        let warnings: [String]
        let bytesRead: Int
        let mime: String?
    }

    /// Perform one fetch. `format` accepts "text" (default; HTML is
    /// stripped) or "raw" (return bytes decoded as UTF-8 without
    /// stripping).
    static func fetch(
        url raw: String,
        maxBytes: Int = defaultMaxBytes,
        format: String = "text",
        timeout: TimeInterval = defaultTimeout,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> FetchResult {
        guard let url = URL(string: raw) else { throw FetchError.invalidURL }
        // OpenClickySanitiser.isAllowedScheme accepts mailto too; for a
        // fetch tool we restrict to http/https only.
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw FetchError.disallowedScheme
        }

        // Redact credentials from the target URL BEFORE sending so any
        // logging or error output does not leak secrets. If redaction
        // reshapes the URL (drops user/password/query token), we send
        // the redacted form because upstream servers should not be
        // receiving those tokens in the first place through this
        // free-lane tool.
        let redacted = OpenClickySanitiser.redactCredentials(url)
        let sendURL = URL(string: redacted) ?? url

        var req = URLRequest(url: sendURL)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // Some upstream servers refuse User-Agent-less clients; use a
        // conservative identifier.
        req.setValue("OpenClicky-WebFetch/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,text/plain,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: req)
            data = d
            guard let h = r as? HTTPURLResponse else {
                throw FetchError.network("non-HTTP response")
            }
            http = h
        } catch let err as FetchError {
            throw err
        } catch {
            throw FetchError.network(error.localizedDescription)
        }

        if !(200..<300).contains(http.statusCode) {
            throw FetchError.httpError(status: http.statusCode)
        }

        var warnings: [String] = []
        let mime = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        let capped: Data
        if data.count > maxBytes {
            capped = data.prefix(maxBytes)
            warnings.append("truncated_to=\(maxBytes)_bytes")
        } else {
            capped = data
        }

        // Decode as UTF-8; fall back to Latin-1 (never fails) so
        // binary content still returns some string.
        let rawText: String
        if let utf8 = String(data: capped, encoding: .utf8) {
            rawText = utf8
        } else if let latin = String(data: capped, encoding: .isoLatin1) {
            rawText = latin
            warnings.append("encoding_fallback=iso-8859-1")
        } else {
            rawText = ""
            warnings.append("decode_failed")
        }

        // Decide whether we treat this as HTML. Trust the MIME first;
        // fall back to a heuristic ("<html" or "<!doctype html" in the
        // first KB) for servers that misreport.
        let isHTML: Bool = {
            if let mime, mime.contains("html") { return true }
            let sniff = rawText.prefix(1024).lowercased()
            return sniff.contains("<html") || sniff.contains("<!doctype html")
        }()

        let text: String
        let title: String?
        if format.lowercased() == "text" && isHTML {
            title = Self.extractTitle(rawText)
            text = Self.stripHTML(rawText)
        } else {
            title = nil
            text = rawText
        }

        return FetchResult(
            title: title,
            text: text,
            warnings: warnings,
            bytesRead: data.count,
            mime: mime
        )
    }

    // MARK: - Inline HTML stripping
    //
    // Mirrors the behaviour of
    // `OpenClickyContextService.DocReadHtml.stripHTML` (whose helpers
    // are file-internal). Ported from Everywhere DocReadHtmlTool.cs
    // @ 30e03e9dcfdd4247fd679828ed86e9042f32d809.

    /// Extract the innerText of the first `<title>` element.
    static func extractTitle(_ html: String) -> String? {
        let lower = html.lowercased()
        guard let openRange = lower.range(of: "<title") else { return nil }
        guard let gt = lower.range(of: ">", range: openRange.upperBound..<lower.endIndex) else { return nil }
        guard let closeRange = lower.range(of: "</title>", range: gt.upperBound..<lower.endIndex) else { return nil }
        let start = html.index(html.startIndex, offsetBy: html.distance(from: html.startIndex, to: gt.upperBound))
        let end = html.index(html.startIndex, offsetBy: html.distance(from: html.startIndex, to: closeRange.lowerBound))
        let raw = String(html[start..<end])
        return decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        s = removeBlock(s, tag: "script")
        s = removeBlock(s, tag: "style")
        for tag in ["/p", "/div", "/br", "br", "/li", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6", "/tr"] {
            s = s.replacingOccurrences(of: "<\(tag)>", with: "\n", options: [.caseInsensitive])
            s = s.replacingOccurrences(of: "<\(tag) />", with: "\n", options: [.caseInsensitive])
            s = s.replacingOccurrences(of: "<\(tag)/>", with: "\n", options: [.caseInsensitive])
        }
        s = stripTags(s)
        s = decodeEntities(s)
        return s
    }

    private static func removeBlock(_ input: String, tag: String) -> String {
        var out = input
        let openTag = "<\(tag)"
        let closeTag = "</\(tag)>"
        while true {
            guard let openRange = out.range(of: openTag, options: .caseInsensitive) else { break }
            guard let closeRange = out.range(of: closeTag, options: .caseInsensitive, range: openRange.upperBound..<out.endIndex) else {
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

    private static func decodeEntities(_ input: String) -> String {
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
