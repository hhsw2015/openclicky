// Ported from Everywhere: src/Everywhere.Mac/Interop/MacVisionOcrEngine.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Apple Vision-backed OCR. Fast recognition level (~30 ms / call at
// desktop resolution); we only need per-line y bboxes (the text layer
// itself comes from AX / SnapshotRenderer), so Fast's slightly lower
// text quality is acceptable and its bbox accuracy is identical to
// Accurate. Matches Everywhere's default `OcrQuality.Fast` branch.
//
// Everywhere -> openclicky signature deltas (see the impl notes at
// docs/ROADMAP/.impl-notes/phase5-ocr-2026-07-22.md for the full list):
//   * Input is `NSImage` instead of a PNG `Stream`. We render to a
//     `CGImage` via `NSImage.cgImage(forProposedRect:context:hints:)`.
//   * No `originPx` argument. Bounding boxes are returned in image-
//     local pixel space (upper-left origin, integer-rounded,
//     w/h >= 1). Callers translate to screen coords themselves.
//   * `Recognize` returns a bare list in C#; we return `OCRResult?`.
//     `nil` means "Vision could not run" (bad image, thrown error).
//     `OCRResult(lines: [])` means "Vision ran, produced zero lines".
//   * Quality fixed to Fast (Accurate branch not exposed at P1).
//   * `async` wrapper: `VNImageRequestHandler.perform` is synchronous,
//     but the public API is `async` so the caller can hop the actual
//     Vision call off the current actor.
//
// Vision configuration (1:1 with Everywhere's Fast branch):
//   * `recognitionLevel = .fast`
//   * `usesLanguageCorrection = false`  (Fast branch in the C# switch)
//   * `recognitionLanguages = languages` (caller-supplied)
//   * Default revision (no explicit `revision` pin)
//   * Options dictionary is empty (no orientation override)

import Foundation
import AppKit
import CoreGraphics
import Vision

/// Vision-backed OCR wrapper.
///
/// See the file header for the Everywhere -> openclicky signature
/// mapping. The public API is a single async static function.
public enum OCRCapture {

    /// Default language priority list. Byte-exact with Everywhere's
    /// `MacVisionOcrEngine.cs:59` — `["zh-Hans", "zh-Hant", "en-US"]`.
    /// Vision treats this as a PRIORITY HINT (not a filter); mismatched
    /// order changes tokenization on mixed-language content, and
    /// dropping `zh-Hant` loses the traditional-Chinese model entirely.
    public static let defaultLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

    /// Run Vision OCR over `image` using the Fast recognition level.
    ///
    /// - Parameters:
    ///   - image: Source image. Must have a rasterisable CGImage
    ///     representation. Empty / zero-size images resolve to `nil`.
    ///   - languages: Recognition language priority list.
    ///     Order matters — Vision uses it as a priority hint.
    /// - Returns: `OCRResult` on success (including the zero-line
    ///   case). `nil` when the image could not be decoded to a
    ///   `CGImage` or when Vision itself threw.
    public static func ocr(
        image: NSImage,
        languages: [String] = defaultLanguages
    ) async -> OCRResult? {
        guard let cgImage = cgImageFrom(image) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            performOCR(on: cgImage, languages: languages)
        }.value
    }

    // MARK: - Private

    /// Extract a `CGImage` from `NSImage`. Returns nil for zero-size
    /// images (matches Everywhere's `src.ImageCount == 0` guard).
    private static func cgImageFrom(_ image: NSImage) -> CGImage? {
        // Guard against zero-size / degenerate NSImage instances.
        let size = image.size
        if size.width <= 0 || size.height <= 0 {
            return nil
        }
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Perform the Vision request synchronously on `cgImage`.
    /// Returns nil only when `handler.perform([...])` throws
    /// (matches Everywhere's `if (!handler.Perform([req], out var err))`
    /// early return). A successful call with no observations yields
    /// `OCRResult(lines: [])`.
    private static func performOCR(
        on cgImage: CGImage,
        languages: [String]
    ) -> OCRResult? {
        let imgW = cgImage.width
        let imgH = cgImage.height

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        // No-op completion — Everywhere pulls results via GetResults
        // after Perform returns. We mirror that: results are read off
        // `request.results` below.
        let request = VNRecognizeTextRequest { _, _ in }

        // Fast branch of Everywhere's `OcrQuality` switch.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages

        do {
            try handler.perform([request])
        } catch {
            // Everywhere logs at Debug/Warning and returns empty list.
            // openclicky returns nil so callers can tell "Vision failed"
            // apart from "Vision returned nothing".
            return nil
        }

        guard let observations = request.results as? [VNRecognizedTextObservation],
              observations.isEmpty == false else {
            return OCRResult(lines: [])
        }

        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)

        for obs in observations {
            let cands = obs.topCandidates(1)
            guard let top = cands.first else { continue }
            let text = top.string

            // Vision normalised rect: origin lower-left, axes 0..1.
            let bb = obs.boundingBox
            let nx = bb.origin.x
            let ny = bb.origin.y
            let nw = bb.size.width
            let nh = bb.size.height

            // Upper-left-origin pixel coords, image-local (no origin
            // translation — callers add that themselves). Round (not
            // truncate) and clamp w/h to `>= 1` so thin glyphs don't
            // collapse to zero.
            let x = Int((nx * Double(imgW)).rounded())
            let w = max(1, Int((nw * Double(imgW)).rounded()))
            let y = Int(((1.0 - ny - nh) * Double(imgH)).rounded())
            let h = max(1, Int((nh * Double(imgH)).rounded()))

            let bounds = CGRect(x: x, y: y, width: w, height: h)
            lines.append(OCRLine(
                text: text,
                bounds: bounds,
                confidence: top.confidence
            ))
        }

        // Ascending y — top-to-bottom on the upper-left origin. Matches
        // Everywhere's `lines.Sort((a, b) => a.Bounds.Y.CompareTo(b.Bounds.Y))`.
        lines.sort { $0.bounds.origin.y < $1.bounds.origin.y }
        return OCRResult(lines: lines)
    }
}
