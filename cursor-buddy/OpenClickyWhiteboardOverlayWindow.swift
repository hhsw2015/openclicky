// OpenClickyWhiteboardOverlayWindow.swift
// cursor-buddy
//
// Phase 7.1 Layer 4 UX — press-hold whiteboard drawing overlay.
//
// macOS 26 root-fix refactor (2026-07-23):
//   Previous implementation created one nonactivatingPanel per
//   NSScreen at cursor-overlay level. macOS 26's WindowServer keeps
//   the last composited tile onscreen after orderOut+close, so
//   `end()`/`cancel()` didn't visually clear the ink. This
//   implementation attaches CALayers to
//   `OpenClickyOverlayLayerHost` (a persistent per-screen fullscreen
//   host window that stays alive for the app's lifetime) and removes
//   the layers on end/cancel. Removing a CALayer from a still-alive
//   host window recomposites cleanly on the next display cycle.
//
// Behaviour preserved:
//   * `begin()` — hotkey keyDown; per-screen ink surface attached.
//   * `end()`   — commits: classifies strokes, runs OCR, writes
//                 WhiteboardStash. Ink disappears immediately.
//   * `cancel()`— Escape/global cancel path; drops everything.
//   * Toggle semantic (already-active begin() = end()) driven by
//     `OpenClickyContextHotkeys.performWhiteboardBegin`.
//   * OCR pipeline `processAndStash` byte-exact-ported from
//     Everywhere @30e03e9d, unchanged.
//   * Global + local NSEvent monitors (macOS 26 non-key workaround).

import AppKit
import Foundation
import QuartzCore
import OpenClickyContextService

// MARK: - Session models

/// One recorded stroke in Quartz global coords, plus the screen id
/// so the region-crop step can pick the right monitor.
private struct OpenClickyWhiteboardSessionStroke {
    var quartzPoints: [CGPoint]
    var screenDisplayID: CGDirectDisplayID
}

// MARK: - Overlay manager (singleton)

/// Owns the whiteboard overlay lifecycle. Public API:
///
///   * `begin()`  — key-down; attach the ink CALayers.
///   * `end()`    — key-up / re-fire; finalise, run OCR, write stash,
///                  remove ink layers immediately.
///   * `cancel()` — Escape; drop everything, remove ink layers.
///
/// Idempotent so rapid key-repeat cannot spawn a duplicate session.
@MainActor
final class OpenClickyWhiteboardOverlayWindow {
    static let shared = OpenClickyWhiteboardOverlayWindow()

    private static let logCategory = "openclicky.whiteboard.overlay"

    /// Per-host layer container. One entry per NSScreen host at the
    /// time `begin()` was called. Layers coordinates are view-local
    /// Cocoa (bottom-left origin) so we reuse Everywhere's per-view
    /// coord math unchanged.
    private struct SessionHost {
        let host: OpenClickyOverlayLayerHost.Host
        let container: CALayer               // groups every layer this session drew on the host
        let tintLayer: CALayer               // semi-transparent black wash
        var strokeLayers: [CAShapeLayer]     // one CAShapeLayer per live stroke on this host
        var classifiedLayers: [CAShapeLayer] // orange dashed preview boxes at commit time
        /// Local (Cocoa, bottom-left) points for each in-progress
        /// stroke on THIS host. Used to rebuild the last stroke's
        /// CAShapeLayer path incrementally as new points come in.
        var strokes: [[CGPoint]]
    }

    private var sessionHosts: [SessionHost] = []

    /// True while a session is active. Read externally by
    /// `OpenClickyContextHotkeys.performWhiteboardBegin` so the toggle
    /// branch mirrors Everywhere's `_activeOverlay is not null` check.
    private(set) var isActive: Bool = false

    /// Session strokes in Quartz global coords, accumulated across
    /// screens. Cleared on `begin()`; drained on `end()`.
    private var sessionStrokes: [OpenClickyWhiteboardSessionStroke] = []

