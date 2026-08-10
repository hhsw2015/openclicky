//
//  OpenClickySmartTurnDetector.swift
//  cursor-buddy
//
//  End-of-turn detection: "did the speaker finish their thought?" from the
//  last 8 s of audio, in ~12-30 ms.
//
//  What it replaces. SKI hands-free currently closes an utterance after a
//  flat 2 s of silence (`SKIModeHandsFreeSession.silenceHangoverFrames`).
//  That is both too slow — 2 s added to every turn the user actually
//  finished — and too fast, because it fires on any thoughtful pause
//  mid-sentence. Silence duration is a poor proxy for completion;
//  intonation is a good one, and that is what this model reads.
//
//  Deliberately independent of E4B. 01 measured every Gemma variant at
//  chance on end-of-turn while costing 0.6-3.6 s, versus smart-turn's 0.96
//  accuracy at 19 ms. Turn-taking is an acoustic problem, not a language
//  one, and coupling them would mean losing turn detection whenever the
//  language model is off.
//
//  The features are the risk, not the inference — see
//  OpenClickyWhisperLogMel and scripts/verify-logmel.sh.
//

import Foundation

#if canImport(onnxruntime)
import onnxruntime
#endif

/// One end-of-turn judgement.
struct OpenClickySmartTurnPrediction {
    /// P(the speaker finished their thought), 0...1.
    let completionProbability: Float
    /// Milliseconds spent in feature extraction plus inference.
    let elapsedMilliseconds: Double

    /// Default threshold. Deliberately above 0.5: a false "finished" cuts
    /// the user off mid-sentence, which is far more annoying than a false
    /// "still talking" — that costs at most the hangover we already pay.
    static let defaultThreshold: Float = 0.7

    func indicatesCompletion(threshold: Float = defaultThreshold) -> Bool {
        completionProbability >= threshold
    }
}

actor OpenClickySmartTurnDetector {

    static let shared = OpenClickySmartTurnDetector()

    /// The model looks at exactly 8 s. Shorter input is left-padded, longer
    /// is trimmed to the most recent 8 s — see `predict(samples:)`.
    static let windowSamples = OpenClickyWhisperLogMel.expectedSamples
    static let sampleRate = OpenClickyWhisperLogMel.sampleRate

    /// Bundle subdirectory, alongside the routelet assets.
    private static let modelSubdirectory = "smart-turn"
    private static let modelName = "smart-turn-v3.2-cpu"

    #if canImport(onnxruntime)
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    #endif
    private var didAttemptLoad = false

    // MARK: - Availability

    /// Whether the model file is present. The feature is opt-in and the
    /// asset is 8 MB, so absence is a normal state, not an error.
    nonisolated static var isModelAvailable: Bool {
        modelURL() != nil
    }

    nonisolated static func modelURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_SMART_TURN_MODEL"],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: modelName,
                                         withExtension: "onnx",
                                         subdirectory: modelSubdirectory) {
            return bundled
        }
        // Manual install, matching where the local LLM weights live.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/smart-turn/\(modelName).onnx")
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    // MARK: - Prediction

    /// Judge whether the speaker has finished.
    ///
    /// `samples` is mono float in [-1, 1] at 16 kHz. Any length is accepted:
    /// shorter than 8 s is LEFT-padded with silence, longer keeps the most
    /// recent 8 s. Left, not right — the model was trained on utterances
    /// that end at the buffer's end, so the decision hinges on the final
    /// few hundred milliseconds. Right-padding would push the actual speech
    /// away from where the model looks for it.
    ///
    /// Returns nil when the model is unavailable or inference fails, so the
    /// caller falls back to the existing hangover rather than guessing.
    func predict(samples: [Float]) async -> OpenClickySmartTurnPrediction? {
        #if canImport(onnxruntime)
        let started = Date()

        let window = Self.fitToWindow(samples)
        guard let features = OpenClickyWhisperLogMel.features(from: window) else { return nil }

        guard let session = loadSessionIfNeeded() else { return nil }

        do {
            let shape: [NSNumber] = [1,
                                     NSNumber(value: OpenClickyWhisperLogMel.melBins),
                                     NSNumber(value: OpenClickyWhisperLogMel.frames)]
            let data = features.withUnsafeBufferPointer { Data(buffer: $0) }
            let input = try ORTValue(tensorData: NSMutableData(data: data),
                                     elementType: ORTTensorElementDataType.float,
                                     shape: shape)

            let outputName = (try? session.outputNames())?.first ?? "logits"
            let outputs = try session.run(withInputs: ["input_features": input],
                                          outputNames: Set([outputName]),
                                          runOptions: nil)
            guard let value = outputs[outputName],
                  let raw = try? value.tensorData() as Data,
                  raw.count >= MemoryLayout<Float>.size else { return nil }

            // The sigmoid IS baked into the graph — use the output as-is.
            //
            // The output tensor is NAMED `logits`, which invites applying
            // one. It is not a logit: feeding all-zeros, all-+5 and all--5
            // returns 0.9889, 0.8341 and 0.9870, i.e. always inside (0,1),
            // and parlor's reference reads `outputs[0][0]` straight into
            // `probability`. A second sigmoid would squash everything
            // toward 0.5 and quietly make the threshold meaningless — the
            // model would still return plausible numbers. 04 lists this
            // trap; I hit it anyway and only caught it by probing the
            // graph.
            let probability = raw.withUnsafeBytes { $0.load(as: Float.self) }

            return OpenClickySmartTurnPrediction(
                completionProbability: probability,
                elapsedMilliseconds: Date().timeIntervalSince(started) * 1000
            )
        } catch {
            NSLog("[SmartTurn] inference failed: \(error.localizedDescription)")
            return nil
        }
        #else
        _ = samples
        return nil
        #endif
    }

    /// Left-pad or tail-trim to exactly one window.
    nonisolated static func fitToWindow(_ samples: [Float]) -> [Float] {
        if samples.count == windowSamples { return samples }
        if samples.count > windowSamples {
            return Array(samples.suffix(windowSamples))
        }
        var padded = [Float](repeating: 0, count: windowSamples - samples.count)
        padded.append(contentsOf: samples)
        return padded
    }

    // MARK: - Session

    #if canImport(onnxruntime)
    private func loadSessionIfNeeded() -> ORTSession? {
        if let ortSession { return ortSession }
        if didAttemptLoad { return nil }
        didAttemptLoad = true

        guard let url = Self.modelURL() else {
            NSLog("[SmartTurn] model not found; end-of-turn detection stays off")
            return nil
        }
        do {
            let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let session = try ORTSession(env: env,
                                         modelPath: url.path,
                                         sessionOptions: try ORTSessionOptions())
            ortEnv = env
            ortSession = session
            return session
        } catch {
            NSLog("[SmartTurn] could not load model: \(error.localizedDescription)")
            return nil
        }
    }
    #endif
}
