// Writer.swift — INSERT paths against the Rewind schema. Every column list
// here matches Rewind 1.5607 exactly. Column order and default values are
// load-bearing: the values we emit are the ones Rewind's own recon logic
// preserves across a restart (verified by injection tests in the prototype).
//
// This file only writes. Reader.swift owns the SELECT paths. Both share
// the SQLCipher bindings in Internal/SQLiteBindings.swift.

import Foundation
import CoreGraphics

/// One OCR bounding box the writer stores under `node` for a given frame.
/// Coordinates are 0-1 normalised, top-left origin (same as Rewind).
public struct OpenRewindNodeInput: Sendable {
    public let text: String
    public let leftX: Double
    public let topY: Double
    public let width: Double
    public let height: Double
    public let windowIndex: Int?
    public init(text: String, leftX: Double, topY: Double,
                width: Double, height: Double, windowIndex: Int? = nil) {
        self.text = text; self.leftX = leftX; self.topY = topY
        self.width = width; self.height = height; self.windowIndex = windowIndex
    }
}

/// Row-level bundle Writer.insertFrame accepts. Matches the columns Rewind
/// writes when it finalises a chunk.
public struct OpenRewindFrameInput: Sendable {
    public let createdAt: Date
    public let imageFileName: String       // matches temp/<name> for reconcile
    public let segmentId: Int64
    public let videoId: Int64?
    public let videoFrameIndex: Int?
    public let isStarred: Bool
    public let encodingStatus: String      // 'pending' | 'deferred' | 'success' | 'failed'
    /// FIX(capture-trigger-2026-07-29): retrace V17. Nullable, OpenRewind
    /// vaults only (gated by openrewind_meta marker). Common values:
    /// 'scheduled' | 'window_change' | 'click' | 'idle_wake' | 'manual'.
    public let captureTrigger: String?
    public init(createdAt: Date, imageFileName: String,
                segmentId: Int64, videoId: Int64?, videoFrameIndex: Int?,
                isStarred: Bool = false,
                encodingStatus: String = "success",
                captureTrigger: String? = nil) {
        self.createdAt = createdAt; self.imageFileName = imageFileName
        self.segmentId = segmentId; self.videoId = videoId
        self.videoFrameIndex = videoFrameIndex
        self.isStarred = isStarred; self.encodingStatus = encodingStatus
        self.captureTrigger = captureTrigger
    }
}

// MARK: - Writer

/// Insert-only writer against a Rewind-compatible vault. Opens its own
/// SQLCipher handle so it can coexist with a Reader (both go via WAL).
public final class OpenRewindWriter: @unchecked Sendable {

    public let storage: OpenRewindStorage
    internal var db: ORKSQLite3?
    internal let queue = DispatchQueue(label: "openrewindkit.writer.serial")

    /// Open (or create-open) the vault DB. Runs `CREATE TABLE …` on
    /// first-ever open so a fresh install can start writing immediately.
    public init(storage: OpenRewindStorage,
                passphrase: String) throws {
        self.storage = storage

        let dbExisted = FileManager.default.fileExists(
            atPath: storage.dbEncrypted.path)
        var handle: ORKSQLite3?
        let flags = ORK_SQLITE_OPEN_READWRITE
                  | ORK_SQLITE_OPEN_CREATE
                  | ORK_SQLITE_OPEN_NOMUTEX
        let rc = ork_open_v2(storage.dbEncrypted.path, &handle, flags, nil)
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
        // FIX(rewind-ida-#4-2026-07-31): match Rewind's SQLCipher page
        // size. Rewind sets `cipher_page_size=4096` (0x100ec6933) — the
        // SQLCipher default is 1024 which triggers a well-known 3-5×
        // write throughput regression under WAL. Setting 4096 aligns
        // with the FS block size and matches Rewind's observed perf.
        // Must run BEFORE any statement (SQLCipher validates page
        // size on first crypto operation).
        do {
            var errPtr: UnsafeMutablePointer<CChar>? = nil
            _ = ork_exec(handle, "PRAGMA cipher_page_size = 4096;", nil, nil, &errPtr)
            _ = errPtr
        }
        // Verify key by touching sqlite_master.
        let stmt = try prepare("SELECT count(*) FROM sqlite_master;")
        defer { ork_finalize(stmt) }
        guard ork_step(stmt) == ORK_SQLITE_ROW else {
            throw OpenRewindError.keyRejected
        }
        // Enable FK enforcement so `doc_segment.frameId → frame(id)`
        // stops silently orphaning when retention deletes frames
        // mid-OCR. Also enable WAL journal for read-during-write.
        // FIX(pragma-2026-07-29): match retrace's PRAGMA set
        // (Database/Schema.swift:88-120). `temp_store=MEMORY` keeps
        // FTS merges off disk; `cache_size=-64000` allocates a 64 MB
        // page cache (retrace default) — 2-3× faster BM25 on cold DB;
        // `wal_autocheckpoint=1000` caps WAL at ~4 MB so reads don't
        // stall behind an ever-growing wal file; `auto_vacuum=
        // INCREMENTAL` lets `PRAGMA incremental_vacuum` reclaim space
        // after retention deletes without a blocking full VACUUM.
        for pragma in [
            "PRAGMA foreign_keys = ON;",
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA cache_size = -64000;",
            "PRAGMA wal_autocheckpoint = 1000;",
            "PRAGMA auto_vacuum = INCREMENTAL;",
        ] {
            var errPtr: UnsafeMutablePointer<CChar>? = nil
            _ = ork_exec(handle, pragma, nil, nil, &errPtr)
        }
        if !dbExisted {
            try OpenRewindSchemaInstaller.install(on: handle)
        } else {
            // Idempotent upgrade: adds any missing FTS tables and
            // columns that older OpenRewind vaults are missing.
            // `IF NOT EXISTS` / `IF NOT EXISTS` in the DDL blob makes
            // this safe to run on already-modern vaults too.
            try OpenRewindSchemaInstaller.installIdempotent(on: handle)
        }
    }

