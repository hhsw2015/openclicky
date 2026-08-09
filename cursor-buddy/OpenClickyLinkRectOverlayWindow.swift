// OpenClickyLinkRectOverlayWindow.swift
// cursor-buddy
//
// macOS 26 root-fix refactor (2026-07-23):
//   Previously this file installed one borderless nonactivatingPanel
//   per NSScreen at `.screenSaver` level and tore them down on
//   dismiss. macOS 26 has a WindowServer regression where such a
//   window's last composited tile does NOT clear on orderOut+close
//   even though `isVisible` reports false; the pixels linger until
//   an unrelated event forces a recomposite. Every attempted
//   workaround (alpha=0, level=.baseWindow, setFrame(.zero),
//   contentView=nil, sleep+runloop pump) has failed.
//
// The fix used here: don't take a window down. Attach CALayers to
// the process-wide `OpenClickyOverlayLayerHost` (a persistent
// fullscreen window per screen that is always alive) and remove the
// layers on dismiss. Layer removal is not subject to the tile-cache
// bug — WindowServer recomposites the host window on the next
// display cycle with the sublayers gone.
//
// Public contract preserved:
//   * `OpenClickyLinkRectOverlayWindow.present(completion:)` — same
//     signature, still returns an instance the caller retains and
//     later calls `dismiss()` on.
//   * `highlightCapturedLinks(rects:)`, `logFlashEnd(rectCount:)`,
//     `dismiss()`, `cancel()` — same signatures.
//   * `Result.rect(CGRect)` / `.cancelled` — same enum.
//   * Harvest -> flash 700ms -> dismiss -> launch-phrase order is
//     driven by `OpenClickyContextHotkeys.harvestAndPersistLinkRect`,
//     which is untouched.
//
// Byte-exact-port references preserved from the previous
// implementation (Everywhere @30e03e9d):
//   * Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs:28-72
//     — `LinkRectSession.HarvestAsync` lifecycle
//   * Everywhere.Mac/Interop/ScreenSelectionSession.cs:37-115 —
//     per-screen mask geometry
//   * Everywhere.Core/Views/ScreenSelection/ScreenSelectionWindow.cs:
//     74-93 — visual composition (black tint α=0.4, white 2px border)
//   * ScreenSelectionWindow.cs:122-154 — aqua flash rectangles for
//     captured links (#FF00C8FF stroke, #4000C8FF 25% fill)
//
// Divergence documented at the black tint: user feedback 2026-07-23
// softened the tint to α=0.2 because macOS 26's brightness curve
// made 0.4 too dark to aim through.
//

