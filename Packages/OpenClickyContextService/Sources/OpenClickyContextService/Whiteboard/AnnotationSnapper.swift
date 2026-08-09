// Ported from Everywhere: src/Everywhere.Mcp/Whiteboard/AnnotationSnapper.cs
// pin @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// 1:1 Swift port of the whiteboard AX-leaf snapper. Byte-parity checkpoints
// preserved from the C# source:
//
//   * LeafTextRoles = { Label, Hyperlink } (`:20-24`).
//   * LeafTextOrImageRoles = { Label, Hyperlink, Image } (`:32-37`).
//   * Per-call visit cap of 5 000 in every hot loop (`:454`, `:481`, `:502`,
//     `:566`, `:600`, `:405`).
//   * Rect prune slack = 8 default, 2 for LeafAtPoint, 0 for NearestLeaf.
//   * Underline query rect: strokeWidth × (80 + 30) with 15 px jitter
//     (`:394-396`, `:410-419`).
//   * Underline x-ratio: 0.5 vs stroke OR (shortLeaf && ≥0.5 vs leaf)
//     (`:428-432`).
//   * Circle sanity gate: leafArea > 4 × annArea AND leaves.Count > 8
//     (`:535`).
//   * Arrow max distance: 100 px (`:198`, `:207`).
//   * NearestLeaf query box: 240 × 240 (`:595`).
//   * TightenLeafToTip row height 32 px, 50 px "small leaf" threshold (`:254`).
//
// Coord contract: everything is Quartz global (top-left), same space as
// `AXPosition`/`AXSize`. See `whiteboard-annotation-snapper-port-plan.md §5`.

import CoreGraphics
import Foundation

public enum AnnotationSnapper {

    private static let leafTextRoles: Set<VisualElementType> = [.label, .hyperlink]
    private static let leafTextOrImageRoles: Set<VisualElementType> = [.label, .hyperlink, .image]

    // Cross-call diagnostic counter — read/reset by Snap after each
    // LeafAtPoint / NearestLeaf so the snap diag surfaces walk size.
    // Everywhere uses `[ThreadStatic] private static int s_lastWalkVisited`
    // (`AnnotationSnapper.cs:585`). We wrap in a class instance passed
    // through the call so Swift concurrency stays clean — but this file
    // is never touched by more than one caller at a time (snap runs on
    // the whiteboard-processing serial queue), so a simple class matches
    // the [ThreadStatic] semantics.
    final class WalkCounter {
        var lastWalkVisited: Int = 0
    }

    /// Entry point. 1:1 with `AnnotationSnapper.Snap` (`:39-53`).
    public static func snap(
        annotation: Annotation,
        root: AXVisualElement,
        strokes: [Stroke],
        prewarmed: PrewarmedTree? = nil
    ) -> SnapResult {
        let ctx = WalkCounter()
        switch annotation.kind {
        case .arrow:
            return snapArrow(annotation, root: root, strokes: strokes, prewarmed: prewarmed, ctx: ctx)
        case .underline:
            return snapUnderline(annotation, root: root, strokes: strokes, prewarmed: prewarmed, ctx: ctx)
        case .circle, .x:
            return snapCircleOrX(annotation, root: root, prewarmed: prewarmed, ctx: ctx)
        case .unknown:
            return reject(annotation.boundingRect, "unknown gesture kind")
        }
    }

    // MARK: - Walk source (prewarm-first)
    //
    // 1:1 with `Walk` (`:56-61`): when a PrewarmedTree is available,
    // scan its flat list; otherwise do a live rect-pruned descent.

    private static func walk(
        root: AXVisualElement,
        query: CGRect,
        prewarmed: PrewarmedTree?,
        slack: CGFloat = 8.0
    ) -> [(node: AXVisualElement, bbox: CGRect)] {
        if let p = prewarmed { return p.queryRect(query, slack: slack) }
        return descendantsInRect(root: root, query: query, slack: slack)
    }

    // MARK: - Arrow (`:67-213`)

