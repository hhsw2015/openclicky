// ContextExtractor.swift — Vision-based OCR + cheap image analytics.
//
// The OCR path is the exact Rewind 1.5607 configuration verified by Frida
// hook on Rewind's live VNRecognizeTextRequest — see the comment inside
// `singlePass(image:)`. This gives 100 % char-exact match with Rewind's
// stored OCR on the same in-memory CGImage (verified 5/5).
//
// Ported from research/prototypes/RewindKit/RewindContextExtractor.swift;
// namespace and struct types renamed to the OpenRewind* prefix. Behaviour
// unchanged.

import AppKit
import CoreImage
import CryptoKit
import Foundation
import NaturalLanguage
import Vision

// MARK: - Public model

public struct OpenRewindExtractedContext: Codable, Sendable {
    public let ocrText: String
    public let ocrNodes: [OCRNode]
    public let dominantLanguage: String?

    public let barcodes: [String]
    public let detectedRectangleCount: Int
    public let hasFaces: Bool

    public let contentKind: String
    public let brightness: Double
    public let perceptualHash: String
    public let dominantColorsHex: [String]

    public let inferredTitle: String?
    public let keywords: [String: Int]

    public let bundleID: String?
    public let windowName: String?
    public let browserUrl: String?
    public let capturedAt: Date
    public let imageWidth: Int
    public let imageHeight: Int

    public let jpegBase64_1280: String
    public let aiSummary: String

    // MARK: - Additions since prototype (all optional so callers that
    // only have OCR + an image can still round-trip).

    /// Accessibility tree nodes for the frontmost window at capture
    /// time. Empty when AX isn't granted or the app blocks introspection.
    /// Contains structural roles (`AXStaticText`, `AXTextArea`, `AXLink`,
    /// `AXButton`, `AXImage`, …) which OCR alone can't tell apart.
    public let axNodes: [AXTextNode]

    /// Audio transcript covering [capturedAt - transcriptLookbackSec,
    /// capturedAt]. Concatenated words with timestamps trimmed off.
    /// Empty when no microphone capture is enabled or no words landed
    /// in the window.
    public let transcriptSnippet: String

    /// Recent app usage — `bundleID → seconds in the last hour`.
    /// Rewind's own "AskRewind" context ships this as tier-1 signal.
    public let recentApps: [AppUsage]

    /// UI events (mouseDown/appSwitch) fired in the seconds around
    /// capture. Helps a model reason about intent ("user just clicked
    /// something" vs. passive viewing).
    public let recentEvents: [UIEventEcho]

    /// Segment the frame lives in — a contiguous run in the same app
    /// with the same browser URL. Anchors citations at a coarser level
    /// than individual frames.
    public let segment: SegmentEcho?

    /// Frame id in the store (if any). Enables `[FRAME#nn]`-style
    /// citations, same convention Rewind uses (IDA string
    /// `frame identifier, in format [FRAME#{frame_id}]`).
    public let frameId: Int64?

    public struct OCRNode: Codable, Sendable {
        public let text: String
        public let leftX: Double
        public let topY: Double
        public let width: Double
        public let height: Double
        public let confidence: Float
        public init(text: String, leftX: Double, topY: Double,
                    width: Double, height: Double, confidence: Float) {
            self.text = text; self.leftX = leftX; self.topY = topY
            self.width = width; self.height = height; self.confidence = confidence
        }
    }

    public struct AXTextNode: Codable, Sendable {
        public let text: String
        public let role: String       // AXStaticText, AXButton, AXLink, ...
        public let leftX: Double      // window-local, normalized 0…1
        public let topY: Double
        public let width: Double
        public let height: Double
    }

    public struct AppUsage: Codable, Sendable {
        public let bundleID: String
        public let seconds: Int
    }

    public struct UIEventEcho: Codable, Sendable {
        public let kind: String       // "mouseDown", "appSwitch", ...
        public let secondsBeforeCapture: Double
        public let app: String?
    }

