//
//  MirageDeepgramTranscriptionProvider.swift
//  cursor-buddy
//
//  Adapter that exposes MirageDeepgramClient through the shared
//  BuddyTranscriptionProvider protocol so it can be picked from any
//  profile (Mirage / SKI / HeyClicky / Local / Quality / Realtime).
//  Same protocol contract as the paid `DeepgramStreamingTranscription
//  Provider` — only the token source differs (aegis-proxy mint vs the
//  user's Deepgram API key). Everything downstream (WSS URL, PCM
//  streaming, is_final / Finalize handshake) is identical.

import AVFoundation
import Foundation

final class MirageDeepgramTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Deepgram (Peeky Free)"
    let requiresSpeechRecognitionPermission = false
    let shouldStartAudioCaptureBeforeProviderReady = true

    /// Configured iff the mirage upstream is set. When empty, the app
    /// can still ship this provider in the picker but the user gets a
    /// clean error at first turn instead of a silent failure.
    var isConfigured: Bool {
        MirageSecrets.isConfigured
    }

    var unavailableExplanation: String? {
        isConfigured ? nil : "Peeky Free is not configured on this build. Fill MirageSecrets.upstreamBaseURL locally."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let keyterm = keyterms.first(where: { !$0.isEmpty }) ?? "OpenClicky"
        let session = try await MirageDeepgramClient.shared.startSession(
            sampleRate: 16000,
            channels: 1,
            keyterm: keyterm
        )
        await session.start()
        return Session(
            inner: session,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    // MARK: - Session wrapper

    private final class Session: BuddyStreamingTranscriptionSession, @unchecked Sendable {
        let finalTranscriptFallbackDelaySeconds: TimeInterval = 3.0

        private let inner: MirageDeepgramClient.Session
        private let onTranscriptUpdate: (String) -> Void
        private let onFinalTranscriptReady: (String) -> Void
        private let onError: (Error) -> Void
        private var partialPollTask: Task<Void, Never>?
        private var didFinalize = false
        /// Resamples the mic input (whatever its native format — usually
        /// Float32 at 48 kHz or 44.1 kHz) into the Int16 16 kHz mono PCM
        /// Deepgram declares in the WSS URL. Without this the naive
        /// `int16ChannelData` read returns nil on Float32 buffers and
        /// no audio ever reaches Deepgram → empty transcript. Same
        /// converter the paid Deepgram / AssemblyAI providers use.
        private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: 16000)

        init(inner: MirageDeepgramClient.Session,
             onTranscriptUpdate: @escaping (String) -> Void,
             onFinalTranscriptReady: @escaping (String) -> Void,
             onError: @escaping (Error) -> Void) {
            self.inner = inner
            self.onTranscriptUpdate = onTranscriptUpdate
            self.onFinalTranscriptReady = onFinalTranscriptReady
            self.onError = onError
            // Poll the actor's currentPartial() at 100ms cadence so the UI
            // can surface a live "you said…" line. Actor guarantees the
            // read is thread-safe.
            self.partialPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let partial = await self.inner.currentPartial()
                    if !partial.isEmpty {
                        self.onTranscriptUpdate(partial)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
            // Convert (Float32 → Int16, native rate → 16 kHz mono) via
            // the shared helper — same one the paid Deepgram / AssemblyAI
            // paths use. Without this step the mic buffer is Float32 at
            // 48 kHz and Deepgram sees zero audio → empty transcript.
            guard let pcm = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
                  !pcm.isEmpty else { return }
            Task { [weak self] in
                try? await self?.inner.sendPCM(pcm)
            }
        }

        func requestFinalTranscript() {
            guard !didFinalize else { return }
            didFinalize = true
            Task { [weak self] in
                do {
                    try await self?.inner.finalize()
                    if let final = try await self?.inner.awaitFinal(seconds: 3.0) {
                        self?.onFinalTranscriptReady(final)
                    }
                } catch {
                    self?.onError(error)
                }
                self?.partialPollTask?.cancel()
                self?.partialPollTask = nil
            }
        }

        func cancel() {
            Task { [weak self] in await self?.inner.cancel() }
            partialPollTask?.cancel()
            partialPollTask = nil
        }
    }
}
