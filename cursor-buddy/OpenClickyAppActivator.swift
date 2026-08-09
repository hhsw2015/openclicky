// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacAppActivator.cs
// + src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs:509-609 (TryFireLaunchPhrase)
// @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Raise a configured "agent app" to the foreground after openclicky
// writes a context stash, and — if the user configured a launch phrase
// — type it plus Return into that app so the receiving Claude Code /
// cmux surface immediately acts on the freshly-written stash.
//
// Two responsibilities:
//
// 1. `activate(bundleId)` / `isFrontmost(bundleId)` — thin wrappers on
//    NSWorkspace. Everywhere goes through raw libobjc P/Invoke because
//    it runs from C#. In Swift we call NSWorkspace directly. Semantics
//    preserved: match on bundle id OR localized name OR executable
//    basename (case-insensitive exact), short-circuit success when the
//    target is already frontmost.
//
// 2. `fireLaunchPhrase(bundleId:phrase:)` — the settle-loop + injection
//    pipeline copied byte-for-byte from `TryFireLaunchPhrase`:
//    16 × 150ms settle ticks, 2 consecutive frontmost ticks required,
//    focus-steal recheck between TypeText and Return, `_phraseInFlight`
//    interlock so rapid double-fires don't stack into "take a look
//    take a look" duplicate injection.
//
// Kept as a standalone singleton (not folded into the stash writer)
// so LinkRect fallback UI can raise the agent app on "picker found
// zero links" without going through a full snapshot write.

import AppKit
import ApplicationServices
import Foundation
import OpenClickyContextService

/// See file header.
///
/// Marked `Sendable` because the singleton is called from background
/// Tasks (fire-and-forget launch phrase). NSWorkspace access from a
/// non-main thread is safe for the read-only queries we use
/// (`frontmostApplication`, `runningApplications`) — AppKit
/// documents these as thread-safe. Activation calls in `activate(_:)`
/// touch NSRunningApplication.activate(options:), which AppKit's
/// header marks safe from any thread.
public final class OpenClickyAppActivator: @unchecked Sendable {

    /// Global instance. `ContextStashWriter` and the LinkRect UI both
    /// go through this singleton so the `_phraseInFlight` interlock
    /// covers every fire path (not just one).
    public static let shared = OpenClickyAppActivator()

    /// Guard against concurrent settle-loop + TypeText fires. Everywhere
    /// uses `Interlocked.CompareExchange`; Swift equivalent is
    /// `NSLock` around a plain Bool. See
    /// `ContextStashWriter.cs:509` for the exact rationale ("take a
    /// looktake a look" duplicate injection when two hotkey paths
    /// fire in quick succession).
    private let phraseLock = NSLock()
    private var phraseInFlight = false

    /// Everywhere primes NSWorkspace at DI time because LSUIElement
    /// apps don't always have AppKit spun up before the first
    /// SnapshotContext press (MacAppActivator.cs:28-53). Openclicky
    /// already has AppKit alive by the time this file is loaded
    /// (menu-bar app, UI initialised at launch), but preserving the
    /// warm-up is cheap insurance for the very first fire.
    private init() {
        _ = NSWorkspace.shared.runningApplications
        _ = NSWorkspace.shared.frontmostApplication
    }

    /// macOS supports frontmost detection via NSWorkspace, so
    /// `TryFireLaunchPhrase` never falls through the
    /// "activator lacks frontmost detection" early-return (see
    /// ContextStashWriter.cs:513-518).
    public var supportsFrontmostDetection: Bool { true }

