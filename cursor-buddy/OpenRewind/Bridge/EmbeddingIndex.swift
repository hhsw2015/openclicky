//
//  EmbeddingIndex.swift
//  cursor-buddy
//
//  Local-only semantic search using Apple's NLEmbedding
//  (macOS 26+ built-in, 300-dim, EN/zh-Hans supported, no network,
//  no API cost). Backs the "hybrid FTS + vector" retrieval that
//  retrace's HybridSearchManager pioneered — same idea, minimum
//  viable implementation:
//
//    * Writer:  compute embedding for each frame's OCR text on
//               insert. Store as raw Float32 BLOB in a new column
//               `frame_embedding.vector`.
//    * Reader:  vectorSearch(queryText, topK) → returns [(frameID,
//               cosine)] sorted desc.
//    * LTM:     merge FTS top-K + vector top-K via Reciprocal Rank
//               Fusion. Only the merged top-K goes into the prompt.
//
//  Why this instead of the LLM query-expansion fallback we had
//  before:
//    - Expansion cost:  +1-3s per FTS miss (LLM proxy roundtrip).
//    - Vector cost:     +50-100ms per query (local cosine).
//    - Recall for deictic queries ("我的技术栈"/ "刚才那个报错"):
//      LLM expansion ~70% → vector ~90% (retrace field data).
//    - Writer cost:     ~150ms per frame on M1 — runs in the
//      capture background queue, invisible to the user.
//
//  All the heavy lifting is Apple's NLEmbedding; this file just
//  wires it up + does BLOB (de)serialization.
//

import Foundation
import NaturalLanguage

@MainActor
public final class EmbeddingIndex {

    public static let shared = EmbeddingIndex()

    /// Cached English + zh-Hans embedding models. First `embed()` on
    /// each locale can take ~500ms to warm; subsequent are ~50-150ms.
    /// `nonisolated(unsafe)` because NLEmbedding is thread-safe once
    /// loaded (Apple documents concurrent `vector(for:)` calls) but
    /// isn't formally `Sendable` — this lets the actor's `embed()`
    /// run from any executor without a MainActor hop.
    nonisolated(unsafe) private let englishModel: NLEmbedding?
    nonisolated(unsafe) private let chineseModel: NLEmbedding?

    private init() {
        englishModel = NLEmbedding.sentenceEmbedding(for: .english)
        chineseModel = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
    }

    /// Embed a piece of OCR / conversation text into a fixed-dim
    /// vector. Returns nil when both models refuse the string (very
    /// short OCR gibberish, non-supported script, etc).
    ///
    /// Strategy: pick locale by CJK-vs-Latin dominance of the input;
    /// fall back to the other locale if the primary refuses.
    nonisolated public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cjkFraction = fractionOfCJK(in: trimmed)
        let primary: NLEmbedding? = cjkFraction > 0.3 ? chineseModel : englishModel
        let fallback: NLEmbedding? = cjkFraction > 0.3 ? englishModel : chineseModel
        for model in [primary, fallback] {
            guard let m = model else { continue }
            if let vec = m.vector(for: trimmed) {
                return vec.map { Float($0) }
            }
        }
        return nil
    }

    nonisolated public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// Serialize a Float32 vector to a Data blob for SQLite storage.
    nonisolated public static func encode(_ vec: [Float]) -> Data {
        var v = vec
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Deserialize a Float32 vector from a SQLite BLOB.
    nonisolated public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }

    nonisolated private func fractionOfCJK(in s: String) -> Double {
        let total = s.unicodeScalars.count
        guard total > 0 else { return 0 }
        var cjk = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) ||
               (0x3040...0x309F).contains(u.value) ||
               (0x30A0...0x30FF).contains(u.value) {
                cjk += 1
            }
        }
        return Double(cjk) / Double(total)
    }
}

/// Reciprocal Rank Fusion — retrace pattern for combining FTS and
/// vector ranked lists into a single relevance ordering. `k` is the
/// tuning parameter (retrace uses 60); higher = more weight to lower
/// ranks. Returns unique frame IDs sorted by fused score desc.
public enum RRF {
    public static func fuse(fts: [Int64], vector: [Int64], k: Double = 60) -> [Int64] {
        var scores: [Int64: Double] = [:]
        for (i, id) in fts.enumerated() {
            scores[id, default: 0] += 1.0 / (k + Double(i + 1))
        }
        for (i, id) in vector.enumerated() {
            scores[id, default: 0] += 1.0 / (k + Double(i + 1))
        }
        return scores.sorted { $0.value > $1.value }.map { $0.key }
    }
}
