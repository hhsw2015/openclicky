//
//  OpenRewindBridge.swift
//  cursor-buddy
//
//  Single lifecycle owner for the embedded OpenRewind subsystem.
//  CompanionManager instantiates the shared bridge at launch; the
//  bridge decides whether to actually start capture based on the
//  `openclicky.screenHistory.enabled` UserDefaults flag.
//
//  When enabled, the bridge composes:
//     Storage → Writer → Reader → Coordinator (in-process, no daemon)
//  and publishes state via `ScreenHistoryState.shared`.
//
//  When disabled, the bridge parks all fields as nil; assist agent
//  tools and MCP handlers see `reader == nil` and short-circuit with
//  "Screen History is not enabled" outcomes.
//

import Foundation
import AppKit
import Combine

@MainActor
public final class OpenRewindBridge: OpenRewindBridgeAccess {

    /// Set to a live instance when Screen History is enabled and boot
    /// succeeded. Nil otherwise. UI code reads `.shared` for the
    /// current state; assist / MCP code reads `.shared?.reader`.
    public private(set) static var shared: OpenRewindBridge?

    // MARK: - Live state
    public let storage: OpenRewindStorage
    public let writer: OpenRewindWriter
    public let reader: OpenRewindReader
    public let passphrase: String
    private let coordinator: OpenRewindCaptureCoordinator
    private let aiProvider: OpenClickyRewindAIProvider
    private var refreshTimer: Timer?

    // MARK: - Boot / shutdown

    /// Call once early in app boot (CompanionManager.init tail).
    /// Reads UserDefaults `openclicky.screenHistory.enabled`; if false,
    /// returns silently without starting capture. If true, allocates
    /// storage + writer + reader + coordinator and starts the capture
    /// pipeline in the background.
    public static func bootIfEnabled() {
        installDefaultsObserverOnce()
        guard shared == nil else { return }
        let enabled = UserDefaults.standard.bool(
            forKey: ScreenHistoryDefaults.enabledKey)
        guard enabled else { return }
        // FIX(product-polish-2026-07-31 #14): crash-loop guard.
        // Record a boot attempt timestamp; if 3 boots have started
        // within the last 60 s AND none checked in successfully,
        // enter safe mode — leave Screen History flag on but skip
        // the boot to give the user a chance to fix / reset.
        if Self.detectCrashLoop() {
            let msg = "Screen History disabled (safe mode): the recorder crashed 3× in the last minute. Open Settings → Screen History to reset the vault."
            NSLog("openrewind_bridge: %@", msg)
            ScreenHistoryState.shared.lastError = msg
            ScreenHistoryState.shared.isEnabled = false
            return
        }
        Self.recordBootAttempt()
        // FIX(product-polish-2026-07-31 #4): multi-instance lockfile.
        // Two OpenClicky processes opening the same encrypted DB WAL
        // would silently corrupt each other. Advisory flock on the
        // vault root prevents that. Existing process's lock survives
        // via fd; abnormal termination releases it automatically.
        if !Self.acquireVaultLock() {
            let msg = "Another OpenClicky instance is already recording. Quit the other instance and try again."
            NSLog("openrewind_bridge: %@", msg)
            ScreenHistoryState.shared.lastError = msg
            ScreenHistoryState.shared.isEnabled = false
            return
        }
        do {
            let bridge = try OpenRewindBridge()
            shared = bridge
            ScreenHistoryState.shared.isEnabled = true
            Task { await bridge.start() }
            Self.recordBootSuccess()
        } catch {
            NSLog("openrewind_bridge boot failed: %@",
                  String(describing: error))
            ScreenHistoryState.shared.lastError = error.localizedDescription
        }
    }

    /// FIX(product-polish-2026-07-31 #14): crash-loop detection.
    /// Boots and successful check-ins are stamped in UserDefaults.
    /// If 3 unmatched boots occur within 60 s, trip the guard.
    private static let bootAttemptsKey = "openrewind.boot.attempts"
    private static let bootSuccessKey  = "openrewind.boot.lastSuccess"