    /// NSEvent monitor handles for the macOS 26 non-key-panel path.
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseDraggedMonitor: Any?
    private var localMouseDraggedMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var localEscapeMonitor: Any?

    /// Unit-test-style dependency injection. Nil in production; when
    /// set, `end()` uses these instead of Vision + SC capture so
    /// tests drive the pipeline without permissions.
    var ocrOverride: ((NSImage) async -> OCRResult?)?
    var captureOverride: ((CGRect) async -> Data?)?

    // Visual constants (match the previous NSView draw path exactly).
    private static let tintColor: CGColor = NSColor.black.withAlphaComponent(0.15).cgColor
    private static let strokeColor: CGColor = NSColor(
        calibratedRed: 1.0,
        green: 235.0 / 255.0,
        blue: 59.0 / 255.0,
        alpha: 1.0
    ).cgColor
    private static let classifiedColor: CGColor = NSColor.orange.cgColor

    private init() {}

    // MARK: - Public API

    /// Show the overlay. Idempotent: a second call while the session
    /// is active is silently ignored (CGEvent tap can fire twice on
    /// stuck key-repeat).
    func begin() {
        if isActive { return }
        isActive = true
        sessionStrokes.removeAll(keepingCapacity: false)

        OpenClickyOverlayLayerHost.shared.ensureInstalled()
        OpenClickyOverlayLayerHost.shared.beginMouseCapture(reason: "whiteboard")

        NSLog("\(Self.logCategory): begin (screens=\(OpenClickyOverlayLayerHost.shared.hosts.count))")
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.begin",
            lane: "system",
            direction: "internal",
            [
                "panel_count": OpenClickyOverlayLayerHost.shared.hosts.count,
            ]
        )

        for host in OpenClickyOverlayLayerHost.shared.hosts {
            let container = CALayer()
            container.frame = host.contentView.bounds
            container.masksToBounds = false
            container.name = "whiteboard.container"

            let tintLayer = CALayer()
            tintLayer.frame = host.contentView.bounds
            tintLayer.backgroundColor = Self.tintColor
            tintLayer.name = "whiteboard.tint"

            OpenClickyOverlayLayerHost.shared.attach(container, to: host)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.addSublayer(tintLayer)
            CATransaction.commit()

            sessionHosts.append(SessionHost(
                host: host,
                container: container,
                tintLayer: tintLayer,
                strokeLayers: [],
                classifiedLayers: [],
                strokes: []
            ))
        }
        NSCursor.crosshair.set()

        // Bring our app frontmost so we behave the same as
        // ScreenSelectionSession — the address bar / target text
        // field loses focus while the user is drawing.
        NSApp.activate(ignoringOtherApps: true)

