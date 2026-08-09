//
//  ClaudeAgentRunner.swift
//  cursor-buddy
//
//  Spawn the local `claude` CLI (Claude Code) and rewire its API traffic
//  through `MirageLocalRelay` so it terminates at aegis-proxy free-tier
//  Claude instead of Anthropic's paid endpoint. This is the "OpenClicky
//  agent = Claude Code + local CPA" equivalence: Claude Code brings the
//  real agentic loop (planning, sub-agents, tool use), we replace its
//  transport under the covers.
//
//  Flow:
//    1. Locate the `claude` binary on disk. GUI-launched apps don't
//       inherit the shell PATH, so we probe a fixed candidate list.
//    2. Start MirageLocalRelay on a loopback port.
//    3. Spawn Process(claude, "-p", prompt, "--output-format", "stream-json")
//       with ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY overrides.
//    4. Parse the CLI's stream-json output line-by-line; caller-supplied
//       callbacks surface assistant text, tool calls, and completion.
//    5. On cancel (barge-in): kill the process, stop the relay.
//
//  If `claude` isn't installed, throw a specific error the UI can act on
//  ("open a link to install claude-code").

import Foundation

/// Reasons the runner refused to start or failed mid-turn. UI-facing.
enum ClaudeAgentRunnerError: Error, LocalizedError {
    /// `claude` binary not found on disk. Prompt user to install.
    case claudeBinaryNotFound
    /// Local relay refused to start (port bind failure, transport init).
    case relayStartFailed(Error)
    /// Process exited before we could wire stdout streaming.
    case processStartFailed(Error)
    /// Process exited non-zero.
    case processExited(Int32)
    /// Runner cancelled by caller (barge-in). Not an error condition, but
    /// callers may want to distinguish.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .claudeBinaryNotFound:
            return "Claude Code CLI not found. Install with `npm install -g @anthropic-ai/claude-code`."
        case .relayStartFailed(let e):
            return "Mirage local relay failed to start: \(e.localizedDescription)"
        case .processStartFailed(let e):
            return "Failed to spawn claude process: \(e.localizedDescription)"
        case .processExited(let code):
            return "claude process exited with code \(code)."
        case .cancelled:
            return "Agent run cancelled."
        }
    }
}

/// A single parsed line from `claude --output-format stream-json`. This is
/// a lightweight passthrough — the real event schema (assistant messages,
/// tool_use blocks, tool_result blocks, summary events) is defined by
/// Claude Code itself. Callers pattern-match on `type` and dig into the
/// raw dict as needed.
struct MirageAgentEvent {
    let type: String
    let raw: [String: Any]
}

