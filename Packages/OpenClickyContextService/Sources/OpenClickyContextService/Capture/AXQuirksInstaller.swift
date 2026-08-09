// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Interop/AXAttributeConstants.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mac/Interop/VisualElementContext.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//                        src/Everywhere.Mcp/Tools/AppResolver.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Installs the two private AXUIElement boolean attributes that force
// Chromium / Electron / SwiftUI apps into "full accessibility" mode:
//
//   * `AXManualAccessibility`   — Electron apps refuse to serve AX
//                                 requests until this is `true`. See
//                                 `VisualElementContext.TextSelection.cs`
//                                 L264: "Electron Apps: set
//                                 AXManualAccessibility to true to
//                                 enable AXAPI".
//   * `AXEnhancedUserInterface` — Chromium/Chrome/Edge refuse to serve
//                                 AX requests until this is `true`. See
//                                 `VisualElementContext.TextSelection.cs`
//                                 L262-263.
//
// Everywhere fires BOTH attributes unconditionally on every AX-consuming
// path (`VisualElementContext.cs:127-128`) rather than branching on
// bundle_id — the two flips are cheap for apps that don't need them and
// the alternative (a per-bundle table that has to keep up with every
// Electron/Chromium fork) is a maintenance rathole. This port keeps the
// same "both, always" contract.
//
// Public API (matches the task spec):
//
//   * `AXQuirksInstaller.installIfNeeded(pid:)` — idempotent per-pid
//     installer. Fires both attributes exactly once per (pid, process
//     lifetime); subsequent calls are a lock-guarded no-op.
//   * `AXQuirksInstaller.setBoolAttribute(pid:attribute:value:)` — the
//     underlying primitive. 1:1 with Everywhere's
//     `SetAppBoolAttribute` except for the error model (see below).
//
// Deviations from Everywhere (see
// `.impl-notes/phase5-axquirks-2026-07-22.md` for the full table):
//   * Throws `AXQuirksError` on failure instead of returning `bool`
//     (task spec HARD constraint).
//   * `.noValue` is treated as success alongside `.success` —
//     `AXUIElementSetAttributeValue` returns `.noValue` when the target
//     application does not currently advertise the attribute; the flip
//     still lands and the next AX walk observes the upgraded tree.
//     Everywhere's C# path only tolerates `.success`; the widening here
//     avoids spurious throws on the first-time flip for apps that
//     don't preload the private attribute names.
//   * Idempotency requires BOTH attributes to land. A partial-success
//     (only one attribute took) is NOT cached, mirroring the spec's
//     "both, then insert" order in the file header. Everywhere caches
//     on `manualOk || enhancedOk`; here the stricter "and" contract
//     matches the throw-on-first-failure semantic — a partial install
//     is treated as a full failure and can be retried on the next
//     caller invocation.
//   * The 1500 ms bounded-wait wrapper Everywhere puts around this call
//     (see `AppResolver.EnsureA11yEnabledOnce`, comment L31-42) is NOT
//     in this installer. It lives at the CALLER level — the installer
//     is a synchronous, best-effort primitive, and any UI-thread caller
//     that can't tolerate the first-time 30s subsystem rebuild must
//     wrap the call in its own `Task { try? ... }` + timeout, exactly
//     the way Everywhere does.
//
// This file uses ONLY `Foundation` + `ApplicationServices` — no AppKit,
// no CoreServices — so it is `swift test`-safe on runners that lack a
// WindowServer session.

import Foundation
import ApplicationServices
import CoreFoundation

// MARK: - Error type

/// Thrown by `AXQuirksInstaller` on any non-success AX result path.
///
/// Modeled as a nested enum rather than a package-wide error type
/// because the installer is the only surface in Layer 0 that returns an
/// `AXError` to the caller — sibling captures (FinderSelection,
/// SelectedText, ...) collapse AX failures to `nil` at the capture
/// boundary. See `.impl-notes/phase5-axquirks-2026-07-22.md`.
public enum AXQuirksError: Error, Equatable, Sendable {

    /// pid was `<= 0`. Everywhere returns `bool false` for this case
    /// (`AXUIElement.cs:1188`); the port promotes it to a thrown error
    /// so callers can distinguish "invalid input" from "AX call
    /// failed".
    case invalidPid(Int32)

