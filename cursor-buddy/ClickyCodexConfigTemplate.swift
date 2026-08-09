import Foundation

struct ClickyCodexConfigTemplate: Equatable {
    static let defaultModelProviderID = "openai"
    static let customModelProviderID = "openclicky"
    static let heyClickyModelProviderID = "clicky"
    // Real model name accepted by the HeyClicky proxy. `heyclicky-free-*`
    // labels are internal UI names — codex must be told the real one.
    // IDA HeyClicky-1.0.40 literal at 0x1012aa9ca.
    static let heyClickyRealCodexModel = "gpt-5.6-sol"

    /// F27 fix — env-var name carrying the bridge token in the codex
    /// spawn env. Referenced by `bearer_token_env_var` in `[mcp_servers.*]`
    /// blocks and injected by `CodexProcessManager.baseEnvironment`.
    /// Switching from a plaintext `http_headers` value to a
    /// `bearer_token_env_var` reference means the on-disk config no
    /// longer contains the token verbatim, and rotating the token
    /// affects the next-spawned codex without touching config.toml.
    static let bridgeTokenEnvVarName = "OPENCLICKY_BRIDGE_TOKEN"

    var model: String
    var reasoningEffort: String
    var workerBaseURL: URL
    var modelInstructionsFileName: String
    var bundledSkillsDirectoryName: String
    var learnedSkillsDirectoryName: String
    var includeOpenAIDeveloperDocsMCP: Bool
    var includeComposioConnectMCP: Bool
    var includeOpenClickyControlMCP: Bool
    var cuaDriverMCPCommand: String?
    // Phase 3 Layer 2 — when non-nil/non-empty, emit
    // [mcp_servers.sensor] block pointing at the local
    // /mcp/sensor endpoint (SSE Streamable HTTP). The value carried
    // here gates emission (empty → block omitted so codex doesn't
    // start with a doomed 401 handshake), but the token itself is NOT
    // written into the config; codex reads it from the env var named
    // by `bridgeTokenEnvVarName` at spawn time
    // (see F27 review Issue 3 / bearer_token_env_var fix).
    var sensorMCPToken: String?
    // F27 review Issue 1 — the port the bridge is actually bound on.
    // Nil means the bridge has not yet reached `.ready`; the template
    // falls back to `OpenClickyExternalControlBridgeServer.resolveDefaultPort()`
    // which covers the `OPENCLICKY_MCP_PORT` env case. Bind-fallback
    // ladder cases require the caller to pass a runtime value.
    var bridgePort: UInt16?
    var preferAPIKeyAuthForDefaultOpenAI: Bool

    init(
        model: String = OpenClickyModelCatalog.defaultCodexActionsModelID,
        reasoningEffort: String = "medium",
        workerBaseURL: URL = ClickyCodexBackend.configuredWorkerBaseURL(),
        modelInstructionsFileName: String = "OpenClickyModelInstructions.md",
        bundledSkillsDirectoryName: String = "OpenClickyBundledSkills",
        learnedSkillsDirectoryName: String = "OpenClickyLearnedSkills",
        includeOpenAIDeveloperDocsMCP: Bool = false,
        includeComposioConnectMCP: Bool = false,
        includeOpenClickyControlMCP: Bool = false,
        cuaDriverMCPCommand: String? = nil,
        sensorMCPToken: String? = nil,
        bridgePort: UInt16? = nil,
        preferAPIKeyAuthForDefaultOpenAI: Bool = false
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workerBaseURL = workerBaseURL
        self.modelInstructionsFileName = modelInstructionsFileName
        self.bundledSkillsDirectoryName = bundledSkillsDirectoryName
        self.learnedSkillsDirectoryName = learnedSkillsDirectoryName
        self.includeOpenAIDeveloperDocsMCP = includeOpenAIDeveloperDocsMCP
        self.includeComposioConnectMCP = includeComposioConnectMCP
        self.includeOpenClickyControlMCP = includeOpenClickyControlMCP
        self.cuaDriverMCPCommand = cuaDriverMCPCommand
        self.sensorMCPToken = sensorMCPToken
        self.bridgePort = bridgePort
        self.preferAPIKeyAuthForDefaultOpenAI = preferAPIKeyAuthForDefaultOpenAI
    }

