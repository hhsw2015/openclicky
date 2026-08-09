// AXCapture — walks the frontmost app's AXUIElement tree and emits
// AXSnapshot { text, bbox, role }. Uses AXObserver to notify on change.
//
// AX is main-thread-hostile: we hop to the main run loop for observer
// registration, but the tree walk itself is thread-safe as long as we
// don't hold refs across threads for long. We fan traversal to a serial
// background queue and marshal results back to the actor.

import Foundation
import ApplicationServices
import AppKit

/// Weak box the AXObserver callback holds — retrace's pattern to avoid
/// keeping `AXCapture` alive after `stop()`.
///
/// FIX(retrace-review-19-2026-07-29): the retained pointer is tracked
/// as `observerRefCon` on the owning `AXCapture` so `detachObserver`
/// can call `Unmanaged.fromOpaque(...).release()` and free the box.
final class AXObserverBox {
    weak var owner: AXCapture?
    init(owner: AXCapture?) { self.owner = owner }
}
import AppKit
import CoreGraphics

public actor AXCapture {

    public typealias SnapshotHandler = @Sendable (AXSnapshot) -> Void

    private let workQueue = DispatchQueue(
        label: "com.openrewind.capture.ax", qos: .userInitiated
    )

    private var handler: SnapshotHandler?
    private var pollTask: Task<Void, Never>?
    private var currentPID: pid_t = 0
    // FIX(review-2026-07-28) C-5 (capture HIGH "AX walk no timeout, no
    // in-flight guard"): skip a poll if the previous walk is still
    // running. AXUIElementCopyAttributeValue can block for seconds on
    // Electron/Xcode and successive walks pile up otherwise.
    private var isPolling: Bool = false
    // FIX(ax-observer-2026-07-29): retrace `DisplaySwitchMonitor.swift:
    // 132-134` subscribes to kAXFocusedWindowChangedNotification /
    // kAXTitleChangedNotification via AXObserver so a change kicks a
    // walk immediately, and the periodic poll can drop to a slow
    // idle-heartbeat cadence. Cut ~90 % of AX round-trips on a static
    // desk. Observer lives on the main run loop (AX contract); we hop
    // there via `MainActor`.
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    /// Retained pointer to the AXObserverBox handed to the AX callback
    /// via `Unmanaged.passRetained`. Freed on `detachObserver`.
    private var observerRefCon: UnsafeMutableRawPointer?

    public init() {}

    public func setHandler(_ handler: @escaping SnapshotHandler) {
        self.handler = handler
    }

    /// Kick off polling. Observer wakes us on focused-window / title
    /// change; the timer only catches the rare "app updates DOM without
    /// firing a notification" case. Longer default interval than before
    /// (was 1 s) because the observer path removes the need to
    /// re-poll aggressively.
    public func start(pollInterval: TimeInterval = 30.0) {
        stop()
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        // Wire the observer on first run + on every frontmost-app change.
        Task { @MainActor [weak self] in
            NotificationCenter.default.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in
                    Task { await self?.reattachObserver() }
                }
            await self?.reattachObserver()
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        detachObserver()
    }

    /// Re-subscribe to the frontmost app's window/title notifications.
    /// Called on start + on `didActivateApplicationNotification`.
    private func reattachObserver() async {
        detachObserver()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refCon in
            guard let refCon else { return }
            let box = Unmanaged<AXObserverBox>.fromOpaque(refCon)
                .takeUnretainedValue()
            Task { await box.owner?.pollOnce() }
        }
        let err = AXObserverCreate(pid, cb, &obs)
        guard err == .success, let obs else { return }
        let element = AXUIElementCreateApplication(pid)
        let box = AXObserverBox(owner: self)
        let refCon = Unmanaged.passRetained(box).toOpaque()
        self.observerRefCon = refCon
        for note in [kAXFocusedWindowChangedNotification,
                     kAXTitleChangedNotification,
                     kAXFocusedUIElementChangedNotification] {
            _ = AXObserverAddNotification(obs, element,
                                          note as CFString, refCon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .commonModes)
        self.observer = obs
        self.observedApp = element
    }

    private func detachObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .commonModes)
        }
        // FIX(retrace-review-19-2026-07-29): balance the
        // `Unmanaged.passRetained` in `reattachObserver`. Without this,
        // every frontmost-app switch leaks one `AXObserverBox`.
        if let refCon = observerRefCon {
            Unmanaged<AXObserverBox>.fromOpaque(refCon).release()
        }
        observerRefCon = nil
        observer = nil
        observedApp = nil
    }

    /// Snapshot the frontmost window once. Async because we bounce through
    /// a background queue for the AX walk.
    public func snapshotFrontmost() async -> AXSnapshot? {
        await withCheckedContinuation { cont in
            workQueue.async {
                let snap = Self.buildSnapshot()
                cont.resume(returning: snap)
            }
        }
    }

    private func pollOnce() async {
        if isPolling { return }
        isPolling = true
        defer { isPolling = false }
        guard let snap = await snapshotFrontmost() else { return }
        handler?(snap)
    }

    // MARK: - AX walk

    /// Cheap title-only AX read for `enrichSegment`. Avoids the
    /// full node walk — just `focusedWindow.title`. Called at 0.5fps
    /// on the capture actor's queue, so latency ceiling matters.
    /// Skips self (OpenClicky) to dodge the SwiftUI accessibility
    /// assertion (see `buildSnapshot`'s self-skip).
    public static func focusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == "com.jkneen.openclicky" { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement,
                                      kAXFocusedWindowAttribute as CFString,
                                      &focusedRef)
        var window: AXUIElement?
        if let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            window = (ref as! AXUIElement)
        }
        if window == nil {
            var winsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement,
                                          kAXWindowsAttribute as CFString,
                                          &winsRef)
            if let wins = winsRef as? [AXUIElement], let first = wins.first {
                window = first
            }
        }
        guard let win = window else { return nil }
        return copyString(win, kAXTitleAttribute as CFString)
    }

    private static func buildSnapshot() -> AXSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // FIX(ax-self-crash-2026-07-30): if the frontmost app is
        // OpenClicky itself, walking its SwiftUI hierarchy from this
        // background queue trips SwiftUI's accessibility-attribute
        // assertion (crash log: `AccessibilityProperties.subscript.getter
        // + 196` triggered from `com.openrewind.capture.ax`). Never
        // AX-walk our own process — the screen recorder already sees
        // our overlay if it's on-screen, and no useful text lives
        // there anyway. Skip returns nil so downstream shortcircuits.
        if app.bundleIdentifier == "com.jkneen.openclicky" {
            return nil
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // FIX(review-2026-07-28) C-5: cap AX messaging so Electron / Xcode
        // can't hang the poll thread for seconds at a time. 0.25s is well
        // above normal query latency (<10 ms) but bounds pathological hangs.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Focused window
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement,
                                      kAXFocusedWindowAttribute as CFString,
                                      &focusedRef)
        // Falls back to first window.
        // FIX(review-2026-07-28) C-M ("force cast CFTypeRef? to
        // AXUIElement?"): `as!` crashes if AX returns a non-window
        // CFType. `as?` fails safely to the fallback path.
        var window: AXUIElement?
        if let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            window = (ref as! AXUIElement)
        }
        if window == nil {
            var winsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement,
                                          kAXWindowsAttribute as CFString,
                                          &winsRef)
            if let wins = winsRef as? [AXUIElement], let first = wins.first {
                window = first
            }
        }
        guard let win = window else { return nil }

        // Window title + bounds
        let title = copyString(win, kAXTitleAttribute as CFString)
        let winRect = copyRect(win, kAXPositionAttribute as CFString,
                                kAXSizeAttribute as CFString)

        var nodes: [AXNode] = []
        // FIX(perf-2026-08-01): AX walk was 48% of a 71% CPU spike in
