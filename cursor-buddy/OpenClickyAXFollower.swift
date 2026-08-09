//
//  OpenClickyAXFollower.swift
//  cursor-buddy
//
//  Phase 7.1 (Layer 4 UX): delta-follow helper for the annotation
//  badge overlay. Given a pinned AX element, `OpenClickyAXFollower`
//  fires a callback whenever the element's bounding rectangle
//  changes so the badge / outline can slide to the new coords.
//
//  Two-mode implementation:
//
//    * AXObserver primary — installs an AXObserver on the app owning
//      the element and listens for `kAXValueChangedNotification`,
//      `kAXWindowMovedNotification`, `kAXWindowResizedNotification`.
//      When any fires, we re-read the target's bounds and invoke the
//      callback. Callbacks land on the main run loop because we add
//      the observer's run-loop source to the main runloop.
//
//    * Poll fallback — a 50 ms `DispatchSourceTimer` re-reads the
//      bounds and diffs them against the last-known rect. Used when
//      `AXObserverCreate` fails (Electron with hardened AX opt-out,
//      restricted apps) or when the observer setup succeeds but the
//      target's app doesn't emit any of the notifications we listen
//      for.
//
//  The fallback timer runs unconditionally at a low rate so the
//  overlay stays snappy even if the observer misses a notification;
//  the timer is cheap because a single AX bounds read for one element
//  is a handful of microseconds when the target is cached in the
//  local process's AX runtime.
//

import AppKit
import ApplicationServices
import Foundation

/// Reports a fresh AX bounding rect (Quartz top-left coordinates)
/// for the followed element. Nil means the element vanished (window
/// closed, app quit, AX tree torn down) — the caller should hide the
/// overlay until a valid rect returns.
typealias OpenClickyAXFollowerCallback = @MainActor (CGRect?) -> Void

@MainActor
final class OpenClickyAXFollower {
    /// Fallback poll interval. 50 ms mirrors Everywhere's
    /// `AnnotationOverlayHost.cs:76` (`DispatcherTimer.Interval =
    /// TimeSpan.FromMilliseconds(50)`); Everywhere's comment at
    /// `:71-74` records that "150 ms was perceptibly laggy" so 50 ms
    /// is deliberate. AX bounds reads for a single element are ~µs
    /// when the AX runtime cache is warm, so the timer stays cheap.
    // FIX(perf-2026-08-01): 20 Hz caused perceptible main-thread jank
    // (Agent C audit finding HIGH). AX bounds reads are cheap but the
    // sync `AXUIElementCopyAttributeValue` round-trip to the target
    // app is not, and each follower ran on the main queue. 10 Hz is
    // still snappy for cursor-follow and halves main-thread load.
    private static let pollInterval: TimeInterval = 0.1

    private let element: AXUIElement
    private let onChange: OpenClickyAXFollowerCallback

    private var observer: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var timer: DispatchSourceTimer?
    private var lastRect: CGRect?
    private var stopped = false

    init(element: AXUIElement, onChange: @escaping OpenClickyAXFollowerCallback) {
        self.element = element
        self.onChange = onChange
    }

    deinit {
        // Deinit runs on whatever thread released us. Tear down the
        // AX observer & timer synchronously; both APIs are thread-safe
        // for the cleanup calls used here.
        if let observer {
            let src = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        timer?.cancel()
    }

    /// Begin observing. Call once. Fires an initial callback with the
    /// current bounds so the caller doesn't have to also plumb the
    /// initial position.
    func start() {
        guard !stopped, observer == nil, timer == nil else { return }

        installObserver()
        installFallbackTimer()

        let initial = Self.readBounds(element)
        lastRect = initial
        onChange(initial)
    }

    /// Stop observing. Safe to call multiple times.
    func stop() {
        stopped = true
        if let observer {
            let src = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            for target in observedElements {
                for notif in Self.observedNotifications {
                    _ = AXObserverRemoveNotification(observer, target, notif as CFString)
                }
            }
        }
        observer = nil
        observedElements.removeAll()
        timer?.cancel()
        timer = nil
    }

    // MARK: - Observer setup

    private static let observedNotifications: [String] = [
        kAXValueChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    private func installObserver() {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            return
        }

        var observerRef: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let follower = Unmanaged<OpenClickyAXFollower>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            // Callbacks arrive on the main runloop already (we added
            // the source to `CFRunLoopGetMain`), but we still hop
            // through the main actor so Swift concurrency stays happy.
            Task { @MainActor [weak follower] in
                follower?.refresh()
            }
        }

        let createResult = AXObserverCreate(pid, callback, &observerRef)
        guard createResult == .success, let observerRef else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Register the notifications against the target itself AND
        // against the owning window (best-effort) so we hear about
        // window moves that don't fire value-changed on the leaf.
        var targets: [AXUIElement] = [element]
        if let window = Self.copyWindowAncestor(element) {
            targets.append(window)
        }

        var anyInstalled = false
        for target in targets {
            var installedForTarget = false
            for notif in Self.observedNotifications {
                let result = AXObserverAddNotification(observerRef, target, notif as CFString, refcon)
                if result == .success {
                    anyInstalled = true
                    installedForTarget = true
                }
            }
            // Only track the target once per successful installation
            // — `stop()` iterates every element × every notification
            // anyway, so storing it four times causes 4×N spurious
            // `AXObserverRemoveNotification` calls (macOS returns
            // -25204 not-registered for the extras, harmless but
            // noisy). Dedup by AX ref identity.
            if installedForTarget,
               !observedElements.contains(where: { CFEqual($0, target) }) {
                observedElements.append(target)
            }
        }

        if !anyInstalled {
            // No notification took — treat the observer as failed; the
            // poll fallback carries us the rest of the way.
            return
        }

        let source = AXObserverGetRunLoopSource(observerRef)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.observer = observerRef
    }

    private func installFallbackTimer() {
        // FIX(perf-2026-08-01): moved AX bounds polling OFF main queue
        // per audit finding #6. Every tick performs a synchronous AX
        // round-trip to the target app (10-300 ms tail latency) —
        // running that on .main was directly competing with cursor
        // overlay updates. Poll on a background queue and hop to main
        // only when the result actually changed.
        let bg = DispatchQueue(label: "openclicky.axfollower.poll",
                                qos: .utility)
        let src = DispatchSource.makeTimerSource(queue: bg)
        src.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        src.setEventHandler { [weak self] in
            self?.refresh()
        }
        src.resume()
        self.timer = src
    }

    // MARK: - Refresh

    private func refresh() {
        if stopped { return }
        let rect = Self.readBounds(element)
        if rect == lastRect { return }
        lastRect = rect
        onChange(rect)
    }

    // MARK: - AX helpers

    private static func readBounds(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else {
            return nil
        }
        // AXValueRef unpack. If either read gives us a plain CFType we
        // can't cast, bail — the element is likely dead.
        guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        let posValue = positionRef as! AXValue
        // swiftlint:disable:next force_cast
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetValue(posValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        if size.width <= 0 || size.height <= 0 { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyWindowAncestor(_ element: AXUIElement) -> AXUIElement? {
        var cursor = element
        for _ in 0..<20 {
            var parentRef: CFTypeRef?
            let ok = AXUIElementCopyAttributeValue(cursor, kAXParentAttribute as CFString, &parentRef)
            guard ok == .success, let parentRef else { return nil }
            if CFGetTypeID(parentRef) != AXUIElementGetTypeID() { return nil }
            // swiftlint:disable:next force_cast
            let parent = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == kAXWindowRole {
                return parent
            }
            cursor = parent
        }
        return nil
    }
}