    /// Effective bridge port for URL interpolation. Prefers the runtime
    /// `bridgePort` (which reflects the fallback ladder), otherwise
    /// resolves via `OPENCLICKY_MCP_PORT` env, else the compiled default.
    var effectiveBridgePort: UInt16 {
        bridgePort ?? OpenClickyExternalControlBridgeServer.resolveDefaultPort()
    }

    /// Base URL for the bridge as seen by codex on the same host. Uses
    /// `effectiveBridgePort` so `OPENCLICKY_MCP_PORT` + bind-fallback are
    /// both honored.
    var bridgeBaseURL: String {
        "http://127.0.0.1:\(effectiveBridgePort)"
    }

    var openAICompatibleEndpoint: URL {
        if workerBaseURL.lastPathComponent == "v1" {
            return workerBaseURL
        }
        return workerBaseURL.appendingPathComponent("v1", isDirectory: false)
    }

    var modelProviderID: String {
        ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) ? Self.defaultModelProviderID : Self.customModelProviderID
    }

    /// True when the caller's `model` is a HeyClicky Free lane label
    /// (`heyclicky-free-*`). The proxy expects a very specific
    /// config.toml shape (verified against IDA HeyClicky-1.0.40 literals
    /// at 0x1012aa9ca, 0x1012aadd9 and the on-disk config that ships
    /// with HeyClicky.app at ~/Library/Application Support/Clicky/CodexHome).
    var isHeyClickyLane: Bool {
        model.hasPrefix("heyclicky-free-")
    }

    func render() -> String {
        // HeyClicky Free lane: emit the exact toml shape HeyClicky.app
        // writes to disk. That format is what the proxy actually accepts
        // — deviations (fast_mode at top level, `openclicky` provider
        // id, missing [features] section, missing log_dir/sqlite_home)
        // cause `codex_models_manager: Unsupported agent proxy path` and
        // the turn dies before any assistantMessage.
        if isHeyClickyLane {
            return renderHeyClickyToml()
        }

        var lines: [String] = [
            "model = \"\(escape(model))\"",
            "model_reasoning_effort = \"\(escape(reasoningEffort))\"",
            "model_provider = \"\(modelProviderID)\"",
            "preferred_auth_method = \"\(preferredAuthMethod)\"",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "personality = \"friendly\"",
            "cli_auth_credentials_store = \"file\"",
            "history.persistence = \"save-all\"",
            // Long-context knobs — reference ~/.codex/config.toml
            "model_context_window = 1000000",
            "model_auto_compact_token_limit = 1000000",
            "tool_output_token_limit = 25000",
            "model_reasoning_summary = \"none\"",
            "",
            "[features]",
            "steer = true",
            "goals = true",
            "undo = true",
            "unified_exec = true",
            "parallel = true",
            "plan_tool = true",
            "multi_agent = true",
            "",
            "[analytics]",
            "enabled = false"
        ]

        if !ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) {
            lines.append(contentsOf: [
                "",
                "[model_providers.\(Self.customModelProviderID)]",
                "name = \"OpenClicky\"",
                "env_key = \"OPENAI_API_KEY\"",
                "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
                "wire_api = \"responses\"",
                "trust_level = \"trusted\"",
                "hide_full_access_warning = true",
                "fast_mode = true",
                "multi_agent = true"
            ])
        }

        if includeOpenAIDeveloperDocsMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openaiDeveloperDocs]",
                "url = \"https://developers.openai.com/mcp\""
            ])
        }

        if includeComposioConnectMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.composio]",
                "url = \"https://connect.composio.dev/mcp\""
            ])
        }

        if let cuaDriverMCPCommand = normalizedOptionalString(cuaDriverMCPCommand) {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.cuaDriver]",
                "command = \"\(escape(cuaDriverMCPCommand))\"",
                "args = [\"mcp\"]",
                "",
                "[mcp_servers.cuaDriver.env]",
                "CUA_DRIVER_TELEMETRY_ENABLED = \"false\"",
                "CUA_TELEMETRY_ENABLED = \"false\""
            ])
        }

        // Unified openclicky-native MCP endpoint. Merges the retired
        // `/mcp` (openClickyControl visual-guidance) and `/mcp/advisor`
        // (free-model consulting) surfaces into a single endpoint served
        // at `/mcp/openclicky`. Bridge-token gated identically to
        // `/mcp/sensor`: codex reads OPENCLICKY_BRIDGE_TOKEN from the
        // spawn env at request time, so token rotation flows to the
        // next spawn automatically and the on-disk config never
        // contains the token value verbatim.
        if includeOpenClickyControlMCP {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openclicky]",
                "url = \"\(bridgeBaseURL)/mcp/openclicky\"",
                // Give rmcp room to reach the bridge while it's still
                // binding (bind-fallback ladder can take >1s on port
                // conflict; auto-resume can race the bridge start).
                "startup_timeout_sec = 10",
                "bearer_token_env_var = \"\(Self.bridgeTokenEnvVarName)\""
            ])
        }

        // Phase 3 Layer 2 — sensor MCP server. Codex's rmcp client
        // auto-detects Streamable HTTP transport from a `url` field, so
        // no explicit `type = "streamable_http"` is needed (mirrors how
        // /mcp/openclicky is exposed by the bridge, though the
        // openclicky-native advisor + visual-guidance surface is
        // deliberately not registered for HeyClicky-lane codex use —
        // see the HeyClicky-lane block comment for why). Token is
        // required: /mcp/sensor returns 401 without a valid bearer
        // token.
        //
        // F27 review fixes:
        //  - Port now interpolated from `bridgeBaseURL` (was hardcoded
        //    32123). Honors OPENCLICKY_MCP_PORT env + runtime bind-fallback.
        //  - Token surfaced via `bearer_token_env_var` instead of an
        //    on-disk http_headers value. Codex resolves it from
        //    OPENCLICKY_BRIDGE_TOKEN in its spawn env, so rotating the
        //    token affects the next-spawned codex without a config
        //    re-render.
        //  - startup_timeout_sec added to close the auto-resume race
        //    window (bridge may still be binding when codex tries to
        //    connect on session resume).
        if normalizedOptionalString(sensorMCPToken) != nil {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.sensor]",
                "url = \"\(bridgeBaseURL)/mcp/sensor\"",
                "startup_timeout_sec = 10",
                "bearer_token_env_var = \"\(Self.bridgeTokenEnvVarName)\""
            ])
        }

        lines.append(contentsOf: [
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(bundledSkillsDirectoryName))\"",
            "enabled = true",
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(learnedSkillsDirectoryName))\"",
            "enabled = true"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    /// HeyClicky-parity config. Field-by-field mirror of the toml
    /// HeyClicky.app writes to its own CodexHome. Any deviation causes
    /// the codex model manager to reject the turn.
    /// Verified against:
    ///  - IDA HeyClicky-1.0.40 string literals (0x1012aa9ca..0x1012ab290)
    ///  - HeyClicky.app on-disk ~/Library/Application Support/Clicky/CodexHome/config.toml
    ///  - clicky-mac reference AgentSessionsBridge.writeCodexConfig
    private func renderHeyClickyToml() -> String {
        let effectiveModel = Self.heyClickyRealCodexModel
        // Do NOT trust workerBaseURL here — heyclicky lane config must
        // hit the proxy regardless of what the byo-openai settings are
        // set to. If HeyClickyProxyBaseURL lookup fails (unconfigured),
        // we still fall back to openAICompatibleEndpoint so the config
        // at least writes something coherent.
        let base: String
        if let proxy = try? AppBundleConfiguration.heyClickyProxyBaseURL() {
            base = proxy
                .appendingPathComponent("agent")
                .appendingPathComponent("openai")
                .appendingPathComponent("v1")
                .absoluteString
        } else {
            base = openAICompatibleEndpoint.absoluteString
        }
        var lines: [String] = [
            "model = \"\(escape(effectiveModel))\"",
            "model_reasoning_effort = \"\(escape(reasoningEffort))\"",
            "model_provider = \"\(Self.heyClickyModelProviderID)\"",
            "preferred_auth_method = \"apikey\"",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "personality = \"friendly\"",
            "cli_auth_credentials_store = \"file\"",
            "mcp_oauth_credentials_store = \"file\"",
            "history.persistence = \"save-all\"",
            // Long-context knobs (user's local ~/.codex/config.toml
            // reference). 1M context window + matching auto-compact
            // threshold lets a single lease do WAY more per-turn work
            // before the context has to be rewound / summarized. The
            // tool_output cap keeps single shell dumps from wasting
            // all remaining budget.
            "model_context_window = 1000000",
            "model_auto_compact_token_limit = 1000000",
            "tool_output_token_limit = 25000",
            // Suppress reasoning summary output — analysis tokens
            // are billed but not useful for our agent runtime; saves
            // token budget so the turn runs longer before hitting
            // the hard cap.
            "model_reasoning_summary = \"none\"",
            "",
            "[model_providers.\(Self.heyClickyModelProviderID)]",
            "name = \"Clicky\"",
            "base_url = \"\(escape(base))\"",
            "env_key = \"OPENAI_API_KEY\"",
            "wire_api = \"responses\"",
            "",
            "[notice]",
            "hide_full_access_warning = true",
            "",
            "[features]",
            "apps = true",
            "fast_mode = false",
            "js_repl = true",
            "multi_agent = true",
            // Long-run enablers — turn/steer (0-quota same-lease
            // continuation), thread/goal/set (drift guard), undo
            // (thread/rollback), unified_exec (better shell), parallel
            // (parallel tool calls), plan_tool (turn/plan/updated).
            "steer = true",
            "goals = true",
            "undo = true",
            "unified_exec = true",
            "parallel = true",
            "plan_tool = true",
            // NOTE: the openclicky-native MCP surface (advisor_* +
            // visual guidance) is intentionally NOT registered for
            // codex-side use. Empirical A/B (Run A vs Run C, phase 2
            // POC) showed calling advisor from inside the agentic
            // loop hurts cost: each tool call adds a codex round-trip
            // (~4-5x more agent credits burned, ~2x wall clock, no
            // quality improvement over baseline). The unified
            // openclicky endpoint is best used in the PLANNING phase
            // (before spawning codex) or by EXTERNAL MCP clients
            // (Claude Code / Cursor) via /mcp/openclicky. See
            // docs/POC_ADVISOR_MCP.md.
        ]

        // Phase 3 Layer 2 — sensor MCP server. Unlike advisor (above),
        // sensor tools are pure local reads served by the loopback bridge
        // with zero per-call model cost, so the "extra codex round-trip"
        // argument does not apply. Emitted only when a bridge token is
        // available (endpoint 401s without it). mcp_servers.* sections
        // are consumed by codex locally, never touched by the HeyClicky
        // proxy.
        //
        // F27 review fixes (see general-lane block for full rationale):
        //  - Port interpolated from `bridgeBaseURL`.
        //  - `bearer_token_env_var` replaces the plaintext http_headers
        //    entry (token resolved from OPENCLICKY_BRIDGE_TOKEN at
        //    codex spawn time).
        //  - `startup_timeout_sec` closes the bridge-still-binding race
        //    on auto-resume.
        if normalizedOptionalString(sensorMCPToken) != nil {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.sensor]",
                "url = \"\(bridgeBaseURL)/mcp/sensor\"",
                "startup_timeout_sec = 10",
                "bearer_token_env_var = \"\(Self.bridgeTokenEnvVarName)\""
            ])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var preferredAuthMethod: String {
        guard ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) else { return "apikey" }
        return preferAPIKeyAuthForDefaultOpenAI ? "apikey" : "chatgpt"
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            // M19: TOML basic strings cannot contain raw newlines or control
            // chars (U+0000–U+001F); leaving them in made the generated
            // config.toml unparseable on bad input. Replace newlines with a
            // space and strip all other control characters.
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .filter { (" \t".contains($0)) || ($0.unicodeScalars.allSatisfy { $0.value >= 0x20 }) }
    }
}

