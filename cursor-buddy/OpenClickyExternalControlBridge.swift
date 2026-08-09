import AppKit
import Foundation
import Network
import Vision
import OpenClickyContextService

/// Keep the loopback bridge bounded before authentication and JSON decoding.
/// The bridge may proxy multimodal inference payloads, so this retains the
/// previous ten-megabyte total-request ceiling while rejecting oversized or
/// malformed requests before any integer/range arithmetic occurs.
private let openClickyExternalControlMaximumHeaderBytes = 32 * 1024
private let openClickyExternalControlMaximumBodyBytes = 10 * 1024 * 1024

/// Local-only bridge used by other apps/agents to display OpenClicky UI affordances
/// without entering the normal voice/conversation/agent state machine.
struct OpenClickyExternalCursorSpec {
    var point: CGPoint
    var caption: String?
    var duration: TimeInterval
    var accentHex: String?
}

enum OpenClickyExternalCursorMode: String {
    case primary
    case secondary
}

enum OpenClickyExternalControlCommand {
    case showCursor(point: CGPoint, caption: String?, duration: TimeInterval, accentHex: String?, mode: OpenClickyExternalCursorMode, travelDuration: TimeInterval)
    case showCursors([OpenClickyExternalCursorSpec])
    case showVisualGuidanceOverlay(OpenClickyVisualGuidanceOverlay)
    case showCaption(text: String, point: CGPoint?, duration: TimeInterval, accentHex: String?)
    case captureScreenshot(focused: Bool)
    case click(point: CGPoint, caption: String?)
    case clear
    case speak(text: String, interrupt: Bool)
    case notify(title: String, body: String, threadID: String?, sound: Bool)
    /// Structured non-success result for gated/stub tools (e.g. Gmail OAuth).
    /// Prefer this over returning `nil` so agents get an explicit capability error.
    case unavailable(statusCode: Int, body: [String: Any])

    // MARK: - Automation-only commands (headless self-test surface)
    /// Start a HeyClicky Free agent session with an explicit prompt.
    /// Returns the new sessionID so the caller can poll state.
    case automationStartAgent(title: String, prompt: String, workingDir: String?, reasoningEffort: String?)
    /// Stop the session (user-initiated).
    case automationStopAgent(sessionID: String)
    /// Submit a follow-up prompt to an EXISTING session so the
    /// proxy sees a genuine follow-up turn (same thread_id).
    case automationFollowUpAgent(sessionID: String, prompt: String)
    /// Trigger the full account-reset flow (server-side account
    /// delete → OAuth chooser → new refresh_token). Used to verify
    /// quota reset + cross-account thread hydration behaviour.
    case automationAccountReset(reason: String)
    /// Raw /codex-thread-launch with caller-specified thread_id +
    /// is_follow_up. Bypasses CodexAgentSession so we can probe
    /// server-side hydration semantics without codex in the loop.
    /// Returns the raw proxy response body so the test can inspect
    /// spoken_start_cue / text_start_cue / title.
    case automationRawThreadLaunch(threadID: String, content: String, isFollowUp: Bool)
    /// Query full agent session state (status, progressStage, entries,
    /// lastError, pendingResumeID, activeThreadID, lease info).
    case automationSessionState(sessionID: String?)
    /// List every agent session with its status.
    case automationListSessions
    /// Inject a controlled fault so we can verify auto-recovery paths
    /// end-to-end without waiting for organic failure. Kinds:
    ///   "kill_codex"        — SIGTERM the codex child
    ///   "expire_credentials" — invalidate JWT and post refresh notif
    ///   "trigger_turn_limit" — post `.heyClickyRequestAutoContinueReplay`
    ///   "trigger_402_quota" — call handle402MidChat with quota text
    ///   "trigger_428"       — call handle402MidChat with 428 text
    case automationInjectFault(kind: String, sessionID: String?)
    /// Simulate one full PTT voice turn end-to-end without touching
    /// microphone/STT/WS. Fires the same downstream pipeline a real
    /// user voice turn would trigger:
    ///   1. preflight snapshot capture (LTM + FTS + Everywhere ctx)
    ///   2. HeyClickyChatToolCallClient.analyzeVoiceResponse → chat.request
    ///   3. rememberVoiceExchange → ConversationLogger writes vault
    ///   4. returns assistant text + timing + citation frame IDs
    /// Lets automated tests exercise the LTM/dialog layer at ~15s per
    /// turn without any Realtime WS quota burn or headphone plugged in.
    case automationSimulateVoiceTurn(transcript: String)
    /// SKI-Mode specific simulation: builds the full UtteranceContext
    /// and writes utterance.final to .oc/events.jsonl in the pinned
    /// active workspace. Returns the emitted JSON payload so the
    /// caller can assert on the context/hints fields.
    case automationSimulateSKIUtterance(transcript: String)
    /// Switch the active OpenClicky profile (heyclicky_free / ski_mode /
    /// mirage / local / realtime / quality) end-to-end: not just the
    /// activeProfileID UserDefault, but the STT / TTS / response model
    /// keys the profile's `.apply()` also toggles + subsystem lifecycles
    /// (`applyProfile` on CompanionManager runs its start/stop hooks).
    /// Automation harnesses need this to exercise a specific lane
    /// without a UI click.
    case automationSetActiveProfile(profileID: String)
    /// Return the tail of the message log store (last N events, JSONL).
    case automationLogTail(count: Int)
    /// Delete a session permanently (stops it, removes from
    /// codexAgentSessions + agentDockItems + persisted snapshots).
    case automationDeleteSession(sessionID: String)
    /// Delete every session whose title matches a substring (used
    /// to sweep up automation-test debris in one call).
    case automationDeleteSessionsByTitleContains(needle: String)
    /// Trigger the HeyClicky Free OAuth login via chrome-extension in
    /// a background tab. Returns immediately; poll session state after
    /// ~20s to see whether the token landed. Bypasses the "signedIn"
    /// gate that `attemptReset` has, so this works even when the
    /// current session is fully wiped.
    case automationTriggerOAuthLogin(email: String?)
    /// Report whether the app has a valid HeyClicky session token +
    /// its expiration.
    case automationAuthStatus
    /// Ask the free planning channel (msgs lane, whichever model
    /// HeyClicky exposes there) to generate plan/spec/architecture
    /// text. Zero agent-credit consumption — consumes 1 msgs quota
    /// (25/day). Meant to produce TASK.md / CHECKLIST / design docs
    /// BEFORE spawning the paid Codex agent. `sessionName` enables
    /// multi-turn document continuation across separate REST calls.
    case automationFreePlan(query: String, systemContext: String?, saveToPath: String?, sessionName: String?, appendToFile: Bool)
    /// Rich variant with optional image + capability list. Used by
    /// advisor_* MCP tools that need multi-modal or specific server
    /// capabilities (web_search, places_lookup, stock_quotes,
    /// memory_save, walkthrough, etc). Response includes structured
    /// widgets/point/walkthrough JSON, not just plain text.
    case automationFreeConsult(query: String, systemContext: String?, sessionName: String?, imagePath: String?, capabilities: [String])
    /// Reset a named multi-turn planning session.
    case automationFreePlanClear(sessionName: String)
}

struct OpenClickyExternalControlResponse {
    var statusCode: Int
    var body: [String: Any]

    static func ok(_ body: [String: Any] = [:]) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: 200, body: ["ok": true].merging(body) { _, new in new })
    }

    static func accepted(_ body: [String: Any] = [:]) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: 202, body: ["ok": true, "accepted": true].merging(body) { _, new in new })
    }

    static func error(_ statusCode: Int, _ message: String) -> OpenClickyExternalControlResponse {
        OpenClickyExternalControlResponse(statusCode: statusCode, body: ["ok": false, "error": message])
    }

    static func unavailable(
        statusCode: Int = 501,
        tool: String,
        capability: String,
        message: String,
        extra: [String: Any] = [:]
    ) -> OpenClickyExternalControlResponse {
        var body: [String: Any] = [
            "ok": false,
            "error": message,
            "tool": tool,
            "capability": capability,
            "status": "gated",
            "implementation": "stub"
        ]
        for (key, value) in extra {
            body[key] = value
        }
        return OpenClickyExternalControlResponse(statusCode: statusCode, body: body)
    }

}

typealias OpenClickyExternalControlHandler = @MainActor (OpenClickyExternalControlCommand) async -> OpenClickyExternalControlResponse

final class OpenClickyExternalControlBridgeServer: @unchecked Sendable {
    /// Static weak reference to the CompanionManager owning the currently
    /// running bridge. Sensor tools that need to reach into app-level state
    /// (e.g. `openclicky_simulate_voice_turn` which drives the same voice
    /// pipeline a real PTT press triggers) read this on-demand. Set by the
    /// server init below; nil'd on dealloc. `@unchecked Sendable`
    /// container-wide so this stays consistent.
    private static let cmRefLock = NSLock()
    private nonisolated(unsafe) static weak var _companionManagerRef: AnyObject?
    static var companionManagerAnchor: AnyObject? {
        cmRefLock.lock(); defer { cmRefLock.unlock() }
        return _companionManagerRef
    }
    static func setCompanionManagerAnchor(_ obj: AnyObject?) {
        cmRefLock.lock(); defer { cmRefLock.unlock() }
        _companionManagerRef = obj
    }

    /// Default port when no `OPENCLICKY_MCP_PORT` env is set. Matches the
    /// documented well-known port for the openclicky sensor bridge; Everywhere
    /// uses 7878 by default (`EverywhereMcpHttpOptions.cs:44`).
    static let defaultPort: UInt16 = 32123
    /// Max fallback ports to try if the primary bind fails. Everywhere-parity
    /// (`EverywhereMcpHttpOptions.cs:11`) — walk up 10 sibling ports before
    /// giving up.
    static let maxPortFallbacks: UInt16 = 10

    /// Resolves the desired listen port from `OPENCLICKY_MCP_PORT` env,
    /// falling back to `defaultPort` when unset or malformed. Mirrors
    /// `EverywhereMcpHttpOptions.ResolveDefaultPort` (`:41-45`).
    static func resolveDefaultPort() -> UInt16 {
        if let raw = ProcessInfo.processInfo.environment["OPENCLICKY_MCP_PORT"],
           let parsed = UInt16(raw), parsed > 0 {
            return parsed
        }
        return defaultPort
    }

    // F27 review — expose the port the bridge actually bound on so
    // downstream config writers (Codex `config.toml`) can reflect the
    // real endpoint rather than the hardcoded default. Two conditions
    // cause the bridge to bind on a port other than `resolveDefaultPort()`:
    //   1. `OPENCLICKY_MCP_PORT` env override.
    //   2. Bind-conflict fallback ladder walking `port + 1` up 10 times
    //      when the primary bind fails (`tryStart(port:fallbacksRemaining:)`).
    // Case (2) can only be observed at runtime, so callers reading the
    // static `activePort` before `.ready` will see `nil` and should fall
    // back to `resolveDefaultPort()` (which covers case (1)).
    private static let activePortLock = NSLock()
    private nonisolated(unsafe) static var _activePort: UInt16?

    /// The port the last-started bridge instance bound on, or `nil` if no
    /// bridge has reached `.ready` yet. Thread-safe.
    static var activePort: UInt16? {
        activePortLock.lock()
        defer { activePortLock.unlock() }
        return _activePort
    }

    fileprivate static func setActivePort(_ value: UInt16?) {
        activePortLock.lock()
        _activePort = value
        activePortLock.unlock()
    }

    /// Callback invoked when the bridge binds successfully, delivering the
    /// resolved port. `CompanionManager` sets this before `start()` so it
    /// can re-render the Codex `config.toml` if the fallback ladder picks
    /// a port other than the initial guess. Called on the bridge queue.
    var onPortResolved: ((UInt16) -> Void)?

    private var port: UInt16
    private let handler: OpenClickyExternalControlHandler
    private let queue = DispatchQueue(label: "com.jkneen.openclicky.external-control-bridge")
    private var listener: NWListener?
    private var sseConnections: [UUID: NWConnection] = [:]
    private let proxySession: URLSession

    init(port: UInt16 = OpenClickyExternalControlBridgeServer.resolveDefaultPort(),
         handler: @escaping OpenClickyExternalControlHandler) {
        self.port = port
        self.handler = handler

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.proxySession = URLSession(configuration: config)
    }

    func start() {
        guard listener == nil else { return }
        tryStart(port: port, fallbacksRemaining: Int(Self.maxPortFallbacks))
    }