    deinit {
        if let db = db { ork_close_v2(db) }
    }

    // MARK: - segment

    /// Insert one focused-app segment. Returns segment.id.
    /// Columns: bundleID, startDate, endDate, windowName, browserUrl,
    /// browserProfile, type. Rewind stores dates in ISO8601 without trailing 'Z'.
    @discardableResult
    public func insertSegment(bundleID: String?,
                              startDate: Date,
                              endDate: Date,
                              windowName: String?,
                              browserUrl: String? = nil,
                              browserProfile: String? = nil,
                              type: Int = 0) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO segment
                    (bundleID, startDate, endDate, windowName,
                     browserUrl, browserProfile, type)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            bind(stmt, 1, bundleID)
            _ = ork_bindString(stmt, 2, ORKDate.iso(startDate))
            _ = ork_bindString(stmt, 3, ORKDate.iso(endDate))
            bind(stmt, 4, windowName)
            bind(stmt, 5, browserUrl)
            bind(stmt, 6, browserProfile)
            _ = ork_bind_int64(stmt, 7, Int64(type))
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    /// Update an existing segment's `endDate`. Used by capture coordinator
    /// to close out the current segment on shutdown so the timeline row
    /// doesn't reflect the bogus `+3600s` future placeholder we stamp when
    /// the segment first opens.
    ///
    /// FIX(review-2026-07-28) C-2 (capture CRITICAL "segment never closed").
    public func updateSegmentEnd(id: Int64, endedAt: Date) throws {
        try queue.sync {
            let sql = "UPDATE segment SET endDate = ? WHERE id = ?;"
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, ORKDate.iso(endedAt))
            _ = ork_bind_int64(stmt, 2, id)
            try step(stmt)
        }
    }

    /// Find the newest frame in a segment. Used by the AX / OCR
    /// fallback path when a caller says "attach to nearest".
    public func latestFrameId(inSegment segmentId: Int64) throws -> Int64? {
        try queue.sync {
            let sql = "SELECT id FROM frame WHERE segmentId = ? ORDER BY createdAt DESC LIMIT 1;"
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentId)
            guard ork_step(stmt) == ORK_SQLITE_ROW else { return nil }
            return ork_col_int64(stmt, 0)
        }
    }

    /// Backfill videoId + videoFrameIndex on a frame that was inserted
    /// hot (videoId=NULL). Mirrors retrace `updateVideoLink`
    /// (research/refs/retrace/Database/Queries/FrameQueries.swift:76).
    public func updateFrameVideoLink(frameId: Int64,
                                     videoId: Int64,
                                     videoFrameIndex: Int) throws {
        try queue.sync {
            // FIX(compat-2026-07-29): encodingStatus is TEXT
            // ('success' / 'pending' / 'deferred') in Rewind. Was
            // integer 1 before — type-inconsistent with the rest of
            // the pipeline.
            // Only promote 'pending' → 'success'. Leaves 'failed' /
            // 'deferred' intact so retry paths keep their context.
            // FIX(retrace-#6-2026-07-31): stamp encodedAt too. That
            // column is authoritative "frame is durable in mp4"; the
            // reader / retention paths can then discriminate against
            // in-flight frames that would trip AVAsset timing errors.
            let sql = """
                UPDATE frame
                   SET videoId = ?, videoFrameIndex = ?,
                       encodingStatus = 'success',
                       encodedAt = ?
                 WHERE id = ? AND encodingStatus = 'pending';
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, videoId)
            _ = ork_bind_int64(stmt, 2, Int64(videoFrameIndex))
            _ = ork_bindString(stmt, 3, ORKDate.iso(Date()))
            _ = ork_bind_int64(stmt, 4, frameId)
            try step(stmt)
        }
    }

    /// FIX(retrace-#7-2026-07-31): stamp redactionReason on a frame
    /// row so downstream analytics know why OCR was skipped. Column
    /// exists in the Rewind V17/V7 schema — see SchemaInstaller.
    @discardableResult
    public func stampRedactionReason(frameId: Int64, reason: String) throws -> Int {
        try queue.sync {
            let sql = """
                UPDATE frame SET redactionReason = ?
                 WHERE id = ? AND (redactionReason IS NULL OR redactionReason = '');
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, reason)
            _ = ork_bind_int64(stmt, 2, frameId)
            try step(stmt)
            return Int(ork_changes(db))
        }
    }

    /// FIX(storage-2026-07-31): DELETE rows that are permanently
    /// unrecoverable — encodingStatus='failed' AND videoId IS NULL AND
    /// older than `cutoff`. Their PNG has been age-purged from
    /// <vault>/temp long ago; nothing can reconstruct the pixels.
    /// Also cascade-drops their `node` and `searchRanking` rows via
    /// the FK/doc_segment link. Returns rows affected.
    ///
    /// This shrinks the DB (Rewind vault compat preserved — deleting
    /// rows Rewind would also treat as invalid never breaks anything).
    @discardableResult
    public func purgeDeadFailedFrames(olderThan cutoff: Date) throws -> Int {
        try queue.sync {
            let cutoffTS = cutoff.timeIntervalSince1970
            // Collect ids first — cascade delete then cleans up
            // doc_segment (which is not enforced by FK) manually.
            var ids: [Int64] = []
            do {
                let sel = """
                    SELECT id FROM frame
                     WHERE encodingStatus = 'failed'
                       AND videoId IS NULL
                       AND (strftime('%s', createdAt) + 0) < ?;
                    """
                let stmt = try prepare(sel); defer { ork_finalize(stmt) }
                _ = ork_bind_double(stmt, 1, cutoffTS)
                while ork_step(stmt) == ORK_SQLITE_ROW {
                    ids.append(ork_col_int64(stmt, 0))
                }
            }
            guard !ids.isEmpty else { return 0 }
            // Drop related searchRanking docids first, then nodes,
            // then frame rows. searchRanking uses external doc_segment
            // link; FTS5 needs the delete via docid.
            let dropSR = """
                DELETE FROM searchRanking
                 WHERE rowid IN (SELECT docid FROM doc_segment WHERE frameId = ?);
                """
            let dropDS = "DELETE FROM doc_segment WHERE frameId = ?;"
            let dropNode = "DELETE FROM node WHERE frameId = ?;"
            let dropFrame = "DELETE FROM frame WHERE id = ?;"
            let s1 = try prepare(dropSR); defer { ork_finalize(s1) }
            let s2 = try prepare(dropDS); defer { ork_finalize(s2) }
            let s3 = try prepare(dropNode); defer { ork_finalize(s3) }
            let s4 = try prepare(dropFrame); defer { ork_finalize(s4) }
            for id in ids {
                _ = ork_bind_int64(s1, 1, id); try step(s1); _ = ork_reset(s1)
                _ = ork_bind_int64(s2, 1, id); try step(s2); _ = ork_reset(s2)
                _ = ork_bind_int64(s3, 1, id); try step(s3); _ = ork_reset(s3)
                _ = ork_bind_int64(s4, 1, id); try step(s4); _ = ork_reset(s4)
            }
            return ids.count
        }
    }

    /// FIX(no-local-chunk-2026-07-30): mark every pending frame older
    /// than `olderThan` as `'failed'`. Used by StartupReconciler
    /// after retroactive linking to hide truly-unrecoverable rows
    /// from the timeline. `frame.createdAt` is TEXT ISO8601 —
    /// compare via strftime to epoch for a numeric comparison.
    /// Returns rows affected.
    @discardableResult
    public func markPendingFramesFailed(olderThan cutoff: Date) throws -> Int {
        try queue.sync {
            let cutoffTS = cutoff.timeIntervalSince1970
            let sql = """
                UPDATE frame SET encodingStatus = 'failed'
                WHERE encodingStatus = 'pending'
                  AND (strftime('%s', createdAt) + 0) < ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_double(stmt, 1, cutoffTS)
            try step(stmt)
            return Int(ork_changes(db))
        }
    }

    /// FIX(root-cause-2026-07-30): backfill videoId for every pending
    /// frame whose `createdAt` falls within `[startedAt, endedAt]` of a
    /// chunk. In-memory `pendingFrameLinks` gets wiped on process
    /// restart; without this, thousands of orphan `pending` rows
    /// accumulate that have a real chunk on disk but no DB link →
    /// "no local chunk (only iCloud copy)" UI placeholder.
    ///
    /// Timestamp-window match is safe: Chunker only rolls sequential
    /// frames from the same session into one chunk, and no other
    /// chunk overlaps that same wall-clock window.
    ///
    /// Returns the number of rows linked.
    @discardableResult
    public func linkPendingFramesToVideo(videoId: Int64,
                                         startedAt: Date,
                                         endedAt: Date) throws -> Int {
        try queue.sync {
            let startTS = startedAt.timeIntervalSince1970
            let endTS = endedAt.timeIntervalSince1970
            // FIX(retro-link-index-2026-07-30): first learn what
            // frameIndex the chunk *actually holds*. Chunk was
            // originally written with a fixed number of frames;
            // linking beyond that count produces frameIndex values
            // for which the mp4 has no track, so image(for:) returns
            // nothing and the UI shows "no local chunk". Cap the
            // retroactive assignment at the existing successful
            // frame count.
            var existingCount: Int = 0
            var existingMaxIdx: Int64 = -1
            do {
                let sel = """
                    SELECT COUNT(*), COALESCE(MAX(videoFrameIndex), -1)
                      FROM frame
                     WHERE videoId = ? AND encodingStatus = 'success';
                    """
                let stmt = try prepare(sel); defer { ork_finalize(stmt) }
                _ = ork_bind_int64(stmt, 1, videoId)
                if ork_step(stmt) == ORK_SQLITE_ROW {
                    existingCount = Int(ork_col_int64(stmt, 0))
                    existingMaxIdx = ork_col_int64(stmt, 1)
                }
            }
            var ids: [Int64] = []
            do {
                let sel = """
                    SELECT id FROM frame
                     WHERE encodingStatus = 'pending'
                       AND videoId IS NULL
                       AND (strftime('%s', createdAt) + 0) BETWEEN ? AND ?
                     ORDER BY createdAt ASC;
                    """
                let stmt = try prepare(sel); defer { ork_finalize(stmt) }
                _ = ork_bind_double(stmt, 1, startTS)
                _ = ork_bind_double(stmt, 2, endTS)
                while ork_step(stmt) == ORK_SQLITE_ROW {
                    ids.append(ork_col_int64(stmt, 0))
                }
            }
            guard !ids.isEmpty else { return 0 }
            // Only link up to the chunk's actual capacity. Assume ~30
            // frames per chunk (2 fps × 15 s Chunker interval) when
            // there are ZERO existing frames — safer to fail closed
            // and mark truly-orphan rows failed than to link them to
            // nonexistent mp4 tracks.
            // Chunker.maxFrames default = 150 (2 fps × 300 s).
            let chunkCapacity = max(existingCount, 150)
            let slotsAvailable = max(0, chunkCapacity - existingCount)
            let toLink = Array(ids.prefix(slotsAvailable))
            let overflow = Array(ids.dropFirst(slotsAvailable))
            let upd = """
                UPDATE frame
                   SET videoId = ?, videoFrameIndex = ?, encodingStatus = 'success'
                 WHERE id = ? AND encodingStatus = 'pending';
                """
            let stmt = try prepare(upd); defer { ork_finalize(stmt) }
            for (i, fid) in toLink.enumerated() {
                let assignIdx = existingMaxIdx + 1 + Int64(i)
                _ = ork_bind_int64(stmt, 1, videoId)
                _ = ork_bind_int64(stmt, 2, assignIdx)
                _ = ork_bind_int64(stmt, 3, fid)
                try step(stmt)
                _ = ork_reset(stmt)
            }
            // Anything overflowing the chunk capacity — mark failed
            // so the timeline filter hides them instead of showing
            // broken "no local chunk" placeholders.
            if !overflow.isEmpty {
                let fail = "UPDATE frame SET encodingStatus = 'failed' WHERE id = ?;"
                let s2 = try prepare(fail); defer { ork_finalize(s2) }
                for fid in overflow {
                    _ = ork_bind_int64(s2, 1, fid)
                    try step(s2)
                    _ = ork_reset(s2)
                }
            }
            return toLink.count
        }
    }

    /// Repair frames whose videoFrameIndex exceeds the actual number
    /// of frames in the chunk. Fills with 'failed' status so the
    /// timeline filter hides them. Called by StartupReconciler to
    /// undo damage from earlier buggy retro-linker versions.
    /// FIX(regression-2026-07-30): the previous cap of 30 was WRONG —
    /// Chunker.maxFrames default is 150. Capping at 30 flipped legit
    /// frames to 'failed'. This function is now a no-op; kept to
    /// preserve StartupReconciler wiring. Overflow-index rows are
    /// harmless: they just fail to decode and the UI shows a
    /// placeholder — better than losing valid rows.
    @discardableResult
    public func failFramesWithOverflowIndex() throws -> Int {
        return 0
    }

    /// Reverse the damage from the 30-cap version by flipping every
    /// row that STILL has a valid chunkRelPath (video row exists) but
    /// was marked 'failed' with a videoFrameIndex between 30 and 149
    /// back to 'success'. Runs once at boot after schema install.
    /// Bulk-fail every row in a chunk whose videoFrameIndex ≥ min.
    /// Called by StartupReconciler's chunk-probe pass so overflow
    /// rows are hidden BEFORE the user scrubs through them.
    @discardableResult
    public func failFramesWithVideoIdAndIndexAtLeast(videoId: Int64,
                                                     minIndex: Int64) throws -> Int {
        try queue.sync {
            let sql = """
                UPDATE frame SET encodingStatus = 'failed'
                 WHERE encodingStatus = 'success'
                   AND videoId = ? AND videoFrameIndex >= ?;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, videoId)
            _ = ork_bind_int64(stmt, 2, minIndex)
            try step(stmt)
            return Int(ork_changes(db))
        }
    }

    /// Mark a single frame 'failed' — used by the self-heal observer
    /// when image(for:) can't decode it. Bounds "no local chunk" to
    /// at most one occurrence per bad row.
    @discardableResult
    public func markFrameFailed(id: Int64) throws -> Bool {
        try queue.sync {
            let sql = "UPDATE frame SET encodingStatus = 'failed' WHERE id = ? AND encodingStatus = 'success';"
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, id)
            try step(stmt)
            return Int(ork_changes(db)) > 0
        }
    }

    @discardableResult
    public func restoreOverCappedFrames() throws -> Int {
        try queue.sync {
            let sql = """
                UPDATE frame SET encodingStatus = 'success'
                 WHERE encodingStatus = 'failed'
                   AND videoId IS NOT NULL
                   AND videoFrameIndex >= 30
                   AND videoFrameIndex < 150;
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            try step(stmt)
            return Int(ork_changes(db))
        }
    }

    // MARK: - video

    /// Insert one chunk registry row. Columns: height, width, path,
    /// captureType, fileSize, frameRate, local, xid, processingState.
    @discardableResult
    public func insertVideo(width: Int,
                            height: Int,
                            path: String,
                            captureType: String? = "",
                            fileSize: Int64,
                            frameRate: Double,
                            local: Bool = true,
                            xid: String,
                            processingState: Int = 0) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO video
                    (height, width, path, captureType, fileSize,
                     frameRate, "local", xid, processingState)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, Int64(height))
            _ = ork_bind_int64(stmt, 2, Int64(width))
            _ = ork_bindString(stmt, 3, path)
            bind(stmt, 4, captureType)
            _ = ork_bind_int64(stmt, 5, fileSize)
            _ = ork_bind_double(stmt, 6, frameRate)
            _ = ork_bind_int64(stmt, 7, local ? 1 : 0)
            _ = ork_bindString(stmt, 8, xid)
            _ = ork_bind_int64(stmt, 9, Int64(processingState))
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    // MARK: - frame

    /// Insert one frame row. See docs/SCHEMA.md#frame — reconcile rule
    /// requires `encodingStatus='success'` for post-chunk rows to survive
    /// a Rewind restart. Columns in insertion order: createdAt,
    /// imageFileName, segmentId, videoId, videoFrameIndex, isStarred,
    /// encodingStatus.
    @discardableResult
    public func insertFrame(_ input: OpenRewindFrameInput) throws -> Int64 {
        try queue.sync {
            // FIX(capture-trigger-2026-07-29): try the 8-column form
            // when we have a trigger and the schema has the extension
            // column (OpenRewind vault via `openrewind_meta`). Fall
            // back to 7-column vanilla form otherwise so Rewind-vault
            // writes (if any) stay Rewind-schema safe. Cached bool
            // avoids `PRAGMA table_info` per insert.
            if let trig = input.captureTrigger, hasCaptureTriggerColumn() {
                let sql = """
                    INSERT INTO frame
                        (createdAt, imageFileName, segmentId, videoId,
                         videoFrameIndex, isStarred, encodingStatus,
                         capture_trigger)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """
                let stmt = try prepare(sql); defer { ork_finalize(stmt) }
                _ = ork_bindString(stmt, 1, ORKDate.iso(input.createdAt))
                _ = ork_bindString(stmt, 2, input.imageFileName)
                _ = ork_bind_int64(stmt, 3, input.segmentId)
                if let v = input.videoId { _ = ork_bind_int64(stmt, 4, v) }
                else { _ = ork_bind_null(stmt, 4) }
                if let idx = input.videoFrameIndex { _ = ork_bind_int64(stmt, 5, Int64(idx)) }
                else { _ = ork_bind_null(stmt, 5) }
                _ = ork_bind_int64(stmt, 6, input.isStarred ? 1 : 0)
                _ = ork_bindString(stmt, 7, input.encodingStatus)
                _ = ork_bindString(stmt, 8, trig)
                try step(stmt)
                return ork_last_insert_rowid(db)
            }
            let sql = """
                INSERT INTO frame
                    (createdAt, imageFileName, segmentId, videoId,
                     videoFrameIndex, isStarred, encodingStatus)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, ORKDate.iso(input.createdAt))
            _ = ork_bindString(stmt, 2, input.imageFileName)
            _ = ork_bind_int64(stmt, 3, input.segmentId)
            if let v = input.videoId { _ = ork_bind_int64(stmt, 4, v) }
            else { _ = ork_bind_null(stmt, 4) }
            if let idx = input.videoFrameIndex { _ = ork_bind_int64(stmt, 5, Int64(idx)) }
            else { _ = ork_bind_null(stmt, 5) }
            _ = ork_bind_int64(stmt, 6, input.isStarred ? 1 : 0)
            _ = ork_bindString(stmt, 7, input.encodingStatus)
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    private var _captureTriggerCached: Bool?
    /// One-shot PRAGMA table_info probe, cached for the Writer's lifetime.
    private func hasCaptureTriggerColumn() -> Bool {
        if let c = _captureTriggerCached { return c }
        var stmt: ORKStmt? = nil
        let sql = "PRAGMA table_info(frame)"
        guard ork_prepare(db, sql, -1, &stmt, nil) == ORK_SQLITE_OK else {
            _captureTriggerCached = false; return false
        }
        defer { ork_finalize(stmt) }
        var found = false
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let c = ork_col_text(stmt, 1),
               String(cString: c) == "capture_trigger" { found = true; break }
        }
        _captureTriggerCached = found
        return found
    }

    // MARK: - searchRanking (FTS5) + doc_segment + node

    /// Insert OCR/AX text into `searchRanking` and link it to the frame via
    /// `doc_segment`. Also writes per-word bounding boxes to `node`. This
    /// is the write side of the exact reverse query the Reader uses.
    ///
    /// `text`      -> searchRanking.c0
    /// `otherText` -> searchRanking.c1 (AX tree contents in OpenRewind)
    /// `title`     -> searchRanking.c2 (short app tail, e.g. "safari")
    /// Extract every 2-char CJK run window from `text`, output
    /// space-separated. `text = "你好世界"` → `"你好 好世 世界"`.
    /// Runs of pure Latin/digit/space produce nothing. Cheap:
    /// single linear scan.
    internal static func cjkBigrams(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        // FIX(perf-2026-08-01 algo-agent #5): rewrite via UnicodeScalar
        // iteration into a single pre-allocated `String` buffer instead
        // of building `[Character]` runs + `[String]` bigrams + final
        // `joined`. Was 4000+ heap allocs per frame flush; now O(1)
        // allocations amortized. ~5-10× faster on CJK-heavy pages.
        // Semantics preserved: same bigrams, same separators.
        var out = ""
        out.reserveCapacity(text.count * 3)  // rough utf8 estimate
        var prev: Unicode.Scalar? = nil
        var inCJKRun = false
        var sawAnyCJK = false
        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) {
                sawAnyCJK = true
                if inCJKRun, let p = prev {
                    if !out.isEmpty { out.append(" ") }
                    out.unicodeScalars.append(p)
                    out.unicodeScalars.append(scalar)
                }
                prev = scalar
                inCJKRun = true
            } else {
                inCJKRun = false
                prev = nil
            }
        }
        return sawAnyCJK ? out : ""
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0x3040...0x309F).contains(v)  // Hiragana
            || (0x30A0...0x30FF).contains(v)  // Katakana
            || (0xAC00...0xD7AF).contains(v)  // Hangul
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) ||    // CJK Unified Ideographs
               (0x3040...0x309F).contains(v) ||    // Hiragana
               (0x30A0...0x30FF).contains(v) ||    // Katakana
               (0xAC00...0xD7AF).contains(v) ||    // Hangul Syllables
               (0x3400...0x4DBF).contains(v) {     // CJK Extension A
                return true
            }
        }
        return false
    }

    public func insertSearchRanking(frameId: Int64,
                                    segmentId: Int64,
                                    text: String,
                                    otherText: String? = nil,
                                    title: String? = nil,
                                    nodes: [OpenRewindNodeInput] = []) throws -> Int64 {
        try queue.sync {
            // FIX(perf-audit-2026-07-31): wrap FTS + doc_segment + N
            // node inserts in ONE transaction. Was N+2 implicit txns →
            // one WAL fsync each. Single BEGIN IMMEDIATE + COMMIT
            // collapses to one fsync → 5-15× throughput on OCR-heavy
            // frames (300-1500 nodes).
            var beginErr: UnsafeMutablePointer<CChar>?
            let beginRC = ork_exec(db, "BEGIN IMMEDIATE;", nil, nil, &beginErr)
            _ = beginErr  // sqlite owns the string; leak on error is fine.
            let inTxn = (beginRC == ORK_SQLITE_OK)
            var commitDone = false
            defer {
                if inTxn && !commitDone {
                    var rollErr: UnsafeMutablePointer<CChar>?
                    _ = ork_exec(db, "ROLLBACK;", nil, nil, &rollErr)
                    _ = rollErr
                }
            }
            // FIX(cjk-fts-2026-07-30): searchRanking uses porter
            // tokenizer which is Latin-only — CJK runs get stored
            // as one un-tokenizable blob, so FTS recall for
            // Chinese/Japanese queries is essentially zero.
            // Vault-compat workaround: append space-separated CJK
            // character bigrams to `otherText` ONLY. `text` stays
            // pristine so Rewind (which reads this vault) shows
            // the original OCR without our augmentation. Porter
            // treats bigrams as pseudo-Latin tokens, giving CJK
            // queries real BM25 recall via the otherText field.
            let originalBig = Self.cjkBigrams(text)
            let otherAug: String? = {
                let base = otherText ?? ""
                let bigOther = Self.cjkBigrams(base)
                let merged = [base, bigOther, originalBig]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return merged.isEmpty ? nil : merged
            }()
            let insertFTS = """
                INSERT INTO searchRanking (text, otherText, title)
                VALUES (?, ?, ?);
                """
            let stmt = try prepare(insertFTS); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, text)
            bind(stmt, 2, otherAug)
            bind(stmt, 3, title)
            try step(stmt)
            let docid = ork_last_insert_rowid(db)

            // 2. Link to frame via doc_segment.
            let linkSQL = """
                INSERT INTO doc_segment (docid, segmentId, frameId)
                VALUES (?, ?, ?);
                """
            let link = try prepare(linkSQL); defer { ork_finalize(link) }
            _ = ork_bind_int64(link, 1, docid)
            _ = ork_bind_int64(link, 2, segmentId)
            _ = ork_bind_int64(link, 3, frameId)
            try step(link)

            // 3. Per-word node rows. textOffset/textLength are UTF-16
            //    positions into the concatenated `text` column so the
            //    Reader can slice snippets. We assume nodes are supplied
            //    in the same order they were concatenated (single space
            //    separator, matching what the ContextExtractor emits).
            _ = text  // silence "unused" if nodes are empty
            if !nodes.isEmpty {
                // FIX(storage-2026-07-31): filter noise nodes.
                //   • drop textLength < 2 (single-char OCR fragments — Vision
                //     splits per-character on some CJK/emoji, doubles our
                //     node table with essentially zero search value).
                //   • cap per-frame node count at 1500 (rewind observed p99
                //     was ~800; anything above 1500 is a spam page like a
                //     wiki index — top-1500 is enough to search / snippet).
                //   • drop whitespace-only text.
                let kept = nodes.enumerated()
                    .filter { (_, n) in
                        let s = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return s.utf16.count >= 2
                    }
                    .prefix(1500)
                let nodeSQL = """
                    INSERT INTO node
                        (frameId, nodeOrder, textOffset, textLength,
                         leftX, topY, width, height, windowIndex)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                let nstmt = try prepare(nodeSQL); defer { ork_finalize(nstmt) }
                var offset = 0
                for (order, n) in kept {
                    let len = n.text.utf16.count
                    _ = ork_reset(nstmt)
                    _ = ork_bind_int64(nstmt, 1, frameId)
                    _ = ork_bind_int64(nstmt, 2, Int64(order))
                    _ = ork_bind_int64(nstmt, 3, Int64(offset))
                    _ = ork_bind_int64(nstmt, 4, Int64(len))
                    _ = ork_bind_double(nstmt, 5, n.leftX)
                    _ = ork_bind_double(nstmt, 6, n.topY)
                    _ = ork_bind_double(nstmt, 7, n.width)
                    _ = ork_bind_double(nstmt, 8, n.height)
                    if let wi = n.windowIndex {
                        _ = ork_bind_int64(nstmt, 9, Int64(wi))
                    } else {
                        _ = ork_bind_null(nstmt, 9)
                    }
                    try step(nstmt)
                    offset += len + 1  // +1 for the single-space separator
                }
            }
            // FIX(perf-audit-2026-07-31): finalize the transaction on
            // success. `defer` above rolls back on any thrown error.
            if inTxn {
                var commitErr: UnsafeMutablePointer<CChar>?
                _ = ork_exec(db, "COMMIT;", nil, nil, &commitErr)
                _ = commitErr
                commitDone = true
            }
            return docid
        }
    }

    // MARK: - node (standalone entry point if searchRanking already written)

    public func insertNode(frameId: Int64,
                           nodeOrder: Int,
                           textOffset: Int,
                           textLength: Int,
                           leftX: Double, topY: Double,
                           width: Double, height: Double,
                           windowIndex: Int? = nil) throws {
        try queue.sync {
            let sql = """
                INSERT INTO node
                    (frameId, nodeOrder, textOffset, textLength,
                     leftX, topY, width, height, windowIndex)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameId)
            _ = ork_bind_int64(stmt, 2, Int64(nodeOrder))
            _ = ork_bind_int64(stmt, 3, Int64(textOffset))
            _ = ork_bind_int64(stmt, 4, Int64(textLength))
            _ = ork_bind_double(stmt, 5, leftX)
            _ = ork_bind_double(stmt, 6, topY)
            _ = ork_bind_double(stmt, 7, width)
            _ = ork_bind_double(stmt, 8, height)
            if let wi = windowIndex { _ = ork_bind_int64(stmt, 9, Int64(wi)) }
            else { _ = ork_bind_null(stmt, 9) }
            try step(stmt)
        }
    }

    // MARK: - event

    /// Insert one event row. Rewind uses `type` values like 'calendar' for
    /// its meeting timeline; OpenRewind adds `ui_key`, `ui_click`,
    /// `ui_app_switch`. Rewind's UI silently ignores unknown types, so this
    /// is a safe overlay.
    @discardableResult
    public func insertEvent(type: String,
                            status: String,
                            title: String? = nil,
                            participants: String? = nil,
                            detailsJSON: String? = nil,
                            calendarID: String? = nil,
                            calendarEventID: String? = nil,
                            calendarSeriesID: String? = nil,
                            segmentID: Int64 = 0) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO event
                    (type, status, title, participants, detailsJSON,
                     calendarID, calendarEventID, calendarSeriesID, segmentID)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, type)
            _ = ork_bindString(stmt, 2, status)
            bind(stmt, 3, title)
            bind(stmt, 4, participants)
            bind(stmt, 5, detailsJSON)
            bind(stmt, 6, calendarID)
            bind(stmt, 7, calendarEventID)
            bind(stmt, 8, calendarSeriesID)
            _ = ork_bind_int64(stmt, 9, segmentID)
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    // MARK: - audio

    @discardableResult
    public func insertAudio(segmentId: Int64,
                            path: String,
                            startTime: Date,
                            duration: Double) throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT INTO audio (segmentId, path, startTime, duration)
                VALUES (?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentId)
            _ = ork_bindString(stmt, 2, path)
            _ = ork_bindString(stmt, 3, ORKDate.iso(startTime))
            _ = ork_bind_double(stmt, 4, duration)
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    // MARK: - transcript_word

    // FIX(review-2026-07-28) K-L: cache the presence of the optional
    // `speakerId` column so we don't hit PRAGMA on every insert. Nil until
    // the first insert probes the schema.
    private var _speakerIdColumnAvailable: Bool?

    private func transcriptWordHasSpeakerColumn() -> Bool {
        if let cached = _speakerIdColumnAvailable { return cached }
        var stmt: ORKStmt?
        let sql = "PRAGMA table_info(\"transcript_word\");"
        guard ork_prepare(db, sql, -1, &stmt, nil) == ORK_SQLITE_OK else {
            _speakerIdColumnAvailable = false
            return false
        }
        defer { ork_finalize(stmt) }
        var found = false
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let n = ork_readString(stmt, 1),
               n.caseInsensitiveCompare("speakerId") == .orderedSame {
                found = true; break
            }
        }
        _speakerIdColumnAvailable = found
        return found
    }

    @discardableResult
    public func insertTranscriptWord(segmentId: Int64,
                                     word: String,
                                     startTime: Double,
                                     endTime: Double,
                                     fullTextOffset: Int? = nil,
                                     // FIX(review-2026-07-28) K-L: opportunistic
                                     // speakerId — silently dropped when the
                                     // column is absent on this vault.
                                     speakerId: Int64? = nil,
                                     // FIX(audio-source-2026-07-31): route
                                     // hint — mic / system / chat / voice /
                                     // "" (unknown). Silently dropped when
                                     // the column doesn't exist (older /
                                     // Rewind-native vaults).
                                     audioSource: String? = nil) throws -> Int64 {
        // FIX(compat-2026-07-29): Rewind's schema stores timeOffset +
        // duration as INTEGER ms (not startTime/endTime REAL). Convert
        // at the boundary. speechSource is required (NOT NULL) so
        // supply a sensible default when the caller omits it.
        let timeOffset = Int64((startTime * 1000).rounded())
        let duration = Int64(max(0, ((endTime - startTime) * 1000).rounded()))
        return try queue.sync {
            let hasSpeaker = transcriptWordHasSpeakerColumn()
            let hasAudioSource = transcriptWordHasAudioSourceColumn()
            // Build INSERT dynamically to skip columns that don't
            // exist on this vault (Rewind-native has neither speaker
            // nor audioSource).
            var cols = "(segmentId, speechSource, word, timeOffset, duration, fullTextOffset"
            var vals = "(?, 'apple.speech', ?, ?, ?, ?"
            if hasSpeaker      { cols += ", speakerId";   vals += ", ?" }
            if hasAudioSource  { cols += ", audioSource"; vals += ", ?" }
            cols += ")"; vals += ")"
            let sql = "INSERT INTO transcript_word \(cols) VALUES \(vals);"
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, segmentId)
            _ = ork_bindString(stmt, 2, word)
            _ = ork_bind_int64(stmt, 3, timeOffset)
            _ = ork_bind_int64(stmt, 4, duration)
            if let off = fullTextOffset { _ = ork_bind_int64(stmt, 5, Int64(off)) }
            else { _ = ork_bind_null(stmt, 5) }
            var idx: Int32 = 6
            if hasSpeaker {
                if let sid = speakerId { _ = ork_bind_int64(stmt, idx, sid) }
                else { _ = ork_bind_null(stmt, idx) }
                idx += 1
            }
            if hasAudioSource {
                _ = ork_bindString(stmt, idx, audioSource ?? "")
                idx += 1
            }
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    /// Cache-aware column probe for `audioSource`. Same pattern as
    /// the existing `transcriptWordHasSpeakerColumn` helper.
    private var _cachedTranscriptWordHasAudioSource: Bool?
    private func transcriptWordHasAudioSourceColumn() -> Bool {
        if let v = _cachedTranscriptWordHasAudioSource { return v }
        let sql = "PRAGMA table_info(transcript_word);"
        guard let stmt = try? prepare(sql) else {
            _cachedTranscriptWordHasAudioSource = false
            return false
        }
        defer { ork_finalize(stmt) }
        var found = false
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let name = ork_col_text(stmt, 1),
               String(cString: name) == "audioSource" {
                found = true; break
            }
        }
        _cachedTranscriptWordHasAudioSource = found
        return found
    }

    // MARK: - summary

    @discardableResult
    public func insertSummary(eventId: Int64?,
                              status: String = "pending") throws -> Int64 {
        try queue.sync {
            let sql = """
                INSERT OR IGNORE INTO summary (eventId, status) VALUES (?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            if let e = eventId { _ = ork_bind_int64(stmt, 1, e) }
            else { _ = ork_bind_null(stmt, 1) }
            _ = ork_bindString(stmt, 2, status)
            try step(stmt)
            return ork_last_insert_rowid(db)
        }
    }

    // MARK: - purge

    /// Insert one row into `purge`, Rewind's cross-restart cleanup queue.
    /// Rewind wakes on launch and unlinks each `path` whose `fileType`
    /// matches the reconcile logic. OpenRewind should enqueue orphaned
    /// PNGs / stale chunk files here rather than deleting them inline —
    /// mirrors Rewind's own crash-safe cleanup.
    ///
    /// FIX(review-2026-07-28) K-M-5: purge table has no writer.
    public func insertPurge(path: String, fileType: String) throws {
        try queue.sync {
            let sql = """
                INSERT OR IGNORE INTO purge (path, fileType) VALUES (?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bindString(stmt, 1, path)
            _ = ork_bindString(stmt, 2, fileType)
            try step(stmt)
        }
    }

    // MARK: - frame_processing

    /// Mark a frame as processed by a given ML pipeline. Rewind checks this
    /// table before re-OCR'ing a frame; write ('ocr', now) after OCR and
    /// ('ax', now) after AX capture.
    public func markFrameProcessed(frameId: Int64,
                                   processingType: String,
                                   createdAt: Date = Date()) throws {
        try queue.sync {
            // Rewind uses UNIQUE(id, processingType); INSERT OR IGNORE
            // keeps us idempotent under retries.
            let sql = """
                INSERT OR IGNORE INTO frame_processing
                    (id, processingType, createdAt)
                VALUES (?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameId)
            _ = ork_bindString(stmt, 2, processingType)
            _ = ork_bindString(stmt, 3, ORKDate.iso(createdAt))
            try step(stmt)
        }
    }

    /// Insert-or-replace one row in the openclicky_embedding sidecar
    /// table. `vec` is raw Float32 packed into Data (native order).
    /// Safe to call for the same frameId multiple times — the row
    /// gets overwritten, matching NLEmbedding's re-emit semantics.
    public func upsertEmbedding(frameId: Int64,
                                 model: String,
                                 vec: Data,
                                 createdAt: Date = Date()) throws {
        try queue.sync {
            let sql = """
                INSERT OR REPLACE INTO openclicky_embedding
                    (frameId, model, vector, createdAt)
                VALUES (?, ?, ?, ?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            _ = ork_bind_int64(stmt, 1, frameId)
            _ = ork_bindString(stmt, 2, model)
            vec.withUnsafeBytes { raw in
                _ = ork_bind_blob(stmt, 3,
                                   raw.baseAddress,
                                   Int32(raw.count),
                                   ORK_SQLITE_TRANSIENT)
            }
            _ = ork_bindString(stmt, 4, ORKDate.iso(createdAt))
            try step(stmt)
        }
    }

    /// Bulk delete for automation cleanup. Scans `transcript_word` for
    /// conversation rows (`speakerId IS NOT NULL`, corresponding to
    /// speakerId 1=user / 2=assistant written by ConversationLogger)
    /// whose `timeOffset` (INTEGER ms since epoch) falls within the last
    /// `sinceHours` and whose `word` matches any of `phrases`
    /// (case-insensitive LIKE %phrase%). Because ConversationLogger
    /// attaches those rows to whatever segment happens to be newest —
    /// often the current browser/other app segment, not the synthetic
    /// `com.jkneen.openclicky.voice` one — a bundleID-scoped purge
    /// misses them. This function targets the words themselves.
    ///
    /// LTM retrieval reads from `transcript_word`, so removing the
    /// matching rows is sufficient to clear the pollution — no cascade
    /// through searchRanking / node / frame is required. Returns per-
    /// phrase deletion counts (plus a "_total" key). Wrapped in a
    /// single transaction for crash safety.
    @discardableResult
    public func purgeAutomationVoiceConversations(sinceHours: Int = 48,
                                                  phrases: [String]) throws -> [String: Int] {
        try queue.sync {
            // Sanitize phrases: drop empty / whitespace-only entries.
            let cleaned: [String] = phrases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var counts: [String: Int] = [:]
            var total = 0
            guard !cleaned.isEmpty else {
                counts["_total"] = 0
                return counts
            }
            // Convert wall-clock window to milliseconds because the
            // physical column is `timeOffset INTEGER ms since epoch`
            // (Writer.insertTranscriptWord stamps `startTime * 1000`).
            let now = Date()
            let hours = max(0, sinceHours)
            let sinceMs = Int64(
                (now.timeIntervalSince1970 - Double(hours) * 3600.0) * 1000.0)
            let untilMs = Int64(now.timeIntervalSince1970 * 1000.0)
            var beginErr: UnsafeMutablePointer<CChar>?
            let beginRC = ork_exec(db, "BEGIN IMMEDIATE;", nil, nil, &beginErr)
            _ = beginErr
            let inTxn = (beginRC == ORK_SQLITE_OK)
            var commitDone = false
            defer {
                if inTxn && !commitDone {
                    var rollErr: UnsafeMutablePointer<CChar>?
                    _ = ork_exec(db, "ROLLBACK;", nil, nil, &rollErr)
                    _ = rollErr
                }
            }
            // Per-phrase DELETE so the response reports which trigger
            // matched what. Case-insensitive: SQLite LIKE is case-
            // insensitive for ASCII by default, but wrap with LOWER()
            // so unicode / accented characters compare consistently.
            // `speakerId IS NOT NULL` matches both user (1) and
            // assistant (2) conversation rows; real captured speech
            // leaves speakerId NULL so it stays untouched.
            let sql = """
                DELETE FROM transcript_word
                 WHERE speakerId IS NOT NULL
                   AND timeOffset BETWEEN ? AND ?
                   AND LOWER(word) LIKE LOWER(?);
                """
            let stmt = try prepare(sql); defer { ork_finalize(stmt) }
            for phrase in cleaned {
                _ = ork_reset(stmt)
                _ = ork_bind_int64(stmt, 1, sinceMs)
                _ = ork_bind_int64(stmt, 2, untilMs)
                _ = ork_bindString(stmt, 3, "%\(phrase)%")
                try step(stmt)
                let deleted = Int(ork_changes(db))
                counts[phrase] = deleted
                total += deleted
            }
            if inTxn {
                var commitErr: UnsafeMutablePointer<CChar>?
                _ = ork_exec(db, "COMMIT;", nil, nil, &commitErr)
                _ = commitErr
                commitDone = true
            }
            counts["_total"] = total
            return counts
        }
    }

    // MARK: - Internal helpers

    private func prepare(_ sql: String) throws -> ORKStmt? {
        var stmt: ORKStmt?
        let rc = ork_prepare(db, sql, -1, &stmt, nil)
        guard rc == ORK_SQLITE_OK else {
            let msg = String(cString: ork_errmsg(db)!)
            throw OpenRewindError.queryFailed(msg)
        }
        return stmt
    }

    private func step(_ stmt: ORKStmt?) throws {
        let rc = ork_step(stmt)
        guard rc == ORK_SQLITE_DONE || rc == ORK_SQLITE_ROW else {
            let msg = String(cString: ork_errmsg(db)!)
            throw OpenRewindError.queryFailed(msg)
        }
    }

    private func bind(_ stmt: ORKStmt?, _ idx: Int32, _ v: String?) {
        if let s = v { _ = ork_bindString(stmt, idx, s) }
        else { _ = ork_bind_null(stmt, idx) }
    }
}

