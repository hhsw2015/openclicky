//
//  OpenClickyIntentClassifier.swift
//  cursor-buddy
//
//  On-device intent classifier ported from Peeky's `routelet`
//  (peeky/src/routelet/mod.rs). Deliberately **not** namespaced under
//  Mirage — this is a generic OpenClicky capability that any profile
//  can consume:
//
//    * Peeky Free profile → MiragePeekyOrchestrator uses it to route
//      requests among chat / find_action / integration / memory before
//      falling back to Claude classifier.
//    * SKI Mode → the same classifier can label the transcribed
//      utterance so SKI can pick a response strategy without another
//      API call.
//    * Any future profile that wants sub-100ms text intent labels.
//
//  Pipeline (matches Peeky routelet):
//    text → MirageRedact.preprocess → HF tokenizer (WordPiece) →
//    input_ids, attention_mask, token_type_ids → BERT embedder (ONNX,
//    [1, 384] output) → linear head coef[K][384] · v + intercept[K] →
//    temperature-scaled softmax → argmax → intent label.
//
//  Bundle expects `AppResources/OpenClicky/mirage-routelet/{embedder.onnx,
//  head.json, tokenizer.json}`. The `mirage-routelet` directory name is
//  historical — we lifted the files verbatim from Peeky. Users of this
//  API do not need to know that.
//
//  Runtime: onnxruntime-swift-package-manager. Vocab is parsed from
//  tokenizer.json directly (WordPiece dict + added_tokens); we don't
//  reconstruct the full HF Tokenizer pipeline because our own greedy
//  WordPiece + [CLS]/[SEP] wrap is enough for the model's inputs.
//  ORT env + session are lazily built on first `embed()` call and kept
//  for the classifier's lifetime.

import Foundation

#if canImport(onnxruntime)
import onnxruntime
#endif

/// Labels the classifier can emit. Matches `head.json.labels` (agent
/// dropped at load — the intent is a voice-cue / Claude-fallback path,
/// not something routelet guesses).
enum OpenClickyIntent: String, CaseIterable {
    case chat
    case findAction = "find_action"
    case integration
    case memory
    case none  // reject class: out-of-distribution / unclear input
}

/// One classification result: predicted label + confidence in [0,1].
struct OpenClickyIntentPrediction {
    let intent: OpenClickyIntent
    let confidence: Float
}

