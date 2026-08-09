# Phase 7 - Doc readers investigation (2026-07-23)

## Ground truth (Everywhere @30e03e9dcfdd4247fd679828ed86e9042f32d809)

Location: `~/Dev/Everywhere/src/Everywhere.Mcp/Tools/`

| File | .NET lib | Fields returned |
|---|---|---|
| DocReadPdfTool.cs | UglyToad.PdfPig (ContentOrderTextExtractor) | text, pages, likely_scanned(<100 chars), source |
| DocReadDocxTool.cs | DocumentFormat.OpenXml | text, paragraphs, source (body + footnotes + endnotes + headers + footers) |
| DocReadXlsxTool.cs | DocumentFormat.OpenXml | text (CSV-ish), sheets, source (shared strings + inline + cell values, CSV escape on `,` `"` `\n` `\r`) |
| DocReadPptxTool.cs | DocumentFormat.OpenXml | text, slides, source (all `<a:t>` per slide) |
| DocReadEpubTool.cs | VersOne.Epub + AngleSharp | text, title, author, chapters, source (reading order, HTML strip via DOM) |
| DocReadHtmlTool.cs | AngleSharp | text (body.TextContent), title, source |
| DocReadTxtTool.cs | plain | text, bytes, source |
| DocReaderResult.cs | shared | Build(text, metadata) truncates >2M chars; UTF-8 -> GB18030 -> Latin-1 fallback |

## Swift equivalents

- **PDF**: `PDFKit.PDFDocument.string` + `pageCount`. Native, no dep.
- **DOCX/XLSX/PPTX/EPUB**: no built-in Zip in Foundation. Spawn `/usr/bin/unzip -p <archive> <entry>` for each XML entry we need, `-Z1` to list entries. Parse XML with `Foundation.XMLParser` (SAX). Available on all macOS.
- **HTML**: strip via regex + entity decode (Everywhere uses AngleSharp DOM; NSAttributedString HTML parsing requires main thread and heavy WebKit init - avoid). Simple `<script>`/`<style>` removal + tag strip + `<title>` extract.
- **TXT**: `Data(contentsOf:)` -> try UTF-8 -> try GB18030 (macOS has kCFStringEncodingGB_18030_2000) -> Latin-1 (never fails).

## Return shape (project-specified)

`DocReaderResult { text, pageCount?, wordCount?, mimeType, warnings:[String] }` — simpler than Everywhere's per-format metadata dict. Fold Everywhere extras into warnings when unusual (e.g. `likely_scanned`, `no-workbook`).

## Errors

- Not-found -> `DocReaderError.fileNotFound(path)`
- Unzip failure -> `DocReaderError.archiveInvalid(reason)`
- Parse failure -> `DocReaderError.parseFailed(reason)`

## Public API

```swift
public enum DocReadPdf {
    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult
}
```

Same shape (async throws, URL, optional maxPages/etc.) for the other 6.

## Constraints (target dir + files)

`Packages/OpenClickyContextService/Sources/OpenClickyContextService/DocReaders/` — 8 files as specified in the task.

Tests: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/DocReadersTests.swift`, one class per reader, generate fixtures programmatically (mini ZIP via /usr/bin/zip when needed).
