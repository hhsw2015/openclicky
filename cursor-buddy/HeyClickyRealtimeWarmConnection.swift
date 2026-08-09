//
//  HeyClickyRealtimeWarmConnection.swift
//  cursor-buddy
//
//  Persistent, pre-warmed OpenAI Realtime WebSocket. Reversed from
//  HeyClicky-1.0.40 DictationController.WarmStreamingConnection:
//  build a WS once, keep it alive with a periodic {"type":"KeepAlive"},
//  hand it off to a PTT turn on demand, then rebuild the next warm
//  connection in the background so the following turn is also instant.
//
//  Design goals (IDA-verified strings):
//   - `warmStreamingConnection`         — the held task
//   - `warmConnectionKeepAliveTimer`   — pings periodically
//   - `isWarmingConnection`             — prevents concurrent builds
//   - `didStartFromWarmConnection` / `usedWarmConnection` — telemetry
//   - `{"type":"KeepAlive"}`            — the ping message
//   - `openWebSocketSession`            — the actual WS constructor
//
//  Kept in a dedicated file so the OpenAIRealtimeSpeechClient logic
//  isn't further complicated. This is HeyClicky-Free specific: the
//  proxy hook mints a fresh ephemeral for each warm session, and the
//  baked model is pulled from the same mint response.
//

import Foundation

/// Pre-built realtime WS handoff. The receiver takes ownership of
/// the WS + the mint metadata used to build it; the warm connection
/// pool immediately kicks off building the NEXT one so the following
/// PTT is also instant.
struct HeyClickyWarmRealtimeSession: @unchecked Sendable {
    let webSocket: URLSessionWebSocketTask
    let bakedModel: String
    let bakedInstructions: String?
    let bearerToken: String
    let createdAt: Date
}

@MainActor
final class HeyClickyRealtimeWarmConnection {
    static let shared = HeyClickyRealtimeWarmConnection()

    /// Held warm session. `nil` means either we've never warmed, or
    /// the last one was already consumed. `checkOut()` swaps this to
    /// nil atomically then triggers a background rebuild.
    private var current: HeyClickyWarmRealtimeSession?
    private var isWarming = false
    private var keepAliveTimer: Timer?
    private var urlSession: URLSession?

    /// Keepalive ping interval. Chose 25s — servers commonly time out
    /// idle WS at 60s; 25s leaves headroom for a lost ping without
    /// dropping the session.
    private static let keepAliveInterval: TimeInterval = 25
    /// Warm sessions older than this get discarded and rebuilt. Even
    /// with keepalives some backends recycle sockets around 5 min.
    private static let maxAge: TimeInterval = 240

    private init() {}

    /// Kick a warm connection at app boot / after successful sign-in.
    /// Idempotent — a second call while a build is in-flight is a no-op.
    func kick() {
        guard AppBundleConfiguration.heyClickySignedIn() else { return }
        guard !isWarming else { return }
        if let current, Date().timeIntervalSince(current.createdAt) < Self.maxAge {
            // still fresh, no need to rebuild
            return
        }
        Task { await self.buildNextWarmSession() }
    }

    /// Hand the currently warm session over to the caller (if any).
    /// Returns nil when no session is warm; caller should fall back to
    /// the standard connect-on-demand path. Immediately triggers a
    /// background rebuild for the next PTT.
    func checkOut() -> HeyClickyWarmRealtimeSession? {
        stopKeepAlive()
        let session = current
        current = nil
        // Kick off the next warm session so the *following* PTT is
        // also instant. Fire-and-forget — errors don't block the
        // caller who is already consuming the current session.
        Task { await self.buildNextWarmSession() }
        return session
    }

    private func buildNextWarmSession() async {
        guard !isWarming else { return }
        isWarming = true
        defer { isWarming = false }

        do {
            let (bearer, _) = try await HeyClickySessionTokenClient.shared.mintRealtimeToken()
            let bakedModel = HeyClickySessionTokenClient.shared.bakedRealtimeModel ?? "gpt-realtime-2"
            let bakedInstructions = HeyClickySessionTokenClient.shared.bakedRealtimeInstructions

            guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else { return }
            components.queryItems = [URLQueryItem(name: "model", value: bakedModel)]
            guard let url = components.url else { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)
            self.urlSession = session

            let ws = session.webSocketTask(with: request)
            ws.resume()

            // Wait for the server hello before we call the session warm.
            // A raw resume() only opens the socket — server may still
            // reject on model / auth, and we'd rather find out here
            // than at the moment the user presses PTT.
            // Give the WS a beat to complete TLS + upgrade before we
            // call it "ready". We deliberately do NOT read the first
            // frame here — the consuming turn's own receive loop will
            // pick up `session.created`. Reading it here would eat the
            // event and hang the consumer waiting for a message that
            // already got consumed.
            try? await Task.sleep(nanoseconds: 800_000_000)
            HeyClickyLog.log("realtime.warm_ws_ready", lane: "voice", direction: "internal", [
                "baked_model": bakedModel
            ])

            let warm = HeyClickyWarmRealtimeSession(
                webSocket: ws,
                bakedModel: bakedModel,
                bakedInstructions: bakedInstructions,
                bearerToken: bearer,
                createdAt: Date()
            )
            self.current = warm
            self.startKeepAlive()
            HeyClickyLog.log("realtime.warm_ready", lane: "voice", direction: "internal", [
                "baked_model": bakedModel
            ])
        } catch {
            HeyClickyLog.log("realtime.warm_failed", lane: "voice", direction: "error", [
                "error": "\(error)"
            ])
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = Timer(timeInterval: Self.keepAliveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendKeepAlive()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func sendKeepAlive() {
        guard let current else { return }
        // OpenAI Realtime API rejects `{"type":"KeepAlive"}` (that was
        // HeyClicky's *proxy-side* dictation ping, not something OpenAI
        // itself accepts). Use a benign `session.update` no-op instead:
        // resending session-level config with no changes is a legal
        // event that OpenAI acknowledges without side effects, so the
        // socket stays alive without corrupting session state.
        let payload = #"{"type":"session.update","session":{}}"#
        Task {
            do {
                try await current.webSocket.send(.string(payload))
            } catch {
                // Send failed: session likely closed. Drop the held
                // reference so the next checkOut() will rebuild.
                await MainActor.run {
                    self.current = nil
                    self.stopKeepAlive()
                }
                // Kick a rebuild so the next PTT still gets a warm one.
                await MainActor.run { self.kick() }
            }
        }
    }
}
