// StorageHealthMonitor — lean port of retrace
// `Storage/FileManager/StorageHealthMonitor.swift` (450 loc → ~80 loc).
//
// What we keep:
//   • Periodic (30 s) disk-space poll on the vault volume
//   • 5/1/0.5 GB warning/critical/stop thresholds (retrace parity)
//   • Notification names retrace emits, so downstream UI can subscribe
//   • Optional onCriticalError callback to auto-stop capture at 0.5 GB
//
// What we drop:
//   • Rolling I/O-latency ring buffer (not actionable without a UI)
//   • Volume-unmount observer (SCStream error path catches this)
//   • Detailed Snapshot struct (single availableGB is enough)
//
// FIX(retrace-#3-2026-07-31): closes the gap where a full disk would
// silently corrupt the WAL. Now capture stops cleanly with a user
// notification instead of scribbling half-written mp4s.

import Foundation

public extension Notification.Name {
    static let openrewindStorageInaccessible =
        Notification.Name("openrewind.storage.inaccessible")
    static let openrewindStorageLow =
        Notification.Name("openrewind.storage.low")
    static let openrewindStorageCritical =
        Notification.Name("openrewind.storage.critical")
    static let openrewindStorageRecovered =
        Notification.Name("openrewind.storage.recovered")
}

public actor OpenRewindStorageHealthMonitor {

    public struct Thresholds: Sendable {
        public var warningGB: Double = 5.0
        public var criticalGB: Double = 1.0
        public var stopGB:     Double = 0.5
        public init() {}
    }

    private enum State { case healthy, low, critical, stopped }

    private let vaultRoot: URL
    private let thresholds: Thresholds
    private let intervalSeconds: TimeInterval
    private let onStop: (@Sendable () -> Void)?
    private var task: Task<Void, Never>?
    private var state: State = .healthy

    public init(vaultRoot: URL,
                thresholds: Thresholds = Thresholds(),
                intervalSeconds: TimeInterval = 30,
                onStop: (@Sendable () -> Void)? = nil) {
        self.vaultRoot = vaultRoot
        self.thresholds = thresholds
        self.intervalSeconds = intervalSeconds
        self.onStop = onStop
    }

    public func start() {
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds:
                    UInt64((self.map { _ in 30.0 } ?? 30.0) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil
    }

    private func tick() {
        guard let availableGB = Self.availableGB(at: vaultRoot) else {
            transition(to: .stopped, reason: "storage_inaccessible",
                       notification: .openrewindStorageInaccessible)
            return
        }
        let next: State
        if availableGB < thresholds.stopGB {
            next = .stopped
        } else if availableGB < thresholds.criticalGB {
            next = .critical
        } else if availableGB < thresholds.warningGB {
            next = .low
        } else {
            next = .healthy
        }
        guard next != state else { return }
        let note: Notification.Name?
        switch next {
        case .stopped:  note = .openrewindStorageInaccessible
        case .critical: note = .openrewindStorageCritical
        case .low:      note = .openrewindStorageLow
        case .healthy:  note = state == .healthy ? nil : .openrewindStorageRecovered
        }
        transition(to: next,
                   reason: String(format: "%.2fGB", availableGB),
                   notification: note)
    }

    private func transition(to next: State,
                            reason: String,
                            notification: Notification.Name?) {
        state = next
        if let n = notification {
            NotificationCenter.default.post(name: n, object: nil,
                                            userInfo: ["reason": reason])
        }
        if next == .stopped {
            NSLog("openrewind-storage: STOP threshold reached (%@)", reason)
            onStop?()
        }
    }

    /// Returns free space in GB for the volume containing `url`, or nil
    /// if the filesystem attribute call fails (device removed, etc).
    static func availableGB(at url: URL) -> Double? {
        let fm = FileManager.default
        // Prefer forAvailableCapacityForImportantUsage — this is what
        // Apple recommends for user-facing storage decisions (accounts
        // for purgeable caches).
        let vals = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let bytes = vals?.volumeAvailableCapacityForImportantUsage {
            return Double(bytes) / 1_073_741_824.0
        }
        // Fallback: raw available bytes.
        if let attrs = try? fm.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.doubleValue / 1_073_741_824.0
        }
        return nil
    }
}
