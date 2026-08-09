// Ported from Everywhere: src/Everywhere.Mac/Interop/MacVisionOcrEngine.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for OCRCapture. Vision runs against images we render
// on the fly with Core Graphics — no fixture files, no WindowServer, no
// permission prompts. The tests still require the Vision framework to
// be available, which is standard on any macOS 14+ SPM test runner.
//
// The text-recognition assertions are tolerant: Vision's Fast level
// sometimes splits words, drops punctuation, or lowercases. We only
// assert that at least one line contains an obvious substring of the
// rendered text, matching the C# side's "was any line produced" shape.

import XCTest
import AppKit
import CoreGraphics
@testable import OpenClickyContextService

final class OCRCaptureTests: XCTestCase {

    // MARK: - Helpers

    /// Render `text` centred inside a solid-white image of the given
    /// pixel size. Returns nil if the graphics context could not be
    /// created (e.g. running under a sandbox that blocks CG bitmaps —
    /// none of the current CI configurations do this).
    private func makeTextImage(
        _ text: String,
        size: CGSize = CGSize(width: 640, height: 160),
        fontSize: CGFloat = 40
    ) -> NSImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Solid white background.
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Draw text via NSString with a system font. Push the CG context
        // so AppKit's `draw(...)` picks it up.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black
        ]
        let ns = NSAttributedString(string: text, attributes: attrs)
        let textSize = ns.size()
        let origin = CGPoint(
            x: (size.width - textSize.width) / 2.0,
            y: (size.height - textSize.height) / 2.0
        )
        ns.draw(at: origin)

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    /// Render a solid white image with no text at all.
    private func makeBlankImage(size: CGSize = CGSize(width: 320, height: 200)) -> NSImage? {
        return makeTextImage("", size: size)
    }

    /// True when any recognised line contains any of the expected
    /// substrings (case-insensitive). Vision Fast is noisy — this
    /// tolerant match mirrors how downstream code consumes the output.
    private func linesContain(
        _ result: OCRResult,
        anyOf needles: [String]
    ) -> Bool {
        for line in result.lines {
            let haystack = line.text.lowercased()
            for needle in needles {
                if haystack.contains(needle.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Nil / error paths

    func test_ocr_returnsNil_forZeroSizeImage() async {
        let empty = NSImage(size: .zero)
        let result = await OCRCapture.ocr(image: empty)
        XCTAssertNil(result, "Zero-size image must resolve to nil (no CGImage)")
    }

    func test_ocr_returnsEmptyLines_forBlankImage() async throws {
        guard let blank = makeBlankImage() else {
            throw XCTSkip("Core Graphics not available in this environment")
        }
        let result = await OCRCapture.ocr(image: blank)
        XCTAssertNotNil(result, "Vision must run over a well-formed blank image")
        XCTAssertEqual(result?.lines.count, 0,
                       "Blank image should produce zero recognised lines")
    }

    // MARK: - Recognition happy paths

    func test_ocr_recognisesEnglishText() async throws {
        guard let image = makeTextImage("Hello OpenClicky") else {
            throw XCTSkip("Could not render text image")
        }
        guard let result = await OCRCapture.ocr(image: image) else {
            XCTFail("Vision returned nil for a valid rendered image")
            return
        }
        XCTAssertFalse(result.lines.isEmpty,
                       "Expected at least one line for rendered English text")
        XCTAssertTrue(
            linesContain(result, anyOf: ["hello", "openclicky", "clicky", "open"]),
            "Expected recognised text to contain a substring of the source. Got: \(result.lines.map(\.text))"
        )
    }

    func test_ocr_recognisesMultiLanguageContent() async throws {
        // Two-line image: English top, Simplified Chinese bottom. We
        // render each line separately so their y-bboxes are clearly
        // separated (Fast level segments by line).
        let size = CGSize(width: 640, height: 240)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw XCTSkip("Core Graphics not available")
        }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: size))

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40),
            .foregroundColor: NSColor.black
        ]
        // In upper-left-origin AppKit drawing here `flipped: false`
        // means the CG y-axis (lower-left origin). "Bottom" in CG
        // coordinates = smaller y; "top" = larger y. Draw English at
        // top of image (larger y), Chinese below it.
        NSAttributedString(string: "Hello", attributes: attrs).draw(at: CGPoint(x: 40, y: 160))
        NSAttributedString(string: "你好", attributes: attrs).draw(at: CGPoint(x: 40, y: 60))

        guard let cg = ctx.makeImage() else {
            throw XCTSkip("CG makeImage failed")
        }
        let image = NSImage(cgImage: cg, size: size)

        guard let result = await OCRCapture.ocr(
            image: image,
            languages: ["en-US", "zh-Hans"]
        ) else {
            XCTFail("Vision returned nil for a valid multi-language image")
            return
        }
        // Vision may segment differently, but we should get at least
        // ONE line total. Assert at least one recognisable substring
        // shows up in either language.
        XCTAssertFalse(result.lines.isEmpty,
                       "Multi-language image should produce at least one line")
        XCTAssertTrue(
            linesContain(result, anyOf: ["hello", "hel", "你好", "你", "好"]),
            "Expected at least one Chinese or English fragment. Got: \(result.lines.map(\.text))"
        )
    }

    // MARK: - Bounding-box invariants

    func test_ocr_boundsHavePositiveDimensions() async throws {
        guard let image = makeTextImage("Hello OpenClicky") else {
            throw XCTSkip("Could not render text image")
        }
        guard let result = await OCRCapture.ocr(image: image),
              result.lines.isEmpty == false else {
            throw XCTSkip("Vision produced no lines on this runner")
        }
        for line in result.lines {
            // Everywhere clamps w/h to >= 1; ensure the port matches.
            XCTAssertGreaterThanOrEqual(line.bounds.width, 1,
                                        "Width must be clamped to >= 1")
            XCTAssertGreaterThanOrEqual(line.bounds.height, 1,
                                        "Height must be clamped to >= 1")
            // Bounds should sit inside the image bounds.
            XCTAssertGreaterThanOrEqual(line.bounds.origin.x, 0)
            XCTAssertGreaterThanOrEqual(line.bounds.origin.y, 0)
            XCTAssertLessThanOrEqual(line.bounds.maxX, image.size.width + 1,
                                     "Bounds should sit within the image")
            XCTAssertLessThanOrEqual(line.bounds.maxY, image.size.height + 1,
                                     "Bounds should sit within the image")
        }
    }

    func test_ocr_linesSortedByAscendingY() async throws {
        // Multi-line image (three lines stacked). Assert the returned
        // order matches Everywhere's ascending-y sort.
        let size = CGSize(width: 640, height: 360)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw XCTSkip("Core Graphics not available")
        }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: size))

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40),
            .foregroundColor: NSColor.black
        ]
        NSAttributedString(string: "line one", attributes: attrs).draw(at: CGPoint(x: 40, y: 280))
        NSAttributedString(string: "line two", attributes: attrs).draw(at: CGPoint(x: 40, y: 160))
        NSAttributedString(string: "line three", attributes: attrs).draw(at: CGPoint(x: 40, y: 40))

        guard let cg = ctx.makeImage() else {
            throw XCTSkip("CG makeImage failed")
        }
        let image = NSImage(cgImage: cg, size: size)

        guard let result = await OCRCapture.ocr(image: image) else {
            XCTFail("Vision returned nil for a valid rendered image")
            return
        }
        guard result.lines.count >= 2 else {
            throw XCTSkip("Vision segmented differently on this runner")
        }
        for i in 1 ..< result.lines.count {
            XCTAssertGreaterThanOrEqual(
                result.lines[i].bounds.origin.y,
                result.lines[i - 1].bounds.origin.y,
                "Lines must be sorted ascending by y"
            )
        }
    }

    // MARK: - Type invariants

    func test_ocrResult_roundTripsJSON() throws {
        let sample = OCRResult(lines: [
            OCRLine(text: "Hello", bounds: CGRect(x: 10, y: 20, width: 100, height: 30), confidence: 0.95),
            OCRLine(text: "世界", bounds: CGRect(x: 10, y: 60, width: 80, height: 30), confidence: 0.87)
        ])
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(OCRResult.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_ocrResult_emptyLinesRoundTripsJSON() throws {
        let sample = OCRResult(lines: [])
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(OCRResult.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_defaultLanguages_matchProductDefault() {
        XCTAssertEqual(OCRCapture.defaultLanguages, ["en-US", "zh-Hans"])
    }
}