    private static func recordBootAttempt() {
        let d = UserDefaults.standard
        var stamps = (d.array(forKey: bootAttemptsKey) as? [Double]) ?? []
        stamps.append(Date().timeIntervalSince1970)
        // Keep last 5 within a rolling 60s window
        let cutoff = Date().timeIntervalSince1970 - 60
        stamps = stamps.filter { $0 > cutoff }.suffix(5).map { $0 }
        d.set(stamps, forKey: bootAttemptsKey)
    }

    private static func recordBootSuccess() {
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: bootSuccessKey)
        UserDefaults.standard.removeObject(forKey: bootAttemptsKey)
    }

    private static func detectCrashLoop() -> Bool {
        let d = UserDefaults.standard
        let stamps = (d.array(forKey: bootAttemptsKey) as? [Double]) ?? []
        let cutoff = Date().timeIntervalSince1970 - 60
        let recent = stamps.filter { $0 > cutoff }
        return recent.count >= 3
    }

    /// FIX(product-polish-2026-07-31 #3): advisory vault lock via
    /// `flock(LOCK_EX|LOCK_NB)` on a lockfile at the vault root. The
    /// fd is held for the process lifetime — abnormal termination
    /// releases it automatically.
    private static var vaultLockFD: Int32 = -1
    private static func acquireVaultLock() -> Bool {
        if vaultLockFD >= 0 { return true }
        let vaultURL = OpenRewindStorage.defaultVaultRoot()
        try? FileManager.default.createDirectory(
            at: vaultURL, withIntermediateDirectories: true)
        let lockURL = vaultURL.appendingPathComponent("openrewind.lock")
        let fd = open(lockURL.path,
                      O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            NSLog("openrewind_bridge: lockfile open failed errno=%d", errno)
            return true  // fail-open — don't block user on file-system quirks
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        vaultLockFD = fd
        return true
    }

    private static var didInstallObserver = false
    private static func installDefaultsObserverOnce() {
        guard !didInstallObserver else { return }
        didInstallObserver = true
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                let want = UserDefaults.standard.bool(
                    forKey: ScreenHistoryDefaults.enabledKey)
                let have = OpenRewindBridge.shared != nil
                if want && !have {
                    OpenRewindBridge.bootIfEnabled()
                } else if !want && have {
                    OpenRewindBridge.disable()
                }
            }
        }
    }

    /// Explicit disable — user toggled Settings off. Stops capture,
    /// closes DB handles, clears the shared instance.
    public static func disable() {
        guard let bridge = shared else { return }
        Task { await bridge.stop() }
        shared = nil
        ScreenHistoryState.shared.isEnabled = false
        ScreenHistoryState.shared.isRecordingScreen = false
        ScreenHistoryState.shared.isRecordingMic = false
        ScreenHistoryState.shared.isRecordingSystemAudio = false
    }

    // MARK: - Private construction

    private init() throws {
        // 1) Route all vault paths through OpenClicky's app-support dir.
        OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"
        // 2) Deep-link scheme + bundle prefix for RewindConfig-aware sites.
        RewindConfig.deepLinkScheme = "openclicky"
        RewindConfig.bundleIDPrefix = "com.jkneen.openclicky"
        // 3) Never record OpenClicky's own UI.
        ScreenCapture.coreExcludedBundleIDs = ["com.jkneen.openclicky"]

        let vault = OpenRewindStorage.defaultVaultRoot()
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)

        let passphrase = try Self.loadOrCreatePassphrase(at: vault)
        let storage = OpenRewindStorage(root: vault)
        let writer = try OpenRewindWriter(storage: storage,
                                          passphrase: passphrase)
        let reader = try OpenRewindReader(storage: storage,
                                          passphrase: passphrase)
        let adapter = OpenRewindWritingAdapter(writer: writer,
                                               vaultRoot: vault)
        let coord = OpenRewindCaptureCoordinator(
            config: .init(vaultRoot: vault),
            writer: adapter)

        self.storage = storage
        self.writer = writer
        self.reader = reader
        self.passphrase = passphrase
        self.coordinator = coord
        self.aiProvider = OpenClickyRewindAIProvider()
        installSelfHealObserver()
    }

    /// FIX(no-local-chunk-selfheal-2026-07-30): Reader.image posts
    /// `openrewind.frame.decode.failed` when the mp4 has no frame at
    /// the requested index — usually because a buggy retro-linker
    /// over-assigned videoFrameIndex. Flip the row to 'failed' so
    /// the query filter hides it and the user stops seeing "no local
    /// chunk" on that frame.
    private var selfHealObserver: NSObjectProtocol?
    private var storageHealthMonitor: OpenRewindStorageHealthMonitor?
    private var storageObservers: [NSObjectProtocol] = []

    /// FIX(product-polish-2026-07-31 #2): route storage-health
    /// notifications into `ScreenHistoryState.lastError` so the notch
    /// + Settings UI actually shows disk-full warnings instead of
    /// silently pausing capture.
    fileprivate func installStorageHealthObservers() {
        for o in storageObservers { NotificationCenter.default.removeObserver(o) }
        storageObservers.removeAll(keepingCapacity: true)
        let observed: [(Notification.Name, String, Bool)] = [
            (.openrewindStorageInaccessible,
             "Vault storage inaccessible — recording paused.", true),
            (.openrewindStorageCritical,
             "Storage critically low — recording paused. Free up disk space.", true),
            (.openrewindStorageLow,
             "Storage low: less than 5 GB free.", false),
            (.openrewindStorageRecovered,
             "", false),
        ]
        for (name, msg, isFatal) in observed {
            let ob = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    if msg.isEmpty {
                        // Recovered — clear only if the last error was a
                        // storage-tagged one.
                        if let e = ScreenHistoryState.shared.lastError,
                           e.contains("storage") || e.contains("Vault storage")
                            || e.contains("Storage") {
                            ScreenHistoryState.shared.lastError = nil
                        }
                    } else {
                        ScreenHistoryState.shared.lastError = msg
                    }
                    if isFatal {
                        ScreenHistoryState.shared.isRecordingScreen = false
                    }
                }
            }
            storageObservers.append(ob)
        }
    }

    private func installSelfHealObserver() {
        // Remove any prior observer token from a previous bridge
        // instance — reboot / Settings-toggle cycles otherwise
        // stacked duplicate observers.
        if let old = selfHealObserver {
            NotificationCenter.default.removeObserver(old)
        }
        selfHealObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("openrewind.frame.decode.failed"),
            object: nil, queue: nil
        ) { [weak self] note in
            guard let fid = note.userInfo?["frameID"] as? Int64,
                  let writer = self?.writer else { return }
            _ = try? writer.markFrameFailed(id: fid)
        }
    }

    deinit {
        if let old = selfHealObserver {
            NotificationCenter.default.removeObserver(old)
        }
    }

    /// Refresh reader's `/tmp` DB copy so the next query sees frames
    /// written by the coordinator since this reader was opened.
    /// Callers (MCP sensor, assist agent) invoke before each read.
    ///
    /// Perf: this hits SQLite copy-to-tmp on the caller's actor. Older
    /// code called it from MainActor and blocked the UI for 20-80ms
    /// while the file copy ran. Prefer `reopenReaderAsync` from any
    /// path that can await — it runs the copy on a detached task and
    /// only returns to the caller once done, without dragging main
    /// runloop through the SQLite call.
    public func reopenReader() throws {
        try reader.reopen(passphrase: passphrase)
    }

    /// Non-blocking variant. Reader + passphrase are Sendable-safe to
    /// capture into the detached task (reader is a class; passphrase
    /// is a value). Never called from MainActor's execution frame.
    public func reopenReaderAsync() async throws {
        let r = reader
        let p = passphrase
        try await Task.detached(priority: .utility) {
            try r.reopen(passphrase: p)
        }.value
    }

    // MARK: - Lifecycle

    private func start() async {
        // AI provider — daily-recap / keyword extraction routes through
        // whichever backend the user picked in Settings.
        // TODO wire once OpenRewindDaemon composition path is used.
        // For now the coordinator drives capture directly.

        // Kick off StartupReconciler to clean stalled pending frames.
        // FIX(crash-tail-recovery-2026-07-31 #10): pass the same
        // ChunkEncoder the live pipeline uses so any orphan PNGs from
        // a previous crashed session get replayed into recovery chunks
        // BEFORE we flip their DB rows to 'failed'.
        do {
            let recoveryProfile = profileFromUserDefaults()
            let recoveryEncoder = EncoderAdapter.makeChunkEncoder(
                profile: recoveryProfile, vaultRoot: storage.root)
            let boxedRecovery: StartupReconciler.RecoveryEncoder = { paths, outMP4 in
                try await recoveryEncoder(paths, outMP4, recoveryProfile)
            }
            try await StartupReconciler(
                reader: reader,
                writer: writer,
                tempRoot: storage.root.appendingPathComponent("temp"),
                chunksRoot: storage.root.appendingPathComponent("chunks"),
                recoveryEncoder: boxedRecovery
            ).run()
        } catch {
            NSLog("openrewind_bridge reconciler skipped: %@",
                  String(describing: error))
        }

        // FIX(self-record-2026-07-30): delay first capture 2s so
        // OpenClicky's notch panel + overlay windows are already in
        // SCShareableContent when we build the initial exclusion
        // filter. Without this, LSUIElement accessory windows that
        // appear immediately after boot slip past the bundle-id filter.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Start capture.
        do {
            let profile = profileFromUserDefaults()
            let encoder = EncoderAdapter.makeChunkEncoder(
                profile: profile, vaultRoot: storage.root)
            try await coordinator.start(profile: profile, encoder: encoder)
            // FIX(retrace-#3-2026-07-31): storage health watchdog.
            // Auto-stop capture at 0.5 GB free to prevent WAL corruption.
            let coord = coordinator
            storageHealthMonitor = OpenRewindStorageHealthMonitor(
                vaultRoot: storage.root,
                onStop: { Task { await coord.setCapturePaused(true) } })
            await storageHealthMonitor?.start()
            // FIX(product-polish-2026-07-31 #2): subscribe to storage
            // health notifications so the user sees WHY capture paused
            // instead of an unexplained blackout. Surfaces via
            // `ScreenHistoryState.lastError` which the notch + Settings
            // UI already renders.
            installStorageHealthObservers()
            // FIX(rewind-ida-#6-2026-07-31): memory-pressure source.
            // On `.critical` mac memory pressure, pause capture so a
            // heavy user workload doesn't jetsam our recorder. On
            // `.warn`, the Notification drops NSCache-backed caches
            // downstream (Reader thumbnail cache subscribes).
            OpenRewindMemoryPressureMonitor.shared.registerCriticalCallback {
                Task { await coord.setCapturePaused(true) }
            }
            OpenRewindMemoryPressureMonitor.shared.start()
            ScreenHistoryState.shared.isRecordingScreen =
                UserDefaults.standard.bool(
                    forKey: ScreenHistoryDefaults.captureScreenKey)
            ScreenHistoryState.shared.isRecordingMic =
                UserDefaults.standard.bool(
                    forKey: ScreenHistoryDefaults.captureMicKey)
            ScreenHistoryState.shared.isRecordingSystemAudio =
                UserDefaults.standard.bool(
                    forKey: ScreenHistoryDefaults.captureSystemAudioKey)
        } catch {
            NSLog("openrewind_bridge coordinator start failed: %@",
                  String(describing: error))
            ScreenHistoryState.shared.lastError = error.localizedDescription
            return
        }

        startRefreshTimer()
        // Delayed exclusion-filter refresh: OpenClicky's notch panel,
        // overlay windows, and virtual cursor are created after bridge
        // boot; the initial SCShareableContent snapshot missed them.
        Task { [coordinator] in
            // First refresh 3s after boot — enough time for OpenClicky's
            // notch panel + overlay windows to have registered. Then
            // additional refreshes at 15s / 45s / 90s in case some
            // long-lived windows appear later (virtual cursor, response
            // cards, etc.). After that the every-5-min refresh handles
            // steady state.
            for delaySec in [3, 15, 45, 90] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                await coordinator.refreshExclusionFilter()
            }
        }
    }

    private func stop() async {
        refreshTimer?.invalidate()
        refreshTimer = nil
        try? await coordinator.stop()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5,
                                            repeats: true) { _ in
            // Run the periodic housekeeping on a detached background
            // task, not the main actor. This work does disk stat + a
            // Reader.coverage query + a potential JSON write; none
            // of it should stall UI. Only the observable state
            // (`ScreenHistoryState.shared.*`) publishes back to main.
            Task.detached(priority: .utility) { [weak self] in
                await self?.refreshStatePublisher()
            }
        }
    }

    /// Wall-clock tick counter that increments every refresh (5s), so
    /// modulo-N gates fire periodic maintenance without extra timers.
    private var refreshTick: Int = 0

    private func refreshStatePublisher() async {
        refreshTick += 1
        // Frame count + vault size are cheap enough to poll every 5s.
        do {
            let coverage = try reader.coverage()
            // FIX(product-polish-2026-07-31 #1): actual frame count.
            let n = (try? reader.totalFrameCount()) ?? 0
            ScreenHistoryState.shared.frameCount = n
            _ = coverage
        } catch {
            // reader may throw right after boot; ignore
        }
        if let attrs = try? FileManager.default
            .attributesOfItem(atPath: storage.dbEncrypted.path),
           let size = attrs[.size] as? Int64 {
            ScreenHistoryState.shared.vaultBytes = size
        }
        // Every 5 min (60 ticks × 5s) rebuild the exclusion filter so
        // any newly-visible OpenClicky window (response cards, virtual
        // cursor overlay, guided-click hosts) gets picked up.
        if refreshTick % 60 == 0 {
            await coordinator.refreshExclusionFilter()
        }
        // Every 4320 ticks (6h) run "reclaim disk, keep memory" IF
        // the temp/ dir has grown past the auto-prune threshold.
        // Users forget to manually clean; this scheduler enforces a
        // rolling media budget without touching FTS/embedding/DB.
        // Threshold configurable via UserDefaults; default 2 GB.
        if refreshTick % 4320 == 0 {
            await runAutoRetentionIfNeeded()
        }
        // Also write the current playhead sidecar so
        // `openrewind.currentContext` (and any other daemon-oriented
        // tool) works. Daemon-side OpenRewind writes this via
        // CurrentPlayheadBroadcast; embedded host does the same here.
        writePlayheadSidecar()
    }

    /// Cache the last frameID we wrote to `current-playhead.json`.
    /// Skipping the disk write when nothing changed is what turns
    /// the 5s tick into a near-noop 99% of the time.
    private var lastSidecarFrameID: Int64 = 0

    /// Emit `<vault>/current-playhead.json` describing the newest
    /// frame we've written. `Tools.currentContext` in OpenRewindMCP
    /// reads this file to answer "what is the user looking at right
    /// now" without needing a daemon process. Skips the write when
    /// the frame hasn't advanced — the sidecar is a state marker,
    /// not a heartbeat.
    private func writePlayheadSidecar() {
        guard let entry = try? reader.recentEntries(limit: 1).first else {
            return
        }
        if entry.id == lastSidecarFrameID { return }
        lastSidecarFrameID = entry.id
        let url = storage.root.appendingPathComponent("current-playhead.json")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "frameId": entry.id,
            "createdAt": iso.string(from: entry.createdAt),
            "bundleID": entry.bundleID ?? NSNull(),
            "windowName": entry.windowName ?? NSNull()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted]) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Background retention: prune old media if temp/ + chunks/ has
    /// grown past the user-configured threshold (default 2 GB). The
    /// DB (FTS + embeddings + conversation history) is preserved so
    /// memory-of-past-context survives — this is the "reclaim disk,
    /// keep memory" mode wired into Settings.
    private func runAutoRetentionIfNeeded() async {
        let thresholdMB = UserDefaults.standard
            .object(forKey: "openclicky.screenHistory.auto_prune_threshold_mb")
            as? Int ?? 2048
        let thresholdBytes = Int64(thresholdMB) * 1024 * 1024
        let mediaBytes = mediaDirSize()
        HeyClickyLog.log("openclicky.retention.auto.check",
                         lane: "system", direction: "internal",
                         ["media_mb": mediaBytes / 1024 / 1024,
                          "threshold_mb": thresholdMB])
        guard mediaBytes > thresholdBytes else { return }
        // Cutoff = anything older than user's retention window
        // (default 7 days). If not set, use 7 days.
        let days = UserDefaults.standard.integer(
            forKey: "openclicky.screenHistory.retention.days")
        let effDays = days > 0 ? days : 7
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -effDays, to: Date())
        let mgr = RetentionManager(reader: reader, storage: storage)
        await mgr.setOwnsDatabase(true)
        do {
            let report = try await mgr.pruneMediaOnly(
                olderThan: cutoff, includeTempJpegs: true)
            HeyClickyLog.log("openclicky.retention.auto.ok",
                             lane: "system", direction: "internal",
                             ["bytes_freed": report.chunkBytesReclaimed,
                              "files_deleted": report.chunkFilesDeleted,
                              "videos_deleted": report.videosDeleted,
                              "cutoff_days": effDays])
        } catch {
            HeyClickyLog.log("openclicky.retention.auto.failed",
                             lane: "system", direction: "error",
                             ["error": error.localizedDescription])
        }
    }

    /// Sum of bytes under temp/ + chunks/. Used only for the
    /// auto-retention threshold check; not user-facing.
    private func mediaDirSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for sub in ["temp", "chunks"] {
            let url = storage.root.appendingPathComponent(sub)
            guard let en = fm.enumerator(at: url,
                includingPropertiesForKeys: [.fileSizeKey])
            else { continue }
            for case let f as URL in en {
                if let s = (try? f.resourceValues(forKeys: [.fileSizeKey])
                              .fileSize) {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    private func profileFromUserDefaults() -> OpenRewindCompressionProfile {
        let raw = UserDefaults.standard.string(
            forKey: ScreenHistoryDefaults.compressionProfileKey) ?? "integration"
        return OpenRewindCompressionProfile(rawValue: raw) ?? .integration
    }

    // MARK: - Passphrase

    private static func loadOrCreatePassphrase(at vault: URL) throws -> String {
        let keyURL = vault.appendingPathComponent("key")
        if let existing = try? String(contentsOf: keyURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard rc == errSecSuccess else {
            throw NSError(domain: "openrewind_bridge",
                          code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "SecRandomCopyBytes failed"])
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try hex.write(to: keyURL, atomically: true, encoding: .utf8)
        // FIX(privacy-audit-2026-08-01 CRITICAL #1): tighten permissions
        // + backup exclusion. Was 0644 default; now 0600 so only the
        // user can read. `isExcludedFromBackup` prevents Time Machine /
        // iCloud from replicating the vault key off the machine. FileVault
        // is still the primary defense at rest — this makes casual
        // exfiltration harder without changing the trust model.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: keyURL.path)
        var mutableURL = keyURL
        var backupResources = URLResourceValues()
        backupResources.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(backupResources)
        return hex
    }

    // MARK: - OpenRewindBridgeAccess (host protocol for DaemonHost)

    public func vaultRoot() -> URL? { storage.root }
    public func refreshFromUserDefaults() {
        // TODO surface toggles to coordinator once CaptureToggles pipe lands
    }
    public func startIfNeeded() { /* boot handled by bootIfEnabled */ }
    public func stop() { OpenRewindBridge.disable() }
}
