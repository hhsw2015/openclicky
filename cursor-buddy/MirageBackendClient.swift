//
//  MirageBackendClient.swift
//  cursor-buddy
//
//  Free-tier Claude via aegis-proxy (the referenceprotocol). Direct Swift port of
//  the CPA reference implementation (`internal/runtime/executor/claude_mirage.go`
//  + the mirage case of `claude_executor.go`). Behaviour parity:
//
//   * Anonymous rotating UUID header (`x-peeky-device-id`). No login, no key.
//   * Wire-exact reqwest/0.13.4 header set (lowercase keys, no Accept-Encoding,
//     no Claude-Code fingerprint like X-Stainless-*, no X-App).
//   * Trial tier: ~20 requests per UUID per UTC day. On HTTP 429 we force a
//     fresh UUID and let the caller retry.
//   * Optional interleaved-thinking-2025-05-14 beta header emitted only when
//     the body actually activates thinking (thinking.type ∈ adaptive/enabled,
//     output_config.effort non-empty, or thinking.budget_tokens > 0).
//
//  Non-goals (kept the Swift side minimal on purpose):
//   * No uTLS / JA3 spoofing — Foundation URLSession on macOS already
//     presents a legitimate consumer-app fingerprint. The upstream Cloudflare
//     Worker never sees TLS layer metadata anyway.
//   * No WARP tunnel — users route themselves (VPN etc.). Direct HTTPS to the
//     Worker over URLSession.
//   * No local HTTP relay here — MirageLocalRelay wraps this client and is
//     what Claude Code hits via ANTHROPIC_BASE_URL during agent turns.
//
//  See also:
//   * docs/mirage-openclicky-integration-plan.md (Section 4.1, 4.5, 4.13)
//   * /Users/wowdd1/Dev/CLIProxyAPIPlus/internal/runtime/executor/claude_mirage.go
//     for the Go reference this was ported from.

import Foundation

#if canImport(NIOCore)
import NIOCore
#endif

#if canImport(NIOHPACK)
import NIOHPACK
#endif

// (Messages endpoint is resolved inline as `MirageSecrets.anthropicMessagesURL`
// at each call site — needed because a top-level `var` gets synthesised as
// main-actor-isolated under Swift concurrency, which the `actor` context of
// MirageBackendClient can't touch. Static enum access from MirageSecrets is
// fine because MirageSecrets has no isolation itself.)

/// Header name the upstream inspects. Do NOT rename — the value is dictated by
/// the remote service and any change breaks the protocol. Lowercase matches
/// what the reference Rust reqwest client sends on the wire (HTTP/2 canonicalises to
/// lowercase anyway, but keeping the map key lowercase means no accidental
/// canonical duplicate leaks through in the H1 fallback path).
private let mirageDeviceHeader = "x-peeky-device-id"

/// UA string the upstream sees. Must match the version pinned in the
/// reference Rust client's `Cargo.toml`; a wrong minor version is itself a
/// fingerprint. Update in lockstep with the CPA constant of the same value.
private let mirageUserAgent = "reqwest/0.13.4"

/// Default rotation threshold. Matches CPA's `mirageDefaultRotateAt = 19`
/// (`internal/runtime/executor/claude_mirage.go`) so a shared observer of
/// both codebases cannot distinguish which client is talking to the upstream
/// by rotation cadence. Trial tier allows ~20 turns per UUID per UTC day;
/// rotating at 19 keeps 1 turn of headroom before hitting 429.
private let mirageDefaultRotateAt = 19

/// Beta header emitted for turns that activate Claude's thinking pathway.
/// Matches what the CPA Go executor sends when it detects a thinking-shaped
/// body (see `mirageThinkingActive` in claude_mirage.go).
private let mirageThinkingBeta = "interleaved-thinking-2025-05-14"

