//
//  LongTermMemoryContext.swift
//  cursor-buddy
//
//  Shared long-term-memory context builder for BOTH the realtime
//  voice model (via session.update instructions) AND the main dialog
//  model (via system prompt). Ensures both consumers see the SAME
//  "who is the user, what did they see, what did we say" snapshot.
//
//  Design:
//    - Cheap enough to call on every user turn (few hundred ms
//      worst-case), so callers don't need their own caching layer.
//    - Returns plain text ready to embed inside a system prompt.
//    - Skips gracefully when Screen History is off — returns empty
//      string, caller's baseline prompt unaffected.
//
//  Blocks in the output:
//    1. Vault coverage — how much history is available
//    2. Today's recap — apps used + top keywords + meetings
//    3. Recent activity — last 30 min app-switch stream
//    4. Recent voice exchanges — last few user↔assistant turns
//      (from transcript_word rows written by ConversationLogger)
//
//  Time bounded per block so a huge vault won't OOM the prompt.
//

import Foundation

public enum LongTermMemoryContext {

    // MARK: - Cache
    //
    // Recap changes at daily granularity, recent activity at ~5-min
    // granularity, conversation only when a new turn lands. Rebuilding
    // per user utterance wastes 200-300 tokens of prompt AND a few
    // hundred ms of DB work. Cache the assembled string for 5 min and
    // return the same one to any caller that asks in that window.
    private actor Cache {
        static let shared = Cache()
        private struct Entry {
            let value: String
            let stamp: Date
        }
        private var entries: [String: Entry] = [:]
        private static let ttl: TimeInterval = 300  // 5 min

        // FIX(ltm-cache-key-2026-07-30): was a single un-keyed entry
        // — realtime turn built with query="咖啡" would cache under
        // the same slot as chat turn with query="航班", so the second
        // caller got the first caller's result. Key by normalized
        // query so the two independent LLM pipelines (realtime + chat)
        // share only when they genuinely ask the same question.
        private func key(_ query: String?) -> String {
            (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func get(query: String? = nil) -> String? {
            let k = key(query)
            guard let e = entries[k],
                  Date().timeIntervalSince(e.stamp) < Self.ttl
            else { return nil }
            return e.value.isEmpty ? nil : e.value
        }

        func set(_ v: String, query: String? = nil) {
            entries[key(query)] = Entry(value: v, stamp: Date())
            // Bound memory: cap at 32 recent (query, block) pairs.
            if entries.count > 32 {
                let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })
                if let k = oldest?.key { entries.removeValue(forKey: k) }
            }
        }

        /// Called when a new voice turn lands so the "recent
        /// conversation" block gets a fresh reading on next build.
        func invalidate() {
            entries.removeAll()
        }
    }

    /// Invalidate the cache — call after ConversationLogger writes a
    /// new turn so the NEXT LTM build sees it.
    public static func invalidateCache() async {
        await Cache.shared.invalidate()
    }