/// Load-once, run-many. Actor-safe wrapper around the ONNX embedder +
/// linear head. `shared` is nil until `bootstrap()` succeeds, so callers
/// should treat the classifier as best-effort — the orchestrator falls
/// back to the Claude classifier when this returns nil.
actor OpenClickyIntentClassifier {
    static let shared = OpenClickyIntentClassifier()

    // MARK: - Loaded state

    private struct Head {
        let coef: [[Float]]
        let intercept: [Float]
        let labels: [String]
        let temperature: Float
    }

    private var head: Head?
    private var didAttemptLoad = false

    /// WordPiece vocabulary parsed from `tokenizer.json`. Nil until
    /// `bootstrap()` succeeds. Bundle-loaded once, reused for every
    /// classify call. ~30k entries, ~500KB in memory.
    private var vocab: [String: Int32]?
    private var clsID: Int32 = 101
    private var sepID: Int32 = 102
    private var unkID: Int32 = 100
    private var padID: Int32 = 0

    #if canImport(onnxruntime)
    /// ORT env + session are held for the lifetime of the classifier.
    /// Session load cost is a few hundred ms (127MB model); we pay it
    /// once at first classify call and cache the result.
    private var ortEnv: ORTEnv?
    private var ortSession: ORTSession?
    #endif

    // MARK: - Bootstrap

    /// Load head.json (weights, temperature, labels) and the WordPiece
    /// vocab from the app bundle. Idempotent. Returns true when both
    /// are ready, false on any load failure (missing bundle, malformed
    /// JSON, shape mismatch). The ORT session itself is lazily built on
    /// first embed() call so bootstrap stays cheap.
    @discardableResult
    func bootstrap() async -> Bool {
        if didAttemptLoad { return head != nil }
        didAttemptLoad = true

        guard let headURL = Bundle.main.url(forResource: "head",
                                            withExtension: "json",
                                            subdirectory: "mirage-routelet") else {
            NSLog("[OpenClickyIntentClassifier] head.json not in bundle")
            return false
        }
        guard let data = try? Data(contentsOf: headURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[OpenClickyIntentClassifier] head.json malformed")
            return false
        }

        guard let rawCoef = obj["coef"] as? [[Any]],
              let rawIntercept = obj["intercept"] as? [Any],
              let rawLabels = obj["labels"] as? [String] else {
            NSLog("[OpenClickyIntentClassifier] head.json missing required fields")
            return false
        }

        let coef: [[Float]] = rawCoef.map { row in
            row.compactMap { v -> Float? in
                if let d = v as? Double { return Float(d) }
                if let i = v as? Int { return Float(i) }
                return nil
            }
        }
        let intercept: [Float] = rawIntercept.compactMap { v in
            if let d = v as? Double { return Float(d) }
            if let i = v as? Int { return Float(i) }
            return nil
        }
        let temperature: Float = {
            if let d = obj["temperature"] as? Double { return Float(d) }
            if let i = obj["temperature"] as? Int { return Float(i) }
            return 1.0
        }()

        guard coef.count == rawLabels.count,
              intercept.count == rawLabels.count,
              coef.allSatisfy({ $0.count == 384 }) else {
            NSLog("[OpenClickyIntentClassifier] head.json shape mismatch")
            return false
        }

        // Peeky drops the `agent` class at load — routelet must not
        // emit Intent::Agent (agent is voice-cue routed instead). We
        // do the same so the softmax renormalises over the 4 real
        // classes + none.
        var labels = rawLabels
        var coefTrim = coef
        var interceptTrim = intercept
        if let agentIdx = labels.firstIndex(of: "agent") {
            labels.remove(at: agentIdx)
            coefTrim.remove(at: agentIdx)
            interceptTrim.remove(at: agentIdx)
        }

        self.head = Head(
            coef: coefTrim,
            intercept: interceptTrim,
            labels: labels,
            temperature: temperature
        )

        // Load the tokenizer vocab. `tokenizer.json` is HuggingFace's
        // fast-tokenizer format — we only need `.model.vocab` (the
        // WordPiece dict) plus a couple of special-token ids for
        // [CLS] / [SEP]. Everything else in the file (normalizer,
        // pre_tokenizer, post_processor) is applied by our own basic
        // tokenizer below; no need to reconstruct the full HF pipeline.
        if let tokURL = Bundle.main.url(forResource: "tokenizer",
                                        withExtension: "json",
                                        subdirectory: "mirage-routelet"),
           let tokData = try? Data(contentsOf: tokURL),
           let tokObj = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
           let model = tokObj["model"] as? [String: Any],
           let v = model["vocab"] as? [String: Int] {
            var vocab: [String: Int32] = [:]
            vocab.reserveCapacity(v.count)
            for (tok, id) in v { vocab[tok] = Int32(id) }
            // Merge added_tokens (special tokens sometimes only appear
            // there, not in `.model.vocab`).
            if let added = tokObj["added_tokens"] as? [[String: Any]] {
                for entry in added {
                    if let id = entry["id"] as? Int, let content = entry["content"] as? String {
                        vocab[content] = Int32(id)
                    }
                }
            }
            self.vocab = vocab
            self.clsID = vocab["[CLS]"] ?? 101
            self.sepID = vocab["[SEP]"] ?? 102
            self.unkID = vocab["[UNK]"] ?? 100
            self.padID = vocab["[PAD]"] ?? 0
        } else {
            NSLog("[OpenClickyIntentClassifier] tokenizer.json load failed")
            return false
        }

        return true
    }

    // MARK: - Classify

    /// Classify `text`. Returns nil when the head isn't loaded or the
    /// embedder pipeline fails. Callers (mirage orchestrator, SKI, …)
    /// should fall back to whatever their next-best path is on nil.
    ///
    /// Threshold guidance (matches Peeky tuning.rs
    /// `ROUTELET_CONFIDENCE_THRESHOLD`): accept `.chat / .findAction /
    /// .integration / .memory` results with confidence >= 0.85, treat
    /// everything below as `.none` and let a slower classifier decide.
    func classify(_ text: String) async -> OpenClickyIntentPrediction? {
        if head == nil {
            await bootstrap()
        }
        guard let head = head else { return nil }

        let normalized = MirageRedact.preprocess(text)
        guard let embedding = await embed(normalized), embedding.count == 384 else {
            return nil
        }
        return Self.headPredict(head: head, embedding: embedding)
    }

    // MARK: - Embed (ONNX via onnxruntime-swift-package-manager)

    /// Run the ONNX embedder on the preprocessed text. Returns a 384-d
    /// vector or nil when the ONNX runtime isn't linked / the model
    /// won't load / the tokenizer isn't ready. Callers fall back to
    /// the Claude classifier when this returns nil.
    private func embed(_ text: String) async -> [Float]? {
        #if canImport(onnxruntime)
        guard let vocab = vocab else { return nil }

        // Tokenize: WordPiece with [CLS]/[SEP], no truncation on our
        // short voice utterances (they never approach the 512 cap).
        var ids: [Int32] = [clsID]
        for word in Self.basicTokenize(text) {
            let pieces = wordpieceTokenize(word, vocab: vocab, unkID: unkID)
            ids.append(contentsOf: pieces)
        }
        ids.append(sepID)

        let seq = ids.count
        let mask = [Int32](repeating: 1, count: seq)
        let typeIDs = [Int32](repeating: 0, count: seq)

        do {
            // Lazily construct the ORT session on first embed call.
            if ortSession == nil {
                guard let modelURL = Bundle.main.url(forResource: "embedder",
                                                     withExtension: "onnx",
                                                     subdirectory: "mirage-routelet") else {
                    NSLog("[OpenClickyIntentClassifier] embedder.onnx not in bundle")
                    return nil
                }
                let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
                let opts = try ORTSessionOptions()
                let sess = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
                self.ortEnv = env
                self.ortSession = sess
            }
            guard let session = ortSession else { return nil }

            // BERT expects int64 tensors. Convert Int32 → Int64.
            let ids64 = ids.map { Int64($0) }
            let mask64 = mask.map { Int64($0) }
            let type64 = typeIDs.map { Int64($0) }

            let shape: [NSNumber] = [1, NSNumber(value: seq)]
            let idData = ids64.withUnsafeBufferPointer { Data(buffer: $0) }
            let maskData = mask64.withUnsafeBufferPointer { Data(buffer: $0) }
            let typeData = type64.withUnsafeBufferPointer { Data(buffer: $0) }

            let idsVal = try ORTValue(tensorData: NSMutableData(data: idData),
                                       elementType: ORTTensorElementDataType.int64,
                                       shape: shape)
            let maskVal = try ORTValue(tensorData: NSMutableData(data: maskData),
                                        elementType: ORTTensorElementDataType.int64,
                                        shape: shape)
            let typeVal = try ORTValue(tensorData: NSMutableData(data: typeData),
                                        elementType: ORTTensorElementDataType.int64,
                                        shape: shape)

            let inputs: [String: ORTValue] = [
                "input_ids": idsVal,
                "attention_mask": maskVal,
                "token_type_ids": typeVal
            ]

            // Discover output name — Peeky's export names it "embedding".
            let outputNames = try session.outputNames()
            let outputName = outputNames.first ?? "embedding"

            let outputs = try session.run(withInputs: inputs,
                                           outputNames: Set([outputName]),
                                           runOptions: nil)
            guard let outVal = outputs[outputName] else { return nil }
            let raw = try outVal.tensorData() as Data
            let count = raw.count / MemoryLayout<Float>.size
            guard count == 384 else {
                NSLog("[OpenClickyIntentClassifier] embedder output size \(count), expected 384")
                return nil
            }
            return raw.withUnsafeBytes { ptr -> [Float] in
                let buf = ptr.bindMemory(to: Float.self)
                return Array(buf)
            }
        } catch {
            NSLog("[OpenClickyIntentClassifier] embed failed: \(error)")
            return nil
        }
        #else
        _ = text
        return nil
        #endif
    }

    /// BERT `BasicTokenizer` word split, honouring the
    /// `handle_chinese_chars` flag that `tokenizer.json` declares for this
    /// checkpoint.
    ///
    /// HuggingFace's normalizer surrounds every CJK codepoint with spaces
    /// BEFORE whitespace splitting, so each Han character becomes its own
    /// word and matches the vocab's 488 single-character CJK entries. The
    /// original port split on spaces only, which handed an entire Chinese
    /// clause to WordPiece as one "word"; nothing in the vocab matches a
    /// multi-character Han string, so every Chinese utterance collapsed to
    /// a single `[UNK]` and the model returned `none` at ~0.99 regardless
    /// of content. English was unaffected (already space-delimited), which
    /// is why this survived unnoticed — and why mirage/SKI Chinese turns
    /// have all been falling through to the slow Claude classifier.
    ///
    /// Reference: `transformers.BasicTokenizer._tokenize_chinese_chars`.
    nonisolated static func basicTokenize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isCJKCodepoint(scalar) {
                // Flush any Latin run in progress, then emit the Han
                // character as a standalone word.
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(Character(scalar)))
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The exact ranges `transformers` classifies as "Chinese characters"
    /// for this normalizer. Deliberately EXCLUDES Hiragana/Katakana —
    /// upstream leaves those glued to their neighbours.
    nonisolated static func isCJKCodepoint(_ scalar: Unicode.Scalar) -> Bool {
        let cp = scalar.value
        return (cp >= 0x4E00 && cp <= 0x9FFF)      // CJK Unified Ideographs
            || (cp >= 0x3400 && cp <= 0x4DBF)      // Extension A
            || (cp >= 0x20000 && cp <= 0x2A6DF)    // Extension B
            || (cp >= 0x2A700 && cp <= 0x2B73F)    // Extension C
            || (cp >= 0x2B740 && cp <= 0x2B81F)    // Extension D
            || (cp >= 0x2B820 && cp <= 0x2CEAF)    // Extension E
            || (cp >= 0xF900 && cp <= 0xFAFF)      // Compatibility Ideographs
            || (cp >= 0x2F800 && cp <= 0x2FA1F)    // Compatibility Supplement
    }

    /// Very small greedy WordPiece tokenizer — the same algorithm HF's
    /// BertTokenizer uses. Lowercase input required (upstream
    /// MirageRedact.preprocess already lowercases). Unknown words map
    /// to `[UNK]` as a single token, matching the standard fallback.
    private func wordpieceTokenize(_ word: String, vocab: [String: Int32], unkID: Int32) -> [Int32] {
        // Peeky's tokenizer.json max input chars per word = 100.
        if word.count > 100 { return [unkID] }

        var tokens: [Int32] = []
        var start = word.startIndex
        while start < word.endIndex {
            var end = word.endIndex
            var found: Int32? = nil
            while end > start {
                var sub = String(word[start..<end])
                if start != word.startIndex { sub = "##" + sub }
                if let id = vocab[sub] {
                    found = id
                    break
                }
                end = word.index(before: end)
            }
            if let id = found {
                tokens.append(id)
                start = end
            } else {
                return [unkID]
            }
        }
        return tokens
    }

    // MARK: - Head math (pure Swift, matches Peeky head_predict_with_confidence)

    static func headPredict(head: [[Float]],
                            intercept: [Float],
                            temperature: Float,
                            labels: [String],
                            embedding: [Float]) -> OpenClickyIntentPrediction? {
        let n = labels.count
        guard n > 0, head.count == n, intercept.count == n else { return nil }

        // Logits: coef[c] · embedding + intercept[c]
        var logits = [Float](repeating: 0, count: n)
        for c in 0..<n {
            var sum: Float = 0
            let row = head[c]
            let d = row.count
            for i in 0..<d {
                sum += row[i] * embedding[i]
            }
            logits[c] = sum + intercept[c]
        }

        // Temperature scale.
        let temp = temperature > 0 ? temperature : 1.0
        for i in 0..<n { logits[i] /= temp }

        // Numerically stable softmax.
        let maxL = logits.max() ?? 0
        var exps = logits.map { Foundation.exp($0 - maxL) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else { return nil }
        for i in 0..<n { exps[i] /= sum }

        // Argmax.
        var bestIdx = 0
        var bestProb: Float = -.infinity
        for i in 0..<n where exps[i] > bestProb {
            bestProb = exps[i]
            bestIdx = i
        }
        guard let intent = OpenClickyIntent(rawValue: labels[bestIdx]) else {
            return nil
        }
        return OpenClickyIntentPrediction(intent: intent, confidence: bestProb)
    }

    private static func headPredict(head: Head, embedding: [Float]) -> OpenClickyIntentPrediction? {
        headPredict(
            head: head.coef,
            intercept: head.intercept,
            temperature: head.temperature,
            labels: head.labels,
            embedding: embedding
        )
    }
}
