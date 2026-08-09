//
//  AppBundleConfiguration.swift
//  cursor-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation
import NaturalLanguage
import Security

nonisolated enum AppBundleConfiguration {
    static let userAnthropicAPIKeyDefaultsKey = "openClickyAnthropicAPIKey"
    static let userElevenLabsAPIKeyDefaultsKey = "openClickyElevenLabsAPIKey"
    static let userElevenLabsVoiceIDDefaultsKey = "openClickyElevenLabsVoiceID"
    static let userCartesiaAPIKeyDefaultsKey = "openClickyCartesiaAPIKey"
    static let userCartesiaVoiceIDDefaultsKey = "openClickyCartesiaVoiceID"
    static let userOpenAIRealtimeVoiceIDDefaultsKey = "openClickyOpenAIRealtimeVoiceID"
    static let userMicrosoftEdgeVoiceIDDefaultsKey = "openClickyMicrosoftEdgeVoiceID"
    /// Deepgram TTS reuses the existing Deepgram STT API key
    /// (`userDeepgramAPIKeyDefaultsKey`). Only the voice/model is
    /// TTS-specific.
    static let userDeepgramTTSVoiceDefaultsKey = "openClickyDeepgramTTSVoice"
    static let userDeepgramVoiceAgentThinkModelDefaultsKey = "openClickyDeepgramVoiceAgentThinkModel"
    static let userTTSProviderDefaultsKey = "openClickyTTSProvider"
    static let openClickyVoicePlaybackVolumeDefaultsKey = "openClickyVoicePlaybackVolume"
    static let defaultVoicePlaybackVolume = 0.45
    static let userSpeculativePreFireDefaultsKey = "openClickySpeculativePreFireEnabled"
    static let userVoiceResponseCaptionsEnabledDefaultsKey = "openClickyVoiceResponseCaptionsEnabled"
    static let userVoiceResponseCaptionFontDefaultsKey = "openClickyVoiceResponseCaptionFont"
    static let userVoiceResponseCaptionOpacityDefaultsKey = "openClickyVoiceResponseCaptionOpacity"
    /// Language the assistant should speak in. Codes: "auto" (follow user
    /// speech), "zh" (Chinese), "en" (English), "ja", "es", "fr", "de".
    /// Injected as an instruction prefix into every Realtime session.update.
    static let userVoiceResponseLanguageDefaultsKey = "openClickyVoiceResponseLanguage"
    static func voiceResponseLanguage() -> String {
        userDefaultsValue(forKey: userVoiceResponseLanguageDefaultsKey) ?? "auto"
    }
    /// Non-nil human-readable instruction snippet for the assistant.
    /// Empty when "auto" so we don't override the model's natural
    /// language detection.
    static func voiceResponseLanguageInstruction() -> String? {
        switch voiceResponseLanguage() {
        case "zh": return "Always reply in Simplified Chinese (简体中文). Speak fluent, natural Mandarin. Do not switch to English unless the user explicitly asks."
        case "en": return "Always reply in English. Do not switch languages unless the user explicitly asks."
        case "ja": return "Always reply in Japanese (日本語). Do not switch languages unless the user explicitly asks."
        case "es": return "Always reply in Spanish (Español). Do not switch languages unless the user explicitly asks."
        case "fr": return "Always reply in French (Français). Do not switch languages unless the user explicitly asks."
        case "de": return "Always reply in German (Deutsch). Do not switch languages unless the user explicitly asks."
        default: return nil
        }
    }
    /// FIX(ai-audit-2026-08-01 #1): per-turn language detection. When
    /// voiceResponseLanguage=="auto", detect the language of the actual
    /// user transcript so we can hint the LLM ("Reply in Chinese since
    /// the user just spoke Chinese"). Fixes bilingual users getting
    /// English replies to Chinese questions.
    /// Returns BCP-47 code ("zh", "en", "ja", …) or nil if inconclusive.
    static func detectedTranscriptLanguage(_ transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        // Confidence gate — reject weak signal (e.g. code snippets).
        let hyps = recognizer.languageHypotheses(withMaximum: 1)
        if let top = hyps[lang], top < 0.6 { return nil }
        return lang.rawValue
    }

    /// Build a language instruction for THIS specific turn. Prefers user
    /// setting; falls back to per-turn detection when setting is "auto".
    static func voiceResponseLanguageInstruction(forTranscript transcript: String) -> String? {
        if let explicit = voiceResponseLanguageInstruction() { return explicit }
        guard let detected = detectedTranscriptLanguage(transcript) else { return nil }
        switch detected {
        case "zh", "zh-Hans", "zh-Hant":
            return "The user just spoke in Chinese. Reply in Simplified Chinese unless they explicitly ask otherwise."
        case "en":
            return "The user just spoke in English. Reply in English."
        case "ja":
            return "The user just spoke in Japanese. Reply in Japanese."
        case "es":
            return "The user just spoke in Spanish. Reply in Spanish."
        case "fr":
            return "The user just spoke in French. Reply in French."
        case "de":
            return "The user just spoke in German. Reply in German."
        default:
            return nil
        }
    }

    static let defaultVoiceResponseCaptionOpacity = 0.92
    static let userAppFontDefaultsKey = "openClickyAppFont"
    static let userAppTitleFontSizeDefaultsKey = "openClickyAppTitleFontSize"
    static let userAppBodyFontSizeDefaultsKey = "openClickyAppBodyFontSize"
    static let userAppSubtextFontSizeDefaultsKey = "openClickyAppSubtextFontSize"
    static let userAppLineSpacingDefaultsKey = "openClickyAppLineSpacing"
    static let userAppBoldTextDefaultsKey = "openClickyAppBoldTextEnabled"
    static let userCodexAgentAPIKeyDefaultsKey = "openClickyCodexAgentAPIKey"
    static let userAssemblyAIAPIKeyDefaultsKey = "openClickyAssemblyAIAPIKey"
    static let userDeepgramAPIKeyDefaultsKey = "openClickyDeepgramAPIKey"
    static let userVoiceTranscriptionProviderDefaultsKey = "openClickyVoiceTranscriptionProvider"
    static let userVoiceActivationModeDefaultsKey = "openClickyVoiceActivationMode"
    static let userCameraDeviceIDDefaultsKey = "openClickyCameraDeviceID"
    static let userCameraVoiceContextEnabledDefaultsKey = "openClickyCameraVoiceContextEnabled"
    static let userAdvancedModeDefaultsKey = "openClickyAdvancedModeEnabled"
    static let userComputerUseBackendDefaultsKey = "openClickyComputerUseBackend"
    static let userNativeComputerUseDefaultsKey = "openClickyNativeComputerUseEnabled"
    static let userMCPDeveloperDocsEnabledDefaultsKey = "openClickyMCPDeveloperDocsEnabled"
    static let userMCPComposioConnectEnabledDefaultsKey = "openClickyMCPComposioConnectEnabled"
    static let userMCPComputerUseEnabledDefaultsKey = "openClickyMCPComputerUseEnabled"
    static let userMCPCuaDriverCommandDefaultsKey = "openClickyMCPCuaDriverCommand"
    static let userExternalInferenceProxyEnabledDefaultsKey = "openClickyExternalInferenceProxyEnabled"
    static let userVisualDrawingOverlayToolsEnabledDefaultsKey = "openClickyVisualDrawingOverlayToolsEnabled"
    static let userGmailOAuthToolsEnabledDefaultsKey = "openClickyGmailOAuthToolsEnabled"
    static let userXLBEnabledDefaultsKey = "openClickyXLBEnabled"
    static let userXLBHostUrlDefaultsKey = "openClickyXLBHostUrl"
    static let userXLBGraphJsonPathDefaultsKey = "openclicky.xlb.graphJsonPath"
    static let userExternalControlBridgeTokenDefaultsKey = "openClickyExternalControlBridgeToken"
    static let userAgentPlaintextProviderSyncEnabledDefaultsKey = "openClickyAgentPlaintextProviderSyncEnabled"
    static let userDesktopNotificationsEnabledDefaultsKey = "openClickyDesktopNotificationsEnabled"
    static let userAgentCompletionVoiceEnabledDefaultsKey = "openClickyAgentCompletionVoiceEnabled"
    static let userWidgetsEnabledDefaultsKey = "openClickyWidgetsEnabled"
    static let userWidgetsIncludeAgentTaskNamesDefaultsKey = "openClickyWidgetsIncludeAgentTaskNames"
    static let userWidgetsIncludeMemorySnippetsDefaultsKey = "openClickyWidgetsIncludeMemorySnippets"
    static let userWidgetsIncludeFocusedAppContextDefaultsKey = "openClickyWidgetsIncludeFocusedAppContext"
    static let userGlassOpacityDefaultsKey = "openClickyGlassOpacity"
    static let userGlassFrostingDefaultsKey = "openClickyGlassFrosting"
    static let userThemeDefaultsKey = "openClickyThemeAppearance"
    /// Hold push-to-talk and circle a region while speaking.
    static let userCircleWhileTalkingEnabledDefaultsKey = "openClickyCircleWhileTalkingEnabled"
    /// When true (default), sample only while the primary mouse button is dragged during PTT hold.
    /// When false, any mouse movement while holding the key draws.
    static let userCircleWhileTalkingRequireClickDefaultsKey = "openClickyCircleWhileTalkingRequireClick"
    static let appGroupIdentifier = "group.com.jkneen.openclicky"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            userAgentCompletionVoiceEnabledDefaultsKey: true,
            userWidgetsEnabledDefaultsKey: true,
            userWidgetsIncludeAgentTaskNamesDefaultsKey: true,
            userWidgetsIncludeMemorySnippetsDefaultsKey: true,
            userWidgetsIncludeFocusedAppContextDefaultsKey: true,
            userCircleWhileTalkingEnabledDefaultsKey: true,
            userCircleWhileTalkingRequireClickDefaultsKey: true
        ])
    }

    static func isCircleWhileTalkingEnabled() -> Bool {
        userDefaultsBool(forKey: userCircleWhileTalkingEnabledDefaultsKey, defaultValue: true)
    }

    static func isCircleWhileTalkingRequireClickEnabled() -> Bool {
        // Default click-and-drag: only true when the key is missing, or when
        // the user explicitly left it on. Users who previously saved false keep that.
        if UserDefaults.standard.object(forKey: userCircleWhileTalkingRequireClickDefaultsKey) == nil {
            return true
        }
        return userDefaultsBool(forKey: userCircleWhileTalkingRequireClickDefaultsKey, defaultValue: true)
    }

    static func anthropicAPIKey() -> String? {
        let configuredAnthropicAPIKey = userDefaultsValue(forKey: userAnthropicAPIKeyDefaultsKey) ?? stringValue(
            forKey: "AnthropicAPIKey",
            environmentKeys: ["ANTHROPIC_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ANTHROPIC_API_KEY")

        guard let configuredAnthropicAPIKey else { return nil }
        return configuredAnthropicAPIKey.hasPrefix("sk-ant-api") ? configuredAnthropicAPIKey : nil
    }

    static func openAIAPIKey() -> String? {
        userDefaultsValue(forKey: userCodexAgentAPIKeyDefaultsKey) ?? stringValue(
            forKey: "OpenAIAPIKey",
            environmentKeys: ["OPENAI_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_API_KEY")
    }

    static func gogKeyringPassword() -> String? {
        stringValue(
            forKey: "GogKeyringPassword",
            environmentKeys: ["GOG_KEYRING_PASSWORD"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_KEYRING_PASSWORD")
    }

    static func gogAccount() -> String? {
        stringValue(
            forKey: "GogAccount",
            environmentKeys: ["GOG_ACCOUNT"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_ACCOUNT")
    }

    static func gogClient() -> String? {
        stringValue(
            forKey: "GogClient",
            environmentKeys: ["GOG_CLIENT"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_CLIENT")
    }

    static func gogExecutablePath() -> String? {
        stringValue(
            forKey: "OpenClickyGogPath",
            environmentKeys: ["OPENCLICKY_GOG_PATH"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_GOG_PATH")
    }

    static func mcpDeveloperDocsEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPDeveloperDocsEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpComposioConnectEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPComposioConnectEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpComputerUseEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPComputerUseEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpCuaDriverCommand() -> String? {
        userDefaultsValue(forKey: userMCPCuaDriverCommandDefaultsKey)
            ?? stringValue(
                forKey: "OpenClickyCuaDriverMCPCommand",
                environmentKeys: [CuaDriverMCPConfiguration.environmentOverrideKey]
            )
            ?? localDevelopmentEnvironmentValue(forKey: CuaDriverMCPConfiguration.environmentOverrideKey)
            ?? CuaDriverMCPConfiguration.resolvedCommandPath()
    }

    static func externalInferenceProxyEnabled() -> Bool {
        userDefaultsBool(forKey: userExternalInferenceProxyEnabledDefaultsKey, defaultValue: false)
            || normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_EXTERNAL_INFERENCE_PROXY_ENABLED"]) == "1"
            || normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_EXTERNAL_INFERENCE_PROXY_ENABLED"])?.lowercased() == "true"
    }

    static func visualDrawingOverlayToolsEnabled() -> Bool {
        let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_VISUAL_DRAWING_OVERLAY_TOOLS_ENABLED"])
        return userDefaultsBool(forKey: userVisualDrawingOverlayToolsEnabledDefaultsKey, defaultValue: true)
            && environmentValue != "0"
            && environmentValue?.lowercased() != "false"
    }

    static func gmailOAuthToolsEnabled() -> Bool {
        let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_GMAIL_OAUTH_TOOLS_ENABLED"])
        return userDefaultsBool(forKey: userGmailOAuthToolsEnabledDefaultsKey, defaultValue: false)
            || environmentValue == "1"
            || environmentValue?.lowercased() == "true"
    }

    static func xlbEnabled() -> Bool {
        let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_XLB_ENABLED"])
        return userDefaultsBool(forKey: userXLBEnabledDefaultsKey, defaultValue: false)
            || environmentValue == "1"
            || environmentValue?.lowercased() == "true"
    }

    /// Optional xlinkBook host URL. Empty = agent_state tool disabled.
    /// User must set this in Settings to opt in.
    static func xlbHostUrl() -> String {
        if let v = userDefaultsValue(forKey: userXLBHostUrlDefaultsKey),
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v
        }
        return "http://localhost:5000"
    }

    /// Path where the Swift bakery writes graph.json. Default location is
    /// openclicky's own Application Support directory
    /// (`~/Library/Application Support/OpenClicky/xlb-graph.json`) so the app
    /// never depends on any external skill install layout for writes.
    ///
    /// Read-side note: when neither the UserDefault override nor the
    /// openclicky-side file exists, and the legacy skill export at
    /// `~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/graphify-out/graph.json`
    /// is still present on disk, we fall back to that skill path so users
    /// carrying a graph from the previous layout still see it. This skill
    /// fallback is transitional and should be removed once existing users
    /// have migrated.
    ///
    /// Override via UserDefault `openclicky.xlb.graphJsonPath` (used for
    /// developer overrides only; the Settings UI no longer exposes it).
    static func xlbGraphJsonPath() -> URL {
        // Openclicky-owned default. All new writes land here.
        let openClickyDefault = "~/Library/Application Support/OpenClicky/xlb-graph.json"
        // Transitional: legacy skill export path from before the openclicky
        // migration. Only consulted as a read fallback when the file
        // physically exists there.
        let legacySkillPath = "~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/graphify-out/graph.json"

        if let v = userDefaultsValue(forKey: userXLBGraphJsonPathDefaultsKey),
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (v as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }

        let expandedDefault = (openClickyDefault as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: expandedDefault) {
            let expandedLegacy = (legacySkillPath as NSString).expandingTildeInPath
            if fm.fileExists(atPath: expandedLegacy) {
                return URL(fileURLWithPath: expandedLegacy)
            }
        }
        return URL(fileURLWithPath: expandedDefault)
    }

    /// Effective context window (tokens) for the currently-selected voice
    /// response model. Auto-tuned xlb caps scale off this value. The
    /// catalog does not (yet) carry an explicit `contextWindow` field, so
    /// we approximate from `maxOutputTokens` which is set uniformly per
    /// model family. Returns 128_000 if the selection cannot be resolved.
    /// TODO: add a first-class `contextWindow` field to
    /// `OpenClickyModelOption` once model metadata is centralized.
    static func xlbEffectiveContextWindow() -> Int {
        let fallback = 128_000
        guard let selectedID = UserDefaults.standard.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey),
              !selectedID.isEmpty else {
            return fallback
        }
        let option = OpenClickyModelCatalog.voiceResponseModel(withID: selectedID)
        let value = option.maxOutputTokens
        return value > 0 ? value : fallback
    }

    /// Per-turn xlb token budget: 15% of the current model's context
    /// window, clamped to [8_000, 60_000].
    static func xlbTurnBudget() -> Int {
        let ctx = xlbEffectiveContextWindow()
        let raw = Int(Double(ctx) * 0.15)
        return max(8_000, min(60_000, raw))
    }

    static func xlbTokenCapSearch() -> Int {
        max(1_500, Int(Double(xlbTurnBudget()) * 0.15))
    }

    static func xlbTokenCapTopic() -> Int {
        max(4_000, Int(Double(xlbTurnBudget()) * 0.40))
    }

    static func xlbTokenCapMeta() -> Int {
        max(2_000, Int(Double(xlbTurnBudget()) * 0.20))
    }

    static func xlbTokenCapSectionFull() -> Int {
        max(5_000, Int(Double(xlbTurnBudget()) * 0.50))
    }

    static func xlbTokenCapSectionSummary() -> Int {
        max(1_500, Int(Double(xlbTurnBudget()) * 0.15))
    }

    static func xlbTokenCapSectionCount() -> Int {
        max(800, Int(Double(xlbTurnBudget()) * 0.08))
    }

    static func xlbTokenCapGraph() -> Int {
        max(2_500, Int(Double(xlbTurnBudget()) * 0.25))
    }

    static func xlbTokenCapState() -> Int {
        max(2_000, Int(Double(xlbTurnBudget()) * 0.20))
    }

    static func externalControlBridgeToken() -> String? {
        userDefaultsValue(forKey: userExternalControlBridgeTokenDefaultsKey) ?? stringValue(
            forKey: "OpenClickyExternalControlBridgeToken",
            environmentKeys: ["OPENCLICKY_BRIDGE_TOKEN"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_BRIDGE_TOKEN")
    }

    /// Generates a new bearer token for the external-control bridge and
    /// persists it into UserDefaults so `externalControlBridgeToken()`
    /// returns it on next read. Codex template picks this up on the next
    /// Agent Mode session start. Returns the new token so callers can
    /// display / copy it immediately.
    @discardableResult
    static func regenerateExternalControlBridgeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: userExternalControlBridgeTokenDefaultsKey)
        return token
    }

    static func agentPlaintextProviderSyncEnabled() -> Bool {
        userDefaultsBool(forKey: userAgentPlaintextProviderSyncEnabledDefaultsKey, defaultValue: false)
    }

    static func agentCompletionVoiceEnabled() -> Bool {
        userDefaultsBool(forKey: userAgentCompletionVoiceEnabledDefaultsKey, defaultValue: true)
    }

    static func assemblyAIAPIKey() -> String? {
        userDefaultsValue(forKey: userAssemblyAIAPIKeyDefaultsKey) ?? stringValue(
            forKey: "AssemblyAIAPIKey",
            environmentKeys: ["ASSEMBLYAI_API_KEY", "ASSEMBLY_AI_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ASSEMBLYAI_API_KEY")
            ?? localDevelopmentEnvironmentValue(forKey: "ASSEMBLY_AI_API_KEY")
    }

    static func deepgramAPIKey() -> String? {
        userDefaultsValue(forKey: userDeepgramAPIKeyDefaultsKey) ?? stringValue(
            forKey: "DeepgramAPIKey",
            environmentKeys: ["DEEPGRAM_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_API_KEY")
    }

    static func elevenLabsAPIKey() -> String? {
        userDefaultsValue(forKey: userElevenLabsAPIKeyDefaultsKey) ?? stringValue(
            forKey: "ElevenLabsAPIKey",
            environmentKeys: ["ELEVENLABS_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ELEVENLABS_API_KEY")
    }

    static func elevenLabsVoiceID() -> String {
        userDefaultsValue(forKey: userElevenLabsVoiceIDDefaultsKey) ?? stringValue(
            forKey: "ElevenLabsVoiceID",
            environmentKeys: ["ELEVENLABS_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ELEVENLABS_VOICE_ID")
        ?? "hpp4J3VqNfWAUOO0d1Us"
    }

    static func cartesiaAPIKey() -> String? {
        userDefaultsValue(forKey: userCartesiaAPIKeyDefaultsKey) ?? stringValue(
            forKey: "CartesiaAPIKey",
            environmentKeys: ["CARTESIA_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "CARTESIA_API_KEY")
    }

    /// Cartesia voice ID. Defaults to one of their public neutral voices.
    /// Users override via Settings → Voice → Cartesia voice ID.
    static func cartesiaVoiceID() -> String {
        userDefaultsValue(forKey: userCartesiaVoiceIDDefaultsKey) ?? stringValue(
            forKey: "CartesiaVoiceID",
            environmentKeys: ["CARTESIA_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "CARTESIA_VOICE_ID")
        ?? "a0e99841-438c-4a64-b679-ae501e7d6091"
    }

    /// OpenAI Realtime output voice. Realtime supports the built-in voice
    /// names directly; Settings stores the selected name here.
    static func openAIRealtimeVoiceID() -> String {
        userDefaultsValue(forKey: userOpenAIRealtimeVoiceIDDefaultsKey) ?? stringValue(
            forKey: "OpenAIRealtimeVoiceID",
            environmentKeys: ["OPENAI_REALTIME_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_REALTIME_VOICE_ID")
        ?? "cedar"
    }

    /// Selected playback engine — "openai_realtime" (default), "elevenlabs",
    /// "cartesia", "deepgram", or "microsoft_edge".
    static func ttsProviderRaw() -> String {
        userDefaultsValue(forKey: userTTSProviderDefaultsKey) ?? "openai_realtime"
    }

    static func voicePlaybackVolume() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: openClickyVoicePlaybackVolumeDefaultsKey) != nil else {
            return defaultVoicePlaybackVolume
        }
        let volume = defaults.double(forKey: openClickyVoicePlaybackVolumeDefaultsKey)
        guard volume.isFinite else { return defaultVoicePlaybackVolume }
        return min(max(volume, 0.0), 1.0)
    }

    /// Deepgram TTS voice/model identifier. Defaults to Aura 2 Thalia
    /// (en). Verified against https://developers.deepgram.com (2026-04-26):
    /// auth uses the same `Authorization: Token <key>` as STT, model
    /// goes in `?model=` query param, output is PCM linear16 when
    /// requested via `encoding=linear16&sample_rate=22050&container=none`.
    static func deepgramTTSVoice() -> String {
        userDefaultsValue(forKey: userDeepgramTTSVoiceDefaultsKey) ?? stringValue(
            forKey: "DeepgramTTSVoice",
            environmentKeys: ["DEEPGRAM_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_TTS_VOICE")
        ?? "aura-2-thalia-en"
    }

    /// LLM model Deepgram Voice Agent should use for the think stage.
    static func deepgramVoiceAgentThinkModel() -> String {
        let rawModel = userDefaultsValue(forKey: userDeepgramVoiceAgentThinkModelDefaultsKey) ?? stringValue(
            forKey: "DeepgramVoiceAgentThinkModel",
            environmentKeys: ["DEEPGRAM_VOICE_AGENT_THINK_MODEL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_VOICE_AGENT_THINK_MODEL")
        ?? "gpt-4o-mini"
        return normalizeDeepgramVoiceAgentThinkModel(rawModel)
    }

    static func normalizeDeepgramVoiceAgentThinkModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-4o-mini" : trimmed.lowercased()
    }

    /// Microsoft Edge Read Aloud voice identifier. These are the free
    /// Edge online voices, not Azure Speech API keys.
    static func microsoftEdgeVoiceID() -> String {
        userDefaultsValue(forKey: userMicrosoftEdgeVoiceIDDefaultsKey) ?? stringValue(
            forKey: "MicrosoftEdgeVoiceID",
            environmentKeys: ["MICROSOFT_EDGE_VOICE_ID", "EDGE_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "MICROSOFT_EDGE_VOICE_ID")
            ?? localDevelopmentEnvironmentValue(forKey: "EDGE_TTS_VOICE")
        ?? "en-US-EmmaMultilingualNeural"
    }

    private static func userDefaultsBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func userDefaultsValue(forKey key: String) -> String? {
        if keychainBackedDefaultsKeys.contains(key) {
            if let keychainValue = keychainValue(forKey: key) {
                return keychainValue
            }
            if let migrated = normalizedConfigurationValue(UserDefaults.standard.string(forKey: key)) {
                _ = setKeychainValue(migrated, forKey: key)
                UserDefaults.standard.removeObject(forKey: key)
                return migrated
            }
            return nil
        }
        return normalizedConfigurationValue(UserDefaults.standard.string(forKey: key))
    }

    static func persistSecret(_ value: String, defaultsKey: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            deleteKeychainValue(forKey: defaultsKey)
        } else {
            _ = setKeychainValue(trimmedValue, forKey: defaultsKey)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func stringValue(forKey key: String, environmentKeys: [String] = []) -> String? {
        if let bundledInfoValue = normalizedConfigurationValue(Bundle.main.object(forInfoDictionaryKey: key) as? String) {
            return bundledInfoValue
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath) else {
            return stringValueFromEnvironment(forKey: key, environmentKeys: environmentKeys)
        }

        if let resourceInfoValue = normalizedConfigurationValue(resourceInfo[key] as? String) {
            return resourceInfoValue
        }

        return stringValueFromEnvironment(forKey: key, environmentKeys: environmentKeys)
    }

    private static func stringValueFromEnvironment(forKey key: String, environmentKeys: [String]) -> String? {
        let candidateEnvironmentKeys = [key] + environmentKeys

        for environmentKey in candidateEnvironmentKeys {
            if let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment[environmentKey]) {
                return environmentValue
            }
        }

        return nil
    }

    // FIX(startup-perf-2026-08-01): cache the concatenated env file
    // contents so 8+ callers don't each read ~4 files from disk. Also
    // caches parsed key->value pairs so repeated lookups skip the
    // regex scan.
    private static let envCache: (contents: String, parsed: [String: String]) = {
        var combined = ""
        for url in localDevelopmentEnvironmentFileURLs() {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                combined += s
                combined += "\n"
            }
        }
        var parsed: [String: String] = [:]
        for line in combined.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let k = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            parsed[k] = v
        }
        return (combined, parsed)
    }()

    private static func localDevelopmentEnvironmentValue(forKey key: String) -> String? {
        return envCache.parsed[key]
    }

    private static let keychainService = "com.jkneen.openclicky.secrets"

    /// Empty on purpose: dev-signed rebuilds trip macOS Keychain ACL
    /// prompts on every relaunch (new codesign identity → old ACL
    /// rejects → password dialog). Route all "sensitive" secrets
    /// through UserDefaults instead. UserDefaults is less protected
    /// but for local dev testing this is fine, and for production
    /// signing (stable identity) we can re-add keys later without
    /// changing the read/write API.
    private static let keychainBackedDefaultsKeys: Set<String> = []

    /// Per-process cache of Keychain lookups. Prevents a single denied
    /// lookup (macOS password-prompt "Deny") from re-prompting every
    /// time a code path reads the same key. `keychainProbeFailed` also
    /// short-circuits ALL subsequent Keychain reads for the session so
    /// a rebuilt+resigned dev binary doesn't chain-prompt the user
    /// during startup (the reported bug: "怎么又需要输密码了").
    private static var keychainCache: [String: String] = [:]
    private static var keychainNegativeCache: Set<String> = []
    private static var keychainProbeFailed: Bool = false

    private static func keychainValue(forKey key: String) -> String? {
        // Hard-short-circuit: never read Keychain in dev-signed
        // builds. Every rebuild triggers a fresh macOS password
        // prompt because codesign identity changes and old ACL
        // rejects the new binary. Return nil so callers fall
        // through to UserDefaults / env. Production signing (stable
        // identity) can revert this if needed.
        return nil
        // unreachable below (kept for reference)
        if let hit = keychainCache[key] { return hit }
        if keychainNegativeCache.contains(key) { return nil }
        if keychainProbeFailed { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // Auth-related failures (user denied prompt / interaction not
        // allowed / device locked) — mark the entire process as
        // Keychain-unavailable so we never prompt again this run.
        if status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecMissingEntitlement {
            keychainProbeFailed = true
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            keychainNegativeCache.insert(key)
            return nil
        }
        let value = normalizedConfigurationValue(String(data: data, encoding: .utf8))
        if let value { keychainCache[key] = value }
        return value
    }

    @discardableResult
    private static func setKeychainValue(_ value: String, forKey key: String) -> Bool {
        // Skip writes when the probe already failed — otherwise we'd
        // re-prompt on every persist attempt.
        if keychainProbeFailed {
            keychainCache[key] = value
            return true
        }
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychainValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func localDevelopmentEnvironmentFileURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        if let explicitSecretsFilePath = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_SECRETS_FILE"]) {
            urls.append(URL(fileURLWithPath: explicitSecretsFilePath))
        }

        if let homeDirectory = fileManager.homeDirectoryForCurrentUser.path.removingPercentEncoding {
            urls.append(URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/openclicky/secrets.env"))
        }

        return urls
    }

    private static func environmentValue(forKey key: String, in fileContents: String) -> String? {
        for rawLine in fileContents.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                continue
            }

            let lineWithoutExportPrefix: String
            if trimmedLine.hasPrefix("export ") {
                lineWithoutExportPrefix = String(trimmedLine.dropFirst("export ".count))
            } else {
                lineWithoutExportPrefix = trimmedLine
            }

            let keyValueParts = lineWithoutExportPrefix.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValueParts.count == 2 else {
                continue
            }

            let parsedKey = keyValueParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard parsedKey == key else {
                continue
            }

            let rawValue = keyValueParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedConfigurationValue(rawValue.trimmingMatchingQuotes())
        }

        return nil
    }

    private static func normalizedConfigurationValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        // Xcode leaves unresolved build-setting placeholders in Info.plist as
        // literal strings. Treat those as missing configuration instead of
        // accidentally sending "$(KEY)" as an API key.
        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }
}

private extension String {
    nonisolated func trimmingMatchingQuotes() -> String {
        guard count >= 2 else { return self }

        if hasPrefix("\""), hasSuffix("\"") {
            return String(dropFirst().dropLast())
        }

        if hasPrefix("'"), hasSuffix("'") {
            return String(dropFirst().dropLast())
        }

        return self
    }
}