/// Anonymous device-id pool + counter. One `MirageBackendClient` maintains a
/// single pool; every request touches `nextDeviceID()` which auto-rotates
/// when the counter crosses `rotateAt`, or when `forceRotate()` fires after
/// an upstream 429. Serialised through an `actor` so the streaming and
/// non-streaming call sites share the same pool safely.
actor MirageBackendClient {
    /// Shared instance. Callers should use this rather than allocating their
    /// own — a single UUID pool is preferable so 429s in one code path bump
    /// the counter that the other paths (relay, direct SSE) also see.
    static let shared = MirageBackendClient()

    /// Current UUID; refreshed after `rotateAt` uses or on force rotation.
    /// Seed is loaded from disk so the base install-id survives restarts and
    /// the daily quota is metered per-install (parity with Peeky Rust
    /// `providers/device_id.rs`). In-memory rotation still bumps this off
    /// disk; the file only stores the stable seed.
    private var deviceID: String = MirageBackendClient.loadOrCreateDeviceID()

    /// Disk-backed seed UUID location. Kept alongside other OpenClicky
    /// state under Application Support. Reads on cold start, writes only
    /// when the file is missing / corrupt.
    private static func deviceIDURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("openclicky", isDirectory: true)
            .appendingPathComponent("mirage_device_id")
    }

    private static func loadOrCreateDeviceID() -> String {
        let url = deviceIDURL()
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let uuid = UUID(uuidString: trimmed) {
                return uuid.uuidString.lowercased()
            }
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }

    /// Number of successful sends against the current `deviceID`.
    private var counter: Int = 0

    /// Rotate proactively at this counter value. See `mirageDefaultRotateAt`
    /// for the rationale on staying below the 20/day upstream ceiling.
    private let rotateAt: Int

    /// URLSession dedicated to mirage traffic so cookie storage and cache
    /// stay isolated from the app's other HTTP work. `ephemeral` avoids
    /// persisting anything (matches the reference rustls client posture).
    private let session: URLSession

    init(rotateAt: Int = mirageDefaultRotateAt) {
        self.rotateAt = rotateAt
        let cfg = URLSessionConfiguration.ephemeral
        // Suppress URLSession's default fingerprint headers on the mirage
        // fallback path. Setting them to empty strings tells CFNetwork
        // NOT to auto-inject `Accept-Encoding: gzip, deflate, br`,
        // `Accept-Language`, `Priority`, or its own `User-Agent` — which
        // together are the fingerprint the NIO transport was built to
        // erase. Passing `nil` leaves them at their defaults; empty
        // string is the documented "please do not send this" contract.
        cfg.httpAdditionalHeaders = [
            "Accept-Encoding": "",
            "Accept-Language": "",
            "Priority": "",
            "User-Agent": mirageUserAgent
        ]
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        // Ask URLSession to prefer HTTP/2. Cloudflare Workers always negotiate
        // h2, so this avoids an ALPN downgrade to h1 which would then require
        // extra care around header casing.
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
    }

    /// Return the current UUID, rotating first if the counter reached the
    /// threshold. Also increments the counter — one call per outgoing request.
    func nextDeviceID() -> String {
        if counter >= rotateAt {
            deviceID = UUID().uuidString.lowercased()
            counter = 0
        }
        counter += 1
        return deviceID
    }

    /// Discard the current UUID immediately. Called after an upstream 429 so
    /// the *next* request lands on a fresh quota bucket. The current request
    /// still fails; the caller decides whether to inline-retry (relay does,
    /// direct callers can too).
    func forceRotate() {
        deviceID = UUID().uuidString.lowercased()
        counter = 1
    }

    /// Snapshot of pool state for logging / diagnostics only.
    func snapshot() -> (deviceID: String, counter: Int, rotateAt: Int) {
        (deviceID, counter, rotateAt)
    }

    // MARK: - Header assembly (see wireHeaders below — kept as ordered tuple
    // list because NIOHPACK encodes headers in the order supplied. Any header
    // outside the emitted set fingerprints the caller as non-conforming.)

    /// Return true when the request body activates a thinking mode that
    /// requires the interleaved-thinking beta header. Mirrors the Go helper
    /// `mirageThinkingActive` in `claude_mirage.go`.
    private func thinkingActive(bodyData: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return false
        }
        if let t = obj["thinking"] as? [String: Any] {
            if let type = t["type"] as? String, ["adaptive", "enabled"].contains(type.lowercased()) {
                return true
            }
            if let budget = t["budget_tokens"] as? Int, budget > 0 { return true }
            if let budget = t["budget_tokens"] as? Double, budget > 0 { return true }
        }
        if let oc = obj["output_config"] as? [String: Any],
           let effort = oc["effort"] as? String,
           !effort.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return false
    }

    // MARK: - Public API

    /// Rewrite the outbound body so the upstream (aegis-proxy → Anthropic)
    /// receives exactly the shape it accepts:
    ///
    /// 1. Strip the catalog-side `mirage/` namespace off the `model` field
    ///    (matches CPA's `sdk/cliproxy/auth/conductor.go` prefix rewrite,
    ///    see docs/mirage-porting-guide.md).
    /// 2. Parse any suffix on the model id (`claude-fable-5(max)`,
    ///    `claude-opus-5(xhigh)`, `claude-fable-5(16384)`) and rewrite the
    ///    `thinking` / `output_config` fields to whatever the suffix maps
    ///    to. This is the Swift port of CPA's `internal/thinking` pipeline
    ///    (spec: docs/mirage-cpa-callflow-spec.md §2.4). Suffix-based body
    ///    injection is what makes `mirage/claude-fable-5(max)` deliver the
    ///    same behaviour under OpenClicky as it does under CPA.
    /// 3. Opus-4.7 up-conversion of legacy `thinking.type=enabled` bodies
    ///    is handled inside the suffix applier's passthrough branch.
    ///
    /// A body that fails to parse as JSON is returned unchanged — the
    /// upstream will reject it and the caller gets a clean error rather
    /// than a silent rewrite.
    private func normalizeBody(_ body: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
              let rawModel = obj["model"] as? String else {
            return body
        }
        // Suffix parser strips the `mirage/` namespace itself, so we feed
        // it the raw model id. `apply` rewrites obj["model"] to the bare id.
        //
        // Default = adaptive `(auto)`. Anthropic's Claude 4+ family lets
        // the model decide thinking budget per-turn — simple "hi" gets
        // near-zero thinking (fast), complex "explain this code" gets
        // deep thinking automatically. Users can override in Peeky
        // Settings with `off` (no thinking, Peeky reference parity),
        // `low..max` (fixed floor), or `(xhigh)` baked in the model id.
        var effectiveModel = rawModel
        if !rawModel.contains("(") {
            let raw = (UserDefaults.standard.string(forKey: "openClickyMirageDialogEffort") ?? "").lowercased()
            switch raw {
            case "off", "none":
                // No thinking suffix — model gets a bare request. The
                // system prompt itself instructs the model to self-pace
                // thinking depth based on the user's question. Default
                // path: fast for chit-chat, deep only when needed.
                break
            case "", "adaptive", "dynamic":
                // Same as `off` — system prompt does the pacing. Left
                // as a named option so users can tell the "let the
                // model decide" mode apart from a hard "no thinking".
                break
            case "auto":
                // Anthropic server-side adaptive (slower on fable-5).
                effectiveModel = "\(rawModel)(auto)"
            default:
                // User pinned a specific level.
                effectiveModel = "\(rawModel)(\(raw))"
            }
        }
        let suffix = MirageThinkingSuffix.parse(effectiveModel)
        let maxTokens = (obj["max_tokens"] as? Int)
            ?? Int((obj["max_tokens"] as? Double) ?? 0)
        suffix.apply(to: &obj, clampMaxTokens: maxTokens > 0 ? maxTokens : nil)

        // Run the full CPA-parity body pipeline after suffix injection so
        // the ordering matches `claude_executor.go:359-424`: suffix (which
        // sets thinking + effort) runs first, then the pipeline can
        // observe those fields when it strips sampling params, injects
        // thinking.display, etc.
        //
        // Betas the caller embedded in `body["betas"]` are pulled out here
        // and forwarded via the anthropic-beta header. That happens inside
        // `wireHeaders`, not here — for now we surface the extracted set
        // through a side channel on the actor. TODO(mirage-body-pipeline):
        // thread these into the outbound request's anthropic-beta.
        let bareModel = obj["model"] as? String ?? rawModel
        let bodyBetas = MirageBodyPipeline.apply(&obj, model: bareModel)
        if !bodyBetas.isEmpty {
            pendingBodyBetas = bodyBetas
        }
        pendingModelForBeta = bareModel

        return (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? body
    }

    /// Betas pulled out of the last `normalizeBody` call. Consumed by
    /// `wireHeaders` on the same actor turn (single-request contract —
    /// send and sendStreamingChunks read this immediately after the
    /// normalize step, before the request goes out). Reset after read.
    private var pendingBodyBetas: [String] = []

    /// Bare model id set by normalizeBody so wireHeaders can decide whether
    /// to auto-attach the 1M context beta. Reset in wireHeaders per-request.
    private var pendingModelForBeta: String? = nil

    /// Models with published 1M context support on the Anthropic API. Kept
    /// as a set here so both the direct-API path (this file) and the Claude
    /// Code CLI path (ClaudeAgentRunner) can agree on which get `[1m]`.
    static func supportsOneMillionContext(_ bareModel: String) -> Bool {
        let m = bareModel.lowercased()
        return m.contains("opus-5")
            || m.contains("opus-4-8")
            || m.contains("opus-4-7")
            || m.contains("sonnet-4-6")
            || m.contains("fable-5")
    }

    /// Ordered header tuple list for the wire. NIO preserves insertion order
    /// into HPACK, so the sequence here is what the peer sees.
    private func wireHeaders(deviceID: String, bodyActivatesThinking: Bool) -> [(String, String)] {
        var h: [(String, String)] = [
            ("content-type", "application/json"),
            ("anthropic-version", "2023-06-01"),
            (mirageDeviceHeader, deviceID),
            ("user-agent", mirageUserAgent),
            ("accept", "*/*")
        ]

        // Assemble anthropic-beta. Three sources merge, dedup, join with
        // commas (matches CPA `applyClaudeHeaders` mirage arm which
        // conditionally emits a single anthropic-beta value):
        //   1. Interleaved thinking (when thinking is active in the body).
        //   2. Any strings the caller stashed in body.betas — pulled out
        //      by MirageBodyPipeline.extractAndRemoveBetas and left in
        //      pendingBodyBetas.
        // CPA also merges from a `strip_anthropic_beta` allowlist per
        // auth attribute, which we don't have in the Swift port because
        // there's only one mirage auth here — the default set is fine.
        var betas: [String] = []
        if bodyActivatesThinking { betas.append(mirageThinkingBeta) }
        // 1M context window beta — ON BY DEFAULT for models Anthropic
        // publishes 1M for (Opus 5, Sonnet 4.6, Fable 5). User can
        // disable in Peeky panel if the aegis-proxy operator's key
        // lacks the 1M entitlement (rare — most modern keys do).
        // Storage key `openClickyMirage1MContextDisabled` (opt-OUT)
        // rather than opt-in so the default matches the user's
        // request "能用 1M 就用 1M".
        if let m = pendingModelForBeta,
           Self.supportsOneMillionContext(m),
           !UserDefaults.standard.bool(forKey: "openClickyMirage1MContextDisabled") {
            betas.append("context-1m-2025-08-07")
        }
        betas.append(contentsOf: pendingBodyBetas)
        pendingBodyBetas.removeAll()
        pendingModelForBeta = nil
        // Dedup preserving order.
        var seen = Set<String>()
        let dedup = betas.filter { seen.insert($0).inserted }
        if !dedup.isEmpty {
            h.append(("anthropic-beta", dedup.joined(separator: ",")))
        }
        return h
    }

    /// Send a non-streaming request. `body` is standard Anthropic Messages
    /// API JSON. Returns the raw response bytes + HTTP status. On 429 we
    /// auto-rotate the UUID before returning so the caller can retry.
    func send(body: Data) async throws -> (data: Data, status: Int) {
        guard let endpoint = MirageSecrets.anthropicMessagesURL else { throw MirageError.notConfigured }
        let outBody = normalizeBody(body)
        let uuid = nextDeviceID()
        let headers = wireHeaders(deviceID: uuid, bodyActivatesThinking: thinkingActive(bodyData: outBody))

        #if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOHTTP2) && canImport(NIOSSL) && canImport(NIOHPACK)
        let wire = MirageWireRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: outBody
        )
        let response = try await MirageWireTransport.send(wire)
        if response.status == 429 {
            forceRotate()
            let retryAfter = Self.retryAfterSeconds(fromNIO: response.headers)
            throw MirageError.quotaExhausted(retryAfter: retryAfter)
        }
        var buf = Data()
        for try await chunk in response.body {
            buf.append(Data(chunk.readableBytesView))
        }
        return (buf, response.status)
        #else
        // Fallback: URLSession. Adds Accept-Encoding / Accept-Language /
        // Priority / its own User-Agent — a distinct fingerprint. Only used
        // until SwiftNIO SPM deps are wired into the Xcode project.
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = outBody
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MirageError.invalidResponse
        }
        if http.statusCode == 429 {
            forceRotate()
            throw MirageError.quotaExhausted(retryAfter: Self.retryAfterSeconds(fromURLResponse: http))
        }
        return (data, http.statusCode)
        #endif
    }

    /// Send a streaming request. Yields body bytes as `Data` chunks so
    /// callers (SSE parsers) can process events incrementally.
    func sendStreamingChunks(body: Data) async throws -> (stream: AsyncThrowingStream<Data, Error>, status: Int) {
        guard let endpoint = MirageSecrets.anthropicMessagesURL else { throw MirageError.notConfigured }
        let outBody = normalizeBody(body)
        let uuid = nextDeviceID()
        let headers = wireHeaders(deviceID: uuid, bodyActivatesThinking: thinkingActive(bodyData: outBody))

        #if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOHTTP2) && canImport(NIOSSL) && canImport(NIOHPACK)
        let wire = MirageWireRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: outBody
        )
        let response = try await MirageWireTransport.send(wire)
        if response.status == 429 {
            forceRotate()
            throw MirageError.quotaExhausted(retryAfter: Self.retryAfterSeconds(fromNIO: response.headers))
        }
        // Adapt ByteBuffer stream to Data stream.
        let (dataStream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            do {
                for try await buf in response.body {
                    cont.yield(Data(buf.readableBytesView))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        return (dataStream, response.status)
        #else
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = outBody
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MirageError.invalidResponse
        }
        if http.statusCode == 429 {
            forceRotate()
            throw MirageError.quotaExhausted(retryAfter: Self.retryAfterSeconds(fromURLResponse: http))
        }
        let (dataStream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            do {
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 4096 {
                        cont.yield(chunk)
                        chunk = Data()
                    }
                }
                if !chunk.isEmpty { cont.yield(chunk) }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        return (dataStream, http.statusCode)
        #endif
    }

    /// Legacy URLSession-shaped streaming API. Kept for the ResponsePipeline
    /// caller which is written against URLSession.AsyncBytes.lines. Prefer
    /// `sendStreamingChunks` in new code.
    #if !(canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOHTTP2) && canImport(NIOSSL) && canImport(NIOHPACK))
    func sendStreaming(body: Data) async throws -> (bytes: URLSession.AsyncBytes, response: HTTPURLResponse) {
        guard let endpoint = MirageSecrets.anthropicMessagesURL else { throw MirageError.notConfigured }
        let outBody = normalizeBody(body)
        let uuid = nextDeviceID()
        let headers = wireHeaders(deviceID: uuid, bodyActivatesThinking: thinkingActive(bodyData: outBody))
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = outBody
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MirageError.invalidResponse
        }
        if http.statusCode == 429 {
            forceRotate()
            throw MirageError.quotaExhausted(retryAfter: Self.retryAfterSeconds(fromURLResponse: http))
        }
        return (bytes, http)
    }
    #endif

    // Parse the upstream `Retry-After` header. The aegis-proxy sets it as
    // an integer seconds value (never a HTTP-date), matching the raw
    // Anthropic / Deepgram behavior; anything unparseable is nil so the
    // caller falls back to its own backoff.
    nonisolated static func retryAfterSeconds(fromURLResponse http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let secs = Int(raw.trimmingCharacters(in: CharacterSet.whitespaces)) else { return nil }
        return TimeInterval(secs)
    }

    #if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOHTTP2) && canImport(NIOSSL) && canImport(NIOHPACK)
    nonisolated static func retryAfterSeconds(fromNIO headers: HPACKHeaders) -> TimeInterval? {
        guard let raw = headers.first(name: "retry-after"),
              let secs = Int(raw.trimmingCharacters(in: CharacterSet.whitespaces)) else { return nil }
        return TimeInterval(secs)
    }
    #endif
}