    /// Ported from `MacAppActivator.Activate` (MacAppActivator.cs:58).
    ///
    /// Match `appIdentifier` against the frontmost app first (returns
    /// true as a no-op if already there — matches C# short-circuit at
    /// :79-81 which avoids the noisy focus-blink). Otherwise walk
    /// `runningApplications` and activate the first entry whose
    /// bundle id, localized name, or executable basename matches
    /// case-insensitively.
    @discardableResult
    public func activate(_ appIdentifier: String) -> Bool {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           Self.matches(frontmost, needle: trimmed) {
            HeyClickyLog.log(
                "openclicky.app_activator.attempt",
                lane: "system",
                [
                    "target": trimmed,
                    "target_bundle": frontmost.bundleIdentifier ?? "?",
                    "target_pid": String(frontmost.processIdentifier),
                    "already_frontmost": "true",
                ]
            )
            return true
        }

        for app in NSWorkspace.shared.runningApplications where Self.matches(app, needle: trimmed) {
            HeyClickyLog.log(
                "openclicky.app_activator.attempt",
                lane: "system",
                [
                    "target": trimmed,
                    "target_bundle": app.bundleIdentifier ?? "?",
                    "target_pid": String(app.processIdentifier),
                    "already_frontmost": "false",
                ]
            )
            // Both flags match Everywhere `MacAppActivator.cs:102`
            // (`ActivateAllWindows | ActivateIgnoringOtherApps`). LSUIElement
            // (menu-bar) apps do NOT inherit implicit ignore-other-apps
            // semantics from `.activate(options:)` alone, so passing the
            // deprecated `.activateIgnoringOtherApps` flag is required to
            // win a focus race against a self-reactivating browser (Arc /
            // Firefox with global hotkeys).
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            HeyClickyLog.log(
                "openclicky.launch_phrase.nsworkspace_activate",
                lane: "system",
                direction: "internal",
                [
                    "target": trimmed,
                    "target_bundle": app.bundleIdentifier ?? "?",
                    "target_name": app.localizedName ?? "?",
                    "target_pid": String(app.processIdentifier),
                ]
            )

            // Follow-up: Carbon SetFrontProcessWithOptions. NSRunningApplication
            // `.activate` is "polite" — focus-stealing apps (Arc, some
            // launchers) can win the race and pull frontmost back in the
            // window between the raise dispatch and the settle loop. The
            // deprecated Carbon path goes through the older WindowServer
            // route and reliably beats the polite API. See Everywhere
            // `MacAppActivator.cs:113-123, 264-296` for the exact pattern.
            // Best-effort: swallow any OSStatus and rely on the polite
            // activate above as a baseline.
            Self.tryCarbonSetFront(pid: app.processIdentifier)
            return true
        }

        return false
    }

    /// Carbon follow-up. Deprecated since macOS 10.9 but still exported
    /// + functional through the current SDK; Everywhere leans on the
    /// older WindowServer path here because it beats apps that race to
    /// self-reactivate. The settle loop's IsFrontmost recheck verifies
    /// the win either way, so a shim failure is harmless.
    ///
    /// `GetProcessForPID` + `SetFrontProcessWithOptions` are marked
    /// UNAVAILABLE (not just deprecated) in Swift's macOS SDK — Apple
    /// removed the Swift-visible shims. Everywhere calls them from C#
    /// via P/Invoke where the "unavailable" attribute doesn't apply
    /// (see `MacAppActivator.cs:113-123, 264-296`). On the Swift side
    /// we route through the Obj-C shim in
    /// `OpenClickyOverlayObjCBridge.m`, which can call the underlying
    /// C symbols directly. This is the fallback that actually wins on
    /// macOS 26 for LSUIElement callers whose
    /// `NSRunningApplication.activate(options:)` gets downgraded.
    private static func tryCarbonSetFront(pid: pid_t) {
        let ok = OpenClickyCarbonSetFrontProcess(pid)
        HeyClickyLog.log(
            "openclicky.launch_phrase.carbon_set_front",
            lane: "system",
            direction: "internal",
            [
                "pid": String(pid),
                "ok": ok ? "true" : "false",
            ]
        )
    }

    /// Ported from `MacAppActivator.IsFrontmost` (MacAppActivator.cs:148).
    ///
    /// True when NSWorkspace's `frontmostApplication` matches the
    /// supplied identifier by bundle id / localized name /
    /// executable basename (case-insensitive exact).
    public func isFrontmost(_ appIdentifier: String) -> Bool {
        let trimmed = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return Self.matches(frontmost, needle: trimmed)
    }

    // MARK: - LaunchPhrase pipeline

