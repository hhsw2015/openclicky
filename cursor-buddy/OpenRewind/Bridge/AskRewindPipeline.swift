//
//  AskRewindPipeline.swift
//  cursor-buddy
//
//  End-to-end "Ask Rewind" implementation, ported from Rewind.app's
//  Ask AI pipeline as reverse-engineered from the shipping binary,
//  then enhanced with retrace's ranking + query-parser improvements.
//
//  Base pipeline (from Rewind binary IDA reverse):
//    1. Query decomposition — LLM extracts structured retrieval params
//       (keywords, apps, websites, meeting-bool, startTime, endTime)
//       from the user's natural-language question. Output is JSON only.
//
//    2. FTS Search + filter — reader.search(keywords), time-window
//       filter, app filter. Returns [Frame].
//
//    3. Answer synthesis — LLM sees "[FRAME#N] Window: ... Date: ...
//       OCR: ...\n\nUser Query: ..." and produces a cited answer.
//
//  Rewind uses the user's own OpenAI key. We route through the same
//  multi-backend `ScreenHistoryAIProvider` the recap uses, so the user
//  picks HeyClicky Free / Claude / OpenAI in Settings → Screen History.
//

import Foundation

// MARK: - Public entry point

public enum AskRewind {

    public struct Answer: Sendable {
        public let text: String
        public let citedFrameIds: [Int64]
        public let searchQuery: String        // keywords used
        public let resultCount: Int           // frames considered
        public let noResults: Bool            // true if stage-1/2 came up empty
    }

    /// Cheap heuristic used when the LLM Stage-1 decomposition fails.
    /// Splits on whitespace for Latin words + generates bigrams over
    /// each CJK run so FTS can hit substrings of Chinese OCR text.
    /// Rewind's own approach is more thorough (GPT-4 JSON) but they're
    /// paying per token; we need a free path that works.
    /// Exposed for shared use by LongTermMemoryContext.queryHitsBlock —
    /// same tokenization the fallback path uses when Stage-1 LLM fails.
    public static func extractQueryKeywords(from raw: String) -> [String] {
        extractFallbackKeywords(from: raw)
    }

