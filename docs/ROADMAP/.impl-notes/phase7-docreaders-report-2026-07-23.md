# Phase 7 - Doc readers report (2026-07-23)

## Files created (8)

Under `Packages/OpenClickyContextService/Sources/OpenClickyContextService/DocReaders/`:

1. `DocReaderResult.swift` — shared plumbing (`DocReaderShared`, `ZipEntryReader`, `docXMLLocalName`, `docReaderDefaultMaxChars`)
2. `DocReadPdf.swift`
3. `DocReadDocx.swift`
4. `DocReadXlsx.swift`
5. `DocReadPptx.swift`
6. `DocReadEpub.swift`
7. `DocReadHtml.swift`
8. `DocReadTxt.swift`

Type surface (`DocReaderResult`, `DocReaderError`) appended to `Sources/OpenClickyContextService/Types/CaptureTypes.swift` per the task's HARD constraint.

Tests: `Tests/OpenClickyContextServiceTests/DocReadersTests.swift` (one XCTestCase class per reader, fixtures synthesised at runtime with `/usr/bin/zip` for the OOXML formats).

## Per-format library

| Reader | Everywhere lib | OpenClicky port |
|---|---|---|
| PDF   | UglyToad.PdfPig                              | `PDFKit.PDFDocument.string` (built-in) |
| DOCX  | DocumentFormat.OpenXml                       | `/usr/bin/unzip -p` + `Foundation.XMLParser` |
| XLSX  | DocumentFormat.OpenXml                       | `/usr/bin/unzip -p` + `Foundation.XMLParser` (sharedStrings + workbook + rels + sheet parts) |
| PPTX  | DocumentFormat.OpenXml                       | `/usr/bin/unzip -p` + `Foundation.XMLParser` on `ppt/slides/slide*.xml` |
| EPUB  | VersOne.Epub + AngleSharp                    | `/usr/bin/unzip -p` + XMLParser on `container.xml` + OPF, HTML strip via own `DocReadHtml.stripHTML` |
| HTML  | AngleSharp DOM                               | Manual `<script>/<style>` removal + tag strip + entity decode, off-main-thread safe |
| TXT   | UTF-8 -> GB18030 -> Latin-1                  | Same fallback chain via `CFStringEncodings.GB_18030_2000` bridge |

No SPM dependencies added. Zip handled via `Process()` on `/usr/bin/unzip` (present on every macOS install).

## Return shape

`DocReaderResult { text, pageCount?, wordCount?, mimeType, warnings:[String] }` per task spec. Per-format Everywhere metadata that doesn't map onto `pageCount`/`wordCount` is emitted as free-form `warnings` entries with `key=value` prefixes (e.g. `paragraphs=2`, `sheets=1`, `title=...`, `author=...`, `chapters=2`, `likely_scanned=true`, `encoding_fallback=latin1`, `truncated=true`). No signal from the Everywhere metadata dicts is dropped.

`DocReaderError { fileNotFound, archiveInvalid, parseFailed, encodingFailed }`. Missing files throw `.fileNotFound(path)` — this replaces Everywhere's `ToolErrors.Error("file not found: ...")` sentinel.

## Public API

Every reader exposes:

```swift
public enum DocReadXxx {
    public static let mimeType: String
    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult
}
```

`maxPages` is honoured by `DocReadPdf` (bounded page walk, emits `max_pages_reached=<n>` warning). Other readers accept and ignore it for signature parity — the ROADMAP entry lists these readers as `path -> {text, metadata}` with no size hint on the Everywhere side.

## Test results

`swift test --filter DocRead` — **13 tests, 13 passed**:

- DocReadDocxTests: 2 tests (body paragraphs, missing-file)
- DocReadEpubTests: 1 test (spine chapters + title/author)
- DocReadHtmlTests: 2 tests (tag strip + script/style removal, missing-file)
- DocReadPdfTests: 2 tests (synthetic PDF via CGPDFContext, missing-file)
- DocReadPptxTests: 1 test (slide order)
- DocReadTxtTests: 3 tests (UTF-8 read, Latin-1 fallback, missing-file)
- DocReadXlsxTests: 2 tests (sheet -> CSV, CSV escaping of `,` and `"`)

Full `swift test` build compiles cleanly. Pre-existing `PickStashTests` (owned by another agent) failed on stale/unrelated fixtures — DocReaders changes do not touch that surface. Sign-and-install ran to completion: `** BUILD SUCCEEDED **` and app was reinstalled with the `OpenClicky Dev Sign` identity.

## Known limitations

- **Zip via `Process()`**: readers block on `/usr/bin/unzip` per entry. Large `.xlsx` with hundreds of sheets pays one process spawn per sheet. Acceptable for the interactive doc-reader use case; not suitable for batch indexing.
- **HTML strip is heuristic**, not full DOM. It handles `<script>`, `<style>`, block-level newlines, and the common named + numeric entities. Malformed HTML with unbalanced tags is best-effort; Everywhere's AngleSharp path recovers more gracefully.
- **DRM-protected PDFs / EPUBs are not supported.** `PDFDocument` returns nil for encrypted files (surface as `parseFailed`). Encrypted `.epub` files (Adobe DRM etc.) also fail at the zip layer.
- **DOCX/XLSX/PPTX**: XML parsing is namespace-stripped (`w:t` -> `t`, `a:t` -> `t`), which matches the local-name behaviour Everywhere's OpenXml wrapper exposes. Documents using non-standard element names outside the OOXML schema will not be extracted.
- **XLSX formula results only**: cells with formulas emit the cached `<v>` result. If the file was saved without cached values (rare), those cells appear empty. Same behaviour as Everywhere's `cell.CellValue?.Text` path.
- **Cell type coverage**: `s` (sharedString) + `inlineStr` + numeric/bool cached values are handled. `date` cells fall through as numeric serial values (Everywhere behaves identically — OpenXml has no automatic date-format resolution here).
- **`maxPages` is honoured only by PDF.** The other readers accept the argument for API parity but don't act on it.