    private static func snapArrow(
        _ ann: Annotation,
        root: AXVisualElement,
        strokes: [Stroke],
        prewarmed: PrewarmedTree?,
        ctx: WalkCounter
    ) -> SnapResult {
        var diag = "arrow: "
        let endpoints = strokeEndpoints(strokes)
        if endpoints.isEmpty {
            return reject(ann.boundingRect, "no usable stroke points")
        }
        diag += "endpoints=[\(endpoints.map { f($0.0, $0.1) }.joined(separator: ","))] "

        // Identify actual tip via head-V midpoint (`:87`, `:223-241`).
        let tipHint = identifyArrowTip(strokes)
        if let tip = tipHint {
            diag += "tipHint=\(f(tip.0, tip.1)) "
            var tipLeaf = leafAtPoint(root: root, x: tip.0, y: tip.1, prewarmed: prewarmed, ctx: ctx)
            if tipLeaf == nil && prewarmed != nil {
                // Prewarm-miss fallback (`:98-99`).
                tipLeaf = leafAtPoint(root: root, x: tip.0, y: tip.1, prewarmed: nil, ctx: ctx)
            }
            if let leaf = tipLeaf {
                diag += "tipLeaf=\"\(trunc(leaf.getText()))\" "
                return SnapResult(
                    rect: tightenLeafToTip(leaf, tipX: tip.0, tipY: tip.1),
                    leaves: [leaf],
                    confidence: 1.0,
                    diagnostics: diag
                )
            }
            // No leaf at tip — NearestLeaf at tip first (`:112-124`).
            var tipNear = nearestLeaf(root: root, x: tip.0, y: tip.1, prewarmed: prewarmed, ctx: ctx)
            if tipNear.leaf == nil && prewarmed != nil {
                tipNear = nearestLeaf(root: root, x: tip.0, y: tip.1, prewarmed: nil, ctx: ctx)
            }
            if let near = tipNear.leaf, tipNear.dist <= 100 {
                diag += "tipNear=\"\(trunc(near.getText()))\" d=\(Int(tipNear.dist)) "
                let conf = max(0.4, 1.0 - tipNear.dist / 100)
                return SnapResult(
                    rect: tightenLeafToTip(near, tipX: tip.0, tipY: tip.1),
                    leaves: [near],
                    confidence: conf,
                    diagnostics: diag
                )
            }
        }

        // Fall-through: evaluate all endpoints (`:128-187`). Prefer in-leaf,
        // smallest area; tie-break in-leaf-vs-near via `foundInLeaf`.
        var bestLeaf: AXVisualElement? = nil
        var bestDist = Double.infinity
        var bestArea = Double.infinity
        var foundInLeaf = false
        var tipX = endpoints[0].0
        var tipY = endpoints[0].1

        for (ex, ey) in endpoints {
            var inLeaf = leafAtPoint(root: root, x: ex, y: ey, prewarmed: prewarmed, ctx: ctx)
            var inWalk = ctx.lastWalkVisited
            if inLeaf == nil && prewarmed != nil {
                inLeaf = leafAtPoint(root: root, x: ex, y: ey, prewarmed: nil, ctx: ctx)
                if inLeaf != nil { inWalk = ctx.lastWalkVisited }
            }
            if let leaf = inLeaf {
                let bb = leaf.boundingRect
                let area = rectArea(bb)
                diag += "in@\(f(ex, ey))[w=\(inWalk)]->\"\(trunc(leaf.getText()))\" "
                if !foundInLeaf || area < bestArea {
                    foundInLeaf = true
                    bestDist = 0
                    bestArea = area
                    bestLeaf = leaf
                    tipX = ex
                    tipY = ey
                }
                continue
            }
            diag += "miss@\(f(ex, ey))[w=\(inWalk)] "
            if foundInLeaf { continue }
            var nr = nearestLeaf(root: root, x: ex, y: ey, prewarmed: prewarmed, ctx: ctx)
            var nearWalk = ctx.lastWalkVisited
            // Prewarm-miss fallback for NearestLeaf, ONLY when prewarm
            // returned nothing at all (`:171-178` explains why we don't
            // fall back on "empty text leaf").
            if nr.leaf == nil && prewarmed != nil {
                let live = nearestLeaf(root: root, x: ex, y: ey, prewarmed: nil, ctx: ctx)
                if live.leaf != nil {
                    nr = live
                    nearWalk = ctx.lastWalkVisited
                }
            }
            if let near = nr.leaf {
                diag += "near@\(f(ex, ey))[w=\(nearWalk)]->\"\(trunc(near.getText()))\" d=\(Int(nr.dist)) "
                if nr.dist < bestDist {
                    bestDist = nr.dist
                    bestLeaf = near
                    tipX = ex
                    tipY = ey
                }
            }
        }

        guard let leaf = bestLeaf else {
            let (cx, cy) = endpoints[0]
            return SnapResult(
                rect: CGRect(x: cx - 30, y: cy - 30, width: 60, height: 60),
                leaves: [],
                rejected: true,
                rejectReason: "no text leaf on this screen",
                diagnostics: diag
            )
        }
        if bestDist > 100 {
            return SnapResult(
                rect: tightenLeafToTip(leaf, tipX: tipX, tipY: tipY),
                leaves: [],
                rejected: true,
                rejectReason: "arrow tip is \(Int(bestDist))px from the nearest text — please point closer",
                diagnostics: diag
            )
        }
        let conf = bestDist == 0 ? 1.0 : max(0.4, 1.0 - bestDist / 100)
        return SnapResult(
            rect: tightenLeafToTip(leaf, tipX: tipX, tipY: tipY),
            leaves: [leaf],
            confidence: conf,
            diagnostics: diag
        )
    }

