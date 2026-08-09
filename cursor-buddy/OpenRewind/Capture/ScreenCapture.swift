// ScreenCapture — SCStream per display, emits CapturedFrame.
//
// macOS 12.3+ API. We enforce macOS 13 at the package level anyway.
// Everything heavy runs off the main thread on a dedicated video queue.

import Foundation
import CoreGraphics
import CoreMedia
import AppKit
import ScreenCaptureKit
import VideoToolbox

/// Actor-wrapped SCStream ring. One `ScreenCapture` may serve one or
/// more displays; call `start()` per display for multi-monitor setups.
public actor ScreenCapture {

    /// FIX(exclusion-ui-2026-07-29): three-layer bundle-ID exclusion,
    /// mirrors retrace's `OCRAppFilterMode` (`Shared/PowerStateMonitor
    /// .swift:50-60`) but applied at *capture* time so an excluded app
    /// is never even filmed. Precedence (union):
    ///   1. `coreExcludedBundleIDs` — hardcoded OpenRewind self-record
    ///      guard. Never surfaced to the user.
    ///   2. `hostExtras` — SPM host adds its own bundle via the
    ///      `additionalExcludedBundleIDs` public property.
    ///   3. UserDefaults `openrewind.excluded.bundleIDs` — comma or
    ///      newline separated list the Settings UI writes. Re-read on
    ///      every stream start/restart so no daemon respawn needed.
    /// Hardcoded self-record guard. SPM host MUST override at startup
    /// with its own browser/daemon/UI bundle IDs — otherwise capture
    /// will film the host's own window and create a feedback loop
    /// where each frame contains the previous frame. See
    /// `docs/PORTING.md` §"Blockers to fix before publishing SPM".
    ///
    /// Override example:
    /// ```
    /// ScreenCapture.coreExcludedBundleIDs = [
    ///     "com.myapp.main",
    ///     "com.myapp.helper",
    /// ]
    /// ```
    /// Assign BEFORE the first `start()` call — later assignments
    /// take effect on the next stream restart.
    public static var coreExcludedBundleIDs: Set<String> = [
        "com.openrewind.browser",
        "com.openrewind.daemon",
        "com.openrewind.mcp",
    ]

    public static let excludedBundleIDsDefaultsKey = "openrewind.excluded.bundleIDs"

    /// Resolve the final exclusion set: core ∪ host ∪ UserDefaults.
    /// UserDefaults value is a `[String]` array; we accept a
    /// comma/newline-separated string too for CLI/env convenience.
    static func resolveExcludedBundleIDs(hostExtras: [String]) -> Set<String> {
        var set = coreExcludedBundleIDs
        set.formUnion(hostExtras)
        let d = UserDefaults.standard
        if let arr = d.array(forKey: excludedBundleIDsDefaultsKey) as? [String] {
            for s in arr {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { set.insert(t) }
            }
        } else if let s = d.string(forKey: excludedBundleIDsDefaultsKey), !s.isEmpty {
            for raw in s.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }) {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { set.insert(t) }
            }
        }
        return set
    }

    public typealias FrameHandler = @Sendable (CapturedFrame) -> Void

    private let videoQueue = DispatchQueue(
        label: "com.openrewind.capture.video",
        qos: .userInitiated
    )

    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var outputs: [CGDirectDisplayID: StreamOutput] = [:]
    private var handler: FrameHandler?

    public init() {}

    /// Register the async closure that receives frames. Set before `start()`.
    public func setFrameHandler(_ handler: @escaping FrameHandler) {
        self.handler = handler
    }

    /// FIX(spm-port-2026-07-29 §PORTING.md blocker): third-party SPM
    /// hosts must be able to exclude their own bundle from capture.
    /// Set this before calling `start()` — bundle IDs are matched
    /// verbatim against `SCRunningApplication.bundleIdentifier`.
    public var additionalExcludedBundleIDs: [String] = []

    /// Start capture on every online display, or the ones passed in `only`.
    /// Retrace/Rewind default = 1 frame every 2 s (0.5 fps). Pass
    /// `fps: 2` to get 2 fps (interval 0.5s). Interval below is
    /// derived as `1/fps` seconds; use `intervalSeconds` init overload
    /// for sub-1 fps.
    public func start(fps: Int = 1,
                      only: [CGDirectDisplayID]? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        // FIX(self-record-2026-07-29): exclude OpenRewind's own app so
        // the timeline can float in front of the user's real screen
        // without the daemon recording our overlay chrome. Rewind and
        // retrace both use this pattern. Match by the browser's bundle
        // id — the daemon runs under a separate bundle id so it's not
        // in this list.
        //
        // FIX(spm-port-2026-07-29): `additionalExcludedBundleIDs` lets
        // a downstream SPM host exclude its own bundle without a fork.
        let allExcluded = Self.resolveExcludedBundleIDs(
            hostExtras: additionalExcludedBundleIDs)
        // Match by bundleIdentifier. Fallback: also exclude ourselves
        // by PID so a host app that lives as LSUIElement (menu-bar
        // accessory, no dock) still gets filtered even when
        // SCShareableContent snapshotted before its windows existed.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = content.applications.filter { app in
            if allExcluded.contains(app.bundleIdentifier) { return true }
            if app.processID == ownPID { return true }
            return false
        }
        NSLog("openrewind-capture: SCContentFilter excluding %d apps (of %d) — matched=%@ ownPID=%d",
              excludedApps.count, content.applications.count,
              excludedApps.map { $0.bundleIdentifier }.joined(separator: ","),
              ownPID)
        let displays = content.displays.filter { d in
            guard let only else { return true }
            return only.contains(d.displayID)
        }
        for display in displays {
            try await start(display: display, fps: fps, exclude: excludedApps)
        }
    }

    private func start(display: SCDisplay,
                       fps: Int,
                       exclude: [SCRunningApplication] = []) async throws {
        // Avoid duplicate streams for the same display.
        if streams[display.displayID] != nil { return }

        let filter = SCContentFilter(display: display,
                                     excludingApplications: exclude,
                                     exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        // FIX(retina-2026-07-29): `display.width/height` are POINTS.
        // Multiply by the display's backing scale factor so we
        // capture at native pixel resolution (Rewind captures 3456×2160
        // on a 14" MBP; we were capturing 1728×1080 → visibly blurry
        // when rendered back on retina).
        let scale = Self.backingScale(for: display.displayID)
        cfg.width = Int(Double(display.width) * scale)
        cfg.height = Int(Double(display.height) * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // Effective interval seconds: 2 s per frame when fps == 1
        // (matches retrace / Rewind default). Higher fps still works.
        let intervalSeconds: Double = fps <= 1 ? 2.0 : 1.0 / Double(fps)
        cfg.minimumFrameInterval = CMTime(seconds: intervalSeconds, preferredTimescale: 600)
        cfg.queueDepth = 4
        // FIX(cursor-2026-07-29): cursor overlay was recorded on every
        // frame and became noise in Live Text search. Rewind's own
        // stream disables the cursor.
        cfg.showsCursor = false

        let delegate = StreamStopDelegate(
            displayID: display.displayID,
            fps: fps
        ) { [weak self] did in
            Task { [weak self] in
                guard let self else { return }
                await self.spawnRestartIfNeeded(displayID: did, fps: fps)
            }
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: delegate)
        let output = StreamOutput(displayID: display.displayID) { [weak self] frame in
            guard let self else { return }
            Task { await self.dispatch(frame) }
        }
        try stream.addStreamOutput(output,
                                   type: .screen,
                                   sampleHandlerQueue: videoQueue)
        try await stream.startCapture()

        streams[display.displayID] = stream
        outputs[display.displayID] = output
        delegates[display.displayID] = delegate
        restartAttempts[display.displayID] = 0
    }

    private var delegates: [CGDirectDisplayID: StreamStopDelegate] = [:]
    private var restartAttempts: [CGDirectDisplayID: Int] = [:]

    private func restartStream(displayID: CGDirectDisplayID, fps: Int) async {
        if stopped { return }
        // Dedup: if another restart Task is already looping for this
        // display, don't spawn a second one racing it.
        if let existing = restartTasks[displayID], !existing.isCancelled { return }
        var attempt = 0
        while !stopped {
            if Task.isCancelled { return }
            attempt += 1
            // Backoff: 1s, 2s, 4s, 8s, 16s, then cap at 30s.
            let delay = min(30.0, pow(2.0, Double(attempt - 1)))
            NSLog("openrewind-capture: SCStream restart #\(attempt) in \(delay)s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let old = streams[displayID] {
                try? await old.stopCapture()
                streams.removeValue(forKey: displayID)
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard !content.displays.isEmpty else {
                    NSLog("openrewind-capture: no displays available, retrying")
                    continue
                }
                // Re-read on every restart so the UserDefaults-backed
                // exclusion list (Settings UI) takes effect without a
                // full daemon respawn.
                let allExcluded = Self.resolveExcludedBundleIDs(
                    hostExtras: additionalExcludedBundleIDs)
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let excludedApps = content.applications.filter { app in
                    if allExcluded.contains(app.bundleIdentifier) { return true }
                    if app.processID == ownPID { return true }
                    return false
                }
                NSLog("openrewind-capture: restart exclude %d apps ownPID=%d matched=%@",
                      excludedApps.count, ownPID,
                      excludedApps.map { $0.bundleIdentifier }.joined(separator: ","))
                // Prefer original display, else fall back to any
                // available (user may have unplugged the external
                // monitor we were tracking).
                let target = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first
                if let d = target {
                    try await start(display: d, fps: fps, exclude: excludedApps)
                    NSLog("openrewind-capture: SCStream restart OK after \(attempt) tries (displayID=\(d.displayID))")
                    // FIX(2026-07-29): clear our slot so future stream
                    // stops can spawn a fresh restart Task. Was leaked
                    // as a completed Task, blocking dedup check.
                    restartTasks.removeValue(forKey: displayID)
                    return
                }
            } catch {
                NSLog("openrewind-capture: SCStream restart failed: \(error) — retrying")
            }
        }
    }

    private var stopped: Bool = false
    private var restartTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    private func spawnRestartIfNeeded(displayID: CGDirectDisplayID, fps: Int) {
        if stopped { return }
        if let t = restartTasks[displayID], !t.isCancelled { return }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.restartStream(displayID: displayID, fps: fps)
        }
        restartTasks[displayID] = task
    }

    /// Force a snapshot-refresh cycle: stops every active stream and
    /// restarts it, causing `SCShareableContent.excludingDesktopWindows`
    /// to re-run so newly-launched host windows (notch overlays, virtual
    /// cursors) get picked up by the bundle-id exclusion filter.
    public func refreshExclusionFilter(fps: Int = 1) async {
        for (displayID, _) in streams {
            await restartStream(displayID: displayID, fps: fps)
        }
    }

    public func stop() async {
        stopped = true
        // Cancel watchdog + any in-flight restart loops so they don't
        // resurrect capture after the caller asked us to stop.
        healthTimer?.cancel()
        healthTimer = nil
        for (_, task) in restartTasks { task.cancel() }
        restartTasks.removeAll()
        for (_, stream) in streams {
            try? await stream.stopCapture()
        }
        streams.removeAll()
        outputs.removeAll()
        delegates.removeAll()
    }

    private func dispatch(_ frame: CapturedFrame) {
        lastFrameTs = Date()
        handler?(frame)
    }

    private var lastFrameTs: Date = Date()
    private var healthTimer: Task<Void, Never>?
    /// Watchdog: if no frame for 60s while `streams` non-empty,
    /// something silently killed the stream — force a restart.
    /// Called by CaptureCoordinator right after start().
    public func startHealthWatchdog(fps: Int) {
        healthTimer?.cancel()
        healthTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                let stale = await self.isStale()
                if stale, !Task.isCancelled {
                    NSLog("openrewind-capture: watchdog — no frame for 60s, force restart")
                    if let firstID = await self.streams.keys.first {
                        await self.spawnRestartIfNeeded(displayID: firstID, fps: fps)
                    }
                }
            }
        }
    }
    private func isStale() -> Bool {
        !streams.isEmpty && Date().timeIntervalSince(lastFrameTs) > 60
    }

    /// Look up the backing scale factor for a given `CGDirectDisplayID`.
    /// Falls back to 2.0 (retina) when no matching NSScreen is present.
    static func backingScale(for displayID: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == displayID {
                return Double(screen.backingScaleFactor)
            }
        }
        return NSScreen.main.map { Double($0.backingScaleFactor) } ?? 2.0
    }
}

