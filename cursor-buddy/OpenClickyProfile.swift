//
//  OpenClickyProfile.swift
//  cursor-buddy
//
//  A settings "profile" is a named bundle that flips the whole voice provider
//  matrix at once (STT + response model + TTS + activation), so users switch
//  between coherent modes instead of hand-tuning a dozen independent toggles.
//
//  Step 1 of design-notes/settings-profiles-spec.md: data model, the three
//  built-in profiles, and atomic apply over the EXISTING UserDefaults keys.
//  No UI yet; nothing in the running app reads `activeProfileID` until the
//  selector is wired in a later step.
//

import Foundation

/// A coherent voice/agent mode. Pure value data — applying it just writes the
/// existing UserDefaults keys that the rest of the app already reads.
nonisolated struct OpenClickyProfile: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// `BuddyTranscriptionProviderID` raw value (e.g. "parakeet").
    let sttProvider: String
    /// `OpenClickyModelCatalog` model id used for spoken responses.
    let responseModelID: String
    /// `OpenClickyTTSProvider` raw value (e.g. "elevenlabs").
    let ttsProvider: String
    /// `OpenClickyVoiceActivationMode` raw value (e.g. "push_to_talk").
    let activationMode: String
    /// Optional provider-specific TTS voice. `nil` leaves the user's current
    /// voice for that provider untouched.
    let ttsVoiceID: String?
    /// Optional Agent Mode (Codex) model override. `nil` leaves it untouched.
    let agentModelID: String?
}

