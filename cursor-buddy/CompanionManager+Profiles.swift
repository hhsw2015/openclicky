//
//  CompanionManager+Profiles.swift
//  cursor-buddy
//
//  Live application of a settings profile. Unlike OpenClickyProfileCatalog.apply
//  (which only writes UserDefaults), this routes through the existing
//  CompanionManager setters so the running app reacts immediately — each setter
//  persists its own key AND updates @Published / runtime state (wake word,
//  dictation provider, TTS client, etc.).
//
//  Step 2 of design-notes/settings-profiles-spec.md.
//

import Foundation

extension CompanionManager {
    /// Applies a profile to the live app: STT provider, response model, TTS
    /// provider, and activation mode, plus optional TTS voice / agent model.
    /// Unknown enum raw values fall back to the current selection rather than
    /// forcing an invalid state.
    func applyProfile(_ profile: OpenClickyProfile) {
        // FIX(task #310 2026-08-04): tear down / bring up
        // profile-specific subsystems on switch. Previously HeyClicky
        // Free's WebSocket, plan poller, session-token refresh loops
        // and chrome bridge all kept running after switching to SKI
        // Mode. Same for SKI's hotkey monitor + hands-free session
        // when switching away.
        let previousID = UserDefaults.standard.string(forKey: OpenClickyProfileCatalog.activeProfileDefaultsKey)
        let switchingAwayFromHeyClicky = previousID == "heyclicky_free" && profile.id != "heyclicky_free"
        let switchingIntoHeyClicky = profile.id == "heyclicky_free" && previousID != "heyclicky_free"
        let switchingIntoMirage = profile.id == "mirage" && previousID != "mirage"

        UserDefaults.standard.set(profile.id, forKey: OpenClickyProfileCatalog.activeProfileDefaultsKey)

        if switchingAwayFromHeyClicky {
            stopHeyClickyFreeSubsystems()
        }
        if switchingIntoHeyClicky {
            startHeyClickyFreeSubsystems()
        }

        if switchingIntoMirage {
            // Bootstrap the on-device intent classifier so the first
            // Peeky Free turn doesn't eat the 100-300ms head.json +
            // tokenizer + ORT session load cost. Also seeds the routelet
            // path before the user speaks.
            Task.detached(priority: .utility) {
                _ = await OpenClickyIntentClassifier.shared.bootstrap()
            }
            // Peeky parity (stt_deepgram.rs:81 warm()): pre-mint the
            // Deepgram proxy token and pre-open the TLS connection to
            // api.deepgram.com. Without this the first PTT press pays
            // ~1.5s cold-start, and the recording only captures a
            // 300ms tail after the user has already released the key.
            Task.detached(priority: .utility) {
                await MirageDeepgramClient.shared.warm()
            }
            // Same treatment for Cartesia: the aegis-proxy
            // `/v1/cartesia/token` mint can run ~1-2 s (up to 20 s on a
            // cold Cloudflare Worker container). Pre-minting now hides
            // that latency behind the profile switch instead of adding
            // it to the first reply.
            Task.detached(priority: .utility) {
                await MirageCartesiaClient.shared.warm()
            }
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.mirage.profile_activated",
                fields: [:]
            )
        }

        // SKI Mode services (hotkey monitor + hands-free VAD) already
        // guard their own runtime on `activeProfile().id == "ski_mode"`
        // and observe UserDefaults.didChange, so they reconcile on
        // profile change automatically. No explicit start/stop needed
        // here.
        SKIModeHandsFreeSession.shared.reconcile()

        // Snapshot per-profile user overrides so we can re-apply them
        // over the profile defaults. `OpenClickyProfileCatalog.apply`
        // already merges them into UserDefaults, but we also need the
        // in-memory setters below to see the final resolved values.
        let overrides = OpenClickyProfileCatalog.resolvedOverrides(for: profile.id)

        setVoiceTranscriptionProvider(overrides.stt ?? profile.sttProvider)
        setSelectedModel(overrides.responseModel ?? profile.responseModelID)

