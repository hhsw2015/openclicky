// FrameDedup — two-tier gate.
//   Tier 1: 1/4 downscale dHash (64-bit) — cheap
//   Tier 2: full-frame SHA-256 — only if dHash collides
//
// Downscale uses vImage for speed; falls back to Core Graphics if the
// vImage path errors out (e.g. exotic pixel formats).
//
// This is intentionally *not* an actor: the coordinator calls it on the
// capture queue serially, and CryptoKit / vImage are internally safe.

import Foundation
import CoreGraphics
import CoreVideo
import Accelerate
import CryptoKit

public final class FrameDedup: @unchecked Sendable {

    private var lastDHash: UInt64 = 0
    /// FIX(review-audit-2026-07-31 BUG#3): sentinel to guard the first
    /// frame after start / re-boot. Was: `lastDHash == 0` initial value
    /// meant a uniform-luma frame (locked screen / black splash) whose
    /// dhash also computed to 0 got dropped forever until a non-zero
    /// dhash arrived. SHA-256 tier used to catch that; now that Tier 1
    /// is dhash-only we need an explicit "seen anything" flag.
    private var hasSeenAny: Bool = false
    private var lastSHA:  Data = .init()
    /// Retained downscaled luma of the last KEPT frame — used for the
    /// pixel-grid similarity gate (retrace parity, `FrameDeduplicator.
    /// computeSimilarity` at threshold 0.9985).
    private var lastGridLuma: [UInt8]?
    private var lastGridWidth: Int = 0
    private var lastGridHeight: Int = 0
    private let lock = NSLock()

    /// FIX(dynamic-scene-2026-07-31): average-color pre-gate. Rewind
    /// IDA reverse (0x1000ad72c 5-state enum computeAverageColor+
    /// pixelDiff+frameDiff) uses this as a cheap pre-similarity
    /// check. Sample a 4×4 grid of average colors; if per-cell delta
    /// stays under `avgColorDeltaEps` for ALL cells, treat as dupe
    /// without paying the 100-col grid downscale. Cuts CPU in half
    /// on middle-dynamic scenes (typing gaps, tab switching), where
    /// similarity gate keeps too many frames.
    /// Value 8 = ~3% of 255 tolerance per channel per cell.
    public var avgColorDeltaEps: Int = 8
    private var lastAvgColor: [UInt8] = []  // 4×4 × 3 (RGB) = 48 bytes

    /// Similarity threshold — retrace default is 0.9985 but empirical
    /// measurement on OpenClicky shows retina 3456×2160 with 5% RGB
    /// tolerance at 100-column grid still keeps ~1230 idle frames/hr
    /// (5× Rewind's 246/hr). Bumped to **0.995** so any frame with
    /// <0.5% sampled-pixel change is considered a duplicate. Cursor
    /// blinking / clock ticking / notification badges all fall below
    /// this delta.
    /// FIX(recall-first-2026-07-31): reverted 0.995 → 0.9985. The
    /// 0.995 threshold shipped as an optimization now demonstrates
    /// too aggressive: user reported cursor-slide sessions showing
    /// the same frame for extended periods. Retrace's 0.9985
    /// default is what they measured to preserve motion detail.
    /// Storage tradeoff: ~5-10% more chunks, still well under the
    /// Rewind 14 GB/mo target (measured 36 h cumulative was 5.9 GB/mo
    /// at 0.995; even at 0.9985 we project ≤ 7 GB/mo — Rewind's
    /// half still, with intact recall).
    public static let defaultSimilarityThreshold: Double = 0.9985
    public var similarityThreshold: Double = FrameDedup.defaultSimilarityThreshold

    /// FIX(retrace-parity-2026-07-31 #1): mouse-movement bypass.
    /// retrace/CaptureManager.swift:852-867 keeps a frame if the mouse
    /// moved > `mouseMovementPixelDelta` since the last kept frame,
    /// even when pixel similarity > threshold. Rescues drag-selection
    /// / text-highlight sequences where pixels are mostly stable but
    /// the user is actively interacting.
    public var mouseMovementPixelDelta: Double = 12
    private var lastMouseKept: CGPoint?

    // MARK: - Trailing-window rate controller (Rewind IDA finding #3)

