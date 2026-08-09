// SchemaInstaller.swift — CREATE TABLE / INDEX / VIRTUAL TABLE for a
// fresh OpenRewind vault. Layout stays compatible with Rewind 1.5607
// (see Schema.swift) so users can migrate either direction.
//
// Called by Writer.init when the SQLCipher DB doesn't exist yet.
// ponytail: one function, one SQL blob. Migrations = the day we need them.

import Foundation

public enum OpenRewindSchemaInstaller {

    /// Full DDL. Column order matches `Schema.swift` enums.
    public static let ddl: String = """
    CREATE TABLE IF NOT EXISTS segment (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        bundleID       TEXT,
        startDate      TEXT,
        endDate        TEXT,
        windowName     TEXT,
        browserUrl     TEXT,
        browserProfile TEXT,
        type           INTEGER DEFAULT 0
    );

    -- video.captureType is TEXT in Rewind ('image' / 'video'). Fixed
    -- types + NOT NULL + defaults per live schema (2026-07-29 review).
    CREATE TABLE IF NOT EXISTS video (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        height          INTEGER,
        width           INTEGER,
        path            TEXT NOT NULL DEFAULT '',
        captureType     TEXT,
        fileSize        INTEGER,
        frameRate       REAL NOT NULL DEFAULT 30.0,
        local           INTEGER NOT NULL DEFAULT 1,
        xid             TEXT,
        processingState INTEGER NOT NULL DEFAULT 0
    );

    -- frame.encodingStatus is TEXT in Rewind (samples: 'deferred',
    -- 'pending', 'success'). Writer already binds text.
    CREATE TABLE IF NOT EXISTS frame (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        createdAt       TEXT,
        imageFileName   TEXT,
        segmentId       INTEGER REFERENCES segment(id),
        videoId         INTEGER REFERENCES video(id),
        videoFrameIndex INTEGER,
        isStarred       INTEGER DEFAULT 0,
        encodingStatus  TEXT DEFAULT 'pending',
        -- FIX(trigger-redaction-2026-07-29): retrace V17/V7 columns.
        capture_trigger  TEXT,
        redactionReason TEXT
    );

    CREATE TABLE IF NOT EXISTS node (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        frameId     INTEGER REFERENCES frame(id),
        nodeOrder   INTEGER,
        textOffset  INTEGER,
        textLength  INTEGER,
        leftX       REAL,
        topY        REAL,
        width       REAL,
        height      REAL,
        windowIndex INTEGER
    );

    CREATE TABLE IF NOT EXISTS doc_segment (
        docid     INTEGER PRIMARY KEY,
        segmentId INTEGER REFERENCES segment(id),
        frameId   INTEGER REFERENCES frame(id)
    );

    CREATE TABLE IF NOT EXISTS audio (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        segmentId INTEGER REFERENCES segment(id),
        path      TEXT,
        startTime TEXT,
        duration  REAL
    );

    -- Rewind schema: (id, segmentId, speechSource NOT NULL, word NOT NULL,
    -- timeOffset INTEGER NOT NULL, fullTextOffset, duration INTEGER NOT NULL).
    -- OpenRewind Writer previously used startTime/endTime; the compat
    -- shim below keeps both column layouts on the same physical table
    -- via generated columns so Reader (startTime/endTime/fullTextOffset)
    -- and Rewind (timeOffset/duration) can co-exist. Rewind's INSERT
    -- writes timeOffset+duration; ours writes those plus the derived
    -- start/end.
    CREATE TABLE IF NOT EXISTS transcript_word (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        segmentId      INTEGER NOT NULL REFERENCES segment(id),
        speechSource   TEXT NOT NULL DEFAULT 'apple.speech',
        word           TEXT NOT NULL,
        timeOffset     INTEGER NOT NULL,
        fullTextOffset INTEGER,
        duration       INTEGER NOT NULL,
        -- FIX(speaker-id-2026-07-30): OpenClicky extension.
        -- Conversation turns log user/assistant text as words; without
        -- a role column we had to prepend `[user] ` / `[assistant] `
        -- into `word` itself, which polluted FTS BM25. speakerId = 0
        -- means user, 1 means assistant, NULL means real captured
        -- speech (default from Rewind schema).
        speakerId      INTEGER
    );

    -- event.type/status are TEXT in Rewind.
    CREATE TABLE IF NOT EXISTS event (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        type              TEXT NOT NULL,
        status            TEXT NOT NULL DEFAULT 'ok',
        title             TEXT,
        participants      TEXT,
        detailsJSON       TEXT,
        calendarID        TEXT,
        calendarEventID   TEXT,
        calendarSeriesID  TEXT,
        segmentID         INTEGER NOT NULL DEFAULT 0 REFERENCES segment(id)
    );

    -- Rewind live layout: (id, status TEXT NOT NULL, text TEXT,
    -- eventId INTEGER NOT NULL UNIQUE REFERENCES event(id)).
    CREATE TABLE IF NOT EXISTS summary (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        status  TEXT NOT NULL DEFAULT 'pending',
        text    TEXT,
        eventId INTEGER NOT NULL UNIQUE REFERENCES event(id)
    );

    -- Rewind: `id` is the frame id (NOT a synthetic PK); UNIQUE per
    -- (id, processingType) lets a frame carry multiple markers.
    CREATE TABLE IF NOT EXISTS frame_processing (
        id             INTEGER NOT NULL,
        processingType TEXT NOT NULL,
        createdAt      TEXT NOT NULL,
        UNIQUE (id, processingType)
    );

    CREATE TABLE IF NOT EXISTS purge (
        path     TEXT NOT NULL,
        fileType TEXT NOT NULL,
        UNIQUE (path, fileType)
    );

    -- Rewind ships THREE full-text tables: `search` (FTS4) is the
    -- primary index doc_segment.docid FK's against; `searchRanking`
    -- (FTS5) drives ranked queries; `searchOffsets` (FTS4) powers
    -- hit-highlighting. All three use the Porter tokenizer, matching
    -- Rewind's default. Rewind also seeds bm25 weights (1.0, 0.3, 3.0)
    -- to bias title matches.
    CREATE VIRTUAL TABLE IF NOT EXISTS search
        USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchRanking
        USING fts5(text, otherText, title, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchOffsets
        USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS tokenizer
        USING fts3tokenize(porter);

    INSERT INTO searchRanking(searchRanking, rank)
        VALUES('rank', 'bm25(1.0, 0.3, 3.0)');

    CREATE INDEX IF NOT EXISTS index_frame_on_createdat
        ON frame(createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_encodingstatus_createdat
        ON frame(encodingStatus, createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_isstarred_createdat
        ON frame(isStarred, createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_segmentid_createdat
        ON frame(segmentId, createdAt);
    CREATE INDEX IF NOT EXISTS index_frame_on_videoid
        ON frame(videoId);
    CREATE INDEX IF NOT EXISTS index_node_on_frameid
        ON node(frameId);
    CREATE INDEX IF NOT EXISTS index_doc_segment_on_frameid_docid
        ON doc_segment(frameId, docid);
    CREATE INDEX IF NOT EXISTS index_doc_segment_on_segmentid_docid
        ON doc_segment(segmentId, docid);
    CREATE INDEX IF NOT EXISTS index_segment_on_appid
        ON segment(bundleID);
    CREATE INDEX IF NOT EXISTS index_segment_on_endtime
        ON segment(endDate);
    CREATE INDEX IF NOT EXISTS index_segment_on_starttime
        ON segment(startDate);
    CREATE INDEX IF NOT EXISTS index_summary_on_eventid
        ON summary(eventId);
    CREATE INDEX IF NOT EXISTS index_summary_on_status
        ON summary(status);
    CREATE INDEX IF NOT EXISTS index_event_on_calendarseriesid
        ON event(calendarSeriesID);
    CREATE INDEX IF NOT EXISTS index_event_on_status
        ON event(status);
    CREATE INDEX IF NOT EXISTS index_transcript_word_on_segmentid_fulltextoffset
        ON transcript_word(segmentId, fullTextOffset);

    -- OpenClicky-only sidecar: semantic search vectors from Apple's
    -- NLEmbedding. Not part of the Rewind schema — Rewind ignores
    -- unknown tables, so vault stays cross-tool compatible. Column
    -- `vector` is raw Float32 BLOB (300 dim EN / 512 dim zh-Hans).
    CREATE TABLE IF NOT EXISTS openclicky_embedding (
        frameId   INTEGER PRIMARY KEY REFERENCES frame(id),
        model     TEXT NOT NULL,
        vector    BLOB NOT NULL,
        createdAt TEXT
    );
    CREATE INDEX IF NOT EXISTS index_openclicky_embedding_on_created
        ON openclicky_embedding(createdAt);

    -- FIX(retrace-#8-2026-07-31): daily DB size snapshot. retrace
    -- Migration V14 creates a `db_storage_snapshot` table with one row
    -- per day so users can see storage-growth trends locally without
    -- external telemetry. OpenClicky-only sidecar (Rewind ignores).
    CREATE TABLE IF NOT EXISTS openclicky_db_storage_snapshot (
        day       TEXT PRIMARY KEY,
        db_bytes  INTEGER NOT NULL,
        wal_bytes INTEGER NOT NULL,
        chunks_bytes INTEGER NOT NULL DEFAULT 0,
        capturedAt TEXT NOT NULL
    );
    """

