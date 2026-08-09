// OpenClickyWhiteboardStrokeClassifier.swift
// cursor-buddy
//
// Pure geometric gesture classifier for Phase 7.1 Whiteboard overlay.
// Ported from Everywhere: src/Everywhere.Mcp/Whiteboard/WhiteboardParser.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Thresholds match Everywhere byte-for-byte so the two ports produce the
// same classification on identical fixtures:
//
//   * min extent: max(width, height) < 5.0  -> Unknown
//   * closure = |start-end| / pathLength  < 0.2 && straight < 0.5 -> Circle
//   * straight < 0.3 -> Circle
//   * straight > 0.75 -> Underline
//   * else -> Arrow
//   * two-stroke gestures: axis + head (Arrow) or crossing chords (X)
//
// This file has no AppKit / UIKit dependencies so it stays trivial to
// unit-test.

import CoreGraphics
import Foundation

/// One recognised gesture. String rawValue matches the wire format the
/// `WhiteboardStash` stores (`WhiteboardRegion.gestureKind`).
enum OpenClickyWhiteboardGestureKind: String, Equatable, Sendable {
    case circle
    case underline
    case arrow
    case x
    case unknown
}

/// One stroke = an ordered polyline of `CGPoint`. Coordinates are in
/// Quartz global screen space (top-left origin) at the point they are
/// handed to the classifier, but the classifier itself is coordinate-
/// system-agnostic — all its computations are relative.
struct OpenClickyWhiteboardStroke: Equatable {
    var points: [CGPoint]

    init(points: [CGPoint]) {
        self.points = points
    }
}

/// Output of `OpenClickyWhiteboardStrokeClassifier.classify`:
/// each recognised gesture with its bounding box (Quartz global rect)
/// and the strokes that backed it (in case the caller needs to re-render).
struct OpenClickyWhiteboardClassifiedGesture: Equatable {
    let kind: OpenClickyWhiteboardGestureKind
    let boundingBox: CGRect
    let strokes: [OpenClickyWhiteboardStroke]
}

enum OpenClickyWhiteboardStrokeClassifier {

    // MARK: - Public entry

    /// Group strokes and classify each group. Mirrors
    /// `WhiteboardParser.ParseGrouped` (`WhiteboardParser.cs:39-55`).
    static func classify(strokes: [OpenClickyWhiteboardStroke])
        -> [OpenClickyWhiteboardClassifiedGesture]
    {
        let filtered = strokes.filter { !$0.points.isEmpty }
        guard !filtered.isEmpty else { return [] }

        let groups = groupStrokes(filtered)
        var results: [OpenClickyWhiteboardClassifiedGesture] = []
        results.reserveCapacity(groups.count)
        for group in groups {
            let kind = classifyGroup(group)
            let rect = rectFor(kind: kind, strokes: group)
            results.append(
                OpenClickyWhiteboardClassifiedGesture(
                    kind: kind,
                    boundingBox: rect,
                    strokes: group
                )
            )
        }
        return results
    }

    /// Classify a single stroke — convenience overload used by the unit
    /// tests. Returns `.unknown` if the stroke is empty.
    static func classifySingle(points: [CGPoint])
        -> OpenClickyWhiteboardClassifiedGesture
    {
        let stroke = OpenClickyWhiteboardStroke(points: points)
        guard !points.isEmpty else {
            return OpenClickyWhiteboardClassifiedGesture(
                kind: .unknown,
                boundingBox: .zero,
                strokes: [stroke]
            )
        }
        let kind = classifyGroup([stroke])
        let rect = rectFor(kind: kind, strokes: [stroke])
        return OpenClickyWhiteboardClassifiedGesture(
            kind: kind,
            boundingBox: rect,
            strokes: [stroke]
        )
    }

    // MARK: - Grouping

    /// Default = one stroke per group. Pairs may merge if they look like
    /// an Arrow (axis+head) or an X (crossing chords). Arrow first so
    /// shaft+barb doesn't get swallowed by X's permissive fallback.
    /// Mirrors `WhiteboardParser.cs:73-102`.
    private static func groupStrokes(_ strokes: [OpenClickyWhiteboardStroke])
        -> [[OpenClickyWhiteboardStroke]]
    {
        var groups: [[OpenClickyWhiteboardStroke]] = strokes.map { [$0] }
        var i = 0
        while i < groups.count {
            var merged = false
            var j = i + 1
            while j < groups.count {
                guard groups[i].count == 1, groups[j].count == 1 else {
                    j += 1
                    continue
                }
                let pair = [groups[i][0], groups[j][0]]
                if looksLikeArrow(pair) || looksLikeX(pair) {
                    groups[i].append(groups[j][0])
                    groups.remove(at: j)
                    merged = true
                    break
                }
                j += 1
            }
            if !merged { i += 1 }
        }
        return groups
    }

