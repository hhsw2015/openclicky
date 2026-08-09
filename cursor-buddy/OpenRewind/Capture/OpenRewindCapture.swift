// OpenRewindCapture — Phase 2 module entry.
// Wires ScreenCaptureKit + AX + CGEventTap + AVAudioEngine into
// OpenRewindKit's Writer. See docs/ARCHITECTURE.md.

import Foundation
import CoreGraphics

#if canImport(OpenRewindKit)
#endif

/// Namespace + version marker for the capture library.
public enum OpenRewindCapture {
    public static let version = "0.2.0"
}

// MARK: - Compression profile
//
// Previously defined here as a standalone fallback. Removed in the
// OpenClicky embed since Kit's canonical definition is now visible in
// the same target. Callers just use `OpenRewindCompressionProfile`
// from Kit/Compressor.swift.

// MARK: - Writer protocol (used until Phase 1 lands the concrete type)
//
// The coordinator depends on this protocol so the target compiles
// against either the real `OpenRewindWriter` struct or a local stub.
public protocol OpenRewindWriting: AnyObject {
    func insertSegment(startedAt: Date,
                       endedAt: Date,
                       app: String?,
                       title: String?,
                       url: String?) throws -> Int64
    // FIX(review-2026-07-28) C-2: coordinator must be able to close the
    // open segment at shutdown so the DB doesn't carry a bogus far-future
    // endDate. Implementations bridge to `OpenRewindWriter.updateSegmentEnd`.
    func updateSegmentEnd(id: Int64, endedAt: Date) throws
    func insertVideo(chunkPath: String,
                     startedAt: Date,
                     endedAt: Date,
                     durationMs: Int64) throws -> Int64
    func insertFrame(segmentId: Int64,
                     videoId: Int64?,
                     frameIndex: Int64,
                     capturedAt: Date,
                     tempPath: String?) throws -> Int64
    /// FIX(capture-trigger-2026-07-29): retrace V17. Optional so hosts
    /// on the old protocol still compile; adapter routes into
    /// `OpenRewindFrameInput.captureTrigger`.
    func insertFrame(segmentId: Int64,
                     videoId: Int64?,
                     frameIndex: Int64,
                     capturedAt: Date,
                     tempPath: String?,
                     captureTrigger: String?) throws -> Int64
    /// Backfill videoId + videoFrameIndex on a frame that was inserted
    /// while the enclosing chunk was still open. Mirrors retrace's
    /// FrameQueries.updateVideoLink.
    func updateFrameVideoLink(frameId: Int64,
                              videoId: Int64,
                              videoFrameIndex: Int) throws
    /// Persist a single transcribed word.
    /// FIX(audio-source-2026-07-31): added `audioSource` — route hint
    /// (mic / system / chat / voice / "") so downstream ranking can
    /// weight or filter by origin.
    func insertTranscriptWord(segmentId: Int64,
                              word: String,
                              startTime: Double,
                              endTime: Double,
                              fullTextOffset: Int?,
                              speakerId: Int64?,
                              audioSource: String?) throws -> Int64
    /// Newest frame id in a segment (for AX/audio fallback).
    func latestFrameId(inSegment segmentId: Int64) throws -> Int64?
    func insertOCR(frameId: Int64,
                   segmentId: Int64,
                   text: String,
                   otherText: String?,
                   title: String?,
                   nodes: [OCRNode]) throws
    func insertEvent(type: String,
                     status: String,
                     capturedAt: Date,
                     app: String?,
                     meta: [String: String]) throws
    func markFrameProcessed(frameId: Int64, type: String) throws
    /// Persist an audio segment row so downstream tools can locate the
    /// m4a on disk without walking the vault. See retrace `audio` table.
    /// Optional to remain source-compatible with pre-2026-07-29 hosts.
    func insertAudio(segmentId: Int64,
                     path: String,
                     startTime: Date,
                     duration: Double) throws -> Int64
    /// FIX(root-cause-2026-07-30): backfill videoId for every pending
    /// frame whose createdAt falls in a chunk's [startedAt, endedAt]
    /// window. Belt-and-braces backup for the in-memory
    /// `pendingFrameLinks` list which gets wiped on process restart.
    /// Optional so old adapters still compile.
    @discardableResult
    func linkPendingFramesToVideo(videoId: Int64,
                                  startedAt: Date,
                                  endedAt: Date) throws -> Int
    /// FIX(retrace-#7-2026-07-31): stamp redactionReason on a frame.
    /// Optional so old adapters compile without change.
    @discardableResult
    func stampRedactionReason(frameId: Int64, reason: String) throws -> Int
}