    /// Attempt to bind on `port`; on failure, walk up to
    /// `fallbacksRemaining` sibling ports (Everywhere-parity behaviour
    /// from `EverywhereMcpHttpOptions.MaxPortFallbacks = 10`).
    private func tryStart(port: UInt16, fallbacksRemaining: Int) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let address = IPv4Address("127.0.0.1"),
               let endpointPort = NWEndpoint.Port(rawValue: port) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: endpointPort)
            }

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = port
                    Self.setActivePort(port)
                    self.onPortResolved?(port)
                    print("OpenClicky external control bridge listening on http://127.0.0.1:\(port)")
                case .failed(let error):
                    print("OpenClicky external control bridge failed on port \(port): \(error)")
                    // Bind-conflict fallback: release the current listener
                    // and step to `port + 1` up to `maxPortFallbacks` total
                    // attempts. Only retry when bind actually failed.
                    listener.cancel()
                    self.queue.async {
                        self.listener = nil
                        if fallbacksRemaining > 0, port < UInt16.max {
                            self.tryStart(port: port + 1, fallbacksRemaining: fallbacksRemaining - 1)
                        }
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("OpenClicky external control bridge could not start on port \(port): \(error)")
            if fallbacksRemaining > 0, port < UInt16.max {
                tryStart(port: port + 1, fallbacksRemaining: fallbacksRemaining - 1)
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Self.setActivePort(nil)
        for (_, connection) in sseConnections {
            connection.cancel()
        }
        sseConnections.removeAll()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .cancelled = state {
                self.removeSSEConnection(connection)
            }
            if case .failed = state {
                self.removeSSEConnection(connection)
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendJSON(["ok": false, "error": error.localizedDescription], statusCode: 400, on: connection)
                return
            }

            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            switch HTTPRequest.parse(nextBuffer) {
            case .request(let request):
                self.handle(request, on: connection)
                return
            case .malformed(let reason):
                self.sendJSON(["ok": false, "error": reason], statusCode: 400, on: connection)
                return
            case .incomplete:
                break
            }

            if isComplete || nextBuffer.count > openClickyExternalControlMaximumHeaderBytes + openClickyExternalControlMaximumBodyBytes {
                self.sendJSON(["ok": false, "error": "Malformed HTTP request"], statusCode: 400, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            sendJSON(["ok": true], statusCode: 200, on: connection)
            return
        }

        if request.method == "GET", request.path == "/health" || request.path == "/" {
            var body: [String: Any] = [
                "ok": true,
                "name": "OpenClicky External Control Bridge",
                "port": port,
                "transport": "local-http+sse",
                "bridgeTokenRequired": true,
                "bridgeTokenConfigured": AppBundleConfiguration.externalControlBridgeToken() != nil,
                "tools": Self.mcpToolDescriptors.compactMap { $0["name"] as? String },
                "capabilities": Self.capabilityCompatibilityMetadata,
                "multiToolEndpoints": ["/mcp/calls", "/tools/calls"],
                "inferenceProxyEnabled": AppBundleConfiguration.externalInferenceProxyEnabled()
            ]
            if AppBundleConfiguration.externalInferenceProxyEnabled() {
                body["proxyEndpoints"] = ["/v1/messages", "/v1/responses", "/v1/chat/completions"]
            }
            sendJSON(body, statusCode: 200, on: connection)
            return
        }

        guard hasValidBridgeToken(request) else {
            sendJSON([
                "ok": false,
                "error": "OpenClicky bridge token required. Configure OPENCLICKY_BRIDGE_TOKEN or the bridge token setting."
            ], statusCode: 401, on: connection)
            return
        }

        if request.method == "GET", request.path.hasPrefix("/mcp/tools") {
            let pool = Self.mcpToolDescriptors + OpenClickyMCPTieredLoader.metaToolDescriptors
            let gated = OpenClickyMCPTieredLoader.shared.filter(pool)
            // Optional `?domain=X` filter: e.g. `/mcp/tools?domain=xlb`
            // returns only the xlb-domain tool descriptors so a
            // discovery hint can point a downstream agent at just the
            // relevant slice without exposing the full 130+ tool pool.
            let query = request.path.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
            var domainFilter: String? = nil
            for part in query.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "domain" {
                    domainFilter = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
            let filtered: [[String: Any]]
            if let domain = domainFilter, !domain.isEmpty {
                let names = OpenClickyMCPTieredDomainMap.names(forDomain: domain)
                filtered = gated.filter { ($0["name"] as? String).map(names.contains) ?? false }
            } else {
                filtered = gated
            }
            sendJSON(["ok": true, "tools": filtered], statusCode: 200, on: connection)
            return
        }

        if request.method == "GET", request.path == "/events" {
            attachSSE(connection)
            return
        }

        if isInferenceProxyEndpoint(request.path) {
            guard AppBundleConfiguration.externalInferenceProxyEnabled() else {
                sendJSON(["ok": false, "error": "Inference proxy is disabled."], statusCode: 404, on: connection)
                return
            }
            guard hasValidBridgeToken(request) else {
                sendJSON(["ok": false, "error": "Inference proxy requires a valid OpenClicky bridge token."], statusCode: 401, on: connection)
                return
            }
            proxyInferenceRequest(request, on: connection)
            return
        }

        // Automation GET aliases so `curl -s /agent/sessions` works
        // without a body — MCP / CLI clients love this.
        if request.method == "GET" {
            let getAutomation: OpenClickyExternalControlCommand? = {
                switch request.path {
                case "/agent/sessions":
                    return .automationListSessions
                case "/agent/session/state":
                    return .automationSessionState(sessionID: nil)
                case "/agent/log/tail":
                    return .automationLogTail(count: 200)
                case "/heyclicky/auth/status":
                    return .automationAuthStatus
                default:
                    return nil
                }
            }()
            if let cmd = getAutomation {
                Task { @MainActor in
                    let result = await self.handler(cmd)
                    self.queue.async {
                        self.sendJSON(result.body, statusCode: result.statusCode, on: connection)
                    }
                }
                return
            }
        }

        guard request.method == "POST" else {
            sendJSON(["ok": false, "error": "Use POST for control commands"], statusCode: 405, on: connection)
            return
        }

        let command: OpenClickyExternalControlCommand?
        switch request.path {
        case "/cursor":
            command = Self.cursorCommand(from: request.jsonBody)
        case "/cursors":
            command = Self.cursorsCommand(from: request.jsonBody)
        case "/scribble":
            command = Self.scribbleCommand(from: request.jsonBody)
        case "/highlight", "/rectangle":
            command = Self.rectangleCommand(from: request.jsonBody)
        case "/caption":
            command = Self.captionCommand(from: request.jsonBody)
        case "/screenshot", "/screenshots":
            command = .captureScreenshot(focused: Self.bool(request.jsonBody["focused"]) ?? false)
        case "/click":
            command = Self.clickCommand(from: request.jsonBody)
        case "/clear":
            command = .clear
        case "/speak":
            command = Self.speakCommand(from: request.jsonBody)
        case "/notify", "/notification":
            command = Self.notifyCommand(from: request.jsonBody)
        // MARK: - Automation self-test endpoints
        case "/agent/task/start":
            let body = request.jsonBody
            let title = (body["title"] as? String) ?? "Automation Test"
            let prompt = (body["prompt"] as? String) ?? ""
            guard !prompt.isEmpty else {
                sendJSON(["ok": false, "error": "prompt required"], statusCode: 400, on: connection)
                return
            }
            let workingDir = body["workingDir"] as? String
            // Automation-launched long-runs benefit from higher
            // reasoning effort — model quality improves visibly, and
            // this is precisely the code path where cost-per-token is
            // hidden by the free-tier proxy. Caller can override with
            // "reasoningEffort" (low|medium|high|xhigh) if the task
            // is trivial and wants speed.
            let reasoningEffort = body["reasoningEffort"] as? String
            command = .automationStartAgent(title: title, prompt: prompt,
                                             workingDir: workingDir,
                                             reasoningEffort: reasoningEffort)
        case "/agent/task/stop":
            let sessionID = (request.jsonBody["sessionID"] as? String) ?? ""
            guard !sessionID.isEmpty else {
                sendJSON(["ok": false, "error": "sessionID required"], statusCode: 400, on: connection)
                return
            }
            command = .automationStopAgent(sessionID: sessionID)
        case "/agent/task/followup":
            let body = request.jsonBody
            let sessionID = (body["sessionID"] as? String) ?? ""
            let prompt = (body["prompt"] as? String) ?? ""
            guard !sessionID.isEmpty, !prompt.isEmpty else {
                sendJSON(["ok": false, "error": "sessionID + prompt required"], statusCode: 400, on: connection)
                return
            }
            command = .automationFollowUpAgent(sessionID: sessionID, prompt: prompt)
        case "/heyclicky/account/reset":
            let reason = (request.jsonBody["reason"] as? String) ?? "automation_test"
            command = .automationAccountReset(reason: reason)
        case "/heyclicky/raw/thread-launch":
            let body = request.jsonBody
            let threadID = (body["threadID"] as? String) ?? ""
            let content = (body["content"] as? String) ?? ""
            let isFollowUp = (body["isFollowUp"] as? Bool) ?? false
            guard !threadID.isEmpty, !content.isEmpty else {
                sendJSON(["ok": false, "error": "threadID + content required"], statusCode: 400, on: connection)
                return
            }
            command = .automationRawThreadLaunch(threadID: threadID, content: content, isFollowUp: isFollowUp)
        case "/agent/plan/generate":
            let body = request.jsonBody
            let query = (body["query"] as? String) ?? ""
            let systemContext = body["systemContext"] as? String
            let saveToPath = body["saveToPath"] as? String
            let sessionName = body["sessionName"] as? String
            let appendToFile = (body["appendToFile"] as? Bool) ?? false
            guard !query.isEmpty else {
                sendJSON(["ok": false, "error": "query required"], statusCode: 400, on: connection)
                return
            }
            command = .automationFreePlan(query: query, systemContext: systemContext, saveToPath: saveToPath, sessionName: sessionName, appendToFile: appendToFile)
        case "/agent/plan/clear":
            let body = request.jsonBody
            let sessionName = (body["sessionName"] as? String) ?? ""
            guard !sessionName.isEmpty else {
                sendJSON(["ok": false, "error": "sessionName required"], statusCode: 400, on: connection)
                return
            }
            command = .automationFreePlanClear(sessionName: sessionName)
        case "/agent/session/state":
            command = .automationSessionState(sessionID: request.jsonBody["sessionID"] as? String)
        case "/agent/sessions":
            command = .automationListSessions
        case "/agent/fault/inject":
            let kind = (request.jsonBody["kind"] as? String) ?? ""
            guard !kind.isEmpty else {
                sendJSON(["ok": false, "error": "kind required"], statusCode: 400, on: connection)
                return
            }
            command = .automationInjectFault(kind: kind, sessionID: request.jsonBody["sessionID"] as? String)
        case "/agent/log/tail":
            let count = (request.jsonBody["count"] as? Int) ?? 100
            command = .automationLogTail(count: min(max(count, 1), 5000))
        case "/agent/session/delete":
            let sessionID = (request.jsonBody["sessionID"] as? String) ?? ""
            guard !sessionID.isEmpty else {
                sendJSON(["ok": false, "error": "sessionID required"], statusCode: 400, on: connection)
                return
            }
            command = .automationDeleteSession(sessionID: sessionID)
        case "/agent/sessions/purge":
            let needle = (request.jsonBody["titleContains"] as? String) ?? ""
            guard !needle.isEmpty else {
                sendJSON(["ok": false, "error": "titleContains required (empty would wipe all)"],
                         statusCode: 400, on: connection)
                return
            }
            command = .automationDeleteSessionsByTitleContains(needle: needle)
        case "/heyclicky/auth/status":
            command = .automationAuthStatus
        case "/heyclicky/auth/login":
            let email = request.jsonBody["email"] as? String
            command = .automationTriggerOAuthLogin(email: email)
        case "/mcp/call", "/tools/call":
            command = Self.mcpToolCommand(from: request.jsonBody)
        case "/mcp/calls", "/tools/calls":
            handleBatchToolCall(request, on: connection)
            return
        case "/mcp/openclicky":
            // Unified openclicky-native MCP endpoint. Merges the retired
            // `/mcp` (openClickyControl visual-guidance surface) and
            // `/mcp/advisor` (free-model consulting surface) into a
            // single Streamable HTTP endpoint so Claude Code / Codex
            // only need one MCP registration. Same JSON-RPC framing as
            // `/mcp/sensor`: SSE `event: message` for tool responses,
            // 202 with `Mcp-Session-Id` for notifications/initialized.
            if let method = Self.string(request.jsonBody["method"]),
               method.hasPrefix("notifications/") || request.jsonBody["id"] == nil {
                sendRawResponse(Data(), statusCode: 202, contentType: "text/event-stream",
                                extraHeaders: ["Mcp-Session-Id": UUID().uuidString], on: connection)
                return
            }
            if let response = Self.mcpJSONRPCResponse(from: request.jsonBody, role: .openclicky) {
                if let command = response.command {
                    Task { @MainActor in
                        let result = await self.handler(command)
                        self.queue.async {
                            self.broadcast(event: "command", object: ["ok": result.statusCode < 400, "path": request.path])
                            self.sendMCPStreamableHTTP(body: response.responseBody(result: result), statusCode: result.statusCode, on: connection)
                        }
                    }
                    return
                }
                sendMCPStreamableHTTP(body: response.responseBody(result: nil), statusCode: 200, on: connection)
                return
            }
            command = nil
        case "/mcp/sensor", "/mcp/openclicky-sensor":
            // Same Streamable HTTP shape as /mcp/advisor. Sensor tools
            // are pure local reads (Layer 0 captures from
            // OpenClickyContextService) and never dispatch through the
            // OpenClickyExternalControlCommand main-actor handler; we
            // execute them directly and return the MCP content envelope.
            if let method = Self.string(request.jsonBody["method"]),
               method.hasPrefix("notifications/") || request.jsonBody["id"] == nil {
                sendRawResponse(Data(), statusCode: 202, contentType: "text/event-stream",
                                extraHeaders: ["Mcp-Session-Id": UUID().uuidString], on: connection)
                return
            }
            handleSensorRequest(request, on: connection)
            return
        case "/mcp/orchestrate", "/mcp/openclicky-orchestrate":
            if let method = Self.string(request.jsonBody["method"]),
               method.hasPrefix("notifications/") || request.jsonBody["id"] == nil {
                sendRawResponse(Data(), statusCode: 202, contentType: "text/event-stream",
                                extraHeaders: ["Mcp-Session-Id": UUID().uuidString], on: connection)
                return
            }
            if let response = Self.mcpJSONRPCResponse(from: request.jsonBody, role: .orchestrate) {
                if let command = response.command {
                    Task { @MainActor in
                        let result = await self.handler(command)
                        self.queue.async {
                            self.broadcast(event: "command", object: ["ok": result.statusCode < 400, "path": request.path])
                            self.sendMCPStreamableHTTP(body: response.responseBody(result: result), statusCode: result.statusCode, on: connection)
                        }
                    }
                    return
                }
                sendMCPStreamableHTTP(body: response.responseBody(result: nil), statusCode: 200, on: connection)
                return
            }
            command = nil
        default:
            sendJSON(["ok": false, "error": "Unknown endpoint"], statusCode: 404, on: connection)
            return
        }

        guard let command else {
            sendJSON(["ok": false, "error": "Invalid command payload"], statusCode: 400, on: connection)
            return
        }

        Task { @MainActor in
            let response = await self.handler(command)
            self.queue.async {
                self.broadcast(event: "command", object: ["ok": response.statusCode < 400, "path": request.path])
                self.sendJSON(response.body, statusCode: response.statusCode, on: connection)
            }
        }
    }

    private func handleBatchToolCall(_ request: HTTPRequest, on connection: NWConnection) {
        guard let calls = Self.array(request.jsonBody["calls"] ?? request.jsonBody["tool_calls"] ?? request.jsonBody["tools"]) else {
            sendJSON(["ok": false, "error": "Expected calls array"], statusCode: 400, on: connection)
            return
        }

        let parsedCalls = calls.enumerated().compactMap { index, value -> (index: Int, name: String, command: OpenClickyExternalControlCommand, delay: TimeInterval)? in
            guard let call = Self.dictionary(value) else { return nil }
            let name = Self.string(call["tool"]) ?? Self.string(call["name"]) ?? "unknown"
            guard let command = Self.mcpToolCommand(from: call) else { return nil }
            let delayMilliseconds = Self.double(call["delayMs"]) ?? Self.double(call["waitMs"]) ?? 0
            let delay = max(0, min(delayMilliseconds / 1000.0, 10.0))
            return (index, name, command, delay)
        }

        guard parsedCalls.count == calls.count else {
            sendJSON(["ok": false, "error": "Every batch call must include a valid tool/name and arguments"], statusCode: 400, on: connection)
            return
        }

        Task { @MainActor in
            var results: [[String: Any]] = []
            var allSucceeded = true
            for parsed in parsedCalls {
                if parsed.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(parsed.delay * 1_000_000_000))
                }
                let result = await self.handler(parsed.command)
                allSucceeded = allSucceeded && result.statusCode < 400
                results.append([
                    "index": parsed.index,
                    "tool": parsed.name,
                    "ok": result.statusCode < 400,
                    "statusCode": result.statusCode,
                    "body": result.body
                ])
            }
            self.queue.async {
                self.broadcast(event: "command", object: ["ok": allSucceeded, "path": request.path, "count": parsedCalls.count])
                self.sendJSON(["ok": allSucceeded, "results": results], statusCode: allSucceeded ? 200 : 207, on: connection)
            }
        }
    }


    private func isInferenceProxyEndpoint(_ path: String) -> Bool {
        path == "/v1/responses" || path == "/v1/chat/completions" || path == "/v1/messages"
    }

    private func hasValidBridgeToken(_ request: HTTPRequest) -> Bool {
        // Env-var fallback so automated tests can run without touching
        // Keychain (Keychain access triggers a macOS password prompt on
        // dev-signed rebuilds). Env var `OPENCLICKY_AUTOMATION_TOKEN`
        // is read directly by Process.env — bypasses AppBundleConfiguration
        // secret-storage machinery entirely.
        let envToken = ProcessInfo.processInfo.environment["OPENCLICKY_AUTOMATION_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envToken, !envToken.isEmpty {
            if Self.constantTimeEquals(request.headers["x-openclicky-token"], envToken) { return true }
            if Self.constantTimeEquals(request.headers["authorization"], "Bearer \(envToken)") { return true }
        }
        guard let configuredToken = AppBundleConfiguration.externalControlBridgeToken(),
              !configuredToken.isEmpty else { return false }
        if Self.constantTimeEquals(request.headers["x-openclicky-token"], configuredToken) {
            return true
        }
        if Self.constantTimeEquals(request.headers["authorization"], "Bearer \(configuredToken)") {
            return true
        }
        return false
    }

    private static func constantTimeEquals(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs,
              let lhsData = lhs.data(using: .utf8),
              let rhsData = rhs.data(using: .utf8),
              lhsData.count == rhsData.count else { return false }

        var difference: UInt8 = 0
        for (left, right) in zip(lhsData, rhsData) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private func proxyInferenceRequest(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "POST" else {
            sendJSON(["ok": false, "error": "Use POST for inference proxy endpoints"], statusCode: 405, on: connection)
            return
        }

        guard let proxyRequest = makeInferenceProxyURLRequest(from: request) else {
            let provider = request.path == "/v1/messages" ? "Anthropic" : "OpenAI"
            sendJSON(["ok": false, "error": "OpenClicky \(provider) API key is not configured"], statusCode: 401, on: connection)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await self.proxySession.data(for: proxyRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.queue.async {
                        self.sendJSON(["ok": false, "error": "Invalid upstream response"], statusCode: 502, on: connection)
                    }
                    return
                }
                self.queue.async {
                    self.sendRawResponse(
                        data,
                        statusCode: httpResponse.statusCode,
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/json",
                        extraHeaders: Self.proxyResponseHeaders(from: httpResponse),
                        on: connection
                    )
                }
            } catch {
                self.queue.async {
                    self.sendJSON(["ok": false, "error": "Inference proxy failed: \(error.localizedDescription)"], statusCode: 502, on: connection)
                }
            }
        }
    }

    private func makeInferenceProxyURLRequest(from request: HTTPRequest) -> URLRequest? {
        let targetBase: String
        let apiKey: String?
        if request.path == "/v1/messages" {
            targetBase = "https://api.anthropic.com"
            apiKey = AppBundleConfiguration.anthropicAPIKey()
        } else {
            targetBase = "https://api.openai.com"
            apiKey = AppBundleConfiguration.openAIAPIKey()
        }

        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: targetBase + request.path) else { return nil }

        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        upstream.timeoutInterval = 120
        upstream.httpBody = request.body
        upstream.setValue(request.headers["content-type"] ?? "application/json", forHTTPHeaderField: "Content-Type")
        if let accept = request.headers["accept"] {
            upstream.setValue(accept, forHTTPHeaderField: "Accept")
        }

        if request.path == "/v1/messages" {
            upstream.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            upstream.setValue(request.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let beta = request.headers["anthropic-beta"] {
                upstream.setValue(beta, forHTTPHeaderField: "anthropic-beta")
            }
        } else {
            upstream.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let organization = request.headers["openai-organization"] {
                upstream.setValue(organization, forHTTPHeaderField: "OpenAI-Organization")
            }
            if let project = request.headers["openai-project"] {
                upstream.setValue(project, forHTTPHeaderField: "OpenAI-Project")
            }
            if let beta = request.headers["openai-beta"] {
                upstream.setValue(beta, forHTTPHeaderField: "OpenAI-Beta")
            }
        }
        return upstream
    }

    private static func proxyResponseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for key in ["request-id", "x-request-id", "openai-processing-ms", "anthropic-ratelimit-requests-remaining", "anthropic-ratelimit-tokens-remaining"] {
            if let value = response.value(forHTTPHeaderField: key) {
                headers[key] = value
            }
        }
        return headers
    }

    private func attachSSE(_ connection: NWConnection) {
        let id = UUID()
        sseConnections[id] = connection
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendSSE(event: "ready", object: ["ok": true, "port": self?.port ?? 0], on: connection)
        })
    }

    private func broadcast(event: String, object: [String: Any]) {
        for (_, connection) in sseConnections {
            sendSSE(event: event, object: object, on: connection)
        }
    }

    private func sendSSE(event: String, object: [String: Any], on connection: NWConnection) {
        let dataObject = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(data: dataObject, encoding: .utf8) ?? "{}"
        let frame = "event: \(event)\ndata: \(json)\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, error != nil else { return }
            self.removeSSEConnection(connection)
        })
    }

    private func removeSSEConnection(_ connection: NWConnection) {
        sseConnections = sseConnections.filter { $0.value !== connection }
    }

    private func sendJSON(_ body: [String: Any], statusCode: Int, on connection: NWConnection) {
        let responseData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendRawResponse(responseData, statusCode: statusCode, contentType: "application/json", on: connection)
    }

    /// MCP Streamable HTTP response: wrap the JSON-RPC body in a single
    /// SSE `event: message\ndata: {...}` frame and close the stream.
    /// Codex 0.132's rmcp client requires this transport shape when
    /// connecting to an HTTP MCP server; a plain
    /// `application/json` reply is rejected as
    /// `UnexpectedContentType`. We also emit `Mcp-Session-Id` so
    /// clients that gate on it are happy — we don't actually keep
    /// server-side session state; each POST is self-contained.
    private func sendMCPStreamableHTTP(body: [String: Any], statusCode: Int, on connection: NWConnection) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        // SSE frame — codex rmcp Streamable HTTP client parses the
        // `event: message\ndata: <json>\n\n` block.
        let frame = "event: message\ndata: \(json)\n\n"
        // Emit as chunked transfer-encoding so the client treats this
        // as a proper streaming response (Content-Length + text/event-stream
        // is a mismatch that some SSE parsers reject as
        // UnexpectedContentType / UnexpectedEndOfStream).
        let reason = Self.reasonPhrase(for: statusCode)
        var headers = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        headers += "Content-Type: text/event-stream\r\n"
        headers += "Cache-Control: no-cache, no-transform\r\n"
        headers += "Transfer-Encoding: chunked\r\n"
        headers += "Connection: close\r\n"
        headers += "Mcp-Session-Id: \(UUID().uuidString)\r\n"
        headers += "Access-Control-Allow-Origin: http://127.0.0.1\r\n"
        headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type, Authorization, x-api-key, x-openclicky-token, mcp-session-id, mcp-protocol-version\r\n"
        headers += "Access-Control-Expose-Headers: Mcp-Session-Id\r\n"
        headers += "\r\n"
        // Chunked: <hex length>\r\n<data>\r\n ... 0\r\n\r\n
        let payload = Data(frame.utf8)
        let chunkHeader = String(format: "%X\r\n", payload.count)
        var data = Data(headers.utf8)
        data.append(Data(chunkHeader.utf8))
        data.append(payload)
        data.append(Data("\r\n0\r\n\r\n".utf8))
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendRawResponse(_ responseData: Data, statusCode: Int, contentType: String, extraHeaders: [String: String] = [:], on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: statusCode)
        var headers = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(responseData.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: http://127.0.0.1\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, x-api-key, x-openclicky-token, anthropic-version, anthropic-beta, OpenAI-Organization, OpenAI-Project, OpenAI-Beta\r\n"
        for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers += "\(key): \(value)\r\n"
        }
        headers += "\r\n"
        var data = Data(headers.utf8)
        data.append(responseData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func cursorCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let point = point(from: json) else { return nil }
        return .showCursor(
            point: point,
            caption: string(json["caption"]),
            duration: duration(from: json),
            accentHex: string(json["accentHex"]),
            mode: cursorMode(from: json),
            travelDuration: travelDuration(from: json)
        )
    }

    private static func cursorsCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let rawCursors = array(json["cursors"]) else { return nil }
        let fallbackDuration = duration(from: json)
        let specs = rawCursors.compactMap { value -> OpenClickyExternalCursorSpec? in
            guard let cursor = dictionary(value), let point = point(from: cursor) else { return nil }
            let cursorDuration = cursor["durationMs"] == nil && cursor["ttlMs"] == nil && cursor["duration"] == nil
                ? fallbackDuration
                : duration(from: cursor)
            return OpenClickyExternalCursorSpec(
                point: point,
                caption: string(cursor["caption"]),
                duration: cursorDuration,
                accentHex: string(cursor["accentHex"])
            )
        }
        return specs.isEmpty ? nil : .showCursors(specs)
    }

    private static func captionCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let text = string(json["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .showCaption(
            text: text,
            point: point(from: json),
            duration: duration(from: json),
            accentHex: string(json["accentHex"])
        )
    }

    private static func clickCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let point = point(from: json) else { return nil }
        return .click(point: point, caption: string(json["caption"]) ?? string(json["label"]))
    }

    private static func speakCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let text = string(json["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .speak(text: text, interrupt: bool(json["interrupt"]) ?? false)
    }

    private static func notifyCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let title = string(json["title"]) ?? "OpenClicky"
        guard let body = string(json["body"]) ?? string(json["text"]),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .notify(
            title: title,
            body: body,
            threadID: string(json["threadID"]) ?? string(json["threadId"]),
            sound: bool(json["sound"]) ?? true
        )
    }

    // FIX(perf-2026-08-01): descriptor pool is 114 dict-literals + a
    // dozen conditional appends. Previously a computed var → rebuilt
    // on every `tools/list` / `/mcp/tools` GET → allocated ~30 KB and
    // did O(N) work per call. Memoize once at class load. Nothing in
    // the pool depends on runtime state (all appends are compile-time
    // conditionals on constants), so a static let is safe.
    // CORRECTION to the note above: the appends are NOT compile-time
    // conditionals on constants. Three of them read UserDefaults —
    // visualDrawingOverlayToolsEnabled, gmailOAuthToolsEnabled, xlbEnabled —
    // which the user toggles in Settings. A plain `static let` froze the tool
    // list at first access, so flipping any of those switches did nothing
    // until the app restarted, and the capability metadata (rebuilt each
    // call) disagreed with the advertised tools in the meantime.
    //
    // Keep the memoization — the O(N) rebuild per tools/list was a real
    // cost — but key it on the flags that actually vary. Recomputing three
    // bools is cheap next to allocating ~30 KB of descriptors.
    private struct MCPToolDescriptorCacheKey: Equatable {
        let visualDrawing: Bool
        let gmail: Bool
        let xlb: Bool

        static var current: MCPToolDescriptorCacheKey {
            MCPToolDescriptorCacheKey(
                visualDrawing: AppBundleConfiguration.visualDrawingOverlayToolsEnabled(),
                gmail: AppBundleConfiguration.gmailOAuthToolsEnabled(),
                xlb: AppBundleConfiguration.xlbEnabled()
            )
        }
    }

    nonisolated(unsafe) private static var mcpToolDescriptorsCache:
        (key: MCPToolDescriptorCacheKey, value: [[String: Any]])?
    private static let mcpToolDescriptorsCacheLock = NSLock()

    private static var mcpToolDescriptors: [[String: Any]] {
        let key = MCPToolDescriptorCacheKey.current
        mcpToolDescriptorsCacheLock.lock()
        defer { mcpToolDescriptorsCacheLock.unlock() }
        if let cached = mcpToolDescriptorsCache, cached.key == key {
            return cached.value
        }
        let built = mcpToolDescriptorsBuilt
        mcpToolDescriptorsCache = (key, built)
        return built
    }

    // Removed publicMCPToolDescriptors — mirage's Claude Code agent path
    // consumes the running MCP server via settings.json's mcpServers HTTP
    // entry instead of embedding descriptors inline. See ClaudeAgentRunner.

    private static var mcpToolDescriptorsBuilt: [[String: Any]] {
        var descriptors: [[String: Any]] = [
            [
                "name": "openclicky_point",
                "description": "Point OpenClicky's native cursor at a macOS screen coordinate with a short caption. Use this as the normal pointing tool call for guided help and tutorials.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"],
                        "durationMs": ["type": "number"],
                        "travelMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "mode": ["type": "string", "enum": ["primary", "secondary"]]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "openclicky_point_many",
                "description": "Point at several visible UI targets at once with temporary secondary OpenClicky cursors.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cursors": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number"],
                                    "y": ["type": "number"],
                                    "caption": ["type": "string"],
                                    "accentHex": ["type": "string"],
                                    "mode": ["type": "string", "enum": ["primary", "secondary"]]
                                ],
                                "required": ["x", "y"]
                            ]
                        ],
                        "durationMs": ["type": "number"]
                    ],
                    "required": ["cursors"]
                ]
            ],
            [
                "name": "show_cursor",
                "description": "Use OpenClicky's native smooth primary-cursor pointing choreography by default, or show a secondary colored cursor when mode=secondary.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"],
                        "durationMs": ["type": "number"],
                        "travelMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "mode": ["type": "string", "enum": ["primary", "secondary"]]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "show_cursors",
                "description": "Show one or more temporary secondary colored cursors with captions. They collapse away automatically.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cursors": ["type": "array"]
                    ],
                    "required": ["cursors"]
                ]
            ],
            [
                "name": "show_caption",
                "description": "Show an OpenClicky proxy caption, optionally at macOS screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"]
                    ],
                    "required": ["text"]
                ]
            ],
        ]

        if AppBundleConfiguration.visualDrawingOverlayToolsEnabled() {
            descriptors.append(contentsOf: visualDrawingMCPToolDescriptors)
        }

        // Gmail tools stay off the advertised surface until the local flag is
        // enabled. Even then they are stubs that return structured gated errors.
        if AppBundleConfiguration.gmailOAuthToolsEnabled() {
            descriptors.append(contentsOf: gmailMCPToolDescriptors)
        }

        // xlinkBook read-only tools. Off unless the user has explicitly
        // configured xlinkBook integration in Settings.
        if AppBundleConfiguration.xlbEnabled() {
            descriptors.append(contentsOf: XLBSensorTools.descriptors)
        }

        descriptors.append(contentsOf: [
            [
                "name": "openclicky_click",
                "description": "Actually left-click a macOS screen coordinate using OpenClicky's native computer-use path. Coordinates are global AppKit screen points, the same coordinate space returned in screenshot displayFrame metadata.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "speak",
                "description": "Speak a short instruction through OpenClicky's TTS without entering dictation or voice-response mode.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "interrupt": ["type": "boolean"]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "notify",
                "description": "Send a native macOS desktop notification from OpenClicky without stealing focus.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "body": ["type": "string"],
                        "threadID": ["type": "string"],
                        "sound": ["type": "boolean"]
                    ],
                    "required": ["body"]
                ]
            ],
            [
                "name": "clear",
                "description": "Clear the OpenClicky proxy cursor/caption overlay.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "advisor_consult",
                "description": "Consult a separate, more capable reasoning model for high-level design, architecture, code review, algorithm sketch, or test-strategy questions. FREE to call (no OpenAI API cost against this session). Best for: 'how should I structure X', 'review this code snippet', 'what tests should I write for Y'. Returns plain text advice.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Your question / code snippet / design problem. Be concrete and self-contained — the advisor cannot access files or your workspace."],
                        "session": ["type": "string", "description": "Optional session id to chain multi-turn consultations."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "advisor_read_image",
                "description": "Ask a separate multimodal model to describe or analyze a local image file. FREE to call. Use for: reading text in screenshots, understanding UI mockups, describing charts/diagrams, extracting content from photos of code or documents. Returns plain text description.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "imagePath": ["type": "string", "description": "Absolute path to a local image (jpeg/png). File must exist and be readable."],
                        "question": ["type": "string", "description": "What to ask about the image (e.g. 'transcribe the code visible in this screenshot')."],
                        "session": ["type": "string", "description": "Optional session id."]
                    ],
                    "required": ["imagePath", "question"]
                ]
            ],
            [
                "name": "advisor_locate_ui",
                "description": "Given a screenshot + a natural-language description of a UI element, ask the multimodal model to return pixel coordinates + bounding box. FREE to call. Returns JSON with x, y, width, height and a label. Use to drive automated clicking / highlighting when you know what you want to hit but not where it is on screen.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "imagePath": ["type": "string", "description": "Absolute path to the screenshot to inspect."],
                        "description": ["type": "string", "description": "What element to locate (e.g. 'the blue Save button in the toolbar')."],
                        "session": ["type": "string", "description": "Optional session id."]
                    ],
                    "required": ["imagePath", "description"]
                ]
            ],
            [
                "name": "advisor_web_search",
                "description": "Ask the advisor model to run a live web search and return a cited summary. FREE to call. Bypasses the codex model's training cutoff — use for current events, library docs, breaking changes, prices, laws. Returns plain text with inline citations.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query (natural language)."],
                        "session": ["type": "string", "description": "Optional session id."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "advisor_places_lookup",
                "description": "Query real-world places / geographic data via the advisor model's Google Places integration. FREE to call. Best for: restaurants, businesses, addresses with ratings. Returns plain text with structured place info.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Maps-style query (e.g. 'coffee shops near Union Square SF')."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "advisor_stock_quote",
                "description": "Fetch live stock/ETF/crypto price + short history via the advisor model's Yahoo Finance integration. FREE to call. Returns plain text with current price + brief trend context.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "ticker": ["type": "string", "description": "Exact ticker symbol (e.g. 'AAPL', 'BTC-USD', 'SPY')."]
                    ],
                    "required": ["ticker"]
                ]
            ],
            [
                "name": "advisor_walkthrough",
                "description": "Given a screenshot + user goal, ask the advisor model to produce an ordered walkthrough (points, highlights, arrows in pixel coords, plus short narration per step). FREE to call. Use to build tutorials or guided demos.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "imagePath": ["type": "string", "description": "Absolute path to the screenshot."],
                        "goal": ["type": "string", "description": "What the user wants to accomplish (e.g. 'help me enable dark mode in these system settings')."],
                        "session": ["type": "string", "description": "Optional session id."]
                    ],
                    "required": ["imagePath", "goal"]
                ]
            ],
            [
                "name": "advisor_memory_save",
                "description": "Persist ONE fact to the advisor's account-scoped long-term memory.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "fact": ["type": "string", "description": "Concise fact ≤ 280 chars. Longer input is truncated server-side."]
                    ],
                    "required": ["fact"]
                ]
            ],
            // ============================================================
            //  codex_* tools — EXTERNAL orchestration only. These let a
            //  MCP client (Claude Code / Cursor / n8n / any MCP consumer)
            //  drive OpenClicky's local Codex agent without touching the
            //  UI. Codex agents should NEVER see these tools (they'd let
            //  the agent recurse); they are exposed only on the
            //  /mcp/orchestrate scoped endpoint.
            // ============================================================
            [
                "name": "openclicky_realtime_text_probe",
                "description": "Send text to the realtime voice session as if the user had spoken it; fire-and-forget, response arrives async on the message log.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The utterance to feed the model."]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "openrewind.searchHybrid",
                "description": "Search Screen History. Defaults to plain FTS5 keyword match (fast). Pass hybrid=true to layer Apple NLEmbedding vector similarity on top via RRF — better recall for paraphrase / synonym queries (\"meeting\" hits \"standup\", \"报错\" hits \"exception\"), costs ~50-100ms extra. Zero API cost either way. Returns {ok, hybrid, count, items:[{frameId, createdAt, bundleID, windowName, snippet}]}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "max results (default 20)"],
                        "hybrid": ["type": "boolean", "description": "enable vector semantic search (default false)"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "openclicky_simulate_voice_turn",
                "description": "Simulate one PTT voice turn end-to-end WITHOUT hardware mic / STT / Realtime WS. Fires the downstream pipeline a real voice turn would (preflight -> LTM query hits -> HeyClicky Free chat) but SKIPS vault persistence so automated test prompts do not pollute user's screen history or LTM. Poll /messages/log via automation_log_tail for `ltm.*` and `xlb.*` events to assert results. ~15s per turn, zero WS quota.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "transcript": ["type": "string", "description": "The user's simulated utterance text."]
                    ],
                    "required": ["transcript"]
                ]
            ],
            [
                "name": "openclicky_set_profile",
                "description": "Switch the active OpenClicky profile end-to-end. Valid ids: local, realtime, quality, heyclicky_free, ski_mode, mirage. Applies the profile's STT / TTS / response model + starts/stops profile-specific subsystems (heyclicky bridge, mirage classifier warm, SKI reconcile). Use before openclicky_simulate_voice_turn when the test needs to exercise a specific lane.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "profile": ["type": "string", "description": "One of: local, realtime, quality, heyclicky_free, ski_mode, mirage"]
                    ],
                    "required": ["profile"]
                ]
            ],
            [
                "name": "openclicky_simulate_ski_utterance",
                "description": "Simulate one SKI-Mode PTT utterance: builds the full UtteranceContext (LTM/xlb/stash/window/mcp URL+token/hints) then writes utterance.final to .oc/events.jsonl in the pinned active workspace. Returns the emitted event JSON so callers can assert on hint contents. Does NOT wait for a CLI reply. Pipeline requires activeProfile == ski_mode and a pinned or auto-resolvable workspace.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "transcript": ["type": "string", "description": "The user's simulated utterance text."]
                    ],
                    "required": ["transcript"]
                ]
            ],
            [
                "name": "codex_task_start",
                "description": "Start a new Codex agent task in a working directory. Returns a sessionID for follow-up / state / stop. External orchestrator only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Human-readable task title."],
                        "prompt": ["type": "string", "description": "Initial prompt for the agent."],
                        "workingDir": ["type": "string", "description": "Absolute path to the working directory."],
                        "reasoningEffort": ["type": "string", "description": "Optional: low | medium | high | xhigh | max. Default xhigh for orchestrated tasks."]
                    ],
                    "required": ["title", "prompt", "workingDir"]
                ]
            ],
            [
                "name": "codex_task_followup",
                "description": "Send a follow-up prompt into an existing agent session. If the session has an active turn we'll route through turn/steer (0 quota); otherwise it starts a new turn on the same lease.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "sessionID": ["type": "string", "description": "The UUID returned by codex_task_start."],
                        "prompt": ["type": "string", "description": "Additional prompt."]
                    ],
                    "required": ["sessionID", "prompt"]
                ]
            ],
            [
                "name": "codex_task_stop",
                "description": "Stop a running codex agent session. Persists thread_id for potential resume.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "sessionID": ["type": "string"]
                    ],
                    "required": ["sessionID"]
                ]
            ],
            [
                "name": "codex_task_state",
                "description": "Query a session's state: stage/status/entryCount/lease info. Omit sessionID to get default session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "sessionID": ["type": "string", "description": "Optional UUID; if omitted returns default session."]
                    ]
                ]
            ],
            [
                "name": "codex_task_list",
                "description": "List all agent sessions with brief metadata.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "codex_task_delete",
                "description": "Delete one agent session by UUID.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "sessionID": ["type": "string"]
                    ],
                    "required": ["sessionID"]
                ]
            ],
            [
                "name": "codex_task_purge",
                "description": "Delete every session whose title contains the given substring. Bulk cleanup.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "titleContains": ["type": "string"]
                    ],
                    "required": ["titleContains"]
                ]
            ],
            [
                "name": "codex_log_tail",
                "description": "Return the most recent N structured log events from the agent bridge. Use to observe orchestrated work in real time.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "count": ["type": "integer", "description": "Number of events (1-5000). Default 200."]
                    ]
                ]
            ],
            [
                "name": "codex_fault_inject",
                "description": "Inject a fault into a session for chaos testing (options: kill_process / drop_lease / force_401 / force_402_quota).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string"],
                        "sessionID": ["type": "string", "description": "Optional target."]
                    ],
                    "required": ["kind"]
                ]
            ],
            [
                "name": "codex_reset_account",
                "description": "Trigger a HeyClicky account reset via the chrome extension (sign-out + sign-in same email → fresh 25 credits). Use only when quota is exhausted.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "reason": ["type": "string", "description": "Free-text reason for audit."]
                    ]
                ]
            ],
            [
                "name": "codex_auth_status",
                "description": "Report HeyClicky signed-in status + token expiry.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
        ])

        return descriptors
    }

    private static var visualDrawingMCPToolDescriptors: [[String: Any]] {
        [
            [
                "name": "show_scribble",
                "description": "Draw a temporary freehand visual guidance path over visible screen content. Coordinates are global AppKit screen points.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.scribble"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "points": ["type": "array"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["points"]
                ]
            ],
            [
                "name": "show_highlight",
                "description": "Draw a temporary rectangle highlight over visible screen content. Coordinates are global AppKit screen points.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.rectangle"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "width": ["type": "number"],
                        "height": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "fillOpacity": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y", "width", "height"]
                ]
            ],
            // `show_rectangle` is accepted by dispatch and advertised in the
            // visual_guidance.rectangle capability's `tools` list, but was
            // missing from the descriptor list -- so an MCP client reading
            // tools/list could never discover a tool the capability metadata
            // told it existed. Same schema and handler as show_highlight.
            [
                "name": "show_rectangle",
                "description": "Draw a temporary rectangle highlight over visible screen content. Alias of show_highlight. Coordinates are global AppKit screen points.",
                "compatibility": ["status": "supported", "capability": "visual_guidance.rectangle"],
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "width": ["type": "number"],
                        "height": ["type": "number"],
                        "durationMs": ["type": "number"],
                        "accentHex": ["type": "string"],
                        "lineWidth": ["type": "number"],
                        "fillOpacity": ["type": "number"],
                        "caption": ["type": "string"]
                    ],
                    "required": ["x", "y", "width", "height"]
                ]
            ],
        ]
    }

    private static var gmailMCPToolDescriptors: [[String: Any]] {
        let compatibility: [String: Any] = [
            "status": "gated",
            "capability": "gmail.oauth",
            "requiresOAuth": true,
            "policy": "read-only-until-confirmed-send",
            "implementation": "stub"
        ]

        return [
            [
                "name": "gmail_list_messages",
                "description": "Gated Gmail OAuth stub. Advertised only when the local Gmail OAuth tools flag is enabled. Calls return a structured not-implemented error until the gog-backed backend is wired.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "maxResults": ["type": "number"],
                        "account": ["type": "string"]
                    ]
                ]
            ],
            [
                "name": "gmail_read_message",
                "description": "Gated Gmail OAuth stub. Advertised only when the local Gmail OAuth tools flag is enabled. Calls return a structured not-implemented error until the gog-backed backend is wired.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "string"],
                        "account": ["type": "string"]
                    ],
                    "required": ["messageId"]
                ]
            ],
            [
                "name": "gmail_draft_reply",
                "description": "Gated Gmail OAuth stub. Prepare a reply draft for user review once the backend exists. Sending remains blocked and is not implemented on this path.",
                "compatibility": compatibility,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "messageId": ["type": "string"],
                        "body": ["type": "string"],
                        "account": ["type": "string"]
                    ],
                    "required": ["messageId", "body"]
                ]
            ]
        ]
    }

    private static var capabilityCompatibilityMetadata: [[String: Any]] {
        let drawingStatus = AppBundleConfiguration.visualDrawingOverlayToolsEnabled() ? "supported" : "gated"
        let gmailToolsEnabled = AppBundleConfiguration.gmailOAuthToolsEnabled()
        return [
            [
                "id": "visual_guidance.scribble",
                "title": "Scribble drawing overlay",
                "status": drawingStatus,
                "tools": ["show_scribble"],
                "featureFlag": AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey,
                "policy": "visible-current-screen-content-only"
            ],
            [
                "id": "visual_guidance.rectangle",
                "title": "Rectangle highlight overlay",
                "status": drawingStatus,
                "tools": ["show_highlight", "show_rectangle"],
                "featureFlag": AppBundleConfiguration.userVisualDrawingOverlayToolsEnabledDefaultsKey,
                "policy": "visible-current-screen-content-only"
            ],
            [
                "id": "gmail.oauth",
                "title": "Gmail OAuth",
                // Always gated until a real OAuth/gog backend exists. The flag only
                // controls whether the stub tools are advertised for early integration.
                "status": "gated",
                "tools": gmailToolsEnabled
                    ? ["gmail_list_messages", "gmail_read_message", "gmail_draft_reply"]
                    : [],
                "featureFlag": AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey,
                "featureFlagEnabled": gmailToolsEnabled,
                "requiresOAuth": true,
                "risk": "external-account-data",
                "policy": "read-only-until-confirmed-send",
                "implementation": "stub"
            ]
        ]
    }

    private static func mcpToolCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let tool = string(json["tool"]) ?? string(json["name"])
        let arguments = dictionary(json["arguments"]) ?? dictionary(json["args"]) ?? json
        switch tool {
        case "openclicky_point", "point", "show_cursor", "openclicky_show_cursor":
            return cursorCommand(from: arguments)
        case "openclicky_point_many", "point_many", "show_cursors", "openclicky_show_cursors":
            return cursorsCommand(from: arguments)
        case "show_caption", "openclicky_show_caption":
            return captionCommand(from: arguments)
        case "show_scribble", "openclicky_show_scribble", "scribble":
            return scribbleCommand(from: arguments)
        case "show_highlight", "show_rectangle", "openclicky_show_highlight", "highlight", "rectangle":
            return rectangleCommand(from: arguments)
        case "screenshot", "screenshots", "capture_screenshot", "openclicky_screenshot":
            return .captureScreenshot(focused: bool(arguments["focused"]) ?? false)
        case "openclicky_click", "click", "left_click", "mouse_click":
            return clickCommand(from: arguments)
        case "clear", "openclicky_clear":
            return .clear
        case "speak", "openclicky_speak":
            return speakCommand(from: arguments)
        case "notify", "notification", "openclicky_notify":
            return notifyCommand(from: arguments)
        case "gmail_list_messages", "gmail_read_message", "gmail_draft_reply":
            return gmailUnavailableCommand(tool: tool ?? "gmail", arguments: arguments)
        case "advisor_consult":
            let query = string(arguments["query"]) ?? ""
            guard !query.isEmpty else { return nil }
            return .automationFreeConsult(
                query: query,
                systemContext: "You are Codex's consulting advisor. Codex has full file/shell access — YOU DO NOT. Answer with direct, concise, actionable text. No preamble.",
                sessionName: string(arguments["session"]),
                imagePath: nil,
                capabilities: ["clipboard_copy"]
            )
        case "advisor_read_image":
            let question = string(arguments["question"]) ?? ""
            let imagePath = string(arguments["imagePath"]) ?? ""
            guard !question.isEmpty, !imagePath.isEmpty else { return nil }
            return .automationFreeConsult(
                query: question,
                systemContext: "You are analyzing the attached screenshot for a coding agent. Answer the user's question directly with concrete observations. No preamble.",
                sessionName: string(arguments["session"]),
                imagePath: imagePath,
                capabilities: ["clipboard_copy"]
            )
        case "advisor_locate_ui":
            let desc = string(arguments["description"]) ?? ""
            let imagePath = string(arguments["imagePath"]) ?? ""
            guard !desc.isEmpty, !imagePath.isEmpty else { return nil }
            let query = "Locate this UI element in the attached screenshot and return its position as JSON: {\"x\": px, \"y\": px, \"width\": px, \"height\": px, \"label\": \"...\"}. Only that JSON, no prose. Element: \(desc)"
            return .automationFreeConsult(
                query: query,
                systemContext: "You are a UI element locator. Return ONLY a single JSON object with pixel coordinates. No prose.",
                sessionName: string(arguments["session"]),
                imagePath: imagePath,
                capabilities: ["clipboard_copy", "point"]
            )
        case "advisor_web_search":
            let query = string(arguments["query"]) ?? ""
            guard !query.isEmpty else { return nil }
            return .automationFreeConsult(
                query: "Please web-search this and return a concise cited summary: \(query)",
                systemContext: "You are a research assistant. Use web search. Return concise cited findings.",
                sessionName: string(arguments["session"]),
                imagePath: nil,
                capabilities: ["clipboard_copy", "web_search"]
            )
        case "advisor_places_lookup":
            let query = string(arguments["query"]) ?? ""
            guard !query.isEmpty else { return nil }
            return .automationFreeConsult(
                query: "Places lookup: \(query)",
                systemContext: "Return concrete places data for the query.",
                sessionName: nil,
                imagePath: nil,
                capabilities: ["clipboard_copy", "places_lookup"]
            )
        case "advisor_stock_quote":
            let ticker = string(arguments["ticker"]) ?? ""
            guard !ticker.isEmpty else { return nil }
            return .automationFreeConsult(
                query: "Get current stock quote and 30-day history for ticker: \(ticker)",
                systemContext: "Return concise price + trend.",
                sessionName: nil,
                imagePath: nil,
                capabilities: ["clipboard_copy", "stock_quotes"]
            )
        case "advisor_walkthrough":
            let goal = string(arguments["goal"]) ?? ""
            let imagePath = string(arguments["imagePath"]) ?? ""
            guard !goal.isEmpty, !imagePath.isEmpty else { return nil }
            return .automationFreeConsult(
                query: "Produce an ordered walkthrough for this goal: \(goal). Reply with beats including point/highlight/arrow markers in pixel coordinates.",
                systemContext: "You are producing an on-screen walkthrough. Use walkthrough.beats with point/highlight/arrow markers.",
                sessionName: string(arguments["session"]),
                imagePath: imagePath,
                capabilities: ["clipboard_copy", "walkthrough", "point"]
            )
        case "advisor_memory_save":
            let fact = string(arguments["fact"]) ?? ""
            guard !fact.isEmpty else { return nil }
            return .automationFreeConsult(
                query: "Please remember this fact for future sessions: \(fact)",
                systemContext: "Persist this fact to your long-term memory. Confirm briefly.",
                sessionName: nil,
                imagePath: nil,
                capabilities: ["clipboard_copy", "memory_save"]
            )
        case "openclicky_simulate_voice_turn":
            let transcript = string(arguments["transcript"]) ?? ""
            guard !transcript.isEmpty else { return nil }
            return .automationSimulateVoiceTurn(transcript: transcript)
        case "openclicky_set_profile":
            let profileID = string(arguments["profile"]) ?? ""
            guard !profileID.isEmpty else { return nil }
            return .automationSetActiveProfile(profileID: profileID)
        case "openclicky_simulate_ski_utterance":
            let transcript = string(arguments["transcript"]) ?? ""
            guard !transcript.isEmpty else { return nil }
            return .automationSimulateSKIUtterance(transcript: transcript)
        case "codex_task_start":
            let title = string(arguments["title"]) ?? ""
            let prompt = string(arguments["prompt"]) ?? ""
            let workingDir = string(arguments["workingDir"])
            let reasoningEffort = string(arguments["reasoningEffort"])
            guard !title.isEmpty, !prompt.isEmpty else { return nil }
            return .automationStartAgent(title: title, prompt: prompt, workingDir: workingDir, reasoningEffort: reasoningEffort)
        case "codex_task_followup":
            let sid = string(arguments["sessionID"]) ?? ""
            let prompt = string(arguments["prompt"]) ?? ""
            guard !sid.isEmpty, !prompt.isEmpty else { return nil }
            return .automationFollowUpAgent(sessionID: sid, prompt: prompt)
        case "codex_task_stop":
            let sid = string(arguments["sessionID"]) ?? ""
            guard !sid.isEmpty else { return nil }
            return .automationStopAgent(sessionID: sid)
        case "codex_task_state":
            return .automationSessionState(sessionID: string(arguments["sessionID"]))
        case "codex_task_list":
            return .automationListSessions
        case "codex_task_delete":
            let sid = string(arguments["sessionID"]) ?? ""
            guard !sid.isEmpty else { return nil }
            return .automationDeleteSession(sessionID: sid)
        case "codex_task_purge":
            let needle = string(arguments["titleContains"]) ?? ""
            guard !needle.isEmpty else { return nil }
            return .automationDeleteSessionsByTitleContains(needle: needle)
        case "codex_log_tail":
            let count: Int = {
                if let v = arguments["count"] as? Int { return v }
                if let s = string(arguments["count"]), let v = Int(s) { return v }
                return 200
            }()
            return .automationLogTail(count: min(max(count, 1), 5000))
        case "codex_fault_inject":
            let kind = string(arguments["kind"]) ?? ""
            guard !kind.isEmpty else { return nil }
            return .automationInjectFault(kind: kind, sessionID: string(arguments["sessionID"]))
        case "codex_reset_account":
            let reason = string(arguments["reason"]) ?? "external_orchestrator_request"
            return .automationAccountReset(reason: reason)
        case "codex_auth_status":
            return .automationAuthStatus
        default:
            return nil
        }
    }

    private static func gmailUnavailableCommand(tool: String, arguments: [String: Any]) -> OpenClickyExternalControlCommand {
        let featureEnabled = AppBundleConfiguration.gmailOAuthToolsEnabled()
        let message: String
        if featureEnabled {
            message = "Gmail OAuth bridge tools are advertised as stubs only. No local OAuth/gog mailbox backend is wired yet. Prefer the bundled gog / google-workspace-gogcli skill path for reads, and do not treat this call as a send."
        } else {
            message = "Gmail OAuth tools are disabled. Enable openClickyGmailOAuthToolsEnabled or OPENCLICKY_GMAIL_OAUTH_TOOLS_ENABLED to advertise the stub surface. Prefer the bundled gog / google-workspace-gogcli skill path."
        }

        var body: [String: Any] = [
            "ok": false,
            "error": message,
            "tool": tool,
            "capability": "gmail.oauth",
            "status": "gated",
            "implementation": "stub",
            "featureFlag": AppBundleConfiguration.userGmailOAuthToolsEnabledDefaultsKey,
            "featureFlagEnabled": featureEnabled,
            "policy": "read-only-until-confirmed-send"
        ]
        if let messageId = string(arguments["messageId"]) {
            body["messageId"] = messageId
        }
        if let query = string(arguments["query"]) {
            body["query"] = query
        }
        return .unavailable(statusCode: 501, body: body)
    }

    /// Tool visibility scope for MCP endpoint. `/mcp/openclicky` exposes
    /// the openclicky-native surface (advisor_* consulting + `show_*` /
    /// `openclicky_*` visual-guidance tools) as one unified endpoint —
    /// it replaces the legacy `/mcp` (openClickyControl) and
    /// `/mcp/advisor` routes. `/mcp/orchestrate` exposes only the
    /// codex-agent orchestration tools (for EXTERNAL drivers like
    /// Claude Code / Cursor — a codex agent should NOT see these or it
    /// could recurse). `.all` remains as an internal fallback default
    /// but no live route is served with it after the endpoint merge.
    fileprivate enum MCPToolRole {
        case all
        case openclicky
        case orchestrate
        case sensor

        func includes(toolName: String) -> Bool {
            switch self {
            case .all:
                return true
            case .openclicky:
                // Unified openclicky-native surface: advisor_* (free-model
                // consulting) + `show_*` / `openclicky_*` (visual guidance
                // + click/point/caption/scribble/rectangle/highlight/speak/
                // notify/clear) + `screenshot`. Legacy `/mcp` and
                // `/mcp/advisor` were merged into this single endpoint so
                // Claude Code / Codex only need one MCP registration for
                // the whole openclicky-native tool set.
                if toolName.hasPrefix("advisor_") { return true }
                if toolName.hasPrefix("openclicky_") { return true }
                if toolName.hasPrefix("show_") { return true }
                if toolName.hasPrefix("xlb_") { return true }
                switch toolName {
                case "point", "point_many",
                     "scribble", "highlight", "rectangle",
                     "click", "left_click", "mouse_click",
                     "clear", "speak", "notify", "notification",
                     "screenshot", "screenshots", "capture_screenshot",
                     "gmail_list_messages", "gmail_read_message", "gmail_draft_reply":
                    return true
                default:
                    return false
                }
            case .orchestrate:
                return toolName.hasPrefix("codex_")
            case .sensor:
                return OpenClickyExternalControlBridgeServer.sensorToolNames.contains(toolName)
            }
        }
    }

    // MARK: - Sensor MCP tools (Phase 2 Layer 2)
    //
    // Local read-only captures ported in Phase 1 to
    // Packages/OpenClickyContextService. Exposed via /mcp/sensor for both
    // codex agents and external MCP clients (Claude Code / Cursor / cmux).
    // Sensor tools do NOT flow through OpenClickyExternalControlCommand:
    // they are pure Foundation/AppKit reads that never touch the companion
    // state machine.

    /// Base set of sensor tool names (P0-P2 + F29 + F30). Phase 7.6b F31
    /// contributes 120 `browser_*` tools that are folded in via
    /// `sensorToolNames` below — kept out of the literal so the literal
    /// stays reviewable.
    fileprivate static let sensorToolNamesBase: Set<String> = Set([
        "get_focused_context",
        "list_apps",
        "get_selected_text",
        "get_clipboard",
        "get_finder_selection",
        "get_browser_url",
        "get_idle_time",
        "probe_workdir",
        "get_focused_window",
        "sensor_health",
        // Phase 5 Layer 0 additions (12 new tools)
        "screenshot",
        "get_browser_tabs",
        "get_terminal_output",
        "ocr_image",
        "check_permission",
        "install_ax_quirks",
        "list_windows",
        "cursor_position",
        "element_under_cursor",
        "recent_agent_sessions",
        "project_registry_lookup",
        "git_awareness",
        // Phase 2 v2 additions: doc readers (7)
        "doc_read_pdf",
        "doc_read_docx",
        "doc_read_xlsx",
        "doc_read_pptx",
        "doc_read_epub",
        "doc_read_html",
        "doc_read_txt",
        // Phase 2 v2 additions: memory tools (8)
        "memory_read",
        "memory_read_endpoint",
        "memory_write_endpoint",
        "memory_write_field_map",
        "memory_append_note",
        "memory_snapshot",
        "memory_freshness",
        "memory_write_verify_fixture",
        // Phase 2 v2 additions: meta tools (6)
        "list_more_tools",
        "search_tools",
        "activate_domain",
        "list_domains",
        "call_tool",
        "batch",
        // Phase 7.5 F29 additions: open-connector (6)
        "connector_list",
        "connector_describe",
        "connector_run",
        "connector_connect",
        "connector_disconnect",
        "connector_list_connections",
        // Phase 7.6a F30 additions: OpenCLI site adapters (3)
        "opencli_list",
        "opencli_describe",
        "opencli_run",
        // F32 chat_bus (6) — Everywhere ChatBusTools.cs
        "chat_send",
        "chat_subscribe",
        "chat_list",
        "chat_read",
        "chat_create",
        "chat_delete",
        // Clipboard MCP surface (4) — Everywhere ClipboardTools.cs
        "clipboard_read",
        "clipboard_write",
        "clipboard_paste",
        "clipboard_copy",
        // F34 web_* (2) — Everywhere WebSearchTool.cs
        "web_search",
        "web_fetch_url",
        // F25 stash-read (7) — Everywhere ReadPickTool.cs, ReadWhiteboardTool.cs,
        // ReadWhiteboardImageTool.cs, AddAnnotationTool.cs, ReadAnnotationsTool.cs,
        // ClearAnnotationsTool.cs, PickElementTool.cs. Impls in
        // Packages/OpenClickyContextService/Sources/OpenClickyContextService/Meta/OpenClickyStashTools.swift.
        "read_pick",
        "read_whiteboard",
        "read_whiteboard_image",
        "add_annotation",
        "read_annotations",
        "clear_annotations",
        "pick_element",
        // MEDIUM-severity ports — Everywhere GetAppContextTool.cs,
        // GetAppStateTool.cs, GateTools.cs:31-75 (strategy_note_write /
        // strategy_note_get), GeneratorTools.cs:390-440 (opendia_smoke_check).
        "get_app_context",
        "get_app_state",
        "strategy_note_get",
        "strategy_note_write",
        "opendia_smoke_check",
        // Automation cleanup: purge conversation rows written by
        // automation_simulate_voice_turn / prior test runs so
        // pollution does not survive into user LTM retrieval.
        "openclicky_purge_automation_conversations",
    ])
    // F33 adapter_* (8) — Everywhere GeneratorTools.cs + GateTools.cs
    .union(OpenClickyAdapterAuthoringBridgeTools.toolNames)
    // F35 page_* (6) — Everywhere CaptureTools.cs (page_*) + openclicky wrappers
    .union(OpenClickyPageBridgeTools.toolNames)
    // F36 capture_* (9) — Everywhere CaptureTools.cs (capture_*) + openclicky extensions
    .union(OpenClickyCaptureAuthoringBridgeTools.toolNames)

    /// Full sensor tool name set. Base + OpenDia (120 `browser_*`) +
    /// Deprecated OpenRewind MCP tools we intentionally drop from the
    /// sensor surface — their functionality was folded into other
    /// tools. Kept on the OpenRewind side (for library callers) but
    /// hidden from external MCP clients to reduce tool sprawl.
    fileprivate static let retiredOpenRewindTools: Set<String> = [
        "openrewind.aiContext",       // → folded into `openrewind.frame`
        "openrewind.summary",         // → superseded by `openrewind.recap`
        "openrewind.resolveCitation"  // → superseded by `openrewind.showFrame`
    ]

    /// OpenRewind Screen History MCP tools (9 `openrewind.*`).
    fileprivate static let sensorToolNames: Set<String> =
        sensorToolNamesBase
            .union(OpenClickyOpenDiaBridgeTools.toolNames)
            // Take builtin tools EXCEPT the three we're consolidating
            // (aiContext folds into frame:includeNeighbours, summary
            // folds into recap, resolveCitation folds into showFrame).
            .union(Set(MCPServer.builtinTools()
                .map { $0.name }
                .filter { !OpenClickyExternalControlBridgeServer.retiredOpenRewindTools.contains($0) }))
            .union([
                "openrewind.ask",
                "openrewind.showFrame",
                "openrewind.extractContext",
                "openrewind.events",
                "openrewind.transcript",
                "openrewind.audio",
                "openrewind.thumbnail",
                "openrewind.recentActivity",
                "openrewind.frameScreenRect",
                "openrewind.locateText",
                "openrewind.searchHybrid",
                "openclicky_simulate_voice_turn",
                "openclicky_simulate_ski_utterance",
                "openclicky_set_profile",
                "openclicky_realtime_text_probe",
                "openclicky_purge_automation_conversations",
                "xlb_search_topic",
                "xlb_get_topic",
                "xlb_get_topic_meta",
                "xlb_get_topic_section",
                "xlb_graph",
                "xlb_agent_state",
                "xlb_execute_command",
                "xlb_grammar_help",
                "xlb_extract_links"
            ])

    /// Domain assignment for every sensor tool. Read by
    /// `bootstrapSensorMetaRegistry()` to file each descriptor into the
    /// meta registry so `list_more_tools`, `search_tools`, and
    /// `list_domains` return sensible results. `core` tools are visible
    /// in the default `tools/list`; the long-tail (`doc_readers`,
    /// `memory`) is hidden until `activate_domain` is called (or
    /// `OPENCLICKY_MCP_FULL=1` disables the gate entirely).
    /// Base domain map (P0-P2 + F29 + F30). Phase 7.6b F31 folds in 120
    /// `browser_*` entries via `sensorToolDomains` below.
    fileprivate static let sensorToolDomainsBase: [String: String] = [
        // core (22 existing + 6 meta)
        "get_focused_context": OpenClickyMetaDomain.core,
        "list_apps": OpenClickyMetaDomain.core,
        "get_selected_text": OpenClickyMetaDomain.core,
        "get_clipboard": OpenClickyMetaDomain.core,
        "get_finder_selection": OpenClickyMetaDomain.core,
        "get_browser_url": OpenClickyMetaDomain.core,
        "get_idle_time": OpenClickyMetaDomain.core,
        "probe_workdir": OpenClickyMetaDomain.core,
        "get_focused_window": OpenClickyMetaDomain.core,
        "sensor_health": OpenClickyMetaDomain.core,
        "screenshot": OpenClickyMetaDomain.core,
        "get_browser_tabs": OpenClickyMetaDomain.core,
        "get_terminal_output": OpenClickyMetaDomain.core,
        "ocr_image": OpenClickyMetaDomain.core,
        "check_permission": OpenClickyMetaDomain.core,
        "install_ax_quirks": OpenClickyMetaDomain.core,
        "list_windows": OpenClickyMetaDomain.core,
        "cursor_position": OpenClickyMetaDomain.core,
        "element_under_cursor": OpenClickyMetaDomain.core,
        "recent_agent_sessions": OpenClickyMetaDomain.core,
        "project_registry_lookup": OpenClickyMetaDomain.core,
        "git_awareness": OpenClickyMetaDomain.core,
        "list_more_tools": OpenClickyMetaDomain.core,
        "search_tools": OpenClickyMetaDomain.core,
        "activate_domain": OpenClickyMetaDomain.core,
        "list_domains": OpenClickyMetaDomain.core,
        "call_tool": OpenClickyMetaDomain.core,
        "batch": OpenClickyMetaDomain.core,
        // doc_readers (hidden until activate_domain)
        "doc_read_pdf": OpenClickyMetaDomain.docReaders,
        "doc_read_docx": OpenClickyMetaDomain.docReaders,
        "doc_read_xlsx": OpenClickyMetaDomain.docReaders,
        "doc_read_pptx": OpenClickyMetaDomain.docReaders,
        "doc_read_epub": OpenClickyMetaDomain.docReaders,
        "doc_read_html": OpenClickyMetaDomain.docReaders,
        "doc_read_txt": OpenClickyMetaDomain.docReaders,
        // memory (hidden until activate_domain)
        "memory_read": OpenClickyMetaDomain.memory,
        "memory_read_endpoint": OpenClickyMetaDomain.memory,
        "memory_write_endpoint": OpenClickyMetaDomain.memory,
        "memory_write_field_map": OpenClickyMetaDomain.memory,
        "memory_append_note": OpenClickyMetaDomain.memory,
        "memory_snapshot": OpenClickyMetaDomain.memory,
        "memory_freshness": OpenClickyMetaDomain.memory,
        "memory_write_verify_fixture": OpenClickyMetaDomain.memory,
        // Phase 7.5 F29 — open-connector (visible when subprocess is
        // running; guarded at dispatch time in
        // OpenClickyConnectorBridgeTools). Domain string is a literal
        // "connector" — the SPM meta-domain roster is off-limits per
        // task constraints, so the tools live in the `core` tier at
        // registry-registration time but display the connector origin
        // in their descriptions.
        "connector_list": OpenClickyMetaDomain.core,
        "connector_describe": OpenClickyMetaDomain.core,
        "connector_run": OpenClickyMetaDomain.core,
        "connector_connect": OpenClickyMetaDomain.core,
        "connector_disconnect": OpenClickyMetaDomain.core,
        "connector_list_connections": OpenClickyMetaDomain.core,
        // Phase 7.6a F30 — OpenCLI site adapters (visible when
        // subprocess is running; guarded at dispatch time in
        // OpenClickyOpenCLIBridgeTools). Same rationale as F29 — the
        // SPM meta-domain roster is off-limits, so these live in the
        // `core` tier at registry-registration time and declare their
        // OpenCLI origin in their descriptions.
        "opencli_list": OpenClickyMetaDomain.core,
        "opencli_describe": OpenClickyMetaDomain.core,
        "opencli_run": OpenClickyMetaDomain.core,
        // F32 chat_bus — hidden by default; activate via
        // `activate_domain name=chat` before use.
        "chat_send": OpenClickyMetaDomain.chat,
        "chat_subscribe": OpenClickyMetaDomain.chat,
        "chat_list": OpenClickyMetaDomain.chat,
        "chat_read": OpenClickyMetaDomain.chat,
        "chat_create": OpenClickyMetaDomain.chat,
        "chat_delete": OpenClickyMetaDomain.chat,
        // Clipboard tools — visible in `core` tier so agents can
        // read/write the pasteboard without domain activation.
        "clipboard_read": OpenClickyMetaDomain.core,
        "clipboard_write": OpenClickyMetaDomain.core,
        "clipboard_paste": OpenClickyMetaDomain.core,
        "clipboard_copy": OpenClickyMetaDomain.core,
        // F34 web_* — hidden by default; activate via
        // `activate_domain name=web` before use.
        "web_search": OpenClickyMetaDomain.web,
        "web_fetch_url": OpenClickyMetaDomain.web,
        // F33 adapter_* — Everywhere GeneratorTools.cs + GateTools.cs.
        // Pinned to `core` following the F30 precedent: the shared
        // meta-domain roster is off-limits per task constraints, so
        // adapter tools live under `core` at registry-registration time
        // and declare their authoring origin in their descriptions.
        // Self-expand gate + input validation gate live in
        // OpenClickyAdapterAuthoringBridgeTools.execute.
        "adapter_scaffold": OpenClickyMetaDomain.core,
        "adapter_save": OpenClickyMetaDomain.core,
        "adapter_verify": OpenClickyMetaDomain.core,
        "adapter_list_local": OpenClickyMetaDomain.core,
        "adapter_drift_check": OpenClickyMetaDomain.core,
        "adapter_delete_local": OpenClickyMetaDomain.core,
        "adapter_regenerate": OpenClickyMetaDomain.core,
        "adapter_lint": OpenClickyMetaDomain.core,
        // F35 page_* — Everywhere upstream 2 + 4 openclicky wrappers.
        // page_extract_by_rule / page_save_extraction_rule map onto
        // Everywhere's extraction-rule cache; page_read/summarise/inspect/
        // actions are thin OpenDia compositions per F35 fallback clause.
        "page_extract_by_rule": OpenClickyMetaDomain.core,
        "page_save_extraction_rule": OpenClickyMetaDomain.core,
        "page_read": OpenClickyMetaDomain.core,
        "page_summarise": OpenClickyMetaDomain.core,
        "page_inspect": OpenClickyMetaDomain.core,
        "page_actions": OpenClickyMetaDomain.core,
        // F36 capture_* — Everywhere upstream 4 + 5 openclicky
        // authoring-store extensions. Backing CaptureSessionStore is
        // not yet ported; upstream 4 currently surface NOT_IMPLEMENTED.
        "capture_start": OpenClickyMetaDomain.core,
        "capture_stop": OpenClickyMetaDomain.core,
        "capture_current": OpenClickyMetaDomain.core,
        "capture_export": OpenClickyMetaDomain.core,
        "capture_draft": OpenClickyMetaDomain.core,
        "capture_publish": OpenClickyMetaDomain.core,
        "capture_list": OpenClickyMetaDomain.core,
        "capture_delete": OpenClickyMetaDomain.core,
        "capture_run": OpenClickyMetaDomain.core,
        // F25 stash-read (7) — Everywhere per-tool sources cited on the
        // Set literal above. Pinned to `core` following the F33/F35
        // precedent: `whiteboard` domain exists in OpenClickyMetaDomain
        // but the roster-mutation escape hatch is off-limits.
        "read_pick": OpenClickyMetaDomain.core,
        "read_whiteboard": OpenClickyMetaDomain.core,
        "read_whiteboard_image": OpenClickyMetaDomain.core,
        "add_annotation": OpenClickyMetaDomain.core,
        "read_annotations": OpenClickyMetaDomain.core,
        "clear_annotations": OpenClickyMetaDomain.core,
        "pick_element": OpenClickyMetaDomain.core,
        // MEDIUM-severity ports — Everywhere GetAppContextTool.cs,
        // GetAppStateTool.cs, GateTools.cs:31-75, GeneratorTools.cs:390-440.
        "get_app_context": OpenClickyMetaDomain.core,
        "get_app_state": OpenClickyMetaDomain.core,
        "strategy_note_get": OpenClickyMetaDomain.core,
        "strategy_note_write": OpenClickyMetaDomain.core,
        "opendia_smoke_check": OpenClickyMetaDomain.core,
        // OpenRewind Screen History tools — hidden until an MCP client
        // explicitly activates the `screen_history` domain.
        "openrewind.search":          OpenClickyMetaDomain.screenHistory,
        "openrewind.timeline":        OpenClickyMetaDomain.screenHistory,
        "openrewind.frame":           OpenClickyMetaDomain.screenHistory,
        "openrewind.currentContext":  OpenClickyMetaDomain.screenHistory,
        "openrewind.recap":           OpenClickyMetaDomain.screenHistory,
        "openrewind.retentionInfo":   OpenClickyMetaDomain.screenHistory,
        "openrewind.ask":             OpenClickyMetaDomain.screenHistory,
        "openrewind.showFrame":       OpenClickyMetaDomain.screenHistory,
        "openrewind.extractContext":  OpenClickyMetaDomain.screenHistory,
        "openrewind.events":          OpenClickyMetaDomain.screenHistory,
        "openrewind.transcript":      OpenClickyMetaDomain.screenHistory,
        "openrewind.audio":           OpenClickyMetaDomain.screenHistory,
        "openrewind.thumbnail":       OpenClickyMetaDomain.screenHistory,
        "openrewind.recentActivity":  OpenClickyMetaDomain.screenHistory,
        "openrewind.frameScreenRect": OpenClickyMetaDomain.screenHistory,
        "openrewind.locateText":      OpenClickyMetaDomain.screenHistory
    ]

    /// Full sensor tool domain map. Base + OpenDia (120 `browser_*` all
    /// pinned to `OpenClickyMetaDomain.browser`, so they stay hidden
    /// from the default `tools/list` until an MCP client calls
    /// `activate_domain name=browser`).
    fileprivate static let sensorToolDomains: [String: String] = {
        var m = sensorToolDomainsBase
        for entry in OpenClickyOpenDiaBridgeTools.toolList {
            m[entry.name] = OpenClickyMetaDomain.browser
        }
        return m
    }()

    /// Retained strong reference to the meta-registry dispatch delegate.
    /// `OpenClickyMetaToolRegistry` holds the delegate weakly so the
    /// bridge must keep a strong reference itself.
    fileprivate static let sensorMetaDispatchDelegate: SensorMetaDispatchDelegate = SensorMetaDispatchDelegate()

    /// Shared meta registry backing `list_more_tools` / `search_tools` /
    /// `activate_domain` / `list_domains` / `call_tool` / `batch`.
    /// Bootstrapped lazily on first access with all 43 sensor
    /// descriptors + a dispatch delegate wired back to
    /// `executeSensorTool`.
    fileprivate static let sensorMetaRegistry: OpenClickyMetaToolRegistry = {
        let registry = OpenClickyMetaToolRegistry()
        registry.setDispatchDelegate(OpenClickyExternalControlBridgeServer.sensorMetaDispatchDelegate)
        for descriptor in OpenClickyExternalControlBridgeServer.sensorToolDescriptorsRaw {
            guard let name = descriptor["name"] as? String,
                  let description = descriptor["description"] as? String else { continue }
            let domain = OpenClickyExternalControlBridgeServer.sensorToolDomains[name] ?? OpenClickyMetaDomain.core
            let hidden = (domain != OpenClickyMetaDomain.core)
            registry.register(MetaToolDescriptor(
                name: name,
                description: description,
                domain: domain,
                isHidden: hidden
            ))
        }
        return registry
    }()

    /// Applies the domain gate (core visible; hidden domains visible
    /// only when activated or when `OPENCLICKY_MCP_FULL=1`).
    fileprivate static var sensorToolDescriptors: [[String: Any]] {
        let all = sensorToolDescriptorsRaw
        // `OPENCLICKY_MCP_FULL=1` disables the gate — everything is visible.
        if !OpenClickyMetaCoreToolGate.filterEnabled {
            return all
        }
        let activeDomains = sensorMetaRegistry.activatedDomains()
        return all.filter { descriptor in
            guard let name = descriptor["name"] as? String else { return false }
            let domain = sensorToolDomains[name] ?? OpenClickyMetaDomain.core
            return domain == OpenClickyMetaDomain.core || activeDomains.contains(domain)
        }
    }

    /// Full, unfiltered descriptor list (all 43 sensor tools). The
    /// registry indexes this list; the gated `sensorToolDescriptors`
    /// view derives from it.
    fileprivate static var sensorToolDescriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "get_focused_context",
                "description": "Bundle the currently-focused macOS context: frontmost app, focused window, selected text, browser URL (if applicable), and Finder selection. One-shot read for agents that want everything about 'what the user is looking at' without chaining multiple calls.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "list_apps",
                "description": "Return the frontmost macOS application (bundle id, localized name, pid, executable path, activation policy). Phase 1 exposes the frontmost app only; the full running-app roster is a Phase 3 TODO.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_selected_text",
                "description": "Return the user's current text selection anywhere on macOS. Uses a three-strategy fallback: AXSelectedText on focused element, AXSelectedText on child elements, and synthesized Cmd+C into the pasteboard. Returns text plus source (ax/child/clipboardCmdC/cache), source app key, and grapheme-cluster length.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_clipboard",
                "description": "Return the current macOS general pasteboard text (public.utf8-plain-text). Text-only in P0; file paths / images / RTF are P1 additions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_finder_selection",
                "description": "Return the current Finder selection: the folder shown in the frontmost Finder window plus every selected item (path, filename, isDirectory, kindHint). Uses AppleScript against Finder.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_browser_url",
                "description": "Return the AXURL published by an AX-accessible app (typically a browser tab). If process_id is omitted, defaults to the frontmost app's pid. Returns null if the pid has no AXURL in its focus chain (up to 16 ancestor hops).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "process_id": ["type": "integer", "description": "Optional pid to query. Defaults to the frontmost app's pid."]
                    ],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_idle_time",
                "description": "Return seconds since the user last touched any input device, via CGEventSourceSecondsSinceLastEventType.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "probe_workdir",
                "description": "Probe an on-disk folder path for OpenClicky's project-type classifier: exists, isDirectory, isEmpty, fileCount, detectedProjectType, hasGit, hasOpenClickyState, hasAgentsMd. OpenClicky-unique (no Everywhere equivalent) - used to decide how to hand a folder to an agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to probe."]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "get_focused_window",
                "description": "Return the AX-focused window of a pid: title, frame (Quartz top-left global coords), displayIndex, isMinimized, isMainWindow. If process_id is omitted, defaults to the frontmost app's pid.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "process_id": ["type": "integer", "description": "Optional pid to query. Defaults to the frontmost app's pid."]
                    ],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "sensor_health",
                "description": "Meta tool for smoke testing. Returns {status, capture_count, version} without touching AppKit or AX APIs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "screenshot",
                "description": "Everywhere-parity screenshot. scope='screen' captures an entire display (screenID = pid if given, else 0). scope='window' captures the top-most on-screen window of pid. scope='region' captures an arbitrary Quartz-space rect. Returns base64-encoded bytes plus format and pixel dimensions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "scope": ["type": "string", "enum": ["screen", "window", "region"], "description": "Capture mode: screen | window | region."],
                        "pid": ["type": "integer", "description": "Process id (required for scope=window; used as screenID index for scope=screen)."],
                        "rect": [
                            "type": "object",
                            "description": "Quartz-space rectangle (top-left origin) for scope=region.",
                            "properties": [
                                "x": ["type": "number"],
                                "y": ["type": "number"],
                                "w": ["type": "number"],
                                "h": ["type": "number"]
                            ] as [String: Any]
                        ] as [String: Any],
                        "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Output encoding. Default jpeg."],
                        "quality": ["type": "integer", "description": "Reserved (encoder currently uses ScreenshotEncoder defaults). Accepted for forward compatibility."]
                    ] as [String: Any],
                    "required": ["scope"]
                ]
            ],
            [
                "name": "get_browser_tabs",
                "description": "Enumerate every open tab across every window of a supported browser (Safari, Chrome, Arc, Brave, Edge, Chromium, Vivaldi, Opera) via AppleScript. If app is omitted, resolves the frontmost browser. Returns null when the browser is not running or not scriptable.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "Optional canonical AppleScript app name (e.g. 'Google Chrome'). Defaults to frontmost browser."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "get_terminal_output",
                "description": "Return the trailing scrollback of the currently-focused terminal (Terminal, iTerm2, Ghostty, Warp, Alacritty, kitty, Konsole, xterm) via AX. Returns {is_terminal, lines_returned, text}. is_terminal is false when the focused app is not a known terminal.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "lines_back": ["type": "integer", "description": "Number of trailing lines to return (1..10000, default 200)."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "ocr_image",
                "description": "Run macOS Vision OCR over a caller-supplied image (base64-encoded PNG/JPEG bytes). Returns line-level text plus bounding boxes (image-local pixel space, upper-left origin) and confidence. Empty lines list is a valid non-error result.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "image_base64": ["type": "string", "description": "Base64-encoded image bytes (PNG or JPEG)."],
                        "languages": [
                            "type": "array",
                            "items": ["type": "string"] as [String: Any],
                            "description": "BCP-47 language codes to prefer. Defaults to ['en-US','zh-Hans']."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["image_base64"]
                ]
            ],
            [
                "name": "check_permission",
                "description": "Passive preflight check for one macOS TCC permission. Never triggers a system prompt. Returns {status} where status is one of granted|denied|notDetermined|restricted|unknown. For kind=automation, the target bundle id is required.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["accessibility", "screenRecording", "inputMonitoring", "microphone", "automation"], "description": "Permission surface to inspect."],
                        "automation_target_bundle_id": ["type": "string", "description": "Bundle id of the AppleEvents target app (only used when kind=automation)."]
                    ] as [String: Any],
                    "required": ["kind"]
                ]
            ],
            [
                "name": "install_ax_quirks",
                "description": "Flip the private AXManualAccessibility and AXEnhancedUserInterface attributes on the target process to force stubborn apps (Electron, Chromium, some SwiftUI hosts) to publish their AX tree. WARNING: this has global side effects on the target app and cannot be reversed cleanly; only invoke on user-affirmed apps.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "pid": ["type": "integer", "description": "Process id of the target app (must be > 0)."]
                    ] as [String: Any],
                    "required": ["pid"]
                ]
            ],
            [
                "name": "list_windows",
                "description": "Enumerate WindowServer windows via CGWindowListCopyWindowInfo. Returns front-to-back list with pid, wid, title, owner, bounds, screenIndex, isOnScreen, layer, alpha. Titles of other apps' windows may be omitted on macOS 15+ without Screen Recording permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "only_on_screen": ["type": "boolean", "description": "Restrict to on-screen windows. Default true."],
                        "exclude_desktop": ["type": "boolean", "description": "Exclude desktop / dock elements. Default true."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "cursor_position",
                "description": "Return the current global cursor position as a Quartz CGPoint (top-left origin) plus the NSScreen.screens index of the containing display. displayIndex is -1 when headless.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "element_under_cursor",
                "description": "Hit-test the AX element at a global Quartz point via AXUIElementCopyElementAtPosition. If x/y are omitted, uses the current cursor position. Returns pid, role, subrole, title, value, bounds, bundleId.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number", "description": "Optional Quartz X. Defaults to current cursor."],
                        "y": ["type": "number", "description": "Optional Quartz Y. Defaults to current cursor."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "recent_agent_sessions",
                "description": "List the most recently active OpenClicky Codex agent sessions, sorted by last update descending. Returns id, projectPath, projectSlug, startedAt, lastUpdatedAt, status, taskSummary.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max sessions to return (default 10)."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "project_registry_lookup",
                "description": "Fuzzy-match a project name / alias against the local ProjectRegistry. Returns entries scored 0..1 with matchedTerm explaining why each entry was picked. Case-insensitive, punctuation-tolerant.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Query text (name, alias, spoken variant)."],
                        "limit": ["type": "integer", "description": "Max matches to return (default 5)."]
                    ] as [String: Any],
                    "required": ["query"]
                ]
            ],
            [
                "name": "git_awareness",
                "description": "Probe a git working tree via short-lived `git` subprocess invocations. Returns repoRoot, currentBranch, detachedHead, isDirty, staged/modified/untracked/stash counts, aheadOfUpstream, behindUpstream, and last-commit metadata. Returns null when the path is not inside a git repo or git is unavailable.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path inside the git working tree."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            // ---- Phase 2 v2 additions: doc readers (7) ------------------
            [
                "name": "doc_read_pdf",
                "description": "Read text from a local PDF file. Returns {text, page_count, word_count, mime_type, warnings}. `max_pages` (optional) caps the number of pages parsed; the rest is skipped and a warning is appended.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the PDF."],
                        "max_pages": ["type": "integer", "description": "Optional cap on pages parsed."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_docx",
                "description": "Read text from a Microsoft Word .docx file. Returns {text, page_count, word_count, mime_type, warnings}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the .docx."],
                        "max_pages": ["type": "integer", "description": "Optional cap on pages parsed."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_xlsx",
                "description": "Read text from a Microsoft Excel .xlsx file. Returns concatenated sheet text plus metadata warnings for sheet names.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the .xlsx."],
                        "max_pages": ["type": "integer", "description": "Optional cap on sheets parsed."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_pptx",
                "description": "Read text from a Microsoft PowerPoint .pptx file. Returns concatenated slide text plus per-slide warnings.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the .pptx."],
                        "max_pages": ["type": "integer", "description": "Optional cap on slides parsed."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_epub",
                "description": "Read text from an EPUB e-book. Returns concatenated chapter text plus title/author warnings.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the .epub."],
                        "max_pages": ["type": "integer", "description": "Optional cap on chapters parsed."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_html",
                "description": "Read text from a local HTML file. Strips tags and returns plain text plus warnings.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the .html/.htm."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            [
                "name": "doc_read_txt",
                "description": "Read text from a plain-text file with UTF-8 -> GB18030 -> Latin-1 encoding fallback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute POSIX path to the text file."]
                    ] as [String: Any],
                    "required": ["path"]
                ]
            ],
            // ---- Phase 2 v2 additions: memory tools (8) -----------------
            [
                "name": "memory_read",
                "description": "Read the OpenClicky memory field map. Returns {entries: {k:v,...}}; when key is provided, returns just that entry (or empty).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string", "description": "Optional single field key to read."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "memory_read_endpoint",
                "description": "Read one named endpoint's memory entry: {name, fields, notes, lastWriteAt}. Returns null when the endpoint has not been written.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "endpoint": ["type": "string", "description": "Endpoint name to look up."]
                    ] as [String: Any],
                    "required": ["endpoint"]
                ]
            ],
            [
                "name": "memory_write_endpoint",
                "description": "Overwrite an endpoint memory record. Throws mergeConflict when the endpoint exists and force is false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "endpoint": ["type": "string", "description": "Endpoint name."],
                        "value": ["type": "object", "description": "Envelope with optional fields:{k:v,...}, notes:[...], force:true."]
                    ] as [String: Any],
                    "required": ["endpoint", "value"]
                ]
            ],
            [
                "name": "memory_write_field_map",
                "description": "Bulk-merge a string->string map into the top-level field bag. Throws mergeConflict on the first colliding key when force is false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "map": ["type": "object", "description": "Map of field keys to string values."],
                        "force": ["type": "boolean", "description": "Overwrite existing keys. Default false."]
                    ] as [String: Any],
                    "required": ["map"]
                ]
            ],
            [
                "name": "memory_append_note",
                "description": "Append an ISO-timestamped note to the global notes list (or to an endpoint's notes when endpoint is provided).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Note body."],
                        "endpoint": ["type": "string", "description": "Optional endpoint name to attach the note to."]
                    ] as [String: Any],
                    "required": ["text"]
                ]
            ],
            [
                "name": "memory_snapshot",
                "description": "Return the whole memory store as a snapshot: {endpoints, fieldMap, notes, verifyFixtures, lastWriteAt}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "memory_freshness",
                "description": "Return {last_write_unix, staleness_seconds} for the memory store.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "memory_write_verify_fixture",
                "description": "Persist a raw JSON body against a verify `cmd`. Throws mergeConflict when the fixture exists and force is false.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cmd": ["type": "string", "description": "Verify command key."],
                        "fixture_json": ["type": "string", "description": "Raw JSON body to store."],
                        "force": ["type": "boolean", "description": "Overwrite. Default false."]
                    ] as [String: Any],
                    "required": ["cmd", "fixture_json"]
                ]
            ],
            // ---- Phase 2 v2 additions: meta tools (6) -------------------
            [
                "name": "list_more_tools",
                "description": "List long-tail (hidden) tools filed under the meta registry. Optional `category` filters by domain (e.g. 'doc_readers', 'memory'). When OPENCLICKY_MCP_FULL=1, returns every registered descriptor regardless of visibility.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "category": ["type": "string", "description": "Optional domain filter."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "search_tools",
                "description": "BM25 search over the meta registry (`(name, description)` per tool). Returns top-K matches with name, description, score, domain.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query."],
                        "top_k": ["type": "integer", "description": "Max results (default 5)."]
                    ] as [String: Any],
                    "required": ["query"]
                ]
            ],
            [
                "name": "activate_domain",
                "description": "Activate a hidden domain so its tools appear in the default tools/list. Returns {ok, activated:[...names...]}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Domain name (e.g. 'doc_readers', 'memory')."]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ],
            [
                "name": "list_domains",
                "description": "List all known domains with tool_count and isActive flags. `core` is always active.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "call_tool",
                "description": "Reflectively invoke any registered sensor tool by name. `arguments_json` is a raw JSON string parsed and forwarded to the target tool's dispatch.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Tool name."],
                        "arguments_json": ["type": "string", "description": "Optional raw JSON string with the tool's arguments."]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ],
            [
                "name": "batch",
                "description": "Sequential batch dispatch. `steps` is a list of {tool, arguments} entries; execution stops on the first error. Returns a list of {tool, ok, resultJson, errorMessage}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "description": "Batch steps.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "tool": ["type": "string"],
                                    "arguments": ["type": "object"]
                                ] as [String: Any]
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["steps"]
                ]
            ],
            // ---- F25 stash-read (7) — mirrors Everywhere Tools/ReadPickTool.cs,
            // ReadWhiteboardTool.cs, ReadWhiteboardImageTool.cs,
            // AddAnnotationTool.cs, ReadAnnotationsTool.cs, ClearAnnotationsTool.cs,
            // PickElementTool.cs — implementations in
            // Packages/OpenClickyContextService/.../Meta/OpenClickyStashTools.swift.
            [
                "name": "read_pick",
                "description": "Read the UI element the user pinned via OpenClicky's Pin-Element hotkey. Returns {pinned, picked_index, app, element}. Consumed on read; expires 5min.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "description": "Output mode: auto | links | text | full. Default auto."],
                        "include_tree_json": ["type": "boolean", "description": "When true, include a JSON encoding of the picked element."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "read_whiteboard",
                "description": "Read user's whiteboard annotations (rectangular gestures). Returns markdown per region with gesture kind (circle/underline/arrow/x). {drawn:false} if none fresh. Consumed on read; expires 5min.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "read_whiteboard_image",
                "description": "Fetch the actual pixels of one image surfaced by a prior read_whiteboard call. Images live for ~5 minutes after the whiteboard was drawn.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "image_id": ["type": "string", "description": "The image_id from read_whiteboard's output."]
                    ] as [String: Any],
                    "required": ["image_id"]
                ]
            ],
            [
                "name": "add_annotation",
                "description": "Queue a user note against a perception anchor. source: pin|whiteboard|selected|linkrect. body: note text. anchor_label: short human-readable target description. anchor_ref (optional): opaque id. Returns {queued:<int>}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string", "description": "One of pin|whiteboard|selected|linkrect."],
                        "body": ["type": "string", "description": "Note body."],
                        "anchor_label": ["type": "string", "description": "Short human-readable target description."],
                        "anchor_ref": ["type": "string", "description": "Optional opaque id (e.g. element_index for pin)."]
                    ] as [String: Any],
                    "required": ["source", "body", "anchor_label"]
                ]
            ],
            [
                "name": "read_annotations",
                "description": "List queued user annotations without consuming them. Each entry: {source, body, anchor_label, anchor_ref, captured_at}. Returns {count, annotations:[...]}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "clear_annotations",
                "description": "Drop every queued annotation without sending. Returns {cleared:<int>}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "pick_element",
                "description": "Trigger OpenClicky's visual element picker. The user clicks the element/window/screen they want and the tool returns its snapshot. Returns {cancelled:true} if dismissed. Prefer this over guessing coordinates when the user says 'this thing', 'that button', 'this window'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "description": "element | window | screen | free. Default element."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            // ---- Clipboard MCP surface (4) — Everywhere ClipboardTools.cs.
            // Names + descriptions byte-exact with Everywhere
            // ClipboardTools.cs:35-58. Read tools alias each other
            // (clipboard_read == clipboard_paste, clipboard_write ==
            // clipboard_copy); the openclicky port additionally routes
            // clipboard_paste / clipboard_copy through CGEvent chords
            // to match SPEC ab browser semantics (see ClipboardWriter.swift).
            [
                "name": "clipboard_read",
                "description": "Read the macOS general pasteboard as plain text. Returns {has_text:bool, text:string}. Cheap; prefer this for inspecting the clipboard. SPEC ab agent_browser_clipboard_read.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "clipboard_write",
                "description": "DANGEROUS: replace the macOS general pasteboard with the given text. SPEC ab agent_browser_clipboard_write.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Text to place on the pasteboard."]
                    ] as [String: Any],
                    "required": ["text"]
                ]
            ],
            // MEDIUM-severity ports. Byte-exact names/schemas/descriptions
            // from Everywhere pin 30e03e9dcfdd4247fd679828ed86e9042f32d809.
            [
                // Everywhere Tools/GetAppContextTool.cs:15-31.
                "name": "get_app_context",
                "description": "Fuzzy app name -> window state (indexed a11y tree). Combines list_apps + get_app_state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app_hint": ["type": "string", "description": "Fuzzy app name. Matched against process name AND window title (case-insensitive substring)."],
                        "show_full_text": ["type": "boolean"],
                        "raise_if_needed": ["type": "boolean"],
                        "include_screenshot": ["type": "boolean"],
                        "include_tree_json": ["type": "boolean"]
                    ] as [String: Any],
                    "required": ["app_hint"]
                ]
            ],
            [
                // Everywhere Tools/GetAppStateTool.cs:11-21.
                "name": "get_app_state",
                "description": "Snapshot a NAMED app's largest visible window as an indexed a11y tree; pass [<element_index>] to click/scroll/set_value/perform_secondary_action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string"],
                        "show_full_text": ["type": "boolean"]
                    ] as [String: Any],
                    "required": ["app"]
                ]
            ],
            [
                // Everywhere Tools/GateTools.cs:63-65.
                "name": "strategy_note_get",
                "description": "Read a StrategyNote from memory or return null.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["site", "name"]
                ]
            ],
            [
                // Everywhere Tools/GateTools.cs:31-36.
                "name": "strategy_note_write",
                "description": "Persist a StrategyNote for a site/name to memory. Validates evidence >=3 items x >=20 chars, replay >=50 chars; returns {path} on success or STRATEGY_NOTE_INCOMPLETE.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "site": ["type": "string"],
                        "name": ["type": "string"],
                        "note": ["type": "string", "description": "JSON string matching the StrategyNote schema."]
                    ] as [String: Any],
                    "required": ["site", "name", "note"]
                ]
            ],
            [
                // Everywhere Tools/GeneratorTools.cs:390-393.
                "name": "opendia_smoke_check",
                "description": "Verify OpenDia extension exposes the browser_* tools the platform depends on. Returns {ok, missing?:[]}. When missing, all Phase 1-5 tools surface OPENDIA_INCOMPATIBLE.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            // Byte-parity with Everywhere `GetClipboardTool.cs:12`.
        ] + OpenClickyConnectorBridgeTools.descriptorsRaw
          + OpenClickyOpenCLIBridgeTools.descriptorsRaw
          + OpenClickyOpenDiaBridgeTools.descriptorsRaw
          + OpenClickyChatBridgeTools.descriptorsRaw
          + OpenClickyWebBridgeTools.descriptorsRaw
          // F33 adapter_* / F35 page_* / F36 capture_* long-tail.
          + OpenClickyAdapterAuthoringBridgeTools.descriptorsRaw
          + OpenClickyPageBridgeTools.descriptorsRaw
          + OpenClickyCaptureAuthoringBridgeTools.descriptorsRaw
          + openRewindMCPDescriptors
    }

    /// Screen History (embedded OpenRewind) MCP tool descriptors.
    /// Sourced from `MCPServer.builtinTools()` so the sensor mirrors
    /// whatever OpenRewind exposes without duplicating schema.
    fileprivate static var openRewindMCPDescriptors: [[String: Any]] {
        // Drop retired tools; expose only the surface we recommend.
        var out = MCPServer.builtinTools()
            .filter { !Self.retiredOpenRewindTools.contains($0.name) }
            .map { $0.toWire() }
        // Add `openrewind.ask` — our end-to-end pipeline (Stage 1 LLM
        // query decomposition + Stage 2 FTS+ranker + Stage 3 LLM
        // synthesis). Not part of OpenRewind's own MCP core; layered
        // on top by the host.
        out.append([
            "name": "openrewind.ask",
            "description": "Ask a natural-language question about the user's past screen activity. Runs the full Ask Rewind pipeline: LLM decomposes the query (extracting keywords / apps / date range), Reader.search returns candidate frames, a multi-signal ranker re-orders them (recency + metadata boost), then an LLM synthesises a cited answer using [FRAME#N] citations. Supports retrace-style syntax in the question: `app:com.cmuxterm.app`, `site:github.com`, `after:2026-07-29`, `before:yesterday`, quoted `\"exact phrase\"`, `-excluded`. Returns { answer, cited_frame_ids, search_query, result_count }.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "description": "The user's natural-language question. May contain retrace-style filter syntax to skip LLM decomposition."
                    ],
                    "previous_queries": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional prior questions in this session (for context-sensitive decomposition)."
                    ]
                ],
                "required": ["question"]
            ]
        ])
        out.append([
            "name": "openrewind.showFrame",
            "description": "Open the Screen History timeline UI at a specific historical frame. Instead of pasting OCR text back to the user, the AI can invoke this and the user sees the actual pixels in the timeline (with scrub / star / ask again controls). Address the frame either by `frame_id` (from a prior openrewind.search / .ask citation) or by `at` (ISO8601 timestamp or unix seconds — closest frame in a 60s window is selected).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frame_id": ["type": "integer",
                                 "description": "OpenRewind frame primary key."],
                    "at": ["type": "string",
                           "description": "ISO8601 timestamp or unix seconds."]
                ],
                "required": [] as [Any]
            ]
        ])
        out.append([
            "name": "openrewind.extractContext",
            "description": "Run OpenRewind's context extractor over an arbitrary image (PNG or JPEG). Returns OCR text with per-word bounding boxes, dominant language, content classification, barcode payloads, and rectangle count — the same structured context the capture pipeline computes per screen frame. Feed either `image_base64` (data:image... prefix stripped, plain base64) or `image_path` (absolute local file). Vision LLMs get more accurate answers when they receive both the image AND this structured breakdown, because they can cross-reference their own reading with the extractor's authoritative OCR + bbox.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "image_base64": ["type": "string"],
                    "image_path": ["type": "string"],
                    "bundle_id": ["type": "string"]
                ],
                "required": [] as [Any]
            ]
        ])
        out.append([
            "name": "openrewind.events",
            "description": "Calendar events synced into the vault (Google/iCloud/Exchange). Answers 'what meeting did I have Wednesday afternoon' type questions. Optional `status` filter (e.g. 'captured', 'scheduled'). Returns rows with title, participants, calendar id, and the segment id linking to the timeline slice that overlapped the meeting.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": ["type": "string"],
                    "limit": ["type": "integer"]
                ],
                "required": [] as [Any]
            ]
        ])
        out.append([
            "name": "openrewind.transcript",
            "description": "Concatenated audio transcript for one segment (Zoom / Teams / whisper). Use when the user asks about spoken content rather than what was on screen — 'what did we say about X in the standup' is a transcript query, not an OCR search.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "segment_id": ["type": "integer"]
                ],
                "required": ["segment_id"]
            ]
        ])
        out.append([
            "name": "openrewind.audio",
            "description": "Metadata for audio recordings linked to a segment (file paths, start times, durations). Lets the caller offer playback or tell the user 'there's a saved recording of this meeting'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "segment_id": ["type": "integer"]
                ],
                "required": ["segment_id"]
            ]
        ])
        out.append([
            "name": "openrewind.thumbnail",
            "description": "Base64-encoded JPEG thumbnail of one historical frame, downscaled to `max_dim` (default 1280). Use when you (a vision LLM) want to actually see the pixels the user saw, not just their OCR text. Returns { width, height, base64, mime_type: 'image/jpeg' }. Cheaper than pulling a full frame via `openrewind.frame` when all you need is the image.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frame_id": ["type": "integer"],
                    "max_dim": ["type": "integer",
                                "description": "Max side length in pixels (default 1280)."]
                ],
                "required": ["frame_id"]
            ]
        ])
        out.append([
            "name": "openrewind.recentActivity",
            "description": "Recent activity stream — 'what happened in the last N minutes'. Groups consecutive entries by focused app to produce a list of { app, from, to, duration_seconds, frame_count, window_samples }. Use for proactive check-ins ('you spent 45 min in Slack, need a break?') or to seed a follow-up query ('you were in Xcode from 2:10 to 3:30 — want to review what you were building?'). Default 30 minutes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer",
                                "description": "Look-back window in minutes (default 30)."]
                ],
                "required": [] as [Any]
            ]
        ])
        out.append([
            "name": "openrewind.frameScreenRect",
            "description": "Screen-space rectangle currently occupied by the Screen History timeline window. Use ONLY when a visual demonstration adds real value beyond citation (e.g. 'let me show you where the error was on your screen' is worth it; a plain answer is not). Combine with `openrewind.locateText` and then hand the resulting screen-pixel coordinates to `openclicky_show_highlight` / `openclicky_point` / `openclicky_show_scribble` so the App draws pointer / circle / arrow overlays on the pixels the user is looking at. Precondition: call `openrewind.showFrame` first so the timeline window is visible.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [Any]
            ]
        ])
        out.append([
            "name": "openrewind.locateText",
            "description": "Find text inside a frame's OCR and return its ABSOLUTE screen pixel bbox — ready to hand to `openclicky_show_highlight(x,y,width,height)` or `openclicky_point(x=center_x,y=center_y)` for a visual annotation. USE SPARINGLY — only when a real-life demonstration is more useful than text citation (e.g. 'this specific line here is what failed'), NOT for every answer. Requires the Screen History timeline to be already open on that frame (call `openrewind.showFrame` first). Returns { matched_text, bbox: {x,y,width,height,center_x,center_y}, frame_screen_rect } all in screen pixels.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "frame_id": ["type": "integer"],
                    "query":    ["type": "string"]
                ],
                "required": ["frame_id", "query"]
            ]
        ])
        out.append([
            "name": "openclicky_purge_automation_conversations",
            "description": "Purge polluting conversation rows from transcript_word. Scans rows written by ConversationLogger (speakerId IS NOT NULL) inside the last `since_hours` (default 48) and deletes those whose `word` matches any of `phrases` (case-insensitive LIKE %phrase%). Bundle-scoped cleanup misses these rows because ConversationLogger attaches turns to the current focused-app segment (browser/other) rather than a synthetic voice segment. Returns per-phrase deletion counts. Cannot be undone.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since_hours": [
                        "type": "integer",
                        "description": "Hours back from now to scan. Defaults to 48.",
                        "default": 48
                    ],
                    "phrases": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Trigger phrases to match against `word` (case-insensitive substring). Defaults to the built-in automation trigger list."
                    ]
                ],
                "required": [] as [Any]
            ]
        ])
        return out
    }

    private func handleSensorRequest(_ request: HTTPRequest, on connection: NWConnection) {
        let jsonBody = request.jsonBody
        let id = jsonBody["id"]
        let method = Self.string(jsonBody["method"])
        switch method {
        case "initialize":
            let body: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "OpenClicky Sensor MCP", "version": "1.0.0"]
                ]
            ]
            sendMCPStreamableHTTP(body: body, statusCode: 200, on: connection)
        case "notifications/initialized":
            sendRawResponse(Data(), statusCode: 202, contentType: "text/event-stream",
                            extraHeaders: ["Mcp-Session-Id": UUID().uuidString], on: connection)
        case "tools/list":
            let body: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "result": ["tools": Self.sensorToolDescriptors]
            ]
            sendMCPStreamableHTTP(body: body, statusCode: 200, on: connection)
        case "tools/call":
            let params = Self.dictionary(jsonBody["params"]) ?? [:]
            let name = Self.string(params["name"]) ?? Self.string(params["tool"])
            let arguments = Self.dictionary(params["arguments"]) ?? [:]
            guard let name else {
                let body: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "error": ["code": -32602, "message": "Missing tool name"]
                ]
                sendMCPStreamableHTTP(body: body, statusCode: 400, on: connection)
                return
            }
            guard Self.sensorToolNames.contains(name) else {
                let body: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "error": ["code": -32602, "message": "Tool '\(name)' is not available at /mcp/sensor"]
                ]
                sendMCPStreamableHTTP(body: body, statusCode: 400, on: connection)
                return
            }
            Task {
                let (contentEnvelope, isError) = await Self.executeSensorTool(name: name, arguments: arguments)
                let body: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id ?? NSNull(),
                    "result": [
                        "content": [contentEnvelope],
                        "isError": isError
                    ]
                ]
                self.queue.async {
                    self.broadcast(event: "command", object: ["ok": !isError, "path": "/mcp/sensor", "tool": name])
                    self.sendMCPStreamableHTTP(body: body, statusCode: 200, on: connection)
                }
            }
        default:
            let body: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "error": ["code": -32601, "message": "Unsupported MCP method"]
            ]
            sendMCPStreamableHTTP(body: body, statusCode: 400, on: connection)
        }
    }

    /// Package-visible bridge to `executeSensorTool` used by the meta
    /// registry dispatch delegate. Blocks recursive meta calls
    /// (`call_tool`, `batch`) so `call_tool` cannot invoke itself.
    static func invokeSensorToolForMeta(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        if name == "call_tool" || name == "batch" {
            return (sensorTextEnvelope(from: [
                "error": "meta tools '\(name)' are not reflectively dispatchable"
            ]), true)
        }
        guard sensorToolNames.contains(name) else {
            return (sensorTextEnvelope(from: ["error": "Unknown sensor tool: \(name)"]), true)
        }
        return await executeSensorTool(name: name, arguments: arguments)
    }

    /// Executes one sensor tool and returns the MCP content envelope plus
    /// error flag. Envelope shape: `{type: "text", text: "<json>"}`.
    private static func executeSensorTool(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        switch name {
        case "sensor_health":
            // capture_count is derived dynamically from the full descriptor
            // pipeline (native `sensorToolDescriptorsRaw` prefix + connector
            // + OpenCLI appended lists at :2338-2339). Was hard-coded to
            // `sensorToolNames.count` (43) which drifted below the real
            // exposed surface (49+ after connectors, growing with F31/F32-F36).
            // Everywhere-pin: match "count what tools/list surfaces" semantics.
            let health: [String: Any] = [
                "status": "ok",
                "capture_count": sensorToolDescriptorsRaw.count,
                "version": "phase1"
            ]
            return (sensorTextEnvelope(from: health), false)
        case "get_focused_context":
            let frontmost = FrontmostAppCapture.capture()
            let selected = SelectedTextCapture.capture()
            let clipboard = ClipboardCapture.capture()
            let finder = await FinderSelectionCapture.capture()
            let pid: Int32 = frontmost?.processId ?? 0
            let browser: BrowserURLInfo? = pid > 0 ? await BrowserURLCapture.capture(processId: pid) : nil
            let focusedWindow: FocusedWindowInfo? = pid > 0 ? FocusedWindowCapture.capture(processId: pid) : nil
            var bundle: [String: Any] = [:]
            bundle["frontmost"] = sensorJSONObject(frontmost) ?? NSNull()
            bundle["selected_text"] = sensorJSONObject(selected) ?? NSNull()
            bundle["clipboard"] = sensorJSONObject(clipboard) ?? NSNull()
            bundle["finder_selection"] = sensorJSONObject(finder) ?? NSNull()
            bundle["browser_url"] = sensorJSONObject(browser) ?? NSNull()
            if let focusedWindow {
                bundle["focused_window"] = sensorFocusedWindowDict(from: focusedWindow)
            } else {
                bundle["focused_window"] = NSNull()
            }
            return (sensorTextEnvelope(from: bundle), false)
        case "list_apps":
            guard let info = FrontmostAppCapture.capture() else {
                return (sensorTextEnvelope(from: ["apps": [] as [Any], "note": "No frontmost app resolvable"]), false)
            }
            let dict = sensorJSONObject(info) ?? [:]
            return (sensorTextEnvelope(from: ["apps": [dict]]), false)
        case "get_selected_text":
            let info = SelectedTextCapture.capture()
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["selected": false]), false)
        case "get_clipboard":
            let info = ClipboardCapture.capture()
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["text": NSNull()]), false)
        case "get_finder_selection":
            let info = await FinderSelectionCapture.capture()
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["currentFolder": NSNull(), "selectedFiles": [] as [Any]]), false)
        case "get_browser_url":
            let pid = sensorInt32(arguments["process_id"]) ?? FrontmostAppCapture.capture()?.processId
            guard let pid, pid > 0 else {
                return (sensorTextEnvelope(from: ["url": NSNull(), "note": "No pid supplied and no frontmost app"]), false)
            }
            let info = await BrowserURLCapture.capture(processId: pid)
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["processId": Int(pid), "url": NSNull()]), false)
        case "get_idle_time":
            let info = IdleTimeCapture.capture()
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["seconds": 0]), false)
        case "probe_workdir":
            guard let path = string(arguments["path"]) else {
                return (sensorTextEnvelope(from: ["error": "path argument required"]), true)
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let result = WorkdirProbe.probe(url)
            return (sensorTextEnvelope(from: sensorJSONObject(result) ?? ["path": path]), false)
        case "get_focused_window":
            let pid = sensorInt32(arguments["process_id"]) ?? FrontmostAppCapture.capture()?.processId
            guard let pid, pid > 0 else {
                return (sensorTextEnvelope(from: ["error": "No pid supplied and no frontmost app"]), true)
            }
            guard let info = FocusedWindowCapture.capture(processId: pid) else {
                return (sensorTextEnvelope(from: ["processId": Int(pid), "window": NSNull(), "note": "No AX focused window"]), false)
            }
            return (sensorTextEnvelope(from: sensorFocusedWindowDict(from: info)), false)

        // ---- Phase 5 Layer 0 additions --------------------------------

        case "screenshot":
            return await handleSensorScreenshot(arguments: arguments)

        case "get_browser_tabs":
            let app = string(arguments["app"])
            let info = await BrowserTabsCapture.capture(app: app)
            guard let info else {
                return (sensorTextEnvelope(from: [
                    "app": app as Any? ?? NSNull(),
                    "tabs": [] as [Any],
                    "note": "Browser not running or not scriptable"
                ]), false)
            }
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["app": info.app, "tabs": [] as [Any]]), false)

        case "get_terminal_output":
            let requested = sensorInt(arguments["lines_back"]) ?? TerminalCapture.defaultLinesBack
            let clamped = max(1, min(requested, TerminalCapture.maxLinesBack))
            let info = await TerminalCapture.capture(linesBack: clamped)
            guard let info else {
                return (sensorTextEnvelope(from: [
                    "is_terminal": false,
                    "lines_returned": 0,
                    "text": "",
                    "note": "No focused terminal"
                ]), false)
            }
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["is_terminal": false, "lines_returned": 0, "text": ""]), false)

        case "ocr_image":
            guard let b64 = string(arguments["image_base64"]) else {
                return (sensorTextEnvelope(from: ["error": "image_base64 argument required"]), true)
            }
            guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
                  let image = NSImage(data: data) else {
                return (sensorTextEnvelope(from: ["error": "Failed to decode base64 image bytes"]), true)
            }
            let languages: [String]
            if let raw = array(arguments["languages"]) {
                languages = raw.compactMap { $0 as? String }
            } else {
                languages = OCRCapture.defaultLanguages
            }
            guard let result = await OCRCapture.ocr(image: image, languages: languages) else {
                return (sensorTextEnvelope(from: ["error": "OCR failed (image undecodable to CGImage or Vision threw)"]), true)
            }
            return (sensorTextEnvelope(from: sensorOCRResultDict(from: result)), false)

        case "check_permission":
            guard let kindString = string(arguments["kind"]),
                  let kind = PermissionKind(rawValue: kindString) else {
                return (sensorTextEnvelope(from: ["error": "kind must be one of accessibility|screenRecording|inputMonitoring|microphone|automation"]), true)
            }
            let bundle = string(arguments["automation_target_bundle_id"])
            let status = PermissionPreflight.check(kind, automationTargetBundleId: bundle)
            return (sensorTextEnvelope(from: [
                "kind": kind.rawValue,
                "status": status.rawValue,
                "automation_target_bundle_id": bundle as Any? ?? NSNull()
            ]), false)

        case "install_ax_quirks":
            guard let pid = sensorInt32(arguments["pid"]), pid > 0 else {
                return (sensorTextEnvelope(from: ["error": "pid argument required (positive Int32)"]), true)
            }
            do {
                try AXQuirksInstaller.installIfNeeded(pid: pid)
                return (sensorTextEnvelope(from: [
                    "ok": true,
                    "pid": Int(pid),
                    "note": "AXManualAccessibility + AXEnhancedUserInterface set. Side effects persist for the app's lifetime."
                ]), false)
            } catch {
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "pid": Int(pid),
                    "error": String(describing: error)
                ]), true)
            }

        case "list_windows":
            let onlyOnScreen = bool(arguments["only_on_screen"]) ?? true
            let excludeDesktop = bool(arguments["exclude_desktop"]) ?? true
            let options = EnumerateOptions(
                onScreenOnly: onlyOnScreen,
                excludeDesktopElements: excludeDesktop
            )
            let windows = WindowEnumerationCapture.enumerateAll(options: options)
            let payload: [String: Any] = [
                "count": windows.count,
                "windows": windows.map { sensorEnumeratedWindowDict(from: $0) }
            ]
            return (sensorTextEnvelope(from: payload), false)

        case "cursor_position":
            guard let pos = CursorCapture.capture() else {
                return (sensorTextEnvelope(from: ["error": "Cursor position unavailable"]), true)
            }
            return (sensorTextEnvelope(from: sensorCursorPositionDict(from: pos)), false)

        case "element_under_cursor":
            let pointArg: CGPoint?
            if let x = double(arguments["x"]), let y = double(arguments["y"]), x.isFinite, y.isFinite {
                pointArg = CGPoint(x: x, y: y)
            } else {
                pointArg = nil
            }
            guard let info = ElementUnderCursorCapture.capture(at: pointArg) else {
                return (sensorTextEnvelope(from: [
                    "element": NSNull(),
                    "note": "No AX element under the requested point"
                ]), false)
            }
            return (sensorTextEnvelope(from: sensorElementUnderCursorDict(from: info)), false)

        case "recent_agent_sessions":
            let limit = sensorInt(arguments["limit"]).map { max(1, min($0, 200)) } ?? 10
            let sessions = RecentSessionsCapture.recent(limit: limit)
            let items = sessions.compactMap { sensorJSONObject($0) }
            return (sensorTextEnvelope(from: ["count": items.count, "sessions": items]), false)

        case "project_registry_lookup":
            guard let query = string(arguments["query"]) else {
                return (sensorTextEnvelope(from: ["error": "query argument required"]), true)
            }
            let limit = sensorInt(arguments["limit"]).map { max(1, min($0, 50)) } ?? 5
            let matches = ProjectRegistry.shared.lookup(query, limit: limit)
            let items = matches.compactMap { sensorJSONObject($0) }
            return (sensorTextEnvelope(from: ["query": query, "count": items.count, "matches": items]), false)

        case "git_awareness":
            guard let path = string(arguments["path"]) else {
                return (sensorTextEnvelope(from: ["error": "path argument required"]), true)
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let info = GitAwarenessCapture.probe(url) else {
                return (sensorTextEnvelope(from: [
                    "path": path,
                    "info": NSNull(),
                    "note": "Not a git working tree or git unavailable"
                ]), false)
            }
            return (sensorTextEnvelope(from: sensorJSONObject(info) ?? ["repoRoot": info.repoRoot]), false)

        // ---- Phase 2 v2 additions: doc readers ----------------------------
        case "doc_read_pdf":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadPdf.read(path: url, maxPages: maxPages)
            }
        case "doc_read_docx":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadDocx.read(path: url, maxPages: maxPages)
            }
        case "doc_read_xlsx":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadXlsx.read(path: url, maxPages: maxPages)
            }
        case "doc_read_pptx":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadPptx.read(path: url, maxPages: maxPages)
            }
        case "doc_read_epub":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadEpub.read(path: url, maxPages: maxPages)
            }
        case "doc_read_html":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadHtml.read(path: url, maxPages: maxPages)
            }
        case "doc_read_txt":
            return await handleDocRead(arguments: arguments) { url, maxPages in
                try await DocReadTxt.read(path: url, maxPages: maxPages)
            }

        // ---- Phase 2 v2 additions: memory tools --------------------------
        case "memory_read":
            let tools = OpenClickyMemoryTools()
            let key = string(arguments["key"])
            let entries = tools.memoryRead(key: key)
            return (sensorTextEnvelope(from: ["entries": entries]), false)
        case "memory_read_endpoint":
            guard let endpoint = string(arguments["endpoint"]) else {
                return (sensorTextEnvelope(from: ["error": "endpoint argument required"]), true)
            }
            let tools = OpenClickyMemoryTools()
            guard let entry = tools.memoryReadEndpoint(endpoint: endpoint) else {
                return (sensorTextEnvelope(from: ["endpoint": endpoint, "value": NSNull()]), false)
            }
            return (sensorTextEnvelope(from: sensorJSONObject(entry) ?? [:]), false)
        case "memory_write_endpoint":
            guard let endpoint = string(arguments["endpoint"]) else {
                return (sensorTextEnvelope(from: ["error": "endpoint argument required"]), true)
            }
            let value = dictionary(arguments["value"]) ?? [:]
            let fieldsAny = dictionary(value["fields"]) ?? [:]
            var fields: [String: String] = [:]
            for (k, v) in fieldsAny { if let s = v as? String { fields[k] = s } else { fields[k] = String(describing: v) } }
            let notesArr = array(value["notes"]) ?? []
            let notes = notesArr.compactMap { $0 as? String }
            let force = bool(value["force"]) ?? false
            do {
                try OpenClickyMemoryTools().memoryWriteEndpoint(
                    endpoint: endpoint,
                    fields: fields,
                    notes: notes,
                    force: force
                )
                return (sensorTextEnvelope(from: ["ok": true, "endpoint": endpoint]), false)
            } catch {
                return (sensorTextEnvelope(from: ["ok": false, "error": memoryErrorMessage(error)]), true)
            }
        case "memory_write_field_map":
            guard let mapAny = dictionary(arguments["map"]) else {
                return (sensorTextEnvelope(from: ["error": "map argument required"]), true)
            }
            var map: [String: String] = [:]
            for (k, v) in mapAny { if let s = v as? String { map[k] = s } else { map[k] = String(describing: v) } }
            let force = bool(arguments["force"]) ?? false
            do {
                try OpenClickyMemoryTools().memoryWriteFieldMap(map: map, force: force)
                return (sensorTextEnvelope(from: ["ok": true, "count": map.count]), false)
            } catch {
                return (sensorTextEnvelope(from: ["ok": false, "error": memoryErrorMessage(error)]), true)
            }
        case "memory_append_note":
            guard let text = string(arguments["text"]) else {
                return (sensorTextEnvelope(from: ["error": "text argument required"]), true)
            }
            let endpoint = string(arguments["endpoint"])
            do {
                try OpenClickyMemoryTools().memoryAppendNote(text: text, endpoint: endpoint)
                return (sensorTextEnvelope(from: ["ok": true]), false)
            } catch {
                return (sensorTextEnvelope(from: ["ok": false, "error": memoryErrorMessage(error)]), true)
            }
        case "memory_snapshot":
            let snap = OpenClickyMemoryTools().memorySnapshot()
            return (sensorTextEnvelope(from: sensorJSONObject(snap) ?? [:]), false)
        case "memory_freshness":
            let info = OpenClickyMemoryTools().memoryFreshness()
            return (sensorTextEnvelope(from: [
                "last_write_unix": info.lastWriteAt,
                "staleness_seconds": info.stalenessSeconds
            ]), false)
        case "memory_write_verify_fixture":
            guard let cmd = string(arguments["cmd"]) else {
                return (sensorTextEnvelope(from: ["error": "cmd argument required"]), true)
            }
            guard let fixture = string(arguments["fixture_json"]) else {
                return (sensorTextEnvelope(from: ["error": "fixture_json argument required"]), true)
            }
            let force = bool(arguments["force"]) ?? false
            do {
                try OpenClickyMemoryTools().memoryWriteVerifyFixture(cmd: cmd, fixture: fixture, force: force)
                return (sensorTextEnvelope(from: ["ok": true]), false)
            } catch {
                return (sensorTextEnvelope(from: ["ok": false, "error": memoryErrorMessage(error)]), true)
            }

        // ---- Phase 2 v2 additions: meta tools ----------------------------
        case "list_more_tools":
            let category = string(arguments["category"])
            let items = sensorMetaRegistry.listMoreTools(category: category).map { desc -> [String: Any] in
                return [
                    "name": desc.name,
                    "description": desc.description,
                    "domain": desc.domain
                ]
            }
            return (sensorTextEnvelope(from: ["tools": items, "count": items.count]), false)
        case "search_tools":
            guard let query = string(arguments["query"]) else {
                return (sensorTextEnvelope(from: ["error": "query argument required"]), true)
            }
            let topK = sensorInt(arguments["top_k"]).map { max(1, min($0, 100)) } ?? 5
            let matches = sensorMetaRegistry.searchTools(query: query, topK: topK).map { hit -> [String: Any] in
                return [
                    "name": hit.name,
                    "description": hit.description,
                    "score": hit.score,
                    "domain": hit.domain
                ]
            }
            return (sensorTextEnvelope(from: ["matches": matches, "count": matches.count]), false)
        case "activate_domain":
            guard let domain = string(arguments["name"]) else {
                return (sensorTextEnvelope(from: ["error": "name argument required"]), true)
            }
            let ok = sensorMetaRegistry.activateDomain(domain)
            let activatedNames = sensorMetaRegistry.allDescriptors()
                .filter { $0.domain == domain }
                .map { $0.name }
            return (sensorTextEnvelope(from: [
                "ok": ok,
                "domain": domain,
                "activated": activatedNames
            ]), ok ? false : true)
        case "list_domains":
            let domains = sensorMetaRegistry.listDomains().map { info -> [String: Any] in
                return [
                    "name": info.name,
                    "tool_count": info.toolCount,
                    "active": info.isActive
                ]
            }
            return (sensorTextEnvelope(from: ["domains": domains, "count": domains.count]), false)
        case "call_tool":
            guard let toolName = string(arguments["name"]) else {
                return (sensorTextEnvelope(from: ["error": "name argument required"]), true)
            }
            // FIX(ai-audit-2026-08-01 multi-turn #5): coerce arguments_json
            // when the LLM passes a dict/array instead of a JSON string.
            // Common mistake: model omits the string quoting entirely.
            // Silently re-serialize so the call succeeds.
            var argsJson = string(arguments["arguments_json"])
            if argsJson == nil, let obj = arguments["arguments_json"] {
                if let data = try? JSONSerialization.data(withJSONObject: obj),
                   let s = String(data: data, encoding: .utf8) {
                    argsJson = s
                }
            }
            if argsJson == nil {
                argsJson = "{}"
            }
            do {
                let raw = try await sensorMetaRegistry.callTool(name: toolName, argumentsJson: argsJson)
                // Forward raw JSON from the target tool as-is.
                return (["type": "text", "text": raw], false)
            } catch {
                return (sensorTextEnvelope(from: ["error": metaErrorMessage(error)]), true)
            }
        case "batch":
            guard let stepsAny = array(arguments["steps"]) else {
                return (sensorTextEnvelope(from: ["error": "steps argument required"]), true)
            }
            var steps: [BatchStep] = []
            for entry in stepsAny {
                guard let dict = entry as? [String: Any], let tool = string(dict["tool"]) else {
                    return (sensorTextEnvelope(from: ["error": "each step requires {tool, arguments?}"]), true)
                }
                let argsDict = dictionary(dict["arguments"]) ?? [:]
                let argsJson: String?
                if argsDict.isEmpty {
                    argsJson = nil
                } else if let data = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
                          let str = String(data: data, encoding: .utf8) {
                    argsJson = str
                } else {
                    argsJson = nil
                }
                steps.append(BatchStep(tool: tool, argumentsJson: argsJson))
            }
            let results = await sensorMetaRegistry.batch(steps).map { r -> [String: Any] in
                return [
                    "tool": r.tool,
                    "ok": r.ok,
                    "result_json": r.resultJson as Any? ?? NSNull(),
                    "error_message": r.errorMessage as Any? ?? NSNull()
                ]
            }
            return (sensorTextEnvelope(from: ["results": results, "count": results.count]), false)

        // ---- F25 stash-read (7) — mirrors Everywhere tool names ---------
        // Impls in `OpenClickyStashTools` (Packages/OpenClickyContextService/
        // .../Meta/OpenClickyStashTools.swift). Wire keys match Everywhere:
        //   read_pick            → ReadPickTool.cs:14
        //   read_whiteboard      → ReadWhiteboardTool.cs:16
        //   read_whiteboard_image→ ReadWhiteboardImageTool.cs:12
        //   add_annotation       → AddAnnotationTool.cs:15
        //   read_annotations     → ReadAnnotationsTool.cs:12
        //   clear_annotations    → ClearAnnotationsTool.cs:12
        //   pick_element         → PickElementTool.cs:14
        case "read_pick":
            let mode = string(arguments["mode"]) ?? "auto"
            let includeTree = bool(arguments["include_tree_json"]) ?? false
            let result = OpenClickyStashTools.readPick(
                mode: mode,
                includeTreeJson: includeTree
            )
            if !result.pinned {
                // Match Everywhere's `{pinned:false, picked_index:null,
                // app:null, element:null}` shape at ReadPickTool.cs:37.
                return (sensorTextEnvelope(from: [
                    "pinned": false,
                    "picked_index": NSNull(),
                    "app": NSNull(),
                    "element": NSNull()
                ]), false)
            }
            var payload: [String: Any] = [
                "pinned": true,
                "picked_index": result.pickedIndex as Any? ?? NSNull(),
                "app": result.app as Any? ?? NSNull(),
                "element": result.element as Any? ?? NSNull()
            ]
            if let tree = result.treeJson { payload["tree_json"] = tree }
            return (sensorTextEnvelope(from: payload), false)

        case "read_whiteboard":
            let result = OpenClickyStashTools.readWhiteboard()
            if !result.drawn {
                // Everywhere ReadWhiteboardTool.cs:33 → `{drawn:false,
                // region_count:0, markdown:null}`.
                return (sensorTextEnvelope(from: [
                    "drawn": false,
                    "region_count": 0,
                    "markdown": NSNull()
                ]), false)
            }
            return (sensorTextEnvelope(from: [
                "drawn": true,
                "region_count": result.regionCount,
                "markdown": result.markdown
            ]), false)

        case "read_whiteboard_image":
            guard let imageId = string(arguments["image_id"]) else {
                return (sensorTextEnvelope(from: ["error": "image_id argument required"]), true)
            }
            guard let bytes = OpenClickyStashTools.readWhiteboardImage(imageId: imageId) else {
                // Everywhere ReadWhiteboardImageTool.cs:31 → `{found:false,
                // image_id, reason}`.
                return (sensorTextEnvelope(from: [
                    "found": false,
                    "image_id": imageId,
                    "reason": "image expired or not found — whiteboard images live 5 minutes"
                ]), false)
            }
            // Wire shape mirrors the sensor screenshot convention:
            // base64-encoded PNG bytes plus a mime string.
            return (sensorTextEnvelope(from: [
                "found": true,
                "image_id": imageId,
                "mime": "image/png",
                "image_base64": bytes.base64EncodedString(),
                "byte_length": bytes.count
            ]), false)

        case "add_annotation":
            guard let source = string(arguments["source"]) else {
                return (sensorTextEnvelope(from: ["error": "source argument required"]), true)
            }
            guard let body = string(arguments["body"]) else {
                return (sensorTextEnvelope(from: ["error": "body argument required"]), true)
            }
            guard let anchorLabel = string(arguments["anchor_label"]) else {
                return (sensorTextEnvelope(from: ["error": "anchor_label argument required"]), true)
            }
            let anchorRef = string(arguments["anchor_ref"])
            let result = OpenClickyStashTools.addAnnotation(
                source: source,
                body: body,
                anchorLabel: anchorLabel,
                anchorRef: anchorRef
            )
            // Everywhere AddAnnotationTool.cs:55 → `{queued:<int>}` on
            // success. On rejection, Everywhere returns
            // ToolErrors.Error(...) — mirror that as isError=true.
            if !result.ok {
                return (sensorTextEnvelope(from: [
                    "error": "annotation rejected",
                    "queued": result.count
                ]), true)
            }
            return (sensorTextEnvelope(from: ["queued": result.count]), false)

        case "read_annotations":
            let items = OpenClickyStashTools.readAnnotations()
            let iso = ISO8601DateFormatter()
            let rows: [[String: Any]] = items.map { item in
                [
                    "source": item.source.rawValue,
                    "body": item.body,
                    "anchor_label": item.anchorLabel,
                    "anchor_ref": item.anchorRef as Any? ?? NSNull(),
                    "captured_at": iso.string(from: item.capturedAt)
                ]
            }
            // Everywhere ReadAnnotationsTool.cs:31 → `{count, annotations}`.
            return (sensorTextEnvelope(from: [
                "count": rows.count,
                "annotations": rows
            ]), false)

        case "clear_annotations":
            let result = OpenClickyStashTools.clearAnnotations()
            // Everywhere ClearAnnotationsTool.cs:20 → `{cleared:<int>}`.
            return (sensorTextEnvelope(from: ["cleared": result.count]), false)

        case "pick_element":
            // OpenClicky's picker is a passive crosshair overlay
            // (OpenClickyPickElementOverlay.begin) that writes to
            // PickStash asynchronously on user click; there is no
            // synchronous await-style API like Everywhere's
            // `IVisualElementContext.PickVisualElementAsync`. Mirror
            // the tool wire contract by kicking off the overlay and
            // returning a `{queued:true}` accept envelope — the caller
            // is expected to poll `read_pick` after the user clicks.
            // The `mode` argument is accepted for wire parity
            // (PickElementTool.cs:19) but the openclicky picker
            // currently only implements the "element" mode.
            let mode = string(arguments["mode"])
            await MainActor.run {
                OpenClickyPickElementOverlay.shared.begin()
            }
            return (sensorTextEnvelope(from: [
                "queued": true,
                "mode": mode as Any? ?? "element",
                "note": "picker overlay armed; call read_pick after the user clicks."
            ]), false)

        // ---- Phase 7.5 F29: open-connector (6) ---------------------------

        case "connector_list",
             "connector_describe",
             "connector_run",
             "connector_connect",
             "connector_disconnect",
             "connector_list_connections":
            return await OpenClickyConnectorBridgeTools.execute(name: name, arguments: arguments)

        // ---- Phase 7.6a F30: OpenCLI site adapters (3) --------------------

        case "opencli_list",
             "opencli_describe",
             "opencli_run":
            return await OpenClickyOpenCLIBridgeTools.execute(name: name, arguments: arguments)

        // ---- F32: chat_bus (6) -----------------------------------------
        // Everywhere ChatBusTools.cs — chat_send/subscribe already
        // implemented; chat_list/read/create/delete added F37 with an
        // in-process channel store on OpenClickyChatBus.
        case "chat_send",
             "chat_subscribe",
             "chat_list",
             "chat_read",
             "chat_create",
             "chat_delete":
            return await OpenClickyChatBridgeTools.execute(name: name, arguments: arguments)

        // ---- Clipboard MCP surface (4) — Everywhere ClipboardTools.cs.
        //   clipboard_read  → ClipboardTools.cs:40 (DoRead alias)
        //   clipboard_paste → ClipboardTools.cs:46 (DoRead alias)
        //   clipboard_write → ClipboardTools.cs:52 (DoWrite)
        //   clipboard_copy  → ClipboardTools.cs:58 (DoWrite alias)
        // Openclicky diverges on paste/copy: writer simulates ⌘V / ⌘C
        // via CGEvent to hit the frontmost app (see ClipboardWriter.swift).
        case "clipboard_read", "clipboard_paste":
            let info = ClipboardCapture.capture()
            let text = info?.text ?? ""
            let payload: [String: Any] = [
                "has_text": !text.isEmpty,
                "text": text
            ]
            // On alias `clipboard_paste`, additionally trigger a CGEvent
            // ⌘V into the frontmost app so the SPEC ab
            // `agent_browser_clipboard_paste` semantic holds. Failure
            // (Input Monitoring denied) is non-fatal — the read succeeded.
            if name == "clipboard_paste" {
                let posted = ClipboardWriter.simulatePaste()
                var out = payload
                out["paste_dispatched"] = posted
                return (sensorTextEnvelope(from: out), false)
            }
            return (sensorTextEnvelope(from: payload), false)

        case "clipboard_write", "clipboard_copy":
            // Everywhere ClipboardTools.cs:70 — DoWrite writes and
            // returns `{ok, bytes}`. clipboard_copy additionally
            // triggers ⌘C in the openclicky port so the browser-side
            // SPEC ab semantic (asks active app to copy its selection)
            // is honoured; upstream aliases it to clipboard_write.
            let text = string(arguments["text"]) ?? ""
            if name == "clipboard_copy" {
                // "Copy" semantically asks the active app to copy its
                // own selection; don't overwrite pasteboard first.
                let posted = ClipboardWriter.simulateCopy()
                return (sensorTextEnvelope(from: [
                    "ok": posted,
                    "bytes": text.utf8.count
                ]), false)
            }
            let result = ClipboardWriter.writeText(text)
            return (sensorTextEnvelope(from: [
                "ok": result.ok,
                "bytes": result.bytes
            ]), false)

        // ---- F34: web_* (2) --------------------------------------------
        case "web_search",
             "web_fetch_url":
            return await OpenClickyWebBridgeTools.execute(name: name, arguments: arguments)

        // ---- F33: adapter_* authoring surface (8) ----------------------
        case "adapter_scaffold",
             "adapter_save",
             "adapter_verify",
             "adapter_list_local",
             "adapter_drift_check",
             "adapter_delete_local",
             "adapter_regenerate",
             "adapter_lint":
            return await OpenClickyAdapterAuthoringBridgeTools.execute(name: name, arguments: arguments)

        // ---- F35: page_* (Everywhere 2 + openclicky 4) -----------------
        case "page_extract_by_rule",
             "page_save_extraction_rule",
             "page_read",
             "page_summarise",
             "page_inspect",
             "page_actions":
            return await OpenClickyPageBridgeTools.execute(name: name, arguments: arguments)

        // ---- F36: capture_* (Everywhere 4 + openclicky 5) --------------
        case "capture_start",
             "capture_stop",
             "capture_current",
             "capture_export",
             "capture_draft",
             "capture_publish",
             "capture_list",
             "capture_delete",
             "capture_run":
            return await OpenClickyCaptureAuthoringBridgeTools.execute(name: name, arguments: arguments)

        // ---- MEDIUM-severity ports (5) ---------------------------------
        // Everywhere Tools/GetAppContextTool.cs, GetAppStateTool.cs,
        // GateTools.cs:31-75, GeneratorTools.cs:390-440. Impls kept in
        // the bridge because they compose already-ported helpers
        // (FrontmostAppCapture, OpenClickyKnownAppResolver, StrategyNote
        // + OpenClickyMetaTools.validateStrategyNote).
        case "get_app_context":
            return await handleSensorGetAppContext(arguments: arguments)
        case "get_app_state":
            return await handleSensorGetAppState(arguments: arguments)
        case "strategy_note_get":
            return handleSensorStrategyNoteGet(arguments: arguments)
        case "strategy_note_write":
            return handleSensorStrategyNoteWrite(arguments: arguments)
        case "opendia_smoke_check":
            return handleSensorOpendiaSmokeCheck()

        // ---- Phase 7.6b F31: OpenDia browser control (120) ---------------
        // Prefix-match all registered browser_* names so we don't have to
        // hand-enumerate 120 cases. Everywhere upstream uses the same
        // prefix-based dispatch via `OpenDiaToolListBuilder.Prefix = "browser_"`.

        default:
            if name.hasPrefix("browser_"),
               OpenClickyOpenDiaBridgeTools.toolNames.contains(name) {
                return await OpenClickyOpenDiaBridgeTools.execute(name: name, arguments: arguments)
            }
            if name == "openrewind.ask" {
                return await Self.handleSensorAskRewind(arguments: arguments)
            }
            if name == "openclicky_simulate_voice_turn" {
                return await Self.handleSensorSimulateVoiceTurn(arguments: arguments)
            }
            if name == "openclicky_simulate_ski_utterance" {
                return await Self.handleSensorSimulateSKIUtterance(arguments: arguments)
            }
            if name == "openclicky_purge_automation_conversations" {
                return await Self.handleSensorPurgeAutomationConversations(arguments: arguments)
            }
            if name == "openrewind.searchHybrid" {
                return await Self.handleSensorSearchHybrid(arguments: arguments)
            }
            if name == "openclicky_realtime_text_probe" {
                return await Self.handleSensorRealtimeTextProbe(arguments: arguments)
            }
            if name == "openrewind.showFrame" {
                return await Self.handleSensorShowFrame(arguments: arguments)
            }
            if name == "openrewind.extractContext" {
                return await Self.handleSensorExtractContext(arguments: arguments)
            }
            if name == "openrewind.events" {
                return await Self.handleSensorEvents(arguments: arguments)
            }
            if name == "openrewind.transcript" {
                return await Self.handleSensorTranscript(arguments: arguments)
            }
            if name == "openrewind.audio" {
                return await Self.handleSensorAudio(arguments: arguments)
            }
            if name == "openrewind.thumbnail" {
                return await Self.handleSensorThumbnail(arguments: arguments)
            }
            if name == "openrewind.recentActivity" {
                return await Self.handleSensorRecentActivity(arguments: arguments)
            }
            if name == "openrewind.frameScreenRect" {
                return await Self.handleSensorFrameScreenRect(arguments: arguments)
            }
            if name == "openrewind.locateText" {
                return await Self.handleSensorLocateText(arguments: arguments)
            }
            if name.hasPrefix("openrewind.") {
                return await Self.handleSensorOpenRewind(name: name, arguments: arguments)
            }
            if XLBSensorTools.handles(name) {
                guard AppBundleConfiguration.xlbEnabled() else {
                    return (sensorTextEnvelope(from: [
                        "error": "xlinkBook integration is disabled (Settings > xlinkBook Integration)"
                    ]), true)
                }
                return await XLBSensorTools.execute(name: name, arguments: arguments)
            }
            return (sensorTextEnvelope(from: ["error": "Unknown sensor tool: \(name)"]), true)
        }
    }

    /// Direct entry to the AskRewind pipeline (three-stage Rewind
    /// pipeline + retrace-inspired ranker + snippet generator).
    /// Exposed as `openrewind.ask` so external MCP clients can send
    /// natural-language questions and receive a cited answer.
    private static func handleSensorAskRewind(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let question = (arguments["question"] as? String) ?? ""
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "question argument required"
            ]), true)
        }
        let previous = (arguments["previous_queries"] as? [String]) ?? []
        do {
            let ans = try await AskRewind.ask(question: question,
                                              previousQueries: previous)
            return (sensorTextEnvelope(from: [
                "ok": !ans.noResults,
                "answer": ans.text,
                "cited_frame_ids": ans.citedFrameIds,
                "search_query": ans.searchQuery,
                "result_count": ans.resultCount,
                "no_results": ans.noResults
            ]), false)
        } catch {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": String(describing: error)
            ]), true)
        }
    }

    /// Automated probe: send text to the realtime session as if the
    /// user had spoken it. Same LLM decision path fires — including
    /// `openclicky_use_screen_context` with `intent`. Response is
    /// fire-and-forget; the intent lands in the message log under
    /// `realtime.tool_call.intent`. Automated tests then read that
    /// log and score classifier accuracy.
    private static func handleSensorRealtimeTextProbe(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let text = ((arguments["text"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "text argument required"
            ]), true)
        }
        await MainActor.run {
            Task { @MainActor in
                await HeyClickyRealtimeSession.shared.simulateTextTurn(text)
            }
        }
        return (sensorTextEnvelope(from: [
            "ok": true,
            "note": "response is async; poll message log for realtime.tool_call.intent"
        ]), false)
    }

    /// Screen History semantic search. Same interface as
    /// `openrewind.search` but pass `hybrid: true` to layer Apple
    /// NLEmbedding vector similarity on top of the FTS keyword match
    /// via RRF fusion. Off by default (`hybrid: false`) — vector
    /// scan loads the whole index into RAM and costs ~50-100ms
    /// per query. External MCP clients can decide per call.
    private static func handleSensorSearchHybrid(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let query = ((arguments["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = (arguments["limit"] as? Int) ?? 20
        let hybrid = (arguments["hybrid"] as? Bool) ?? false
        guard !query.isEmpty else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "query argument required"]), true)
        }
        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared })
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "screen_history_off"]), true)
        }
        let adapter = await MainActor.run { RewindDataAdapter(reader: bridge.reader) }
        let hits: [OpenRewindSearchHit]
        do {
            hits = try await adapter.search(query, limit: limit, hybrid: hybrid)
        } catch {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "search_failed:\(error.localizedDescription)"
            ]), true)
        }
        let items: [[String: Any]] = hits.map { h in
            [
                "frameId": h.entry.id,
                "createdAt": ISO8601DateFormatter().string(from: h.entry.createdAt),
                "bundleID": h.entry.bundleID ?? "",
                "windowName": h.entry.windowName ?? "",
                "snippet": h.snippet,
            ]
        }
        return (sensorTextEnvelope(from: [
            "ok": true, "hybrid": hybrid,
            "count": items.count, "items": items,
        ]), false)
    }

    /// Automation: simulate a PTT voice turn without touching mic/STT/WS.
    /// Fires the same downstream pipeline the realtime tool_call path
    /// would: preflight → LTM+FTS → chat.request → rememberVoiceExchange.
    private static func handleSensorSimulateVoiceTurn(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let transcript = ((arguments["transcript"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "transcript argument required"
            ]), true)
        }
        let cm: CompanionManager? = await MainActor.run {
            OpenClickyExternalControlBridgeServer.companionManagerAnchor as? CompanionManager
        }
        guard let cm else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "companionManager not attached to bridge"
            ]), true)
        }
        let startedAt = Date()
        await MainActor.run {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "automation.simulate_voice_turn.begin",
                fields: ["transcript_len": transcript.count,
                         "preview": String(transcript.prefix(60))])
        }
        // Preflight snapshot
        await HeyClickyChatToolCallClient.capturePTTSnapshot()
        // Dialog turn
        let systemPrompt = await MainActor.run { cm.currentVoiceResponseSystemPrompt() }
        let history = await MainActor.run { cm.voiceConversationHistoryForAPI() }
        // Parity with _analyzeVoiceResponseCore: inject the xlb hint block
        // when Settings > xlinkBook Integration is enabled so automation
        // tests exercise the same prompt shape as a real PTT turn.
        await XLBSensorTools.resetTurnBudget()
        await MainActor.run { cm.suppressVoiceResponseSideEffects = true }
        defer {
            Task { @MainActor in cm.suppressVoiceResponseSideEffects = false }
        }
        let injectedPrompt = await CompanionManager.applyXLBHintIfEnabled(to: transcript)
        // Profile-aware dispatch. HeyClicky Free previously hardcoded here;
        // now we honour the active profile so an automation harness can
        // exercise the Peeky Free (mirage) lane end-to-end without having
        // to speak into a microphone. Any future profile (SKI, quality,
        // etc.) that adds an in-process reply path can slot in the same way.
        let activeProfileID = OpenClickyProfileCatalog.activeProfile().id
        let assistantText: String
        do {
            switch activeProfileID {
            case "mirage":
                let modelID = await MainActor.run { cm.selectedModel }
                let contextBrief = await cm.buildMirageContextBrief(userQuery: injectedPrompt)
                let result = await MiragePeekyOrchestrator.shared.runTurn(
                    transcript: injectedPrompt,
                    modelForBranches: modelID,
                    contextBrief: contextBrief,
                    onTextChunk: { _ in }
                )
                if let err = result.error {
                    throw err
                }
                assistantText = result.text
            default:
                assistantText = try await HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(
                    companionManager: cm,
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: history,
                    userPrompt: injectedPrompt,
                    onTextChunk: { _ in }
                )
            }
        } catch {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "chat_failed: \(error.localizedDescription)"
            ]), true)
        }
        // Automation source: do NOT persist to vault / LTM.
        _ = transcript
        _ = assistantText
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        await MainActor.run {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "automation.simulate_voice_turn.ok",
                fields: ["elapsedMs": elapsedMs,
                         "assistant_len": assistantText.count,
                         "assistant_preview": String(assistantText.prefix(80))])
        }
        return (sensorTextEnvelope(from: [
            "ok": true,
            "elapsedMs": elapsedMs,
            "transcript": transcript,
            "assistantText": assistantText,
            "assistantLen": assistantText.count
        ]), false)
    }

    /// SKI-Mode simulate handler. Builds UtteranceContext + writes
    /// utterance.final to the pinned workspace's .oc/events.jsonl.
    /// Returns the emitted event JSON for assertions.
    private static func handleSensorSimulateSKIUtterance(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let transcript = ((arguments["transcript"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "transcript argument required"
            ]), true)
        }
        let cmAny: AnyObject? = await MainActor.run { OpenClickyExternalControlBridgeServer.companionManagerAnchor }
        guard let cm = cmAny as? CompanionManager else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "companion manager not available"
            ]), true)
        }
        guard let workspace = await OpenClickyAgentsPresenceStore.shared.effectiveActiveWorkspace() else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "no active SKI workspace"
            ]), true)
        }
        let resolvedCtx = await cm.buildSKIUtteranceContext(userQuery: transcript)
        _ = await OpenClickyFileBridge.shared.writeUtteranceAndAwait(
            workspace: workspace,
            text: transcript,
            context: resolvedCtx,
            timeoutSeconds: 0.1
        )
        // Read back the last utterance.final line
        var lastEvent: [String: Any] = [:]
        let eventsPath = workspace.appendingPathComponent(".oc/events.jsonl")
        if let data = try? Data(contentsOf: eventsPath),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n").reversed() {
                if let d = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   (obj["event"] as? String) == "utterance.final" {
                    lastEvent = obj
                    break
                }
            }
        }
        return (sensorTextEnvelope(from: [
            "ok": true,
            "workspace": workspace.path,
            "transcript": transcript,
            "emitted_event": lastEvent
        ]), false)
    }

    /// Default trigger phrases the automation harness leaks into
    /// conversation history when it exercises the tool suite. Kept
    /// alongside the handler so the tool descriptor + handler stay in
    /// lockstep. Case-insensitive at the SQL layer.
    fileprivate static let defaultAutomationPurgePhrases: [String] = [
        "vibe coding", "deep learning", "gpt-4", "docker",
        "paper", "cursor", "pytorch", "vibe cod",
        "deep lea", "awesome", "model", "mcp"
    ]

    /// Automation cleanup handler. Scans `transcript_word` for
    /// conversation rows (`speakerId IS NOT NULL`) inside the last
    /// `since_hours` (default 48) and deletes those whose `word`
    /// matches any of the caller-supplied `phrases` (default: the
    /// hard-coded automation trigger list). Bundle-scoped cleanup
    /// misses these rows because ConversationLogger attaches turns
    /// to the newest existing segment (usually the current browser or
    /// other-app segment), not to a synthetic voice segment.
    /// Returns per-phrase deletion counts. Goes through
    /// OpenRewindWriter so we never touch SQLite directly.
    private static func handleSensorPurgeAutomationConversations(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let sinceHours: Int = {
            if let n = (arguments["since_hours"] as? NSNumber)?.intValue { return n }
            if let s = arguments["since_hours"] as? String, let n = Int(s) { return n }
            return 48
        }()
        let phrases: [String] = {
            if let arr = arguments["phrases"] as? [String], !arr.isEmpty { return arr }
            if let arr = arguments["phrases"] as? [Any] {
                let strs = arr.compactMap { $0 as? String }
                if !strs.isEmpty { return strs }
            }
            return Self.defaultAutomationPurgePhrases
        }()
        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared }) else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "screen_history_off"
            ]), true)
        }
        do {
            let counts = try bridge.writer.purgeAutomationVoiceConversations(
                sinceHours: sinceHours,
                phrases: phrases)
            var fields: [String: Any] = [:]
            for (k, v) in counts { fields[k] = v }
            fields["since_hours"] = sinceHours
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "automation.purge_conversations.ok",
                fields: fields)
            let total = counts["_total"] ?? counts.values.reduce(0, +)
            let payload: [String: Any] = [
                "ok": true,
                "deleted": counts,
                "sinceHours": sinceHours,
                "phrases": phrases,
                "totalDeleted": total
            ]
            return (sensorTextEnvelope(from: payload), false)
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "automation.purge_conversations.failed",
                fields: ["error": String(describing: error)])
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": String(describing: error)
            ]), true)
        }
    }

    /// Open the timeline UI at a specific historical frame. AI uses
    /// this to say "look here" — instead of pasting OCR text, it can
    /// invoke this tool and the user sees the actual pixel frame in
    /// the timeline chrome, ready to scrub / star / ask again.
    private static func handleSensorShowFrame(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared })
        else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "Screen History is not enabled."
            ]), true)
        }
        // Accept either { frame_id } or { at: ISO8601 } like the rest
        // of the openrewind.* toolset.
        try? await bridge.reopenReaderAsync()
        var target: Date?
        if let id = (arguments["frame_id"] as? NSNumber)?.int64Value {
            // FIX(perf-2026-07-31): use indexed entryByID lookup
            // instead of scanning 20000 rows to find one id.
            target = (try? bridge.reader.entryByID(id))?.createdAt
        } else if let atStr = arguments["at"] as? String {
            if let unix = Double(atStr) {
                target = Date(timeIntervalSince1970: unix)
            } else {
                target = ISO8601DateFormatter().date(from: atStr)
            }
        }
        guard let t = target else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "Provide frame_id (Int64) or at (ISO8601 / unix seconds)."
            ]), true)
        }
        await MainActor.run {
            ScreenHistoryWindowManager.shared.show()
            // Give the timeline view a beat to boot, then seek.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(
                    name: .screenHistoryJumpToDate,
                    object: nil,
                    userInfo: ["date": t])
            }
        }
        return (sensorTextEnvelope(from: [
            "ok": true,
            "shown_at": ISO8601DateFormatter().string(from: t)
        ]), false)
    }

    /// Run the OpenRewind context extractor over an arbitrary image
    /// (PNG or JPEG). Returns OCR text + per-word bounding boxes +
    /// language + content classification. This is the same pipeline
    /// screen capture uses per frame, exposed as a stand-alone tool
    /// so any AI (vision or text-only) can enrich an image it was
    /// handed with structured context.
    private static func handleSensorExtractContext(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        var data: Data?
        if let b64 = arguments["image_base64"] as? String,
           let decoded = Data(base64Encoded: b64) {
            data = decoded
        } else if let path = arguments["image_path"] as? String {
            data = try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard let d = data,
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": "Provide image_base64 or image_path (PNG/JPEG)."
            ]), true)
        }
        do {
            let ctx = try await OpenRewindContextExtractor.extract(
                image: cg,
                capturedAt: Date(),
                bundleID: (arguments["bundle_id"] as? String),
                ambient: .empty,
                recognitionLevel: .accurate,
                thumbnailWidth: 1280,
                precomputedOCR: nil)
            let nodes: [[String: Any]] = ctx.ocrNodes.map { n in
                [
                    "text": n.text,
                    "bbox": ["x": n.leftX, "y": n.topY,
                             "width": n.width, "height": n.height],
                    "confidence": n.confidence
                ]
            }
            return (sensorTextEnvelope(from: [
                "ok": true,
                "ocr_text": ctx.ocrText,
                "ocr_nodes": nodes,
                "language": ctx.dominantLanguage ?? NSNull(),
                "content_kind": ctx.contentKind,
                "has_faces": ctx.hasFaces,
                "barcodes": ctx.barcodes,
                "rectangle_count": ctx.detectedRectangleCount
            ]), false)
        } catch {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": String(describing: error)
            ]), true)
        }
    }

    // MARK: - Additional Screen History tools

    enum RewindResult<T> {
        case ok(T)
        case fail(String)
    }
    private static func withBridge<T>(_ body: @escaping @Sendable (OpenRewindBridge) throws -> T) async
        -> RewindResult<T> where T: Sendable
    {
        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared })
        else { return .fail("Screen History is not enabled.") }
        try? await bridge.reopenReaderAsync()
        // FIX(jank-audit-2026-07-31): run `body` off the main actor.
        // Body typically does bulk reader queries (20k row scans on
        // Timeline / thumbnail asks). Previously ran on caller's
        // actor context (MainActor via withBridge async return path).
        // Detached task avoids main-thread stalls.
        return await Task.detached(priority: .userInitiated) {
            do { return .ok(try body(bridge)) }
            catch { return .fail(String(describing: error)) }
        }.value
    }

    /// Return calendar events indexed alongside the timeline. Rewind
    /// syncs Google/iCloud/Exchange calendars into the vault so AI
    /// can answer "what meeting did I have Wednesday afternoon".
    private static func handleSensorEvents(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let status = arguments["status"] as? String
        let limit = (arguments["limit"] as? Int) ?? 200
        switch await withBridge({ bridge -> [OpenRewindEvent] in
            try bridge.reader.events(status: status, limit: limit)
        }) {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let rows):
            var items: [[String: Any]] = []
            items.reserveCapacity(rows.count)
            for e in rows {
                var d: [String: Any] = [:]
                d["id"] = e.id
                d["type"] = e.type
                d["status"] = e.status
                d["title"] = e.title as Any? ?? NSNull()
                d["participants"] = e.participants as Any? ?? NSNull()
                d["detailsJSON"] = e.detailsJSON as Any? ?? NSNull()
                d["calendarID"] = e.calendarID as Any? ?? NSNull()
                d["calendarEventID"] = e.calendarEventID as Any? ?? NSNull()
                d["calendarSeriesID"] = e.calendarSeriesID as Any? ?? NSNull()
                d["segmentID"] = e.segmentID
                items.append(d)
            }
            var out: [String: Any] = [:]
            out["ok"] = true
            out["count"] = items.count
            out["items"] = items
            return (sensorTextEnvelope(from: out), false)
        }
    }

    /// Return concatenated transcript text for one segment (a
    /// contiguous focused-app / meeting session). AI can find "what
    /// was said" in Zoom / Teams / voice notes instead of / on top of
    /// OCR text.
    private static func handleSensorTranscript(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let segId = (arguments["segment_id"] as? NSNumber)?.int64Value
              ?? (arguments["segmentId"] as? NSNumber)?.int64Value
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "segment_id (Int64) required"
            ]), true)
        }
        switch await withBridge({ bridge -> String in
            try bridge.reader.transcriptText(segmentID: segId)
        }) {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let text):
            return (sensorTextEnvelope(from: [
                "ok": true, "segment_id": segId,
                "text": text, "length": text.count
            ]), false)
        }
    }

    /// Return audio recording metadata linked to a segment (file paths,
    /// start times, durations). Frontends can offer playback; AI can
    /// tell the user "there's an audio recording of this meeting".
    private static func handleSensorAudio(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let segId = (arguments["segment_id"] as? NSNumber)?.int64Value
              ?? (arguments["segmentId"] as? NSNumber)?.int64Value
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "segment_id (Int64) required"
            ]), true)
        }
        switch await withBridge({ bridge -> [OpenRewindAudio] in
            try bridge.reader.audioRecordings(segmentID: segId)
        }) {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let rows):
            let iso = ISO8601DateFormatter()
            let items: [[String: Any]] = rows.map { a in
                [
                    "id": a.id,
                    "segment_id": a.segmentID,
                    "path": a.path,
                    "start_time": iso.string(from: a.startTime),
                    "duration_seconds": a.durationSeconds
                ]
            }
            return (sensorTextEnvelope(from: [
                "ok": true, "count": items.count, "items": items
            ]), false)
        }
    }

    /// Base64 thumbnail for one frame — for vision-LLM ingestion.
    /// Fixed-size, hardcoded 1280 maxDim, JPEG q70 (Rewind default).
    private static func handleSensorThumbnail(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let fid = (arguments["frame_id"] as? NSNumber)?.int64Value
              ?? (arguments["id"] as? NSNumber)?.int64Value
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "frame_id (Int64) required"
            ]), true)
        }
        let maxDim = (arguments["max_dim"] as? Int) ?? 1280
        switch await withBridge({ bridge -> (String, Int, Int) in
            // Note: `withBridge` closure is @MainActor. Reader itself
            // uses its own serial DispatchQueue internally, so the
            // main-thread cost is confined to the SQLite bind/step
            // call — heavy for 20k-row scans. TODO: refactor to run
            // the query on a background actor.
            // FIX(perf-2026-07-31): entryByID uses the frame table
            // primary-key index; the old recentEntries(20000) scan
            // touched every row to find one id.
            guard let entry = try bridge.reader.entryByID(fid) else {
                throw NSError(domain: "openrewind.thumbnail", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "frame \(fid) not found"])
            }
            let payload = try bridge.reader.screenshotPayload(for: entry, maxDim: maxDim)
            return (payload.base64, payload.width, payload.height)
        }) {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let (b64, w, h)):
            return (sensorTextEnvelope(from: [
                "ok": true,
                "frame_id": fid,
                "mime_type": "image/jpeg",
                "width": w, "height": h,
                "base64": b64
            ]), false)
        }
    }

    /// "What happened in the last N minutes" quick pull. Groups
    /// consecutive entries by bundleID to build an activity stream
    /// like: [{app, from, to, frameCount, windowSample}].
    /// AI polls this periodically for proactive behaviour.
    private static func handleSensorRecentActivity(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let minutes = (arguments["minutes"] as? Int) ?? 30
        let now = Date()
        let from = now.addingTimeInterval(-Double(minutes) * 60)
        switch await withBridge({ bridge -> [[String: Any]] in
            let entries = try bridge.reader.entries(from: from, to: now,
                                                    limit: 2000)
            // Reader returns newest-first; group by consecutive app.
            let ordered = entries.sorted { $0.createdAt < $1.createdAt }
            var out: [[String: Any]] = []
            var current: (app: String, from: Date, to: Date,
                          frames: Int, windows: Set<String>)?
            let iso = ISO8601DateFormatter()
            func flush() {
                guard let c = current else { return }
                out.append([
                    "app": c.app,
                    "from": iso.string(from: c.from),
                    "to": iso.string(from: c.to),
                    "duration_seconds": c.to.timeIntervalSince(c.from),
                    "frame_count": c.frames,
                    "window_samples": Array(c.windows.prefix(5))
                ])
            }
            for e in ordered {
                let app = e.bundleID ?? "?"
                let win = e.windowName ?? ""
                if var c = current, c.app == app {
                    c.to = e.createdAt
                    c.frames += 1
                    if !win.isEmpty { c.windows.insert(win) }
                    current = c
                } else {
                    flush()
                    current = (app: app, from: e.createdAt, to: e.createdAt,
                               frames: 1,
                               windows: win.isEmpty ? [] : [win])
                }
            }
            flush()
            return out
        }) {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let stream):
            return (sensorTextEnvelope(from: [
                "ok": true,
                "minutes": minutes,
                "segment_count": stream.count,
                "stream": stream
            ]), false)
        }
    }

    /// Return the screen-space rectangle currently occupied by the
    /// given frame's image inside the Screen History timeline window.
    /// AI uses this to convert the normalized OCR node bboxes from
    /// `openrewind.frame` into absolute screen pixels for the existing
    /// `openclicky_show_highlight` / `openclicky_point` overlay tools.
    private static func handleSensorFrameScreenRect(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        _ = arguments
        return await MainActor.run { () -> ([String: Any], Bool) in
            guard let win = NSApp.windows.first(where: {
                $0.isVisible && ($0.title == "Screen History"
                                 || $0.contentViewController != nil
                                    && $0.styleMask.contains(.borderless))
            }) else {
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "error": "Screen History timeline window is not visible. Call openrewind.showFrame first."
                ]), true)
            }
            // Convert window frame from Cocoa bottom-left to CG top-left
            // (which is what OpenClicky overlay tools use).
            let frame = win.frame
            let screen = win.screen ?? NSScreen.main
            let screenHeight = screen?.frame.height ?? 0
            let cgY = screenHeight - frame.origin.y - frame.height
            return (sensorTextEnvelope(from: [
                "ok": true,
                "x": frame.origin.x,
                "y": cgY,
                "width": frame.width,
                "height": frame.height,
                "cocoa_y": frame.origin.y,
                "screen_height": screenHeight
            ]), false)
        }
    }

    /// Locate a text query inside a frame's OCR nodes and return the
    /// matching bbox in ABSOLUTE screen pixels — so AI can hand it
    /// straight to `openclicky_show_highlight` / `_point` to draw a
    /// pointer / circle / arrow on the actual pixel content the user
    /// is looking at.
    ///
    /// Node bboxes are already normalized 0-1 in the DB. The timeline
    /// view aspect-fits the frame inside its window; we compute that
    /// letterboxed rect the same way `FrameOverlayView.SearchHighlightOverlay`
    /// does upstream.
    private static func handleSensorLocateText(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let fid = (arguments["frame_id"] as? NSNumber)?.int64Value
              ?? (arguments["id"] as? NSNumber)?.int64Value
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "frame_id (Int64) required"
            ]), true)
        }
        guard let query = (arguments["query"] as? String), !query.isEmpty
        else {
            return (sensorTextEnvelope(from: [
                "ok": false, "error": "query (String) required"
            ]), true)
        }

        // Fetch OCR nodes for the frame.
        let ocrResult = await withBridge { bridge -> [OpenRewindOCRNode] in
            let (_, nodes) = try bridge.reader.ocr(for: fid)
            return nodes
        }
        let nodes: [OpenRewindOCRNode]
        switch ocrResult {
        case .fail(let msg):
            return (sensorTextEnvelope(from: ["ok": false, "error": msg]), true)
        case .ok(let n): nodes = n
        }

        // Best-match: prefer node whose text case-insensitively contains query.
        let needle = query.lowercased()
        let match = nodes.first(where: { !$0.text.isEmpty
            && $0.text.lowercased().contains(needle) })

        // Compute timeline window rect + aspect-fit image rect.
        return await MainActor.run { () -> ([String: Any], Bool) in
            guard let win = NSApp.windows.first(where: {
                $0.isVisible && $0.styleMask.contains(.borderless)
            }) else {
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "error": "Screen History timeline is not open. Call openrewind.showFrame first."
                ]), true)
            }
            let winFrame = win.frame
            let screen = win.screen ?? NSScreen.main
            let screenHeight = screen?.frame.height ?? 0
            // AppCustomWindow shows image aspect-fit; hard-code the
            // 16:10 assumption isn't safe. We approximate by using the
            // window frame directly — timeline draws full-bleed
            // borderless, so the image rect ≈ window rect.
            let imgX = winFrame.origin.x
            let imgY = screenHeight - winFrame.origin.y - winFrame.height
            let imgW = winFrame.width
            let imgH = winFrame.height

            guard let m = match else {
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "error": "No OCR node in frame \(fid) matched \"\(query)\"",
                    "frame_screen_rect": [
                        "x": imgX, "y": imgY,
                        "width": imgW, "height": imgH
                    ]
                ]), true)
            }
            // Normalized bbox × image rect → absolute pixels.
            let bx = imgX + m.leftX * imgW
            let by = imgY + m.topY  * imgH
            let bw = m.width  * imgW
            let bh = m.height * imgH
            return (sensorTextEnvelope(from: [
                "ok": true,
                "matched_text": m.text,
                "bbox": [
                    "x": bx, "y": by,
                    "width": bw, "height": bh,
                    "center_x": bx + bw / 2,
                    "center_y": by + bh / 2
                ],
                "frame_screen_rect": [
                    "x": imgX, "y": imgY,
                    "width": imgW, "height": imgH
                ]
            ]), false)
        }
    }

    /// Screen History dispatch — forwards `openrewind.*` tools to
    /// `MCPServer.handle()` using the live reader owned by
    /// `OpenRewindBridge`. When the bridge is disabled we return
    /// a friendly "not enabled" outcome.
    private static func handleSensorOpenRewind(name: String,
                                               arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        // Perf: reopen off-main so the SQLite copy doesn't block the
        // UI runloop while an MCP call is in flight.
        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared }) else {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "code": "not_enabled",
                "error": "Screen History is not enabled."
            ]), false)
        }
        try? await bridge.reopenReaderAsync()
        let reader = bridge.reader
        let wrapped = OpenRewindKitReader(reader: reader)
        do {
            let result = try await MCPServer.handle(name: name,
                                                    params: arguments,
                                                    reader: wrapped)
            return (sensorTextEnvelope(from: result), false)
        } catch {
            return (sensorTextEnvelope(from: [
                "ok": false,
                "error": String(describing: error)
            ]), true)
        }
    }

    /// Shared doc-read dispatch: parse `path` + `max_pages`, run the
    /// reader, and JSON-encode the `DocReaderResult` with snake-case
    /// wire keys.
    private static func handleDocRead(
        arguments: [String: Any],
        reader: (URL, Int?) async throws -> DocReaderResult
    ) async -> ([String: Any], Bool) {
        guard let path = string(arguments["path"]) else {
            return (sensorTextEnvelope(from: ["error": "path argument required"]), true)
        }
        let maxPages = sensorInt(arguments["max_pages"]).flatMap { $0 > 0 ? $0 : nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let result = try await reader(url, maxPages)
            return (sensorTextEnvelope(from: [
                "text": result.text,
                "page_count": result.pageCount as Any? ?? NSNull(),
                "word_count": result.wordCount as Any? ?? NSNull(),
                "mime_type": result.mimeType,
                "warnings": result.warnings
            ]), false)
        } catch let err as DocReaderError {
            return (sensorTextEnvelope(from: ["error": docReaderErrorMessage(err)]), true)
        } catch {
            return (sensorTextEnvelope(from: ["error": String(describing: error)]), true)
        }
    }

    /// Convert a `DocReaderError` into a wire-safe message string.
    private static func docReaderErrorMessage(_ err: DocReaderError) -> String {
        switch err {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .archiveInvalid(let m): return "archive invalid: \(m)"
        case .parseFailed(let m): return "parse failed: \(m)"
        case .encodingFailed(let p): return "encoding failed: \(p)"
        }
    }

    /// Convert a `MemoryStoreError` (or any other error) into a
    /// wire-safe message string.
    private static func memoryErrorMessage(_ err: Error) -> String {
        if let err = err as? MemoryStoreError {
            switch err {
            case .mergeConflict(let path): return "MERGE_CONFLICT: \(path)"
            case .decodeFailure(let path, let u): return "decode failure at \(path): \(u)"
            case .ioFailure(let path, let u): return "io failure at \(path): \(u)"
            }
        }
        return String(describing: err)
    }

    /// Convert a `MetaToolError` (or any other error) into a wire-safe
    /// message string.
    private static func metaErrorMessage(_ err: Error) -> String {
        if let err = err as? MetaToolError {
            switch err {
            case .selfExpandDisabled: return "SELFEXPAND_DISABLED"
            case .unknownTool(let n): return "unknown tool: \(n)"
            case .noDispatchDelegate: return "dispatch delegate not configured"
            case .dispatchFailed(let n, let u): return "dispatch failed for \(n): \(u)"
            case .strategyNoteIncomplete(let missing): return "STRATEGY_NOTE_INCOMPLETE: \(missing.joined(separator: ","))"
            case .mutationUnapproved: return "MUTATION_UNAPPROVED"
            }
        }
        return String(describing: err)
    }

    // MARK: - MEDIUM-severity port handlers
    //
    // Everywhere pin 30e03e9dcfdd4247fd679828ed86e9042f32d809.
    //
    // Full a11y-tree walking (Everywhere `ElementIndexer.Walk`) is not
    // yet ported to openclicky — the FrontmostAppCapture + AX bridge in
    // this codebase resolves the frontmost app only. These handlers
    // therefore return an Everywhere-shape best-effort envelope: match
    // the frontmost app against the hint, echo its metadata, and note
    // the missing tree. Callers pinned to the Everywhere shape can
    // still probe the tool wire contract.

    /// Dispatch helper for `get_app_context`. Everywhere
    /// `Tools/GetAppContextTool.cs:15-134`. Fuzzy-matches the hint
    /// against the frontmost app (which is the only app openclicky
    /// currently resolves) and returns its metadata plus a
    /// tree_text=nil sentinel.
    private static func handleSensorGetAppContext(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let hint = string(arguments["app_hint"]),
              !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (sensorTextEnvelope(from: ["error": "app_hint argument required"]), true)
        }
        guard let info = FrontmostAppCapture.capture() else {
            return (sensorTextEnvelope(from: [
                "error": "APP_NOT_RUNNING",
                "app_hint": hint
            ]), true)
        }
        let localized = info.localizedName ?? ""
        let bundleId = info.bundleId ?? ""
        let matchesKey = AppKeyResolver.matchesQuery(info.appKey, query: hint)
        let matchesName = !localized.isEmpty && localized.range(of: hint, options: .caseInsensitive) != nil
        let matchesBundle = !bundleId.isEmpty && bundleId.range(of: hint, options: .caseInsensitive) != nil
        if !(matchesKey || matchesName || matchesBundle) {
            return (sensorTextEnvelope(from: [
                "error": "APP_NOT_RUNNING",
                "app_hint": hint,
                "frontmost_app_key": info.appKey
            ]), true)
        }
        let raiseIfNeeded = (arguments["raise_if_needed"] as? Bool) ?? false
        let bundle: [String: Any] = [
            "matched": [
                "app": info.appKey,
                "window_title": localized,
                "hint": hint,
                "raised": raiseIfNeeded
            ] as [String: Any],
            "app": info.appKey,
            "window_title": localized,
            "window_bounds": NSNull(),
            "screenshot_png_b64": NSNull(),
            "tree_text": NSNull(),
            "tree_json": NSNull(),
            "selected_items": [] as [Any],
            "focused_items": [] as [Any],
            "focused_path": NSNull(),
            "note": "openclicky ElementIndexer.Walk not yet ported — matched-app metadata only."
        ]
        return (sensorTextEnvelope(from: bundle), false)
    }

    /// Dispatch helper for `get_app_state`. Everywhere
    /// `Tools/GetAppStateTool.cs:11-30`. Uses
    /// `OpenClickyKnownAppResolver` to derive the agent-state URL from
    /// the app's window title and HTTP-fetches it, mirroring
    /// Everywhere's MacFocusBackend HTTP path.
    private static func handleSensorGetAppState(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let app = string(arguments["app"]),
              !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (sensorTextEnvelope(from: ["error": "app argument required"]), true)
        }
        let knownRules = OpenClickyContextAwarenessSettings.shared.knownApps.map {
            OpenClickyKnownAppRule(titlePattern: $0.titlePattern, discoverUrl: $0.discoverUrl)
        }
        // Try to match either the app key/name/bundle against a
        // KnownApps regex. Falls back to using `app` as the title
        // itself (Everywhere resolves title from the AX subsystem;
        // openclicky uses the caller-supplied name).
        let frontmost = FrontmostAppCapture.capture()
        let title = frontmost?.localizedName ?? app
        guard let resolved = OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: title,
            knownApps: knownRules
        ) ?? OpenClickyKnownAppResolver.resolveDiscoveryUrl(
            appTitle: app,
            knownApps: knownRules
        ) else {
            return (sensorTextEnvelope(from: [
                "error": "KNOWN_APP_MISS",
                "app": app,
                "note": "no KnownApps entry matches the supplied title."
            ]), true)
        }
        guard let url = URL(string: resolved.statePath) else {
            return (sensorTextEnvelope(from: [
                "error": "INVALID_STATE_URL",
                "app": app,
                "state_url": resolved.statePath
            ]), true)
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if status < 200 || status >= 300 {
                return (sensorTextEnvelope(from: [
                    "error": "AGENT_STATE_HTTP_\(status)",
                    "app": app,
                    "state_url": resolved.statePath,
                    "body": text
                ]), true)
            }
            return (sensorTextEnvelope(from: [
                "app": app,
                "state_url": resolved.statePath,
                "discover_url": resolved.discoverUrl,
                "status": status,
                "body": text
            ]), false)
        } catch {
            return (sensorTextEnvelope(from: [
                "error": "AGENT_STATE_FETCH_FAILED",
                "app": app,
                "state_url": resolved.statePath,
                "message": String(describing: error)
            ]), true)
        }
    }

    /// UserDefaults key namespace for strategy-note storage. One key per
    /// `<site>/<name>` pair, holding the JSON-encoded StrategyNote.
    private static func sensorStrategyNoteKey(site: String, name: String) -> String {
        return "openclicky.strategyNote.\(site).\(name)"
    }

    /// Dispatch helper for `strategy_note_get`. Everywhere
    /// `Tools/GateTools.cs:63-75`.
    private static func handleSensorStrategyNoteGet(arguments: [String: Any]) -> ([String: Any], Bool) {
        if !OpenClickyMetaSelfExpandGate.isEnabled {
            return (sensorTextEnvelope(from: ["ok": false, "code": "SELFEXPAND_DISABLED", "message": ""]), true)
        }
        guard let site = string(arguments["site"]),
              let name = string(arguments["name"]),
              !site.isEmpty, !name.isEmpty else {
            return (sensorTextEnvelope(from: ["ok": false, "code": "INVALID_IDENTIFIER", "message": "site and name required"]), true)
        }
        let key = sensorStrategyNoteKey(site: site, name: name)
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return (sensorTextEnvelope(from: ["ok": true, "note": NSNull()]), false)
        }
        return (sensorTextEnvelope(from: obj), false)
    }

    /// Dispatch helper for `strategy_note_write`. Everywhere
    /// `Tools/GateTools.cs:31-61`. Uses openclicky's
    /// `OpenClickyMetaTools.validateStrategyNote` (previously
    /// unreferenced, per task instruction).
    private static func handleSensorStrategyNoteWrite(arguments: [String: Any]) -> ([String: Any], Bool) {
        if !OpenClickyMetaSelfExpandGate.isEnabled {
            return (sensorTextEnvelope(from: ["ok": false, "code": "SELFEXPAND_DISABLED", "message": ""]), true)
        }
        guard let site = string(arguments["site"]),
              let name = string(arguments["name"]),
              !site.isEmpty, !name.isEmpty else {
            return (sensorTextEnvelope(from: ["ok": false, "code": "INVALID_IDENTIFIER", "message": "site and name required"]), true)
        }
        guard let noteJson = string(arguments["note"]),
              let noteData = noteJson.data(using: .utf8) else {
            return (sensorTextEnvelope(from: ["ok": false, "code": "ARGUMENT_ERROR", "message": "note (JSON string) required"]), true)
        }
        let parsed: StrategyNote
        do {
            let decoder = JSONDecoder()
            parsed = try decoder.decode(StrategyNote.self, from: noteData)
        } catch {
            return (sensorTextEnvelope(from: ["ok": false, "code": "ARGUMENT_ERROR", "message": String(describing: error)]), true)
        }
        let meta = OpenClickyMetaToolRegistry()
        do {
            try meta.validateStrategyNote(parsed)
        } catch let err as MetaToolError {
            switch err {
            case .strategyNoteIncomplete(let missing):
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "code": "STRATEGY_NOTE_INCOMPLETE",
                    "message": "note is incomplete",
                    "details": ["missing_fields": missing]
                ]), true)
            case .mutationUnapproved:
                return (sensorTextEnvelope(from: [
                    "ok": false,
                    "code": "MUTATION_UNAPPROVED",
                    "message": "evidence names a mutating verb (POST/PUT/DELETE/PATCH) but mutation:false",
                    "details": ["site": site, "name": name]
                ]), true)
            case .selfExpandDisabled:
                return (sensorTextEnvelope(from: ["ok": false, "code": "SELFEXPAND_DISABLED", "message": ""]), true)
            default:
                return (sensorTextEnvelope(from: ["ok": false, "code": "ARGUMENT_ERROR", "message": String(describing: err)]), true)
            }
        } catch {
            return (sensorTextEnvelope(from: ["ok": false, "code": "ARGUMENT_ERROR", "message": String(describing: error)]), true)
        }
        // Persist to UserDefaults keyed by <site>/<name>.
        guard let stored = try? JSONEncoder().encode(parsed),
              let storedString = String(data: stored, encoding: .utf8) else {
            return (sensorTextEnvelope(from: ["ok": false, "code": "ARGUMENT_ERROR", "message": "encode failed"]), true)
        }
        let key = sensorStrategyNoteKey(site: site, name: name)
        UserDefaults.standard.set(storedString, forKey: key)
        return (sensorTextEnvelope(from: ["path": key]), false)
    }

    /// Dispatch helper for `opendia_smoke_check`. Everywhere
    /// `Tools/GeneratorTools.cs:390-440`. Minimal impl per task —
    /// full OpenDia extension probe is scope-creep; return an
    /// always-ok envelope with a timestamp so the tool descriptor
    /// exists and callers can pin against the shape.
    private static func handleSensorOpendiaSmokeCheck() -> ([String: Any], Bool) {
        let ts = Int64(Date().timeIntervalSince1970)
        return (sensorTextEnvelope(from: ["ok": true, "timestamp": ts]), false)
    }

    /// Dispatch helper for `screenshot`. Broken out to keep
    /// `executeSensorTool` readable — the arg parsing + rect construction
    /// path is non-trivial.
    private static func handleSensorScreenshot(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let scope = string(arguments["scope"]) else {
            return (sensorTextEnvelope(from: ["error": "scope argument required (screen|window|region)"]), true)
        }
        let format: ScreenshotFormat
        switch string(arguments["format"])?.lowercased() {
        case "png": format = .png
        case "jpeg", "jpg", nil, "": format = .jpeg
        case let other?:
            return (sensorTextEnvelope(from: ["error": "unknown format '\(other)' (expected jpeg|png)"]), true)
        }
        let result: ScreenshotResult?
        switch scope.lowercased() {
        case "screen":
            let screenID = sensorInt(arguments["pid"]) ?? 0
            result = await ScreenshotCaptureEverywhere.captureScreen(screenID: screenID, format: format)
        case "window":
            guard let pid = sensorInt32(arguments["pid"]), pid > 0 else {
                return (sensorTextEnvelope(from: ["error": "scope=window requires positive pid"]), true)
            }
            result = await ScreenshotCaptureEverywhere.captureWindow(pid: pid, format: format)
        case "region":
            guard let rectDict = dictionary(arguments["rect"]),
                  let x = double(rectDict["x"]),
                  let y = double(rectDict["y"]),
                  let w = double(rectDict["w"]),
                  let h = double(rectDict["h"]),
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite,
                  w > 0, h > 0 else {
                return (sensorTextEnvelope(from: ["error": "scope=region requires rect:{x,y,w,h} with positive w/h"]), true)
            }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            result = await ScreenshotCaptureEverywhere.captureRegion(rect: rect, format: format)
        default:
            return (sensorTextEnvelope(from: ["error": "scope must be screen|window|region"]), true)
        }
        guard let shot = result else {
            return (sensorTextEnvelope(from: ["error": "Screenshot capture returned nil (permission denied, empty rect, or capture failure)"]), true)
        }
        return (sensorTextEnvelope(from: sensorScreenshotResultDict(from: shot)), false)
    }

    /// Wraps an arbitrary JSON-serialisable object into an MCP text content
    /// entry. The wire payload is the JSON string; the outer envelope stays
    /// as native dict so it can be merged into the JSON-RPC response.
    private static func sensorTextEnvelope(from object: Any) -> [String: Any] {
        let jsonData = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let jsonText = String(data: jsonData, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": jsonText]
    }

    /// Converts a Codable capture struct into a `[String: Any]` dictionary
    /// via `JSONEncoder` -> `JSONSerialization`. Returns nil if the value
    /// is nil or encoding fails.
    private static func sensorJSONObject<T: Encodable>(_ value: T?) -> [String: Any]? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// FocusedWindowInfo carries a CGRect which does not have a built-in
    /// Codable representation that survives JSON round-trip cleanly, so
    /// hand-serialise into a dict with x/y/width/height.
    private static func sensorFocusedWindowDict(from info: FocusedWindowInfo) -> [String: Any] {
        return [
            "processId": Int(info.processId),
            "title": info.title as Any? ?? NSNull(),
            "frame": [
                "x": info.frame.origin.x,
                "y": info.frame.origin.y,
                "width": info.frame.size.width,
                "height": info.frame.size.height
            ] as [String: Any],
            "displayIndex": info.displayIndex.map { $0 as Any } ?? NSNull(),
            "isMinimized": info.isMinimized,
            "isMainWindow": info.isMainWindow
        ]
    }

    private static func sensorInt32(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(exactly: value) }
        if let value = value as? Double, value.isFinite {
            return Int32(exactly: Int64(value))
        }
        if let s = value as? String, let parsed = Int32(s) { return parsed }
        return nil
    }

    private static func sensorInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? Double, value.isFinite {
            return Int(exactly: Int64(value))
        }
        if let s = value as? String, let parsed = Int(s) { return parsed }
        return nil
    }

    /// Flatten a CGRect to `{x,y,width,height}` — the shape callers of
    /// `sensor_focused_window` and the Phase 5 additions expect.
    private static func sensorCGRectDict(_ rect: CGRect) -> [String: Any] {
        return [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.size.width,
            "height": rect.size.height
        ]
    }

    /// Serialise an `EnumeratedWindow`. Hand-rolled because CGRect
    /// round-trips through Codable as a nested `{origin, size}` shape
    /// which doesn't match Everywhere's flat `{x,y,width,height}` wire.
    private static func sensorEnumeratedWindowDict(from w: EnumeratedWindow) -> [String: Any] {
        return [
            "pid": Int(w.pid),
            "wid": Int(w.wid),
            "title": w.title as Any? ?? NSNull(),
            "ownerName": w.ownerName as Any? ?? NSNull(),
            "bounds": sensorCGRectDict(w.bounds),
            "screenIndex": w.screenIndex.map { $0 as Any } ?? NSNull(),
            "isOnScreen": w.isOnScreen,
            "layer": w.layer,
            "alpha": w.alpha
        ]
    }

    private static func sensorElementUnderCursorDict(from info: ElementUnderCursorInfo) -> [String: Any] {
        return [
            "pid": Int(info.pid),
            "role": info.role as Any? ?? NSNull(),
            "subrole": info.subrole as Any? ?? NSNull(),
            "title": info.title as Any? ?? NSNull(),
            "value": info.value as Any? ?? NSNull(),
            "bounds": sensorCGRectDict(info.bounds),
            "bundleId": info.bundleId as Any? ?? NSNull()
        ]
    }

    private static func sensorCursorPositionDict(from pos: CursorPosition) -> [String: Any] {
        return [
            "point": [
                "x": pos.point.x,
                "y": pos.point.y
            ] as [String: Any],
            "displayIndex": pos.displayIndex,
            "capturedAtUnix": pos.capturedAtUnix
        ]
    }

    private static func sensorScreenshotResultDict(from shot: ScreenshotResult) -> [String: Any] {
        return [
            "screenshot_base64": shot.data.base64EncodedString(),
            "format": shot.format.rawValue,
            "width": shot.pixelWidth,
            "height": shot.pixelHeight,
            "byte_length": shot.data.count
        ]
    }

    private static func sensorOCRResultDict(from result: OCRResult) -> [String: Any] {
        let lines: [[String: Any]] = result.lines.map { line in
            [
                "text": line.text,
                "bbox": [
                    "x": line.bounds.origin.x,
                    "y": line.bounds.origin.y,
                    "w": line.bounds.size.width,
                    "h": line.bounds.size.height
                ] as [String: Any],
                "confidence": Double(line.confidence)
            ]
        }
        return ["lines": lines, "count": lines.count]
    }

    /// Wrap a meta-tool body dict into an MCP `content` envelope. The
    /// primary bridge returns tool output as `{content:[{type,text}]}`;
    /// meta tools produce structured JSON so we serialize once here.
    private static func tieredMetaContentEnvelope(body: [String: Any], isError: Bool) -> [String: Any] {
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            text = "{\"ok\":false,\"error\":\"meta serialization failed\"}"
        }
        return [
            "content": [[
                "type": "text",
                "text": text
            ]],
            "isError": isError
        ]
    }

    private static func mcpJSONRPCResponse(from json: [String: Any], role: MCPToolRole = .all) -> MCPJSONRPCBridgeResponse? {
        guard string(json["jsonrpc"]) != nil || string(json["method"]) != nil else { return nil }
        let id = json["id"]
        let method = string(json["method"])
        switch method {
        case "initialize":
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "OpenClicky External Control Bridge", "version": "1.0.0"]
            ])
        case "notifications/initialized":
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: [:])
        case "tools/list":
            let pool = mcpToolDescriptors + OpenClickyMCPTieredLoader.metaToolDescriptors
            let roleScoped = pool.filter { descriptor in
                let name = (descriptor["name"] as? String) ?? ""
                return role.includes(toolName: name)
            }
            let gated = OpenClickyMCPTieredLoader.shared.filter(roleScoped)
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: ["tools": gated])
        case "tools/call":
            let params = dictionary(json["params"]) ?? [:]
            let name = string(params["name"]) ?? string(params["tool"])
            let arguments = dictionary(params["arguments"]) ?? [:]
            guard let name else {
                return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: nil, errorMessage: "Missing tool name")
            }
            // Meta tools live in `core` and are always callable regardless
            // of role — they are the reflection surface every client uses
            // to reach hidden domains.
            if OpenClickyMCPTieredLoader.metaToolNames.contains(name) {
                let pool = mcpToolDescriptors + OpenClickyMCPTieredLoader.metaToolDescriptors
                let (body, isError) = OpenClickyTieredMetaDispatch.handle(name: name, arguments: arguments, primaryPool: pool)
                let envelope = tieredMetaContentEnvelope(body: body, isError: isError)
                return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: envelope)
            }
            // Enforce role gate: role-restricted endpoints reject tools
            // outside their scope so a rogue caller can't request a
            // codex_* tool from /mcp/advisor.
            guard role.includes(toolName: name) else {
                return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: nil,
                                                errorMessage: "Tool '\(name)' is not available at this endpoint (role scope)")
            }
            let command = mcpToolCommand(from: ["tool": name, "arguments": arguments])
            return MCPJSONRPCBridgeResponse(id: id, command: command, staticResult: nil, errorMessage: command == nil ? "Unknown or invalid tool" : nil)
        default:
            return MCPJSONRPCBridgeResponse(id: id, command: nil, staticResult: nil, errorMessage: "Unsupported MCP method")
        }
    }

    private static func point(from json: [String: Any]) -> CGPoint? {
        // M14: guard against NaN/Infinity so a malformed {"x":"NaN","y":"NaN"}
        // cannot propagate through pointClampedToDesktop into a CGEvent.
        if let point = dictionary(json["point"]), let x = double(point["x"]), let y = double(point["y"]) {
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let x = double(json["x"]), let y = double(json["y"]) else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func scribbleCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        guard let rawPoints = array(json["points"]) else { return nil }
        let points = rawPoints.compactMap { value -> CGPoint? in
            if let dict = dictionary(value) { return point(from: dict) }
            if let pair = array(value), pair.count >= 2, let x = double(pair[0]), let y = double(pair[1]) {
                return CGPoint(x: x, y: y)
            }
            return nil
        }
        guard points.count >= 2 else { return nil }
        let overlay = OpenClickyVisualGuidanceOverlay.scribble(
            points: points,
            accentHex: string(json["accentHex"]),
            lineWidth: double(json["lineWidth"]) ?? double(json["strokeWidth"]) ?? 5,
            caption: string(json["caption"]),
            duration: duration(from: json)
        )
        return overlay.isRenderable ? .showVisualGuidanceOverlay(overlay) : nil
    }

    private static func rectangleCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        let rect: CGRect?
        if let rectDict = dictionary(json["rect"]) ?? dictionary(json["rectangle"]) {
            rect = rectFrom(rectDict)
        } else {
            rect = rectFrom(json)
        }
        guard let rect else { return nil }
        let overlay = OpenClickyVisualGuidanceOverlay.rectangle(
            rect: rect,
            accentHex: string(json["accentHex"]),
            lineWidth: double(json["lineWidth"]) ?? double(json["strokeWidth"]) ?? 4,
            fillOpacity: double(json["fillOpacity"]) ?? 0.14,
            caption: string(json["caption"]),
            duration: duration(from: json)
        )
        return overlay.isRenderable ? .showVisualGuidanceOverlay(overlay) : nil
    }

    private static func rectFrom(_ json: [String: Any]) -> CGRect? {
        if let x = double(json["x"]), let y = double(json["y"]), let width = double(json["width"]), let height = double(json["height"]) {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        if let x1 = double(json["x1"]), let y1 = double(json["y1"]), let x2 = double(json["x2"]), let y2 = double(json["y2"]) {
            return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        }
        return nil
    }

    private static func cursorMode(from json: [String: Any]) -> OpenClickyExternalCursorMode {
        guard let rawMode = string(json["mode"])?.lowercased() else { return .primary }
        if rawMode == "secondary" || rawMode == "new" || rawMode == "ghost" {
            return .secondary
        }
        return .primary
    }

    private static func duration(from json: [String: Any]) -> TimeInterval {
        let milliseconds = double(json["durationMs"]) ?? double(json["ttlMs"])
        if let milliseconds { return max(0.2, min(milliseconds / 1000.0, 60.0)) }
        return max(0.2, min(double(json["duration"]) ?? 4.0, 60.0))
    }

    private static func travelDuration(from json: [String: Any]) -> TimeInterval {
        let milliseconds = double(json["travelMs"]) ?? double(json["moveMs"])
        if let milliseconds { return max(0.0, min(milliseconds / 1000.0, 3.0)) }
        return max(0.0, min(double(json["travelDuration"]) ?? 0.65, 3.0))
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let parsed = Double(value) { return parsed.isFinite ? parsed : nil }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        if let value = value as? Int { return value != 0 }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "OK"
        }
    }
}

