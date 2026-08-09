// CompressorAdaptive.swift — adaptive HEVC bitrate tuning ported from
// retrace (MIT). Retrace-original source lives at
//   research/refs/retrace/Storage/VideoEncoder/HEVCEncoder.swift
// Retrace itself is MIT-licensed. See docs/COMPRESSION.md for the
// measurement rationale. This file ports:
//   • base screen-content bpppf curve (5 anchor points, 0.018 → 0.085)
//   • sqrt-based screen-content density boost
//   • targeted low-resolution display bitrate floor
//   • bounded burst-cap for kVTCompressionPropertyKey_DataRateLimits
//
// FIX(adaptive-hevc): full port from retrace HEVCEncoder.swift:252-301,
//                     739-809. Kept in a dedicated file so `.rewindParity`
//                     in Compressor.swift stays bit-identical with Rewind
//                     while `.aggressive` / `.integration` opt in.

import Foundation
import VideoToolbox

public enum OpenRewindAdaptiveTuning {

    // MARK: - Retrace constants (mirror HEVCEncoder.swift:220-225)

    /// Retrace's reference display: the internal panel on a 14-inch M-series
    /// MacBook Pro. Everything above this is scaled sublinearly, everything
    /// below (that looks like a laptop panel) gets floored.
    // FIX(adaptive-hevc): HEVCEncoder.swift:221
    static let referencePixelCount: Double = 3024.0 * 1964.0

    /// Retrace bakes 30 fps into its bitrate math regardless of capture
    /// cadence. See HEVCEncoder.swift:220.
    // FIX(adaptive-hevc): HEVCEncoder.swift:220
    public static let expectedSourceFrameRate: Double = 30

    // FIX(adaptive-hevc): HEVCEncoder.swift:222-225
    static let minimumFlooredDisplayWidth: Int  = 1024
    static let minimumFlooredDisplayHeight: Int = 665
    static let maximumFlooredDisplayWidth: Int  = 2200
    static let maximumFlooredDisplayHeight: Int = 1250

    // MARK: - Base curve (retrace anchor points)

    /// Retrace's 5-anchor piecewise-linear map from `quality ∈ [0, 1]` to
    /// base bits-per-pixel-per-frame.
    // FIX(adaptive-hevc): HEVCEncoder.swift:739-750
    public static func baseScreenContentBitsPerPixelPerFrame(quality: Double) -> Double {
        interpolate(
            clampedQuality: quality,
            points: [
                (0.00, 0.018),
                (0.25, 0.032),
                (0.50, 0.055),
                (0.75, 0.070),
                (1.00, 0.085),
            ]
        )
    }

    // MARK: - Density boost

    /// Sublinear compensation for non-reference displays. Big screens are
    /// scaled DOWN (sqrt of the pixel ratio); small dense laptop panels
    /// clamp at 1.0-1.8. Retrace clamps 5K down to ~14 Mbps this way.
    // FIX(adaptive-hevc): HEVCEncoder.swift:752-777
    public static func screenContentDensityBoost(
        width: Int, height: Int
    ) -> Double {
        let pixelCount = max(Double(width) * Double(height), 1.0)
        guard pixelCount > 0 else { return 1.0 }
        let densityRatio = (referencePixelCount / pixelCount).squareRoot()

        if pixelCount >= referencePixelCount {
            // Above reference: sqrt-scaled down so 5K captures land at
            // ~13-14 Mbps instead of full linear pixel-count penalty.
            return densityRatio
        }

        // Below reference: small laptop-class displays get a fuller boost,
        // but arbitrary small surfaces (windows) are bounded to 1.8×.
        if shouldApplyLowResolutionDisplayFloor(
            width: width, height: height, pixelCount: pixelCount
        ) {
            return Swift.max(densityRatio, 1.0)
        }
        return Swift.min(Swift.max(densityRatio, 1.0), 1.8)
    }

    // MARK: - Low-resolution display floor

    /// For laptop-class displays smaller than reference, floor the bit rate
    /// at what the reference display would use at this quality. Returns
    /// nil when the target isn't a laptop-class display.
    // FIX(adaptive-hevc): HEVCEncoder.swift:779-796
    public static func targetedLowResolutionDisplayBitrateFloor(
        width: Int, height: Int, quality: Double
    ) -> Int? {
        let pixelCount = Double(width) * Double(height)
        guard shouldApplyLowResolutionDisplayFloor(
            width: width, height: height, pixelCount: pixelCount
        ) else {
            return nil
        }
        let bpp = baseScreenContentBitsPerPixelPerFrame(quality: quality)
        let native = bpp * referencePixelCount * expectedSourceFrameRate
        return Int(native.rounded())
    }

    /// Absolute minimum bit rate — retrace's `750_000` guardrail so a
    /// captured browser tab or tiny window doesn't emit a 60 kbps chunk.
    // FIX(adaptive-hevc): HEVCEncoder.swift:281 (`750_000` literal)
    public static func lowResolutionBitrateFloor(width: Int, height: Int) -> Int {
        return 750_000
    }

    // MARK: - Adaptive bit rate

