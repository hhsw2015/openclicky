// OpenClickyLinkRectHarvester.swift
// cursor-buddy
//
// Ported from Everywhere:
//   src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs
//   @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Given a drag rect in Quartz (top-left origin) global coordinates,
// walks the AX tree of every on-screen pid whose window intersects
// the rect, collects `AXLink` elements whose bounds pass a linkclump
// majority-overlap test, extracts (url, title), redacts credentials,
// dedups by URL, and caps at Everywhere-parity limits.
//
// Design notes vs. `VisualElementContext.LinkRect.HarvestLinks`:
//   * Single global 50k node budget, drained across every pid.
//   * `MaxDepth = 60` per subtree (matches C# `MaxDepth`).
//   * Zero-size nodes still descend (lazy AX subtrees expose 0x0
//     containers with populated `AXChildren`) — only accept if the
//     node itself passes majority-overlap.
//   * Icon-only anchors (both axes ≤ 32 AND no title from any AX
//     channel) are dropped.
//   * Dedup add-or-upgrade: `(hasTitle ? 100 : 0) + width*height`
//     wins over the smaller / unlabelled sibling.
//   * `javascript:` rescue path from Everywhere is deferred (see
//     phase7-1-linkrect impl notes). Non-http(s)/mailto URLs are
//     dropped.
//   * Credential redaction is applied at the boundary so the
//     `picked_links[]` field carries the same sanitised URL shape
//     as the SnapshotContext `url` field.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenClickyContextService

/// Everywhere-parity caps. Values match
/// `VisualElementContext.LinkRect.cs:326,357` and
/// `ContextStashWriter.cs:405-407` byte-for-byte.
enum OpenClickyLinkRectLimits {
    static let maxLinks = 200
    static let maxUrlLen = 2048
    static let maxTitleLen = 200
    static let maxDepth = 60
    static let walkBudget = 50_000
}

/// Pure test seam so the geometry + selection rules stay verifiable
/// without the opaque `AXUIElement` C-ref.
enum OpenClickyLinkRectGeometry {

    /// Ported from `IntersectsLoose` (LinkRect.cs:400). Uses
    /// half-open right/bottom edges matching `PixelRect.Right/Bottom`.
    static func intersectsLoose(_ a: CGRect, _ b: CGRect) -> Bool {
        let aRight = a.origin.x + a.size.width
        let aBottom = a.origin.y + a.size.height
        let bRight = b.origin.x + b.size.width
        let bBottom = b.origin.y + b.size.height
        return !(aRight < b.origin.x
                 || a.origin.x > bRight
                 || aBottom < b.origin.y
                 || a.origin.y > bBottom)
    }

    /// Ported from `MajorityOverlap` (LinkRect.cs:411-422).
    /// Anchor is "selected" iff:
    ///   * any horizontal overlap
    ///   * anchor mid-Y lies inside the rect's Y span
    static func majorityOverlap(anchor: CGRect, dragRect: CGRect) -> Bool {
        guard anchor.size.width > 0, anchor.size.height > 0 else { return false }
        let anchorRight = anchor.origin.x + anchor.size.width
        let dragRight = dragRect.origin.x + dragRect.size.width
        if anchorRight < dragRect.origin.x || anchor.origin.x > dragRight {
            return false
        }
        let midY = anchor.origin.y + anchor.size.height / 2
        let dragBottom = dragRect.origin.y + dragRect.size.height
        return midY >= dragRect.origin.y && midY <= dragBottom
    }

    /// Ported from `AddOrUpgrade` (LinkRect.cs:474-488). Larger
    /// area OR having a non-empty title beats the incumbent. Dict
    /// keyed by lowercase URL to match C# `OrdinalIgnoreCase`.
    static func upgradeScore(title: String?, bounds: CGRect) -> CGFloat {
        let titleBonus: CGFloat = (title?.isEmpty == false) ? 100 : 0
        return titleBonus + bounds.size.width * bounds.size.height
    }
}

/// Result of a single drag-rect harvest.
public struct OpenClickyLinkRectHarvestResult: Equatable, Sendable {
    /// Deduped, capped, credential-redacted picks in insertion order.
    public let picks: [OpenClickyPickedLink]
    /// Bounds (Quartz global, top-left origin) for each pick, aligned
    /// by index with `picks`. Empty when the corresponding pick came
    /// from a non-AX source (e.g. clipboard rescue). Used by the
    /// LinkRect overlay's 700ms flash — port of Everywhere's
    /// `HarvestedLink.Bounds` (IVisualElementContext.cs:184-187).
    public let pickBounds: [CGRect]
    /// Number of AXLink candidates seen before dedup / cap / filter.
    /// Diagnostic only.
    public let candidatesSeen: Int
    /// Number of AX nodes visited during the walk. Cost signal.
    public let nodesVisited: Int
    /// True when the walk terminated because `walkBudget` was drained
    /// rather than the tree being exhausted.
    public let budgetExhausted: Bool
}

/// AX-side harvest. Public entry point:
///   `OpenClickyLinkRectHarvester.harvest(dragRect:)`.
///
/// Everything mutable lives inside a session struct so multiple
/// concurrent harvests (in tests) don't share the visit counter.
public enum OpenClickyLinkRectHarvester {

