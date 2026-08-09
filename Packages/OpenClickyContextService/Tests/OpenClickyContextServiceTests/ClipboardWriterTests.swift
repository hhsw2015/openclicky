// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacClipboardWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for ClipboardWriter + ClipboardWriteResult.
//
// These tests mutate the macOS general pasteboard directly, so setUp
// snapshots the current items and tearDown restores them (matching
// ClipboardCaptureTests). A sentinel round-trip skips the entire test
// when the pasteboard is unreachable (headless CI, sandbox denial, …).
//
// The `simulatePaste` / `simulateCopy` cases only assert that CGEvent
// allocation succeeds — actually driving a paste into a frontmost app
// requires Input Monitoring TCC and a real GUI session, so those tests
// XCTSkip when the TCC-facing CGEvent path is not usable in the current
// environment.

import XCTest
import AppKit
@testable import OpenClickyContextService

final class ClipboardWriteResultTests: XCTestCase {

    func test_clipboardWriteResult_roundTripsJSON() throws {
        let sample = ClipboardWriteResult(ok: true, bytes: 5)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ClipboardWriteResult.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.bytes, 5)
    }

    func test_clipboardWriteResult_jsonKeys_matchEnvelope() throws {
        // Everywhere's `ClipboardTools.DoWrite` returns
        // `{ "ok": true, "bytes": N }`. openclicky's serialized shape
        // must line up field-for-field so the MCP callers do not need
        // a per-side envelope shim.
        let sample = ClipboardWriteResult(ok: false, bytes: 0)
        let data = try JSONEncoder().encode(sample)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["bytes"] as? Int, 0)
    }
}

final class ClipboardWriterTests: XCTestCase {

    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
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
        let sentinel = "openclicky-clipboard-writer-probe-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(sentinel, forType: .string)
        if !ok || NSPasteboard.general.string(forType: .string) != sentinel {
            throw XCTSkip("NSPasteboard unavailable in this environment")
        }
    }

    // MARK: - writeText — round trips

    func test_writeText_placesTextOnPasteboard() throws {
        try requireLivePasteboard()

        let payload = "hello openclicky \(UUID().uuidString)"
        let result = ClipboardWriter.writeText(payload)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bytes, payload.utf8.count)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), payload)
    }

    func test_writeText_replacesPriorContents() throws {
        try requireLivePasteboard()

        // Pre-populate with an unrelated string that writeText should
        // wipe (mirrors Everywhere's `clearContents` + `setString`
        // sequence — no leftover items).
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("prior", forType: .string)

        let result = ClipboardWriter.writeText("replacement")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "replacement")
    }

    func test_writeText_bumpsChangeCount() throws {
        try requireLivePasteboard()

        let before = NSPasteboard.general.changeCount
        let result = ClipboardWriter.writeText("bump")
        XCTAssertTrue(result.ok)
        XCTAssertGreaterThan(NSPasteboard.general.changeCount, before,
                             "clearContents + setString must bump changeCount")
    }

    // MARK: - writeText — empty string

    func test_writeText_emptyString_isOKWithZeroBytes() throws {
        try requireLivePasteboard()

        let result = ClipboardWriter.writeText("")
        XCTAssertTrue(result.ok, "Empty string is a valid pasteboard payload")
        XCTAssertEqual(result.bytes, 0)
        // Empty string is still non-nil — matches Everywhere's
        // `GetText()` returning "" (not null) after a `SetText("")`.
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "")
    }

    // MARK: - writeText — byte count semantics

    func test_writeText_bytesReportsUTF8Length_ascii() throws {
        try requireLivePasteboard()
        let result = ClipboardWriter.writeText("hello")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bytes, 5)
    }

    func test_writeText_bytesReportsUTF8Length_multibyte() throws {
        try requireLivePasteboard()
        // "日本語" — 3 characters, 9 UTF-8 bytes (3 bytes each).
        // Everywhere's `text.Length` would report 3 (UTF-16 code units).
        // Swift port reports the wire byte count instead.
        let payload = "日本語"
        let result = ClipboardWriter.writeText(payload)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bytes, 9)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), payload)
    }

    func test_writeText_bytesReportsUTF8Length_emoji() throws {
        try requireLivePasteboard()
        // U+1F600 — 4 UTF-8 bytes, 2 UTF-16 code units.
        let payload = "\u{1F600}"
        let result = ClipboardWriter.writeText(payload)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bytes, 4)
    }

    // MARK: - writeText — 1 MB payload

    func test_writeText_oneMegabytePayload_isOK() throws {
        try requireLivePasteboard()
        // 1 MiB of ASCII 'a' — exercises the "large text" path Everywhere's
        // `stringWithUTF8String:` handles without explicit chunking.
        let payload = String(repeating: "a", count: 1024 * 1024)
        let result = ClipboardWriter.writeText(payload)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bytes, 1024 * 1024)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.count, 1024 * 1024)
    }

    // MARK: - simulatePaste / simulateCopy — dry-run allocation

    /// These tests do not verify that the frontmost app received the
    /// keystroke — that would require Input Monitoring TCC and a real
    /// GUI session. They verify that `ClipboardWriter` can allocate
    /// the CGEvent pair and dispatch it without crashing. If CGEvent
    /// allocation fails (typical on headless CI) the test skips
    /// instead of failing.
    private func requireCGEventAvailability() throws {
        guard let probe = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x09,  // kVK_ANSI_V
            keyDown: true
        ) else {
            throw XCTSkip("CGEvent allocation unavailable in this environment")
        }
        _ = probe  // silence unused-value warning
    }

    func test_simulatePaste_postsWithoutCrashing() throws {
        try requireCGEventAvailability()
        XCTAssertTrue(ClipboardWriter.simulatePaste())
    }

    func test_simulateCopy_postsWithoutCrashing() throws {
        try requireCGEventAvailability()
        XCTAssertTrue(ClipboardWriter.simulateCopy())
    }
}