    /// Ported from `TryFireLaunchPhrase` (ContextStashWriter.cs:509-609).
    ///
    /// Byte-for-byte behaviour:
    /// - Skip empty phrase.
    /// - `_phraseInFlight` interlock: concurrent fires collapse to one.
    /// - Settle loop: up to 16 × 150ms ticks, requires 2 consecutive
    ///   frontmost readings before typing. Re-issues Activate each
    ///   tick.
    /// - Pre-TypeText frontmost recheck. On focus loss: log warn, do
    ///   nothing (phrase NOT typed → no leak into wrong app).
    /// - Pre-Return frontmost recheck. On focus loss: log warn,
    ///   withhold Return (keystrokes may have leaked but Return is
    ///   the dangerous submit event).
    ///
    /// Runs as an async fire-and-forget path so the caller (write
    /// pipeline) is not blocked. Everywhere uses `Task.Run` for the
    /// same reason.
    public func fireLaunchPhrase(bundleId: String, phrase: String) async {
        // Everywhere uses `string.IsNullOrWhiteSpace(phrase)` at
        // ContextStashWriter.cs:512. Swift `.isEmpty` returns false for
        // "  " / "\n", which would type whitespace and press Return —
        // firing a blank submit into the receiving agent. Actually trim
        // (previous port only aliased) so the variable name is honest.
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return }
        guard supportsFrontmostDetection else {
            HeyClickyLog.log(
                "openclicky.launch_phrase.no_frontmost_detection",
                lane: "system",
                direction: "error",
                ["bundle_id": bundleId]
            )
            return
        }

        // Interlock. NSLock protects the Bool; identical semantics to
        // `Interlocked.CompareExchange(ref _phraseInFlight, 1, 0)`.
        phraseLock.lock()
        if phraseInFlight {
            phraseLock.unlock()
            HeyClickyLog.log(
                "openclicky.launch_phrase.skipped_in_flight",
                lane: "system",
                ["bundle_id": bundleId]
            )
            return
        }
        phraseInFlight = true
        phraseLock.unlock()
        HeyClickyLog.log(
            "openclicky.stash.writer.phrase_in_flight_set",
            lane: "system",
            ["from_state": "false", "bundle_id": bundleId]
        )

        // defer ensures every exit path (early return, thrown error,
        // successful completion) clears the flag — mirrors the C#
        // `finally { Interlocked.Exchange(ref _phraseInFlight, 0) }`.
        defer {
            phraseLock.lock()
            phraseInFlight = false
            phraseLock.unlock()
            HeyClickyLog.log(
                "openclicky.stash.writer.phrase_in_flight_reset",
                lane: "system",
                ["reason": "defer_exit", "bundle_id": bundleId]
            )
        }

        // Settle loop. 16 × 150ms = 2.4s cap so a misconfigured agent
        // id doesn't hold the injection pipeline forever.
        var stable = 0
        var settled = false
        var ticksUsed = 0
        for i in 0..<Self.settleIterations {
            _ = activate(bundleId)
            try? await Task.sleep(nanoseconds: UInt64(Self.settleTickMillis) * 1_000_000)
            let front = isFrontmost(bundleId)
            ticksUsed = i + 1
            let actualBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            HeyClickyLog.log(
                "openclicky.app_activator.settle_tick",
                lane: "system",
                [
                    "i": String(i),
                    "actual_bundle": actualBundle,
                    "front_hit": front ? "true" : "false",
                    "stable": String(stable + (front ? 1 : 0)),
                ]
            )
            if front {
                stable += 1
                if stable >= Self.settleStableTicks {
                    settled = true
                    break
                }
            } else {
                stable = 0
            }
        }
        if settled {
            HeyClickyLog.log(
                "openclicky.app_activator.settle_ok",
                lane: "system",
                [
                    "bundle_id": bundleId,
                    "ticks_used": String(ticksUsed),
                ]
            )
        }
        if !settled {
            // Snapshot who's actually frontmost so we can tell whether
            // Openclicky itself is holding focus vs. a focus-stealing
            // launcher / browser. Emitted BEFORE the settle_failed event
            // so log tailers grep-order [snapshot, settle_failed] together.
            let front = NSWorkspace.shared.frontmostApplication
            HeyClickyLog.log(
                "openclicky.launch_phrase.settle_frontmost_snapshot",
                lane: "system",
                direction: "internal",
                [
                    "expected": bundleId,
                    "actual_bundle": front?.bundleIdentifier ?? "nil",
                    "actual_name": front?.localizedName ?? "nil",
                    "actual_pid": String(front?.processIdentifier ?? -1),
                ]
            )
            // Visible failure signal — surfaces in Settings → Logs so the
            // user sees WHY the launch phrase never fired. Previously the
            // only trace was an NSLog line that never reached the unified
            // log for LSUIElement apps in Release builds.
            HeyClickyLog.log(
                "openclicky.launch_phrase.settle_failed",
                lane: "system",
                direction: "error",
                [
                    "bundle_id": bundleId,
                    "settle_iterations": Self.settleIterations,
                    "settle_tick_millis": Self.settleTickMillis,
                ]
            )
            return
        }

