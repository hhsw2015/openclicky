//
//  ScreenHistoryAIProvider.swift
//  cursor-buddy
//
//  Bridges the embedded rewind subsystem's internal LLM needs
//  (summarise, extractKeywords) through OpenClicky's existing AI
//  backends. User picks the backend in Settings → Screen History; this
//  file dispatches per-request.
//
//  All backends expose the same `completeText(prompt:) async throws -> String`
//  shape. HeyClicky Free is the default free path (money rule); paid
//  backends are opt-in only and never auto-promoted from Free.
//
//  Once OpenRewindKit ships and exposes its `OpenRewindAIProvider`
//  protocol, `OpenClickyScreenHistoryAIProvider` will conform to it
//  and forward calls here. Until then the API is stub-shaped so we can
//  wire the plumbing without waiting.
//

import Foundation
import AppKit

// MARK: - Public API

public struct ScreenHistoryAIProvider: Sendable {

    public init() {}

    /// One-sentence summary. Backend chosen by
    /// `ScreenHistoryAIBackend.current`.
    public func summarize(_ text: String,
                          hint: String? = nil) async throws -> String {
        let head = String(text.prefix(4000))
        let extra = hint.map { "\n上下文提示: \($0)" } ?? ""
        let prompt = "用中文一句话概括下面这段内容, 不要客套语, 只输出结论:\n\n\(head)\(extra)"
        return try await complete(prompt: prompt)
    }

    /// K comma-separated keywords, filtered + capped.
    public func extractKeywords(_ text: String,
                                count k: Int = 10) async throws -> [String] {
        let head = String(text.prefix(4000))
        let prompt = """
        从下面文本里提炼 \(k) 个最能代表主题的关键词 (名词优先, 中文或英文都行),
        用逗号分隔一行返回, 不要编号不要解释, 不要 markdown:

        \(head)
        """
        let raw = try await complete(prompt: prompt)
        let parts: [Substring] = raw.split(whereSeparator: { c in
            c == "," || c == "，" || c == "\n"
        })
        let trimmed: [String] = parts.map { substring in
            String(substring).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let filtered = trimmed.filter { !$0.isEmpty && $0.count <= 40 }
        return Array(filtered.prefix(k))
    }

    /// Raw completion — send the caller's prompt verbatim to whichever
    /// backend the user selected. No wrapping "summarize" or "extract"
    /// instructions layered on top. Used by callers that need to
    /// enforce their own strict output schema (e.g. Ask Rewind's
    /// Stage-1 JSON decomposition).
    public func rawComplete(_ prompt: String) async throws -> String {
        try await complete(prompt: prompt)
    }

    // MARK: - Router

    private func complete(prompt: String) async throws -> String {
        switch ScreenHistoryAIBackend.current {
        case .none:
            throw ScreenHistoryAIError.disabled
        case .heyClickyFree:
            return try await Self.heyClickyFree(prompt: prompt)
        case .claudeSDK:
            return try await Self.claudeSDK(prompt: prompt)
        case .claudeAPI:
            return try await Self.claudeAPI(prompt: prompt)
        case .openAI:
            return try await Self.openAI(prompt: prompt)
        case .apple:
            return try await Self.apple(prompt: prompt)
        }
    }
}

// MARK: - Backend adapters

extension ScreenHistoryAIProvider {

