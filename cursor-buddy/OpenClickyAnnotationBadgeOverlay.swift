//
//  OpenClickyAnnotationBadgeOverlay.swift
//  cursor-buddy
//
//  Phase 7.1 (Layer 4 UX): floating "➕" annotation badge that follows
//  every currently-pinned element and lets the user attach a free-text
//  note into `AnnotationStash`.
//
//  Ported from Everywhere's `AnnotationOverlayHost` + `AnnotationOverlayWindow`
//  (`src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs`,
//  `src/Everywhere.Core/Views/Annotation/AnnotationOverlayWindow.cs`).
//
//  Design summary
//  --------------
//  * Subscribes to `.pickStashDidChange`, `.annotationStashDidChange`,
//    `.openClickyWhiteboardStashCleared`. On change, recomputes an
//    `AnchorState` list — one anchor per live pin / whiteboard region.
//  * Also subscribes to `.openClickyManualCaptureCompleted` so the
//    badges tear themselves down after the user ships a snapshot to
//    the agent (mirrors Everywhere `AnnotationOverlayHost.cs:63-64,
//    218-237`).
//  * Each anchor gets an AppKit `NSPanel` pair: a click-through outline
//    that traces the element bounds, and an interactive badge with an
//    `NSHostingView<AnnotationBadgeView>` root.
//  * `OpenClickyAXFollower` slides both panels when the element moves.
//  * Clicking ➕ expands the badge to a textarea (320×110). Commit
//    gestures: Cmd+Enter, or focus loss. Empty commit that follows a
//    ✓ badge deletes the previously-stored annotation.
//  * `ClearContextStash` fires `.pickStashDidChange` (PickStash becomes
//    empty) so `.rebuild()` tears down every pair automatically.
//
//  Test surface
//  ------------
//  The `AnnotationBadgeOverlayClassifier` struct is `internal` and pure
//  so `cursor-buddyTests` can exercise the ➕ / ✓ / count classifier
//  logic without spinning up NSPanels.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import OpenClickyContextService

// MARK: - Anchor / state models

/// Everything an on-screen badge / outline needs to render. Value type
/// so the overlay's rebuild pass can diff old vs new without touching
/// live UI state.
struct AnnotationAnchor: Hashable {
    /// Stable identity for the anchor — used both as the dictionary
    /// key on the overlay and as `AnnotationItem.anchorRef` when the
    /// user commits a note. Currently derived from the pinned element
    /// (pid + role + title + bounds hash) so a fresh pin of the same
    /// element counts as the same anchor.
    let id: String
    let source: AnnotationSource
    let label: String
    /// Bounds in AX/Quartz top-left global coords. Consumers turn this
    /// into Cocoa panel frames.
    let axBounds: CGRect
    /// AX element to feed into `OpenClickyAXFollower`. Only meaningful
    /// for `.pin` anchors; whiteboard / linkrect anchors leave this nil
    /// and the badge stays put where it was drawn.
    let axElement: AXElementBox?
}

/// Boxed AX element so we can shove it in a Hashable struct. AX
/// elements are `CFTypeRef`; identity comparison is enough for us.
final class AXElementBox: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// UI-facing snapshot of one anchor's badge state. Kept out of the
/// hashable `AnnotationAnchor` so a fresh annotation append doesn't
/// tear down and rebuild the underlying NSPanels.
struct AnnotationBadgeState: Equatable {
    /// Number of live `AnnotationItem`s whose `anchorRef == anchor.id`
    /// AND `source == anchor.source`. Zero means "not yet annotated"
    /// → render "＋". Non-zero renders "✓ N".
    var noteCount: Int

    /// Latest annotation body for this anchor, if any. Prefilled into
    /// the textarea on re-edit so the user can revise instead of
    /// starting over.
    var lastBody: String?

    var isAnnotated: Bool { noteCount > 0 }
}

/// Process-wide side table mapping anchor ids to their live
/// `AXUIElement`. `PickStash` only carries value snapshots so the
/// follower needs a fresh handle to observe. The pick overlay writes
/// here alongside `PickStash.shared.set(...)`; the badge overlay
/// classifier reads back the boxed element for delta-follow.
@MainActor
enum OpenClickyPinnedAXElementRegistry {
    private static var boxByAnchorID: [String: AXElementBox] = [:]

