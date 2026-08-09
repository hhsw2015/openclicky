// ReaderAggregates.swift — higher-level helpers on OpenRewindReader:
// thumbnails, JSONL export, sessions, app usage, meetings, daily recap,
// browser history, and aiContext. Ported from the prototype and kept
// functionally identical.

import AppKit
import Foundation

// MARK: - Thumbnails

extension OpenRewindReader {

    public func thumbnail(for entry: OpenRewindEntry, maxDim: Int = 512) throws -> NSImage {
        let full = try image(for: entry)
        // FIX(nan-crash-2026-07-29): entry.width/height are 0 for hot
        // frames that haven't been linked to a video row yet. Fall
        // back to the loaded image's real pixel size.
        var w = entry.width, h = entry.height
        if w <= 0 || h <= 0 {
            let sz = full.size
            w = Int(sz.width)
            h = Int(sz.height)
        }
        // Ultimate safety: refuse to divide by zero. NSImage.size can
        // still return (0,0) on some NSImageReps; bail out with the
        // full image rather than dispatch a NaN-throwing Int() cast.
        guard w > 0, h > 0 else { return full }
        let ratio = min(CGFloat(maxDim) / CGFloat(w),
                        CGFloat(maxDim) / CGFloat(h))
        let scaled = CGFloat(w) * ratio
        guard scaled.isFinite else { return full }
        let outW = max(Int(scaled), 1)
        let outH = max(Int(CGFloat(h) * ratio), 1)
        let thumb = NSImage(size: NSSize(width: outW, height: outH))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH),
                  from: NSRect(origin: .zero, size: full.size),
                  operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    public func thumbnailJPEG(for entry: OpenRewindEntry,
                              maxDim: Int = 512,
                              quality: Double = 0.7) throws -> Data {
        let img = try thumbnail(for: entry, maxDim: maxDim)
        guard let tiff = img.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg,
                        properties: [.compressionFactor: quality]) else {
            throw OpenRewindError.decodeFailed("jpeg encode failed")
        }
        return data
    }

    public func thumbnailBase64(for entry: OpenRewindEntry,
                                maxDim: Int = 512,
                                quality: Double = 0.7) throws -> String {
        let raw = try thumbnailBase64Raw(for: entry, maxDim: maxDim, quality: quality)
        return "data:image/jpeg;base64,\(raw)"
    }

    public func thumbnailBase64Raw(for entry: OpenRewindEntry,
                                   maxDim: Int = 1280,
                                   quality: Double = 0.7) throws -> String {
        let data = try thumbnailJPEG(for: entry, maxDim: maxDim, quality: quality)
        return data.base64EncodedString()
    }

    public struct ScreenshotPayload: Sendable {
        public let base64: String
        public let mimeType: String
        public let width: Int
        public let height: Int
    }

    public func screenshotPayload(for entry: OpenRewindEntry,
                                  maxDim: Int = 1280,
                                  quality: Double = 0.7) throws -> ScreenshotPayload {
        let full = try image(for: entry)
        let ratio = min(CGFloat(maxDim) / CGFloat(entry.width),
                        CGFloat(maxDim) / CGFloat(entry.height))
        let outW = max(Int(CGFloat(entry.width) * ratio), 1)
        let outH = max(Int(CGFloat(entry.height) * ratio), 1)
        let thumb = NSImage(size: NSSize(width: outW, height: outH))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH),
                  from: NSRect(origin: .zero, size: full.size),
                  operation: .copy, fraction: 1)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg,
                        properties: [.compressionFactor: quality]) else {
            throw OpenRewindError.decodeFailed("jpeg encode failed")
        }
        return ScreenshotPayload(base64: data.base64EncodedString(),
                                 mimeType: "image/jpeg",
                                 width: outW, height: outH)
    }
}

// MARK: - Summaries / usage / meetings / recap / history

extension OpenRewindReader {

