//
//  BuddyTranscriptionProvider.swift
//  cursor-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

enum BuddyTranscriptionProviderID: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case parakeet = "parakeet"
    case whisperLocal = "whisper_local"
    case appleSpeech = "apple"
    case assemblyAI = "assemblyai"
    case deepgram = "deepgram"
    case openAI = "openai"
    case heyclickyFree = "heyclicky_free"
    /// Free-tier Deepgram STT via aegis-proxy (Peeky Free lane). Wire
    /// identical to the paid `.deepgram` case; the token comes from the
    /// mirage token-mint endpoint instead of the user's own Deepgram key.
    /// Available to any profile — not bound to the .peekyFree profile.
    case mirageDeepgram = "mirage_deepgram"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .parakeet:
            return "Parakeet"
        case .whisperLocal:
            return "Whisper (local)"
        case .appleSpeech:
            return "Apple Speech"
        case .assemblyAI:
            return "AssemblyAI"
        case .deepgram:
            return "Deepgram"
        case .openAI:
            return "Whisper"
        case .heyclickyFree:
            return "HeyClicky Free"
        case .mirageDeepgram:
            return "Deepgram (Peeky Free)"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "Local-first"
        case .parakeet:
            return "Local Parakeet"
        case .whisperLocal:
            return "Local whisper.cpp"
        case .appleSpeech:
            return "On-device Apple"
        case .assemblyAI:
            return "Streaming"
        case .deepgram:
            return "Streaming"
        case .openAI:
            return "OpenAI listening"
        case .heyclickyFree:
            return "Sign in with Google"
        case .mirageDeepgram:
            return "Free-tier Deepgram (rotating anonymous UUID)"
        }
    }
}

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var shouldStartAudioCaptureBeforeProviderReady: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    var shouldStartAudioCaptureBeforeProviderReady: Bool { true }
}

enum BuddyTranscriptionProviderFactory {
    struct ProviderSelection {
        let requestedProviderID: BuddyTranscriptionProviderID
        let displayedProviderID: BuddyTranscriptionProviderID
        let provider: any BuddyTranscriptionProvider
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(preferredProvider: selectedProviderID())
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func makeProvider(preferredProviderID: String) -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func currentProviderSelection() -> ProviderSelection {
        resolveProviderSelection(preferredProvider: selectedProviderID())
    }

    static func providerSelection(preferredProviderID: String) -> ProviderSelection {
        resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
    }

    static func providerIDsForSelectionGrid() -> [BuddyTranscriptionProviderID] {
        BuddyTranscriptionProviderID.allCases.filter { providerID in
            switch providerID {
            case .parakeet:
                return OpenClickyParakeetTranscriptionProvider().isConfigured
            case .whisperLocal:
                return WhisperLocalTranscriptionProvider().isConfigured
            case .heyclickyFree:
                return AppBundleConfiguration.heyClickySignedIn()
                    && (try? AppBundleConfiguration.heyClickyProxyBaseURL()) != nil
            default:
                return true
            }
        }
    }

    static func selectedProviderID() -> BuddyTranscriptionProviderID {
        let rawValue = UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
            ?? AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
            ?? BuddyTranscriptionProviderID.automatic.rawValue
        return BuddyTranscriptionProviderID(rawValue: rawValue.lowercased()) ?? .automatic
    }

    private static func resolveProviderSelection(preferredProvider: BuddyTranscriptionProviderID? = nil) -> ProviderSelection {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let resolvedPreferredProvider = preferredProvider ?? preferredProviderRawValue.flatMap(BuddyTranscriptionProviderID.init(rawValue:))

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let deepgramProvider = DeepgramStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()
        let parakeetProvider = OpenClickyParakeetTranscriptionProvider()

        if resolvedPreferredProvider == .appleSpeech {
            return ProviderSelection(
                requestedProviderID: .appleSpeech,
                displayedProviderID: .appleSpeech,
                provider: AppleSpeechTranscriptionProvider()
            )
        }

        if resolvedPreferredProvider == .heyclickyFree {
            let heyClicky = HeyClickyProxyTranscriptionProvider()
            if heyClicky.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .heyclickyFree,
                    displayedProviderID: .heyclickyFree,
                    provider: heyClicky
                )
            }
            print("Transcription: HeyClicky Free preferred but not signed in, falling back")
            let fallback = configuredFallback(
                excluding: .heyclickyFree,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                parakeetProvider: parakeetProvider
            )
            return ProviderSelection(
                requestedProviderID: .heyclickyFree,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .whisperLocal {
            let whisperProvider = WhisperLocalTranscriptionProvider()
            return ProviderSelection(
                requestedProviderID: .whisperLocal,
                displayedProviderID: .whisperLocal,
                provider: whisperProvider
            )
        }

        // Peeky Free (mirage) Deepgram — free-tier via aegis-proxy. Not
        // bound to any specific profile: any profile can select it in
        // Settings. When the mirage upstream isn't configured we fall
        // through so the user gets the normal fallback chain instead of
        // a hard error.
        if resolvedPreferredProvider == .mirageDeepgram {
            let mirage = MirageDeepgramTranscriptionProvider()
            if mirage.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .mirageDeepgram,
                    displayedProviderID: .mirageDeepgram,
                    provider: mirage
                )
            }
            print("Transcription: Peeky Free Deepgram preferred but MirageSecrets not configured, falling back")
        }

