//
//  HeyClickySessionTokenClient.swift
//  cursor-buddy
//
//  In-memory cached ephemeral token mints for realtime, Codex, and
//  dictation-receipt endpoints. See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §7.
//

import Foundation

final class HeyClickySessionTokenClient: @unchecked Sendable {
    static let shared = HeyClickySessionTokenClient()

    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.token")
    /// Bump from 10s → 60s so callers (WS handshake) get a token that
    /// still has real headroom, matching demo `RefreshLeadTimeSeconds=60`.
    private let refreshBuffer: TimeInterval = 60
    /// Demo `EphemeralRefreshIntervalSeconds=480` — pre-emptively mint
    /// every 480s so an in-flight WS never blocks waiting for a fresh
    /// token when its own ephemeral is about to expire.
    private var proactiveRefreshTimer: DispatchSourceTimer?
    private static let proactiveRefreshInterval: TimeInterval = 480
    /// Codex ephemeral lives ~4h. Refresh it every 3.5h so a long-
    /// running agent turn (or a several-hour idle session) never
    /// meets the 401 storm the reactive path incurs. The renewal is
    /// a SOFT rekey — codex process stays up, `account/login/start`
    /// with the new apiKey swaps its bearer, thread/lease/message
    /// history all preserved. User sees nothing.
    private var proactiveCodexRefreshTimer: DispatchSourceTimer?
    private static let proactiveCodexRefreshInterval: TimeInterval = 3.5 * 3600

    /// Server-baked realtime session config, refreshed on every
    /// `/agent/realtime/session` mint. Callers of `mintRealtimeToken`
    /// should read these after mint so the WS connects with the
    /// same model name the proxy signed the ephemeral against.
    private var cachedBakedRealtimeModel: String?
    private var cachedBakedRealtimeInstructions: String?

    var bakedRealtimeModel: String? {
        stateQueue.sync { cachedBakedRealtimeModel }
    }
    var bakedRealtimeInstructions: String? {
        stateQueue.sync { cachedBakedRealtimeInstructions }
    }

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private var cachedRealtime: CachedToken?
    private var cachedCodex: CachedToken?
    private var cachedDictationReceipt: CachedToken?

    /// Sync peek at the current cached codex ephemeral, if any and
    /// still fresh. Used by CodexProcessManager.start() (which is sync
    /// and cannot await mintCodexToken) so the spawned child gets the
    /// short-lived per-account codex bearer that HeyClicky uses
    /// natively — sending the raw Supabase JWT as OPENAI_API_KEY to
    /// /agent/openai/v1/responses gets 401 "Invalid or expired
    /// HeyClicky session token" from the proxy. See IDA
    /// HeyClicky-1.0.40 sub_1007772A8 (/agent/session-token mint) +
    /// `cachedBackendAgentSessionToken` + `agentSessionTokenInjected
    /// AtLastProcessSpawn`.
    func peekCachedCodexToken() -> String? {
        stateQueue.sync { validCached(cachedCodex)?.value }
    }

    init() {
        // Rehydrate the realtime ephemeral from disk on init. Codex /
        // dictation-receipt are cheap to re-mint on demand so we don't
        // bother persisting those — realtime is the expensive one
        // (baked model + instructions are 57KB from the server).
        (self.cachedRealtime,
         self.cachedBakedRealtimeModel,
         self.cachedBakedRealtimeInstructions) = Self.loadPersistedRealtime()
    }
    private var inflightRealtime: Task<(String, Int?), Error>?
    private var inflightCodex: Task<String, Error>?
    private var inflightDictationReceipt: Task<String, Error>?

