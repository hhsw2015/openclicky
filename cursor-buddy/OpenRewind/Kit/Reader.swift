// Reader.swift — read-only queries against a Rewind-compatible vault.
// Ported from research/prototypes/RewindKit/RewindKit.swift with types
// renamed to the OpenRewind* prefix and shared SQLite bindings moved to
// Internal/SQLiteBindings.swift. Functional behaviour matches the
// prototype (88 passing tests).

import AppKit
import AVFoundation
import CoreMedia
import Foundation

// MARK: - Public row types

public struct OpenRewindEntry: Identifiable, Hashable, Sendable {
    public let id: Int64                    // frame.id
    public let createdAt: Date
    public let bundleID: String?
    public let windowName: String?
    public let browserUrl: String?
    public let videoID: Int64?
    public let videoFrameIndex: Int?
    public let chunkRelPath: String?
    public let width: Int
    public let height: Int
    /// PNG basename under `<vault>/temp/`. Set while a frame is a
    /// "hot" capture, before the chunker rolls it into an mp4 and
    /// backfills videoId. Used by `image(for:)` as fallback.
    public let imageFileName: String?

    public init(id: Int64, createdAt: Date, bundleID: String?, windowName: String?,
                browserUrl: String?, videoID: Int64?, videoFrameIndex: Int?,
                chunkRelPath: String?, width: Int, height: Int,
                imageFileName: String? = nil) {
        self.id = id; self.createdAt = createdAt
        self.bundleID = bundleID; self.windowName = windowName
        self.browserUrl = browserUrl; self.videoID = videoID
        self.videoFrameIndex = videoFrameIndex; self.chunkRelPath = chunkRelPath
        self.width = width; self.height = height
        self.imageFileName = imageFileName
    }
}

public struct OpenRewindOCRNode: Identifiable, Sendable {
    public let id: Int64
    public let text: String
    public let leftX: Double
    public let topY: Double
    public let width: Double
    public let height: Double
    public init(id: Int64, text: String, leftX: Double, topY: Double, width: Double, height: Double) {
        self.id = id; self.text = text
        self.leftX = leftX; self.topY = topY
        self.width = width; self.height = height
    }
}

public struct OpenRewindSearchHit: Identifiable, Sendable {
    public let id: Int64
    public let snippet: String
    public let entry: OpenRewindEntry
}

public struct OpenRewindSegment: Identifiable, Sendable {
    public let id: Int64
    public let bundleID: String?
    public let startDate: Date
    public let endDate: Date
    public let windowName: String?
    public let browserUrl: String?
    public let browserProfile: String?
    public let type: Int
}

public struct OpenRewindVideo: Identifiable, Sendable {
    public let id: Int64
    public let xid: String
    public let path: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let fileSize: Int64
    public let local: Bool
    public let processingState: Int
    public let captureType: String?
}

public struct OpenRewindTranscriptWord: Identifiable, Sendable {
    // FIX(review-2026-07-28): dropped speechSource/timeOffsetMs/durationMs;
    // the real schema is (id, segmentId, word, startTime, endTime,
    // fullTextOffset) per docs/SCHEMA.md #transcript_word.
    public let id: Int64
    public let segmentID: Int64
    public let word: String
    public let startTime: Double
    public let endTime: Double
    public let fullTextOffset: Int?
}

public struct OpenRewindAudio: Identifiable, Sendable {
    public let id: Int64
    public let segmentID: Int64
    public let path: String
    public let startTime: Date
    public let durationSeconds: Double
}

public struct OpenRewindEvent: Identifiable, Sendable {
    public let id: Int64
    public let type: String
    public let status: String
    public let title: String?
    public let participants: String?
    public let detailsJSON: String?
    public let calendarID: String?
    public let calendarEventID: String?
    public let calendarSeriesID: String?
    public let segmentID: Int64
}

public struct OpenRewindSummary: Identifiable, Sendable {
    public let id: Int64
    public let status: String
    public let text: String?
    public let eventID: Int64
}

public struct OpenRewindFrameProcessing: Sendable {
    public let id: Int64
    public let processingType: String
    public let createdAt: Date
}

public struct OpenRewindFrameContext: Sendable {
    public let entry: OpenRewindEntry
    public let segment: OpenRewindSegment?
    public let video: OpenRewindVideo?
    public let ocrText: String
    public let ocrNodes: [OpenRewindOCRNode]
    public let transcriptWords: [OpenRewindTranscriptWord]
    public let audio: [OpenRewindAudio]
    public let events: [OpenRewindEvent]
    public let processing: [OpenRewindFrameProcessing]
}

// MARK: - AI-friendly aggregates

public struct OpenRewindTimeSummary: Sendable {
    public let start: Date
    public let end: Date
    public let totalActiveSeconds: Double
    public let framesCount: Int
    public let uniqueSegments: Int
    public let apps: [AppTime]
    public let topURLs: [URLVisit]
    public let topWindows: [WindowTime]
    public let topOCRKeywords: [String: Int]

    public struct AppTime: Sendable {
        public let bundleID: String
        public let seconds: Double
        public let segments: Int
        public let frames: Int
    }
    public struct URLVisit: Sendable {
        public let url: String
        public let visits: Int
        public let seconds: Double
    }
    public struct WindowTime: Sendable {
        public let windowName: String
        public let bundleID: String?
        public let seconds: Double
    }
}

public struct OpenRewindSession: Sendable {
    public let id: Int
    public let bundleID: String?
    public let startDate: Date
    public let endDate: Date
    public let segmentIDs: [Int64]
    public let frameCount: Int
    public let topWindowNames: [String]
    public var seconds: Double { endDate.timeIntervalSince(startDate) }
}

public struct OpenRewindAppUsage: Sendable {
    public let bundleID: String
    public let totalSeconds: Double
    public let launches: Int
    public let avgSessionSeconds: Double
    public let frames: Int
}

public struct OpenRewindMeeting: Sendable {
    public let app: String
    public let startDate: Date
    public let endDate: Date
    public let segmentIDs: [Int64]
    public let title: String?
    public var seconds: Double { endDate.timeIntervalSince(startDate) }
}

public struct OpenRewindDailyRecap: Sendable {
    public let day: Date
    public let firstActivity: Date?
    public let lastActivity: Date?
    public let activeSeconds: Double
    public let frameCount: Int
    public let uniqueApps: Int
    public let topApps: [OpenRewindAppUsage]
    public let meetings: [OpenRewindMeeting]
    public let topURLs: [OpenRewindTimeSummary.URLVisit]
    public let ocrKeywords: [String: Int]
}

public struct OpenRewindURLVisit: Sendable {
    public let url: String
    public let host: String
    public let title: String?
    public let bundleID: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let visits: Int
    public let totalSeconds: Double
}

public struct OpenRewindAIContext: Sendable {
    public let anchor: OpenRewindEntry
    public let neighborsBefore: [OpenRewindEntry]
    public let neighborsAfter: [OpenRewindEntry]
    public let segment: OpenRewindSegment?
    public let ocrText: String
    public let ocrNodes: [OpenRewindOCRNode]
    public let sameWindowMinutes: Double
    public let recentApps: [String]
    public let anchorImageBase64: String?
}

