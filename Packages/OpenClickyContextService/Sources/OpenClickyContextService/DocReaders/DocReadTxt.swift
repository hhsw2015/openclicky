// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadTxtTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere returns `{text, metadata:{bytes, source}}` after decoding
// via the UTF-8 -> GB18030 -> Latin-1 fallback chain. We surface bytes
// count via `warnings=["bytes=<n>"]` and any non-utf8 outcome via
// `warnings=["encoding_fallback=<name>"]`.

import Foundation

public enum DocReadTxt {

    public static let mimeType = "text/plain"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages
        try DocReaderShared.requireExists(path)

        let (text, encoding) = try DocReaderShared.readTextWithFallback(path)
        var warnings: [String] = []

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int {
            warnings.append("bytes=\(size)")
        }
        if encoding != "utf-8" {
            warnings.append("encoding_fallback=\(encoding)")
        }

        let capped = DocReaderShared.capped(text, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: nil,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }
}