/// Errors surfaced by MirageBackendClient. Kept small on purpose; higher
/// layers translate these into user-facing UI messages.
enum MirageError: Error, LocalizedError {
    case invalidResponse
    case quotaExhausted(retryAfter: TimeInterval?)
    case upstreamStatus(Int, body: Data)
    /// `MirageSecrets.upstreamBaseURL` is empty. The public git tree ships
    /// this state; personal builds fill the URL in and skip-worktree the
    /// secrets file. Surfaces to callers so they can print a helpful hint
    /// instead of silently falling back to a paid path.
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Peeky Free backend returned an unexpected response."
        case .quotaExhausted:
            return "Peeky Free trial quota exhausted for the current session. Rotating identity — please retry."
        case .upstreamStatus(let code, _):
            return "Peeky Free upstream returned HTTP \(code)."
        case .notConfigured:
            return "Peeky Free is not configured on this build. Fill MirageSecrets.upstreamBaseURL locally (see MirageSecrets.swift header)."
        }
    }
}

extension MirageBackendClient {
    /// True when the local build has a Peeky Free upstream configured. Used
    /// by the pipeline dispatch to refuse `.peekyFree` early and surface a
    /// clean error rather than throwing mid-request.
    static var isConfigured: Bool { MirageSecrets.isConfigured }
}