        // Last-ditch pre-type recheck. Focus may have flipped during
        // the final 150ms tick between the settle confirmation and
        // now (browser handling a global hotkey on key-up etc.).
        if !isFrontmost(bundleId) {
            HeyClickyLog.log(
                "openclicky.launch_phrase.focus_stolen_pre_type",
                lane: "system",
                direction: "error",
                ["bundle_id": bundleId]
            )
            return
        }

        InputSimulator.typeText(trimmedPhrase)

        // Pre-Return recheck. TypeText is synchronous so by now most
        // keystrokes have already landed. If focus flipped mid-type,
        // some strokes may have leaked into the stealer — but the
        // Return is the dangerous submit event, so we withhold.
        if !isFrontmost(bundleId) {
            HeyClickyLog.log(
                "openclicky.launch_phrase.focus_stolen_pre_return",
                lane: "system",
                direction: "error",
                ["bundle_id": bundleId]
            )
            return
        }

        do {
            try InputSimulator.pressKey("Return")
            HeyClickyLog.log(
                "openclicky.launch_phrase.fired",
                lane: "system",
                [
                    "bundle_id": bundleId,
                    "phrase_chars": trimmedPhrase.count,
                ]
            )
        } catch {
            HeyClickyLog.log(
                "openclicky.launch_phrase.return_failed",
                lane: "system",
                direction: "error",
                [
                    "bundle_id": bundleId,
                    "error": "\(error)",
                ]
            )
        }
    }

    // MARK: - Matching

    /// Ported from `MacAppActivator.Matches` / `MatchesExecutable`
    /// (MacAppActivator.cs:193-218). Exact, case-insensitive match on
    /// any of: bundle id, localized name, executable basename.
    /// A substring match is deliberately not offered — `AgentAppId="chat"`
    /// would otherwise sweep in `WeChat`, `Whatsapp`, etc.
    private static func matches(_ app: NSRunningApplication, needle: String) -> Bool {
        if let bundle = app.bundleIdentifier,
           bundle.compare(needle, options: .caseInsensitive) == .orderedSame {
            return true
        }
        if let name = app.localizedName,
           name.compare(needle, options: .caseInsensitive) == .orderedSame {
            return true
        }
        if let exec = app.executableURL?.lastPathComponent,
           exec.compare(needle, options: .caseInsensitive) == .orderedSame {
            return true
        }
        return false
    }

    // MARK: - Constants (byte-parity with ContextStashWriter.cs:543-559)

    /// Loop cap: 16 iterations × 150ms = 2.4s wall-clock cap on the
    /// settle phase. Matches ContextStashWriter.cs:543.
    private static let settleIterations = 16

    /// Delay between settle ticks. Matches ContextStashWriter.cs:547.
    private static let settleTickMillis = 150

    /// How many consecutive frontmost ticks are needed before we type.
    /// Matches ContextStashWriter.cs:553 (`++stable >= 2`).
    private static let settleStableTicks = 2
}