    public struct SegmentEcho: Codable, Sendable {
        public let bundleID: String?
        public let browserUrl: String?
        public let startedAt: Date
        public let endedAt: Date?
    }
}

// MARK: - Ambient inputs

/// Everything the extractor pulls in beyond the pixel buffer. Passed by
/// the caller so `extract(image:ambient:…)` stays synchronous below the
/// Vision pipeline.
public struct OpenRewindExtractionAmbient: Sendable {
    public var axNodes: [OpenRewindExtractedContext.AXTextNode]
    public var transcriptSnippet: String
    public var recentApps: [OpenRewindExtractedContext.AppUsage]
    public var recentEvents: [OpenRewindExtractedContext.UIEventEcho]
    public var segment: OpenRewindExtractedContext.SegmentEcho?
    public var frameId: Int64?

    public init(
        axNodes: [OpenRewindExtractedContext.AXTextNode] = [],
        transcriptSnippet: String = "",
        recentApps: [OpenRewindExtractedContext.AppUsage] = [],
        recentEvents: [OpenRewindExtractedContext.UIEventEcho] = [],
        segment: OpenRewindExtractedContext.SegmentEcho? = nil,
        frameId: Int64? = nil
    ) {
        self.axNodes = axNodes
        self.transcriptSnippet = transcriptSnippet
        self.recentApps = recentApps
        self.recentEvents = recentEvents
        self.segment = segment
        self.frameId = frameId
    }

    public static let empty = OpenRewindExtractionAmbient()
}

// MARK: - Extractor

public enum OpenRewindContextExtractor {

    /// Pre-computed OCR result (from `TileOCRProcessor` etc.) that
    /// lets a caller skip `extract`'s internal full-frame Vision call.
    /// When supplied, `runOCR` is not invoked — huge saving because a
    /// typing/scrolling desk mutates only ~10 % of the tile grid per
    /// frame; retrace hits ~90 % cache and cuts OCR CPU by ~5×.
    public struct PrecomputedOCR: Sendable {
        public let text: String
        public let nodes: [OpenRewindExtractedContext.OCRNode]
        public let dominantLanguage: String?
        public init(text: String,
                    nodes: [OpenRewindExtractedContext.OCRNode],
                    dominantLanguage: String? = nil) {
            self.text = text
            self.nodes = nodes
            self.dominantLanguage = dominantLanguage
        }
    }

    public static func extract(
        image: CGImage,
        capturedAt: Date = Date(),
        bundleID: String? = nil,
        windowName: String? = nil,
        browserUrl: String? = nil,
        ambient: OpenRewindExtractionAmbient = .empty,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        thumbnailWidth: Int = 1280,
        analytics: Bool = false,
        precomputedOCR: PrecomputedOCR? = nil
    ) async throws -> OpenRewindExtractedContext {

        // OCR is the mandatory path (search index). Barcode / rect /
        // face are analytics that quadrupled ANE memory pressure and
        // starved SCStream; gated behind `analytics: true`.
        let ocrText: String
        let ocrNodes: [OpenRewindExtractedContext.OCRNode]
        let lang: String?
        if let pre = precomputedOCR {
            ocrText = pre.text
            ocrNodes = pre.nodes
            if let l = pre.dominantLanguage {
                lang = l
            } else if pre.text.count >= 20 {
                let r = NLLanguageRecognizer()
                r.processString(pre.text)
                lang = r.dominantLanguage?.rawValue
            } else {
                lang = nil
            }
        } else {
            (ocrText, ocrNodes, lang) = try await runOCR(image, level: recognitionLevel)
        }
        var barcodes: [String] = []
        var rectCount = 0
        var hasFaces = false
        if analytics {
            barcodes = (try? await runBarcodes(image)) ?? []
            rectCount = (try? await runRectangles(image)) ?? 0
            hasFaces = (try? await runFaces(image)) ?? false
        }

        let brightness = averageLuminance(image)
        let phash = perceptualHash(image)
        let colors = dominantColors(image, count: 3)
        let kind = classify(ocrText: ocrText, bundleID: bundleID,
                             brightness: brightness, colors: colors)
        let title = inferTitle(from: ocrNodes)
        let keywords = bagOfKeywords(from: ocrText)
        let jpeg = jpegBase64(cgImage: image, maxWidth: thumbnailWidth)

        let summary = renderSummary(kind: kind, bundleID: bundleID,
                                     windowName: windowName,
                                     browserUrl: browserUrl,
                                     title: title, ocrText: ocrText)

        return OpenRewindExtractedContext(
            ocrText: ocrText,
            ocrNodes: ocrNodes,
            dominantLanguage: lang,
            barcodes: barcodes,
            detectedRectangleCount: rectCount,
            hasFaces: hasFaces,
            contentKind: kind,
            brightness: brightness,
            perceptualHash: phash,
            dominantColorsHex: colors,
            inferredTitle: title,
            keywords: keywords,
            bundleID: bundleID,
            windowName: windowName,
            browserUrl: browserUrl,
            capturedAt: capturedAt,
            imageWidth: image.width,
            imageHeight: image.height,
            jpegBase64_1280: jpeg,
            aiSummary: summary,
            axNodes: ambient.axNodes,
            transcriptSnippet: ambient.transcriptSnippet,
            recentApps: ambient.recentApps,
            recentEvents: ambient.recentEvents,
            segment: ambient.segment,
            frameId: ambient.frameId)
    }