    func mintRealtimeToken() async throws -> (value: String, expiresAt: Int?) {
        if let cached = validCached(cachedRealtime) {
            return (cached.value, Int(cached.expiresAt.timeIntervalSince1970))
        }
        let task: Task<(String, Int?), Error> = stateQueue.sync {
            if let inflight = inflightRealtime { return inflight }
            let created = Task<(String, Int?), Error> { [weak self] in
                defer { self?.stateQueue.sync { self?.inflightRealtime = nil } }
                guard let self else { throw HeyClickyProxyError.malformedResponse }
                let (value, expiresAt) = try await self.mintEphemeral(
                    path: AppBundleConfiguration.heyClickyRealtimeEphemeralPath()
                )
                let expiryDate = expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date().addingTimeInterval(50)
                self.stateQueue.sync {
                    self.cachedRealtime = CachedToken(value: value, expiresAt: expiryDate)
                }
                self.persistRealtime()
                return (value, expiresAt)
            }
            inflightRealtime = created
            return created
        }
        return try await task.value
    }

    func mintCodexToken(launchSource: HeyClickyLaunchSource) async throws -> String {
        if let cached = validCached(cachedCodex) {
            return cached.value
        }
        let task: Task<String, Error> = stateQueue.sync {
            if let inflight = inflightCodex { return inflight }
            let created = Task<String, Error> { [weak self] in
                defer { self?.stateQueue.sync { self?.inflightCodex = nil } }
                guard let self else { throw HeyClickyProxyError.malformedResponse }
                let (value, expiresAt) = try await self.mintEphemeral(
                    path: AppBundleConfiguration.heyClickyCodexEphemeralPath(),
                    extraBody: ["launch_source": launchSource.rawValue]
                )
                let expiryDate = expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date().addingTimeInterval(300)
                self.stateQueue.sync {
                    self.cachedCodex = CachedToken(value: value, expiresAt: expiryDate)
                }
                return value
            }
            inflightCodex = created
            return created
        }
        return try await task.value
    }

    func mintDictationReceipt() async throws -> String {
        if let cached = validCached(cachedDictationReceipt) {
            return cached.value
        }
        let task: Task<String, Error> = stateQueue.sync {
            if let inflight = inflightDictationReceipt { return inflight }
            let created = Task<String, Error> { [weak self] in
                defer { self?.stateQueue.sync { self?.inflightDictationReceipt = nil } }
                guard let self else { throw HeyClickyProxyError.malformedResponse }
                let (value, expiresAt) = try await self.mintEphemeral(
                    path: AppBundleConfiguration.heyClickyDictationReceiptPath()
                )
                let expiryDate = expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date().addingTimeInterval(60)
                self.stateQueue.sync {
                    self.cachedDictationReceipt = CachedToken(value: value, expiresAt: expiryDate)
                }
                return value
            }
            inflightDictationReceipt = created
            return created
        }
        return try await task.value
    }

    /// Kicks off the 480s pre-emptive refresh loop. Idempotent; safe
    /// to call multiple times (only first call installs the timer).
    /// The loop only refreshes the *realtime* ephemeral because that's
    /// the only one that lives long enough to matter — Codex/dictation
    /// are minted on demand.
    func startProactiveRefreshLoop() {
        stateQueue.sync {
            guard proactiveRefreshTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(
                deadline: .now() + Self.proactiveRefreshInterval,
                repeating: Self.proactiveRefreshInterval
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Task {
                    _ = try? await self.mintRealtimeToken()
                    // Preemptive Supabase JWT refresh — if the access
                    // token expires in less than 5 minutes, refresh it
                    // now instead of waiting for the reactive 401 storm
                    // that fires when the user next interacts. Without
                    // this, a 90-minute silence + one keystroke would
                    // hit 401 → refresh → rekey codex → retry — a
                    // 3-5 second stall the user perceives as "stuck".
                    if let exp = AppBundleConfiguration.heyClickySessionExpiresAt() {
                        let secondsLeft = exp.timeIntervalSinceNow
                        if secondsLeft > 0 && secondsLeft < 300 {
                            HeyClickyLog.log("session_token_ttl_below_threshold",
                                             lane: "system", direction: "internal", [
                                "seconds_left": Int(secondsLeft)
                            ])
                            _ = try? await HeyClickySessionAuthenticator.shared.refresh()
                            HeyClickyLog.log("preemptive_refresh_fired",
                                             lane: "system", direction: "internal", [:])
                        }
                    }
                }
            }
            timer.resume()
            proactiveRefreshTimer = timer
        }
        // Kick an immediate mint so the first PTT doesn't pay the
        // ~15-20s Cloudflare cold-start penalty. If we already have a
        // valid disk-persisted token from a previous launch,
        // mintRealtimeToken() will simply return it without a network
        // round-trip.
        Task { _ = try? await self.mintRealtimeToken() }
    }

