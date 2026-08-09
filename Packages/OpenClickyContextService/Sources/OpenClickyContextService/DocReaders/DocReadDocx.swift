// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadDocxTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere opens .docx via DocumentFormat.OpenXml and walks
// `Paragraph` descendants of the main document body, then footnotes,
// endnotes, headers, footers - emitting each paragraph's InnerText on
// its own line (mirrors `pandoc -t plain`).
//
// OpenXml is a .NET dependency. On Swift/macOS we treat the .docx as a
// zip archive (which it is) and parse the XML parts we need with
// `Foundation.XMLParser`. The parts of interest are:
//   - word/document.xml      (body)
//   - word/footnotes.xml     (optional)
//   - word/endnotes.xml      (optional)
//   - word/header*.xml       (optional, N files)
//   - word/footer*.xml       (optional, N files)
// The relevant text-carrying element is `<w:t>` (and `<w:tab>` /
// `<w:br>` for whitespace - we substitute a tab / newline). Paragraphs
// are `<w:p>`: at each `</w:p>` we emit a newline. This matches
// OpenXml's `Paragraph.InnerText` + `sb.AppendLine` shape.

import Foundation

public enum DocReadDocx {

    public static let mimeType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages // docx has no page concept at parse-time
        try DocReaderShared.requireExists(path)

        let entries = try ZipEntryReader.listEntries(archive: path)

        // Body is required. Everywhere handles a missing body gracefully
        // (empty output). We surface that as a warning so tests can see it.
        var warnings: [String] = []
        var sb = ""
        var paragraphCount = 0

        if entries.contains("word/document.xml") {
            let data = try ZipEntryReader.readEntry(archive: path, entry: "word/document.xml")
            let parsed = try parseWordXML(data)
            sb.append(parsed.text)
            paragraphCount += parsed.paragraphs
        } else {
            warnings.append("no-main-document")
        }

        // Footnotes + endnotes.
        for ent in ["word/footnotes.xml", "word/endnotes.xml"] {
            if entries.contains(ent) {
                if let data = try? ZipEntryReader.readEntry(archive: path, entry: ent) {
                    let parsed = try parseWordXML(data)
                    sb.append(parsed.text)
                }
            }
        }

        // Headers and footers. Everywhere iterates HeaderParts / FooterParts
        // in package order. `unzip -Z1` lists in archive order which is the
        // same insertion order.
        for ent in entries {
            let name = (ent as NSString).lastPathComponent
            if (name.hasPrefix("header") && name.hasSuffix(".xml")) ||
                (name.hasPrefix("footer") && name.hasSuffix(".xml")) {
                if let data = try? ZipEntryReader.readEntry(archive: path, entry: ent) {
                    let parsed = try parseWordXML(data)
                    sb.append(parsed.text)
                }
            }
        }

        let capped = DocReaderShared.capped(sb, warnings: &warnings)
        warnings.append("paragraphs=\(paragraphCount)")

        return DocReaderResult(
            text: capped,
            pageCount: nil,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }

    // MARK: - XML

    private static func parseWordXML(_ data: Data) throws -> (text: String, paragraphs: Int) {
        let delegate = DocxDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            if let err = parser.parserError {
                throw DocReaderError.parseFailed("docx xml: \(err.localizedDescription)")
            }
        }
        return (delegate.output, delegate.paragraphCount)
    }

    private final class DocxDelegate: NSObject, XMLParserDelegate {
        var output = ""
        var paragraphCount = 0
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let local = docXMLLocalName(qName ?? elementName)
            switch local {
            case "t":
                inText = true
            case "tab":
                output.append("\t")
            case "br", "cr":
                output.append("\n")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { output.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let local = docXMLLocalName(qName ?? elementName)
            switch local {
            case "t":
                inText = false
            case "p":
                paragraphCount += 1
                output.append("\n")
            default:
                break
            }
        }
    }
}