    public func summarize(from start: Date, to end: Date,
                          topN: Int = 10,
                          keywordMinLength: Int = 4) throws -> OpenRewindTimeSummary {
        let appSQL = """
            SELECT s.bundleID,
                   SUM((strftime('%s', s.endDate) - strftime('%s', s.startDate))
                       * 1.0
                       + (substr(s.endDate, 20, 3) - substr(s.startDate, 20, 3)) / 1000.0
                   ) AS seconds,
                   COUNT(DISTINCT s.id) AS segs,
                   COUNT(f.id) AS frames
            FROM segment s
            LEFT JOIN frame f ON f.segmentId = s.id
                              AND f.createdAt >= ?
                              AND f.createdAt <= ?
            WHERE s.startDate <= ? AND s.endDate >= ?
            GROUP BY s.bundleID
            ORDER BY seconds DESC;
            """
        var apps: [OpenRewindTimeSummary.AppTime] = []
        let (_, appRows) = try rawQuery(
            appSQL, [ORKDate.iso(start), ORKDate.iso(end),
                     ORKDate.iso(end), ORKDate.iso(start)])
        for r in appRows {
            guard let bid = r[0], !bid.isEmpty else { continue }
            let sec = Double(r[1] ?? "0") ?? 0
            let segs = Int(r[2] ?? "0") ?? 0
            let frs = Int(r[3] ?? "0") ?? 0
            apps.append(.init(bundleID: bid, seconds: max(sec, 0),
                              segments: segs, frames: frs))
        }

        let urlSQL = """
            SELECT s.browserUrl,
                   COUNT(DISTINCT s.id),
                   SUM((strftime('%s', s.endDate) - strftime('%s', s.startDate)) * 1.0)
            FROM segment s
            WHERE s.startDate <= ? AND s.endDate >= ?
              AND s.browserUrl IS NOT NULL AND s.browserUrl != ''
            GROUP BY s.browserUrl
            ORDER BY 2 DESC
            LIMIT ?;
            """
        var urls: [OpenRewindTimeSummary.URLVisit] = []
        let (_, urlRows) = try rawQuery(urlSQL,
            [ORKDate.iso(end), ORKDate.iso(start), String(topN)])
        for r in urlRows {
            guard let u = r[0] else { continue }
            urls.append(.init(url: u,
                              visits: Int(r[1] ?? "0") ?? 0,
                              seconds: max(Double(r[2] ?? "0") ?? 0, 0)))
        }

        let winSQL = """
            SELECT s.windowName, s.bundleID,
                   SUM((strftime('%s', s.endDate) - strftime('%s', s.startDate)) * 1.0)
            FROM segment s
            WHERE s.startDate <= ? AND s.endDate >= ?
              AND s.windowName IS NOT NULL AND s.windowName != ''
            GROUP BY s.windowName, s.bundleID
            ORDER BY 3 DESC
            LIMIT ?;
            """
        var wins: [OpenRewindTimeSummary.WindowTime] = []
        let (_, winRows) = try rawQuery(winSQL,
            [ORKDate.iso(end), ORKDate.iso(start), String(topN)])
        for r in winRows {
            guard let w = r[0] else { continue }
            wins.append(.init(windowName: w,
                              bundleID: r[1],
                              seconds: max(Double(r[2] ?? "0") ?? 0, 0)))
        }

        let (_, fRows) = try rawQuery("""
            SELECT COUNT(*), COUNT(DISTINCT segmentId) FROM frame
            WHERE createdAt >= ? AND createdAt <= ?;
            """, [ORKDate.iso(start), ORKDate.iso(end)])
        let framesCount = Int(fRows.first?[0] ?? "0") ?? 0
        let uniqueSegs  = Int(fRows.first?[1] ?? "0") ?? 0

        // FIX(review-2026-07-28) K-M-2: query the FTS5 vtable's public
        // `text` column instead of the `_content` shadow. See
        // Reader.ocr(for:) for the rationale.
        let ocrSQL = """
            SELECT sr.text FROM searchRanking sr
            JOIN doc_segment ds ON ds.docid = sr.rowid
            JOIN frame f ON f.id = ds.frameId
            WHERE f.createdAt >= ? AND f.createdAt <= ?
            LIMIT 500;
            """
        var kw: [String: Int] = [:]
        let stopwords: Set<String> = [
            "http","https","com","the","and","for","that","this","with",
            "from","into","have","been","were","was","are","not","but",
            "all","you","your","our","their","its","just","its","them",
        ]
        let (_, ocrRows) = try rawQuery(ocrSQL, [ORKDate.iso(start), ORKDate.iso(end)])
        for row in ocrRows {
            guard let t = row.first ?? nil else { continue }
            for tok in t.lowercased().split(whereSeparator: {
                !$0.isLetter && !$0.isNumber
            }) {
                let w = String(tok)
                if w.count >= keywordMinLength && !stopwords.contains(w) {
                    kw[w, default: 0] += 1
                }
            }
        }
        let topKW = Dictionary(uniqueKeysWithValues:
            kw.sorted { $0.value > $1.value }.prefix(topN)
              .map { ($0.key, $0.value) })

        let totalActive = apps.reduce(0.0) { $0 + $1.seconds }
        return OpenRewindTimeSummary(
            start: start, end: end,
            totalActiveSeconds: totalActive,
            framesCount: framesCount,
            uniqueSegments: uniqueSegs,
            apps: apps,
            topURLs: urls,
            topWindows: wins,
            topOCRKeywords: topKW)
    }

