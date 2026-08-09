//
//  HeyClickyProxyTranscriptionProvider.swift
//  cursor-buddy
//
//  BuddyTranscriptionProvider backed by HeyClicky Free's dictation
//  path. IDA-verified (HeyClicky-1.0.40):
//    - POST /v2/dictation/deepgram-token → short-lived Deepgram token
//    - Client then streams to wss://api.deepgram.com/v1/listen using
//      that token directly (not through the proxy).
//  See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §5.1 (updated).
//

import AVFoundation
import Foundation

struct HeyClickyProxyTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HeyClickyProxyTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "HeyClicky Free"
    let requiresSpeechRecognitionPermission = false

    private let urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
    }

    var isConfigured: Bool { AppBundleConfiguration.heyClickySignedIn() }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "HeyClicky Free needs sign-in. Open Settings → HeyClicky Free."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw HeyClickyProxyTranscriptionProviderError(
                message: unavailableExplanation ?? "HeyClicky Free is not configured."
            )
        }

        let token: String
        do {
            token = try await mintDeepgramToken()
        } catch let err as HeyClickyProxyError {
            if case .quotaExhausted = err {
                await MainActor.run {
                    _ = HeyClickyAccountResetManager.shared.attemptReset(
                        reason: "stt_lane_quota_exhausted"
                    )
                }
            }
            throw err
        }

        // Reuse openclicky's existing Deepgram streaming implementation.
        // The proxy-minted token is passed through as the Authorization
        // bearer; everything else (URL construction, PCM16 conversion,
        // interim/final message parsing) is inherited unchanged.
        let session = DeepgramStreamingTranscriptionSession(
            apiKey: token,
            modelName: "nova-3",
            urlSession: urlSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        try await session.open()
        return session
    }

    /// POST /v2/dictation/deepgram-token → { token: "..." } (approx).
    /// IDA string at 0x1012b5910. Response shape not visible in strings;
    /// try common key names.
    private func mintDeepgramToken() async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [String: String]())
        let (data, _) = try await HeyClickyProxyClient.shared.postJSON(
            path: "/v2/dictation/deepgram-token",
            body: body,
            includeDictationReceipt: false
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HeyClickyProxyError.malformedResponse
        }
        let token = (json["token"] as? String)
            ?? (json["deepgram_token"] as? String)
            ?? (json["api_key"] as? String)
            ?? (json["key"] as? String)
        guard let token, !token.isEmpty else {
            throw HeyClickyProxyError.malformedResponse
        }
        return token
    }
}
