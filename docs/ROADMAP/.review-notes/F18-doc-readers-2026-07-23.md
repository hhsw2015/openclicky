# Review F18: Doc readers (7 formats)

**Everywhere pin**: 30e03e9d
**openclicky files**:
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/DocReaders/DocReaderResult.swift`
- `.../DocReadPdf.swift`
- `.../DocReadDocx.swift`
- `.../DocReadXlsx.swift`
- `.../DocReadPptx.swift`
- `.../DocReadEpub.swift`
- `.../DocReadHtml.swift`
- `.../DocReadTxt.swift`
- `Types/CaptureTypes.swift:1789-1837` (`DocReaderResult` / `DocReaderError`)

**Everywhere files**:
- `src/Everywhere.Mcp/Tools/DocReaderResult.cs`
- `src/Everywhere.Mcp/Tools/DocReadPdfTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadDocxTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadXlsxTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadPptxTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadEpubTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadHtmlTool.cs`
- `src/Everywhere.Mcp/Tools/DocReadTxtTool.cs`

**Reviewer**: F18 review agent
**Date**: 2026-07-23

## Alignment Table

### Shared plumbing

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Default char cap | `2_000_000` (`DocReaderResult.swift:21`) | `2_000_000` (`DocReaderResult.cs:10`) | OK | |
| `truncated` warning | Emitted as `"truncated=true"` in `warnings[]` (`DocReaderResult.swift:28-34`) | Emitted as `metadata.truncated:true` in JSON (`DocReaderResult.cs:28-35`) | DIVERGE | LOW / intentional — openclicky ships typed struct instead of JSON `{text, metadata}`. |
| Encoding fallback chain | UTF-8 → GB18030 (via `CFStringEncoding.GB_18030_2000`) → Latin-1 (`DocReaderResult.swift:39-61`) | UTF-8 (strict) → GB18030 (CodePages provider) → Latin-1 (`DocReaderResult.cs:47-64`) | OK | Both chain identically; Swift bridges to CoreFoundation for GB18030; C# uses CodePagesEncodingProvider. |
| Encoding surface | Returned as tuple `(text, encoding)` then written into `warnings=["encoding_fallback=<enc>"]` (`DocReaderResult.swift:39-61`, `DocReadTxt.swift:25-27`, `DocReadHtml.swift:28-29`) | Swallowed inside `ReadAllTextWithFallback` — only `text` returned (`DocReaderResult.cs:47-64`) | DIVERGE | LOW — openclicky surfaces which fallback fired; Everywhere hides it. Superset. |
| File-not-found preflight | `requireExists` → `DocReaderError.fileNotFound` (`DocReaderResult.swift:65-69`) | `DocReaderResult.NotFound(path)` returns `ToolErrors.Error` (`DocReaderResult.cs:44-45`) | OK | Both check `File.exists`; Swift throws, C# returns error envelope. |
| Zip access | `/usr/bin/unzip` subprocess (`DocReaderResult.swift:76-142`) | `System.IO.Packaging` in-process (`DocumentFormat.OpenXml`) | DIVERGE | MEDIUM / intentional per file header (`DocReaderResult.swift:11-15`). Consequence: unzip must exist on PATH (macOS ships it at `/usr/bin/unzip` — always present). |
| Error type | `DocReaderError` enum: `fileNotFound / archiveInvalid / parseFailed / encodingFailed` (`CaptureTypes.swift:1832-1837`) | All exceptions caught, converted to `ToolErrors.FromException(...)` envelope (`Doc*Tool.cs`) | DIVERGE | LOW / intentional per header (`CaptureTypes.swift:1828-1831`) — Swift keeps reasons discriminable. |
| Result shape | Typed struct `DocReaderResult{text, pageCount?, wordCount?, mimeType, warnings[]}` (`CaptureTypes.swift:1806-1826`) | JSON `{text, metadata:{…}}` inside `CallToolResult` (`DocReaderResult.cs:26-42`) | DIVERGE | LOW / intentional per header. Bridge wraps at the JSON boundary. |
| Per-format metadata fidelity | Flattened into `warnings` list (e.g. `"paragraphs=12"`, `"sheets=3"`, `"slides=8"`, `"chapters=5"`, `"title=..."`, `"author=..."`, `"bytes=..."`, `"encoding_fallback=..."`) | Structured `metadata` dict per format (`Doc*Tool.cs`) | DIVERGE | MEDIUM / intentional per header (`CaptureTypes.swift:1794-1798`). Consumers must parse `warnings` strings to recover named fields. |
| `maxPages` parameter | Optional `Int?` on every reader signature; only PDF honors it (`DocReadPdf.swift:31, 41-46`; other readers ignore it `_ = maxPages`) | Not present anywhere — Everywhere reads full doc always | DIVERGE | LOW / intentional per `DocReadPdf.swift:14-16`. Only PDF actually enforces it — DOCX/XLSX/PPTX/EPUB/HTML/TXT accept the arg then discard it. Signature-parity across readers but not semantic. |

### PDF

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | `PDFKit.PDFDocument` (`DocReadPdf.swift:19, 34`) | `UglyToad.PdfPig` `ContentOrderTextExtractor` (`DocReadPdfTool.cs:5-7, 32`) | OK — parity-matched per checklist. |
| Text concatenation | Per-page `page.string` + `"\n"` (`DocReadPdf.swift:49-54`) | `sb.AppendLine(content)` per page (`DocReadPdfTool.cs:32-34`) | OK | Both append trailing newline after each page. |
| Page counting | `doc.pageCount` written to `pageCount` field (`DocReadPdf.swift:39, 67`) | `metadata["pages"] = doc.NumberOfPages` (`DocReadPdfTool.cs:40`) | OK | |
| `likely_scanned` | `warnings.append("likely_scanned=true")` when `trimmed.count < 100` (`DocReadPdf.swift:57-61`) | `metadata["likely_scanned"] = text.Trim().Length < 100` (`DocReadPdfTool.cs:41`) | OK — same 100-char threshold, same trim. Semantic match. |
| `max_pages` honored | `if cap > 0 && cap < totalPages: limit = cap; warn "max_pages_reached=<cap>"` (`DocReadPdf.swift:41-46`) | N/A (Everywhere always reads all pages) | DIVERGE-additive | LOW / documented at `DocReadPdf.swift:14-16`. |
| Init failure | `throw DocReaderError.parseFailed("PDFDocument init returned nil …")` (`DocReadPdf.swift:35-37`) | `catch (Exception ex) { return ToolErrors.FromException(...) }` (`DocReadPdfTool.cs:45-48`) | OK — different mechanism, same "fail with reason" outcome. |
| Empty page | Skipped without error (`DocReadPdf.swift:50-53`) | If `page.string` is null: still appends `""` and newline via `AppendLine` (`DocReadPdfTool.cs:33`) | DIVERGE | LOW — Everywhere emits a stray newline for pages with no extractable text; openclicky elides it entirely. Affects byte-count of the returned text on edge cases. |

### DOCX

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | `/usr/bin/unzip` + `Foundation.XMLParser` (`DocReadDocx.swift:9-19`) | `DocumentFormat.OpenXml.Packaging` (`DocReadDocxTool.cs:3-4`) | DIVERGE | MEDIUM / intentional per header — OpenXml is .NET-only, not available on Swift. Semantic-equivalent XML walk. |
| Body parse | `word/document.xml` (`DocReadDocx.swift:40-47`) | `MainDocumentPart.Document.Body` (`DocReadDocxTool.cs:28-37`) | OK | |
| Footnotes | `word/footnotes.xml` (`DocReadDocx.swift:50-56`) | `MainDocumentPart.FootnotesPart.Footnotes` (`DocReadDocxTool.cs:39-45`) | OK | |
| Endnotes | `word/endnotes.xml` (`DocReadDocx.swift:50-56`) | `MainDocumentPart.EndnotesPart.Endnotes` (`DocReadDocxTool.cs:47-53`) | OK | |
| Headers/footers | Iterate all `header*.xml` / `footer*.xml` in archive order (`DocReadDocx.swift:62-71`) | Iterate `MainDocumentPart.HeaderParts` + `.FooterParts` (`DocReadDocxTool.cs:55-71`) | OK — order matches per file header comment. |
| Paragraph terminator | `\n` at `</w:p>` (`DocReadDocx.swift:132-134`) | `sb.AppendLine(para.InnerText)` (`DocReadDocxTool.cs:34,43,49,61,68`) | OK — `AppendLine` on .NET emits `\r\n` on Windows and `\n` on macOS/Linux by default; on the macOS runtime targets openclicky ships on, both yield `\n`. On Windows-built binary the byte-diff would show `\r\n` vs `\n`. Minor and outside deployment target. |
| Text element handling | `w:t` → collect; `w:tab` → `\t`; `w:br` / `w:cr` → `\n` (`DocReadDocx.swift:107-118`) | `para.InnerText` (OpenXml auto-concatenates all descendant text runs, preserving explicit tabs but flattening line breaks into text) | DIVERGE | LOW — openclicky's manual walk preserves `w:tab`→`\t` and `w:br`→`\n`; Everywhere's `InnerText` doesn't emit tabs or line-breaks explicitly. Different whitespace. |
| Paragraph count | Tracked, appended as `"paragraphs=<n>"` (`DocReadDocx.swift:38, 74`) | `metadata["paragraphs"] = paragraphCount` (`DocReadDocxTool.cs:75`) | OK | |

### XLSX

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | `/usr/bin/unzip` + `Foundation.XMLParser` (`DocReadXlsx.swift:12-16`) | `DocumentFormat.OpenXml` (`DocReadXlsxTool.cs:3-5`) | DIVERGE | MEDIUM / intentional. |
| Shared strings | Parse `<si><t>...</t></si>` from `xl/sharedStrings.xml` (`DocReadXlsx.swift:33-36, 101-148`) | `wb.SharedStringTablePart?.SharedStringTable` (`DocReadXlsxTool.cs:35`) | OK | |
| Sheet order | Read `xl/workbook.xml` `<sheet>` elements in order, resolve via `xl/_rels/workbook.xml.rels` `Id→Target` map (`DocReadXlsx.swift:39-68`) | `workbook.Descendants<Sheet>()` + `GetPartById(sheet.Id.Value)` (`DocReadXlsxTool.cs:42-46`) | OK | Both walk workbook order. |
| Cell type handling | `t="s"` → shared string; else `inlineStr`/number/etc use `currentValue` (`DocReadXlsx.swift:270-278`) | `SharedString` → `sst.ChildElements[idx].InnerText`; `InlineString` → `cell.InnerText`; else `cell.CellValue?.Text` (`DocReadXlsxTool.cs:74-86`) | SEM-OK | Both resolve shared-string index via `Int(currentValue)` before lookup; both handle inline strings by treating cell's inner text; both fall back to raw cell value. |
| CSV escaping | Escape when `s` contains `,`, `"`, `\n`, `\r`; wrap in `"..."` and double `"` (`DocReadXlsx.swift:91-97`) | Same predicate (`.IndexOfAny([',', '"', '\n', '\r']) >= 0`) and same escape (`DocReadXlsxTool.cs:88-92`) | OK — byte-match. |
| Row joiner | `,` (`DocReadXlsx.swift:72-73`) | `,` via `string.Join(",", …)` (`DocReadXlsxTool.cs:55`) | OK | |
| Row terminator | `\n` (`DocReadXlsx.swift:73`) | `AppendLine` (`DocReadXlsxTool.cs:55`) | OK on macOS. Same caveat as DOCX on Windows. |
| Sheet count | Written as `pageCount` field and `warnings=["sheets=N"]` (`DocReadXlsx.swift:77-88`) | `metadata["sheets"] = sheetCount` (`DocReadXlsxTool.cs:61`) | OK | |
| Empty workbook | Emits `warnings=["no-workbook"]` with empty text (`DocReadXlsx.swift:39-48`) | Emits `metadata.sheets=0` with empty text (`DocReadXlsxTool.cs:30-40`) | OK — semantically equivalent. |

### PPTX

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | `/usr/bin/unzip` + `Foundation.XMLParser` (`DocReadPptx.swift:12-13`) | `DocumentFormat.OpenXml` (`DocReadPptxTool.cs:3-5`) | DIVERGE | MEDIUM / intentional. |
| Slide order | Filter `ppt/slides/slide*.xml`, sort by natural-number ordering on trailing digits (`DocReadPptx.swift:25-27, 53-61`) | `pres.SlideParts` iteration order (relationship-walk order) (`DocReadPptxTool.cs:28-31`) | SEM-OK | Different implementation, same intent per file header comment (`DocReadPptx.swift:2-11`). Verified: OpenXml `SlideParts` returns in relationship-declaration order which for standard authoring tools matches slide1.xml, slide2.xml, … |
| Text element | Every `a:t` (namespace-stripped `t`) written on its own line (`DocReadPptx.swift:85-102`) | `slideRoot.Descendants<Text>()` — DrawingML `Text` elements = `a:t` — via `sb.AppendLine(t.Text)` (`DocReadPptxTool.cs:34-38`) | OK — semantic byte-parity. |
| Slide count | Written as `pageCount` field and `warnings=["slides=N"]` (`DocReadPptx.swift:34, 40, 45`) | `metadata["slides"] = slideCount` (`DocReadPptxTool.cs:44`) | OK | |

### EPUB

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | `/usr/bin/unzip` + `Foundation.XMLParser` + `DocReadHtml.stripHTML` (`DocReadEpub.swift:14-18`) | `VersOne.Epub` + AngleSharp (`DocReadEpubTool.cs:3-6`) | DIVERGE | MEDIUM / intentional per file header (`DocReadEpub.swift:1-16`). |
| Container walk | `META-INF/container.xml` → OPF full-path (`DocReadEpub.swift:29-38, 101-124`) | Encapsulated by VersOne.Epub | SEM-OK | Openclicky implements the spec explicitly. |
| OPF spine order | `<itemref idref>` sequence + `<manifest><item id href>` map (`DocReadEpub.swift:135-195`) | `book.ReadingOrder` (VersOne resolves OPF spine) (`DocReadEpubTool.cs:27`) | SEM-OK | Both walk spine order. |
| Chapter body | HTML from spine item → `DocReadHtml.stripHTML` (`DocReadEpub.swift:67-70`) | `AngleSharp.ParseDocument(item.Content).Body?.TextContent` (`DocReadEpubTool.cs:29-31`) | DIVERGE | LOW — different HTML strippers, same intent (visible text). Whitespace not byte-exact. |
| Title / author | Parse `<dc:title>` / `<dc:creator>` from OPF (`DocReadEpub.swift:152-195`); emit as `warnings=["title=...", "author=..."]` (`DocReadEpub.swift:54-56`) | `book.Title` / `book.Author` (`DocReadEpubTool.cs:36-37`) | OK-content, DIVERGE-shape | Content match; shape flattened to warnings. |
| Chapter count | `warnings=["chapters=N"]` and `pageCount = chapters` (`DocReadEpub.swift:73, 78`) | `metadata["chapters"] = chapters` (`DocReadEpubTool.cs:38`) | OK | |
| Path normalization | Explicit `a/b/../c → a/c` collapse (`DocReadEpub.swift:89-97`) | Encapsulated by VersOne | SEM-OK | Openclicky reproduces the OPF spec's relative-href resolution. |
| Container/OPF errors | `throw DocReaderError.parseFailed(...)` with specific message (`DocReadEpub.swift:31-32, 41-42, 108-111`) | Catch-all `ToolErrors.FromException(...)` (`DocReadEpubTool.cs:42-45`) | OK — different mechanism, same "fail with reason". |

### HTML

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Library | Manual strip (no library) (`DocReadHtml.swift:8-16, 68-122`) | AngleSharp `HtmlParser` (`DocReadHtmlTool.cs:2, 21-23`) | DIVERGE | MEDIUM / intentional per file header (`DocReadHtml.swift:1-16`). Whitespace exactness differs; visible tokens preserved. |
| Encoding | UTF-8 / GB18030 / Latin-1 chain (`DocReadHtml.swift:27-29`) | Same chain via `ReadAllTextWithFallback` (`DocReadHtmlTool.cs:20`) | OK | |
| Title extract | `<title>...</title>` case-insensitive substring extraction + entity decode (`DocReadHtml.swift:49-63`) | `dom.Title` (`DocReadHtmlTool.cs:26`) | SEM-OK | Both extract the same source. Openclicky trims + decodes entities inline. |
| Body extraction | Remove `<script>` / `<style>` blocks; replace `</p>` / `</div>` / `<br>` / `</li>` / `</h1>-</h6>` / `</tr>` with `\n`; strip remaining tags; decode entities (`DocReadHtml.swift:68-87`) | `dom.Body?.TextContent` (`DocReadHtmlTool.cs:23`) | DIVERGE | LOW — different strip; visible-token preservation but not byte-identical whitespace. |
| Entities | Named (`amp/lt/gt/quot/apos/nbsp/copy/reg`) + numeric decimal + numeric hex (`DocReadHtml.swift:126-161`) | AngleSharp's full HTML5 entity set | DIVERGE | LOW — openclicky handles common subset only. Uncommon entities (`&mdash;` / `&hellip;` / …) pass through as-is on openclicky. |
| Title emitted | `warnings=["title=<t>"]` (`DocReadHtml.swift:32`) | `metadata["title"]` (`DocReadHtmlTool.cs:26`) | OK-content | |

### TXT

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| Encoding chain | UTF-8 → GB18030 → Latin-1 (`DocReadTxt.swift:18`) | Same (`DocReadTxtTool.cs:20`) | OK | |
| Byte-size | `FileManager.default.attributesOfItem` → `warnings=["bytes=<n>"]` (`DocReadTxt.swift:21-24`) | `new FileInfo(path).Length` → `metadata["bytes"]` (`DocReadTxtTool.cs:23`) | OK-content | |
| Encoding-fallback signal | `warnings=["encoding_fallback=<enc>"]` (`DocReadTxt.swift:25-27`) | Not surfaced (silently swallowed) | DIVERGE-additive | Superset. LOW. |
| Truncated | Via `DocReaderShared.capped` (`DocReadTxt.swift:29`) | Via `DocReaderResult.Build` (`DocReadTxtTool.cs:21`) | OK | |

## Issues Found

- **LOW** — `DocReadPdf`: Empty page emits nothing (`DocReadPdf.swift:50-53`), Everywhere emits a stray `\n` (via `AppendLine("")`). Byte-diff on edge cases. Trivial fix — always `sb.append("\n")` even when `page.string` is nil.

- **LOW** — `DocReadHtml`: Entity decoder covers only 8 named entities (`DocReadHtml.swift:127-130`). Everywhere via AngleSharp handles the full HTML5 named-entity set. Docs with `&mdash;`, `&hellip;`, `&trade;`, `&ldquo;`, `&rdquo;`, `&laquo;`, `&raquo;`, `&#8226;` etc. will keep the raw entity in the extracted text. Fix: extend the `named` dict with the ~50 common HTML entities; or drop in a small vendored map.