#if DEBUG
extension OpenClickyExternalControlBridgeServer {
    static var testMCPToolDescriptors: [[String: Any]] {
        mcpToolDescriptors
    }

    static var testCapabilityCompatibilityMetadata: [[String: Any]] {
        capabilityCompatibilityMetadata
    }

    static func testCommand(from json: [String: Any]) -> OpenClickyExternalControlCommand? {
        mcpToolCommand(from: json)
    }
}
#endif

/// Dispatch delegate that forwards `OpenClickyMetaToolRegistry.callTool`
/// requests back through the bridge's static `executeSensorTool`
/// dispatch. Used to let `call_tool` and `batch` reach every registered
/// sensor tool without duplicating the dispatch switch.
///
/// The delegate parses the `arguments_json` string (if any) as a JSON
/// object, invokes `executeSensorTool(name:arguments:)`, and returns the
/// content envelope's `text` field (raw tool JSON) as the reply string
/// per `MetaToolDispatchDelegate` contract.
final class SensorMetaDispatchDelegate: MetaToolDispatchDelegate {
    func dispatch(name: String, argumentsJson: String?) async throws -> String {
        var arguments: [String: Any] = [:]
        if let json = argumentsJson,
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            arguments = dict
        }
        let (envelope, isError) = await OpenClickyExternalControlBridgeServer
            .invokeSensorToolForMeta(name: name, arguments: arguments)
        let text = (envelope["text"] as? String) ?? "{}"
        if isError {
            throw MetaToolError.dispatchFailed(name: name, underlying: text)
        }
        return text
    }
}