        let ttsRaw = overrides.tts ?? profile.ttsProvider
        if let ttsProvider = OpenClickyTTSProvider(rawValue: ttsRaw) {
            // Sync setter so any same-turn observer of
            // `selectedTTSProvider` (e.g. the pipeline reading the live
            // client for a filler right after profile switch) sees the
            // new provider immediately — the default deferred path
            // hops through DispatchQueue.main.async which returns
            // before the mutation.
            setTTSProvider(ttsProvider, deferred: false)
        }
        let activationRaw = overrides.activationMode ?? profile.activationMode
        if let activationMode = OpenClickyVoiceActivationMode(rawValue: activationRaw) {
            setVoiceActivationMode(activationMode)
        }

        // Same routing as OpenClickyProfileCatalog.apply — mirage's agent
        // model belongs in `openClickyMirageAgentModel` (read by
        // ClaudeAgentRunner), NOT `clickyCodexModel` (read by Codex Agent
        // Mode, which cannot resolve mirage/… namespaced ids).
        if let agentModelID = overrides.agentModel ?? profile.agentModelID {
            UserDefaults.standard.set(agentModelID,
                forKey: OpenClickyProfileCatalog.agentModelStorageKey(forProfile: profile.id))
        }
        // ttsVoiceID is left to OpenClickyProfileCatalog.apply / future voice
        // wiring; built-in profiles carry nil so there is nothing to set here.

        // NOTE: openclicky-voice skill installation is user-driven — see
        // the "Install voice skill" row in Advanced Providers. We do NOT
        // write into ~/.claude/skills/ etc. without an explicit user
        // action; those directories belong to the user's CLI agents.
    }

    /// The profile whose id was last applied (default when none recorded yet).
    var activeProfile: OpenClickyProfile {
        OpenClickyProfileCatalog.activeProfile()
    }

    // MARK: - Per-profile Advanced-Providers overrides
    //
    // Settings surfaces that let the user pick a specific STT / TTS /
    // response-LLM / agent-LLM component call these helpers so the
    // choice is (a) applied to the live app right now and (b) recorded
    // as a per-profile override that survives future profile switches.
    // The next `applyProfile(...)` merges these overrides on top of the
    // profile defaults; "Reset to profile defaults" clears them.

    func setVoiceTranscriptionProviderPreservingOverride(_ providerID: String) {
        setVoiceTranscriptionProvider(providerID)
        OpenClickyProfileCatalog.setOverride(
            providerID, field: .stt, forProfile: activeProfile.id)
    }

    func setTTSProviderPreservingOverride(_ provider: OpenClickyTTSProvider) {
        setTTSProvider(provider)
        OpenClickyProfileCatalog.setOverride(
            provider.rawValue, field: .tts, forProfile: activeProfile.id)
    }

    func setSelectedModelPreservingOverride(_ model: String) {
        setSelectedModel(model)
        OpenClickyProfileCatalog.setOverride(
            model, field: .responseModel, forProfile: activeProfile.id)
    }

    /// Record a per-profile agent-model override. The caller is expected
    /// to also write the id into whichever storage key the agent runner
    /// reads (`openClickyMirageAgentModel` for mirage, `clickyCodexModel`
    /// otherwise); the setter mirrors that in `applyProfile`.
    func setAgentModelPreservingOverride(_ modelID: String) {
        UserDefaults.standard.set(modelID,
            forKey: OpenClickyProfileCatalog.agentModelStorageKey(forProfile: activeProfile.id))
        OpenClickyProfileCatalog.setOverride(
            modelID, field: .agentModel, forProfile: activeProfile.id)
    }

    func setVoiceActivationModePreservingOverride(_ mode: OpenClickyVoiceActivationMode) {
        setVoiceActivationMode(mode)
        OpenClickyProfileCatalog.setOverride(
            mode.rawValue, field: .activationMode, forProfile: activeProfile.id)
    }

    /// Wipe all overrides for the active profile and re-apply the
    /// profile defaults (used by "Reset to profile defaults" in Settings).
    func resetActiveProfileToDefaults() {
        let profile = activeProfile
        OpenClickyProfileCatalog.clearOverrides(for: profile.id)
        OpenClickyProfileCatalog.apply(profile, applyDefaults: true)
        applyProfile(profile)
    }
}