    private static func extractFallbackKeywords(from raw: String) -> [String] {
        let stop: Set<String> = [
            "the","a","an","and","or","of","to","in","on","for","from",
            "with","is","are","was","were","did","do","does","how","what",
            "when","where","who","why","this","that","my","me","i","you",
            "your","show","find","tell","get","about",
            "我","的","了","是","在","有","和","或","过","这个","那个",
            "什么","怎么","怎么样","最近","一下","呢","吗","啊","做",
            "今天","昨天","上周","last","today","yesterday"
        ]
        // Bigram-blocklist: 2-char CJK combos that are pure stopwords —
        // "今天/在做" alone gives zero-signal FTS queries.
        let bigramStop: Set<String> = [
            "今天","昨天","什么","怎么","最近","刚才","现在","一下",
            "在做","的时","时候","过了","有没","没有"
        ]

        var out: [String] = []
        let tokens = raw
            .components(separatedBy: CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for tok in tokens {
            let lower = tok.lowercased()
            if stop.contains(lower) { continue }
            // Latin-only token: length >= 2 wins as-is.
            if tok.allSatisfy({ $0.isASCII }) {
                if tok.count >= 2 { out.append(tok) }
                continue
            }
            // Mixed token: split into runs — each contiguous Latin run
            // becomes a whole word (>= 2 chars); each CJK run gets
            // sliding 2-char bigrams. Handles "深度seek" → ["深度","seek"],
            // "openclicky聊天" → ["openclicky","聊天"], etc.
            let scalars = Array(tok.unicodeScalars)
            var i = 0
            while i < scalars.count {
                if isCJK(scalars[i]) {
                    var j = i
                    while j < scalars.count && isCJK(scalars[j]) { j += 1 }
                    let run = Array(scalars[i..<j])
                    var k = 0
                    while k < run.count - 1 {
                        let bg = String(String.UnicodeScalarView([run[k], run[k+1]]))
                        if !bigramStop.contains(bg) && !out.contains(bg) {
                            out.append(bg)
                        }
                        k += 1
                    }
                    // Single-char CJK runs (like isolated "了") get dropped.
                    if run.count == 1 && !stop.contains(String(run[0])) {
                        // still skip — 1-char CJK is almost always stopword
                    }
                    i = j
                } else if isAsciiWordChar(scalars[i]) {
                    // Latin/digit run — ASCII-range only. Swift's
                    // `.properties.isAlphabetic` is true for CJK too,
                    // which merges "深度seek泄露" into one bogus latin
                    // run.  Restrict to a-z / A-Z / 0-9.
                    var j = i
                    while j < scalars.count, isAsciiWordChar(scalars[j]) {
                        j += 1
                    }
                    let word = String(String.UnicodeScalarView(scalars[i..<j]))
                    if word.count >= 2 && !stop.contains(word.lowercased()) && !out.contains(word) {
                        out.append(word)
                    }
                    i = j
                } else {
                    i += 1  // punctuation, symbol — skip
                }
            }
        }
        return out
    }

    private static func isAsciiWordChar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x30...0x39).contains(v)          // 0-9
            || (0x41...0x5A).contains(v)          // A-Z
            || (0x61...0x7A).contains(v)          // a-z
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) ||
        (0x3040...0x309F).contains(s.value) ||
        (0x30A0...0x30FF).contains(s.value)
    }

    public static func ask(question: String,
                           previousQueries: [String] = [],
                           now: Date = Date()) async throws -> Answer {

        guard let bridge = await MainActor.run(body: { OpenRewindBridge.shared })
        else {
            return Answer(text: "屏幕历史未启用。请到 Settings → Screen History 开启。",
                          citedFrameIds: [], searchQuery: "",
                          resultCount: 0, noResults: true)
        }

        // Short-circuit: if the raw question already parses as a
        // structured query (contains app: / site: / after: / before: /
        // quoted phrases / -excludes), skip Stage 1 LLM.
        let rawParsed = RewindQueryParser.parse(question, now: now)
        let parsed: ParsedRewindQuery
        if rawParsed.isSearchable && rawParsed.hasStructuredHints {
            parsed = rawParsed
        } else {
            // Stage 1: try LLM decomposition first, but fall back to
            // treating every token in the question as a search term if
            // the LLM fails to emit parseable JSON. HeyClicky Free and
            // small models don't always follow strict JSON prompts.
            var p = ParsedRewindQuery()
            do {
                let decomp = try await decomposeQuery(question: question,
                                                       previousQueries: previousQueries,
                                                       now: now)
                p.searchTerms = decomp.keywords
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                p.apps = decomp.apps
                p.websites = decomp.websites
                p.startDate = decomp.startTime
                p.endDate = decomp.endTime
            } catch { /* fall through */ }
            if p.searchTerms.isEmpty {
                // Fallback: extract likely keywords from the raw
                // question — drop stopwords + retrace filter prefixes.
                p.searchTerms = Self.extractFallbackKeywords(from: question)
            }
            parsed = p
        }

        guard parsed.isSearchable else {
            return Answer(text: "I'm sorry, but I could not find any keywords to search for from your question. Please provide a specific time frame or specify what you're looking for in the question.",
                          citedFrameIds: [], searchQuery: "",
                          resultCount: 0, noResults: true)
        }

        let keywords = (parsed.searchTerms + parsed.phrases).joined(separator: " ")

        // Stage 2: retrieval (rewind base) + retrace-style ranking
        try? await bridge.reopenReaderAsync()
        // FTS5 defaults to implicit AND across tokens; that makes it
        // brittle for natural-language queries with 3+ words. First
        // try AND (strict), then fall back to OR (broad) if empty.
        let terms = parsed.searchTerms + parsed.phrases
        let broadQuery = terms.isEmpty
            ? (parsed.apps.first ?? parsed.websites.first ?? "")
            : terms.joined(separator: " OR ")
        var hits = (try? bridge.reader.search(keywords, limit: 60)) ?? []
        if hits.isEmpty && !broadQuery.isEmpty {
            hits = (try? bridge.reader.search(broadQuery, limit: 60)) ?? []
        }
        let filtered = filterHits(hits,
                                  apps: parsed.apps,
                                  websites: parsed.websites,
                                  startTime: parsed.startDate,
                                  endTime: parsed.endDate,
                                  excluded: parsed.excluded)
        guard !filtered.isEmpty else {
            return Answer(text: "No results found. Try refining your search.",
                          citedFrameIds: [], searchQuery: keywords,
                          resultCount: 0, noResults: true)
        }
        // Retrace-inspired multi-signal ranker: recency (0.2) + metadata
        // match (0.1) on top of FTS relevance. URLs weighted highest,
        // window title second, app name third.
        let ranked = RewindResultRanker.rank(filtered,
                                             queryTerms: extractQueryTerms(keywords),
                                             now: now)
        let top = Array(ranked.prefix(8))

        // Stage 3: synthesise answer
        let framesText = try formatFrames(top,
                                          reader: bridge.reader,
                                          keywords: keywords)
        let answer = try await synthesiseAnswer(framesText: framesText,
                                                userQuery: question)
        return Answer(text: answer,
                      citedFrameIds: top.map { $0.entry.id },
                      searchQuery: keywords,
                      resultCount: filtered.count,
                      noResults: false)
    }
}

