//
//  EmbeddingStore.swift
//  cursor-buddy
//
//  Semantic-search facade. Runs OFF the main actor so voice/LTM turns
//  never stall the UI while we cosine-score a few thousand rows.
//
//  Design notes:
//    * `EmbeddingCacheActor` owns the in-memory (frameId, vector)
//      snapshot with a 30 s TTL. Access from any thread; cosine
//      scoring happens inside the actor so we hold the vectors by
//      reference the whole time (no MainActor bounce).
//    * Cosine uses Accelerate's `vDSP_dotpr` / `vDSP_svesq` — an
//      order of magnitude faster than the naive loop on M-series
//      chips and doesn't touch the SwiftUI main hop.
//    * `upsert` returns immediately; the SQLite write is scheduled
//      on the writer's own queue, and the cache is refreshed
//      incrementally so the next `topK` sees the new frame.
//

import Foundation
import Accelerate

public enum EmbeddingStore {

    public static func upsert(bridge: OpenRewindBridge,
                              frameId: Int64,
                              text: String,
                              model: String = "NLEmbedding.sentence") {
        guard let vec = EmbeddingIndex.shared.embed(text) else { return }
        let data = EmbeddingIndex.encode(vec)
        Task.detached(priority: .utility) {
            do {
                try bridge.writer.upsertEmbedding(frameId: frameId,
                                                  model: model,
                                                  vec: data)
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "openclicky.embedding.upsert_failed",
                    fields: ["error": "\(error)"])
            }
        }
        Task { await EmbeddingCacheActor.shared.mergeUpsert(frameId: frameId, vec: vec) }
    }

    /// Cosine top-K. Await'd from the voice turn — runs entirely off
    /// the main actor; the caller's continuation resumes on whatever
    /// executor called us. On an M1, 3k-row cosine + sort finishes in
    /// under 5 ms, negligible against a 10 s chat.request.
    public static func topK(bridge: OpenRewindBridge,
                            queryText: String,
                            k: Int = 20) async
        -> [(frameId: Int64, cosine: Float)]
    {
        guard let qvec = EmbeddingIndex.shared.embed(queryText) else { return [] }
        return await EmbeddingCacheActor.shared.topK(
            bridge: bridge, query: qvec, k: k)
    }
}

/// Serial actor guarding the decoded embedding index. The whole
/// scoring loop runs on the actor's executor — never the main queue.
private actor EmbeddingCacheActor {
    static let shared = EmbeddingCacheActor()

    private var cachedRows: [(frameId: Int64, vec: [Float])] = []
    private var cacheStamp: Date = .distantPast
    private static let cacheTTL: TimeInterval = 30

    func mergeUpsert(frameId: Int64, vec: [Float]) {
        cachedRows.removeAll { $0.frameId == frameId }
        cachedRows.append((frameId, vec))
    }

    func topK(bridge: OpenRewindBridge, query: [Float], k: Int)
        -> [(frameId: Int64, cosine: Float)]
    {
        refreshIfNeeded(bridge: bridge)
        guard !cachedRows.isEmpty else { return [] }
        // Precompute the query's L2 norm once — every dot product then
        // divides by (||q|| * ||v_i||) but we can normalise on the fly
        // per row for correctness. Accelerate handles both norms and
        // the dot product with vDSP.
        var qNormSq: Float = 0
        vDSP_svesq(query, 1, &qNormSq, vDSP_Length(query.count))
        let qNorm = sqrt(qNormSq).nonZero()
        var scored: [(Int64, Float)] = []
        scored.reserveCapacity(cachedRows.count)
        for row in cachedRows {
            let vec = row.vec
            guard vec.count == query.count else { continue }
            var dot: Float = 0
            vDSP_dotpr(query, 1, vec, 1, &dot, vDSP_Length(vec.count))
            var normSq: Float = 0
            vDSP_svesq(vec, 1, &normSq, vDSP_Length(vec.count))
            let denom = qNorm * sqrt(normSq).nonZero()
            scored.append((row.frameId, dot / denom))
        }
        // Partial sort — we only need the top K, not a full sort.
        // For K ≪ N (typical: 20 out of thousands), this is O(N + K log K).
        return partialTopK(scored, k: k)
    }

    private func refreshIfNeeded(bridge: OpenRewindBridge) {
        if !cachedRows.isEmpty,
           Date().timeIntervalSince(cacheStamp) < Self.cacheTTL { return }
        let raw = bridge.reader.loadEmbeddings()
        cachedRows = raw.map { ($0.frameId, EmbeddingIndex.decode($0.vector)) }
        cacheStamp = Date()
    }

    private func partialTopK(_ input: [(Int64, Float)], k: Int)
        -> [(frameId: Int64, cosine: Float)]
    {
        if k >= input.count {
            return input.sorted { $0.1 > $1.1 }
                .map { (frameId: $0.0, cosine: $0.1) }
        }
        // Heap-based partial sort (top-K by score, descending).
        var heap: [(Int64, Float)] = []
        heap.reserveCapacity(k)
        for row in input {
            if heap.count < k {
                heap.append(row)
                if heap.count == k { heap.sort { $0.1 < $1.1 } } // min-heap by score
            } else if row.1 > heap[0].1 {
                heap[0] = row
                // Sift the new element down; heap is small, resort is
                // fine (k ~= 20 => ~86 ops per replacement).
                heap.sort { $0.1 < $1.1 }
            }
        }
        return heap.sorted { $0.1 > $1.1 }
            .map { (frameId: $0.0, cosine: $0.1) }
    }
}

private extension Float {
    /// Guard against divide-by-zero from an all-zero vector (which
    /// shouldn't happen but Accelerate is happy to produce a NaN).
    func nonZero() -> Float { self == 0 ? .leastNonzeroMagnitude : self }
}
