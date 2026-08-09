// Compressor.swift — HEVC encoder settings that keep `hvcC` bit-identical
// with Rewind's own output. See docs/COMPRESSION.md for measurements.
//
// The encoder path uses VideoToolbox via AVAssetWriter — this file only
// declares the profile enum and the settings dictionary the daemon feeds
// to AVAssetWriter. Concrete chunk assembly / dedup lives in
// OpenRewindCapture (which is why we keep the profile enum public).

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Compression profile a caller can request. See docs/COMPRESSION.md for
/// space / PSNR / OCR-coverage measurements per profile.
///
/// Merged 2026-07-29: `.aggressive` and `.integration` are now the SAME
/// pipeline (keyint=30, FrameDedup on, adaptive bitrate). `.aggressive`
/// stays as a Codable/UserDefaults alias so old configs still decode;
/// pick `.integration` for new callers.
public enum OpenRewindCompressionProfile: String, CaseIterable, Sendable, Codable {
    /// 1:1 with Rewind's own encoder. FrameDedup on, keyint 30, Rewind's
    /// bitrate formula, hvcC bit-identical. Use for interop / testing.
    case rewindParity

    /// Legacy alias for `.integration` — identical behaviour since
    /// 2026-07-29. Kept for back-compat with saved UserDefaults values.
    case aggressive

    /// Default. FrameDedup + adaptive bitrate + keyint 30. ~4-5× less
    /// storage than `.rewindParity` on a typical desk. Every frame
    /// crisp (unlike the old keyint=300).
    case integration

    /// Whether the daemon should skip encoding + OCR when the frame is
    /// visually identical to the previous one. All profiles opt in as
    /// of 2026-07-29 — dedup is lossless (identical frames are indexed
    /// against the last written frame; visual output is unchanged) and
    /// buys ~30-70 % on static-desk workloads for free. Keeping the
    /// property on the profile enum in case a future profile wants to
    /// opt out for some interop scenario.
    public var useFrameDedup: Bool {
        switch self {
        case .rewindParity, .aggressive, .integration: return true
        }
    }
}

/// Settings bundle a caller passes into `Compressor.videoSettings(...)`.
public struct OpenRewindCompressionSettings: Sendable {
    public let profile: OpenRewindCompressionProfile
    public let width: Int
    public let height: Int
    public let frameRate: Double
    /// True when the daemon should gate encoding on frame dedup output.
    public let useFrameDedup: Bool

    public init(profile: OpenRewindCompressionProfile,
                width: Int,
                height: Int,
                frameRate: Double) {
        self.profile = profile
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.useFrameDedup = profile.useFrameDedup
    }
}

// MARK: - Compressor

public enum OpenRewindCompressor {

    /// Build the AVAssetWriter `outputSettings` dictionary for HEVC-hvc1
    /// encoding, matching the requested profile. Starts from
    /// `AVOutputSettingsAssistant.hevc1920x1080` as the baseline preset —
    /// Rewind uses the same preset lookup — then overrides
    /// `AVVideoAverageBitRateKey` and `AVVideoMaxKeyFrameIntervalKey`.
    public static func videoSettings(for s: OpenRewindCompressionSettings) -> [String: Any] {
        // Baseline preset. Falls through to a hand-rolled dict if
        // AVOutputSettingsAssistant is unavailable (rare on macOS 13+).
        var base: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: s.width,
            AVVideoHeightKey: s.height,
        ]
        // FIX(review-2026-07-28) K-M-1: use the hevcPreset(width:height:)
        // helper so 4K sources bind to the .hevc3840x2160 preset instead of
        // silently falling through to 1080p (which would clamp bitrate on
        // Retina/external 5K displays).
        let presetKind = AVOutputSettingsAssistant.hevcPreset(
            width: s.width, height: s.height)
        if let preset = AVOutputSettingsAssistant(preset: presetKind),
           var v = preset.videoSettings {
            v[AVVideoWidthKey] = s.width
            v[AVVideoHeightKey] = s.height
            v[AVVideoCodecKey] = AVVideoCodecType.hevc
            base = v
        }

