//
//  MirageProxyTokenMinter.swift
//  cursor-buddy
//
//  Shared token-mint recipe for the aegis-proxy free-tier lanes. Deepgram
//  and Cartesia both hit the proxy the same way — POST an empty JSON body
//  with the rotating x-peeky-device-id, decode `{token, expires_in}`, cache
//  under a per-service key — so this file owns the recipe once instead of
//  copying it into every provider client.
//
//  Wire fingerprint is preserved bit-for-bit: same header order, same UA
//  `reqwest/0.13.4`, same accept, same body `{}`. Callers pass an
//  endpoint URL and an "error factory" so status-code mapping stays in
//  the caller's own error type.
//
//  Reference: Peeky Rust `providers/stt_deepgram.rs:mint_token` +
//  `providers/tts_cartesia.rs:mint_token` (identical shapes).

import Foundation

enum MirageProxyTokenMinter {
    /// Mint a bearer token from the aegis-proxy. Returns `(token, ttl)`
    /// so the caller can seed its `MirageTokenCache`.
    /// - Parameters:
    ///   - endpoint: proxy URL for this service (e.g. `MirageSecrets.deepgramTokenURL`)
    ///   - service: human-readable name used only for logging
    ///   - session: URLSession to use (defaults to `.shared`)
    ///   - makeError: caller-owned error factory `(statusCode, body) -> Error`
    ///     used for non-429 failures so callers keep their bespoke error types
    ///   - ttlFallbackSeconds: what to return when the proxy omits
    ///     `expires_in` (Peeky Rust reference: 60s)
    static func mint(
        endpoint: URL,
        service: String,
        session: URLSession = .shared,
        ttlFallbackSeconds: TimeInterval = 60,
        makeError: @Sendable (Int, Data) -> Error
    ) async throws -> (token: String, ttl: TimeInterval) {
        let uuid = await MirageBackendClient.shared.nextDeviceID()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(uuid, forHTTPHeaderField: "x-peeky-device-id")
        req.setValue("reqwest/0.13.4", forHTTPHeaderField: "user-agent")
        req.setValue("*/*", forHTTPHeaderField: "accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "error",
                event: "mirage.\(service).token_transport_failed",
                fields: ["error": "\(error)"])
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw makeError(-1, data)
        }
        if http.statusCode == 429 {
            // Rotate the shared UUID pool so subsequent calls (mint or
            // otherwise) advance to the next identity, mirroring Peeky
            // Rust's `mint_token` behavior on quota exhaustion.
            await MirageBackendClient.shared.forceRotate()
            throw makeError(429, data)
        }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String else {
            throw makeError(http.statusCode, data)
        }
        let ttl = TimeInterval((obj["expires_in"] as? Int) ?? Int(ttlFallbackSeconds))
        return (token, ttl)
    }
}