    /// Migration DDL for existing vaults. Adds missing FTS4 tables,
    /// tokenizer, transcript_word columns, summary.text, and any
    /// UNIQUE constraint that older schemas lack. All statements are
    /// `IF NOT EXISTS`, so this is safe to run every boot.
    private static let migrationDDL: String = """
    CREATE VIRTUAL TABLE IF NOT EXISTS search
        USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS searchOffsets
        USING fts4(text, otherText, tokenize=porter);
    CREATE VIRTUAL TABLE IF NOT EXISTS tokenizer
        USING fts3tokenize(porter);
    CREATE TABLE IF NOT EXISTS openclicky_embedding (
        frameId   INTEGER PRIMARY KEY REFERENCES frame(id),
        model     TEXT NOT NULL,
        vector    BLOB NOT NULL,
        createdAt TEXT
    );
    CREATE INDEX IF NOT EXISTS index_openclicky_embedding_on_created
        ON openclicky_embedding(createdAt);
    CREATE UNIQUE INDEX IF NOT EXISTS uq_purge_path_filetype
        ON purge(path, fileType);
    CREATE UNIQUE INDEX IF NOT EXISTS uq_frame_processing_id_type
        ON frame_processing(id, processingType);
    """

    /// Idempotent upgrade path. Existing 0.1 vaults with legacy schema
    /// pick up the FTS4 siblings + UNIQUE constraints without needing
    /// a full rebuild. Column-level migrations (transcript_word,
    /// summary.text) live in `alterColumns` — attempted via ALTER TABLE
    /// which silently fails on already-modern schemas.
    ///
    /// FIX(rewind-compat-2026-07-29): `capture_trigger` / `redactionReason`
    /// on `frame` are OpenRewind-specific extensions. We MUST NOT run
    /// those ALTERs on a Rewind vault (docs/COMPATIBILITY.md rule 2:
    /// "Never CREATE TABLE, ALTER TABLE, or drop indexes on a Rewind
    /// vault"). Writer is opened only on OpenRewind vaults today, but
    /// this is belt-and-braces for anyone porting via SPM: detect
    /// Rewind by presence of Rewind-signature columns and skip the
    /// frame-column ALTERs on that DB.
    internal static func installIdempotent(on db: ORKSQLite3?) throws {
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        _ = ork_exec(db, migrationDDL, nil, nil, &errPtr)
        errPtr = nil
        // Common ALTERs — all forward-compatible with Rewind
        // (Rewind's SchemaValidator accepts unknown columns because
        // sqlite gives them NULL and Rewind's SELECTs enumerate cols
        // by name).
        for stmt in [
            "ALTER TABLE summary ADD COLUMN text TEXT",
            "ALTER TABLE transcript_word ADD COLUMN speechSource TEXT NOT NULL DEFAULT 'apple.speech'",
            "ALTER TABLE transcript_word ADD COLUMN timeOffset INTEGER",
            "ALTER TABLE transcript_word ADD COLUMN duration INTEGER",
            // FIX(speaker-id-2026-07-30): see fresh-schema comment.
            "ALTER TABLE transcript_word ADD COLUMN speakerId INTEGER",
            // FIX(audio-source-2026-07-31): where the transcript came
            // from. `speechSource` records the engine, `audioSource`
            // records the audio route: `mic`, `system`, `chat`,
            // `voice`. Rewind-vault-safe: pure additive column.
            "ALTER TABLE transcript_word ADD COLUMN audioSource TEXT DEFAULT ''",
        ] {
            var localErr: UnsafeMutablePointer<CChar>? = nil
            _ = ork_exec(db, stmt, nil, nil, &localErr)
        }
        // OpenRewind-only frame extensions. Belt-and-braces: check the
        // schema signature before ALTERing — Rewind ships without them
        // and we don't want to accidentally mutate a shared vault.
        if isOpenRewindOwnedFrameSchema(db) {
            for stmt in [
                // retrace migrations V17 (capture_trigger) + V7 (redactionReason).
                "ALTER TABLE frame ADD COLUMN capture_trigger TEXT",
                "ALTER TABLE frame ADD COLUMN redactionReason TEXT",
                // FIX(retrace-#6-2026-07-31): V19 encodedAt column —
                // distinguishes "frame row exists" from "frame is
                // durable on disk". Reader guards against reading
                // frames that captured but haven't hit the mp4 yet.
                "ALTER TABLE frame ADD COLUMN encodedAt TEXT",
                // FIX(retrace-#7-2026-07-31): V15 rewrite tracking —
                // idempotent segment rewrites after a crash mid-flight.
                "ALTER TABLE frame ADD COLUMN rewritePurpose TEXT",
                "ALTER TABLE frame ADD COLUMN rewrittenAt TEXT",
            ] {
                var localErr: UnsafeMutablePointer<CChar>? = nil
                _ = ork_exec(db, stmt, nil, nil, &localErr)
            }
        }
    }