// MARK: - Retrace-style ranker

/// Multi-signal search-result ranker ported from
/// `retrace/Search/Ranking/ResultRanker.swift`. Applied on top of the
/// FTS bm25 ordering already returned by Reader.search:
///
///   final_score = fts_rank + 0.2 * recency_boost + 0.1 * metadata_boost
///
/// Boost values match retrace's tuning (URLs weighted highest as
/// they carry the most signal; app-name lowest).
enum RewindResultRanker {

    static func rank(_ hits: [OpenRewindSearchHit],
                     queryTerms: Set<String>,
                     now: Date,
                     recencyWeight: Double = 0.2,
                     metadataWeight: Double = 0.1) -> [OpenRewindSearchHit] {
        // Retrace's FTS ranker stored `relevanceScore` per hit; our
        // hits come out of Reader.search already in FTS-rank order,
        // so we treat rank position as the base score: 1.0 down to 0.0.
        let count = max(1, hits.count)
        let scored = hits.enumerated().map { (idx, hit) -> (OpenRewindSearchHit, Double) in
            let base = 1.0 - Double(idx) / Double(count)
            let recency = recencyBoost(for: hit.entry.createdAt, now: now)
            let meta = metadataBoost(for: hit.entry, queryTerms: queryTerms)
            let score = base + recencyWeight * recency + metadataWeight * meta
            return (hit, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    private static func recencyBoost(for ts: Date, now: Date) -> Double {
        let ageDays = now.timeIntervalSince(ts) / 86400.0
        return max(0, 1.0 - ageDays / 30.0)   // linear decay, 30-day floor
    }

    private static func metadataBoost(for entry: OpenRewindEntry,
                                      queryTerms: Set<String>) -> Double {
        var boost = 0.0
        if let title = entry.windowName?.lowercased() {
            let n = queryTerms.filter { title.contains($0) }.count
            boost += Double(n) * 0.3
        }
        if let bundle = entry.bundleID?.lowercased() {
            let n = queryTerms.filter { bundle.contains($0) }.count
            boost += Double(n) * 0.2
        }
        if let url = entry.browserUrl?.lowercased() {
            let n = queryTerms.filter { url.contains($0) }.count
            boost += Double(n) * 0.5   // URLs are strongest signal
        }
        return min(boost, 1.0)
    }
}

private func extractQueryTerms(_ keywords: String) -> Set<String> {
    Set(keywords.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .map { $0.replacingOccurrences(of: "\"", with: "") })
}

// MARK: - Stage 1: query decomposition

private struct QueryDecomposition {
    var keywords: String
    var apps: [String]
    var websites: [String]
    var meeting: Bool
    var startTime: Date?
    var endTime: Date?
}

// Stage-1 prompt — CN JSON protocol style that HeyClicky Free reliably
// follows (proven by the assist-agent tool loop). We give it a minimal
// schema, a concrete example, and the same "只输出 JSON,不要 markdown,不要 prose"
// terminator that AssistAgentPrompt uses.
private let stage1SystemPrompt = """
你是一个提取搜索参数的助手。用户问一个关于他们过去看过的屏幕内容的问题,
你要从中提炼出用于全文检索(FTS)的结构化字段。

只输出一个 JSON 对象,包含这些键:
{
  "keywords": "空格分隔的关键词 (只保留真实检索词,去掉'邮件''会议''对话'这种填充,去掉'写''读''找'这种动词)",
  "apps":     ["可选,如果用户明确点名某个 app,填其 bundle 标识片段;否则空数组"],
  "websites": ["可选,如果用户点名某网站,填其主机名片段;否则空数组"],
  "startTime": "MM-dd-yyyy HH:mm 或 null",
  "endTime":   "MM-dd-yyyy HH:mm 或 null"
}

示例1: "帮我找一下昨天写的那封关于搜索策略的邮件"
输出: {"keywords":"搜索策略","apps":[],"websites":[],"startTime":null,"endTime":null}

示例2: "cmuxterm 里最近有没有 kafka 报错"
输出: {"keywords":"kafka 报错","apps":["cmuxterm"],"websites":[],"startTime":null,"endTime":null}

只输出 JSON,不要 markdown,不要 prose,不要解释。
"""

private func decomposeQuery(question: String,
                            previousQueries: [String],
                            now: Date) async throws -> QueryDecomposition {
    let dfLocal = DateFormatter()
    dfLocal.dateFormat = "MM-dd-yyyy HH:mm"
    let nowStr = dfLocal.string(from: now)

    var userMsg = "Current time: \(nowStr)\n\n"
    if !previousQueries.isEmpty {
        userMsg += "Previous queries in this session:\n"
        for q in previousQueries.suffix(3) {
            userMsg += "  - \(q)\n"
        }
        userMsg += "\n"
    }
    userMsg += "Question: \(question)"

    let raw = try await ScreenHistoryAIProvider().rawComplete(
        stage1SystemPrompt + "\n\n用户问题: " + userMsg)
    return parseDecomposition(raw, dfLocal: dfLocal)
}

private func parseDecomposition(_ raw: String,
                                dfLocal: DateFormatter) -> QueryDecomposition {
    // Strip markdown fences if present.
    let cleaned = raw
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = cleaned.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return QueryDecomposition(keywords: "", apps: [], websites: [],
                                  meeting: false,
                                  startTime: nil, endTime: nil)
    }
    let keywords = (obj["keywords"] as? String) ?? ""
    let apps = (obj["apps"] as? [String]) ?? []
    let websites = (obj["websites"] as? [String]) ?? []
    let meeting = (obj["meeting"] as? Bool) ?? false
    let start = (obj["startTime"] as? String).flatMap(dfLocal.date(from:))
    let end = (obj["endTime"] as? String).flatMap(dfLocal.date(from:))
    return QueryDecomposition(keywords: keywords, apps: apps,
                              websites: websites, meeting: meeting,
                              startTime: start, endTime: end)
}

// MARK: - Stage 2: retrieval filters

private func filterHits(_ hits: [OpenRewindSearchHit],
                        apps: [String],
                        websites: [String],
                        startTime: Date?,
                        endTime: Date?,
                        excluded: [String] = []) -> [OpenRewindSearchHit] {
    hits.filter { h in
        let e = h.entry
        if let s = startTime, e.createdAt < s { return false }
        if let end = endTime, e.createdAt > end { return false }
        if !apps.isEmpty {
            let bid = e.bundleID ?? ""
            let match = apps.contains { needle in
                bid.range(of: needle, options: .caseInsensitive) != nil
            }
            if !match { return false }
        }
        if !websites.isEmpty {
            let url = e.browserUrl ?? ""
            let match = websites.contains { site in
                url.range(of: site, options: .caseInsensitive) != nil
            }
            if !match { return false }
        }
        if !excluded.isEmpty {
            let snip = h.snippet.lowercased()
            let win = (e.windowName ?? "").lowercased()
            let hay = snip + " " + win
            if excluded.contains(where: { hay.contains($0.lowercased()) }) {
                return false
            }
        }
        return true
    }
}

// MARK: - Stage 3: answer synthesis

// Rewind's Stage-2 system prompt (near-verbatim from the binary).
private let stage3SystemPrompt = """
You are an intelligent assistant powering Rewind AI. You are provided
with OCR readings of the user's screen at various times in the past,
and should use them to answer the user's question.

Each "frame" will contain the name of the window, and the date at
which it was taken, as well as a frame identifier, in the format
[FRAME#{frame_id}].

Please synthesize the most useful parts of the frames into a response,
adding in any additional contextual information you know. Please keep
the response short, and also cite any information you receive from a
frame by using the frame identifier.

Do not use the word "frame" in your response, only refer to frames as
"search results".

When citing frames, do not directly refer to the frame, like "As seen
in [FRAME#1], you were walking", instead use them as citations that
are not part of the sentence, like: "You were walking. [FRAME#1]".

This is very important — do not use frames as a part of the sentence!
The sentence should sound complete without the [FRAME#1], and the
[FRAME#1] tag should solely exist as additional citation.

Please respond in 2-3 paragraphs. It may be useful to quote verbatim
from frames.

In cases where one or two frames are much more relevant than other
frames, you should focus most of your response on the relevant frames.

When citing multiple frames for a given result, cite them as
[FRAME#1][FRAME#2].

NOTE: The OCR text is stitched from tile-based OCR — regions do not
follow reading order. Treat it as a bag of terms describing what was
on screen and synthesise a natural-language answer.

If all the information provided is not relevant to the user's
question, please say so.
"""

private func formatFrames(_ hits: [OpenRewindSearchHit],
                          reader: OpenRewindReader,
                          keywords: String) throws -> String {
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    let terms = keywords
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
    var out = ""
    for hit in hits.prefix(8) {
        let e = hit.entry
        let win = e.windowName ?? "Unknown window"
        let app = e.bundleID ?? "?"
        let date = df.string(from: e.createdAt)
        // Prefer the FTS snippet. If empty (matched tile was empty),
        // synthesise a highlighted snippet from the full-frame OCR
        // via RewindSnippetGenerator so the LLM always has usable
        // context to cite.
        var body = hit.snippet
        if body.isEmpty {
            let full = (try? reader.ocr(for: e.id).text) ?? ""
            body = RewindSnippetGenerator.generate(fullText: full,
                                                   queryTerms: terms,
                                                   maxSnippets: 3)
        }
        out += "[FRAME#\(e.id)] Window: \(win) (\(app)) Date: \(date)\n"
        out += "OCR: \(body)\n\n"
    }
    return out
}

private func synthesiseAnswer(framesText: String,
                              userQuery: String) async throws -> String {
    let combined = stage3SystemPrompt + "\n\n"
        + framesText
        + "User Query: \(userQuery)"
    return try await ScreenHistoryAIProvider().rawComplete(combined)
}
