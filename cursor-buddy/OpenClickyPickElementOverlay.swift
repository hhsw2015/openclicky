//
//  OpenClickyPickElementOverlay.swift
//  cursor-buddy
//
//  Phase 7.1 (Layer 4 UX): visual pick-element selector.
//
//  Ported from Everywhere's `VisualElementContext.PickerSession`
//  (`src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs`) plus
//  the generic `ScreenSelectionSession` overlay it inherits @30e03e9d.
//
//  macOS 26 root-fix refactor (2026-07-23):
//    Previous implementation installed a small floating NSPanel that
//    was `setFrame`-tracked over the hovered element. On macOS 26 the
//    WindowServer keeps that panel's last composited tile onscreen
//    after teardown until an unrelated event forces a recomposite.
//    This implementation attaches ONE small CALayer to the persistent
//    `OpenClickyOverlayLayerHost` and moves its frame on hit-test.
//    Teardown = `layer.removeFromSuperlayer()`.
//
//  Flow (driven by `OpenClickyContextHotkeys.performAgentPickElement`):
//
//    1. `begin()` creates ONE small transparent CAShapeLayer that
//       renders a 2px green rounded outline. Layer starts hidden
//       (frame = .zero). Crosshair cursor is pushed.
//    2. Global + local `.mouseMoved` monitors (30fps throttled)
//       call `AXUIElementCopyElementAtPosition` with the pointer in
//       Quartz coords, resolve the element's frame, and move the
//       highlight layer to match. On hit failure the layer's path
//       is cleared.
//    3. Global + local `.leftMouseDown` monitors call
//       `handleClick(on:at:)` which extracts the element's role /
//       title / value / bounds / pid / bundleId, wraps them into a
//       `PickedElement`, and writes into `PickStash.shared`.
//    4. Escape key OR right mouse click cancels without capturing.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import OpenClickyContextService

@MainActor
final class OpenClickyPickElementOverlay {
    /// Process-wide instance — the overlay is a one-at-a-time modal
    /// gesture. Held so hotkey re-fire is idempotent.
    static let shared = OpenClickyPickElementOverlay()

    /// One highlight layer per host. Each layer's `path` is set to a
    /// rounded rect in the host's local Cocoa coords when the AX
    /// element under the cursor lands on that host; nil when the
    /// cursor is elsewhere / hit-test failed.
    private struct SessionHost {
        let host: OpenClickyOverlayLayerHost.Host
        let highlight: CAShapeLayer
    }
    private var sessionHosts: [SessionHost] = []

    /// NSEvent monitor handles kept so `teardown()` can remove them.
    private var localKeyMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    /// 30fps throttle for hit-test.
    private var lastHitAt: TimeInterval = 0
    private static let minHitInterval: TimeInterval = 1.0 / 30.0

    /// Last resolved AX element under the cursor (used by the click
    /// monitor when its own hit-test comes back empty — e.g. the
    /// layer briefly covers the pointer for a frame during layout).
    private var lastHoverElement: AXUIElement?

    private lazy var systemWide = AXUIElementCreateSystemWide()

    private var isActive: Bool { !sessionHosts.isEmpty }

    private init() {}

    // MARK: - Public API

    /// Show the crosshair overlay. Safe to call while already active;
    /// second calls are no-ops so re-firing the hotkey during a pick
    /// session doesn't stack overlays.
    func begin() {
        if isActive { return }
        HeyClickyLog.log(
            "openclicky.pick_overlay.begin",
            lane: "system",
            direction: "internal",
            [
                "screen_count": NSScreen.screens.count,
            ]
        )
        installLayers()
        installEventMonitors()
        NSCursor.crosshair.push()
    }

    /// Tear down without writing to PickStash. Called by Escape,
    /// right-click, and after a successful click capture.
    func cancel(reason: String = "user_cancelled") {
        HeyClickyLog.log(
            "openclicky.pick_overlay.dismiss",
            lane: "system",
            direction: "internal",
            [
                "reason": reason,
            ]
        )
        teardown()
    }

    // MARK: - Lifecycle