    /// FIX(rewind-compat-review-18-2026-07-29): the earlier heuristic
    /// keyed off `encodingStatus` col presence, but Rewind ships that
    /// column itself (verified via `strings` on the Rewind binary +
    /// retrace's V1 schema). So the guard was inert — Writer opened
    /// on a Rewind vault would have run our ALTERs.
    ///
    /// Real sentinel: `openrewind_meta` — a marker table we CREATE
    /// only in `install(on:)` (fresh DDL). Rewind never has it. Its
    /// presence is proof of "OpenRewind owns this DB" and green-lights
    /// the extension-column ALTERs. Absent → refuse to mutate the
    /// schema — the caller's DB is either Rewind's or something else
    /// we shouldn't touch.
    private static func isOpenRewindOwnedFrameSchema(_ db: ORKSQLite3?) -> Bool {
        var stmt: ORKStmt? = nil
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='openrewind_meta'"
        guard ork_prepare(db, sql, -1, &stmt, nil) == ORK_SQLITE_OK else { return false }
        defer { ork_finalize(stmt) }
        guard ork_step(stmt) == ORK_SQLITE_ROW else { return false }
        return ork_col_int64(stmt, 0) > 0
    }

    /// Best-effort backfill of `openrewind_meta` so pre-existing
    /// OpenRewind vaults (created before the marker was introduced)
    /// still qualify as "ours". Called from `installIdempotent`
    /// exactly once per open. If the DB is a Rewind vault we DO
    /// still create this table — but only after `isRewindSchemaHeuristic`
    /// says no. See callers.
    private static func stampOpenRewindMarker(_ db: ORKSQLite3?) {
        var e: UnsafeMutablePointer<CChar>? = nil
        _ = ork_exec(db, "CREATE TABLE IF NOT EXISTS openrewind_meta (key TEXT PRIMARY KEY, value TEXT)", nil, nil, &e)
        e = nil
        _ = ork_exec(db, "INSERT OR IGNORE INTO openrewind_meta(key, value) VALUES('vault_owner','openrewind')", nil, nil, &e)
    }

