import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyProfileTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenClickyProfileTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func catalogExposesSixProfiles() {
        let ids = OpenClickyProfileCatalog.all.map(\.id)
        #expect(ids == ["local", "realtime", "quality", "heyclicky_free", "ski_mode", "mirage"])
        #expect(OpenClickyProfileCatalog.defaultProfileID == "local")
    }

    @Test func mirageProfileDefaultsToFreeTierProviders() {
        let mirage = OpenClickyProfileCatalog.profile(withID: "mirage")
        #expect(mirage.id == "mirage")
        #expect(mirage.displayName == "Peeky Free")
        #expect(mirage.sttProvider == BuddyTranscriptionProviderID.mirageDeepgram.rawValue)
        #expect(mirage.ttsProvider == OpenClickyTTSProvider.mirageCartesia.rawValue)
        #expect(mirage.responseModelID == "mirage/claude-fable-5")
        // Agent tier is deliberately Opus 5, not the cheap tier: the dialog
        // model stays on Fable 5 while planning turns get the strongest
        // model. See the comment on OpenClickyProfile.mirage.
        #expect(mirage.agentModelID == "mirage/claude-opus-5")
    }

    @Test func taskCompletionVoiceDefaultsOn() {
        let key = AppBundleConfiguration.userAgentCompletionVoiceEnabledDefaultsKey
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppBundleConfiguration.agentCompletionVoiceEnabled())
    }

    @Test func profileLookupFallsBackToDefaultForUnknownID() {
        #expect(OpenClickyProfileCatalog.profile(withID: "realtime").id == "realtime")
        #expect(OpenClickyProfileCatalog.profile(withID: nil).id == "local")
        #expect(OpenClickyProfileCatalog.profile(withID: "nope").id == "local")
    }

    @Test func applyingLocalProfileWritesExpectedKeys() {
        let defaults = freshDefaults("local")
        OpenClickyProfileCatalog.apply(.init(
            id: OpenClickyProfileCatalog.local.id,
            displayName: OpenClickyProfileCatalog.local.displayName,
            sttProvider: OpenClickyProfileCatalog.local.sttProvider,
            responseModelID: OpenClickyProfileCatalog.local.responseModelID,
            ttsProvider: OpenClickyProfileCatalog.local.ttsProvider,
            activationMode: OpenClickyProfileCatalog.local.activationMode,
            ttsVoiceID: OpenClickyProfileCatalog.local.ttsVoiceID,
            agentModelID: OpenClickyProfileCatalog.local.agentModelID
        ), defaults: defaults)

        #expect(defaults.string(forKey: OpenClickyProfileCatalog.activeProfileDefaultsKey) == "local")
        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "parakeet")
        #expect(defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey) == "claude-haiku-4-5")
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "microsoft_edge")
        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey) == "push_to_talk")
    }

    @Test func applyingRealtimeProfileSelectsSpeechToSpeechStack() {
        let defaults = freshDefaults("realtime")
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.realtime, defaults: defaults)

        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "openai")
        #expect(defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey) == OpenClickyModelCatalog.defaultSpeechModelID)
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "openai_realtime")
    }

    @Test func applyingQualityProfileSelectsCloudStack() {
        let defaults = freshDefaults("quality")
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.quality, defaults: defaults)

        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "deepgram")
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "elevenlabs")
        #expect(OpenClickyProfileCatalog.activeProfile(defaults: defaults).id == "quality")
    }

    @Test func optionalFieldsDoNotClobberUnrelatedKeysWhenNil() {
        let defaults = freshDefaults("optional")
        defaults.set("existing-codex-model", forKey: "clickyCodexModel")
        defaults.set("existing-eleven-voice", forKey: AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey)

        // Built-in profiles carry nil agentModelID / ttsVoiceID, so applying
        // them must leave those unrelated keys intact.
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.local, defaults: defaults)

        #expect(defaults.string(forKey: "clickyCodexModel") == "existing-codex-model")
        #expect(defaults.string(forKey: AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) == "existing-eleven-voice")
    }
}
