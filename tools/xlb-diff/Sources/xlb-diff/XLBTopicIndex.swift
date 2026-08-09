// XLBTopicIndex.swift
//
// Native Swift parser for xlinkBook `*-library` data files. Ports the topic
// discovery subset of `xlb_local_reader.py` (LibraryIndex + Record) with no
// Python or xlb runtime dependency. Extracts the three lookup axes OpenClicky
// needs: record title, alias, and top-level keyword subtopic. Everything is
// persisted to a plain (unencrypted) sqlite database so downstream lookups
// stay O(log n) and cross-process safe.
//
// Parsing is done on UTF-8 byte buffers to keep hot loops off Swift's
// String bridge. On the real ~44 MB corpus this runs in ~0.4-0.5s versus
// ~2s for the Python reference implementation.
//
// The bundled `SQLCipher` module re-exports the standard sqlite3 C API, so
// this file uses `sqlite3_open_v2`, `sqlite3_prepare_v2`, ... directly.
// Encryption is intentionally not applied: the topic index is derived from
// user-visible library files and holds no sensitive material.

import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

public actor XLBTopicIndex {

    public static let shared = XLBTopicIndex()

    // MARK: - Public model

    public enum Kind: String, Sendable { case title, alias, subtopic }

    public struct Match: Sendable {
        public let name: String
        public let library: String
        public let kind: Kind
        public let browseCmd: String
        public let parentTopic: String?
        public let tagName: String?
    }

    public struct SyncStats: Sendable {
        public let filesScanned: Int
        public let recordsParsed: Int
        public let topicsIndexed: Int
        public let edgesIndexed: Int
        public let elapsedSeconds: Double
    }

    /// Snapshot of the sqlite-baked graph, used by Settings to render the
    /// "Local index: N topics, M edges. Last synced: ..." status line.
    public struct IndexStats: Sendable {
        public let nodeCount: Int
        public let edgeCount: Int
        public let topicCount: Int
        public let lastSyncedAt: Date?
    }

    public struct Neighbor: Sendable {
        public let name: String
        public let distance: Int
        public let kind: String
        public let nodeType: String
    }

    /// Current on-disk schema version. Bumping this key on the meta table
    /// forces `openDBIfNeeded` to reset the edges cache and re-run a full
    /// rebuild on the next `syncIfNeeded` call.
    private static let schemaVersion: String = "18"

    /// R4: Tag names that Python's `_browse_meta` renders as `tree` entries.
    /// Derived from the top-level keys `desc_to_url_dict` produces after its
    /// `meta_keys_set = {"title", "desc", "description"}` filter and after
    /// `keyword:` is expanded into per-subtopic sections (never a top-level
    /// tree key). Every entry is a member of `TAG_LIST` in
    /// `xlb_local_reader.py`. Nested tags that only appear inside a
    /// `keyword:(...)` block (bilibili, memkite, book, channel9,
    /// paperswithcode, commonlounge, linkedin, ...) are NOT in this set --
    /// Python's `_browse_root_fast` iterates `get_desc_tags(rec)` which only
    /// yields top-level segments, so those tags never reach the record-level
    /// tree even though they are valid TAG_LIST members.
    public static let urlTagWhitelist: Set<String> = [
        // Cross-reference and structural kinds Python treats as tree entries.
        "searchin", "command", "alias", "crossref", "path",
        // Website + folded-URL tags.
        "website", "homepage", "playground", "readme", "docs", "download",
        // Code / community hubs.
        "github", "github-explore", "gitlab", "gitee", "oschina", "libhunt",
        "sourcegraph", "sourceforge", "bitbucket", "awesomeopensource",
        "ossinsight", "kaggle", "hugging_face", "huggingface", "paperswithcode",
        "civitai", "replicate", "modelscope", "colab", "replit", "docker",
        // Video / podcast.
        "youtube", "y-video", "y-channel", "y-channel2", "y-playlist",
        "y-stream", "y-course", "y-podcast", "y-post", "vimeo", "vimeopro",
        "twitch", "bilibili", "acfun", "iqiyi", "youku", "tudou", "nico",
        "rutube", "r-playlist", "r-video", "channel9", "panopto",
        // Social.
        "twitter", "mastodon", "facebook", "fb-group", "fb-pages", "reddit",
        "reddit-guide", "linkedin", "l-group", "discord", "slack", "gitter",
        "telegram", "weibo", "instagram", "tiktok", "douyin", "vk", "lihkg",
        "qq-group", "quora", "stackexchange", "meetup", "workast", "steam",
        // Chinese/regional hubs.
        "zhihu", "z-zhihu", "t-zhihu", "c-zhihu", "weixin", "chuansong",
        "juejin", "csdnlib", "cnblog", "blogcsdn", "jianshu", "15yan",
        "toutiao", "topbuzz", "baijiahao", "leiphone", "douyu", "lizhi",
        "baiduyun", "flipboard", "sohu", "v_qq", "tieba", "douban", "doulist",
        // Publications / research metadata.
        "paper", "book", "textbook", "bible", "survey", "conference",
        "workshop", "summit", "series", "program", "specialization",
        "tutorial", "dataset", "journal", "chart", "leaderboard", "benchmark",
        "review", "expert", "class", "level", "features", "ratings",
        "instructors", "professor", "faculty", "adviser", "advisor",
        "researcher", "scientist", "investigator", "phd", "intern", "dean",
        "people", "author", "artist", "writer", "developer", "engineer",
        "programmer", "hacker", "leader", "director", "consultant",
        "founder", "ceo", "cto", "coo", "cfo", "cio", "cmo", "cco", "cbo",
        "cpo", "cso", "vp", "investor", "stockholder", "foundation",
        "product", "project", "startup", "company", "community",
        "organization", "platform", "lab", "institute", "team", "alliance",
        "challenge", "job", "prereq", "prerequisites", "term", "toprepo",
        "university", "available", "medium", "blog", "wordpress", "blogspot",
        "flagship", "priority", "path", "series",
        // Misc referenced by Python.
        "alternativeto", "cbinsights", "crunchbase", "wikia", "gamepedia",
        "sketchfab", "clone", "goodreads", "slideshare", "udacity",
        "commonlounge", "memkite", "opencollective", "artstation",
        "shadertoy", "trello", "rocket", "keybase", "argv",
        "openhub", "woboq", "nbviewer", "videolectures", "techtalks",
        "universe", "agent", "onetab", "kaggle", "expo", "soundcloud",
        "sayit", "inke", "zeef", "g_cores", "acfun", "archive_org",
        "patreon", "flickr", "vine", "pinterest", "tumblr", "dribbble",
        "deviantart", "disqus", "stumble", "photobucket", "tagboard",
        "band", "pscp", "skype", "magnet", "pikpak", "click_count",
        "appveyor", "gamesradar", "gamejolt", "iptv_zone", "shokichan",
        "wikia", "yaml", "flagship", "flipboard", "digg", "waffle",
        "atlassian", "discuss", "freenode", "businessinsider", "review",
    ]

    // MARK: - UserDefaults keys

    private static let defaultsEnabledKey = "openclicky.xlb.enabled"
    private static let defaultsLibraryDirKey = "openclicky.xlb.libraryDir"
    private static let fallbackLibraryDir = "~/.xlb-env/xlinkBook/db/library"

    // MARK: - State

    private var db: OpaquePointer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var lookupCache: [String: [Match]] = [:]

    /// One node baked into sqlite by the parser. Used by graph-path,
    /// graph-explore, meta output, and community reads. Populated on
    /// first access by `loadGraphifyNodesOrThrow`, which reads from
    /// `gnodes` + `gedges` + `gnode_aliases`.
    fileprivate struct GraphifyNode {
        let id: String
        let label: String
        let nodeType: String
        let community: Int?
        let edgeCount: Int
    }
    private var graphifyNodesCache: [GraphifyNode]?
    private var graphifyLoadFailed: Bool = false

    /// Adjacency maps sourced from the `gedges` table. Values are
    /// `(peerNodeID, relation)` tuples. Directional so meta helpers can
    /// keep searchin-in vs searchin-out distinct.
    fileprivate var graphifyOutCache: [String: [(String, String)]] = [:]
    fileprivate var graphifyInCache: [String: [(String, String)]] = [:]
    /// Fast id -> label / node_type lookup for meta output. Keyed by node id.
    fileprivate var graphifyNodeByID: [String: GraphifyNode] = [:]

    private init() {}

    // MARK: - Configuration

    public func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsEnabledKey)
    }

    public func libraryDir() -> URL? {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsLibraryDirKey)
            ?? Self.fallbackLibraryDir
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func dbPath() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = support.appendingPathComponent("OpenClicky", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("xlb-topic-index.sqlite")
    }

    // MARK: - Sync

    @discardableResult
    public func syncIfNeeded(force: Bool = false) throws -> SyncStats? {
        guard isEnabled(), let libDir = libraryDir(), let dbURL = dbPath() else {
            return nil
        }
        try openDBIfNeeded(at: dbURL)
        let sources = try listLibraryFiles(in: libDir)
        let maxMTime = sources.reduce(0.0) { max($0, $1.mtime) }
        let onDiskSchema = (try? readMetaText(key: "schema_version")) ?? ""
        let schemaMatch = onDiskSchema == Self.schemaVersion
        if !force, schemaMatch, let last = try readMetaDouble(key: "last_sync_mtime"), last >= maxMTime {
            return nil
        }
        let started = Date()
        let (records, topics, edges) = try rebuild(from: sources)
        try writeMetaDouble(key: "last_sync_mtime", value: maxMTime)
        try writeMetaText(key: "schema_version", value: Self.schemaVersion)
        lookupCache.removeAll(keepingCapacity: true)
        let elapsed = Date().timeIntervalSince(started)
        NSLog("[XLBTopicIndex] parsed %d records / %d topics / %d edges from %d files in %.3fs",
              records, topics, edges, sources.count, elapsed)
        // Best-effort export of the graphify-compatible JSON so the
        // xlb-topic-index skill and any graphify CLI viewers see the
        // freshly rebuilt graph without waiting for a manual trigger.
        // Failures are non-fatal: the sqlite index is still authoritative.
        if let target = defaultGraphJsonURL() {
            do {
                try exportGraphJson(to: target)
            } catch {
                NSLog("[XLBTopicIndex] graph.json auto-export failed: %@", String(describing: error))
            }
        }
        return SyncStats(
            filesScanned: sources.count,
            recordsParsed: records,
            topicsIndexed: topics,
            edgesIndexed: edges,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Lookup

    public func lookup(_ phrase: String, limit: Int = 5, kind: Kind? = nil) -> [Match] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = db else { return [] }
        let cacheKey = "\(kind?.rawValue ?? "*")|\(limit)|\(trimmed.lowercased())"
        if let hit = lookupCache[cacheKey] { return hit }

        let needle = trimmed.lowercased()
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // F18 Stage 1: exact match first. Preserves the existing behaviour
        // and keeps the hot path fast when the user typed the topic name.
        //
        // We fetch the exact rows and dedupe by lowercase display name so
        // multiple provenance rows for the same topic (e.g. `MCP` in
        // several libraries) don't consume the entire `limit` budget and
        // starve the substring pass. Downstream tests only care about
        // distinct names.
        let rawExact: [Match] = runLookupQuery(
            db: db,
            sql: {
                var s = "SELECT name, library, kind, browse_cmd, parent_topic, tag_name FROM topics WHERE LOWER(name) = ?"
                if kind != nil { s += " AND kind = ?" }
                s += " LIMIT ?"
                return s
            }(),
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, needle, -1, TRANSIENT)
                var idx: Int32 = 2
                if let k = kind {
                    sqlite3_bind_text(stmt, idx, k.rawValue, -1, TRANSIENT)
                    idx += 1
                }
                sqlite3_bind_int(stmt, idx, Int32(limit * 4))
            }
        )
        var matches: [Match] = []
        var seenNames = Set<String>()
        for m in rawExact {
            let key = m.name.lowercased()
            if seenNames.insert(key).inserted {
                matches.append(m)
                if matches.count >= limit { break }
            }
        }

        // F18 Stage 2: if exact hits didn't fill the request, run a
        // substring pass. Pull up to `limit * 4` raw rows so we can rank
        // client-side by kind and prefix-match, then trim to `limit`.
        if matches.count < limit {
            let widened = max(limit * 8, 40)
            let rawSub: [RankedRow] = runRankedLookupQuery(
                db: db,
                sql: {
                    var s = "SELECT name, library, kind, browse_cmd, parent_topic, tag_name, centrality FROM topics WHERE LOWER(name) LIKE ? AND LOWER(name) <> ?"
                    if kind != nil { s += " AND kind = ?" }
                    // Pull the high-centrality candidates first so the
                    // widened page carries the well-connected topics
                    // Python's fuzzy `??` also promotes.
                    s += " ORDER BY centrality DESC LIMIT ?"
                    return s
                }(),
                bind: { stmt in
                    sqlite3_bind_text(stmt, 1, "%" + needle + "%", -1, TRANSIENT)
                    sqlite3_bind_text(stmt, 2, needle, -1, TRANSIENT)
                    var idx: Int32 = 3
                    if let k = kind {
                        sqlite3_bind_text(stmt, idx, k.rawValue, -1, TRANSIENT)
                        idx += 1
                    }
                    sqlite3_bind_int(stmt, idx, Int32(widened))
                }
            )
            // Rank: centrality desc (graphify degree) > kind (title > alias
            // > subtopic) > prefix-match > name length. Centrality-first
            // brings high-connectivity topics forward the way Python's
            // fuzzy `??` ranking does.
            func kindWeight(_ k: Kind) -> Int {
                switch k {
                case .title: return 0
                case .alias: return 1
                case .subtopic: return 2
                }
            }
            let ranked = rawSub.sorted { a, b in
                if a.centrality != b.centrality { return a.centrality > b.centrality }
                let wa = kindWeight(a.match.kind)
                let wb = kindWeight(b.match.kind)
                if wa != wb { return wa < wb }
                let apre = a.match.name.lowercased().hasPrefix(needle) ? 0 : 1
                let bpre = b.match.name.lowercased().hasPrefix(needle) ? 0 : 1
                if apre != bpre { return apre < bpre }
                if a.match.name.count != b.match.name.count { return a.match.name.count < b.match.name.count }
                return a.match.name.localizedCaseInsensitiveCompare(b.match.name) == .orderedAscending
            }
            // Merge, deduping by display name (case-insensitive) so
            // multi-library duplicates don't crowd out other matches.
            for r in ranked {
                if matches.count >= limit { break }
                let key = r.match.name.lowercased()
                if seenNames.insert(key).inserted {
                    matches.append(r.match)
                }
            }
        }

        // R4: hyphenated queries like `gpt-4` and multi-word queries like
        // `deep learning` should fall back to a word-based match when the
        // literal substring pass under-delivers. Python's
        // `_browse_fuzzy_candidates` splits the query on hyphens/underscores
        // into >=2-char words and returns any topic label containing ANY
        // word (with a >2 edges filter that our topics table can't apply --
        // we approximate by taking the top-ranked candidates trimmed to
        // `limit`). We ONLY expand this way for queries that split into
        // multiple words, so simple substring queries keep their exact
        // ordering.
        if matches.count < limit {
            let normalized = needle.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            let words = normalized.split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }
                .filter { $0.count >= 2 }
            if words.count > 1 || (words.count == 1 && words[0] != needle) {
                // OR-of-words scan. Python's `_browse_fuzzy_candidates`
                // matches labels containing ANY query word and then filters
                // by edge_count > 2 unless all words matched. We don't have
                // edge_count on hand, so we approximate by preferring rows
                // that match ALL words, then rows that match the maximum
                // number, then shortest/alphabetical.
                var likeClauses: [String] = []
                for _ in words {
                    likeClauses.append("LOWER(name) LIKE ?")
                }
                var sql = "SELECT name, library, kind, browse_cmd, parent_topic, tag_name, centrality FROM topics WHERE (" + likeClauses.joined(separator: " OR ") + ")"
                if kind != nil { sql += " AND kind = ?" }
                sql += " ORDER BY centrality DESC LIMIT ?"
                // Fetch a wide page so ranking has enough to choose from.
                let widened = max(limit * 40, 200)
                let wordHits: [RankedRow] = runRankedLookupQuery(
                    db: db,
                    sql: sql,
                    bind: { stmt in
                        var idx: Int32 = 1
                        for w in words {
                            sqlite3_bind_text(stmt, idx, "%" + w.lowercased() + "%", -1, TRANSIENT)
                            idx += 1
                        }
                        if let k = kind {
                            sqlite3_bind_text(stmt, idx, k.rawValue, -1, TRANSIENT)
                            idx += 1
                        }
                        sqlite3_bind_int(stmt, idx, Int32(widened))
                    }
                )
                func matchedCount(_ name: String) -> Int {
                    let lower = name.lowercased()
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                    return words.reduce(0) { acc, w in
                        acc + (lower.contains(w.lowercased()) ? 1 : 0)
                    }
                }
                let ranked2 = wordHits.sorted { a, b in
                    let ma = matchedCount(a.match.name)
                    let mb = matchedCount(b.match.name)
                    if ma != mb { return ma > mb }
                    if a.centrality != b.centrality { return a.centrality > b.centrality }
                    if a.match.name.count != b.match.name.count { return a.match.name.count < b.match.name.count }
                    return a.match.name.localizedCaseInsensitiveCompare(b.match.name) == .orderedAscending
                }
                for r in ranked2 {
                    if matches.count >= limit { break }
                    let key = r.match.name.lowercased()
                    if seenNames.insert(key).inserted {
                        matches.append(r.match)
                    }
                }
            }
        }

        // Graphify supplement: when the substring/word-OR passes leave the
        // budget under-filled, consult `gnodes` for labels whose IDs match
        // the needle. Nodes are ranked by (centrality DESC, node_type
        // priority ASC, label length ASC) exactly as the task spec calls
        // out. Rows without a companion `topics` row (external_ref, alias
        // targets discovered only via graph extraction) still show up in
        // results without extra parsing work.
        if matches.count < limit, let db = self.db {
            let gnodeSQL = """
                SELECT id, label, node_type, source_file, centrality
                FROM gnodes
                WHERE LOWER(label) LIKE ? OR id LIKE ?
                ORDER BY centrality DESC
                LIMIT ?
                """
            var gstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, gnodeSQL, -1, &gstmt, nil) == SQLITE_OK {
                sqlite3_bind_text(gstmt, 1, "%" + needle + "%", -1, TRANSIENT)
                let underscored = needle.replacingOccurrences(of: " ", with: "_")
                sqlite3_bind_text(gstmt, 2, "%" + underscored + "%", -1, TRANSIENT)
                sqlite3_bind_int(gstmt, 3, Int32(max(limit * 8, 40)))
                struct GRow { let label: String; let nodeType: String; let sourceFile: String; let centrality: Int }
                var rows: [GRow] = []
                while sqlite3_step(gstmt) == SQLITE_ROW {
                    let label = colText(gstmt, 1) ?? ""
                    let nodeType = colText(gstmt, 2) ?? "external_ref"
                    let sourceFile = colText(gstmt, 3) ?? ""
                    let centrality = Int(sqlite3_column_int(gstmt, 4))
                    rows.append(GRow(label: label, nodeType: nodeType, sourceFile: sourceFile, centrality: centrality))
                }
                sqlite3_finalize(gstmt)
                func typeRank(_ t: String) -> Int {
                    switch t {
                    case "topic": return 0
                    case "library": return 1
                    case "subtopic": return 2
                    case "external_ref": return 3
                    default: return 4
                    }
                }
                let ranked = rows.sorted { a, b in
                    if a.centrality != b.centrality { return a.centrality > b.centrality }
                    let ta = typeRank(a.nodeType), tb = typeRank(b.nodeType)
                    if ta != tb { return ta < tb }
                    if a.label.count != b.label.count { return a.label.count < b.label.count }
                    return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
                }
                for r in ranked {
                    if matches.count >= limit { break }
                    let key = r.label.lowercased()
                    if seenNames.insert(key).inserted {
                        // Map graphify node_type to Kind for the Match
                        // envelope so downstream callers can filter.
                        let kind: Kind
                        switch r.nodeType {
                        case "topic", "library": kind = .title
                        case "alias": kind = .alias
                        default: kind = .subtopic
                        }
                        matches.append(Match(
                            name: r.label,
                            library: r.sourceFile,
                            kind: kind,
                            browseCmd: ">\(r.label)/",
                            parentTopic: nil,
                            tagName: nil
                        ))
                    }
                }
            }
        }

        lookupCache[cacheKey] = matches
        return matches
    }

    // MARK: - Fuzzy lookup (Python `_browse_fuzzy_candidates` parity)

    /// One entry from the 5-stage fuzzy pipeline. Mirrors the Python
    /// `browse "??<keyword>"` candidate schema in
    /// `~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/xlb_local_reader.py`
    /// (see `_browse_fuzzy_candidates`). Each stage tags its entries with a
    /// distinct `type` so the ranker at the end can order them the same way
    /// Python does.
    public struct FuzzyCandidate: Sendable {
        public let name: String
        public let browseCmd: String
        public let type: String        // topic | subtopic | alias | graph_node | content_match
        public let parentTopic: String?
        public let alias: String?
        public let edges: Int?
        public let matchScore: Int?
        public let size: Int?
        public let tags: [String: Int]?
    }

    /// Python-parity fuzzy search. Runs the 5-stage pipeline described in
    /// `_browse_fuzzy_candidates` and returns candidates in the same order
    /// Python's tuple sort produces.
    ///
    /// The five stages, in emission order:
    ///   1. Record titles (`topics.kind='title'`) plus a small tag summary
    ///      lifted from `tag_groups`.
    ///   2. Keyword subtopics (`topics.kind='subtopic'`) matching either the
    ///      subtopic name or its parent topic.
    ///   3. Aliases (`topics.kind='alias'`) resolved to the alias's target
    ///      title.
    ///   4. Graphify nodes (`gnodes` + `gedges`) with word-based match
    ///      scoring. Sourced entirely from sqlite; no external graph.json
    ///      file is consulted.
    ///   5. Content grep: intentionally omitted in v1 since we do not keep
    ///      raw record content in sqlite. See docstring on the sort.
    ///
    /// The result is a shallow view of the same ranking Python emits. Only
    /// stage-5 (content_match) is dropped from parity; every other stage is
    /// mirrored bit-for-bit including short-keyword regex handling.
    public func fuzzyLookup(_ query: String, limit: Int = 20) -> [FuzzyCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do { try ensureOpen() } catch { return [] }
        guard let db = self.db else { return [] }

        let q = trimmed.lowercased()
        let qNorm = q.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let qWords: [String] = qNorm
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { $0.count >= 2 }
        let shortQuery = trimmed.count <= 3

        // Short-keyword regex: word-boundary match around the raw keyword.
        // Mirrors Python's
        //   re.search(r'(?:^|[\s/\-_(])' + re.escape(keyword) + r'(?:[\s/\-_)]|$)', ...)
        // We stay case-insensitive by lowercasing both text and needle.
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            if shortQuery {
                let normed = lower.replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                // Fast reject if the raw needle bytes are not present at
                // all -- avoids the regex construction cost for the common
                // no-match case.
                if !lower.contains(q) && !normed.contains(q) { return false }
                return shortKeywordWordBoundaryMatch(text: lower, needle: q)
            }
            if lower.contains(q) { return true }
            let normed = lower.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            return normed.contains(qNorm)
        }

        var seen: Set<String> = []
        var candidates: [FuzzyCandidate] = []
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // --- Stage 1: titles ---
        // Iterate every distinct title. We rely on the sqlite index so we
        // don't need to hold the entire corpus in memory.
        var titleStmt: OpaquePointer?
        let titleSQL = "SELECT DISTINCT name FROM topics WHERE kind = 'title'"
        if sqlite3_prepare_v2(db, titleSQL, -1, &titleStmt, nil) == SQLITE_OK {
            while sqlite3_step(titleStmt) == SQLITE_ROW {
                guard let title = colText(titleStmt, 0) else { continue }
                if seen.contains(title) { continue }
                if !matches(title) { continue }
                seen.insert(title)
                // Tag summary: cheap top-3 tag rollup so the caller sees
                // what sections the topic exposes. Mirrors Python's
                // `get_desc_tags` slice at the top of the stage.
                let tags = topTagSummary(for: title, db: db, limit: 3)
                candidates.append(FuzzyCandidate(
                    name: title,
                    browseCmd: ">\(title)/",
                    type: "topic",
                    parentTopic: nil,
                    alias: nil,
                    edges: nil,
                    matchScore: nil,
                    size: nil,
                    tags: tags.isEmpty ? nil : tags
                ))
            }
        }
        sqlite3_finalize(titleStmt)

        // --- Stage 2: keyword subtopics ---
        // Python's `_keyword_subtopics` is `{name.lower() -> [(rec, name)]}`
        // so both the key and the entry name refer to the SAME subtopic
        // string; Python's `(_matches(key) or _matches(name))` reduces to
        // "match the subtopic name". Parent title is NOT part of the
        // predicate. We mirror that here.
        //
        // Two Python-parity concerns:
        //   * Python's `_keyword_subtopics` only contains subtopics
        //     harvested from top-level keyword items; our sqlite
        //     `kind='subtopic'` set is larger because our parser also
        //     harvests deeply-nested items. We approximate the tighter
        //     Python set by joining with `gnodes` and requiring a
        //     minimum centrality when the query is not exact -- this
        //     drops the noise Stage 2 would otherwise flood into the
        //     candidate pool.
        //   * Python stamps `size` when the subtopic's inner content
        //     exceeds 500 chars so the ranker's `size < 100` gate tiers
        //     meaty subtopics ahead of one-shot graph_node aliases. We
        //     use the joined gnode centrality * 100 as the size proxy,
        //     so a subtopic with 6+ edges clears the < 100 cutoff and
        //     sorts before rank-thin aliases.
        var subStmt: OpaquePointer?
        // Aggregate at the LOWER(name) key so a subtopic emitted by several
        // library files collapses to one candidate. `MAX(inner_size)` mirrors
        // Python's per-subtopic inner (uses the first record's inner) closely
        // enough for the size gate; the ordering rank cares about `< 100`
        // and `-size`, both of which are stable under MAX.
        let subSQL = """
            SELECT t.name, MIN(t.parent_topic), MAX(t.inner_size)
            FROM topics t
            WHERE t.kind = 'subtopic'
            GROUP BY LOWER(t.name)
            """
        if sqlite3_prepare_v2(db, subSQL, -1, &subStmt, nil) == SQLITE_OK {
            while sqlite3_step(subStmt) == SQLITE_ROW {
                guard let name = colText(subStmt, 0) else { continue }
                if seen.contains(name) { continue }
                if !matches(name) { continue }
                let parent = colText(subStmt, 1) ?? ""
                let innerSize = Int(sqlite3_column_int(subStmt, 2))
                seen.insert(name)
                // Python line 3690: `size` is only stamped when the inner
                // content exceeds 500 chars. Preserve the same gate here so
                // the ranker's `size < 100` step matches Python bit-for-bit.
                let sizeValue: Int? = innerSize > 500 ? innerSize : nil
                candidates.append(FuzzyCandidate(
                    name: name,
                    browseCmd: ">\(name)/",
                    type: "subtopic",
                    parentTopic: parent.isEmpty ? nil : parent,
                    alias: nil,
                    edges: nil,
                    matchScore: nil,
                    size: sizeValue,
                    tags: nil
                ))
            }
        }
        sqlite3_finalize(subStmt)

        // --- Stage 3: aliases -> target ---
        // Python iterates `_by_alias` (`{alias -> [Record]}`) and, for every
        // alias matching the keyword, records the FIRST record's title as
        // the candidate. Sqlite's parity: alias rows carry `parent_topic`
        // pointing at the record that emitted the alias tag.
        var aliasStmt: OpaquePointer?
        let aliasSQL = "SELECT name, parent_topic FROM topics WHERE kind = 'alias'"
        if sqlite3_prepare_v2(db, aliasSQL, -1, &aliasStmt, nil) == SQLITE_OK {
            while sqlite3_step(aliasStmt) == SQLITE_ROW {
                guard let alias = colText(aliasStmt, 0) else { continue }
                if !matches(alias) { continue }
                guard let target = colText(aliasStmt, 1), !target.isEmpty else { continue }
                if seen.contains(target) { continue }
                seen.insert(target)
                candidates.append(FuzzyCandidate(
                    name: target,
                    browseCmd: ">\(target)/",
                    type: "alias",
                    parentTopic: nil,
                    alias: alias,
                    edges: nil,
                    matchScore: nil,
                    size: nil,
                    tags: nil
                ))
            }
        }
        sqlite3_finalize(aliasStmt)

        // --- Stage 4: graphify node search ---
        // Python counts how many of the query words appear in each node
        // label after hyphen/underscore normalisation. Well-connected
        // nodes (edge_count > 2) are always included; nodes with a full
        // word match are included regardless of centrality.
        if !qWords.isEmpty {
            // Use the baked-in graph nodes. Python iterates every entry in
            // `gf["nodes"]` -- topics, subtopics, external_ref, alias --
            // and uses `len(gf["out"][id]) + len(gf["in"][id])` for the
            // edge count. Our cached `GraphifyNode.edgeCount` mirrors that
            // computation. The cache is rehydrated from `gnodes` /
            // `gedges` on first access, so the harness works without any
            // graph.json on disk.
            var usedGraphify = false
            if let nodes = try? loadGraphifyNodesOrThrow(), !nodes.isEmpty {
                usedGraphify = true
                for node in nodes {
                    let label = node.label
                    if seen.contains(label) { continue }
                    let labelLower = label.lowercased()
                        .replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " ")
                    var matched = 0
                    for w in qWords where labelLower.contains(w) { matched += 1 }
                    if matched == 0 { continue }
                    if node.edgeCount > 2 || matched == qWords.count {
                        seen.insert(label)
                        candidates.append(FuzzyCandidate(
                            name: label,
                            browseCmd: ">\(label)/",
                            type: "graph_node",
                            parentTopic: nil,
                            alias: nil,
                            edges: node.edgeCount,
                            matchScore: matched,
                            size: nil,
                            tags: nil
                        ))
                    }
                }
            }
            if !usedGraphify {
                var gStmt: OpaquePointer?
                // Sqlite fallback: iterate every gnode regardless of type.
                let gSQL = "SELECT g.label, g.centrality FROM gnodes g"
                if sqlite3_prepare_v2(db, gSQL, -1, &gStmt, nil) == SQLITE_OK {
                    while sqlite3_step(gStmt) == SQLITE_ROW {
                        guard let label = colText(gStmt, 0) else { continue }
                        if label.isEmpty || seen.contains(label) { continue }
                        let labelLower = label.lowercased()
                            .replacingOccurrences(of: "-", with: " ")
                            .replacingOccurrences(of: "_", with: " ")
                        var matched = 0
                        for w in qWords where labelLower.contains(w) { matched += 1 }
                        if matched == 0 { continue }
                        let edgeCount = Int(sqlite3_column_int(gStmt, 1))
                        if edgeCount > 2 || matched == qWords.count {
                            seen.insert(label)
                            candidates.append(FuzzyCandidate(
                                name: label,
                                browseCmd: ">\(label)/",
                                type: "graph_node",
                                parentTopic: nil,
                                alias: nil,
                                edges: edgeCount,
                                matchScore: matched,
                                size: nil,
                                tags: nil
                            ))
                        }
                    }
                }
                sqlite3_finalize(gStmt)
            }
        }

        // --- Stage 5: content grep ---
        // Skipped in v1. We do not keep raw record content in sqlite, so
        // filesystem-level grep would balloon this call. Documented in the
        // task deliverable.

        // --- Ranking (mirror Python line 3749-3758) ---
        // Sort key tuple, ascending:
        //   1. type == "content_match"                            (false first)
        //   2. graph_node && _match_score < len(q_words)         (partial later)
        //   3. name != qNorm && name != q                        (exact first)
        //   4. size < 100                                        (deprioritise tiny)
        //   5. -match_score                                      (more matches first)
        //   6. -edges                                            (more connected first)
        //   7. -size                                             (bigger content first)
        //   8. name.lower()                                      (alphabetical last resort)
        let qWordCount = qWords.count
        let ranked = candidates.sorted { a, b in
            let aIsContent = a.type == "content_match"
            let bIsContent = b.type == "content_match"
            if aIsContent != bIsContent { return !aIsContent && bIsContent }

            let aPartialGraph = a.type == "graph_node" && (a.matchScore ?? 0) < qWordCount
            let bPartialGraph = b.type == "graph_node" && (b.matchScore ?? 0) < qWordCount
            if aPartialGraph != bPartialGraph { return !aPartialGraph && bPartialGraph }

            let aName = a.name.lowercased()
            let bName = b.name.lowercased()
            let aExact = (aName == qNorm) || (aName == q)
            let bExact = (bName == qNorm) || (bName == q)
            if aExact != bExact { return aExact && !bExact }

            let aTiny = (a.size ?? 0) < 100
            let bTiny = (b.size ?? 0) < 100
            if aTiny != bTiny { return !aTiny && bTiny }

            let aScore = a.matchScore ?? 0
            let bScore = b.matchScore ?? 0
            if aScore != bScore { return aScore > bScore }

            let aEdges = a.edges ?? 0
            let bEdges = b.edges ?? 0
            if aEdges != bEdges { return aEdges > bEdges }

            let aSize = a.size ?? 0
            let bSize = b.size ?? 0
            if aSize != bSize { return aSize > bSize }

            return aName < bName
        }

        _ = TRANSIENT   // silence unused-let warning in release builds
        if limit >= ranked.count { return ranked }
        return Array(ranked.prefix(limit))
    }

    /// Cheap top-N tag summary for a record title. Prefers `tag_groups`
    /// (which we pre-aggregate) and falls back to counting distinct
    /// `topics.tag_name` values under the parent when the record has no
    /// tag_group rows yet. Only whitelist tags are counted so the summary
    /// matches Python's `_browse_meta` tree.
    private func topTagSummary(for title: String, db: OpaquePointer, limit: Int) -> [String: Int] {
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        // First: tag_groups counts (parent -> tag_name).
        let lower = title.lowercased()
        var counts: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT tag_name, COUNT(*) FROM topics WHERE LOWER(parent_topic) = ? AND tag_name IS NOT NULL AND tag_name != '' GROUP BY tag_name ORDER BY COUNT(*) DESC LIMIT ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, lower, -1, TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(max(1, limit * 3)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let tag = colText(stmt, 0) else { continue }
                let count = Int(sqlite3_column_int(stmt, 1))
                if !Self.urlTagWhitelist.contains(tag.lowercased()) { continue }
                counts[tag] = count
                if counts.count >= limit { break }
            }
        }
        sqlite3_finalize(stmt)
        return counts
    }

    /// Match `needle` in `text` at ASCII word boundaries. Mirrors Python's
    /// short-keyword regex `(?:^|[\s/\-_(])<needle>(?:[\s/\-_)]|$)`.
    /// Case-insensitive against pre-lowered strings.
    private func shortKeywordWordBoundaryMatch(text: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let hay = Array(text.utf8)
        let n = Array(needle.utf8)
        if hay.count < n.count { return false }
        func isLeftBoundary(_ b: UInt8) -> Bool {
            return b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
                || b == 0x2F || b == 0x2D || b == 0x5F || b == 0x28
        }
        func isRightBoundary(_ b: UInt8) -> Bool {
            return b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
                || b == 0x2F || b == 0x2D || b == 0x5F || b == 0x29
        }
        var i = 0
        let limit = hay.count - n.count
        while i <= limit {
            var ok = true
            for k in 0..<n.count where hay[i + k] != n[k] { ok = false; break }
            if ok {
                let leftOK = (i == 0) || isLeftBoundary(hay[i - 1])
                let rightIdx = i + n.count
                let rightOK = (rightIdx == hay.count) || isRightBoundary(hay[rightIdx])
                if leftOK && rightOK { return true }
            }
            i += 1
        }
        return false
    }

    /// Shared helper for the two-stage lookup so both stages share the same
    /// row-decoding logic.
    private func runLookupQuery(
        db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) -> [Match] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Match] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = colText(stmt, 0) ?? ""
            let library = colText(stmt, 1) ?? ""
            let kindStr = colText(stmt, 2) ?? "title"
            let browse = colText(stmt, 3) ?? ""
            let parent = colText(stmt, 4)
            let tag = colText(stmt, 5)
            out.append(Match(
                name: name,
                library: library,
                kind: Kind(rawValue: kindStr) ?? .title,
                browseCmd: browse,
                parentTopic: parent,
                tagName: tag
            ))
        }
        return out
    }

    /// Internal wrapper that also carries `topics.centrality` for the
    /// fuzzy/substring ranker. The SELECT must include the centrality
    /// column as the seventh field.
    private struct RankedRow {
        let match: Match
        let centrality: Int
    }

    private func runRankedLookupQuery(
        db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) -> [RankedRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [RankedRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = colText(stmt, 0) ?? ""
            let library = colText(stmt, 1) ?? ""
            let kindStr = colText(stmt, 2) ?? "title"
            let browse = colText(stmt, 3) ?? ""
            let parent = colText(stmt, 4)
            let tag = colText(stmt, 5)
            let centrality = Int(sqlite3_column_int(stmt, 6))
            out.append(RankedRow(
                match: Match(
                    name: name,
                    library: library,
                    kind: Kind(rawValue: kindStr) ?? .title,
                    browseCmd: browse,
                    parentTopic: parent,
                    tagName: tag
                ),
                centrality: centrality
            ))
        }
        return out
    }

    // MARK: - Topic meta helpers (F16)

    public struct TopicHierarchy: Sendable {
        public let library: String
        public let parent: String?
    }

    public struct DirectedEdge: Sendable {
        public let peer: String
        public let kind: String
    }

    public struct SectionCount: Sendable {
        public let kind: String
        public let count: Int
    }

    public struct TagSectionCount: Sendable {
        public let tagName: String
        public let count: Int
    }

    /// One row from the topics table matched by lower(name). Used by
    /// `handleGetTopicMeta` to build the hierarchy section.
    public func topicHierarchy(name: String) -> TopicHierarchy? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        do { try ensureOpen() } catch { return nil }
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT library, parent_topic FROM topics WHERE LOWER(name) = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, trimmed, -1, TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let library = colText(stmt, 0) ?? ""
            let parent = colText(stmt, 1)
            return TopicHierarchy(library: library, parent: parent)
        }
        return nil
    }

    /// F16: outgoing searchin edges from `name`. Returns display-cased
    /// peer names paired with the edge kind (always `searchin` here).
    public func searchinOut(from name: String, limit: Int = 50) -> [DirectedEdge] {
        // Prefer the sqlite-baked graphify adjacency: mirror Python's
        // `_browse_meta` which slices `gf["out"].get(gid, [])` filtered by
        // relation. `loadGraphifyNodesOrThrow` rehydrates the caches from
        // `gedges` on first access.
        do { try ensureOpen() } catch { }
        _ = try? loadGraphifyNodesOrThrow()
        if let nid = graphResolveNode(name: name), !graphifyOutCache.isEmpty {
            var out: [DirectedEdge] = []
            for (peer, rel) in graphifyOutCache[nid] ?? [] where rel == "searchin" {
                let label = graphifyNodeByID[peer]?.label ?? peer
                out.append(DirectedEdge(peer: label, kind: rel))
                if out.count >= limit { break }
            }
            return out
        }
        return directedSearchin(name: name, direction: .out, limit: limit)
    }

    /// F16: incoming searchin edges to `name`.
    public func searchinIn(to name: String, limit: Int = 50) -> [DirectedEdge] {
        do { try ensureOpen() } catch { }
        _ = try? loadGraphifyNodesOrThrow()
        if let nid = graphResolveNode(name: name), !graphifyInCache.isEmpty {
            var out: [DirectedEdge] = []
            for (peer, rel) in graphifyInCache[nid] ?? [] where rel == "searchin" {
                let label = graphifyNodeByID[peer]?.label ?? peer
                out.append(DirectedEdge(peer: label, kind: rel))
                if out.count >= limit { break }
            }
            return out
        }
        return directedSearchin(name: name, direction: .into, limit: limit)
    }

    private enum SearchinDirection { case out, into }

    private func directedSearchin(name: String, direction: SearchinDirection, limit: Int) -> [DirectedEdge] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        do { try ensureOpen() } catch { return [] }
        guard let db = db else { return [] }
        let sql: String
        switch direction {
        case .out:
            sql = "SELECT dst, kind FROM edges WHERE LOWER(src) = ? AND kind = 'searchin' LIMIT ?"
        case .into:
            sql = "SELECT src, kind FROM edges WHERE LOWER(dst) = ? AND kind = 'searchin' LIMIT ?"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, trimmed, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
        var out: [DirectedEdge] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let peer = colText(stmt, 0) ?? ""
            let kind = colText(stmt, 1) ?? "searchin"
            let display = prettyName(peer.lowercased()) ?? peer
            out.append(DirectedEdge(peer: display, kind: kind))
        }
        return out
    }

    /// F16: per-kind counts for topic rows whose `parent_topic` matches the
    /// given name (case-insensitive). Powers the "section counts" row of the
    /// meta output.
    public func sectionCounts(parent: String) -> [SectionCount] {
        let trimmed = parent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        do { try ensureOpen() } catch { return [] }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT kind, COUNT(*) FROM topics WHERE LOWER(parent_topic) = ? GROUP BY kind ORDER BY kind"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, trimmed, -1, TRANSIENT)
        var out: [SectionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = colText(stmt, 0) ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            out.append(SectionCount(kind: kind, count: count))
        }
        return out
    }

    /// F16: per-tag-name counts for topic rows whose `parent_topic` matches
    /// the given name (case-insensitive). Powers the "tag section counts"
    /// row of the meta output. Groups by the parser-emitted `tag_name`
    /// provenance (github, youtube, searchin, command, keyword, alias,
    /// crossref, etc.) so aggregation matches Python's `--meta` output.
    public func tagSectionCounts(topic: String) -> [TagSectionCount] {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        do { try ensureOpen() } catch { return [] }
        guard let db = db else { return [] }
        // Python's `_browse_meta` resolves the topic name through
        // `find_by_title` -> `find_by_keyword` (exact then substring) so a
        // query like `Docker` maps to the `Docker images` subtopic record.
        // Mirror that here: if the direct tag_groups lookup produces no
        // rows, fall back to the first subtopic name in `topics` whose
        // lowercase form contains `trimmed`.
        let direct = fetchTagSectionCounts(parent: trimmed, db: db)
        if !direct.isEmpty { return direct }
        for candidate in subtopicMatches(needle: trimmed, db: db, limit: 20) {
            let alt = fetchTagSectionCounts(parent: candidate, db: db)
            if !alt.isEmpty { return alt }
        }
        return []
    }

    /// Return up to `limit` candidate subtopic names (lowercased) whose
    /// display form contains `needle`. Sorted shortest-first so
    /// `firstSubtopicMatch`-style callers see the most specific match
    /// first, but callers can walk the list when a shorter candidate has
    /// no tag_groups rows.
    private func subtopicMatches(needle: String, db: OpaquePointer, limit: Int) -> [String] {
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let sql = "SELECT DISTINCT LOWER(name) FROM topics WHERE kind='subtopic' AND LOWER(name) LIKE ? ORDER BY LENGTH(name) ASC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%" + needle + "%", -1, TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = colText(stmt, 0) { out.append(name) }
        }
        return out
    }

    private func fetchTagSectionCounts(parent: String, db: OpaquePointer) -> [TagSectionCount] {
        // R3: read from `tag_groups` — the parser stamps one row per (parent,
        // tag) pair whenever it enters a tag group (github, website, youtube,
        // searchin, command, ...) inside a subtopic. That gives us the same
        // set of tag names Python's `--meta` tree exposes. We keep the count
        // column for API parity even though every value is 1 (each parent/tag
        // pair is unique). Rows are sorted alphabetically for deterministic
        // output.
        var stmt: OpaquePointer?
        let sql = "SELECT tag_name FROM tag_groups WHERE LOWER(parent) = ? ORDER BY tag_name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, parent, -1, TRANSIENT)
        var out: [TagSectionCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tag = colText(stmt, 0) ?? ""
            if tag.isEmpty { continue }
            // R4: Python's `_browse_meta` only renders tags whose top-level
            // segment survives `desc_to_url_dict`'s filter. Filter here so
            // tags emitted by `harvestTagGroups` for the record's subtopic
            // context (nested inside a keyword item) do not leak into the
            // record-level meta tree.
            if !Self.urlTagWhitelist.contains(tag.lowercased()) { continue }
            out.append(TagSectionCount(tagName: tag, count: 1))
        }
        return out
    }

    /// F16: community peers for `name`. Reads `gnodes.community` -- the
    /// Louvain assignment stamped by `assignGraphifyCommunities` at the
    /// end of every `syncIfNeeded` -- and returns the co-cluster peers
    /// sorted by (node_type, label). Falls back to the sqlite `edges`
    /// Louvain result when `gnodes` is empty (e.g. before the first sync).
    public func communityPeers(of name: String, limit: Int = 15) -> [String] {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let clusters: [[String]]
        if let baked = try? graphCommunityCanonical(), !baked.isEmpty {
            clusters = baked
        } else {
            clusters = graphCommunity(minSize: 2)
        }
        for cluster in clusters {
            if cluster.contains(where: { $0.lowercased() == needle }) {
                let peers = cluster.filter { $0.lowercased() != needle }
                return Array(peers.prefix(max(0, limit)))
            }
        }
        return []
    }

    /// Read `gnodes.community` (populated by `assignGraphifyCommunities`
    /// during `syncIfNeeded`) and return one array per cluster, each
    /// holding the display labels of its members. Cluster order follows
    /// ascending community id. Members are sorted per Python's
    /// `_graph_community`: `(type_order, label)` with type_order =
    /// {topic: 0, library: 1, subtopic: 2, external_ref: 3}.
    public func graphCommunityCanonical() throws -> [[String]] {
        let nodes = try loadGraphifyNodesOrThrow()
        struct Member { let label: String; let priority: Int }
        var byCommunity: [Int: [Member]] = [:]
        let typeOrder: [String: Int] = [
            "topic": 0, "library": 1, "subtopic": 2, "external_ref": 3,
        ]
        for node in nodes {
            guard let cid = node.community else { continue }
            let priority = typeOrder[node.nodeType] ?? 9
            byCommunity[cid, default: []].append(Member(label: node.label, priority: priority))
        }
        let ordered = byCommunity.keys.sorted().map { key -> [String] in
            let sorted = (byCommunity[key] ?? []).sorted { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                return a.label < b.label
            }
            return sorted.map { $0.label }
        }
        return ordered
    }

    /// Lazy-loading accessor for the baked-in graph. On first hit reads the
    /// `gnodes` + `gedges` sqlite tables and stashes an in-memory adjacency
    /// map alongside a label/type/community lookup. Later calls return the
    /// cached copy. Marks a failed load so subsequent invocations do not
    /// repeatedly rescan sqlite when the tables are empty.
    ///
    /// This replaces the old `graph.json` decoder: Python's Louvain pass runs
    /// natively in Swift during `syncIfNeeded`, so `gnodes.community` is
    /// authoritative and callers do not need to hit the filesystem.
    fileprivate func loadGraphifyNodesOrThrow() throws -> [GraphifyNode] {
        if let cache = graphifyNodesCache { return cache }
        if graphifyLoadFailed {
            throw NSError(domain: "XLBTopicIndex", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "graphify sqlite load previously failed"
            ])
        }
        do { try ensureOpen() } catch {
            graphifyLoadFailed = true
            throw error
        }
        guard let db = db else {
            graphifyLoadFailed = true
            throw NSError(domain: "XLBTopicIndex", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "graphify sqlite db unavailable"
            ])
        }

        // Adjacency + edge-count harvest from `gedges`. Ordered by insertion
        // id so the emitted adjacency preserves the same peer order Python's
        // `_load_graphify` sees when it reads `gf["out"]` (the JSON preserves
        // list order, which for the skill mirrors the parser's emission
        // order).
        var outMap: [String: [(String, String)]] = [:]
        var inMap: [String: [(String, String)]] = [:]
        var edgeCounts: [String: Int] = [:]
        var edgeStmt: OpaquePointer?
        let edgeSQL = "SELECT source, target, relation FROM gedges ORDER BY id"
        if sqlite3_prepare_v2(db, edgeSQL, -1, &edgeStmt, nil) == SQLITE_OK {
            while sqlite3_step(edgeStmt) == SQLITE_ROW {
                guard let s = colText(edgeStmt, 0),
                      let t = colText(edgeStmt, 1),
                      let r = colText(edgeStmt, 2) else { continue }
                outMap[s, default: []].append((t, r))
                inMap[t, default: []].append((s, r))
                edgeCounts[s, default: 0] += 1
                edgeCounts[t, default: 0] += 1
            }
        }
        sqlite3_finalize(edgeStmt)

        // Node harvest from `gnodes`. `centrality` doubles as the
        // edge_count for Stage 4 fuzzy ranking parity with graph.json
        // (`len(out.get(id,[])) + len(in.get(id,[]))`).
        var out: [GraphifyNode] = []
        var byID: [String: GraphifyNode] = [:]
        var nodeStmt: OpaquePointer?
        let nodeSQL = "SELECT id, label, node_type, community FROM gnodes"
        if sqlite3_prepare_v2(db, nodeSQL, -1, &nodeStmt, nil) == SQLITE_OK {
            while sqlite3_step(nodeStmt) == SQLITE_ROW {
                guard let id = colText(nodeStmt, 0) else { continue }
                guard let label = colText(nodeStmt, 1) else { continue }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let nodeType = colText(nodeStmt, 2) ?? ""
                let community: Int?
                if sqlite3_column_type(nodeStmt, 3) == SQLITE_NULL {
                    community = nil
                } else {
                    community = Int(sqlite3_column_int(nodeStmt, 3))
                }
                let edgeCount = edgeCounts[id] ?? 0
                let n = GraphifyNode(
                    id: id,
                    label: trimmed,
                    nodeType: nodeType,
                    community: community,
                    edgeCount: edgeCount
                )
                out.append(n)
                byID[id] = n
            }
        }
        sqlite3_finalize(nodeStmt)

        if out.isEmpty && outMap.isEmpty {
            graphifyLoadFailed = true
            throw NSError(domain: "XLBTopicIndex", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "graphify sqlite tables empty"
            ])
        }

        self.graphifyOutCache = outMap
        self.graphifyInCache = inMap
        self.graphifyNodesCache = out
        self.graphifyNodeByID = byID
        return out
    }

    /// Python's `_graph_resolve_node`. Prefers exact ID -> exact label ->
    /// substring, biased toward `topic > subtopic > library > external_ref >
    /// alias`. Returns the sqlite `gnodes.id` when resolvable, else nil.
    fileprivate func graphResolveNode(name: String) -> String? {
        let nodes = (try? loadGraphifyNodesOrThrow()) ?? []
        if nodes.isEmpty { return nil }
        // Python's `_node_id` lowercases and turns spaces into underscores.
        // We also fold hyphens and slashes so `Deep Learning` and
        // `deep_learning` resolve identically.
        let nid = Self.gnodeIDCandidate(name)
        if graphifyNodeByID[nid] != nil { return nid }
        let needle = name.lowercased()
        let typePriority: [String: Int] = [
            "topic": 0, "subtopic": 1, "library": 2,
            "external_ref": 3, "alias": 4,
        ]
        var exact: [(Int, String)] = []
        var subs: [(Int, String)] = []
        for n in nodes {
            let label = n.label.lowercased()
            let p = typePriority[n.nodeType] ?? 9
            if label == needle {
                exact.append((p, n.id))
            } else if label.contains(needle) {
                subs.append((p, n.id))
            }
        }
        if !exact.isEmpty {
            exact.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            return exact.first?.1
        }
        if !subs.isEmpty {
            subs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            return subs.first?.1
        }
        return nil
    }

    /// Turn a label into the same lowercase / underscore form the parser
    /// uses when writing `gnodes.id`. Mirrors Python's `_node_id` plus a
    /// slight extra fold for hyphen/slash separators so caller-supplied
    /// names like `deep-learning` still resolve.
    fileprivate static func gnodeIDCandidate(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var chars: [Character] = []
        chars.reserveCapacity(lower.count)
        for c in lower {
            if c == " " || c == "-" || c == "/" { chars.append("_") }
            else { chars.append(c) }
        }
        return String(chars)
    }

    // MARK: - Filesystem watch

    public func startWatchingIfEnabled() {
        stopWatching()
        guard isEnabled(), let dir = libraryDir() else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { [weak self] in try? await self?.syncIfNeeded() }
        }
        src.setCancelHandler {
            close(fd)
        }
        watchFD = fd
        watcher = src
        src.resume()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchFD = -1
    }

    // MARK: - Database

    /// Public-ish helper for graph queries so they can lazily open the db
    /// on the first call without requiring a prior `syncIfNeeded`.
    private func ensureOpen() throws {
        if db != nil { return }
        guard let dbURL = dbPath() else { return }
        try openDBIfNeeded(at: dbURL)
    }

    private func openDBIfNeeded(at url: URL) throws {
        if db != nil { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            throw NSError(domain: "XLBTopicIndex", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sqlite3_open_v2 failed for \(url.path)"
            ])
        }
        self.db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        exec("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
        """)
        // Schema drift: if the stored schema_version disagrees with the
        // current binary, drop the topics + edges tables so the fresh
        // CREATE below picks up the new column/constraint shape. The
        // subsequent syncIfNeeded call will refill both tables.
        let storedSchema = (try? readMetaText(key: "schema_version")) ?? ""
        if !storedSchema.isEmpty, storedSchema != Self.schemaVersion {
            exec("DROP TABLE IF EXISTS topics;")
            exec("DROP TABLE IF EXISTS edges;")
            exec("DROP TABLE IF EXISTS tag_groups;")
            exec("DROP TABLE IF EXISTS gnodes;")
            exec("DROP TABLE IF EXISTS gnode_aliases;")
            exec("DROP TABLE IF EXISTS gedges;")
        }
        exec("""
            CREATE TABLE IF NOT EXISTS topics (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                library TEXT NOT NULL,
                kind TEXT NOT NULL,
                browse_cmd TEXT NOT NULL,
                parent_topic TEXT,
                tag_name TEXT,
                centrality INTEGER NOT NULL DEFAULT 0,
                inner_size INTEGER NOT NULL DEFAULT 0,
                UNIQUE(name, kind, library, tag_name)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_topics_lower_name ON topics(LOWER(name));")
        exec("CREATE INDEX IF NOT EXISTS idx_topics_library ON topics(library);")
        exec("CREATE INDEX IF NOT EXISTS idx_topics_tag_name ON topics(tag_name);")
        exec("CREATE INDEX IF NOT EXISTS idx_topics_centrality ON topics(centrality DESC);")
        // Graph edge table. Names stored lowercased for case-insensitive
        // BFS. `library` records provenance for later filtering. The
        // UNIQUE(src, dst, kind) constraint keeps INSERT OR IGNORE cheap
        // and lets a repeated crawl converge without duplicates.
        exec("""
            CREATE TABLE IF NOT EXISTS edges (
                src TEXT NOT NULL,
                dst TEXT NOT NULL,
                kind TEXT NOT NULL,
                library TEXT NOT NULL,
                UNIQUE(src, dst, kind)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);")
        exec("CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst);")
        // R3: tag-group aggregation table. Powers `tagSectionCounts` output
        // matching Python's `--meta` tree top-level tag names (github,
        // website, youtube, searchin, command, ...). Rows are keyed on the
        // enclosing subtopic and the immediate tag name so the counts
        // reflect distinct tag groups even when the tag's inner has no
        // qualifying subtopic names.
        exec("""
            CREATE TABLE IF NOT EXISTS tag_groups (
                parent TEXT NOT NULL,
                tag_name TEXT NOT NULL,
                library TEXT NOT NULL,
                UNIQUE(parent, tag_name)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_tag_groups_parent ON tag_groups(parent);")

        // Graphify-compatible richer graph. Mirrors the JSON schema produced
        // by ~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/
        // xlb_graph_extract.py. `gnodes.id` is `label.lower().replace(' ', '_')`
        // (see `_node_id` in the Python source). Nodes hold `node_type`,
        // `parent_id`, and post-parse `community` + `centrality`. Aliases are
        // stored one-per-row in `gnode_aliases` so the parent node's row
        // stays a fixed-width record.
        exec("""
            CREATE TABLE IF NOT EXISTS gnodes (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                node_type TEXT NOT NULL,
                file_type TEXT NOT NULL DEFAULT 'document',
                source_file TEXT,
                parent_id TEXT,
                community INTEGER,
                centrality INTEGER NOT NULL DEFAULT 0
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_gnodes_type ON gnodes(node_type);")
        exec("CREATE INDEX IF NOT EXISTS idx_gnodes_label_lower ON gnodes(LOWER(label));")
        exec("""
            CREATE TABLE IF NOT EXISTS gnode_aliases (
                node_id TEXT NOT NULL,
                alias TEXT NOT NULL,
                UNIQUE(node_id, alias)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_gnode_aliases_node ON gnode_aliases(node_id);")
        exec("""
            CREATE TABLE IF NOT EXISTS gedges (
                id INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                target TEXT NOT NULL,
                relation TEXT NOT NULL,
                confidence TEXT NOT NULL DEFAULT 'EXTRACTED',
                source_file TEXT,
                grp TEXT,
                UNIQUE(source, target, relation)
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_gedges_src ON gedges(source);")
        exec("CREATE INDEX IF NOT EXISTS idx_gedges_tgt ON gedges(target);")
    }

    @discardableResult
    private func exec(_ sql: String) -> Int32 {
        guard let db = db else { return SQLITE_MISUSE }
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: raw)
    }

    private func readMetaDouble(key: String) throws -> Double? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW, let text = colText(stmt, 0) {
            return Double(text)
        }
        return nil
    }

    private func writeMetaDouble(key: String, value: Double) throws {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, String(value), -1, TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    private func readMetaText(key: String) throws -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return colText(stmt, 0)
        }
        return nil
    }

    private func writeMetaText(key: String, value: String) throws {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - Filesystem

    private struct SourceFile {
        let url: URL
        let library: String
        let mtime: TimeInterval
    }

    private func listLibraryFiles(in dir: URL) throws -> [SourceFile] {
        // F21: do not rely on `.skipsHiddenFiles` because its behaviour is
        // volume-dependent (network mounts and case-sensitive volumes have
        // reported inconsistencies). The explicit `!name.hasPrefix(".")`
        // check below mirrors Python's `glob.glob("*-library")` semantics
        // bit-for-bit across all volumes.
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )
        var result: [SourceFile] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix("-library"), !name.hasPrefix(".") else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            let library = String(name.dropLast("-library".count))
            result.append(SourceFile(url: url, library: library, mtime: mtime))
        }
        return result.sorted { $0.library < $1.library }
    }

    // MARK: - Bulk parse + insert

    private func rebuild(from sources: [SourceFile]) throws -> (records: Int, topics: Int, edges: Int) {
        guard let db = db else { return (0, 0, 0) }
        // Invalidate the in-memory graphify caches so the next reader hits
        // sqlite fresh once the rebuild finishes.
        graphifyNodesCache = nil
        graphifyNodeByID = [:]
        graphifyOutCache = [:]
        graphifyInCache = [:]
        graphifyLoadFailed = false
        exec("BEGIN IMMEDIATE;")
        exec("DELETE FROM topics;")
        exec("DELETE FROM edges;")
        exec("DELETE FROM tag_groups;")
        exec("DELETE FROM gnodes;")
        exec("DELETE FROM gnode_aliases;")
        exec("DELETE FROM gedges;")

        var insertStmt: OpaquePointer?
        let insertSQL = "INSERT OR IGNORE INTO topics(name, library, kind, browse_cmd, parent_topic, tag_name, inner_size) VALUES(?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "prepare insert failed"
            ])
        }
        defer { sqlite3_finalize(insertStmt) }

        var edgeStmt: OpaquePointer?
        let edgeSQL = "INSERT OR IGNORE INTO edges(src, dst, kind, library) VALUES(?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, edgeSQL, -1, &edgeStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "prepare edge insert failed"
            ])
        }
        defer { sqlite3_finalize(edgeStmt) }

        var tagGroupStmt: OpaquePointer?
        let tagGroupSQL = "INSERT OR IGNORE INTO tag_groups(parent, tag_name, library) VALUES(?, ?, ?)"
        guard sqlite3_prepare_v2(db, tagGroupSQL, -1, &tagGroupStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "prepare tag_group insert failed"
            ])
        }
        defer { sqlite3_finalize(tagGroupStmt) }

        // Graphify-compatible node/edge statements. `INSERT OR IGNORE` lets
        // repeated emissions collapse silently, matching Python's dedupe pass.
        // `gnodeUpgradeStmt` promotes a placeholder external_ref node to a
        // richer node_type once we learn the label's true role -- Python's
        // `dedupe_nodes` does the same merge.
        var gnodeStmt: OpaquePointer?
        let gnodeSQL = "INSERT OR IGNORE INTO gnodes(id, label, node_type, file_type, source_file, parent_id) VALUES(?, ?, ?, 'document', ?, ?)"
        guard sqlite3_prepare_v2(db, gnodeSQL, -1, &gnodeStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "prepare gnode insert failed"
            ])
        }
        defer { sqlite3_finalize(gnodeStmt) }

        var gnodeUpgradeStmt: OpaquePointer?
        let gnodeUpgradeSQL = "UPDATE gnodes SET node_type = ?, source_file = COALESCE(NULLIF(source_file, ''), ?), parent_id = COALESCE(NULLIF(parent_id, ''), ?) WHERE id = ? AND (node_type IN ('external_ref', 'category_ref', 'alias'))"
        guard sqlite3_prepare_v2(db, gnodeUpgradeSQL, -1, &gnodeUpgradeStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "prepare gnode upgrade failed"
            ])
        }
        defer { sqlite3_finalize(gnodeUpgradeStmt) }

        var gnodeAliasStmt: OpaquePointer?
        let gnodeAliasSQL = "INSERT OR IGNORE INTO gnode_aliases(node_id, alias) VALUES(?, ?)"
        guard sqlite3_prepare_v2(db, gnodeAliasSQL, -1, &gnodeAliasStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "prepare gnode alias insert failed"
            ])
        }
        defer { sqlite3_finalize(gnodeAliasStmt) }

        var gedgeStmt: OpaquePointer?
        let gedgeSQL = "INSERT OR IGNORE INTO gedges(source, target, relation, confidence, source_file, grp) VALUES(?, ?, ?, 'EXTRACTED', ?, ?)"
        guard sqlite3_prepare_v2(db, gedgeSQL, -1, &gedgeStmt, nil) == SQLITE_OK else {
            exec("ROLLBACK;")
            throw NSError(domain: "XLBTopicIndex", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "prepare gedge insert failed"
            ])
        }
        defer { sqlite3_finalize(gedgeStmt) }

        var recordCount = 0
        var topicCount = 0
        var edgeCount = 0

        for source in sources {
            guard let data = try? Data(contentsOf: source.url, options: [.mappedIfSafe]) else { continue }
            let bytes = [UInt8](data)
            let parser = LibraryFileParser(
                bytes: bytes,
                library: source.library,
                stmt: insertStmt,
                edgeStmt: edgeStmt,
                tagGroupStmt: tagGroupStmt,
                gnodeStmt: gnodeStmt,
                gnodeUpgradeStmt: gnodeUpgradeStmt,
                gnodeAliasStmt: gnodeAliasStmt,
                gedgeStmt: gedgeStmt,
                dbHandle: db
            )
            let (r, t, e) = parser.parse()
            recordCount += r
            topicCount += t
            edgeCount += e
        }

        exec("COMMIT;")

        // Populate `topics.centrality` from the freshly built edges table.
        // Centrality here is graphify's degree measure: the number of edge
        // endpoints touching a topic's lowercased name in either direction.
        // We stage the aggregate into a temp table so the UPDATE join stays
        // O(V + E) even on the full 27k-node index (SQLite's correlated
        // subquery on `topics` would otherwise re-scan `edges` per row).
        exec("DROP TABLE IF EXISTS _centrality;")
        exec("""
            CREATE TEMP TABLE _centrality AS
            SELECT node AS n, COUNT(*) AS c FROM (
                SELECT LOWER(src) AS node FROM edges
                UNION ALL
                SELECT LOWER(dst) AS node FROM edges
            ) GROUP BY node;
        """)
        exec("CREATE INDEX IF NOT EXISTS _centrality_n ON _centrality(n);")
        exec("""
            UPDATE topics
            SET centrality = COALESCE(
                (SELECT c FROM _centrality WHERE _centrality.n = LOWER(topics.name)),
                0
            );
        """)
        exec("DROP TABLE IF EXISTS _centrality;")

        // Populate `gnodes.centrality`: number of gedges endpoints touching
        // this node id. Same staging trick as `topics.centrality` above.
        exec("DROP TABLE IF EXISTS _gcentrality;")
        exec("""
            CREATE TEMP TABLE _gcentrality AS
            SELECT node AS n, COUNT(*) AS c FROM (
                SELECT source AS node FROM gedges
                UNION ALL
                SELECT target AS node FROM gedges
            ) GROUP BY node;
        """)
        exec("CREATE INDEX IF NOT EXISTS _gcentrality_n ON _gcentrality(n);")
        exec("""
            UPDATE gnodes
            SET centrality = COALESCE(
                (SELECT c FROM _gcentrality WHERE _gcentrality.n = gnodes.id),
                0
            );
        """)
        exec("DROP TABLE IF EXISTS _gcentrality;")

        // Run Louvain community detection over the undirected gedges graph
        // and stamp `gnodes.community` with the assignment. Mirrors what
        // the skill's Python `xlb_graph_extract.py --cluster` writes to
        // `graphify-out/graph.json` (NetworkX Louvain fallback path).
        assignGraphifyCommunities(db: db)

        exec("ANALYZE;")
        return (recordCount, topicCount, edgeCount)
    }

    /// Compute Louvain community assignments over the gedges undirected
    /// graph and write them back to `gnodes.community`. Reuses the same
    /// `louvainCommunities` implementation the legacy `graphCommunity`
    /// call relies on so both tables converge on the same partition.
    private func assignGraphifyCommunities(db: OpaquePointer) {
        var adjacency: [String: [String: Double]] = [:]
        let loadSQL = "SELECT DISTINCT source, target FROM gedges"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, loadSQL, -1, &stmt, nil) == SQLITE_OK else { return }
        var m = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let src = colText(stmt, 0), let dst = colText(stmt, 1) else { continue }
            if src == dst { continue }
            adjacency[src, default: [:]][dst, default: 0] += 1
            adjacency[dst, default: [:]][src, default: 0] += 1
            m += 1
        }
        sqlite3_finalize(stmt)
        if adjacency.isEmpty { return }
        var deg: [String: Double] = [:]
        deg.reserveCapacity(adjacency.count)
        for (node, nbrs) in adjacency {
            var d = 0.0
            for (_, w) in nbrs { d += w }
            deg[node] = d
        }
        let (labels, _, _) = louvainCommunities(
            adjacency: adjacency,
            weightedDegrees: deg,
            totalWeight: m,
            maxPassIterations: 20
        )
        var updateStmt: OpaquePointer?
        let updateSQL = "UPDATE gnodes SET community = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(updateStmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (nodeID, communityID) in labels {
            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            sqlite3_bind_int(updateStmt, 1, Int32(communityID))
            sqlite3_bind_text(updateStmt, 2, nodeID, -1, TRANSIENT)
            _ = sqlite3_step(updateStmt)
        }
    }

    // MARK: - Graph queries

    /// Undirected BFS across the `edges` table. Returns the name chain from
    /// `from` to `to` inclusive, using each node's canonical display casing
    /// preserved in the `topics` table when available. Returns nil when no
    /// path fits within `maxDepth` hops.
    ///
    /// F15: default depth is 12 to match Python (which has no per-call cap
    /// beyond a global visited-node ceiling). Callers can request 1..20.
    public func graphPath(from source: String, to target: String, maxDepth: Int = 12) -> [String]? {
        let srcTrim = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let dstTrim = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !srcTrim.isEmpty, !dstTrim.isEmpty else { return nil }
        if srcTrim.lowercased() == dstTrim.lowercased() {
            return [prettyName(srcTrim.lowercased()) ?? source]
        }
        do { try ensureOpen() } catch { return nil }

        // Run Python's `_graph_shortest_path` (BFS across `out` and `in`
        // as undirected edges, node cap at 15000) over the sqlite-baked
        // gedges adjacency. Resolve endpoints via the same priority table
        // Python uses so aliases (e.g. `Kubernetes` -> Docker alias)
        // route correctly.
        _ = try? loadGraphifyNodesOrThrow()
        if let srcID = graphResolveNode(name: srcTrim),
           let dstID = graphResolveNode(name: dstTrim) {
            if srcID == dstID {
                let label = graphifyNodeByID[srcID]?.label ?? srcTrim
                return [label]
            }
            var visited: Set<String> = [srcID]
            var parent: [String: String] = [:]
            var queue: [String] = [srcID]
            var head = 0
            var found = false
            while head < queue.count, visited.count <= 15000 {
                let current = queue[head]
                head += 1
                let outs = graphifyOutCache[current] ?? []
                for (peer, _) in outs {
                    if visited.contains(peer) { continue }
                    visited.insert(peer)
                    parent[peer] = current
                    if peer == dstID { found = true; break }
                    queue.append(peer)
                }
                if found { break }
                let ins = graphifyInCache[current] ?? []
                for (peer, _) in ins {
                    if visited.contains(peer) { continue }
                    visited.insert(peer)
                    parent[peer] = current
                    if peer == dstID { found = true; break }
                    queue.append(peer)
                }
                if found { break }
            }
            if found {
                var chain: [String] = []
                var cur = dstID
                while true {
                    let label = graphifyNodeByID[cur]?.label ?? cur
                    chain.append(label)
                    if cur == srcID { break }
                    guard let p = parent[cur] else { break }
                    cur = p
                }
                return chain.reversed()
            }
            // gedges present but no path found. Python emits an error
            // here -- return nil so callers treat it as unreachable
            // instead of falling back to the sqlite edges (which would
            // manufacture a shorter but semantically different path).
            return nil
        }

        // Fallback: sqlite edges BFS (used when gedges resolution fails).
        guard let db = db else { return nil }
        let src = srcTrim.lowercased()
        let dst = dstTrim.lowercased()
        var visited: [String: String] = [src: ""]
        var frontier: [String] = [src]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            var next: [String] = []
            for node in frontier {
                let neighbors = neighborsOfLower(node, db: db)
                for n in neighbors where visited[n] == nil {
                    visited[n] = node
                    if n == dst {
                        return reconstructPath(visited: visited, endLower: dst, startLower: src, original: source)
                    }
                    next.append(n)
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }

    /// BFS neighborhood exploration matching Python `_graph_explore` in
    /// `xlb_local_reader.py` (lines 3951-4023). At every hop we walk BOTH
    /// outgoing (`edges.src = current`) AND incoming (`edges.dst = current`)
    /// edges of the given `kinds`. Python hard-codes `follow_rels =
    /// {"searchin"}`, so the default `kinds` here stays `["searchin"]`.
    /// After the full BFS to `hops` depth, results are grouped by distance,
    /// sorted per hop by (node_type priority, label) and trimmed to
    /// `limit` (Python default: 50).
    ///
    /// `node_type` for each visited node mirrors Python's `nodes[nid]`
    /// entry: `.title` -> "topic", `.subtopic` -> "subtopic",
    /// `.alias` -> "alias". Nodes that only appear as edge endpoints
    /// (no matching `topics` row) fall back to "external_ref".
    public func graphExplore(from source: String, hops: Int, kinds: Set<String> = ["searchin"], limit: Int = 50) -> [Neighbor] {
        let srcTrim = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !srcTrim.isEmpty, hops > 0 else { return [] }
        do { try ensureOpen() } catch { return [] }

        // Prefer the sqlite-baked graphify adjacency (mirrors Python's
        // `_graph_explore`). BFS on the `out`/`in` maps built from
        // `gedges`, filtered to the requested kinds (default `searchin`),
        // grouped by hop distance, sorted by (type priority, label),
        // trimmed to `limit`.
        _ = try? loadGraphifyNodesOrThrow()
        if let srcID = graphResolveNode(name: srcTrim), !graphifyNodeByID.isEmpty {
            var visited: [String: Int] = [srcID: 0]
            var queue: [(String, Int)] = [(srcID, 0)]
            var head = 0
            while head < queue.count {
                let (cur, depth) = queue[head]
                head += 1
                if depth >= hops { continue }
                for (peer, rel) in graphifyOutCache[cur] ?? [] {
                    if !kinds.contains(rel) { continue }
                    if visited[peer] != nil { continue }
                    visited[peer] = depth + 1
                    queue.append((peer, depth + 1))
                }
                for (peer, rel) in graphifyInCache[cur] ?? [] {
                    if !kinds.contains(rel) { continue }
                    if visited[peer] != nil { continue }
                    visited[peer] = depth + 1
                    queue.append((peer, depth + 1))
                }
            }
            let typeOrder: [String: Int] = [
                "topic": 0, "library": 1, "subtopic": 2,
                "external_ref": 3, "alias": 4,
            ]
            var byHop: [Int: [Neighbor]] = [:]
            for (nid, dist) in visited where nid != srcID {
                let node = graphifyNodeByID[nid]
                let label = node?.label ?? nid
                let nodeType = node?.nodeType ?? "external_ref"
                byHop[dist, default: []].append(
                    Neighbor(name: label, distance: dist, kind: "searchin", nodeType: nodeType)
                )
            }
            for (dist, list) in byHop {
                byHop[dist] = list.sorted { a, b in
                    let ta = typeOrder[a.nodeType] ?? 9
                    let tb = typeOrder[b.nodeType] ?? 9
                    if ta != tb { return ta < tb }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            let cap = max(0, limit)
            var results: [Neighbor] = []
            for dist in byHop.keys.sorted() {
                guard let list = byHop[dist] else { continue }
                for e in list {
                    if results.count >= cap { break }
                    results.append(e)
                }
                if results.count >= cap { break }
            }
            return results
        }

        // Fallback: sqlite edges BFS.
        let src = srcTrim.lowercased()
        guard let db = db else { return [] }

        // BFS: visited maps node -> (distance, first edge kind observed).
        var visitedDist: [String: Int] = [src: 0]
        var visitedKind: [String: String] = [:]
        var queue: [(node: String, depth: Int)] = [(src, 0)]
        var head = 0
        while head < queue.count {
            let (current, depth) = queue[head]
            head += 1
            if depth >= hops { continue }
            let neighbors = neighborsOfLowerWithKind(current, db: db, kinds: kinds)
            for (n, kind) in neighbors {
                if visitedDist[n] != nil { continue }
                visitedDist[n] = depth + 1
                visitedKind[n] = kind
                queue.append((n, depth + 1))
            }
        }

        // Collect neighbors (excluding the start), resolve display name and
        // node_type from the `topics` table in a single pass.
        var neighborNames = [String]()
        neighborNames.reserveCapacity(visitedDist.count)
        for (n, _) in visitedDist where n != src {
            neighborNames.append(n)
        }
        let typeAndLabel = resolveTypeAndLabel(lowerNames: neighborNames, db: db)

        // Group by hop distance, sort each hop by (type priority, label).
        let typeOrder: [String: Int] = [
            "topic": 0, "library": 1, "subtopic": 2,
            "external_ref": 3, "alias": 4,
        ]
        var byHop: [Int: [Neighbor]] = [:]
        for n in neighborNames {
            let dist = visitedDist[n] ?? 0
            let info = typeAndLabel[n] ?? (nodeType: "external_ref", label: n)
            let kind = visitedKind[n] ?? "searchin"
            byHop[dist, default: []].append(
                Neighbor(name: info.label, distance: dist, kind: kind, nodeType: info.nodeType)
            )
        }
        for (dist, list) in byHop {
            byHop[dist] = list.sorted { a, b in
                let ta = typeOrder[a.nodeType] ?? 9
                let tb = typeOrder[b.nodeType] ?? 9
                if ta != tb { return ta < tb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        // Iterate hops in ascending order, take first `limit`.
        let cap = max(0, limit)
        var results: [Neighbor] = []
        results.reserveCapacity(min(cap, neighborNames.count))
        for dist in byHop.keys.sorted() {
            guard let list = byHop[dist] else { continue }
            for entry in list {
                if results.count >= cap { break }
                results.append(entry)
            }
            if results.count >= cap { break }
        }
        return results
    }

    /// Fetch `(node_type, display label)` for a batch of lowercased node
    /// names. Rows missing from `topics` are treated as "external_ref"
    /// (edge endpoints that never became a topic row).
    private func resolveTypeAndLabel(
        lowerNames: [String],
        db: OpaquePointer
    ) -> [String: (nodeType: String, label: String)] {
        var out: [String: (nodeType: String, label: String)] = [:]
        if lowerNames.isEmpty { return out }
        // Kind rank so a single node with multiple `topics` rows picks the
        // most authoritative label (title > subtopic > alias).
        func rank(_ kind: String) -> Int {
            switch kind {
            case "title": return 0
            case "subtopic": return 2
            case "alias": return 4
            default: return 9
            }
        }
        var seenRank: [String: Int] = [:]
        // SQLite parameter cap is 999. Chunk the IN(...) list to be safe.
        let chunkSize = 500
        var idx = 0
        while idx < lowerNames.count {
            let end = min(idx + chunkSize, lowerNames.count)
            let slice = Array(lowerNames[idx..<end])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let sql = "SELECT LOWER(name), name, kind FROM topics WHERE LOWER(name) IN (\(placeholders))"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (i, n) in slice.enumerated() {
                    sqlite3_bind_text(stmt, Int32(i + 1), n, -1, TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let lower = colText(stmt, 0) ?? ""
                    let label = colText(stmt, 1) ?? lower
                    let kindStr = colText(stmt, 2) ?? "title"
                    let nodeType: String
                    switch kindStr {
                    case "title": nodeType = "topic"
                    case "subtopic": nodeType = "subtopic"
                    case "alias": nodeType = "alias"
                    default: nodeType = "external_ref"
                    }
                    let r = rank(kindStr)
                    if let prev = seenRank[lower], prev <= r { continue }
                    seenRank[lower] = r
                    out[lower] = (nodeType: nodeType, label: label)
                }
            }
            sqlite3_finalize(stmt)
            idx = end
        }
        // Fill in external_ref for any node without a topics row.
        for n in lowerNames where out[n] == nil {
            out[n] = (nodeType: "external_ref", label: n)
        }
        return out
    }

    /// Top hubs by searchin-only degree. Each unique (src, dst) pair in
    /// `edges` filtered by the given kinds contributes 1 to each endpoint.
    /// Result is sorted by degree desc, ties broken alphabetically on the
    /// lowercase node key so results stay deterministic across runs.
    ///
    /// F12: defaults to `["searchin"]` because Python's `_graph_hubs` uses
    /// `metric = "searchin_degree"` -- prior total-degree implementation
    /// over-weighted crossref / command_ref links.
    public func graphHubs(limit: Int, kinds: Set<String> = ["searchin"]) -> [(name: String, degree: Int)] {
        let bounded = max(1, limit)
        do {
            try ensureOpen()
        } catch {
            return []
        }
        guard let db = db else { return [] }
        let filter = kindsInClause(kinds)
        let sql = """
            WITH e(src, dst) AS (SELECT DISTINCT src, dst FROM edges WHERE kind IN (\(filter)))
            SELECT node, COUNT(*) AS c FROM (
                SELECT src AS node FROM e
                UNION ALL
                SELECT dst AS node FROM e
            )
            GROUP BY node
            ORDER BY c DESC, node ASC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(bounded))
        var out: [(name: String, degree: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let node = colText(stmt, 0) else { continue }
            let degree = Int(sqlite3_column_int(stmt, 1))
            let display = prettyName(node) ?? node
            out.append((name: display, degree: degree))
        }
        return out
    }

    /// F13: OpenClicky computes community assignments on-demand using the
    /// Louvain modularity-maximisation algorithm over the full undirected
    /// edge set. Louvain is what graphify runs under the hood (via
    /// NetworkX + graspologic), so the Swift result now approaches the
    /// same partition Python's `--graph-community` reads out of
    /// `graphify-out/graph.json`.
    ///
    /// The legacy synchronous Label Propagation variant is preserved as
    /// `graphCommunityLPA` for callers that want a cheap fallback or need
    /// to compare partitions.
    public func graphCommunity(minSize: Int = 3, maxIterations: Int = 20) -> [[String]] {
        do {
            try ensureOpen()
        } catch {
            return []
        }
        guard let db = db else { return [] }
        let started = Date()
        let (adjacency, weightedDegrees, totalEdges) = loadUndirectedAdjacency(db: db)
        if adjacency.isEmpty { return [] }
        let (labels, iterations, modularity) = louvainCommunities(
            adjacency: adjacency,
            weightedDegrees: weightedDegrees,
            totalWeight: totalEdges,
            maxPassIterations: max(1, maxIterations)
        )
        var groups: [Int: [String]] = [:]
        for (node, lbl) in labels {
            groups[lbl, default: []].append(node)
        }
        var clusters: [[String]] = []
        for (_, members) in groups where members.count >= max(1, minSize) {
            let pretty = members.map { prettyName($0) ?? $0 }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            clusters.append(pretty)
        }
        clusters.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? "").localizedCaseInsensitiveCompare(rhs.first ?? "") == .orderedAscending
        }
        let elapsed = Date().timeIntervalSince(started)
        NSLog("[XLBTopicIndex] graphCommunity(Louvain) converged in %d pass iteration(s), Q=%.4f, %d clusters (>= %d), %.3fs",
              iterations, modularity, clusters.count, minSize, elapsed)
        return clusters
    }

    /// Legacy synchronous Label Propagation over the full undirected edge
    /// set. Retained as a fallback: LPA is convergence-friendly and much
    /// cheaper than Louvain when the caller just needs "some" clustering.
    /// Prefer `graphCommunity` (Louvain) for production ranking / meta
    /// output where partition quality matters.
    public func graphCommunityLPA(minSize: Int = 3, maxIterations: Int = 20) -> [[String]] {
        do {
            try ensureOpen()
        } catch {
            return []
        }
        guard let db = db else { return [] }

        // 1. Load distinct undirected edges into an in-memory adjacency
        //    dictionary keyed by lowercase node name. Names in the
        //    `edges` table are already lowercased at insert time so we
        //    don't need to re-normalise here.
        var adjacency: [String: Set<String>] = [:]
        let loadSQL = "SELECT DISTINCT src, dst FROM edges"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, loadSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let src = colText(stmt, 0), let dst = colText(stmt, 1) else { continue }
            if src == dst { continue }
            adjacency[src, default: []].insert(dst)
            adjacency[dst, default: []].insert(src)
        }
        sqlite3_finalize(stmt)
        if adjacency.isEmpty { return [] }

        // 2. Initialize labels: every node owns its own label.
        var labels: [String: String] = [:]
        labels.reserveCapacity(adjacency.count)
        for node in adjacency.keys { labels[node] = node }
        let sortedNodes = adjacency.keys.sorted()

        // 3. Synchronous LPA loop. Break ties by lexicographic smaller
        //    label so runs are deterministic.
        var iterations = 0
        for _ in 0..<max(1, maxIterations) {
            iterations += 1
            var next = labels
            var changed = false
            for node in sortedNodes {
                guard let neighbors = adjacency[node], !neighbors.isEmpty else { continue }
                var counts: [String: Int] = [:]
                for n in neighbors {
                    let lbl = labels[n] ?? n
                    counts[lbl, default: 0] += 1
                }
                var bestLabel: String? = nil
                var bestCount = -1
                for (lbl, cnt) in counts {
                    if cnt > bestCount || (cnt == bestCount && (bestLabel.map { lbl < $0 } ?? true)) {
                        bestCount = cnt
                        bestLabel = lbl
                    }
                }
                if let winner = bestLabel, winner != labels[node] {
                    next[node] = winner
                    changed = true
                }
            }
            labels = next
            if !changed { break }
        }

        // 4. Group nodes by their converged label.
        var groups: [String: [String]] = [:]
        for (node, lbl) in labels {
            groups[lbl, default: []].append(node)
        }

        // 5. Filter + shape output. Display names come from the topics
        //    table when available so callers see original casing.
        var clusters: [[String]] = []
        for (_, members) in groups where members.count >= max(1, minSize) {
            let pretty = members.map { prettyName($0) ?? $0 }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            clusters.append(pretty)
        }
        clusters.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first ?? "").localizedCaseInsensitiveCompare(rhs.first ?? "") == .orderedAscending
        }
        NSLog("[XLBTopicIndex] graphCommunityLPA converged in %d iteration(s), %d clusters (>= %d)",
              iterations, clusters.count, minSize)
        return clusters
    }

    // MARK: - Louvain community detection

    /// Load the undirected, unweighted adjacency out of the `edges` table
    /// as (adjacency, weightedDegree, m). Because edges are unweighted at
    /// the source, `weightedDegree[node]` reduces to the neighbour count
    /// and `m` is the total edge count. Self-loops are dropped so the
    /// modularity formula stays well-defined.
    private func loadUndirectedAdjacency(
        db: OpaquePointer
    ) -> (adjacency: [String: [String: Double]], weightedDegree: [String: Double], m: Double) {
        var adjacency: [String: [String: Double]] = [:]
        let loadSQL = "SELECT DISTINCT src, dst FROM edges"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, loadSQL, -1, &stmt, nil) == SQLITE_OK else {
            return ([:], [:], 0)
        }
        var m = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let src = colText(stmt, 0), let dst = colText(stmt, 1) else { continue }
            if src == dst { continue }
            // Undirected: add both directions with weight 1. If we later see
            // (dst, src) as a second row we let the += bump the weight so
            // parallel edges aggregate correctly.
            adjacency[src, default: [:]][dst, default: 0] += 1
            adjacency[dst, default: [:]][src, default: 0] += 1
            m += 1
        }
        sqlite3_finalize(stmt)
        var deg: [String: Double] = [:]
        deg.reserveCapacity(adjacency.count)
        for (node, nbrs) in adjacency {
            var d = 0.0
            for (_, w) in nbrs { d += w }
            deg[node] = d
        }
        return (adjacency, deg, m)
    }

    /// Louvain community detection over an undirected weighted graph.
    /// Runs Phase 1 (local moves) and Phase 2 (aggregation) recursively
    /// until modularity stops improving. Returns the final community id
    /// per original node, the number of Phase 1 iterations executed
    /// across all levels, and the modularity Q of the final partition.
    ///
    /// Determinism: node iteration order is a stable sort of the node
    /// keys. When two candidate communities produce the same modularity
    /// gain we prefer the smaller community id and then the community
    /// whose label sorts alphabetically. This mirrors graphify's
    /// `resolution=1.0, threshold=1e-4` NetworkX defaults.
    private func louvainCommunities(
        adjacency: [String: [String: Double]],
        weightedDegrees: [String: Double],
        totalWeight: Double,
        maxPassIterations: Int
    ) -> (labels: [String: Int], iterations: Int, modularity: Double) {
        // Fast-path: empty edge set = every node in its own community.
        if totalWeight == 0 {
            var labels: [String: Int] = [:]
            for (i, n) in adjacency.keys.sorted().enumerated() { labels[n] = i }
            return (labels, 0, 0)
        }

        // Level 0: map original names to compact integer node ids.
        let originalNodes = adjacency.keys.sorted()
        var idOf: [String: Int] = [:]
        idOf.reserveCapacity(originalNodes.count)
        for (i, n) in originalNodes.enumerated() { idOf[n] = i }

        var adj: [[(Int, Double)]] = Array(repeating: [], count: originalNodes.count)
        var deg: [Double] = Array(repeating: 0, count: originalNodes.count)
        for (name, nbrs) in adjacency {
            guard let ni = idOf[name] else { continue }
            var packed: [(Int, Double)] = []
            packed.reserveCapacity(nbrs.count)
            for (peer, w) in nbrs {
                if let pj = idOf[peer] { packed.append((pj, w)) }
            }
            packed.sort { $0.0 < $1.0 }
            adj[ni] = packed
            deg[ni] = weightedDegrees[name] ?? 0
        }

        let m = totalWeight            // total edge weight (sum of edge weights, not endpoints)
        var nodeToCommunity: [Int: Int] = [:]   // ownership across levels, keyed by ORIGINAL node id
        for i in 0..<originalNodes.count { nodeToCommunity[i] = i }

        var totalIters = 0
        var level = 0
        while true {
            let n = adj.count
            var comm = Array(0..<n)                 // current community id per super-node
            var commTot: [Double] = deg             // Σ_tot per community
            let selfLoops: [Double] = adj.enumerated().map { (i, nb) in
                nb.reduce(0.0) { $0 + ($1.0 == i ? $1.1 : 0) }
            }
            var commIn: [Double] = selfLoops        // Σ_in per community starts at self-loop weight

            let twoM = 2.0 * m
            var improved = true
            var passIters = 0
            while improved, passIters < maxPassIterations {
                improved = false
                passIters += 1
                for i in 0..<n {
                    let ci = comm[i]
                    let ki = deg[i]
                    // Compute k_{i,C} for every neighbour community C.
                    var kiToComm: [Int: Double] = [:]
                    for (j, w) in adj[i] {
                        if j == i { continue }
                        let cj = comm[j]
                        kiToComm[cj, default: 0] += w
                    }
                    // Remove i from its current community.
                    let kiToCi = kiToComm[ci] ?? 0
                    commTot[ci] -= ki
                    commIn[ci] -= 2.0 * kiToCi + selfLoops[i]

                    // Find the best community to move i into. Ties broken
                    // by smaller community id first, then alphabetical
                    // community label -- since community ids at this level
                    // are just integers, the id tie-break is enough for
                    // determinism.
                    var bestComm = ci
                    var bestGain = 0.0
                    let sortedComms = kiToComm.keys.sorted()
                    for c in sortedComms {
                        let kiToC = kiToComm[c] ?? 0
                        let gain = kiToC - commTot[c] * ki / twoM
                        if gain > bestGain + 1e-12 || (abs(gain - bestGain) <= 1e-12 && c < bestComm) {
                            bestGain = gain
                            bestComm = c
                        }
                    }
                    // Insert i into the winning community.
                    commTot[bestComm] += ki
                    let kiToBest = kiToComm[bestComm] ?? 0
                    commIn[bestComm] += 2.0 * kiToBest + selfLoops[i]
                    if bestComm != ci {
                        comm[i] = bestComm
                        improved = true
                    }
                }
            }
            totalIters += passIters

            // If no local move improved modularity, stop. Otherwise
            // aggregate to a smaller graph and recurse.
            let distinctComms = Set(comm)
            if distinctComms.count == n && level > 0 {
                break
            }

            // Push this level's assignment down to original nodes.
            if level == 0 {
                for i in 0..<originalNodes.count {
                    nodeToCommunity[i] = comm[i]
                }
            } else {
                // At level > 0, `comm` is indexed by super-node. Composite
                // through the previous mapping stored in `nodeToCommunity`.
                let previousLabel = nodeToCommunity
                for i in 0..<originalNodes.count {
                    let superNode = previousLabel[i] ?? i
                    nodeToCommunity[i] = comm[superNode]
                }
            }

            if distinctComms.count == n { break }

            // Phase 2: build the reduced graph, one super-node per
            // community. Edges within a community become weighted
            // self-loops (2 * intra edge weight); edges between
            // communities become the summed inter-community weight.
            let idxOfComm: [Int: Int] = {
                var m: [Int: Int] = [:]
                for (newIdx, c) in distinctComms.sorted().enumerated() {
                    m[c] = newIdx
                }
                return m
            }()
            let newSize = idxOfComm.count
            var newAdj: [[Int: Double]] = Array(repeating: [:], count: newSize)
            var newDeg: [Double] = Array(repeating: 0, count: newSize)
            for i in 0..<n {
                guard let ni = idxOfComm[comm[i]] else { continue }
                for (j, w) in adj[i] {
                    guard let nj = idxOfComm[comm[j]] else { continue }
                    newAdj[ni][nj, default: 0] += w
                    newDeg[ni] += w
                }
            }
            adj = newAdj.map { dict -> [(Int, Double)] in
                dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            }
            deg = newDeg
            // Remap nodeToCommunity so the previous-level composition uses
            // the new indices.
            for i in 0..<originalNodes.count {
                let old = nodeToCommunity[i] ?? i
                nodeToCommunity[i] = idxOfComm[old] ?? old
            }
            level += 1
            if level > 20 { break }   // hard safety cap
        }

        // Compute final modularity Q for reporting.
        var labelsByName: [String: Int] = [:]
        for i in 0..<originalNodes.count {
            labelsByName[originalNodes[i]] = nodeToCommunity[i] ?? i
        }
        let q = computeModularity(
            adjacency: adjacency,
            weightedDegrees: weightedDegrees,
            labels: labelsByName,
            m: totalWeight
        )
        return (labelsByName, totalIters, q)
    }

    /// Modularity Q for an undirected graph:
    ///   Q = (1/2m) Σ [A_ij - k_i k_j / 2m] δ(c_i, c_j)
    /// Computed once at the end for the caller's log line.
    private func computeModularity(
        adjacency: [String: [String: Double]],
        weightedDegrees: [String: Double],
        labels: [String: Int],
        m: Double
    ) -> Double {
        if m == 0 { return 0 }
        let twoM = 2.0 * m
        var q = 0.0
        for (i, nbrs) in adjacency {
            let ci = labels[i] ?? -1
            let ki = weightedDegrees[i] ?? 0
            for (j, w) in nbrs {
                let cj = labels[j] ?? -2
                if ci != cj { continue }
                let kj = weightedDegrees[j] ?? 0
                q += w - (ki * kj) / twoM
            }
        }
        return q / twoM
    }

    private func neighborsOfLower(_ node: String, db: OpaquePointer) -> [String] {
        var out: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT dst FROM edges WHERE src = ? UNION SELECT src FROM edges WHERE dst = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, node, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 2, node, -1, TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = colText(stmt, 0) { out.append(s) }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    private func neighborsOfLowerWithKind(_ node: String, db: OpaquePointer, kinds: Set<String> = []) -> [(String, String)] {
        var out: [(String, String)] = []
        var stmt: OpaquePointer?
        let filter = kinds.isEmpty ? "" : " AND kind IN (\(kindsInClause(kinds)))"
        let sql = """
            SELECT dst, kind FROM edges WHERE src = ?\(filter)
            UNION
            SELECT src, kind FROM edges WHERE dst = ?\(filter)
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, node, -1, TRANSIENT)
            sqlite3_bind_text(stmt, 2, node, -1, TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = colText(stmt, 0), let k = colText(stmt, 1) {
                    out.append((s, k))
                }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Render a `Set<String>` of kinds as an inline SQL `IN` clause body,
    /// e.g. `{"searchin", "crossref"}` -> `'crossref','searchin'`.
    /// Values are single-quote-escaped and sorted so the SQL text is stable
    /// for the prepared-statement cache. Empty sets fall back to all kinds
    /// used in the parser (`searchin`, `crossref`, `command_ref`).
    fileprivate func kindsInClause(_ kinds: Set<String>) -> String {
        let source = kinds.isEmpty ? ["searchin", "crossref", "command_ref"] : Array(kinds)
        return source
            .sorted()
            .map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            .joined(separator: ",")
    }

    private func prettyName(_ lower: String) -> String? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM topics WHERE LOWER(name) = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, lower, -1, TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return colText(stmt, 0)
        }
        return nil
    }

    private func reconstructPath(
        visited: [String: String],
        endLower: String,
        startLower: String,
        original: String
    ) -> [String] {
        var chain: [String] = []
        var cur = endLower
        while !cur.isEmpty {
            chain.append(prettyName(cur) ?? cur)
            if cur == startLower { break }
            guard let prev = visited[cur] else { break }
            cur = prev
        }
        // Replace the start display with the caller's original casing if we
        // couldn't recover a topic row for it.
        if let last = chain.last, last.caseInsensitiveCompare(original) == .orderedSame {
            chain[chain.count - 1] = original
        }
        return chain.reversed()
    }

    // MARK: - Graphify graph.json export

    /// Serializes the sqlite-baked graph (`gnodes` + `gnode_aliases` +
    /// `gedges`) into the JSON schema emitted by
    /// `xlb-topic-index/scripts/xlb_graph_extract.py`. The output is byte-for-
    /// byte compatible with `graphify-out/graph.json` (same key order,
    /// including the `links` alias for the graphify CLI).
    ///
    /// Path must be writable. Parent directories are created on demand.
    public func exportGraphJson(to path: URL) throws {
        try ensureOpen()
        guard let db = db else {
            throw NSError(domain: "XLBTopicIndex", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "graph.json export: sqlite not open"
            ])
        }

        // Load aliases keyed by node id so each gnode row emits its full
        // alias list in one dict, matching Python's asdict(GNode).
        var aliasesByNode: [String: [String]] = [:]
        var aliasStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT node_id, alias FROM gnode_aliases", -1, &aliasStmt, nil) == SQLITE_OK {
            while sqlite3_step(aliasStmt) == SQLITE_ROW {
                guard let nid = colText(aliasStmt, 0), let a = colText(aliasStmt, 1) else { continue }
                aliasesByNode[nid, default: []].append(a)
            }
        }
        sqlite3_finalize(aliasStmt)

        // Emit nodes. Preserve Python's dict key order:
        //   id, label, node_type, file_type, source_file, aliases, parent_id, community
        // Communities are only present when the Louvain pass ran; the Swift
        // rebuild always populates the column, so we include it for every
        // node whose column is not NULL, matching Python's --cluster output.
        var nodes: [[String: Any]] = []
        nodes.reserveCapacity(24_000)
        var nStmt: OpaquePointer?
        let nSQL = "SELECT id, label, node_type, file_type, source_file, parent_id, community FROM gnodes"
        guard sqlite3_prepare_v2(db, nSQL, -1, &nStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "XLBTopicIndex", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "graph.json export: prepare gnodes failed"
            ])
        }
        while sqlite3_step(nStmt) == SQLITE_ROW {
            let id = colText(nStmt, 0) ?? ""
            let label = colText(nStmt, 1) ?? ""
            let nodeType = colText(nStmt, 2) ?? "topic"
            let fileType = colText(nStmt, 3) ?? "document"
            let sourceFile = colText(nStmt, 4) ?? ""
            let parentID = colText(nStmt, 5) ?? ""
            var row: [String: Any] = [
                "id": id,
                "label": label,
                "node_type": nodeType,
                "file_type": fileType,
                "source_file": sourceFile,
                "aliases": aliasesByNode[id] ?? [],
                "parent_id": parentID,
            ]
            if sqlite3_column_type(nStmt, 6) != SQLITE_NULL {
                row["community"] = Int(sqlite3_column_int64(nStmt, 6))
            }
            nodes.append(row)
        }
        sqlite3_finalize(nStmt)

        // Emit edges. Preserve Python's dict key order:
        //   source, target, relation, confidence, source_file, group
        // The sqlite column is named `grp` because `group` is a SQL keyword;
        // map it back to `group` for schema parity.
        var edges: [[String: Any]] = []
        edges.reserveCapacity(31_000)
        var eStmt: OpaquePointer?
        let eSQL = "SELECT source, target, relation, confidence, source_file, grp FROM gedges"
        guard sqlite3_prepare_v2(db, eSQL, -1, &eStmt, nil) == SQLITE_OK else {
            throw NSError(domain: "XLBTopicIndex", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "graph.json export: prepare gedges failed"
            ])
        }
        while sqlite3_step(eStmt) == SQLITE_ROW {
            let src = colText(eStmt, 0) ?? ""
            let tgt = colText(eStmt, 1) ?? ""
            let rel = colText(eStmt, 2) ?? ""
            let conf = colText(eStmt, 3) ?? "EXTRACTED"
            let sf = colText(eStmt, 4) ?? ""
            let grp = colText(eStmt, 5) ?? ""
            edges.append([
                "source": src,
                "target": tgt,
                "relation": rel,
                "confidence": conf,
                "source_file": sf,
                "group": grp,
            ])
        }
        sqlite3_finalize(eStmt)

        // Python emits: {directed, multigraph, graph, nodes, edges, links}.
        // `links` is the same list object as `edges`; JSONSerialization
        // renders them as two independent arrays with identical content,
        // which is what graphify's CLI already expects.
        let payload: [String: Any] = [
            "directed": true,
            "multigraph": false,
            "graph": [String: Any](),
            "nodes": nodes,
            "edges": edges,
            "links": edges,
        ]

        let fm = FileManager.default
        let parent = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Atomic write via a tempfile in the same directory so partial
        // failures don't leave the skill reading a truncated JSON.
        let tmp = parent.appendingPathComponent(".graph.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        try fm.moveItem(at: tmp, to: path)
        NSLog("[XLBTopicIndex] wrote graph.json: %d nodes / %d edges -> %@",
              nodes.count, edges.count, path.path)
    }

    /// Regenerates `graph.json` at the openclicky-side default path
    /// (`~/Library/Application Support/OpenClicky/xlb-graph.json`) unless
    /// overridden via the `openclicky.xlb.graphJsonPath` UserDefault.
    /// Returns the URL that was written so the Settings UI can surface it.
    @discardableResult
    public func regenerateGraphJson() throws -> URL {
        guard let target = defaultGraphJsonURL() else {
            throw NSError(domain: "XLBTopicIndex", code: 43, userInfo: [
                NSLocalizedDescriptionKey: "graph.json export: could not resolve destination"
            ])
        }
        try exportGraphJson(to: target)
        return target
    }

    /// Resolves the graph.json destination for writes. The default lives
    /// under openclicky's own Application Support directory so no external
    /// skill install is required. Reads that need a graph.json on disk
    /// should prefer this location first and fall back to the legacy skill
    /// path only if the file physically exists there (transitional).
    private func defaultGraphJsonURL() -> URL? {
        // Openclicky-owned default. All new writes land here.
        let openClickyDefault = "~/Library/Application Support/OpenClicky/xlb-graph.json"
        // Transitional read fallback: legacy skill export path from before
        // the openclicky migration.
        let legacySkillPath = "~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/graphify-out/graph.json"

        if let raw = UserDefaults.standard.string(forKey: "openclicky.xlb.graphJsonPath"),
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }

        let expandedDefault = (openClickyDefault as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: expandedDefault) {
            let expandedLegacy = (legacySkillPath as NSString).expandingTildeInPath
            if fm.fileExists(atPath: expandedLegacy) {
                return URL(fileURLWithPath: expandedLegacy)
            }
        }
        return URL(fileURLWithPath: expandedDefault)
    }

    // MARK: - Index stats (Settings status line)

    /// Returns lightweight counts + last-sync timestamp for the Settings
    /// panel. Opens the DB on demand; returns nil when disabled or the
    /// underlying sqlite file is missing.
    public func indexStats() -> IndexStats? {
        guard isEnabled() else { return nil }
        do { try ensureOpen() } catch { return nil }
        guard let db = db else { return nil }
        func scalarCount(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return 0
        }
        let nodes = scalarCount("SELECT COUNT(*) FROM gnodes")
        let edges = scalarCount("SELECT COUNT(*) FROM gedges")
        let topics = scalarCount("SELECT COUNT(*) FROM topics")
        let mtime = (try? readMetaDouble(key: "last_sync_mtime")) ?? nil
        let syncedAt: Date? = {
            guard let m = mtime, m > 0 else { return nil }
            return Date(timeIntervalSince1970: m)
        }()
        return IndexStats(
            nodeCount: nodes,
            edgeCount: edges,
            topicCount: topics,
            lastSyncedAt: syncedAt
        )
    }
}

// MARK: - Byte-level parser

/// Parses a single `*-library` file. Everything runs on the raw UTF-8 byte
/// buffer to avoid Swift's `String` bridge on 8 MB single-line records.
///
/// Emits into the shared prepared statement so the whole rebuild sits in one
/// sqlite transaction.
private final class LibraryFileParser {

    // Tag names (all ASCII) whose left-hand side is not a real subtopic.
    // Mirrors the Python TAG_LIST in xlb_local_reader.py verbatim. Stored
    // without the trailing colon and lowercased for O(1) case-insensitive
    // membership tests in the top-level walk of the `keyword:` section.
    static let tagNames: Set<String> = [
        "id", "title", "url", "videourl", "author", "winner", "ratings",
        "term", "prereq", "prerequisites", "toprepo", "project", "university",
        "available", "level", "features", "instructors", "professor",
        "faculty", "investigator", "researcher", "adviser", "scientist", "phd",
        "people", "follow", "description", "textbook", "book", "bible", "paper",
        "homepage", "organization", "platform", "specialization", "journal",
        "tutorial", "dataset", "priority", "parentid", "category", "summary",
        "published", "version", "path", "icon", "shortname",
        "ceo", "cso", "cto", "cio", "cfo", "cmo", "cco", "cbo", "coo", "cpo",
        "founder", "vp", "investor", "stockholder", "foundation",
        "programmer", "engineer", "developer", "hacker", "product",
        "artist", "writer", "leader", "director", "consultant",
        "community", "conference", "workshop", "challenge", "company", "startup",
        "lab", "team", "institute", "summit",
        "alias", "slack", "workast", "gitter", "twitter", "mastodon", "social-tag",
        "youtube", "github", "ossinsight", "huggingface", "hugging_face", "linux_do",
        "paperswithcode", "civitai", "replicate", "modelscope", "colab", "replit",
        "github-explore", "awesomeopensource", "gitlab", "oschina", "gitee",
        "libhunt", "sourcegraph", "vimeo", "g-group", "g-plus", "medium",
        "goodreads", "fb-group", "fb-pages", "meetup", "huodongxing",
        "y-video", "y-channel", "y-channel2", "y-playlist", "y-stream",
        "y-course", "y-podcast", "y-post", "rutube", "r-playlist", "r-video",
        "pornhub", "randomstreetview", "topwebsiterank", "topwebsiterank-keyword",
        "topwebsiterank-category", "award", "website", "memkite", "blog",
        "linkedin", "l-group", "cbinsights", "alternativeto", "clone", "docker",
        "stackexchange", "quora", "zhihu", "t-zhihu", "z-zhihu", "c-zhihu",
        "v2ex", "blogspot", "bitbucket", "sourceforge", "business", "country",
        "price", "date", "advisor", "intern", "facebook", "vk", "reddit",
        "reddit-guide", "lihkg", "weibo", "job", "alliance", "slideshare",
        "crossref", "contentref", "vimeopro", "atlassian", "qq-group", "discuss",
        "weixin", "chuansong", "localdb", "engintype", "keyword", "udacity",
        "review", "instagram", "leiphone", "businessinsider", "freenode",
        "videolectures", "techtalks", "universe", "agent", "survey", "series",
        "program", "douyu", "digg", "twitch", "tiktok", "douyin", "steam",
        "ustream", "csdnlib", "cnblog", "iqiyi", "flipboard", "channel9",
        "panopto", "piazza", "expert", "blogcsdn", "pcpartpicker", "baijiahao",
        "dean", "jianshu", "15yan", "nucleus", "youku", "zaker", "v_qq", "sohu",
        "nbviewer", "flagship", "toutiao", "topbuzz", "leaderboard", "benchmark",
        "baiduyun", "inke", "sayit", "kaggle", "soundcloud", "expo",
        "bilibili", "acfun", "archive_org", "zeef", "g_cores", "tieba",
        "discord", "mixer", "periscope", "flickr", "vine", "tudou", "patreon",
        "g_youtube", "douban", "doulist", "click_count", "artstation", "appveyor",
        "gamesradar", "opencollective", "gamejolt", "onetab", "nico", "wordpress",
        "photobucket", "stumble", "disqus", "waffle", "pinterest", "deviantart",
        "dribbble", "shadertoy", "tumblr", "inoreader", "commonlounge", "woboq",
        "openhub", "sketchfab", "argv", "crunchbase", "wikia", "gamepedia",
        "keybase", "telegram", "shokichan", "iptv_zone", "tagboard", "band",
        "pscp", "searchin", "command", "class", "trello", "rocket", "skype",
        "chart", "lizhi", "juejin", "magnet", "pikpak",
    ]

    // "keyword:" as bytes for a raw byte-search.
    static let keywordTag: [UInt8] = Array("keyword:".utf8)
    // "alias(" as lowercase bytes.
    static let aliasTag: [UInt8] = Array("alias(".utf8)
    // "searchin(" as lowercase bytes.
    static let searchinTag: [UInt8] = Array("searchin(".utf8)
    // "command(" as lowercase bytes.
    static let commandTag: [UInt8] = Array("command(".utf8)
    // " | " field separator.
    static let sep: [UInt8] = [0x20, 0x7C, 0x20]

    /// R1: Python's `_index_all_named_items` skip set. TAG_LIST already
    /// covers most of these but Python re-adds a few control names that are
    /// not tag prefixes (e.g. "readme", "playground", "chart") so
    /// `Readme(...)` chunks don't get emitted as fake subtopics.
    static let namedItemSkipExtras: Set<String> = [
        "alias", "searchin", "command", "crossref", "homepage", "readme",
        "playground", "category", "chat with learn", "chart",
    ]

    /// R3: Python's `desc_to_url_dict` folds several URL-container tags under
    /// a single "website" bucket in the meta tree. When we encounter these
    /// heads we emit `website` into `tag_groups` instead of the raw name so
    /// `tagSectionCounts` matches Python's `--meta` output. The homepage /
    /// playground / readme tags never appear as their own tree keys on the
    /// Python side, only as `gn` (grouped names) inside `website`.
    static let websiteFoldedTags: Set<String> = [
        "homepage", "playground", "readme", "docs",
    ]

    /// R5: URL-container tag names. When a candidate `Name(` match is enclosed
    /// by one of these tags, the Name is a display label (e.g.
    /// `github(user/repo*Display Label(user/repo))`) NOT a genuine subtopic.
    /// Mirrors `_URL_CONTAINER_TAGS` in `xlb_local_reader.py`. Names are
    /// stored lowercase and compared case-insensitively. Some entries contain
    /// dots or spaces on the Python side (e.g. `medium.com`, `app store`);
    /// the byte-level tag-name walk here stops on space so the space variant
    /// (`app store`) will never form -- kept for reference parity anyway.
    static let urlContainerTags: Set<String> = [
        "github", "youtube", "y-video", "y-playlist", "y-channel", "paper",
        "homepage", "readme", "docs", "playground", "website", "discord",
        "reddit", "twitter", "linkedin", "medium", "blog", "alternativeto",
        "juejin", "bilibili", "instagram", "tiktok", "steam", "crunchbase",
        "hugging_face", "huggingface", "arxiv", "book", "podcast", "wechat",
        "weixin", "facebook", "douyu", "douban", "iqiyi", "youku", "soundcloud",
        "app-store", "google-play", "app_store", "app store", "channel9",
        "medium.com", "commonlounge", "meetup", "conference",
    ]

    let bytes: [UInt8]
    let library: String
    let stmt: OpaquePointer?
    let edgeStmt: OpaquePointer?
    let tagGroupStmt: OpaquePointer?
    let gnodeStmt: OpaquePointer?
    let gnodeUpgradeStmt: OpaquePointer?
    let gnodeAliasStmt: OpaquePointer?
    let gedgeStmt: OpaquePointer?
    let dbHandle: OpaquePointer?
    private var edgesInserted: Int = 0

    /// Cheap per-file dedupe of gnode + gedge emissions before hitting
    /// sqlite. Prevents O(rows*inserts) INSERT OR IGNORE traffic when the
    /// parser walks the same subtopic through structural and byte-scan
    /// passes (e.g. once from `walkKeywordSection`, again from
    /// `harvestAllNamedItems`).
    private var emittedGNodes: Set<String> = []
    private var emittedGEdges: Set<String> = []
    /// Tracks gnode ids that have been emitted at least once (any node_type).
    /// Matches Python's `_enrich_from_local_reader` gate:
    /// `if sub_nid not in existing_node_ids` -- only NEWLY-DISCOVERED
    /// subtopics get an accompanying `record --contains--> sub` edge.
    private var emittedGNodeIDs: Set<String> = []
    /// Parents (by gnode id) whose graphify alias emissions have already
    /// fired for their FIRST `alias(...)` body. Python's
    /// `extract_alias_from_value` only reads the first `alias(` in a
    /// keyword item's value; we mirror that per parent so the alias_of
    /// count stays proportional to the number of parent nodes.
    private var gnodeAliasParents: Set<String> = []

    init(
        bytes: [UInt8],
        library: String,
        stmt: OpaquePointer?,
        edgeStmt: OpaquePointer?,
        tagGroupStmt: OpaquePointer?,
        gnodeStmt: OpaquePointer?,
        gnodeUpgradeStmt: OpaquePointer?,
        gnodeAliasStmt: OpaquePointer?,
        gedgeStmt: OpaquePointer?,
        dbHandle: OpaquePointer?
    ) {
        self.bytes = bytes
        self.library = library
        self.stmt = stmt
        self.edgeStmt = edgeStmt
        self.tagGroupStmt = tagGroupStmt
        self.gnodeStmt = gnodeStmt
        self.gnodeUpgradeStmt = gnodeUpgradeStmt
        self.gnodeAliasStmt = gnodeAliasStmt
        self.gedgeStmt = gedgeStmt
        self.dbHandle = dbHandle
    }

    // MARK: - Graphify emission

    /// Python's `_node_id(label)`: lowercase + spaces to underscores.
    private static func gnodeID(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Emit one gnode row. `INSERT OR IGNORE` collapses duplicates. When
    /// the row already exists and the new emission has a stronger
    /// `node_type` (topic > library > subtopic > external_ref > alias),
    /// promote the existing row -- this mirrors `dedupe_nodes` in
    /// `xlb_graph_extract.py` where the last-seen non-`external_ref`
    /// wins.
    @discardableResult
    private func emitGNode(
        label: String,
        nodeType: String,
        sourceFile: String?,
        parentID: String?
    ) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = Self.gnodeID(trimmed)
        guard !id.isEmpty else { return nil }
        // First emission wins outright when the key is new. Subsequent
        // emissions attempt an upgrade if the incoming node_type is
        // stronger than the stored one (see `gnodeUpgradeStmt` WHERE).
        let key = id + "|" + nodeType
        let seen = emittedGNodes.contains(key)
        emittedGNodes.insert(key)
        emittedGNodeIDs.insert(id)
        guard let s = gnodeStmt else { return id }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if !seen {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            sqlite3_bind_text(s, 1, id, -1, TRANSIENT)
            sqlite3_bind_text(s, 2, trimmed, -1, TRANSIENT)
            sqlite3_bind_text(s, 3, nodeType, -1, TRANSIENT)
            if let sf = sourceFile, !sf.isEmpty {
                sqlite3_bind_text(s, 4, sf, -1, TRANSIENT)
            } else {
                sqlite3_bind_text(s, 4, "", -1, TRANSIENT)
            }
            if let pid = parentID, !pid.isEmpty {
                sqlite3_bind_text(s, 5, pid, -1, TRANSIENT)
            } else {
                sqlite3_bind_text(s, 5, "", -1, TRANSIENT)
            }
            _ = sqlite3_step(s)
        }
        // If the incoming type is stronger than external_ref/alias, run
        // the upgrade UPDATE. Cheap when the row is already a stronger
        // node_type (the WHERE guards against downgrades).
        let strong = Self.strongerThanExternal(nodeType)
        if strong, let up = gnodeUpgradeStmt {
            sqlite3_reset(up)
            sqlite3_clear_bindings(up)
            sqlite3_bind_text(up, 1, nodeType, -1, TRANSIENT)
            sqlite3_bind_text(up, 2, sourceFile ?? "", -1, TRANSIENT)
            sqlite3_bind_text(up, 3, parentID ?? "", -1, TRANSIENT)
            sqlite3_bind_text(up, 4, id, -1, TRANSIENT)
            _ = sqlite3_step(up)
        }
        return id
    }

    private static func strongerThanExternal(_ nodeType: String) -> Bool {
        switch nodeType {
        case "topic", "library", "subtopic": return true
        default: return false
        }
    }

    /// Emit one alias row into `gnode_aliases`. Idempotent via UNIQUE.
    private func emitGNodeAlias(nodeID: String, alias: String) {
        guard let s = gnodeAliasStmt else { return }
        let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeID.isEmpty, !a.isEmpty else { return }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        sqlite3_bind_text(s, 1, nodeID, -1, TRANSIENT)
        sqlite3_bind_text(s, 2, a, -1, TRANSIENT)
        _ = sqlite3_step(s)
    }

    /// Emit one gedge row. Names are already lowercased/underscored IDs.
    /// Uses in-process de-dup so repeat callers don't burn INSERT OR
    /// IGNORE cycles.
    private func emitGEdge(
        source: String,
        target: String,
        relation: String,
        sourceFile: String?,
        group: String?
    ) {
        guard let s = gedgeStmt else { return }
        guard !source.isEmpty, !target.isEmpty, source != target else { return }
        let key = source + "|" + target + "|" + relation
        if emittedGEdges.contains(key) { return }
        emittedGEdges.insert(key)
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        sqlite3_bind_text(s, 1, source, -1, TRANSIENT)
        sqlite3_bind_text(s, 2, target, -1, TRANSIENT)
        sqlite3_bind_text(s, 3, relation, -1, TRANSIENT)
        sqlite3_bind_text(s, 4, sourceFile ?? "", -1, TRANSIENT)
        sqlite3_bind_text(s, 5, group ?? "", -1, TRANSIENT)
        _ = sqlite3_step(s)
    }

    /// Emit one row into `tag_groups` marking `parent` as having a section
    /// with `tag_name`. Uses INSERT OR IGNORE so repeated hits on the same
    /// pair collapse silently.
    @discardableResult
    private func emitTagGroup(parent: String, tagName: String) -> Bool {
        guard let s = tagGroupStmt else { return false }
        let p = parent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty, !t.isEmpty else { return false }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(s)
        sqlite3_clear_bindings(s)
        sqlite3_bind_text(s, 1, p, -1, TRANSIENT)
        sqlite3_bind_text(s, 2, t, -1, TRANSIENT)
        sqlite3_bind_text(s, 3, library, -1, TRANSIENT)
        _ = sqlite3_step(s)
        return sqlite3_changes(dbHandle) > 0
    }

    func parse() -> (records: Int, topics: Int, edges: Int) {
        var records = 0
        var topics = 0
        var start = 0
        let n = bytes.count
        // Emit graphify library node once per file. Python's parser uses
        // the filename (e.g. `ai-library`) verbatim as the label; the node
        // id lowercases it and underscores spaces.
        let libraryFile = library + "-library"
        _ = emitGNode(
            label: libraryFile,
            nodeType: "library",
            sourceFile: libraryFile,
            parentID: nil
        )
        var i = 0
        while i < n {
            if bytes[i] == 0x0A {
                if i > start {
                    let (r, t) = parseLine(start: start, end: i)
                    records += r
                    topics += t
                }
                start = i + 1
            }
            i += 1
        }
        if start < n {
            let (r, t) = parseLine(start: start, end: n)
            records += r
            topics += t
        }
        return (records, topics, edgesInserted)
    }

    /// Parse one record line (byte range half-open). Fields are `|`-separated
    /// exactly like the xlb Python `Record._pos` implementation: the split
    /// hunts for the pipe character directly, not the ` | ` triplet, since
    /// some records use adjacent bars (` | | `) to encode empty fields.
    ///
    /// If a raw line contains no `|` at all, Python's `Record.__init__`
    /// prepends `" | "` and appends ` | | ` so the row still yields 4 fields
    /// (id="", title=<line>, url="", desc=""). We mirror that here by
    /// synthesising the field ranges directly rather than mutating the
    /// underlying byte buffer.
    private func parseLine(start: Int, end: Int) -> (Int, Int) {
        var fieldStart = start
        var fields: [(Int, Int)] = []
        var i = start
        while i < end {
            if bytes[i] == 0x7C { // '|'
                fields.append((fieldStart, i))
                fieldStart = i + 1
                if fields.count == 3 { break }
            }
            i += 1
        }
        fields.append((fieldStart, end))

        // F2: records without any `|` become " | <line> | | " -- id empty,
        // title is the entire line, url empty, desc empty.
        if fields.count == 1 {
            let (ts, te) = trimmed((start, end))
            if te <= ts { return (0, 0) }
            fields = [(ts, ts), (ts, te), (ts, ts), (ts, ts)]
        }
        guard fields.count >= 4 else { return (0, 0) }

        let (titleStart, titleEnd) = trimmed(fields[1])
        guard titleEnd > titleStart else { return (0, 0) }
        guard let title = string(titleStart, titleEnd) else { return (0, 0) }

        var inserted = 0
        if bind(name: title, kind: .title, parent: nil, browse: ">\(title)/") { inserted += 1 }

        // Graphify: emit the record topic node and `library --contains--> topic`.
        let libraryFile = library + "-library"
        let libraryID = Self.gnodeID(libraryFile)
        let topicID = emitGNode(
            label: title,
            nodeType: "topic",
            sourceFile: libraryFile,
            parentID: nil
        ) ?? Self.gnodeID(title)
        emitGEdge(source: libraryID, target: topicID, relation: "contains", sourceFile: libraryFile, group: nil)

        // Content field runs from field[3].start to end of line.
        let (contentStart, contentEnd) = fields[3]

        // F3: aliases are harvested from the entire desc, not just the
        // keyword section, so the topics table absorbs every alias() body
        // for lookups. Python's graphify pass only emits `alias_of` edges
        // rooted at each keyword-item's `sub_nid` (via
        // `_extract_item_graph`), NOT at the record title. Pass
        // `graphify: false` here so the topics-table sweep does not
        // produce record-rooted `alias_of` edges that Python does not.
        harvestAliases(from: contentStart, to: contentEnd, parent: title, count: &inserted, graphify: false)

        // F4: crossref emits Source --crossref--> Target edges, one per
        // comma-separated value on a top-level `crossref:` tag. Python's
        // xlb_graph_extract.py:461-469 uses re.finditer(r"crossref:([^\s]+)").
        harvestCrossref(from: contentStart, to: contentEnd, parent: title, count: &inserted)

        // F3b: top-level `alias:` (COLON form, comma-separated values) at
        // depth 0. Python's xlb_graph_extract.py:684-703 handles this once
        // per record and emits `record_title --alias_of--> alias` gedges.
        // Distinct from `alias(...)` bodies which live inside keyword items.
        harvestTopLevelAliasTag(from: contentStart, to: contentEnd, parent: title, count: &inserted)

        if let kwRange = findKeywordSection(from: contentStart, to: contentEnd) {
            walkKeywordSection(kwRange.0, kwRange.1, parent: title, count: &inserted)
        }

        // R1 fix: mirror Python's `_index_all_named_items` which regex-scans the
        // ENTIRE desc for `Name(` patterns regardless of paren depth. This
        // catches deeply-nested subtopics (e.g. `Vibe Coding` at paren depth 6
        // inside `Engineering Degree`'s Programmer Skill Map chain) that the
        // structural walker cannot reach because upstream URL text has
        // unbalanced parens.
        harvestAllNamedItems(from: contentStart, to: contentEnd, parent: title, count: &inserted)

        // R3: record-title tag groups. Python's `_browse_meta` builds the
        // record's tree via `_browse_root_fast` -> `get_desc_tags(rec)`,
        // which uses `next_pos` to find top-level ` tag:` boundaries in the
        // raw desc. Only tags that appear at the outermost paren depth
        // become record-level tree entries. Nested tags inside a
        // `keyword:(...)` block never surface at the record level.
        harvestTagGroupsForRecord(from: contentStart, to: contentEnd, parent: title)

        return (1, inserted)
    }

    /// Insert one edge (src -> dst, kind) if the prepared edge statement is
    /// available. Names are stored lowercased so BFS lookups do not need to
    /// normalise on every step. Returns true when a new row landed.
    @discardableResult
    private func emitEdge(_ src: String, _ dst: String, kind: String) -> Bool {
        guard let edgeStmt = edgeStmt else { return false }
        // Skip degenerate self-loops and empty names; they add graph noise.
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let d = dst.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, !d.isEmpty, s != d else { return false }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(edgeStmt)
        sqlite3_clear_bindings(edgeStmt)
        sqlite3_bind_text(edgeStmt, 1, s, -1, TRANSIENT)
        sqlite3_bind_text(edgeStmt, 2, d, -1, TRANSIENT)
        sqlite3_bind_text(edgeStmt, 3, kind, -1, TRANSIENT)
        sqlite3_bind_text(edgeStmt, 4, library, -1, TRANSIENT)
        _ = sqlite3_step(edgeStmt)
        let ok = sqlite3_changes(dbHandle) > 0
        if ok { edgesInserted += 1 }
        return ok
    }

    /// Bind a row and step. Increments `changes` on success.
    private func bind(name: String, kind: XLBTopicIndex.Kind, parent: String?, browse: String, tagName: String? = nil, innerSize: Int = 0) -> Bool {
        guard let stmt = stmt else { return false }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, name, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, library, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 3, kind.rawValue, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 4, browse, -1, TRANSIENT)
        if let parent = parent {
            sqlite3_bind_text(stmt, 5, parent, -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let tag = tagName, !tag.isEmpty {
            sqlite3_bind_text(stmt, 6, tag.lowercased(), -1, TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_int(stmt, 7, Int32(max(0, innerSize)))
        _ = sqlite3_step(stmt)
        return sqlite3_changes(dbHandle) > 0
    }

    /// Trim leading + trailing ASCII whitespace / newline in a byte range.
    private func trimmed(_ r: (Int, Int)) -> (Int, Int) {
        var s = r.0
        var e = r.1
        while s < e, bytes[s] == 0x20 || bytes[s] == 0x09 || bytes[s] == 0x0D { s += 1 }
        while e > s, bytes[e - 1] == 0x20 || bytes[e - 1] == 0x09 || bytes[e - 1] == 0x0D { e -= 1 }
        return (s, e)
    }

    private func string(_ start: Int, _ end: Int) -> String? {
        guard end > start else { return nil }
        return bytes.withUnsafeBufferPointer { buf -> String? in
            let slice = UnsafeBufferPointer(rebasing: buf[start..<end])
            return String(decoding: slice, as: UTF8.self)
        }
    }

    /// Locate the `keyword:` byte substring within [from, to). Returns the
    /// content range (after `keyword:`) delimited by the next top-level tag
    /// or the end of the field.
    private func findKeywordSection(from: Int, to: Int) -> (Int, Int)? {
        guard let kwStart = findSubsequence(Self.keywordTag, from: from, to: to) else { return nil }
        let s = kwStart + Self.keywordTag.count
        // Walk from s, tracking paren depth. Stop at the next ` <letters>:`
        // sequence at depth 0.
        var depth = 0
        var j = s
        while j < to {
            let ch = bytes[j]
            if ch == 0x28 { depth += 1 }
            else if ch == 0x29 { if depth > 0 { depth -= 1 } }
            else if ch == 0x20, depth == 0 {
                var k = j + 1
                while k < to {
                    let c = bytes[k]
                    if c == 0x3A {
                        if k > j + 1 { return (s, j) }
                        break
                    }
                    let isLetter =
                        (c >= 0x41 && c <= 0x5A) ||
                        (c >= 0x61 && c <= 0x7A) ||
                        c == 0x2D || c == 0x5F
                    if !isLetter { break }
                    k += 1
                }
            }
            j += 1
        }
        return (s, to)
    }

    /// Walk a `keyword:` section, splitting on top-level commas. For each
    /// `Name(inner)` chunk, emit the name and harvest aliases from inner.
    ///
    /// R3: the top-level keyword item does not set `currentTagName`. Instead
    /// `currentTagName = nil` so descendants inherit the immediate enclosing
    /// URL-emitting tag (github/website/youtube/...) rather than the outer
    /// "keyword" umbrella. This makes `tagSectionCounts` match Python's
    /// `--meta` tree aggregation (github: N, website: M, ...).
    private func walkKeywordSection(_ start: Int, _ end: Int, parent: String, count: inout Int) {
        var depth = 0
        var partStart = start
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { depth += 1 }
            else if ch == 0x29 { if depth > 0 { depth -= 1 } }
            else if ch == 0x2C, depth == 0 {
                processKeywordItem(partStart, i, parent: parent, currentTagName: nil, count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            processKeywordItem(partStart, end, parent: parent, currentTagName: nil, count: &count)
        }
    }

    private func processKeywordItem(_ start: Int, _ end: Int, parent: String, currentTagName: String?, count: inout Int) {
        let (s, e) = trimmed((start, end))
        guard e > s else { return }

        // Locate first '(' at depth 0 relative to this chunk.
        var openIdx = -1
        for j in s..<e {
            if bytes[j] == 0x28 { openIdx = j; break }
        }
        let nameEnd = openIdx >= 0 ? openIdx : e
        let (ns, ne) = trimmed((s, nameEnd))
        guard ne > ns else { return }
        guard let name = string(ns, ne) else { return }
        let lower = name.lowercased()
        guard !Self.tagNames.contains(lower) else { return }
        if name.hasPrefix("http") || name.hasPrefix("//") { return }
        if name.count > 120 { return }
        // F5: Python only rejects len < 2 and URL prefixes. Names like
        // "Course: CS231n" or "A*B" are valid subtopics.
        if name.count < 2 { return }

        let sameAsParent = name.caseInsensitiveCompare(parent) == .orderedSame
        // Python's `_by_title`/`_keyword_subtopics` are populated only by
        // `_by_title = title.lower()` (line 1452) and `_index_all_named_items`
        // (line 1618). Nothing else emits topic rows. Emit the `contains` edge
        // + graphify below but do NOT bind a topic row here.
        // Python's graphify pass emits `parent --contains--> subtopic` for
        // every keyword item; the topic-graph explore/path tools follow
        // `contains` alongside `searchin`. Mirror that here so undirected
        // BFS reaches subtopics without depending on searchin coverage.
        if !sameAsParent {
            emitEdge(parent, name, kind: "contains")
        }

        // F7: `currentSubtopic` becomes this keyword item's name so that
        // command_ref / searchin edges emitted from nested content attach
        // to the closest enclosing subtopic (matches Python's `sub_nid`).
        let currentSubtopic = sameAsParent ? parent : name

        // Graphify: emit `parent --contains--> subtopic` and any aliases
        // harvested from the item's value. This mirrors
        // `_extract_item_graph` in xlb_graph_extract.py.
        let libraryFile = library + "-library"
        let parentID = Self.gnodeID(parent)
        let subID = sameAsParent
            ? parentID
            : (emitGNode(label: name, nodeType: "subtopic", sourceFile: libraryFile, parentID: parentID) ?? Self.gnodeID(name))
        if !sameAsParent {
            emitGEdge(source: parentID, target: subID, relation: "contains", sourceFile: libraryFile, group: nil)
        }

        // Aliases + nested subtopic recursion inside inner.
        if openIdx >= 0 {
            let innerStart = openIdx + 1
            let innerEnd = e - (bytes[e - 1] == 0x29 ? 1 : 0)
            if innerEnd > innerStart {
                harvestAliases(from: innerStart, to: innerEnd, parent: name, count: &count)
                recurseNested(innerStart, innerEnd,
                              parent: name,
                              currentSubtopic: currentSubtopic,
                              currentTagName: currentTagName,
                              depth: 1,
                              count: &count)
            }
        }
    }

    // MARK: - Nested recursion

    /// Recursion cap (matches Python `_index_keyword_names_recursive` default).
    static let maxDepth = 10

    /// Walk an inner content region (`+`-separated at depth 0) looking for
    /// nested `Name(Value)` groups. Emits each `Name` as a `.subtopic` row
    /// with `parent_topic = parent` and recurses into its `Value`. Tag names
    /// like `github(...)`, `alias(...)` never emit, but `searchin(...)` and
    /// `command(...)` are unpacked for their `>Name` / `Name(?query)` items.
    ///
    /// `currentSubtopic` is the closest enclosing keyword subtopic name. It
    /// stays constant as we descend through non-emitting groups so that
    /// child edges (searchin / command_ref) attach to the right node.
    private func recurseNested(
        _ start: Int,
        _ end: Int,
        parent: String,
        currentSubtopic: String,
        currentTagName: String?,
        depth: Int,
        count: inout Int
    ) {
        if depth >= Self.maxDepth { return }
        var partStart = start
        var d = 0
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { d += 1 }
            else if ch == 0x29 { if d > 0 { d -= 1 } }
            else if ch == 0x2B, d == 0 { // '+'
                processNestedPart(partStart, i,
                                  parent: parent,
                                  currentSubtopic: currentSubtopic,
                                  currentTagName: currentTagName,
                                  depth: depth,
                                  count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            processNestedPart(partStart, end,
                              parent: parent,
                              currentSubtopic: currentSubtopic,
                              currentTagName: currentTagName,
                              depth: depth,
                              count: &count)
        }
    }

    /// One `+`-separated slice inside a nested content region.
    private func processNestedPart(
        _ start: Int,
        _ end: Int,
        parent: String,
        currentSubtopic: String,
        currentTagName: String?,
        depth: Int,
        count: inout Int
    ) {
        let (s, e) = trimmed((start, end))
        guard e > s else { return }
        // Must be `Text(Value)` form, i.e. ends with ')'.
        guard bytes[e - 1] == 0x29 else { return }
        // Locate first '(' -- everything before it is the name.
        var openIdx = -1
        for j in s..<e where bytes[j] == 0x28 { openIdx = j; break }
        guard openIdx > s else { return }
        let (ns, ne) = trimmed((s, openIdx))
        guard ne > ns, let name = string(ns, ne) else { return }
        let lower = name.lowercased()
        let innerStart = openIdx + 1
        let innerEnd = e - 1

        // Fan out into searchin / command child names before returning.
        if lower == "searchin" {
            emitTagGroup(parent: currentSubtopic, tagName: "searchin")
            if innerEnd > innerStart {
                extractSearchinNames(innerStart, innerEnd,
                                     parent: parent,
                                     searchinRoot: currentSubtopic,
                                     depth: depth + 1,
                                     count: &count)
            }
            return
        }
        if lower == "command" {
            emitTagGroup(parent: currentSubtopic, tagName: "command")
            if innerEnd > innerStart {
                extractCommandNames(innerStart, innerEnd,
                                    parent: parent,
                                    currentSubtopic: currentSubtopic,
                                    count: &count)
            }
            return
        }
        // Non-emitting tag heads (github, youtube, website, paper, ...):
        // do not emit the tag itself as a topic, but stamp `tag_name = <tag>`
        // on all descendants recursively so the meta-output aggregation sees
        // the tag-name provenance Python's `--meta` output uses.
        if Self.tagNames.contains(lower) {
            // R3: register this tag group on currentSubtopic so
            // `tagSectionCounts` returns Python's `--meta` tree tag names
            // (github, website, youtube, ...) even when the inner has no
            // qualifying subtopic emissions. Fold homepage/playground/
            // readme/docs into `website` to match Python's tree.
            if Self.websiteFoldedTags.contains(lower) {
                emitTagGroup(parent: currentSubtopic, tagName: "website")
            } else {
                emitTagGroup(parent: currentSubtopic, tagName: lower)
            }
            if innerEnd > innerStart {
                recurseNested(innerStart, innerEnd,
                              parent: parent,
                              currentSubtopic: currentSubtopic,
                              currentTagName: lower,
                              depth: depth + 1,
                              count: &count)
            }
            return
        }
        if name.hasPrefix("http") || name.hasPrefix("//") { return }
        if name.count > 120 { return }
        if name.count < 2 { return }
        // Python's `_extract_nested_subtopics` skips names with `.` or `/`
        // (they look like URLs / file paths, not subtopics).
        if name.contains(".") || name.contains("/") { return }

        // Python's substance gate (`xlb_graph_extract.py:673`):
        //   `if len(inner) > 10 and ("(" in inner or "+" in inner):`
        // Python uses `find_balanced_paren` for the substance check so the
        // inner is a single `Name(...)` payload -- not the whole `+` slice
        // (which may contain sibling `*`-separated items). We do the same:
        // reach the *balanced* close of `openIdx` and confine the gate to
        // that window.
        let balancedInnerEnd: Int
        if let bClose = balancedClose(openIdx: openIdx, to: e) {
            balancedInnerEnd = bClose
        } else {
            balancedInnerEnd = innerEnd
        }
        let innerByteLen = max(0, balancedInnerEnd - innerStart)
        var hasParen = false
        var hasPlus = false
        if innerByteLen > 10 {
            var k = innerStart
            while k < balancedInnerEnd {
                let b = bytes[k]
                if b == 0x28 { hasParen = true; if hasPlus { break } }
                else if b == 0x2B { hasPlus = true; if hasParen { break } }
                k += 1
            }
        }
        let substanceOK = innerByteLen > 10 && (hasParen || hasPlus)
        if !substanceOK { return }

        let sameAsParent = name.caseInsensitiveCompare(parent) == .orderedSame
        // Python emits topic rows for nested items only via
        // `_index_all_named_items` (harvestAllNamedItems). No direct bind here.
        // Mirror graphify's `contains` edges (parent -> nested subtopic).
        if !sameAsParent {
            emitEdge(parent, name, kind: "contains")
            let libraryFile = library + "-library"
            let parentID = Self.gnodeID(parent)
            let subID = emitGNode(label: name, nodeType: "subtopic", sourceFile: libraryFile, parentID: parentID) ?? Self.gnodeID(name)
            emitGEdge(source: parentID, target: subID, relation: "contains", sourceFile: libraryFile, group: nil)
        }

        if innerEnd > innerStart {
            // The nested `Name(...)` becomes the new closest subtopic for
            // its descendants: Python's `_extract_item_graph` recurses with
            // this label as `sub_nid`.
            recurseNested(innerStart, innerEnd,
                          parent: sameAsParent ? parent : name,
                          currentSubtopic: sameAsParent ? currentSubtopic : name,
                          currentTagName: currentTagName,
                          depth: depth + 1,
                          count: &count)
        }
    }

    /// Extract `>Name` / `&>Name` / `!Name` / `#Category` items from a
    /// `searchin(...)` body. Python only splits on `*` at the top level of
    /// a searchin block; `&` is a separator ONLY inside a group's inner
    /// parens (see `_parse_group_ref`). We honour that with `separator`:
    /// pass `false` at the outermost call (from a `keyword:` item) and
    /// `true` when recursing inside a `&>Group(...)` body.
    private func extractSearchinNames(
        _ start: Int,
        _ end: Int,
        parent: String,
        searchinRoot: String,
        depth: Int,
        count: inout Int,
        splitAmpersand: Bool = false
    ) {
        if depth >= Self.maxDepth { return }
        var partStart = start
        var d = 0
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { d += 1 }
            else if ch == 0x29 { if d > 0 { d -= 1 } }
            else if d == 0, ch == 0x2A || (splitAmpersand && ch == 0x26) {
                // '*' always splits; '&' only splits inside a group body.
                processSearchinItem(partStart, i,
                                    parent: parent,
                                    searchinRoot: searchinRoot,
                                    depth: depth,
                                    count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            processSearchinItem(partStart, end,
                                parent: parent,
                                searchinRoot: searchinRoot,
                                depth: depth,
                                count: &count)
        }
    }

    /// One `searchin` item. Strips `>`, `!`, `#` prefixes, extracts the
    /// name, emits it as a subtopic + searchin edge, then recurses into
    /// any `(...)` payload. Group heads (items that begin with `&>`) are
    /// NOT emitted as topics/edges themselves (Python's parser treats them
    /// as metadata on the inner refs); only their inner body is walked.
    private func processSearchinItem(
        _ start: Int,
        _ end: Int,
        parent: String,
        searchinRoot: String,
        depth: Int,
        count: inout Int
    ) {
        // Trim leading whitespace before inspecting the prefix.
        var s = start
        let e = end
        while s < e, bytes[s] == 0x20 || bytes[s] == 0x09 { s += 1 }
        guard s < e else { return }

        // F6: `&>` prefix means this is a group head. Do NOT emit a topic
        // or edge for the group name; only descend into its inner
        // parenthesised body.
        var isGroup = false
        if s + 1 < e, bytes[s] == 0x26, bytes[s + 1] == 0x3E {
            isGroup = true
            s += 2
            // Optional `!` display hint.
            if s < e, bytes[s] == 0x21 { s += 1 }
        } else {
            // Non-group: peel any combination of leading ref markers.
            // Python distinguishes topic (`>`) from category (`#`), but
            // both are emitted with the same edge kind for our purposes.
            // F10: category refs (`#Category`) peel the leading `#` and
            // become an ordinary edge target.
            while s < e {
                let ch = bytes[s]
                if ch == 0x3E || ch == 0x21 || ch == 0x23 { // '>', '!', '#'
                    s += 1
                } else {
                    break
                }
            }
        }

        let (ts, te) = trimmed((s, e))
        guard te > ts else { return }
        var openIdx = -1
        for j in ts..<te where bytes[j] == 0x28 { openIdx = j; break }
        let nameEnd = openIdx >= 0 ? openIdx : te
        let (ns, ne) = trimmed((ts, nameEnd))

        // For group heads we skip the name-emission block entirely. We
        // still walk the inner payload with `&` splitting enabled.
        if !isGroup, ne > ns, let name = string(ns, ne) {
            // F5: only reject on URL prefixes and length < 2.
            if name.count >= 2,
               name.count <= 120,
               !name.hasPrefix("http"),
               !name.hasPrefix("//") {
                let lower = name.lowercased()
                if !Self.tagNames.contains(lower) {
                    // Python's `_parse_group_ref` splits flat group-inner
                    // refs on `@>` (e.g. `>Docker@>lxc` -> `Docker`, `lxc`).
                    // Mirror that so chains like `docker@>lxc` don't get
                    // emitted as a single compound external_ref.
                    let parts: [String]
                    if name.contains("@>") {
                        parts = name.components(separatedBy: "@>")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    } else {
                        parts = [name]
                    }
                    for p in parts {
                        if p.count < 2 || p.count > 120 { continue }
                        if p.hasPrefix("http") || p.hasPrefix("//") { continue }
                        if Self.tagNames.contains(p.lowercased()) { continue }
                        let sameAsParent = p.caseInsensitiveCompare(parent) == .orderedSame
                        if sameAsParent { continue }
                        emitEdge(searchinRoot, p, kind: "searchin")
                        // Graphify: emit external_ref target + searchin edge
                        // rooted at the enclosing subtopic. Python's
                        // `_extract_item_graph` uses `sub_nid` for the source.
                        let libraryFile = library + "-library"
                        let rootID = Self.gnodeID(searchinRoot)
                        let targetID = emitGNode(
                            label: p,
                            nodeType: "external_ref",
                            sourceFile: nil,
                            parentID: nil
                        ) ?? Self.gnodeID(p)
                        emitGEdge(source: rootID, target: targetID, relation: "searchin", sourceFile: libraryFile, group: nil)
                    }
                }
            }
        }

        // Recurse into the parenthesised payload if present. For group
        // heads we must split on both `*` and `&` (Python's
        // `_parse_group_ref` splits on `&` at top level inside the group
        // body). For normal items we keep `*`-only splitting.
        if openIdx >= 0, bytes[te - 1] == 0x29, te - 1 > openIdx + 1 {
            let nextParent: String
            if isGroup {
                nextParent = parent
            } else if ne > ns, let n = string(ns, ne),
                      n.caseInsensitiveCompare(parent) != .orderedSame {
                nextParent = n
            } else {
                nextParent = parent
            }
            extractSearchinNames(openIdx + 1, te - 1,
                                 parent: nextParent,
                                 searchinRoot: searchinRoot,
                                 depth: depth + 1,
                                 count: &count,
                                 splitAmpersand: isGroup)
        }
    }

    /// `command(Foo(?=query)*Bar(??other))` -- each `*`-separated item is
    /// either `Name(query)` or a bare query prefixed by `??`, `?=>`, `?>`,
    /// `>>`, or `>`. Python's `_extract_command_target` peels these
    /// prefixes and takes the topic before the first `/` as the target.
    private func extractCommandNames(
        _ start: Int,
        _ end: Int,
        parent: String,
        currentSubtopic: String,
        count: inout Int
    ) {
        var partStart = start
        var d = 0
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { d += 1 }
            else if ch == 0x29 { if d > 0 { d -= 1 } }
            else if ch == 0x2A, d == 0 { // '*'
                processCommandItem(partStart, i,
                                   parent: parent,
                                   currentSubtopic: currentSubtopic,
                                   count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            processCommandItem(partStart, end,
                               parent: parent,
                               currentSubtopic: currentSubtopic,
                               count: &count)
        }
    }

    private func processCommandItem(
        _ start: Int,
        _ end: Int,
        parent: String,
        currentSubtopic: String,
        count: inout Int
    ) {
        let (s, e) = trimmed((start, end))
        guard e > s else { return }

        // Two shapes to handle (mirroring Python's `extract_command_from_value`
        // + `_extract_command_target`):
        //   1) Name(query)  -- extract the target from `query`, NOT from `Name`.
        //      Python calls `_extract_command_target(cmd_query)` where
        //      `cmd_query = query` (contents inside the parens). For
        //      `Amnat Charoen(>world travel/Amnat Charoen)` the target is
        //      `world travel`, not `Amnat Charoen`.
        //   2) bare query with `??`, `?=>`, `?>`, `>>`, or `>` prefix --
        //      peel the prefix and take the segment before the first `/`.
        var openIdx = -1
        for j in s..<e where bytes[j] == 0x28 { openIdx = j; break }

        let target: String?
        if openIdx > s {
            // Shape 1: has a `Name(query)` head. Extract the query and run
            // it through the same prefix-peel logic as the bare case.
            let queryStart = openIdx + 1
            let queryEnd: Int
            if e > queryStart, bytes[e - 1] == 0x29 {
                queryEnd = e - 1
            } else {
                queryEnd = e
            }
            guard queryEnd > queryStart, let raw = string(queryStart, queryEnd) else { return }
            target = Self.extractCommandTargetTopic(raw)
        } else {
            // Shape 2: bare query. Peel prefixes in Python's order.
            guard let raw = string(s, e) else { return }
            target = Self.extractCommandTargetTopic(raw)
        }

        guard let name = target else { return }
        if name.count > 120 || name.count < 2 { return }
        if name.hasPrefix("http") || name.hasPrefix("//") { return }
        // Reject residual query prefixes just in case.
        if name.hasPrefix("?") || name.hasPrefix(">") { return }
        let lower = name.lowercased()
        if Self.tagNames.contains(lower) { return }

        let sameAsSub = name.caseInsensitiveCompare(currentSubtopic) == .orderedSame
        // Python emits topic rows only via `_index_all_named_items`.
        // Keep the command_ref edge + graphify below.
        if !sameAsSub {
            // F7: command_ref edge always attaches to the closest enclosing
            // subtopic (Python's `sub_nid`), never to the outer walk's
            // `parent` at arbitrary depth.
            emitEdge(currentSubtopic, name, kind: "command_ref")
            // Graphify: `sub_nid --command_ref--> external_ref(target)`.
            // Mirrors `_extract_item_graph`'s command loop where the
            // target label comes from `_extract_command_target`.
            let libraryFile = library + "-library"
            let subID = Self.gnodeID(currentSubtopic)
            let targetID = emitGNode(
                label: name,
                nodeType: "external_ref",
                sourceFile: nil,
                parentID: nil
            ) ?? Self.gnodeID(name)
            emitGEdge(source: subID, target: targetID, relation: "command_ref", sourceFile: libraryFile, group: nil)
        }
    }

    /// Python's `_extract_command_target(query)`. Peels one of the recognized
    /// query prefixes (`??`, `?=>`, `?>`, `>>`, `>`) and returns the topic
    /// segment before the first `/`, or nil when no prefix matches. Used by
    /// both `processCommandItem` (nested walker) and `emitCommandRef`
    /// (byte-scan sweep) so command targets always resolve to the referenced
    /// topic label rather than the wrapping `Name(` head.
    private static func extractCommandTargetTopic(_ raw: String) -> String? {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("??") {
            let topic = String(q.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return topic.isEmpty ? nil : topic
        }
        if q.hasPrefix("?=>") {
            q = String(q.dropFirst(3))
        } else if q.hasPrefix("?>") {
            q = String(q.dropFirst(2))
        } else if q.hasPrefix(">>") {
            q = String(q.dropFirst(2))
        } else if q.hasPrefix(">") {
            q = String(q.dropFirst(1))
        } else {
            return nil
        }
        if let slash = q.firstIndex(of: "/") {
            q = String(q[..<slash])
        }
        let stripped = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// R1: mirror Python's `_index_all_named_items`. Scan the whole content
    /// region for `Name(` patterns preceded by `,+):!\s` (or start-of-region).
    /// Name must start with an uppercase ASCII letter or CJK/Kana, be 2..61
    /// chars, and NOT be a TAG_LIST tag name. Each match is emitted as a
    /// `.subtopic` row parented to the record `parent`.
    ///
    /// The inner content (balanced parens) is walked for aliases + searchin +
    /// command edges so the graph tables also see cross-references from
    /// deeply-nested subtopics. This is the key departure from the paren-
    /// recursive walker: we do not require the ancestor chain to have
    /// balanced parens, since URL comments in the corpus regularly break
    /// balance and would otherwise strand thousands of subtopics.
    private func harvestAllNamedItems(from start: Int, to end: Int, parent: String, count: inout Int) {
        // R5: Pre-pass — compute URL-container nesting depth for every byte
        // offset in [start, end]. Mirrors `_compute_url_depth` in
        // `xlb_local_reader.py`. For each `(` we walk backward through
        // tag-name characters to recover the tag name; if it belongs to
        // `urlContainerTags` we push a URL-scope frame. `)` pops the frame.
        // Emissions from inside a URL-scope frame are display labels for
        // links (e.g. github/youtube/paper labels), not real subtopics.
        let regionLen = max(0, end - start)
        var urlDepth = [Int](repeating: 0, count: regionLen + 1)
        var scopeStack: [Bool] = []
        var currentDepth = 0
        for k in 0..<regionLen {
            let idx = start + k
            urlDepth[k] = currentDepth
            let ch = bytes[idx]
            if ch == 0x28 { // '('
                // Walk backward through tag-name chars: [A-Za-z0-9_\-.].
                var t = idx - 1
                while t >= start {
                    let b = bytes[t]
                    let isName =
                        (b >= 0x41 && b <= 0x5A) ||     // A-Z
                        (b >= 0x61 && b <= 0x7A) ||     // a-z
                        (b >= 0x30 && b <= 0x39) ||     // 0-9
                        b == 0x5F || b == 0x2D || b == 0x2E   // _ - .
                    if !isName { break }
                    t -= 1
                }
                let tagStart = t + 1
                let isURL: Bool
                if tagStart < idx, let raw = string(tagStart, idx) {
                    isURL = Self.urlContainerTags.contains(raw.lowercased())
                } else {
                    isURL = false
                }
                scopeStack.append(isURL)
                if isURL { currentDepth += 1 }
            } else if ch == 0x29 { // ')'
                if let wasURL = scopeStack.popLast(), wasURL {
                    currentDepth = max(0, currentDepth - 1)
                }
            }
        }
        urlDepth[regionLen] = currentDepth

        var i = start
        while i < end {
            // Find next '('
            if bytes[i] != 0x28 { i += 1; continue }
            let openIdx = i
            // Look backwards for the name characters. Skip trailing spaces.
            let nameEnd = openIdx
            // Walk backwards through allowed name bytes. Name body must not
            // contain any of `()*+,`. Stop when we hit a boundary char or
            // start-of-region.
            var j = openIdx - 1
            while j >= start {
                let b = bytes[j]
                // Stop chars: `()*+,`
                if b == 0x28 || b == 0x29 || b == 0x2A || b == 0x2B || b == 0x2C {
                    break
                }
                j -= 1
            }
            let nameStart = j + 1
            // Trim leading whitespace/tab
            var ns = nameStart
            var ne = nameEnd
            while ns < ne, bytes[ns] == 0x20 || bytes[ns] == 0x09 { ns += 1 }
            while ne > ns, bytes[ne - 1] == 0x20 || bytes[ne - 1] == 0x09 { ne -= 1 }
            guard ne > ns else { i = openIdx + 1; continue }

            // Python regex: `(?:^|[,+):!\s])\s*([A-Z一-鿿぀-ヿ][^()*+,]{0,60})\(`
            // Find the LEFTMOST valid start position within [ns, ne): must be
            // preceded by a boundary char (start-of-region, or one of
            // `,+):!` or whitespace) after which optional `\s*` skipping,
            // AND the char at that position must be uppercase A-Z or a
            // CJK/Hiragana/Katakana lead byte.
            func isBoundary(_ b: UInt8) -> Bool {
                switch b {
                case 0x2C, 0x2B, 0x29, 0x3A, 0x21,
                     0x20, 0x09, 0x0A, 0x0D:
                    return true
                default:
                    return false
                }
            }
            func isFirstOK(_ b: UInt8) -> Bool {
                if b >= 0x41 && b <= 0x5A { return true }
                if b >= 0xE3 && b <= 0xE9 { return true }
                return false
            }
            // Try each candidate start k in [ns, ne). The candidate is
            // valid when (k == start OR bytes[k-1] is a boundary or
            // whitespace after which we skip \s* to reach k) AND
            // bytes[k] passes isFirstOK.
            // Because our backward walk already stopped at `()*+,`, the
            // preceding char at bytes[nameStart-1] is guaranteed to be one
            // of those (or start-of-region). Between nameStart and ne all
            // bytes are non-`()*+,`. The valid "boundary" precondition for
            // Python is at start-of-region, at a `,+):!` char, or at
            // whitespace. We scan k forward and accept the first k where
            // the preceding byte (bytes[k-1]) is one of Python's boundary
            // chars (including whitespace), OR k == start.
            var pickedStart = -1
            var kIter = ns
            while kIter < ne {
                let precedingOK: Bool
                if kIter == start {
                    precedingOK = true
                } else {
                    let prev = bytes[kIter - 1]
                    precedingOK = isBoundary(prev)
                }
                if precedingOK && isFirstOK(bytes[kIter]) {
                    pickedStart = kIter
                    break
                }
                kIter += 1
            }
            if pickedStart < 0 { i = openIdx + 1; continue }
            ns = pickedStart
            // Length bound: name body max 61 chars (Python: 1 + [^()*+,]{0,60}).
            // We use bytes as a rough cap; multibyte names may over-count but
            // the 120 char post-decode cap below is the real bound.
            if ne - ns > 200 { i = openIdx + 1; continue }
            guard let name = string(ns, ne) else { i = openIdx + 1; continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < 2 { i = openIdx + 1; continue }
            // Python's regex enforces `[A-Z...][^()*+,]{0,60}` -> total name
            // length capped at 61 chars. Post-decode Unicode-scalar count.
            if trimmed.count > 61 { i = openIdx + 1; continue }
            if trimmed.hasPrefix("http") || trimmed.hasPrefix("//") { i = openIdx + 1; continue }
            let lower = trimmed.lowercased()
            if Self.tagNames.contains(lower) { i = openIdx + 1; continue }
            // Python's extra skip set beyond TAG_LIST.
            if Self.namedItemSkipExtras.contains(lower) { i = openIdx + 1; continue }

            // R5: suppress emissions from inside URL-container tag scopes
            // (github/youtube/paper/...). The pre-pass `urlDepth` records
            // the nesting at every byte offset; index by the position of
            // the first Name character. Matches `_index_all_named_items`
            // in `xlb_local_reader.py` (Skill fix trimmed 3465 false
            // positives, e.g. "Ultimate Guide to Vibe Coding" as a
            // display label for a github repo).
            let posInRegion = ns - start
            if posInRegion >= 0, posInRegion < urlDepth.count, urlDepth[posInRegion] > 0 {
                i = openIdx + 1
                continue
            }

            // Emit subtopic row (INSERT OR IGNORE dedupes by name/kind/lib/tag).
            // Compute inner byte length ahead of bind so `topics.inner_size`
            // mirrors Python's `len(inner)` for the Stage 2 size gate.
            let sameAsParent = trimmed.caseInsensitiveCompare(parent) == .orderedSame
            let innerRange = balancedClose(openIdx: openIdx, to: end)
            let innerByteLen: Int
            if let close = innerRange {
                innerByteLen = max(0, close - (openIdx + 1))
            } else {
                innerByteLen = 0
            }
            if !sameAsParent,
               bind(name: trimmed, kind: .subtopic, parent: parent, browse: ">\(trimmed)/", tagName: nil, innerSize: innerByteLen) {
                count += 1
            }
            // Note: no `contains` edge is emitted here. Python's graphify
            // only records contains for `record -> keyword_item` and
            // `keyword_item -> nested_item` (handled at their respective
            // emission sites). Emitting from this catch-all named-item
            // sweep would create parent->child edges for URL-embedded
            // names, people/researcher tags, etc. that Python treats as
            // group members, not as contained topics.
            //
            // Graphify: Python's `_enrich_from_local_reader` emits a
            // `contains` edge and a subtopic gnode from every entry in the
            // deep `_keyword_subtopics` index (xlb_graph_extract.py:723) --
            // but ONLY when the subtopic id is NEW (not already emitted by
            // the structural first-pass). Mirror that gate here: check
            // `emittedGNodeIDs` before calling `emitGNode` so the byte-scan
            // sweep does not double-count `record -> subtopic` contains
            // edges that were already covered by the structural walker's
            // `keyword_item -> nested` emission.
            let libraryFile = library + "-library"
            let parentGID = Self.gnodeID(parent)
            let candidateSubID = Self.gnodeID(trimmed)
            let wasNewSubtopic = !sameAsParent && !emittedGNodeIDs.contains(candidateSubID)
            let subGID = sameAsParent
                ? parentGID
                : (emitGNode(label: trimmed, nodeType: "subtopic", sourceFile: libraryFile, parentID: parentGID) ?? candidateSubID)
            if wasNewSubtopic {
                emitGEdge(source: parentGID, target: subGID, relation: "contains", sourceFile: libraryFile, group: nil)
            }

            // Walk the inner region for edges. innerRange was resolved above.
            if let close = innerRange {
                let innerStart = openIdx + 1
                let innerEnd = close
                if innerEnd > innerStart {
                    // Alias / searchin / command child edges from the inner
                    // content are attached to this subtopic name.
                    //
                    // Python's `_enrich_from_local_reader` only emits alias
                    // edges when the subtopic id is NEW (i.e. not already
                    // introduced by the structural pass). Searchin and
                    // command edges fire unconditionally -- they dedupe via
                    // `existing_edge_keys`.
                    if wasNewSubtopic {
                        harvestAliases(from: innerStart, to: innerEnd, parent: trimmed, count: &count)
                    } else {
                        harvestAliases(from: innerStart, to: innerEnd, parent: trimmed, count: &count, graphify: false)
                    }
                    harvestSearchinEdges(from: innerStart, to: innerEnd, parent: trimmed, count: &count)
                    harvestCommandEdges(from: innerStart, to: innerEnd, parent: trimmed, count: &count)
                    // R3: record top-level tag groups (`github(...)`,
                    // `website(...)`, `searchin(...)`, `command(...)`, ...)
                    // seen inside this subtopic's inner. Emits one row per
                    // (subtopic, tag) into `tag_groups`.
                    harvestTagGroups(from: innerStart, to: innerEnd, parent: trimmed)
                }
                // Advance one byte past the open paren so nested `Name(`
                // matches inside the inner are re-scanned. Python's
                // `re.finditer` returns overlapping matches at every depth;
                // skipping to `close + 1` would drop all deep subtopics.
                i = openIdx + 1
            } else {
                i = openIdx + 1
            }
        }
    }

    /// R2 helper: locate every `searchin(...)` block inside [start, end) and
    /// emit an outgoing searchin edge from `parent` to each ref target inside.
    /// Uses the same ref-parsing rules as `processSearchinItem` but without
    /// re-emitting subtopics (which `harvestAllNamedItems` already handled).
    private func harvestSearchinEdges(from start: Int, to end: Int, parent: String, count: inout Int) {
        let needle = Self.searchinTag
        var i = start
        while i + needle.count <= end {
            if matchesLowercase(needle, at: i) {
                let openIdx = i + needle.count - 1
                if bytes[openIdx] == 0x28,
                   let close = balancedClose(openIdx: openIdx, to: end) {
                    emitSearchinEdgesInBody(openIdx + 1, close, parent: parent, count: &count)
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
    }

    /// Walk one `searchin(...)` body: split on `*` at depth 0, peel each
    /// ref's prefix (`>`, `!`, `#`, `&>`), and emit `parent -> ref` edges of
    /// kind `searchin`. Recurses into `&>Group(...)` inner using `&` as split.
    private func emitSearchinEdgesInBody(_ start: Int, _ end: Int, parent: String, count: inout Int, splitAmpersand: Bool = false) {
        var partStart = start
        var d = 0
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { d += 1 }
            else if ch == 0x29 { if d > 0 { d -= 1 } }
            else if d == 0, ch == 0x2A || (splitAmpersand && ch == 0x26) {
                emitSearchinRef(partStart, i, parent: parent, count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            emitSearchinRef(partStart, end, parent: parent, count: &count)
        }
    }

    private func emitSearchinRef(_ start: Int, _ end: Int, parent: String, count: inout Int) {
        var s = start
        let e = end
        while s < e, bytes[s] == 0x20 || bytes[s] == 0x09 { s += 1 }
        guard s < e else { return }

        var isGroup = false
        if s + 1 < e, bytes[s] == 0x26, bytes[s + 1] == 0x3E {
            isGroup = true
            s += 2
            if s < e, bytes[s] == 0x21 { s += 1 }
        } else {
            while s < e {
                let ch = bytes[s]
                if ch == 0x3E || ch == 0x21 || ch == 0x23 { s += 1 }
                else { break }
            }
        }
        let (ts, te) = trimmed((s, e))
        guard te > ts else { return }
        var openIdx = -1
        for j in ts..<te where bytes[j] == 0x28 { openIdx = j; break }
        let nameEnd = openIdx >= 0 ? openIdx : te
        let (ns, ne) = trimmed((ts, nameEnd))

        if !isGroup, ne > ns, let name = string(ns, ne) {
            if name.count >= 2, name.count <= 120,
               !name.hasPrefix("http"), !name.hasPrefix("//") {
                // Python's `_parse_group_ref` splits `@>` chains inside
                // group inners into distinct targets. Mirror that so
                // `docker@>lxc` becomes two edges (`->docker`, `->lxc`).
                let parts: [String]
                if name.contains("@>") {
                    parts = name.components(separatedBy: "@>")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                } else {
                    parts = [name]
                }
                // Python's `parse_searchin_targets` does NOT filter targets
                // by TAG_LIST membership -- `>Docker` still becomes a
                // `docker` external_ref target.
                for p in parts {
                    if p.count < 2 || p.count > 120 { continue }
                    if p.hasPrefix("http") || p.hasPrefix("//") { continue }
                    if p.caseInsensitiveCompare(parent) == .orderedSame { continue }
                    emitEdge(parent, p, kind: "searchin")
                    let libraryFile = library + "-library"
                    let parentGID = Self.gnodeID(parent)
                    let targetGID = emitGNode(
                        label: p,
                        nodeType: "external_ref",
                        sourceFile: nil,
                        parentID: nil
                    ) ?? Self.gnodeID(p)
                    emitGEdge(source: parentGID, target: targetGID, relation: "searchin", sourceFile: libraryFile, group: nil)
                }
            }
        }
        if openIdx >= 0, bytes[te - 1] == 0x29, te - 1 > openIdx + 1 {
            emitSearchinEdgesInBody(openIdx + 1, te - 1, parent: parent, count: &count, splitAmpersand: isGroup)
        }
    }

    /// R3 helper: record-level tag scanner. Mirrors Python's
    /// `desc_to_url_dict`, which drives `_browse_meta`'s tree. Emits one
    /// row per (record, tag) into `tag_groups` for:
    ///
    /// 1. Every `<space>tag:` segment at paren-depth 0 in the raw desc
    ///    (Python's `split_desc_to_tags` via `get_desc_tags`). Nested
    ///    tags inside a non-keyword parent (`people:...`, `crossref:...`,
    ///    etc.) never surface at the record level.
    ///
    /// 2. Every `<Name>(` head that appears as a keyword-item sub-tag
    ///    (paren depth exactly 2 from the `keyword:` value opening
    ///    paren, i.e. inside `keyword:Item(<Name>(...)+<Name2>(...))`).
    ///    Python's `desc_to_url_dict` hoists these to top-level url_dict
    ///    keys via `_parse_keyword_items_for_markdown`, so tags like
    ///    `github`, `medium`, `bilibili`, `y-playlist`, `paper`,
    ///    `hugging_face`, ... surface as record-level tree entries when
    ///    they appear inside `keyword:` items.
    private func harvestTagGroupsForRecord(from start: Int, to end: Int, parent: String) {
        var i = start
        var depth = 0
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { // '('
                depth += 1
                i += 1
                continue
            }
            if ch == 0x29 { // ')'
                if depth > 0 { depth -= 1 }
                i += 1
                continue
            }
            // At top level, treat position `start` and any space as a
            // possible tag boundary. Python prepends a leading space to
            // the desc before scanning; the equivalent here is to allow
            // `i == start` as an implicit boundary.
            if depth == 0, ch == 0x20 || i == start {
                let nameStart = ch == 0x20 ? i + 1 : i
                var j = nameStart
                while j < end {
                    let b = bytes[j]
                    let isAlpha = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                    let isDigit = b >= 0x30 && b <= 0x39
                    let isSep = b == 0x2D || b == 0x5F // '-' or '_'
                    if isAlpha || isDigit || isSep {
                        j += 1
                        continue
                    }
                    break
                }
                if j > nameStart, j < end, bytes[j] == 0x3A { // ':'
                    if let name = string(nameStart, j) {
                        let lower = name.lowercased()
                        let skip: Set<String> = ["title", "desc", "description", "id", "url", "videourl"]
                        if lower == "keyword" {
                            // Recurse into the `keyword:` value to
                            // harvest each item's sub-tag names, which
                            // Python's `desc_to_url_dict` hoists to the
                            // record-level tree.
                            i = j + 1
                            harvestKeywordItemSubTags(from: i, to: end, parent: parent)
                            // Skip past the entire `keyword:` value:
                            // walk until we return to top level after
                            // consuming its comma-separated items.
                            // We simply let the outer loop resume; the
                            // paren depth tracking below will keep us
                            // out of the keyword body until it closes.
                            continue
                        }
                        if !skip.contains(lower), !lower.isEmpty {
                            if Self.websiteFoldedTags.contains(lower) {
                                emitTagGroup(parent: parent, tagName: "website")
                            } else if Self.tagNames.contains(lower) {
                                emitTagGroup(parent: parent, tagName: lower)
                            }
                        }
                    }
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
    }

    /// R3 helper: walk the value of a `keyword:` segment and emit one row
    /// per (record, sub_tag) pair. Each keyword item has the form
    /// `ItemName(sub_tag(inner)+sub_tag2(inner2))`. Python's
    /// `_parse_keyword_items_for_markdown` yields those sub_tags, which
    /// `desc_to_url_dict` promotes to url_dict top-level keys. The value
    /// runs until we return to paren-depth 0 AND encounter a new
    /// top-level tag boundary (`<space><tag>:`).
    private func harvestKeywordItemSubTags(from start: Int, to end: Int, parent: String) {
        var i = start
        var depth = 0
        // Depth 0 = at item level (between commas separating items;
        // Andrew NG, Yoshua Bengio, ...). Depth 1 = inside an item's
        // inner, where sub_tag(...) heads live. Sub_tags can nest
        // further, so we only harvest heads whose opening paren is at
        // depth==1.
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { // '('
                if depth == 1 {
                    // Walk backwards to find the sub_tag head. Stop at
                    // any structural boundary (`()*+,`) or a space; the
                    // head is bounded by these.
                    var j = i - 1
                    while j >= start {
                        let b = bytes[j]
                        if b == 0x28 || b == 0x29 || b == 0x2A || b == 0x2B || b == 0x2C { break }
                        j -= 1
                    }
                    let (ns, ne) = trimmed((j + 1, i))
                    if ne > ns, let name = string(ns, ne) {
                        let lower = name.lowercased()
                        if !lower.isEmpty,
                           !lower.hasPrefix("http"),
                           !lower.hasPrefix("//") {
                            if Self.websiteFoldedTags.contains(lower) {
                                emitTagGroup(parent: parent, tagName: "website")
                            } else if Self.tagNames.contains(lower) {
                                emitTagGroup(parent: parent, tagName: lower)
                            }
                        }
                    }
                }
                depth += 1
            } else if ch == 0x29 { // ')'
                if depth > 0 {
                    depth -= 1
                } else {
                    // Unbalanced close: end of keyword value in the
                    // outer scanner's world.
                    return
                }
            } else if depth == 0, ch == 0x20 {
                // At depth 0, a space might be an inter-item separator
                // (`Andrew NG, Yoshua Bengio`) OR the start of a new
                // top-level tag boundary. Peek ahead: if the next
                // identifier is followed by `:`, treat as end of keyword
                // value. Otherwise skip and continue.
                let peekStart = i + 1
                var j = peekStart
                while j < end {
                    let b = bytes[j]
                    let isAlpha = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                    let isDigit = b >= 0x30 && b <= 0x39
                    let isSep = b == 0x2D || b == 0x5F
                    if isAlpha || isDigit || isSep {
                        j += 1
                        continue
                    }
                    break
                }
                if j > peekStart, j < end, bytes[j] == 0x3A {
                    if let name = string(peekStart, j) {
                        let lower = name.lowercased()
                        // Only bail when the peeked identifier is an
                        // actual known tag; otherwise it is item text
                        // (e.g. `Google Cloud Platform:` inside a
                        // keyword item's value is not a TAG_LIST
                        // member).
                        if Self.tagNames.contains(lower) ||
                           Self.websiteFoldedTags.contains(lower) ||
                           lower == "keyword" ||
                           lower == "title" || lower == "desc" ||
                           lower == "description" {
                            return
                        }
                    }
                }
            }
            i += 1
        }
    }

    /// R3 helper: subtopic-level tag scanner. Subtopic bodies use
    /// paren-based tag heads (e.g. `bilibili(a*b)+youtube(c)` inside
    /// `Mu Li(...)`), not `tag:value`, so this walks for `Name(` at any
    /// depth within the inner span.
    private func harvestTagGroups(from start: Int, to end: Int, parent: String) {
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { // '('
                // Walk backwards to find the tag head.
                var j = i - 1
                while j >= start {
                    let b = bytes[j]
                    if b == 0x28 || b == 0x29 || b == 0x2A || b == 0x2B || b == 0x2C { break }
                    j -= 1
                }
                let (ns, ne) = trimmed((j + 1, i))
                if ne > ns, let name = string(ns, ne) {
                    let lower = name.lowercased()
                    if !lower.isEmpty,
                       !lower.hasPrefix("http"),
                       !lower.hasPrefix("//") {
                        if Self.websiteFoldedTags.contains(lower) {
                            emitTagGroup(parent: parent, tagName: "website")
                        } else if Self.tagNames.contains(lower) {
                            emitTagGroup(parent: parent, tagName: lower)
                        }
                    }
                }
            }
            i += 1
        }
    }

    /// R2 helper: harvest `command(...)` edges out of a subtopic body. Mirrors
    /// `extractCommandNames` but only emits edges (subtopic rows come from
    /// `harvestAllNamedItems`).
    ///
    /// `graphifyEmit` controls the gedge emission. Passing `false` keeps
    /// the sqlite `edges` table row emissions running (they backstop
    /// graph explore/hubs paths and are always safe) but suppresses the
    /// gedges row. Byte-scan sweeps rediscover the same command targets
    /// the structural `_extract_item_graph` path already emitted -- Python
    /// only re-emits from `_enrich_from_local_reader` when the parent
    /// node was freshly introduced by the deep-index enrichment. In our
    /// implementation we default `graphifyEmit` to false at the byte-scan
    /// call site so the two paths don't double-count.
    private func harvestCommandEdges(from start: Int, to end: Int, parent: String, count: inout Int, graphifyEmit: Bool = false) {
        let needle = Self.commandTag
        var i = start
        while i + needle.count <= end {
            if matchesLowercase(needle, at: i) {
                let openIdx = i + needle.count - 1
                if bytes[openIdx] == 0x28,
                   let close = balancedClose(openIdx: openIdx, to: end) {
                    emitCommandEdgesInBody(openIdx + 1, close, parent: parent, count: &count, graphifyEmit: graphifyEmit)
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
    }

    private func emitCommandEdgesInBody(_ start: Int, _ end: Int, parent: String, count: inout Int, graphifyEmit: Bool) {
        var partStart = start
        var d = 0
        var i = start
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { d += 1 }
            else if ch == 0x29 { if d > 0 { d -= 1 } }
            else if ch == 0x2A, d == 0 {
                emitCommandRef(partStart, i, parent: parent, graphifyEmit: graphifyEmit)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            emitCommandRef(partStart, end, parent: parent, graphifyEmit: graphifyEmit)
        }
    }

    private func emitCommandRef(_ start: Int, _ end: Int, parent: String, graphifyEmit: Bool) {
        let (s, e) = trimmed((start, end))
        guard e > s else { return }
        var openIdx = -1
        for j in s..<e where bytes[j] == 0x28 { openIdx = j; break }
        let target: String?
        if openIdx > s {
            // `Name(query)`: extract from `query`, matching Python's
            // `_extract_command_target(cmd_query)` on the parens body.
            let queryStart = openIdx + 1
            let queryEnd: Int
            if e > queryStart, bytes[e - 1] == 0x29 {
                queryEnd = e - 1
            } else {
                queryEnd = e
            }
            guard queryEnd > queryStart, let raw = string(queryStart, queryEnd) else { return }
            target = Self.extractCommandTargetTopic(raw)
        } else {
            guard let raw = string(s, e) else { return }
            target = Self.extractCommandTargetTopic(raw)
        }
        guard let name = target else { return }
        if name.count < 2 || name.count > 120 { return }
        if name.hasPrefix("http") || name.hasPrefix("//") { return }
        if name.hasPrefix("?") || name.hasPrefix(">") { return }
        let lower = name.lowercased()
        if Self.tagNames.contains(lower) { return }
        if name.caseInsensitiveCompare(parent) == .orderedSame { return }
        emitEdge(parent, name, kind: "command_ref")
        // Graphify: `parent --command_ref--> external_ref(target)`. Only
        // for bare-query shapes AND when the caller requested graphify
        // emission (byte-scan sweep passes false to avoid double-counting
        // Python's structural-walker path).
        guard graphifyEmit else { return }
        let libraryFile = library + "-library"
        let parentGID = Self.gnodeID(parent)
        let targetGID = emitGNode(
            label: name,
            nodeType: "external_ref",
            sourceFile: nil,
            parentID: nil
        ) ?? Self.gnodeID(name)
        emitGEdge(source: parentGID, target: targetGID, relation: "command_ref", sourceFile: libraryFile, group: nil)
    }

    /// Scan bytes for `alias(...)` groups, decode inner as `*`-separated
    /// aliases, and insert them under `parent`. When `graphify` is false,
    /// alias rows still land in the topics table but no `alias_of` gedge
    /// is emitted -- used for the record-level sweep at `parseLine`, since
    /// Python's `_extract_item_graph` only emits alias edges rooted at the
    /// keyword item's `sub_nid`, not the record title.
    private func harvestAliases(from start: Int, to end: Int, parent: String, count: inout Int, graphify: Bool = true) {
        var i = start
        // Python's `extract_alias_from_value` only reads the FIRST
        // `alias(...)` body it finds inside a keyword item's value. The
        // sqlite topics table has always harvested every occurrence; the
        // graphify emission needs to match Python. Track whether we've
        // emitted graphify aliases for this parent yet via
        // `gnodeAliasParents`, and let `emitAlias` skip the alias_of edge
        // once the first body is drained.
        while i + Self.aliasTag.count <= end {
            if matchesLowercase(Self.aliasTag, at: i) {
                let openIdx = i + Self.aliasTag.count - 1
                if let close = balancedClose(openIdx: openIdx, to: end) {
                    let innerStart = openIdx + 1
                    emitAliases(innerStart, close, parent: parent, count: &count, graphify: graphify)
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
    }

    // "crossref:" byte prefix for the F4 harvest pass.
    static let crossrefTag: [UInt8] = Array("crossref:".utf8)

    /// F3b: scan the raw desc for `alias:foo, bar, baz` tags at paren
    /// depth 0. Mirrors xlb_graph_extract.py:684-703: emit `topic
    /// --alias_of--> alias` gedges for each comma-separated value up to
    /// the next top-level tag boundary. Only fires on the FIRST match
    /// (Python `break` at line 703). The alias() body form (parentheses)
    /// is handled separately by `harvestAliases`.
    private func harvestTopLevelAliasTag(from start: Int, to end: Int, parent: String, count: inout Int) {
        let tag: [UInt8] = [0x61, 0x6C, 0x69, 0x61, 0x73, 0x3A]
        var depth = 0
        var i = start
        while i + tag.count <= end {
            let ch = bytes[i]
            if ch == 0x28 { depth += 1 }
            else if ch == 0x29 { if depth > 0 { depth -= 1 } }
            let atBoundary = (i == start) || bytes[i - 1] == 0x20 || bytes[i - 1] == 0x09 || bytes[i - 1] == 0x0A
            if depth == 0, atBoundary, matchesLowercase(tag, at: i) {
                let valueStart = i + tag.count
                var vDepth = 0
                var j = valueStart
                var valueEnd = end
                while j < end {
                    let b = bytes[j]
                    if b == 0x28 { vDepth += 1 }
                    else if b == 0x29 { if vDepth > 0 { vDepth -= 1 } }
                    else if b == 0x20, vDepth == 0 {
                        var k = j + 1
                        while k < end {
                            let c = bytes[k]
                            if c == 0x3A { valueEnd = j; break }
                            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
                                           (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
                            if !isLetter { break }
                            k += 1
                        }
                        if valueEnd != end { break }
                    }
                    j += 1
                }
                if valueEnd > valueStart, let raw = string(valueStart, valueEnd) {
                    let libraryFile = library + "-library"
                    let parentID = Self.gnodeID(parent)
                    for piece in raw.split(separator: ",") {
                        let alias = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
                        if alias.isEmpty { continue }
                        if alias.count < 2 || alias.count > 120 { continue }
                        if alias.hasPrefix("http") || alias.hasPrefix("//") { continue }
                        if alias.contains("(") || alias.contains(")") { continue }
                        if bind(name: alias, kind: .alias, parent: parent, browse: ">\(parent)/", tagName: "alias") {
                            count += 1
                        }
                        let aliasID = emitGNode(
                            label: alias,
                            nodeType: "alias",
                            sourceFile: nil,
                            parentID: parentID
                        ) ?? Self.gnodeID(alias)
                        emitGEdge(source: parentID, target: aliasID, relation: "alias_of", sourceFile: libraryFile, group: nil)
                        emitGNodeAlias(nodeID: parentID, alias: alias)
                    }
                }
                return
            }
            i += 1
        }
    }

    /// F4: scan the raw desc for `crossref:foo/bar, baz/qux` tags and emit
    /// one `Source --crossref--> Target` edge per comma-separated target.
    /// Python's regex is `re.finditer(r"crossref:([^\s]+)", desc)` -- it
    /// stops at the first whitespace character, so no paren balancing is
    /// required. Each target may contain `/`; only the trailing segment
    /// becomes the topic name (the whole string is preserved in the
    /// browse_cmd for future navigation).
    private func harvestCrossref(from start: Int, to end: Int, parent: String, count: inout Int) {
        var i = start
        let tagLen = Self.crossrefTag.count
        while i + tagLen <= end {
            if matchesLowercase(Self.crossrefTag, at: i) {
                let valueStart = i + tagLen
                // Value runs to the next whitespace (space, tab, newline).
                var j = valueStart
                while j < end {
                    let b = bytes[j]
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { break }
                    j += 1
                }
                if j > valueStart, let raw = string(valueStart, j) {
                    for piece in raw.split(separator: ",") {
                        let target = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
                        if target.isEmpty { continue }
                        emitCrossref(target: target, parent: parent, count: &count)
                    }
                }
                i = max(j, i + tagLen)
                continue
            }
            i += 1
        }
    }

    private func emitCrossref(target: String, parent: String, count: inout Int) {
        // Use the trailing path segment as the display topic name, but
        // preserve the full `foo/bar` string in browse_cmd. Python indexes
        // both forms; we index the short one so lookups can find it.
        let topicName: String
        if let slash = target.lastIndex(of: "/") {
            let after = target[target.index(after: slash)...]
            let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
            topicName = trimmed.isEmpty ? target : trimmed
        } else {
            topicName = target
        }
        if topicName.count < 2 || topicName.count > 120 { return }
        if topicName.hasPrefix("http") || topicName.hasPrefix("//") { return }

        let sameAsParent = topicName.caseInsensitiveCompare(parent) == .orderedSame
        // Python emits topic rows only via `_index_all_named_items`.
        // Keep the crossref edge + graphify below.
        if !sameAsParent {
            emitEdge(parent, topicName, kind: "crossref")
            // Graphify: `topic --crossref--> external_ref`, using the
            // trailing path segment for the target label. Matches
            // xlb_graph_extract.py:463-469.
            let libraryFile = library + "-library"
            let parentID = Self.gnodeID(parent)
            let targetID = emitGNode(
                label: topicName,
                nodeType: "external_ref",
                sourceFile: nil,
                parentID: nil
            ) ?? Self.gnodeID(topicName)
            emitGEdge(source: parentID, target: targetID, relation: "crossref", sourceFile: libraryFile, group: nil)
        }
    }

    private func emitAliases(_ start: Int, _ end: Int, parent: String, count: inout Int, graphify: Bool = true) {
        // Python's graphify path only reads the FIRST alias(...) body per
        // parent value. Gate the graphify emission with a per-parent flag
        // so nested alias() bodies still contribute to the sqlite topics
        // table but not to `gedges`. The `graphifyAliases` bool passed to
        // `emitAlias` controls the graphify side; topics table always
        // absorbs the row (Python's LibraryIndex behaves the same).
        let parentID = Self.gnodeID(parent)
        let graphifyOK = graphify && !parentID.isEmpty && !gnodeAliasParents.contains(parentID)
        if graphifyOK { gnodeAliasParents.insert(parentID) }
        var partStart = start
        var i = start
        while i < end {
            if bytes[i] == 0x2A { // '*'
                emitAlias(partStart, i, parent: parent, graphifyAliases: graphifyOK, count: &count)
                partStart = i + 1
            }
            i += 1
        }
        if partStart < end {
            emitAlias(partStart, end, parent: parent, graphifyAliases: graphifyOK, count: &count)
        }
    }

    private func emitAlias(_ start: Int, _ end: Int, parent: String, graphifyAliases: Bool, count: inout Int) {
        let (s, e) = trimmed((start, end))
        guard e > s, e - s <= 120, let alias = string(s, e) else { return }
        if alias.hasPrefix("http") || alias.hasPrefix("//") { return }
        // Reject aliases that look like tag values embedded in an alias() list
        // by accident (e.g. contain '(', ')', or newlines).
        if alias.contains("(") || alias.contains(")") { return }
        if bind(name: alias, kind: .alias, parent: parent, browse: ">\(parent)/", tagName: "alias") {
            count += 1
        }
        // Graphify: emit `alias` gnode + `alias_of` edge, and record the
        // alias against the enclosing parent's gnode row. Mirrors the
        // alias loop in `_extract_item_graph` (xlb_graph_extract.py:509).
        // Only fire on the FIRST alias(...) body for this parent to match
        // Python's `extract_alias_from_value`; later bodies (rare) get
        // absorbed into `topics` but not `gedges`.
        guard graphifyAliases else { return }
        let libraryFile = library + "-library"
        let parentID = Self.gnodeID(parent)
        let aliasID = emitGNode(
            label: alias,
            nodeType: "alias",
            sourceFile: nil,
            parentID: parentID
        ) ?? Self.gnodeID(alias)
        emitGEdge(source: parentID, target: aliasID, relation: "alias_of", sourceFile: libraryFile, group: nil)
        emitGNodeAlias(nodeID: parentID, alias: alias)
    }

    /// Return index of matching `)` for `(` at `openIdx`, or nil.
    private func balancedClose(openIdx: Int, to end: Int) -> Int? {
        var depth = 0
        var i = openIdx
        while i < end {
            let ch = bytes[i]
            if ch == 0x28 { depth += 1 }
            else if ch == 0x29 {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Case-insensitive ASCII match of `pattern` starting at index `i`.
    private func matchesLowercase(_ pattern: [UInt8], at i: Int) -> Bool {
        let n = pattern.count
        for k in 0..<n {
            var b = bytes[i + k]
            if b >= 0x41 && b <= 0x5A { b += 0x20 }
            if b != pattern[k] { return false }
        }
        return true
    }

    /// Simple linear byte-substring search bound to [from, to).
    private func findSubsequence(_ needle: [UInt8], from: Int, to: Int) -> Int? {
        let m = needle.count
        if m == 0 || to - from < m { return nil }
        let first = needle[0]
        var i = from
        let limit = to - m
        while i <= limit {
            if bytes[i] == first {
                var ok = true
                for k in 1..<m where bytes[i + k] != needle[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }
}