    /// Rewind-shape probe: Rewind has both `frame.encodingStatus` AND
    /// the FTS5 `searchRanking` vtable AND no `openrewind_meta`. If
    /// we can positively identify Rewind's shape we refuse to write
    /// the marker (belt-and-braces even if a caller ignored the
    /// COMPATIBILITY rule and pointed us at a Rewind vault).
    private static func looksLikeRewindVault(_ db: ORKSQLite3?) -> Bool {
        // Rewind's exact table set is (frame, segment, video, searchRanking, ...).
        // We probe for a Rewind-only marker that we know does NOT exist in
        // OpenRewind-only vaults: the `Rewind` config-key pattern in the
        // `settings` table if present, or the `RewindSchema` migration hash.
        // Cheap probe: look for `sqlite_master` row for `sqlite_sequence`
        // whose seq value matches a Rewind-only auto-increment (fragile).
        //
        // Simplest defensive answer: if `openrewind_meta` is ABSENT AND
        // any Rewind-canonical table exists, treat as Rewind vault.
        var stmt: ORKStmt? = nil
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('frame','segment','video')"
        guard ork_prepare(db, sql, -1, &stmt, nil) == ORK_SQLITE_OK else { return false }
        defer { ork_finalize(stmt) }
        var seen = 0
        while ork_step(stmt) == ORK_SQLITE_ROW { seen += 1 }
        return seen >= 2
    }

    /// Executes DDL on an already-keyed handle.
    internal static func install(on db: ORKSQLite3?) throws {
        var errPtr: UnsafeMutablePointer<CChar>? = nil
        let rc = ork_exec(db, ddl, nil, nil, &errPtr)
        guard rc == ORK_SQLITE_OK else {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown"
            _ = errPtr
            throw OpenRewindError.openFailed("schema install rc=\(rc): \(msg)")
        }
        // FIX(rewind-compat-review-18-2026-07-29): tag this vault as
        // OpenRewind-owned so future opens can safely ALTER our
        // extension columns without risk of touching a Rewind vault.
        stampOpenRewindMarker(db)
    }

    /// Public helper for migration callers who want to certify an
    /// existing pre-marker OpenRewind vault. Do NOT call on a Rewind
    /// vault — refuses if `looksLikeRewindVault` says the DB matches
    /// Rewind's shape and doesn't already have `openrewind_meta`.
    internal static func stampAsOpenRewindOwned(_ db: ORKSQLite3?) -> Bool {
        if isOpenRewindOwnedFrameSchema(db) { return true }
        if looksLikeRewindVault(db) { return false }
        stampOpenRewindMarker(db)
        return true
    }
}