    public func sessions(from start: Date, to end: Date,
                         mergeGapSeconds: TimeInterval = 60,
                         limit: Int = 2000) throws -> [OpenRewindSession] {
        let segs = try segments(from: start, to: end, limit: limit)
        let ordered = segs.reversed()
        var sessions: [OpenRewindSession] = []
        var currentSegs: [OpenRewindSegment] = []
        var currentBundle: String?
        var currentStart: Date = .distantPast
        var currentEnd: Date = .distantPast

        func flush() {
            guard !currentSegs.isEmpty else { return }
            let ids = currentSegs.map { String($0.id) }.joined(separator: ",")
            let frameCount: Int
            let topWindows: [String]
            if let (_, rows) = try? rawQuery(
                "SELECT COUNT(*) FROM frame WHERE segmentId IN (\(ids));", []) {
                frameCount = Int(rows.first?[0] ?? "0") ?? 0
            } else { frameCount = 0 }
            if let (_, rows) = try? rawQuery("""
                SELECT windowName, COUNT(*) FROM segment
                WHERE id IN (\(ids)) AND windowName IS NOT NULL AND windowName != ''
                GROUP BY windowName ORDER BY 2 DESC LIMIT 5;
                """, []) {
                topWindows = rows.compactMap { $0.first ?? nil }
            } else { topWindows = [] }
            sessions.append(OpenRewindSession(
                id: sessions.count,
                bundleID: currentBundle,
                startDate: currentStart,
                endDate: currentEnd,
                segmentIDs: currentSegs.map { $0.id },
                frameCount: frameCount,
                topWindowNames: topWindows))
        }

        for s in ordered {
            if currentBundle == s.bundleID,
               s.startDate.timeIntervalSince(currentEnd) <= mergeGapSeconds {
                currentSegs.append(s)
                currentEnd = max(currentEnd, s.endDate)
            } else {
                flush()
                currentSegs = [s]
                currentBundle = s.bundleID
                currentStart = s.startDate
                currentEnd = s.endDate
            }
        }
        flush()
        return sessions.sorted { $0.startDate > $1.startDate }
    }

    public func appUsage(from start: Date, to end: Date) throws -> [OpenRewindAppUsage] {
        let simpleSQL = """
            SELECT s.bundleID,
                   SUM((strftime('%s', s.endDate) - strftime('%s', s.startDate)) * 1.0),
                   COUNT(DISTINCT s.id),
                   COUNT(f.id)
            FROM segment s
            LEFT JOIN frame f ON f.segmentId = s.id
                              AND f.createdAt >= ? AND f.createdAt <= ?
            WHERE s.startDate <= ? AND s.endDate >= ?
              AND s.bundleID IS NOT NULL AND s.bundleID != ''
            GROUP BY s.bundleID
            ORDER BY 2 DESC;
            """
        let (_, rows) = try rawQuery(simpleSQL,
            [ORKDate.iso(start), ORKDate.iso(end),
             ORKDate.iso(end), ORKDate.iso(start)])
        var out: [OpenRewindAppUsage] = []
        for r in rows {
            guard let bid = r[0], !bid.isEmpty else { continue }
            let total = max(Double(r[1] ?? "0") ?? 0, 0)
            let launches = Int(r[2] ?? "0") ?? 0
            let frames = Int(r[3] ?? "0") ?? 0
            let avg = launches > 0 ? total / Double(launches) : 0
            out.append(.init(bundleID: bid,
                             totalSeconds: total,
                             launches: launches,
                             avgSessionSeconds: avg,
                             frames: frames))
        }
        return out
    }

