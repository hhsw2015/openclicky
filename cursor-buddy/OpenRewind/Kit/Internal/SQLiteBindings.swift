// SQLiteBindings.swift — internal SQLCipher C bindings shared by Reader,
// Writer, and SchemaValidator.
//
// Previously this file bound `sqlite3_*` symbols via `@_silgen_name` and
// relied on the system libsqlite3.dylib being replaced at link time.
// That worked for read-only symbols but sqlite3_key_v2 (needed to unlock
// Rewind's encrypted vault) does NOT exist in Apple's libsqlite3, so any
// path that opened a real Rewind DB failed with rc=21.
//
// We now depend on the `CSQLCipher` system-library target (see Package.swift
// + Sources/CSQLCipher/module.modulemap) which points at Homebrew's
// libsqlcipher. The `ork_*` names are kept as thin @inlinable wrappers so
// Reader/Writer/Migrator/SchemaValidator diffs stay empty.

import Foundation
import SQLCipher

// FIX(swift-sqlcipher-2026-07-29): swift-sqlcipher's Swift module map
// doesn't re-export `sqlite3_key_v2` symbols to callers (only used
// internally by SQLiteDB). Bind directly via @_silgen_name — the C
// symbol is present in the sqlcipher static lib.
@_silgen_name("sqlite3_key_v2")
internal func swiftsqlcipher_sqlite3_key_v2(
    _ h: OpaquePointer?, _ dbName: UnsafePointer<CChar>?,
    _ pKey: UnsafeRawPointer?, _ nKey: Int32) -> Int32

internal typealias ORKSQLite3 = OpaquePointer
internal typealias ORKStmt    = OpaquePointer

internal let ORK_SQLITE_ROW   : Int32 = 100
internal let ORK_SQLITE_DONE  : Int32 = 101
internal let ORK_SQLITE_OK    : Int32 = 0
internal let ORK_SQLITE_NULL  : Int32 = 5
internal let ORK_SQLITE_OPEN_READWRITE : Int32 = 0x00000002
internal let ORK_SQLITE_OPEN_CREATE    : Int32 = 0x00000004
internal let ORK_SQLITE_OPEN_NOMUTEX   : Int32 = 0x00008000
internal let ORK_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


@discardableResult
internal func ork_open_v2(
    _ f: UnsafePointer<CChar>?,
    _ h: UnsafeMutablePointer<ORKSQLite3?>?,
    _ flags: Int32,
    _ vfs: UnsafePointer<CChar>?) -> Int32
{
    return sqlite3_open_v2(f, h, flags, vfs)
}


@discardableResult
internal func ork_close_v2(_ h: ORKSQLite3?) -> Int32 {
    return sqlite3_close_v2(h)
}


