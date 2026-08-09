//
//  LLMClientAdapters.swift
//  cursor-buddy
//
//  Concrete `LLMClient` implementations. Every adapter is a THIN forward
//  to the pre-existing `analyze*` helpers so wire behavior stays identical.
//  Nothing here allocates network connections or holds long-lived state —
//  the underlying clients (`ClaudeAPI`, `MirageBackendClient`, etc.) are
//  already singletons or shared through `CompanionManager`.
//
//  Access-control note: `analyze*Response` methods on `CompanionManager`
//  are `private` in `CompanionManager+AIResponsePipeline.swift`. Adapters
//  therefore receive a small closure block (`DispatchHooks`) from the
//  companion at construction time; the closure captures the private
//  method and can be invoked from any file. This avoids widening the
//  method access level and keeps the switch-mapping visible in the
//  pipeline file where it belongs.

import Foundation

// MARK: - Dispatch hooks (closure indirection for private analyze* methods)

/// Bag of closures owned by `CompanionManager+AIResponsePipeline`. Each
/// closure forwards to the corresponding private `analyze*` helper. The
/// registry hands these to adapters at resolution time.
///
/// Extending this bag is the ONLY way to add a new provider adapter —
/// keeps every provider's parameter surface visible in one place so we
/// can spot drift (e.g. one adapter ignoring `assistantPrefill`).
struct LLMDispatchHooks {
    var apple: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    var anthropic: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    var openAI: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    var codex: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    var mirage: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    var heyclicky: @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
}

// MARK: - Adapters

/// Apple Foundation Models — on-device, static call, no `CompanionManager`
/// state needed. Text-only path; `images` is passed through but the
/// underlying client ignores it (matches current behavior).
@MainActor
final class AppleFoundationLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [] }

    private let hook: LLMDispatchHooks.Apple

    typealias Hook = LLMDispatchHooks.Apple
    init(hook: @escaping Hook) { self.hook = hook }

    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

@MainActor
final class AnthropicLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.images, .assistantPrefill] }
    private let hook: LLMDispatchHooks.Anthropic
    init(hook: @escaping LLMDispatchHooks.Anthropic) { self.hook = hook }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

@MainActor
final class OpenAILLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.images] }
    private let hook: LLMDispatchHooks.OpenAI
    init(hook: @escaping LLMDispatchHooks.OpenAI) { self.hook = hook }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

@MainActor
final class CodexLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.images, .tools] }
    private let hook: LLMDispatchHooks.Codex
    init(hook: @escaping LLMDispatchHooks.Codex) { self.hook = hook }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

@MainActor
final class MirageLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.images, .assistantPrefill] }
    private let hook: LLMDispatchHooks.Mirage
    init(hook: @escaping LLMDispatchHooks.Mirage) { self.hook = hook }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

@MainActor
final class HeyClickyLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.images, .tools] }
    private let hook: LLMDispatchHooks.HeyClicky
    init(hook: @escaping LLMDispatchHooks.HeyClicky) { self.hook = hook }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        try await hook(request, onTextChunk)
    }
}

/// Sentinel adapter for providers that route audio directly and cannot
/// service a text/screenshot fallback. Throws the same error the old
/// switch produced.
@MainActor
final class UnsupportedLLMAdapter: LLMClient {
    var capabilities: LLMCapabilities { [.realtimeVoiceOnly] }
    let provider: OpenClickyModelProvider
    let errorDomain: String
    let errorCode: Int
    let message: String
    init(
        provider: OpenClickyModelProvider,
        errorDomain: String = "LLMClient",
        errorCode: Int = -20,
        message: String
    ) {
        self.provider = provider
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
    }
    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        throw NSError(
            domain: errorDomain,
            code: errorCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - Hook typealiases

extension LLMDispatchHooks {
    typealias Apple     = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    typealias Anthropic = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    typealias OpenAI    = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    typealias Codex     = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    typealias Mirage    = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
    typealias HeyClicky = @MainActor (LLMRequest, @MainActor @Sendable @escaping (String) -> Void) async throws -> String
}
