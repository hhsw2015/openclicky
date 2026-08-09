//
//  ScreenHistoryAIBackend.swift
//  cursor-buddy
//
//  Which AI backend the "Screen History" (embedded rewind) subsystem
//  routes its internal LLM work through — daily-recap summaries,
//  keyword extraction, snippet distillation. Independent from the main
//  dialog model and from the assist agent — this is *rewind's own*
//  reasoning need, not the user's conversation.
//
//  User picks one in Settings → Screen History → "AI backend". Default
//  is HeyClicky Free (zero cost, no account required beyond the free
//  plan the user already signed into for the rest of OpenClicky).
//
//  Money rule: HeyClicky Free is the free path, always preferred when
//  present. Claude SDK / API + OpenAI + Apple local are opt-in choices
//  the user made explicitly — never silently promoted from Free to
//  paid.
//

import Foundation

public enum ScreenHistoryAIBackend: String, CaseIterable, Sendable {
    /// Free proxy — POST to /chat-tool-call. Requires HeyClicky login.
    case heyClickyFree
    /// Claude via subscription-backed Agent SDK. Requires local Claude
    /// Code CLI sign-in. NEVER used silently — user must select.
    case claudeSDK
    /// Direct Claude HTTP messages/create. Requires ANTHROPIC_API_KEY.
    case claudeAPI
    /// OpenAI chat/completions. Requires OPENAI_API_KEY.
    case openAI
    /// On-device Apple foundation model. macOS 26+ only. Zero cost, slow.
    case apple
    /// Disable rewind's internal AI entirely. Raw signals only —
    /// no summaries, no keywords. Timeline still works.
    case none

    public static let defaultsKey = "openclicky.screenHistory.aiBackend"

    public static var current: ScreenHistoryAIBackend {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return ScreenHistoryAIBackend(rawValue: raw) ?? .heyClickyFree
    }

    public static func set(_ value: ScreenHistoryAIBackend) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
    }

    public var displayName: String {
        switch self {
        case .heyClickyFree: return "HeyClicky Free (免费, 默认)"
        case .claudeSDK:     return "Claude (subscription)"
        case .claudeAPI:     return "Claude API (需 API key)"
        case .openAI:        return "OpenAI (需 API key)"
        case .apple:         return "Apple 本地模型 (macOS 26+)"
        case .none:          return "关闭 (只保留原始数据)"
        }
    }
}

public enum ScreenHistoryAIError: Error, LocalizedError, Sendable {
    case disabled
    case backendUnavailable(ScreenHistoryAIBackend, reason: String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "屏幕历史内部 AI 已关闭"
        case .backendUnavailable(let b, let r):
            return "AI 后端 \(b.rawValue) 不可用: \(r)"
        case .emptyReply:
            return "AI 返回空回复"
        }
    }
}