    /// HeyClicky Free — POST to the same Cloudflare Worker the assist
    /// agent uses. Simplest path: send prompt as `query`, no image,
    /// return the `text` field from the response envelope.
    static func heyClickyFree(prompt: String) async throws -> String {
        // See AssistAgentDirectTransport — host lives in HeyClickySecrets.
        guard let workerURL = URL(string: HeyClickySecrets.proxyBaseURL + "/chat-tool-call"),
              !HeyClickySecrets.proxyBaseURL.isEmpty else {
            throw HeyClickyConfigError.proxyBaseURLMissing
        }
        let sessionID = UUID().uuidString.lowercased()

        var body: [String: Any] = [
            "query": prompt,
            "mimeType": "image/jpeg",
            "client_capabilities": ["clipboard_copy"],
            "frontmost_app_bundle_id": "com.jkneen.openclicky",
            "environment": [
                "os_version": osVersionReported,
                "timezone": TimeZone.current.identifier,
                "display_count": NSScreen.screens.count,
                "locale": Locale.current.identifier,
            ],
            "session_id": sessionID,
        ]
        _ = body

        let data = try JSONSerialization.data(withJSONObject: body,
                                              options: [.sortedKeys])
        var request = URLRequest(url: workerURL, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("openclicky-screen-history/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "X-Clicky-Session-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Clicky-Trace-Id")
        request.setValue("normal", forHTTPHeaderField: "X-Clicky-Mode")

        let accessToken = AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey) ?? ""
        guard !accessToken.isEmpty else {
            throw ScreenHistoryAIError.backendUnavailable(
                .heyClickyFree, reason: "HeyClicky 未登录")
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let sub = AssistAgentDirectTransport.decodeJWTSub(accessToken) {
            request.setValue(sub, forHTTPHeaderField: "X-Clicky-Distinct-Id")
        }

        let (respData, respURL) = try await URLSession.shared.data(for: request)
        guard let http = respURL as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (respURL as? HTTPURLResponse)?.statusCode ?? -1
            throw ScreenHistoryAIError.backendUnavailable(
                .heyClickyFree, reason: "HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let text = obj["text"] as? String,
              !text.isEmpty
        else {
            throw ScreenHistoryAIError.emptyReply
        }
        return text
    }

    /// Claude via subscription-backed Agent SDK. Deliberate opt-in path
    /// — never invoked unless user selects `.claudeSDK`.
    static func claudeSDK(prompt: String) async throws -> String {
        // TODO: wire once ClaudeAgentSDKAPI gains a plain-text
        // completion entry point. For now we route through the same
        // analyzeImage path with an empty image marker, which the SDK
        // treats as a text-only turn.
        throw ScreenHistoryAIError.backendUnavailable(
            .claudeSDK, reason: "SDK completeText helper not yet wired")
    }

    /// Direct Claude HTTP messages/create. Requires ANTHROPIC_API_KEY.
    static func claudeAPI(prompt: String) async throws -> String {
        let apiKey = AppBundleConfiguration.anthropicAPIKey() ?? ""
        guard !apiKey.isEmpty else {
            throw ScreenHistoryAIError.backendUnavailable(
                .claudeAPI, reason: "缺少 ANTHROPIC_API_KEY")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                                 timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 512,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ScreenHistoryAIError.backendUnavailable(
                .claudeAPI, reason: "HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String,
              !text.isEmpty
        else {
            throw ScreenHistoryAIError.emptyReply
        }
        return text
    }

    /// OpenAI chat/completions. Requires OPENAI_API_KEY.
    static func openAI(prompt: String) async throws -> String {
        let apiKey = AppBundleConfiguration.openAIAPIKey() ?? ""
        guard !apiKey.isEmpty else {
            throw ScreenHistoryAIError.backendUnavailable(
                .openAI, reason: "缺少 OPENAI_API_KEY")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                                 timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 512,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw ScreenHistoryAIError.backendUnavailable(
                .openAI, reason: "HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String,
              !text.isEmpty
        else {
            throw ScreenHistoryAIError.emptyReply
        }
        return text
    }

    /// On-device Apple foundation model. macOS 26+.
    static func apple(prompt: String) async throws -> String {
        // TODO: wire once AppleFoundationModelsVoiceClient exposes a
        // plain-text completion (currently only `analyzeVoiceResponse`).
        throw ScreenHistoryAIError.backendUnavailable(
            .apple, reason: "Apple 本地文本 completion 尚未接入")
    }

    // Shared OS version helper (mirror AssistAgentDirectTransport).
    private static let osVersionReported: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
}
