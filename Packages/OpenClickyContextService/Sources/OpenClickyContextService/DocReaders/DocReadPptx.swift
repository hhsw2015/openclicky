// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadPptxTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere iterates `PresentationPart.SlideParts` and for each slide
// concatenates every `<a:t>` element (DrawingML text) with newline
// separators. `SlideParts` is ordered per the OpenXml relationship
// walk, which for practical inputs is slide1.xml, slide2.xml, ...
//
// On Swift we unzip the .pptx and enumerate `ppt/slides/slide*.xml`
// entries in natural-number order. For each slide we run an XMLParser
// that emits the text of every `a:t` (namespace-stripped local
// name = "t") on its own line.

import Foundation

public enum DocReadPptx {

    public static let mimeType =
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages
        try DocReaderShared.requireExists(path)

        let entries = try ZipEntryReader.listEntries(archive: path)
        let slidePaths = entries
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted(by: pptxSlideOrder)

        var warnings: [String] = []
        var sb = ""
        var slideCount = 0

        for entry in slidePaths {
            slideCount += 1
            let data = try ZipEntryReader.readEntry(archive: path, entry: entry)
            let parsed = try parseSlide(data)
            sb.append(parsed)
        }

        warnings.append("slides=\(slideCount)")
        let capped = DocReaderShared.capped(sb, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: slideCount,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }

    /// Natural-number ordering on the "N" in "slideN.xml" (slide2 before slide10).
    private static func pptxSlideOrder(_ a: String, _ b: String) -> Bool {
        func idx(_ s: String) -> Int {
            let base = (s as NSString).lastPathComponent
            let digits = base.drop(while: { !$0.isNumber })
                .prefix(while: { $0.isNumber })
            return Int(digits) ?? Int.max
        }
        return idx(a) < idx(b)
    }

    private static func parseSlide(_ data: Data) throws -> String {
        let d = SlideDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("slide xml: \(err.localizedDescription)")
            }
        }
        return d.output
    }

    private final class SlideDelegate: NSObject, XMLParserDelegate {
        var output = ""
        private var inT = false
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            // pptx uses a:t (DrawingML) but namespace stripping yields "t".
            if docXMLLocalName(qName ?? elementName) == "t" {
                inT = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { buffer.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if docXMLLocalName(qName ?? elementName) == "t" {
                output.append(buffer)
                output.append("\n")
                inT = false
                buffer = ""
            }
        }
    }
}