public extension OpenRewindWriting {
    /// Default no-op so old adapters compile. Real implementations
    /// (Daemon's `OpenRewindWritingAdapter`) override.
    func insertAudio(segmentId: Int64, path: String,
                     startTime: Date, duration: Double) throws -> Int64 {
        return 0
    }
    /// Default: forward to the legacy 5-arg insertFrame ignoring trigger.
    /// Overrides emit the new column when the schema has it.
    func insertFrame(segmentId: Int64, videoId: Int64?,
                     frameIndex: Int64, capturedAt: Date,
                     tempPath: String?, captureTrigger: String?) throws -> Int64 {
        return try insertFrame(segmentId: segmentId,
                               videoId: videoId,
                               frameIndex: frameIndex,
                               capturedAt: capturedAt,
                               tempPath: tempPath)
    }
}

/// One OCR/AX node payload — matches Rewind's `searchRanking.node` slot.
public struct OCRNode: Sendable, Equatable {
    public var text: String
    public var bbox: CGRect   // normalized 0…1
    public var role: String?
    public init(text: String, bbox: CGRect, role: String? = nil) {
        self.text = text
        self.bbox = bbox
        self.role = role
    }
}

// MARK: - Shared capture types

/// A single captured frame emitted from `ScreenCapture`.
public struct CapturedFrame: @unchecked Sendable {
    public let image: CGImage
    public let timestamp: Date
    public let displayID: CGDirectDisplayID
    public let windowInfo: WindowInfo?
    public init(image: CGImage,
                timestamp: Date,
                displayID: CGDirectDisplayID,
                windowInfo: WindowInfo?) {
        self.image = image
        self.timestamp = timestamp
        self.displayID = displayID
        self.windowInfo = windowInfo
    }
}

/// Frontmost window snapshot (title + owning app + optional URL).
public struct WindowInfo: Sendable, Equatable {
    public var app: String?
    public var title: String?
    public var bundleID: String?
    public var url: String?
    public init(app: String? = nil, title: String? = nil,
                bundleID: String? = nil, url: String? = nil) {
        self.app = app
        self.title = title
        self.bundleID = bundleID
        self.url = url
    }
}

/// One AX text node emitted by `AXCapture`.
public struct AXNode: Sendable, Equatable {
    public var text: String
    public var bbox: CGRect     // in the frontmost window's local coords, normalized 0…1
    public var role: String
    public init(text: String, bbox: CGRect, role: String) {
        self.text = text
        self.bbox = bbox
        self.role = role
    }
}

/// AX tree walk result for the frontmost window.
public struct AXSnapshot: Sendable {
    public var timestamp: Date
    public var window: WindowInfo
    public var nodes: [AXNode]
    public init(timestamp: Date, window: WindowInfo, nodes: [AXNode]) {
        self.timestamp = timestamp
        self.window = window
        self.nodes = nodes
    }
}

/// UI event emitted by `UIEventsMonitor`.
public struct UIEvent: Sendable {
    public enum Kind: String, Sendable {
        case keyDown, keyUp, mouseDown, mouseUp, scroll, appSwitch
    }
    public let kind: Kind
    public let timestamp: Date
    public let app: String?
    public let meta: [String: String]
    public init(kind: Kind, timestamp: Date, app: String?, meta: [String: String] = [:]) {
        self.kind = kind
        self.timestamp = timestamp
        self.app = app
        self.meta = meta
    }
}
