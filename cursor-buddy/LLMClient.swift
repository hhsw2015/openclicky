//
//  LLMClient.swift
//  cursor-buddy
//
//  Common shape for every voice-response provider (Claude, OpenAI/Codex,
//  Mirage/PeekyFree, HeyClickyFree, Apple Foundation Models). Each concrete
//  client is a thin adapter around the pre-existing `analyze*` helpers, so
//  the underlying wire behavior is byte-identical to what the old
//  `analyzeVoiceResponse` provider switch dispatched to before the cutover.
//
//  This is now the ONLY dispatch path — the switch was deleted after the
//  static equivalence review in
//  docs/peeky-review-2026-08-06/10-llmclient-equivalence.md.

import Foundation

// MARK: - Public value types

/// One voice-response request. Field names + semantics mirror what the
/// old switch(provider) branches accept today so adapters can forward
/// verbatim without lossy conversions.
struct LLMRequest {
    /// Provider-scoped model identifier (may be prefixed, e.g. "mirage/…").
    let model: String

    /// Rendered system prompt. Callers already apply any provider-specific
    /// directives (ROUTE, xlb hints, filler suppression) before hand-off.
    let systemPrompt: String

    /// Prior turns; each entry pairs the user's placeholder text with the
    /// assistant's already-spoken reply. Same shape used by every current
    /// `analyze*` helper.
    let conversationHistory: [(userPlaceholder: String, assistantResponse: String)]

    /// The user's latest utterance.
    let userPrompt: String

    /// Optional screenshot/vision context. Empty array = no visual input.
    let images: [(data: Data, label: String)]

    /// Assistant-prefill (Anthropic feature). Only Claude/Mirage honour it;
    /// non-supporting adapters must ignore it silently.
    let assistantPrefill: String?
}

/// Capability bits the pipeline uses to gate features without switching
/// on `OpenClickyModelProvider`. Values are additive.
struct LLMCapabilities: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let images            = LLMCapabilities(rawValue: 1 << 0)
    static let assistantPrefill  = LLMCapabilities(rawValue: 1 << 1)
    static let tools             = LLMCapabilities(rawValue: 1 << 2)
    static let realtimeAudio     = LLMCapabilities(rawValue: 1 << 3)
    /// Client is a live speech/text-only path with no vision surface.
    static let realtimeVoiceOnly = LLMCapabilities(rawValue: 1 << 4)
}

/// Shared voice-response contract. Every provider currently invoked from
/// `analyzeVoiceResponse` conforms via an adapter. `send` returns the full
/// assistant text once streaming completes — providers already flatten to
/// plain text via `onTextChunk`, so this is compatible with the existing
/// TTS pipeline unchanged.
///
/// `@MainActor` because every existing `analyze*` implementation reaches
/// into main-actor state (UI logging, companion accessors); making the
/// protocol main-actor keeps call sites free of hop noise.
@MainActor
protocol LLMClient: AnyObject {
    var capabilities: LLMCapabilities { get }

    /// Send one voice-response turn. Chunks stream to `onTextChunk` while
    /// the reply is being generated; the final return value is the full
    /// accumulated text (may be `""` when the provider intentionally
    /// suppresses TTS — matches the current SKI empty-return contract).
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String
}
