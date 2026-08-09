// OCRRunner — Vision text-recognition wrapper for the helper.
//
// Runs one VNRecognizeTextRequest per frame with the same tuning
// (revision 3, .accurate, minimumTextHeight, CPU-only) the main app's
// OpenRewindVisionOCRConfig uses. Kept CPU-only intentionally: the
// whole point of this helper is that Vision work happens in a
// separate address space AND on the CPU, never on the shared ANE that
// WindowServer needs to keep the cursor smooth.
//
// The helper does not port the tile cache. Tile diffing is an
// optimisation for repeated similar frames on the same bundle; here
// each XPC call may hit a different helper worker and each frame is
// treated as a full-frame OCR. The dominant win from off-processing
// remains: Vision + ANE queues no longer compete with the main app's
// UI thread.

import Foundation
import CoreGraphics
import ImageIO
import Vision

public struct OCRRegion: Sendable {
    public let text: String
    public let confidence: Float
    public let leftX: Double
    public let topY: Double
    public let width: Double
    public let height: Double
}

public enum OCRRunner {

    public enum RunError: Error, CustomStringConvertible {
        case decodeFailed
        case visionFailed(String)

        public var description: String {
            switch self {
            case .decodeFailed:            return "png decode failed"
            case .visionFailed(let s):     return "vision failed: \(s)"
            }
        }
    }

    /// Decode PNG bytes, downsample to 1600 px longest side, run Vision.
    public static func recognize(pngData: Data) throws -> [OCRRegion] {
        guard let cg = decodePNG(pngData) else {
            throw RunError.decodeFailed
        }
        let scaled = downsampleIfNeeded(cg, maxSide: 1600)
        return try runVision(cgImage: scaled)
    }

    // MARK: - Vision

    private static func runVision(cgImage: CGImage) throws -> [OCRRegion] {
        var out: [OCRRegion] = []
        var visionErr: Error?
        let sem = DispatchSemaphore(value: 0)

        let req = VNRecognizeTextRequest { req, err in
            defer { sem.signal() }
            if let err {
                visionErr = err
                return
            }
            let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
            out.reserveCapacity(obs.count)
            for o in obs {
                guard let c = o.topCandidates(1).first else { continue }
                let bb = o.boundingBox
                let topLeftY = 1 - bb.origin.y - bb.height
                out.append(OCRRegion(
                    text: c.string,
                    confidence: c.confidence,
                    leftX: Double(bb.origin.x),
                    topY: Double(topLeftY),
                    width: Double(bb.width),
                    height: Double(bb.height)))
            }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.0143
        // CPU-only: keep ANE free for WindowServer / main-app cursor
        // compositing. Vision is ~1.5x slower on CPU but this runs
        // in a separate process at background QoS, so wall-clock
        // OCR latency is invisible to the user.
        req.usesCPUOnly = true
        if #available(macOS 13.0, *) {
            req.revision = VNRecognizeTextRequestRevision3
            req.automaticallyDetectsLanguage = true
            req.recognitionLanguages = ["zh-Hans", "en-US"]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
        } catch {
            throw RunError.visionFailed("\(error)")
        }
        sem.wait()
        if let visionErr {
            throw RunError.visionFailed("\(visionErr)")
        }

        // Sort into reading order (top-to-bottom, left-to-right).
        return out.sorted { a, b in
            let dy = a.topY - b.topY
            if abs(dy) > 0.01 { return dy < 0 }
            return a.leftX < b.leftX
        }
    }

    // MARK: - Decode + downsample

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func downsampleIfNeeded(_ cg: CGImage,
                                           maxSide: Int) -> CGImage {
        let w = cg.width, h = cg.height
        let longest = max(w, h)
        guard longest > maxSide else { return cg }
        let scale = Double(maxSide) / Double(longest)
        let dw = max(1, Int(Double(w) * scale))
        let dh = max(1, Int(Double(h) * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue
                   | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: nil, width: dw, height: dh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmap) else {
            return cg
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        return ctx.makeImage() ?? cg
    }
}
