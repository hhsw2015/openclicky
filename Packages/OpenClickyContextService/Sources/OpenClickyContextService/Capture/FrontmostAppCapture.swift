// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/AppKey.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Mcp/MacFocusBackend.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Captures info about the currently frontmost application on macOS.
// Two responsibilities, cleanly separated:
//   1. `AppKeyResolver.fromProcessId(_:)` — 1:1 semantic port of
//      Everywhere's `AppKey.FromProcessId(int)`. String output, same
//      fallback chain, so openclicky snapshots share a stable identifier
//      space with Everywhere.
//   2. `FrontmostAppCapture.capture()` — resolves the frontmost
//      NSRunningApplication and packages it into `FrontmostAppInfo`.
//      This is openclicky's richer surface; Everywhere itself reads the
//      equivalent NSRunningApplication fields ad-hoc in
//      `VisualElementContext.cs` but never bundles them into a struct.
//
// Intentional Swift-side deviation from Everywhere:
//   - Everywhere's `AppKey.FromProcessId` uses `System.Diagnostics.Process`,
//     which returns the executable filename without extension. On macOS
//     via Swift the closest analog is
//     `NSRunningApplication.executableURL.lastPathComponent`. Both yield
//     e.g. "Finder"; the port preserves the `.lowercased()` step.
//   - We never filter Prohibited-activation-policy apps at THIS layer
//     (that filter belongs in RunningAppsCapture). If NSWorkspace names
//     a Prohibited app as frontmost — theoretically possible for the
//     openclicky menu-bar app itself during a UI transition — we still
//     report it, tagged accordingly via `activationPolicy`.

import Foundation
import AppKit

/// 1:1 Swift port of Everywhere's `AppKey` static helpers
/// (`src/Everywhere.Mcp/Snapshot/AppKey.cs`).
public enum AppKeyResolver {

    /// Ported from `AppKey.FromProcessId` (AppKey.cs:12-29).
    ///
    /// Contract (matches C# behavior exactly):
    ///   * `pid <= 0`                    -> `"unknown"`
    ///   * process resolvable + name nonempty -> `name.lowercased()`
    ///   * process resolvable + name empty   -> `"\(pid)"`
    ///   * any lookup failure            -> `"\(pid)"`
    ///
    /// Naming detail: Everywhere reads .NET's `Process.ProcessName`, which
    /// on macOS is the executable filename minus extension (typically
    /// identical to `NSRunningApplication.executableURL.lastPathComponent`
    /// for GUI apps whose executable has no extension).
    public static func fromProcessId(_ processId: Int32) -> String {
        if processId <= 0 {
            return "unknown"
        }
        guard let app = NSRunningApplication(processIdentifier: processId),
              let execName = app.executableURL?.lastPathComponent,
              !execName.isEmpty
        else {
            return "\(processId)"
        }
        return execName.lowercased()
    }

    /// Ported from `AppKey.MatchesQuery` (AppKey.cs:31-40).
    /// Case-insensitive equality OR case-insensitive substring match.
    /// Blank / whitespace-only query -> `false`.
    public static func matchesQuery(_ appKey: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        if appKey.caseInsensitiveCompare(query) == .orderedSame {
            return true
        }
        return appKey.range(of: query, options: .caseInsensitive) != nil
    }
}

/// Captures the currently frontmost application on macOS.
///
/// Wraps `NSWorkspace.shared.frontmostApplication` — the canonical AppKit
/// API for this on macOS and the same source Everywhere reads (indirectly)
/// via `NSWorkspace.SharedWorkspace.RunningApplications` throughout
/// `VisualElementContext.cs`.
public enum FrontmostAppCapture {

    /// Returns a snapshot of the frontmost application, or `nil` if
    /// AppKit currently reports no frontmost app (rare — happens during
    /// login/logout transitions or between app-switch events).
    public static func capture() -> FrontmostAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            CaptureLog.log("openclicky.frontmost.miss", direction: "error")
            return nil
        }
        let pid = app.processIdentifier
        if pid <= 0 {
            // Defensive: NSRunningApplication.processIdentifier is
            // documented to return -1 for apps not yet fully launched.
            CaptureLog.log("openclicky.frontmost.bad_pid",
                           direction: "error",
                           ["pid": "\(pid)"])
            return nil
        }
        let info = FrontmostAppInfo(
            processId: pid,
            bundleId: app.bundleIdentifier,
            localizedName: app.localizedName,
            executablePath: app.executableURL?.path,
            appKey: AppKeyResolver.fromProcessId(pid),
            activationPolicy: FrontmostActivationPolicy(app.activationPolicy)
        )
        CaptureLog.log(
            "openclicky.frontmost.capture",
            [
                "pid": "\(pid)",
                "bundle_id": info.bundleId ?? "",
                "app_key": info.appKey
            ]
        )
        return info
    }
}
