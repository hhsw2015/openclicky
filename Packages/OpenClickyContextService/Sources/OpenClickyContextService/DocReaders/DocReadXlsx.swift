// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocReadXlsxTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere reads .xlsx via DocumentFormat.OpenXml. For each `Sheet`
// it walks `Row`/`Cell`, resolves shared-string references, and joins
// per-row cells with `,`, escaping the CSV specials `,` `"` `\n` `\r`
// with `""` doubling and outer quotes. Result: `xlsx2csv`-like output,
// one row per line, blank line between sheets is NOT introduced (the
// Everywhere code appends only per-row lines, so sheets are
// concatenated back-to-back).
//
// On Swift we parse the zip parts directly:
//   xl/sharedStrings.xml   -> array of <si><t>...</t></si> texts
//   xl/workbook.xml        -> ordered <sheet> list (name + r:id)
//   xl/_rels/workbook.xml.rels -> r:id -> Target file (sheet1.xml etc.)
//   xl/worksheets/sheetN.xml -> rows of <row><c t="s|inlineStr|..." ><v>i</v></c></row>

import Foundation

public enum DocReadXlsx {

    public static let mimeType =
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    public static func read(path: URL, maxPages: Int? = nil) async throws -> DocReaderResult {
        _ = maxPages
        try DocReaderShared.requireExists(path)

        let entries = try ZipEntryReader.listEntries(archive: path)
        var warnings: [String] = []

        // Shared strings (optional).
        var sharedStrings: [String] = []
        if entries.contains("xl/sharedStrings.xml"),
           let data = try? ZipEntryReader.readEntry(archive: path, entry: "xl/sharedStrings.xml") {
            sharedStrings = try parseSharedStrings(data)
        }

        // Sheet order.
        guard entries.contains("xl/workbook.xml") else {
            warnings.append("no-workbook")
            return DocReaderResult(
                text: "",
                pageCount: 0,
                wordCount: nil,
                mimeType: mimeType,
                warnings: warnings
            )
        }
        let workbookData = try ZipEntryReader.readEntry(archive: path, entry: "xl/workbook.xml")
        let sheetRefs = try parseWorkbook(workbookData)

        // rId -> target map.
        var relMap: [String: String] = [:]
        if entries.contains("xl/_rels/workbook.xml.rels"),
           let relData = try? ZipEntryReader.readEntry(
               archive: path, entry: "xl/_rels/workbook.xml.rels") {
            relMap = try parseRels(relData)
        }

        var sb = ""
        var sheetCount = 0

        for sheet in sheetRefs {
            sheetCount += 1
            let rel = relMap[sheet.rId] ?? "worksheets/sheet\(sheetCount).xml"
            // Rels targets are relative to xl/.
            let entry = "xl/\(rel)"
            if !entries.contains(entry) { continue }
            let data = try ZipEntryReader.readEntry(archive: path, entry: entry)
            let rows = try parseSheet(data, sharedStrings: sharedStrings)
            for row in rows {
                sb.append(row.map(csvEscape).joined(separator: ","))
                sb.append("\n")
            }
        }

        warnings.append("sheets=\(sheetCount)")
        let capped = DocReaderShared.capped(sb, warnings: &warnings)

        return DocReaderResult(
            text: capped,
            pageCount: sheetCount,
            wordCount: nil,
            mimeType: mimeType,
            warnings: warnings
        )
    }

    // MARK: - CSV

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            let doubled = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        return s
    }

    // MARK: - XML parts

    private static func parseSharedStrings(_ data: Data) throws -> [String] {
        let d = SharedStringsDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("sharedStrings.xml: \(err.localizedDescription)")
            }
        }
        return d.strings
    }

    private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var currentSI: String?
        private var buffer = ""
        private var inT = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = docXMLLocalName(qName ?? elementName)
            if name == "si" {
                currentSI = ""
            } else if name == "t" {
                inT = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { buffer.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = docXMLLocalName(qName ?? elementName)
            if name == "t" {
                inT = false
                currentSI?.append(buffer)
                buffer = ""
            } else if name == "si" {
                strings.append(currentSI ?? "")
                currentSI = nil
            }
        }
    }

    struct SheetRef { let name: String; let rId: String }

    private static func parseWorkbook(_ data: Data) throws -> [SheetRef] {
        let d = WorkbookDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("workbook.xml: \(err.localizedDescription)")
            }
        }
        return d.sheets
    }

    private final class WorkbookDelegate: NSObject, XMLParserDelegate {
        var sheets: [SheetRef] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if docXMLLocalName(qName ?? elementName) == "sheet" {
                let name = attributeDict["name"] ?? ""
                // r:id may appear as `r:id` or (rare) `id` after namespace strip.
                let rid = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
                sheets.append(SheetRef(name: name, rId: rid))
            }
        }
    }

    private static func parseRels(_ data: Data) throws -> [String: String] {
        let d = RelsDelegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("workbook.xml.rels: \(err.localizedDescription)")
            }
        }
        return d.map
    }

    private final class RelsDelegate: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if docXMLLocalName(qName ?? elementName) == "Relationship" {
                if let id = attributeDict["Id"], let tgt = attributeDict["Target"] {
                    map[id] = tgt
                }
            }
        }
    }

    private static func parseSheet(_ data: Data, sharedStrings: [String]) throws -> [[String]] {
        let d = SheetDelegate(sharedStrings: sharedStrings)
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        if !p.parse() {
            if let err = p.parserError {
                throw DocReaderError.parseFailed("sheet xml: \(err.localizedDescription)")
            }
        }
        return d.rows
    }

    private final class SheetDelegate: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        var rows: [[String]] = []

        private var currentRow: [String] = []
        private var currentCellType: String?
        private var currentValue = ""
        private var inV = false
        private var inInlineStr = false
        private var inT = false

        init(sharedStrings: [String]) {
            self.sharedStrings = sharedStrings
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = docXMLLocalName(qName ?? elementName)
            switch name {
            case "row":
                currentRow = []
            case "c":
                currentCellType = attributeDict["t"]
                currentValue = ""
                inInlineStr = false
            case "v":
                inV = true
                currentValue = ""
            case "is":
                inInlineStr = true
            case "t":
                if inInlineStr { inT = true; currentValue = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inV || inT { currentValue.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = docXMLLocalName(qName ?? elementName)
            switch name {
            case "v":
                inV = false
            case "t":
                inT = false
            case "is":
                inInlineStr = false
            case "c":
                let resolved: String
                if currentCellType == "s", let idx = Int(currentValue),
                   idx >= 0, idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                } else {
                    // inlineStr / str / number / bool / date / etc.
                    resolved = currentValue
                }
                currentRow.append(resolved)
                currentCellType = nil
                currentValue = ""
            case "row":
                rows.append(currentRow)
                currentRow = []
            default: break
            }
        }
    }
}