@discardableResult
internal func ork_exec(
    _ h: ORKSQLite3?, _ s: UnsafePointer<CChar>?,
    _ cb: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
    _ arg: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
{
    return sqlite3_exec(h, s, cb, arg, err)
}


@discardableResult
internal func ork_key_v2(
    _ h: ORKSQLite3?, _ dbName: UnsafePointer<CChar>?,
    _ pKey: UnsafeRawPointer?, _ nKey: Int32) -> Int32
{
    return swiftsqlcipher_sqlite3_key_v2(h, dbName, pKey, nKey)
}


@discardableResult
internal func ork_prepare(
    _ h: ORKSQLite3?, _ sql: UnsafePointer<CChar>?,
    _ n: Int32,
    _ out: UnsafeMutablePointer<ORKStmt?>?,
    _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
{
    return sqlite3_prepare_v2(h, sql, n, out, tail)
}


@discardableResult
internal func ork_step(_ s: ORKStmt?) -> Int32 {
    return sqlite3_step(s)
}


@discardableResult
internal func ork_finalize(_ s: ORKStmt?) -> Int32 {
    return sqlite3_finalize(s)
}


@discardableResult
internal func ork_reset(_ s: ORKStmt?) -> Int32 {
    return sqlite3_reset(s)
}


@discardableResult
internal func ork_bind_text(
    _ s: ORKStmt?, _ idx: Int32,
    _ v: UnsafePointer<CChar>?,
    _ n: Int32,
    _ d: sqlite3_destructor_type?) -> Int32
{
    return sqlite3_bind_text(s, idx, v, n, d)
}


@discardableResult
internal func ork_bind_int64(
    _ s: ORKStmt?, _ idx: Int32, _ v: Int64) -> Int32
{
    return sqlite3_bind_int64(s, idx, v)
}


@discardableResult
internal func ork_bind_double(
    _ s: ORKStmt?, _ idx: Int32, _ v: Double) -> Int32
{
    return sqlite3_bind_double(s, idx, v)
}


@discardableResult
internal func ork_bind_null(_ s: ORKStmt?, _ idx: Int32) -> Int32 {
    return sqlite3_bind_null(s, idx)
}


@discardableResult
internal func ork_bind_blob(
    _ s: ORKStmt?, _ idx: Int32,
    _ v: UnsafeRawPointer?,
    _ n: Int32,
    _ d: sqlite3_destructor_type?) -> Int32
{
    return sqlite3_bind_blob(s, idx, v, n, d)
}

internal let ORK_SQLITE_TRANSIENT: sqlite3_destructor_type = unsafeBitCast(
    OpaquePointer(bitPattern: -1)!, to: sqlite3_destructor_type.self)

internal func ork_col_blob(_ s: ORKStmt?, _ c: Int32) -> Data? {
    guard let raw = sqlite3_column_blob(s, c) else { return nil }
    let count = Int(sqlite3_column_bytes(s, c))
    return Data(bytes: raw, count: count)
}


internal func ork_last_insert_rowid(_ h: ORKSQLite3?) -> Int64 {
    return sqlite3_last_insert_rowid(h)
}


internal func ork_col_text(_ s: ORKStmt?, _ c: Int32) -> UnsafePointer<UInt8>? {
    return sqlite3_column_text(s, c)
}


/// Row-count of the most recent successful INSERT/UPDATE/DELETE on
/// this connection. Needed by `RetentionManager` to log how many rows
/// each cascade step actually removed.
internal func ork_changes(_ h: ORKSQLite3?) -> Int32 {
    return sqlite3_changes(h)
}


internal func ork_col_int64(_ s: ORKStmt?, _ c: Int32) -> Int64 {
    return sqlite3_column_int64(s, c)
}


internal func ork_col_int(_ s: ORKStmt?, _ c: Int32) -> Int32 {
    return sqlite3_column_int(s, c)
}


internal func ork_col_double(_ s: ORKStmt?, _ c: Int32) -> Double {
    return sqlite3_column_double(s, c)
}


internal func ork_col_type(_ s: ORKStmt?, _ c: Int32) -> Int32 {
    return sqlite3_column_type(s, c)
}


internal func ork_errmsg(_ h: ORKSQLite3?) -> UnsafePointer<CChar>? {
    return sqlite3_errmsg(h)
}


internal func ork_column_count(_ s: ORKStmt?) -> Int32 {
    return sqlite3_column_count(s)
}


internal func ork_column_name(_ s: ORKStmt?, _ c: Int32) -> UnsafePointer<CChar>? {
    return sqlite3_column_name(s, c)
}

internal extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Date helpers (Rewind's stored ISO8601 format, no trailing Z)

internal enum ORKDate {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d).replacingOccurrences(of: "Z", with: "")
    }
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s + "Z")
            ?? { let g = ISO8601DateFormatter(); return g.date(from: s + "Z") }()
    }
}

// MARK: - Small statement helpers (shared)

internal enum ORKBind {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

internal func ork_bindString(_ stmt: ORKStmt?, _ idx: Int32, _ v: String) -> Int32 {
    return v.withCString { p in
        ork_bind_text(stmt, idx, p, Int32(strlen(p)), ORK_TRANSIENT)
    }
}

internal func ork_readString(_ stmt: ORKStmt?, _ col: Int32) -> String? {
    guard let raw = ork_col_text(stmt, col) else { return nil }
    return String(cString: raw)
}

internal func ork_bindAll(_ stmt: ORKStmt?, _ binds: [ORKBind]) {
    for (i, b) in binds.enumerated() {
        let idx = Int32(i + 1)
        switch b {
        case .text(let s):   _ = ork_bindString(stmt, idx, s)
        case .int(let n):    _ = ork_bind_int64(stmt, idx, n)
        case .double(let d): _ = ork_bind_double(stmt, idx, d)
        case .null:          _ = ork_bind_null(stmt, idx)
        }
    }
}
