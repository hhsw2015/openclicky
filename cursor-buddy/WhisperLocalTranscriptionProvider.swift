//
//  WhisperLocalTranscriptionProvider.swift
//  cursor-buddy
//
//  BuddyTranscriptionProvider adapter over the existing
//  WhisperCppTranscriber (OpenRewind/Capture). Buffers PTT audio,
//  hands the accumulated Int16 samples to whisper.cpp on finalize.
//  Batch-only — whisper.cpp large-v3-turbo is not streaming.
//

import AVFoundation
import Foundation

final class WhisperLocalTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper (local)"
    let requiresSpeechRecognitionPermission = false
    let shouldStartAudioCaptureBeforeProviderReady = true

    var isConfigured: Bool {
        WhisperLocalModelManager.modelExists(WhisperLocalModelVariant.configured())
    }

    var unavailableExplanation: String? {
        if isConfigured { return nil }
        return "Download the Whisper local model in Advanced Providers before selecting it."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let language = WhisperLocalPreferences.language()
        let model = WhisperLocalPreferences.modelName()
        let transcriber = WhisperCppTranscriber.shared(modelName: model, language: language)
        return WhisperLocalTranscriptionSession(
            transcriber: transcriber,
            language: language,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

enum WhisperLocalPreferences {
    static let modelNameDefaultsKey = "openclicky.voice.whisperLocalModel"
    static let languageDefaultsKey = "openclicky.voice.whisperLocalLanguage"

    static func modelName() -> String {
        UserDefaults.standard.string(forKey: modelNameDefaultsKey) ?? "large-v3-turbo-q5_0"
    }

    static func language() -> String {
        // Explicit user override wins.
        if let override = UserDefaults.standard.string(forKey: languageDefaultsKey),
           !override.isEmpty {
            return override
        }
        // Follow the voice response language: user speaking zh → force
        // zh (whisper-cli confirmed empirically that `-l zh` on our
        // audio dump gives correct "你好, 现在几点了" vs auto-detect's
        // English translation). This is a divergence from SKI (which
        // uses auto) but SKI captures via VPIO + AGC which produces
        // louder, cleaner audio that whisper's auto-detect handles;
        // ours is quieter and auto flips to English.
        let responseLang = UserDefaults.standard.string(forKey: "openClickyVoiceResponseLanguage")
        switch responseLang?.lowercased() {
        case "zh", "zh-cn", "zh-tw", "cn":
            return "zh"
        case "en", "en-us", "en-gb":
            return "en"
        default:
            return "auto"
        }
    }
}

private final class WhisperLocalTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 20.0

    private static let targetSampleRate = 16_000

    private let transcriber: WhisperCppTranscriber
    private let language: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.openclicky.whisper.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        transcriber: WhisperCppTranscriber,
        language: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.transcriber = transcriber
        self.language = language
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let buffered = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBuffered(buffered)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBuffered(_ audioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldStop = stateQueue.sync {
            isCancelled || audioData.isEmpty
        }
        if shouldStop {
            deliverFinal("")
            return
        }

        let samples = Self.int16Samples(from: audioData)
        guard samples.count >= 8_000 else {
            deliverFinal("")
            return
        }

        let utterance = AudioUtterance(
            samples: samples,
            sampleRate: Self.targetSampleRate,
            startedAt: Date(),
            duration: TimeInterval(samples.count) / Double(Self.targetSampleRate),
            onDiskURL: nil,
            source: "voice"
        )

        do {
            let words = try await transcriber.transcribe(utterance: utterance)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let text = words.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                onTranscriptUpdate(text)
            }
            deliverFinal(text)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }

    /// SKI-parity tail trim: scan the last ~2 s window for the
    /// quietest 20 ms slice and cut there. Leaves everything BEFORE
    /// the quiet slice intact — we don't touch the beginning (SKI's
    /// Silero VAD handles start boundary; we don't). This alone
    /// removes the trailing silence that whisper hallucinates from.
    // Retained as reference — Silero VAD path is bypassed. Live
    // trim algorithm can be revisited if we drop the Whisper 1.9.1
    // baseline that transcribes raw PCM correctly.
    private static func trimTrailingSilence(_ samples: [Int16]) -> [Int16] {
        let frameSize = 320  // 20 ms @ 16 kHz
        let scanWindow = 32_000  // 2 s @ 16 kHz — SKI's ring size
        guard samples.count > frameSize * 4 else { return samples }
        let scanStart = max(0, samples.count - scanWindow)
        // Compute energy for every 20 ms frame in the scan window.
        var minEnergy = Double.infinity
        var minEnergyEnd = samples.count  // where to cut (default: keep all)
        var i = scanStart
        while i + frameSize <= samples.count {
            var acc: Double = 0
            for j in 0..<frameSize {
                let f = Double(samples[i + j]) / 32768.0
                acc += f * f
            }
            let rms = (acc / Double(frameSize)).squareRoot()
            if rms < minEnergy {
                minEnergy = rms
                // Cut at the START of the quiet frame — preserves speech
                // that ends just before this quiet 20 ms slice.
                minEnergyEnd = i
            }
            i += frameSize
        }
        // Only trim if the quietest frame is actually quiet (RMS < 0.02)
        // AND it's not right at the very end (which would be a no-op).
        guard minEnergy < 0.02,
              minEnergyEnd < samples.count - frameSize,
              minEnergyEnd > 0 else {
            return samples
        }
        return Array(samples[0..<minEnergyEnd])
    }

    private static func trimSilenceEnergyBased(_ samples: [Int16]) -> [Int16] {
        let frameSize = 320  // 20 ms @ 16 kHz
        guard samples.count > frameSize * 4 else { return samples }
        var frameEnergy: [Double] = []
        var i = 0
        while i + frameSize <= samples.count {
            var acc: Double = 0
            for j in 0..<frameSize {
                let f = Double(samples[i + j]) / 32768.0
                acc += f * f
            }
            frameEnergy.append((acc / Double(frameSize)).squareRoot())
            i += frameSize
        }
        guard let peak = frameEnergy.max(), peak > 0.005 else {
            // Whole clip is basically silence — return as-is,
            // upstream RMS floor will drop it.
            return samples
        }
        // Keep frames above 8% of peak RMS. Lower threshold since
        // VPIO auto-gain-controls the whole clip toward a target
        // loudness — 20% was cutting mid-word syllables. Also add
        // 200 ms pre-roll / post-roll so word onsets survive.
        let threshold = peak * 0.08
        var startFrame = 0
        while startFrame < frameEnergy.count && frameEnergy[startFrame] < threshold {
            startFrame += 1
        }
        var endFrame = frameEnergy.count - 1
        while endFrame > startFrame && frameEnergy[endFrame] < threshold {
            endFrame -= 1
        }
        // Add 200 ms padding on each side (10 frames @ 20 ms).
        startFrame = max(0, startFrame - 10)
        endFrame = min(frameEnergy.count - 1, endFrame + 10)
        let startSample = startFrame * frameSize
        let endSample = min(samples.count, (endFrame + 1) * frameSize)
        guard endSample > startSample else { return samples }
        return Array(samples[startSample..<endSample])
    }

    private static func dumpPCM16(_ samples: [Int16], to path: String) {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * bitsPerSample / 8
        let dataSize: UInt32 = UInt32(samples.count * 2)
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        var chunkSize: UInt32 = 36 + dataSize
        wav.append(Data(bytes: &chunkSize, count: 4))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        var subchunk1Size: UInt32 = 16
        wav.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1
        wav.append(Data(bytes: &audioFormat, count: 2))
        var ch = channels
        wav.append(Data(bytes: &ch, count: 2))
        var sr = sampleRate
        wav.append(Data(bytes: &sr, count: 4))
        var br = byteRate
        wav.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        wav.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample
        wav.append(Data(bytes: &bps, count: 2))
        wav.append("data".data(using: .ascii)!)
        var ds = dataSize
        wav.append(Data(bytes: &ds, count: 4))
        samples.withUnsafeBufferPointer { buf in
            wav.append(UnsafeBufferPointer(start: buf.baseAddress?.withMemoryRebound(to: UInt8.self, capacity: samples.count * 2) { $0 }, count: samples.count * 2))
        }
        try? wav.write(to: URL(fileURLWithPath: path))
    }

    private static func int16Samples(from audioData: Data) -> [Int16] {
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        audioData.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset + MemoryLayout<Int16>.size <= rawBuffer.count {
                let raw = rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                samples.append(Int16(littleEndian: raw))
                offset += MemoryLayout<Int16>.size
            }
        }
        return samples
    }

    private func deliverFinal(_ text: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(text)
    }

    deinit {
        transcriptionTask?.cancel()
    }
}
