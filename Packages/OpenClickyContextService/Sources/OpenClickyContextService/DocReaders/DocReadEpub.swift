// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadEpubTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere reads .epub via VersOne.Epub + AngleSharp. It iterates
// `book.ReadingOrder` (the spine), parses each chapter's HTML with
// AngleSharp, and appends `dom.Body?.TextContent`. Metadata: title,
// author, chapters.
//
// On Swift we open the archive with unzip and manually resolve the
// spine:
//   1. META-INF/container.xml -> full-path to the OPF manifest
//   2. OPF file: <manifest> maps `id` -> `href`; <spine> lists reading
//      order via idrefs; <metadata> carries dc:title / dc:creator.
//   3. Each spine document (usually XHTML) is HTML-stripped via
//      DocReadHtml.stripHTML for content-parity with the Everywhere
//      pipeline (both flatten to visible text).

import Foundation

public enum DocReadEpub {

    public static let mimeType = "application/epub+zip"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages
        try DocReaderShared.requireExists(path)

        let entries = try ZipEntryReader.listEntries(archive: path)

        // 1. container.xml
        guard entries.contains("META-INF/container.xml") else {
            throw DocReaderError.parseFailed("epub missing META-INF/container.xml")
        }
        let containerData = try ZipEntryReader.readEntry(
            archive: path, entry: "META-INF/container.xml")
        guard let opfPath = try parseContainer(containerData) else {
            throw DocReaderError.parseFailed("epub container has no rootfile")
        }

        // 2. OPF
        guard entries.contains(opfPath) else {
            throw DocReaderError.parseFailed("epub OPF missing: \(opfPath)")
        }
        let opfData = try ZipEntryReader.readEntry(archive: path, entry: opfPath)
        let opf = try parseOPF(opfData)

        // 3. Spine walk. hrefs are relative to the OPF dir.
        let opfDir: String = {
            if let slash = opfPath.lastIndex(of: "/") {
                return String(opfPath[..<slash])
            }
            return ""
        }()

        var warnings: [String] = []
        if let t = opf.title { warnings.append("title=\(t)") }
        if let a = opf.author { warnings.append("author=\(a)") }

        var sb = ""
        var chapters = 0

        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let full = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            let normalized = normalizePath(full)
            if !entries.contains(normalized) { continue }
            chapters += 1
            let data = try ZipEntryReader.readEntry(archive: path, entry: normalized)
            let html = String(data: data, encoding: .utf8) ?? ""
            sb.append(DocReadHtml.stripHTML(html))
            sb.append("\n")
        }

        warnings.append("chapters=\(chapters)")
        let capped = DocReaderShared.capped(sb, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: chapters,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }

    // MARK: - path normalization

    /// Collapse `a/b/../c` -> `a/c`. Epub OPF hrefs sometimes escape the
    /// OPF directory with `../`.
    static func normalizePath(_ p: String) -> String {
        var parts: [String] = []
        for seg in p.split(separator: "/") {
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if seg == "." { continue }
            else { parts.append(String(seg)) }
        }
        return parts.joined(separator: "/")
    }

    // MARK: - container.xml

    private static func parseContainer(_ data: Data) throws -> String? {
        let d = ContainerDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("container.xml: \(err.localizedDescription)")
            }
        }
        return d.fullPath
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var fullPath: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if docXMLLocalName(qName ?? elementName) == "rootfile" {
                fullPath = attributeDict["full-path"] ?? fullPath
            }
        }
    }

    // MARK: - OPF

    struct OPF {
        let manifest: [String: String]  // id -> href
        let spine: [String]              // ordered idrefs
        let title: String?
        let author: String?
    }

    private static func parseOPF(_ data: Data) throws -> OPF {
        let d = OPFDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("OPF: \(err.localizedDescription)")
            }
        }
        return OPF(
            manifest: d.manifest,
            spine: d.spine,
            title: d.title.isEmpty ? nil : d.title,
            author: d.author.isEmpty ? nil : d.author
        )
    }

    private final class OPFDelegate: NSObject, XMLParserDelegate {
        var manifest: [String: String] = [:]
        var spine: [String] = []
        var title = ""
        var author = ""

        private var currentText = ""
        private var currentTag: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let raw = qName ?? elementName
            let name = docXMLLocalName(raw)
            switch name {
            case "item":
                if let id = attributeDict["id"], let href = attributeDict["href"] {
                    manifest[id] = href
                }
            case "itemref":
                if let idref = attributeDict["idref"] { spine.append(idref) }
            case "title", "creator":
                currentTag = name
                currentText = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentTag != nil { currentText.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = docXMLLocalName(qName ?? elementName)
            if name == "title" && currentTag == "title" {
                if title.isEmpty { title = currentText }
                currentTag = nil
            } else if name == "creator" && currentTag == "creator" {
                if author.isEmpty { author = currentText }
                currentTag = nil
            }
        }
    }
}
