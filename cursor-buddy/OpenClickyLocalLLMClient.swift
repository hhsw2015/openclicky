//
//  OpenClickyLocalLLMClient.swift
//  cursor-buddy
//
//  LLMClient over a locally running llama.cpp sidecar (OpenAI-compatible
//  /v1/chat/completions). Located, not packaged — see
//  OpenClickyLocalLLMLocator.
//
//  What this is for, and what it is not:
//
//  Measured on this machine (docs/parlor-integration-research/
//  05-integration-plan.md §12), Gemma 4 E4B is good at a narrow band and
//  bad outside it. It translates (8/8, 315 ms), it grounds cross-language
//  UI references that OCR structurally cannot (4/4 vs 0/4), it sees
//  non-text controls (4/4 vs 0/4), and it finds one distinctive frame among
//  twenty (precision 1.00, ~1.2 s/frame). It is NOT a transcriber (CER
//  0.138 vs whisper's 0.000), NOT an intent classifier (routelet is
//  calibrated), and NOT a reasoner.
//
//  Two prompt constraints are enforced here rather than left to callers,
//  because both failures are silent and plausible:
//
//    1. Never ask "is this an X?". Asked "what application is this?" the
//       model answers `Slack`; asked "is this a terminal?" about the same
//       frame it answers `YES`. Perception is fine, the leading question is
//       not. Callers ask what something is; `matches` does the matching.
//    2. Dense text — terminals, code, logs — is refused by category, not by
//       inspection. Told to judge for itself the model "read" a terminal
//       line and returned a command that had genuinely been typed minutes
//       earlier: plausible, specific, invented.
//

import Foundation

enum OpenClickyLocalLLMError: LocalizedError {
    case runtimeUnavailable
    case serverUnreachable(URL)
    case httpStatus(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "No local model runtime found. Install llama.cpp (brew install llama.cpp) and place GGUF weights in ~/models."
        case .serverUnreachable(let url):
            return "Local model server is not responding at \(url.absoluteString)."
        case .httpStatus(let code, let body):
            return "Local model server returned HTTP \(code): \(body.prefix(200))"
        case .malformedResponse:
            return "Local model server returned an unreadable response."
        }
    }
}

@MainActor
final class OpenClickyLocalLLMClient: LLMClient {

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = OpenClickyLocalLLMLocator.baseURL(),
         session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Vision turns run ~1.2-2.3 s warm, but the first request after
            // launch also pays model load (several seconds for 5 GB).
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 300
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// No `assistantPrefill` (Anthropic-only) and no tools — the local model
    /// is a perception layer, and tool loops belong to the backend.
    nonisolated var capabilities: LLMCapabilities { [.images] }

    // MARK: - Health

    /// Whether the sidecar is up. Short timeout: this gates a fallback
    /// decision, so a slow answer is as bad as a negative one.
    func isReachable(timeout: TimeInterval = 1.5) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = timeout
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - LLMClient

    func send(
        _ request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let text = try await complete(
            system: request.systemPrompt,
            history: request.conversationHistory,
            user: request.userPrompt,
            images: request.images,
            maxTokens: 512
        )
        if !text.isEmpty { onTextChunk(text) }
        return text
    }

    // MARK: - Focused helpers
    //
    // These are the shapes §12 actually measured. Callers should prefer them
    // over `send` for perception work: each pins the token budget and the
    // question form that were validated.

    /// Translate to English for routelet, which is English-only
    /// (`BAAI/bge-small-en-v1.5`; its 488 CJK vocab entries are leftovers
    /// from bert-base-uncased, not support). Chinese in, English out took
    /// routelet accuracy from 0% to 87.5% — matching hand-written English.
    func translateToEnglish(_ text: String) async throws -> String {
        try await complete(
            system: "Translate the user's text to English. Reply with only the translation, no commentary.",
            history: [],
            user: text,
            images: [],
            maxTokens: 64
        )
    }

    /// Ask what something is. Deliberately open-ended within a bounded
    /// length — see the class comment on why "is this an X?" is banned.
    func identify(image: Data, question: String, maxWords: Int = 2) async throws -> String {
        try await complete(
            system: "Answer with at most \(maxWords) words. No punctuation, no explanation.",
            history: [],
            user: question,
            images: [(data: image, label: "screen")],
            maxTokens: max(8, maxWords * 4)
        )
    }

    /// Whether `identify`'s answer falls in a category. Matching happens
    /// here, in code, rather than by asking the model to confirm a guess.
    /// `nonisolated`: pure string comparison with no instance state, so
    /// there is no reason for callers to hop to the main actor to use it.
    nonisolated static func matches(_ answer: String, anyOf synonyms: Set<String>) -> Bool {
        let normalized = answer.lowercased()
        return synonyms.contains { normalized.contains($0.lowercased()) }
    }

    // MARK: - Transport

    private func complete(
        system: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        user: String,
        images: [(data: Data, label: String)],
        maxTokens: Int
    ) async throws -> String {
        var messages: [[String: Any]] = []
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for turn in history {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }

        if images.isEmpty {
            messages.append(["role": "user", "content": user])
        } else {
            var parts: [[String: Any]] = images.map { image in
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/\(Self.imageMediaSubtype(for: image.data));base64,\(image.data.base64EncodedString())"]
                ]
            }
            parts.append(["type": "text", "text": user])
            messages.append(["role": "user", "content": parts])
        }

        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            // Deterministic. These are perception calls whose answers get
            // string-matched; sampling variation is pure downstream noise.
            "temperature": 0
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenClickyLocalLLMError.serverUnreachable(baseURL)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenClickyLocalLLMError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw OpenClickyLocalLLMError.httpStatus(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenClickyLocalLLMError.malformedResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PNG or JPEG, by signature. Screen captures are JPEG, pasted images
    /// are often PNG, and llama.cpp rejects a mismatched declared type.
    private static func imageMediaSubtype(for data: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if data.count >= 4, [UInt8](data.prefix(4)) == pngSignature { return "png" }
        return "jpeg"
    }
}