        if resolvedPreferredProvider == .parakeet {
            if parakeetProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .parakeet,
                    displayedProviderID: .parakeet,
                    provider: parakeetProvider
                )
            }

            print("Transcription: Parakeet preferred but not available, falling back")
            let fallback = configuredFallback(
                excluding: .parakeet,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                parakeetProvider: parakeetProvider
            )
            return ProviderSelection(
                requestedProviderID: .parakeet,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .assemblyAI,
                    displayedProviderID: .assemblyAI,
                    provider: assemblyAIProvider
                )
            }

            print("Transcription: AssemblyAI preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .assemblyAI,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                parakeetProvider: parakeetProvider
            )
            return ProviderSelection(
                requestedProviderID: .assemblyAI,
                displayedProviderID: .assemblyAI,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .deepgram {
            if deepgramProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .deepgram,
                    displayedProviderID: .deepgram,
                    provider: deepgramProvider
                )
            }

            print("Transcription: Deepgram preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .deepgram,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                parakeetProvider: parakeetProvider
            )
            return ProviderSelection(
                requestedProviderID: .deepgram,
                displayedProviderID: .deepgram,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .openAI,
                    displayedProviderID: .openAI,
                    provider: openAIProvider
                )
            }

            print("Transcription: OpenAI preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .openAI,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                parakeetProvider: parakeetProvider
            )
            return ProviderSelection(
                requestedProviderID: .openAI,
                displayedProviderID: .openAI,
                provider: fallback.1
            )
        }

        let fallback = configuredFallback(
            excluding: nil,
            assemblyAIProvider: assemblyAIProvider,
            deepgramProvider: deepgramProvider,
            openAIProvider: openAIProvider,
            parakeetProvider: parakeetProvider
        )
        return ProviderSelection(
            requestedProviderID: .automatic,
            displayedProviderID: .automatic,
            provider: fallback.1
        )
    }

    private static func configuredFallback(
        excluding excludedProvider: BuddyTranscriptionProviderID?,
        assemblyAIProvider: AssemblyAIStreamingTranscriptionProvider,
        deepgramProvider: DeepgramStreamingTranscriptionProvider,
        openAIProvider: OpenAIAudioTranscriptionProvider,
        parakeetProvider: OpenClickyParakeetTranscriptionProvider
    ) -> (BuddyTranscriptionProviderID, any BuddyTranscriptionProvider) {
        if excludedProvider != .parakeet, parakeetProvider.isConfigured {
            print("Transcription: using Parakeet as fallback")
            return (.parakeet, parakeetProvider)
        }

        // Whisper.cpp local — offline, free, multilingual, better
        // Chinese than AppleSpeech. Prefer over any cloud provider when
        // the model file is installed; only skip when the user has NOT
        // downloaded a Whisper model yet (isConfigured=false).
        if excludedProvider != .whisperLocal {
            let whisperProvider = WhisperLocalTranscriptionProvider()
            if whisperProvider.isConfigured {
                print("Transcription: using Whisper local as fallback")
                return (.whisperLocal, whisperProvider)
            }
        }

        if excludedProvider != .assemblyAI, assemblyAIProvider.isConfigured {
            print("Transcription: using AssemblyAI as fallback")
            return (.assemblyAI, assemblyAIProvider)
        }

        if excludedProvider != .deepgram, deepgramProvider.isConfigured {
            print("Transcription: using Deepgram as fallback")
            return (.deepgram, deepgramProvider)
        }

        if excludedProvider != .openAI, openAIProvider.isConfigured {
            print("Transcription: using OpenAI as fallback")
            return (.openAI, openAIProvider)
        }

        print("Transcription: using Apple Speech as fallback")
        return (.appleSpeech, AppleSpeechTranscriptionProvider())
    }
}
