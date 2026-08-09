// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Enumerates every running application AppKit knows about, applying the
// two portable filters `VisualElementContext.TryFastListApps` uses:
// `activationPolicy != .prohibited` and `processIdentifier > 0`.
//
// Everywhere's C# version has a third filter — `AXUIElement.FreshFocusedWindowOf(pid) is null`
// — which turns the list into "apps with at least one AX-addressable window".
// That gate belongs in the AX layer (see `Capture/FocusedWindowCapture.swift`);
// this capture is deliberately upstream of any AX round-trip so callers can
// see all launched apps (including ones with no window yet) and apply the
// window filter downstream.
//
// See `docs/ROADMAP/.impl-notes/phase5-runningapps-2026-07-23.md` for the
// alignment table.

import Foundation
import AppKit

/// Enumerates running applications on macOS.
///
/// Corresponds to Everywhere's `VisualElementContext.TryFastListApps`
/// (`src/Everywhere.Mac/Interop/VisualElementContext.cs:97-111`). Ordering
/// is whatever `NSWorkspace.shared.runningApplications` returns — AppKit
/// does not document a guaranteed order but the order is empirically
/// stable across quick successive calls. A new launch or termination
/// between two calls will reshuffle things; callers must NOT assume the
/// index of a given app is durable.
public enum RunningAppsCapture {

    /// Returns every running application AppKit reports, dropping the two
    /// entries Everywhere would have discarded at the capture boundary:
    ///   * `activationPolicy == .prohibited` (per
    ///     `VisualElementContext.cs:103`), and
    ///   * `processIdentifier <= 0` (per `VisualElementContext.cs:105`).
    ///
    /// The result is never `nil`; an empty array is theoretically possible
    /// on a machine with no running apps, but in practice this method
    /// always returns at least one entry (the caller's own process).
    public static func list() -> [RunningAppInfo] {
        let apps = NSWorkspace.shared.runningApplications
        var result: [RunningAppInfo] = []
        result.reserveCapacity(apps.count)
        for app in apps {
            // 1:1 with VisualElementContext.cs:103.
            if app.activationPolicy == .prohibited { continue }
            let pid = app.processIdentifier
            // 1:1 with VisualElementContext.cs:105. Also guards against the
            // documented -1 return for apps not yet fully launched.
            if pid <= 0 { continue }

            result.append(
                RunningAppInfo(
                    processId: pid,
                    bundleId: app.bundleIdentifier,
                    name: app.localizedName,
                    executableName: app.executableURL?.lastPathComponent,
                    activationPolicy: FrontmostActivationPolicy(app.activationPolicy),
                    isHidden: app.isHidden,
                    isFinishedLaunching: app.isFinishedLaunching,
                    ownsMenuBar: app.ownsMenuBar,
                    launchDate: app.launchDate
                )
            )
        }
        CaptureLog.log(
            "openclicky.running_apps.list",
            [
                "raw_count": "\(apps.count)",
                "kept_count": "\(result.count)"
            ]
        )
        return result
    }
}