    /// `AXUIElementSetAttributeValue` returned an AXError other than
    /// `.success` or `.noValue`. Carries the raw status so callers can
    /// diagnose (e.g. `.apiDisabled` == no Accessibility consent,
    /// `.notImplemented` == the target app doesn't participate in AX
    /// at all, `.cannotComplete` == the private attribute is not
    /// installable on this app).
    ///
    /// `Int32` payload matches `AXError`'s underlying storage.
    case setAttributeFailed(status: Int32)

    // MARK: - Equatable
    public static func == (lhs: AXQuirksError, rhs: AXQuirksError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidPid(let a), .invalidPid(let b)):
            return a == b
        case (.setAttributeFailed(let a), .setAttributeFailed(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Installer

/// Installs Everywhere's two private-attribute accessibility quirks on
/// a target process, with per-pid memoisation. See file header for the
/// full contract.
public enum AXQuirksInstaller {

    // MARK: - Attribute names
    //
    // Byte-identical to `AXAttributeConstants.cs:30-31`. These are the
    // documented private attribute names Chromium and Electron both
    // read on startup — do NOT change these strings without updating
    // Everywhere in lockstep.

    /// `AXManualAccessibility` — Electron gate. See file header.
    public static let manualAccessibility: String = "AXManualAccessibility"

    /// `AXEnhancedUserInterface` — Chromium gate. See file header.
    public static let enhancedUserInterface: String = "AXEnhancedUserInterface"

    // MARK: - Memoisation state
    //
    // Matches Everywhere's `ConcurrentDictionary<int, bool>` at
    // `AppResolver.cs:20`. Swift's `NSLock` provides the same
    // "atomic try-insert; skip if present" guarantee at trivial cost.

    private static let lock = NSLock()

    /// pids that have already had both attributes successfully
    /// installed. Only populated on success — a partial or failed
    /// install can be retried on the next call.
    private static var installedPids: Set<Int32> = []

    // MARK: - AX messaging timeout bootstrap
    //
    // 1:1 with Everywhere's static-ctor block at
    // `AXUIElement.cs:471-475`, which sets a 1s messaging timeout on
    // the SystemWide handle to bound the AX default of 6s. Everywhere
    // fires this ONCE globally (not per-app). Openclicky captures that
    // one-shot semantic with a Swift `dispatch_once` equivalent
    // — the first call from anywhere in the package triggers the
    // install, subsequent calls are no-ops.
    //
    // Kept in this file so that the same seam owns both the per-pid
    // quirks (Manual / Enhanced) and the global timeout tweak. All
    // capture files that touch AX call `ensureAXBootstrap()` at
    // module load or first use (or transitively via
    // `installIfNeeded`).
    private static let axBootstrap: Void = {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 1.0)
        CaptureLog.log(
            "openclicky.ax.system_wide_timeout_set",
            ["timeout_s": "1.0"]
        )
    }()

    /// Idempotent global bootstrap. Callers that touch AX outside the
    /// per-pid quirk path (e.g. `SemanticExtractor.focused`,
    /// `ElementUnderCursorCapture.capture`) invoke this to guarantee
    /// the SystemWide messaging timeout has been narrowed to 1s
    /// before their first AX call. Cheap after the first invocation
    /// (accessing a `let` initialized closure is one atomic load).
    public static func ensureAXBootstrap() {
        _ = axBootstrap
    }

    // MARK: - Public API

    /// Install both quirks (`AXManualAccessibility`,
    /// `AXEnhancedUserInterface`) on the AX application element for
    /// `pid`. Idempotent per pid.
    ///
    /// Behaviour:
    ///   * `pid <= 0` -> throws `AXQuirksError.invalidPid(pid)`.
    ///   * pid already in the installed set -> returns immediately,
    ///     no AX call fires.
    ///   * Fires `AXManualAccessibility` FIRST, then
    ///     `AXEnhancedUserInterface`. Order matches
    ///     `VisualElementContext.cs:127-128`. If the first call
    ///     throws, the second is NOT attempted and the pid is NOT
    ///     cached — the caller can retry.
    ///   * On dual success, the pid is inserted into the cache. Any
    ///     subsequent call is a no-op.
    ///
    /// Blocking-call warning (verbatim from Everywhere,
    /// `AppResolver.cs:31-42`): the underlying
    /// `AXUIElementSetAttributeValue` call is SYNCHRONOUS. On
    /// Notes/Finder/Electron the FIRST invocation can take 30+ seconds
    /// while the target app's AX subsystem is rebuilt. This installer
    /// does NOT wrap the call in a timeout — that policy lives at the
    /// caller.
    public static func installIfNeeded(pid: Int32) throws {
        guard pid > 0 else {
            throw AXQuirksError.invalidPid(pid)
        }

        // Bound the SystemWide AX messaging timeout to 1s on first
        // touch. Mirrors Everywhere's static-ctor at AXUIElement.cs:471-475.
        ensureAXBootstrap()

        // Fast-path cache check under lock. Mirrors Everywhere's
        // `if (!_a11yEnabledPids.TryAdd(pid, true)) return;` at
        // `AppResolver.cs:25-28` — but we split the check from the
        // insert so a failing install doesn't poison the cache.
        lock.lock()
        let alreadyInstalled = installedPids.contains(pid)
        lock.unlock()
        if alreadyInstalled {
            return
        }

        // Order matches VisualElementContext.cs L127-128:
        //   manualOk   = SetAppBoolAttribute(pid, "AXManualAccessibility",  true);
        //   enhancedOk = SetAppBoolAttribute(pid, "AXEnhancedUserInterface", true);
        //
        // Everywhere returns `manualOk || enhancedOk`; the throwing
        // contract here requires BOTH to land (see file header
        // "Deviations"). The caller can retry a partial failure.
        try setBoolAttribute(
            pid: pid,
            attribute: manualAccessibility,
            value: true
        )
        try setBoolAttribute(
            pid: pid,
            attribute: enhancedUserInterface,
            value: true
        )

        // Both attributes landed — cache the pid. This is the only
        // place `installedPids` grows.
        lock.lock()
        installedPids.insert(pid)
        lock.unlock()

        CaptureLog.log(
            "openclicky.ax.quirks_installed",
            ["pid": "\(pid)"]
        )
    }

    /// Fetch a snapshot of the currently-installed pids. Test-facing
    /// convenience — production callers should treat the installer as
    /// a black box.
    ///
    /// Returned as a copied `Set<Int32>` so the caller can iterate
    /// without holding the lock.
    static func installedPidsSnapshot() -> Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return installedPids
    }

    /// Clear the memoisation cache. Test-facing hook only — production
    /// code has no reason to un-cache, because the underlying AX flip
    /// is not reversible for the process lifetime.
    static func resetInstalledPidsForTesting() {
        lock.lock()
        defer { lock.unlock() }
        installedPids.removeAll()
    }

    /// 1:1 port of `AXUIElement.SetAppBoolAttribute` at
    /// `AXUIElement.cs:1186-1203`, with the error-model deviation
    /// documented in the file header.
    ///
    /// Uses the CoreFoundation `kCFBooleanTrue` / `kCFBooleanFalse`
    /// singletons — NOT `NSNumber(value:)`. The file-level comment at
    /// `AXUIElement.cs:1181-1184` explains why:
    ///
    ///   > AXUIElementSetAttributeValue rejects NSNumber private
    ///   > AXManualAccessibility / AXEnhancedUserInterface attributes -
    ///   > only CFBoolean singleton is accepted (returns .success).
    ///
    /// Ownership: `AXUIElementCreateApplication` returns a
    /// `+1`-retained CFType. Swift's implicit CFType bridging releases
    /// it when `app` goes out of scope, so we do NOT need an explicit
    /// `CFRelease` (Everywhere's `finally { CFInterop.CFRelease(...) }`
    /// at L1201 is required only because C# does not ARC these).
    public static func setBoolAttribute(
        pid: Int32,
        attribute: String,
        value: Bool
    ) throws {
        guard pid > 0 else {
            throw AXQuirksError.invalidPid(pid)
        }

        let app = AXUIElementCreateApplication(pid)
        let cfBool: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        let status = AXUIElementSetAttributeValue(
            app,
            attribute as CFString,
            cfBool
        )

        CaptureLog.log(
            "openclicky.ax.quirks_set_attribute",
            direction: (status == .success || status == .noValue) ? "internal" : "error",
            [
                "pid": "\(pid)",
                "attr": attribute,
                "value": value ? "true" : "false",
                "ax_error": "\(status.rawValue)"
            ]
        )

        // Success gate matches the task spec: `.success` is the
        // Everywhere-exact match; `.noValue` is the widened
        // success-alias that avoids spurious throws when the target
        // app has not preloaded the private attribute name. Any other
        // AXError is a real failure.
        if status != .success && status != .noValue {
            throw AXQuirksError.setAttributeFailed(status: status.rawValue)
        }
    }
}
