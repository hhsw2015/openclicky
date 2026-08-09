//
//  AssistAgentAccounts.swift
//  cursor-buddy
//
//  Multi-account discovery for the assist agent's parallel-dispatch
//  path. Port of heyclicky_agent/accounts.py.
//
//  The main dialog stays on the primary signed-in account (see
//  HeyClickySessionAuthenticator). Additional accounts exported to
//  `~/Library/Application Support/OpenClicky/heyclicky-accounts/`
//  become an assist-agent-only pool — used by dispatch_parallel to
//  fan out sub-agents in true parallel without hammering one quota.
//
//  Also provides the quality/cooldown ledger so the parallel
//  dispatcher can pick the healthiest idle account per sub-task.
//

import Foundation

public struct AssistAgentAccount: Identifiable, Sendable {
    public let id: String        // email (unique)
    public let email: String
    public let accessToken: String
    public let refreshToken: String
    public let sourcePath: URL
    public let exportedAt: TimeInterval
}

public enum AssistAgentAccounts {

    // MARK: - Paths

    public static let accountsDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("OpenClicky/heyclicky-accounts", isDirectory: true)

    public static let cooldownDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("OpenClicky/heyclicky-cooldown", isDirectory: true)

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Discovery

    /// Return every account exported to disk.
    public static func loadAll() -> [AssistAgentAccount] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: nil) else { return [] }
        var out: [AssistAgentAccount] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let email = (obj["openClickyHeyClickySessionUserEmail"] as? String) ?? ""
            let access = (obj["openClickyHeyClickySessionAccessToken"] as? String) ?? ""
            let refresh = (obj["openClickyHeyClickySessionRefreshToken"] as? String) ?? ""
            if email.isEmpty || access.isEmpty { continue }
            var exportedAt: TimeInterval = 0
            if let stamp = obj["exportedAt"] as? String,
               let d = iso8601.date(from: stamp) {
                exportedAt = d.timeIntervalSince1970
            }
            out.append(AssistAgentAccount(
                id: email, email: email,
                accessToken: access, refreshToken: refresh,
                sourcePath: url, exportedAt: exportedAt))
        }
        return out
    }

    // MARK: - Cooldown / quality ledger

    private static func cooldownPath(for email: String) -> URL {
        let safe = email.map { c -> Character in
            (c.isLetter || c.isNumber || ".-_@".contains(c)) ? c : "_"
        }
        return cooldownDir.appendingPathComponent("\(String(safe)).json")
    }

    private static func loadLedger(_ email: String) -> [String: Any] {
        guard !email.isEmpty else { return [:] }
        let p = cooldownPath(for: email)
        guard FileManager.default.fileExists(atPath: p.path),
              let data = try? Data(contentsOf: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func saveLedger(_ email: String, _ data: [String: Any]) {
        guard !email.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: cooldownDir, withIntermediateDirectories: true)
        let p = cooldownPath(for: email)
        if let bytes = try? JSONSerialization.data(withJSONObject: data) {
            try? bytes.write(to: p, options: .atomic)
        }
    }

    public static func markUsed(_ email: String) {
        var d = loadLedger(email)
        d["email"] = email
        d["last_used_at"] = Date().timeIntervalSince1970
        saveLedger(email, d)
    }

    public static func lastUsed(_ email: String) -> TimeInterval {
        (loadLedger(email)["last_used_at"] as? Double) ?? 0
    }

    /// EMA-tracked success rate. α=0.2, same as Python. Default 0.5 for
    /// unknown accounts so we don't unfairly deprioritise new ones.
    public static func recordResult(_ email: String, ok: Bool) {
        var d = loadLedger(email)
        let prevRate = (d["ok_rate"] as? Double) ?? 0.5
        let count = (d["call_count"] as? Int) ?? 0
        d["ok_rate"] = prevRate * 0.8 + (ok ? 1.0 : 0.0) * 0.2
        d["call_count"] = count + 1
        d["last_result_at"] = Date().timeIntervalSince1970
        saveLedger(email, d)
    }

    public static func quality(_ email: String) -> (rate: Double, count: Int) {
        let d = loadLedger(email)
        return ((d["ok_rate"] as? Double) ?? 0.5,
                (d["call_count"] as? Int) ?? 0)
    }

    // MARK: - Selection policy (mirrors production hop policy)

    /// Rank the pool by (-quality, last_used, -exported_at) and return
    /// the head — the "healthiest, coldest" account, excluding
    /// `currentEmail` when alternatives exist. Same policy the fixed
    /// `probe_infinite` / `_try_account_hop` uses.
    /// Decode JWT `exp` claim; returns seconds remaining or nil when
    /// the token is malformed. Python parity: `config.token_expiry_seconds`.
    public static func tokenSecondsRemaining(_ jwt: String) -> Double? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        // Base64URL → Base64 padding.
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return exp - Date().timeIntervalSince1970
    }

    private static func hasFreshToken(_ acc: AssistAgentAccount,
                                       minSeconds: Double = 30) -> Bool {
        guard !acc.accessToken.isEmpty else { return true }  // unknown — hope
        guard let secs = tokenSecondsRemaining(acc.accessToken) else { return true }
        return secs > minSeconds
    }

    public static func pickBest(
        excluding currentEmail: String?,
        from pool: [AssistAgentAccount]
    ) -> AssistAgentAccount? {
        var candidates = pool.filter { $0.email != (currentEmail ?? "") }
        if candidates.isEmpty { candidates = pool }
        // ROOT_CAUSE Layer 5: skip candidates whose JWT expires in
        // <30s — hopping to them produces immediate HTTP 401 (real
        // evidence: run2 turns 126-128 playingapi 401 loop).
        let fresh = candidates.filter { hasFreshToken($0) }
        let usable = fresh.isEmpty ? candidates : fresh
        let ranked = usable.sorted { a, b in
            let qa = quality(a.email).rate
            let qb = quality(b.email).rate
            if qa != qb { return qa > qb }
            let la = lastUsed(a.email)
            let lb = lastUsed(b.email)
            if la != lb { return la < lb }
            return a.exportedAt > b.exportedAt
        }
        return ranked.first
    }
}
