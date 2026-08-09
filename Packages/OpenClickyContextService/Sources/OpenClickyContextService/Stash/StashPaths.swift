// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/StashPaths.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Single source of truth for the on-disk stash path the SnapshotContext
// hotkey writes and the openclicky-context-hook binary reads.
// openclicky is macOS-only; the Windows/Linux branches from `StashPaths.cs`
// are intentionally dropped.

import Foundation

public enum OpenClickyStashPaths {
    public static let fileName = "context-stash.json"

    public static func contextStashDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenClicky", isDirectory: true)
    }

    public static func contextStash() -> URL {
        contextStashDirectory().appendingPathComponent(fileName, isDirectory: false)
    }
}