    // MARK: - Classification

    private static func classifyGroup(_ strokes: [OpenClickyWhiteboardStroke])
        -> OpenClickyWhiteboardGestureKind
    {
        if strokes.count == 2 {
            // Same order as WhiteboardParser.cs:110-119: Arrow, then X.
            if looksLikeArrow(strokes) { return .arrow }
            if looksLikeX(strokes) { return .x }
            return .circle // shouldn't reach here with the group's guard
        }
        guard let s = strokes.first, s.points.count >= 2 else {
            return .unknown
        }
        let bb = strokeBBox(s)
        // Reject truly degenerate — mirrors L128.
        if max(bb.width, bb.height) < 5.0 { return .unknown }

        let straight = straightness(s)
        let dx = s.points[0].x - s.points[s.points.count - 1].x
        let dy = s.points[0].y - s.points[s.points.count - 1].y
        let pathLen = pathLength(s)
        let closure: Double
        if pathLen > 0 {
            closure = sqrt(dx * dx + dy * dy) / pathLen
        } else {
            closure = 1.0
        }

        if closure < 0.2, straight < 0.5 { return .circle }
        if straight < 0.3 { return .circle }
        if straight > 0.75 { return .underline }
        return .arrow
    }

    private static func looksLikeX(_ strokes: [OpenClickyWhiteboardStroke]) -> Bool {
        for i in 0..<strokes.count {
            for j in (i + 1)..<strokes.count {
                let a = strokes[i].points
                let b = strokes[j].points
                if a.count < 2 || b.count < 2 { continue }
                if !segmentsCross(a[0], a[a.count - 1], b[0], b[b.count - 1]) { continue }
                let lenA = hypot(a[a.count - 1].x - a[0].x, a[a.count - 1].y - a[0].y)
                let lenB = hypot(b[b.count - 1].x - b[0].x, b[b.count - 1].y - b[0].y)
                if lenA < 5 || lenB < 5 { continue }
                let ratio = lenA / lenB

                // Midpoint-coincidence branch — catches wide-flat X.
                let midAX = (a[0].x + a[a.count - 1].x) * 0.5
                let midAY = (a[0].y + a[a.count - 1].y) * 0.5
                let midBX = (b[0].x + b[b.count - 1].x) * 0.5
                let midBY = (b[0].y + b[b.count - 1].y) * 0.5
                let midDist = hypot(midAX - midBX, midAY - midBY)
                let avgLen = (lenA + lenB) * 0.5
                if avgLen > 0, midDist / avgLen <= 0.3 { return true }

                // Angle-fallback + strict length parity (L182-184).
                if ratio < 0.4 || ratio > 2.5 { continue }
                let angle = angleBetween(a[0], a[a.count - 1], b[0], b[b.count - 1])
                if angle >= 35 && angle <= 145 { return true }
            }
        }
        return false
    }

    private static func looksLikeArrow(_ strokes: [OpenClickyWhiteboardStroke]) -> Bool {
        if strokes.count < 2 { return false }
        let a = strokes[0].points
        let b = strokes[1].points
        if a.count < 2 || b.count < 2 { return false }
        let lenA = hypot(a[a.count - 1].x - a[0].x, a[a.count - 1].y - a[0].y)
        let lenB = hypot(b[b.count - 1].x - b[0].x, b[b.count - 1].y - b[0].y)
        if lenA < 5 || lenB < 5 { return false }
        let axisLen = max(lenA, lenB)
        let headLen = min(lenA, lenB)
        let axis: [CGPoint] = lenA >= lenB ? a : b
        let head: [CGPoint] = lenA >= lenB ? b : a
        if headLen / axisLen > 0.95 { return false }
        let thr = max(15.0, axisLen * 0.30)
        func nearEither(_ p: CGPoint) -> Bool {
            let d0 = hypot(p.x - axis[0].x, p.y - axis[0].y)
            let d1 = hypot(p.x - axis[axis.count - 1].x, p.y - axis[axis.count - 1].y)
            return d0 < thr || d1 < thr
        }
        return nearEither(head[0]) || nearEither(head[head.count - 1])
    }

    // MARK: - Rect selection