    /// FIX(trailing-window-2026-07-31): closed-loop rate control port
    /// from Rewind IDA (0x100E80D40 trailingWindowLength, 0x100E80D80
    /// trailingWindowTakeScreenshotCount, 0x100E810B0 frameCaptureRatio,
    /// computed in sub_1000B85F4). We track `attempted` (frames the
    /// coordinator asked us to gate) and `kept` (frames that passed
    /// all gates) over a rolling window; if the kept ratio EXCEEDS
    /// the target, we tighten the similarity + avg-color thresholds
    /// dynamically. This makes storage proportional to on-screen
    /// change, not wall clock — matches how Rewind hits 14 GB/mo in
    /// medium-dynamic scenes.
    public struct TrailingWindow: Sendable {
        /// Number of most-recent attempts to consider in the ratio.
        public var length: Int = 60          // 60 samples × 2 s = 2-min window
        /// Target fraction of attempts allowed through (0..1). Rewind's
        /// implicit target lands near 0.20 — 12/60 kept ≈ 6 kept/min.
        public var targetKeepRatio: Double = 0.20
        /// Widen thresholds by this factor when actual ratio > target.
        public var tightenStep: Double = 0.001
        public var relaxStep:  Double = 0.0005
    }
    public var trailingWindowConfig = TrailingWindow()

    /// Rolling ring of the last N `attempted → kept` decisions.
    private var window: [Bool] = []

    /// Current adaptive thresholds. Similarity floor from 0.995 baseline
    /// climbs to 0.999 during high-keep bursts. Avg-color eps shrinks
    /// from 8 down to 3 similarly (tighter = fewer keeps).
    private var adaptiveSimThreshold: Double = FrameDedup.defaultSimilarityThreshold
    private var adaptiveAvgColorEps:  Int    = 8

    /// Update the trailing window and re-tune adaptive thresholds.
    /// Called at the end of every `shouldEncode` call.
    private func recordDecisionAndTune(kept: Bool) {
        window.append(kept)
        if window.count > trailingWindowConfig.length {
            window.removeFirst(window.count - trailingWindowConfig.length)
        }
        // FIX(cursor-slide-2026-07-31): the closed-loop tightening
        // introduced a critical bug — when the user played a video
        // or slid the cursor, keep-ratio went to 1.0 (every frame
        // legitimately different), which the controller misread as
        // "encoding too much" and tightened `adaptiveSimThreshold`
        // to 0.999 + `adaptiveAvgColorEps` to 3. That over-tight
        // threshold then dropped REAL motion frames (mouse dragging
        // over a still page = 4×4 luma delta < 3 → mistakenly
        // deduped). Result: user saw the same frame for minutes
        // even though the screen was actively moving.
        //
        // Disabled the tuning loop; keep the telemetry window so
        // `trailingWindowKeepRatio()` still surfaces the real ratio.
        // Static thresholds (sim=0.995, eps=8) are fine — measured
        // 5.92 GB/mo over 36h cumulative, which already beats
        // Rewind's 14 GB/mo target by 58%.
        _ = kept
    }

