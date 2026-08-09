// Ported from Everywhere: src/Everywhere.Mcp/Tools/DocRead*Tool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Behavioural coverage for the 7 doc readers ported from Everywhere.
// Fixtures are synthesised in a per-test temp directory so tests do
// not need a checked-in binary corpus. .docx / .xlsx / .pptx / .epub
// are built as spec-conformant minimal zip archives via /usr/bin/zip.

import XCTest
import AppKit
import CoreGraphics
import CoreText
@testable import OpenClickyContextService

// MARK: - Shared fixture helpers

private enum DocFixtures {
    static func tempDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-doc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Build a zip archive whose contents match `parts` (path -> UTF-8
    /// text). Uses `/usr/bin/zip` which is present on every macOS.
    static func makeZip(at output: URL, parts: [(String, String)]) throws {
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (path, body) in parts {
            let full = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: full.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.data(using: .utf8)!.write(to: full)
        }
        // Zip inside staging so relative paths are preserved.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = staging
        proc.arguments = ["-r", "-q", output.path, "."]
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: staging)
    }
}

// MARK: - PDF

final class DocReadPdfTests: XCTestCase {
    func test_missingFile_throwsFileNotFound() async {
        let url = URL(fileURLWithPath: "/tmp/openclicky-nonexistent-\(UUID().uuidString).pdf")
        do {
            _ = try await DocReadPdf.read(path: url)
            XCTFail("expected fileNotFound")
        } catch let err as DocReaderError {
            if case .fileNotFound = err { return }
            XCTFail("expected .fileNotFound, got \(err)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_readsSyntheticPDF() async throws {
        // Build a 1-page PDF with PDFKit so we don't need a binary fixture.
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hello.pdf")

        // PDFKit has no cross-platform text-emitting builder without
        // AppKit view drawing. Use CGPDFContext directly.
        makeSyntheticPDF(at: url, text: "Hello OpenClicky")

        let result = try await DocReadPdf.read(path: url)
        XCTAssertEqual(result.mimeType, "application/pdf")
        XCTAssertNotNil(result.pageCount)
        XCTAssertGreaterThanOrEqual(result.pageCount ?? 0, 1)
    }
}

// PDF construction helper (module-level so it's testable without exposing
// PDF context noise inside the reader). Draws one string on one page.
private func makeSyntheticPDF(at url: URL, text: String) {
    let mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    var box = mediaBox
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    // Very simple text rendering: use Core Text via NSString+attributes
    // isn't available without a font selector, so draw via NSString-into-context.
    let ns = text as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24)
    ]
    let attributed = NSAttributedString(string: ns as String, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = CGPoint(x: 72, y: 720)
    CTLineDraw(line, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

// MARK: - DOCX

final class DocReadDocxTests: XCTestCase {
    private static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:r><w:t>Hello docx</w:t></w:r></w:p>
        <w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>
      </w:body>
    </w:document>
    """

    func test_readsBodyParagraphs() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.docx")
        try DocFixtures.makeZip(at: url, parts: [("word/document.xml", Self.documentXML)])

        let r = try await DocReadDocx.read(path: url)
        XCTAssertTrue(r.text.contains("Hello docx"))
        XCTAssertTrue(r.text.contains("Second paragraph."))
        XCTAssertTrue(r.warnings.contains("paragraphs=2"),
                      "warnings=\(r.warnings)")
    }

    func test_missingFile_throwsFileNotFound() async {
        let url = URL(fileURLWithPath: "/tmp/openclicky-none-\(UUID().uuidString).docx")
        do {
            _ = try await DocReadDocx.read(path: url)
            XCTFail("expected fileNotFound")
        } catch let err as DocReaderError {
            if case .fileNotFound = err { return }
            XCTFail("got \(err)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: - XLSX

final class DocReadXlsxTests: XCTestCase {
    private static let shared = """
    <?xml version="1.0"?>
    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
      <si><t>alpha</t></si>
      <si><t>beta</t></si>
    </sst>
    """
    private static let workbook = """
    <?xml version="1.0"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """
    private static let rels = """
    <?xml version="1.0"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/>
    </Relationships>
    """
    private static let sheet = """
    <?xml version="1.0"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        <row r="1">
          <c r="A1" t="s"><v>0</v></c>
          <c r="B1" t="s"><v>1</v></c>
        </row>
        <row r="2">
          <c r="A2"><v>42</v></c>
          <c r="B2"><v>3.14</v></c>
        </row>
      </sheetData>
    </worksheet>
    """

    func test_readsSheetAsCSV() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.xlsx")
        try DocFixtures.makeZip(at: url, parts: [
            ("xl/sharedStrings.xml", Self.shared),
            ("xl/workbook.xml", Self.workbook),
            ("xl/_rels/workbook.xml.rels", Self.rels),
            ("xl/worksheets/sheet1.xml", Self.sheet),
        ])
        let r = try await DocReadXlsx.read(path: url)
        XCTAssertEqual(r.pageCount, 1, "expected 1 sheet")
        XCTAssertTrue(r.text.contains("alpha,beta"), "text=\(r.text)")
        XCTAssertTrue(r.text.contains("42,3.14"), "text=\(r.text)")
        XCTAssertTrue(r.warnings.contains("sheets=1"))
    }

    func test_csvEscapesCommaAndQuote() async throws {
        let sheetXML = """
        <?xml version="1.0"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>a,b</t></is></c><c r="B1" t="inlineStr"><is><t>c"d</t></is></c></row>
          </sheetData>
        </worksheet>
        """
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.xlsx")
        try DocFixtures.makeZip(at: url, parts: [
            ("xl/workbook.xml", Self.workbook),
            ("xl/_rels/workbook.xml.rels", Self.rels),
            ("xl/worksheets/sheet1.xml", sheetXML),
        ])
        let r = try await DocReadXlsx.read(path: url)
        XCTAssertTrue(r.text.contains("\"a,b\""), "text=\(r.text)")
        XCTAssertTrue(r.text.contains("\"c\"\"d\""), "text=\(r.text)")
    }
}

// MARK: - PPTX

final class DocReadPptxTests: XCTestCase {
    private static let slide1 = """
    <?xml version="1.0"?>
    <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
           xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <p:cSld><p:spTree>
        <p:sp><p:txBody>
          <a:p><a:r><a:t>Slide one title</a:t></a:r></a:p>
        </p:txBody></p:sp>
      </p:spTree></p:cSld>
    </p:sld>
    """
    private static let slide2 = """
    <?xml version="1.0"?>
    <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
           xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
      <p:cSld><p:spTree>
        <p:sp><p:txBody>
          <a:p><a:r><a:t>Slide two body</a:t></a:r></a:p>
        </p:txBody></p:sp>
      </p:spTree></p:cSld>
    </p:sld>
    """

    func test_readsSlidesInOrder() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.pptx")
        try DocFixtures.makeZip(at: url, parts: [
            ("ppt/slides/slide1.xml", Self.slide1),
            ("ppt/slides/slide2.xml", Self.slide2),
        ])
        let r = try await DocReadPptx.read(path: url)
        XCTAssertEqual(r.pageCount, 2)
        let idx1 = r.text.range(of: "Slide one title")?.lowerBound
        let idx2 = r.text.range(of: "Slide two body")?.lowerBound
        XCTAssertNotNil(idx1)
        XCTAssertNotNil(idx2)
        if let a = idx1, let b = idx2 {
            XCTAssertLessThan(a, b, "slide order preserved")
        }
    }
}

// MARK: - EPUB

final class DocReadEpubTests: XCTestCase {
    private static let container = """
    <?xml version="1.0"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf"
                  media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
    private static let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Test Book</dc:title>
        <dc:creator>Jane Doe</dc:creator>
      </metadata>
      <manifest>
        <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
      </spine>
    </package>
    """
    private static let chap1 = """
    <html><body><p>First chapter body.</p></body></html>
    """
    private static let chap2 = """
    <html><body><p>Second chapter body.</p></body></html>
    """

    func test_readsSpineChapters() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.epub")
        try DocFixtures.makeZip(at: url, parts: [
            ("META-INF/container.xml", Self.container),
            ("OEBPS/content.opf", Self.opf),
            ("OEBPS/chap1.xhtml", Self.chap1),
            ("OEBPS/chap2.xhtml", Self.chap2),
        ])
        let r = try await DocReadEpub.read(path: url)
        XCTAssertEqual(r.pageCount, 2)
        XCTAssertTrue(r.text.contains("First chapter body."), "text=\(r.text)")
        XCTAssertTrue(r.text.contains("Second chapter body."), "text=\(r.text)")
        XCTAssertTrue(r.warnings.contains("title=Test Book"), "warnings=\(r.warnings)")
        XCTAssertTrue(r.warnings.contains("author=Jane Doe"), "warnings=\(r.warnings)")
        XCTAssertTrue(r.warnings.contains("chapters=2"), "warnings=\(r.warnings)")
    }
}

// MARK: - HTML

final class DocReadHtmlTests: XCTestCase {
    func test_stripsTagsAndKeepsTextContent() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.html")
        let html = """
        <!doctype html>
        <html>
          <head>
            <title>My Page</title>
            <style>body { color: red; }</style>
          </head>
          <body>
            <script>console.log('should not appear');</script>
            <h1>Heading</h1>
            <p>Hello&nbsp;world &amp; friends.</p>
          </body>
        </html>
        """
        try html.data(using: .utf8)!.write(to: url)
        let r = try await DocReadHtml.read(path: url)
        XCTAssertFalse(r.text.contains("console.log"), "script leaked")
        XCTAssertFalse(r.text.contains("color: red"), "style leaked")
        XCTAssertTrue(r.text.contains("Heading"))
        XCTAssertTrue(r.text.contains("Hello world & friends."), "text=\(r.text)")
        XCTAssertTrue(r.warnings.contains("title=My Page"), "warnings=\(r.warnings)")
    }

    func test_missingFile_throwsFileNotFound() async {
        let url = URL(fileURLWithPath: "/tmp/openclicky-none-\(UUID().uuidString).html")
        do {
            _ = try await DocReadHtml.read(path: url)
            XCTFail("expected fileNotFound")
        } catch let err as DocReaderError {
            if case .fileNotFound = err { return }
            XCTFail("got \(err)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

// MARK: - TXT

final class DocReadTxtTests: XCTestCase {
    func test_readsUtf8() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.txt")
        let payload = "hello 世界"
        try payload.data(using: .utf8)!.write(to: url)
        let r = try await DocReadTxt.read(path: url)
        XCTAssertEqual(r.text, payload)
        XCTAssertFalse(r.warnings.contains("encoding_fallback=latin1"))
    }

    func test_fallbackToLatin1WhenNotUtf8() async throws {
        let dir = try DocFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.txt")
        // 0xE9 = é in Latin-1 but invalid UTF-8 on its own.
        let bytes: [UInt8] = [0x68, 0x69, 0x20, 0xE9, 0x21]
        try Data(bytes).write(to: url)
        let r = try await DocReadTxt.read(path: url)
        let fell = r.warnings.contains(where: { $0.hasPrefix("encoding_fallback=") })
        XCTAssertTrue(fell, "expected encoding_fallback warning, got \(r.warnings)")
    }

    func test_missingFile_throwsFileNotFound() async {
        let url = URL(fileURLWithPath: "/tmp/openclicky-none-\(UUID().uuidString).txt")
        do {
            _ = try await DocReadTxt.read(path: url)
            XCTFail("expected fileNotFound")
        } catch let err as DocReaderError {
            if case .fileNotFound = err { return }
            XCTFail("got \(err)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