nonisolated enum CuaDriverMCPConfiguration {
    static let environmentOverrideKey = "OPENCLICKY_CUA_DRIVER_MCP_COMMAND"
    static let knownCommandPaths = [
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
        "/usr/local/bin/cua-driver",
        "/opt/homebrew/bin/cua-driver"
    ]

    static func resolvedCommandPath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = normalized(environment[environmentOverrideKey]) {
            return override
        }

        if let bundled = bundledRuntimeExecutableURL(fileManager: fileManager) {
            return bundled.path
        }

        return knownCommandPaths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }

    static func bundledRuntimeExecutableURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        // Release builds copy CuaDriverRuntime directly into the app's
        // Resources directory. Resolve that bundle location first; the source
        // checkout fallback is only for development/test execution.
        var runtimeDirectories: [URL] = []
        if let bundledRuntime = bundle.url(forResource: "CuaDriverRuntime", withExtension: nil) {
            runtimeDirectories.append(bundledRuntime)
        }
        if let resourceURL = bundle.resourceURL {
            runtimeDirectories.append(resourceURL.appendingPathComponent("CuaDriverRuntime", isDirectory: true))
        }
        if let sourceResources = CodexRuntimeLocator.sourceAppResourcesDirectory(fileManager: fileManager) {
            runtimeDirectories.append(sourceResources.appendingPathComponent("CuaDriverRuntime", isDirectory: true))
        }

        for runtimeDirectory in runtimeDirectories {
            let executable = runtimeDirectory.appendingPathComponent("cua-driver", isDirectory: false)
            if fileManager.isExecutableFile(atPath: executable.path) {
                return executable
            }
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ClickyCodexBackend {
    static let defaultOpenAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let openClickyLocalModelBaseURL = URL(string: "http://127.0.0.1:32124")!

    static func configuredWorkerBaseURL() -> URL {
        // Never route Codex agents at the local MLX endpoint: mlx_lm only serves
        // /v1/chat/completions, while Codex requires the Responses API, so that
        // endpoint 404s on /v1/responses. Ignore it wherever it is configured.
        if let raw = ProcessInfo.processInfo.environment["CLICKY_AGENT_BASE_URL"],
           let url = validatedWorkerBaseURL(raw),
           !isOpenClickyLocalModelBaseURL(url) {
            return url
        }

        if let raw = UserDefaults.standard.string(forKey: "clickyAgentBaseURL"),
           let url = validatedWorkerBaseURL(raw),
           !isOpenClickyLocalModelBaseURL(url) {
            return url
        }

        return defaultOpenAIBaseURL
    }

    static func validatedWorkerBaseURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = components.url
        else {
            return nil
        }
        // M15: reject http:// for non-loopback hosts in code (don't lean on ATS).
        // A remote http endpoint would send the OpenAI key over plaintext.
        if scheme == "http", host != "127.0.0.1", host != "localhost" {
            return nil
        }
        return url
    }

    static func isDefaultOpenAIBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(defaultOpenAIBaseURL)
    }

    static func isOpenClickyLocalModelBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(openClickyLocalModelBaseURL)
    }

    private static func normalizedBaseURL(_ url: URL) -> String {
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("/v1") {
            normalized += "/v1"
        }
        return normalized.lowercased()
    }
}