    /// 3.5h loop that pre-emptively mints a fresh codex ephemeral +
    /// posts `.heyClickyCodexEphemeralRefreshed` so CodexAgentSession
    /// can soft-rekey the running codex process (via
    /// `account/login/start`). Prevents the 4h-expiry 401 storm on
    /// long-running turns / hours-idle sessions. Idempotent.
    /// Only meaningful in the heyclicky lane; safe no-op otherwise.
    func startProactiveCodexRefreshLoop() {
        stateQueue.sync {
            guard proactiveCodexRefreshTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(
                deadline: .now() + Self.proactiveCodexRefreshInterval,
                repeating: Self.proactiveCodexRefreshInterval
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                Task {
                    // Guard: only refresh when the user is actually
                    // signed into heyclicky (else this is BYOK codex
                    // and there's nothing to rekey).
                    guard AppBundleConfiguration.heyClickySignedIn() else {
                        return
                    }
                    // Force a re-mint: invalidate cache first so
                    // mintCodexToken hits the network instead of
                    // returning the near-expiry cached value.
                    self.stateQueue.sync { self.cachedCodex = nil }
                    do {
                        _ = try await self.mintCodexToken(launchSource: .codex)
                        HeyClickyLog.log("codex.proactive_ephemeral_refreshed",
                                         lane: "agent", direction: "internal", [:])
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .heyClickyCodexEphemeralRefreshed,
                                object: nil
                            )
                        }
                    } catch {
                        HeyClickyLog.log("codex.proactive_ephemeral_refresh_failed",
                                         lane: "agent", direction: "error",
                                         ["error": "\(error)"])
                    }
                }
            }
            timer.resume()
            proactiveCodexRefreshTimer = timer
            HeyClickyLog.log("codex.proactive_refresh_loop_started",
                             lane: "agent", direction: "internal",
                             ["interval_seconds": Int(Self.proactiveCodexRefreshInterval)])
        }
    }

    func stopProactiveCodexRefreshLoop() {
        stateQueue.sync {
            proactiveCodexRefreshTimer?.cancel()
            proactiveCodexRefreshTimer = nil
        }
    }

    /// Stop just the proactive refresh loop (leaves cached tokens
    /// intact — caller can still consume them until expiry). Used by
    /// `CompanionManager.stop()` to avoid a leaked repeating timer.
    func stopProactiveRefreshLoop() {
        stateQueue.sync {
            proactiveRefreshTimer?.cancel()
            proactiveRefreshTimer = nil
        }
    }

    // MARK: - Realtime persistence

    private static var realtimeCacheURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("OpenClicky", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("heyclicky-realtime-ephemeral.json")
    }

    private static func loadPersistedRealtime() -> (CachedToken?, String?, String?) {
        guard let data = try? Data(contentsOf: realtimeCacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? String, !value.isEmpty,
              let expiresAtEpoch = json["expiresAt"] as? TimeInterval else {
            return (nil, nil, nil)
        }
        let expiresAt = Date(timeIntervalSince1970: expiresAtEpoch)
        // Fast path: don't rehydrate if already expired (or within our
        // refresh buffer). Saves the caller a validCached() reject.
        guard expiresAt.timeIntervalSinceNow > 60 else {
            return (nil, nil, nil)
        }
        return (
            CachedToken(value: value, expiresAt: expiresAt),
            json["bakedModel"] as? String,
            json["bakedInstructions"] as? String
        )
    }

    private func persistRealtime() {
        guard let cached = cachedRealtime else {
            try? FileManager.default.removeItem(at: Self.realtimeCacheURL)
            return
        }
        var payload: [String: Any] = [
            "value": cached.value,
            "expiresAt": cached.expiresAt.timeIntervalSince1970
        ]
        if let m = cachedBakedRealtimeModel { payload["bakedModel"] = m }
        if let i = cachedBakedRealtimeInstructions { payload["bakedInstructions"] = i }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: Self.realtimeCacheURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.realtimeCacheURL.path
            )
        } catch {
            // Best-effort — a disk-full at cache-write can't be worse
            // than re-minting on next launch.
        }
    }

    func invalidateAll() {
        stateQueue.sync {
            inflightRealtime?.cancel()
            inflightCodex?.cancel()
            inflightDictationReceipt?.cancel()
            inflightRealtime = nil
            inflightCodex = nil
            inflightDictationReceipt = nil
            cachedRealtime = nil
            cachedCodex = nil
            cachedDictationReceipt = nil
            cachedBakedRealtimeModel = nil
            cachedBakedRealtimeInstructions = nil
            proactiveRefreshTimer?.cancel()
            proactiveRefreshTimer = nil
        }
        persistRealtime()
    }

    private func validCached(_ cached: CachedToken?) -> CachedToken? {
        guard let cached else { return nil }
        return cached.expiresAt.timeIntervalSinceNow > refreshBuffer ? cached : nil
    }

    private func mintEphemeral(path: String, extraBody: [String: String] = [:]) async throws -> (String, Int?) {
        let body = try JSONSerialization.data(withJSONObject: extraBody)
        // Explicit false: the dictation-receipt endpoint IS the mint target,
        // requesting one for the mint call would recurse.
        HeyClickyLog.log("token.mint_started", lane: "voice", direction: "outgoing", ["path": path])
        let (data, _) = try await HeyClickyProxyClient.shared.postJSON(path: path, body: body, includeDictationReceipt: false)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HeyClickyProxyError.malformedResponse
        }
        let clientSecret = json["client_secret"] as? [String: Any]
        // Priority matches demo `AgentSessionTokenClient.swift:92-95`:
        // currentSessionToken > token > value. Then fall through to
        // the /agent/realtime/session shape which uses top-level
        // `value`, and finally the legacy client_secret nesting.
        let token = (json["currentSessionToken"] as? String)
            ?? (json["token"] as? String)
            ?? (json["value"] as? String)
            ?? (clientSecret?["value"] as? String)
            ?? (json["ephemeral_token"] as? String)
        guard let token, !token.isEmpty else {
            HeyClickyLog.log("token.mint_malformed", direction: "error", ["path": path])
            throw HeyClickyProxyError.malformedResponse
        }
        // demo tolerates both snake_case (Supabase / OpenAI) and
        // camelCase (worker) + `expires_in` seconds. Match all three.
        let expiresAt: Int? = {
            if let v = json["expires_at"] as? Int { return v }
            if let v = json["expiresAt"] as? Int { return v }
            if let v = clientSecret?["expires_at"] as? Int { return v }
            if let v = json["expires_in"] as? Int {
                return Int(Date().timeIntervalSince1970) + v
            }
            return nil
        }()
        // Cache the server-baked session config (model + instructions)
        // from /agent/realtime/session so the realtime WS caller can
        // connect with the correct model name — demo does the same
        // (RealtimeSessionClient.fetchEphemeralFromProxy).
        if let session = json["session"] as? [String: Any] {
            let bakedModel = session["model"] as? String
            let bakedInstructions = session["instructions"] as? String
            stateQueue.sync {
                self.cachedBakedRealtimeModel = bakedModel
                self.cachedBakedRealtimeInstructions = bakedInstructions
            }
        }
        HeyClickyLog.log("token.mint_ok", lane: "voice", direction: "incoming", [
            "path": path,
            "expires_in": expiresAt.map { $0 - Int(Date().timeIntervalSince1970) } ?? -1,
            "baked_model": (json["session"] as? [String: Any])?["model"] as? String ?? "-"
        ])
        return (token, expiresAt)
    }
}