    static func store(_ element: AXUIElement, for anchorID: String) {
        boxByAnchorID[anchorID] = AXElementBox(element)
    }

    static func element(for anchorID: String) -> AXElementBox? {
        boxByAnchorID[anchorID]
    }

    static func remove(_ anchorID: String) {
        boxByAnchorID.removeValue(forKey: anchorID)
    }

    static func removeAll() {
        boxByAnchorID.removeAll()
    }
}

/// Pure classifier: given a snapshot of the three stashes, decide
/// which anchors should be on screen and their badge state. Exists as
/// its own struct so tests can run it without NSPanels.
struct AnnotationBadgeOverlayClassifier {
    /// Legacy single-pin field (kept for backward-compat with test
    /// fixtures). If `picks` is provided it wins. Multi-pin uses
    /// `PickStash.peekAll()`.
    let pick: PickedElement?
    /// Multi-pin snapshot from `PickStash.peekAll()`. When empty,
    /// falls back to the single `pick` field.
    var picks: [PickedElement] = []
    let annotations: [AnnotationItem]
    let whiteboardPending: Bool
    /// Optional live-element resolver — the process-wide registry is
    /// used at runtime; tests pass a closure returning nil.
    var resolveElement: (String) -> AXElementBox? = { _ in nil }

    func anchors() -> [(anchor: AnnotationAnchor, state: AnnotationBadgeState)] {
        var out: [(AnnotationAnchor, AnnotationBadgeState)] = []

        // Resolve the effective pin set. Prefer multi-slot `picks`;
        // fall back to legacy single `pick` field for old tests.
        let allPicks: [PickedElement]
        if !picks.isEmpty {
            allPicks = picks
        } else if let pick {
            allPicks = [pick]
        } else {
            allPicks = []
        }

        for pick in allPicks {
            let id = Self.pinAnchorID(for: pick)
            let label = Self.pinAnchorLabel(for: pick)
            let matching = annotations.filter {
                $0.source == .pin && ($0.anchorRef == id || $0.anchorLabel == label)
            }
            let anchor = AnnotationAnchor(
                id: id,
                source: .pin,
                label: label,
                axBounds: pick.bounds,
                axElement: resolveElement(id)
            )
            let state = AnnotationBadgeState(
                noteCount: matching.count,
                lastBody: matching.last?.body
            )
            out.append((anchor, state))
        }

        // Whiteboard / linkrect: we don't have per-region UI yet, so
        // Phase 7.1 leaves them out. The infrastructure listens for
        // the notifications so future phases can drop anchors in
        // here without another round of plumbing.

        return out
    }

    static func pinAnchorID(for element: PickedElement) -> String {
        let role = element.role ?? "-"
        let title = element.title ?? "-"
        let bx = Int(element.bounds.origin.x.rounded())
        let by = Int(element.bounds.origin.y.rounded())
        let bw = Int(element.bounds.size.width.rounded())
        let bh = Int(element.bounds.size.height.rounded())
        return "pin:\(element.pid):\(role):\(title):\(bx),\(by),\(bw),\(bh)"
    }

    static func pinAnchorLabel(for element: PickedElement) -> String {
        let roleName = element.role.map { Self.friendlyRoleName($0) } ?? "Element"
        if let title = element.title, !title.isEmpty {
            return "\(roleName) \"\(title)\""
        }
        return roleName
    }

    private static func friendlyRoleName(_ role: String) -> String {
        if role.hasPrefix("AX") { return String(role.dropFirst(2)) }
        return role
    }
}

// MARK: - Overlay controller

@MainActor
final class OpenClickyAnnotationBadgeOverlay {
    static let shared = OpenClickyAnnotationBadgeOverlay()

    /// The stashes we observe. Injected so unit tests can point us at
    /// private instances instead of the process-wide shared ones.
    private let pickStash: PickStash
    private let annotationStash: AnnotationStash
    private let notificationCenter: NotificationCenter