    /// 1:1 with `IdentifyArrowTip` (`:223-241`).
    private static func identifyArrowTip(_ strokes: [Stroke]) -> (Double, Double)? {
        guard strokes.count == 2 else { return nil }
        let p1 = strokes[0].points
        let p2 = strokes[1].points
        if p1.count < 2 || p2.count < 2 { return nil }
        let len1 = (Double(p1.last!.x - p1[0].x)).squared() + (Double(p1.last!.y - p1[0].y)).squared()
        let len2 = (Double(p2.last!.x - p2[0].x)).squared() + (Double(p2.last!.y - p2[0].y)).squared()
        let axis = len1 >= len2 ? p1 : p2
        let head = len1 >= len2 ? p2 : p1
        let headMidX = Double(head[0].x + head.last!.x) * 0.5
        let headMidY = Double(head[0].y + head.last!.y) * 0.5
        let d0 = (Double(axis[0].x) - headMidX).squared() + (Double(axis[0].y) - headMidY).squared()
        let d1 = (Double(axis.last!.x) - headMidX).squared() + (Double(axis.last!.y) - headMidY).squared()
        return d0 <= d1
            ? (Double(axis[0].x), Double(axis[0].y))
            : (Double(axis.last!.x), Double(axis.last!.y))
    }

    /// 1:1 with `TightenLeafToTip` (`:250-260`).
    private static func tightenLeafToTip(_ leaf: AXVisualElement, tipX: Double, tipY: Double) -> CGRect {
        let bb = leaf.boundingRect
        if bb.height <= 50 { return bb }
        let rowH: Double = 32
        let top = max(Double(bb.origin.y), tipY - rowH / 2)
        let bottom = min(Double(bb.maxY), tipY + rowH / 2)
        if bottom <= top { return bb }
        return CGRect(x: bb.origin.x, y: top, width: bb.width, height: bottom - top)
    }