    /// Build the shared context block. Returns empty string when the
    /// bridge is not available (Screen History off, permissions
    /// missing, etc.).
    ///
    /// - Parameters:
    ///   - now: current wallclock time (injected for testing).
    ///   - recentMinutes: activity stream window (default 30).
    ///   - conversationTurnLimit: max user↔assistant pairs to include (default 6).
    public static func build(now: Date = Date(),
                             recentMinutes: Int = 30,
                             conversationTurnLimit: Int = 6,
                             query: String? = nil,
                             intent: String? = nil) async -> String {
        let startedAt = now
        let qPreview = (query ?? "").prefix(60)
        let cached = await Cache.shared.get(query: query)

        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared })
        else {
            await MainActor.run {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "ltm.build.skipped",
                    fields: ["reason": "bridge_nil",
                             "hasQuery": query != nil,
                             "queryPreview": String(qPreview)])
            }
            return cached ?? ""
        }
        // Perf: was `await MainActor.run { try? bridge.reopenReader() }`
        // which blocked the UI runloop for ~20-80ms during voice turns.
        // Detached async variant runs the SQLite copy off-main so the
        // cursor stays fluid while the LTM pipeline warms up.
        try? await bridge.reopenReaderAsync()

        if let cached = cached {
            var hitsBlockValue: String? = nil
            if let q = query {
                hitsBlockValue = await queryHitsBlock(reader: bridge.reader,
                                                      bridge: bridge,
                                                      query: q, now: now)
            }
            await MainActor.run {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "ltm.build.cached_hit",
                    fields: ["cachedLen": cached.count,
                             "hitsLen": hitsBlockValue?.count ?? 0,
                             "queryPreview": String(qPreview),
                             "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
            }
            if let h = hitsBlockValue { return cached + "\n\n" + h }
            return cached
        }

        // FIX(ltm-priority-tiers-2026-07-30): tag each block with a
        // priority tier so the truncator knows what to drop first.
        // T0 = must-keep, T1 = high signal, T2 = ambient droppable.
        //
        // FIX(intent-gated-2026-07-30): when the realtime model
        // classifies the user's utterance, some layers are pure
        // noise for that intent:
        // - world_knowledge (e.g. "珠峰高度") → skip screen history
        //   (coverage / recap / recent activity). Keep recent_conv +
        //   live focus so the AI still knows who's asking.
        // - live_context ("现在屏幕上说啥了") → skip past ambient
        //   (coverage / recap / recent activity), keep live + conv.
        // - past_memory / recent_conv / other / nil → keep everything
        //   (backward compat).
        // FIX(intent-override-2026-07-30): the model's classifier
        // is fallible — user asks "喜马拉雅多高" (looks like
        // world_knowledge) but their DB has past discussions about
        // hiking Everest. Run the query hits pass FIRST; if we get
        // matches, the DB has said something relevant and we must
        // treat this as past_memory regardless of what the model
        // guessed. DB truth > LLM guess.
        var earlyHits: String? = nil
        if let q = query {
            earlyHits = await queryHitsBlock(reader: bridge.reader,
                                             bridge: bridge,
                                             query: q, now: now)
        }
        let hasDBHits = !(earlyHits?.isEmpty ?? true)
        var effectiveIntent = (intent ?? "").lowercased()
        if hasDBHits &&
           (effectiveIntent == "world_knowledge" ||
            effectiveIntent == "live_context") {
            effectiveIntent = "past_memory"
        }
        let dropAmbient = (effectiveIntent == "world_knowledge" ||
                           effectiveIntent == "live_context")
        var tagged: [(tier: Int, text: String)] = []
        if !dropAmbient,
           let cov = coverageBlock(reader: bridge.reader) {
            tagged.append((2, cov))
        }
        if !dropAmbient,
           let recap = recapBlock(reader: bridge.reader, now: now) {
            tagged.append((2, recap))
        }
        if let live = await liveFocusedContextBlock() {
            tagged.append((1, live))
        }
        if !dropAmbient,
           let recent = recentActivityBlock(reader: bridge.reader,
                                            now: now,
                                            minutes: recentMinutes) {
            tagged.append((2, recent))
        }
        if let conv = recentConversationBlock(reader: bridge.reader,
                                              limit: conversationTurnLimit) {
            tagged.append((1, conv))
        }
        let blocks = tagged.map { $0.text }

        guard !blocks.isEmpty else { return "" }
        // Terse header + explicit protocol between Memory and live tools.
        // Without this rule the model either 100% trusts Memory (misses
        // fresh events) or 100% ignores it (repeats questions the user
        // already asked). Both fail modes observed in testing.
        let header = """
        ## Memory (from Screen History)
        - Ambient blocks below = what the user has seen + past voice turns (may be stale hours).
        - If a "Relevant history for this question" section follows, those are pre-fetched FTS hits keyed to the CURRENT user question — read them first, they're the fastest path to a grounded answer.
        - Empty history but you need detail? Call rewind_frame / openrewind.ask / rewind_search to drill in. Don't say "I don't remember" without trying.
        - For fresh facts / news / prices / releases → advisor_web_search. Memory is stale by design.
        - Best answers COMBINE both: Memory tells you what the user cares about; web fills in fresh specifics. Cite frames as [F#N] and web sources inline.
        """
        // FIX(ltm-token-budget-2026-07-30): cap assembled block size
        // to avoid diluting the LLM's attention. Tier 2 (ambient
        // background: coverage/recap/recent activity) drops first
        // when we're over budget; Tier 1 (live focus + recent conv)
        // stays. Header always stays. Budget in CHARS (≈ 4 chars/tok
        // → 6000 chars ≈ 1500 tokens). Set 0 in UserDefaults to
        // disable capping.
        let budgetChars = UserDefaults.standard.object(
            forKey: "openclicky.ltm.budget_chars") as? Int ?? 6000
        let kept = Self.applyBudget(tagged: tagged,
                                    header: header,
                                    budgetChars: budgetChars)
        let assembled = header + "\n\n" + kept.joined(separator: "\n\n")
        await Cache.shared.set(assembled, query: query)
        // Reuse the earlyHits computed above (used for intent
        // override) so we don't re-run FTS + vector.
        let hitsBlockValue: String? = earlyHits
        await MainActor.run {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "ltm.build.assembled",
                fields: ["blockCount": blocks.count,
                         "assembledLen": assembled.count,
                         "hitsLen": hitsBlockValue?.count ?? 0,
                         "queryPreview": String(qPreview),
                         "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
        }
        if let h = hitsBlockValue { return assembled + "\n\n" + h }
        return assembled
    }

    /// Run the same 3-stage AskRewind retrieval the tool uses, but
    /// return the RAW hit snippets (not a synthesised answer). Cheap
    /// — a single FTS + rank pass, no LLM. Injected inline so the
    /// dialog model reasons over screen + conversation history in one
    /// shot instead of tool-calling.
    private static func queryHitsBlock(reader: OpenRewindReader,
                                       bridge: OpenRewindBridge,
                                       query: String,
                                       now: Date) async -> String? {
        let startedAt = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            await MainActor.run {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "ltm.query_hits.skipped",
                    fields: ["reason": "too_short", "len": trimmed.count])
            }
            return nil
        }
        // Parse structured hints (site:/app:/after:/quoted phrases) so
        // "app:cmux kafka" narrows correctly. But the parser doesn't
        // tokenize CJK — for Chinese natural-language queries it leaves
        // the whole sentence as a single term, which then fails FTS
        // (implicit AND across CJK chars). Run our bigram splitter on
        // top of whatever the parser returned so both English and CJK
        // queries land as usable FTS tokens.
        // Skip LTM search entirely for pure-world-knowledge questions
        // (physics/geography/history/etc). ampersand of noise (LTM
        // block + FTS overhead) with zero payoff. Heuristic: if the
        // query contains no user-anchored pronouns ("我/my/刚才/上次"),
        // it's probably world-knowledge — bail.
        // FIX(memory-priority-2026-07-31): removed the anchor-gate
        // entirely. User feedback: "记忆里命中的更优先，为什么你要跳过？"
        // Reality: if the vault has hits on the user's query, that
        // ALWAYS beats "world-knowledge" LLM guessing. The previous
        // gate skipped past-memory retrieval whenever the query
        // lacked personal pronouns (我 / my / 刚才) — which meant a
        // question like "如何看待王虹获得菲尔兹奖" got 0 retrieval
        // even though the vault had 6 FTS hits on 王虹. Now: always
        // proceed to the multi-strategy retrieval; downstream RRF +
        // recency ranking naturally down-weights irrelevant hits,
        // and the world-knowledge case pays a cheap FTS-miss cost
        // instead of skipping altogether.

        let parsed = RewindQueryParser.parse(trimmed, now: now)
        // ALWAYS augment with bigram splitter — the parser under-tokenizes
        // CJK. Merging keeps Latin exact tokens and adds CJK bigrams so
        // "编辑器/记忆/技术栈" and their CJK bigrams all get a shot at FTS.
        let parserTerms = parsed.searchTerms + parsed.phrases
        let bigramTerms = AskRewind.extractQueryKeywords(from: trimmed)
        var termSet = Set<String>()
        var terms: [String] = []
        for t in (parserTerms + bigramTerms) {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                         .trimmingCharacters(in: .punctuationCharacters)
            if clean.count >= 2, !termSet.contains(clean.lowercased()) {
                termSet.insert(clean.lowercased())
                terms.append(clean)
            }
        }
        // Cap to keep FTS query manageable.
        if terms.count > 10 { terms = Array(terms.prefix(10)) }
        let strictQ = terms.joined(separator: " ")
        let broadQ = terms.joined(separator: " OR ")
        // Hybrid retrieval: FTS (bm25 keyword) + vector (semantic
        // similarity), fused via RRF. This is retrace's core insight —
        // FTS finds exact matches, vector finds paraphrases and
        // synonyms without any hardcoded expansion. Cost: ~50-100ms
        // for vector on a few thousand frames (in-memory cosine), and
        // the FTS shots stay as-is.
        var hits: [OpenRewindSearchHit] = []
        if !strictQ.isEmpty {
            // FIX(parallel-ltm-2026-07-30): fire FTS strict and vector
            // top-K concurrently — they don't depend on each other.
            // Broad FTS is conditional (only when strict is thin) so
            // it stays post-strict. Cuts ~50-100ms off the LTM path.
            async let ftsStrictAsync: [OpenRewindSearchHit] =
                Task.detached(priority: .userInitiated) {
                    (try? reader.search(strictQ, limit: 30)) ?? []
                }.value
            async let vecHitsAsync: [(frameId: Int64, cosine: Float)] =
                EmbeddingStore.topK(bridge: bridge, queryText: trimmed, k: 30)
            let ftsStrict = await ftsStrictAsync
            let vecHits = await vecHitsAsync
            let ftsBroad: [OpenRewindSearchHit] = ftsStrict.count >= 5
                ? []
                : (broadQ.isEmpty ? [] : (try? reader.search(broadQ, limit: 30)) ?? [])
            let ftsMerged = mergePreservingOrder(ftsStrict, ftsBroad)
            // RRF fusion: take top ids from both lists, fuse by rank,
            // then reload the merged top-K as SearchHits (FTS ones
            // carry their bm25 snippet; vector-only ones we
            // hydrate from raw OCR).
            let ftsIds = ftsMerged.map { $0.entry.id }
            let vecIds = vecHits.map { $0.frameId }
            let fusedIds = RRF.fuse(fts: ftsIds, vector: vecIds).prefix(20)
            hits = hydrateHits(ftsMerged: ftsMerged,
                                fusedOrder: Array(fusedIds),
                                reader: reader)
            await MainActor.run {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "ltm.query_hits.hybrid",
                    fields: ["fts_strict": ftsStrict.count,
                             "fts_broad": ftsBroad.count,
                             "vec_hits": vecHits.count,
                             "fused_hits": hits.count,
                             "queryPreview": String(trimmed.prefix(60))])
            }
        }
        guard !hits.isEmpty else {
            await MainActor.run {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "ltm.query_hits.empty",
                    fields: ["strictQ": strictQ, "broadQ": broadQ,
                             "queryPreview": String(trimmed.prefix(60)),
                             "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
            }
            return nil
        }
        // Rank by recency + metadata (retrace pattern), keep top 4 to
        // cap tokens. 4 * ~120 chars ≈ 480 chars added per turn.
        let queryTerms = Set(trimmed.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty })
        let ranked = RewindResultRanker.rank(hits,
                                             queryTerms: queryTerms,
                                             now: now)
        let df = DateFormatter(); df.dateFormat = "MMM d HH:mm"
        var lines: [String] = []
        for hit in ranked.prefix(4) {
            let e = hit.entry
            let win = (e.windowName ?? "?").prefix(30)
            let app = shortBundle(e.bundleID ?? "?")
            let date = df.string(from: e.createdAt)
            var snip = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            snip = snip.replacingOccurrences(of: "\n", with: " ")
            if snip.count > 160 { snip = String(snip.prefix(160)) + "…" }
            lines.append("[F#\(e.id) \(date) \(app):\(win)] \(snip)")
        }
        let out = "Relevant history for this question:\n" + lines.joined(separator: "\n")
        await MainActor.run {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "ltm.query_hits.built",
                fields: ["hitCount": lines.count,
                         "outLen": out.count,
                         "strictQ": strictQ,
                         "topFrame": ranked.first?.entry.id ?? 0,
                         "queryPreview": String(trimmed.prefix(60)),
                         "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)])
        }
        return out
    }

    // MARK: - Block builders

    private static func coverageBlock(reader: OpenRewindReader) -> String? {
        guard let (earliest, latest, days) = try? reader.coverage(),
              let ea = earliest, let la = latest else { return nil }
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return "History: \(days)d (\(df.string(from: ea))–\(df.string(from: la)))"
    }

    private static func recapBlock(reader: OpenRewindReader, now: Date) -> String? {
        guard let recap = try? reader.dailyRecap(for: now) else { return nil }
        var parts: [String] = []
        // "Today: 234min in X (52m), Y (30m), Z (12m)"
        if !recap.topApps.isEmpty {
            let apps = recap.topApps.prefix(4).map { a in
                "\(shortBundle(a.bundleID))(\(Int(a.totalSeconds/60))m)"
            }.joined(separator: ", ")
            parts.append("Today \(Int(recap.activeSeconds/60))m: \(apps)")
        }
        // Keywords one-liner. Drop OCR tile fragments — accepts ONLY
        // words of length >= 5 that are entirely a-z0-9 (Latin real
        // word), or >= 2 CJK ideographs. This kills "inpu / opusz /
        // rewin / ount / ridge" tile-edge noise while preserving
        // meaningful terms like "openclicky", "kafka", "screenshot".
        if !recap.ocrKeywords.isEmpty {
            let kws = recap.ocrKeywords
                .sorted { $0.value > $1.value }
                .map { $0.key }
                .filter { isMeaningfulKeyword($0) }
                .prefix(10)
            if !kws.isEmpty {
                parts.append("Seen: \(kws.joined(separator: ", "))")
            }
        }
        // Meetings one-liner
        if !recap.meetings.isEmpty {
            let ms = recap.meetings.prefix(3).map { $0.title ?? "-" }
                .joined(separator: "; ")
            parts.append("Meetings: \(ms)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func recentActivityBlock(reader: OpenRewindReader,
                                            now: Date,
                                            minutes: Int) -> String? {
        let from = now.addingTimeInterval(-Double(minutes) * 60)
        guard let entries = try? reader.entries(from: from, to: now, limit: 2000),
              !entries.isEmpty else { return nil }
        let ordered = entries.sorted { $0.createdAt < $1.createdAt }
        struct Seg { let app: String; let start: Date; var end: Date }
        var segs: [Seg] = []
        for e in ordered {
            let app = e.bundleID ?? "?"
            if var last = segs.last, last.app == app {
                last.end = e.createdAt
                segs[segs.count - 1] = last
            } else {
                segs.append(Seg(app: app, start: e.createdAt, end: e.createdAt))
            }
        }
        guard !segs.isEmpty else { return nil }
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        // Compact: single line "Recent (30m): HH:MM app(dur), ..."
        let items = segs.suffix(5).map { s in
            "\(df.string(from: s.start)) \(shortBundle(s.app))(\(Int(s.end.timeIntervalSince(s.start)))s)"
        }.joined(separator: " → ")
        return "Recent \(minutes)m: \(items)"
    }

    /// Tiered memory: only auto-inject conversations from the last
    /// ~10 minutes. Older exchanges go through the retrieval layer
    /// (queryHitsBlock) — forcing FTS/LLM-expansion to actually work.
    /// Without this everything piles into a "Recent exchanges" profile
    /// block, model gets flooded with unrelated seeds, and retrieval
    /// quality never has to improve.
    private static let liveMemoryWindowSeconds: TimeInterval = 10 * 60

    private static func recentConversationBlock(reader: OpenRewindReader,
                                                limit: Int) -> String? {
        // FIX(speaker-column-2026-07-30): prefer new speakerId column
        // (0=user, 1=assistant). Fall back to legacy `[user]`/`[assistant]`
        // prefix for pre-migration rows. Bridge selects both: if
        // speakerId is present use it, else parse the prefix.
        let sql = """
            SELECT word, startTime,
                   CASE WHEN EXISTS (SELECT 1 FROM pragma_table_info('transcript_word') WHERE name='speakerId')
                        THEN (SELECT speakerId FROM transcript_word tw2 WHERE tw2.id = transcript_word.id)
                        ELSE NULL
                   END as spk
            FROM transcript_word
            WHERE (word LIKE '[user]%' OR word LIKE '[assistant]%'
                   OR speakerId IS NOT NULL)
            ORDER BY id DESC LIMIT ?;
            """
        guard let (_, rows) = try? reader.rawQuery(sql, [String(limit * 2)]),
              !rows.isEmpty else { return nil }
        let now = Date()
        var lines: [String] = []
        var considered = 0
        for r in rows.reversed() {
            let raw = r[0] ?? ""
            guard !raw.isEmpty else { continue }
            let speakerIDStr: String? = r.count > 2 ? (r[2] ?? nil) : nil
            let speakerID: Int? = speakerIDStr.flatMap { Int($0) }
            let (role, body): (String, String) = {
                if let s = speakerID {
                    let r: String = s == 0 ? "U" : (s == 1 ? "A" : "?")
                    return (r, raw)
                }
                if raw.hasPrefix("[user] ") { return ("U", String(raw.dropFirst(7))) }
                if raw.hasPrefix("[assistant] ") { return ("A", String(raw.dropFirst(12))) }
                return ("?", raw)
            }()
            considered += 1
            var age: TimeInterval = .infinity
            if let tsStr = r.count > 1 ? r[1] : nil,
               let secs = Double(tsStr ?? "") {
                age = now.timeIntervalSince1970 - secs
            }
            // Hard tier cut: skip anything older than the live memory
            // window. Older material must be retrieved by queryHitsBlock.
            if age > liveMemoryWindowSeconds { continue }
            let ageStr: String
            if age < 30 { ageStr = "just now" }
            else if age < 120 { ageStr = "\(Int(age))s ago" }
            else { ageStr = "\(Int(age/60))min ago" }
            lines.append("[\(ageStr)] \(role): \(body.prefix(140))")
            if lines.count >= limit * 2 { break }
        }
        guard !lines.isEmpty else { return nil }
        return "Recent exchanges (last 10 min only — older context comes via retrieval):\n"
             + lines.joined(separator: "\n")
    }

    /// Live focused-context block: current app, window title, browser URL
    /// if in a browser. retrace weights URL 0.5 (strongest metadata
    /// signal) — putting it in the memory block lets the model reason
    /// about "right now" alongside "in the past".
    @MainActor
    private static func liveFocusedContextBlock() async -> String? {
        guard let snap = AssistAgentActiveWindow.capture() else { return nil }
        var parts: [String] = []
        if !snap.appName.isEmpty { parts.append("app=\(snap.appName)") }
        if let title = snap.windowTitle, !title.isEmpty {
            parts.append("window=\"\(title.prefix(80))\"")
        }
        if let url = snap.browserURL, !url.isEmpty {
            parts.append("url=\(url.prefix(120))")
        }
        guard !parts.isEmpty else { return nil }
        return "Now: " + parts.joined(separator: " | ")
    }

    /// Merge two SearchHit lists preserving the first's order, then
    /// appending any not already seen from the second.
    private static func mergePreservingOrder(_ a: [OpenRewindSearchHit],
                                             _ b: [OpenRewindSearchHit])
        -> [OpenRewindSearchHit]
    {
        var seen = Set<Int64>()
        var out: [OpenRewindSearchHit] = []
        for h in a where !seen.contains(h.entry.id) {
            seen.insert(h.entry.id); out.append(h)
        }
        for h in b where !seen.contains(h.entry.id) {
            seen.insert(h.entry.id); out.append(h)
        }
        return out
    }

    /// Rebuild SearchHit ordering from RRF's fused-id list. For each
    /// fused id, prefer the FTS hit (has bm25 snippet); if it's
    /// vector-only, hydrate from the entry table so downstream
    /// snippet rendering still works.
    private static func hydrateHits(ftsMerged: [OpenRewindSearchHit],
                                     fusedOrder: [Int64],
                                     reader: OpenRewindReader)
        -> [OpenRewindSearchHit]
    {
        let ftsByID = Dictionary(uniqueKeysWithValues:
            ftsMerged.map { ($0.entry.id, $0) })
        var out: [OpenRewindSearchHit] = []
        for id in fusedOrder {
            if let h = ftsByID[id] { out.append(h); continue }
            // Vector-only hit — fetch the entry to attach.
            if let entry = try? reader.entryByID(id) {
                out.append(OpenRewindSearchHit(id: id, snippet: "", entry: entry))
            }
        }
        return out
    }

    /// LLM-driven query expansion — cheap fallback when the two
    /// bigram-based FTS attempts both come up empty. Sends the
    /// original question to the same free proxy the rest of the
    /// pipeline uses (`ScreenHistoryAIProvider`) with a compact
    /// prompt: "list 3-5 likely keywords the answer to this question
    /// would have been indexed under". Model returns space-separated
    /// tokens; we OR them into FTS.
    ///
    /// No hardcoded synonym table — the model picks based on what
    /// concepts the question actually implies. Falls back to [] on
    /// any error so the caller degrades gracefully.
    private static func llmExpandQuery(question: String) async -> [String] {
        let prompt = """
        用户问的问题:
        \(question)

        用户的屏幕历史 + 对话记录里可能存了跟这问题相关的信息.
        请列出 3 到 5 个**具体检索词**, 用空格分隔, 只输出这一行. 例如:
          问 "我的技术栈是什么" → Rust tokio sqlx PostgreSQL framework 语言
          问 "刚才那个报错" → error exception 报错 traceback
          问 "我用的编辑器" → editor IDE Vim Neovim Xcode

        无需解释, 只输出关键词行. 若问题不是关于用户历史的, 输出 NONE.
        """
        let expandedRaw = (try? await ScreenHistoryAIProvider().rawComplete(prompt)) ?? ""
        let cleaned = expandedRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.uppercased().hasPrefix("NONE") || cleaned.isEmpty {
            return []
        }
        // Take the first line, split on whitespace, keep 2-30 char terms.
        let firstLine = cleaned.split(separator: "\n").first.map(String.init) ?? cleaned
        let terms = firstLine
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 && $0.count <= 30 }
        // Cap.
        return Array(terms.prefix(8))
    }

    /// Rewind's OCR is tile-based and cuts words at tile boundaries
    /// ("inpu", "rewin", "opusz"). Filter to real words to keep the
    /// injected memory block signal-dense.
    private static func isMeaningfulKeyword(_ w: String) -> Bool {
        let s = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2 else { return false }
        // CJK: 2+ ideographs pass. Rewind tile cuts don't happen inside
        // ideographs (they're indivisible), so any 2+ CJK is real.
        let cjkCount = s.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value)
        }.count
        if cjkCount >= 2 { return true }
        // Latin: 5+ chars, all a-z0-9. Kills 4-letter tile fragments
        // like "inpu", "cont", "hing" without losing "kafka", "claude".
        guard s.count >= 5 else { return false }
        let latin = s.lowercased()
        return latin.allSatisfy { $0.isLetter || $0.isNumber } &&
               latin.contains(where: { $0.isLetter })
    }

    /// Strip the vendor prefix off a bundle identifier so long
    /// `com.company.thebrowser.Browser` type strings don't dominate
    /// the tiny memory block. Keeps last two components at most.
    private static func shortBundle(_ id: String) -> String {
        let parts = id.split(separator: ".")
        guard parts.count > 2 else { return id }
        return parts.suffix(2).joined(separator: ".")
    }

    /// Return the subset of `tagged` blocks whose total char count
    /// (plus `header`) fits under `budgetChars`. Tier 2 (ambient
    /// background) drops first; Tier 1 (high signal) always kept.
    /// `budgetChars <= 0` disables the cap (returns all blocks).
    private static func applyBudget(tagged: [(tier: Int, text: String)],
                                    header: String,
                                    budgetChars: Int) -> [String] {
        guard budgetChars > 0 else { return tagged.map { $0.text } }
        // Preserve original order (matters for prompt readability),
        // but let tier drive drop-eligibility.
        let separatorCost = 2 // "\n\n"
        var currentTotal = header.count
        // Two-pass: first count with all Tier 1 kept; drop Tier 2
        // from END inward until we fit. This preserves the earliest
        // ambient blocks (coverage first, most valuable stable
        // context) while dropping the tail (recent activity list,
        // often the noisiest).
        var keep: [Bool] = Array(repeating: true, count: tagged.count)
        for item in tagged {
            currentTotal += item.text.count + separatorCost
        }
        if currentTotal <= budgetChars {
            return tagged.map { $0.text }
        }
        // Over budget. Drop Tier 2 from the end.
        for i in stride(from: tagged.count - 1, through: 0, by: -1) {
            guard currentTotal > budgetChars else { break }
            if tagged[i].tier >= 2 {
                keep[i] = false
                currentTotal -= (tagged[i].text.count + separatorCost)
            }
        }
        // Still over budget? Drop Tier 1 from the end as last resort.
        for i in stride(from: tagged.count - 1, through: 0, by: -1) {
            guard currentTotal > budgetChars else { break }
            if keep[i] && tagged[i].tier >= 1 {
                keep[i] = false
                currentTotal -= (tagged[i].text.count + separatorCost)
            }
        }
        var out: [String] = []
        for (i, item) in tagged.enumerated() where keep[i] {
            out.append(item.text)
        }
        return out
    }
}