/// Built-in profiles + atomic apply. `nonisolated` so it can be exercised from
/// tests and any context; it only touches `UserDefaults`, which is thread-safe.
nonisolated enum OpenClickyProfileCatalog {
    /// UserDefaults key recording the currently-selected profile.
    static let activeProfileDefaultsKey = "openClickyActiveProfileID"
    /// Mirrors the literal key written by `CompanionManager.setSelectedModel`.
    static let voiceResponseModelDefaultsKey = "selectedVoiceResponseModel"

    static let local = OpenClickyProfile(
        id: "local",
        displayName: "Local",
        sttProvider: BuddyTranscriptionProviderID.parakeet.rawValue,
        // Anthropic provider -> Claude Agent SDK first (local Code sign-in,
        // no per-token key) per the money rule. Haiku keeps it fast/cheap.
        responseModelID: "claude-haiku-4-5",
        ttsProvider: OpenClickyTTSProvider.microsoftEdge.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let realtime = OpenClickyProfile(
        id: "realtime",
        displayName: "Realtime",
        sttProvider: BuddyTranscriptionProviderID.openAI.rawValue,
        // Speech-to-speech: owns STT + reasoning + audio in one Realtime turn,
        // avoiding the multi-hop first-audio latency of the text->TTS path.
        responseModelID: OpenClickyModelCatalog.defaultSpeechModelID,
        ttsProvider: OpenClickyTTSProvider.openAIRealtime.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let quality = OpenClickyProfile(
        id: "quality",
        displayName: "Quality",
        sttProvider: BuddyTranscriptionProviderID.deepgram.rawValue,
        responseModelID: OpenClickyModelCatalog.defaultDelegationModelID, // claude-sonnet
        ttsProvider: OpenClickyTTSProvider.elevenLabs.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let heyclickyFree = OpenClickyProfile(
        id: "heyclicky_free",
        displayName: "HeyClicky Free",
        sttProvider: BuddyTranscriptionProviderID.heyclickyFree.rawValue,
        // Realtime WS speech model — one WebSocket does STT + Claude
        // Fable 5 thinking + TTS in one round. When users want the
        // two-stage push-to-talk lane, they can switch response model
        // to `heyclicky-free-chat` in Advanced.
        responseModelID: "heyclicky-free-speech",
        // Speak uses the OpenAI Realtime WS transport whose Bearer
        // token is a proxy-minted ephemeral (spec §5.3). This is what
        // gives HeyClicky Free its multi-voice speech capability
        // (alloy / cedar / ash / marin / ballad / echo / …). Users who
        // prefer offline can switch to Microsoft Edge in Settings.
        ttsProvider: OpenClickyTTSProvider.openAIRealtime.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: "heyclicky-free"
    )

    /// SKI Mode: local zh STT (whisper.cpp large-v3-turbo) + decomposed
    /// reasoning through Claude (SDK-first per money rule) + local TTS.
    /// Avoids the realtime WS lane so BuddyTranscriptionProvider is
    /// actually invoked. Phase 1: no file bridge yet — response goes
    /// through the existing Claude path. Phase 2 will swap in
    /// `.oc/events.jsonl` writer/reader once file bridge lands.
    static let skiMode = OpenClickyProfile(
        id: "ski_mode",
        displayName: "SKI Mode",
        sttProvider: BuddyTranscriptionProviderID.whisperLocal.rawValue,
        responseModelID: "claude-haiku-4-5",
        ttsProvider: OpenClickyTTSProvider.microsoftEdge.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    /// Mirage: free-tier Claude via the aegis-proxy Cloudflare Worker, using
    /// the same wire protocol as the upstream reference Rust client. Anonymous
    /// rotating UUID header; no login. All heavy inference (Sonnet/Opus/Fable
    /// 5) is paid for by the upstream author's Anthropic account, transparent
    /// to the user. STT and TTS stay on SKI-style local providers (whisper.cpp
    /// + Microsoft Edge) for the initial rollout; later phases upgrade to
    /// Deepgram / Cartesia via the same aegis-proxy token-mint endpoints once
    /// their Swift clients land. `agentModelID` defaults to Haiku for the
    /// Claude-Code-driven agent loop — it is the cheapest per-turn model and
    /// matches the reference client's own default.
    static let mirage = OpenClickyProfile(
        id: "mirage",
        displayName: "Peeky Free",
        // Deepgram STT + Cartesia TTS both flow through the same
        // aegis-proxy /mint-token endpoint that fronts the LLM lane, so
        // the whole voice loop is free-tier by default. Users can flip
        // to whisperLocal / microsoftEdge in Settings for full offline.
        sttProvider: BuddyTranscriptionProviderID.mirageDeepgram.rawValue,
        responseModelID: "mirage/claude-fable-5",
        ttsProvider: OpenClickyTTSProvider.mirageCartesia.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        // Agent (Claude Code) defaults to Opus 5 — user explicitly wants
        // the strongest tier for planning turns while the dialog model
        // stays on cheaper Fable 5. Both auto-append [1m] context suffix
        // in ClaudeAgentRunner when the model supports it.
        agentModelID: "mirage/claude-opus-5"
    )

    static let all: [OpenClickyProfile] = [local, realtime, quality, heyclickyFree, skiMode, mirage]

    static let defaultProfileID = local.id

    /// Resolves a profile by id, falling back to the default for unknown ids.
    static func profile(withID id: String?) -> OpenClickyProfile {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return all.first(where: { $0.id == defaultProfileID }) ?? local
        }
        return match
    }

    /// The currently-selected profile (default if none stored yet).
    static func activeProfile(defaults: UserDefaults = .standard) -> OpenClickyProfile {
        profile(withID: defaults.string(forKey: activeProfileDefaultsKey))
    }

    /// Atomically writes the existing keys the rest of the app already reads.
    /// Optional fields are only written when present, so switching profiles
    /// never clobbers an unrelated provider's voice or the agent model.
    ///
    /// After the profile default is written, any per-profile user overrides
    /// stored under `overridesDefaultsKey` are re-applied on top so the
    /// user's manual choices from Advanced Providers survive a profile
    /// toggle. `applyDefaults: true` forces the profile defaults to win
    /// (used by "Reset to profile defaults" in Settings).
    static func apply(
        _ profile: OpenClickyProfile,
        defaults: UserDefaults = .standard,
        applyDefaults: Bool = false
    ) {
        defaults.set(profile.id, forKey: activeProfileDefaultsKey)
        defaults.set(profile.sttProvider, forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
        defaults.set(profile.responseModelID, forKey: voiceResponseModelDefaultsKey)
        defaults.set(profile.ttsProvider, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
        defaults.set(profile.activationMode, forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey)

        if let ttsVoiceID = profile.ttsVoiceID {
            defaults.set(ttsVoiceID, forKey: ttsVoiceDefaultsKey(for: profile.ttsProvider))
        }
        // Route the profile's agent-model id to the storage key its own
        // agent runner reads. Peeky Free (mirage) uses
        // `openClickyMirageAgentModel`; HeyClicky / SKI / Codex use
        // `clickyCodexModel`. Writing a `mirage/...` id into
        // `clickyCodexModel` would leak into Codex Agent Mode's model
        // resolver, which can't handle the mirage/ namespace.
        if let agentModelID = profile.agentModelID {
            defaults.set(agentModelID, forKey: agentModelStorageKey(forProfile: profile.id))
        }

        // Overlay per-profile user overrides so manual Advanced-Providers
        // choices survive a profile switch. `applyDefaults` skips the
        // overlay (Settings "Reset to profile defaults" flow).
        if !applyDefaults {
            applyOverrides(for: profile.id, defaults: defaults)
        } else {
            clearOverrides(for: profile.id, defaults: defaults)
        }
    }

    /// UserDefaults key the agent runner for a given profile reads.
    /// Peeky Free (mirage) uses `openClickyMirageAgentModel` because its
    /// agent runner is `ClaudeAgentRunner` (the mirage/ namespace only
    /// makes sense there); every other profile writes to the shared
    /// `clickyCodexModel` key that Codex Agent Mode consumes.
    ///
    /// Centralized so the four sites that need this routing (profile
    /// apply, override apply, override write, direct set) can never
    /// drift.
    static func agentModelStorageKey(forProfile profileID: String) -> String {
        profileID == "mirage" ? "openClickyMirageAgentModel" : "clickyCodexModel"
    }

    // MARK: - Per-profile overrides

    /// UserDefaults key holding `[profileID: [field: rawValue]]`.
    static let overridesDefaultsKey = "openClickyProfileOverrides"

    /// Field names for per-profile overrides. Kept string-typed so the map
    /// stays plist-serializable and future fields can be added without
    /// breaking older stored dicts.
    enum OverrideField: String {
        case stt
        case tts
        case responseModel
        case agentModel
        case ttsVoice
        case activationMode
    }

    static func setOverride(
        _ value: String,
        field: OverrideField,
        forProfile profileID: String,
        defaults: UserDefaults = .standard
    ) {
        var root = (defaults.dictionary(forKey: overridesDefaultsKey) as? [String: [String: String]]) ?? [:]
        var perProfile = root[profileID] ?? [:]
        perProfile[field.rawValue] = value
        root[profileID] = perProfile
        defaults.set(root, forKey: overridesDefaultsKey)
    }

    static func clearOverrides(for profileID: String, defaults: UserDefaults = .standard) {
        var root = (defaults.dictionary(forKey: overridesDefaultsKey) as? [String: [String: String]]) ?? [:]
        root[profileID] = nil
        defaults.set(root, forKey: overridesDefaultsKey)
    }

    /// Typed snapshot of the override dict for one profile. Every field
    /// is nil when the user has not overridden it, so callers can `??`
    /// against the profile default.
    struct ResolvedOverrides {
        var stt: String?
        var tts: String?
        var responseModel: String?
        var agentModel: String?
        var ttsVoice: String?
        var activationMode: String?
    }

    /// Normalise an override value: empty / whitespace strings mean
    /// "unset", not "override to empty string". Consumers use `??` to
    /// fall back to the profile default; returning `""` would take
    /// precedence over the default and route the app into an invalid
    /// provider/model.
    private static func normalizedOverride(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolvedOverrides(for profileID: String, defaults: UserDefaults = .standard) -> ResolvedOverrides {
        guard let root = defaults.dictionary(forKey: overridesDefaultsKey) as? [String: [String: String]],
              let o = root[profileID] else { return ResolvedOverrides() }
        return ResolvedOverrides(
            stt: normalizedOverride(o[OverrideField.stt.rawValue]),
            tts: normalizedOverride(o[OverrideField.tts.rawValue]),
            responseModel: normalizedOverride(o[OverrideField.responseModel.rawValue]),
            agentModel: normalizedOverride(o[OverrideField.agentModel.rawValue]),
            ttsVoice: normalizedOverride(o[OverrideField.ttsVoice.rawValue]),
            activationMode: normalizedOverride(o[OverrideField.activationMode.rawValue])
        )
    }

    private static func applyOverrides(for profileID: String, defaults: UserDefaults) {
        guard let root = defaults.dictionary(forKey: overridesDefaultsKey) as? [String: [String: String]],
              let overrides = root[profileID] else { return }
        // Route every read through `normalizedOverride` so an empty
        // string in the persisted dict falls through to the profile
        // default instead of clobbering the default with "".
        if let v = normalizedOverride(overrides[OverrideField.stt.rawValue]) {
            defaults.set(v, forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
        }
        if let v = normalizedOverride(overrides[OverrideField.tts.rawValue]) {
            defaults.set(v, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
        }
        if let v = normalizedOverride(overrides[OverrideField.responseModel.rawValue]) {
            defaults.set(v, forKey: voiceResponseModelDefaultsKey)
        }
        if let v = normalizedOverride(overrides[OverrideField.agentModel.rawValue]) {
            defaults.set(v, forKey: agentModelStorageKey(forProfile: profileID))
        }
        if let v = normalizedOverride(overrides[OverrideField.ttsVoice.rawValue]),
           let ttsProvider = defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) {
            defaults.set(v, forKey: ttsVoiceDefaultsKey(for: ttsProvider))
        }
        if let v = normalizedOverride(overrides[OverrideField.activationMode.rawValue]) {
            defaults.set(v, forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey)
        }
    }

    /// Maps a TTS provider raw value to its provider-specific voice key.
    private static func ttsVoiceDefaultsKey(for ttsProvider: String) -> String {
        switch OpenClickyTTSProvider(rawValue: ttsProvider) {
        case .elevenLabs:
            return AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        case .cartesia:
            return AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey
        case .openAIRealtime:
            return AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey
        case .microsoftEdge:
            return AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey
        case .deepgram:
            return AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey
        case .mirageCartesia:
            // Free-tier Cartesia shares the same voice-id knob as the paid
            // `.cartesia` provider — same field on the wire, same range of
            // valid Cartesia voice UUIDs. Users overriding one implicitly
            // overrides the other, which matches user expectations.
            return AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey
        case .none:
            return AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        }
    }
}