- **LOW** — `DocReadHtml` block-close list at `DocReadHtml.swift:74` handles `/p, /div, /br, br, /li, /h1-6, /tr`. Missing: `/table, /section, /article, /header, /footer, /nav, /aside, /pre, /blockquote, /ul, /ol, /dd, /dt`. Documents heavy on these block-level elements will produce run-together paragraphs. Fix: expand list.

- **LOW** — Per-format metadata (paragraphs / sheets / slides / chapters / title / author / bytes / encoding_fallback) is stringified into `warnings` (e.g. `"paragraphs=12"`). Consumers must parse strings to recover named fields. Alternative: keep the free-form `warnings` list AND add a `[String: String]` `metadata` field to `DocReaderResult` for structured round-trip. Documented in header (`CaptureTypes.swift:1794-1798`) as intentional but adds friction for downstream JSON consumers.

- **LOW** — `maxPages` argument accepted but silently ignored by DOCX, XLSX, PPTX, EPUB, HTML, TXT (`_ = maxPages` in each). Signature-parity across readers but not semantic — a caller passing `maxPages: 5` to `DocReadXlsx.read(...)` sees zero effect. Fix options: (a) drop the arg from signatures that can't honor it — but that breaks the "one arg shape across readers" API property; (b) add an actual sheet-cap / slide-cap / chapter-cap in the readers that support paged output; (c) document behavior at each reader's signature.