    /// Live badge pairs keyed by anchor id.
    private var pairs: [String: BadgePair] = [:]

    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    init(
        pickStash: PickStash = .shared,
        annotationStash: AnnotationStash = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.pickStash = pickStash
        self.annotationStash = annotationStash
        self.notificationCenter = notificationCenter
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let center = notificationCenter
        center.publisher(for: .pickStashDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        center.publisher(for: .annotationStashDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        center.publisher(for: .openClickyWhiteboardStashCleared)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        center.publisher(for: .openClickyManualCaptureCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleManualCaptureCompleted() }
            .store(in: &cancellables)

        rebuild()
    }

    /// Snapshot shipped → clear everything on-screen so the next
    /// prompt is genuinely clean. Everywhere's parity path is
    /// `AnnotationOverlayHost.OnManualCaptureCompleted`
    /// (`AnnotationOverlayHost.cs:218-237`): unsubscribe handlers,
    /// hide + close overlays, drop `_overlays`. On our side we also
    /// drain the pin / annotation / whiteboard stashes so the
    /// classifier stays empty on the next rebuild.
    private func handleManualCaptureCompleted() {
        clearAllBadges()
        pickStash.clearWithEvent()
        let queued = annotationStash.peek()
        if !queued.isEmpty {
            annotationStash.consume(queued)
        }
        WhiteboardStash.shared.clearWithEvent()
        OpenClickyPinnedAXElementRegistry.removeAll()
    }

    /// Tear down every live badge/outline pair. Used both by
    /// `stop()` and by the ManualCaptureCompleted fan-out.
    func clearAllBadges() {
        for (_, pair) in pairs {
            pair.tearDown()
        }
        pairs.removeAll()
    }

    func stop() {
        cancellables.removeAll()
        for (_, pair) in pairs {
            pair.tearDown()
        }
        pairs.removeAll()
        started = false
    }

    // MARK: - Rebuild

    /// Diff live anchors against the pairs dictionary; add new pairs,
    /// remove stale ones, refresh state on existing.
    ///
    /// Multi-pin semantics (byte-parity with Everywhere
    /// `AnnotationOverlayHost.OnPinned`, `_overlays.Add` at
    /// `AnnotationOverlayHost.cs:205`): every Alt+S press ACCUMULATES
    /// a badge onscreen. Previous pins stay visible until the user
    /// commits (Enter → SnapshotContext → `handleManualCaptureCompleted`
    /// wipes them all) or explicitly clears (Alt+C / annotation clear).
    ///
    /// Implementation: PickStash is single-slot (Everywhere-parity —
    /// see `PickStash.cs:18 _current`). The multi-pin ACCUMULATION
    /// lives here in the overlay's `pairs` dict. Non-pin sources
    /// (annotation, whiteboard) still follow their stash 1:1.
    func rebuild() {
        var classifier = AnnotationBadgeOverlayClassifier(
            pick: nil,
            annotations: annotationStash.peek(),
            whiteboardPending: false,
            resolveElement: { OpenClickyPinnedAXElementRegistry.element(for: $0) }
        )
        classifier.picks = pickStash.peekAll()
        let anchors = classifier.anchors()
        let liveIDs = Set(anchors.map { $0.anchor.id })

        // Drop stale anchors (their stash entry vanished). PickStash
        // is now multi-slot (`peekAll`), so all live pins are in
        // classifier output. A pair whose id isn't in liveIDs is a
        // legitimately removed pin (Alt+C or TTL expiry) or a stale
        // annotation.
        for (id, pair) in pairs where !liveIDs.contains(id) {
            pair.tearDown()
            pairs.removeValue(forKey: id)
        }

        // Create or update remaining anchors.
        for (anchor, state) in anchors {
            if let pair = pairs[anchor.id] {
                pair.apply(state: state)
            } else {
                let pair = BadgePair(
                    anchor: anchor,
                    onCommit: { [weak self] body in
                        self?.commit(body: body, for: anchor)
                    },
                    onClear: { [weak self] in
                        self?.clearAnnotations(for: anchor)
                    }
                )
                pair.apply(state: state)
                pair.presentIfNeeded()
                pairs[anchor.id] = pair
            }
        }
    }

    // MARK: - Commit / clear paths

    private func commit(body: String, for anchor: AnnotationAnchor) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Drop the previous annotation for this anchor so re-edits
        // don't stack revisions in the payload. Same pattern
        // Everywhere follows in `AnnotationOverlayHost.OnCommitted`.
        let existing = annotationStash.peek().filter {
            $0.source == anchor.source && ($0.anchorRef == anchor.id || $0.anchorLabel == anchor.label)
        }
        if !existing.isEmpty {
            annotationStash.consume(existing)
        }

        let item = AnnotationItem(
            source: anchor.source,
            body: trimmed,
            anchorRef: anchor.id,
            anchorLabel: anchor.label
        )
        do {
            _ = try annotationStash.append(item)
            HeyClickyLog.log(
                "openclicky.annotation_badge.commit",
                lane: "system",
                direction: "internal",
                [
                    "body_len": trimmed.count,
                    "total_annotations": annotationStash.peek().count,
                ]
            )
        } catch {
            NSLog("openclicky.annotationBadge.overlay: append rejected \(error)")
        }
    }

    private func clearAnnotations(for anchor: AnnotationAnchor) {
        let existing = annotationStash.peek().filter {
            $0.source == anchor.source && ($0.anchorRef == anchor.id || $0.anchorLabel == anchor.label)
        }
        if !existing.isEmpty {
            annotationStash.consume(existing)
        }
    }
}

// MARK: - BadgePair (private)

/// Owns the AppKit windows + AXFollower for one anchor.
@MainActor
private final class BadgePair {
    let anchor: AnnotationAnchor

