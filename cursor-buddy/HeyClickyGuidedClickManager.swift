//
//  HeyClickyGuidedClickManager.swift
//  cursor-buddy
//
//  Guided-click overlay + follow-up injection for the demo's [TARGET]
//  primitive. See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §5.5.
//

import AppKit
import Foundation

@MainActor
final class HeyClickyGuidedClickManager: NSObject {
    static let shared = HeyClickyGuidedClickManager()

    private var overlayWindow: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var target: CGPoint = .zero
    private var radius: CGFloat = 0
    private var label: String = ""
    private var screenIndex: Int?
    private var timeoutTask: Task<Void, Never>?

    /// Buffered follow-up when the Realtime WS is not ready. Consumed
    /// by OpenAIRealtimeSpeechClient on next session.created event.
    private(set) var pendingFollowUp: String?

    func consumePendingFollowUp() -> String? {
        let value = pendingFollowUp
        pendingFollowUp = nil
        return value
    }

    func arm(x: Double, y: Double, radius: Double, label: String, screen: Int?) {
        disarm()

        let screens = NSScreen.screens
        let matchedScreen: NSScreen = {
            if let screen, screen >= 0, screen < screens.count { return screens[screen] }
            return NSScreen.main ?? screens.first ?? NSScreen()
        }()
        let scale = matchedScreen.backingScaleFactor
        let frame = matchedScreen.frame

        // Walkthrough coords are top-left screenshot pixels. AppKit's
        // NSEvent.mouseLocation is bottom-left points. Convert once here
        // so hit-test and overlay share one coordinate system.
        let xPoints = CGFloat(x) / scale
        let yTopPoints = CGFloat(y) / scale
        let rPoints = CGFloat(radius) / scale
        let targetPoint = CGPoint(
            x: frame.minX + xPoints,
            y: frame.maxY - yTopPoints
        )
        self.target = targetPoint
        self.radius = rPoints
        self.label = label
        self.screenIndex = screen

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: matchedScreen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]

        let overlayView = HeyClickyGuidedClickOverlayView(
            frame: NSRect(origin: .zero, size: frame.size),
            targetInScreen: targetPoint,
            radius: rPoints,
            screenFrame: frame
        )
        window.contentView = overlayView
        window.orderFrontRegardless()
        overlayWindow = window
        HeyClickyLog.log(
            "openclicky.window.installed.guided_click",
            lane: "system",
            direction: "internal",
            [
                "window_num": window.windowNumber,
                "size_w": Int(window.frame.width),
                "size_h": Int(window.frame.height),
                "level": window.level.rawValue,
                "alpha": Double(window.alphaValue),
                "purpose": "heyclicky_guided_click_ring",
            ]
        )

        installMonitors()
        scheduleTimeout()

        // Tell any subscribed OverlayWindow to fly the buddy to the
        // target ring so the visual is consistent with regular POINT
        // guidance instead of an orphan blue circle appearing.
        NotificationCenter.default.post(
            name: .heyClickyTargetArmed,
            object: nil,
            userInfo: [
                "x": targetPoint.x,
                "y": targetPoint.y,
                "screenIndex": screen ?? -1
            ]
        )
    }

    func disarm() {
        let windowNum = overlayWindow?.windowNumber ?? 0
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        HeyClickyLog.log(
            "openclicky.window.dismissed.guided_click",
            lane: "system",
            direction: "internal",
            [
                "window_num": windowNum,
                "reason": "disarm",
            ]
        )
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.evaluateClick(at: NSEvent.mouseLocation)
            }
            _ = event
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.evaluateClick(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func evaluateClick(at location: NSPoint) {
        // Compare in screen coordinates.
        let dx = location.x - target.x
        let dy = location.y - target.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius else { return }
        let followUp = "guided_click_follow_up: \(label)"
        pendingFollowUp = followUp
        NotificationCenter.default.post(
            name: .clickyHeyClickyGuidedClickFollowUp,
            object: nil,
            userInfo: ["text": followUp, "label": label]
        )
        disarm()
    }

    private func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.disarm() }
        }
    }
}

private final class HeyClickyGuidedClickOverlayView: NSView {
    private let targetInScreen: CGPoint
    private let radius: CGFloat
    private let screenFrame: CGRect

    init(frame: NSRect, targetInScreen: CGPoint, radius: CGFloat, screenFrame: CGRect) {
        self.targetInScreen = targetInScreen
        self.radius = radius
        self.screenFrame = screenFrame
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let localX = targetInScreen.x - screenFrame.minX
        let localY = targetInScreen.y - screenFrame.minY
        let rect = CGRect(
            x: localX - radius,
            y: localY - radius,
            width: radius * 2,
            height: radius * 2
        )
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: rect)
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
        ctx.fillEllipse(in: rect)
    }
}