    private func installLayers() {
        OpenClickyOverlayLayerHost.shared.ensureInstalled()
        // Pick overlay is passive — it hovers a small outline but does
        // NOT swallow mouse events. The click monitors capture the
        // element and dismiss; the app underneath still receives its
        // native click (this matches Everywhere's behaviour and is
        // exactly what the user expects — clicking a button should
        // click the button).
        for host in OpenClickyOverlayLayerHost.shared.hosts {
            let layer = CAShapeLayer()
            layer.frame = host.contentView.bounds
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = NSColor.systemGreen.cgColor
            layer.lineWidth = 2
            layer.name = "pick.highlight"
            layer.path = nil
            OpenClickyOverlayLayerHost.shared.attach(layer, to: host)
            sessionHosts.append(SessionHost(host: host, highlight: layer))
            HeyClickyLog.log(
                "openclicky.window.installed.pick_overlay",
                lane: "system",
                direction: "internal",
                [
                    "window_num": host.window.windowNumber,
                    "size_w": Int(host.window.frame.width),
                    "size_h": Int(host.window.frame.height),
                    "level": host.window.level.rawValue,
                    "alpha": Double(host.window.alphaValue),
                    "purpose": "pick_element_highlight",
                ]
            )
        }
    }

    private func installEventMonitors() {
        // Escape via local key monitor. Local monitor only fires
        // when our app is frontmost; the CGEvent hotkey path in
        // OpenClickyContextHotkeys already covers the global case
        // via its own tap, so we rely on local here for the common
        // "user still has focus" case.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.cancel(reason: "escape")
                return nil
            }
            return event
        }

        // Right-click cancels regardless of which app is frontmost.
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { [weak self] _ in
            self?.cancel(reason: "right_click")
        }

        // Mouse-move drives the hit-test.
        let moveHandler: (NSEvent) -> Void = { [weak self] _ in
            self?.performHitTest()
        }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { event in
            moveHandler(event)
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved]
        ) { event in
            moveHandler(event)
            return event
        }

        // Left-click captures. Same global/local pairing as the
        // move monitor; either can fire depending on the frontmost
        // app.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            self?.performClickCapture()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.performClickCapture()
            return event
        }
    }

    private func teardown() {
        // Remove every highlight layer we attached to the persistent
        // host. Because `OpenClickyOverlayLayerHost.detach` drops
        // implicit animations, the outline vanishes on the next
        // display cycle. The host window itself stays alive.
        let layers = sessionHosts.map { $0.highlight }
        OpenClickyOverlayLayerHost.shared.detachAll(layers)
        if !sessionHosts.isEmpty {
            HeyClickyLog.log(
                "openclicky.window.dismissed.pick_overlay",
                lane: "system",
                direction: "internal",
                [
                    "host_count": sessionHosts.count,
                    "reason": "teardown",
                ]
            )
        }
        sessionHosts.removeAll(keepingCapacity: false)
        lastHoverElement = nil

        for monitor in [
            localKeyMonitor,
            globalRightClickMonitor,
            globalMoveMonitor,
            localMoveMonitor,
            globalClickMonitor,
            localClickMonitor,
        ] {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        localKeyMonitor = nil
        globalRightClickMonitor = nil
        globalMoveMonitor = nil
        localMoveMonitor = nil
        globalClickMonitor = nil
        localClickMonitor = nil

        NSCursor.pop()
    }

    // MARK: - Hit-test

    private func performHitTest() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHitAt < Self.minHitInterval { return }
        lastHitAt = now

        // NSEvent.mouseLocation is Cocoa global (bottom-left origin,
        // primary screen anchored). AX and CGWindowList speak Quartz
        // (top-left origin, primary screen anchored). Convert once.
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)

        HeyClickyLog.log(
            "openclicky.pick_overlay.mouse_move",
            lane: "system",
            direction: "internal",
            [
                "cursor_qx": String(format: "%.0f", axPoint.x),
                "cursor_qy": String(format: "%.0f", axPoint.y),
            ]
        )

        var element: AXUIElement?
        let axResult = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &element
        )
        guard axResult == .success, let element else {
            HeyClickyLog.log(
                "openclicky.pick_overlay.ax_hit_fail",
                lane: "system",
                direction: "error",
                [
                    "ax_error": Int(axResult.rawValue),
                ]
            )
            clearHighlight()
            return
        }

        // Skip elements we own (menu bar bubble, notch panel, etc.)
        // so the highlight doesn't briefly clamp onto ourselves as
        // the pointer passes through our own surfaces.
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        if pid == getpid() {
            clearHighlight()
            return
        }

        guard let axFrame = Self.copyBoundsAttribute(element),
              axFrame.width > 0, axFrame.height > 0 else {
            HeyClickyLog.log(
                "openclicky.pick_overlay.ax_hit_fail",
                lane: "system",
                direction: "error",
                [
                    "reason": "no_frame",
                ]
            )
            clearHighlight()
            return
        }

        lastHoverElement = element
        let role = Self.copyStringAttribute(element, kAXRoleAttribute) ?? "?"
        let title = Self.copyStringAttribute(element, kAXTitleAttribute) ?? ""
        HeyClickyLog.log(
            "openclicky.pick_overlay.ax_hit_ok",
            lane: "system",
            direction: "internal",
            [
                "role": role,
                "title": String(title.prefix(80)),
                "bounds_w": String(format: "%.0f", axFrame.width),
                "bounds_h": String(format: "%.0f", axFrame.height),
                "bounds_x": String(format: "%.0f", axFrame.origin.x),
                "bounds_y": String(format: "%.0f", axFrame.origin.y),
            ]
        )

        // Update the layer for every host: paint the outline in
        // host-local coords if the AX frame's centre falls on that
        // host, clear elsewhere.
        let centre = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let cocoaCentre = NSPoint(x: centre.x, y: primaryHeight - centre.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            if sh.host.screen.frame.contains(cocoaCentre) {
                let localRect = OpenClickyOverlayLayerHost.viewLocalRect(
                    fromQuartzGlobal: axFrame,
                    on: sh.host
                )
                // Inset by half the stroke width so the 2px line sits
                // fully inside `localRect` — matches the pre-refactor
                // NSView draw path.
                let inset = localRect.insetBy(dx: 1, dy: 1)
                if inset.width > 0, inset.height > 0 {
                    sh.highlight.path = CGPath(
                        roundedRect: inset,
                        cornerWidth: 6,
                        cornerHeight: 6,
                        transform: nil
                    )
                } else {
                    sh.highlight.path = nil
                }
            } else {
                sh.highlight.path = nil
            }
        }
        CATransaction.commit()
    }

    private func clearHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sh in sessionHosts {
            sh.highlight.path = nil
        }
        CATransaction.commit()
    }

    // MARK: - Click capture

    private func performClickCapture() {
        // Re-run the hit-test synchronously against the current
        // mouseLocation so the captured element matches what the
        // user sees under the crosshair the instant they click.
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)

        var element: AXUIElement?
        let axResult = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &element
        )

        var pid: pid_t = 0
        var resolved: AXUIElement? = nil
        if axResult == .success, let element {
            _ = AXUIElementGetPid(element, &pid)
            if pid != getpid() {
                resolved = element
            }
        }
        let target = resolved ?? lastHoverElement
        guard let target else {
            HeyClickyLog.log(
                "openclicky.pick_overlay.ax_hit_fail",
                lane: "system",
                direction: "error",
                [
                    "reason": "click_no_element",
                    "ax_error": Int(axResult.rawValue),
                ]
            )
            cancel(reason: "click_no_element")
            return
        }
        handleClick(on: target, at: axPoint)
    }

    // MARK: - Capture

    private func handleClick(on element: AXUIElement, at axPoint: CGPoint) {
        let role = Self.copyStringAttribute(element, kAXRoleAttribute)
        // Name cascade — mirrors Everywhere `IVisualElement.Name`
        // (`AXUIElement.cs:257-283`): AXTitle → AXDescription → AXHelp.
        // For AXStaticText (very common: <p> in web pages, comment
        // body, list items), AXTitle is often empty but AXDescription
        // or AXValue carries the actual text.
        let rawTitle = Self.copyStringAttribute(element, kAXTitleAttribute)
        let description = Self.copyStringAttribute(element, kAXDescriptionAttribute)
        let help = Self.copyStringAttribute(element, "AXHelp")
        let rawValue = Self.copyStringAttribute(element, kAXValueAttribute)
        // First non-empty of title/description/help wins as the primary "title".
        let title = [rawTitle, description, help]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Value cascade: AXValue → concat of AXChildren text (up to 2K chars)
        // when AXValue is empty. Handles containers whose "text content"
        // lives in nested labels/AXStaticTexts.
        let value: String?
        if let v = rawValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = v
        } else {
            value = Self.collectChildText(element, maxLength: 2000)
        }

        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let bounds = Self.copyBoundsAttribute(element)

        let picked = PickedElement(
            pid: Int32(pid),
            role: role,
            title: title,
            value: value,
            bounds: bounds ?? CGRect(origin: axPoint, size: .zero),
            bundleId: bundleId
        )

        HeyClickyLog.log(
            "openclicky.pick_overlay.click_captured",
            lane: "system",
            direction: "internal",
            [
                "role": role ?? "?",
                "title": String((title ?? "").prefix(80)),
                "pid": Int(pid),
                "bundle_id": bundleId ?? "",
                "bounds_w": String(format: "%.0f", picked.bounds.width),
                "bounds_h": String(format: "%.0f", picked.bounds.height),
            ]
        )

        // Register the live AX element in the pinned-element side
        // table BEFORE writing to PickStash so the badge overlay's
        // .pickStashDidChange handler can find it during classifier
        // rebuild for AXFollower delta-follow.
        let anchorID = AnnotationBadgeOverlayClassifier.pinAnchorID(for: picked)
        OpenClickyPinnedAXElementRegistry.store(element, for: anchorID)
        PickStash.shared.set(picked)
        NSLog("openclicky.pickElement.overlay: captured role=\(role ?? "?") title=\(title ?? "?") pid=\(pid)")
        teardown()
    }

    // MARK: - AX helpers

    /// Walk `element`'s AXChildren once and concat their text
    /// (Title / Value / Description). Bounded to `maxLength` chars
    /// and 64 children so a container with a huge subtree doesn't
    /// stall the pick path. Used when the pinned element's own
    /// AXValue is empty (typical for div/section wrappers whose
    /// content lives in nested labels).
    fileprivate static func collectChildText(_ element: AXUIElement, maxLength: Int) -> String? {
        var accum = ""
        var visited = 0
        // Bounded DFS. Depth cap 4 covers common web patterns
        // (AXList → AXListItem → AXStaticText) without runaway walks
        // on huge subtrees. Visited cap 500 prevents stalls on giant
        // trees (e.g. entire scroll containers).
        func walk(_ el: AXUIElement, depth: Int) {
            if accum.count >= maxLength || visited >= 500 || depth > 4 { return }
            visited += 1
            let bits = [
                copyStringAttribute(el, kAXTitleAttribute),
                copyStringAttribute(el, kAXValueAttribute),
                copyStringAttribute(el, kAXDescriptionAttribute),
            ]
                .compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for bit in bits {
                if !accum.isEmpty { accum += " " }
                accum += bit
                if accum.count >= maxLength { return }
            }
            var raw: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw)
            guard err == .success, let arr = raw as? [AXUIElement], !arr.isEmpty else { return }
            for child in arr.prefix(64) {
                walk(child, depth: depth + 1)
                if accum.count >= maxLength || visited >= 500 { return }
            }
        }
        walk(element, depth: 0)
        let trimmed = accum.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "…" : trimmed
    }

    fileprivate static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard result == .success, let raw else { return nil }
        if CFGetTypeID(raw) == CFStringGetTypeID() {
            return raw as? String
        }
        return String(describing: raw)
    }

    fileprivate static func copyBoundsAttribute(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else {
            return nil
        }
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
        return CGRect(origin: origin, size: size)
    }
}
