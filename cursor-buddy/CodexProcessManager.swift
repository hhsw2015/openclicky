import Foundation

nonisolated final class CodexProcessManager: @unchecked Sendable {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.codex-process")

    var onNotification: (([String: Any]) -> Void)?
    var onStderrLine: ((String) -> Void)?

    var isRunning: Bool {
        stateQueue.sync { process?.isRunning == true }
    }

    func start(
        executableURL: URL,
        codexHome: URL,
        taskDir: String? = nil,
        taskProgressPath: String? = nil
    ) throws {
        if isRunning { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--listen", "stdio://",
            // Safer seed defaults for the app-server. These are overridden by
            // every caller's per-turn `turn/start` params: Agent Mode (a
            // user-directed coding agent) explicitly requests
            // `danger-full-access` per-turn where the user wants full power; the
            // voice session and point detector request `workspace-write`.
            // Defaulting the seed to `workspace-write` means any future caller
            // that forgets to set a sandbox gets the confined one, not the whole
            // volume.
            "-c", "approval_policy=\"never\"",
            "-c", "sandbox_mode=\"workspace-write\""
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = Self.baseEnvironment(codexHome: codexHome, runtimeExecutableURL: executableURL)

        // Openclicky task-planning contract (see docs/OPENCLICKY_TASK_SPEC.md).
        // Injected here so codex, on spawn, can glob $OPENCLICKY_TASK_DIR and
        // drive $OPENCLICKY_TASK_PROGRESS to `LAST_COMPLETED: DONE`. The
        // AGENTS-longrun-template.md session-instructions block references
        // these env var names verbatim.
        if let dir = taskDir?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            environment["OPENCLICKY_TASK_DIR"] = dir
        }
        if let progressPath = taskProgressPath?.trimmingCharacters(in: .whitespacesAndNewlines), !progressPath.isEmpty {
            environment["OPENCLICKY_TASK_PROGRESS"] = progressPath
        }

        let configFile = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        let configText = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let prefersChatGPTAuth = configText.contains("preferred_auth_method = \"chatgpt\"")
        if let configuredAPIKey = AppBundleConfiguration.openAIAPIKey(),
           !configuredAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["OPENAI_API_KEY"] = configuredAPIKey
        } else if let codexEphemeral = HeyClickySessionTokenClient.shared.peekCachedCodexToken(),
                  !codexEphemeral.isEmpty {
            // Heyclicky lane: prefer the SHORT-LIVED codex ephemeral
            // token minted via POST /agent/session-token, matching
            // HeyClicky-1.0.40's own path (`cachedBackendAgentSession
            // Token` + `agentSessionTokenInjectedAtLastProcessSpawn`).
            // Sending the raw Supabase JWT to /agent/openai/v1/
            // responses gets 401 "Invalid or expired HeyClicky session
            // token" — the proxy expects the ephemeral only.
            environment["OPENAI_API_KEY"] = codexEphemeral
        } else if let jwt = AppBundleConfiguration.heyClickySessionAccessToken(),
                  !jwt.isEmpty {
            // Fallback: no codex ephemeral cached yet (very first spawn
            // before preamble ran). Use the Supabase JWT so the child
            // at least starts; the ~1s first /responses will 401 and
            // the recovery loop will mint + rekey. Better than
            // "Missing environment variable: OPENAI_API_KEY".
            environment["OPENAI_API_KEY"] = jwt
        } else if prefersChatGPTAuth {
            environment.removeValue(forKey: "OPENAI_API_KEY")
        }

        // HeyClicky Free gate: only inject proxy env when the CURRENT
        // agent model is heyclicky. Previously this keyed only on the
        // snapshot (`heyClickyPreviousAgentBaseURL != nil`), so after a
        // user switched Agent Mode from heyclicky to their own BYOK codex,
        // the stale snapshot kept injecting CLICKY_WORKER_BASE_URL +
        // OPENAI_BASE_URL into the BYOK child — every response request
        // got routed through the heyclicky proxy and 401/402'd.
        //
        // Endpoints (IDA HeyClicky-1.0.40 @ 0x1011bb470):
        //   OPENAI_BASE_URL             - <proxy>/agent/openai/v1
        //   CLICKY_WORKER_BASE_URL      - proxy root
        //   CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_app
        let currentAgentModel = UserDefaults.standard.string(forKey: "clickyCodexModel") ?? ""
        // Detect heyclicky lane by any of:
        //   1) UI-selected agent model is heyclicky-free-*
        //   2) HeyClicky hook has already been activated (snapshot set)
        //   3) User is signed into heyclicky and no BYOK openai key —
        //      this is the automation-API path where the caller sets
        //      no `clickyCodexModel` UserDefault but still expects the
        //      heyclicky proxy env, because they have no other agent key.
        let uiIsHeyClicky = currentAgentModel.hasPrefix("heyclicky-free-")
        let hookIsActive = AppBundleConfiguration.heyClickyPreviousAgentBaseURL() != nil
        let signedIn = AppBundleConfiguration.heyClickySignedIn()
        let hasByok = !((AppBundleConfiguration.openAIAPIKey() ?? "").isEmpty)
        let automationDefault = signedIn && !hasByok
        let agentIsHeyClickyLane = uiIsHeyClicky || hookIsActive || automationDefault
        if agentIsHeyClickyLane,
           let proxyBase = try? AppBundleConfiguration.heyClickyProxyBaseURL() {
            environment["CLICKY_WORKER_BASE_URL"] = proxyBase.absoluteString
            environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] = "codex_app"
            let responsesBase = proxyBase
                .appendingPathComponent("agent")
                .appendingPathComponent("openai")
                .appendingPathComponent("v1")
            environment["OPENAI_BASE_URL"] = responsesBase.absoluteString
        } else {
            // BYOK codex must NOT inherit any proxy env from the parent
            // process (which itself may have OPENAI_BASE_URL set from a
            // dev shell). Strip so the child hits api.openai.com.
            environment.removeValue(forKey: "CLICKY_WORKER_BASE_URL")
            environment.removeValue(forKey: "CODEX_INTERNAL_ORIGINATOR_OVERRIDE")
            environment.removeValue(forKey: "OPENAI_BASE_URL")
        }

        process.environment = environment
        process.terminationHandler = { [weak self] terminated in
            let statusCode = terminated.terminationStatus
            self?.failAllPendingRequests(message: "Codex app-server exited with status \(statusCode).")
            // Notify the higher layer so it can clear thread/lease
            // state and let the next follow-up prompt re-run the
            // preamble against a fresh codex process. Without this,
            // ensureThread's early-return path keeps using the dead
            // thread and every subsequent turn hangs.
            NotificationCenter.default.post(
                name: .heyClickyCodexProcessExited,
                object: nil,
                userInfo: ["exit_status": statusCode]
            )
        }

        // H5: assign process/pipe ivars behind stateQueue so concurrent
        // writeLine/isRunning/stop reads on stateQueue cannot tear. The
        // readability handlers themselves dispatch back onto stateQueue, so
        // setting them inside the sync block is safe (closure assignment only).
        stateQueue.sync {
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdout(data)
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.stateQueue.async { [weak self] in
                    self?.consumeStderr(data)
                }
            }
        }

        try process.run()
    }

    /// Shared subprocess environment (CODEX_HOME, PATH with bundled runtime
    /// paths prepended, GOG CLI vars) reused by both the persistent
    /// app-server (`start`) and one-shot `codex exec` callers such as
    /// `CodexPointDetector`.
    static func baseEnvironment(codexHome: URL, runtimeExecutableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["PATH"] = pathForAgentProcess(
            CodexRuntimeLocator.pathByPrependingBundledRuntimePaths(
                existingPath: environment["PATH"],
                runtimeExecutableURL: runtimeExecutableURL
            )
        )
        applyGogCLIEnvironment(to: &environment)

        // F27 review Issue 3 — inject the bridge bearer token into the
        // codex spawn env under the name referenced by
        // `ClickyCodexConfigTemplate.bridgeTokenEnvVarName`. Codex's
        // rmcp client resolves `bearer_token_env_var` from its
        // process env at MCP handshake time, so this env var is what
        // authenticates every sensor / openClickyControl call. Also
        // covers the `OPENCLICKY_AUTOMATION_TOKEN` dev-mode fallback
        // to match `hasValidBridgeToken` acceptance in
        // OpenClickyExternalControlBridge.swift. Kept out of a
        // separate helper because this is the single spawn point and
        // the coupling is deliberate.
        let bridgeTokenEnvName = ClickyCodexConfigTemplate.bridgeTokenEnvVarName
        if environment[bridgeTokenEnvName] == nil {
            if let configured = AppBundleConfiguration.externalControlBridgeToken(),
               !configured.isEmpty {
                environment[bridgeTokenEnvName] = configured
            } else if let dev = environment["OPENCLICKY_AUTOMATION_TOKEN"], !dev.isEmpty {
                environment[bridgeTokenEnvName] = dev
            }
        }
        // Bridge macOS network-preferences HTTP proxy into the child
        // process env so codex-sandboxed shell/curl invocations honor
        // it. macOS GUI apps get proxy config via SystemConfiguration,
        // not shell env — subprocesses inherit that but Chromium /
        // curl / requests read HTTP_PROXY env instead. Copy the
        // configured proxy in.
        if environment["HTTP_PROXY"] == nil, environment["http_proxy"] == nil {
            let proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [CFString: Any]
            if let dict = proxies,
               let httpEnable = dict[kCFNetworkProxiesHTTPEnable as CFString] as? Int, httpEnable == 1,
               let host = dict[kCFNetworkProxiesHTTPProxy as CFString] as? String,
               let port = dict[kCFNetworkProxiesHTTPPort as CFString] as? Int {
                let url = "http://\(host):\(port)"
                environment["HTTP_PROXY"] = url
                environment["http_proxy"] = url
                environment["HTTPS_PROXY"] = url
                environment["https_proxy"] = url
                environment["ALL_PROXY"] = url
                environment["all_proxy"] = url
                // Localhost + heyclicky must NOT go through the proxy,
                // otherwise the ephemeral OPENAI_BASE_URL loops through
                // the user's own worker adding latency.
                // Derive the bypass host from the configured proxy rather than
                // repeating the literal; empty template contributes nothing.
                let proxyHost = URL(string: HeyClickySecrets.proxyBaseURL)?.host
                environment["NO_PROXY"] = (["localhost", "127.0.0.1", ".local"] + [proxyHost].compactMap { $0 })
                    .joined(separator: ",")
                environment["no_proxy"] = environment["NO_PROXY"]!
            }
        }
        return environment
    }

    /// Runs a one-shot (non-app-server) Codex subprocess to completion and
    /// returns its trimmed stdout. Shared by callers such as
    /// `CodexPointDetector` that invoke `codex exec` rather than the
    /// persistent `app-server` this manager otherwise drives.
    static func runOneShotProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        errorDomain: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.environment = environment

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
                        throw NSError(
                            domain: errorDomain,
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func pathForAgentProcess(_ path: String) -> String {
        let requiredPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var components = path.split(separator: ":").map(String.init)
        for requiredPath in requiredPaths where !components.contains(requiredPath) {
            components.append(requiredPath)
        }
        return components.joined(separator: ":")
    }

    private static func applyGogCLIEnvironment(to environment: inout [String: String]) {
        environment["GOG_COLOR"] = "never"
        environment["GOG_GMAIL_NO_SEND"] = environment["GOG_GMAIL_NO_SEND"] ?? "1"

        if environment["OPENCLICKY_GOG_PATH"]?.isEmpty != false,
           let gogExecutablePath = AppBundleConfiguration.gogExecutablePath() {
            environment["OPENCLICKY_GOG_PATH"] = gogExecutablePath
        }

        if environment["GOG_KEYRING_PASSWORD"]?.isEmpty != false,
           let gogKeyringPassword = AppBundleConfiguration.gogKeyringPassword() {
            environment["GOG_KEYRING_PASSWORD"] = gogKeyringPassword
            environment["GOG_KEYRING_BACKEND"] = environment["GOG_KEYRING_BACKEND"] ?? "file"
        }

        if environment["GOG_ACCOUNT"]?.isEmpty != false,
           let gogAccount = AppBundleConfiguration.gogAccount() {
            environment["GOG_ACCOUNT"] = gogAccount
        }

        if environment["GOG_CLIENT"]?.isEmpty != false,
           let gogClient = AppBundleConfiguration.gogClient() {
            environment["GOG_CLIENT"] = gogClient
        }
    }

    @discardableResult
    func initialize(clientName: String = "open-clicky", title: String = "OpenClicky", version: String = "1.0.0") async throws -> [String: Any] {
        let response = try await sendRequest(request: Self.makeInitializeRequest(clientName: clientName, title: title, version: version))
        try sendNotification(method: "initialized")
        return response
    }

    static func makeInitializeRequest(clientName: String = "open-clicky", title: String = "OpenClicky", version: String = "1.0.0") -> CodexRPCRequest {
        CodexRPCRequest(id: 1, method: "initialize", params: [
            "clientInfo": [
                "name": clientName,
                "title": title,
                "version": version
            ],
            "capabilities": [
                "experimentalApi": true
            ]
        ])
    }

    func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await sendRequest(request: CodexRPCRequest(method: method, params: params))
    }

    func sendRequest(request: CodexRPCRequest) async throws -> [String: Any] {
        guard isRunning else {
            throw CodexRPCError(message: "Codex app-server is not running.")
        }

        let requestID = stateQueue.sync { () -> Int in
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        let requestWithID = CodexRPCRequest(id: requestID, method: request.method, params: request.params)
        let line = try requestWithID.encodedLine()
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "codex.rpc.request",
            fields: Self.summarizedRequestFieldsForLog(
                id: requestID,
                method: request.method,
                params: request.params as? [String: Any]
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.pending[requestID] = continuation
                self.writeLine(line)
            }
        }
    }

    func sendNotification(method: String, params: [String: Any]? = nil) throws {
        guard isRunning else {
            throw CodexRPCError(message: "Codex app-server is not running.")
        }
        let request = CodexRPCRequest(id: nil, method: method, params: params)
        let line = try request.encodedLine()
        OpenClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "codex.rpc.notification",
            fields: [
                "method": method,
                "params": params ?? [:]
            ]
        )
        stateQueue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    func stop() {
        // H5: serialize teardown with start()/writeLine on stateQueue so a
        // concurrent writeLine cannot read a half-torn inputPipe.
        let stoppedProcess: Process? = stateQueue.sync {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            inputPipe?.fileHandleForWriting.closeFile()
            let stopped = process
            if process?.isRunning == true {
                process?.terminate()
            }
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
            return stopped
        }
        _ = stoppedProcess
        failAllPendingRequests(message: "Codex app-server stopped.")
    }

    deinit {
        stop()
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        inputPipe?.fileHandleForWriting.write(data)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        consumeLines(from: &stdoutBuffer) { [weak self] line in
            self?.handleStdoutLine(line)
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer.append(data)
        consumeLines(from: &stderrBuffer) { [weak self] line in
            let isBenign = Self.isBenignStderrLine(line)
            OpenClickyMessageLogStore.shared.append(
                lane: "agent",
                direction: "incoming",
                event: isBenign ? "codex.stderr.benign" : "codex.stderr",
                fields: [
                    "line": line
                ]
            )
            DispatchQueue.main.async {
                self?.onStderrLine?(line)
            }
        }
    }

    private static func isBenignStderrLine(_ line: String) -> Bool {
        let benignMarkers = [
            "http://127.0.0.1:7778/mcp",
            "mcpServer/startupStatus/updated"
        ]
        let lower = line.lowercased()
        return benignMarkers.contains { lower.contains($0.lowercased()) }
    }

    private func consumeLines(from buffer: inout Data, handler: (String) -> Void) {
        let newline = Data([0x0A])
        while let range = buffer.firstRange(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            handler(line)
        }
    }

    private func handleStdoutLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if Self.shouldLogRPCMessage(message) {
                OpenClickyMessageLogStore.shared.append(
                    lane: "agent",
                    direction: "incoming",
                    event: "codex.rpc.message",
                    fields: Self.summarizedMessageFieldsForLog(message)
                )
            }
            if let id = CodexJSON.int(message["id"]) {
                let continuation = pending.removeValue(forKey: id)
                if let error = CodexJSON.dictionary(message["error"]) {
                    var text = CodexRPCErrorMessage.readableMessage(from: error["message"])
                        ?? "Codex app-server returned an error."
                    if let dataText = Self.readableErrorData(error["data"]),
                       !dataText.isEmpty,
                       dataText != text {
                        text += "\n\(dataText)"
                    }
                    continuation?.resume(throwing: CodexRPCError(message: text))
                } else {
                    let result = CodexJSON.dictionary(message["result"]) ?? [:]
                    continuation?.resume(returning: result)
                }
            } else {
                onNotification?(message)
            }
        } catch {
            onStderrLine?("Could not parse Codex RPC line: \(line)")
        }
    }

    private static func summarizedRequestFieldsForLog(id: Int, method: String, params: [String: Any]?) -> [String: Any] {
        var fields: [String: Any] = [
            "id": id,
            "method": method
        ]

        guard let params else { return fields }

        switch method {
        case "thread/start":
            fields["model"] = params["model"] ?? ""
            fields["cwd"] = params["cwd"] ?? ""
            fields["approvalPolicy"] = params["approvalPolicy"] ?? ""
            fields["sandbox"] = params["sandbox"] ?? ""
            fields["baseInstructionsLength"] = (params["baseInstructions"] as? String)?.count ?? 0
            fields["developerInstructionsLength"] = (params["developerInstructions"] as? String)?.count ?? 0
        case "turn/start":
            fields["threadId"] = params["threadId"] ?? ""
            fields["model"] = params["model"] ?? ""
            fields["cwd"] = params["cwd"] ?? ""
            fields["effort"] = params["effort"] ?? ""
            if let input = params["input"] as? [[String: Any]],
               let first = input.first,
               let text = first["text"] as? String {
                fields["inputTextLength"] = text.count
                fields["inputTextPreview"] = Self.shortLogSnippet(text, maxLength: 240)
            }
        default:
            fields["params"] = params
        }

        return fields
    }

    private static func summarizedMessageFieldsForLog(_ message: [String: Any]) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let id = CodexJSON.int(message["id"]) {
            fields["id"] = id
        }
        if let method = CodexJSON.string(message["method"]) {
            fields["method"] = method
            let params = CodexJSON.dictionary(message["params"]) ?? [:]
            fields["paramsSummary"] = summarizedNotificationParamsForLog(method: method, params: params)
            return fields
        }
        if let error = CodexJSON.dictionary(message["error"]) {
            fields["error"] = CodexRPCErrorMessage.readableMessage(from: error["message"]) ?? "Codex RPC error"
        } else if let result = CodexJSON.dictionary(message["result"]) {
            fields["resultKeys"] = Array(result.keys).sorted()
        } else {
            fields["kind"] = "unknown"
        }
        return fields
    }

    private static func shouldLogRPCMessage(_ message: [String: Any]) -> Bool {
        guard let method = CodexJSON.string(message["method"]) else { return true }

        switch method {
        case "item/agentMessage/delta",
             "command/exec/outputDelta",
             "item/commandExecution/outputDelta":
            return false
        default:
            return true
        }
    }

    private static func summarizedNotificationParamsForLog(method: String, params: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = [:]
        if let itemID = CodexJSON.string(params["itemId"]) {
            summary["itemId"] = itemID
        }
        if let turnID = CodexJSON.string(params["turnId"]) {
            summary["turnId"] = turnID
        }
        if let delta = CodexJSON.string(params["delta"]) {
            summary["deltaLength"] = delta.count
        }
        if let text = CodexJSON.string(params["text"]) {
            summary["textLength"] = text.count
            summary["textPreview"] = Self.shortLogSnippet(text, maxLength: 180)
        }
        if let item = CodexJSON.dictionary(params["item"]) {
            summary["itemType"] = CodexJSON.string(item["type"]) ?? ""
            summary["itemId"] = CodexJSON.string(item["id"]) ?? summary["itemId"] ?? ""
            if let text = CodexJSON.string(item["text"]) {
                summary["itemTextLength"] = text.count
                summary["itemTextPreview"] = Self.shortLogSnippet(text, maxLength: 180)
            }
            if let command = CodexJSON.string(item["command"]) {
                summary["commandPreview"] = Self.shortLogSnippet(command, maxLength: 180)
            }
            if let output = CodexJSON.string(item["aggregatedOutput"]) {
                summary["aggregatedOutputLength"] = output.count
            }
        }
        // MCP startup diagnostics — we want to see the actual failure
        // reason when a configured MCP server can't reach us, not just
        // an opaque "keys=[error,name,status]".
        if method == "mcpServer/startupStatus/updated" {
            if let name = CodexJSON.string(params["name"]) {
                summary["mcp_name"] = name
            }
            if let status = CodexJSON.string(params["status"]) {
                summary["mcp_status"] = status
            } else if let statusDict = CodexJSON.dictionary(params["status"]) {
                summary["mcp_status_keys"] = Array(statusDict.keys).sorted()
                if let kind = CodexJSON.string(statusDict["kind"]) {
                    summary["mcp_status_kind"] = kind
                }
            }
            if let err = params["error"] {
                if let s = CodexJSON.string(err) {
                    summary["mcp_error"] = Self.shortLogSnippet(s, maxLength: 1500)
                } else if let dict = CodexJSON.dictionary(err) {
                    if let msg = CodexJSON.string(dict["message"]) {
                        summary["mcp_error_message"] = Self.shortLogSnippet(msg, maxLength: 1500)
                    }
                    if let kind = CodexJSON.string(dict["kind"]) {
                        summary["mcp_error_kind"] = kind
                    }
                }
            }
        }
        if summary.isEmpty {
            summary["keys"] = Array(params.keys).sorted()
        }
        return summary
    }

    private static func shortLogSnippet(_ text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        return "\(flattened[..<endIndex])..."
    }

    private static func readableErrorData(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let message = CodexRPCErrorMessage.readableMessage(from: value) {
            return message
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
    }

    private func failAllPendingRequests(message: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let continuations = self.pending.values
            self.pending.removeAll()
            for continuation in continuations {
                continuation.resume(throwing: CodexRPCError(message: message))
            }
        }
    }
}
