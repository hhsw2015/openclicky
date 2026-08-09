// SchemaValidator.swift — verify that every Rewind table + column we
// depend on is present, and that `searchRanking` is FTS5 (not the legacy
// FTS4 `search` table). Runs on daemon start via OpenRewindDaemon;
// throws `OpenRewindError.schemaInvalid` with a detailed manifest if
// anything is missing.

import Foundation

/// Namespace for schema validation entry points.
public enum OpenRewindSchemaValidator {

    /// Open the DB with the given passphrase and confirm the schema is
    /// what we expect. Only reads — never mutates. Throws
    /// `OpenRewindError.schemaInvalid` when the vault is broken or has
    /// been recreated by a different Rewind version.
    public static func verify(storage: OpenRewindStorage,
                              passphrase: String) throws {
        var handle: ORKSQLite3?
        let flags = ORK_SQLITE_OPEN_READWRITE | ORK_SQLITE_OPEN_NOMUTEX
        let rc = ork_open_v2(storage.dbEncrypted.path, &handle, flags, nil)
        guard rc == ORK_SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: ork_errmsg($0)!) } ?? "open error"
            throw OpenRewindError.openFailed(msg)
        }
        defer { ork_close_v2(handle) }
        let keyRC = passphrase.withCString { p in
            ork_key_v2(handle, "main", p, Int32(strlen(p)))
        }
        guard keyRC == ORK_SQLITE_OK else {
            throw OpenRewindError.openFailed("sqlite3_key_v2 failed rc=\(keyRC)")
        }

        // Sanity-touch.
        var probe: ORKStmt?
        guard ork_prepare(handle, "SELECT count(*) FROM sqlite_master;", -1, &probe, nil) == ORK_SQLITE_OK,
              ork_step(probe) == ORK_SQLITE_ROW else {
            ork_finalize(probe)
            throw OpenRewindError.keyRejected
        }
        ork_finalize(probe)

        try verify(handle: handle)
    }

    /// Lower-level variant used when the caller already has an open handle
    /// (Reader/Writer initialisers, migration paths).
    internal static func verify(handle: ORKSQLite3?) throws {
        var missingTables: [String] = []
        var missingColumns: [String] = []
        var notFTS5: [String] = []

        // 1. Regular tables + columns.
        for (table, expected) in OpenRewindSchema.expectedColumns {
            let cols = pragmaColumns(handle: handle, table: table)
            if cols.isEmpty {
                missingTables.append(table)
                continue
            }
            let colSet = Set(cols)
            for c in expected where !colSet.contains(c) {
                missingColumns.append("\(table).\(c)")
            }
        }

        // 2. FTS5 tables. sqlite_master.sql for these begins with
        //    "CREATE VIRTUAL TABLE ... USING fts5(".
        for t in OpenRewindSchema.expectedFTS5Tables {
            let sql = masterSQL(handle: handle, name: t)
            if sql == nil {
                missingTables.append(t)
            } else if !(sql?.lowercased().contains("using fts5") ?? false) {
                notFTS5.append(t)
            }
        }

        // 3. Indexes we depend on for query performance. Missing indexes
        //    don't corrupt data but cause table scans on hot Reader paths;
        //    surface them under `missingTables` so the invalid-schema
        //    envelope is a single failure surface.
        //    FIX(review-2026-07-28) K-M-4: the expectedIndexes list existed
        //    but was never consulted. Walk sqlite_master and flag anything
        //    Rewind's own migrations create that we don't see.
        let indexNames = allIndexNames(handle: handle)
        for idx in OpenRewindSchema.expectedIndexes where !indexNames.contains(idx) {
            missingTables.append("index:\(idx)")
        }

        guard missingTables.isEmpty
                && missingColumns.isEmpty
                && notFTS5.isEmpty else {
            throw OpenRewindError.schemaInvalid(
                missingTables: missingTables,
                missingColumns: missingColumns,
                notFTS5: notFTS5)
        }
    }

    // FIX(review-2026-07-28) K-M-4: index-name lookup used by verify().
    private static func allIndexNames(handle: ORKSQLite3?) -> Set<String> {
        var stmt: ORKStmt?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'index';"
        guard ork_prepare(handle, sql, -1, &stmt, nil) == ORK_SQLITE_OK else {
            return []
        }
        defer { ork_finalize(stmt) }
        var out = Set<String>()
        while ork_step(stmt) == ORK_SQLITE_ROW {
            if let n = ork_readString(stmt, 0) { out.insert(n) }
        }
        return out
    }

    // MARK: - Helpers

    private static func pragmaColumns(handle: ORKSQLite3?, table: String) -> [String] {
        var stmt: ORKStmt?
        let sql = "PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\");"
        guard ork_prepare(handle, sql, -1, &stmt, nil) == ORK_SQLITE_OK else {
            return []
        }
        defer { ork_finalize(stmt) }
        var out: [String] = []
        while ork_step(stmt) == ORK_SQLITE_ROW {
            // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
            if let n = ork_readString(stmt, 1) { out.append(n) }
        }
        return out
    }

    private static func masterSQL(handle: ORKSQLite3?, name: String) -> String? {
        var stmt: ORKStmt?
        let sql = "SELECT sql FROM sqlite_master WHERE name = ? LIMIT 1;"
        guard ork_prepare(handle, sql, -1, &stmt, nil) == ORK_SQLITE_OK else {
            return nil
        }
        defer { ork_finalize(stmt) }
        _ = ork_bindString(stmt, 1, name)
        if ork_step(stmt) == ORK_SQLITE_ROW {
            return ork_readString(stmt, 0)
        }
        return nil
    }
}
