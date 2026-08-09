//
//  OpenClickyOverlayLayerHost.swift
//  cursor-buddy
//
//  Root fix for the macOS 26 "overlay tile does not clear" bug.
//
//  Background — the bug we are working around:
//    On macOS 26, a borderless nonactivatingPanel at `.screenSaver`
//    level that has painted content does NOT drop its last composited
//    tile when we `orderOut(nil)` + `close()`. `window.isVisible`
//    reports `false`, but the pixels remain onscreen until an
//    unrelated event triggers WindowServer to recomposite. Every
//    workaround (alpha=0, level=.baseWindow, setFrame(.zero),
//    contentView=nil, sleep+runloop pump) has failed to force a
//    flush. Everywhere doesn't hit this because it hosts its overlays
//    via Avalonia CGLayer, not per-hotkey NSPanels.
//
//  The fix:
//    Never tear down a painted top-level window during the session
//    lifecycle. Instead, keep ONE fullscreen click-through NSWindow
//    per NSScreen alive for the entire app lifetime and hang CALayers
//    off its contentView.layer. Layer removal
//    (`removeFromSuperlayer()` inside a `CATransaction` with implicit
//    actions disabled) is not subject to the tile-cache bug —
//    WindowServer sees the parent window redraw immediately with the
//    sublayers gone.
//
//  This host is the shared substrate for:
//    * `OpenClickyLinkRectOverlayWindow` (Alt+L drag-to-select links)
//    * `OpenClickyWhiteboardOverlayWindow` (Alt+D press-hold ink)
//    * `OpenClickyPickElementOverlay`     (Alt+S AX pick)
//
//  It is intentionally separate from `OverlayWindowManager` /
//  `OverlayWindow` (which owns the cursor-buddy sprite and is only
//  live when the user has granted Accessibility + enabled the
//  cursor). The three hotkey overlays need to work even when the
//  cursor buddy is hidden, so they can't depend on that manager's
//  windows.
//
//  Mouse-event routing preserved:
//    Hotkey sessions still install global + local NSEvent monitors
//    (macOS 26 non-key-panel workaround). During a session we flip
//    `ignoresMouseEvents` to `false` on the host windows so drags
//    are absorbed and don't select text / initiate DnD in the app
//    beneath. When the session ends we flip it back to `true` so
//    the persistent host does not steal clicks system-wide.
//
//  Layer tree per screen:
//    hostContentView (NSView, wantsLayer=true)
//      └── layer  (CALayer, geometryFlipped=false so Cocoa y-up)
//            ├── session layers added by LinkRect  (named `linkrect.*`)
//            ├── session layers added by Whiteboard(named `whiteboard.*`)
//            └── session layer added by Pick       (named `pick.*`)
//
//  All coord math is Cocoa view-local (bottom-left origin) — the
//  same space the previous NSView drawing paths used. Sessions
//  convert Quartz-global (top-left origin) via the helpers on this
//  class so each session's CGRect math stays in one place.
//

import AppKit
import Foundation
import QuartzCore

@MainActor
final class OpenClickyOverlayLayerHost {
    static let shared = OpenClickyOverlayLayerHost()

    /// One host per NSScreen. Recreated when the display config
    /// changes (`NSApplication.didChangeScreenParametersNotification`).
    struct Host {
        let screen: NSScreen
        let window: LayerHostWindow
        let contentView: LayerHostContentView
        /// Convenience: the root CALayer sessions attach sublayers to.
        var rootLayer: CALayer { contentView.layer! }
    }

    private(set) var hosts: [Host] = []

    /// Counter of active mouse-capturing sessions. When > 0 the host
    /// windows are non-click-through (they intercept drags so the app
    /// underneath does not select text / start DnD). When == 0 they
    /// are fully click-through.
    private var mouseCaptureRefcount: Int = 0

    private var screenChangeObserver: NSObjectProtocol?