    public func meetings(from start: Date, to end: Date,
                         limit: Int = 500) throws -> [OpenRewindMeeting] {
        let bundles = OpenRewindMeetingApp.all
        let placeholders = bundles.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT id, bundleID, startDate, endDate, windowName
            FROM segment
            WHERE startDate <= ? AND endDate >= ?
              AND bundleID IN (\(placeholders))
            ORDER BY startDate;
            """
        var binds = [ORKDate.iso(end), ORKDate.iso(start)]
        binds.append(contentsOf: bundles)
        let (_, rows) = try rawQuery(sql, binds)

        var out: [OpenRewindMeeting] = []
        var cur: (app: String, start: Date, end: Date, ids: [Int64], title: String?)?
        for r in rows {
            let id = Int64(r[0] ?? "0") ?? 0
            let app = r[1] ?? ""
            let s = ORKDate.parse(r[2] ?? "") ?? Date()
            let e = ORKDate.parse(r[3] ?? "") ?? Date()
            let title = (r[4]?.isEmpty == false) ? r[4] : nil
            if var c = cur, c.app == app,
               s.timeIntervalSince(c.end) < 120 {
                c.end = max(c.end, e); c.ids.append(id)
                if c.title == nil { c.title = title }
                cur = c
            } else {
                if let c = cur {
                    out.append(OpenRewindMeeting(app: c.app, startDate: c.start,
                                                  endDate: c.end,
                                                  segmentIDs: c.ids, title: c.title))
                }
                cur = (app, s, e, [id], title)
            }
            if out.count >= limit { break }
        }
        if let c = cur {
            out.append(OpenRewindMeeting(app: c.app, startDate: c.start,
                                          endDate: c.end,
                                          segmentIDs: c.ids, title: c.title))
        }
        return out.filter { $0.seconds >= 60 }
    }

    public func dailyRecap(for day: Date) throws -> OpenRewindDailyRecap {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end   = cal.date(byAdding: .day, value: 1, to: start)!

        let summary = try summarize(from: start, to: end, topN: 20)
        let usage   = try appUsage(from: start, to: end)
        let meetings = try self.meetings(from: start, to: end)

        let (_, boundsRows) = try rawQuery("""
            SELECT MIN(createdAt), MAX(createdAt) FROM frame
            WHERE createdAt >= ? AND createdAt <= ?;
            """, [ORKDate.iso(start), ORKDate.iso(end)])
        let firstS = boundsRows.first?[0] ?? nil
        let lastS  = boundsRows.first?[1] ?? nil

        return OpenRewindDailyRecap(
            day: start,
            firstActivity: firstS.flatMap(ORKDate.parse),
            lastActivity:  lastS.flatMap(ORKDate.parse),
            activeSeconds: summary.totalActiveSeconds,
            frameCount: summary.framesCount,
            uniqueApps: usage.count,
            topApps: Array(usage.prefix(10)),
            meetings: meetings,
            topURLs: Array(summary.topURLs.prefix(10)),
            ocrKeywords: summary.topOCRKeywords)
    }

    public func browserHistory(from start: Date, to end: Date,
                               limit: Int = 200) throws -> [OpenRewindURLVisit] {
        let sql = """
            SELECT browserUrl, bundleID, windowName,
                   MIN(startDate), MAX(endDate),
                   COUNT(*),
                   SUM((strftime('%s', endDate) - strftime('%s', startDate)) * 1.0)
            FROM segment
            WHERE startDate <= ? AND endDate >= ?
              AND browserUrl IS NOT NULL AND browserUrl != ''
            GROUP BY browserUrl
            ORDER BY 5 DESC
            LIMIT ?;
            """
        let (_, rows) = try rawQuery(sql, [ORKDate.iso(end), ORKDate.iso(start), String(limit)])
        return rows.compactMap { r in
            guard let u = r[0], !u.isEmpty else { return nil }
            let bundle = r[1] ?? ""
            let title  = r[2]
            let first  = ORKDate.parse(r[3] ?? "") ?? Date()
            let last   = ORKDate.parse(r[4] ?? "") ?? Date()
            let visits = Int(r[5] ?? "0") ?? 0
            let total  = max(Double(r[6] ?? "0") ?? 0, 0)
            let host   = URL(string: u)?.host ?? u
            return OpenRewindURLVisit(url: u, host: host, title: title,
                                       bundleID: bundle,
                                       firstSeen: first, lastSeen: last,
                                       visits: visits, totalSeconds: total)
        }
    }

    public func topDomains(from start: Date, to end: Date,
                           limit: Int = 20) throws -> [(host: String, visits: Int, seconds: Double)] {
        let visits = try browserHistory(from: start, to: end, limit: 2000)
        var acc: [String: (Int, Double)] = [:]
        for v in visits {
            let (n, s) = acc[v.host] ?? (0, 0)
            acc[v.host] = (n + v.visits, s + v.totalSeconds)
        }
        return acc.sorted { $0.value.1 > $1.value.1 }
                  .prefix(limit)
                  .map { ($0.key, $0.value.0, $0.value.1) }
    }

    public func coverage() throws -> (earliest: Date?, latest: Date?, days: Int) {
        let (_, rows) = try rawQuery(
            "SELECT MIN(createdAt), MAX(createdAt) FROM frame;")
        let earliest = rows.first?[0].flatMap(ORKDate.parse)
        let latest   = rows.first?[1].flatMap(ORKDate.parse)
        let days = (earliest != nil && latest != nil)
            ? max(Int(latest!.timeIntervalSince(earliest!) / 86400) + 1, 1)
            : 0
        return (earliest, latest, days)
    }

    /// FIX(product-polish-2026-07-31 #1): return the actual frame row
    /// count. Previously `Bridge.refreshStatePublisher` was multiplying
    /// coverage.days by 0 as a TODO placeholder; the notch + Settings
    /// showed "0 frames indexed" forever.
    public func totalFrameCount() throws -> Int {
        let (_, rows) = try rawQuery("SELECT COUNT(*) FROM frame;")
        return Int(rows.first?[0] ?? "0") ?? 0
    }

    public func keywords(from query: String, maxWords: Int = 8) -> String {
        let stop: Set<String> = [
            "what","when","where","who","why","how","did","do","does","was",
            "were","is","are","the","a","an","and","or","of","to","in","on",
            "for","from","with","that","this","my","me","i","you","your",
            "about","show","find","search","get","give","list","tell"
        ]
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !stop.contains($0) }
        let picked = Array(words.prefix(maxWords))
        return picked.joined(separator: " ")
    }

    public func searchForAI(_ question: String,
                            limit: Int = 8,
                            thumbnailSize: Int = 384) throws
        -> [(hit: OpenRewindSearchHit, imageDataURL: String?)] {
        let kw = keywords(from: question)
        let hits = try search(kw.isEmpty ? question : kw, limit: limit)
        var out: [(OpenRewindSearchHit, String?)] = []
        for h in hits {
            let dataURL = try? thumbnailBase64(for: h.entry, maxDim: thumbnailSize)
            out.append((h, dataURL))
        }
        return out
    }

    public func aiContext(around anchor: OpenRewindEntry,
                          neighborhood: Int = 5,
                          thumbnail: Bool = true,
                          thumbnailSize: Int = 384) throws -> OpenRewindAIContext {
        let all = try entries(from: anchor.createdAt.addingTimeInterval(-600),
                              to:   anchor.createdAt.addingTimeInterval(600),
                              limit: 1000)
        let sorted = all.sorted { $0.createdAt < $1.createdAt }
        var before: [OpenRewindEntry] = []
        var after: [OpenRewindEntry] = []
        if let idx = sorted.firstIndex(where: { $0.id == anchor.id }) {
            let bs = max(idx - neighborhood, 0)
            before = Array(sorted[bs..<idx])
            let ae = min(idx + 1 + neighborhood, sorted.count)
            after = Array(sorted[(idx+1)..<ae])
        }
        let (text, nodes) = try ocr(for: anchor.id)

        var seg: OpenRewindSegment? = nil
        var sameWinSec: Double = 0
        let (_, segRows) = try rawQuery("""
            SELECT s.id, s.bundleID, s.startDate, s.endDate, s.windowName,
                   s.browserUrl, s.browserProfile, s.type
            FROM frame f JOIN segment s ON s.id = f.segmentId
            WHERE f.id = ?;
            """, [String(anchor.id)])
        if let r = segRows.first {
            let sSeg = OpenRewindSegment(
                id: Int64(r[0] ?? "0") ?? 0,
                bundleID: r[1],
                startDate: ORKDate.parse(r[2] ?? "") ?? Date(),
                endDate:   ORKDate.parse(r[3] ?? "") ?? Date(),
                windowName: r[4], browserUrl: r[5]?.nonEmpty,
                browserProfile: r[6]?.nonEmpty,
                type: Int(r[7] ?? "0") ?? 0)
            seg = sSeg
            sameWinSec = sSeg.endDate.timeIntervalSince(sSeg.startDate)
        }
        let (_, appRows) = try rawQuery("""
            SELECT DISTINCT s.bundleID FROM segment s
            WHERE s.endDate >= ? AND s.startDate <= ?
              AND s.bundleID IS NOT NULL AND s.bundleID != ''
            ORDER BY s.endDate DESC LIMIT 10;
            """, [ORKDate.iso(anchor.createdAt.addingTimeInterval(-3600)),
                  ORKDate.iso(anchor.createdAt)])
        let recent = appRows.compactMap { $0.first ?? nil }

        var dataURL: String? = nil
        if thumbnail {
            dataURL = try? thumbnailBase64(for: anchor, maxDim: thumbnailSize)
        }

        return OpenRewindAIContext(
            anchor: anchor,
            neighborsBefore: before, neighborsAfter: after,
            segment: seg,
            ocrText: text, ocrNodes: nodes,
            sameWindowMinutes: sameWinSec / 60.0,
            recentApps: recent,
            anchorImageBase64: dataURL)
    }

    // MARK: - JSONL export

    public func exportJSONL(to url: URL,
                            from start: Date? = nil,
                            to end: Date? = nil,
                            includeOCR: Bool = true) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: url.path) else {
            throw OpenRewindError.openFailed("cannot open \(url.path) for write")
        }
        defer { try? fh.close() }

        let sql: String
        var binds: [String] = []
        if let s = start, let e = end {
            sql = """
                SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                       v.path, f.videoFrameIndex,
                       (SELECT sr.text FROM doc_segment ds
                        JOIN searchRanking sr ON sr.rowid = ds.docid
                        WHERE ds.frameId = f.id LIMIT 1)
                FROM frame f
                LEFT JOIN segment s ON s.id = f.segmentId
                LEFT JOIN video   v ON v.id = f.videoId
                WHERE f.videoId IS NOT NULL
                  AND f.createdAt >= ? AND f.createdAt <= ?
                ORDER BY f.createdAt;
                """
            binds = [ORKDate.iso(s), ORKDate.iso(e)]
        } else {
            sql = """
                SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
                       v.path, f.videoFrameIndex,
                       (SELECT sr.text FROM doc_segment ds
                        JOIN searchRanking sr ON sr.rowid = ds.docid
                        WHERE ds.frameId = f.id LIMIT 1)
                FROM frame f
                LEFT JOIN segment s ON s.id = f.segmentId
                LEFT JOIN video   v ON v.id = f.videoId
                WHERE f.videoId IS NOT NULL
                ORDER BY f.createdAt;
                """
        }
        let (_, rows) = try rawQuery(sql, binds)
        var written = 0
        for r in rows {
            var obj: [String: Any] = [:]
            obj["id"]     = Int(r[0] ?? "0") ?? 0
            obj["ts"]     = r[1] ?? ""
            obj["app"]    = r[2] ?? ""
            obj["window"] = r[3] ?? ""
            let url_ = r[4] ?? ""
            if !url_.isEmpty { obj["url"] = url_ }
            obj["chunk"]  = r[5] ?? ""
            obj["frame"]  = Int(r[6] ?? "0") ?? 0
            if includeOCR, let t = r[7], !t.isEmpty {
                obj["ocr"] = t
            }
            let data = try JSONSerialization.data(withJSONObject: obj,
                                                   options: [.sortedKeys])
            fh.write(data)
            fh.write(Data([0x0a]))
            written += 1
        }
        return written
    }
}
