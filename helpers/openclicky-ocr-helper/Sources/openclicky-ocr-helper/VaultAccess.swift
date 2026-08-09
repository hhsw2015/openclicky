// VaultAccess — helper-side SQLCipher handle. Opens the same
// db-enc.sqlite3 the main app writes, using the 32-byte hex
// passphrase persisted at `<vault>/key` by OpenRewindBridge.
//
// Guarantees the helper matches the main app's PRAGMAs:
//   * cipher_page_size = 4096   (Rewind parity)
//   * journal_mode     = WAL    (concurrent readers/writers)
//   * foreign_keys     = ON
//   * temp_store       = MEMORY
//
// The helper opens a single connection at process start and holds it
// open. WAL means the main app's simultaneous read/write connection
// coexists safely.

import Foundation
import SQLCipher

@_silgen_name("sqlite3_key_v2")
private func openclicky_sqlite3_key_v2(
    _ h: OpaquePointer?, _ dbName: UnsafePointer<CChar>?,
    _ pKey: UnsafeRawPointer?, _ nKey: Int32) -> Int32

public final class VaultAccess {

    public enum VaultError: Error, CustomStringConvertible {
        case keyMissing(String)
        case openFailed(String)
        case keyRejected
        case queryFailed(String)

        public var description: String {
            switch self {
            case .keyMissing(let p):   return "vault key not found at \(p)"
            case .openFailed(let s):   return "vault open failed: \(s)"
            case .keyRejected:         return "SQLCipher key rejected"
            case .queryFailed(let s):  return "vault query failed: \(s)"
            }
        }
    }

    private let db: OpaquePointer
    private let lock = NSLock()

