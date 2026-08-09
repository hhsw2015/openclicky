// WhisperCppTranscriber — local Whisper.cpp AudioTranscriber.
//
// Ported from retrace `WhisperCppTranscriptionService.swift` (MIT).
// Uses the vendored `libwhisper.dylib` + ggml stack in
// `/Vendors/whisper/`. Model file (whisper-small ~465 MB) downloads
// on first use into
//   ~/Library/Application Support/OpenClicky/models/whisper-small.bin
// Falls through to Apple Speech if download or init fails so the
// pipeline never blocks on a missing model.
//
// FIX(whisper-2026-07-31): user needed Chinese transcription quality
// significantly better than Apple Speech (which produced "祝福窗户
// 数学" for "北京大学数学系"). Whisper Small on-device with zh-CN
// gets to CER ~5% — comparable to Rewind AI / retrace.

import Foundation
import AVFoundation
#if canImport(CWhisper)
import CWhisper
#endif

/// FIX(whisper-quit-abort-2026-08-04): vendored libggml-metal.0.dylib
/// has an async worker (`ggml_metal_rsets_init`) that outlives static
/// destruction on Cmd-Q; the destructor's `ggml_abort` then SIGABRTs
/// the process. Track every live context in a global set and free them
/// before AppKit calls `exit()`.
private final class WhisperContextRegistry: @unchecked Sendable {
    static let shared = WhisperContextRegistry()
    private let lock = NSLock()
    private var contexts: Set<OpaqueContextBox> = []

    struct OpaqueContextBox: Hashable {
        let ptr: OpaquePointer
        static func == (a: Self, b: Self) -> Bool { a.ptr == b.ptr }
        func hash(into hasher: inout Hasher) { hasher.combine(UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(ptr)))) }
    }

    func register(_ ctx: OpaquePointer) {
        lock.lock(); defer { lock.unlock() }
        contexts.insert(OpaqueContextBox(ptr: ctx))
    }

    func drop(_ ctx: OpaquePointer) {
        lock.lock(); defer { lock.unlock() }
        contexts.remove(OpaqueContextBox(ptr: ctx))
    }

    /// Call from `applicationWillTerminate` before AppKit's exit() to
    /// avoid the ggml-metal static destructor's abort race.
    static func freeAllForShutdown() {
        #if canImport(CWhisper)
        let all = shared.snapshot()
        for box in all {
            whisper_free(box.ptr)
        }
        shared.clear()
        #endif
    }

    private func snapshot() -> Set<OpaqueContextBox> {
        lock.lock(); defer { lock.unlock() }
        return contexts
    }

    private func clear() {
        lock.lock(); defer { lock.unlock() }
        contexts.removeAll()
    }
}

/// Public entry called from AppDelegate.applicationWillTerminate.
public enum WhisperCppShutdown {
    public static func freeAll() {
        WhisperContextRegistry.freeAllForShutdown()
    }
}

public final class WhisperCppTranscriber: AudioTranscriber, @unchecked Sendable {

    public var displayName: String { "whisper.cpp:\(modelName)" }

    /// Shared cache of (model, language) → transcriber. Prevents each
    /// PTT press / hands-free flush / segmenter utterance from
    /// building a fresh 465-547 MB whisper context. FIX(task #326 F1).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: WhisperCppTranscriber] = [:]

    public static func shared(modelName: String, language: String) -> WhisperCppTranscriber {
        let key = "\(modelName)|\(language)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        let fresh = WhisperCppTranscriber(modelName: modelName, language: language)
        cache[key] = fresh
        return fresh
    }

    private let modelName: String
    private let modelURL: URL
    private let downloadURL: URL
    private let language: String
    private let lock = NSLock()
    /// Held for the duration of a single `whisper_full` call so
    /// concurrent transcribes (background segmenter + PTT + hands-free)
    /// serialize on the same ctx instead of corrupting each other.
    /// FIX(task #326 F2).
    private let whisperCallLock = NSLock()
    private var context: OpaquePointer?
    private var initTask: Task<Void, Error>?