    private let outline: OutlinePanel
    private let badge: BadgePanel
    private var follower: OpenClickyAXFollower?

    private let onCommit: (String) -> Void
    private let onClear: () -> Void

    private var currentAXRect: CGRect

    init(
        anchor: AnnotationAnchor,
        onCommit: @escaping (String) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.anchor = anchor
        self.onCommit = onCommit
        self.onClear = onClear
        self.currentAXRect = anchor.axBounds

        self.outline = OutlinePanel()
        self.badge = BadgePanel(anchorLabel: anchor.label)

        self.badge.onCommit = { [weak self] body in
            self?.onCommit(body)
        }
        self.badge.onClear = { [weak self] in
            self?.onClear()
        }
    }

    func presentIfNeeded() {
        moveTo(axRect: currentAXRect)
        outline.orderFrontRegardless()
        badge.orderFrontRegardless()
        HeyClickyLog.log(
            "openclicky.annotation_badge.attached",
            lane: "system",
            direction: "internal",
            [
                "anchor_role": anchor.axElement != nil ? "pin" : anchor.source.rawValue,
                "anchor_title": String(anchor.label.prefix(80)),
                "x": Int(anchor.axBounds.origin.x),
                "y": Int(anchor.axBounds.origin.y),
            ]
        )
        HeyClickyLog.log(
            "openclicky.window.installed.annotation_badge_outline",
            lane: "system",
            direction: "internal",
            [
                "window_num": outline.windowNumber,
                "size_w": Int(outline.frame.width),
                "size_h": Int(outline.frame.height),
                "level": outline.level.rawValue,
                "alpha": Double(outline.alphaValue),
                "purpose": "annotation_badge_outline",
            ]
        )
        HeyClickyLog.log(
            "openclicky.window.installed.annotation_badge",
            lane: "system",
            direction: "internal",
            [
                "window_num": badge.windowNumber,
                "size_w": Int(badge.frame.width),
                "size_h": Int(badge.frame.height),
                "level": badge.level.rawValue,
                "alpha": Double(badge.alphaValue),
                "purpose": "annotation_badge_popover",
            ]
        )

        if let box = anchor.axElement {
            let follower = OpenClickyAXFollower(element: box.element) { [weak self] rect in
                guard let self else { return }
                guard let rect else {
                    self.outline.orderOut(nil)
                    // Keep the badge if it's currently expanded so we
                    // don't yank the popover under a typing user.
                    if !self.badge.isExpanded {
                        self.badge.orderOut(nil)
                    }
                    return
                }
                self.currentAXRect = rect
                self.moveTo(axRect: rect)
                if !self.outline.isVisible { self.outline.orderFrontRegardless() }
                if !self.badge.isVisible { self.badge.orderFrontRegardless() }
            }
            follower.start()
            self.follower = follower
        }
    }

