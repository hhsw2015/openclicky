// Ported from Everywhere: src/Everywhere.Mac/Interop/PermissionHelper.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Passive, check-only preflight for the five macOS TCC surfaces the
// openclicky ContextService touches:
//
//   * Accessibility - AXIsProcessTrusted()
//   * ScreenRecording - CGPreflightScreenCaptureAccess()
//   * InputMonitoring - IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
//   * Microphone - AVCaptureDevice.authorizationStatus(for: .audio)
//   * Automation (per target bundle id) -
//       AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)
//
// Deviations from Everywhere's C# source (documented in
// docs/ROADMAP/.impl-notes/phase5-permission-2026-07-22.md):
//
//   1. Accessibility uses `AXIsProcessTrusted()` (no options
//      dictionary) instead of `AXIsProcessTrustedWithOptions` with
//      `AXTrustedCheckOptionPrompt = true`. The options variant is a
//      prompt-triggering call; the no-options variant is the passive
//      check we want here. Everywhere's helper is bootstrap-side (it
//      wants to *demand* the grant); openclicky wants a preflight that
//      can decorate UI without touching TCC.
//   2. Screen recording uses `CGPreflightScreenCaptureAccess()` instead
//      of a real 1x1 `CGWindowListCreateImage` capture. Preflight is
//      the documented "check without prompting" path introduced in
//      macOS 10.15.
//
// Everywhere's `PermissionHelper.cs` only models Accessibility and
// ScreenRecording; the other three permissions live in adjacent
// subsystems in that codebase (voice input, hotkey tap, AppleScript
// runner). openclicky consolidates them here so ContextService callers
// have one entry point.

import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid
import CoreGraphics

/// Passive, non-prompting preflight for macOS TCC permissions used by
/// ContextService captures. Every method is safe to call any number of
/// times, holds no state, and never triggers the system's "Please grant
/// X" prompt.
public enum PermissionPreflight {

    /// Query the current status of one macOS permission surface.
    ///
    /// - Parameters:
    ///   - kind: Which permission to inspect. See `PermissionKind` for
    ///     the mapping to the backing macOS API.
    ///   - automationTargetBundleId: Only consulted when
    ///     `kind == .automation`. Must be the bundle identifier of the
    ///     app AppleEvents will address (for example
    ///     `"com.apple.finder"`). Passing `nil` for `.automation`
    ///     returns `.unknown` because the underlying
    ///     `AEDeterminePermissionToAutomateTarget` API requires a
    ///     target AEDesc; there is no "any target" query.
    /// - Returns: A `PermissionStatus`. See its documentation for the
    ///   full state matrix. For bool-only APIs
    ///   (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`),
    ///   only `.granted` and `.denied` are reachable.
    public static func check(
        _ kind: PermissionKind,
        automationTargetBundleId: String? = nil
    ) -> PermissionStatus {
        let status: PermissionStatus
        switch kind {
        case .accessibility:
            status = checkAccessibility()
        case .screenRecording:
            status = checkScreenRecording()
        case .inputMonitoring:
            status = checkInputMonitoring()
        case .microphone:
            status = checkMicrophone()
        case .automation:
            status = checkAutomation(targetBundleId: automationTargetBundleId)
        }
        CaptureLog.log(
            "openclicky.permission.check",
            [
                "kind": kind.rawValue,
                "status": String(describing: status),
                "target_bundle": automationTargetBundleId ?? ""
            ]
        )
        return status
    }

    // MARK: - Individual checks

    /// Accessibility (AX) trust for the current process.
    ///
    /// Backed by `AXIsProcessTrusted()`. Everywhere calls the
    /// prompt-triggering `AXIsProcessTrustedWithOptions` variant during
    /// bootstrap; we use the passive variant so a preflight never
    /// forces a permission dialog.
    private static func checkAccessibility() -> PermissionStatus {
        return AXIsProcessTrusted() ? .granted : .denied
    }

    /// Screen recording preflight.
    ///
    /// `CGPreflightScreenCaptureAccess()` returns `true` iff the app is
    /// currently authorised for screen capture. Unlike
    /// `CGRequestScreenCaptureAccess()` (which prompts) and unlike
    /// Everywhere's live 1x1 `CGWindowListCreateImage` grab (which
    /// silently returns an all-black image when unauthorized while
    /// still counting as an access attempt), preflight is side-effect
    /// free.
    private static func checkScreenRecording() -> PermissionStatus {
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Input Monitoring (Listen Event) preflight via IOKit HID.
    ///
    /// Backed by `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`. The
    /// underlying enum has three states: granted / denied / unknown
    /// (the last means "the user has not been asked yet").
    private static func checkInputMonitoring() -> PermissionStatus {
        let raw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch raw {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .notDetermined
        default:
            return .unknown
        }
    }

    /// Microphone (audio capture) authorisation status.
    ///
    /// Backed by `AVCaptureDevice.authorizationStatus(for: .audio)`.
    /// This is a pure getter; it never prompts. `requestAccess(...)`
    /// is the prompting call, which we deliberately never invoke.
    private static func checkMicrophone() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    /// Automation (AppleEvents) permission to talk to a specific
    /// target app.
    ///
    /// Backed by `AEDeterminePermissionToAutomateTarget(_, _, _,
    /// askUserIfNeeded: false)`. The `askUserIfNeeded: false` flag is
    /// exactly the toggle that keeps this call passive.
    ///
    /// Return values (see `<CoreServices/AE/AEHelpers.h>` /
    /// `AppleEvents.h`):
    ///   * `noErr` (0)                             -> `.granted`
    ///   * `errAEEventNotPermitted` (-1743)        -> `.denied`
    ///   * `errAEEventWouldRequireUserConsent`
    ///     (-1744) or `procNotFound` (-600)        -> `.notDetermined`
    ///   * anything else                           -> `.unknown`
    ///
    /// Passing a nil / empty bundle id returns `.unknown`; there is no
    /// "any target" form of this API.
    private static func checkAutomation(targetBundleId: String?) -> PermissionStatus {
        guard let bundleId = targetBundleId, !bundleId.isEmpty else {
            return .unknown
        }

        // Build an AEAddressDesc addressing the target by bundle id.
        // `typeApplicationBundleID` was introduced with the same API
        // family (macOS 10.14+).
        var targetDesc = AEAddressDesc()
        let bundleData = Data(bundleId.utf8)
        let createErr: OSStatus = bundleData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            // AECreateDesc returns OSErr (Int16); widen to OSStatus.
            let e = AECreateDesc(
                DescType(typeApplicationBundleID),
                base,
                bundleData.count,
                &targetDesc
            )
            return OSStatus(e)
        }
        if createErr != noErr {
            return .unknown
        }
        defer { AEDisposeDesc(&targetDesc) }

        let status = AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            DescType(typeWildCard),
            DescType(typeWildCard),
            false // askUserIfNeeded: never prompt from a preflight.
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent),
             OSStatus(procNotFound):
            return .notDetermined
        default:
            return .unknown
        }
    }
}
