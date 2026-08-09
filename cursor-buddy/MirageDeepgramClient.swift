//
//  MirageDeepgramClient.swift
//  cursor-buddy
//
//  Free-tier Deepgram STT via aegis-proxy. Two-step wire:
//
//    Step 1 — mint a short-lived Deepgram JWT via POST
//             /v1/deepgram/token on aegis-proxy (rotating anonymous
//             UUID header, no login).
//    Step 2 — open a WSS directly to api.deepgram.com/v1/listen using
//             that JWT as `Authorization: Token <jwt>`. From here on
//             the aegis-proxy is out of the audio path — audio goes
//             directly to Deepgram, and Deepgram's inference bill is
//             charged to the aegis-proxy operator's account.
//
//  This is the free lane's counterpart to Peeky's
//  `peeky/src/providers/stt_deepgram.rs`. Wire-format contract matches
//  byte-for-byte (nova-3 model, linear16, interim_results=true, Finalize
//  → CloseStream sequence, and the same 1.5s grace between them so
//  Deepgram gets a chance to emit the is_final event before the socket
//  drops).
//
//  Session lifecycle:
//    session = MirageDeepgramClient.shared.startSession(sampleRate:channels:keyterm:)
//    session.sendPCM(chunk)   // called from the audio capture callback
//    session.finalize()        // hotkey release / silence detected
//    let final = await session.awaitFinal(timeout: 3.0)
//    // session dies on scope exit or explicit .cancel()
//
//  Threading: the client is an actor; the session holds its own
//  URLSessionWebSocketTask + a MainActor-published `partial` string for
//  UI binding.

import Foundation
#if canImport(NIOCore)
import NIOCore
#endif

// MARK: - Wire constants (mirror Peeky reference client)

/// Endpoint for the raw Deepgram listen stream. Kept in the client
/// itself, not MirageSecrets, because api.deepgram.com is the direct
/// endpoint after token mint — no aegis-proxy involvement.
private let deepgramListenBaseURL = "wss://api.deepgram.com/v1/listen"

/// Model + processing flags. Kept identical to Peeky's URL so the wire
/// looks the same to Deepgram's edge (they log User-Agent + query
/// params — either they don't correlate rotating device-ids yet, or
/// Peeky's is our reference for what passes their bot filters today).
// Deepgram model selection is language-driven. Peeky ships nova-3 for
// English (best latency + accuracy), but nova-3 is English-only —
// speaking Chinese to it returns an empty transcript. Fall back to
// nova-2-general which supports zh-CN + multilingual.
private let deepgramModelDefault = "nova-3"
private let deepgramLanguageDefault = "en"
private let deepgramModelMultilingual = "nova-2-general"

/// Resolve (model, language) from the user's `voiceResponseLanguage`
/// setting. "auto" and "en" → nova-3 + en. "zh"/"ja"/etc → nova-2 with
/// the specific language. Called per-session so Settings changes take
/// effect on the next PTT without a restart.
private func resolveDeepgramModelAndLanguage() -> (model: String, language: String) {
    let raw = AppBundleConfiguration.voiceResponseLanguage()
    switch raw {
    case "auto", "en":
        return (deepgramModelDefault, deepgramLanguageDefault)
    case "zh":
        return (deepgramModelMultilingual, "zh-CN")
    case "ja":
        return (deepgramModelMultilingual, "ja")
    case "es":
        return (deepgramModelMultilingual, "es")
    case "fr":
        return (deepgramModelMultilingual, "fr")
    case "de":
        return (deepgramModelMultilingual, "de")
    default:
        return (deepgramModelDefault, deepgramLanguageDefault)
    }
}
private let deepgramEncoding = "linear16"

/// Errors surfaced by MirageDeepgramClient.
enum MirageDeepgramError: Error, LocalizedError {
    case notConfigured
    case tokenMintFailed(Int, body: Data)
    case websocketFailed(Error)
    case closedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Peeky Free STT is not configured — set MirageSecrets.upstreamBaseURL."
        case .tokenMintFailed(let code, _):
            return "Peeky Free STT token mint returned HTTP \(code)."
        case .websocketFailed(let e):
            return "Deepgram WSS failed: \(e.localizedDescription)"
        case .closedUnexpectedly:
            return "Deepgram WSS closed before returning a transcript."
        }
    }
}