    public init(vaultRoot: URL) throws {
        let keyURL = vaultRoot.appendingPathComponent("key")
        guard let passphrase = (try? String(contentsOf: keyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !passphrase.isEmpty else {
            throw VaultError.keyMissing(keyURL.path)
        }

        let dbURL = vaultRoot.appendingPathComponent("db-enc.sqlite3")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "open rc=\(rc)"
            if handle != nil { sqlite3_close_v2(handle) }
            throw VaultError.openFailed(msg)
        }
        let keyRC = passphrase.withCString { p in
            openclicky_sqlite3_key_v2(h, "main", p, Int32(strlen(p)))
        }
        guard keyRC == SQLITE_OK else {
            sqlite3_close_v2(h)
            throw VaultError.openFailed("sqlite3_key_v2 rc=\(keyRC)")
        }

        // Must set cipher_page_size before touching sqlite_master.
        _ = sqlite3_exec(h, "PRAGMA cipher_page_size = 4096;", nil, nil, nil)

        // Verify key by touching sqlite_master.
        var probeStmt: OpaquePointer?
        let probeRC = sqlite3_prepare_v2(
            h, "SELECT count(*) FROM sqlite_master;", -1, &probeStmt, nil)
        guard probeRC == SQLITE_OK,
              sqlite3_step(probeStmt) == SQLITE_ROW else {
            sqlite3_finalize(probeStmt)
            sqlite3_close_v2(h)
            throw VaultError.keyRejected
        }
        sqlite3_finalize(probeStmt)

        for pragma in [
            "PRAGMA foreign_keys = ON;",
            "PRAGMA journal_mode = WAL;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA synchronous = NORMAL;",
        ] {
            _ = sqlite3_exec(h, pragma, nil, nil, nil)
        }

        self.db = h
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Writes

    /// Represents one OCR bbox node the helper persists into `node`.
    public struct NodeInput: Sendable {
        public let text: String
        public let leftX: Double
        public let topY: Double
        public let width: Double
        public let height: Double
        public init(text: String, leftX: Double, topY: Double,
                    width: Double, height: Double) {
            self.text = text
            self.leftX = leftX; self.topY = topY
            self.width = width; self.height = height
        }
    }

    /// Mirrors OpenRewindWriter.insertSearchRanking: FTS insert +
    /// doc_segment link + per-node rows, wrapped in a single
    /// transaction so we pay one WAL fsync per frame.
    public func insertSearchRanking(frameID: Int64,
                                    segmentID: Int64,
                                    text: String,
                                    otherText: String?,
                                    title: String?,
                                    nodes: [NodeInput]) throws {
        lock.lock()
        defer { lock.unlock() }

        var beginErr: UnsafeMutablePointer<CChar>?
        let beginRC = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, &beginErr)
        if beginErr != nil { sqlite3_free(beginErr) }
        let inTxn = (beginRC == SQLITE_OK)

        var committed = false
        defer {
            if inTxn && !committed {
                var rollErr: UnsafeMutablePointer<CChar>?
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, &rollErr)
                if rollErr != nil { sqlite3_free(rollErr) }
            }
        }

        // 1. FTS row.
        let insertFTS = """
            INSERT INTO searchRanking (text, otherText, title)
            VALUES (?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertFTS, -1, &stmt, nil) == SQLITE_OK else {
            throw VaultError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        Self.bindString(stmt, 1, text)
        Self.bindOptString(stmt, 2, otherText)
        Self.bindOptString(stmt, 3, title)
        let ftsStep = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard ftsStep == SQLITE_DONE else {
            throw VaultError.queryFailed("searchRanking insert step rc=\(ftsStep)")
        }
        let docid = sqlite3_last_insert_rowid(db)

        // 2. doc_segment link.
        let linkSQL = """
            INSERT INTO doc_segment (docid, segmentId, frameId)
            VALUES (?, ?, ?);
            """
        var linkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, linkSQL, -1, &linkStmt, nil) == SQLITE_OK else {
            throw VaultError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(linkStmt, 1, docid)
        sqlite3_bind_int64(linkStmt, 2, segmentID)
        sqlite3_bind_int64(linkStmt, 3, frameID)
        let linkStep = sqlite3_step(linkStmt)
        sqlite3_finalize(linkStmt)
        guard linkStep == SQLITE_DONE else {
            throw VaultError.queryFailed("doc_segment insert step rc=\(linkStep)")
        }

        // 3. Node rows. Filter + cap to match main-app policy so DB
        // stays wire-compatible.
        let kept = nodes.enumerated().filter { (_, n) in
            let s = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.utf16.count >= 2
        }.prefix(1500)

        let nodeSQL = """
            INSERT INTO node
                (frameId, nodeOrder, textOffset, textLength,
                 leftX, topY, width, height, windowIndex)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var offset = 0
        for (order, n) in kept {
            var nStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, nodeSQL, -1, &nStmt, nil) == SQLITE_OK else {
                throw VaultError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            let len = n.text.utf16.count
            sqlite3_bind_int64(nStmt, 1, frameID)
            sqlite3_bind_int64(nStmt, 2, Int64(order))
            sqlite3_bind_int64(nStmt, 3, Int64(offset))
            sqlite3_bind_int64(nStmt, 4, Int64(len))
            sqlite3_bind_double(nStmt, 5, n.leftX)
            sqlite3_bind_double(nStmt, 6, n.topY)
            sqlite3_bind_double(nStmt, 7, n.width)
            sqlite3_bind_double(nStmt, 8, n.height)
            sqlite3_bind_int64(nStmt, 9, 0)
            _ = sqlite3_step(nStmt)
            sqlite3_finalize(nStmt)
            offset += len + 1
        }

        // 4. Stamp frame_processing so the reconciler skips this on
        // next boot. INSERT OR IGNORE keeps this idempotent.
        let procSQL = """
            INSERT OR IGNORE INTO frame_processing
                (id, processingType, createdAt)
            VALUES (?, ?, ?);
            """
        var procStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, procSQL, -1, &procStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(procStmt, 1, frameID)
            Self.bindString(procStmt, 2, "ocr")
            let iso = Self.rewindISO(Date())
            Self.bindString(procStmt, 3, iso)
            _ = sqlite3_step(procStmt)
            sqlite3_finalize(procStmt)
        }

        // 5. Commit.
        if inTxn {
            var commitErr: UnsafeMutablePointer<CChar>?
            let cRC = sqlite3_exec(db, "COMMIT;", nil, nil, &commitErr)
            if commitErr != nil { sqlite3_free(commitErr) }
            guard cRC == SQLITE_OK else {
                throw VaultError.queryFailed("commit rc=\(cRC)")
            }
            committed = true
        }
    }

    // MARK: - Helpers

    private static let sqliteTransient = unsafeBitCast(
        Int(-1), to: sqlite3_destructor_type.self)

    private static func bindString(_ stmt: OpaquePointer?, _ idx: Int32,
                                   _ v: String) {
        _ = v.withCString { p in
            sqlite3_bind_text(stmt, idx, p, Int32(strlen(p)), sqliteTransient)
        }
    }

    private static func bindOptString(_ stmt: OpaquePointer?, _ idx: Int32,
                                      _ v: String?) {
        if let v {
            bindString(stmt, idx, v)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func rewindISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var s = f.string(from: date)
        if s.hasSuffix("Z") { s.removeLast() }
        return s
    }
}