    /// Called from `OpenClickyContextHotkeys.performLinkRectStub`
    /// after the overlay resolves a rect.
    public static func harvest(dragRect: CGRect) -> OpenClickyLinkRectHarvestResult {
        guard dragRect.size.width > 0, dragRect.size.height > 0 else {
            return .init(picks: [], pickBounds: [], candidatesSeen: 0, nodesVisited: 0, budgetExhausted: false)
        }

        var session = HarvestSession(dragRect: dragRect)
        session.harvest()
        let result = session.finalise()

        // Debug log for round-2 accuracy verification. Emit AFTER the
        // walk so the log shows the settled candidate/kept counts and
        // the first link's bounds (used to spot when majority-overlap
        // rules drift). First-link bounds are in Quartz global coords —
        // same space as `dragRect` — so the log tail can eyeball the
        // pair without another translation.
        let firstBounds = session.byUrlBounds.values.first ?? .zero
        HeyClickyLog.log(
            "openclicky.linkrect_harvest.debug",
            lane: "system",
            direction: "internal",
            [
                "drag_quartz_x": Int(dragRect.origin.x),
                "drag_quartz_y": Int(dragRect.origin.y),
                "drag_w": Int(dragRect.size.width),
                "drag_h": Int(dragRect.size.height),
                "candidates_scanned": result.candidatesSeen,
                "candidates_kept": result.picks.count,
                "first_link_bounds_x": Int(firstBounds.origin.x),
                "first_link_bounds_y": Int(firstBounds.origin.y),
                "first_link_bounds_w": Int(firstBounds.size.width),
                "first_link_bounds_h": Int(firstBounds.size.height),
            ]
        )
        return result
    }

    // MARK: - Internal session

    private struct HarvestSession {
        let dragRect: CGRect
        var byUrl: [String: OpenClickyPickedLink] = [:]
        var byUrlBounds: [String: CGRect] = [:]
        var insertionOrder: [String] = []
        var nodesVisited = 0
        var candidatesSeen = 0
        var budgetRemaining = OpenClickyLinkRectLimits.walkBudget
        var budgetExhausted = false

        mutating func harvest() {
            let pids = onScreenPidsIntersecting(dragRect)
            for pid in pids {
                if budgetRemaining <= 0 {
                    budgetExhausted = true
                    break
                }
                let app = AXUIElementCreateApplication(pid)
                walk(app, depth: 0)
            }
        }

        mutating func walk(_ node: AXUIElement, depth: Int) {
            if depth > OpenClickyLinkRectLimits.maxDepth { return }
            if budgetRemaining <= 0 {
                budgetExhausted = true
                return
            }
            budgetRemaining -= 1
            nodesVisited += 1

            let bounds = axBounds(of: node)
            if let bounds, bounds.size.width > 0, bounds.size.height > 0,
               !OpenClickyLinkRectGeometry.intersectsLoose(bounds, dragRect) {
                return
            }

            if isLink(node), let bounds,
               bounds.size.width > 0, bounds.size.height > 0,
               OpenClickyLinkRectGeometry.majorityOverlap(anchor: bounds, dragRect: dragRect) {
                candidatesSeen += 1
                acceptLink(node, bounds: bounds)
            }

            for child in axChildren(of: node) {
                if budgetRemaining <= 0 {
                    budgetExhausted = true
                    return
                }
                walk(child, depth: depth + 1)
            }
        }

        mutating func acceptLink(_ node: AXUIElement, bounds: CGRect) {
            guard var url = axURL(of: node), !url.isEmpty else { return }
            if url.count > OpenClickyLinkRectLimits.maxUrlLen { return }
            guard let parsed = URL(string: url),
                  OpenClickySanitiser.isAllowedScheme(parsed) else { return }
            url = OpenClickySanitiser.redactCredentials(parsed)
            if url.isEmpty || url.count > OpenClickyLinkRectLimits.maxUrlLen { return }

            var title = axTitle(of: node)
            if title == nil { title = axDescription(of: node) }
            if title == nil { title = axValueText(of: node) }
            if let t = title, t.count > OpenClickyLinkRectLimits.maxTitleLen {
                title = String(t.prefix(OpenClickyLinkRectLimits.maxTitleLen))
            }
            let effectiveTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasTitle = !(effectiveTitle?.isEmpty ?? true)

            let smallW = bounds.size.width <= 32
            let smallH = bounds.size.height <= 32
            if !hasTitle && smallW && smallH { return }

            OpenClickyLinkRectHarvester.addOrUpgrade(
                byUrl: &byUrl,
                byUrlBounds: &byUrlBounds,
                insertionOrder: &insertionOrder,
                url: url,
                title: effectiveTitle,
                bounds: bounds
            )
        }