/// Free-tier Deepgram client. Only one instance is needed per app —
/// the actor's UUID pool + token cache is shared across sessions.
actor MirageDeepgramClient {
    static let shared = MirageDeepgramClient()

    private let tokenCache = MirageTokenCache()

    /// Mint a fresh Deepgram JWT via aegis-proxy. Called by the token
    /// cache on cold-start / expiry. Piggybacks the same UUID pool as
    /// MirageBackendClient (which manages the shared rotating identity)
    /// so all three lanes — Anthropic, Deepgram, Cartesia — rotate in
    /// lockstep. This is important: a device-id that exists in the
    /// upstream KV for one provider but not the others is exactly the
    /// fingerprint the mirage pattern is trying to avoid.
    private func mintDeepgramToken() async throws -> (String, TimeInterval) {
        guard let endpoint = MirageSecrets.deepgramTokenURL else {
            throw MirageDeepgramError.notConfigured
        }
        return try await MirageProxyTokenMinter.mint(
            endpoint: endpoint,
            service: "deepgram",
            ttlFallbackSeconds: 60,
            makeError: { code, body in
                MirageDeepgramError.tokenMintFailed(code, body: body)
            })
    }

    /// Public entry: get a cached-or-fresh Deepgram JWT.
    /// Peeky parity: pre-open the TLS connection to api.deepgram.com and
    /// pre-mint a proxy token so the first real STT session doesn't pay
    /// the ~1.5s TCP + TLS + token-mint cold-start. Called on profile
    /// switch. Safe to invoke repeatedly — token cache dedupes.
    func warm() async {
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "mirage.deepgram.warm_started", fields: [:])
        do {
            _ = try await self.currentToken()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "mirage.deepgram.warm_token_ok", fields: [:])
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "error",
                event: "mirage.deepgram.warm_token_failed",
                fields: ["error": "\(error)"])
        }
        var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        req.setValue("Bearer warm", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    func currentToken() async throws -> String {
        try await tokenCache.token { try await self.mintDeepgramToken() }
    }

    /// Invalidate the cached token so the next session mints. Used when
    /// a downstream WSS returns 401/403 (token revoked / rotated
    /// upstream).
    func invalidateToken() async {
        await tokenCache.invalidate()
    }

    /// Open a new streaming session. Returns a `Session` handle the
    /// caller feeds PCM into. Actor boundary crossed once here; every
    /// subsequent send is on the session's own queue.
    func startSession(sampleRate: Int = 16000,
                      channels: Int = 1,
                      keyterm: String = "OpenClicky") async throws -> Session {
        let token = try await currentToken()
        let (model, language) = resolveDeepgramModelAndLanguage()
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "mirage.deepgram.session_config",
            fields: ["model": model, "language": language, "sampleRate": sampleRate])
        var comps = URLComponents(string: deepgramListenBaseURL)!
        var qs: [URLQueryItem] = [
            .init(name: "model", value: model),
            .init(name: "language", value: language),
            .init(name: "encoding", value: deepgramEncoding),
            .init(name: "sample_rate", value: "\(sampleRate)"),
            .init(name: "channels", value: "\(channels)"),
            .init(name: "punctuate", value: "true"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true")
        ]
        // `keyterm=` is nova-3 only. On nova-2 it triggers WS 400 →
        // "服务器发出错误的响应". Use the legacy `keywords=` there.
        if model.hasPrefix("nova-3") {
            qs.append(.init(name: "keyterm", value: keyterm))
        } else {
            qs.append(.init(name: "keywords", value: keyterm))
        }
        comps.queryItems = qs
        guard let url = comps.url else {
            throw MirageDeepgramError.websocketFailed(URLError(.badURL))
        }
        // Peeky's Rust reference (stt_deepgram.rs:170) uses `Bearer <jwt>`
        // for proxy-minted tokens, NOT `Token <api_key>`. Aegis-proxy
        // mints a short-lived Deepgram JWT which authenticates via
        // `Authorization: Bearer <jwt>` — the "Token" scheme is only for
        // long-lived personal API keys in Direct mode.
        //
        // macOS URLSession's WebSocket transport silently strips custom
        // Authorization headers on WSS upgrade. Deepgram's documented
        // workaround for proxied tokens is
        // `Sec-WebSocket-Protocol: bearer, <jwt>` per
        //   https://developers.deepgram.com/docs/authenticating-with-websockets
        // We send both to maximize compatibility.
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: url, protocols: ["bearer", token])
        _ = req
        task.resume()
        let session = Session(task: task)
        // Kick the recv loop. Without this, `awaitFinal()` parks the
        // continuation and never wakes up because nothing is draining
        // inbound frames. Peeky Rust does the same at
        // `stt_deepgram.rs:228-255` (spawns the reader as part of open).
        await session.start()
        return session
    }
}

extension MirageDeepgramClient {

