// Storage.swift — the on-disk vault descriptor. Public because callers
// need to point Reader/Writer at Rewind's vault, OpenRewind's vault, or
// an arbitrary path (tests, imports, backups).

import Foundation

/// Locations OpenRewindKit uses on disk. Defaults to the OpenRewind vault
/// under `~/Library/Application Support/OpenRewind`; use
/// `.rewindDefault` to point at a running Rewind.app install.
public struct OpenRewindStorage: Sendable {
    public let root: URL
    public let dbEncrypted: URL
    public let chunksDir: URL

    public init(root: URL) {
        self.root = root
        self.dbEncrypted = root.appendingPathComponent("db-enc.sqlite3")
        self.chunksDir = root.appendingPathComponent("chunks")
    }

    public init(root: URL, dbEncrypted: URL, chunksDir: URL) {
        self.root = root
        self.dbEncrypted = dbEncrypted
        self.chunksDir = chunksDir
    }

    /// The default OpenRewind vault: `~/Library/Application Support/OpenRewind/`.
    public static let openRewindDefault: OpenRewindStorage = {
        let root = defaultVaultRoot()
        return OpenRewindStorage(root: root)
    }()

    /// FIX(spm-embed-2026-07-29): host override for the vault path.
    /// Standalone app uses "OpenRewind"; embedded hosts (OpenClicky
    /// etc.) call `OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"`
    /// at launch before any Reader/Writer opens. Every hardcoded
    /// `~/Library/Application Support/OpenRewind` path in the tree
    /// routes through `defaultVaultRoot()` so setting this once
    /// re-points them all.
    ///
    /// Access must happen before `openRewindDefault` is first read
    /// because that constant is lazy. Setting later has no effect on
    /// `.openRewindDefault` but WILL affect ad-hoc `defaultVaultRoot()`
    /// callers (Browser log path, flag files, playhead broadcast).
    public static var defaultAppSupportName: String = "OpenRewind"

    /// Compose the default vault path from the current
    /// `defaultAppSupportName`. Every call site that used to hardcode
    /// `Library/Application Support/OpenRewind` should route here.
    public static func defaultVaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(defaultAppSupportName)")
    }

    /// Rewind.app's own vault location (for migration scenarios).
    public static let rewindDefault: OpenRewindStorage = {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.memoryvault.MemoryVault")
        return OpenRewindStorage(root: root)
    }()

    /// Rewind's shipped SQLCipher passphrase. Kept `internal` so it
    /// doesn't become a public SPM export or land in code search.
    /// Callers who legitimately need it (MCP, Browser rewind mode)
    /// live in this package.
    internal static let rewindPassphrase =
        "soiZ58XZJhdka55hLUp18yOtTUTDXz7Diu7Z4JzuwhRwGG13N6Z9RTVU1fGiKkuF"

    /// FIX(spm-port-2026-07-29): consent-gated public accessor so SPM
    /// hosts on the same machine as Rewind.app can open Rewind's vault
    /// without duplicating the string.
    public enum RewindPassphraseConsent {
        /// I understand this opens Rewind.app's local vault; user
        /// has consented to interop.
        case userAcknowledgedInterop
    }
    public static func rewindInteropPassphrase(
        _ consent: RewindPassphraseConsent) -> String {
        switch consent {
        case .userAcknowledgedInterop:
            return rewindPassphrase
        }
    }
}

/// FIX(spm-embed-2026-07-29): host-configurable knobs the Browser + MCP
/// use to compose URLs and bundle-scoped identifiers. Standalone app
/// keeps the defaults; embedded hosts (OpenClicky, etc.) set these once
/// at launch:
///
/// ```swift
/// RewindConfig.deepLinkScheme = "openclicky"
/// RewindConfig.bundleIDPrefix = "com.openclicky"
/// OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"
/// ```
public enum RewindConfig {
    /// URL scheme for deep-link citations. Default `openrewind`.
    public static var deepLinkScheme: String = "openrewind"

    /// Bundle-ID prefix for self-exclusion + IPC channel names.
    public static var bundleIDPrefix: String = "com.openrewind"
}

/// Errors surfaced by Reader/Writer/Compressor.
public enum OpenRewindError: Error, CustomStringConvertible {
    case openFailed(String)
    case keyRejected
    case queryFailed(String)
    case chunkMissing(String)
    case decodeFailed(String)
    case schemaInvalid(missingTables: [String], missingColumns: [String], notFTS5: [String])
    case notImplemented(String)

    public var description: String {
        switch self {
        case .openFailed(let s):   return "open failed: \(s)"
        case .keyRejected:         return "SQLCipher key was rejected"
        case .queryFailed(let s):  return "query failed: \(s)"
        case .chunkMissing(let s): return "chunk missing on disk: \(s)"
        case .decodeFailed(let s): return "frame decode failed: \(s)"
        case .schemaInvalid(let t, let c, let f):
            return "schema invalid — missing tables=\(t) missing columns=\(c) not FTS5=\(f)"
        case .notImplemented(let s): return "not implemented: \(s)"
        }
    }
}