        installEventMonitors()
    }

    /// Finalise the session, snapshot strokes, run OCR pipeline,
    /// commit to `WhiteboardStash.shared`. Removes ink layers before
    /// OCR runs so the user gets the screen back immediately.
    func end() {
        guard isActive else { return }
        isActive = false
        teardownEventMonitors()

        // Snapshot strokes before we tear down the visual layer.
        let strokes = sessionStrokes
        NSLog("\(Self.logCategory): end (strokes=\(strokes.count))")
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.commit",
            lane: "system",
            direction: "internal",
            [
                "stroke_count": strokes.count,
                "regions": strokes.reduce(0) { $0 + $1.quartzPoints.count },
            ]
        )

        // OPTIONAL preview flash: repaint each host's ink area with
        // the classifier's orange bounding boxes for ~250 ms so the
        // user sees which regions were recognised, then remove the
        // whole session container. If strokes are empty we skip the
        // preview and go straight to detach.
        let ocrOverrideCopy = ocrOverride
        let captureOverrideCopy = captureOverride
        let containersToDetach = sessionHosts.map { $0.container }
        // Immediately remove the stroke layers so the ink visually
        // vanishes — the tint / classified boxes still render for the
        // brief preview window if there are any.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for idx in sessionHosts.indices {
            for stroke in sessionHosts[idx].strokeLayers {
                stroke.removeFromSuperlayer()
            }
            sessionHosts[idx].strokeLayers.removeAll(keepingCapacity: false)
        }
        CATransaction.commit()

        if !strokes.isEmpty {
            let classified = classifyByScreen(strokes: strokes)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (hostIdx, entries) in classified {
                guard sessionHosts.indices.contains(hostIdx) else { continue }
                for entry in entries {
                    let layer = CAShapeLayer()
                    layer.frame = sessionHosts[hostIdx].host.contentView.bounds
                    layer.fillColor = NSColor.clear.cgColor
                    layer.strokeColor = Self.classifiedColor
                    layer.lineWidth = 1
                    layer.lineDashPattern = [4, 3]
                    layer.name = "whiteboard.classified"
                    layer.path = CGPath(rect: entry.rect, transform: nil)
                    sessionHosts[hostIdx].container.addSublayer(layer)
                    sessionHosts[hostIdx].classifiedLayers.append(layer)
                }
            }
            CATransaction.commit()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for container in containersToDetach {
                container.removeFromSuperlayer()
            }
            CATransaction.commit()
            self.sessionHosts.removeAll(keepingCapacity: false)
            OpenClickyOverlayLayerHost.shared.endMouseCapture(reason: "whiteboard_end")
        }

        if strokes.isEmpty {
            // Ensure we don't leak a mouse-capture refcount if the
            // preview didn't run (empty session). Balance begin().
            // The Task above still runs; guard by short-circuit.
            return
        }

        Task { @MainActor in
            await Self.processAndStash(
                strokes: strokes,
                ocrOverride: ocrOverrideCopy,
                captureOverride: captureOverrideCopy
            )
        }
    }

    /// Cancel the session without writing to the stash. Removes ink
    /// layers immediately.
    func cancel() {
        guard isActive else { return }
        isActive = false
        teardownEventMonitors()
        NSLog("\(Self.logCategory): cancel")
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.cancel",
            lane: "system",
            direction: "internal",
            ["reason": "cancel"]
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            sh.container.removeFromSuperlayer()
        }
        CATransaction.commit()
        sessionHosts.removeAll(keepingCapacity: false)
        sessionStrokes.removeAll(keepingCapacity: false)
        OpenClickyOverlayLayerHost.shared.endMouseCapture(reason: "whiteboard_cancel")
    }

    // MARK: - Event monitors

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

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                HeyClickyLog.log(
                    "openclicky.whiteboard_overlay.cancel",
                    lane: "system",
                    direction: "internal",
                    ["reason": "escape"]
                )
                self.cancel()
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
            localEscapeMonitor,
        ] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMouseDownMonitor = nil
        localMouseDownMonitor = nil
        globalMouseDraggedMonitor = nil
        localMouseDraggedMonitor = nil
        globalMouseUpMonitor = nil
        localMouseUpMonitor = nil
        localEscapeMonitor = nil
    }

    /// Resolve which host the cursor is currently over and its local
    /// point in that host's contentView coord space.
    private func hostUnderCursor() -> (hostIdx: Int, local: CGPoint)? {
        let cocoa = NSEvent.mouseLocation
        for (idx, sh) in sessionHosts.enumerated() {
            if sh.host.screen.frame.contains(cocoa) {
                let local = OpenClickyOverlayLayerHost.viewLocalPoint(
                    fromCocoaGlobal: cocoa,
                    on: sh.host
                )
                return (idx, local)
            }
        }
        return nil
    }

    private func handleMouseDown() {
        guard isActive, let (hostIdx, local) = hostUnderCursor() else { return }
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.mouse_down",
            lane: "system",
            direction: "internal",
            [
                "screen_index": hostIdx,
                "x": Int(local.x),
                "y": Int(local.y),
            ]
        )
        beginLocalStroke(on: hostIdx, at: local)
        session_stroke_began(hostIdx: hostIdx, localPoint: local)
    }

    private func handleMouseDragged() {
        guard isActive, let (hostIdx, local) = hostUnderCursor() else { return }
        appendToLocalStroke(on: hostIdx, at: local)
        session_stroke_moved(hostIdx: hostIdx, localPoint: local)
    }

    private func handleMouseUp() {
        guard isActive, let (hostIdx, local) = hostUnderCursor() else { return }
        appendToLocalStroke(on: hostIdx, at: local)
        let counts = strokeStats(hostIdx: hostIdx)
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.mouse_up",
            lane: "system",
            direction: "internal",
            [
                "screen_index": hostIdx,
                "point_count": counts.points,
                "stroke_count": counts.strokes,
            ]
        )
        session_stroke_ended(hostIdx: hostIdx, localPoint: local)
    }

    // MARK: - Stroke rendering (view-local Cocoa coords)

    private func beginLocalStroke(on hostIdx: Int, at point: CGPoint) {
        guard sessionHosts.indices.contains(hostIdx) else { return }
        sessionHosts[hostIdx].strokes.append([point])
        let layer = CAShapeLayer()
        layer.frame = sessionHosts[hostIdx].host.contentView.bounds
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = Self.strokeColor
        layer.lineWidth = 3
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.name = "whiteboard.stroke"
        // Kick off with a single point path (invisible until 2+ points).
        let p = CGMutablePath()
        p.move(to: point)
        layer.path = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sessionHosts[hostIdx].container.addSublayer(layer)
        CATransaction.commit()
        sessionHosts[hostIdx].strokeLayers.append(layer)
    }

    private func appendToLocalStroke(on hostIdx: Int, at point: CGPoint) {
        guard sessionHosts.indices.contains(hostIdx) else { return }
        if sessionHosts[hostIdx].strokes.isEmpty {
            beginLocalStroke(on: hostIdx, at: point)
            return
        }
        sessionHosts[hostIdx].strokes[sessionHosts[hostIdx].strokes.count - 1].append(point)
        // Rebuild the last stroke's path incrementally.
        guard let lastLayer = sessionHosts[hostIdx].strokeLayers.last else { return }
        let stroke = sessionHosts[hostIdx].strokes[sessionHosts[hostIdx].strokes.count - 1]
        let p = CGMutablePath()
        if let first = stroke.first {
            p.move(to: first)
            for point in stroke.dropFirst() {
                p.addLine(to: point)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lastLayer.path = p
        CATransaction.commit()
    }

    private func strokeStats(hostIdx: Int) -> (points: Int, strokes: Int) {
        guard sessionHosts.indices.contains(hostIdx) else { return (0, 0) }
        let s = sessionHosts[hostIdx].strokes
        let total = s.reduce(0) { $0 + $1.count }
        return (total, s.count)
    }

    // MARK: - Session stroke recording (Quartz global)

    fileprivate func session_stroke_began(hostIdx: Int, localPoint: CGPoint) {
        guard sessionHosts.indices.contains(hostIdx) else { return }
        let host = sessionHosts[hostIdx].host
        let displayID = Self.displayID(for: host)
        let global = Self.toQuartzGlobal(localPoint: localPoint, host: host)
        sessionStrokes.append(OpenClickyWhiteboardSessionStroke(
            quartzPoints: [global],
            screenDisplayID: displayID
        ))
        HeyClickyLog.log(
            "openclicky.whiteboard_overlay.stroke_captured",
            lane: "system",
            direction: "internal",
            [
                "stroke_index": sessionStrokes.count - 1,
                "first_pt_x": Int(global.x),
                "first_pt_y": Int(global.y),
                "last_pt_x": Int(global.x),
                "last_pt_y": Int(global.y),
                "point_count": 1,
                "screen_index": hostIdx,
            ]
        )
    }

    fileprivate func session_stroke_moved(hostIdx: Int, localPoint: CGPoint) {
        guard sessionHosts.indices.contains(hostIdx) else { return }
        guard !sessionStrokes.isEmpty else {
            session_stroke_began(hostIdx: hostIdx, localPoint: localPoint)
            return
        }
        let host = sessionHosts[hostIdx].host
        let global = Self.toQuartzGlobal(localPoint: localPoint, host: host)
        sessionStrokes[sessionStrokes.count - 1].quartzPoints.append(global)
    }

    fileprivate func session_stroke_ended(hostIdx: Int, localPoint: CGPoint) {
        guard sessionHosts.indices.contains(hostIdx) else { return }
        guard !sessionStrokes.isEmpty else { return }
        let host = sessionHosts[hostIdx].host
        let global = Self.toQuartzGlobal(localPoint: localPoint, host: host)
        sessionStrokes[sessionStrokes.count - 1].quartzPoints.append(global)
    }

    // MARK: - Coordinate helpers

    /// Convert a Cocoa point in the given host's contentView to
    /// Quartz global (top-left origin, primary display).
    private static func toQuartzGlobal(
        localPoint: CGPoint,
        host: OpenClickyOverlayLayerHost.Host
    ) -> CGPoint {
        let screen = host.screen
        let cocoaGlobal = CGPoint(
            x: screen.frame.origin.x + localPoint.x,
            y: screen.frame.origin.y + localPoint.y
        )
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGPoint(x: cocoaGlobal.x, y: primaryMaxY - cocoaGlobal.y)
    }

    /// Map a host to its `CGDirectDisplayID`. Falls back to 0 if the
    /// display ID isn't advertised (rare on hot-plug).
    private static func displayID(for host: OpenClickyOverlayLayerHost.Host) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (host.screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// Run the classifier once, then group each bbox by the sessionHost
    /// whose screen contains the bbox centre. Bboxes are converted from
    /// Quartz-global (top-left origin) to host-local Cocoa (bottom-left)
    /// so the CAShapeLayer paths line up.
    ///
    /// Mirrors Everywhere's classifier-then-render path
    /// (`WhiteboardHotkeyInitializer.cs:461`).
    private func classifyByScreen(
        strokes: [OpenClickyWhiteboardSessionStroke]
    ) -> [(Int, [(kind: OpenClickyWhiteboardGestureKind, rect: CGRect)])] {
        let classifierStrokes = strokes.map {
            OpenClickyWhiteboardStroke(points: $0.quartzPoints)
        }
        let gestures = OpenClickyWhiteboardStrokeClassifier.classify(strokes: classifierStrokes)
        if gestures.isEmpty { return [] }

        var buckets: [Int: [(kind: OpenClickyWhiteboardGestureKind, rect: CGRect)]] = [:]
        for gesture in gestures {
            guard let hostIdx = hostIndexForQuartzRect(gesture.boundingBox) else { continue }
            guard sessionHosts.indices.contains(hostIdx) else { continue }
            let localRect = OpenClickyOverlayLayerHost.viewLocalRect(
                fromQuartzGlobal: gesture.boundingBox,
                on: sessionHosts[hostIdx].host
            )
            var arr = buckets[hostIdx] ?? []
            arr.append((kind: gesture.kind, rect: localRect))
            buckets[hostIdx] = arr
        }
        return Array(buckets.map { ($0.key, $0.value) })
    }

    private func hostIndexForQuartzRect(_ rect: CGRect) -> Int? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoaCentre = NSPoint(x: centre.x, y: primaryMaxY - centre.y)
        for (idx, sh) in sessionHosts.enumerated() {
            if sh.host.screen.frame.contains(cocoaCentre) { return idx }
        }
        return sessionHosts.isEmpty ? nil : 0
    }

    // MARK: - Processing pipeline (byte-exact port of Everywhere OCR path)

    @MainActor
    private static func processAndStash(
        strokes: [OpenClickyWhiteboardSessionStroke],
        ocrOverride: ((NSImage) async -> OCRResult?)?,
        captureOverride: ((CGRect) async -> Data?)?
    ) async {
        let classifierStrokes: [OpenClickyWhiteboardStroke] = strokes.map {
            OpenClickyWhiteboardStroke(points: $0.quartzPoints)
        }
        let gestures = OpenClickyWhiteboardStrokeClassifier.classify(strokes: classifierStrokes)
        if gestures.isEmpty {
            NSLog("\(Self.logCategory): no gestures after classification; skipping stash")
            return
        }

        // Build AX root ONCE for the commit — mirrors Everywhere
        // `WhiteboardHotkeyInitializer.cs:461-482` where `focusedRoot` is
        // resolved before the per-gesture loop, and the (optional) prewarm
        // scheduled during overlay-show is used for every snap call.
        // Prewarming is a Phase-7.2 enhancement; for now we always fall
        // through to the live rect-pruned walk (`prewarmed: nil` -> live
        // path in AnnotationSnapper.walk).
        let axRoot: AXVisualElement? = {
            guard let pid = FrontmostAppCapture.capture()?.processId else { return nil }
            return WhiteboardOrchestrator.buildRoot(pid: pid)
        }()

        // Byte-parity with Everywhere `WhiteboardHotkeyInitializer.cs:291-325`:
        // ONE shared screen bitmap is captured up-front, then every gesture
        // crops from it. This matches Vision's input pixel raster across
        // regions (per-region SC captures at 2× backingScale can drift
        // between gestures and mismatch Everywhere's downsampled 1920×1080
        // raster). Only build the shared bitmap when we have no override.
        let sharedBitmap: NSImage?
        let sharedBitmapScreenRect: CGRect
        if captureOverride == nil {
            let screenResult = await ScreenshotCaptureEverywhere.captureScreen(
                screenID: 0,
                format: .png
            )
            if let data = screenResult?.data, let img = NSImage(data: data) {
                sharedBitmap = img
                sharedBitmapScreenRect = NSScreen.screens.first?.frame ?? .zero
            } else {
                sharedBitmap = nil
                sharedBitmapScreenRect = .zero
            }
        } else {
            sharedBitmap = nil
            sharedBitmapScreenRect = .zero
        }

        var regions: [WhiteboardRegion] = []
        var imageMap: [UUID: Data] = [:]
        for (gestureIndex, gesture) in gestures.enumerated() {
            let regionID = UUID()
            let quartzBbox = gesture.boundingBox

            HeyClickyLog.log(
                "openclicky.whiteboard_overlay.stroke_bbox_quartz",
                lane: "system",
                direction: "internal",
                [
                    "stroke_index": gestureIndex,
                    "quartz_x": Int(quartzBbox.origin.x),
                    "quartz_y": Int(quartzBbox.origin.y),
                    "quartz_w": Int(quartzBbox.width),
                    "quartz_h": Int(quartzBbox.height),
                ]
            )
            HeyClickyLog.log(
                "openclicky.whiteboard_overlay.stroke_classified",
                lane: "system",
                direction: "internal",
                [
                    "stroke_index": gestureIndex,
                    "kind": gesture.kind.rawValue,
                    "confidence": 1.0,
                ]
            )

            guard quartzBbox.width > 1, quartzBbox.height > 1 else {
                regions.append(WhiteboardRegion(
                    id: regionID,
                    bboxScreen: quartzBbox,
                    gestureKind: gesture.kind.rawValue,
                    ocrText: nil
                ))
                continue
            }

            // AX-snap (primary text channel). Byte-parity with
            // `WhiteboardHotkeyInitializer.cs:596-641`: we snap FIRST and
            // record `snap.textLeaves`; OCR still runs (below) and acts as
            // the fallback when AX yields nothing. Coordinate contract:
            // gesture.boundingBox is already Quartz global, so is the AX
            // leaf bbox — no conversion needed (see plan §5).
            let snappedRegion: WhiteboardSnappedRegion? = {
                guard let root = axRoot else { return nil }
                let annKind: AnnotationKind
                switch gesture.kind {
                case .circle:    annKind = .circle
                case .underline: annKind = .underline
                case .arrow:     annKind = .arrow
                case .x:         annKind = .x
                case .unknown:   annKind = .unknown
                }
                let axStrokes: [Stroke] = gesture.strokes.map { Stroke(points: $0.points) }
                return WhiteboardOrchestrator.snap(
                    kind: annKind,
                    strokes: axStrokes,
                    boundingRect: quartzBbox,
                    root: root,
                    prewarmed: nil
                )
            }()
            let axText: String = {
                guard let r = snappedRegion, !r.rejected else { return "" }
                let parts = r.textLeaves.map { $0.text }.filter { !$0.isEmpty }
                return parts.joined(separator: "\n")
            }()
            if let r = snappedRegion {
                HeyClickyLog.log(
                    "openclicky.whiteboard_overlay.ax_snap",
                    lane: "system",
                    direction: "internal",
                    [
                        "stroke_index": gestureIndex,
                        "kind": r.kind.rawValue,
                        "rejected": r.rejected,
                        "reject_reason": r.rejectReason,
                        "confidence": r.confidence,
                        "text_leaves": r.textLeaves.count,
                        "image_leaves": r.imageLeaves.count,
                        "diagnostics": r.diagnostics,
                    ]
                )
            }

            let ocrRect: CGRect
            let widenedL: Int
            let widenedR: Int
            let widenedT: Int
            let widenedB: Int
            if gesture.kind == .underline {
                widenedL = 60
                widenedR = 60
                widenedT = 50
                widenedB = 20
                ocrRect = CGRect(
                    x: max(0, quartzBbox.origin.x - CGFloat(widenedL)),
                    y: max(0, quartzBbox.origin.y - CGFloat(widenedT)),
                    width: quartzBbox.width + CGFloat(widenedL + widenedR),
                    height: quartzBbox.height + CGFloat(widenedT + widenedB)
                )
            } else {
                widenedL = 0
                widenedR = 0
                widenedT = 0
                widenedB = 0
                ocrRect = quartzBbox
            }
            HeyClickyLog.log(
                "openclicky.whiteboard_overlay.ocr_band",
                lane: "system",
                direction: "internal",
                [
                    "stroke_index": gestureIndex,
                    "band_x": Int(ocrRect.origin.x),
                    "band_y": Int(ocrRect.origin.y),
                    "band_w": Int(ocrRect.width),
                    "band_h": Int(ocrRect.height),
                    "widened_l": widenedL,
                    "widened_r": widenedR,
                    "widened_t": widenedT,
                    "widened_b": widenedB,
                ]
            )

            var ocrText: String? = nil
            var pngBytes: Data? = nil
            if let capture = captureOverride {
                pngBytes = await capture(ocrRect)
            } else if let shared = sharedBitmap, sharedBitmapScreenRect.width > 0 {
                // Byte-parity with Everywhere: crop from the shared
                // bitmap instead of running a fresh SC capture per
                // region. Convert Quartz-global ocrRect → shared-bitmap
                // pixel rect using the shared bitmap's actual pixel
                // dimensions vs the primary screen's point rect.
                let scaleX = shared.size.width / sharedBitmapScreenRect.width
                let scaleY = shared.size.height / sharedBitmapScreenRect.height
                let cropRect = NSRect(
                    x: (ocrRect.origin.x - sharedBitmapScreenRect.origin.x) * scaleX,
                    y: (ocrRect.origin.y - sharedBitmapScreenRect.origin.y) * scaleY,
                    width: ocrRect.width * scaleX,
                    height: ocrRect.height * scaleY
                )
                if let cgImg = shared.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let cropped = cgImg.cropping(to: cropRect) {
                    let rep = NSBitmapImageRep(cgImage: cropped)
                    pngBytes = rep.representation(using: .png, properties: [:])
                }
            }
            if pngBytes == nil, captureOverride == nil {
                // Fallback: shared bitmap failed → per-region SC capture.
                let result = await ScreenshotCaptureEverywhere.captureRegion(
                    rect: ocrRect,
                    format: .png
                )
                pngBytes = result?.data
            }
            if let bytes = pngBytes, let nsImg = NSImage(data: bytes) {
                let backing = NSScreen.main?.backingScaleFactor ?? 1.0
                HeyClickyLog.log(
                    "openclicky.whiteboard_overlay.screenshot_captured",
                    lane: "system",
                    direction: "internal",
                    [
                        "stroke_index": gestureIndex,
                        "image_w": Int(nsImg.size.width),
                        "image_h": Int(nsImg.size.height),
                        "backing_scale": Double(backing),
                    ]
                )
                let ocrResult: OCRResult?
                if let override = ocrOverride {
                    ocrResult = await override(nsImg)
                } else {
                    ocrResult = await OCRCapture.ocr(image: nsImg)
                }
                var lines = ocrResult?.lines ?? []
                let inputLineCount = lines.count

                if gesture.kind == .underline, lines.count > 1 {
                    let backingScale = nsImg.size.height > 0 && ocrRect.height > 0
                        ? Double(nsImg.size.height) / Double(ocrRect.height)
                        : 1.0
                    let strokeMidQuartz = Double(quartzBbox.origin.y + quartzBbox.height * 0.5)
                    let strokeMidImage = (strokeMidQuartz - Double(ocrRect.origin.y)) * backingScale
                    var bestLine: OCRLine? = nil
                    var bestDy = Double.infinity
                    for line in lines {
                        let lineMid = Double(line.bounds.origin.y) + Double(line.bounds.height) * 0.5
                        let dy = abs(lineMid - strokeMidImage)
                        if dy < bestDy { bestDy = dy; bestLine = line }
                    }
                    if let bestLine {
                        lines = [bestLine]
                    }
                }

                HeyClickyLog.log(
                    "openclicky.whiteboard_overlay.nearest_line_filter",
                    lane: "system",
                    direction: "internal",
                    [
                        "stroke_index": gestureIndex,
                        "lines_input": inputLineCount,
                        "lines_kept": lines.count,
                        "kept_first": String((lines.first?.text ?? "").prefix(80)),
                    ]
                )

                let joined = lines.map { $0.text }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                ocrText = joined.isEmpty ? nil : joined
                HeyClickyLog.log(
                    "openclicky.whiteboard_overlay.ocr_result",
                    lane: "system",
                    direction: "internal",
                    [
                        "stroke_index": gestureIndex,
                        "text_len": (ocrText ?? "").count,
                        "first_line": String((lines.first?.text ?? "").prefix(80)),
                    ]
                )
                imageMap[regionID] = bytes
            }

            // Merge: AX-snap text wins as the primary channel; OCR is the
            // fallback when AX yielded nothing (`WhiteboardHotkeyInitializer.cs:641`
            // plus the ReadWhiteboardTool text-join rule that skips Images).
            let mergedText = WhiteboardOrchestrator.mergedText(
                snapText: axText,
                ocrText: ocrText ?? ""
            )
            regions.append(WhiteboardRegion(
                id: regionID,
                bboxScreen: quartzBbox,
                gestureKind: gesture.kind.rawValue,
                ocrText: mergedText
            ))
        }

        NSLog("\(Self.logCategory): stashing \(regions.count) region(s), \(imageMap.count) image(s)")
        WhiteboardStash.shared.set(regions: regions, imageBytesById: imageMap)

        if !regions.isEmpty {
            HeyClickyLog.log(
                "openclicky.whiteboard_overlay.auto_capture_fired",
                lane: "system",
                direction: "internal",
                [
                    "region_count": regions.count,
                ]
            )
            await OpenClickyContextStashWriter.shared.captureAsync()
        }
    }
}
