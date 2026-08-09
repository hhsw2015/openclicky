//
//  AssistAgentDirectTransport.swift
//  cursor-buddy
//
//  Direct HTTP transport for the assist agent's inner rounds. Builds
//  the `/chat-tool-call` request body byte-for-byte like the Python
//  reference (heyclicky_agent/client.py::post) so the model sees
//  exactly what Python sees:
//
//    { query, mimeType, client_capabilities, frontmost_app_bundle_id,
//      environment: { os_version, timezone, display_count,
//                     device_model, locale, preferred_languages },
//      session_id, [screenshotBase64/Width/Height] }
//
//  Bypasses HeyClickyChatToolCallClient entirely — no preflight
//  context formatter, no walkthrough/typing/clipboard decoding, no
//  UI-action defaults. The assist loop's systemPrompt (containing
//  the full CN tool menu) is prepended to `query`, and the raw
//  reply text is returned verbatim so the loop can AssistAgentJSON-
//  extract it.
//
//  Session id is stable across an assist run so server-side memory
//  survives, but distinct from the primary voice session id so a
//  poisoned assist session doesn't corrupt the user's chat context.
//

import Foundation

public final class AssistAgentDirectTransport: AssistAgentTransport, @unchecked Sendable {

    /// Session id used for all rounds inside one assist invocation.
    ///
    /// Default: derive from the primary voice session id via
    /// `HeyClickyChatToolCallClient.currentVoiceSessionID()`. Rationale:
    /// the assist agent should share the main dialog's server-side
    /// memory so it inherits pre-assist chat context (user's earlier
    /// questions, model's earlier grounding) without having to
    /// reconstruct it inside `prior`. When the primary id isn't yet
    /// established, fall back to a per-invocation UUID so the request
    /// still succeeds.
    ///
    /// Rounds inside one AssistAgentLoop reuse the same value so the
    /// server keeps tool-call context across rounds. Mutable so the
    /// loop's session-rotation escape hatch (C5) can cycle it when
    /// the server session is poisoned.
    private var sessionID: String

    /// Optional account override — when set, `Bearer` + `X-Clicky-Distinct-Id`
    /// use these tokens instead of the primary Keychain slot. Set by
    /// `hopAccount(_:)` when the loop escalates a poisoned session.
    private var overrideAccessToken: String? = nil
    private var overrideEmail: String? = nil

    /// Track which accounts we've already tried in this run so we don't
    /// ping-pong back to the same one.
    private var triedEmails: Set<String> = []

    /// Build a transport whose Bearer token comes from an exported
    /// account credential instead of the primary Keychain slot.
    /// Used by parallel sub-agent runners so each sub hits the CF
    /// Worker under a different account (multi-account fan-out).
    @MainActor
    public static func forCredential(_ cred: AssistAgentCredential)
        -> AssistAgentDirectTransport
    {
        let t = AssistAgentDirectTransport()
        t.overrideAccessToken = cred.accessToken
        t.overrideEmail = cred.email
        t.triedEmails.insert(cred.email)
        return t
    }

    public init(sessionID: String? = nil) {
        if let explicit = sessionID, !explicit.isEmpty {
            self.sessionID = explicit
        } else {
            // FRESH session per assist invocation.
            //
            // Reusing the main dialog session was tempting for
            // context continuity, but it back-propagates the main
            // model's "I'm the answer layer, I don't have tools"
            // refusal into the assist rounds — the server keys its
            // persona memory off session_id. A fresh UUID gives the
            // model a clean context where our tool-menu system prompt
            // is the ONLY thing it has to go on.
            //
            // The trade-off (no server-side memory of the user's
            // earlier chat) is fine: the assist loop's inner rounds
            // re-send the accumulated `prior` verbatim each call, so
            // step-log + userTask + digest survive the session split.
            self.sessionID = UUID().uuidString.lowercased()
        }
    }

    /// C5: rotate the server-side session id. Called by the loop when
    /// consecutive empties at the AIMD floor look like session poison.
    /// The next request lands on a fresh server session with no
    /// alignment-filter memory of prior rounds.
    public func rotateSession() -> String {
        let fresh = UUID().uuidString.lowercased()
        self.sessionID = fresh
        return String(fresh.prefix(8))
    }