    deinit {
        // FIX(task #326 F6): free the whisper_ctx we owned so the
        // 465-547 MB model buffer doesn't leak. If this transcriber
        // was in the shared cache, cache eviction is what freed the
        // last strong ref → this deinit runs off-main.
        if let ctx = context {
            WhisperContextRegistry.shared.drop(ctx)
            whisper_free(ctx)
        }
        context = nil
        initTask = nil
    }
    /// FIX(whisper-fallback-2026-07-31): if Whisper.cpp bootstrap fails
    /// (download refused, disk error, ggml init returns null…), don't
    /// leave the user with ZERO transcripts. Fall through to Apple
    /// Speech so mic captured audio still becomes searchable text.
    /// AppleSpeech uses cloud zh-CN which beats no-transcript-at-all
    /// even though CER is worse than Whisper. Sticky: once we fail,
    /// stop retrying the huggingface download on every utterance.
    private let fallback: AppleSpeechTranscriber
    private var whisperDisabled = false

    public init(modelName: String = "small",
                language: String = "zh") {
        // FIX(whisper-url-2026-08-01): huggingface artifacts are named
        // `ggml-small.bin` / `ggml-medium.bin`, NOT `ggml-whisper-small.bin`.
        // Previous default `"whisper-small"` produced a 404 that stuck
        // the fallback path forever. Strip the redundant prefix.
        self.modelName = modelName
        self.language = language
        self.fallback = AppleSpeechTranscriber(
            locale: Locale(identifier: language == "zh" ? "zh-CN" : language))

        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first!
        let modelsDir = root.appendingPathComponent("OpenClicky/models",
                                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir,
                                                  withIntermediateDirectories: true)
        self.modelURL = modelsDir.appendingPathComponent("ggml-\(modelName).bin")
        self.downloadURL = URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(modelName).bin"
        )!
    }

    public func transcribe(utterance: AudioUtterance) async throws
        -> [AudioTranscriptWord]
    {
        // FIX(whisper-hallucination-guard-2026-08-01): Whisper base+small
        // hallucinate confident-sounding Chinese subtitles on silent /
        // near-silent input ("剛剛還有的食物說了什麼", "字幕製作:貝爾").
        // Gate: (a) require >= 1.5s of audio, (b) require RMS energy
        // above a real-speech floor. Utterances that pass VAD but are
        // just AC hum / keyboard clicks get dropped here before they
        // waste a whisper pass and pollute the DB.
        let sampleCount = utterance.samples.count
        let minSamples = 24_000  // 1.5s @ 16k
        if sampleCount < minSamples {
            logEvent("skip_too_short", ["samples": sampleCount])
            return []
        }
        // RMS over int16 samples normalised to [-1, 1].
        var acc: Double = 0
        for s in utterance.samples {
            let v = Double(s) / 32_768.0
            acc += v * v
        }
        let rms = (acc / Double(sampleCount)).squareRoot()
        // FIX(whisper-halluc-2026-08-01b): 0.05 for passive capture
        // (OpenRewind background mic recording, where >99% of clips
        // are near-silence and hallucination cost dominates).
        // FIX(whisper-ptt-rms-2026-08-04): PTT dictation
        // (source="voice") is a user actively holding the mic key —
        // hallucination risk is small and the caller expects a
        // response. Drop the floor so short/quiet-mic PTT still
        // transcribes. no_speech_thold + suppress_nst below still
        // block the classic subtitle-poisoning output.
        let rmsFloor = utterance.source == "voice" ? 0.01 : 0.05
        if rms < rmsFloor {
            logEvent("skip_low_rms", ["rms_x1000": Int(rms * 1000),
                                       "samples": sampleCount])
            return []
        }
        logEvent("transcribe_call",
                 ["samples": sampleCount,
                  "duration_s": Int(utterance.duration),
                  "rms_x1000": Int(rms * 1000),
                  "source": utterance.source,
                  "disabled": whisperDisabled])
        #if canImport(CWhisper)
        if whisperDisabled {
            return try await fallback.transcribe(utterance: utterance)
        }
        do {
            try await ensureReady()
            let words = try await runWhisper(utterance: utterance)
            logEvent("transcribe_ok", ["words": words.count])
            return words
        } catch {
            logEvent("transcribe_failed_falling_back", ["error": "\(error)"])
            whisperDisabled = true
            return try await fallback.transcribe(utterance: utterance)
        }
        #else
        logEvent("cwhisper_not_linked_fallback")
        return try await fallback.transcribe(utterance: utterance)
        #endif
    }

    // MARK: - Init / download

    private func ensureReady() async throws {
        if context != nil { return }
        // Coalesce concurrent init attempts.
        if let task = initTask { return try await task.value }
        let task = Task { try await self.bootstrap() }
        initTask = task
        try await task.value
    }

    private func logEvent(_ event: String, _ fields: [String: Any] = [:]) {
        var f = fields
        f["provider"] = "whisper.cpp"
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.whisper.\(event)", fields: f)
    }

    private func bootstrap() async throws {
        logEvent("bootstrap_start", ["model": modelName,
                                    "modelPath": modelURL.path])
        // FIX(whisper-explicit-download-2026-08-04): removed opportunistic
        // URLSession.shared.download from this path so an accidental
        // provider selection cannot silently spend 30-90 s downloading
        // hundreds of megabytes. The model must be present already —
        // users trigger download from Settings -> Advanced Providers.
        // Fallback path (Apple Speech) still fires on the catch site.
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            logEvent("model_missing", ["path": modelURL.path])
            throw NSError(
                domain: "openclicky-whisper",
                code: -404,
                userInfo: [NSLocalizedDescriptionKey:
                    "Whisper model \(modelName) not downloaded. Open Advanced Providers to download it."]
            )
        }
        logEvent("model_present", ["path": modelURL.path])
        #if canImport(CWhisper)
        logEvent("init_context_start")
        try initContext()
        logEvent("init_context_ok")
        #endif
    }

    #if canImport(CWhisper)
    private func initContext() throws {
        // FIX(whisper-coreml-stub-crash-2026-08-01): even when a real
        // ggml-<model>-encoder.mlmodelc sits next to the .bin, the
        // `_with_params(use_gpu=true)` path still routes through our
        // vendored `libwhisper.coreml.dylib` stub whose
        // `whisper_coreml_init` returns NULL — whisper.cpp then runs
        // partial cleanup that double-frees encoder state → SIGABRT.
        // Rebuilding the coreml dylib properly is task #259. Until
        // then always use the plain `whisper_init_from_file` path
        // (CPU + Metal encoder, no CoreML). Still ~5-10× faster than
        // Apple Speech cloud and CER ~15% on zh-CN with base model.
        logEvent("init_path", ["variant": "plain_no_coreml"])
        guard let ctx = whisper_init_from_file(modelURL.path) else {
            throw NSError(domain: "openclicky-whisper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "whisper_init_from_file returned NULL"])
        }
        lock.lock(); self.context = ctx; lock.unlock()
        WhisperContextRegistry.shared.register(ctx)
    }

    /// Convert Int16 samples → Float32 in [-1, 1] and call whisper_full.
    private func runWhisper(utterance: AudioUtterance) async throws
        -> [AudioTranscriptWord]
    {
        guard let ctx = context else { return [] }
        // SKI parity: raw f32 samples, no peak-normalization, no RMS
        // rejection at this layer. Silero VAD upstream is what trims
        // silence — for OpenClicky PTT (no VAD), we accept the tradeoff
        // that quiet clips may produce short output.
        let samples: [Float] = utterance.samples.map { Float($0) / 32768.0 }
        // FIX(whisper-ski-parity-2026-08-04): reversed SKI (heyski.io)
        // binary — `WhisperEngine::infer` @ 0x1007a9014 in ski. SKI uses
        // BEAM_SEARCH with beam_size=3 (not greedy) and lets whisper.cpp
        // pick its own no_speech / entropy / logprob thresholds instead
        // of overriding them. Greedy + strict thresholds was our #1
        // reason for the "quiet mic → 1 kanji" degenerate output.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 3
        params.beam_search.patience = -1.0
        // language hint — nil = whisper.cpp auto-detect. Force "zh"
        // if the user configured a Chinese response language; drop the
        // string entirely (null pointer) for auto. Passing the literal
        // string "auto" to whisper.cpp DOES NOT mean auto — it means
        // an unknown language code, and the decoder falls through to
        // whatever the training-set prior points at (which is why we
        // were seeing "优优独播剧场").
        let effectiveLanguage: String? = {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "auto" {
                return nil
            }
            return trimmed
        }()
        var langCString: UnsafePointer<CChar>? = nil
        if let lang = effectiveLanguage {
            langCString = lang.withCString { p in UnsafePointer(strdup(p)) }
        }
        params.language = langCString
        params.translate = false
        // FIX(whisper-hallucination-2026-08-01): short-audio zh with
        // any context bleed produces training-data poison like
        // "(字幕製作:貝爾)" (subtitle credit from training data).
        // Reset context every call + suppress non-speech tokens +
        // pin temperature=0 + block completely-silent clips via
        // no_speech_thold. Standard whisper.cpp hallucination fix set.
        // whisper-cli (that works on our audio dump) uses defaults:
        // no_context=false, single_segment=false. Match those instead
        // of the SKI reversal — SKI may internally control segment
        // boundaries via Silero, and single_segment gives us the
        // "优优独播剧场" hallucination on multi-segment audio.
        params.no_context = false
        params.single_segment = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.temperature = 0.2  // SKI offset 48
        // SKI parity: NO override on no_speech_thold / entropy_thold /
        // logprob_thold / suppress_blank / suppress_nst — leave the
        // whisper.cpp defaults. Our aggressive override values were
        // starving the decoder.

        // FIX(task #326 F2): serialize whisper_full calls across
        // concurrent callers (background segmenter + PTT + hands-free
        // all share the singleton). Two concurrent `whisper_full` on
        // the same ctx corrupts internal state.
        whisperCallLock.lock()
        let rc = samples.withUnsafeBufferPointer { p -> Int32 in
            whisper_full(ctx, params, p.baseAddress, Int32(samples.count))
        }
        whisperCallLock.unlock()
        // Free the dup'd language cstring.
        if let langCString { free(UnsafeMutablePointer(mutating: langCString)) }
        guard rc == 0 else { return [] }

        var words: [AudioTranscriptWord] = []
        let nSegments = whisper_full_n_segments(ctx)
        // Post-decode hallucination filter: whisper.cpp exposes
        // per-segment "probability the model thinks this was silence".
        // High no_speech = high hallucination risk. Drop >= 0.4.
        for i in 0..<nSegments {
            guard let txt = whisper_full_get_segment_text(ctx, i) else { continue }
            let start = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
            let end   = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
            // SKI parity: NO post-decode noSpeechProb filter. SKI takes
            // whatever segment whisper produces; the filter here was
            // dropping legitimate output on quiet clips and forcing the
            // model into a hallucination retry loop.
            _ = whisper_full_get_segment_no_speech_prob(ctx, i)
            // FIX(whisper-utf8-2026-08-01): `String(cString:)` bails at
            // the first invalid UTF-8 byte, silently truncating multi-
            // byte CJK sequences when whisper.cpp's static output buffer
            // ends mid-codepoint. `String(decoding:as:)` with `Unicode.
            // UTF8.self` handles the boundary by replacing broken tail
            // bytes with `\u{FFFD}` and keeping the rest. Then strip
            // the replacement char before insertion so the row stays
            // clean.
            let cText = String(decoding: UnsafeBufferPointer(
                start: UnsafePointer<UInt8>(OpaquePointer(txt)),
                count: strlen(txt)), as: Unicode.UTF8.self)
            let text = cText
                .replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words.append(.init(text: text, start: start, end: end, confidence: 0.9))
        }
        return words
    }
    #endif
}
