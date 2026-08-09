// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for SelectedTextCapture + SelectionCache + SelectedTextInfo.
//
// GUI-dependent branches (Strategies 1-3 against a live AX tree) are gated
// behind XCTSkipIf because they require Accessibility consent AND a
// foreground app with a real text selection. What CAN be tested
// deterministically on any host:
//   * SelectionCache TTL, store/getFresh, empty-text short-circuit
//   * SelectedTextInfo JSON round-trip and length semantics
//   * SelectedTextSource enum wire values (cache/ax/child/clipboardCmdC)
//   * Cache HIT path in SelectedTextCapture.capture(...)
//   * Cache-miss falls through to live capture (which typically returns
//     nil under the test host)
//   * Clipboard restore: the pasteboard is snapshotted in setUp and
//     restored in tearDown so unlucky runs never wipe developer state.

import XCTest
import AppKit
@testable import OpenClickyContextService

// MARK: - SelectionCache

final class SelectionCacheTests: XCTestCase {

    func test_getFresh_returnsNil_whenEmpty() {
        let cache = SelectionCache()
        XCTAssertNil(cache.getFresh())
    }

    func test_getFresh_returnsStoredValue_withinTtl() {
        let now = Date()
        let cache = SelectionCache(clock: { now }, ttl: 120)
        cache.store(text: "hello", appKey: "textedit")
        let hit = cache.getFresh()
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.text, "hello")
        XCTAssertEqual(hit?.appKey, "textedit")
    }

    func test_getFresh_returnsNil_afterTtlExpires() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let cache = SelectionCache(clock: { clock }, ttl: 120)
        cache.store(text: "will expire", appKey: "safari")
        // Advance beyond TTL.
        clock = clock.addingTimeInterval(121)
        XCTAssertNil(cache.getFresh(), "expired entries must not be returned")
    }

    func test_getFresh_returnsValue_atTtlBoundary() {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let cache = SelectionCache(clock: { clock }, ttl: 120)
        cache.store(text: "boundary", appKey: nil)
        clock = clock.addingTimeInterval(120)  // exactly TTL
        XCTAssertNotNil(cache.getFresh(), "boundary (== TTL) counts as fresh")
    }

    func test_store_ignoresEmptyText() {
        let cache = SelectionCache()
        cache.store(text: "", appKey: "any")
        XCTAssertNil(cache.getFresh(), "empty text must not populate the cache")
    }

    func test_store_overwritesPreviousEntry() {
        var clock = Date()
        let cache = SelectionCache(clock: { clock }, ttl: 120)
        cache.store(text: "first", appKey: "app-a")
        clock = clock.addingTimeInterval(1)
        cache.store(text: "second", appKey: "app-b")
        XCTAssertEqual(cache.getFresh()?.text, "second")
        XCTAssertEqual(cache.getFresh()?.appKey, "app-b")
    }

    func test_reset_clearsEntry() {
        let cache = SelectionCache()
        cache.store(text: "boop", appKey: "app")
        cache.reset()
        XCTAssertNil(cache.getFresh())
    }

    func test_ttlConstant_matchesEverywhereReference() {
        // Everywhere's SelectionCache.cs:14 -> TimeSpan.FromMinutes(2)
        XCTAssertEqual(SelectionCache.ttl, 120)
    }
}

// MARK: - SelectedTextInfo shape

final class SelectedTextInfoTests: XCTestCase {

    func test_selectedTextInfo_roundTripsJSON() throws {
        let sample = SelectedTextInfo(
            text: "hello openclicky",
            source: .ax,
            sourceApp: "textedit",
            length: 16
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SelectedTextInfo.self, from: data)
        XCTAssertEqual(decoded, sample)
    }

    func test_selectedTextSource_rawValuesAreStable() {
        // Wire values must stay stable — downstream stash / MCP tools key on them.
        XCTAssertEqual(SelectedTextSource.ax.rawValue, "ax")
        XCTAssertEqual(SelectedTextSource.child.rawValue, "child")
        XCTAssertEqual(SelectedTextSource.clipboardCmdC.rawValue, "clipboardCmdC")
        XCTAssertEqual(SelectedTextSource.cache.rawValue, "cache")
    }

