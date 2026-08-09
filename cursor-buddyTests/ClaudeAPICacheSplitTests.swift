// ClaudeAPICacheSplitTests.swift
// cursor-buddyTests
//
// `ClaudeAPI` is the FALLBACK path (SDK-first money rule: the Claude Agent
// SDK is primary because it rides the paid Claude Code sign-in; this HTTP
// path bills per token). It used to send `"system": systemPrompt` as a bare
// string with no `cache_control` at all, so every fallback turn re-paid for
// the identity/tools/style preamble that the mirage path already caches.
//
// The invariant that earns the money is #2: bytes under the cache marker
// must be identical across turns even when the volatile tail changes.
// Everything else here guards against breaking that while fixing something
// else.

import XCTest
@testable import OpenClicky

final class ClaudeAPICacheSplitTests: XCTestCase {

    private let stable = "You are OpenClicky. Identity, tools, style."

    private func cachedTexts(_ blocks: [[String: Any]]) -> [String] {
        blocks.filter { $0["cache_control"] != nil }.compactMap { $0["text"] as? String }
    }

    func test_split_cachesExactlyTheStablePrefix() {
        let blocks = ClaudeAPI.systemBlocks(
            for: stable + "\n\nmemory: user likes dark mode",
            stablePrefix: stable
        )
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(cachedTexts(blocks), [stable])
        XCTAssertNil(blocks[1]["cache_control"],
                     "volatile tail must not carry a marker — it would move the breakpoint past changing bytes")
        XCTAssertEqual(blocks[1]["text"] as? String, "memory: user likes dark mode")
    }

    /// The whole point. Two turns with completely different dynamic tails
    /// must produce byte-identical cached content, or every turn is a miss.
    func test_split_cachedBytesAreStableAcrossTurns() {
        let turn1 = ClaudeAPI.systemBlocks(for: stable + "\n\nmemory: A", stablePrefix: stable)
        let turn2 = ClaudeAPI.systemBlocks(for: stable + "\n\nmemory: B totally different",
                                           stablePrefix: stable)
        XCTAssertEqual(cachedTexts(turn1), cachedTexts(turn2),
                       "cache prefix drifted between turns — every request will miss")
    }

    func test_split_noTailProducesSingleCachedBlock() {
        let blocks = ClaudeAPI.systemBlocks(for: stable, stablePrefix: stable)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(cachedTexts(blocks), [stable])
    }

    func test_split_whitespaceOnlyTailDoesNotLeakEmptyBlock() {
        let blocks = ClaudeAPI.systemBlocks(for: stable + "\n\n   \n", stablePrefix: stable)
        XCTAssertEqual(blocks.count, 1, "whitespace-only tail must not become an empty text block")
    }

    /// Visual-analysis and assist-agent rounds pass their own prompt. It must
    /// survive intact and still be cached — those flows are byte-stable within
    /// themselves, so caching the whole thing is correct.
    func test_split_customPromptIsPreservedAndCached() {
        let custom = "Analyze this screenshot and reply in JSON."
        let blocks = ClaudeAPI.systemBlocks(for: custom, stablePrefix: stable)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(cachedTexts(blocks), [custom])
    }

    /// Never emit `"system": []` — the field should be absent instead.
    func test_split_emptyPromptProducesNoBlocks() {
        XCTAssertTrue(ClaudeAPI.systemBlocks(for: "", stablePrefix: stable).isEmpty)
    }

    /// `"".hasPrefix("")` is true, so an empty stablePrefix could produce a
    /// bogus empty cached block plus the entire prompt as an unmarked tail —
    /// i.e. caching nothing at all.
    func test_split_emptyStablePrefixStillCachesWholePrompt() {
        let custom = "Analyze this screenshot and reply in JSON."
        let blocks = ClaudeAPI.systemBlocks(for: custom, stablePrefix: "")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(cachedTexts(blocks), [custom])
    }

    /// Splitting must not drop content — only the seam whitespace.
    func test_split_losesNoContent() {
        let full = stable + "\n\nmemory: X"
        let joined = ClaudeAPI.systemBlocks(for: full, stablePrefix: stable)
            .compactMap { $0["text"] as? String }
            .joined()
        let normalize: (String) -> String = {
            $0.replacingOccurrences(of: "\n", with: "")
              .replacingOccurrences(of: " ", with: "")
        }
        XCTAssertEqual(normalize(joined), normalize(full))
    }

    /// The real prompt must actually match itself — guards against someone
    /// making `stableVoiceResponseSystemPromptForCaching()` compute something
    /// per-call (a date, a count) which would silently disable caching.
    func test_realStablePrefixIsByteStable() {
        let a = CompanionManager.stableVoiceResponseSystemPromptForCaching()
        let b = CompanionManager.stableVoiceResponseSystemPromptForCaching()
        XCTAssertEqual(a, b, "stable prefix is not constant — caching is disabled")
        XCTAssertFalse(a.isEmpty)
    }
}