    func apply(state: AnnotationBadgeState) {
        badge.apply(state: state)
    }

    func tearDown() {
        follower?.stop()
        follower = nil
        let outlineNum = outline.windowNumber
        let badgeNum = badge.windowNumber
        outline.orderOut(nil)
        badge.orderOut(nil)
        HeyClickyLog.log(
            "openclicky.annotation_badge.detached",
            lane: "system",
            direction: "internal",
            [
                "reason": "teardown",
            ]
        )
        HeyClickyLog.log(
            "openclicky.window.dismissed.annotation_badge_outline",
            lane: "system",
            direction: "internal",
            ["window_num": outlineNum, "reason": "teardown"]
        )
        HeyClickyLog.log(
            "openclicky.window.dismissed.annotation_badge",
            lane: "system",
            direction: "internal",
            ["window_num": badgeNum, "reason": "teardown"]
        )
    }

    private func moveTo(axRect: CGRect) {
        guard axRect.width > 0, axRect.height > 0 else { return }
        let cocoa = Self.cocoaRect(fromAXRect: axRect)
        outline.setFrame(cocoa, display: true)

        // Badge sits at the top-right corner, offset outwards a hair.
        let badgeSize = BadgePanel.collapsedSize
        let origin = NSPoint(
            x: cocoa.maxX + 6 - badgeSize.width / 2,
            y: cocoa.maxY - 6 - badgeSize.height / 2
        )
        badge.updateAnchor(origin: origin)
    }

    private static func cocoaRect(fromAXRect axRect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return axRect }
        let flippedY = primary.frame.height - axRect.origin.y - axRect.size.height
        return NSRect(x: axRect.origin.x, y: flippedY, width: axRect.size.width, height: axRect.size.height)
    }
}

// MARK: - Outline panel

private final class OutlinePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        OpenClickyWindowLevels.applyCursorOverlayLevel(to: self)

        let view = OutlineView()
        view.autoresizingMask = [.width, .height]
        self.contentView = view
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.systemRed.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - Badge panel

@MainActor
private final class BadgePanel: NSPanel {
    static let collapsedSize = CGSize(width: 24, height: 24)
    static let expandedSize = CGSize(width: 320, height: 110)

    var onCommit: ((String) -> Void)?
    var onClear: (() -> Void)?

    fileprivate var isExpanded = false
    private var collapsedOrigin: NSPoint = .zero
    private let anchorLabel: String

    private let hostingView: NSHostingView<BadgeRootView>
    private let viewModel: BadgeViewModel

    init(anchorLabel: String) {
        self.anchorLabel = anchorLabel
        let model = BadgeViewModel()
        self.viewModel = model
        let root = BadgeRootView(model: model)
        self.hostingView = NSHostingView(rootView: root)

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        OpenClickyWindowLevels.applyCursorOverlayLevel(to: self)

        hostingView.frame = NSRect(origin: .zero, size: Self.collapsedSize)
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView

        model.onPlusTap = { [weak self] in
            self?.toggleExpanded()
        }
        model.onCommit = { [weak self] body in
            self?.handleCommit(body: body)
        }
        model.onCancel = { [weak self] in
            self?.collapse(commit: false)
        }
    }

    override var canBecomeKey: Bool { isExpanded }
    override var canBecomeMain: Bool { false }

    func updateAnchor(origin: NSPoint) {
        collapsedOrigin = origin
        if !isExpanded {
            setFrameOrigin(origin)
        } else {
            // Keep the popover's badge corner anchored at the same
            // collapsed origin — the textarea grows down-left from it.
            let expanded = NSPoint(
                x: origin.x - (Self.expandedSize.width - Self.collapsedSize.width),
                y: origin.y - (Self.expandedSize.height - Self.collapsedSize.height)
            )
            setFrameOrigin(expanded)
        }
    }

    func apply(state: AnnotationBadgeState) {
        viewModel.apply(state: state)
    }

    private func toggleExpanded() {
        if isExpanded {
            collapse(commit: true)
        } else {
            expand()
        }
    }

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true

