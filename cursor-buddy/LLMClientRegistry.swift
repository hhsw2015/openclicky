//
//  LLMClientRegistry.swift
//  cursor-buddy
//
//  Maps `OpenClickyModelProvider` to a concrete `LLMClient`. Adapters live
//  in `LLMClientAdapters.swift`. Every voice-response dispatch goes through
//  `client(for:hooks:).send(...)`; there is no fallback switch to compare
//  against, so this file is deliberately small.
//
//  Static equivalence with the pre-refactor switch is documented in
//  docs/peeky-review-2026-08-06/10-llmclient-equivalence.md — each hook
//  closure forwards its `LLMRequest` fields to the identical `analyze*`
//  helper the switch used to call, byte for byte.

import Foundation

@MainActor
enum LLMClientRegistry {
    /// Resolve the client for a given provider. The `hooks` bag captures
    /// the pipeline's own `analyze*` closures so adapters can forward
    /// verbatim to the pre-existing implementations without widening any
    /// method's access level.
    static func client(
        for provider: OpenClickyModelProvider,
        hooks: LLMDispatchHooks
    ) -> LLMClient {
        switch provider {
        case .apple:         return AppleFoundationLLMAdapter(hook: hooks.apple)
        case .anthropic:     return AnthropicLLMAdapter(hook: hooks.anthropic)
        case .openAI:        return OpenAILLMAdapter(hook: hooks.openAI)
        case .codex:         return CodexLLMAdapter(hook: hooks.codex)
        case .peekyFree:     return MirageLLMAdapter(hook: hooks.mirage)
        case .heyclickyFree: return HeyClickyLLMAdapter(hook: hooks.heyclicky)
        case .deepgram:
            // Deepgram Voice Agent handles live mic turns directly. The
            // old switch used `DeepgramVoiceAgentClient` as the error
            // domain — mirror it verbatim so callers pattern-matching on
            // NSError.domain still work after the cutover.
            return UnsupportedLLMAdapter(
                provider: .deepgram,
                errorDomain: "DeepgramVoiceAgentClient",
                errorCode: -20,
                message: "Deepgram Voice Agent handles live microphone turns directly; text/screenshot fallback should route through a normal response model.")
        }
    }
}