        // Compression properties overrides. Merge instead of replace so
        // preset defaults (ProfileLevel, AllowFrameReordering) stay.
        var comp: [String: Any] =
            (base[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]

        let pixels = Double(s.width * s.height)
        let fps = max(s.frameRate, 1.0)

        switch s.profile {
        case .rewindParity:
            // Rewind's own formula: w*h*fps*0.06375, keyint 30.
            // MUST stay bit-identical with Rewind's hvcC — do not touch.
            // FIX(bitrate-clamp-2026-07-28): defensively clamp the
            // computed bitrate. Rewind's formula is safe on realistic
            // inputs (2160p60 ≈ 60 Mbps) but a wild fps or 8K+ display
            // could overflow VT's Int32-encoded property. Clamp to
            // 100 Mbps — hvcC parity is unaffected because the formula
            // still produces the same value under realistic conditions.
            let raw = pixels * fps * 0.06375
            comp[AVVideoAverageBitRateKey] = Int(min(raw, 100_000_000))
            comp[AVVideoMaxKeyFrameIntervalKey] = 30
        case .aggressive, .integration:
            // FIX(adaptive-hevc): replace fixed 0.008 bpp with retrace's
            // piecewise-linear curve + density boost + laptop-class floor.
            // See CompressorAdaptive.swift and retrace HEVCEncoder.swift:252.
            let averageBitRate = OpenRewindAdaptiveTuning.adaptiveBitrate(
                width: s.width,
                height: s.height,
                frameRate: fps,
                profile: s.profile
            )
            comp[AVVideoAverageBitRateKey] = averageBitRate
            // FIX(keyint-30-2026-07-29): keyint=300 caused visible P-frame
            // decay — frame 149 of a 150-frame chunk was 149 P-frames away
            // from the last I-frame → cumulative motion-comp error → blur.
            // Retrace itself pins keyint=30 (`Shared/Protocols/
            // StorageProtocol.swift:246` "Storage guardrail: keep this
            // long for compression efficiency"). 30 is already the sane
            // maximum; 300 was over-optimisation. Space regressed ~15-20 %
            // (still 4-5× under Rewind thanks to FrameDedup + adaptive
            // bitrate); sharpness is uniform across the chunk.
            comp[AVVideoMaxKeyFrameIntervalKey] = 30

            // FIX(adaptive-hevc): bounded burst cap so I-frames stay sharp
            // without breaking the segment average budget. Retrace uses
            // `max(avg × 6/8, 128 × 1024)` bytes / 1s window.
            // See HEVCEncoder.swift:288-292 + 384-387.
            comp[kVTCompressionPropertyKey_DataRateLimits as String] =
                OpenRewindAdaptiveTuning.burstDataRateLimits(
                    averageBitRate: averageBitRate)

            // FIX(adaptive-hevc): retrace enables SpatialAdaptiveQP on
            // macOS 15+. See HEVCEncoder.swift:400-403.
            if #available(macOS 15.0, *) {
                comp[kVTCompressionPropertyKey_SpatialAdaptiveQPLevel as String] =
                    NSNumber(value: kVTQPModulationLevel_Default)
            }

            // FIX(adaptive-hevc): tell VT the source cadence so rate
            // control matches retrace's assumptions (30 fps baked in).
            comp[kVTCompressionPropertyKey_ExpectedFrameRate as String] =
                NSNumber(value: fps)
        }

        // Match Rewind's encoder profile explicitly. Keeping this here so
        // the preset can't silently drift.
        comp[AVVideoProfileLevelKey] = "HEVC_Main_AutoLevel"
        comp[AVVideoAllowFrameReorderingKey] = true

        base[AVVideoCompressionPropertiesKey] = comp
        return base
    }

    /// Retrace sets `movieFragmentInterval` on the AVAssetWriter itself,
    /// not through the settings dict. Callers should apply this to any
    /// writer that used `.aggressive` or `.integration` output settings so
    /// fragments flush every 0.1s (bounded loss on daemon crash).
    // FIX(adaptive-hevc): retrace HEVCEncoder.swift:446 — set on writer,
    // not the settings dict.
    public static let movieFragmentInterval: CMTime =
        CMTime(seconds: 0.1, preferredTimescale: 600)

    /// Convenience: return a `.mp4`-style container hint. Rewind emits
    /// `mp42/isommp41mp42/hvc1`; AVAssetWriter picks these from
    /// `.mov` file type + HEVC codec, so we return that. See docs/COMPRESSION.md.
    public static let fileType: AVFileType = .mp4
}

// MARK: - AVOutputSettingsAssistant enum shim

/// Preset lookup mirrors what Rewind uses. If Apple ever changes the
/// enum name we localise the mapping here.
private extension AVOutputSettingsAssistant {
    static func hevcPreset(width: Int, height: Int) -> AVOutputSettingsPreset {
        // Coarse bucketing — the preset only sets defaults we overwrite
        // anyway. Pick the closest resolution rung.
        if width >= 3840 { return .hevc3840x2160 }
        return .hevc1920x1080
    }
}
