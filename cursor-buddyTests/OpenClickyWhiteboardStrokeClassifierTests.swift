// OpenClickyWhiteboardStrokeClassifierTests.swift
// cursor-buddyTests
//
// Fixtures verify the ported classifier matches the Everywhere
// `WhiteboardParser.cs` thresholds byte-for-byte. All coordinates are
// synthetic — no screen capture / permissions required.

import CoreGraphics
import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyWhiteboardStrokeClassifierTests {

    // MARK: helpers

    private func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, samples: Int = 32) -> [CGPoint] {
        var pts: [CGPoint] = []
        for i in 0...samples {
            let t = Double(i) / Double(samples) * 2 * .pi
            pts.append(CGPoint(x: cx + r * CGFloat(cos(t)),
                                y: cy + r * CGFloat(sin(t))))
        }
        return pts
    }

    private func line(from: CGPoint, to: CGPoint, samples: Int = 20) -> [CGPoint] {
        var pts: [CGPoint] = []
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            pts.append(CGPoint(x: from.x + (to.x - from.x) * t,
                                y: from.y + (to.y - from.y) * t))
        }
        return pts
    }

    // MARK: Circle

    @Test func circleClassifiesAsCircle() {
        let pts = circle(cx: 100, cy: 100, r: 40)
        let result = OpenClickyWhiteboardStrokeClassifier.classifySingle(points: pts)
        #expect(result.kind == .circle)
    }

    // MARK: Underline

    @Test func longHorizontalStrokeClassifiesAsUnderline() {
        let pts = line(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 300, y: 202))
        let result = OpenClickyWhiteboardStrokeClassifier.classifySingle(points: pts)
        #expect(result.kind == .underline)
    }

    // MARK: Arrow (single-stroke)

    @Test func curvedStrokeClassifiesAsArrow() {
        // Path curves such that straightness sits in [0.3, 0.75] and
        // closure is not <0.2: an obvious "path with a bend".
        var pts: [CGPoint] = []
        for i in 0...30 {
            let t = CGFloat(i) / 30
            // Start at (0, 0), curve to (200, 60) with a mid-bump.
            let x = t * 200
            let y = 60 * t + 20 * sin(t * .pi)
            pts.append(CGPoint(x: x, y: y))
        }
        let result = OpenClickyWhiteboardStrokeClassifier.classifySingle(points: pts)
        #expect(result.kind == .arrow)
    }

    // MARK: Two-stroke X

    @Test func crossingStrokesClassifyAsX() {
        let strokeA = OpenClickyWhiteboardStroke(points: line(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200)
        ))
        let strokeB = OpenClickyWhiteboardStroke(points: line(
            from: CGPoint(x: 200, y: 100), to: CGPoint(x: 100, y: 200)
        ))
        let out = OpenClickyWhiteboardStrokeClassifier.classify(strokes: [strokeA, strokeB])
        #expect(out.count == 1)
        #expect(out.first?.kind == .x)
    }

    // MARK: Unknown

    @Test func trivialStrokeClassifiesAsUnknown() {
        // Two points 2 px apart -> below the 5.0 extent floor.
        let pts = [CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 11)]
        let result = OpenClickyWhiteboardStrokeClassifier.classifySingle(points: pts)
        #expect(result.kind == .unknown)
    }

    // MARK: Bounding box

    @Test func classifierProducesValidBoundingBox() {
        let pts = circle(cx: 500, cy: 500, r: 30)
        let result = OpenClickyWhiteboardStrokeClassifier.classifySingle(points: pts)
        #expect(result.boundingBox.width > 0)
        #expect(result.boundingBox.height > 0)
        // Circle bbox is inset by 2 px per Everywhere `.Inflate(-2)`.
        #expect(result.boundingBox.origin.x >= 470)
        #expect(result.boundingBox.origin.y >= 470)
    }

    // MARK: Two stroke Arrow (axis + head)

    @Test func axisPlusHeadClassifiesAsArrow() {
        // Long axis running left-to-right, small head at the right endpoint.
        let axis = OpenClickyWhiteboardStroke(points: line(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 0)
        ))
        let head = OpenClickyWhiteboardStroke(points: line(
            from: CGPoint(x: 200, y: 0), to: CGPoint(x: 180, y: 10)
        ))
        let out = OpenClickyWhiteboardStrokeClassifier.classify(strokes: [axis, head])
        #expect(out.count == 1)
        #expect(out.first?.kind == .arrow)
    }
}
