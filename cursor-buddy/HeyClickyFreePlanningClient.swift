//
//  HeyClickyFreePlanningClient.swift
//  cursor-buddy
//
//  Free planning-channel access via HeyClicky's /chat-tool-call.
//  Zero agent-credit consumption — consumes the msgs quota lane
//  (25/day) instead of the agent quota lane. Used to generate
//  TASK.md / CHECKLIST / architecture docs BEFORE spawning the
//  paid Codex agent. Server routes /chat-tool-call to whichever
//  free reasoning model HeyClicky currently exposes (do NOT hard-
//  code a model name; the server picks it).
//
//  Reference: ccline/heyclicky-ask (Python standalone, same endpoint).
//

import Foundation

final class HeyClickyFreePlanningClient: @unchecked Sendable {
    static let shared = HeyClickyFreePlanningClient()

    /// Named multi-turn document sessions. The server side of
    /// /chat-tool-call is stateless per REST call — but the model
    /// still benefits from prior context, so we thread it through
    /// the request body as a prefix. Sessions live for the app
    /// lifetime; call clearSession(name:) to reset.
    private var sessions: [String: [(user: String, assistant: String)]] = [:]

    struct PlanRequest {
        let query: String
        let systemContext: String?
        /// Optional session name for multi-turn doc generation. When
        /// non-nil, prior turns under this name are prepended to the
        /// query as `Previous turn N — user: ...\n assistant: ...` so
        /// the model can continue where it left off.
        let sessionName: String?
        let timeoutSeconds: Int
        /// Optional path to a local image file to include as
        /// screenshot input. When present the client base64-encodes
        /// the file and sends it as `screenshotBase64`, unlocking the
        /// model's SCREEN_UNDERSTANDING + GUI_POINTING capabilities.
        var imagePath: String? = nil
        /// Optional client capabilities requested for this call. Common
        /// values: "clipboard_copy", "web_search", "places_lookup",
        /// "stock_quotes", "memory_save", "typing", "point",
        /// "walkthrough", "widgets". Server decides what it actually
        /// engages based on the query.
        var capabilities: [String] = ["clipboard_copy"]
    }

    struct PlanResult {
        let text: String
        let raw: [String: Any]
        /// The typed rich channels returned by the server. Callers
        /// that need only text should use `text`; callers building
        /// UI-automation or multimodal tools should inspect these.
        var clipboardText: String? {
            raw["clipboardText"] as? String
        }
        var point: [String: Any]? {
            raw["point"] as? [String: Any]
        }
        var typing: [String: Any]? {
            raw["typing"] as? [String: Any]
        }
        var widgets: [[String: Any]] {
            (raw["widgets"] as? [[String: Any]]) ?? []
        }
        var walkthroughBeats: [[String: Any]] {
            guard let w = raw["walkthrough"] as? [String: Any],
                  let beats = w["beats"] as? [[String: Any]] else { return [] }
            return beats
        }
    }

    /// Wipe the named session history so the next call starts fresh.
    func clearSession(name: String) {
        sessions[name] = nil
    }

    /// Ask the free planning channel to generate a plan / spec /
    /// TASK.md / architecture doc. Returns the model's textual
    /// response. Never touches agent-credit; consumes msgs-quota.
    func generatePlan(_ request: PlanRequest) async throws -> PlanResult {
        var query = request.query
        if let ctx = request.systemContext, !ctx.isEmpty {
            query = "\(ctx)\n\n---\n\n\(query)"
        }
        // Multi-turn continuation: prepend prior turns so the model
        // knows what it already wrote. Server is stateless per call,
        // but repacking history keeps the doc coherent across parts.
        if let sessionName = request.sessionName,
           let history = sessions[sessionName], !history.isEmpty {
            var buf = "Continuing a multi-part document. Prior turns:\n\n"
            for (i, (u, a)) in history.enumerated() {
                buf += "--- Turn \(i+1) request ---\n\(u)\n\n"
                buf += "--- Turn \(i+1) response ---\n\(a)\n\n"
            }
            buf += "--- Now respond to this next turn ---\n\(query)"
            query = buf
        }
        // Load optional image + downscale it for the request body.
        var imageBase64 = ""
        var imgWidth = 0
        var imgHeight = 0
        if let path = request.imagePath, !path.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           !data.isEmpty {
            imageBase64 = data.base64EncodedString()
            // We don't have easy access to real dimensions without
            // NSImage import here — fall back to sane defaults; server
            // primarily uses the base64 content, dims are advisory.
            imgWidth = 1280
            imgHeight = 800
        }
        var body: [String: Any] = [
            "query": query,
            "mimeType": "image/jpeg",
            "screenshotBase64": imageBase64,
            "client_capabilities": request.capabilities,
            "frontmost_app_bundle_id": Bundle.main.bundleIdentifier ?? "com.jkneen.openclicky",
            "environment": Self.environmentDict()
        ]
        if imgWidth > 0 && imgHeight > 0 {
            body["screenshotWidthInPixels"] = imgWidth
            body["screenshotHeightInPixels"] = imgHeight
        }
        let requestBody: Data
        do {
            requestBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw HeyClickyProxyError.malformedResponse
        }

        let path = AppBundleConfiguration.heyClickyChatToolCallPath()
        HeyClickyLog.log("free_planning.request", lane: "voice", direction: "outgoing", [
            "query_len": query.count,
            "cost_channel": "msgs"
        ])
        let (data, _) = try await HeyClickyProxyClient.shared.postJSON(
            path: path,
            body: requestBody,
            includeDictationReceipt: true
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            HeyClickyLog.log("free_planning.decode_failed", lane: "voice", direction: "error", [
                "body_bytes": data.count
            ])
            throw HeyClickyProxyError.malformedResponse
        }
        // Server sometimes decides a long / structured response should be
        // clipboard-only ("here's the spec, ready to paste"). For automated
        // callers that need the actual content, prefer clipboardText when
        // it's longer than the visible chat text. Log both lengths so
        // callers can see which channel carried the payload.
        let rawText = (json["text"] as? String) ?? ""
        let clip = (json["clipboardText"] as? String) ?? ""
        let text: String
        let source: String
        if clip.count > rawText.count * 3 && clip.count > 200 {
            text = clip
            source = "clipboard"
        } else {
            text = rawText
            source = "text"
        }
        HeyClickyLog.log("free_planning.response", lane: "voice", direction: "incoming", [
            "text_len": text.count,
            "raw_text_len": rawText.count,
            "clip_len": clip.count,
            "used_source": source,
            "session": request.sessionName ?? "-"
        ])
        // Append to session history for future continuation.
        if let sessionName = request.sessionName, !text.isEmpty {
            var history = sessions[sessionName] ?? []
            history.append((user: request.query, assistant: text))
            sessions[sessionName] = history
        }
        return PlanResult(text: text, raw: json)
    }

    private static func environmentDict() -> [String: Any] {
        let info = ProcessInfo.processInfo
        let osVer = info.operatingSystemVersion
        let osString = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        return [
            "os_version": osString,
            "timezone": TimeZone.current.identifier,
            "display_count": 1,
            "device_model": "Mac",
            "locale": Locale.current.identifier,
            "preferred_languages": Locale.preferredLanguages.prefix(3).map { $0 }
        ]
    }
}