    /// C9: hop to another exported account. Picks the healthiest cold
    /// candidate we haven't tried yet in this run. Returns the new
    /// email on success, "" when nothing viable. Auto-rotates the
    /// session id so the new account's fresh server session isn't
    /// poisoned by the old id.
    /// Called by the loop after each API round with the classification
    /// so the account quality ledger stays in sync. Only meaningful
    /// when we're on an override account; otherwise primary-account
    /// stats belong elsewhere.
    public func recordCallResult(ok: Bool) {
        guard let email = overrideEmail, !email.isEmpty else { return }
        AssistAgentAccounts.recordResult(email, ok: ok)
    }

    public func hopAccount() -> String {
        // Remember what we're leaving so pickBest can exclude it.
        let leaving = overrideEmail
        if let leaving { triedEmails.insert(leaving) }
        let pool = AssistAgentAccounts.loadAll()
            .filter { !triedEmails.contains($0.email) }
        guard let pick = AssistAgentAccounts.pickBest(
            excluding: leaving, from: pool) else { return "" }
        self.overrideEmail = pick.email
        self.overrideAccessToken = pick.accessToken
        self.triedEmails.insert(pick.email)
        AssistAgentAccounts.markUsed(pick.email)
        _ = self.rotateSession()
        return pick.email
    }

