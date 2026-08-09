//
//  HeyClickyProxyClient.swift
//  cursor-buddy
//
//  HTTP base for HeyClicky Free Tier. Handles auth headers, 401
//  single-shot refresh-retry, and error taxonomy mapping.
//  See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §1.1 file 1.
//

import Foundation
import Compression

final class HeyClickyProxyClient: @unchecked Sendable {
    static let shared = HeyClickyProxyClient()

    private let urlSession: URLSession
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.proxy")

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            // 45s → 20s. Cloudflare workers cold-start in ~1-3s but
            // the mint round can still stall if a fresh worker was
            // just spun up; 20s gives room without making the UI or
            // WS start-up wait a full minute for a doomed request.
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 120
            config.waitsForConnectivity = true
            // Keep TCP + TLS connections warm across mint / chat /
            // plan calls so we don't pay a 3-way handshake + TLS 1.3
            // round-trip on every request. HTTP/2 multiplexes multiple
            // requests over one connection — with `httpShouldUsePipelining`
            // and a high per-host cap the proxy calls (mint token,
            // chat-tool-call, plan refresh) all ride the same socket.
            config.httpShouldUsePipelining = true
            config.httpMaximumConnectionsPerHost = 6
            // Accept-Encoding gzip is opt-in default in URLSession, but
            // Content-Encoding on outgoing bodies is not — we gzip the
            // outbound JSON manually for chat-tool-call (300KB → ~50KB
            // on a Retina screenshot after base64). See postJSON.
            config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, br"]
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Perform a JSON POST against `<proxyBase><path>`. Retries once on 401
    /// after refreshing the session token.
    func postJSON(
        path: String,
        body: Data,
        includeDictationReceipt: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        let url = base.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)