// MARK: - Sample buffer plumbing

/// SCStreamOutput cannot itself be an actor. This class marshals sample
/// buffers off ScreenCaptureKit's queue into our frame handler.
final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

    private let displayID: CGDirectDisplayID
    private let onFrame: @Sendable (CapturedFrame) -> Void

    init(displayID: CGDirectDisplayID,
         onFrame: @escaping @Sendable (CapturedFrame) -> Void) {
        self.displayID = displayID
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage else { return }

        let ts = Date()
        // FIX(jank-audit-2026-07-31 #1): removed per-frame
        // `NSWorkspace.frontmostApplication` read from the SCStream
        // callback. That call takes the main-thread AppKit lock, so
        // firing it 30-60× per second contended with the cursor
        // overlay's own main-thread rendering. Coordinator now reads
        // the frontmost app on its own actor when it needs the info
        // (rate-limited by segment enrichment TTL). See
        // CaptureCoordinator.enrichSegment for the replacement path.
        let frame = CapturedFrame(image: cgImage,
                                  timestamp: ts,
                                  displayID: displayID,
                                  windowInfo: nil)
        onFrame(frame)
    }

    /// Deprecated — retained only for reference. Callers must read
    /// frontmost app off the SCStream callback path.
    static func frontmostWindowInfo() -> WindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return WindowInfo(app: app.localizedName,
                          title: nil,
                          bundleID: app.bundleIdentifier,
                          url: nil)
    }
}

/// SCStreamDelegate hook — fires `didStopWithError` when the system
/// terminates the stream (ANE OOM, permission revoke, sleep). We use
/// it to trigger an auto-restart from ScreenCapture.
final class StreamStopDelegate: NSObject, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    let fps: Int
    let onStop: (CGDirectDisplayID) -> Void
    init(displayID: CGDirectDisplayID, fps: Int,
         onStop: @escaping (CGDirectDisplayID) -> Void) {
        self.displayID = displayID
        self.fps = fps
        self.onStop = onStop
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("openrewind-capture: SCStream didStop error=%@", "\(error)")
        onStop(displayID)
    }
}
