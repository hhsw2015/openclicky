// EncoderAdapter.swift — turns a list of hot PNGs into a single HEVC .mp4
// using OpenRewindKit.OpenRewindCompressor's videoSettings (bit-identical
// hvcC with Rewind). Fed to Chunker via a `ChunkEncoder` closure.

import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum EncoderAdapter {

    /// Fixed cine timescale (matches Rewind).
    static let timescale: Int32 = 600
    /// Playback FPS baked into the chunk (real capture cadence varies).
    static let playbackFPS: Double = 30.0

    /// Cached mtime + parsed profile from config.yaml. Only re-parses
    /// when the file's mtime advances; a stat() per chunk close is
    /// cheap while JSON parse per chunk would be silly.
    private final class ConfigCache: @unchecked Sendable {
        private let lock = NSLock()
        private var lastMtime: Date?
        private var cached: KitProfile?
        func profile(vaultRoot: URL, fallback: KitProfile) -> KitProfile {
            let url = vaultRoot.appendingPathComponent("config.yaml")
            let mtime = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            lock.lock(); defer { lock.unlock() }
            if mtime == lastMtime, let c = cached { return c }
            lastMtime = mtime
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let raw = dict["compression.profile"],
               let p = KitProfile(rawValue: raw) {
                cached = p
                return p
            }
            cached = fallback
            return fallback
        }
    }

    static func makeChunkEncoder(profile: KitProfile, vaultRoot: URL)
        -> ChunkEncoder {
        let cache = ConfigCache()
        // FIX(perf-2026-08-01 CRITICAL): encode() contains blocking
        // Thread.sleep + DispatchSemaphore.wait. Running it on the
        // Chunker actor executor pins that executor for 100-500 ms per
        // chunk flush; other actor callers back up → CaptureCoordinator
        // ingest actor stalls → main-thread hops queue up → the
        // "偶乎卡住" cursor freeze. Hop encode work onto a dedicated
        // detached background thread so no actor executor blocks.
        return { pngPaths, outMP4, capProfile in
            let live = cache.profile(vaultRoot: vaultRoot, fallback: profile)
            let kitProfile = Self.kitProfile(from: capProfile) ?? live
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .background).async {
                    do {
                        try Self.encode(pngPaths: pngPaths, out: outMP4, profile: kitProfile)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func kitProfile(
        from cap: CapProfile
    ) -> KitProfile? {
        switch cap {
        case .rewindParity: return .rewindParity
        // Merged 2026-07-29: `.aggressive` from a saved profile now
        // routes to `.integration` (identical pipeline). Kept for
        // UserDefaults back-compat.
        case .aggressive:   return .integration
        case .integration:  return .integration
        }
    }

    // MARK: - Encode

    static func encode(pngPaths: [URL],
                       out: URL,
                       profile: KitProfile) throws {
        guard !pngPaths.isEmpty else { return }

        // 1. Discover source dimensions from the first PNG.
        let firstImage = try loadPNG(pngPaths[0])
        let width  = firstImage.width
        let height = firstImage.height

        // 2. Compressor settings from Kit.
        let settings = OpenRewindCompressionSettings(
            profile: profile,
            width: width,
            height: height,
            frameRate: playbackFPS
        )
        let outputSettings = OpenRewindCompressor.videoSettings(for: settings)

        // 3. AVAssetWriter — hvc1 in .mp4 container.
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out,
                                       fileType: OpenRewindCompressor.fileType)
        writer.shouldOptimizeForNetworkUse = false
        // FIX(adaptive-hevc): retrace HEVCEncoder.swift:446 — set on the
        // writer, not the settings dict. Only meaningful for the
        // adaptive-tuned profiles; rewindParity stays 30-frame keyframes
        // so a 0.1s fragment interval is harmless.
        if profile != .rewindParity {
            writer.movieFragmentInterval = OpenRewindCompressor.movieFragmentInterval
        }
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            // FIX(rewind-ida-#8-2026-07-31): explicit pool size 4.
            // Rewind's HEVC settings dict (sub_100540140, symbol
            // `CVPixelBufferPoolSize` at 0x100e99ac0) preallocates a
            // small pool instead of malloc'ing per frame. Cuts the
            // allocator hot path during chunk flush. 4 = ~2× the
            // in-flight adaptor.append budget for AV writer.
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pbAttrs
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "EncoderAdapter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "writer cannot add input"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "EncoderAdapter", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
        }
        writer.startSession(atSourceTime: .zero)

        // 4. Feed frames at uniform playbackFPS pacing.
        let ptsInc = Int64(Double(timescale) / playbackFPS)
        for (i, url) in pngPaths.enumerated() {
            while !input.isReadyForMoreMediaData {
                // FIX(Agent-G-2026-07-31): raise cadence from 5ms to
                // 20ms. Encoder input readiness flips at ~30-60 Hz;
                // 5ms polling burns 3-8ms of idle CPU per stall while
                // adding no responsiveness. Outer wrapper already runs
                // on DispatchQueue.global(.background) so blocking
                // here is safe. Full async conversion via
                // requestMediaDataWhenReady deferred.
                Thread.sleep(forTimeInterval: 0.020)
            }
            let image: CGImage
            do {
                image = try loadPNG(url)
            } catch {
                logError("skip PNG \(url.lastPathComponent): \(error)")
                continue
            }
            // FIX(retrace-#6-2026-07-31): reuse the adaptor's
            // pixelBufferPool so per-frame BGRA allocation is a
            // cheap pool checkout, not a fresh CVPixelBufferCreate.
            // Prevents `mach_vm_allocate 0x4` under sustained 24h
            // capture. retrace/Storage/VideoEncoder/FrameConverter
            // .swift:39-60 uses the same pattern.
            guard let pb = makeBGRA(image: image,
                                     width: width, height: height,
                                     pool: adaptor.pixelBufferPool) else {
                logError("BGRA conversion failed for \(url.lastPathComponent)")
                continue
            }
            let pts = CMTime(value: Int64(i) * ptsInc, timescale: timescale)
            if !adaptor.append(pb, withPresentationTime: pts) {
                logError("adaptor.append failed at \(i): \(writer.error?.localizedDescription ?? "?")")
            }
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if let err = writer.error {
            throw err
        }
    }

    // MARK: - Utilities

    private static func loadPNG(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "EncoderAdapter", code: -10,
                userInfo: [NSLocalizedDescriptionKey: "cannot decode \(url.path)"])
        }
        return img
    }

    static func makeBGRA(image: CGImage, width: Int, height: Int,
                         pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        var pbOpt: CVPixelBuffer?
        // FIX(retrace-#6-2026-07-31): prefer adaptor's pool. Falls back
        // to fresh allocation for callers without a pool (still safe).
        if let pool = pool {
            let s = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
            if s != kCVReturnSuccess { pbOpt = nil }
        }
        if pbOpt == nil {
            let attrs = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, attrs, &pbOpt)
            guard status == kCVReturnSuccess else { return nil }
        }
        guard let pb = pbOpt else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}