- **LOW** — DOCX text-run handling differs from Everywhere. Openclicky preserves `w:tab` → `\t` and `w:br`/`w:cr` → `\n` (`DocReadDocx.swift:112-115`); Everywhere's `InnerText` flattens both to nothing. On docs with tab-aligned tables or explicit line-break runs, openclicky will emit tabs/newlines that Everywhere would drop. Byte-diff. Direction of the discrepancy favors openclicky (more information preserved), but not byte-parity.

- **LOW** — `AppendLine` on macOS/.NET emits `\n`; on Windows/.NET it emits `\r\n`. On the Everywhere macOS build these match Swift `"\n"`; on a Windows Everywhere build they diverge. Not actionable at the openclicky end but worth noting for cross-fleet golden-diff fixtures.

- **LOW** — `DocReaderShared.capped` uses `.count` (grapheme cluster count, not UTF-16 code-unit count) for the 2M cap (`DocReaderResult.swift:29-31`); Everywhere uses `text.Length` (UTF-16 code units) (`DocReaderResult.cs:28-32`). For CJK-heavy content the openclicky cap fires at a HIGHER byte count than Everywhere's (each CJK grapheme is 1 unit for Swift `count`, still 1 unit for C# `Length` since C#'s `string.Length` is UTF-16 code units — a CJK character in BMP is 1 code unit; emoji is 2 code units). Difference surfaces for emoji-heavy or extended-grapheme content. Non-goal for typical docs, but the units aren't identical.