    /// A single Deepgram streaming session. Owns the WS task + a
    /// receive loop; parses partial and is_final events; exposes
    /// `partial()` for the current live guess and `finalTranscript()`
    /// for the committed answer once `finalize()` has been called.
    ///
    /// One session per hotkey press. Discard after use — do not reuse
    /// across turns, matching Peeky's turn-per-connection contract.
    actor Session {
        private let task: URLSessionWebSocketTask
        private var partial: String = ""
        private var finalSegments: [String] = []
        private var receivedFinal: Bool = false
        private var receiveLoopStarted: Bool = false
        private var finalWaiters: [CheckedContinuation<String, Error>] = []

        init(task: URLSessionWebSocketTask) {
            self.task = task
        }

        /// Start the background receive loop. Idempotent.
        func start() {
            guard !receiveLoopStarted else { return }
            receiveLoopStarted = true
            Task { await self.recvLoop() }
        }

        private var pcmBytesSent: Int = 0
        private var pcmChunksSent: Int = 0

        /// Send one PCM chunk (linear16, LE). Caller reshapes any other
        /// format to match `sampleRate` × `channels` upfront.
        func sendPCM(_ pcm: Data) async throws {
            try await task.send(.data(pcm))
            pcmBytesSent += pcm.count
            pcmChunksSent += 1
            if pcmChunksSent == 1 {
                NSLog("[MirageDeepgram] first PCM chunk sent: %d bytes", pcm.count)
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "outgoing",
                    event: "mirage.deepgram.first_pcm",
                    fields: ["bytes": pcm.count])
            }
        }

        /// Diagnostic: how much audio have we shipped this session?
        func stats() -> (chunks: Int, bytes: Int) {
            (pcmChunksSent, pcmBytesSent)
        }

        /// Signal end-of-audio. Sends `{"type":"Finalize"}` — Deepgram
        /// commits pending audio and emits an `is_final` event. Follow
        /// with `awaitFinal` to collect the resulting transcript.
        ///
        /// Do NOT `cancel()` or send CloseStream immediately after — the
        /// receive loop needs time to see the is_final. `awaitFinal`
        /// enforces this waiting.
        func finalize() async throws {
            let msg = URLSessionWebSocketTask.Message.string(#"{"type":"Finalize"}"#)
            try await task.send(msg)
        }

        /// Wait for the first is_final event after `finalize()`. Returns
        /// the assembled transcript (final segments joined, ignoring
        /// interim partials). Times out after `seconds`, returning
        /// whatever partial we have.
        func awaitFinal(seconds: TimeInterval = 3.0) async throws -> String {
            if receivedFinal {
                return finalSegments.joined(separator: " ")
            }
            let result: String
            do {
                result = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await withCheckedThrowingContinuation { cont in
                            Task { await self.parkWaiter(cont) }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        return "" // timeout sentinel
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            } catch {
                // Timeout / cancellation: return whatever we have.
                result = self.currentBestTranscript()
            }
            // Graceful shutdown: CloseStream + close.
            let close = URLSessionWebSocketTask.Message.string(#"{"type":"CloseStream"}"#)
            try? await task.send(close)
            // 1.5s grace matches Peeky reference (agent may still be
            // sending the trailing metadata event).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            task.cancel(with: .goingAway, reason: nil)
            return result.isEmpty ? currentBestTranscript() : result
        }

        /// Live interim guess. Useful for a "you said…" UI overlay.
        func currentPartial() -> String { partial }

        /// Cancel immediately without awaiting is_final. Barge-in path.
        func cancel() {
            task.cancel(with: .goingAway, reason: nil)
        }

        // MARK: - Internals

        private func parkWaiter(_ cont: CheckedContinuation<String, Error>) {
            if receivedFinal {
                cont.resume(returning: finalSegments.joined(separator: " "))
                return
            }
            finalWaiters.append(cont)
        }

        private func currentBestTranscript() -> String {
            let final = finalSegments.joined(separator: " ")
            return final.isEmpty ? partial : final
        }

        private func recvLoop() async {
            while !receivedFinal {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let s):
                        parseEvent(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { parseEvent(s) }
                    @unknown default:
                        continue
                    }
                } catch {
                    // Socket dropped — signal any waiter with best-effort transcript.
                    let best = currentBestTranscript()
                    for cont in finalWaiters { cont.resume(returning: best) }
                    finalWaiters.removeAll()
                    return
                }
            }
        }

        private func parseEvent(_ payload: String) {
            NSLog("[MirageDeepgram] recv: %@", payload.prefix(300).description)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            guard let channel = obj["channel"] as? [String: Any],
                  let alts = channel["alternatives"] as? [[String: Any]],
                  let transcript = alts.first?["transcript"] as? String else {
                return
            }
            let isFinal = (obj["is_final"] as? Bool) ?? false
            if isFinal {
                if !transcript.isEmpty { finalSegments.append(transcript) }
                partial = ""
                receivedFinal = true
                let full = finalSegments.joined(separator: " ")
                for cont in finalWaiters { cont.resume(returning: full) }
                finalWaiters.removeAll()
            } else {
                partial = transcript
            }
        }
    }
}
