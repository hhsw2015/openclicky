//
//  SKIModeHandsFreeSession.swift
//  cursor-buddy
//
//  Opt-in hands-free (VAD-driven) capture for SKI Mode. When the user
//  flips "hands-free mode" ON in Settings, this session keeps the mic
//  open (16 kHz mono), feeds every 576-sample chunk to Silero VAD, and
//  emits a completed utterance once the trailing silence exceeds
//  `vad_silence_ms` (default 2000 ms, matches SKI). The emitted PCM is
//  handed to the same whisper transcriber the PTT path uses; the final
//  text lands in `.oc/events.jsonl` via OpenClickyFileBridge.
//
//  Toggle key: `openclicky.ski.handsFreeMode` (Bool, default false).
//  Tunables:
//    - `openclicky.ski.vadSilenceMs`  Int  default 2000
//    - `openclicky.ski.vadThreshold`  Double default 0.5
//
//  Failure modes we guard:
//    - No mic permission → session refuses to start, logs skip.
//    - Silero unavailable → session refuses to start.
//    - Whisper says `no_speech > 0.6` → drop utterance silently to
//      avoid piping wall-of-YouTube-subtitles at the CLI agent when
//      only room noise / music was captured.
//

import AVFoundation
import Combine
import Foundation
import SileroVAD

@MainActor
final class SKIModeHandsFreeSession: ObservableObject {
    static let shared = SKIModeHandsFreeSession()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isCapturing: Bool = false

    private var engine: AVAudioEngine?
    /// FIX(task #326 F3): the audio-tap side accesses vad + these
    /// three buffers off-main. Serial `ingestQueue` serializes access
    /// so the `nonisolated(unsafe)` is safe in practice.
    nonisolated(unsafe) private var vad: SileroVAD?
    nonisolated(unsafe) private var speechBuffer: [Int16] = []
    nonisolated(unsafe) private var silenceRunFrames: Int = 0
    nonisolated(unsafe) private var isInSpeech: Bool = false
    private var cancellables: Set<AnyCancellable> = []

    /// FIX(task #326 F3): serial background queue for VAD ingest.
    /// Prior code fired `Task { @MainActor in ingest(...) }` per audio
    /// buffer (~30-50 Hz), saturating the main thread. Ingest doesn't
    /// need MainActor — only the `isCapturing` publish + notification
    /// do, and those bounce onto MainActor from within.
    private let ingestQueue = DispatchQueue(
        label: "com.openclicky.ski.handsfree.ingest",
        qos: .userInitiated
    )

    /// Number of chunks (~36 ms each) of trailing silence before we
    /// close the utterance. Read from UserDefaults with the SKI default.
    private var silenceHangoverFrames: Int {
        let ms = UserDefaults.standard.integer(forKey: "openclicky.ski.vadSilenceMs")
        let effective = ms > 0 ? ms : 2000
        return max(1, effective / 36)
    }

    /// Speech-probability threshold for Silero VAD.
    private var speechThreshold: Float {
        let v = UserDefaults.standard.double(forKey: "openclicky.ski.vadThreshold")
        return v > 0 ? Float(v) : 0.5
    }

