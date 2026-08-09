// Chunker — batches CapturedFrames into hot PNGs, then rolls them up
// into a cold HEVC chunk. Filename format matches Rewind:
//   <vault>/temp/YYYY-MM-DDTHH:MM:SS.mmm.png
// Cold chunk path:
//   <vault>/chunks/YYYYMM/DD/<xid>.mp4
//
// Encoding delegates to OpenRewindKit's Compressor via the injected
// `ChunkEncoder` closure. This keeps FrameDedup and this file agnostic
// to Phase 1's exact API surface.

import Foundation
import CoreGraphics
import ImageIO
import Security
import UniformTypeIdentifiers

/// Called with a list of hot PNG paths + destination chunk path.
/// Must produce an HEVC .mp4 (hvcC bit-identical with Rewind).
public typealias ChunkEncoder = @Sendable (
    _ pngPaths: [URL],
    _ outMP4: URL,
    _ profile: OpenRewindCompressionProfile
) async throws -> Void

public actor Chunker {

    // Defaults chosen to match COMPRESSION.md (short GOPs, small chunks).
    public struct Config: Sendable {
        public var maxFrames: Int
        public var maxDuration: TimeInterval
        public var vaultRoot: URL
        public var profile: OpenRewindCompressionProfile
        // FIX(chunker-length-2026-07-28): retrace defaults to 300s /
        // 3000 frames (StorageConfig.segmentDurationSeconds). Longer
        // segments = less mp4 header overhead + better inter-frame
        // compression. Callers that need tighter chunks (real-time
        // analysis) pass smaller values explicitly.
                // FIX(2026-07-29): Rewind rolls chunks at 150 frames per
        // ffprobe evidence (`d9jgon1dlpe08ti8vrtg` = 150 frames /
        // 5s mp4 at 30fps timeline). Matching that means the same
        // chunk cadence and no 100-min hot-PNG backlog.
        public init(maxFrames: Int = 150,
                    maxDuration: TimeInterval = 300,
                    vaultRoot: URL,
                    profile: OpenRewindCompressionProfile = .integration) {
            self.maxFrames = maxFrames
            self.maxDuration = maxDuration
            self.vaultRoot = vaultRoot
            self.profile = profile
        }
    }

    private var config: Config
    private var encoder: ChunkEncoder?

    private var pending: [(url: URL, ts: Date)] = []
    private var batchStartedAt: Date?

    private let fs = FileManager.default
    private let ioQueue = DispatchQueue(
        label: "com.openrewind.capture.chunker", qos: .utility
    )

    /// Called when a hot PNG has been written; carries the file URL and
    /// capture timestamp. Coordinator uses this to write a frame row.
    public var onHotFrameWritten: (@Sendable (URL, Date) -> Void)?
    /// Called after an MP4 chunk is finalized. Delivers path + first/last ts.
    public var onColdChunkWritten: (@Sendable (URL, Date, Date, [URL]) -> Void)?

    public init(config: Config) {
        self.config = config
    }

    public func setEncoder(
        _ enc: @escaping @Sendable ([URL], URL, OpenRewindCompressionProfile) async throws -> Void
    ) {
        self.encoder = enc
    }

    public func setHotFrameCallback(_ cb: @Sendable @escaping (URL, Date) -> Void) {
        self.onHotFrameWritten = cb
    }

    public func setColdChunkCallback(_ cb: @Sendable @escaping (URL, Date, Date, [URL]) -> Void) {
        self.onColdChunkWritten = cb
    }

    /// Add a captured frame. Writes hot PNG on the IO queue and rolls up
    /// to cold chunk when either threshold is exceeded.
    public func ingest(_ frame: CapturedFrame) async {
        // FIX(compat-2026-07-29): match Rewind on-disk naming — bare
        // ISO8601 in `<vault>/temp/<iso>` with NO extension and NO
        // display-id prefix. Multi-display collision resolved by
        // routing extra displays through `<vault>/temp/<displayID>/`
        // subdir. Single-display users (Rewind's default) share the
        // exact same file layout as Rewind.
        let baseTemp = config.vaultRoot.appendingPathComponent("temp", isDirectory: true)
        let tempDir = frame.displayID == 1
            ? baseTemp
            : baseTemp.appendingPathComponent("\(frame.displayID)", isDirectory: true)
        do {
            try fs.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return
        }
        var name = Self.rewindFileName(from: frame.timestamp)
        var dst = tempDir.appendingPathComponent(name)
        // Sub-ms collision guard — append `-N` when the target exists.
        var suffix = 1
        while fs.fileExists(atPath: dst.path) {
            name = "\(Self.rewindFileName(from: frame.timestamp))-\(suffix)"
            dst = tempDir.appendingPathComponent(name)
            suffix += 1
            if suffix > 99 { return } // pathological — bail out
        }

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            ioQueue.async { [image = frame.image] in
                cont.resume(returning: Self.writePNG(image, to: dst))
            }
        }
        guard ok else { return }

        pending.append((dst, frame.timestamp))
        if batchStartedAt == nil { batchStartedAt = frame.timestamp }
        onHotFrameWritten?(dst, frame.timestamp)

        if shouldRollOver() {
            await flush()
        }
    }

    /// Force a rollover of any pending frames into a cold chunk.
    public func flush() async {
        // FIX(review-2026-07-28) C-4 (capture HIGH "flush no-op when
        // encoder unset leaks PNGs"): if no encoder was ever wired, the old
        // code just returned, so `pending` (and the on-disk temp PNGs) grew
        // unbounded across every hot frame. Drop the PNGs so the vault
        // doesn't fill.
        guard !pending.isEmpty else { return }
        guard let encoder = encoder else {
            for f in pending {
                try? fs.removeItem(at: f.url)
            }
            pending.removeAll(keepingCapacity: true)
            batchStartedAt = nil
            return
        }
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        batchStartedAt = nil

        let first = frames.first!.ts
        let last  = frames.last!.ts

        let month = Self.monthDir(first)
        let day   = Self.dayDir(first)
        let dir = config.vaultRoot
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
        try? fs.createDirectory(at: dir, withIntermediateDirectories: true)

        let xid = Self.xid(first)
        // FIX(review-2026-07-28) C-L: docs/ARCHITECTURE.md specifies cold
        // chunks are extension-less (`<vault>/chunks/YYYYMM/DD/<xid>`);
        // Rewind's own encoder writes them that way. The previous `.mp4`
        // suffix would trip Rewind's reconcile logic that scans for
        // extension-less xid files.
        let out = dir.appendingPathComponent(xid)

        do {
            try await encoder(frames.map(\.url), out, config.profile)
            // FIX(adaptive-hevc): retrace HEVCEncoder recreates the writer
            // when the output file was deleted mid-encode (aggressive
            // retention or manual cleanup). Our writer path is per-chunk
            // (not frame-by-frame) so the analogous check is a
            // post-encode existence verify — if the file disappeared
            // between finishWriting and here, re-run once. See
            // research/refs/retrace/Storage/VideoEncoder/HEVCEncoder.swift.
            if !fs.fileExists(atPath: out.path) {
                try await encoder(frames.map(\.url), out, config.profile)
            }
            onColdChunkWritten?(out, first, last, frames.map(\.url))
            // Remove hot PNGs — cold chunk is the source of truth now.
            for f in frames {
                try? fs.removeItem(at: f.url)
            }
        } catch {
            // FIX(stability-review-23-2026-07-29 §Encoder failure):
            // encode failed. HealthMonitor doesn't exist yet (was a
            // planned Phase 3.5 subsystem). Real risk: repeated
            // failures leave orphan PNGs eating disk until the temp
            // dir fills up.
            //
            // Pragma: log the error, then age-purge — anything under
            // <vault>/temp/ older than 30 minutes is unreachable
            // (chunker's `pending` array only holds the last 5 min of
            // frames). This bounds the leak to ~30 min × 0.5 fps ×
            // 15 MB ≈ 13.5 GB worst case, and self-heals once encoder
            // recovers.
            NSLog("openrewind-capture: chunk encode failed: %@; hot PNGs retained pending age-purge", "\(error)")
            Self.agePurgeHotFrames(root: out.deletingLastPathComponent())
        }
    }

    /// Age-purge orphan hot PNGs older than 30 minutes.
    /// Called from the encode-failure path; also called opportunistically
    /// on every chunk rollover to catch the rare crash-between-rollover
    /// case that StartupReconciler alone won't touch (files younger than
    /// its 60s cutoff at the moment of crash).
    ///
    /// FIX(temp-leak-2026-07-30): the old implementation used
    /// `skipsSubdirectoryDescendants` and only checked the top of
    /// `temp/`, missing the per-frame ISO8601 subdirectories (`temp/
    /// 2026-07-30T00:59:18.698/`) where PNGs actually live. Result: on
    /// any prolonged encoder failure the temp tree grew unbounded
    /// (measured at 1.4 GB after one day). Walk recursively now.
    private static func agePurgeHotFrames(root chunkDir: URL) {
        let vault = chunkDir.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temp = vault.appendingPathComponent("temp")
        let fs = FileManager.default
        guard let en = fs.enumerator(
            at: temp,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 60)
        var purged = 0
        for case let u as URL in en {
            let vals = try? u.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true,
                  let mtime = vals?.contentModificationDate,
                  mtime < cutoff else { continue }
            try? fs.removeItem(at: u)
            purged += 1
        }
        if purged > 0 {
            NSLog("openrewind-capture: age-purge removed %d orphan hot PNGs older than 30m", purged)
            // After deleting PNGs the ISO8601 per-frame dirs are
            // usually empty — collapse them so we don't leave
            // thousands of stale directory entries either.
            if let dirs = try? fs.contentsOfDirectory(
                at: temp,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) {
                for d in dirs {
                    if (try? fs.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
                        try? fs.removeItem(at: d)
                    }
                }
            }
        }
    }

    private func shouldRollOver() -> Bool {
        guard let start = batchStartedAt else { return false }
        if pending.count >= config.maxFrames { return true }
        if Date().timeIntervalSince(start) >= config.maxDuration { return true }
        return false
    }

    // MARK: - Naming helpers

    // Cached formatters — instantiating a DateFormatter costs ~100μs
    // and we're called every frame (0.5 fps × 24h = 43k allocations).
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMM"
        return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd"
        return f
    }()

    /// Rewind's exact ISO-with-ms format: `YYYY-MM-DDTHH:MM:SS.mmm`
    public static func rewindFileName(from date: Date) -> String {
        isoFmt.string(from: date)
    }
    private static func monthDir(_ date: Date) -> String { monthFmt.string(from: date) }
    private static func dayDir(_ date: Date) -> String { dayFmt.string(from: date) }

    // rs/xid generator state (github.com/rs/xid).
    // 12 bytes: 4 B UNIX seconds BE ‖ 3 B machine ‖ 2 B pid ‖ 3 B counter.
    // Encoded as 20-char lowercase base32hex.
    private static let xidMachineID: [UInt8] = {
        var mid = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, 3, &mid)
        return mid
    }()
    private static let xidPidBytes: [UInt8] = {
        let pid = UInt16(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier)
        return [UInt8(pid >> 8), UInt8(pid & 0xFF)]
    }()
    private static let xidCounter: ManagedAtomicWrapper = {
        var seed = UInt32(0)
        var buf = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, 3, &buf)
        seed = UInt32(buf[0]) << 16 | UInt32(buf[1]) << 8 | UInt32(buf[2])
        return ManagedAtomicWrapper(seed & 0xFFFFFF)
    }()

    private static let xidAlphabet: [Character] = Array(
        "0123456789abcdefghijklmnopqrstuv")

    /// rs/xid 20-char base32hex identifier — matches Rewind's chunk
    /// filename + video.xid format exactly.
    static func xid(_ date: Date) -> String {
        let seconds = UInt32(date.timeIntervalSince1970)
        let counter = xidCounter.increment() & 0xFFFFFF
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = UInt8((seconds >> 24) & 0xFF)
        bytes[1] = UInt8((seconds >> 16) & 0xFF)
        bytes[2] = UInt8((seconds >> 8) & 0xFF)
        bytes[3] = UInt8(seconds & 0xFF)
        bytes[4] = xidMachineID[0]; bytes[5] = xidMachineID[1]; bytes[6] = xidMachineID[2]
        bytes[7] = xidPidBytes[0]; bytes[8] = xidPidBytes[1]
        bytes[9]  = UInt8((counter >> 16) & 0xFF)
        bytes[10] = UInt8((counter >> 8) & 0xFF)
        bytes[11] = UInt8(counter & 0xFF)
        // base32hex 12B → 20 chars.
        var out = [Character]()
        out.reserveCapacity(20)
        // Standard rs/xid encoding (branch-free, from Go reference).
        out.append(xidAlphabet[Int(bytes[0] >> 3)])
        out.append(xidAlphabet[Int((bytes[1] >> 6) | (bytes[0] << 2) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[1] >> 1) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[2] >> 4) | (bytes[1] << 4) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[3] >> 7) | (bytes[2] << 1) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[3] >> 2) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[4] >> 5) | (bytes[3] << 3) & 0x1F)])
        out.append(xidAlphabet[Int(bytes[4] & 0x1F)])
        out.append(xidAlphabet[Int(bytes[5] >> 3)])
        out.append(xidAlphabet[Int((bytes[6] >> 6) | (bytes[5] << 2) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[6] >> 1) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[7] >> 4) | (bytes[6] << 4) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[8] >> 7) | (bytes[7] << 1) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[8] >> 2) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[9] >> 5) | (bytes[8] << 3) & 0x1F)])
        out.append(xidAlphabet[Int(bytes[9] & 0x1F)])
        out.append(xidAlphabet[Int(bytes[10] >> 3)])
        out.append(xidAlphabet[Int((bytes[11] >> 6) | (bytes[10] << 2) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[11] >> 1) & 0x1F)])
        out.append(xidAlphabet[Int((bytes[11] << 4) & 0x1F)])
        return String(out)
    }

    /// Minimal atomic uint counter — Chunker is class-serial, but xid()
    /// can be called from encoder queue. Use OSAtomicIncrement32 alt.
    private final class ManagedAtomicWrapper: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt32
        init(_ v: UInt32) { self.value = v }
        func increment() -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            value = (value &+ 1) & 0xFFFFFF
            return value
        }
    }

    // NOTE: The on-disk file keeps a `.png` extension for backwards
    // compatibility with downstream code (EncoderAdapter, RetentionManager,
    // etc.) that greps or constructs paths by extension. The BYTES inside
    // are JPEG-encoded (quality 0.85) because PNG is 5-10x larger and
    // slower to write, and disk pressure was flagged as a HIGH capture
    // issue. CGImageSourceCreateWithURL sniffs the actual file magic, so
    // the HEVC encoder and any other consumer decodes transparently. If
    // you change the encoded format here, keep the extension mismatch
    // deliberate or update every call site.
    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(dst, image, options as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }
}
