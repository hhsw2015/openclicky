// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacClipboardReader.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for ClipboardCapture + ClipboardInfo.
//
// These tests exercise the macOS general pasteboard directly, so they
// mutate real user state during the test run. Each test snapshots the
// pasteboard first and restores it in tearDown so the developer's clipboard
// survives an unlucky test invocation.
//
// Some CI / headless environments may fail to open a pasteboard connection
// (e.g. no active loginwindow session). Those cases are detected via a
// sentinel round-trip and the test skips rather than fails, matching the
// pattern used by FrontmostAppCaptureTests.

import XCTest
import AppKit
@testable import OpenClickyContextService

final class ClipboardInfoTests: XCTestCase {

    // MARK: JSON round-trip — ensures snapshot format stays stable.

    func test_clipboardInfo_roundTripsJSON_textOnly() throws {
        let sample = ClipboardInfo(text: "hello openclicky")
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ClipboardInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.text, "hello openclicky")
        XCTAssertNil(decoded.filePaths)
        XCTAssertNil(decoded.imageData)
        XCTAssertNil(decoded.rtfData)
    }

    func test_clipboardInfo_roundTripsJSON_nilText() throws {
        let sample = ClipboardInfo(text: nil)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ClipboardInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertNil(decoded.text)
    }
}

final class ClipboardCaptureTests: XCTestCase {

    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        // Snapshot every item so we can restore whatever the developer
        // had on the pasteboard. NSPasteboardItem is copyable via a
        // fresh item with the same types/data.
        savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if !savedItems.isEmpty {
            NSPasteboard.general.writeObjects(savedItems)
        }
        savedItems = []
        super.tearDown()
    }

    /// Round-trips a sentinel string; skips the test if the pasteboard
    /// is unreachable (headless CI, sandbox denial, …).
    private func requireLivePasteboard() throws {
        let sentinel = "openclicky-clipboard-probe-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(sentinel, forType: .string)
        if !ok || NSPasteboard.general.string(forType: .string) != sentinel {
            throw XCTSkip("NSPasteboard unavailable in this environment")
        }
    }

    // MARK: text-only round trip

    func test_capture_returnsText_whenTextWritten() throws {
        try requireLivePasteboard()

        let payload = "hello openclicky \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(payload, forType: .string))

        let info = ClipboardCapture.capture()
        XCTAssertNotNil(info, "Expected ClipboardInfo when text is on the pasteboard")
        XCTAssertEqual(info?.text, payload)

        // P1 fields must stay nil until they are implemented.
        XCTAssertNil(info?.filePaths)
        XCTAssertNil(info?.imageData)
        XCTAssertNil(info?.rtfData)
    }

    // MARK: empty pasteboard -> nil

    func test_capture_returnsNil_whenPasteboardEmpty() throws {
        try requireLivePasteboard()

        // clearContents leaves the pasteboard with no items; stringForType:
        // yields nil, which Everywhere maps to null. openclicky lifts that
        // into a nil ClipboardInfo.
        NSPasteboard.general.clearContents()

        let info = ClipboardCapture.capture()
        XCTAssertNil(info, "Expected nil ClipboardInfo when the pasteboard is empty")
    }

    // MARK: content changes between calls

    func test_capture_reflectsUpdates_betweenCalls() throws {
        try requireLivePasteboard()

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("first", forType: .string)
        XCTAssertEqual(ClipboardCapture.capture()?.text, "first")

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("second", forType: .string)
        XCTAssertEqual(ClipboardCapture.capture()?.text, "second")

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("", forType: .string)
        // Empty string is still a valid string value — mirrors Everywhere:
        // GetText() would return "" (non-null) here.
        XCTAssertEqual(ClipboardCapture.capture()?.text, "")
    }

    // MARK: non-string content only -> nil

    func test_capture_returnsNil_whenOnlyNonStringContent() throws {
        try requireLivePasteboard()

        NSPasteboard.general.clearContents()
        // Write a TIFF blob under the tiff type without any string
        // representation. `stringForType:` must yield nil, matching
        // Everywhere's null-returning path for image-only pasteboards.
        let tiffBytes = Data([0x49, 0x49, 0x2A, 0x00])  // little-endian TIFF magic
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(tiffBytes, forType: .tiff))
        XCTAssertTrue(NSPasteboard.general.writeObjects([item]))

        // Sanity-check: the tiff type is present but string type is not.
        XCTAssertNil(NSPasteboard.general.string(forType: .string),
                    "Precondition: pasteboard should have no string type")

        let info = ClipboardCapture.capture()
        XCTAssertNil(info, "Expected nil when the pasteboard has only non-text content")
    }
}