    func test_selectedTextInfo_preservesGraphemeSequences() throws {
        // Emoji ZWJ + RTL + surrogates. Length is grapheme-cluster count
        // (String.count), matching the doc 01 spec.
        let raw = "hello \u{1F469}\u{200D}\u{1F4BB} مرحبا"
        let sample = SelectedTextInfo(
            text: raw,
            source: .clipboardCmdC,
            sourceApp: nil,
            length: raw.count
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SelectedTextInfo.self, from: data)
        XCTAssertEqual(decoded.text, raw, "graphemes must round-trip verbatim")
        XCTAssertEqual(decoded.length, raw.count)
    }
}

// MARK: - SelectedTextCapture

final class SelectedTextCaptureTests: XCTestCase {

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

    /// Cache hit is the highest-priority path. Fully deterministic —
    /// does not touch AX or the pasteboard.
    func test_capture_returnsCache_whenCacheIsFresh() {
        let cache = SelectionCache()
        cache.store(text: "cached-text", appKey: "myapp")
        let info = SelectedTextCapture.capture(cache: cache)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.text, "cached-text")
        XCTAssertEqual(info?.source, .cache)
        XCTAssertEqual(info?.sourceApp, "myapp")
        XCTAssertEqual(info?.length, "cached-text".count)
    }

    func test_capture_skipsCache_whenExpired() {
        var clock = Date(timeIntervalSince1970: 3_000_000)
        let cache = SelectionCache(clock: { clock }, ttl: 120)
        cache.store(text: "stale", appKey: "app")
        clock = clock.addingTimeInterval(121)

        // Cache is now expired. The live path will likely fail (no AX
        // consent under swift-test), and we assert the source is NOT
        // .cache — we specifically do not want the stale entry back.
        let info = SelectedTextCapture.capture(cache: cache)
        if let info {
            XCTAssertNotEqual(info.source, .cache, "expired cache must not be served")
        }
    }

    /// Under `swift test` with no frontmost app selection, the live path
    /// yields nil. This ensures the call terminates and does not crash.
    func test_capture_returnsNilOrLiveValue_underHeadlessRun() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil,
            "OPENCLICKY_SKIP_UI_TESTS set; skipping live probe"
        )
        let cache = SelectionCache()
        // Cache is empty; must run the AX/clipboard branches and finish.
        _ = SelectedTextCapture.capture(cache: cache)
        // No assertion on value — just proves the pipeline terminates.
    }

    /// The Cmd-C fallback must leave the pasteboard exactly as it found
    /// it, even when no selection is present. We prime the pasteboard,
    /// call capture, and assert the payload is intact.
    func test_capture_restoresClipboard_afterFallback() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil,
            "OPENCLICKY_SKIP_UI_TESTS set; skipping clipboard restore probe"
        )

        let sentinel = "openclicky-selected-text-probe-\(UUID().uuidString)"
        let pb = NSPasteboard.general
        pb.clearContents()
        XCTAssertTrue(pb.setString(sentinel, forType: .string))

        let cache = SelectionCache()
        _ = SelectedTextCapture.capture(cache: cache)

        // After capture the sentinel MUST still be readable, whether or
        // not the fallback was actually triggered.
        XCTAssertEqual(
            pb.string(forType: .string),
            sentinel,
            "Cmd-C fallback must restore original clipboard content"
        )
    }

    /// Cache short-circuit must fire BEFORE any AX / clipboard work.
    /// Verified indirectly: put a distinctive value on the pasteboard,
    /// pre-populate the cache, run capture. Result must be the cache
    /// value and the pasteboard sentinel must still be present.
    func test_capture_takesCachePath_beforeClipboardFallback() {
        let sentinel = "unrelated-clipboard-\(UUID().uuidString)"
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.setString(sentinel, forType: .string)

        let cache = SelectionCache()
        cache.store(text: "priority-cache", appKey: "myapp")

        let info = SelectedTextCapture.capture(cache: cache)
        XCTAssertEqual(info?.text, "priority-cache")
        XCTAssertEqual(info?.source, .cache)
        // Cmd-C should never have run: clipboard sentinel is intact.
        XCTAssertEqual(pb.string(forType: .string), sentinel)
    }
}