    /// 1:1 with `StrokeEndpoints` (`:262-274`).
    private static func strokeEndpoints(_ strokes: [Stroke]) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(strokes.count * 2)
        for s in strokes {
            guard let first = s.points.first, let last = s.points.last else { continue }
            pts.append((Double(first.x), Double(first.y)))
            pts.append((Double(last.x), Double(last.y)))
        }
        return pts
    }

    // MARK: - Underline (`:280-380`)

    private static func snapUnderline(
        _ ann: Annotation,
        root: AXVisualElement,
        strokes: [Stroke],
        prewarmed: PrewarmedTree?,
        ctx: WalkCounter
    ) -> SnapResult {
        var strokeTop = Double.infinity
        var strokeBottom = -Double.infinity
        var strokeX1 = Double.infinity
        var strokeX2 = -Double.infinity
        for s in strokes {
            for p in s.points {
                let py = Double(p.y)
                let px = Double(p.x)
                if py < strokeTop { strokeTop = py }
                if py > strokeBottom { strokeBottom = py }
                if px < strokeX1 { strokeX1 = px }
                if px > strokeX2 { strokeX2 = px }
            }
        }
        if strokeTop == Double.infinity {
            return reject(ann.boundingRect, "empty stroke")
        }
        var diag = "underline: "
        diag += "strokeTop=\(Int(strokeTop)) strokeBottom=\(Int(strokeBottom)) "
        diag += "strokeX=[\(Int(strokeX1)),\(Int(strokeX2))] "

        let strokeWidth = max(strokeX2 - strokeX1, 1)
        var (above, aboveDiag) = collectUnderlineCandidatesV(
            root: root,
            strokeY: strokeTop, strokeX1: strokeX1, strokeX2: strokeX2,
            strokeWidth: strokeWidth, above: true, prewarmed: prewarmed
        )
        diag += "above=\(aboveDiag) "
        if above.isEmpty, prewarmed != nil {
            let (liveAbove, liveDiag) = collectUnderlineCandidatesV(
                root: root,
                strokeY: strokeTop, strokeX1: strokeX1, strokeX2: strokeX2,
                strokeWidth: strokeWidth, above: true, prewarmed: nil
            )
            diag += "aboveLive=\(liveDiag) "
            above = liveAbove
        }
        var candidates = above
        var pickedSide: UnderlineSide = .above
        if candidates.isEmpty {
            var (below, belowDiag) = collectUnderlineCandidatesV(
                root: root,
                strokeY: strokeBottom, strokeX1: strokeX1, strokeX2: strokeX2,
                strokeWidth: strokeWidth, above: false, prewarmed: prewarmed
            )
            diag += "below=\(belowDiag)"
            if below.isEmpty, prewarmed != nil {
                let (liveBelow, liveBelowDiag) = collectUnderlineCandidatesV(
                    root: root,
                    strokeY: strokeBottom, strokeX1: strokeX1, strokeX2: strokeX2,
                    strokeWidth: strokeWidth, above: false, prewarmed: nil
                )
                diag += " belowLive=\(liveBelowDiag)"
                below = liveBelow
            }
            candidates = below
            pickedSide = .below
        }
        if candidates.isEmpty {
            return SnapResult(
                rect: ann.boundingRect,
                leaves: [],
                rejected: true,
                rejectReason: "no text line near the underline — draw the line directly above or below a line of text",
                diagnostics: diag
            )
        }
        // Sort by closest gap, tie-break by x-overlap (`:348-367`).
        let anchor = pickedSide == .above ? strokeTop : strokeBottom
        var bands: [(leaf: AXVisualElement, edgeY: Double)] = candidates.map { c in
            let bb = c.boundingRect
            let edgeY = pickedSide == .above ? Double(bb.maxY) : Double(bb.origin.y)
            return (c, edgeY)
        }
        bands.sort { a, b in
            let gapA = abs(anchor - a.edgeY)
            let gapB = abs(anchor - b.edgeY)
            if gapA != gapB { return gapA < gapB }
            let bbA = a.leaf.boundingRect
            let bbB = b.leaf.boundingRect
            let oxA = min(Double(bbA.maxX), strokeX2) - max(Double(bbA.origin.x), strokeX1)
            let oxB = min(Double(bbB.maxX), strokeX2) - max(Double(bbB.origin.x), strokeX1)
            return oxB < oxA
        }
        let topY = bands[0].edgeY
        let chosen = bands.filter { abs($0.edgeY - topY) < 8 }.map { $0.leaf }
        let gapTop = abs(anchor - topY)
        let conf = max(0.4, 1.0 - gapTop / 60)
        return SnapResult(
            rect: adjustRectToLeaves(ann.boundingRect, leaves: chosen),
            leaves: chosen,
            confidence: conf,
            diagnostics: diag
        )
    }

    private enum UnderlineSide { case above, below }

    /// 1:1 with `CollectUnderlineCandidatesV` (`:384-439`).
    private static func collectUnderlineCandidatesV(
        root: AXVisualElement,
        strokeY: Double, strokeX1: Double, strokeX2: Double,
        strokeWidth: Double,
        above: Bool,
        prewarmed: PrewarmedTree?
    ) -> ([AXVisualElement], String) {
        var list: [AXVisualElement] = []
        var seen = 0
        var failedSide = 0
        var failedGap = 0
        var failedXBand = 0
        var failedXRatio = 0
        var totalWalked = 0
        // Query rect: strokeWidth × ~110, offset by ±80 with 15 px jitter
        // (`:394-396`).
        let queryRect = above
            ? CGRect(x: strokeX1, y: strokeY - 80 - 15, width: strokeWidth, height: 80 + 30)
            : CGRect(x: strokeX1, y: strokeY - 15, width: strokeWidth, height: 80 + 30)
        for (e, bb) in walk(root: root, query: queryRect, prewarmed: prewarmed) {
            totalWalked += 1
            // 5 000 hard cap (`:405`) — Chromium can deliver 76k+ Labels.
            if totalWalked > 5000 { break }
            if !leafTextRoles.contains(e.type) { continue }
            seen += 1
            let bbY = Double(bb.origin.y)
            let bbBottom = Double(bb.maxY)
            if above {
                if bbBottom > strokeY + 15 { failedSide += 1; continue }
                if strokeY - bbBottom > 80 { failedGap += 1; continue }
            } else {
                if bbY < strokeY - 15 { failedSide += 1; continue }
                if bbY - strokeY > 80 { failedGap += 1; continue }
            }
            let xInter = min(Double(bb.maxX), strokeX2) - max(Double(bb.origin.x), strokeX1)
            if xInter <= 0 { failedXBand += 1; continue }
            let ratioVsStroke = xInter / strokeWidth
            let leafW = max(1, Double(bb.width))
            let ratioVsLeaf = xInter / leafW
            let shortLeaf = Double(bb.width) < strokeWidth * 0.5
            if ratioVsStroke < 0.5 && !(shortLeaf && ratioVsLeaf >= 0.5) {
                failedXRatio += 1
                continue
            }
            list.append(e)
        }
        let diag = "[seen=\(seen) kept=\(list.count) failedSide=\(failedSide) failedGap=\(failedGap) failedXBand=\(failedXBand) failedXRatio=\(failedXRatio)]"
        return (list, diag)
    }

    // MARK: - Circle / X (`:445-547`)

    private static func snapCircleOrX(
        _ ann: Annotation,
        root: AXVisualElement,
        prewarmed: PrewarmedTree?,
        ctx: WalkCounter
    ) -> SnapResult {
        var diag = "circle/x: rect=\(f(ann.boundingRect)) "
        var leaves: [AXVisualElement] = []
        var totalLeaves = 0
        var walked = 0

        // Pass 1: strict containment (`:452-470`).
        for (e, bb) in walk(root: root, query: ann.boundingRect, prewarmed: prewarmed) {
            walked += 1
            if walked > 5000 { break }
            if !leafTextOrImageRoles.contains(e.type) { continue }
            totalLeaves += 1
            let a = ann.boundingRect
            if Double(bb.origin.y) >= Double(a.origin.y)
                && Double(bb.maxY) <= Double(a.maxY)
                && Double(bb.origin.x) >= Double(a.origin.x) - 4
                && Double(bb.maxX) <= Double(a.maxX) + 4 {
                leaves.append(e)
            }
        }
        diag += "totalLeaves=\(totalLeaves) pass1Strict=\(leaves.count) "

        // Pass 2: ≥50% vertical overlap + any x-overlap (`:478-494`).
        if leaves.isEmpty {
            var w2 = 0
            for (e, bb) in walk(root: root, query: ann.boundingRect, prewarmed: prewarmed) {
                w2 += 1
                if w2 > 5000 { break }
                if !leafTextOrImageRoles.contains(e.type) { continue }
                let a = ann.boundingRect
                let inter = min(Double(bb.maxY), Double(a.maxY)) - max(Double(bb.origin.y), Double(a.origin.y))
                if inter <= 0 || bb.height <= 0 { continue }
                if inter / Double(bb.height) < 0.5 { continue }
                let xInter = min(Double(bb.maxX), Double(a.maxX)) - max(Double(bb.origin.x), Double(a.origin.x))
                if xInter <= 0 { continue }
                leaves.append(e)
            }
            diag += "pass2VOverlap=\(leaves.count) "
        }

        // Pass 3: 50% total-area overlap ratio (`:498-507`).
        if leaves.isEmpty {
            var w3 = 0
            for (e, bb) in walk(root: root, query: ann.boundingRect, prewarmed: prewarmed) {
                w3 += 1
                if w3 > 5000 { break }
                if !leafTextOrImageRoles.contains(e.type) { continue }
                if overlapRatio(of: bb, against: ann.boundingRect) >= 0.5 {
                    leaves.append(e)
                }
            }
            diag += "pass3Area=\(leaves.count) "
        }

        // Fallback: NearestLeaf within 120 px (`:509-524`).
        if leaves.isEmpty {
            let cx = Double(ann.boundingRect.midX)
            let cy = Double(ann.boundingRect.midY)
            let nr = nearestLeaf(root: root, x: cx, y: cy, prewarmed: nil, ctx: ctx)
            diag += "nearest=\"\(trunc(nr.leaf?.getText() ?? ""))\" d=\(Int(nr.dist)) "
            guard let near = nr.leaf, nr.dist <= 120 else {
                return SnapResult(
                    rect: ann.boundingRect,
                    leaves: [],
                    rejected: true,
                    rejectReason: "no text inside the gesture — please redraw closer to the content",
                    diagnostics: diag
                )
            }
            return SnapResult(
                rect: near.boundingRect,
                leaves: [near],
                confidence: max(0.3, 1.0 - nr.dist / 120),
                diagnostics: diag
            )
        }

        // Sanity: exclude Image leaves from area cap so an intentional
        // circle-around-a-row-of-thumbnails doesn't trip (`:526-541`).
        let annArea = rectArea(ann.boundingRect)
        let leafArea = leaves
            .filter { $0.type != .image }
            .reduce(0.0) { $0 + rectArea($1.boundingRect) }
        if leafArea > annArea * 4 && leaves.count > 8 {
            return SnapResult(
                rect: ann.boundingRect,
                leaves: [],
                rejected: true,
                rejectReason: "gesture is too small for \(leaves.count) text elements — please redraw",
                diagnostics: diag
            )
        }
        return SnapResult(
            rect: adjustRectToLeaves(ann.boundingRect, leaves: leaves),
            leaves: leaves,
            diagnostics: diag
        )
    }

    // MARK: - Helpers

    private static func reject(_ rect: CGRect, _ reason: String) -> SnapResult {
        return SnapResult(rect: rect, leaves: [], rejected: true, rejectReason: reason)
    }

    /// 1:1 with `LeafAtPoint` (`:556-581`).
    private static func leafAtPoint(
        root: AXVisualElement,
        x: Double, y: Double,
        prewarmed: PrewarmedTree?,
        ctx: WalkCounter
    ) -> AXVisualElement? {
        let pointRect = CGRect(x: x, y: y, width: 1, height: 1)
        var visited = 0
        var hit: AXVisualElement? = nil
        for (e, bb) in walk(root: root, query: pointRect, prewarmed: prewarmed, slack: 2.0) {
            visited += 1
            if visited > 5000 { break }
            if !leafTextRoles.contains(e.type) { continue }
            let dx0 = Double(bb.origin.x)
            let dx1 = Double(bb.maxX)
            let dy0 = Double(bb.origin.y)
            let dy1 = Double(bb.maxY)
            if x < dx0 || x > dx1 || y < dy0 || y > dy1 { continue }
            // First (shallowest) leaf-role node containing the point wins —
            // matches the reasoning at `:570-577`.
            hit = e
            break
        }
        ctx.lastWalkVisited = visited
        return hit
    }

    /// 1:1 with `NearestLeaf` (`:587-609`).
    private static func nearestLeaf(
        root: AXVisualElement,
        x: Double, y: Double,
        prewarmed: PrewarmedTree?,
        ctx: WalkCounter
    ) -> (leaf: AXVisualElement?, dist: Double) {
        var best: AXVisualElement? = nil
        var bestD = Double.infinity
        // 240×240 bounding box around the point (`:595`).
        let pointRect = CGRect(x: x - 120, y: y - 120, width: 240, height: 240)
        var visited = 0
        for (e, bb) in walk(root: root, query: pointRect, prewarmed: prewarmed, slack: 0.0) {
            visited += 1
            if visited > 5000 { break }
            if !leafTextRoles.contains(e.type) { continue }
            let dx = max(max(Double(bb.origin.x) - x, 0), x - Double(bb.maxX))
            let dy = max(max(Double(bb.origin.y) - y, 0), y - Double(bb.maxY))
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestD {
                bestD = d
                best = e
            }
        }
        ctx.lastWalkVisited = visited
        return (best, bestD)
    }

    /// 1:1 with `AdjustRectToLeaves` (`:611-626`). Pad = 4.
    private static func adjustRectToLeaves(_ rect: CGRect, leaves: [AXVisualElement], pad: CGFloat = 4.0) -> CGRect {
        if leaves.isEmpty { return rect }
        var x1 = Double.infinity
        var y1 = Double.infinity
        var x2 = -Double.infinity
        var y2 = -Double.infinity
        for lf in leaves {
            let bb = lf.boundingRect
            if Double(bb.origin.x) < x1 { x1 = Double(bb.origin.x) }
            if Double(bb.origin.y) < y1 { y1 = Double(bb.origin.y) }
            if Double(bb.maxX) > x2 { x2 = Double(bb.maxX) }
            if Double(bb.maxY) > y2 { y2 = Double(bb.maxY) }
        }
        return CGRect(
            x: x1 - Double(pad),
            y: y1 - Double(pad),
            width: x2 - x1 + 2 * Double(pad),
            height: y2 - y1 + 2 * Double(pad)
        )
    }

    private static func overlapRatio(of a: CGRect, against b: CGRect) -> Double {
        let inter = a.intersection(b)
        let area = rectArea(a)
        if inter.isNull { return 0 }
        return area > 0 ? rectArea(inter) / area : 0.0
    }

    private static func rectArea(_ r: CGRect) -> Double {
        return Double(max(0, r.width)) * Double(max(0, r.height))
    }

    // MARK: - Live rect-pruned descent (`:820-868`)
    //
    // Fallback path when no PrewarmedTree is supplied. Skip subtrees whose
    // own bbox has non-zero size and doesn't intersect the query expanded
    // by `slack`. Empty-bbox nodes still recurse. Leaf-role nodes yield
    // themselves and DO NOT recurse into their children.

    static func descendantsInRect(
        root: AXVisualElement,
        query: CGRect,
        slack: CGFloat = 8.0
    ) -> [(node: AXVisualElement, bbox: CGRect)] {
        let expanded = CGRect(
            x: query.origin.x - slack,
            y: query.origin.y - slack,
            width: query.width + 2 * slack,
            height: query.height + 2 * slack
        )
        var out: [(AXVisualElement, CGRect)] = []
        Self.descendantsInRectImpl(node: root, nodeBb: root.boundingRect, expanded: expanded, sink: &out)
        return out
    }

    private static func descendantsInRectImpl(
        node: AXVisualElement,
        nodeBb: CGRect,
        expanded: CGRect,
        sink: inout [(AXVisualElement, CGRect)]
    ) {
        sink.append((node, nodeBb))
        // Leaf-role nodes: yield but don't recurse (`:844-846`).
        if leafTextOrImageRoles.contains(node.type) { return }
        for child in node.children() {
            let cBb = child.boundingRect
            if cBb.width > 0 && cBb.height > 0 {
                let inter = cBb.intersection(expanded)
                if inter.isNull || inter.width <= 0 || inter.height <= 0 { continue }
            }
            descendantsInRectImpl(node: child, nodeBb: cBb, expanded: expanded, sink: &sink)
        }
    }

    // MARK: - Formatters (diag)

    private static func f(_ r: CGRect) -> String {
        return "(\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width))x\(Int(r.height)))"
    }

    private static func f(_ x: Double, _ y: Double) -> String {
        return "(\(Int(x)),\(Int(y)))"
    }

    private static func trunc(_ s: String, _ n: Int = 30) -> String {
        if s.isEmpty { return "" }
        let t = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}

// MARK: - Small math sugar

private extension Double {
    func squared() -> Double { return self * self }
}
