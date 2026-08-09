//
//  PeekyFreePanelView.swift
//  cursor-buddy
//
//  Settings panel for the Peeky Free (mirage) profile lane. Mirrors the
//  shape of `SKIModePanelView` — one scrollable page grouped by role:
//    * Status: whether MirageSecrets is configured, active profile, quota.
//    * Model picker (mirage catalog subset).
//    * STT lane selector (mirageDeepgram vs whisperLocal for offline).
//    * TTS lane selector (mirageCartesia vs microsoftEdge for offline).
//    * Classifier controls: bootstrap state, confidence threshold hint.
//    * Automation shortcut: "run e2e test" button that fires
//      openclicky_set_profile + a canned utterance sweep.

import SwiftUI

/// Inline zh-Hans strings for Peeky Free settings. Selected by the active
/// `OpenClickyLocaleManager` language — no Localizable.strings needed. We
/// keep the two languages inline so the panel isn't blocked on a full
/// project-wide .lproj rollout.
private enum PeekyPanelStrings {
    static func t(_ en: String, _ zh: String, lang: String) -> String {
        lang.hasPrefix("zh") ? zh : en
    }
}

struct PeekyFreePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var openClickyLocale: OpenClickyLocaleManager = .shared
    @State private var classifierReadyRefreshTick: Int = 0
    @State private var lastAutomationResult: String = ""
    @State private var showsCustomVoiceUUID: Bool = false

    private var lang: String { openClickyLocale.currentLanguage }
    private func t(_ en: String, _ zh: String) -> String {
        PeekyPanelStrings.t(en, zh, lang: lang)
    }

    var body: some View {
        // Profile-specific tab: expose knobs the Peeky Free lane actually
        // owns — dialog model, agent model, thinking levels, Cartesia
        // voice, working dir. Every choice here is scoped to the mirage/
        // catalog so you can't accidentally jump to a HeyClicky /
        // Anthropic-direct model from this tab. Cross-profile switches
        // live in Advanced Providers.
        VStack(alignment: .leading, spacing: 16) {
            statusGroup
            modelGroup
            thinkingLevelGroup
            agentModelGroup
            sttGroup
            ttsGroup
            betaGroup
            claudeCodeSettingsGroup
            configExportGroup
            classifierGroup
        }
        .padding(.top, 4)
        // Re-render with the active locale so both `Text` literals and
        // formatters flip when the user changes language in Settings.
        // Matches the SKI / HeyClicky settings pattern.
        .environment(\.locale, openClickyLocale.currentLocale)
    }

    // MARK: - Status

    private var statusGroup: some View {
        settingsGroup(t("Lane status", "通道状态")) {
            HStack(spacing: 10) {
                Circle()
                    .fill(MirageSecrets.isConfigured ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MirageSecrets.isConfigured
                         ? t("aegis-proxy is configured", "aegis-proxy 已配置")
                         : t("aegis-proxy endpoint is empty — Peeky Free lane will refuse to route.",
                             "aegis-proxy 端点为空 — Peeky Free 通道会拒绝路由"))
                        .font(.system(size: 12, weight: .regular))
                    Text(t("The public git tree ships MirageSecrets.swift empty. Local builds fill it in and `git update-index --skip-worktree` the file.",
                           "公开 git 里 MirageSecrets.swift 是空的。本地构建填好后用 `git update-index --skip-worktree` 隐藏改动。"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Divider().opacity(0.3)
            HStack(spacing: 12) {
                Text(t("Active profile:", "当前配置:"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(OpenClickyProfileCatalog.activeProfile().displayName)
                    .font(.system(size: 11, weight: .semibold))
                if OpenClickyProfileCatalog.activeProfile().id == "mirage" {
                    Text(t("(you're on this lane)", "(已在此通道)"))
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                } else {
                    Button(t("Switch to Peeky Free", "切换到 Peeky Free")) {
                        companionManager.applyProfile(OpenClickyProfileCatalog.mirage)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
                Spacer()
            }
            Divider().opacity(0.3)
            rotationCounterRow
        }
    }

    /// Approximate "how close am I to the next anonymous UUID rotation".
    /// Reads `MirageBackendClient.snapshot()` on view refresh — the
    /// values are actor state so this is a snapshot at render time, not
    /// a live subscription. Close-enough diagnostic for "roughly how
    /// many turns before proxy quota rolls onto a new identity".
    @State private var lastRotationSnapshot: (deviceID: String, counter: Int, rotateAt: Int)? = nil

    private var rotationCounterRow: some View {
        HStack(spacing: 12) {
            Text(t("UUID rotation:", "UUID 轮换:"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let s = lastRotationSnapshot {
                Text("\(s.counter) / \(s.rotateAt) on \(String(s.deviceID.prefix(8)))…")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            } else {
                Text(t("(fetching…)", "(获取中…)"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(t("Refresh", "刷新")) {
                Task {
                    let s = await MirageBackendClient.shared.snapshot()
                    await MainActor.run { lastRotationSnapshot = s }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .task {
            // First-render snapshot; button covers manual refresh.
            let s = await MirageBackendClient.shared.snapshot()
            await MainActor.run { lastRotationSnapshot = s }
        }
    }

    // MARK: - Model

    private var modelGroup: some View {
        settingsGroup(t("Response model", "回复模型")) {
            Text(t("Peeky Free routes each turn through aegis-proxy to Anthropic. Pick which Claude tier this profile uses when it activates. Fable 5 is the cheapest and matches Peeky's default; Opus/Sonnet variants cost more per turn but are visible for direct A/B.",
                   "Peeky Free 每轮经 aegis-proxy 转发到 Anthropic。选此配置激活时使用的 Claude 级别。Fable 5 最便宜 (Peeky 默认); Opus/Sonnet 每轮更贵, 但方便直接对比。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("Model", "模型"), selection: Binding<String>(
                get: { companionManager.selectedModel },
                set: { companionManager.setSelectedModelPreservingOverride($0) }
            )) {
                Section(header: Text(t("Recommended (free via aegis-proxy)", "推荐 (aegis-proxy 免费)"))) {
                    ForEach(mirageModelIDs, id: \.self) { modelID in
                        Text(mirageModelDisplayName(modelID)).tag(modelID)
                    }
                }
                Section(header: Text(t("Advanced (all providers)", "高级 (全部)"))) {
                    ForEach(advancedModelIDs, id: \.self) { modelID in
                        Text(mirageModelDisplayName(modelID)).tag(modelID)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var mirageModelIDs: [String] {
        OpenClickyModelCatalog.voiceResponseModels
            .filter { $0.id.hasPrefix("mirage/") }
            .map { $0.id }
    }

    /// Every non-mirage model exposed to the dialog picker as an
    /// "Advanced overrides" option. Peeky Free's default stays mirage/…
    /// but a user with a paid Anthropic / OpenAI key can pick a direct
    /// tier here without switching profile. Persisted per-profile via
    /// `setSelectedModelPreservingOverride`.
    private var advancedModelIDs: [String] {
        OpenClickyModelCatalog.voiceResponseModels
            .filter { !$0.id.hasPrefix("mirage/") }
            .map { $0.id }
    }

    private func mirageModelDisplayName(_ modelID: String) -> String {
        OpenClickyModelCatalog.voiceResponseModel(withID: modelID).label
    }

    // MARK: - Thinking level (dialog + agent, independent)

    /// Effort levels available for both dialog and agent lanes. Matches
    /// Peeky's `MirageThinkingSuffix.MirageThinkingLevel` and Claude
    /// Code's `effortLevel` setting (`minimal / low / medium / high /
    /// xhigh / max`).
    /// Dialog / agent effort options.
    ///  - "adaptive" (default) = client-side heuristic picks a level per
    ///    turn: short chit-chat → off, medium turns → minimal, analytical
    ///    questions → low. Fast for casual talk, deeper when it matters.
    ///  - "off" = no thinking at all (Peeky reference parity, fastest).
    ///  - "auto" = Anthropic's server-side adaptive. Slow on fable-5.
    ///  - "low..max" = pinned floor. Deeper but slower on trivial turns.
    private static let thinkingLevels = ["adaptive", "off", "auto", "minimal", "low", "medium", "high", "xhigh", "max"]

    private var thinkingLevelGroup: some View {
        settingsGroup(t("Thinking level", "思考强度")) {
            Text(t("Dialog and agent turns can pick different thinking levels. `auto` (default) lets the model self-adjust per-turn — simple questions stay fast, complex ones get deep thinking automatically. `off` disables thinking entirely (fastest). low..max pin a floor.",
                   "对话和 Agent 轮次可以分别设置思考强度。`auto` (默认) 让模型每轮自适应 — 简单问题快, 复杂问题自动深入。`off` 完全关闭思考 (最快)。low..max 固定下限。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Dialog (chat)", "对话")).font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("", selection: Binding<String>(
                        // Default "adaptive" — client-side heuristic
                        // picks a thinking level per turn based on the
                        // user's utterance (short → off, medium → minimal,
                        // "why/how/explain/…" → low). Users can pin a
                        // specific tier or fully turn off.
                        get: { UserDefaults.standard.string(forKey: ClaudeAgentRunner.dialogEffortDefaultsKey) ?? "adaptive" },
                        set: { UserDefaults.standard.set($0, forKey: ClaudeAgentRunner.dialogEffortDefaultsKey) }
                    )) {
                        ForEach(Self.thinkingLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Agent (Claude Code)", "Agent"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Picker("", selection: Binding<String>(
                        get: { UserDefaults.standard.string(forKey: ClaudeAgentRunner.claudeAgentEffortDefaultsKey) ?? "xhigh" },
                        set: { UserDefaults.standard.set($0, forKey: ClaudeAgentRunner.claudeAgentEffortDefaultsKey) }
                    )) {
                        ForEach(Self.thinkingLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
                Spacer()
            }
        }
    }

    // MARK: - Claude Code specific settings (working dir)

    private var claudeCodeSettingsGroup: some View {
        settingsGroup(t("Claude Code working directory", "Claude Code 工作目录")) {
            Text(t("Directory Claude Code runs in when handling agent turns. Affects which files it can read/edit. Default: ~/Dev if it exists, else your home directory.",
                   "Agent 轮次调 Claude Code 时的工作目录, 决定它能读写哪些文件。默认: ~/Dev (若存在), 否则家目录。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("", text: Binding<String>(
                    get: {
                        UserDefaults.standard.string(forKey: ClaudeAgentRunner.claudeAgentWorkingDirDefaultsKey) ?? ""
                    },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: ClaudeAgentRunner.claudeAgentWorkingDirDefaultsKey)
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: ClaudeAgentRunner.claudeAgentWorkingDirDefaultsKey)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 400)
                Button(t("Pick…", "选择…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        UserDefaults.standard.set(url.path, forKey: ClaudeAgentRunner.claudeAgentWorkingDirDefaultsKey)
                    }
                }
                Text(t("Resolved: \(resolvedWorkingDir())", "当前生效: \(resolvedWorkingDir())"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Export config for external Claude CLI

    @State private var configExportStatus: String = ""
    @State private var relayURL: URL? = nil

    /// Render + copy a settings.json that points the user's own Claude
    /// CLI at OpenClicky's mirage relay. Preserves the user's existing
    /// `~/.claude/settings.json` (MCP servers, hooks, keybinds) — only
    /// overlays the fields the relay needs.
    ///
    /// The button also starts the shared MirageLocalRelay so the URL
    /// pasted into `ANTHROPIC_BASE_URL` actually resolves. Relay stays
    /// up until the app exits.
    private var configExportGroup: some View {
        settingsGroup(t("Use Peeky Free from your own Claude CLI",
                        "在你自己的 Claude CLI 里用 Peeky Free")) {
            Text(t("Generates a settings.json overlay that routes Anthropic requests through OpenClicky's local mirage relay. Copy it, then paste into ~/.claude/settings.json (merges with your existing config). Starts the relay so ANTHROPIC_BASE_URL actually resolves.",
                   "生成一段 settings.json 覆盖片段, 让 Anthropic 请求走 OpenClicky 本地 mirage 中继。复制后粘贴到 ~/.claude/settings.json (与你现有配置合并)。同时会启动中继, 让 ANTHROPIC_BASE_URL 真的能连上。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(t("Copy settings.json", "复制 settings.json")) {
                    Task { await copyConfigToClipboard(kind: .settingsJSON) }
                }
                Button(t("Copy shell exports", "复制 shell 环境变量")) {
                    Task { await copyConfigToClipboard(kind: .shellExports) }
                }
                Spacer()
            }
            if !configExportStatus.isEmpty {
                Text(configExportStatus)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let url = relayURL {
                Text(t("Relay listening: ", "中继监听: ") + url.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private enum ConfigExportKind { case settingsJSON, shellExports }

    @MainActor
    private func copyConfigToClipboard(kind: ConfigExportKind) async {
        // Resolve live settings from the current pickers / defaults.
        // `resolveEffectiveModelID` handles the mirage/ prefix strip and
        // appends `[1m]` when the selected model supports it, so the
        // pasted config matches what OpenClicky's own agent turns use.
        let rawModel = UserDefaults.standard.string(
            forKey: ClaudeAgentRunner.claudeAgentModelDefaultsKey)
            ?? ClaudeAgentRunner.defaultAgentModelCatalogID
        let effectiveModel = ClaudeAgentRunner.resolveEffectiveModelID(rawModel: rawModel)
        let effort = UserDefaults.standard.string(
            forKey: ClaudeAgentRunner.claudeAgentEffortDefaultsKey) ?? "auto"

        // Start the shared relay if not running. Failures fall back to
        // the placeholder URL so the pasted config is still shape-correct
        // — user can swap ports later.
        let baseURL: URL
        do {
            let started = try await MirageLocalRelay.shared.startIfNeeded()
            baseURL = started
            relayURL = started
        } catch {
            baseURL = URL(string: "http://127.0.0.1:0")!
            configExportStatus = t("Relay start failed — pasted config uses placeholder port.",
                                   "中继启动失败 — 配置里是占位端口。")
        }

        let dict = ClaudeAgentRunner.buildClaudeSettingsDict(
            baseURL: baseURL,
            effectiveModel: effectiveModel,
            effort: effort,
            mcpBridgePort: nil)

        let clipboardText: String
        switch kind {
        case .settingsJSON:
            let data = (try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            // JSONSerialization auto-escapes forward slashes ("\/"),
            // which is legal JSON but looks ugly when pasted into
            // ~/.claude/settings.json. The escape is optional per
            // RFC 8259, so post-process to plain "/".
            clipboardText = (String(data: data, encoding: .utf8) ?? "{}")
                .replacingOccurrences(of: "\\/", with: "/")
        case .shellExports:
            // Compact `export KEY=VALUE` block so users can `source` or
            // paste into their shell before running claude.
            let env = (dict["env"] as? [String: String]) ?? [:]
            clipboardText = env
                .sorted(by: { $0.key < $1.key })
                .map { "export \($0.key)=\(shellQuote($0.value))" }
                .joined(separator: "\n")
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clipboardText, forType: .string)
        configExportStatus = t("Copied. Paste into ~/.claude/settings.json (or shell).",
                               "已复制。粘贴到 ~/.claude/settings.json (或 shell)。")
    }

    private func shellQuote(_ s: String) -> String {
        // Single-quote unless the value already contains a single quote;
        // then double-quote and escape. Good enough for keys we emit
        // ourselves — none of them contain `$` or backticks.
        if !s.contains("'") { return "'\(s)'" }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func resolvedWorkingDir() -> String {
        if let custom = UserDefaults.standard.string(forKey: ClaudeAgentRunner.claudeAgentWorkingDirDefaultsKey),
           !custom.isEmpty {
            return (custom as NSString).abbreviatingWithTildeInPath
        }
        let dev = NSHomeDirectory() + "/Dev"
        return FileManager.default.fileExists(atPath: dev) ? "~/Dev" : "~"
    }

    // MARK: - Agent (Claude Code) model — separate from dialog model

    /// Peeky Free's `intent = agent` branch delegates to the local Claude
    /// Code binary via `ClaudeAgentRunner`. That agent's model is stored
    /// under `openClickyMirageAgentModel` and is INDEPENDENT of the dialog
    /// response model — chat / find_action / integration / memory use
    /// `selectedModel`, but agent turns can pick a stronger tier for
    /// planning without paying for it on every non-agent turn.
    private var agentModelGroup: some View {
        settingsGroup(t("Agent model (Claude Code)", "Agent 模型 (Claude Code)")) {
            Text(t("Used ONLY for `peeky agent, …` turns (routed to the local Claude Code binary). Dialog / integration / memory turns still use the response model above. Pick a stronger tier here if you want deeper agent planning without paying for it on every voice reply.",
                   "仅用于 `peeky agent, …` 触发的 Agent 轮次 (转发到本地 Claude Code 二进制)。对话/工具/记忆轮次仍走上方的回复模型。想让 Agent 规划更强, 又不想每轮语音都变贵, 就在这里选更强的档。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("Agent model", "Agent 模型"), selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: ClaudeAgentRunner.claudeAgentModelDefaultsKey)
                        ?? ClaudeAgentRunner.defaultAgentModelCatalogID
                },
                set: { companionManager.setAgentModelPreservingOverride($0) }
            )) {
                Section(header: Text(t("Recommended (free via aegis-proxy)", "推荐 (aegis-proxy 免费)"))) {
                    ForEach(mirageModelIDs, id: \.self) { modelID in
                        Text(mirageModelDisplayName(modelID)).tag(modelID)
                    }
                }
                Section(header: Text(t("Advanced (all providers)", "高级 (全部)"))) {
                    ForEach(advancedModelIDs, id: \.self) { modelID in
                        Text(mirageModelDisplayName(modelID)).tag(modelID)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    // MARK: - TTS

    /// Curated Cartesia voice IDs — same catalog Peeky's reference client
    /// ships. Users can also paste a raw UUID in the text field below to
    /// use any Cartesia voice not on this list.
    /// Cartesia voices the aegis-proxy free tier is authorised to serve.
    /// This is a hand-verified subset of Cartesia's public catalog —
    /// aegis-proxy's token mint only whitelists specific voice IDs, so
    /// picking one outside this list will 404. The user's own dashboard
    /// UUID can still be pasted via the "Advanced" field below.
    ///
    /// If a voice here starts returning voice_not_found, remove it. Log:
    /// `voice.response_failure_silent` with `voice_not_found` in the
    /// error body.
    private static let cartesiaVoices: [(id: String, name: String, gender: String)] = [
        ("a0e99841-438c-4a64-b679-ae501e7d6091", "Barbershop Man", "male"),
        // "Storyteller Lady" (41534ada-...) removed — returns 404
        // voice_not_found on aegis-proxy free tier.
        ("00a77add-48d5-4ef6-8157-71e5437b282d", "Casual Man", "male"),
        ("87748186-23bb-4158-a1eb-332911b0b708", "Wizardman", "male"),
        ("2ee87190-8f84-4925-97da-e52547f9462c", "Child", "child"),
        ("2b568345-1d48-4047-b25f-7baccf842eb0", "Kentucky Woman", "female"),
        ("39b376fc-488e-4d0c-8b37-e00b72059fdd", "Merchant", "male"),
        ("bf991597-6c13-47e4-8411-91ec2de5c466", "Newsman", "male"),
        ("d7862948-75c3-4c7c-ae28-2959fe166f49", "British Reading Lady", "female"),
        ("f9836c6e-a0bd-460e-9d3c-f7299fa60f94", "Southern Woman", "female")
    ]

    /// STT picker — Peeky Free's recommended lane is
    /// `mirageDeepgram` (free Deepgram via aegis-proxy). Users with a
    /// paid Deepgram key or offline preference can override here; the
    /// choice is persisted per-profile via
    /// `setVoiceTranscriptionProviderPreservingOverride`.
    private var sttProviderIDs: [String] {
        BuddyTranscriptionProviderID.allCases.map { $0.rawValue }
    }

    private var sttGroup: some View {
        settingsGroup(t("Speech-to-text", "语音识别")) {
            Text(t("Peeky Free's recommended STT is Deepgram routed through aegis-proxy (free, ~20 turns/day). Pick anything else here to override for this profile only.",
                   "Peeky Free 默认走 aegis-proxy 免费 Deepgram (~20 轮/天)。选其他只覆盖此配置。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("STT", "STT"), selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
                        ?? BuddyTranscriptionProviderID.mirageDeepgram.rawValue
                },
                set: { companionManager.setVoiceTranscriptionProviderPreservingOverride($0) }
            )) {
                ForEach(sttProviderIDs, id: \.self) { providerID in
                    Text(BuddyTranscriptionProviderID(rawValue: providerID)?.label ?? providerID)
                        .tag(providerID)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    private var ttsGroup: some View {
        settingsGroup(t("Cartesia voice", "Cartesia 声音")) {
            Text(t("Peeky Free's default TTS is Cartesia via aegis-proxy — no personal Cartesia key needed. Pick which voice to use. To switch TTS provider entirely (e.g. Edge Neural for offline), use Advanced Providers.",
                   "Peeky Free 默认 TTS 是 Cartesia (经 aegis-proxy), 无需个人 Cartesia key。选一个声音即可。想彻底换 TTS 引擎 (比如 Edge Neural 离线), 去「高级 Provider」。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Cartesia voice picker + preview — always visible on the
            // Peeky tab since Cartesia is the lane default. If the user
            // has flipped to a non-Cartesia provider globally, we still
            // let them tune the Cartesia voice here so switching back
            // works instantly.
            if true {
                Divider().opacity(0.3)
                HStack(spacing: 8) {
                    Text(t("Voice:", "声音:"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding<String>(
                        get: {
                            UserDefaults.standard.string(forKey: AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey)
                                ?? Self.cartesiaVoices[0].id
                        },
                        set: { companionManager.setCartesiaVoiceID($0) }
                    )) {
                        ForEach(Self.cartesiaVoices, id: \.id) { v in
                            Text("\(v.name) (\(v.gender))").tag(v.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    Button(t("Preview", "试听")) {
                        let sample = t("Hi, I'm your Peeky Free voice. Say switch to Peeky to activate me.",
                                       "你好, 我是你的 Peeky Free 语音。说 \"切换到 Peeky\" 来激活我。")
                        companionManager.previewCurrentTTSVoice(sample)
                    }
                    Spacer()
                }
                // Custom voice UUID field — collapsed by default because
                // 99% of users just want a preset. Advanced users who
                // grabbed a Cartesia voice UUID from their dashboard can
                // toggle it open to paste their own.
                DisclosureGroup(
                    isExpanded: $showsCustomVoiceUUID,
                    content: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("Paste any Cartesia voice UUID from your dashboard. Overrides the picker above until cleared.",
                                   "粘贴 Cartesia 面板上任一 voice UUID, 会覆盖上方 picker, 清空后恢复。"))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            TextField("Voice UUID", text: Binding<String>(
                                get: {
                                    UserDefaults.standard.string(forKey: AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) ?? ""
                                },
                                set: { companionManager.setCartesiaVoiceID($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 400)
                        }
                        .padding(.top, 4)
                    },
                    label: {
                        Text(t("Advanced: custom voice UUID", "高级: 自定义 voice UUID"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                )
            }
        }
    }

    // MARK: - Classifier

    /// Anthropic-beta toggles. 1M context is ON by default so
    /// Opus/Sonnet-4.6/Fable-5 turns actually use their full window
    /// (aegis-proxy's key normally has the entitlement). Users who see
    /// silent 400s can flip this OFF as a diagnostic.
    ///
    /// `@AppStorage` (not `@State` snapshot) so external writes to
    /// UserDefaults (a Settings reset, a defaults sync from another
    /// window, etc.) re-render this toggle live instead of staying on
    /// the first-launch value.
    @AppStorage("openClickyMirage1MContextDisabled")
    private var oneMillionContextDisabled: Bool = false

    private var betaGroup: some View {
        settingsGroup(t("Anthropic beta headers", "Anthropic beta 头")) {
            Toggle(isOn: Binding<Bool>(
                get: { !oneMillionContextDisabled },
                set: { v in
                    // @AppStorage writes through to UserDefaults, so
                    // no explicit .set(forKey:) call is needed here.
                    oneMillionContextDisabled = !v
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("1M context window (Opus/Sonnet-4.6/Fable-5) — ON",
                           "1M 上下文窗口 (Opus/Sonnet-4.6/Fable-5) — 开启"))
                    Text(t("Sends anthropic-beta: context-1m-2025-08-07 when the selected model supports it. Turn off only if you see silent 400s (means the proxy operator's key lacks the entitlement).",
                           "选中的模型支持时会附加 anthropic-beta: context-1m-2025-08-07。仅在看到静默 400 时关闭 (说明代理方 key 没这个权限)。"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var classifierGroup: some View {
        settingsGroup(t("On-device intent classifier", "本地意图分类器")) {
            let _ = classifierReadyRefreshTick
            Text(t("A local MiniLM ONNX model (~127 MB, ships in the app bundle) labels every utterance into one of chat / find_action / integration / memory before touching the network. Confidence threshold matches Peeky's tuning (0.85). Fires locally, saves aegis-proxy quota.",
                   "本地 MiniLM ONNX 模型 (~127 MB, 打包在 app 内), 在联网前把每句话标为 chat / find_action / integration / memory 之一。置信度阈值 0.85 (与 Peeky tuning 一致)。本地跑, 省 aegis-proxy 额度。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(t("Warm classifier", "预热分类器")) {
                    Task.detached(priority: .utility) {
                        _ = await OpenClickyIntentClassifier.shared.bootstrap()
                        await MainActor.run { classifierReadyRefreshTick += 1 }
                    }
                }
                Text(t("Idempotent — safe to run multiple times.", "幂等 — 可多次执行。"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Automation

    private var automationGroup: some View {
        settingsGroup(t("Automation smoke test", "自动化冒烟测试")) {
            Text(t("Fires 5 canned utterances (one per intent) through the automation MCP endpoint, exercising the exact same pipeline a real voice PTT would. Uses `openclicky_set_profile` then `openclicky_simulate_voice_turn`.",
                   "通过自动化 MCP 端点发 5 条固定话术 (每个 intent 一条), 走真实 PTT 的完整流水线。使用 `openclicky_set_profile` 加 `openclicky_simulate_voice_turn`。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(t("Run smoke test", "运行冒烟测试")) {
                    lastAutomationResult = t("Running...", "运行中...")
                    Task {
                        let result = await runInProcessSmokeTest()
                        await MainActor.run { lastAutomationResult = result }
                    }
                }
                Text(lastAutomationResult)
                    .font(.system(size: 11))
                    .foregroundColor(lastAutomationResult.contains("failed") ? .red : .secondary)
                Spacer()
            }
            Text(t("For headless CI, run `scripts/mirage-e2e-test.sh` — same test with detailed log output.",
                   "如需无头 CI, 跑 `scripts/mirage-e2e-test.sh` — 同样的测试, 详细日志输出。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    /// In-process smoke test that fires 5 mirage turns via the orchestrator
    /// directly (bypasses the HTTP MCP endpoint so no token is needed).
    /// Same 5 utterances the shell script uses. Reports pass / fail count.
    private func runInProcessSmokeTest() async -> String {
        let orch = MiragePeekyOrchestrator.shared
        let utterances: [(String, MirageIntent)] = [
            ("hello there, tell me a joke", .chat),
            ("pause spotify", .integration),
            ("click the login button", .findAction),
            ("remember my favorite color is blue", .memory),
            ("peeky agent, open finder", .agent)
        ]
        var pass = 0
        for (text, expected) in utterances {
            let result = await orch.runTurn(
                transcript: text,
                modelForBranches: "mirage/claude-fable-5",
                onTextChunk: { _ in }
            )
            if result.intent == expected { pass += 1 }
        }
        return pass == utterances.count
            ? t("\(pass)/\(utterances.count) intents match", "\(pass)/\(utterances.count) 意图匹配")
            : t("\(pass)/\(utterances.count) intents match — check log tail",
                "\(pass)/\(utterances.count) 意图匹配 — 请查看日志")
    }

    // MARK: - Helpers (match SKI panel style)

    @ViewBuilder
    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }
}