/// Orchestrates one agentic turn: relay + spawned claude process + event
/// pipe. Not a singleton — one instance per turn, disposed when the run
/// completes.
actor ClaudeAgentRunner {

    // MARK: - Configuration

    /// UserDefaults key for a user-supplied path override. When set, wins
    /// over the built-in candidate list. Handy for non-standard installs
    /// (custom prefixes, launcher shims, dev checkouts).
    static let claudeBinaryPathDefaultsKey = "openClickyClaudeCodeBinaryPath"

    /// UserDefaults key for the mirage-routed agent model. Value is a
    /// catalog id (e.g. `mirage/claude-opus-5`). The runner strips the
    /// `mirage/` prefix before handing it to the CLI's `--model` since
    /// the aegis-proxy upstream only accepts the bare identifier.
    static let claudeAgentModelDefaultsKey = "openClickyMirageAgentModel"
    /// Effort level used for **dialog** (chat/find_action/integration/
    /// memory) branches — routed via MirageBackendClient direct API.
    /// Separate from agent because dialog turns want faster/cheaper
    /// responses. Default: high.
    static let dialogEffortDefaultsKey = "openClickyMirageDialogEffort"
    /// Working directory for spawned Claude Code processes. Default:
    /// `~/Dev` if it exists, else `~`. Set via Settings.
    static let claudeAgentWorkingDirDefaultsKey = "openClickyMirageAgentWorkingDir"

    /// UserDefaults key for the agent effort level. Values match
    /// Claude Code's `effortLevel` field: minimal / low / medium / high /
    /// xhigh / max. Default = xhigh.
    static let claudeAgentEffortDefaultsKey = "openClickyMirageAgentEffort"

    /// UserDefaults key for enabling the 1M-context Opus variant
    /// (`opus[1m]`). Default = true when the selected model is Opus family.
    static let claudeAgentUse1MContextDefaultsKey = "openClickyMirageAgentUse1MContext"

    /// Fallback default agent model, used when the user hasn't picked one.
    /// Points at the catalog's Opus 5 mirage entry — matches OpenClickyProfile
    /// .peekyFree.agentModelID (kept in lockstep so Settings and Runner
    /// agree even if the two ever disagree on which is authoritative).
    static let defaultAgentModelCatalogID = "mirage/claude-opus-5"

    /// Fallback default effort. Matches ~/.claude/settings.json shipped by
    /// the user (verified against `.claude/settings.json` on this machine).
    static let defaultAgentEffort = "xhigh"

    /// We spawn the *real* Claude Code binary directly (not the personal
    /// `~/bin/claude-with-override` wrapper). Reason: the wrapper hardcodes
    /// its own `--model opus[1m]` and reads a fixed override.md path, which
    /// makes it impossible to switch model / effort per turn without
    /// editing the shell script. OpenClicky replicates the wrapper's
    /// useful behaviours (versions-dir discovery, override.md injection,
    /// env flags) here in Swift so a user changing the wrapper doesn't
    /// affect OpenClicky and OpenClicky changing its behaviour doesn't
    /// affect the user's Terminal `claude`.
    ///
    /// Candidate paths in first-hit order:
    ///   * `~/.local/share/claude/versions/<latest>/claude` — where the
    ///     native installer keeps its versioned binaries; the wrapper
    ///     resolves this same path, we mirror the logic in
    ///     `resolveVersionedBinary()`.
    ///   * `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` — Homebrew.
    ///   * `~/.claude/local/claude` — legacy native-installer symlink.
    ///   * `~/.local/bin`, `~/.npm-global/bin`, `~/.volta/bin`, `~/bin` —
    ///     package-manager installs.
    private static let claudeCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        NSString(string: "~/.claude/local/claude").expandingTildeInPath,
        NSString(string: "~/.local/bin/claude").expandingTildeInPath,
        NSString(string: "~/.npm-global/bin/claude").expandingTildeInPath,
        NSString(string: "~/.volta/bin/claude").expandingTildeInPath,
        NSString(string: "~/bin/claude").expandingTildeInPath,
    ]

    /// Resolve the newest binary in `~/.local/share/claude/versions`, if
    /// any. Matches the wrapper's `find_real_binary` (see
    /// ~/bin/claude-with-override): pick the highest semver dir that has
    /// an executable `claude` in it, skipping `.bak` / `.locked`.
    private static func resolveVersionedBinary() -> String? {
        let dir = NSString(string: "~/.local/share/claude/versions").expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }
        let filtered = entries.filter { !$0.contains(".bak") && !$0.contains(".locked") }
        // Sort with `sort -V`-style version compare. Swift's built-in
        // `compare(_:options:.numeric)` matches that ordering for standard
        // semver-ish dir names.
        let sorted = filtered.sorted { a, b in
            a.compare(b, options: .numeric) == .orderedAscending
        }
        for name in sorted.reversed() {
            let candidate = "\(dir)/\(name)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Read an env var as the login shell sees it. GUI apps don't inherit
    /// the user's shell rc; `zsh -l -c 'printf %s "$FOO"'` gives us the
    /// same value the user would see in Terminal. Nil = unset or empty.
    /// Failure to spawn zsh (sandbox, etc.) also returns nil.
    static func loginShellEnv(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i required so ~/.zshrc runs (interactive shell). -l picks up
        // ~/.zprofile / ~/.zlogin. Without -i, exported vars from zshrc
        // are missing.
        task.arguments = ["-i", "-l", "-c", "printf '%s' \"${\(name)}\""]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let val = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return val.isEmpty ? nil : val
            }
        } catch {
            // Sandbox / missing shell — fall through with nil.
        }
        return nil
    }

    // MARK: - Discovery

    /// Return the absolute path of a `claude` binary that both exists and
    /// is executable, or nil if none of our candidates match. Called at
    /// runner start; the UI can prompt for installation if this returns nil.
    static func locateClaudeBinary() -> String? {
        // 1. Explicit user override (Settings → Advanced). Wins over
        // everything so a dev build or non-standard install is honoured.
        if let override = UserDefaults.standard.string(forKey: claudeBinaryPathDefaultsKey)?
            .trimmingCharacters(in: .whitespaces), !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // 2. Latest versioned native-installer binary — the actual
        //    binary shipped by claude.com/install lives here. Picking
        //    this over any PATH-visible `claude` shim is important
        //    because we run the raw binary ourselves; we don't want to
        //    accidentally hit a wrapper script that layers its own
        //    args / env on top of ours.
        if let versioned = resolveVersionedBinary() {
            return versioned
        }
        // 3. Known non-wrapper install locations.
        for path in claudeCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Last resort: try `which claude` via /bin/sh with a login shell
        // (picks up ~/.zshrc PATH additions the app process didn't inherit).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // shell missing / sandboxed — fall through
        }
        return nil
    }

    // MARK: - Instance state

    private let relay: MirageLocalRelay
    private var process: Process?
    private var stdoutStream: AsyncThrowingStream<MirageAgentEvent, Error>?

    /// Per-turn scratch `$CLAUDE_CONFIG_DIR` created by
    /// `materializeScratchClaudeHome`. Cleaned up in `tearDown`.
    private var scratchHomeToCleanup: URL?

    /// Create a fresh empty directory + a `settings.json` that hard-writes
    /// the mirage relay endpoint. Returned URL is passed to the CLI via
    /// `CLAUDE_CONFIG_DIR`, so ~/.claude/settings.json is bypassed for
    /// this turn only.
    /// - Parameters:
    ///   - baseURL: the running MirageLocalRelay's URL.
    ///   - effectiveModel: the fully-resolved model id (e.g.
    ///     `claude-opus-5[1m]` or `claude-fable-5`). Used to populate the
    ///     top-level `model` field AND every `ANTHROPIC_DEFAULT_*_MODEL`
    ///     env fallback, so the CLI's family-alias resolver always ends
    ///     up on the same model the user picked.
    ///   - effort: value for `effortLevel` (minimal/low/medium/high/xhigh/max).
    /// Resolve the fully-decorated model id the Claude Code CLI wants
    /// to see. Appends `[1m]` when the model supports 1M context AND
    /// the user has not disabled it. Preserves any `mirage/` namespace
    /// prefix — that prefix is CPA's explicit routing signal (see
    /// `docs/mirage-change-manifest.md`); MirageLocalRelay strips it
    /// server-side in `normalizeBody` before sending upstream.
    ///
    /// Passing the prefixed form through the CLI is intentional:
    ///   - CLI passes `model` verbatim as `--model` value → relay body
    ///   - relay sees `mirage/…` → routes to aegis-proxy free tier
    ///   - relay strips prefix → upstream Anthropic sees `claude-opus-5[1m]`
    ///
    /// Single source of truth so the CLI wrapper and the Peeky panel's
    /// "Copy config" button produce identical strings.
    static func resolveEffectiveModelID(
        rawModel: String,
        defaults: UserDefaults = .standard
    ) -> String {
        // Detect and remember the mirage/ prefix so we can re-attach it
        // after suffix processing.
        let hasMiragePrefix = rawModel.hasPrefix("mirage/")
        let bareModel: String = hasMiragePrefix
            ? String(rawModel.dropFirst("mirage/".count))
            : rawModel
        // Which models offer the 1M-context tier on aegis-proxy today
        // (Anthropic public matrix): Opus family, Fable 5, Sonnet 4.6.
        let supports1M = bareModel.contains("opus")
            || bareModel.contains("fable-5")
            || bareModel.contains("sonnet-4-6")
        let use1M: Bool = {
            if defaults.object(forKey: claudeAgentUse1MContextDefaultsKey) != nil {
                return defaults.bool(forKey: claudeAgentUse1MContextDefaultsKey)
            }
            return supports1M
        }()
        let withSuffix: String
        if use1M && supports1M && !bareModel.contains("[1m]") {
            withSuffix = bareModel + "[1m]"
        } else {
            withSuffix = bareModel
        }
        return hasMiragePrefix ? "mirage/" + withSuffix : withSuffix
    }

    /// Read the user's own `~/.claude/settings.json` if it exists, and
    /// overlay only the fields we need to route through OpenClicky's
    /// mirage relay (`env.ANTHROPIC_BASE_URL`, `model`,
    /// `effortLevel`, `env.ANTHROPIC_AUTH_TOKEN`). Their MCP servers,
    /// hooks, custom keybinds, `permissions`, and anything else the
    /// user set are preserved. When no template exists, fall back to a
    /// minimal dict.
    ///
    /// Used by (a) the internal per-turn scratch home so a mirage
    /// agent turn respects the user's tooling, and (b) the Peeky panel
    /// "copy config" button so users can paste this back into their
    /// own `~/.claude/settings.json`.
    static func buildClaudeSettingsDict(
        baseURL: URL,
        effectiveModel: String,
        effort: String,
        mcpBridgePort: Int? = nil,
        templateURL: URL? = nil
    ) -> [String: Any] {
        // 1. Start from user's template (if present) or an empty dict.
        let templatePath = templateURL ?? URL(
            fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = {
            guard let data = try? Data(contentsOf: templatePath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return obj
        }()

        // 2. Overlay OpenClicky-required fields. Only fields whose
        //    values we own are overwritten; everything else the user
        //    configured survives.
        settings["model"] = effectiveModel
        settings["effortLevel"] = effort
        // Nudge these on if template omitted them; do NOT force off
        // when template explicitly disables (user preference wins on
        // toggles they set).
        if settings["alwaysThinkingEnabled"] == nil {
            settings["alwaysThinkingEnabled"] = true
        }
        if settings["showThinkingSummaries"] == nil {
            settings["showThinkingSummaries"] = true
        }
        if settings["enableWorkflows"] == nil {
            settings["enableWorkflows"] = true
        }

        // 3. env — merge, not replace. User's env vars (API keys they
        //    set for other providers, custom PATH, etc.) survive; we
        //    only inject/override the ones the relay needs.
        //
        // NOTE: env.ANTHROPIC_DEFAULT_*_MODEL takes the BARE model id
        // (e.g. `mirage/claude-opus-5`, WITHOUT the `[1m]` suffix).
        // Those env vars are used as fallback model names inserted
        // verbatim into Messages API bodies — the `[1m]` suffix is a
        // Claude-CLI-side convention (tells the CLI to attach the 1M
        // beta header on the wire), not a valid model id upstream.
        // The mirage/ prefix stays: MirageLocalRelay's normalizeBody
        // strips it before sending to Anthropic.
        let bareModelForEnv: String = {
            if let openBracket = effectiveModel.range(of: "[1m]") {
                return String(effectiveModel[..<openBracket.lowerBound])
            }
            return effectiveModel
        }()
        // env dict — merge, not replace. User's template might store
        // values as [String: Any] (numbers, bools) rather than strict
        // [String: String]; coerce non-string scalars via
        // `String(describing:)` so we do not silently drop the whole
        // dict when a single value is (e.g.) an Int.
        var env: [String: String] = {
            guard let raw = settings["env"] as? [String: Any] else { return [:] }
            var out: [String: String] = [:]
            for (k, v) in raw {
                if let s = v as? String { out[k] = s }
                else if let n = v as? NSNumber { out[k] = n.stringValue }
                else if let b = v as? Bool { out[k] = b ? "true" : "false" }
                // Skip nested dicts / arrays — they cannot round-trip
                // through shell env anyway.
            }
            return out
        }()
        env["ANTHROPIC_BASE_URL"] = baseURL.absoluteString
        // Preserve user's real Anthropic key if they had one — the
        // mirage relay stripes its own header and does not read
        // ANTHROPIC_AUTH_TOKEN, so writing our dummy would silently
        // clobber the user's paid-tier credential and they would only
        // notice when they turned off the relay. Only set the dummy
        // when no auth token was previously configured.
        if env["ANTHROPIC_AUTH_TOKEN"] == nil || env["ANTHROPIC_AUTH_TOKEN"]?.isEmpty == true {
            env["ANTHROPIC_AUTH_TOKEN"] = "sk-mirage-relay-dummy"
        }
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = bareModelForEnv
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = bareModelForEnv
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = bareModelForEnv
        env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] = bareModelForEnv
        env["CLAUDE_CODE_ATTRIBUTION_HEADER"] = "false"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_GROWTHBOOK"] = "1"
        env["ENABLE_PROMPT_CACHING_1H"] = "true"
        if env["CLAUDE_CODE_WORKFLOWS"] == nil {
            env["CLAUDE_CODE_WORKFLOWS"] = "1"
        }
        settings["env"] = env

        // 4. mcpServers — merge, not replace. Only inject openclicky
        //    when the caller supplied a bridge port.
        if let port = mcpBridgePort {
            var mcpServers = (settings["mcpServers"] as? [String: Any]) ?? [:]
            mcpServers["openclicky"] = [
                "type": "http",
                "url": "http://127.0.0.1:\(port)/mcp"
            ]
            settings["mcpServers"] = mcpServers
        }

        return settings
    }

    private static func materializeScratchClaudeHome(
        baseURL: URL,
        effectiveModel: String,
        effort: String
    ) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-mirage-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Field layout mirrors the shape of ~/.claude/settings.json — same
        // top-level keys the CLI recognises — but stripped down to just
        // what an agent turn needs. In particular we intentionally omit:
        //   * hooks     — would fire the user's shell hooks on every tool
        //                 call (UI popups, tty7 notifications, orca
        //                 permission prompts) which don't belong in an
        //                 embedded agent.
        //   * plugins   — plugin resolution costs ~1s at startup, and we
        //                 want a hermetic env.
        //   * statusLine — Not applicable to `-p` non-interactive mode.
        //
        // Kept + hardcoded to match the user's own preferences (see
        // /Users/wowdd1/.claude/settings.json for the reference values):
        //   alwaysThinkingEnabled + effortLevel = xhigh
        //   model                                = opus[1m]  (1M context Opus 5 via mirage)
        //   showThinkingSummaries                = true
        //   skipDangerousModePermissionPrompt    = true  (spawned agent
        //                                                can't take an
        //                                                interactive prompt)
        //   cleanupPeriodDays                    = 99999 (no in-turn cleanup)
        //   enableWorkflows                      = true
        // Every family alias (haiku/sonnet/opus) collapses to the same
        // effective model. This mirrors the user's own settings pattern
        // (~/.claude/settings.json maps all four families to
        // claude-opus-4.7) — the intent is that no matter which family
        // Claude Code's internal router picks for sub-agents, they all
        // end up on the model the user asked for.
        // MCP servers — expose OpenClicky's ExternalControlBridge so the
        // spawned Claude Code can call openclicky_point / show_cursor /
        // agent_* / sensor_* natively. The bridge listens on
        // 127.0.0.1:<activePort>; the CLI reads the HTTP MCP entry from
        // settings.json's mcpServers field. Skipped when the bridge hasn't
        // bound yet (agent turns pre-startup are rare — worst case Claude
        // Code just doesn't see the OpenClicky tools that turn).
        let bridgePort = OpenClickyExternalControlBridgeServer.activePort
            ?? OpenClickyExternalControlBridgeServer.resolveDefaultPort()
        let settings = buildClaudeSettingsDict(
            baseURL: baseURL,
            effectiveModel: effectiveModel,
            effort: effort,
            mcpBridgePort: Int(bridgePort))
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: base.appendingPathComponent("settings.json"))
        return base
    }

    init() {
        self.relay = MirageLocalRelay()
    }

    /// Run one agent turn. Returns an async stream of parsed events so the
    /// caller can pipe them into the OpenClicky agent bubble / HUD as they
    /// arrive. When the process exits the stream finishes; a cancellation
    /// (Task.cancel) kills the process and closes the stream with .cancelled.
    ///
    /// - Parameters:
    ///   - prompt: the user's transcript / task description
    ///   - workingDirectory: where claude runs (defaults to home)
    ///   - env: extra env vars merged on top of the base spawn env. Useful
    ///     for `CLAUDE_CODE_DISABLE_TELEMETRY=1` etc.
    func run(prompt: String,
             model: String? = nil,
             workingDirectory: URL? = nil,
             extraEnv: [String: String] = [:]) async throws -> AsyncThrowingStream<MirageAgentEvent, Error> {

        guard let claudeBin = Self.locateClaudeBinary() else {
            throw ClaudeAgentRunnerError.claudeBinaryNotFound
        }

        // Start the relay and grab the base URL we'll hand claude.
        let baseURL: URL
        do {
            baseURL = try await relay.start()
        } catch {
            throw ClaudeAgentRunnerError.relayStartFailed(error)
        }

        // We defer the scratch-dir + args build until AFTER we resolve
        // model/effort below, so the settings.json ends up with the
        // effective values baked in.

        // Assemble environment. Start from an empty dict rather than
        // ProcessInfo.processInfo.environment so we don't leak the parent
        // app's ANTHROPIC_* or HTTP_PROXY settings into claude.
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            // Point claude at our relay. It will POST to <base>/v1/messages.
            "ANTHROPIC_BASE_URL": baseURL.absoluteString,
            // Any non-empty api_key satisfies claude's env check; our relay
            // ignores whatever the CLI sends and injects the mirage UUID.
            "ANTHROPIC_API_KEY": "sk-mirage-relay-dummy",
            // CLAUDE_CONFIG_DIR is filled in below once scratchHome is
            // materialised — its value depends on the resolved model +
            // effort, which we compute after this dict is initialised.
            // Turn off any auto-updater / telemetry the CLI may try to run.
            "CLAUDE_CODE_DISABLE_TELEMETRY": "1",
            "DISABLE_AUTOUPDATER": "1",
        ]
        for (k, v) in extraEnv { env[k] = v }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudeBin)

        // CLI arg assembly. Model + `[1m]` suffix come from user settings.
        // Precedence (highest first):
        //   1. Caller-passed `model:` argument (e.g. specific intent needs
        //      a cheaper model for a probe).
        //   2. UserDefaults key `openClickyMirageAgentModel` (Settings →
        //      Peeky Free → Agent model).
        //   3. Static fallback = `mirage/claude-opus-5`.
        //
        // The `mirage/` prefix is stripped before we hand the id to the
        // Claude Code CLI — that prefix is purely OpenClicky's catalog
        // namespace (see MirageBackendClient.normalizeBody) and the CLI /
        // upstream only accept the bare `claude-*` identifier.
        //
        // 1M-context Opus variant is opted into via the
        // `openClickyMirageAgentUse1MContext` bool (default true when the
        // selected model contains `opus`). Appending `[1m]` to the model
        // id is Claude Code's supported syntax for the extended context
        // variant and matches what ~/bin/claude-with-override hardcodes.
        let defaults = UserDefaults.standard
        let rawModel: String = (model?.trimmingCharacters(in: .whitespaces))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? {
                let s = defaults.string(forKey: Self.claudeAgentModelDefaultsKey)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return s.isEmpty ? nil : s
            }()
            ?? Self.defaultAgentModelCatalogID

        let effectiveModel = Self.resolveEffectiveModelID(
            rawModel: rawModel, defaults: defaults)

        // Resolve effort. Same precedence: caller > UserDefaults > fallback.
        let effort: String = {
            let saved = defaults.string(forKey: Self.claudeAgentEffortDefaultsKey)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return saved.isEmpty ? Self.defaultAgentEffort : saved
        }()

        // Now that model + effort are resolved, materialise the scratch
        // CLAUDE_CONFIG_DIR with them baked in.
        let scratchHome: URL
        do {
            scratchHome = try Self.materializeScratchClaudeHome(
                baseURL: baseURL,
                effectiveModel: effectiveModel,
                effort: effort
            )
        } catch {
            await relay.stop()
            throw ClaudeAgentRunnerError.processStartFailed(error)
        }
        self.scratchHomeToCleanup = scratchHome
        env["CLAUDE_CONFIG_DIR"] = scratchHome.path

        var args: [String] = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--model", effectiveModel
        ]

        // Dynamic override.md injection — mirrors the wrapper's behaviour
        // (`if -f "$OVERRIDE"` … `--append-system-prompt-file "$OVERRIDE"`).
        // We probe `~/.claude/override.md` at spawn time so a user edit
        // between turns takes effect immediately. If it isn't present we
        // just skip the arg — Claude Code is fine without one.
        let overridePath = NSString(string: "~/.claude/override.md").expandingTildeInPath
        if FileManager.default.fileExists(atPath: overridePath),
           !args.contains("--append-system-prompt-file") {
            args.append(contentsOf: ["--append-system-prompt-file", overridePath])
        }

        task.arguments = args
        task.environment = env
        // cwd resolution ladder (first match wins):
        //   1. explicit `workingDirectory` param (caller override — e.g.
        //      the orchestrator passes the focused-folder from context)
        //   2. `openClickyMirageAgentWorkingDir` UserDefault (Settings)
        //   3. `~/Dev` if it exists (common dev root)
        //   4. `~` (home) as last resort
        if let cwd = workingDirectory {
            task.currentDirectoryURL = cwd
        } else if let custom = UserDefaults.standard.string(forKey: Self.claudeAgentWorkingDirDefaultsKey),
                  !custom.isEmpty,
                  FileManager.default.fileExists(atPath: (custom as NSString).expandingTildeInPath) {
            task.currentDirectoryURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            let dev = NSHomeDirectory() + "/Dev"
            task.currentDirectoryURL = URL(fileURLWithPath:
                FileManager.default.fileExists(atPath: dev) ? dev : NSHomeDirectory())
        }

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        // Provide a closed stdin so claude doesn't block waiting for input.
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            await relay.stop()
            throw ClaudeAgentRunnerError.processStartFailed(error)
        }
        self.process = task

        // Bridge process stdout → parsed event stream. Uses Foundation's
        // `readabilityHandler` (same pattern as CodexProcessManager.swift
        // line 165) so events surface immediately when claude flushes,
        // instead of polling on a 30ms sleep loop.
        let (eventStream, cont) = AsyncThrowingStream<MirageAgentEvent, Error>.makeStream()
        let lineBuffer = LineBuffer()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = lineBuffer.appendAndDrain(data)
            for line in lines {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    let type = obj["type"] as? String ?? "unknown"
                    cont.yield(MirageAgentEvent(type: type, raw: obj))
                }
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            NSLog("[ClaudeAgentRunner] claude stderr: \(text)")
        }

        task.terminationHandler = { [weak self] terminated in
            // Detach handlers so Foundation drops the pipes.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let code = terminated.terminationStatus
            if code == 0 {
                cont.finish()
            } else {
                cont.finish(throwing: ClaudeAgentRunnerError.processExited(code))
            }
            Task { await self?.tearDown() }
        }

        self.stdoutStream = eventStream
        return eventStream
    }

    /// Split a growing byte buffer on `0x0A` boundaries. Used because
    /// readabilityHandler chunk boundaries do not respect line boundaries
    /// but stream-json is one JSON per line.
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()
        func appendAndDrain(_ chunk: Data) -> [Data] {
            lock.lock(); defer { lock.unlock() }
            pending.append(chunk)
            var out: [Data] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: 0..<nl)
                pending.removeSubrange(0...nl)
                if !line.isEmpty { out.append(line) }
            }
            return out
        }
    }

    /// Barge-in / user cancel. Kills the process (SIGTERM, then SIGKILL if
    /// still alive after 500ms) and tears the relay down.
    func cancel() {
        if let p = process, p.isRunning {
            p.terminate()
            // Escalate if still alive shortly after.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let p = await self?.process, p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Idempotent cleanup called after the process ends or on cancel.
    private func tearDown() async {
        await relay.stop()
        process = nil
        stdoutStream = nil
        if let dir = scratchHomeToCleanup {
            try? FileManager.default.removeItem(at: dir)
            scratchHomeToCleanup = nil
        }
    }
}
