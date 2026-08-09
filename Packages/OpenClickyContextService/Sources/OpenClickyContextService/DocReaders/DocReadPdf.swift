// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadPdfTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere uses UglyToad.PdfPig's `ContentOrderTextExtractor` and
// concatenates the per-page text with newlines. macOS provides
// equivalent functionality through PDFKit (`PDFDocument.string` or
// `PDFPage.string`) which reads the same content-stream text objects.
//
// Parity notes:
//   - Everywhere returns `metadata.pages = doc.NumberOfPages`. We map
//     this to `DocReaderResult.pageCount`.
//   - Everywhere sets `metadata.likely_scanned = text.Trim().Length < 100`
//     to hint that OCR would be needed. We emit
//     `warnings=["likely_scanned=true"]` in that case.
//   - Everywhere does not accept a `maxPages` argument. The task adds it
//     as an optional cap so callers can bound work on large PDFs; when
//     the cap fires we append `warnings=["max_pages_reached=<n>"]`.

import Foundation
import PDFKit

public enum DocReadPdf {

    public static let mimeType = "application/pdf"

    /// Extract text from a PDF file at `path`.
    ///
    /// - Parameter path: Absolute POSIX URL of the .pdf file.
    /// - Parameter maxPages: Optional cap on the number of pages read
    ///   (Everywhere reads the entire document). When set and reached,
    ///   the result includes `max_pages_reached=<n>` in `warnings`.
    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        try DocReaderShared.requireExists(path)

        guard let doc = PDFDocument(url: path) else {
            throw DocReaderError.parseFailed("PDFDocument init returned nil for \(path.path)")
        }

        var warnings: [String] = []
        let totalPages = doc.pageCount
        let limit: Int
        if let cap = maxPages, cap > 0, cap < totalPages {
            limit = cap
            warnings.append("max_pages_reached=\(cap)")
        } else {
            limit = totalPages
        }

        var sb = ""
        for i in 0..<limit {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string {
                sb.append(s)
                sb.append("\n")
            }
        }

        let trimmed = sb.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 100 {
            // Everywhere flags this so callers know to fall back to OCR.
            warnings.append("likely_scanned=true")
        }

        let capped = DocReaderShared.capped(sb, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: totalPages,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }
}
