// OpenRewindReading.swift — the read-side contract MCP tools depend on.
//
// Design note: OpenRewindKit's Reader is being reshaped in parallel with
// this target (Phase 1 vs Phase 4). To keep OpenRewindMCP buildable on its
// own, the tools depend ONLY on this protocol and the small value types
// declared here. Kit will later provide an adapter that conforms its
// `OpenRewindReader` to `OpenRewindReading`; until then the executable
// runs against `StubReader`, which returns empty/placeholder data so
// stdio wiring, framing, and schema surface can be exercised end-to-end.
//
// All types are Sendable so tool handlers can safely hop actors.

import Foundation

// MARK: - Value types (MCP wire-shaped, protocol-owned)

public struct MCPFrame: Sendable {
    public let frameId: Int64
    public let createdAt: Date
    public let bundleID: String?
    public let windowName: String?
    public let browserUrl: String?
    public let videoId: Int64?
    public let videoFrameIndex: Int?

    public init(frameId: Int64,
                createdAt: Date,
                bundleID: String?,
                windowName: String?,
                browserUrl: String?,
                videoId: Int64?,
                videoFrameIndex: Int?) {
        self.frameId = frameId
        self.createdAt = createdAt
        self.bundleID = bundleID
        self.windowName = windowName
        self.browserUrl = browserUrl
        self.videoId = videoId
        self.videoFrameIndex = videoFrameIndex
    }
}

public struct MCPSearchHit: Sendable {
    public let frame: MCPFrame
    public let snippet: String
    public init(frame: MCPFrame, snippet: String) {
        self.frame = frame; self.snippet = snippet
    }
}

public struct MCPOCRNode: Sendable {
    public let text: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.x = x; self.y = y
        self.width = width; self.height = height
    }
}

public struct MCPFrameDetail: Sendable {
    public let frame: MCPFrame
    public let ocrText: String
    public let nodes: [MCPOCRNode]
    public init(frame: MCPFrame, ocrText: String, nodes: [MCPOCRNode]) {
        self.frame = frame; self.ocrText = ocrText; self.nodes = nodes
    }
}

public struct MCPRecentApp: Sendable {
    public let bundleID: String
    public let count: Int
    public init(bundleID: String, count: Int) {
        self.bundleID = bundleID; self.count = count
    }
}

public struct MCPAIContext: Sendable {
    public let center: MCPFrame
    public let neighbors: [MCPFrame]
    public let recentApps: [MCPRecentApp]
    public let transcriptSnippet: String?
    public init(center: MCPFrame,
                neighbors: [MCPFrame],
                recentApps: [MCPRecentApp],
                transcriptSnippet: String?) {
        self.center = center
        self.neighbors = neighbors
        self.recentApps = recentApps
        self.transcriptSnippet = transcriptSnippet
    }
}

public struct MCPAppMinutes: Sendable {
    public let bundleID: String
    public let minutes: Double
    public init(bundleID: String, minutes: Double) {
        self.bundleID = bundleID; self.minutes = minutes
    }
}

public struct MCPMeeting: Sendable {
    public let app: String
    public let title: String?
    public let start: Date
    public let end: Date
    public init(app: String, title: String?, start: Date, end: Date) {
        self.app = app; self.title = title
        self.start = start; self.end = end
    }
}

public struct MCPDailySummary: Sendable {
    public let summary: String
    public let apps: [MCPAppMinutes]
    public let keywords: [String]
    public let meetings: [MCPMeeting]
    public init(summary: String,
                apps: [MCPAppMinutes],
                keywords: [String],
                meetings: [MCPMeeting]) {
        self.summary = summary; self.apps = apps
        self.keywords = keywords; self.meetings = meetings
    }
}

// MARK: - Protocol

/// The read surface the MCP server needs. Kept intentionally narrow so
/// Kit's Reader can be swapped for a mock in tests without pulling in
/// SQLCipher / AVFoundation. All methods must be safe to call from a
/// concurrent context; the concrete `OpenRewindKitReader` adapter (added
/// once Kit stabilises) will delegate to a serial queue internally.
public protocol OpenRewindReading: Sendable {
    func search(query: String,
                from: Date?,
                to: Date?,
                limit: Int) async throws -> [MCPSearchHit]

    func timeline(from: Date,
                  to: Date,
                  limit: Int) async throws -> [MCPFrame]

    func aiContext(around timestamp: Date,
                   neighborhood: Int) async throws -> MCPAIContext

    func frame(id: Int64,
               includeThumbnail: Bool) async throws -> (detail: MCPFrameDetail,
                                                        thumbnailBase64: String?)

    func summary(for date: Date) async throws -> MCPDailySummary

    /// Optional thumbnail rendering (base-64 JPEG) for a frame. Returns
    /// nil when the reader can't or shouldn't render.
    func thumbnail(for frameId: Int64) async throws -> String?
}

// MARK: - Stub

/// Default reader used when OpenRewindKit isn't wired yet. Returns
/// empty arrays and a single synthetic placeholder frame so the JSON-RPC
/// surface is exercisable end-to-end. Once Kit's `OpenRewindReader`
/// stabilises, add a `OpenRewindKitReader` adapter and select at boot.
///
/// TODO(phase-1): replace `StubReader` with a Kit-backed adapter.
public struct StubReader: OpenRewindReading {
    public init() {}

    private func placeholder(id: Int64 = 0, at date: Date = Date()) -> MCPFrame {
        MCPFrame(frameId: id, createdAt: date,
                 bundleID: nil, windowName: nil, browserUrl: nil,
                 videoId: nil, videoFrameIndex: nil)
    }

    public func search(query: String, from: Date?, to: Date?, limit: Int)
        async throws -> [MCPSearchHit] { [] }

    public func timeline(from: Date, to: Date, limit: Int)
        async throws -> [MCPFrame] { [] }

    public func aiContext(around timestamp: Date, neighborhood: Int)
        async throws -> MCPAIContext {
        MCPAIContext(center: placeholder(at: timestamp),
                     neighbors: [],
                     recentApps: [],
                     transcriptSnippet: nil)
    }

    public func frame(id: Int64, includeThumbnail: Bool)
        async throws -> (detail: MCPFrameDetail, thumbnailBase64: String?) {
        let detail = MCPFrameDetail(frame: placeholder(id: id),
                                    ocrText: "",
                                    nodes: [])
        return (detail, nil)
    }

    public func summary(for date: Date) async throws -> MCPDailySummary {
        MCPDailySummary(summary: "",
                        apps: [],
                        keywords: [],
                        meetings: [])
    }

    public func thumbnail(for frameId: Int64) async throws -> String? { nil }
}