/// Bundle IDs Rewind recognises as meeting apps.
public enum OpenRewindMeetingApp: String, CaseIterable, Sendable {
    case zoom      = "us.zoom.xos"
    case teams     = "com.microsoft.teams"
    case teams2    = "com.microsoft.teams2"
    case webex     = "com.webex.meetingmanager"
    case chromeMeet = "com.google.Chrome"
    case safariMeet = "com.apple.Safari"
    public static var all: [String] { allCases.map(\.rawValue) }
}

// MARK: - Reader

/// Read-only view of a Rewind-compatible vault. Every method is thread-
/// safe (serial queue) and blocking; consumers typically wrap calls in a
/// `Task.detached` or their own concurrency layer.
public final class OpenRewindReader: @unchecked Sendable {

    public let storage: OpenRewindStorage
    internal var db: ORKSQLite3?
    internal let queue = DispatchQueue(label: "openrewindkit.reader.serial")
    internal let workingCopyURL: URL

    private var frameCache: [String: NSImage] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit: Int
    private lazy var symlinkDir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrewindkit-symlinks-\(getpid())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Open the DB with a SQLCipher passphrase. Copies the file (+ WAL /
    /// SHM) to a private temp path so a live writer can't fight us for
    /// the lock. Runs a `SELECT count(*) FROM sqlite_master` to verify
    /// the key is accepted.
    public init(storage: OpenRewindStorage = .openRewindDefault,
                passphrase: String,
                cacheLimit: Int = 12) throws {  // ~660MB max at retina — was 32=1.7GB
        self.storage = storage
        self.cacheLimit = cacheLimit

        // Purge orphaned tmp dirs from crashed prior processes.
        // Their names embed the old pid; if `kill -0 pid` fails (proc
        // gone), the dir is safe to remove.
        Self.purgeOrphanTmpDirs()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrewindkit-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent("db.sqlite3")
        // FIX(race-2026-07-29): Browser boots before daemon can build
        // the vault. Wait up to 3s for the file to appear so a fresh
        // install doesn't surface "no such file" to the user.
        if !FileManager.default.fileExists(atPath: storage.dbEncrypted.path) {
            let deadline = Date().addingTimeInterval(3.0)
            while !FileManager.default.fileExists(atPath: storage.dbEncrypted.path),
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard FileManager.default.fileExists(atPath: storage.dbEncrypted.path) else {
                throw OpenRewindError.openFailed(
                    "vault DB not built yet at \(storage.dbEncrypted.path); daemon may still be starting")
            }
        }
        try FileManager.default.copyItem(at: storage.dbEncrypted, to: tmp)
        for suffix in ["-wal", "-shm"] {
            let src2 = URL(fileURLWithPath: storage.dbEncrypted.path + suffix)
            if FileManager.default.fileExists(atPath: src2.path) {
                let dst = URL(fileURLWithPath: tmp.path + suffix)
                try? FileManager.default.copyItem(at: src2, to: dst)
            }
        }
        self.workingCopyURL = tmp

        var handle: ORKSQLite3?
        let flags = ORK_SQLITE_OPEN_READWRITE | ORK_SQLITE_OPEN_NOMUTEX
        let rc = ork_open_v2(tmp.path, &handle, flags, nil)
        guard rc == ORK_SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: ork_errmsg($0)!) } ?? "open error"
            throw OpenRewindError.openFailed(msg)
        }
        self.db = handle
        let keyRC = passphrase.withCString { p in
            ork_key_v2(handle, "main", p, Int32(strlen(p)))
        }
        guard keyRC == ORK_SQLITE_OK else {
            ork_close_v2(handle); self.db = nil
            throw OpenRewindError.openFailed("sqlite3_key_v2 failed rc=\(keyRC)")
        }
        // Sanity-check by touching sqlite_master.
        let stmt = try prepare("SELECT count(*) FROM sqlite_master;")
        defer { ork_finalize(stmt) }
        guard ork_step(stmt) == ORK_SQLITE_ROW else {
            throw OpenRewindError.keyRejected
        }
        // FIX(sqlite-pragmas-2026-07-28): apply retrace's init pragmas
        // (Database/Schema.swift:90-119) — 2-5× write throughput, 30 %
        // smaller idle DB via incremental vacuum. Safe on read paths.
        let pragmas = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA foreign_keys = ON;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA cache_size = -64000;",           // 64 MB
            "PRAGMA auto_vacuum = INCREMENTAL;",
            "PRAGMA wal_autocheckpoint = 1000;"
        ]
        for p in pragmas {
            let s = try? prepare(p)
            _ = ork_step(s)
            ork_finalize(s)
        }
    }

    deinit {
        if let db = db { ork_close_v2(db) }
        try? FileManager.default.removeItem(at: workingCopyURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: symlinkDir)
    }

    // MARK: - Time-range queries

    public func recentEntries(limit: Int = 200) throws -> [OpenRewindEntry] {
        // FIX(hot-frames-2026-07-29): drop `videoId IS NOT NULL` gate.
        // Fresh captures live as PNGs under vault/temp/ until the chunker
        // finalizes a video (~30s+); without this the timeline was empty
        // for the first half-minute of every session.
        // FIX(no-local-chunk-2026-07-30): exclude rows whose encoding
        // status was flipped to 'failed' by StartupReconciler — those
        // frames never made it into a chunk AND their hot PNG was
        // swept, so the UI would otherwise show "no local chunk".
        let sql = """
            SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                   f.videoId, f.videoFrameIndex, f.imageFileName, v.path, v.width, v.height
            FROM frame f
            LEFT JOIN segment s ON s.id = f.segmentId
            LEFT JOIN video   v ON v.id = f.videoId
            WHERE COALESCE(f.encodingStatus, 'success') != 'failed'
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """
        return try queue.sync { try selectEntries(sql, [.int(Int64(limit))]) }
    }

    /// Single-frame lookup by id. Used by deep-link handler when the
    /// requested id is outside the in-memory `entries[]` window.
    public func entryByID(_ id: Int64) throws -> OpenRewindEntry? {
        let sql = """
            SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                   f.videoId, f.videoFrameIndex, f.imageFileName, v.path, v.width, v.height
            FROM frame f
            LEFT JOIN segment s ON s.id = f.segmentId
            LEFT JOIN video   v ON v.id = f.videoId
            WHERE f.id = ?
              AND COALESCE(f.encodingStatus, 'success') != 'failed'
            LIMIT 1;
            """
        return try queue.sync {
            try selectEntries(sql, [.int(id)]).first
        }
    }

    public func entries(from start: Date, to end: Date,
                        limit: Int = 1000) throws -> [OpenRewindEntry] {
        // FIX(stability-review-23-2026-07-29): removed the
        // `f.videoId IS NOT NULL` filter. Hot-window frames (chunker
        // hasn't rolled the mp4 yet) legitimately have `videoId=NULL`
        // for up to 30s; excluding them hid the last-half-minute of
        // capture from any time-range query. Mirrors the fix already
        // in `recentEntries` (image(for:) falls back to the hot PNG).
        let sql = """
            SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                   f.videoId, f.videoFrameIndex, f.imageFileName, v.path, v.width, v.height
            FROM frame f
            LEFT JOIN segment s ON s.id = f.segmentId
            LEFT JOIN video   v ON v.id = f.videoId
            WHERE f.createdAt >= ? AND f.createdAt <= ?
              AND COALESCE(f.encodingStatus, 'success') != 'failed'
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """
        return try queue.sync {
            try selectEntries(sql, [.text(ORKDate.iso(start)),
                                     .text(ORKDate.iso(end)),
                                     .int(Int64(limit))])
        }
    }

    public func lastSeconds(_ seconds: TimeInterval,
                            limit: Int = 500) throws -> [OpenRewindEntry] {
        try entries(from: Date().addingTimeInterval(-seconds),
                    to: Date(), limit: limit)
    }

    // MARK: - Search (FTS5)

    /// FTS5 search across OCR + AX + title columns. Rewind stores its
    /// live index in `searchRanking` (FTS5); the legacy `search` FTS4
    /// vtable exists but is empty on modern builds.
    public func search(_ query: String, limit: Int = 100) throws -> [OpenRewindSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // FIX(retrace-#14-2026-07-31): parse retrace-style tokens out of
        // the query — site:, app:, before:/after:, quoted phrase — and
        // fold them into SQL WHERE clauses so `site:github.com login`
        // finds only GitHub login frames. Anything not recognised falls
        // through to the free-text FTS path.
        let parsed = Self.parseAdvancedQuery(trimmed)
        // FIX(cjk-fts-2026-07-30): Writer stores CJK bigrams in
        // otherText for each frame; the porter tokenizer can't
        // split CJK on its own. Bigram-ize the query too so it
        // matches those pre-tokenized indexes. Pure-Latin queries
        // pass through unchanged.
        let expanded = Self.expandCJKQuery(parsed.freeText)
        // If both freeText and filters are empty, nothing to do.
        if expanded.isEmpty && parsed.hasNoFilters { return [] }
        var whereClauses: [String] = []
        var haveFTS = false
        // Ordered list of positional bindings to apply after prepare().
        var bindings: [(_ stmt: OpaquePointer?, _ idx: Int32) -> Void] = []
        if !expanded.isEmpty {
            whereClauses.append("searchRanking MATCH ?")
            haveFTS = true
            let expanded = expanded
            bindings.append { s, i in _ = ork_bindString(s, i, expanded) }
        }
        if let sitePattern = parsed.sitePattern {
            whereClauses.append("s.browserUrl LIKE ?")
            bindings.append { s, i in _ = ork_bindString(s, i, "%\(sitePattern)%") }
        }
        if let appPattern = parsed.appPattern {
            whereClauses.append("s.bundleID LIKE ?")
            bindings.append { s, i in _ = ork_bindString(s, i, "%\(appPattern)%") }
        }
        if let afterDate = parsed.afterDate {
            whereClauses.append("f.createdAt >= ?")
            bindings.append { s, i in _ = ork_bindString(s, i, ORKDate.iso(afterDate)) }
        }
        if let beforeDate = parsed.beforeDate {
            whereClauses.append("f.createdAt < ?")
            bindings.append { s, i in _ = ork_bindString(s, i, ORKDate.iso(beforeDate)) }
        }
        let whereSQL = whereClauses.isEmpty ? "1=1" : whereClauses.joined(separator: " AND ")
        // FIX(retrace-#14 rank boost): 2× recency bonus in ORDER BY —
        // recent frames float above older ones with the same FTS score.
        // Metadata-hit rows (site/app match without FTS) still ordered
        // by createdAt DESC as retrace's ResultRanker.swift:28-109 does.
        let sql = """
            SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                   f.videoId, f.videoFrameIndex, f.imageFileName, v.path, v.width, v.height,
                   \(haveFTS ? "snippet(searchRanking, 0, '[', ']', '…', 20)" : "''")
            FROM \(haveFTS ? "searchRanking JOIN doc_segment ds ON ds.docid = searchRanking.rowid JOIN frame f ON f.id = ds.frameId"
                             : "frame f")
            LEFT JOIN segment s ON s.id = f.segmentId
            LEFT JOIN video   v ON v.id = f.videoId
            WHERE \(whereSQL)
            \(haveFTS
              // FIX(rewind-ida-#5-2026-07-31): weight BM25 columns
              // like Rewind does — `bm25(1.0, 0.3, 3.0)` at 0x100ed2bd0.
              // Column layout matches ours: text (1.0), otherText (0.3
              // — bigram noise weighted low), title (3.0 — dominant).
              // Combined 50/50 with recency so both semantic relevance
              // AND recency drive ranking (retrace ResultRanker parity).
              ? "ORDER BY (bm25(searchRanking, 1.0, 0.3, 3.0) - (julianday('now') - julianday(f.createdAt))*0.1) ASC"
              : "ORDER BY f.createdAt DESC")
            LIMIT ?;
            """
        return try queue.sync {
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            // Apply the ordered positional bindings computed above.
            for (i, bind) in bindings.enumerated() {
                bind(stmt, Int32(i + 1))
            }
            _ = ork_bind_int64(stmt, Int32(bindings.count + 1), Int64(limit))
            // FIX(tile-ocr-2026-07-30): each frame has many docid tiles;
            // the first hit for a frame is often an empty tile. Prefer
            // the FIRST NON-EMPTY snippet for each frame instead of
            // taking whichever row FTS returned first.
            var hits: [OpenRewindSearchHit] = []
            var seenIndex: [Int64: Int] = [:]
            while ork_step(stmt) == ORK_SQLITE_ROW {
                let entry = readEntry(stmt)
                let snip = ork_readString(stmt, 10) ?? ""
                if let idx = seenIndex[entry.id] {
                    if hits[idx].snippet.isEmpty && !snip.isEmpty {
                        hits[idx] = OpenRewindSearchHit(id: entry.id,
                                                        snippet: snip,
                                                        entry: entry)
                    }
                } else {
                    seenIndex[entry.id] = hits.count
                    hits.append(OpenRewindSearchHit(id: entry.id,
                                                    snippet: snip,
                                                    entry: entry))
                }
            }
            // FIX(tile-ocr-2026-07-30 pass 2): if a hit's snippet is
            // still empty, synthesise one from the concatenated frame
            // OCR text — take a 160-char window around the first
            // case-insensitive occurrence of the query. Keeps the caller
            // from getting empty snippets when the FTS row that matched
            // happens to be an empty tile.
            let needle = trimmed.lowercased()
            for i in hits.indices where hits[i].snippet.isEmpty {
                let full = (try? unlocked_ocrText(frameID: hits[i].entry.id)) ?? ""
                guard !full.isEmpty else { continue }
                let lower = full.lowercased()
                if let r = lower.range(of: needle) {
                    let start = max(full.startIndex,
                                    full.index(r.lowerBound,
                                               offsetBy: -60,
                                               limitedBy: full.startIndex) ?? full.startIndex)
                    let end = min(full.endIndex,
                                  full.index(r.upperBound,
                                             offsetBy: 100,
                                             limitedBy: full.endIndex) ?? full.endIndex)
                    let context = String(full[start..<end])
                        .replacingOccurrences(of: "\n", with: " ")
                    hits[i] = OpenRewindSearchHit(id: hits[i].id,
                                                  snippet: context,
                                                  entry: hits[i].entry)
                } else {
                    // No literal substring match; return leading text.
                    let head = String(full.prefix(160))
                        .replacingOccurrences(of: "\n", with: " ")
                    hits[i] = OpenRewindSearchHit(id: hits[i].id,
                                                  snippet: head,
                                                  entry: hits[i].entry)
                }
            }
            return hits
        }
    }

    // MARK: - OCR

    /// Concat text for a frame WITHOUT re-entering `queue.sync`. Only
    /// callable from an already-serialised context. Used by `search()`
    /// to fall back to full-frame OCR when the matched FTS row's tile
    /// is empty.
    fileprivate func unlocked_ocrText(frameID: Int64) throws -> String {
        let sql = """
            SELECT sr.text FROM doc_segment ds
            JOIN searchRanking sr ON sr.rowid = ds.docid
            WHERE ds.frameId = ? ORDER BY ds.docid;
            """
        let stmt = try prepare(sql); defer { ork_finalize(stmt) }
        _ = ork_bind_int64(stmt, 1, frameID)
        var parts: [String] = []
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let s = ork_readString(stmt, 0), !s.isEmpty { parts.append(s) }
        }
        return parts.joined(separator: "\n")
    }

    public func ocr(for frameID: Int64) throws -> (text: String, nodes: [OpenRewindOCRNode]) {
        try queue.sync {
            var text = ""
            // FIX(review-2026-07-28) K-M-2: read from the FTS5 virtual
            // table by rowid instead of the private `searchRanking_content`
            // shadow. Shadow tables are an SQLite implementation detail
            // and become read-error surfaces if FTS5's content= mode
            // changes; the vtable exposes the same c0 column through the
            // public API.
            // FIX(tile-ocr-2026-07-30): a single frame is decomposed into
            // many docids by the tile OCR pipeline; each row holds one
            // tile's text. Concatenate every non-empty tile so `text`
            // matches what the user saw, AND keep the per-tile pieces
            // so node.textOffset/textLength (which are relative to a
            // single tile) can be sliced correctly.
            let textSQL = """
                SELECT sr.text FROM doc_segment ds
                JOIN searchRanking sr ON sr.rowid = ds.docid
                WHERE ds.frameId = ? ORDER BY ds.docid;
                """
            var tilePieces: [String] = []
            do {
                let stmt = try prepare(textSQL); defer { ork_finalize(stmt) }
                _ = ork_bind_int64(stmt, 1, frameID)
                while ork_step(stmt) == ORK_SQLITE_ROW {
                    tilePieces.append(ork_readString(stmt, 0) ?? "")
                }
                text = tilePieces.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            var nodes: [OpenRewindOCRNode] = []
            let boxSQL = """
                SELECT id, textOffset, textLength, leftX, topY, width, height
                FROM node WHERE frameId = ? ORDER BY nodeOrder;
                """
            let stmt = try prepare(boxSQL); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameID)
            // FIX(tile-ocr-2026-07-30): the node table stores offsets
            // relative to a specific tile's `searchRanking.text` row,
            // but does NOT record WHICH tile. Since a frame is split
            // across multiple tiles, we can't reliably slice per-node
            // text back out. Callers get the concatenated frame text
            // (fully accurate) plus per-node bboxes for highlighting;
            // node.text stays empty. This is a real upstream schema
            // constraint, not a workaround: rewind itself uses the FTS
            // snippet from `searchRanking` for per-hit context, not
            // node-level slices.
            while ork_step(stmt) == ORK_SQLITE_ROW {
                let id  = ork_col_int64(stmt, 0)
                let lx  = ork_col_double(stmt, 3)
                let ty  = ork_col_double(stmt, 4)
                let w   = ork_col_double(stmt, 5)
                let h   = ork_col_double(stmt, 6)
                nodes.append(OpenRewindOCRNode(id: id, text: "",
                                                leftX: lx, topY: ty,
                                                width: w, height: h))
            }
            return (text, nodes)
        }
    }

    // MARK: - Segments / videos / transcripts / events / summaries

    public func segments(from start: Date, to end: Date,
                         limit: Int = 500) throws -> [OpenRewindSegment] {
        try queue.sync {
            let sql = """
                SELECT id, bundleID, startDate, endDate, windowName,
                       browserUrl, browserProfile, type
                FROM segment
                WHERE endDate >= ? AND startDate <= ?
                ORDER BY startDate DESC
                LIMIT ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, ORKDate.iso(start))
            _ = ork_bindString(stmt, 2, ORKDate.iso(end))
            _ = ork_bind_int64(stmt, 3, Int64(limit))
            var out: [OpenRewindSegment] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindSegment(
                    id: ork_col_int64(stmt, 0),
                    bundleID: ork_readString(stmt, 1),
                    startDate: ORKDate.parse(ork_readString(stmt, 2) ?? "") ?? Date(),
                    endDate:   ORKDate.parse(ork_readString(stmt, 3) ?? "") ?? Date(),
                    windowName: ork_readString(stmt, 4),
                    browserUrl: ork_readString(stmt, 5)?.nonEmpty,
                    browserProfile: ork_readString(stmt, 6)?.nonEmpty,
                    type: Int(ork_col_int(stmt, 7))))
            }
            return out
        }
    }

    public func videos(limit: Int = 10000) throws -> [OpenRewindVideo] {
        try queue.sync {
            let sql = """
                SELECT id, xid, path, width, height, frameRate, fileSize,
                       local, processingState, captureType
                FROM video ORDER BY id DESC LIMIT ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, Int64(limit))
            var out: [OpenRewindVideo] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindVideo(
                    id: ork_col_int64(stmt, 0),
                    xid: ork_readString(stmt, 1) ?? "",
                    path: ork_readString(stmt, 2) ?? "",
                    width: Int(ork_col_int(stmt, 3)),
                    height: Int(ork_col_int(stmt, 4)),
                    frameRate: ork_col_double(stmt, 5),
                    fileSize: ork_col_int64(stmt, 6),
                    local: ork_col_int(stmt, 7) != 0,
                    processingState: Int(ork_col_int(stmt, 8)),
                    captureType: ork_readString(stmt, 9)))
            }
            return out
        }
    }

    public func transcriptWords(segmentID: Int64) throws -> [OpenRewindTranscriptWord] {
        try queue.sync {
            // FIX(compat-2026-07-29): Rewind's real schema is (id,
            // segmentId, speechSource, word, timeOffset INTEGER ms,
            // fullTextOffset, duration INTEGER ms). Convert ms → sec
            // so the public row type keeps its existing REAL fields.
            let sql = """
                SELECT id, segmentId, word, timeOffset, duration, fullTextOffset
                FROM transcript_word WHERE segmentId = ?
                ORDER BY timeOffset;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentID)
            var out: [OpenRewindTranscriptWord] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                let fto: Int? = ork_col_type(stmt, 5) == ORK_SQLITE_NULL
                              ? nil : Int(ork_col_int(stmt, 5))
                let offsetMs = ork_col_int64(stmt, 3)
                let durMs = ork_col_int64(stmt, 4)
                let start = Double(offsetMs) / 1000.0
                let end = Double(offsetMs + durMs) / 1000.0
                out.append(OpenRewindTranscriptWord(
                    id: ork_col_int64(stmt, 0),
                    segmentID: ork_col_int64(stmt, 1),
                    word: ork_readString(stmt, 2) ?? "",
                    startTime: start,
                    endTime: end,
                    fullTextOffset: fto))
            }
            return out
        }
    }

    /// Segment id for a frame. Nil if frame not found.
    public func segmentID(forFrameID frameID: Int64) throws -> Int64? {
        try queue.sync {
            let stmt = try prepare("SELECT segmentId FROM frame WHERE id = ?;")
            defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameID)
            guard ork_step(stmt) == ORK_SQLITE_ROW else { return nil }
            return ork_col_int64(stmt, 0)
        }
    }

    public func transcriptText(segmentID: Int64) throws -> String {
        let words = try transcriptWords(segmentID: segmentID)
        return words.map(\.word).joined(separator: " ")
    }

    public func audioRecordings(segmentID: Int64) throws -> [OpenRewindAudio] {
        try queue.sync {
            let sql = """
                SELECT id, segmentId, path, startTime, duration
                FROM audio WHERE segmentId = ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentID)
            var out: [OpenRewindAudio] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindAudio(
                    id: ork_col_int64(stmt, 0),
                    segmentID: ork_col_int64(stmt, 1),
                    path: ork_readString(stmt, 2) ?? "",
                    startTime: ORKDate.parse(ork_readString(stmt, 3) ?? "") ?? Date(),
                    durationSeconds: ork_col_double(stmt, 4)))
            }
            return out
        }
    }

    public func events(status: String? = nil,
                       limit: Int = 200) throws -> [OpenRewindEvent] {
        try queue.sync {
            let (sql, binds): (String, [ORKBind])
            if let status = status {
                sql = """
                    SELECT id, type, status, title, participants, detailsJSON,
                           calendarID, calendarEventID, calendarSeriesID, segmentID
                    FROM event WHERE status = ? ORDER BY id DESC LIMIT ?;
                    """
                binds = [.text(status), .int(Int64(limit))]
            } else {
                sql = """
                    SELECT id, type, status, title, participants, detailsJSON,
                           calendarID, calendarEventID, calendarSeriesID, segmentID
                    FROM event ORDER BY id DESC LIMIT ?;
                    """
                binds = [.int(Int64(limit))]
            }
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            ork_bindAll(stmt, binds)
            var out: [OpenRewindEvent] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindEvent(
                    id: ork_col_int64(stmt, 0),
                    type: ork_readString(stmt, 1) ?? "",
                    status: ork_readString(stmt, 2) ?? "",
                    title: ork_readString(stmt, 3),
                    participants: ork_readString(stmt, 4),
                    detailsJSON: ork_readString(stmt, 5),
                    calendarID: ork_readString(stmt, 6),
                    calendarEventID: ork_readString(stmt, 7),
                    calendarSeriesID: ork_readString(stmt, 8),
                    segmentID: ork_col_int64(stmt, 9)))
            }
            return out
        }
    }

    public func summaries(limit: Int = 200) throws -> [OpenRewindSummary] {
        try queue.sync {
            let sql = """
                SELECT id, status, text, eventId FROM summary
                ORDER BY id DESC LIMIT ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, Int64(limit))
            var out: [OpenRewindSummary] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindSummary(
                    id: ork_col_int64(stmt, 0),
                    status: ork_readString(stmt, 1) ?? "",
                    text: ork_readString(stmt, 2),
                    eventID: ork_col_int64(stmt, 3)))
            }
            return out
        }
    }

    public func frameProcessing(frameID: Int64) throws -> [OpenRewindFrameProcessing] {
        try queue.sync {
            let sql = """
                SELECT id, processingType, createdAt FROM frame_processing
                WHERE id = ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameID)
            var out: [OpenRewindFrameProcessing] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindFrameProcessing(
                    id: ork_col_int64(stmt, 0),
                    processingType: ork_readString(stmt, 1) ?? "",
                    createdAt: ORKDate.parse(ork_readString(stmt, 2) ?? "") ?? Date()))
            }
            return out
        }
    }

    // MARK: - Context bundle

    /// Single call that returns everything the DB stores about a frame.
    public func context(for frameID: Int64) throws -> OpenRewindFrameContext {
        let entryRows = try queue.sync { () throws -> [OpenRewindEntry] in
            let sql = """
                SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                       f.videoId, f.videoFrameIndex, f.imageFileName, v.path, v.width, v.height
                FROM frame f
                LEFT JOIN segment s ON s.id = f.segmentId
                LEFT JOIN video   v ON v.id = f.videoId
                WHERE f.id = ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameID)
            var out: [OpenRewindEntry] = []
            while ork_step(stmt) == ORK_SQLITE_ROW { out.append(readEntry(stmt)) }
            return out
        }
        guard let entry = entryRows.first else {
            throw OpenRewindError.queryFailed("frame \(frameID) not found")
        }
        let (ocrText, ocrNodes) = try self.ocr(for: frameID)
        var segID: Int64 = 0
        try queue.sync {
            let stmt = try prepare("SELECT segmentId FROM frame WHERE id = ?;")
            defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameID)
            if ork_step(stmt) == ORK_SQLITE_ROW { segID = ork_col_int64(stmt, 0) }
        }
        let seg = try segmentByID(segID)
        let vid: OpenRewindVideo?
        if let v = entry.videoID { vid = try videoByID(v) } else { vid = nil }
        let transcript = (segID > 0) ? (try transcriptWords(segmentID: segID)) : []
        let aud        = (segID > 0) ? (try audioRecordings(segmentID: segID)) : []
        let evs        = try eventsFor(segmentID: segID)
        let proc       = try frameProcessing(frameID: frameID)
        return OpenRewindFrameContext(entry: entry, segment: seg, video: vid,
                                       ocrText: ocrText, ocrNodes: ocrNodes,
                                       transcriptWords: transcript,
                                       audio: aud, events: evs, processing: proc)
    }

    // MARK: - Raw escape hatch

    public func rawQuery(_ sql: String,
                         _ bindings: [String] = []) throws -> (columns: [String], rows: [[String?]]) {
        try queue.sync {
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            for (i, s) in bindings.enumerated() {
                _ = ork_bindString(stmt, Int32(i + 1), s)
            }
            let colCount = ork_column_count(stmt)
            var columns: [String] = []
            for i in 0 ..< colCount {
                if let n = ork_column_name(stmt, i) {
                    columns.append(String(cString: n))
                } else { columns.append("col\(i)") }
            }
            var rows: [[String?]] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                var row: [String?] = []
                for i in 0 ..< colCount {
                    row.append(ork_readString(stmt, i))
                }
                rows.append(row)
            }
            return (columns, rows)
        }
    }

    private func segmentByID(_ id: Int64) throws -> OpenRewindSegment? {
        guard id > 0 else { return nil }
        return try queue.sync {
            let stmt = try prepare("""
                SELECT id, bundleID, startDate, endDate, windowName,
                       browserUrl, browserProfile, type FROM segment WHERE id = ?;
                """)
            defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, id)
            guard ork_step(stmt) == ORK_SQLITE_ROW else { return nil }
            return OpenRewindSegment(
                id: ork_col_int64(stmt, 0),
                bundleID: ork_readString(stmt, 1),
                startDate: ORKDate.parse(ork_readString(stmt, 2) ?? "") ?? Date(),
                endDate:   ORKDate.parse(ork_readString(stmt, 3) ?? "") ?? Date(),
                windowName: ork_readString(stmt, 4),
                browserUrl: ork_readString(stmt, 5)?.nonEmpty,
                browserProfile: ork_readString(stmt, 6)?.nonEmpty,
                type: Int(ork_col_int(stmt, 7)))
        }
    }

    public func videoByID(_ id: Int64) throws -> OpenRewindVideo? {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, xid, path, width, height, frameRate, fileSize,
                       local, processingState, captureType FROM video WHERE id = ?;
                """)
            defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, id)
            guard ork_step(stmt) == ORK_SQLITE_ROW else { return nil }
            return OpenRewindVideo(
                id: ork_col_int64(stmt, 0),
                xid: ork_readString(stmt, 1) ?? "",
                path: ork_readString(stmt, 2) ?? "",
                width: Int(ork_col_int(stmt, 3)),
                height: Int(ork_col_int(stmt, 4)),
                frameRate: ork_col_double(stmt, 5),
                fileSize: ork_col_int64(stmt, 6),
                local: ork_col_int(stmt, 7) != 0,
                processingState: Int(ork_col_int(stmt, 8)),
                captureType: ork_readString(stmt, 9))
        }
    }

    private func eventsFor(segmentID: Int64) throws -> [OpenRewindEvent] {
        guard segmentID > 0 else { return [] }
        return try queue.sync {
            let sql = """
                SELECT id, type, status, title, participants, detailsJSON,
                       calendarID, calendarEventID, calendarSeriesID, segmentID
                FROM event WHERE segmentID = ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentID)
            var out: [OpenRewindEvent] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                out.append(OpenRewindEvent(
                    id: ork_col_int64(stmt, 0),
                    type: ork_readString(stmt, 1) ?? "",
                    status: ork_readString(stmt, 2) ?? "",
                    title: ork_readString(stmt, 3),
                    participants: ork_readString(stmt, 4),
                    detailsJSON: ork_readString(stmt, 5),
                    calendarID: ork_readString(stmt, 6),
                    calendarEventID: ork_readString(stmt, 7),
                    calendarSeriesID: ork_readString(stmt, 8),
                    segmentID: ork_col_int64(stmt, 9)))
            }
            return out
        }
    }

    // MARK: - Frame decode

    /// Cache-only lookup — returns nil if the frame isn't already
    /// decoded. Used during active scrub so we never trigger an
    /// AVFoundation decode on the UI-blocking path. Falls back to
    /// full `image(for:)` when the user settles on a frame.
    public func cachedImage(for entry: OpenRewindEntry) -> NSImage? {
        // Hot PNG path — pre-encode frames are cheap to test.
        if entry.chunkRelPath == nil || entry.videoID == nil,
           let name = entry.imageFileName, !name.isEmpty {
            let tempURL = storage.root
                .appendingPathComponent("temp")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: tempURL.path),
               let img = NSImage(contentsOf: tempURL) {
                return img
            }
        }
        // Chunk path — ThumbnailCache hit only.
        guard let rel = entry.chunkRelPath, let idx = entry.videoFrameIndex
        else { return nil }
        let chunk = storage.chunksDir.appendingPathComponent(rel)
        let mp4 = symlinkDir.appendingPathComponent(
            chunk.lastPathComponent + ".mp4")
        return ThumbnailCache.shared.image(chunkURL: mp4, frameIndex: idx)
    }

    public func image(for entry: OpenRewindEntry) throws -> NSImage {
        // Hot path: chunker hasn't rolled this frame into an mp4 yet.
        // Rewind's own DB never surfaces this state to the user (chunk
        // + videoId are backfilled before UI sees the row), but during
        // live capture the PNG lives under `<vault>/temp/`.
        if entry.chunkRelPath == nil || entry.videoID == nil,
           let name = entry.imageFileName, !name.isEmpty {
            // Rewind stores bare ISO8601 in imageFileName. On-disk file
            // lives at `<vault>/temp/<iso>` (no extension).
            let tempURL = storage.root
                .appendingPathComponent("temp")
                .appendingPathComponent(name)
            if let img = NSImage(contentsOf: tempURL) { return img }
            // Legacy fallback for OpenRewind 0.1 which wrote `temp/1-<iso>.png`.
            let legacyURL = storage.root.appendingPathComponent(name)
            if let img = NSImage(contentsOf: legacyURL) { return img }
        }
        guard let rel = entry.chunkRelPath, let idx = entry.videoFrameIndex
        else { throw OpenRewindError.chunkMissing("entry has no chunk") }
        let cacheKey = "\(entry.videoID ?? 0)#\(idx)"
        // FIX(review-2026-07-28): frameCache reads/writes now go through the
        // serial queue — previously image(for:) mutated the LRU cache
        // concurrently while every DB path used the queue.
        if let hit = (queue.sync { frameCache[cacheKey] }) { return hit }

        let chunk = storage.chunksDir.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: chunk.path)
        else { throw OpenRewindError.chunkMissing(chunk.path) }

        let mp4 = symlinkDir.appendingPathComponent(chunk.lastPathComponent + ".mp4")
        // FIX: symlink creation is racy across concurrent image(for:)
        // callers — check→create is not atomic. Just try; if it exists
        // (POSIX EEXIST or Cocoa 516), that's fine — a peer created it.
        if !FileManager.default.fileExists(atPath: mp4.path) {
            do {
                try FileManager.default.createSymbolicLink(at: mp4,
                                                           withDestinationURL: chunk)
            } catch let err as NSError where err.code == NSFileWriteFileExistsError
                                          || err.code == 17 /* EEXIST */ {
                // peer created it — proceed
            }
        }

        // FIX(perf-2026-07-28): fast path via ThumbnailCache — decoded
        // CGImages survive across scrubs.
        if let hit = ThumbnailCache.shared.image(chunkURL: mp4, frameIndex: idx) {
            cache(cacheKey, hit)
            return hit
        }

        // FIX(perf-2026-07-28): route through the process-wide
        // FrameGeneratorCache so one AVAssetImageGenerator is reused
        // for every frame in a chunk instead of building a fresh one
        // on every tick.
        let gen = FrameGeneratorCache.shared.generator(for: mp4)

        // FIX(review-2026-07-28): read the video's real frameRate rather than
        // hard-coding 30 fps (was CMTime(value: idx*20, timescale: 600)).
        // Aggressive-mode chunks decode the wrong frame under the fixed rate.
        let fps: Double
        if let vid = entry.videoID, let v = try? videoByID(vid), v.frameRate > 0 {
            fps = v.frameRate
        } else {
            fps = 30.0
        }
        let scale = Int32(max(1, round(fps)))
        let time = CMTime(value: Int64(idx), timescale: scale)
        do {
            // Actor call — serialise decode per chunk. Block on the
            // synchronous DispatchSemaphore path we already use here so
            // `image(for:)` stays blocking (@unchecked Sendable Reader
            // is called from Task.detached callers).
            let cg = try Self.blockingDecode(via: gen, time: time)
            // Fall back to real CGImage dims when video row hasn't
            // populated width/height yet.
            let w = entry.width > 0 ? entry.width : cg.width
            let h = entry.height > 0 ? entry.height : cg.height
            let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
            let cost = w * h * 4
            ThumbnailCache.shared.set(img, chunkURL: mp4, frameIndex: idx, costBytes: cost)
            cache(cacheKey, img)
            return img
        } catch {
            // FIX(no-auto-flip-2026-07-30): never auto-flip on
            // decode error. Reports of legit frames disappearing
            // came from too-eager permanent-error classification.
            // Just throw and let the UI show a placeholder; next
            // scrub tries again.
            throw OpenRewindError.decodeFailed("\(error)")
        }
    }

    /// FIX(perf-2026-07-28): bridge the async `FrameGenerator` actor to
    /// the existing blocking `image(for:)` API. Callers wrap this in
    /// `Task.detached`, so blocking here doesn't stall MainActor.
    // FrameGenerator is now a plain class with NSLock-serialised
    // synchronous decode (see FrameGenerator.swift). Direct call — no
    // more async→sync bridge, no cooperative-pool deadlock hazard.
    private static func blockingDecode(via gen: FrameGenerator,
                                       time: CMTime) throws -> CGImage {
        try gen.image(at: time)
    }

    private static func decodeSyncCGImage(from gen: AVAssetImageGenerator,
                                          at time: CMTime) throws -> CGImage {
        if #available(macOS 15.0, *) {
            let sem = DispatchSemaphore(value: 0)
            var result: Result<CGImage, Error>!
            gen.generateCGImageAsynchronously(for: time) { cg, _, err in
                if let cg = cg {
                    result = .success(cg)
                } else {
                    result = .failure(err
                        ?? NSError(domain: "OpenRewindKit", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey:
                                                "unknown decoder failure"]))
                }
                sem.signal()
            }
            sem.wait()
            return try result.get()
        } else {
            return try gen.copyCGImage(at: time, actualTime: nil)
        }
    }

    private func cache(_ key: String, _ img: NSImage) {
        // FIX(review-2026-07-28): route LRU cache mutations through the
        // serial queue to remove the race with concurrent thumbnail
        // callers (Reader is @unchecked Sendable and typically wrapped in
        // Task.detached).
        queue.sync {
            frameCache[key] = img
            cacheOrder.append(key)
            while cacheOrder.count > cacheLimit {
                let victim = cacheOrder.removeFirst()
                frameCache.removeValue(forKey: victim)
            }
        }
    }

    // MARK: - Reopen (workaround for stale-copy snapshot)
    //
    // FIX(review-2026-07-28) [kit MEDIUM upgraded to HIGH TODO]:
    // The Reader init copies the encrypted DB (and its WAL/SHM) to a private
    // temp directory so it can coexist with a running Rewind.app. That means
    // the daemon composition (Reader + Writer on the same vault, same
    // process) sees stale data from Writer inserts. `reopen()` re-snapshots
    // the on-disk vault so callers can refresh without tearing down the
    // whole Reader. Proper fix (share connection with Writer) is deferred.
    public func reopen(passphrase: String) throws {
        try queue.sync {
            // Close current handle + clear cache.
            if let db = db { ork_close_v2(db) }
            db = nil
            frameCache.removeAll()
            cacheOrder.removeAll()
            // Re-snapshot into the same working-copy path.
            let src = storage.dbEncrypted
            try? FileManager.default.removeItem(at: workingCopyURL)
            try FileManager.default.copyItem(at: src, to: workingCopyURL)
            for suffix in ["-wal", "-shm"] {
                let src2 = URL(fileURLWithPath: src.path + suffix)
                let dst = URL(fileURLWithPath: workingCopyURL.path + suffix)
                try? FileManager.default.removeItem(at: dst)
                if FileManager.default.fileExists(atPath: src2.path) {
                    try? FileManager.default.copyItem(at: src2, to: dst)
                }
            }
            var handle: ORKSQLite3?
            let flags = ORK_SQLITE_OPEN_READWRITE | ORK_SQLITE_OPEN_NOMUTEX
            let rc = ork_open_v2(workingCopyURL.path, &handle, flags, nil)
            guard rc == ORK_SQLITE_OK, handle != nil else {
                throw OpenRewindError.openFailed("reopen rc=\(rc)")
            }
            self.db = handle
            let keyRC = passphrase.withCString { p in
                ork_key_v2(handle, "main", p, Int32(strlen(p)))
            }
            guard keyRC == ORK_SQLITE_OK else {
                ork_close_v2(handle); self.db = nil
                throw OpenRewindError.openFailed("reopen key rc=\(keyRC)")
            }
        }
    }

    // NOTE(compat-2026-07-28): star state lives in the app-side
    // `StarStore` sidecar (JSON in Application Support). Rewind's DB
    // is strictly read-only in our contract, and the previous SQL
    // writer both violated that AND crashed by skipping `queue.sync`.

    // MARK: - Internal helpers used by Writer + extensions

    /// Serial dispatch onto the reader's sqlite queue. Public so
    /// `RetentionManager` can share the same lock discipline.
    internal func queueSync<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }
    /// Raw handle — only for the retention DELETE / VACUUM path which
    /// needs `ork_changes(db)` after each `ork_step`.
    internal var dbHandle: ORKSQLite3? { db }

    /// Load all `openclicky_embedding` rows as (frameId, vector Data).
    /// Blobs come back as native Data — skips rawQuery's text encoding
    /// which would corrupt the raw Float32 payload. Sorted by
    /// createdAt DESC, capped at `limit` to bound RAM.
    public func loadEmbeddings(limit: Int = 20000)
        -> [(frameId: Int64, vector: Data)]
    {
        return (try? queueSync {
            let sql = """
                SELECT frameId, vector
                  FROM openclicky_embedding
                  ORDER BY createdAt DESC
                  LIMIT ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, Int64(limit))
            var out: [(Int64, Data)] = []
            while ork_step(stmt) == ORK_SQLITE_ROW {
                let id = ork_col_int64(stmt, 0)
                if let blob = ork_col_blob(stmt, 1), !blob.isEmpty {
                    out.append((id, blob))
                }
            }
            return out
        }) ?? []
    }

    internal func prepare(_ sql: String) throws -> ORKStmt? {
        var stmt: ORKStmt?
        let rc = ork_prepare(db, sql, -1, &stmt, nil)
        guard rc == ORK_SQLITE_OK else {
            let msg = String(cString: ork_errmsg(db)!)
            throw OpenRewindError.queryFailed(msg)
        }
        return stmt
    }

    internal func readEntry(_ stmt: ORKStmt?) -> OpenRewindEntry {
        let id      = ork_col_int64(stmt, 0)
        let created = ork_readString(stmt, 1) ?? ""
        let bundle  = ork_readString(stmt, 2)
        let window  = ork_readString(stmt, 3)
        let url     = ork_readString(stmt, 4)
        let vid: Int64? = ork_col_type(stmt, 5) == ORK_SQLITE_NULL
                        ? nil : ork_col_int64(stmt, 5)
        let fidx: Int?  = ork_col_type(stmt, 6) == ORK_SQLITE_NULL
                        ? nil : Int(ork_col_int(stmt, 6))
        let imgFile = ork_readString(stmt, 7)
        let path    = ork_readString(stmt, 8)
        let w       = Int(ork_col_int(stmt, 9))
        let h       = Int(ork_col_int(stmt, 10))
        return OpenRewindEntry(id: id,
                                createdAt: ORKDate.parse(created) ?? Date(),
                                bundleID: bundle, windowName: window,
                                browserUrl: (url?.isEmpty == false) ? url : nil,
                                videoID: vid, videoFrameIndex: fidx,
                                chunkRelPath: path, width: w, height: h,
                                imageFileName: imgFile)
    }

    private func selectEntries(_ sql: String, _ binds: [ORKBind]) throws -> [OpenRewindEntry] {
        let stmt = try prepare(sql); defer { ork_finalize(stmt) }
        ork_bindAll(stmt, binds)
        var out: [OpenRewindEntry] = []
        while ork_step(stmt) == ORK_SQLITE_ROW { out.append(readEntry(stmt)) }
        return out
    }

    /// Delete `/tmp/openrewindkit-<pid>-*` dirs whose pid no longer
    /// has a live process. Crashed / SIGKILL'd runs leave the working
    /// SQLite copy behind — each ≥ vault size. Boot-time cleanup keeps
    /// /tmp bounded.
    static func purgeOrphanTmpDirs() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: tmp.path) else { return }
        for name in entries where name.hasPrefix("openrewindkit-") {
            // Two formats:
            //   openrewindkit-<pid>-<UUID>   (UUID contains 4 dashes)
            //   openrewindkit-symlinks-<pid>
            // Strip prefix, then peel either the "symlinks-" tag or
            // read the first `-`-terminated field as the pid.
            let stripped = String(name.dropFirst("openrewindkit-".count))
            let pidStr: String
            if stripped.hasPrefix("symlinks-") {
                pidStr = String(stripped.dropFirst("symlinks-".count))
            } else if let dash = stripped.firstIndex(of: "-") {
                pidStr = String(stripped[..<dash])
            } else {
                continue
            }
            guard let pid = pid_t(pidStr) else { continue }
            if pid == getpid() { continue }
            if kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    /// Expand a search query so CJK runs match the bigram-tokenized
    /// index the Writer populates in `otherText`. Latin/digit portions
    /// pass through unchanged. Uses FTS5 OR so any CJK bigram matches.
    /// Example: "珠峰新闻" → "珠峰 峰新 新闻 新闻".
    /// Example: "hello 世界" → "hello 世界".
    // MARK: - Query parser (retrace #14 lean port)

    /// FIX(retrace-#14-2026-07-31): result of parsing a user query.
    /// Extracted tokens go into structured fields; the residue is the
    /// free-text search term. Retrace's QueryParser.swift:18-167 does
    /// the same job with a much bigger tokenizer. We handle the four
    /// tokens users actually type: `site:`, `app:`, `after:`, `before:`
    /// plus quoted phrases.
    internal struct ParsedQuery: Sendable {
        var freeText: String
        var sitePattern: String?
        var appPattern: String?
        var afterDate: Date?
        var beforeDate: Date?
        var hasNoFilters: Bool {
            sitePattern == nil && appPattern == nil
                && afterDate == nil && beforeDate == nil
        }
    }

    internal static func parseAdvancedQuery(_ input: String) -> ParsedQuery {
        var free: [String] = []
        var site: String?
        var app: String?
        var after: Date?
        var before: Date?
        var i = input.startIndex
        while i < input.endIndex {
            // Skip whitespace
            while i < input.endIndex, input[i].isWhitespace { i = input.index(after: i) }
            if i >= input.endIndex { break }
            // Quoted phrase
            if input[i] == "\"" {
                let start = input.index(after: i)
                if let end = input[start...].firstIndex(of: "\"") {
                    free.append(String(input[start..<end]))
                    i = input.index(after: end)
                    continue
                } else {
                    // Unterminated quote: consume rest as free text
                    free.append(String(input[start...]))
                    break
                }
            }
            // Token to next whitespace
            let start = i
            while i < input.endIndex, !input[i].isWhitespace { i = input.index(after: i) }
            let tok = String(input[start..<i])
            let lower = tok.lowercased()
            if let colon = tok.firstIndex(of: ":") {
                let key = String(tok[..<colon]).lowercased()
                let val = String(tok[tok.index(after: colon)...])
                if !val.isEmpty {
                    switch key {
                    case "site":   site = val; continue
                    case "app":    app = val;  continue
                    case "after":  if let d = parseFilterDate(val) { after = d; continue }
                    case "before": if let d = parseFilterDate(val) { before = d; continue }
                    default: break
                    }
                }
                _ = lower  // fall through to free text
            }
            free.append(tok)
        }
        return ParsedQuery(
            freeText: free.joined(separator: " "),
            sitePattern: site, appPattern: app,
            afterDate: after, beforeDate: before)
    }

    /// Parse `after:` / `before:` values. Accept: YYYY-MM-DD, `today`,
    /// `yesterday`, `Nd` (last N days), `Nh` (last N hours).
    private static func parseFilterDate(_ raw: String) -> Date? {
        let s = raw.lowercased()
        let cal = Calendar.current
        let now = Date()
        if s == "today" { return cal.startOfDay(for: now) }
        if s == "yesterday" {
            return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
        }
        if s.hasSuffix("d"), let n = Int(s.dropLast()) {
            return cal.date(byAdding: .day, value: -n, to: now)
        }
        if s.hasSuffix("h"), let n = Int(s.dropLast()) {
            return cal.date(byAdding: .hour, value: -n, to: now)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: raw)
    }

    internal static func expandCJKQuery(_ query: String) -> String {
        // FIX(cjk-fts-or-2026-07-30): return an FTS5 expression that
        //   - joins CJK bigrams from a single CJK run with OR (any
        //     bigram anywhere in the doc counts). Fixes the earlier
        //     AND-semantics bug where 5+ bigrams all had to hit the
        //     same tile-level doc.
        //   - single-char CJK is dropped (writer only emits bigrams;
        //     unigram tokens don't exist in the index).
        //   - Latin runs pass through as porter-stemmed tokens
        //     (AND-joined with the CJK group by default MATCH).
        //
        // Example: "珠峰 hello" → "(\"珠峰\") hello" (any-bigram AND hello)
        // Example: "hello 世界很大" → "hello (\"世界\" OR \"界很\" OR \"很大\")"
        // Example: "珠"                → "" (unigram dropped)
        var groups: [String] = []
        var buffer: [Character] = []
        var latinRun: [Character] = []
        func flushCJK() {
            defer { buffer.removeAll() }
            guard buffer.count >= 2 else { return }
            var bigrams: [String] = []
            for i in 0..<(buffer.count - 1) {
                let bg = String([buffer[i], buffer[i + 1]])
                    .replacingOccurrences(of: "\"", with: "")
                bigrams.append("\"\(bg)\"")
            }
            if bigrams.count == 1 {
                groups.append(bigrams[0])
            } else {
                groups.append("(" + bigrams.joined(separator: " OR ") + ")")
            }
        }
        func flushLatin() {
            defer { latinRun.removeAll() }
            let s = String(latinRun).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return }
            // Strip FTS5 syntax chars that would break MATCH parsing.
            // FIX(fts-latin-sanitize-2026-07-30): `:` is column filter,
            // `*` is prefix wildcard, `!` NEAR/NOT-adjacent, `+` `-`
            // are boolean prefixes when leading. Whitelist to
            // alphanumerics + `_` + `.` (kept for URLs/hosts).
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "._"))
            let cleaned = String(s.unicodeScalars.map {
                allowed.contains($0) ? Character($0) : " "
            }).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty {
                groups.append(cleaned)
            }
        }
        for ch in query {
            if Self.isCJKChar(ch) {
                flushLatin()
                buffer.append(ch)
            } else if ch.isWhitespace {
                flushCJK()
                flushLatin()
            } else {
                flushCJK()
                latinRun.append(ch)
            }
        }
        flushCJK()
        flushLatin()
        // If everything was dropped (single CJK char with no Latin),
        // fall back to empty so caller short-circuits — search()
        // guards for isEmpty and returns [].
        return groups.joined(separator: " ")
    }

    private static func isCJKChar(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) ||
               (0x3040...0x309F).contains(v) ||
               (0x30A0...0x30FF).contains(v) ||
               (0xAC00...0xD7AF).contains(v) ||
               (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }
}
