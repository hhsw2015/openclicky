// Ported from Everywhere: src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs
//   snap-then-OCR merge loop @ :461-700
// pin @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Sits between the whiteboard overlay commit path and the WhiteboardStash
// writer. For each classified gesture it:
//
//   1. Builds an Annotation record from the gesture.
//   2. Snaps against the focused-window AX tree via AnnotationSnapper
//      (`WhiteboardHotkeyInitializer.cs:596-603`).
//   3. Runs OCR on a per-kind cropped bitmap and applies the Underline
//      nearest-line filter (`:596-624`).
//   4. Strips Image-type nodes from the text set (`:641`).
//   5. Emits (kind, boundingRect, textLeaves, ocrLines, imageLeaves) that
//      the overlay wraps into a WhiteboardRegion (`:686-688`).
//
// The overlay owns the actual bitmap capture and OCR runner — this file
// stays pure so it can be unit-tested with fixture roots + injected OCR.

import ApplicationServices
import CoreGraphics
import Foundation

/// One AX-derived leaf the snapper accepted. Text is the collapsed name
/// cascade result; identifier is best-effort so downstream stashes can
/// distinguish "snap hit" from "OCR-only".
public struct WhiteboardSnapLeaf: Sendable {
    public let text: String
    public let bounds: CGRect
    public let type: VisualElementType

    public init(text: String, bounds: CGRect, type: VisualElementType) {
        self.text = text
        self.bounds = bounds
        self.type = type
    }
}

/// One-per-gesture output the overlay converts into a `WhiteboardRegion`.
/// This is the pre-stash shape; the overlay collapses to the existing
/// `WhiteboardRegion(id, bboxScreen, gestureKind, ocrText)` value type by
/// joining `textLeaves` + `ocrLines` where AX was empty.
public struct WhiteboardSnappedRegion: Sendable {
    public let kind: AnnotationKind
    public let boundingRect: CGRect
    public let textLeaves: [WhiteboardSnapLeaf]
    public let imageLeaves: [WhiteboardSnapLeaf]
    public let confidence: Double
    public let rejected: Bool
    public let rejectReason: String
    public let diagnostics: String

    public init(
        kind: AnnotationKind,
        boundingRect: CGRect,
        textLeaves: [WhiteboardSnapLeaf],
        imageLeaves: [WhiteboardSnapLeaf],
        confidence: Double,
        rejected: Bool,
        rejectReason: String,
        diagnostics: String
    ) {
        self.kind = kind
        self.boundingRect = boundingRect
        self.textLeaves = textLeaves
        self.imageLeaves = imageLeaves
        self.confidence = confidence
        self.rejected = rejected
        self.rejectReason = rejectReason
        self.diagnostics = diagnostics
    }
}

public enum WhiteboardOrchestrator {

    /// Run the snap-then-OCR merge for one gesture. `root` is the focused
    /// window AX element (see plan `§6` — pull via FocusedWindowCapture);
    /// `prewarmed` is optional (nil forces the live rect-pruned walk).
    ///
    /// Mirrors the per-gesture body of `WhiteboardHotkeyInitializer.cs`
    /// `:596-688`. The OCR side is orchestrated by the caller; we accept
    /// the already-run `ocrLines` so this module stays synchronous and
    /// coordinate-space-clean.
    public static func snap(
        kind: AnnotationKind,
        strokes: [Stroke],
        boundingRect: CGRect,
        root: AXVisualElement,
        prewarmed: PrewarmedTree? = nil
    ) -> WhiteboardSnappedRegion {
        let annotation = Annotation(kind: kind, boundingRect: boundingRect)
        let result = AnnotationSnapper.snap(
            annotation: annotation,
            root: root,
            strokes: strokes,
            prewarmed: prewarmed
        )

        // Split leaves by image vs text — same rationale at
        // `WhiteboardHotkeyInitializer.cs:641-644`: SnapCircleOrX includes
        // Image nodes in its leaf set so a Circle over an image still
        // snaps, but the text join downstream silently skips them.
        var text: [WhiteboardSnapLeaf] = []
        var images: [WhiteboardSnapLeaf] = []
        for leaf in result.leaves {
            let snap = WhiteboardSnapLeaf(
                text: leaf.getText(),
                bounds: leaf.boundingRect,
                type: leaf.type
            )
            switch leaf.type {
            case .image:
                images.append(snap)
            case .label, .hyperlink:
                text.append(snap)
            case .other:
                break
            }
        }

        return WhiteboardSnappedRegion(
            kind: kind,
            boundingRect: boundingRect,
            textLeaves: text,
            imageLeaves: images,
            confidence: result.confidence,
            rejected: result.rejected,
            rejectReason: result.rejectReason,
            diagnostics: result.diagnostics
        )
    }

    /// Merge AX-snap text with OCR fallback. Byte-parity with the read tool
    /// path: AX wins as the primary text channel; OCR is kept for downstream
    /// slicing and empty-AX fallback (`WhiteboardHotkeyInitializer.cs:641`).
    ///
    /// - Parameters:
    ///   - snapText: joined AX-leaf text (`textLeaves` from `snap`).
    ///   - ocrText: joined OCR fallback text; empty means Vision returned
    ///     nothing.
    /// - Returns: the string that should populate `WhiteboardRegion.ocrText`
    ///   (the existing stash field). Named `ocrText` for backward
    ///   compatibility even though AX-hit content is the primary source.
    public static func mergedText(snapText: String, ocrText: String) -> String? {
        let ax = snapText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ax.isEmpty { return ax }
        let ocr = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ocr.isEmpty ? nil : ocr
    }

    /// Build the AXVisualElement root for a pid + focused-window pair.
    /// Callers should pre-check `pid > 0`; nil return means the AX handle
    /// is unusable (torn-down window, missing consent) and the overlay
    /// should skip the snap phase and fall back to OCR-only.
    public static func buildRoot(pid: pid_t) -> AXVisualElement? {
        guard pid > 0 else { return nil }
        // Mirrors AXQuirksInstaller bootstrap flow already used by
        // FocusedElementCapture — the whiteboard snapper is a peer AX
        // caller that runs on the same 1s SystemWide timeout.
        AXQuirksInstaller.ensureAXBootstrap()

        let app = AXUIElementCreateApplication(pid)
        // Prefer the app's focused window; fall back to main window
        // (`AXUIElement.cs:1167-1174`, mirrored by
        // `FocusedWindowCapture.resolveWindow`).
        let window: AXUIElement
        if let focused = copyAXElement(app, "AXFocusedWindow" as CFString) {
            window = focused
        } else if let main = copyAXElement(app, "AXMainWindow" as CFString) {
            window = main
        } else {
            return nil
        }
        let type = AXVisualElement.readType(from: window)
        let bounds = AXVisualElement.readBounds(from: window)
        return AXVisualElement(element: window, type: type, boundingRect: bounds)
    }

    private static func copyAXElement(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr, &value)
        guard err == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
}