- **LOW** — HTML strip does not collapse runs of whitespace (comment at `DocReadHtml.swift:85-87` explicitly says "preserve single newlines"). Everywhere's `TextContent` also doesn't collapse. Consumers doing `.trim().split()` are unaffected; string-equality golden diffs would differ.

## Verdict

- [ ] BYTE_MATCH
- [x] SEMANTIC_MATCH — result shape (`text` + per-format metadata + `warnings`), text content for the primary body, sheet/slide/paragraph/chapter counts, PDF `likely_scanned` threshold (100 chars), CSV escape rules for XLSX (byte-identical), encoding fallback chain, and file-not-found preflight all line up. Library substitutions (PdfPig→PDFKit, OpenXml→unzip+XMLParser, VersOne+AngleSharp→manual OPF walk + manual HTML strip, AngleSharp→manual HTML strip) are documented at each file header as intentional and produce equivalent output for typical inputs.
- [ ] DIVERGENT
- [ ] BROKEN

## Recommendations

Prioritized fix list:

1. **HTML entity coverage** (`DocReadHtml.swift:127-130`): extend the named entity dict to include at minimum `mdash / ndash / hellip / trade / ldquo / rdquo / lsquo / rsquo / laquo / raquo / bull / middot / times / divide / deg / sect / para / plusmn / frac12 / frac14 / frac34 / not / brvbar / iexcl / iquest / cent / pound / yen / euro`. ~50 entries.

2. **HTML block-close coverage** (`DocReadHtml.swift:74`): extend the block-tag list with `/table, /section, /article, /header, /footer, /nav, /aside, /pre, /blockquote, /ul, /ol, /dd, /dt` for closer visual-paragraph fidelity.

3. **`maxPages` non-honor** (all readers except PDF): pick one of (a) drop the arg from non-honoring reader signatures, (b) implement sheet/slide/chapter caps, or (c) document the no-op explicitly in each ignoring reader's Doc comment. Currently `_ = maxPages` is silent.

4. **`DocReaderResult` metadata shape**: consider adding a first-class `metadata: [String: String]` field alongside `warnings` so downstream JSON consumers get structured round-trip instead of parsing `"key=value"` strings. Non-blocking but improves API ergonomics.

5. **PDF empty-page byte-parity** (`DocReadPdf.swift:50-53`): always append `"\n"` after each page attempt (including when `page.string` is nil) to match Everywhere's `AppendLine` behavior on empty content.

6. Nothing else is blocking. Readers are semantically parity-matched with Everywhere for the common cases; documented deviations are all intentional and callable-out at file headers.