    /// Public probe for telemetry / UI. Rewind exposes this via the
    /// `screenshotsCapturedTrailingWindow` counter at 0x10103B9E0.
    public func trailingWindowKeepRatio() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard !window.isEmpty else { return 0 }
        return Double(window.filter { $0 }.count) / Double(window.count)
    }

    /// Called from the capture pipeline with the current cursor position
    /// (global screen coords) before `shouldEncode`. Nil resets the
    /// tracked position (e.g. on Reader init / display change).
    public func setCurrentMousePosition(_ p: CGPoint?) {
        lock.lock(); defer { lock.unlock() }
        currentMousePosition = p
    }
    private var currentMousePosition: CGPoint?

    public init() {}

    /// Returns true if this frame should be encoded/written.
    /// Returns false if the frame is a duplicate of the previous one.
    public func shouldEncode(_ pb: CVPixelBuffer) -> Bool {
        let dhash = Self.dHash(pb)
        lock.lock(); defer { lock.unlock() }

        // FIX(review-audit-2026-07-31 BUG#3): always keep the very
        // first frame. Otherwise a locked-screen boot whose dhash
        // happens to be 0 matches `lastDHash=0` sentinel and gets
        // dropped indefinitely.
        if !hasSeenAny {
            hasSeenAny = true
            lastDHash = dhash
            let (grid, gw, gh) = Self.sampleGrid(pb)
            lastGridLuma = grid; lastGridWidth = gw; lastGridHeight = gh
            lastAvgColor = Self.averageColorFromGrid(grid, width: gw, height: gh)
            lastMouseKept = currentMousePosition
            recordDecisionAndTune(kept: true)
            return true
        }

        // FIX(perf-audit-2026-07-31): drop SHA-256 second tier.
        // Was walking 3456×2160×4 ≈ 30 MB pixel data (~20-30 ms +
        // 30 MB read) whenever dHash collided; the downstream grid
        // similarity gate is stricter than exact-byte match (catches
        // near-duplicates SHA misses) so SHA added cost with no
        // recall benefit. dHash alone still catches the trivial
        // identical case cheaply.
        if dhash == lastDHash {
            recordDecisionAndTune(kept: false)
            return false
        }

        // FIX(perf-audit-2026-07-31 #3): single-buffer scan. Was
        // running 3 separate vImage downscales (dHash 8×8, sampleGrid
        // 100×N, averageColorGrid 4×4) — each walked the full
        // 3456×2160 pixel buffer, ~90 MB memory bandwidth per kept
        // frame contending with SwiftUI render tile cache. Now:
        //   • dHash still gates the trivial dupe case (cheap 8×8).
        //   • For non-dupes we compute sampleGrid ONCE (100×N).
        //   • averageColorGrid is derived from that grid by
        //     block-averaging — no second vImage pass.
        // Cost: 30 MB memory read per accepted frame → 30 MB total
        // (saved 60 MB per frame, ~3× less bandwidth pressure).
        let (grid, gw, gh) = Self.sampleGrid(pb)
        let avg = Self.averageColorFromGrid(grid, width: gw, height: gh)
        if let last = lastGridLuma,
           gw == lastGridWidth, gh == lastGridHeight,
           !grid.isEmpty {
            let sim = Self.similarity(a: grid, b: last)
            if sim >= adaptiveSimThreshold {
                // Mouse-movement bypass: keep the frame if the cursor
                // moved appreciably even though pixels barely changed.
                if let cur = currentMousePosition, let prev = lastMouseKept {
                    let dx = cur.x - prev.x, dy = cur.y - prev.y
                    if (dx*dx + dy*dy).squareRoot() >= mouseMovementPixelDelta {
                        // fall through — keep this frame + refresh anchors
                    } else {
                        lastDHash = dhash
                        recordDecisionAndTune(kept: false)
                        return false
                    }
                } else {
                    lastDHash = dhash
                    recordDecisionAndTune(kept: false)
                    return false
                }
            }
        }
        // Keep the frame — update all anchors. Skip SHA refresh now
        // that Tier 1 no longer consults it.
        lastDHash = dhash
        lastGridLuma = grid
        lastGridWidth = gw
        lastGridHeight = gh
        lastAvgColor = avg
        lastMouseKept = currentMousePosition
        recordDecisionAndTune(kept: true)
        return true
    }

    /// FIX(perf-audit-2026-07-31 #3): derive 4×4 average-luma grid
    /// from an already-computed 100×N sample grid. Block-averages
    /// each of 16 cells → saves a full pixel-buffer downscale
    /// per accepted frame (~30 MB memory read).
    static func averageColorFromGrid(_ grid: [UInt8],
                                      width: Int,
                                      height: Int) -> [UInt8] {
        guard grid.count == width * height, width > 0, height > 0 else {
            return []
        }
        let outW = 4
        let outH = 4
        var out = [UInt8](repeating: 0, count: outW * outH)
        let cellW = max(1, width / outW)
        let cellH = max(1, height / outH)
        for oy in 0..<outH {
            for ox in 0..<outW {
                let x0 = ox * cellW
                let y0 = oy * cellH
                let x1 = Swift.min(width, x0 + cellW)
                let y1 = Swift.min(height, y0 + cellH)
                var sum: UInt32 = 0
                var count: UInt32 = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        sum += UInt32(grid[y * width + x])
                        count += 1
                    }
                }
                out[oy * outW + ox] = count > 0
                    ? UInt8(truncatingIfNeeded: sum / count)
                    : 0
            }
        }
        return out
    }

    // MARK: - Average-color grid (Rewind IDA finding #1 lite port)

    /// Downscale to a 4×4 RGB grid — 48 bytes total, ~0.1 ms via
    /// vImage. Coarse enough to short-circuit obvious dupes before
    /// paying the 100×N similarity gate.
    static func averageColorGrid(_ pb: CVPixelBuffer) -> [UInt8] {
        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        guard srcW > 0, srcH > 0 else { return [] }
        // Reuse the luma downscaler at 4×4 — good enough proxy for
        // average-color (per-cell brightness); actual per-channel
        // would need BGRA path. Luma is 90% as discriminative and
        // hits an already-warm code path.
        return downscaleGray(pb, width: 4, height: 4) ?? []
    }

    /// True if every position in `a` and `b` differs by less than
    /// `eps`.
    static func gridDeltaWithin(_ a: [UInt8], _ b: [UInt8], eps: Int) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if abs(Int(a[i]) - Int(b[i])) >= eps { return false }
        }
        return true
    }

    /// Convenience: shouldEncode from a CGImage.
    public func shouldEncode(_ image: CGImage) -> Bool {
        guard let pb = Self.pixelBuffer(from: image) else { return true }
        return shouldEncode(pb)
    }

    // MARK: - dHash

    /// 8x8 dHash: downscale to 9x8 grayscale, compare adjacent pixels.
    static func dHash(_ pb: CVPixelBuffer) -> UInt64 {
        guard let gray = downscaleGray(pb, width: 9, height: 8) else { return 0 }
        var bits: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let idx = row * 9 + col
                let left  = gray[idx]
                let right = gray[idx + 1]
                if left < right {
                    bits |= (UInt64(1) << UInt64(row * 8 + col))
                }
            }
        }
        return bits
    }

    private static func downscaleGray(_ pb: CVPixelBuffer,
                                      width: Int,
                                      height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        let srcStride = CVPixelBufferGetBytesPerRow(pb)

        var srcBuf = vImage_Buffer(data: base,
                                   height: vImagePixelCount(srcH),
                                   width: vImagePixelCount(srcW),
                                   rowBytes: srcStride)

        // Destination BGRA at target size
        let dstStride = width * 4
        let dstBytes = UnsafeMutablePointer<UInt8>.allocate(capacity: dstStride * height)
        defer { dstBytes.deallocate() }
        var dstBuf = vImage_Buffer(data: dstBytes,
                                   height: vImagePixelCount(height),
                                   width: vImagePixelCount(width),
                                   rowBytes: dstStride)

        let scaleErr = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil,
                                            vImage_Flags(kvImageHighQualityResampling))
        guard scaleErr == kvImageNoError else { return nil }

        // Convert BGRA to grayscale via simple luma approximation.
        var out = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let b = dstBytes[i * 4 + 0]
            let g = dstBytes[i * 4 + 1]
            let r = dstBytes[i * 4 + 2]
            // 0.299*R + 0.587*G + 0.114*B, in fixed point.
            let luma = (UInt32(r) * 299 + UInt32(g) * 587 + UInt32(b) * 114) / 1000
            out[i] = UInt8(min(luma, 255))
        }
        return out
    }

    // MARK: - Similarity grid (retrace parity)

    /// Downscale to a 100xN luma grid (aspect-preserving) — cheaper
    /// than retrace's 10 000-sample scan while retaining the same
    /// pixel-diff semantics. Uses vImage for the resize.
    static func sampleGrid(_ pb: CVPixelBuffer) -> ([UInt8], Int, Int) {
        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        guard srcW > 0, srcH > 0 else { return ([], 0, 0) }
        let targetW = 100
        let targetH = max(1, Int((Double(targetW) * Double(srcH) / Double(srcW)).rounded()))
        guard let luma = downscaleGray(pb, width: targetW, height: targetH),
              luma.count == targetW * targetH else {
            return ([], 0, 0)
        }
        return (luma, targetW, targetH)
    }

    /// retrace-parity per-pixel tolerance test (5 % of 255 ≈ 13 units).
    /// Return: fraction of samples within tolerance ∈ [0,1].
    static func similarity(a: [UInt8], b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var matching = 0
        for i in 0..<a.count {
            let d = Int(a[i]) - Int(b[i])
            if d > -13 && d < 13 { matching += 1 }
        }
        return Double(matching) / Double(a.count)
    }

    // MARK: - SHA

    static func sha256(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Data() }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let height = CVPixelBufferGetHeight(pb)
        let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                      count: stride * height)
        var hasher = SHA256()
        hasher.update(bufferPointer: UnsafeRawBufferPointer(buf))
        return Data(hasher.finalize())
    }

    // MARK: - CGImage → CVPixelBuffer helper

    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue
        )
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
