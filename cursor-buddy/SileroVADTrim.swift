//
//  SileroVADTrim.swift
//  cursor-buddy
//
//  Wraps paean-ai/silero-vad-swift (Silero VAD v6 via CoreML) to
//  return only the speech-tagged region of a PTT audio clip. Feeds
//  Whisper a clean speech-only stream so it stops hallucinating on
//  silence-heavy inputs (SKI parity).
//
//  Silero expects 576-sample chunks @ 16 kHz (36 ms). We iterate
//  frame-by-frame, tag each as speech / silence, then splice out
//  the contiguous speech region (with a small silence-hangover so
//  we don't clip word endings).
//

import Foundation
import SileroVAD

enum SileroVADTrim {
    // Silero v6 config
    private static let chunkSize = 576
    private static let sampleRate = 16_000
    /// Frames below this probability are treated as silence.
    private static let speechThreshold: Float = 0.5
    /// Number of consecutive silent frames after speech before we
    /// call the utterance "ended". At 36 ms/frame, 14 frames ≈ 500 ms
    /// — SKI uses ~2000 ms hangover for its full VAD; PTT clips are
    /// much shorter so 500 ms is enough to avoid clipping word tails.
    private static let silenceHangoverFrames = 14
    /// Padding kept at the start of speech (in frames).
    private static let leadInFrames = 3

    // Shared VAD instance — reset() before each utterance.
    private static let vad: SileroVAD? = {
        return try? SileroVAD()
    }()

    /// Given Int16 mono @ 16 kHz PCM, return only the speech-tagged
    /// slice. Falls back to the input unchanged if the VAD model
    /// can't be loaded.
    static func speechOnly(_ samples: [Int16]) -> [Int16] {
        guard let vad = vad, samples.count >= chunkSize else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.silerovad.skip",
                fields: [
                    "reason": (vad == nil ? "model_nil" : "too_short"),
                    "input_samples": String(samples.count)
                ]
            )
            return samples
        }
        vad.reset()

        // Convert Int16 → Float32 [-1, 1] as Silero expects.
        var floats = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            floats[i] = Float(samples[i]) / 32768.0
        }

        // Run VAD frame-by-frame, tag each 576-sample chunk.
        let frameCount = floats.count / chunkSize
        var isSpeech = [Bool](repeating: false, count: frameCount)
        for f in 0..<frameCount {
            let start = f * chunkSize
            let chunk = Array(floats[start..<(start + chunkSize)])
            let probability: Float
            do {
                probability = try vad.process(chunk)
            } catch {
                // If any frame errors, bail and return original —
                // upstream RMS floor still catches full-silence.
                return samples
            }
            isSpeech[f] = probability >= speechThreshold
        }

        let speechFrames = isSpeech.filter { $0 }.count
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.silerovad.stats",
            fields: [
                "input_samples": String(samples.count),
                "total_frames": String(frameCount),
                "speech_frames": String(speechFrames),
                "speech_pct": String(speechFrames * 100 / max(frameCount, 1))
            ]
        )
        // Find first speech frame + last speech frame (with hangover).
        guard let firstSpeech = isSpeech.firstIndex(of: true) else {
            // Nothing speech-tagged — return empty so caller drops.
            return []
        }
        var lastSpeech = isSpeech.count - 1
        while lastSpeech >= 0 && !isSpeech[lastSpeech] {
            lastSpeech -= 1
        }
        // Extend the tail by hangover so word endings survive.
        let endFrame = min(isSpeech.count - 1, lastSpeech + silenceHangoverFrames)
        let startFrame = max(0, firstSpeech - leadInFrames)

        let startSample = startFrame * chunkSize
        let endSample = min(samples.count, (endFrame + 1) * chunkSize)
        guard endSample > startSample else { return [] }
        var out = Array(samples[startSample..<endSample])
        // FIX(gain-boost-2026-08-04): peak-normalize speech-only slice
        // to Int16 ±16384 (~-6 dBFS). SKI's VoiceProcessingIO does this
        // upstream via Apple AGC; we do it explicitly here. Otherwise
        // quiet mic input goes to whisper at RMS ~0.03 and the model
        // hallucinates YouTube subtitle sequences (「优优独播剧场」etc.)
        // because it sees speech shape but too-low energy for phonetic
        // discrimination.
        var peak: Int16 = 1
        for s in out {
            let a = s == Int16.min ? Int16.max : abs(s)
            if a > peak { peak = a }
        }
        if peak > 0 && peak < 12_000 {
            let scale = Double(16_384) / Double(peak)
            for i in 0..<out.count {
                let boosted = Double(out[i]) * scale
                let clamped = max(-32_768.0, min(32_767.0, boosted))
                out[i] = Int16(clamped)
            }
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.silerovad.trim",
            fields: [
                "in_samples": String(samples.count),
                "out_samples": String(out.count),
                "kept_pct": String(out.count * 100 / max(samples.count, 1)),
                "peak_before": String(peak),
                "gain_applied": peak < 12_000 && peak > 0 ? "yes" : "no"
            ]
        )
        return out
    }
}