        func finalise() -> OpenClickyLinkRectHarvestResult {
            var picks: [OpenClickyPickedLink] = []
            var bounds: [CGRect] = []
            picks.reserveCapacity(min(byUrl.count, OpenClickyLinkRectLimits.maxLinks))
            bounds.reserveCapacity(min(byUrl.count, OpenClickyLinkRectLimits.maxLinks))
            for key in insertionOrder {
                guard let link = byUrl[key] else { continue }
                picks.append(link)
                bounds.append(byUrlBounds[key] ?? .zero)
                if picks.count >= OpenClickyLinkRectLimits.maxLinks { break }
            }
            return OpenClickyLinkRectHarvestResult(
                picks: picks,
                pickBounds: bounds,
                candidatesSeen: candidatesSeen,
                nodesVisited: nodesVisited,
                budgetExhausted: budgetExhausted
            )
        }
    }

    // MARK: - Test-visible primitives

    static func addOrUpgrade(
        byUrl: inout [String: OpenClickyPickedLink],
        byUrlBounds: inout [String: CGRect],
        insertionOrder: inout [String],
        url: String,
        title: String?,
        bounds: CGRect
    ) {
        let key = url.lowercased()
        if let existingBounds = byUrlBounds[key], let existing = byUrl[key] {
            let existingScore = OpenClickyLinkRectGeometry.upgradeScore(
                title: existing.title, bounds: existingBounds)
            let newScore = OpenClickyLinkRectGeometry.upgradeScore(
                title: title, bounds: bounds)
            if newScore > existingScore {
                byUrl[key] = OpenClickyPickedLink(url: url, title: title)
                byUrlBounds[key] = bounds
            }
        } else {
            byUrl[key] = OpenClickyPickedLink(url: url, title: title)
            byUrlBounds[key] = bounds
            insertionOrder.append(key)
        }
    }

    // MARK: - AX plumbing

    private static func isLink(_ node: AXUIElement) -> Bool {
        guard let role = copyString(node, kAXRoleAttribute) else { return false }
        // AX exposes the hyperlink role as "AXLink". macOS SDK does
        // not export a `kAXLinkRole` constant (only navigation /
        // web-area roles have named constants in the framework), so
        // we match the literal — same string Everywhere's
        // `AXRoleAttribute.Hyperlink` produces.
        return role == "AXLink"
    }

    private static func axURL(of node: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &raw)
        guard status == .success, let raw else { return nil }
        if CFGetTypeID(raw) == CFURLGetTypeID() {
            return (raw as! CFURL as URL).absoluteString
        }
        if CFGetTypeID(raw) == CFStringGetTypeID() {
            return raw as? String
        }
        return nil
    }

    private static func axTitle(of node: AXUIElement) -> String? {
        copyString(node, kAXTitleAttribute)
    }

    private static func axDescription(of node: AXUIElement) -> String? {
        copyString(node, kAXDescriptionAttribute)
    }

    private static func axValueText(of node: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &raw)
        guard status == .success, let raw else { return nil }
        if CFGetTypeID(raw) == CFStringGetTypeID() {
            return raw as? String
        }
        return nil
    }

    private static func copyString(_ node: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attr as CFString, &raw)
        guard status == .success, let raw else { return nil }
        if CFGetTypeID(raw) == CFStringGetTypeID() {
            return raw as? String
        }
        return nil
    }

    private static func axChildren(of node: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            node, kAXChildrenAttribute as CFString, &raw)
        guard status == .success, let raw else { return [] }
        if CFGetTypeID(raw) == CFArrayGetTypeID() {
            return (raw as! [AnyObject]).compactMap { element -> AXUIElement? in
                if CFGetTypeID(element) == AXUIElementGetTypeID() {
                    return (element as! AXUIElement)
                }
                return nil
            }
        }
        return []
    }

    private static func axBounds(of node: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                node, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(
                node, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        // FIX(stability-2026-08-01 crash-audit #2): Electron / Chromium
        // AX providers can return CFNumber/CFString for pos/size on
        // rare edge cases. Force-cast crashed the entire app. Guard
        // with AXValue TypeID before casting; skip node on mismatch.
        guard CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetValue(posValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Pid enumeration

    /// Ported from `CollectAllOnScreenPids` (LinkRect.cs:566-590).
    /// Only enumerates apps whose visible windows intersect the drag
    /// rect. Missing / unparseable bounds fall through (include pid).
    private static func onScreenPidsIntersecting(_ dragRect: CGRect) -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var seen = Set<pid_t>()
        var ordered: [pid_t] = []
        for dict in windowInfoList {
            guard let ownerInt = dict[kCGWindowOwnerPID as String] as? Int,
                  let owner = pid_t(exactly: ownerInt) else { continue }
            if let bounds = dict[kCGWindowBounds as String] as? [String: Double] {
                let x = bounds["X"] ?? 0
                let y = bounds["Y"] ?? 0
                let w = bounds["Width"] ?? 0
                let h = bounds["Height"] ?? 0
                let winRect = CGRect(x: x, y: y, width: w, height: h)
                if w > 0, h > 0,
                   !OpenClickyLinkRectGeometry.intersectsLoose(winRect, dragRect) {
                    continue
                }
            }
            if seen.insert(owner).inserted {
                ordered.append(owner)
            }
        }
        return ordered
    }
}
