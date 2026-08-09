// MemoryPressureMonitor.swift — port of Rewind's memory-pressure
// broadcast (finding #6 from IDA reverse of
// `LRUCacheMemoryWarningNotification` at 0x100ec38d0 +
// `memoryPressureSource` at 0x100ec3890).
//
// What we mirror from Rewind:
//   • register a `dispatch_source_memorypressure` on `.warn`+`.critical`
//   • post a Notification the app can observe to purge caches
//   • callback for critical-level: pause capture pipeline
//
// What we drop from a fuller port:
//   • Rewind's LRUCache subsystem observes the notification directly;
//     we let each cache subscribe on its own (NSCache already handles
//     macOS pressure automatically, so most of our caches are covered).

import Foundation

public extension Notification.Name {
    /// Fired on macOS memory-pressure warn OR critical. Observers should
    /// drop non-essential caches. Analogue of Rewind's
    /// `LRUCacheMemoryWarningNotification` (0x100ec38d0).
    static let openrewindMemoryPressure =
        Notification.Name("openrewind.memory.pressure")
}

public final class OpenRewindMemoryPressureMonitor: @unchecked Sendable {
    public static let shared = OpenRewindMemoryPressureMonitor()

    private let queue = DispatchQueue(
        label: "openrewind.memory.pressure",
        qos: .utility)
    private var source: DispatchSourceMemoryPressure?
    /// Called on `.critical` events; pipeline should pause captures.
    private var criticalCallbacks: [@Sendable () -> Void] = []
    private let cbLock = NSLock()

    private init() {}

    public func start() {
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue)
        s.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            NotificationCenter.default.post(
                name: .openrewindMemoryPressure, object: nil,
                userInfo: ["level": event.rawValue])
            NSLog("openrewind-memory: pressure event mask=%lu", event.rawValue)
            if event.contains(.critical) {
                self.cbLock.lock()
                let cbs = self.criticalCallbacks
                self.cbLock.unlock()
                for cb in cbs { cb() }
            }
        }
        s.resume()
        source = s
    }

    public func stop() {
        source?.cancel(); source = nil
    }

    /// Register a callback fired on `.critical` events. Use for hard
    /// pause actions (stop encoder, drop write batches).
    public func registerCriticalCallback(_ cb: @escaping @Sendable () -> Void) {
        cbLock.lock(); criticalCallbacks.append(cb); cbLock.unlock()
    }
}
