// UIEventsMonitor — CGEventTap on keyboard/mouse + NSWorkspace app-switch.
// Debounced to at most 1 event/second per (app, kind). Emits `UIEvent`.
//
// The tap runs on a dedicated background thread with its own run loop so
// we never block the main thread. If Input Monitoring permission is
// missing, CGEvent.tapCreate returns nil and we surface `.disabled`.

import Foundation
import CoreGraphics
import AppKit

public actor UIEventsMonitor {

    public typealias EventHandler = @Sendable (UIEvent) -> Void

    public enum State: Sendable {
        case idle, running, disabled
    }

    private var runLoopThread: Thread?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // FIX(review-2026-07-28) C-1: capture the tap thread's CFRunLoop so
    // stop() can `CFRunLoopRemoveSource` + `CFRunLoopStop` — the old code
    // only disabled the tap and cancelled the Thread, leaking the run-loop
    // source and mach port on every restart.
    private var tapRunLoop: CFRunLoop?
    // FIX(review-2026-07-28) C-2 (Capture CRITICAL): retained refcon so the
    // tap callback never dereferences a dangling actor.
    private var refconRetained: Unmanaged<UIEventsMonitor>?
    private var handler: EventHandler?
    private var lastEmitted: [String: TimeInterval] = [:]
    // FIX(review-2026-07-28) C-M: bound the debounce map so a long-running
    // capture session with many transient apps can't grow lastEmitted
    // without limit. FIFO eviction over the insertion-order list keeps the
    // most recent 1024 (app, kind) pairs live, which is far larger than
    // the ~30-50 pairs an active session actually produces.
    private var lastEmittedOrder: [String] = []
    private let lastEmittedCap = 1024
    private var appSwitchObserver: NSObjectProtocol?
    public private(set) var state: State = .idle

    public init() {}

    public func setHandler(_ handler: @escaping EventHandler) {
        self.handler = handler
    }

    /// Start the CGEventTap and NSWorkspace observers.
    public func start() {
        if state == .running { return }

        // App-switch observer (works even without event tap perms).
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            guard let self else { return }
            let app = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                       as? NSRunningApplication)?.localizedName
            Task { await self.emit(kind: .appSwitch, app: app, meta: [:]) }
        }

        // CGEventTap: kick off on its own thread so its CFRunLoop can run.
        let thread = Thread { [weak self] in
            self?.installTapOnCurrentThread()
            RunLoop.current.run()
        }
        thread.name = "com.openrewind.capture.eventtap"
        thread.qualityOfService = .utility
        thread.start()
        runLoopThread = thread
        state = .running
    }

    public func stop() {
        state = .idle
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appSwitchObserver = nil
        }
        // FIX(review-2026-07-28) C-1: properly tear down the run loop
        // source, THEN stop the run loop, THEN cancel the thread.
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let src = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        tapPort = nil
        runLoopSource = nil
        tapRunLoop = nil
        runLoopThread?.cancel()
        runLoopThread = nil
        // Release the retained refcon last — the tap callback is guaranteed
        // to be quiesced now.
        refconRetained?.release()
        refconRetained = nil
    }

    // MARK: - Tap

    private nonisolated func installTapOnCurrentThread() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)   |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)   |
            (1 << CGEventType.scrollWheel.rawValue)

        // FIX(review-2026-07-28) C-2: passRetained gives the tap callback a
        // stable reference even if the actor is torn down mid-flight. stop()
        // releases it explicitly after the tap has been disabled.
        let retained = Unmanaged.passRetained(self)
        let selfPtr = retained.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<UIEventsMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                let kind: UIEvent.Kind
                switch type {
                case .keyDown:          kind = .keyDown
                case .keyUp:            kind = .keyUp
                case .leftMouseDown, .rightMouseDown: kind = .mouseDown
                case .leftMouseUp,   .rightMouseUp:   kind = .mouseUp
                case .scrollWheel:      kind = .scroll
                default:
                    return Unmanaged.passUnretained(event)
                }
                let app = NSWorkspace.shared.frontmostApplication?.localizedName
                Task { await monitor.emit(kind: kind, app: app, meta: [:]) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            // Permission missing — surface as `.disabled` on next actor hop.
            // Balance the passRetained so the actor isn't leaked.
            retained.release()
            Task { await self.markDisabled() }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let rl = CFRunLoopGetCurrent() else {
            retained.release()
            Task { await self.markDisabled() }
            return
        }
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Task { await self.retainTap(port: tap, source: source,
                                    runLoop: rl, refcon: retained) }
    }

    private func retainTap(port: CFMachPort,
                           source: CFRunLoopSource?,
                           runLoop: CFRunLoop,
                           refcon: Unmanaged<UIEventsMonitor>) {
        self.tapPort = port
        self.runLoopSource = source
        self.tapRunLoop = runLoop
        self.refconRetained = refcon
    }

    private func markDisabled() {
        state = .disabled
    }

    private func emit(kind: UIEvent.Kind, app: String?, meta: [String: String]) {
        // Debounce: max 1 per (app,kind) per second.
        let now = Date().timeIntervalSince1970
        let key = "\(app ?? "-")|\(kind.rawValue)"
        if let last = lastEmitted[key], now - last < 1.0 { return }
        // FIX(review-2026-07-28) C-M: cap the debounce map — see
        // `lastEmittedCap` declaration. New keys append to the order list;
        // once the cap is reached, evict the oldest key before inserting.
        if lastEmitted[key] == nil {
            if lastEmitted.count >= lastEmittedCap,
               let victim = lastEmittedOrder.first {
                lastEmittedOrder.removeFirst()
                lastEmitted.removeValue(forKey: victim)
            }
            lastEmittedOrder.append(key)
        }
        lastEmitted[key] = now
        handler?(UIEvent(kind: kind, timestamp: Date(), app: app, meta: meta))
    }
}