    private static func rectFor(
        kind: OpenClickyWhiteboardGestureKind,
        strokes: [OpenClickyWhiteboardStroke]
    ) -> CGRect {
        let bb = multiStrokeBBox(strokes)
        switch kind {
        case .circle:
            // Everywhere: `bb.Inflate(-2)` (shrink by 2 on each side).
            return bb.insetBy(dx: 2, dy: 2)
        case .underline:
            return underlineRect(strokes, bb: bb)
        case .arrow:
            return arrowRect(strokes)
        case .x, .unknown:
            return bb
        }
    }

    private static func underlineRect(
        _ strokes: [OpenClickyWhiteboardStroke],
        bb: CGRect
    ) -> CGRect {
        var ys: [CGFloat] = []
        for s in strokes {
            for p in s.points { ys.append(p.y) }
        }
        ys.sort()
        guard !ys.isEmpty else { return bb }
        let median = ys[ys.count / 2]
        let lineH: CGFloat = 28.0
        return CGRect(x: bb.origin.x, y: median - lineH, width: bb.width, height: lineH)
    }

    private static func arrowRect(_ strokes: [OpenClickyWhiteboardStroke]) -> CGRect {
        guard let start = strokes.first?.points.first else { return .zero }
        var bestX = start.x
        var bestY = start.y
        var bestD2: CGFloat = -1
        for s in strokes {
            for p in s.points {
                let dx = p.x - start.x
                let dy = p.y - start.y
                let d2 = dx * dx + dy * dy
                if d2 > bestD2 {
                    bestD2 = d2
                    bestX = p.x
                    bestY = p.y
                }
            }
        }
        return CGRect(x: bestX - 100, y: bestY - 50, width: 200, height: 100)
    }

    // MARK: - Geometry helpers

    private static func strokeBBox(_ s: OpenClickyWhiteboardStroke) -> CGRect {
        guard let first = s.points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in s.points.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func multiStrokeBBox(_ strokes: [OpenClickyWhiteboardStroke]) -> CGRect {
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        for s in strokes {
            for p in s.points {
                if p.x < minX { minX = p.x }
                if p.x > maxX { maxX = p.x }
                if p.y < minY { minY = p.y }
                if p.y > maxY { maxY = p.y }
            }
        }
        if minX == .infinity { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func straightness(_ s: OpenClickyWhiteboardStroke) -> CGFloat {
        let len = strokeLength(s)
        if len < 1.0 { return 0.0 }
        let p0 = s.points[0]
        let p1 = s.points[s.points.count - 1]
        let chord = hypot(p0.x - p1.x, p0.y - p1.y)
        return chord / len
    }

    private static func pathLength(_ s: OpenClickyWhiteboardStroke) -> CGFloat {
        strokeLength(s)
    }

    private static func strokeLength(_ s: OpenClickyWhiteboardStroke) -> CGFloat {
        var sum: CGFloat = 0
        for i in 1..<s.points.count {
            sum += hypot(s.points[i].x - s.points[i - 1].x,
                          s.points[i].y - s.points[i - 1].y)
        }
        return sum
    }

    private static func segmentsCross(
        _ p1: CGPoint, _ p2: CGPoint,
        _ p3: CGPoint, _ p4: CGPoint
    ) -> Bool {
        func cross(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) -> CGFloat {
            ax * by - ay * bx
        }
        let d1 = cross(p4.x - p3.x, p4.y - p3.y, p1.x - p3.x, p1.y - p3.y)
        let d2 = cross(p4.x - p3.x, p4.y - p3.y, p2.x - p3.x, p2.y - p3.y)
        let d3 = cross(p2.x - p1.x, p2.y - p1.y, p3.x - p1.x, p3.y - p1.y)
        let d4 = cross(p2.x - p1.x, p2.y - p1.y, p4.x - p1.x, p4.y - p1.y)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private static func angleBetween(
        _ a0: CGPoint, _ a1: CGPoint,
        _ b0: CGPoint, _ b1: CGPoint
    ) -> CGFloat {
        let ax = a1.x - a0.x
        let ay = a1.y - a0.y
        let bx = b1.x - b0.x
        let by = b1.y - b0.y
        let la = hypot(ax, ay)
        let lb = hypot(bx, by)
        if la == 0 || lb == 0 { return 0 }
        var cos = (ax * bx + ay * by) / (la * lb)
        cos = min(max(cos, -1.0), 1.0)
        return acos(cos) * 180.0 / .pi
    }
}