    /// Full replacement for the fixed `pixels × fps × 0.008` formula on
    /// `.aggressive` / `.integration`. Uses retrace's math so 4K/5K
    /// captures stay reasonable and 800×600 windows don't starve.
    // FIX(adaptive-hevc): HEVCEncoder.swift:252-301
    public static func adaptiveBitrate(
        width: Int,
        height: Int,
        frameRate: Double,
        profile: OpenRewindCompressionProfile
    ) -> Int {
        // Retrace's `config.quality` for continuous screen capture lands
        // near the low end of the curve; `.aggressive` picks the aggressive
        // floor (0.0 → 0.018 bpppf). `.integration` shares the same curve
        // because dedup is orthogonal to the quality axis. `.rewindParity`
        // never uses this path — Compressor.swift still owns that formula.
        let quality: Double
        switch profile {
        case .aggressive, .integration: quality = 0.0
        case .rewindParity:             quality = 0.0 // unused; kept for exhaustiveness
        }

        let pixelCount = Double(width) * Double(height)
        let fps = Swift.max(frameRate, 1.0)

        let baseBpp = baseScreenContentBitsPerPixelPerFrame(quality: quality)
        let boost = screenContentDensityBoost(width: width, height: height)
        let effectiveBpp = baseBpp * boost

        // FIX(bitrate-clamp-2026-07-28): symmetric ceiling with
        // Compressor.rewindParity — 100 Mbps hard cap so unrealistic
        // width×height×fps inputs can't overflow VT.
        let raw = (effectiveBpp * pixelCount * fps).rounded()
        let derived = Int(Swift.min(raw, 100_000_000))
        let displayFloor = targetedLowResolutionDisplayBitrateFloor(
            width: width, height: height, quality: quality) ?? 0
        let absoluteFloor = lowResolutionBitrateFloor(width: width, height: height)

        return Swift.max(derived, displayFloor, absoluteFloor)
    }

    // MARK: - Burst cap

    /// Retrace's `kVTCompressionPropertyKey_DataRateLimits` value:
    ///   `max(Int((avg × 6.0 / 8.0).rounded()), 128 × 1024)` bytes / 1 s.
    /// The `1` window sits at index [1] because VT expects `[bytes, seconds]`
    /// pairs, and retrace uses a single 1-second window.
    // FIX(adaptive-hevc): HEVCEncoder.swift:288-292 (+ VT usage at 384-387)
    public static func burstDataRateLimits(averageBitRate: Int) -> [Any] {
        let bytesPerSecond = Swift.max(
            Int((Double(averageBitRate) * 6.0 / 8.0).rounded()),
            128 * 1024
        )
        // NSNumber wrapping to match how VideoToolbox reads the CFArray.
        return [NSNumber(value: bytesPerSecond), NSNumber(value: 1)]
    }

    // MARK: - Internals

    // FIX(adaptive-hevc): HEVCEncoder.swift:798-809
    static func shouldApplyLowResolutionDisplayFloor(
        width: Int, height: Int, pixelCount: Double
    ) -> Bool {
        guard pixelCount < referencePixelCount else { return false }
        guard width  >= minimumFlooredDisplayWidth,
              width  <= maximumFlooredDisplayWidth else { return false }
        guard height >= minimumFlooredDisplayHeight,
              height <= maximumFlooredDisplayHeight else { return false }
        let aspect = Double(width) / Double(Swift.max(height, 1))
        return aspect >= 1.5 && aspect <= 2.2
    }

    // FIX(adaptive-hevc): HEVCEncoder.swift:811-835
    static func interpolate(
        clampedQuality: Double,
        points: [(quality: Double, bpppf: Double)]
    ) -> Double {
        let q = Swift.min(Swift.max(clampedQuality, 0.0), 1.0)
        guard let first = points.first else { return 0.0 }
        guard let last  = points.last  else { return first.bpppf }
        if q <= first.quality { return first.bpppf }
        for i in 0..<(points.count - 1) {
            let lo = points[i]
            let hi = points[i + 1]
            guard q <= hi.quality else { continue }
            let span = hi.quality - lo.quality
            guard span > 0 else { return hi.bpppf }
            let t = (q - lo.quality) / span
            return lo.bpppf + t * (hi.bpppf - lo.bpppf)
        }
        return last.bpppf
    }
}

// MARK: - Hardware verification

public enum OpenRewindEncoderProbe {

    public struct EncoderEntry: Sendable {
        public let codecName: String
        public let codecType: UInt32
        public let encoderName: String
        public let isHardwareAccelerated: Bool
    }

    /// Walk VTCopyVideoEncoderList and return every encoder VideoToolbox
    /// currently advertises. Cheap; safe to call at daemon boot. The
    /// daemon should log a warning if no HW HEVC entry appears, but keep
    /// running — the SW encoder still emits valid hvcC.
    // FIX(adaptive-hevc): HEVCEncoder.swift:303-322 (VT encoder probe)
    public static func availableHEVCEncoders() -> [EncoderEntry] {
        var listRef: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listRef)
        guard status == noErr, let list = listRef as? [[String: Any]] else {
            return []
        }
        let hevcCodec = kCMVideoCodecType_HEVC
        var out: [EncoderEntry] = []
        for entry in list {
            let ct = (entry[kVTVideoEncoderList_CodecType as String] as? UInt32) ?? 0
            guard ct == hevcCodec else { continue }
            let codecName = (entry[kVTVideoEncoderList_CodecName as String]
                             as? String) ?? "HEVC"
            let encoderName = (entry[kVTVideoEncoderList_EncoderName as String]
                               as? String) ?? "?"
            let hw = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String]
                      as? Bool) ?? false
            out.append(EncoderEntry(
                codecName: codecName,
                codecType: ct,
                encoderName: encoderName,
                isHardwareAccelerated: hw
            ))
        }
        return out
    }

    /// True if any registered HEVC encoder claims hardware acceleration.
    public static func hasHardwareHEVC() -> Bool {
        availableHEVCEncoders().contains { $0.isHardwareAccelerated }
    }
}