        return try await sendWithRefresh(url: url, method: "POST", contentType: "application/json", body: body, includeDictationReceipt: includeDictationReceipt)
    }

    /// GET a JSON resource with the same X-Clicky headers + refresh
    /// retry logic. Path may embed a query string. Returns raw body +
    /// HTTPURLResponse so callers can inspect status codes.
    func getJSON(
        path: String,
        includeDictationReceipt: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        // Preserve any query string embedded in `path` — URL relative
        // resolution swallows it, so build the full URL manually.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            throw HeyClickyProxyError.malformedResponse
        }
        return try await sendWithRefresh(
            url: url,
            method: "GET",
            contentType: "application/json",
            body: Data(),
            includeDictationReceipt: includeDictationReceipt
        )
    }

    /// Perform a multipart POST. Retries once on 401.
    func postMultipart(
        path: String,
        body: Data,
        boundary: String,
        includeDictationReceipt: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let base = try AppBundleConfiguration.heyClickyProxyBaseURL()
        let url = base.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        return try await sendWithRefresh(
            url: url,
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body,
            includeDictationReceipt: includeDictationReceipt
        )
    }

    private func sendWithRefresh(
        url: URL,
        method: String,
        contentType: String,
        body: Data,
        includeDictationReceipt: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try await makeRequest(url: url, method: method, contentType: contentType, body: body, includeDictationReceipt: includeDictationReceipt)

        do {
            HeyClickyLog.log("proxy.request", lane: "system", direction: "outgoing", [
                "method": method,
                "path": url.path,
                "body_bytes": body.count,
                // Debug: for small non-sensitive endpoints, dump body
                // keys to verify shape. Cap 400 bytes. Content field
                // itself may be long; take only key structure.
                "reqPeek": url.path.contains("codex-thread-launch") || url.path.contains("record-agent-launch") ?
                    String(data: body.prefix(400), encoding: .utf8) ?? "<binary>" : "-"
            ])
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                HeyClickyLog.log("proxy.no_http_response", direction: "error", ["path": url.path])
                throw HeyClickyProxyError.malformedResponse
            }
            let cfRay = http.value(forHTTPHeaderField: "cf-ray") ?? "-"
            HeyClickyLog.log("proxy.response", lane: "system", direction: "incoming", [
                "path": url.path,
                "status": http.statusCode,
                "body_bytes": data.count,
                "cfRay": cfRay,
                // Include full body verbatim on non-2xx so shape / auth
                // errors are diagnosable from the log without needing
                // to attach a network sniffer. Cap at 800 bytes.
                "errPeek": (200..<300).contains(http.statusCode) ? "-" :
                    String(data: data.prefix(800), encoding: .utf8) ?? "<binary>",
                // Also capture 200 bodies for lease endpoints — that's
                // where cost/quota telemetry lives and we need to see
                // the raw fields to know what the server actually
                // returns (docs / IDA schema may not match reality).
                "leasePeek": (url.path.contains("record-agent-launch")
                              || url.path.contains("turn-lease"))
                             && (200..<300).contains(http.statusCode)
                    ? (String(data: data.prefix(800), encoding: .utf8) ?? "<binary>")
                    : "-"
            ])
            // Cloudflare geo-block: proxy Worker returns 403
            // "Country, region, or territory not supported" for
            // certain edges (users routed through Dubai/India). This
            // is a routing artifact — retrying with a fresh URLSession
            // forces DNS re-resolve + new TCP handshake so Anycast
            // may pick a different edge. Only retry once to avoid
            // amplification against a genuinely blocked account.
            if http.statusCode == 403,
               let bodyStr = String(data: data, encoding: .utf8),
               bodyStr.contains("Country") || bodyStr.contains("region") {
                HeyClickyLog.log("proxy.geo_block_retry", lane: "system",
                                 direction: "internal",
                                 ["cfRay": cfRay, "path": url.path])
                let freshConfig = URLSessionConfiguration.ephemeral
                freshConfig.timeoutIntervalForRequest = 30
                freshConfig.httpAdditionalHeaders = ["Accept-Encoding": "gzip, br"]
                let freshSession = URLSession(configuration: freshConfig)
                let retryReq = try await makeRequest(url: url, method: method, contentType: contentType, body: body, includeDictationReceipt: includeDictationReceipt)
                let (retryData, retryResp) = try await freshSession.data(for: retryReq)
                if let retryHttp = retryResp as? HTTPURLResponse {
                    let retryRay = retryHttp.value(forHTTPHeaderField: "cf-ray") ?? "-"
                    HeyClickyLog.log("proxy.geo_block_retry_result", lane: "system",
                                     direction: "internal",
                                     ["cfRay": retryRay, "status": retryHttp.statusCode])
                    if (200..<300).contains(retryHttp.statusCode) {
                        return (retryData, retryHttp)
                    }
                }
            }
            // Real signal that everything is healthy: any 2xx proxy
            // response proves both network and auth are working. Post
            // .ready so a stale recovery caption ("网络恢复中…" /
            // "正在续期额度…") clears immediately. UI truth: the
            // caption is only visible when a live problem exists.
            if (200..<300).contains(http.statusCode) {
                NotificationCenter.default.postHeyClickyStatus(.ready)
            }
            if http.statusCode == 401 {
                let refreshed = try await HeyClickySessionAuthenticator.shared.refresh()
                if refreshed {
                    request = try await makeRequest(url: url, method: method, contentType: contentType, body: body, includeDictationReceipt: includeDictationReceipt)
                    let (retryData, retryResponse) = try await urlSession.data(for: request)
                    guard let retryHttp = retryResponse as? HTTPURLResponse else {
                        throw HeyClickyProxyError.malformedResponse
                    }
                    try mapError(status: retryHttp.statusCode)
                    return (retryData, retryHttp)
                }
                // Refresh failed → surface via router so UI can prompt sign-in-again.
                NotificationCenter.default.post(
                    name: .clickyHeyClickySessionExpired,
                    object: nil
                )
                throw HeyClickyProxyError.unauthorized
            }
            try mapError(status: http.statusCode)
            return (data, http)
        } catch let err as HeyClickyProxyError {
            throw err
        } catch {
            throw HeyClickyProxyError.transportError(error)
        }
    }

    /// Retry wrapper around `sendWithRefresh` with exponential backoff
    /// on transient errors (5xx, network). Delays: 1s, 2s, 5s, 15s,
    /// 30s. Fail-fast on 401/402/429/400 — those are semantic, not
    /// transient. Ceiling: 5 tries then re-throw. Used by callers who
    /// want end-to-end resilience without adding their own loop.
    func postJSONWithBackoff(
        path: String,
        body: Data,
        includeDictationReceipt: Bool = false,
        maxAttempts: Int = 5
    ) async throws -> (Data, HTTPURLResponse) {
        let delays: [UInt64] = [1_000_000_000, 2_000_000_000, 5_000_000_000, 15_000_000_000, 30_000_000_000]
        var lastError: Error = HeyClickyProxyError.malformedResponse
        for attempt in 0..<maxAttempts {
            do {
                return try await postJSON(path: path, body: body, includeDictationReceipt: includeDictationReceipt)
            } catch let err as HeyClickyProxyError {
                switch err {
                case .upstreamUnavailable, .transportError:
                    lastError = err
                    if attempt < maxAttempts - 1 {
                        let delay = delays[min(attempt, delays.count - 1)]
                        HeyClickyLog.log("proxy.backoff_retry", lane: "system",
                                         direction: "internal",
                                         ["path": path, "attempt": attempt + 1,
                                          "waitMs": Int(delay / 1_000_000)])
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                case .unauthorized, .quotaExhausted, .malformedResponse, .leaseNeedsContinue:
                    // Semantic — don't retry blindly.
                    throw err
                }
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    let delay = delays[min(attempt, delays.count - 1)]
                    try? await Task.sleep(nanoseconds: delay)
                    continue
                }
            }
        }
        throw lastError
    }

    private func makeRequest(
        url: URL,
        method: String,
        contentType: String,
        body: Data,
        includeDictationReceipt: Bool
    ) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Skip client-side gzip: the Cloudflare Worker fronting HeyClicky
        // doesn't accept `Content-Encoding: gzip` on inbound bodies and
        // returns 400 malformedResponse. Downscale + screenshot quality
        // already cuts the payload from 300KB → 60-80KB which is fine
        // over HTTP/2 keep-alive.
        request.httpBody = body
        if let token = AppBundleConfiguration.heyClickySessionAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        await HeyClickyHeaderBuilder.shared.apply(to: &request, includeDictationReceipt: includeDictationReceipt)
        return request
    }

    private func mapError(status: Int) throws {
        switch status {
        case 200...299: return
        case 401: throw HeyClickyProxyError.unauthorized
        case 402, 429: throw HeyClickyProxyError.quotaExhausted
        case 500...599: throw HeyClickyProxyError.upstreamUnavailable
        default: throw HeyClickyProxyError.malformedResponse
        }
    }

    /// Gzip a request body using Apple's Compression framework and
    /// prepend the 10-byte gzip header so Cloudflare workers /
    /// standard HTTP proxies recognize it as `Content-Encoding: gzip`
    /// instead of raw DEFLATE. Returns nil when compression fails —
    /// caller falls back to the uncompressed body.
    fileprivate static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bufferSize = max(64, data.count)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }
        let compressedSize: Int = data.withUnsafeBytes { rawBuffer -> Int in
            guard let sourceBaseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, bufferSize,
                sourceBaseAddress, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else { return nil }
        // Prepend the gzip header (10 bytes) and append the 8-byte
        // trailer (CRC32 + ISIZE). COMPRESSION_ZLIB emits raw deflate,
        // NOT gzip — wrap it manually to match the `gzip` Content-Encoding.
        var out = Data()
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(destinationBuffer, count: compressedSize)
        var crc = HeyClickyProxyClient.crc32(data)
        var size = UInt32(data.count & 0xffffffff)
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// CRC-32 (IEEE polynomial) needed for gzip trailer. Tiny table-less
    /// implementation — fine for one-shot payload sizes we send.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (0xedb88320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        return crc ^ 0xffffffff
    }
}