    private init() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
    }

    /// Start / stop based on the user's toggle. Idempotent.
    func reconcile() {
        let enabled = UserDefaults.standard.bool(forKey: "openclicky.ski.handsFreeMode")
        let inSKI = OpenClickyProfileCatalog.activeProfile().id == "ski_mode"
        if enabled && inSKI {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isRunning else { return }
        do {
            vad = try SileroVAD()
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.handsfree_start_failed",
                fields: ["reason": "silero_load_failed", "error": "\(error)"]
            )
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        // Target: mono 16 kHz Int16 for whisper.cpp. AVAudioEngine
        // gives us Float32 at hardware rate; convert per-buffer.
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: true) else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.handsfree_start_failed",
                fields: ["reason": "outformat_nil"]
            )
            return
        }
        let converter = AVAudioConverter(from: inputFormat, to: outFormat)

        // Snapshot values that the audio tap needs off-main.
        let queue = self.ingestQueue
        let hangover = self.silenceHangoverFrames
        let threshold = self.speechThreshold
        let vadRef = self.vad
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let converter = converter else { return }
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000.0 / inputFormat.sampleRate) + 512
            guard let converted = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            var supplied = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            let count = Int(converted.frameLength)
            guard count > 0,
                  let int16 = converted.int16ChannelData?.pointee else { return }
            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count { samples[i] = int16[i] }
            // FIX(task #326 F3): dispatch onto our serial ingest queue
            // instead of hopping onto the MainActor per audio buffer.
            queue.async { [weak self, vadRef, hangover, threshold] in
                self?.ingestOffMain(samples: samples, vad: vadRef,
                                    hangover: hangover, threshold: threshold)
            }
        }
        do {
            try engine.start()
            self.engine = engine
            self.isRunning = true
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.handsfree_started",
                fields: [
                    "silence_hangover_frames": String(silenceHangoverFrames),
                    "speech_threshold": String(format: "%.2f", speechThreshold)
                ]
            )
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.handsfree_start_failed",
                fields: ["reason": "engine_start", "error": "\(error)"]
            )
        }
    }

    private func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        vad = nil
        speechBuffer.removeAll()
        silenceRunFrames = 0
        isInSpeech = false
        isRunning = false
        isCapturing = false
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.ski.handsfree_stopped",
            fields: [:]
        )
    }

    /// Off-main audio ingest. Runs on `ingestQueue`; touches
    /// speechBuffer / silenceRunFrames / isInSpeech without main-actor
    /// isolation. Safe because the queue is serial — only one caller
    /// at a time. When it detects a flush condition it bounces onto
    /// MainActor to post notification + update `@Published` state.
    nonisolated(unsafe) private func ingestOffMain(
        samples: [Int16],
        vad: SileroVAD?,
        hangover: Int,
        threshold: Float
    ) {
        guard let vad = vad else { return }
        let chunkSize = 576
        var floats = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { floats[i] = Float(samples[i]) / 32768.0 }
        var offset = 0
        while offset + chunkSize <= floats.count {
            let chunk = Array(floats[offset..<(offset + chunkSize)])
            offset += chunkSize
            let probability: Float
            do {
                probability = try vad.process(chunk)
            } catch {
                continue
            }
            let isSpeech = probability >= threshold
            let base = (offset - chunkSize)
            for i in 0..<chunkSize {
                let s = samples[min(samples.count - 1, base + i)]
                speechBuffer.append(s)
            }
            // Cap ring at 60 s. FIX(task #326 F3 detail): avoid the
            // O(n) removeFirst by only doing it when we cross the cap
            // AND we're not in speech (a mid-speech trim would drop
            // audio the user wants).
            if !isInSpeech && speechBuffer.count > 16_000 * 60 {
                speechBuffer.removeFirst(speechBuffer.count - 16_000 * 60)
            }
            if isSpeech {
                if !isInSpeech {
                    isInSpeech = true
                    DispatchQueue.main.async { [weak self] in
                        self?.isCapturing = true
                    }
                }
                silenceRunFrames = 0
            } else if isInSpeech {
                silenceRunFrames += 1
                if silenceRunFrames >= hangover {
                    flushUtteranceOffMain()
                }
            } else {
                if speechBuffer.count > chunkSize * 4 {
                    speechBuffer.removeFirst(speechBuffer.count - chunkSize * 4)
                }
            }
        }
    }

    /// Off-main flush: capture the buffered samples, reset VAD state,
    /// hop to main only to post notification.
    nonisolated(unsafe) private func flushUtteranceOffMain() {
        let samples = speechBuffer
        speechBuffer.removeAll(keepingCapacity: true)
        silenceRunFrames = 0
        isInSpeech = false
        // FIX(task #326 F4 hands-free): reset Silero between
        // utterances so LSTM state doesn't drift across long sessions.
        vad?.reset()
        guard samples.count >= 16_000 / 2 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            NotificationCenter.default.post(
                name: Notification.Name("com.openclicky.ski.handsFreeUtteranceCaptured"),
                object: nil,
                userInfo: ["samples": samples]
            )
        }
    }

    /// Legacy MainActor entrypoint retained for callers that still
    /// hop through it (none in production; kept for completeness).
    private func ingest(samples: [Int16]) {
        guard let vad = vad else { return }
        let chunkSize = 576
        var floats = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { floats[i] = Float(samples[i]) / 32768.0 }

        var offset = 0
        while offset + chunkSize <= floats.count {
            let chunk = Array(floats[offset..<(offset + chunkSize)])
            offset += chunkSize
            let probability: Float
            do {
                probability = try vad.process(chunk)
            } catch {
                continue
            }
            let isSpeech = probability >= speechThreshold

            // Always accumulate raw samples in the buffer for the
            // window that MIGHT be an utterance.
            let base = (offset - chunkSize)
            for i in 0..<chunkSize {
                let s = samples[min(samples.count - 1, base + i)]
                speechBuffer.append(s)
            }
            // Cap buffer at ~60 s to avoid runaway.
            if speechBuffer.count > 16_000 * 60 {
                speechBuffer.removeFirst(speechBuffer.count - 16_000 * 60)
            }

            if isSpeech {
                if !isInSpeech {
                    isInSpeech = true
                    isCapturing = true
                }
                silenceRunFrames = 0
            } else if isInSpeech {
                silenceRunFrames += 1
                if silenceRunFrames >= silenceHangoverFrames {
                    flushUtterance()
                }
            } else {
                // Not in speech and no new speech: keep the buffer
                // trimmed to a small look-back window (lead-in).
                if speechBuffer.count > chunkSize * 4 {
                    speechBuffer.removeFirst(speechBuffer.count - chunkSize * 4)
                }
            }
        }
    }

    /// A speech run just ended. Hand the buffered samples off to
    /// whisper via the same provider the PTT path uses, then wire the
    /// text through the SKI file bridge.
    private func flushUtterance() {
        let samples = speechBuffer
        speechBuffer.removeAll(keepingCapacity: true)
        silenceRunFrames = 0
        isInSpeech = false
        isCapturing = false
        guard samples.count >= 16_000 / 2 else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.ski.handsfree_utterance_dropped",
                fields: ["reason": "too_short", "samples": String(samples.count)]
            )
            return
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.ski.handsfree_utterance_captured",
            fields: ["samples": String(samples.count)]
        )
        // Notify listeners (CompanionManager) so they can pump the
        // audio through the current whisper provider and then the
        // file bridge. Kept as a notification so this file stays
        // independent of the transcriber import surface.
        NotificationCenter.default.post(
            name: Notification.Name("com.openclicky.ski.handsFreeUtteranceCaptured"),
            object: nil,
            userInfo: ["samples": samples]
        )
    }
}