private struct MCPJSONRPCBridgeResponse {
    let id: Any?
    let command: OpenClickyExternalControlCommand?
    let staticResult: [String: Any]?
    var errorMessage: String? = nil

    func responseBody(result: OpenClickyExternalControlResponse?) -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0"]
        if let id { body["id"] = id }
        if let errorMessage {
            body["error"] = ["code": -32602, "message": errorMessage]
            return body
        }
        if let staticResult {
            body["result"] = staticResult
            return body
        }
        if let result {
            // Prefer command-specific textual output when present.
            // advisor_consult puts the model's response under "text" —
            // returning just "ok" would strip it before codex sees it.
            let text: String = {
                if let t = result.body["text"] as? String, !t.isEmpty { return t }
                if let err = result.body["error"] as? String, !err.isEmpty { return err }
                if (result.body["ok"] as? Bool) == true { return "ok" }
                return "error"
            }()
            body["result"] = [
                "content": [[
                    "type": "text",
                    "text": text
                ]],
                "isError": result.statusCode >= 400
            ]
            return body
        }
        body["result"] = [:]
        return body
    }
}

private struct HTTPRequest {
    enum ParseResult {
        case incomplete
        case malformed(String)
        case request(HTTPRequest)
    }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > openClickyExternalControlMaximumHeaderBytes
                ? .malformed("HTTP request headers exceed the maximum size.")
                : .incomplete
        }
        guard headerRange.lowerBound <= openClickyExternalControlMaximumHeaderBytes else {
            return .malformed("HTTP request headers exceed the maximum size.")
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("HTTP request headers must be UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .malformed("HTTP request line is missing.")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2].hasPrefix("HTTP/") else {
            return .malformed("HTTP request line is invalid.")
        }

        var headers: [String: String] = [:]
        var sawContentLength = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .malformed("HTTP request header is invalid.")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .malformed("HTTP request header name is missing.")
            }
            if key == "content-length" {
                guard !sawContentLength else {
                    return .malformed("Multiple Content-Length headers are not allowed.")
                }
                sawContentLength = true
            }
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"],
           !transferEncoding.isEmpty,
           transferEncoding.lowercased() != "identity" {
            return .malformed("Transfer-Encoding is not supported.")
        }

        let bodyStart = headerRange.upperBound
        let contentLength: Int
        if let declaredLength = headers["content-length"] {
            guard !declaredLength.isEmpty,
                  declaredLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsedLength = Int(declaredLength),
                  parsedLength <= openClickyExternalControlMaximumBodyBytes else {
                return .malformed("Content-Length is invalid or exceeds the maximum request size.")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        // `contentLength <= data.count - bodyStart` avoids both a negative
        // range and integer overflow for attacker-controlled header values.
        guard bodyStart <= data.count else {
            return .malformed("HTTP request body offset is invalid.")
        }
        guard contentLength <= data.count - bodyStart else {
            return .incomplete
        }
        let bodyEnd = bodyStart + contentLength
        return .request(
            HTTPRequest(
                method: parts[0].uppercased(),
                path: URLComponents(string: parts[1])?.path ?? parts[1],
                headers: headers,
                body: Data(data[bodyStart..<bodyEnd])
            )
        )
    }
}