        let frame = NSRect(
            origin: NSPoint(
                x: collapsedOrigin.x - (Self.expandedSize.width - Self.collapsedSize.width),
                y: collapsedOrigin.y - (Self.expandedSize.height - Self.collapsedSize.height)
            ),
            size: Self.expandedSize
        )
        setFrame(frame, display: true)
        viewModel.expand()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        HeyClickyLog.log(
            "openclicky.annotation_badge.expanded",
            lane: "system",
            direction: "internal",
            [:]
        )
    }

    private func collapse(commit: Bool) {
        if !isExpanded { return }
        isExpanded = false

        let body = viewModel.textBody.trimmingCharacters(in: .whitespacesAndNewlines)

        if commit {
            if !body.isEmpty {
                onCommit?(body)
                viewModel.markCommitted(body: body)
            } else if viewModel.hadCommittedBody {
                // Re-editing a ✓ badge, cleared text, collapsed →
                // treat as delete.
                onClear?()
                viewModel.markCleared()
            }
        }

        let frame = NSRect(origin: collapsedOrigin, size: Self.collapsedSize)
        setFrame(frame, display: true)
        viewModel.collapse()
    }

    private func handleCommit(body: String) {
        collapse(commit: true)
    }
}

// MARK: - Badge SwiftUI

/// Observable model driving the badge / popover. Lives in AppKit so
/// AppKit can push imperative "collapse" / "expand" calls.
@MainActor
final class BadgeViewModel: ObservableObject {
    @Published var noteCount: Int = 0
    @Published var isExpanded: Bool = false
    @Published var textBody: String = ""

    /// Whether the current anchor already has at least one committed
    /// annotation. Used to decide "empty collapse means delete".
    fileprivate var hadCommittedBody: Bool = false

    fileprivate var onPlusTap: (() -> Void)?
    fileprivate var onCommit: ((String) -> Void)?
    fileprivate var onCancel: (() -> Void)?

    var badgeLabel: String {
        if noteCount == 0 { return "＋" }
        if noteCount == 1 { return "✓" }
        return "✓ \(noteCount)"
    }

    var badgeFill: Color {
        if noteCount == 0 {
            return Color(red: 0.86, green: 0.12, blue: 0.20) // red ➕
        }
        return Color(red: 0.24, green: 0.78, blue: 0.55) // green ✓
    }

    func apply(state: AnnotationBadgeState) {
        noteCount = state.noteCount
        hadCommittedBody = state.noteCount > 0
        if let body = state.lastBody, !isExpanded {
            textBody = body
        }
    }

    func expand() {
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
    }

    func markCommitted(body: String) {
        hadCommittedBody = true
        textBody = body
    }

    func markCleared() {
        hadCommittedBody = false
        textBody = ""
    }

    func plusTapped() { onPlusTap?() }
    func commitTapped() { onCommit?(textBody) }
    func cancelTapped() { onCancel?() }
}

private struct BadgeRootView: View {
    @ObservedObject var model: BadgeViewModel
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if model.isExpanded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.33), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)

                textEditorLayer
                    .padding(.leading, 12)
                    .padding(.trailing, 34)
                    .padding(.vertical, 10)
            }

            plusButton
                .padding(4)
        }
        .background(Color.clear)
        .onKeyPress(.escape) {
            model.cancelTapped()
            return .handled
        }
    }

    private var plusButton: some View {
        Button {
            model.plusTapped()
        } label: {
            Text(model.badgeLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(model.badgeFill)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                )
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var textEditorLayer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("annotate this element…")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            AnnotationTextEditor(text: $model.textBody, onCommit: {
                model.commitTapped()
            }, onCancel: {
                model.cancelTapped()
            })
            .focused($textFieldFocused)
            .onAppear {
                textFieldFocused = true
            }
        }
    }
}

/// Multi-line editor that submits on Cmd+Enter and cancels on Escape.
/// Backed by an `NSTextView` so we can intercept the key events without
/// SwiftUI's TextEditor eating them.
private struct AnnotationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 12)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView, textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AnnotationTextEditor
        weak var textView: NSTextView?

        init(_ parent: AnnotationTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Plain Enter inserts a newline; Cmd+Enter submits.
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.command) {
                    parent.onCommit()
                    return true
                }
            }
            return false
        }
    }
}
