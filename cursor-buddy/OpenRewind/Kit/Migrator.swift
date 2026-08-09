// Migrator.swift — one-shot cross-vault migration between two Rewind-
// compatible SQLCipher vaults. See docs/ARCHITECTURE.md § "Migration" and
// docs/COMPRESSION.md § "Migration to Rewind" for the design intent.
//
// The engine reads from `plan.source`, writes to `plan.target`. Every insert
// goes through a single target-DB connection wrapped in BEGIN/COMMIT so a
// mid-run failure rolls the target back to its pre-migration state. Chunk
// files on disk are hard-linked when possible (same volume, near-zero cost),
// fall back to copy across volumes, or re-encoded when fidelity demands it.
//
// SQL is duplicated from Writer.swift on purpose: SQLite transactions are
// per-connection, so a Writer that owns its own handle cannot participate
// in a Migrator BEGIN/COMMIT. Keeping the SQL local to this file lets the
// engine hold one connection for the whole migration.

import Foundation

// MARK: - Public types

/// Which vault flows into which. Only `.toRewind` is fully wired for the
/// one-shot migration path today; `.fromRewind` and `.bidirectional` fall
/// through the same execute() body (source/target are already generic).
public enum MigrationDirection: Sendable {
    case toRewind
    case fromRewind
    case bidirectional
}

/// How faithfully pixels are preserved. See docs/COMPRESSION.md#migration-to-rewind.
public enum MigrationFidelity: Sendable {
    /// Hard-link (or copy on EXDEV) the source chunk into the target vault.
    /// Fast, byte-identical, but preserves whatever quality the source was
    /// encoded at.
    case fromChunks
    /// Re-encode from source PNGs in `plan.sourcePNGsDir`, using
    /// `.rewindParity`. Falls back to `.fromChunks` when PNGs are missing.
    case fromPNGs
    /// Live-capture mode: the daemon writes both vaults at chunk finalise.
    /// Not applicable to one-shot migrate — the engine rejects this
    /// fidelity in execute().
    case dualWrite
    /// Prefer `.fromPNGs`; silently fall back to `.fromChunks` per chunk
    /// whose source PNGs are gone.
    case bestEffort
}

/// What to do when a source xid already exists in the target vault.
public enum ConflictPolicy: Sendable {
    /// Leave target alone, log skip, continue.
    case skip
    /// DELETE the target rows (frame → doc_segment → node → searchRanking →
    /// video) before inserting the source rows. Chunk file on disk is
    /// replaced too.
    case overwrite
    /// Insert with a rewritten xid: `<xid>-copyN` where N is the next free
    /// integer starting at 1. Chunk file is written under the new xid path
    /// too.
    case duplicate
    /// Throw on first conflict.
    case error
}

/// A migration plan: two vaults, passphrases, direction/fidelity/conflict,
/// and an optional xid subset. The engine reads everything else from the
/// two databases.
public struct MigrationPlan: Sendable {
    public let source: OpenRewindStorage
    public let target: OpenRewindStorage
    public let sourcePassphrase: String
    public let targetPassphrase: String
    public let direction: MigrationDirection
    public let fidelity: MigrationFidelity
    public let conflictPolicy: ConflictPolicy
    /// If non-nil, only migrate videos whose xid is in this list.
    public let xidFilter: [String]?
    /// Optional root under which source PNGs (per-frame `imageFileName`)
    /// still live. Required for `.fromPNGs`; ignored for `.fromChunks`.
    /// Convention: `<sourcePNGsDir>/<imageFileName>`.
    public let sourcePNGsDir: URL?

    public init(source: OpenRewindStorage,
                target: OpenRewindStorage,
                sourcePassphrase: String,
                targetPassphrase: String,
                direction: MigrationDirection = .toRewind,
                fidelity: MigrationFidelity = .fromChunks,
                conflictPolicy: ConflictPolicy = .skip,
                xidFilter: [String]? = nil,
                sourcePNGsDir: URL? = nil) {
        self.source = source
        self.target = target
        self.sourcePassphrase = sourcePassphrase
        self.targetPassphrase = targetPassphrase
        self.direction = direction
        self.fidelity = fidelity
        self.conflictPolicy = conflictPolicy
        self.xidFilter = xidFilter
        self.sourcePNGsDir = sourcePNGsDir
    }
}

/// Result of `plan()` — a dry-run size + count estimate.
public struct MigrationSummary: Sendable {
    public let toMigrate: Int
    public let alreadyPresent: Int
    public let conflicts: Int
    public let sizeEstimateBytes: Int64

    public init(toMigrate: Int, alreadyPresent: Int,
                conflicts: Int, sizeEstimateBytes: Int64) {
        self.toMigrate = toMigrate
        self.alreadyPresent = alreadyPresent
        self.conflicts = conflicts
        self.sizeEstimateBytes = sizeEstimateBytes
    }
}

/// Progress ping fired from `execute()`.
public struct MigrationProgress: Sendable {
    public let phase: String
    public let completed: Int
    public let total: Int
    public let currentXid: String?

    public init(phase: String, completed: Int,
                total: Int, currentXid: String?) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentXid = currentXid
    }
}

/// Terminal result of `execute()`. `success == failed.isEmpty`.
public struct MigrationResult: Sendable {
    public let started: Date
    public let ended: Date
    public let inserted: Int
    public let skipped: Int
    public let failed: [(xid: String, reason: String)]
    public let hardlinkedChunks: Int
    public let copiedChunks: Int
    public let reEncoded: Int
    /// The xids the engine actually wrote into the target (post-conflict
    /// resolution — includes `-copyN` names for `.duplicate`). `rollback()`
    /// walks this list.
    public let insertedXids: [String]

    public var success: Bool { failed.isEmpty }

    public init(started: Date, ended: Date, inserted: Int, skipped: Int,
                failed: [(xid: String, reason: String)],
                hardlinkedChunks: Int, copiedChunks: Int, reEncoded: Int,
                insertedXids: [String]) {
        self.started = started
        self.ended = ended
        self.inserted = inserted
        self.skipped = skipped
        self.failed = failed
        self.hardlinkedChunks = hardlinkedChunks
        self.copiedChunks = copiedChunks
        self.reEncoded = reEncoded
        self.insertedXids = insertedXids
    }
}

/// Result of `verify()`.
public struct VerificationReport: Sendable {
    public let checkedRows: Int
    public let mismatches: [(xid: String, reason: String)]
    public var passed: Bool { mismatches.isEmpty }

    public init(checkedRows: Int,
                mismatches: [(xid: String, reason: String)]) {
        self.checkedRows = checkedRows
        self.mismatches = mismatches
    }
}

/// Errors surfaced by MigrationEngine. Wraps `OpenRewindError` for lower
/// layers; adds a couple of migration-specific cases.
public enum MigrationError: Error, CustomStringConvertible, Sendable {
    case conflict(xid: String)
    case notSupported(String)
    case sourceOpenFailed(String)
    case targetOpenFailed(String)
    case chunkMissing(xid: String, path: String)
    case sqlError(String)

