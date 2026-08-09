//
//  MirageCartesiaClient.swift
//  cursor-buddy
//
//  Free-tier Cartesia TTS via aegis-proxy. Same two-step pattern as the
//  Deepgram client:
//
//    Step 1 — mint a short-lived Cartesia bearer token via POST
//             /v1/cartesia/token on aegis-proxy.
//    Step 2 — POST directly to api.cartesia.ai/tts/sse with the bearer,
//             stream PCM chunks back as SSE `chunk` events with the
//             audio base64-encoded. Aegis-proxy is off the audio path.
//
//  Wire values match Peeky (`peeky/src/providers/tts_cartesia.rs`):
//    model_id      = "sonic-2"
//    default voice = "a0e99841-438c-4a64-b679-ae501e7d6091"
//    output_format = pcm_s16le @ 24 kHz mono, container raw

import Foundation
#if canImport(NIOCore)
import NIOCore
#endif

private let cartesiaSSEURL = URL(string: "https://api.cartesia.ai/tts/sse")!
private let cartesiaAPIVersion = "2026-03-01"
private let cartesiaDefaultModel = "sonic-2"
private let cartesiaDefaultVoiceID = "a0e99841-438c-4a64-b679-ae501e7d6091"
private let cartesiaSampleRate = 24000

enum MirageCartesiaError: Error, LocalizedError {
    case notConfigured
    case tokenMintFailed(Int, body: Data)
    case sseFailed(Int, body: Data)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Peeky Free TTS is not configured — set MirageSecrets.upstreamBaseURL."
        case .tokenMintFailed(let code, _):
            return "Peeky Free TTS token mint returned HTTP \(code)."
        case .sseFailed(let code, _):
            return "Cartesia TTS SSE returned HTTP \(code)."
        }
    }
}

actor MirageCartesiaClient {
    static let shared = MirageCartesiaClient()

    private let tokenCache = MirageTokenCache()

    /// Mint a fresh Cartesia bearer via aegis-proxy. Shares the UUID
    /// pool with MirageBackendClient + MirageDeepgramClient so the three
    /// lanes advance rotation together.
    private func mintCartesiaToken() async throws -> (String, TimeInterval) {
        guard let endpoint = MirageSecrets.cartesiaTokenURL else {
            throw MirageCartesiaError.notConfigured
        }
        return try await MirageProxyTokenMinter.mint(
            endpoint: endpoint,
            service: "cartesia",
            ttlFallbackSeconds: 60,
            makeError: { code, body in
                MirageCartesiaError.tokenMintFailed(code, body: body)
            })
    }

    /// Pre-mint the Cartesia proxy token so the first TTS sentence
    /// doesn't pay the ~2s token-mint cold-start on top of the ~500ms
    /// PCM generation latency. Runs on app boot when mirage is active
    /// and on profile switch to mirage.
    func warm() async {
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "mirage.cartesia.warm_started", fields: [:])
        do {
            _ = try await self.currentToken()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "mirage.cartesia.warm_token_ok", fields: [:])
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "error",
                event: "mirage.cartesia.warm_token_failed",
                fields: ["error": "\(error)"])
        }
    }

    func currentToken() async throws -> String {
        try await tokenCache.token { try await self.mintCartesiaToken() }
    }

    func invalidateToken() async {
        await tokenCache.invalidate()
    }

    /// Stream synthesized PCM chunks. Each yielded `Data` is raw s16le
    /// mono at 24 kHz — feed straight into AVAudioEngine's schedule
    /// buffer.
    func synthesize(text: String,
                    voiceID: String? = nil,
                    language: String = "en") async throws -> AsyncThrowingStream<Data, Error> {
        let token = try await currentToken()
        let body: [String: Any] = [
            "model_id": cartesiaDefaultModel,
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": voiceID ?? cartesiaDefaultVoiceID
            ],
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": cartesiaSampleRate
            ],
            "language": language
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: cartesiaSSEURL)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(cartesiaAPIVersion, forHTTPHeaderField: "Cartesia-Version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MirageCartesiaError.sseFailed(-1, body: Data())
        }
        if http.statusCode == 429 {
            await MirageBackendClient.shared.forceRotate()
            await invalidateToken()
        }
        guard http.statusCode == 200 else {
            var buf = Data()
            for try await b in bytes { buf.append(b) }
            throw MirageCartesiaError.sseFailed(http.statusCode, body: buf)
        }

        return AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" { break }
                        guard let jsonData = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }
                        let type = (obj["type"] as? String) ?? ""
                        if type == "chunk",
                           let b64 = obj["data"] as? String,
                           let pcm = Data(base64Encoded: b64), !pcm.isEmpty {
                            continuation.yield(pcm)
                        } else if type == "done" || type == "message_stop" {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
