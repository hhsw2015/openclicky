// Ported from Everywhere: src/Everywhere.Mcp/Whiteboard/AnnotationSnapper.cs
// pin @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Value-type inputs and outputs for the AnnotationSnapper. Split out of
// AnnotationSnapper.swift so the surface types are trivially importable
// from cursor-buddy without dragging the entire snapper.
//
// - `AnnotationKind`  <- `AnnotationKind` enum (Everywhere Interop, matches
//   `OpenClickyWhiteboardGestureKind` rawValues so we can pivot between them).
// - `Annotation`      <- `Annotation` record: kind + BoundingRect.
// - `Stroke`          <- `Stroke` record: `IReadOnlyList<Point>` polyline.
// - `SnapResult`      <- `SnapResult` record (`SnapResult.cs:11-22`).

import CoreGraphics
import Foundation

/// Mirrors Everywhere's `AnnotationKind` enum. Only the four gestures the
/// snapper actually dispatches on are represented. `unknown` is rejected
/// up front (`AnnotationSnapper.cs:51`).
public enum AnnotationKind: String, Sendable, Equatable {
    case circle
    case underline
    case arrow
    case x
    case unknown
}

/// One recognised gesture with its parser-computed bounding box. Ports
/// Everywhere's `Annotation` record.
public struct Annotation: Sendable, Equatable {
    public let kind: AnnotationKind
    public let boundingRect: CGRect

    public init(kind: AnnotationKind, boundingRect: CGRect) {
        self.kind = kind
        self.boundingRect = boundingRect
    }
}

/// One stroke = ordered polyline in Quartz global points. Matches
/// Everywhere's `Stroke` record shape (`Stroke.Points`).
public struct Stroke: Sendable, Equatable {
    public let points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

/// Snap output for one annotation. Byte-parity with `SnapResult.cs:11-22`:
/// `Rect` (union-of-leaves after `AdjustRectToLeaves` pad), `Leaves`
/// (Label/Hyperlink/Image AX nodes), `Rejected` + `RejectReason`,
/// `Confidence` in [0.3, 1.0], `Diagnostics` trace string.
public struct SnapResult: Sendable {
    public let rect: CGRect
    public let leaves: [AXVisualElement]
    public let rejected: Bool
    public let rejectReason: String
    public let confidence: Double
    public let diagnostics: String

    public init(
        rect: CGRect,
        leaves: [AXVisualElement],
        rejected: Bool = false,
        rejectReason: String = "",
        confidence: Double = 1.0,
        diagnostics: String = ""
    ) {
        self.rect = rect
        self.leaves = leaves
        self.rejected = rejected
        self.rejectReason = rejectReason
        self.confidence = confidence
        self.diagnostics = diagnostics
    }
}
