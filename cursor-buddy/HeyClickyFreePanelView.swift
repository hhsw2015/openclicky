//
//  HeyClickyFreePanelView.swift
//  cursor-buddy
//
//  Settings tab for the HeyClicky Free profile. Mirrors the shape of
//  `SKIModePanelView` / `PeekyFreePanelView` so all three free lanes have
//  parity: status → quota → knobs → automation shortcut.
//
//  The full sign-in / reset / Chrome bridge / realtime WS UI already lives
//  in the shared `heyClickyFreeGroup` under Advanced Providers; this tab
//  surfaces the same knobs at their new home so users on the HeyClicky
//  Free profile don't need to hunt for them under the generic providers
//  section.

import SwiftUI

struct HeyClickyFreePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var heyClickyPlan = HeyClickyPlanClient.shared
    @ObservedObject private var openClickyLocale: OpenClickyLocaleManager = .shared
    @State private var refreshTick: Int = 0
    @State private var statusMessage: String = ""

    private var lang: String { openClickyLocale.currentLanguage }
    private func t(_ en: String, _ zh: String) -> String {
        lang.hasPrefix("zh") ? zh : en
    }

    var body: some View {
        // Profile-specific tab: scoped to what HeyClicky Free actually
        // owns — model choice (only heyclicky-free-* entries), voice,
        // assist-agent + quota. Cross-profile / other-provider knobs
        // live in Advanced Providers.
        VStack(alignment: .leading, spacing: 16) {
            statusGroup
            modelGroup
            agentModelGroup
            sttGroup
            quotaGroup
            voiceGroup
            assistAgentGroup
            actionsGroup
        }
        .padding(.top, 4)
        .environment(\.locale, openClickyLocale.currentLocale)
        .onAppear {
            Task { await heyClickyPlan.refresh() }
        }
    }

    // MARK: - Sign-in status

    private var statusGroup: some View {
        settingsGroup(t("Sign-in status", "登录状态")) {
            let _ = refreshTick
            let signedIn = AppBundleConfiguration.heyClickySignedIn()
            HStack(spacing: 10) {
                Circle()
                    .fill(signedIn ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    if signedIn {
                        Text(t("Signed in as \(AppBundleConfiguration.heyClickySessionUserEmail() ?? "(unknown)")",
                               "已登录 \(AppBundleConfiguration.heyClickySessionUserEmail() ?? "(未知)")"))
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(t("Not signed in", "未登录"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(t("HeyClicky Free routes voice + chat through the HeyClicky proxy using your Google/OAuth session — no personal API key needed. Sign-in also unlocks proxy-minted OpenAI Realtime + Deepgram tokens.",
                           "HeyClicky Free 用你的 Google/OAuth 会话经 HeyClicky proxy 转发语音+对话, 无需个人 API key。登录后同时解锁代理签发的 OpenAI Realtime + Deepgram token。"))
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
                if OpenClickyProfileCatalog.activeProfile().id == "heyclicky_free" {
                    Text(t("(you're on this lane)", "(已在此通道)"))
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                } else {
                    Button(t("Switch to HeyClicky Free", "切换到 HeyClicky Free")) {
                        companionManager.applyProfile(OpenClickyProfileCatalog.heyclickyFree)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
                Spacer()
            }
        }
    }

    // MARK: - Quota

    private var quotaGroup: some View {
        settingsGroup(t("Free quota", "免费额度")) {
            let _ = refreshTick
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let plan = heyClickyPlan.latest {
                        Text(plan.remainingText)
                            .font(.system(size: 12, weight: .medium))
                    } else if heyClickyPlan.isRefreshing {
                        Text(t("Loading…", "加载中…"))
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(t("Not loaded — the proxy may be cold-starting. Hit Refresh below.",
                               "未加载 — 代理可能冷启动中, 点下方刷新。"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Text(t("Quota resets automatically on the proxy side. Reset now uses one account-reset credit; use sparingly.",
                           "额度会在代理端自动重置。立即重置会消耗一次账号重置额度, 谨慎使用。"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(t("Refresh quota", "刷新额度")) {
                    Task { await heyClickyPlan.refresh() }
                }
                Button(t("Reset free quota now", "立即重置免费额度")) {
                    _ = HeyClickyAccountResetManager.shared.attemptReset(reason: "settings_tab")
                    statusMessage = t("Reset requested.", "已请求重置。")
                }
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Model (heyclicky-free catalog)

    /// HeyClicky Free's own three response tiers (proxy-published).
    /// These are what the profile ships by default and stay pinned at
    /// the top of the model picker.
    private var recommendedModelIDs: [String] {
        OpenClickyModelCatalog.voiceResponseModels
            .filter { $0.id.hasPrefix("heyclicky-free") }
            .map { $0.id }
    }

    /// Every other model in the catalog — surfaced as "Advanced" so a
    /// power user on HeyClicky Free can point the dialog turn at e.g. a
    /// direct Anthropic or OpenAI key, or borrow mirage's free Cartesia
    /// TTS. Choice is persisted per-profile via
    /// `setSelectedModelPreservingOverride`, so a later profile toggle
    /// does not clobber it.
    private var advancedModelIDs: [String] {
        OpenClickyModelCatalog.voiceResponseModels
            .filter { !$0.id.hasPrefix("heyclicky-free") }
            .map { $0.id }
    }

    private var modelGroup: some View {
        settingsGroup(t("Response model", "回复模型")) {
            Text(t("HeyClicky Free proxies three tiers. Chat = text replies with tool use. Realtime speech = full voice-in / voice-out through OpenAI Realtime. The bubble picks the right one per turn.",
                   "HeyClicky Free 代理三档: Chat = 文本回复 + 工具调用。Realtime speech = 全语音进出 (OpenAI Realtime)。气泡按需自动选择。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("Model", "模型"), selection: Binding<String>(
                get: { companionManager.selectedModel },
                set: { companionManager.setSelectedModelPreservingOverride($0) }
            )) {
                Section(header: Text(t("Recommended", "推荐"))) {
                    ForEach(recommendedModelIDs, id: \.self) { modelID in
                        Text(OpenClickyModelCatalog.voiceResponseModel(withID: modelID).label)
                            .tag(modelID)
                    }
                }
                Section(header: Text(t("Advanced (all providers)", "高级 (全部)"))) {
                    ForEach(advancedModelIDs, id: \.self) { modelID in
                        Text(OpenClickyModelCatalog.voiceResponseModel(withID: modelID).label)
                            .tag(modelID)
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    // MARK: - Voice (OpenAI Realtime)

    /// Voice IDs published by OpenAI Realtime that the HeyClicky proxy
    /// forwards without modification. Matches the list in the shared
    /// settings section so users see the same choices whether they open
    /// this tab or Advanced Providers.
    private static let realtimeVoices: [(id: String, label: String)] = [
        ("marin", "Marin (feminine)"),
        ("cedar", "Cedar (masculine)"),
        ("alloy", "Alloy"),
        ("ash", "Ash"),
        ("ballad", "Ballad"),
        ("coral", "Coral"),
        ("echo", "Echo"),
        ("sage", "Sage"),
        ("shimmer", "Shimmer"),
        ("verse", "Verse")
    ]

    /// Codex Agent Mode's model id — separate storage key
    /// (`clickyCodexModel`), separate from the dialog model above. Peeky
    /// Free's panel has the same split; keep parity here so a HeyClicky
    /// user does not have to leave the tab to set which model handles
    /// long-form Codex agent runs.
    private var codexActionsModelIDs: [String] {
        OpenClickyModelCatalog.codexActionsModels.map { $0.id }
    }

    private var agentModelGroup: some View {
        settingsGroup(t("Agent model", "Agent 模型")) {
            Text(t("Which model handles Codex Agent Mode turns (multi-turn edits, tool use). Independent of the dialog model above — pick the one whose reasoning depth you want for planning + editing files.",
                   "哪个模型处理 Codex Agent Mode 任务 (多轮编辑, 工具调用)。与上面的对话模型独立 — 按你希望的推理深度挑一个。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("Agent model", "Agent 模型"), selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: "clickyCodexModel")
                        ?? OpenClickyModelCatalog.defaultCodexActionsModelID
                },
                set: { companionManager.setAgentModelPreservingOverride($0) }
            )) {
                ForEach(codexActionsModelIDs, id: \.self) { modelID in
                    Text(OpenClickyModelCatalog.codexActionsModels
                        .first { $0.id == modelID }?.label ?? modelID)
                        .tag(modelID)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    /// Speech-to-text lane. HeyClicky Free proxies through OpenAI
    /// Realtime for the speech turn, but the *dictation* / text tier
    /// still picks a first-pass STT (used for classification, tool
    /// calls, and the mini-chat text field). Same three profiles all
    /// expose the STT lane so users can override per-profile
    /// (e.g. offline whisper) without leaving the tab.
    private var sttProviderIDs: [String] {
        // Show every provider, ordered so the profile's recommended
        // choice ends up near the top via `.picker` alphabetical fold.
        BuddyTranscriptionProviderID.allCases.map { $0.rawValue }
    }

    private var sttGroup: some View {
        settingsGroup(t("Speech-to-text", "语音识别")) {
            Text(t("Which STT engine turns your voice into text before the response model sees it. HeyClicky Free's recommended lane is Deepgram via the proxy; pick anything else here to override for this profile only.",
                   "把你的语音转成文字给回复模型看的 STT 引擎。HeyClicky Free 默认走 proxy 的 Deepgram; 选其他项只覆盖此配置。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(t("STT", "STT"), selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
                        ?? BuddyTranscriptionProviderID.automatic.rawValue
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

    private var voiceGroup: some View {
        settingsGroup(t("Voice", "声音")) {
            Text(t("HeyClicky Free routes voice replies through OpenAI Realtime via the HeyClicky proxy. Pick which realtime voice you'd like — the proxy passes the voice id straight through, no extra cost.",
                   "HeyClicky Free 用 HeyClicky proxy 转发 OpenAI Realtime 语音回复。选一个 realtime 声音 — 代理直接透传 voice id, 不额外消耗。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(t("Voice:", "声音:"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Picker("", selection: Binding<String>(
                    get: {
                        UserDefaults.standard.string(forKey: AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey)
                            ?? Self.realtimeVoices[0].id
                    },
                    set: { newValue in
                        UserDefaults.standard.set(newValue, forKey: AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey)
                    }
                )) {
                    ForEach(Self.realtimeVoices, id: \.id) { v in
                        Text(v.label).tag(v.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Button(t("Preview", "试听")) {
                    let voiceID = UserDefaults.standard.string(forKey: AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey)
                        ?? Self.realtimeVoices[0].id
                    Task { await companionManager.previewOpenAIRealtimeVoice(voiceID: voiceID) }
                }
                Spacer()
            }
        }
    }

    // MARK: - Assist Agent

    private var assistAgentGroup: some View {
        settingsGroup(t("Assist Agent", "辅助代理")) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Multi-round tool use", "多轮工具调用"))
                        .font(.system(size: 12, weight: .medium))
                    Text(t("Lets the model chain extra tool calls (search / read / act) inside one turn. Off = context-only injection, fastest and cheapest. On = deeper answers, more quota per turn.",
                           "允许模型在一轮内链式调用工具 (搜索/读取/操作)。关 = 只注入上下文, 最快最省。开 = 更深入回答, 单轮消耗更多额度。"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { AppBundleConfiguration.assistAgentEnabled() },
                    set: { AppBundleConfiguration.setAssistAgentEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Actions

    private var actionsGroup: some View {
        settingsGroup(t("Diagnostics & advanced", "诊断与高级")) {
            Text(t("Sign-in flow, Chrome bridge, OAuth callback debugging, and the realtime WS setup live under Advanced Providers — this tab surfaces the day-to-day knobs; Advanced Providers has the full toolkit.",
                   "登录流程、Chrome 桥、OAuth 回调调试和 realtime WS 配置都在「高级 Provider」标签页 — 这里是常用开关, 完整工具在「高级 Provider」。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helper

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