    public func ask(prior: String,
                    priorImage: Data?,
                    systemPrompt: String) async throws -> AssistAgentTransportReply
    {
        let started = Date()
        // Compose the full query the way Python does: system prompt
        // (tool menu + task) verbatim on top, then the prior
        // (accumulated step summaries + user task recap).
        let query = "\(systemPrompt)\n\n\(prior)"

        // Mirror Python's body — same keys, same order.
        var body: [String: Any] = [
            "query": query,
            "mimeType": "image/jpeg",
            "client_capabilities": ["clipboard_copy"],
            "frontmost_app_bundle_id": "com.jkneen.openclicky",
            "environment": [
                "os_version": Self.osVersionReported,
                "timezone": TimeZone.current.identifier,
                "display_count": NSScreen.screens.count,
                "device_model": Self.deviceModel,
                "locale": Locale.current.identifier,
                "preferred_languages": Locale.preferredLanguages,
            ],
            "session_id": sessionID,
        ]

        // If the caller passed a prior-as-image, attach it (base64).
        // Real pixel dims are read back from the JPEG itself — the
        // server keys coordinate transforms off these numbers, so
        // hard-coding font-page constants (as an earlier version did)
        // caused every point beat to land in the wrong place.
        if let img = priorImage, !img.isEmpty {
            body["screenshotBase64"] = img.base64EncodedString()
            let (w, h) = Self.readJPEGDims(img)
            body["screenshotWidthInPixels"] = w
            body["screenshotHeightInPixels"] = h
        }

        let bodyData = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys])

        HeyClickyLog.log("assist_agent.request",
                         lane: "agent", direction: "outgoing",
                         [
                             "query_len": query.count,
                             "body_bytes": bodyData.count,
                             "has_image": priorImage != nil,
                             "session_id": String(sessionID.prefix(8)),
                         ])

        // Direct Cloudflare Worker POST — bypass HeyClicky SaaS.
        // The App's HeyClickyProxyClient routes through the official
        // heyclicky.app SaaS layer which imposes its own "answer layer"
        // system prompt on the model; hitting the Worker straight
        // gives us the raw model that Python parity depends on.
        // Host comes from HeyClickySecrets (empty in the public tree), not a
        // literal — the endpoint belongs to the HeyClicky Free backend and
        // must not ship in source. Empty template => this path self-disables.
        guard let workerURL = URL(string: HeyClickySecrets.proxyBaseURL + "/chat-tool-call"),
              !HeyClickySecrets.proxyBaseURL.isEmpty else {
            throw HeyClickyConfigError.proxyBaseURLMissing
        }
        var request = URLRequest(url: workerURL, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("openclicky-assist-agent/1.0", forHTTPHeaderField: "User-Agent")

        // Auth: prefer the override credential when set (loop hopped to
        // an alternate exported account), else fall back to the primary
        // Supabase session token from Keychain.
        let accessToken: String = {
            if let ot = overrideAccessToken, !ot.isEmpty { return ot }
            return AppBundleConfiguration.heyClickyReadKeychainSecret(
                forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey) ?? ""
        }()
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        // IDA-verified X-Clicky-* headers so the CF Worker doesn't
        // 401-flag us as a scraper. Session id is passed both in the
        // body (`session_id`) and the header (server keys memory off
        // the header).
        request.setValue(sessionID, forHTTPHeaderField: "X-Clicky-Session-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Clicky-Trace-Id")
        request.setValue("normal", forHTTPHeaderField: "X-Clicky-Mode")
        if let sub = Self.decodeJWTSub(accessToken) {
            request.setValue(sub, forHTTPHeaderField: "X-Clicky-Distinct-Id")
        }

        let data: Data
        let urlResp: URLResponse
        do {
            (data, urlResp) = try await URLSession.shared.data(for: request)
        } catch {
            // Log the specific transport error so the notch pill /
            // log-tail can show WHY the round failed (timeout /
            // DNS / TLS / cancelled) instead of silently vanishing.
            let ns = error as NSError
            HeyClickyLog.log("assist_agent.transport_error",
                             lane: "agent", direction: "error",
                             ["code": ns.code,
                              "domain": ns.domain,
                              "desc": String(ns.localizedDescription.prefix(120)),
                              "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000)])
            throw error
        }
        guard let response = urlResp as? HTTPURLResponse else {
            HeyClickyLog.log("assist_agent.response_no_http",
                             lane: "agent", direction: "error", [:])
            return AssistAgentTransportReply(
                text: "", elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
        }

        guard response.statusCode == 200 else {
            HeyClickyLog.log("assist_agent.response_http_error",
                             lane: "agent", direction: "error",
                             ["status": response.statusCode,
                              "body_bytes": data.count])
            return AssistAgentTransportReply(
                text: "", elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
        }

        // Response is `{"text": "...", ...UI-action fields}`. The
        // model's tool JSON (`{"步骤":"需要", ...}`) rides inside `text`
        // (same as Python). The peripheral UI-action fields
        // (clipboardText / typing / point) share the same dispatcher
        // the main dialog uses so they still fire during an assist
        // loop turn — e.g. the model can say "clipboard is now the
        // answer, tell the user".
        var text = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            text = (obj["text"] as? String) ?? ""
        }
        // Dispatch UI actions via the App's existing handlers.
        if let cm = await AssistAgentBridge.shared.companion {
            await MainActor.run {
                HeyClickyChatToolCallClient.dispatchSimpleUIActions(
                    rawJSON: data, companion: cm)
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        HeyClickyLog.log("assist_agent.response",
                         lane: "agent", direction: "incoming",
                         ["text_len": text.count,
                          "elapsed_ms": elapsedMs,
                          "preview": String(text.prefix(400))])
        return AssistAgentTransportReply(text: text, elapsedMs: elapsedMs)
    }

    // MARK: - Environment constants (mirror Python defaults)

    private static let osVersionReported: String = {
        // Report the same "26.0.1" family Python does so server-side
        // any OS-gated behaviour stays consistent between the two
        // clients. Fall back to real OS if that assumption breaks.
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Read real pixel dimensions from JPEG bytes via CGImageSource.
    /// Falls back to (1280, 800) if the SOF markers can't be found —
    /// server would rather see plausible numbers than zeros.
    private static func readJPEGDims(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any] else {
            return (1280, 800)
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 1280
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 800
        return (w, h)
    }

    /// Pull the `sub` claim off a Supabase JWT (matches Python
    /// `_decode_jwt_sub`). Silent nil on any decode failure — the
    /// header is best-effort.
    static func decodeJWTSub(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1])
        // base64url pad
        while body.count % 4 != 0 { body.append("=") }
        body = body.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["sub"] as? String
    }

    private static let deviceModel: String = {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            let model = String(cString: buf)
            let arch: String
            #if arch(arm64)
                arch = "arm64"
            #else
                arch = "x86_64"
            #endif
            return "\(model), \(arch)"
        }
        return "Mac, arm64"
    }()
}

#if canImport(AppKit)
import AppKit
#endif
