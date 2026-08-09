// Schema.swift — Rewind schema constants used by SchemaValidator, Writer,
// Reader, and Migrator. Values are the ones actually observed in a live
// Rewind 1.5607 install; see docs/SCHEMA.md.

import Foundation

/// Namespace for Rewind's schema — table names, column names, index names,
/// and the SQL text `SchemaValidator` runs against `sqlite_master`.
public enum OpenRewindSchema {

    // MARK: - Table names

    public enum Table: String, CaseIterable, Sendable {
        case segment
        case video
        case frame
        case node
        case docSegment       = "doc_segment"
        case searchRanking
        case audio
        case transcriptWord   = "transcript_word"
        case event
        case summary
        case frameProcessing  = "frame_processing"
        case purge
    }

    // MARK: - Column-name enums (per table, in declared order)

    public enum SegmentColumn: String, CaseIterable, Sendable {
        case id, bundleID, startDate, endDate, windowName,
             browserUrl, browserProfile, type
    }

    public enum VideoColumn: String, CaseIterable, Sendable {
        case id, height, width, path, captureType, fileSize,
             frameRate, `local`, xid, processingState
    }

    public enum FrameColumn: String, CaseIterable, Sendable {
        case id, createdAt, imageFileName, segmentId, videoId,
             videoFrameIndex, isStarred, encodingStatus
    }

    public enum NodeColumn: String, CaseIterable, Sendable {
        case id, frameId, nodeOrder, textOffset, textLength,
             leftX, topY, width, height, windowIndex
    }

    public enum DocSegmentColumn: String, CaseIterable, Sendable {
        case docid, segmentId, frameId
    }

    /// searchRanking is FTS5 — validator asserts the vtable exists and
    /// that its declared columns match.
    public enum SearchRankingColumn: String, CaseIterable, Sendable {
        case text, otherText, title
    }

    public enum AudioColumn: String, CaseIterable, Sendable {
        case id, segmentId, path, startTime, duration
    }

    public enum TranscriptWordColumn: String, CaseIterable, Sendable {
        // Rewind-compat: (id, segmentId, speechSource, word,
        // timeOffset INTEGER ms, fullTextOffset, duration INTEGER ms).
        case id, segmentId, speechSource, word, timeOffset,
             fullTextOffset, duration
    }

    public enum EventColumn: String, CaseIterable, Sendable {
        case id, type, status, title, participants, detailsJSON,
             calendarID, calendarEventID, calendarSeriesID, segmentID
    }

    public enum SummaryColumn: String, CaseIterable, Sendable {
        // Rewind live: (id, status, text, eventId).
        case id, status, text, eventId
    }

    public enum FrameProcessingColumn: String, CaseIterable, Sendable {
        case id, processingType, createdAt
    }

    public enum PurgeColumn: String, CaseIterable, Sendable {
        case path, fileType
    }

    // MARK: - Indexes we depend on

    public static let expectedIndexes: [String] = [
        "index_frame_on_createdat",
        "index_frame_on_encodingstatus_createdat",
        "index_frame_on_isstarred_createdat",
        "index_frame_on_segmentid_createdat",
        "index_frame_on_videoid",
        "index_node_on_frameid",
        "index_doc_segment_on_frameid_docid",
        "index_doc_segment_on_segmentid_docid",
        "index_segment_on_appid",
        "index_segment_on_endtime",
        "index_segment_on_starttime",
        "index_summary_on_eventid",
        "index_summary_on_status",
        "index_event_on_calendarseriesid",
        "index_event_on_status",
        "index_transcript_word_on_segmentid_fulltextoffset",
    ]

    /// Map of table name to expected column list — validator walks this to
    /// confirm every column is present.
    public static let expectedColumns: [(String, [String])] = [
        (Table.segment.rawValue,          SegmentColumn.allCases.map(\.rawValue)),
        (Table.video.rawValue,            VideoColumn.allCases.map(\.rawValue)),
        (Table.frame.rawValue,            FrameColumn.allCases.map(\.rawValue)),
        (Table.node.rawValue,             NodeColumn.allCases.map(\.rawValue)),
        (Table.docSegment.rawValue,       DocSegmentColumn.allCases.map(\.rawValue)),
        (Table.audio.rawValue,            AudioColumn.allCases.map(\.rawValue)),
        (Table.transcriptWord.rawValue,   TranscriptWordColumn.allCases.map(\.rawValue)),
        (Table.event.rawValue,            EventColumn.allCases.map(\.rawValue)),
        (Table.summary.rawValue,          SummaryColumn.allCases.map(\.rawValue)),
        (Table.frameProcessing.rawValue,  FrameProcessingColumn.allCases.map(\.rawValue)),
        (Table.purge.rawValue,            PurgeColumn.allCases.map(\.rawValue)),
    ]

    /// FTS5 tables are virtual — presence is checked separately.
    public static let expectedFTS5Tables: [String] = [
        Table.searchRanking.rawValue,
    ]
}