    private init() {
        installIfNeeded()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshForCurrentScreens()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    // MARK: - Installation

    /// Idempotent. Safe to call from any of the three hotkey sessions
    /// before they begin. If the host was never touched before app
    /// launch (e.g. cold path Alt+L press), this brings the windows
    /// up on demand.
    func ensureInstalled() {
        installIfNeeded()
    }

    private func installIfNeeded() {
        // Rebuild if screens changed (host count mismatch or a stale
        // screen frame). Cheap because there are typically 1-3 hosts.
        let currentScreens = NSScreen.screens
        if hosts.count == currentScreens.count,
           zip(hosts, currentScreens).allSatisfy({ $0.screen.frame == $1.frame }) {
            return
        }
        rebuild(for: currentScreens)
    }

    private func rebuild(for screens: [NSScreen]) {
        for old in hosts {
            old.window.orderOut(nil)
            old.window.close()
        }
        hosts.removeAll()

        for (idx, screen) in screens.enumerated() {
            let window = LayerHostWindow(screen: screen)
            let content = LayerHostContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.autoresizingMask = [.width, .height]
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            // The root layer uses Cocoa (bottom-left) y-up so we can
            // reuse the existing Quartz->view-local math from the
            // pre-refactor NSView drawing paths without another flip.
            content.layer?.isGeometryFlipped = false
            window.contentView = content
            window.orderFrontRegardless()
            // Default idle state: never eat mouse events. Sessions
            // opt into capture via `beginMouseCapture()`.
            window.ignoresMouseEvents = true

            HeyClickyLog.log(
                "openclicky.overlay_layer_host.installed",
                lane: "system",
                direction: "internal",
                [
                    "screen_idx": idx,
                    "screen_w": Int(screen.frame.width),
                    "screen_h": Int(screen.frame.height),
                    "window_num": window.windowNumber,
                    "level": window.level.rawValue,
                ]
            )

            hosts.append(Host(screen: screen, window: window, contentView: content))
        }
    }

    private func refreshForCurrentScreens() {
        // Preserve any in-flight session layers on the same-index host
        // when possible. The typical case is a display hot-plug; the
        // clean thing is to rebuild — sessions can survive a re-install
        // because we keep the same Host struct semantics. Any layers
        // attached to old hosts vanish with those hosts; sessions are
        // expected to gracefully re-attach on the next mouse event.
        let previousMouseCapture = mouseCaptureRefcount
        rebuild(for: NSScreen.screens)
        if previousMouseCapture > 0 {
            // Reapply the mouse-capture toggle to the new hosts.
            for host in hosts {
                host.window.ignoresMouseEvents = false
            }
        }
    }

    // MARK: - Screen lookup

    /// Return the host whose screen contains the given Cocoa-global
    /// (bottom-left origin) point, or nil if the point falls outside
    /// every attached display.
    func host(forCocoaGlobal point: CGPoint) -> Host? {
        hosts.first { $0.screen.frame.contains(point) }
    }

    /// Return the host for the primary display (`NSScreen.screens[0]`),
    /// or the first host if the primary can't be resolved.
    var primaryHost: Host? {
        hosts.first
    }

    // MARK: - Mouse-capture toggle

    /// Flip host windows to non-click-through so drag events are
    /// absorbed by AppKit (canBecomeKey=false blocks responder-chain
    /// routing, so nothing actually reacts — but the app underneath
    /// no longer sees the drag either). Balanced by
    /// `endMouseCapture()`. Refcounted so overlapping sessions
    /// compose sanely.
    func beginMouseCapture(reason: String) {
        installIfNeeded()
        mouseCaptureRefcount += 1
        if mouseCaptureRefcount == 1 {
            for host in hosts {
                host.window.ignoresMouseEvents = false
            }
        }
        HeyClickyLog.log(
            "openclicky.overlay_layer_host.mouse_capture_begin",
            lane: "system",
            direction: "internal",
            [
                "reason": reason,
                "refcount": mouseCaptureRefcount,
                "hosts": hosts.count,
            ]
        )
    }

    func endMouseCapture(reason: String) {
        mouseCaptureRefcount = max(0, mouseCaptureRefcount - 1)
        if mouseCaptureRefcount == 0 {
            for host in hosts {
                host.window.ignoresMouseEvents = true
            }
        }
        HeyClickyLog.log(
            "openclicky.overlay_layer_host.mouse_capture_end",
            lane: "system",
            direction: "internal",
            [
                "reason": reason,
                "refcount": mouseCaptureRefcount,
            ]
        )
    }

    // MARK: - Layer helpers

    /// Add a sublayer to a specific host's root layer. Implicit
    /// animations are disabled so the layer appears immediately.
    func attach(_ layer: CALayer, to host: Host) {
        // Restore visibility: prior dismiss set alpha=0 + orderOut.
        // A new session must bring window back before adding layers.
        if !host.window.isVisible {
            host.window.orderFrontRegardless()
        }
        if host.window.alphaValue < 1 {
            host.window.alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.rootLayer.addSublayer(layer)
        CATransaction.commit()
    }

    /// Remove a sublayer. Implicit animations disabled + parent layer
    /// marked dirty + window forced to redisplay synchronously — the
    /// critical path that fixes the macOS 26 bug. Removing the layer
    /// alone is not enough on macOS 26: the parent CALayer holding
    /// the sublayer has no backing store of its own (host contentView
    /// draws nothing), so its content flush is a no-op. WindowServer
    /// never gets a "new tile" signal and keeps the last composited
    /// pixels onscreen. We force it with `display()`.
    func detach(_ layer: CALayer) {
        detachAll([layer])
    }

    /// Bulk detach (single CATransaction + one forced redisplay per
    /// affected host).
    func detachAll(_ layers: [CALayer]) {
        var affected: [Host] = []
        for layer in layers {
            if let h = hostOwning(layer), !affected.contains(where: { $0.window === h.window }) {
                affected.append(h)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.removeFromSuperlayer()
        }
        // Belt-and-suspenders: drop every remaining sublayer per host.
        for h in affected {
            h.rootLayer.sublayers = nil
        }
        CATransaction.commit()
        CATransaction.flush()

        // The layer-removal-only path (even at NSStatusWindowLevel 25)
        // is unreliable on macOS 26 when the host is a persistent
        // borderless full-screen NSWindow with a clear layer-hosted
        // contentView — WindowServer keeps the last composited tile
        // pinned until an unrelated event forces a recomposite. Only
        // destroying the NSWindow itself reliably clears that tile.
        // Rebuild the host slot with a fresh NSWindow.
        rebuildHostWindows(for: affected)
    }

    private func rebuildHostWindows(for affected: [Host]) {
        // Everywhere byte-exact (VisualElementContext.LinkRect.cs:69):
        //   `await Dispatcher.UIThread.InvokeAsync(window!.Close);`
        // Fresh windows per session; close destroys them entirely.
        // macOS 26 tile-cache workaround: minimizing the window is the
        // one teardown path that reliably invokes WindowServer's
        // "region invalidated" flow (because macOS animates the
        // minimize itself). We shrink the window to 1×1 offscreen,
        // trigger miniaturize (which cancels immediately since the
        // window is at level 25 — not miniaturizable), then close.
        // The act of ATTEMPTING miniaturize wakes WindowServer.
        for old in affected {
            guard let idx = hosts.firstIndex(where: { $0.window === old.window }) else { continue }
            let newContent = LayerHostContentView(frame: NSRect(origin: .zero, size: old.screen.frame.size))
            newContent.autoresizingMask = [.width, .height]
            newContent.wantsLayer = true
            newContent.layer?.backgroundColor = NSColor.clear.cgColor
            newContent.layer?.isGeometryFlipped = false
            old.window.contentView = newContent
            old.window.viewsNeedDisplay = true
            old.window.display()
            old.window.alphaValue = 0
            old.window.orderOut(nil)
            HeyClickyLog.log(
                "openclicky.overlay_layer_host.after_dismiss_state",
                lane: "system",
                direction: "internal",
                [
                    "alpha": Double(old.window.alphaValue),
                    "isVisible": old.window.isVisible,
                    "windowNum": old.window.windowNumber,
                ]
            )
            hosts[idx] = Host(screen: old.screen, window: old.window, contentView: newContent)
        }

        // macOS 26 fix: our overlay host is at level 25, but the app's
        // cursor_overlay OverlayWindow sits at level 499 — higher.
        // WindowServer may be caching our host's last frame INSIDE
        // that higher window's backing store. Force it to redraw by
        // toggling its ordering: orderOut then orderFront.
        for w in NSApp.windows where w.isVisible && w.className.contains("OverlayWindow") {
            let level = w.level
            w.orderOut(nil)
            w.orderFrontRegardless()
            w.level = level
        }
        // Also ensure our host is fully teardown-flushed.
        for h in hosts {
            h.window.viewsNeedDisplay = true
            h.window.displayIfNeeded()
        }

        // macOS 26 WindowServer tile-cache workaround.
        let loc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzLoc = CGPoint(x: loc.x, y: primaryHeight - loc.y)
        let src = CGEventSource(stateID: .combinedSessionState)
        if let ev = CGEvent(mouseEventSource: src,
                            mouseType: .mouseMoved,
                            mouseCursorPosition: quartzLoc,
                            mouseButton: .left) {
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Find the host whose rootLayer is an ancestor of the given layer.
    private func hostOwning(_ layer: CALayer) -> Host? {
        var cursor: CALayer? = layer.superlayer ?? layer
        while let c = cursor {
            for h in hosts {
                if c === h.rootLayer { return h }
            }
            cursor = c.superlayer
        }
        return hosts.first
    }

    // MARK: - Coordinate helpers

    /// Convert a Quartz global rect (top-left origin, primary-screen
    /// anchored) into a rect in the given host's contentView local
    /// coord space (Cocoa, bottom-left origin, screen-anchored).
    static func viewLocalRect(fromQuartzGlobal quartzRect: CGRect,
                              on host: Host) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Quartz top-left -> Cocoa global bottom-left.
        let cocoaGlobalY = primaryHeight - quartzRect.origin.y - quartzRect.size.height
        // Cocoa global -> view-local (subtract screen origin because
        // the contentView fills the window which is anchored at the
        // screen origin).
        let localX = quartzRect.origin.x - host.screen.frame.origin.x
        let localY = cocoaGlobalY - host.screen.frame.origin.y
        return CGRect(x: localX, y: localY, width: quartzRect.width, height: quartzRect.height)
    }

    /// Convert a Cocoa global point (bottom-left origin) into a point
    /// in the given host's local coord space.
    static func viewLocalPoint(fromCocoaGlobal cocoa: CGPoint,
                               on host: Host) -> CGPoint {
        CGPoint(
            x: cocoa.x - host.screen.frame.origin.x,
            y: cocoa.y - host.screen.frame.origin.y
        )
    }
}

// MARK: - Persistent host NSWindow / contentView

/// Fullscreen host window living at the cursor-overlay level for the
/// life of the app. Never orderedOut / closed in normal operation —
/// only rebuilt on display config change. That is the entire point:
/// the WindowServer tile stays owned by this window and its
/// sublayers come and go without disturbing it.
@MainActor
final class LayerHostWindow: NSPanel {
    init(screen: NSScreen) {
        // Borderless NSPanel (no titlebar). Drag-rect anchor was
        // shifting down when this used `.titled` NSWindow because
        // titled windows preserve a titlebar-height inset even with
        // fullSizeContentView. Back to borderless NSPanel.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        // hasShadow = true (Avalonia default). Without a shadow region
        // WindowServer on macOS 26 does not redraw the window's screen
        // area when the window closes — the previous tile is kept until
        // an unrelated event forces recomposite. A clear shadow makes
        // WindowServer treat close() as a "region invalidated" event.
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = false
        // Sit at the same level as the cursor buddy overlay so we
        // paint above app windows / menu bar surfaces but below drag
        // images. `applyCursorOverlayLevel` also matches the level
        // used by `OverlayWindow`, `OpenClickyAnnotationBadgeOverlay`,
        // and the pre-refactor per-hotkey NSPanels — so the visual
        // z-ordering does not change.
        // Everywhere byte-exact: NSStatusWindowLevel = 25 (WindowHelper.cs:364).
        // Prior attempts used the higher `.cursorOverlay` (499) level which
        // triggers a macOS 26 WindowServer regression that keeps the last
        // composited tile onscreen after teardown. Level 25 does not exhibit
        // this behavior — Avalonia's overlays work because they live here.
        self.level = NSWindow.Level(rawValue: 25)
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        self.setFrame(screen.frame, display: false)
        self.setFrameOrigin(screen.frame.origin)
    }

    // macOS 26 SIGABRT fix: canBecomeKey=false on borderless
    // nonactivatingPanel routes orderFront through the sheet-detection
    // path in AppKit which trips an NSRemoteView observer. We never
    // need key status — mouse capture is via NSEvent monitors, not
    // responder chain.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// contentView backing the persistent host. Layer-hosting; also
/// implements hitTest so that when `ignoresMouseEvents = false` the
/// window swallows drags but does not become the first responder
/// (matches the pre-refactor `canBecomeKey = false` panels).
@MainActor
final class LayerHostContentView: NSView {
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // When the host window is click-through (`ignoresMouseEvents
        // = true`), AppKit never calls this. When the host is set to
        // eat mouse (session active), returning `self` lets the
        // window swallow the click so it doesn't reach the app
        // underneath. Global NSEvent monitors installed by the
        // session still fire and drive the gesture state machine.
        return self
    }
}