    // MARK: - Vision requests

    private static func runOCR(_ image: CGImage,
                               level: VNRequestTextRecognitionLevel)
        async throws -> (String, [OpenRewindExtractedContext.OCRNode], String?) {

        let nodes = await singlePass(image: image)

        // Rewind stores observations in Vision's raw callback order, which
        // is close to reading order. We sort strictly top-to-bottom then
        // left-to-right for deterministic downstream storage.
        let sorted = nodes.sorted { a, b in
            let dy = a.topY - b.topY
            if abs(dy) > 0.01 { return dy < 0 }
            return a.leftX < b.leftX
        }
        let text = sorted.map(\.text).joined(separator: " ")

        var lang: String? = nil
        if text.count >= 20 {
            let r = NLLanguageRecognizer()
            r.processString(text)
            lang = r.dominantLanguage?.rawValue
        }
        return (text, sorted, lang)
    }

    private static func singlePass(image: CGImage)
        async -> [OpenRewindExtractedContext.OCRNode] {
        await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                guard let obs = req.results as? [VNRecognizedTextObservation]
                else { cont.resume(returning: []); return }
                var out: [OpenRewindExtractedContext.OCRNode] = []
                for o in obs {
                    guard let c = o.topCandidates(1).first else { continue }
                    let bb = o.boundingBox
                    out.append(.init(
                        text: c.string,
                        leftX: Double(bb.origin.x),
                        topY: Double(1.0 - bb.origin.y - bb.height),
                        width: Double(bb.width),
                        height: Double(bb.height),
                        confidence: c.confidence))
                }
                cont.resume(returning: out)
            }
            // FIX(retrace-review-19-2026-07-29): full-frame Vision knobs
            // moved into `OpenRewindVisionOCRConfig.fullFrame` so both
            // this path and TileOCR share one place to tune Vision.
            // Defaults are bit-exact with Rewind's own request setup
            // (verified via Frida hook on Rewind's live VNRecognizeText):
            // rev 3, accurate, correction=false, min height 0, auto
            // language detection ON with the ["zh-Hans","en-US"] hint.
            OpenRewindVisionOCRConfig.fullFrame.apply(to: req)
            // FIX(review-2026-07-28) K-L: explicit .up orientation so we
            // match Rewind's request setup on the same CGImage. CGImage's
            // native orientation is already .up, but stating it explicitly
            // guarantees Vision won't guess EXIF-flip when a caller passes
            // an image derived from a rotated pixel buffer.
            let handler = VNImageRequestHandler(cgImage: image,
                                                orientation: .up,
                                                options: [:])
            try? handler.perform([req])
        }
    }

    private static func runBarcodes(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectBarcodesRequest { req, err in
                if let _ = err { cont.resume(returning: []); return }
                let out = (req.results as? [VNBarcodeObservation])?
                    .compactMap { $0.payloadStringValue } ?? []
                cont.resume(returning: out)
            }
            // FIX(review-2026-07-28) K-L: parity with runOCR — always .up.
            let h = VNImageRequestHandler(cgImage: image,
                                          orientation: .up, options: [:])
            do { try h.perform([req]) }
            catch { cont.resume(returning: []) }
        }
    }

    private static func runRectangles(_ image: CGImage) async throws -> Int {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectRectanglesRequest { req, err in
                if let _ = err { cont.resume(returning: 0); return }
                cont.resume(returning: req.results?.count ?? 0)
            }
            req.minimumConfidence = 0.7
            req.maximumObservations = 20
            // FIX(review-2026-07-28) K-L: parity with runOCR — always .up.
            let h = VNImageRequestHandler(cgImage: image,
                                          orientation: .up, options: [:])
            do { try h.perform([req]) }
            catch { cont.resume(returning: 0) }
        }
    }

    private static func runFaces(_ image: CGImage) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            let req = VNDetectFaceRectanglesRequest { req, err in
                if let _ = err { cont.resume(returning: false); return }
                cont.resume(returning: (req.results?.count ?? 0) > 0)
            }
            // FIX(review-2026-07-28) K-L: parity with runOCR — always .up.
            let h = VNImageRequestHandler(cgImage: image,
                                          orientation: .up, options: [:])
            do { try h.perform([req]) }
            catch { cont.resume(returning: false) }
        }
    }

    // MARK: - Cheap image analytics (no Vision)

    private static func averageLuminance(_ cg: CGImage) -> Double {
        let w = 64, h = 64
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Double = 0
        var n: Double = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            let b = Double(data[i]), g = Double(data[i+1]), r = Double(data[i+2])
            sum += 0.299 * r + 0.587 * g + 0.114 * b
            n += 1
        }
        return (sum / n) / 255.0
    }

    private static func perceptualHash(_ cg: CGImage) -> String {
        let w = 8, h = 8
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lums: [Double] = []
        for i in stride(from: 0, to: data.count, by: 4) {
            let b = Double(data[i]), g = Double(data[i+1]), r = Double(data[i+2])
            lums.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
        let avg = lums.reduce(0, +) / Double(lums.count)
        var bits: UInt64 = 0
        for (i, l) in lums.enumerated() {
            if l >= avg { bits |= (1 << UInt64(i)) }
        }
        return String(format: "%016llx", bits)
    }

    private static func dominantColors(_ cg: CGImage, count: Int) -> [String] {
        let w = 32, h = 32
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var buckets: [UInt32: Int] = [:]
        for i in stride(from: 0, to: data.count, by: 4) {
            let b = data[i] & 0xF8, g = data[i+1] & 0xF8, r = data[i+2] & 0xF8
            let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            buckets[key, default: 0] += 1
        }
        return buckets.sorted { $0.value > $1.value }
            .prefix(count)
            .map { String(format: "#%06x", $0.key) }
    }

    private static func inferTitle(from nodes: [OpenRewindExtractedContext.OCRNode]) -> String? {
        let candidates = nodes.filter { $0.text.count >= 3 && $0.text.count <= 80 }
        return candidates.max(by: { $0.height < $1.height })?.text
    }

    private static func bagOfKeywords(from text: String,
                                      minLen: Int = 4,
                                      topN: Int = 15) -> [String: Int] {
        let stop: Set<String> = [
            "http","https","com","the","and","for","that","this","with",
            "from","into","have","been","were","was","are","not","but",
            "all","you","your","our","their","its","just","them",
        ]
        var counts: [String: Int] = [:]
        for tok in text.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }) {
            let w = String(tok)
            if w.count >= minLen && !stop.contains(w) {
                counts[w, default: 0] += 1
            }
        }
        return Dictionary(uniqueKeysWithValues:
            counts.sorted { $0.value > $1.value }.prefix(topN)
                  .map { ($0.key, $0.value) })
    }

    private static func classify(ocrText: String, bundleID: String?,
                                 brightness: Double,
                                 colors: [String]) -> String {
        let text = ocrText.lowercased()
        if let b = bundleID {
            if b.contains("terminal") || b.contains("iterm")
                || b.contains("ghostty") || b.contains("cmux")
                || b.contains("warp") { return "terminal" }
            if b.contains("safari") || b.contains("chrome")
                || b.contains("arc") || b.contains("firefox")
                || b.contains("brave") { return "browser" }
            if b.contains("xcode") || b.contains("vscode")
                || b.contains("cursor") { return "code" }
            if b.contains("mail") || b.contains("messages")
                || b.contains("slack") || b.contains("discord")
                || b.contains("zoom") || b.contains("teams") { return "chat" }
            if b.contains("preview") || b.contains("pdf")
                || b.contains("word") || b.contains("pages")
                || b.contains("notes") { return "document" }
        }
        _ = colors
        if brightness < 0.25
            && (text.contains("$") || text.contains("~/") || text.contains("~ %"))
        { return "terminal" }
        if text.contains("http://") || text.contains("https://")
            || text.contains("www.") { return "browser" }
        if text.contains("import ") || text.contains("func ")
            || text.contains("def ") || text.contains("class ")
            || text.contains("{") { return "code" }
        return "other"
    }

    private static func renderSummary(kind: String, bundleID: String?,
                                      windowName: String?,
                                      browserUrl: String?,
                                      title: String?,
                                      ocrText: String) -> String {
        var parts: [String] = []
        parts.append("User is viewing \(kind)")
        if let b = bundleID { parts.append("in \(b)") }
        if let w = windowName, !w.isEmpty { parts.append("titled '\(w)'") }
        if let u = browserUrl { parts.append("at \(u)") }
        if let t = title, t.count > 0 && t != windowName {
            parts.append("main heading: \(t)")
        }
        let snippet = ocrText.prefix(200)
            .replacingOccurrences(of: "\n", with: " ")
        if !snippet.isEmpty { parts.append("screen text: \(snippet)") }
        return parts.joined(separator: "; ")
    }

    private static func jpegBase64(cgImage: CGImage, maxWidth: Int) -> String {
        let ratio = min(CGFloat(maxWidth) / CGFloat(cgImage.width), 1)
        let w = max(Int(CGFloat(cgImage.width) * ratio), 1)
        let h = max(Int(CGFloat(cgImage.height) * ratio), 1)
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let source = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width,
                                                              height: cgImage.height))
        source.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                    from: NSRect(x: 0, y: 0, width: cgImage.width,
                                 height: cgImage.height),
                    operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg,
                          properties: [.compressionFactor: 0.7]) else { return "" }
        return data.base64EncodedString()
    }
}

// MARK: - Convenience overloads

public extension OpenRewindContextExtractor {
    static func extract(fileURL: URL,
                        capturedAt: Date = Date(),
                        bundleID: String? = nil,
                        windowName: String? = nil,
                        browserUrl: String? = nil)
        async throws -> OpenRewindExtractedContext {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "OpenRewindContextExtractor", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                            "cannot decode \(fileURL.path)"])
        }
        return try await extract(image: cg, capturedAt: capturedAt,
                                  bundleID: bundleID, windowName: windowName,
                                  browserUrl: browserUrl)
    }

    static func extract(nsImage: NSImage,
                        capturedAt: Date = Date(),
                        bundleID: String? = nil,
                        windowName: String? = nil,
                        browserUrl: String? = nil)
        async throws -> OpenRewindExtractedContext {
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil,
                                        hints: nil) else {
            throw NSError(domain: "OpenRewindContextExtractor", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "no CGImage"])
        }
        return try await extract(image: cg, capturedAt: capturedAt,
                                  bundleID: bundleID, windowName: windowName,
                                  browserUrl: browserUrl)
    }
}