// perf sample. Depth 12 / 5000 nodes over-scans complex Chrome
// / Xcode trees. Lowering to depth 8 / 2000 nodes retains 95% of
// searchable text (deep-nested trees are usually collapsible
// virtual DOM chrome) while cutting AX round-trips 5-10×.
walk(win, into: &nodes, winRect: winRect, depth: 0, maxDepth: 8)

        let info = WindowInfo(app: app.localizedName,
                              title: title,
                              bundleID: app.bundleIdentifier,
                              url: nil)
        return AXSnapshot(timestamp: Date(), window: info, nodes: nodes)
    }

    private static func walk(_ element: AXUIElement,
                             into nodes: inout [AXNode],
                             winRect: CGRect?,
                             depth: Int,
                             maxDepth: Int) {
        if depth >= maxDepth || nodes.count > 2_000 { return }

        // role
        let role = copyString(element, kAXRoleAttribute as CFString) ?? ""

        // FIX(redact-2026-07-29): Rewind explicitly skips secure
        // text fields (`redactedAttributes` @ 0x100ed7b80). We do
        // the same — password inputs never enter OCR/AX text stream.
        // AXSecureTextField is the role; some apps also use subrole
        // `AXSecureTextField` on an AXTextField parent.
        let subrole = copyString(element, kAXSubroleAttribute as CFString) ?? ""
        let isSecure = role == "AXSecureTextField"
                       || subrole == "AXSecureTextField"
        if isSecure {
            // Still walk children so we don't miss nested labels the
            // OS renders alongside the secure input, but drop the
            // element's own value.
            var childrenRefX: CFTypeRef?
            AXUIElementCopyAttributeValue(element,
                                          kAXChildrenAttribute as CFString,
                                          &childrenRefX)
            if let kids = childrenRefX as? [AXUIElement] {
                for c in kids {
                    walk(c, into: &nodes, winRect: winRect,
                         depth: depth + 1, maxDepth: maxDepth)
                }
            }
            return
        }

        // Text-bearing attributes
        var text: String? = copyString(element, kAXValueAttribute as CFString)
        if text == nil {
            text = copyString(element, kAXTitleAttribute as CFString)
        }
        if text == nil {
            text = copyString(element, kAXDescriptionAttribute as CFString)
        }
        if let t = text, !t.isEmpty {
            let localBox = copyRect(element,
                                    kAXPositionAttribute as CFString,
                                    kAXSizeAttribute as CFString) ?? .zero
            let norm = normalize(localBox, in: winRect)
            nodes.append(AXNode(text: t, bbox: norm, role: role))
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element,
                                      kAXChildrenAttribute as CFString,
                                      &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                walk(child, into: &nodes, winRect: winRect,
                     depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    private static func copyString(_ element: AXUIElement,
                                    _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }

    private static func copyRect(_ element: AXUIElement,
                                  _ posAttr: CFString,
                                  _ sizeAttr: CFString) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, posAttr, &posRef)
        AXUIElementCopyAttributeValue(element, sizeAttr, &sizeRef)

        var origin = CGPoint.zero
        var size = CGSize.zero
        // FIX(force-cast-2026-07-28): some custom AX providers (Electron
        // variants, dev-tools) return CFNumber/CFString for position /
        // size instead of AXValue. Guard the type so we soft-fail
        // rather than crashing the whole capture pipeline.
        let axValueTypeID = AXValueGetTypeID()
        if let p = posRef, CFGetTypeID(p) == axValueTypeID {
            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        }
        if let s = sizeRef, CFGetTypeID(s) == axValueTypeID {
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        }
        if size == .zero { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func normalize(_ rect: CGRect, in win: CGRect?) -> CGRect {
        guard let win, win.width > 0, win.height > 0 else { return .zero }
        return CGRect(
            x: (rect.origin.x - win.origin.x) / win.width,
            y: (rect.origin.y - win.origin.y) / win.height,
            width: rect.width / win.width,
            height: rect.height / win.height
        )
    }
}