    public var description: String {
        switch self {
        case .conflict(let x):        return "conflict on xid \(x)"
        case .notSupported(let s):    return "not supported: \(s)"
        case .sourceOpenFailed(let s): return "source open failed: \(s)"
        case .targetOpenFailed(let s): return "target open failed: \(s)"
        case .chunkMissing(let x, let p): return "chunk missing xid=\(x) path=\(p)"
        case .sqlError(let s):        return "sql error: \(s)"
        }
    }
}

// MARK: - Engine

/// One-shot migration engine. Actor because SQLite writes are single-writer
/// and progress callbacks must serialize behind the target transaction.
public actor MigrationEngine {

    private let source: OpenRewindStorage
    private let target: OpenRewindStorage

    public init(source: OpenRewindStorage, target: OpenRewindStorage) {
        self.source = source
        self.target = target
    }

    // MARK: plan()

    /// Diff source xids against target, group by conflict policy, estimate
    /// bytes on disk. No writes.
    public func plan(_ plan: MigrationPlan) async throws -> MigrationSummary {
        let sourceReader = try openSourceReader(plan)
        let sourceVideos = try sourceReader.videos(limit: 1_000_000)
        let filtered = filterVideos(sourceVideos, plan: plan)

        var targetHandle: ORKSQLite3?
        try openDB(path: plan.target.dbEncrypted.path,
                   passphrase: plan.targetPassphrase,
                   readonly: true,
                   into: &targetHandle,
                   errKind: .target)
        defer { if let h = targetHandle { ork_close_v2(h) } }
        let targetXids = try selectXids(db: targetHandle)

        var toMigrate = 0
        var alreadyPresent = 0
        var conflicts = 0
        var estBytes: Int64 = 0
        for v in filtered {
            if targetXids.contains(v.xid) {
                alreadyPresent += 1
                switch plan.conflictPolicy {
                case .skip:                 break
                case .overwrite, .duplicate:
                    conflicts += 1
                    toMigrate += 1
                    estBytes += v.fileSize
                case .error:
                    // FIX(review-2026-07-28) M-4: `.error` conflicts do not
                    // become work — they abort the whole batch. Do not
                    // count them into toMigrate.
                    conflicts += 1
                }
            } else {
                toMigrate += 1
                estBytes += v.fileSize
            }
        }
        return MigrationSummary(toMigrate: toMigrate,
                                alreadyPresent: alreadyPresent,
                                conflicts: conflicts,
                                sizeEstimateBytes: estBytes)
    }

    // MARK: execute()

    /// Wrap the whole migration in a single target-DB transaction. Chunk
    /// file ops happen alongside DB inserts; on any error the DB rolls back
    /// and best-effort chunk cleanup runs.
    public func execute(_ plan: MigrationPlan,
                        progress: @Sendable @escaping (MigrationProgress) -> Void)
                        async throws -> MigrationResult {
        if case .dualWrite = plan.fidelity {
            throw MigrationError.notSupported(
                "dualWrite is a live-capture mode; use `.fromChunks` for one-shot")
        }

        let started = Date()
        var inserted = 0
        var skipped = 0
        var failed: [(xid: String, reason: String)] = []
        var hardlinked = 0
        var copied = 0
        var reEncoded = 0
        var insertedXids: [String] = []
        var writtenChunkFiles: [URL] = []  // for rollback of partial disk state

        let sourceReader = try openSourceReader(plan)
        let sourceVideos = filterVideos(
            try sourceReader.videos(limit: 1_000_000), plan: plan)

        var target: ORKSQLite3?
        try openDB(path: plan.target.dbEncrypted.path,
                   passphrase: plan.targetPassphrase,
                   readonly: false,
                   into: &target,
                   errKind: .target)
        guard let db = target else {
            throw MigrationError.targetOpenFailed("nil handle after open")
        }
        defer { ork_close_v2(db) }

        try exec(db, "BEGIN IMMEDIATE;")
        var committed = false
        defer {
            if !committed {
                _ = try? exec(db, "ROLLBACK;")
                // Also unlink chunk files we may have laid down before failing.
                for url in writtenChunkFiles {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let total = sourceVideos.count
        // FIX(review-2026-07-28) M-4 (kit CRITICAL "migrator drops segment"):
        // segment.id is AUTOINCREMENT on both sides, so source ids will
        // collide with unrelated target rows. Build a per-run remap:
        // source segmentId -> destination segmentId (created lazily via
        // insertSegment on target the first time we see it).
        var segmentIdMap: [Int64: Int64] = [:]
        var seenSegments: Set<Int64> = []
        for (idx, v) in sourceVideos.enumerated() {
            progress(MigrationProgress(phase: "migrating",
                                       completed: idx,
                                       total: total,
                                       currentXid: v.xid))
            // FIX(review-2026-07-28) M-3: track this video's placed chunk
            // file so an inner failure can unlink it before continuing.
            var perVideoChunkURL: URL? = nil

            do {
                let existing = try selectXid(db: db, xid: v.xid)
                var effectiveXid = v.xid
                if existing != nil {
                    switch plan.conflictPolicy {
                    case .skip:
                        skipped += 1
                        continue
                    case .error:
                        throw MigrationError.conflict(xid: v.xid)
                    case .overwrite:
                        try deleteVideoTree(db: db, videoId: existing!)
                        try? removeChunkFile(plan: plan, videoPath: v.path)
                    case .duplicate:
                        effectiveXid = try nextDuplicateXid(db: db, base: v.xid)
                    }
                }

                // Copy or re-encode the chunk file, then insert DB rows.
                let (movedURL, mode) = try placeChunkFile(
                    plan: plan,
                    sourceVideo: v,
                    effectiveXid: effectiveXid)
                writtenChunkFiles.append(movedURL)
                perVideoChunkURL = movedURL
                switch mode {
                case .hardlinked: hardlinked += 1
                case .copied:     copied += 1
                case .reencoded:  reEncoded += 1
                }

                // Insert video row (using the effective path stored under
                // effectiveXid; keep the same relative structure as source).
                let newVideoId = try insertVideo(
                    db: db,
                    width: v.width,
                    height: v.height,
                    path: relPathForEffectiveXid(sourcePath: v.path,
                                                 sourceXid: v.xid,
                                                 effectiveXid: effectiveXid),
                    captureType: v.captureType,
                    fileSize: fileSize(at: movedURL) ?? v.fileSize,
                    frameRate: v.frameRate,
                    local: v.local,
                    xid: effectiveXid,
                    processingState: v.processingState)

                // Frames.
                let sourceFrames = try selectSourceFrames(
                    reader: sourceReader, videoId: v.id)
                // FIX(review-2026-07-28) M-4: per-source-frame remap.
                // Also collects frameIdMap so frame_processing / node inserts
                // can be re-keyed off destination ids.
                var frameIdMap: [Int64: Int64] = [:]
                for f in sourceFrames {
                    // Remap segment id via segmentIdMap (create on first
                    // reference).
                    let dstSegId = try mapSegmentId(
                        srcId: f.segmentId,
                        reader: sourceReader,
                        db: db,
                        map: &segmentIdMap,
                        seen: &seenSegments)
                    // Rule 3 of docs/COMPATIBILITY.md — a chunk-finalized
                    // frame MUST land with encodingStatus='success', or Rewind's
                    // reconcileInconsistentFrameStatuses will delete it on next
                    // start when the source PNG in temp/ is absent. Migrator
                    // only carries chunks, never PNGs, so force success here.
                    let newFrameId = try insertFrame(
                        db: db,
                        createdAt: f.createdAt,
                        imageFileName: f.imageFileName,
                        segmentId: dstSegId,
                        videoId: newVideoId,
                        videoFrameIndex: f.videoFrameIndex,
                        isStarred: f.isStarred,
                        encodingStatus: "success")
                    frameIdMap[f.id] = newFrameId

                    // searchRanking + doc_segment + node.
                    if let fts = try selectFTSRow(
                        reader: sourceReader, frameId: f.id) {
                        let nodes = try selectNodes(
                            reader: sourceReader, frameId: f.id)
                        try insertSearchRankingBundle(
                            db: db,
                            frameId: newFrameId,
                            segmentId: dstSegId,
                            text: fts.c0,
                            otherText: fts.c1,
                            title: fts.c2,
                            nodes: nodes)
                    }
                }

                // FIX(review-2026-07-28) M-4 (kit CRITICAL "drops audio,
                // transcript_word, frame_processing"): migrate the auxiliary
                // rows that reference remapped segment/frame ids.
                try migrateAuxRowsForVideo(
                    db: db,
                    reader: sourceReader,
                    videoId: v.id,
                    segmentIdMap: segmentIdMap,
                    frameIdMap: frameIdMap)

                inserted += 1
                insertedXids.append(effectiveXid)
                perVideoChunkURL = nil  // success — do not unlink
            } catch let e as MigrationError {
                // .error conflict policy MUST abort the whole batch —
                // if we caught it here, the tx would COMMIT with a partial
                // migration and the caller would get silent partial success.
                // Re-throw so the outer `catch` rolls the transaction back.
                if case .conflict = e, plan.conflictPolicy == .error {
                    throw e
                }
                // FIX(review-2026-07-28) M-3: unlink any chunk file we
                // placed for this xid before continuing, so a per-video
                // failure never leaves an orphan file in the target vault.
                if let orphan = perVideoChunkURL {
                    try? FileManager.default.removeItem(at: orphan)
                    if let i = writtenChunkFiles.firstIndex(of: orphan) {
                        writtenChunkFiles.remove(at: i)
                    }
                }
                failed.append((xid: v.xid, reason: "\(e)"))
            } catch {
                if let orphan = perVideoChunkURL {
                    try? FileManager.default.removeItem(at: orphan)
                    if let i = writtenChunkFiles.firstIndex(of: orphan) {
                        writtenChunkFiles.remove(at: i)
                    }
                }
                failed.append((xid: v.xid, reason: "\(error)"))
                // Continue with next video; do not tear down the whole tx —
                // partial success is still valuable, and the caller can
                // rollback if they want everything unwound.
            }
        }

        try exec(db, "COMMIT;")
        committed = true

        progress(MigrationProgress(phase: "done",
                                   completed: total,
                                   total: total,
                                   currentXid: nil))

        return MigrationResult(
            started: started,
            ended: Date(),
            inserted: inserted,
            skipped: skipped,
            failed: failed,
            hardlinkedChunks: hardlinked,
            copiedChunks: copied,
            reEncoded: reEncoded,
            insertedXids: insertedXids)
    }

    // MARK: verify()

    /// Post-migration sanity: for every xid in `plan` (or its filter) that
    /// exists on both sides, check frame count match, FTS c0 match, and
    /// chunk file existence. hvcC atom is compared when target and source
    /// files are separate; skipped when hard-linked (same inode).
    public func verify(_ plan: MigrationPlan) async throws -> VerificationReport {
        var mismatches: [(xid: String, reason: String)] = []
        var checked = 0

        let sourceReader = try openSourceReader(plan)
        let sourceVideos = filterVideos(
            try sourceReader.videos(limit: 1_000_000), plan: plan)

        var target: ORKSQLite3?
        try openDB(path: plan.target.dbEncrypted.path,
                   passphrase: plan.targetPassphrase,
                   readonly: true,
                   into: &target,
                   errKind: .target)
        defer { if let h = target { ork_close_v2(h) } }

        for v in sourceVideos {
            guard let targetVideoId = try selectXid(db: target, xid: v.xid) else {
                continue  // not migrated; not verify()'s job to flag missing
            }
            checked += 1

            // 1. frame count parity.
            let srcCount = try countFramesForVideo(reader: sourceReader,
                                                   videoId: v.id)
            let tgtCount = try countFramesForVideoDB(db: target,
                                                     videoId: targetVideoId)
            if srcCount != tgtCount {
                mismatches.append((v.xid,
                    "frame count \(srcCount) → \(tgtCount)"))
            }

            // 2. FTS c0 parity per frame.
            let srcTexts = try ftsTextsForVideo(reader: sourceReader,
                                                videoId: v.id)
            let tgtTexts = try ftsTextsForVideoDB(db: target,
                                                  videoId: targetVideoId)
            if srcTexts != tgtTexts {
                mismatches.append((v.xid, "searchRanking.c0 differs"))
            }

            // 3. chunk file existence + hvcC parity.
            let srcChunk = plan.source.chunksDir.appendingPathComponent(v.path)
            let tgtChunk = plan.target.chunksDir.appendingPathComponent(v.path)
            let fm = FileManager.default
            if !fm.fileExists(atPath: tgtChunk.path) {
                mismatches.append((v.xid, "target chunk missing"))
            } else if !sameInode(srcChunk, tgtChunk) {
                // Compare hvcC atoms.
                if let a = try? extractHvcC(from: srcChunk),
                   let b = try? extractHvcC(from: tgtChunk) {
                    // FIX(review-2026-07-28) M-2: also flag hvc1<->hev1
                    // codec-tag mismatch even when hvcC payload is bit-
                    // identical.
                    if a.payload != b.payload {
                        mismatches.append((v.xid, "hvcC mismatch"))
                    } else if a.fourCC != b.fourCC {
                        mismatches.append((v.xid,
                            "codec tag mismatch \(a.fourCC) -> \(b.fourCC)"))
                    }
                }
                // else: hvcC unreadable on one side; leave silent (not
                // strictly a verify failure — treated as a soft warning).
            }
        }
        return VerificationReport(checkedRows: checked,
                                  mismatches: mismatches)
    }

    // MARK: rollback()

    /// Best-effort undo: DELETE any target rows whose xid was written by
    /// `execute()`. Reverse-dependency order: frame → doc_segment → node →
    /// searchRanking → video. Chunk files are left in place (recovery
    /// tooling and user judgement decide whether to unlink).
    public func rollback(from result: MigrationResult) async throws {
        guard result.inserted > 0 else { return }
        // MigrationResult doesn't carry the passphrase (it's not Sendable-
        // safe to stash secrets there). Callers must use the passphrase
        // overload; this signature exists to satisfy the stated API.
        throw MigrationError.notSupported(
            "rollback requires the target passphrase; use rollback(from:passphrase:)")
    }

    /// Rollback variant that takes the passphrase explicitly.
    public func rollback(from result: MigrationResult,
                         passphrase: String) async throws {
        guard result.inserted > 0 else { return }
        var target: ORKSQLite3?
        try openDB(path: self.target.dbEncrypted.path,
                   passphrase: passphrase,
                   readonly: false,
                   into: &target,
                   errKind: .target)
        guard let db = target else {
            throw MigrationError.targetOpenFailed("nil handle after open")
        }
        defer { ork_close_v2(db) }

        try exec(db, "BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { _ = try? exec(db, "ROLLBACK;") } }

        for xid in result.insertedXids {
            guard let videoId = try selectXid(db: db, xid: xid) else { continue }
            // FIX(review-2026-07-28) M-L: rollback asymmetry — `.duplicate`
            // policy wrote a fresh chunk file under the `-copyN` xid that
            // isn't shared with any source. execute()'s failure path
            // already unlinks orphan files, but rollback() (called after
            // a successful COMMIT) also owns cleanup of every insertedXid.
            // Best-effort remove the chunk before deleting DB rows; ignore
            // errors so a missing file doesn't block the rollback.
            if let path = try selectVideoPath(db: db, videoId: videoId) {
                let chunk = self.target.chunksDir.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: chunk)
            }
            try deleteVideoTree(db: db, videoId: videoId)
        }
        try exec(db, "COMMIT;")
        committed = true
    }
}

// MARK: - Helpers

private enum OpenErrKind { case source, target }

private enum ChunkPlaceMode { case hardlinked, copied, reencoded }

private struct SourceFrameRow {
    let id: Int64
    let createdAt: Date
    let imageFileName: String
    let segmentId: Int64
    let videoFrameIndex: Int?
    let isStarred: Bool
    let encodingStatus: String
}

private struct FTSTriple {
    let c0: String
    let c1: String?
    let c2: String?
}

private struct NodeRow {
    let nodeOrder: Int
    let textOffset: Int
    let textLength: Int
    let leftX: Double
    let topY: Double
    let width: Double
    let height: Double
    let windowIndex: Int?
}

extension MigrationEngine {

    // ---- open helpers ------------------------------------------------------

    fileprivate func openSourceReader(_ plan: MigrationPlan) throws
        -> OpenRewindReader {
        do {
            return try OpenRewindReader(storage: plan.source,
                                        passphrase: plan.sourcePassphrase,
                                        cacheLimit: 4)
        } catch {
            throw MigrationError.sourceOpenFailed("\(error)")
        }
    }

    fileprivate func openDB(path: String,
                            passphrase: String,
                            readonly: Bool,
                            into handle: inout ORKSQLite3?,
                            errKind: OpenErrKind) throws {
        let flags: Int32 = readonly
            ? ORK_SQLITE_OPEN_READWRITE | ORK_SQLITE_OPEN_NOMUTEX
            : ORK_SQLITE_OPEN_READWRITE | ORK_SQLITE_OPEN_NOMUTEX
        // NB: We open read-write in both branches so SQLCipher can honour
        // the key; a "readonly" reader would still get a rejection on the
        // sanity-check pragma. Callers only run SELECT in the readonly path.
        let rc = ork_open_v2(path, &handle, flags, nil)
        guard rc == ORK_SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: ork_errmsg($0)!) }
                ?? "open error rc=\(rc)"
            switch errKind {
            case .source: throw MigrationError.sourceOpenFailed(msg)
            case .target: throw MigrationError.targetOpenFailed(msg)
            }
        }
        let keyRC = passphrase.withCString { p in
            ork_key_v2(handle, "main", p, Int32(strlen(p)))
        }
        guard keyRC == ORK_SQLITE_OK else {
            ork_close_v2(handle); handle = nil
            switch errKind {
            case .source: throw MigrationError.sourceOpenFailed("key rc=\(keyRC)")
            case .target: throw MigrationError.targetOpenFailed("key rc=\(keyRC)")
            }
        }
        let stmt = try prepareStmt(handle, "SELECT count(*) FROM sqlite_master;")
        defer { ork_finalize(stmt) }
        guard ork_step(stmt) == ORK_SQLITE_ROW else {
            ork_close_v2(handle); handle = nil
            switch errKind {
            case .source: throw MigrationError.sourceOpenFailed("key rejected")
            case .target: throw MigrationError.targetOpenFailed("key rejected")
            }
        }
    }

    fileprivate func filterVideos(_ videos: [OpenRewindVideo],
                                  plan: MigrationPlan) -> [OpenRewindVideo] {
        guard let filter = plan.xidFilter else { return videos }
        let set = Set(filter)
        return videos.filter { set.contains($0.xid) }
    }

    // ---- SQL helpers -------------------------------------------------------

    fileprivate func exec(_ db: ORKSQLite3?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sql.withCString {
            ork_exec(db, $0, nil, nil, &err)
        }
        if rc != ORK_SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sql rc=\(rc)"
            throw MigrationError.sqlError(msg)
        }
    }

    fileprivate func prepareStmt(_ db: ORKSQLite3?, _ sql: String) throws
        -> ORKStmt? {
        var stmt: ORKStmt?
        let rc = ork_prepare(db, sql, -1, &stmt, nil)
        guard rc == ORK_SQLITE_OK else {
            let msg = String(cString: ork_errmsg(db)!)
            throw MigrationError.sqlError(msg)
        }
        return stmt
    }

    fileprivate func step(_ stmt: ORKStmt?, on db: ORKSQLite3?) throws {
        let rc = ork_step(stmt)
        guard rc == ORK_SQLITE_DONE || rc == ORK_SQLITE_ROW else {
            let msg = String(cString: ork_errmsg(db)!)
            throw MigrationError.sqlError(msg)
        }
    }

    fileprivate func bindOptString(_ stmt: ORKStmt?, _ idx: Int32,
                                   _ v: String?) {
        if let s = v { _ = ork_bindString(stmt, idx, s) }
        else { _ = ork_bind_null(stmt, idx) }
    }

    // ---- segment migration (FIX review-2026-07-28 M-4 kit CRITICAL) ---

    /// Ensure `srcId` has a destination counterpart. Reads the source
    /// segment row (via Reader.rawQuery), INSERTs it on the target the
    /// first time it's referenced, and records the mapping.
    fileprivate func mapSegmentId(srcId: Int64,
                                  reader: OpenRewindReader,
                                  db: ORKSQLite3?,
                                  map: inout [Int64: Int64],
                                  seen: inout Set<Int64>) throws -> Int64 {
        if let mapped = map[srcId] { return mapped }
        if seen.contains(srcId) {
            // Should not happen — belt-and-suspenders.
            return srcId
        }
        seen.insert(srcId)
        // Fetch source row.
        let (_, rows) = try reader.rawQuery("""
            SELECT bundleID, startDate, endDate, windowName,
                   browserUrl, browserProfile, type
            FROM segment WHERE id = ? LIMIT 1;
            """, [String(srcId)])
        guard let r = rows.first, r.count >= 7 else {
            // Source has no matching segment (orphan frame) — leave the id
            // as-is and let the FK dangle. Log via map so we don't reinsert.
            map[srcId] = srcId
            return srcId
        }
        let bundleID  = r[0]
        let startISO  = r[1] ?? ORKDate.iso(Date())
        let endISO    = r[2] ?? startISO
        let windowNm  = r[3]
        let browserUR = r[4]
        let browserPR = r[5]
        let ty        = Int(r[6] ?? "0") ?? 0

        // INSERT INTO segment on target — mirror Writer.insertSegment.
        let sql = """
            INSERT INTO segment
                (bundleID, startDate, endDate, windowName,
                 browserUrl, browserProfile, type)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        let stmt = try prepareStmt(db, sql); defer { ork_finalize(stmt) }
        bindOptString(stmt, 1, bundleID)
        _ = ork_bindString(stmt, 2, startISO)
        _ = ork_bindString(stmt, 3, endISO)
        bindOptString(stmt, 4, windowNm)
        bindOptString(stmt, 5, browserUR)
        bindOptString(stmt, 6, browserPR)
        _ = ork_bind_int64(stmt, 7, Int64(ty))
        try step(stmt, on: db)
        let dstId = ork_last_insert_rowid(db)
        map[srcId] = dstId
        return dstId
    }

    // ---- aux row migration (audio / transcript_word / frame_processing)
    // FIX(review-2026-07-28) M-4 (kit CRITICAL).
    fileprivate func migrateAuxRowsForVideo(db: ORKSQLite3?,
                                            reader: OpenRewindReader,
                                            videoId: Int64,
                                            segmentIdMap: [Int64: Int64],
                                            frameIdMap: [Int64: Int64]) throws {
        // Collect unique source segments referenced by this video's frames.
        let (_, segRows) = try reader.rawQuery("""
            SELECT DISTINCT segmentId FROM frame WHERE videoId = ?;
            """, [String(videoId)])
        let srcSegments: [Int64] = segRows.compactMap {
            $0.first.flatMap { $0 }.flatMap(Int64.init)
        }
        for srcSeg in srcSegments {
            guard let dstSeg = segmentIdMap[srcSeg] else { continue }
            // audio rows for this segment.
            let (_, audioRows) = try reader.rawQuery("""
                SELECT path, startTime, duration
                FROM audio WHERE segmentId = ?;
                """, [String(srcSeg)])
            for a in audioRows where a.count >= 3 {
                guard let path = a[0], let ts = a[1],
                      let durS = a[2], let dur = Double(durS) else { continue }
                let sql = """
                    INSERT INTO audio (segmentId, path, startTime, duration)
                    VALUES (?, ?, ?, ?);
                    """
                let s = try prepareStmt(db, sql); defer { ork_finalize(s) }
                _ = ork_bind_int64(s, 1, dstSeg)
                _ = ork_bindString(s, 2, path)
                _ = ork_bindString(s, 3, ts)
                _ = ork_bind_double(s, 4, dur)
                try step(s, on: db)
            }

            // transcript_word rows for this segment.
            let (_, twRows) = try reader.rawQuery("""
                SELECT word, startTime, endTime, fullTextOffset
                FROM transcript_word WHERE segmentId = ?
                ORDER BY startTime;
                """, [String(srcSeg)])
            for w in twRows where w.count >= 4 {
                guard let word = w[0],
                      let stS = w[1], let st = Double(stS),
                      let etS = w[2], let et = Double(etS) else { continue }
                let ftoStr = w[3]
                let sql = """
                    INSERT INTO transcript_word
                        (segmentId, word, startTime, endTime, fullTextOffset)
                    VALUES (?, ?, ?, ?, ?);
                    """
                let s = try prepareStmt(db, sql); defer { ork_finalize(s) }
                _ = ork_bind_int64(s, 1, dstSeg)
                _ = ork_bindString(s, 2, word)
                _ = ork_bind_double(s, 3, st)
                _ = ork_bind_double(s, 4, et)
                if let ftoStr = ftoStr, let fto = Int64(ftoStr) {
                    _ = ork_bind_int64(s, 5, fto)
                } else {
                    _ = ork_bind_null(s, 5)
                }
                try step(s, on: db)
            }
        }

        // frame_processing rows keyed off source frame ids.
        for (srcFrameId, dstFrameId) in frameIdMap {
            let (_, fpRows) = try reader.rawQuery("""
                SELECT processingType, createdAt
                FROM frame_processing WHERE id = ?;
                """, [String(srcFrameId)])
            for r in fpRows where r.count >= 2 {
                guard let ptype = r[0], let ca = r[1] else { continue }
                let sql = """
                    INSERT OR IGNORE INTO frame_processing
                        (id, processingType, createdAt)
                    VALUES (?, ?, ?);
                    """
                let s = try prepareStmt(db, sql); defer { ork_finalize(s) }
                _ = ork_bind_int64(s, 1, dstFrameId)
                _ = ork_bindString(s, 2, ptype)
                _ = ork_bindString(s, 3, ca)
                try step(s, on: db)
            }
        }
    }

    // ---- xid queries -------------------------------------------------------

    fileprivate func selectXids(db: ORKSQLite3?) throws -> Set<String> {
        let stmt = try prepareStmt(db, "SELECT xid FROM video;")
        defer { ork_finalize(stmt) }
        var out = Set<String>()
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let s = ork_readString(stmt, 0) { out.insert(s) }
        }
        return out
    }

    fileprivate func selectXid(db: ORKSQLite3?, xid: String) throws -> Int64? {
        let stmt = try prepareStmt(db, "SELECT id FROM video WHERE xid = ? LIMIT 1;")
        defer { ork_finalize(stmt) }
        _ = ork_bindString(stmt, 1, xid)
        if ork_step(stmt) == ORK_SQLITE_ROW {
            return ork_col_int64(stmt, 0)
        }
        return nil
    }

    // FIX(review-2026-07-28) M-L: read the video's on-disk relative path
    // so rollback can unlink the chunk file we wrote.
    fileprivate func selectVideoPath(db: ORKSQLite3?, videoId: Int64) throws
        -> String? {
        let stmt = try prepareStmt(db, "SELECT path FROM video WHERE id = ? LIMIT 1;")
        defer { ork_finalize(stmt) }
        _ = ork_bind_int64(stmt, 1, videoId)
        if ork_step(stmt) == ORK_SQLITE_ROW {
            return ork_readString(stmt, 0)
        }
        return nil
    }

    fileprivate func nextDuplicateXid(db: ORKSQLite3?, base: String) throws
        -> String {
        var n = 1
        while true {
            let candidate = "\(base)-copy\(n)"
            // FIX(review-2026-07-28) M-1: also check disk uniqueness of the
            // derived path so a pre-existing orphan file from a prior failed
            // migration is not silently overwritten.
            if try selectXid(db: db, xid: candidate) == nil {
                // Path derivation mirrors relPathForEffectiveXid's
                // deterministic YYYYMM/DD/<xid> branch. We can only prove
                // disk-freeness when we can rebuild the path — which is the
                // common case (base36 ms xid).
                if let ts = timestampFromXid(candidate) {
                    let fmt = DateFormatter()
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    fmt.timeZone = TimeZone(identifier: "UTC")
                    fmt.dateFormat = "yyyyMM/dd"
                    let rel = "\(fmt.string(from: ts))/\(candidate)"
                    let onDiskAlready = FileManager.default.fileExists(
                        atPath: (self.target.chunksDir
                            .appendingPathComponent(rel)).path)
                    if !onDiskAlready { return candidate }
                } else {
                    return candidate
                }
            }
            n += 1
        }
    }

    // ---- source-side selects (via Reader.rawQuery) -------------------------

    fileprivate func selectSourceFrames(reader: OpenRewindReader,
                                        videoId: Int64) throws
        -> [SourceFrameRow] {
        let (_, rows) = try reader.rawQuery("""
            SELECT id, createdAt, imageFileName, segmentId,
                   videoFrameIndex, isStarred, encodingStatus
            FROM frame WHERE videoId = ?
            ORDER BY videoFrameIndex, id;
            """, [String(videoId)])
        return rows.compactMap { r -> SourceFrameRow? in
            guard r.count >= 7,
                  let idStr = r[0], let id = Int64(idStr),
                  let created = r[1].flatMap(ORKDate.parse),
                  let ifn = r[2],
                  let segStr = r[3], let seg = Int64(segStr) else { return nil }
            let vfi: Int? = r[4].flatMap(Int.init)
            let starred = (r[5].flatMap(Int.init) ?? 0) != 0
            let enc = r[6] ?? "success"
            return SourceFrameRow(id: id,
                                  createdAt: created,
                                  imageFileName: ifn,
                                  segmentId: seg,
                                  videoFrameIndex: vfi,
                                  isStarred: starred,
                                  encodingStatus: enc)
        }
    }

    fileprivate func selectFTSRow(reader: OpenRewindReader,
                                  frameId: Int64) throws -> FTSTriple? {
        // FIX(review-2026-07-28) K-M-2: query the FTS5 vtable's public
        // columns (`text`, `otherText`, `title`) instead of the private
        // `searchRanking_content` shadow.
        let (_, rows) = try reader.rawQuery("""
            SELECT sr.text, sr.otherText, sr.title
            FROM doc_segment ds
            JOIN searchRanking sr ON sr.rowid = ds.docid
            WHERE ds.frameId = ? LIMIT 1;
            """, [String(frameId)])
        guard let r = rows.first, r.count >= 3, let c0 = r[0] else { return nil }
        return FTSTriple(c0: c0, c1: r[1], c2: r[2])
    }

    fileprivate func selectNodes(reader: OpenRewindReader,
                                 frameId: Int64) throws -> [NodeRow] {
        let (_, rows) = try reader.rawQuery("""
            SELECT nodeOrder, textOffset, textLength,
                   leftX, topY, width, height, windowIndex
            FROM node WHERE frameId = ? ORDER BY nodeOrder;
            """, [String(frameId)])
        return rows.compactMap { r -> NodeRow? in
            guard r.count >= 8,
                  let ord = r[0].flatMap(Int.init),
                  let off = r[1].flatMap(Int.init),
                  let len = r[2].flatMap(Int.init),
                  let lx = r[3].flatMap(Double.init),
                  let ty = r[4].flatMap(Double.init),
                  let w = r[5].flatMap(Double.init),
                  let h = r[6].flatMap(Double.init) else { return nil }
            let wi: Int? = r[7].flatMap(Int.init)
            return NodeRow(nodeOrder: ord, textOffset: off, textLength: len,
                           leftX: lx, topY: ty, width: w, height: h,
                           windowIndex: wi)
        }
    }

    fileprivate func countFramesForVideo(reader: OpenRewindReader,
                                         videoId: Int64) throws -> Int {
        let (_, rows) = try reader.rawQuery(
            "SELECT count(*) FROM frame WHERE videoId = ?;",
            [String(videoId)])
        return rows.first?.first?.flatMap(Int.init) ?? 0
    }

    fileprivate func ftsTextsForVideo(reader: OpenRewindReader,
                                      videoId: Int64) throws -> [String] {
        // FIX(review-2026-07-28) K-M-2: query the FTS5 vtable.
        let (_, rows) = try reader.rawQuery("""
            SELECT sr.text FROM frame f
            JOIN doc_segment ds ON ds.frameId = f.id
            JOIN searchRanking sr ON sr.rowid = ds.docid
            WHERE f.videoId = ? ORDER BY f.videoFrameIndex, f.id;
            """, [String(videoId)])
        return rows.map { $0.first.flatMap { $0 } ?? "" }
    }

    // ---- target-side selects (raw handle) ----------------------------------

    fileprivate func countFramesForVideoDB(db: ORKSQLite3?,
                                           videoId: Int64) throws -> Int {
        let stmt = try prepareStmt(db, "SELECT count(*) FROM frame WHERE videoId = ?;")
        defer { ork_finalize(stmt) }
        _ = ork_bind_int64(stmt, 1, videoId)
        if ork_step(stmt) == ORK_SQLITE_ROW {
            return Int(ork_col_int(stmt, 0))
        }
        return 0
    }

    fileprivate func ftsTextsForVideoDB(db: ORKSQLite3?,
                                        videoId: Int64) throws -> [String] {
        // FIX(review-2026-07-28) K-M-2: query the FTS5 vtable.
        let stmt = try prepareStmt(db, """
            SELECT sr.text FROM frame f
            JOIN doc_segment ds ON ds.frameId = f.id
            JOIN searchRanking sr ON sr.rowid = ds.docid
            WHERE f.videoId = ? ORDER BY f.videoFrameIndex, f.id;
            """)
        defer { ork_finalize(stmt) }
        _ = ork_bind_int64(stmt, 1, videoId)
        var out: [String] = []
        while ork_step(stmt) == ORK_SQLITE_ROW {
            out.append(ork_readString(stmt, 0) ?? "")
        }
        return out
    }

    // ---- target-side inserts (mirror Writer.swift SQL) ---------------------

    fileprivate func insertVideo(db: ORKSQLite3?,
                                 width: Int, height: Int, path: String,
                                 captureType: String?, fileSize: Int64,
                                 frameRate: Double, local: Bool, xid: String,
                                 processingState: Int) throws -> Int64 {
        let sql = """
            INSERT INTO video
                (height, width, path, captureType, fileSize,
                 frameRate, "local", xid, processingState)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let stmt = try prepareStmt(db, sql); defer { ork_finalize(stmt) }
        _ = ork_bind_int64(stmt, 1, Int64(height))
        _ = ork_bind_int64(stmt, 2, Int64(width))
        _ = ork_bindString(stmt, 3, path)
        bindOptString(stmt, 4, captureType)
        _ = ork_bind_int64(stmt, 5, fileSize)
        _ = ork_bind_double(stmt, 6, frameRate)
        _ = ork_bind_int64(stmt, 7, local ? 1 : 0)
        _ = ork_bindString(stmt, 8, xid)
        _ = ork_bind_int64(stmt, 9, Int64(processingState))
        try step(stmt, on: db)
        return ork_last_insert_rowid(db)
    }

    fileprivate func insertFrame(db: ORKSQLite3?,
                                 createdAt: Date, imageFileName: String,
                                 segmentId: Int64, videoId: Int64,
                                 videoFrameIndex: Int?, isStarred: Bool,
                                 encodingStatus: String) throws -> Int64 {
        let sql = """
            INSERT INTO frame
                (createdAt, imageFileName, segmentId, videoId,
                 videoFrameIndex, isStarred, encodingStatus)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        let stmt = try prepareStmt(db, sql); defer { ork_finalize(stmt) }
        _ = ork_bindString(stmt, 1, ORKDate.iso(createdAt))
        _ = ork_bindString(stmt, 2, imageFileName)
        _ = ork_bind_int64(stmt, 3, segmentId)
        _ = ork_bind_int64(stmt, 4, videoId)
        if let idx = videoFrameIndex {
            _ = ork_bind_int64(stmt, 5, Int64(idx))
        } else {
            _ = ork_bind_null(stmt, 5)
        }
        _ = ork_bind_int64(stmt, 6, isStarred ? 1 : 0)
        _ = ork_bindString(stmt, 7, encodingStatus)
        try step(stmt, on: db)
        return ork_last_insert_rowid(db)
    }

    fileprivate func insertSearchRankingBundle(
        db: ORKSQLite3?, frameId: Int64, segmentId: Int64,
        text: String, otherText: String?, title: String?,
        nodes: [NodeRow]) throws {

        // FIX(migrator-cjk-2026-07-30): Writer.insertSearchRanking
        // augments `otherText` with CJK bigrams so porter-tokenised
        // FTS5 can still match Chinese/Japanese queries. Migrator
        // was writing raw `otherText` from the source vault → any
        // rebuild pass would lose CJK recall introduced by the
        // Reader-side bigram query expansion. Apply the same
        // augmentation here.
        let originalBig = OpenRewindWriter.cjkBigrams(text)
        let augmentedOther: String? = {
            let base = otherText ?? ""
            let bigOther = OpenRewindWriter.cjkBigrams(base)
            let merged = [base, bigOther, originalBig]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return merged.isEmpty ? nil : merged
        }()

        // 1. searchRanking (FTS5)
        let ftsSQL = "INSERT INTO searchRanking (text, otherText, title) VALUES (?, ?, ?);"
        let fts = try prepareStmt(db, ftsSQL); defer { ork_finalize(fts) }
        _ = ork_bindString(fts, 1, text)
        bindOptString(fts, 2, augmentedOther)
        bindOptString(fts, 3, title)
        try step(fts, on: db)
        let docid = ork_last_insert_rowid(db)

        // 2. doc_segment
        let dsSQL = "INSERT INTO doc_segment (docid, segmentId, frameId) VALUES (?, ?, ?);"
        let ds = try prepareStmt(db, dsSQL); defer { ork_finalize(ds) }
        _ = ork_bind_int64(ds, 1, docid)
        _ = ork_bind_int64(ds, 2, segmentId)
        _ = ork_bind_int64(ds, 3, frameId)
        try step(ds, on: db)

        // 3. node rows (preserve source offsets — do NOT recompute).
        guard !nodes.isEmpty else { return }
        let nodeSQL = """
            INSERT INTO node
                (frameId, nodeOrder, textOffset, textLength,
                 leftX, topY, width, height, windowIndex)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let ns = try prepareStmt(db, nodeSQL); defer { ork_finalize(ns) }
        for n in nodes {
            _ = ork_reset(ns)
            _ = ork_bind_int64(ns, 1, frameId)
            _ = ork_bind_int64(ns, 2, Int64(n.nodeOrder))
            _ = ork_bind_int64(ns, 3, Int64(n.textOffset))
            _ = ork_bind_int64(ns, 4, Int64(n.textLength))
            _ = ork_bind_double(ns, 5, n.leftX)
            _ = ork_bind_double(ns, 6, n.topY)
            _ = ork_bind_double(ns, 7, n.width)
            _ = ork_bind_double(ns, 8, n.height)
            if let wi = n.windowIndex { _ = ork_bind_int64(ns, 9, Int64(wi)) }
            else { _ = ork_bind_null(ns, 9) }
            try step(ns, on: db)
        }
    }

    // ---- target-side deletes (overwrite / rollback) ------------------------

    fileprivate func deleteVideoTree(db: ORKSQLite3?, videoId: Int64) throws {
        // Order: node → doc_segment → searchRanking → frame → video.
        // (node and searchRanking are keyed off frame/docid.)
        let sqls: [(String, [Int64])] = [
            ("""
             DELETE FROM node
             WHERE frameId IN (SELECT id FROM frame WHERE videoId = ?);
             """, [videoId]),
            ("""
             DELETE FROM searchRanking
             WHERE rowid IN (
                 SELECT docid FROM doc_segment
                 WHERE frameId IN (SELECT id FROM frame WHERE videoId = ?)
             );
             """, [videoId]),
            ("""
             DELETE FROM doc_segment
             WHERE frameId IN (SELECT id FROM frame WHERE videoId = ?);
             """, [videoId]),
            ("DELETE FROM frame WHERE videoId = ?;", [videoId]),
            ("DELETE FROM video WHERE id = ?;", [videoId]),
        ]
        for (sql, args) in sqls {
            let s = try prepareStmt(db, sql); defer { ork_finalize(s) }
            for (i, a) in args.enumerated() {
                _ = ork_bind_int64(s, Int32(i + 1), a)
            }
            try step(s, on: db)
        }
    }

    // ---- chunk file placement ---------------------------------------------

    /// Copy or hard-link a source chunk into the target vault. On EXDEV,
    /// falls back to a byte copy. `.fromPNGs` re-encodes; missing PNGs fall
    /// back to hard-link. `.bestEffort` tries PNGs first per chunk. Returns
    /// the target URL for post-mortem cleanup and which mode was used.
    fileprivate func placeChunkFile(plan: MigrationPlan,
                                    sourceVideo v: OpenRewindVideo,
                                    effectiveXid: String) throws
        -> (URL, ChunkPlaceMode) {
        let relPath = relPathForEffectiveXid(sourcePath: v.path,
                                             sourceXid: v.xid,
                                             effectiveXid: effectiveXid)
        let src = plan.source.chunksDir.appendingPathComponent(v.path)
        let dst = plan.target.chunksDir.appendingPathComponent(relPath)

        try ensureParent(of: dst)

        switch plan.fidelity {
        case .fromChunks:
            return (dst, try hardlinkOrCopy(src: src, dst: dst))
        case .fromPNGs:
            if let dir = plan.sourcePNGsDir,
               tryReEncodeFromPNGs(pngsDir: dir, video: v, dst: dst) {
                return (dst, .reencoded)
            }
            return (dst, try hardlinkOrCopy(src: src, dst: dst))
        case .bestEffort:
            if let dir = plan.sourcePNGsDir,
               tryReEncodeFromPNGs(pngsDir: dir, video: v, dst: dst) {
                return (dst, .reencoded)
            }
            return (dst, try hardlinkOrCopy(src: src, dst: dst))
        case .dualWrite:
            throw MigrationError.notSupported(
                "dualWrite is a live-capture mode; use `.fromChunks` for one-shot")
        }
    }

    fileprivate func hardlinkOrCopy(src: URL, dst: URL) throws
        -> ChunkPlaceMode {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw MigrationError.chunkMissing(xid: "?", path: src.path)
        }
        // If dst already exists (overwrite path already unlinked; belt-
        // and-suspenders), remove it first.
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        // POSIX link()
        let rc = src.path.withCString { s in
            dst.path.withCString { d in
                link(s, d)
            }
        }
        if rc == 0 {
            return .hardlinked
        }
        // EXDEV or any other failure → byte copy.
        try fm.copyItem(at: src, to: dst)
        return .copied
    }

    /// TODO(phase-4): full re-encode from source PNGs using
    /// `OpenRewindCompressor.videoSettings(.rewindParity)`. Requires
    /// AVAssetWriter + a PNG-to-CVPixelBuffer path; that codepath lives in
    /// OpenRewindCapture, not OpenRewindKit. For now we return false so the
    /// caller falls back to `.fromChunks`. The signature is here so the
    /// public fidelity contract already reflects the intent.
    fileprivate func tryReEncodeFromPNGs(pngsDir: URL,
                                         video v: OpenRewindVideo,
                                         dst: URL) -> Bool {
        // FIX(review-2026-07-28) M-M-4: emit a clearer warning so callers
        // running `.fromPNGs` or `.bestEffort` don't silently get a
        // hardlink under the impression the re-encode ran. The stub still
        // returns false; the warning surfaces the fidelity downgrade.
        let probe = pngsDir.appendingPathComponent(v.path)
        FileHandle.standardError.write(Data("""
            [OpenRewindMigrator] .fromPNGs re-encode is stubbed \
            (phase-4 TODO). Falling back to .fromChunks for xid=\(v.xid) \
            (probe=\(probe.path)).\n
            """.utf8))
        return false
    }

    fileprivate func ensureParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
    }

    fileprivate func removeChunkFile(plan: MigrationPlan,
                                     videoPath: String) throws {
        let dst = plan.target.chunksDir.appendingPathComponent(videoPath)
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
    }

    fileprivate func relPathForEffectiveXid(sourcePath: String,
                                            sourceXid: String,
                                            effectiveXid: String) -> String {
        // Rewind stores chunks as <YYYYMM>/<DD>/<xid>. When we rewrite the
        // xid (duplicate policy) we substitute the trailing path segment.
        if sourceXid == effectiveXid { return sourcePath }
        var parts = sourcePath.split(separator: "/").map(String.init)
        if let last = parts.last, last == sourceXid {
            parts[parts.count - 1] = effectiveXid
            return parts.joined(separator: "/")
        }
        // FIX(review-2026-07-28) M-1: the previous fallback returned
        // "<sourcePath>-copy" which collides across duplicates and doesn't
        // match the required YYYYMM/DD/<xid> shape. Rebuild the whole path
        // deterministically from effectiveXid — the xid itself is base36
        // milliseconds, so we can derive YYYYMM/DD from it.
        //
        // If we can't parse the timestamp out of the xid (custom xid, older
        // Rewind), preserve the source parent directory and just substitute
        // the last segment with effectiveXid — still collision-free because
        // effectiveXid contains -copyN.
        if let ts = timestampFromXid(effectiveXid) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyyMM/dd"
            return "\(fmt.string(from: ts))/\(effectiveXid)"
        }
        if parts.count >= 2 {
            parts[parts.count - 1] = effectiveXid
            return parts.joined(separator: "/")
        }
        return effectiveXid
    }

    /// Best-effort base36-millis parse. Returns nil for non-conforming xids.
    fileprivate func timestampFromXid(_ xid: String) -> Date? {
        // Strip any trailing "-copyN" suffix.
        let base: String
        if let range = xid.range(of: "-copy") {
            base = String(xid[..<range.lowerBound])
        } else {
            base = xid
        }
        guard let ms = Int64(base, radix: 36) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    fileprivate func fileSize(at url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    fileprivate func sameInode(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(); var sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_ino == sb.st_ino && sa.st_dev == sb.st_dev
    }

    // ---- hvcC atom extraction (verify) -------------------------------------

    /// Walk `moov/trak/mdia/minf/stbl/stsd/hvc1|hev1/hvcC`, return the
    /// atom's payload bytes and the 4CC of its containing sample entry so
    /// callers can detect an hvc1 <-> hev1 mismatch. Returns nil if the
    /// atom is absent — verify() treats absence on both sides as a soft
    /// warning.
    fileprivate func extractHvcC(from url: URL) throws -> (payload: Data, fourCC: String)? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let moov = findAtom(in: data, name: "moov") else { return nil }
        guard let trak = findAtom(in: moov, name: "trak") else { return nil }
        guard let mdia = findAtom(in: trak, name: "mdia") else { return nil }
        guard let minf = findAtom(in: mdia, name: "minf") else { return nil }
        guard let stbl = findAtom(in: minf, name: "stbl") else { return nil }
        guard let stsd = findAtom(in: stbl, name: "stsd") else { return nil }
        // stsd payload has 4-byte version/flags + 4-byte entry_count, then
        // one or more sample entries; find the hvc1/hev1 entry.
        let stsdBody = stsd.count > 8 ? stsd.subdata(in: 8..<stsd.count) : Data()
        // FIX(review-2026-07-28) M-2: distinguish hvc1 vs hev1 so verify
        // can flag a codec-tag mismatch even when the hvcC payload matches.
        var fourCC = "hvc1"
        var hvc1 = findAtom(in: stsdBody, name: "hvc1")
        if hvc1 == nil {
            hvc1 = findAtom(in: stsdBody, name: "hev1")
            fourCC = "hev1"
        }
        guard let hvcEntry = hvc1 else { return nil }
        // Sample entry has 78 bytes of header before the codec-specific
        // atoms (VisualSampleEntry). Skip and look for hvcC.
        guard hvcEntry.count > 78 else { return nil }
        let entryBody = hvcEntry.subdata(in: 78..<hvcEntry.count)
        guard let payload = findAtom(in: entryBody, name: "hvcC") else {
            return nil
        }
        return (payload, fourCC)
    }

    /// Linear scan for a top-level atom by 4CC name. Returns the atom's
    /// payload (bytes after the size+type header).
    ///
    /// FIX(review-2026-07-28) M-2: handle 64-bit largesize (`size == 1`,
    /// next 8 bytes are UInt64 largesize) and "extends to EOF" (`size ==
    /// 0`). Previously `size < 8` short-circuited on both, silently
    /// aborting the walk over any chunk containing a >4 GiB mdat.
    fileprivate func findAtom(in data: Data, name: String) -> Data? {
        let nameBytes = Array(name.utf8)
        guard nameBytes.count == 4 else { return nil }
        var offset = 0
        while offset + 8 <= data.count {
            let sizeBE = data.subdata(in: offset..<offset+4)
            var size = Int(UInt32(bigEndian: sizeBE.withUnsafeBytes {
                $0.load(as: UInt32.self)
            }))
            var headerSize = 8
            if size == 1 {
                // 64-bit largesize follows the 32-bit size + 4-byte type.
                guard offset + 16 <= data.count else { return nil }
                let large = data.subdata(in: offset+8..<offset+16)
                let ls = UInt64(bigEndian: large.withUnsafeBytes {
                    $0.load(as: UInt64.self)
                })
                if ls > Int.max { return nil }
                size = Int(ls)
                headerSize = 16
                if size < headerSize { return nil }
            } else if size == 0 {
                // Extends to end of enclosing container.
                size = data.count - offset
            } else if size < 8 {
                return nil
            }
            if offset + size > data.count { return nil }
            let matches = nameBytes.enumerated().allSatisfy { (i, b) in
                data[offset + 4 + i] == b
            }
            if matches {
                let bodyStart = offset + headerSize
                let bodyEnd = offset + size
                return data.subdata(in: bodyStart..<bodyEnd)
            }
            offset += size
        }
        return nil
    }
}