import AppKit
import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class OpenClickyLinkRectOverlayWindow {

    /// Result completed by the session. `.rect` when the user
    /// finishes a non-empty drag, `.cancelled` on Esc / right-click /
    /// empty drag.
    enum Result {
        case rect(CGRect) // Quartz global, top-left origin
        case cancelled
    }

    // Per-host layer set. One entry per NSScreen host, owned by this
    // session. All sublayers ride under `container` so a single
    // `removeFromSuperlayer()` in `dismiss()` tears down everything
    // this session drew on that host.
    private struct SessionHost {
        let host: OpenClickyOverlayLayerHost.Host
        let container: CALayer          // parent for every layer below
        let tintLayer: CAShapeLayer     // black α=0.2 tint with the drag-rect hole punched
        let borderLayer: CAShapeLayer   // 2px white outline around the drag rect
        var flashLayer: CAShapeLayer?   // aqua highlights for captured links (installed at flash time)
    }

    private var sessionHosts: [SessionHost] = []
    private var completion: ((Result) -> Void)?
    private var didFire = false
    private var strongSelf: OpenClickyLinkRectOverlayWindow?

    /// NSEvent monitor handles. macOS 26 SIGABRT fix keeps overlay
    /// panels non-key, so NSView mouseDown/Dragged/Up never fire on
    /// the responder chain. We drive drag input via global + local
    /// NSEvent monitors instead (mirrors OpenClickyPickElementOverlay).
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseDraggedMonitor: Any?
    private var localMouseDraggedMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var localEscapeMonitor: Any?
    private var isDragging = false

    /// Anchor + current point in Quartz global (top-left) coords.
    /// Used by handleMouseDragged/Up and by the currentQuartzRect
    /// accessor.
    private var anchorQuartz: CGPoint?
    private var currentQuartz: CGPoint?

    /// Shared color / geometry constants. Sourced from the pre-refactor
    /// NSView draw path so we render pixel-identically.
    private static let tintColor: CGColor = NSColor(white: 0.0, alpha: 0.2).cgColor
    private static let borderColor: CGColor = NSColor.white.cgColor
    private static let flashBorderColor: CGColor =
        NSColor(red: 0.0, green: 200.0 / 255.0, blue: 1.0, alpha: 1.0).cgColor
    private static let flashFillColor: CGColor =
        NSColor(red: 0.0, green: 200.0 / 255.0, blue: 1.0, alpha: 0.25).cgColor

    /// Show a fresh overlay. `completion` is invoked exactly once on
    /// the main queue when the drag finishes or the user cancels.
    ///
    /// Everywhere-parity contract (VisualElementContext.LinkRect.cs:57-70):
    /// on `.rect(_)` the overlay STAYS ALIVE so the caller can flash
    /// the highlight over the captured links (700ms in Everywhere).
    /// The caller MUST invoke `dismiss()` once it has consumed the
    /// rect — otherwise the overlay lingers on screen and steals
    /// mouse input. On `.cancelled` the overlay dismisses itself
    /// internally.
    static func present(completion: @escaping (Result) -> Void) -> OpenClickyLinkRectOverlayWindow {
        let overlay = OpenClickyLinkRectOverlayWindow()
        overlay.completion = completion
        overlay.strongSelf = overlay
        overlay.installOnAllScreens()
        return overlay
    }

    private init() {}

    // MARK: - Installation

    private func installOnAllScreens() {
        // Bring the persistent host up if it hasn't been touched yet
        // (cold-path Alt+L press before the cursor buddy overlay is
        // ever installed).
        OpenClickyOverlayLayerHost.shared.ensureInstalled()
        // Session is going to eat drags so the app underneath doesn't
        // interpret them as text selection / DnD.
        OpenClickyOverlayLayerHost.shared.beginMouseCapture(reason: "linkrect")

        let hosts = OpenClickyOverlayLayerHost.shared.hosts
        for (idx, host) in hosts.enumerated() {
            let container = CALayer()
            container.frame = host.contentView.bounds
            container.masksToBounds = false
            container.name = "linkrect.container"

            let tintLayer = CAShapeLayer()
            tintLayer.frame = host.contentView.bounds
            tintLayer.fillColor = Self.tintColor
            tintLayer.fillRule = .evenOdd
            tintLayer.name = "linkrect.tint"
            tintLayer.path = CGPath(rect: host.contentView.bounds, transform: nil)

            let borderLayer = CAShapeLayer()
            borderLayer.frame = host.contentView.bounds
            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.strokeColor = Self.borderColor
            borderLayer.lineWidth = 2
            borderLayer.name = "linkrect.border"
            borderLayer.path = nil

            OpenClickyOverlayLayerHost.shared.attach(container, to: host)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.addSublayer(tintLayer)
            container.addSublayer(borderLayer)
            CATransaction.commit()

            sessionHosts.append(SessionHost(
                host: host,
                container: container,
                tintLayer: tintLayer,
                borderLayer: borderLayer,
                flashLayer: nil
            ))

            HeyClickyLog.log(
                "openclicky.linkrect_overlay.install_panel",
                lane: "system",
                direction: "internal",
                [
                    "screen_idx": idx,
                    "cocoa_origin_x": Int(host.screen.frame.origin.x),
                    "cocoa_origin_y": Int(host.screen.frame.origin.y),
                    "size_w": Int(host.screen.frame.width),
                    "size_h": Int(host.screen.frame.height),
                    "level": host.window.level.rawValue,
                    "backing_scale": Int(host.window.backingScaleFactor),
                ]
            )
        }
        // Force the app frontmost so Option-L doesn't race the
        // browser's own Option+L. Same as the pre-refactor path.
        NSApp.activate(ignoringOtherApps: true)

        HeyClickyLog.log(
            "openclicky.linkrect_overlay.begin",
            lane: "system",
            direction: "internal",
            [
                "panel_count": sessionHosts.count,
            ]
        )

        installEventMonitors()
    }

    // MARK: - Event monitors (macOS 26 non-key window workaround)

    private func installEventMonitors() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            self?.handleMouseDown()
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.handleMouseDown()
            return event
        }

        globalMouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] _ in
            self?.handleMouseDragged()
        }
        localMouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] event in
            self?.handleMouseDragged()
            return event
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            self?.handleMouseUp()
        }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseUp()
            return event
        }

        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { [weak self] _ in
            self?.handleCancelFromMonitor(reason: "right_click")
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.handleCancelFromMonitor(reason: "escape")
                return nil
            }
            return event
        }
    }

    private func teardownEventMonitors() {
        for monitor in [
            globalMouseDownMonitor,
            localMouseDownMonitor,
            globalMouseDraggedMonitor,
            localMouseDraggedMonitor,
            globalMouseUpMonitor,
            localMouseUpMonitor,
            globalRightClickMonitor,
            localEscapeMonitor,
        ] {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalMouseDownMonitor = nil
        localMouseDownMonitor = nil
        globalMouseDraggedMonitor = nil
        localMouseDraggedMonitor = nil
        globalMouseUpMonitor = nil
        localMouseUpMonitor = nil
        globalRightClickMonitor = nil
        localEscapeMonitor = nil
    }

    /// Convert `NSEvent.mouseLocation` (Cocoa global, bottom-left,
    /// primary-screen origin) into Quartz global (top-left,
    /// primary-screen origin).
    private func cursorQuartz() -> (cocoa: CGPoint, quartz: CGPoint) {
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        return (cocoa, quartz)
    }

    /// Current Quartz global (top-left origin) drag rect, or nil if
    /// no active drag.
    private var currentQuartzRect: CGRect? {
        guard let a = anchorQuartz, let c = currentQuartz else { return nil }
        let minX = min(a.x, c.x)
        let minY = min(a.y, c.y)
        let maxX = max(a.x, c.x)
        let maxY = max(a.y, c.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func handleMouseDown() {
        guard !didFire else { return }
        let (cocoa, quartz) = cursorQuartz()
        let screenIdx = NSScreen.screens.firstIndex { $0.frame.contains(cocoa) } ?? -1
        isDragging = true
        anchorQuartz = quartz
        currentQuartz = quartz
        HeyClickyLog.log(
            "openclicky.linkrect_overlay.mouse_down_anchor",
            lane: "system",
            direction: "internal",
            [
                "cocoa_x": Int(cocoa.x),
                "cocoa_y": Int(cocoa.y),
                "quartz_x": Int(quartz.x),
                "quartz_y": Int(quartz.y),
                "on_screen_idx": screenIdx,
            ]
        )
        renderDragRect()
    }

    private func handleMouseDragged() {
        guard !didFire, isDragging else { return }
        let (cocoa, quartz) = cursorQuartz()
        currentQuartz = quartz
        renderDragRect()

        if let rectQuartz = currentQuartzRect {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let rectCocoaY = primaryHeight - rectQuartz.origin.y - rectQuartz.size.height
            HeyClickyLog.log(
                "openclicky.linkrect_overlay.mouse_drag_current",
                lane: "system",
                direction: "internal",
                [
                    "cocoa_x": Int(cocoa.x),
                    "cocoa_y": Int(cocoa.y),
                    "quartz_x": Int(quartz.x),
                    "quartz_y": Int(quartz.y),
                    "rect_cocoa_x": Int(rectQuartz.origin.x),
                    "rect_cocoa_y": Int(rectCocoaY),
                    "rect_cocoa_w": Int(rectQuartz.size.width),
                    "rect_cocoa_h": Int(rectQuartz.size.height),
                    "rect_quartz_x": Int(rectQuartz.origin.x),
                    "rect_quartz_y": Int(rectQuartz.origin.y),
                    "rect_quartz_w": Int(rectQuartz.size.width),
                    "rect_quartz_h": Int(rectQuartz.size.height),
                ]
            )
        }
    }

    private func handleMouseUp() {
        guard !didFire, isDragging else { return }
        isDragging = false
        let (_, quartz) = cursorQuartz()
        currentQuartz = quartz
        let finalRect = currentQuartzRect ?? .zero
        HeyClickyLog.log(
            "openclicky.linkrect_overlay.mouse_up",
            lane: "system",
            direction: "internal",
            [
                "quartz_x": Int(quartz.x),
                "quartz_y": Int(quartz.y),
                "rect_w": Int(finalRect.width),
                "rect_h": Int(finalRect.height),
            ]
        )
        finish(finalRect: finalRect)
    }

    private func handleCancelFromMonitor(reason: String) {
        guard !didFire else { return }
        HeyClickyLog.log(
            "openclicky.linkrect_overlay.cancel",
            lane: "system",
            direction: "internal",
            ["reason": reason]
        )
        cancel()
    }

    /// Byte-exact `LinkRectSession.OnLeftButtonUp`
    /// (VisualElementContext.LinkRect.cs:133-149):
    /// resolve `.rect` when the drag has area, otherwise `.cancelled`.
    /// The overlay STAYS ALIVE on `.rect` — the layer host keeps
    /// painting the drag rect + tint until `dismiss()` fires (which
    /// the caller does AFTER the 700ms flash).
    private func finish(finalRect: CGRect) {
        guard !didFire else { return }
        didFire = true
        // Root-fix: as soon as mouseUp resolves, remove the tint +
        // border layers from every host so the drag rect visually
        // vanishes IMMEDIATELY on mouseUp — before the flash paints
        // and before the browser gets focus. This is the exact user-
        // visible behavior the ticket asked for: "Overlay should
        // visibly vanish IMMEDIATELY on mouseUp before flash".
        //
        // The `container` layer stays attached so the flash sublayer
        // (added by `highlightCapturedLinks(rects:)`) can render
        // against a clean substrate. `dismiss()` later removes the
        // container.
        // Clear tint/border paths (NOT remove layers) so any subsequent
        // display cycle paints empty on those layers. Removing them
        // from the tree doesn't force WindowServer to recomposite;
        // clearing their content and forcing redraw does.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            sh.tintLayer.path = nil
            sh.borderLayer.path = nil
        }
        CATransaction.commit()
        CATransaction.flush()
        // Force each host to redraw the (now empty) content.
        for sh in sessionHosts {
            sh.host.contentView.needsDisplay = true
            sh.host.contentView.displayIfNeeded()
            sh.host.window.viewsNeedDisplay = true
            sh.host.window.display()
        }
        // We're done consuming mouse events. Balance the
        // beginMouseCapture on install. Host windows go back to
        // click-through so nothing between here and dismiss() steals
        // clicks (in particular the browser needs to receive its own
        // focus click when the launch phrase fires).
        OpenClickyOverlayLayerHost.shared.endMouseCapture(reason: "linkrect_mouseup")
        capturedMouseAtInstall = false

        // Detach mouse-input monitors so drag events during the flash
        // don't retrigger the state machine. Escape/right-click stay
        // available via the CGEvent tap in OpenClickyContextHotkeys.
        teardownEventMonitors()

        if finalRect.width > 0, finalRect.height > 0 {
            completion?(.rect(finalRect))
        } else {
            // Empty drag == cancelled. Everywhere:
            // VisualElementContext.LinkRect.cs:144-147 sets the promise
            // to null in that case, and the caller's null-check path
            // at line 47-51 auto-closes the window.
            dismiss()
            completion?(.cancelled)
        }
        completion = nil
        // Retain `strongSelf` until dismiss(); the .rect(_) branch
        // hasn't fired dismiss() yet so the caller can still reach us
        // to invoke it. dismiss() itself will nil strongSelf.
    }

    func cancel() {
        guard !didFire else { return }
        didFire = true
        dismiss()
        completion?(.cancelled)
        completion = nil
    }

    /// Byte-exact port of `LinkRectSession.HighlightCapturedLinks`
    /// (VisualElementContext.LinkRect.cs:75-92). Paints an aqua border
    /// around every captured anchor rect so the user gets visual
    /// confirmation the links were harvested. Colours match
    /// `ScreenSelectionWindow.cs:124-127`:
    ///   * border: `Color.FromArgb(0xFF, 0x00, 0xC8, 0xFF)` (opaque aqua)
    ///   * fill:   `Color.FromArgb(0x40, 0x00, 0xC8, 0xFF)` (25% aqua)
    /// Everywhere holds the paint for 700ms in `HarvestAsync`
    /// (LinkRect.cs:63) before calling `Close()` at line 69.
    ///
    /// `rects` are Quartz global (top-left origin) — same coordinate
    /// space as the drag rect.
    func highlightCapturedLinks(rects: [CGRect]) {
        let firstRect = rects.first ?? .zero
        HeyClickyLog.log(
            "openclicky.linkrect_overlay.flash_paint",
            lane: "system",
            direction: "internal",
            [
                "link_count": rects.count,
                "first_rect_x": Int(firstRect.origin.x),
                "first_rect_y": Int(firstRect.origin.y),
                "first_rect_w": Int(firstRect.size.width),
                "first_rect_h": Int(firstRect.size.height),
            ]
        )
        // Fan the rects out to each host based on which screen a rect
        // sits on. A rect that spans two screens (rare) gets drawn on
        // both — its portion outside the host is offscreen anyway.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in sessionHosts.indices {
            let sh = sessionHosts[idx]
            let flashLayer = CAShapeLayer()
            flashLayer.frame = sh.host.contentView.bounds
            flashLayer.fillColor = Self.flashFillColor
            flashLayer.strokeColor = Self.flashBorderColor
            flashLayer.lineWidth = 2
            flashLayer.name = "linkrect.flash"

            let path = CGMutablePath()
            for rectQuartz in rects {
                guard rectQuartz.width > 0, rectQuartz.height > 0 else { continue }
                let localRect = OpenClickyOverlayLayerHost.viewLocalRect(
                    fromQuartzGlobal: rectQuartz,
                    on: sh.host
                )
                guard localRect.width > 0, localRect.height > 0 else { continue }
                // Skip rects that don't intersect this host at all.
                guard localRect.intersects(sh.host.contentView.bounds) else { continue }
                path.addRect(localRect)
            }
            flashLayer.path = path
            sh.container.addSublayer(flashLayer)
            sessionHosts[idx].flashLayer = flashLayer
        }
        CATransaction.commit()
    }

    /// Companion log for the end of the 700ms flash window. Caller
    /// invokes this immediately before it calls `dismiss()` so the
    /// log tail shows the sequence `flash_paint -> flash_end ->
    /// dismiss_step ...`.
    func logFlashEnd(rectCount: Int) {
        HeyClickyLog.log(
            "openclicky.linkrect_overlay.flash_end",
            lane: "system",
            direction: "internal",
            ["link_count": rectCount]
        )
    }

    /// Root-fix dismiss: remove every sublayer this session attached
    /// to the persistent host. The host window itself stays alive —
    /// its next display cycle recomposites with the sublayers gone
    /// and the tile clears immediately (this is exactly the property
    /// the pre-refactor NSPanel path could not achieve on macOS 26).
    func dismiss() {
        teardownEventMonitors()
        // If mouseUp already ran we've already ended capture; guard
        // against a stray Escape after mouseUp.
        // The refcount pattern makes both paths safe:
        //   * cancel() -> dismiss() (never released capture yet)     -> refcount -1
        //   * finish() -> released capture already, dismiss() no-op  -> refcount unchanged
        // We track it explicitly on `didFire` via `capturedMouse`.
        if capturedMouseAtInstall {
            OpenClickyOverlayLayerHost.shared.endMouseCapture(reason: "linkrect_dismiss")
            capturedMouseAtInstall = false
        }
        for (idx, sh) in sessionHosts.enumerated() {
            HeyClickyLog.log(
                "openclicky.linkrect_overlay.dismiss_step",
                lane: "system",
                direction: "internal",
                [
                    "step": "before_detach",
                    "screen_idx": idx,
                    "window_isVisible": sh.host.window.isVisible,
                    "alpha": Double(sh.host.window.alphaValue),
                    "level": sh.host.window.level.rawValue,
                ]
            )
        }
        // Force the host layer tree to a cleared, redrawn state BEFORE
        // we detach the container. Setting hidden=true + display() gets
        // WindowServer to composite an empty frame first, then we
        // detach with the container already invisible.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            sh.container.isHidden = true
        }
        CATransaction.commit()
        CATransaction.flush()
        for sh in sessionHosts {
            sh.host.contentView.needsDisplay = true
            sh.host.contentView.displayIfNeeded()
            sh.host.window.viewsNeedDisplay = true
            sh.host.window.display()
        }
        let containers = sessionHosts.map { $0.container }
        OpenClickyOverlayLayerHost.shared.detachAll(containers)
        for (idx, sh) in sessionHosts.enumerated() {
            HeyClickyLog.log(
                "openclicky.linkrect_overlay.dismiss_step",
                lane: "system",
                direction: "internal",
                [
                    "step": "after_detach",
                    "screen_idx": idx,
                    "window_isVisible": sh.host.window.isVisible,
                    "alpha": Double(sh.host.window.alphaValue),
                    "level": sh.host.window.level.rawValue,
                ]
            )
        }

        HeyClickyLog.log(
            "openclicky.linkrect_overlay.dismiss",
            lane: "system",
            direction: "internal",
            [
                "total_screens": sessionHosts.count,
            ]
        )
        sessionHosts.removeAll()
        strongSelf = nil
    }

    /// Renders the black-tint-with-hole + white 2px border for the
    /// current drag rect. Fans across every host so a drag that spans
    /// two screens paints on both.
    private func renderDragRect() {
        guard let rectQuartz = currentQuartzRect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            let hostBounds = sh.host.contentView.bounds
            let localRect = OpenClickyOverlayLayerHost.viewLocalRect(
                fromQuartzGlobal: rectQuartz,
                on: sh.host
            )
            // Tint = full screen minus drag rect (evenOdd fill rule
            // treats the second subpath as a hole).
            let tintPath = CGMutablePath()
            tintPath.addRect(hostBounds)
            if localRect.width > 0, localRect.height > 0,
               localRect.intersects(hostBounds) {
                tintPath.addRect(localRect)
            }
            sh.tintLayer.path = tintPath

            if localRect.width > 0, localRect.height > 0,
               localRect.intersects(hostBounds) {
                sh.borderLayer.path = CGPath(rect: localRect, transform: nil)
            } else {
                sh.borderLayer.path = nil
            }
        }
        CATransaction.commit()
    }

    /// True while the session holds a mouse-capture refcount on the
    /// layer host. Set by `installOnAllScreens`, released by
    /// `finish()` (on mouseUp) or `dismiss()` (cancel path).
    private var capturedMouseAtInstall: Bool = true
}
