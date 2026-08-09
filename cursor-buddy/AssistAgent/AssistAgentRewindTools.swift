//
//  AssistAgentRewindTools.swift
//  cursor-buddy
//
//  Assist-agent side executor for Screen History (embedded OpenRewind)
//  tools. Three canonical entry points (`rewind_search` /
//  `rewind_frame` / `rewind_recap`), plus richer helpers for the MCP
//  sensor path. All go through `OpenRewindBridge.shared.reader`;
//  when Screen History is not enabled we return a benign `ok:false`
//  outcome that the loop naturally routes past.
//

import Foundation
import AppKit

public enum AssistAgentRewindTools {

    public static func isAvailable() -> Bool {
        OpenRewindBridge.shared != nil
    }

    /// Dispatch a rewind_* tool call. Returns the AssistAgent tool
    /// outcome (ok flag + one-line summary + full raw payload).
    public static func run(tool: String,
                           args: [String: String]) async -> AssistAgentToolOutcome {
        guard let bridge = OpenRewindBridge.shared else {
            return .init(
                ok: false,
                summary: "屏幕历史未启用",
                raw: "用户未开启屏幕历史录制,或权限不足。请到 Settings → Screen History 开启。")
        }
        // Refresh the reader's /tmp copy so we see freshly-written frames.
        try? await bridge.reopenReaderAsync()
        let reader = bridge.reader
        do {
            switch tool {
            case "rewind_search":         return try await search(reader: reader, args: args)
            case "rewind_frame":          return try frame(reader: reader, args: args)
            case "rewind_recap":          return try recap(reader: reader, args: args)
            case "rewind_coverage":       return try coverage(reader: reader)
            case "rewind_last":           return try lastN(reader: reader, args: args)
            case "rewind_app_usage":      return try appUsage(reader: reader, args: args)
            case "rewind_meetings":       return try meetings(reader: reader, args: args)
            case "rewind_browser_history": return try browserHistory(reader: reader, args: args)
            case "rewind_top_domains":    return try topDomains(reader: reader, args: args)
            case "rewind_ocr":            return try ocrOnly(reader: reader, args: args)
            case "rewind_ask":            return await askRewind(args: args)
            case "rewind_recent":         return try recentActivity(reader: reader, args: args)
            case "rewind_events":         return try events(reader: reader, args: args)
            case "rewind_transcript":     return try transcript(reader: reader, args: args)
            case "rewind_thumbnail":      return try thumbnailBase64(reader: reader, args: args)
            case "rewind_show_frame":     return await showFrame(reader: reader, args: args)
            case "rewind_locate":         return await locateText(reader: reader, args: args)
            default:
                return .init(ok: false,
                             summary: "unknown rewind tool: \(tool)",
                             raw: "no handler")
            }
        } catch {
            return .init(ok: false,
                         summary: "屏幕历史查询失败: \(error.localizedDescription)",
                         raw: String(describing: error))
        }
    }

    // MARK: - search

    private static func search(reader: OpenRewindReader,
                               args: [String: String]) async throws -> AssistAgentToolOutcome {
        let q = (args["query"] ?? args["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return .init(ok: false, summary: "missing query", raw: "query required")
        }
        let limit = Int(args["limit"] ?? "8") ?? 8
        let hybrid = (args["hybrid"] ?? "false").lowercased() == "true"
        var pairs = try reader.searchForAI(q, limit: max(1, min(limit, 20)), thumbnailSize: 0)
        // Semantic fallback: when the agent explicitly requested
        // hybrid (or when the keyword pass found nothing), layer in
        // Apple NLEmbedding vector matches via RRF. Cheap on small
        // vaults and only triggered when it's likely to help.
        if hybrid || pairs.isEmpty,
           let bridge = await MainActor.run(body: { OpenRewindBridge.shared }) {
            let vec = await EmbeddingStore.topK(
                bridge: bridge, queryText: q,
                k: max(1, min(limit, 20)))
            if !vec.isEmpty {
                let ftsIds = pairs.map { $0.hit.entry.id }
                let vecIds = vec.map { $0.frameId }
                let fused = RRF.fuse(fts: ftsIds, vector: vecIds).prefix(limit)
                // Reorder pairs by fused order, hydrating vec-only IDs.
                let byId = Dictionary(uniqueKeysWithValues: pairs.map {
                    ($0.hit.entry.id, $0)
                })
                var reordered: [(hit: OpenRewindSearchHit, imageDataURL: String?)] = []
                for id in fused {
                    if let p = byId[id] { reordered.append(p); continue }
                    if let entry = try? reader.entryByID(id) {
                        reordered.append((
                            hit: OpenRewindSearchHit(id: id, snippet: "",
                                                      entry: entry),
                            imageDataURL: nil))
                    }
                }
                if !reordered.isEmpty { pairs = reordered }
            }
        }
        if pairs.isEmpty {
            return .init(ok: true, summary: "no hits for \"\(q)\"", raw: "0 rows")
        }
        let df = ISO8601DateFormatter()
        let lines: [String] = pairs.enumerated().map { (i, pair) in
            let hit = pair.hit
            let entry = hit.entry
            let bundle = entry.bundleID ?? "?"
            let win = (entry.windowName ?? "").prefix(60)
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ").prefix(140)
            return "#\(i+1) frame=\(entry.id) \(df.string(from: entry.createdAt)) app=\(bundle) win=\(win)\n    \(snippet)"
        }
        let summary = "\(pairs.count) hits for \"\(q)\" — top frame ids: "
            + pairs.prefix(5).map { String($0.hit.entry.id) }.joined(separator: ",")
        return .init(ok: true, summary: summary, raw: lines.joined(separator: "\n"))
    }

    // MARK: - frame

    private static func frame(reader: OpenRewindReader,
                              args: [String: String]) throws -> AssistAgentToolOutcome {
        let id: Int64? = args["frame_id"].flatMap(Int64.init)
        let at: Date? = args["at"].flatMap(parseTimestamp)
        let entry: OpenRewindEntry
        if let id {
            // FIX(perf-2026-07-31): O(log n) by-id lookup instead of
            // full-table scan of 20k rows.
            guard let e = try reader.entryByID(id) else {
                return .init(ok: false, summary: "no such frame: \(id)", raw: "not found")
            }
            entry = e
        } else if let at {
            let window = try reader.entries(from: at.addingTimeInterval(-30),
                                            to: at.addingTimeInterval(30),
                                            limit: 1)
            guard let e = window.first else {
                return .init(ok: false,
                             summary: "no frame near \(at)",
                             raw: "60-second window empty")
            }
            entry = e
        } else {
            return .init(ok: false,
                         summary: "need frame_id or at",
                         raw: "provide frame_id (Int64) or at (ISO8601/unix seconds)")
        }
        let ctx = try reader.aiContext(around: entry,
                                       neighborhood: 3,
                                       thumbnail: true,
                                       thumbnailSize: 512)
        let df = ISO8601DateFormatter()
        let bundle = entry.bundleID ?? "?"
        let win = entry.windowName ?? ""
        let url = entry.browserUrl ?? ""
        var raw = "frame \(entry.id) at \(df.string(from: entry.createdAt))\n"
        raw += "app: \(bundle)\n"
        if !win.isEmpty { raw += "window: \(win)\n" }
        if !url.isEmpty { raw += "url: \(url)\n" }
        raw += "\n--- OCR ---\n\(ctx.ocrText.prefix(3000))\n"
        if !ctx.recentApps.isEmpty {
            raw += "\n--- recent apps ---\n" + ctx.recentApps.prefix(8).joined(separator: ", ") + "\n"
        }
        let hasImage = ctx.anchorImageBase64 != nil
        let summary = "frame=\(entry.id) \(df.string(from: entry.createdAt)) app=\(bundle) " +
            (win.isEmpty ? "" : "win=\"\(win.prefix(40))\" ") + (hasImage ? "(thumbnail available)" : "")
        return .init(ok: true, summary: summary, raw: raw)
    }

    // MARK: - recap

    private static func recap(reader: OpenRewindReader,
                              args: [String: String]) throws -> AssistAgentToolOutcome {
        let day: Date
        if let s = args["date"], let parsed = parseDay(s) {
            day = parsed
        } else {
            day = Date()
        }
        let recap = try reader.dailyRecap(for: day)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var out = "recap for \(df.string(from: day))\n"
        out += "coverage: \(Int(recap.activeSeconds/60)) min, frames=\(recap.frameCount)\n\n"
        out += "top apps:\n"
        for row in recap.topApps.prefix(8) {
            out += "  \(row.bundleID)  \(Int(row.totalSeconds/60))m\n"
        }
        if !recap.topURLs.isEmpty {
            out += "\ntop urls:\n"
            for u in recap.topURLs.prefix(8) {
                out += "  \(u.url)  \(u.visits)x\n"
            }
        }
        if !recap.ocrKeywords.isEmpty {
            let kws = recap.ocrKeywords.sorted { $0.value > $1.value }.prefix(15).map { $0.key }
            out += "\ntop keywords: " + kws.joined(separator: ", ") + "\n"
        }
        let summary = "\(df.string(from: day)): \(recap.frameCount) frames, " +
            "\(Int(recap.activeSeconds/60))m, top app: \(recap.topApps.first?.bundleID ?? "-")"
        return .init(ok: true, summary: summary, raw: out)
    }

    // MARK: - coverage / last N / aggregates

    private static func coverage(reader: OpenRewindReader) throws -> AssistAgentToolOutcome {
        let c = try reader.coverage()
        let df = ISO8601DateFormatter()
        let earliest = c.earliest.map { df.string(from: $0) } ?? "-"
        let latest = c.latest.map { df.string(from: $0) } ?? "-"
        let summary = "Screen History spans \(c.days) days: \(earliest) → \(latest)"
        return .init(ok: true, summary: summary, raw: summary)
    }

    private static func lastN(reader: OpenRewindReader,
                              args: [String: String]) throws -> AssistAgentToolOutcome {
        let seconds = Double(args["seconds"] ?? "300") ?? 300
        let limit = Int(args["limit"] ?? "50") ?? 50
        let rows = try reader.lastSeconds(seconds, limit: max(1, min(limit, 500)))
        if rows.isEmpty {
            return .init(ok: true, summary: "no frames in last \(Int(seconds))s", raw: "0 rows")
        }
        let df = ISO8601DateFormatter()
        let lines = rows.prefix(min(rows.count, 40)).map { e in
            "frame=\(e.id) \(df.string(from: e.createdAt)) \(e.bundleID ?? "?") \((e.windowName ?? "").prefix(60))"
        }
        return .init(ok: true,
                     summary: "\(rows.count) frames in last \(Int(seconds))s",
                     raw: lines.joined(separator: "\n"))
    }

    private static func appUsage(reader: OpenRewindReader,
                                 args: [String: String]) throws -> AssistAgentToolOutcome {
        let (start, end) = dateRange(args: args, defaultHours: 24)
        let rows = try reader.appUsage(from: start, to: end)
        let df = ISO8601DateFormatter()
        var out = "app usage \(df.string(from: start)) → \(df.string(from: end))\n"
        for r in rows.prefix(15) {
            out += "  \(r.bundleID)  \(Int(r.totalSeconds/60))m  launches=\(r.launches)  frames=\(r.frames)\n"
        }
        let summary = "\(rows.count) apps; top: \(rows.first?.bundleID ?? "-")"
        return .init(ok: true, summary: summary, raw: out)
    }

    private static func meetings(reader: OpenRewindReader,
                                 args: [String: String]) throws -> AssistAgentToolOutcome {
        let (start, end) = dateRange(args: args, defaultHours: 24 * 7)
        let rows = try reader.meetings(from: start, to: end, limit: 200)
        let df = ISO8601DateFormatter()
        if rows.isEmpty { return .init(ok: true, summary: "no meetings in range", raw: "0 rows") }
        var out = "meetings \(df.string(from: start)) → \(df.string(from: end))\n"
        for m in rows.prefix(20) {
            let seconds = m.endDate.timeIntervalSince(m.startDate)
            out += "  \(m.app)  \(df.string(from: m.startDate))..\(df.string(from: m.endDate))  \(Int(seconds/60))m  \(m.title ?? "-")\n"
        }
        return .init(ok: true, summary: "\(rows.count) meetings", raw: out)
    }

    private static func browserHistory(reader: OpenRewindReader,
                                       args: [String: String]) throws -> AssistAgentToolOutcome {
        let (start, end) = dateRange(args: args, defaultHours: 24)
        let limit = Int(args["limit"] ?? "50") ?? 50
        let rows = try reader.browserHistory(from: start, to: end,
                                             limit: max(1, min(limit, 500)))
        let df = ISO8601DateFormatter()
        var out = "browser history \(df.string(from: start)) → \(df.string(from: end))\n"
        for v in rows.prefix(30) {
            out += "  \(v.host)  \(v.visits)x  \(Int(v.totalSeconds/60))m  \(v.url)\n"
        }
        return .init(ok: true,
                     summary: "\(rows.count) urls; top: \(rows.first?.host ?? "-")",
                     raw: out)
    }

    private static func topDomains(reader: OpenRewindReader,
                                   args: [String: String]) throws -> AssistAgentToolOutcome {
        let (start, end) = dateRange(args: args, defaultHours: 24)
        let limit = Int(args["limit"] ?? "20") ?? 20
        let rows = try reader.topDomains(from: start, to: end, limit: max(1, min(limit, 100)))
        var out = "top domains:\n"
        for d in rows.prefix(30) {
            out += "  \(d.host)  visits=\(d.visits)  \(Int(d.seconds/60))m\n"
        }
        return .init(ok: true, summary: "\(rows.count) domains", raw: out)
    }

    private static func ocrOnly(reader: OpenRewindReader,
                                args: [String: String]) throws -> AssistAgentToolOutcome {
        guard let id = args["frame_id"].flatMap(Int64.init) else {
            return .init(ok: false, summary: "missing frame_id", raw: "frame_id required")
        }
        let (text, nodes) = try reader.ocr(for: id)
        let summary = "frame \(id): \(nodes.count) OCR nodes, \(text.count) chars"
        return .init(ok: true, summary: summary, raw: String(text.prefix(4000)))
    }

    // MARK: - shared helpers

    private static func dateRange(args: [String: String],
                                  defaultHours: Double) -> (Date, Date) {
        let end: Date = args["to"].flatMap(parseTimestamp) ?? Date()
        let start: Date = args["from"].flatMap(parseTimestamp)
            ?? end.addingTimeInterval(-defaultHours * 3600)
        return (start, end)
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        if let unix = Double(s) { return Date(timeIntervalSince1970: unix) }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    private static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    // MARK: - Ask (end-to-end pipeline)

    private static func askRewind(args: [String: String]) async -> AssistAgentToolOutcome {
        let question = (args["question"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else {
            return .init(ok: false, summary: "missing question", raw: "question required")
        }
        do {
            let ans = try await AskRewind.ask(question: question)
            let cited = ans.citedFrameIds.prefix(5).map(String.init).joined(separator: ",")
            let summary = ans.noResults
                ? "屏幕历史无匹配"
                : "\(ans.resultCount) hits; frames: \(cited)"
            return .init(ok: !ans.noResults, summary: summary, raw: ans.text)
        } catch {
            return .init(ok: false, summary: "ask 失败",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - Recent activity stream

    private static func recentActivity(reader: OpenRewindReader,
                                       args: [String: String]) throws -> AssistAgentToolOutcome {
        let minutes = Int(args["minutes"] ?? "30") ?? 30
        let now = Date()
        let from = now.addingTimeInterval(-Double(minutes) * 60)
        let entries = try reader.entries(from: from, to: now, limit: 2000)
        let ordered = entries.sorted { $0.createdAt < $1.createdAt }
        struct Seg {
            let app: String; let start: Date; var end: Date; var frames: Int
        }
        var segs: [Seg] = []
        for e in ordered {
            let app = e.bundleID ?? "?"
            if var last = segs.last, last.app == app {
                last.end = e.createdAt; last.frames += 1
                segs[segs.count - 1] = last
            } else {
                segs.append(Seg(app: app, start: e.createdAt,
                                 end: e.createdAt, frames: 1))
            }
        }
        let df = ISO8601DateFormatter()
        var raw = "activity last \(minutes)m:\n"
        for s in segs {
            raw += "  \(s.app)  \(df.string(from: s.start))..\(df.string(from: s.end))  \(Int(s.end.timeIntervalSince(s.start)))s  frames=\(s.frames)\n"
        }
        let summary = "\(segs.count) app segments in \(minutes)m; top: \(segs.first?.app ?? "-")"
        return .init(ok: true, summary: summary, raw: raw)
    }

    // MARK: - Events / transcript / thumbnail

    private static func events(reader: OpenRewindReader,
                               args: [String: String]) throws -> AssistAgentToolOutcome {
        let rows = try reader.events(status: args["status"],
                                     limit: Int(args["limit"] ?? "50") ?? 50)
        if rows.isEmpty {
            return .init(ok: true, summary: "no calendar events", raw: "0 rows")
        }
        var out = "\(rows.count) events:\n"
        for e in rows.prefix(20) {
            out += "  #\(e.id) [\(e.status)] \(e.type) — \(e.title ?? "-")\n"
        }
        return .init(ok: true, summary: "\(rows.count) events", raw: out)
    }

    private static func transcript(reader: OpenRewindReader,
                                   args: [String: String]) throws -> AssistAgentToolOutcome {
        guard let seg = args["segment_id"].flatMap(Int64.init) else {
            return .init(ok: false, summary: "need segment_id", raw: "segment_id required")
        }
        let text = try reader.transcriptText(segmentID: seg)
        let summary = "segment \(seg): \(text.count) chars transcript"
        return .init(ok: !text.isEmpty, summary: summary,
                     raw: String(text.prefix(4000)))
    }

    private static func thumbnailBase64(reader: OpenRewindReader,
                                        args: [String: String]) throws -> AssistAgentToolOutcome {
        guard let fid = args["frame_id"].flatMap(Int64.init) else {
            return .init(ok: false, summary: "need frame_id", raw: "frame_id required")
        }
        let all = try reader.recentEntries(limit: 20000)
        guard let entry = all.first(where: { $0.id == fid }) else {
            return .init(ok: false, summary: "no frame \(fid)", raw: "not found")
        }
        let payload = try reader.screenshotPayload(for: entry, maxDim: 1280)
        let summary = "frame \(fid) thumbnail \(payload.width)×\(payload.height)"
        return .init(ok: true, summary: summary,
                     raw: "data:image/jpeg;base64,\(payload.base64.prefix(2000))…(truncated)")
    }

    // MARK: - Show frame / locate text (visual demonstration helpers)

    @MainActor
    private static func showFrame(reader: OpenRewindReader,
                                  args: [String: String]) async -> AssistAgentToolOutcome {
        var target: Date?
        if let idStr = args["frame_id"], let id = Int64(idStr) {
            let all = (try? reader.recentEntries(limit: 20000)) ?? []
            target = all.first(where: { $0.id == id })?.createdAt
        } else if let atStr = args["at"] {
            if let unix = Double(atStr) { target = Date(timeIntervalSince1970: unix) }
            else { target = ISO8601DateFormatter().date(from: atStr) }
        }
        guard let t = target else {
            return .init(ok: false, summary: "need frame_id or at",
                         raw: "provide frame_id or at")
        }
        ScreenHistoryWindowManager.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .screenHistoryJumpToDate,
                                            object: nil,
                                            userInfo: ["date": t])
        }
        return .init(ok: true, summary: "shown at \(t)",
                     raw: "timeline opened, seeking to \(ISO8601DateFormatter().string(from: t))")
    }

    @MainActor
    private static func locateText(reader: OpenRewindReader,
                                   args: [String: String]) async -> AssistAgentToolOutcome {
        guard let fid = args["frame_id"].flatMap(Int64.init) else {
            return .init(ok: false, summary: "need frame_id", raw: "frame_id required")
        }
        guard let query = args["query"], !query.isEmpty else {
            return .init(ok: false, summary: "need query", raw: "query required")
        }
        guard let (_, nodes) = try? reader.ocr(for: fid) else {
            return .init(ok: false, summary: "no ocr for frame \(fid)", raw: "not found")
        }
        let needle = query.lowercased()
        guard let m = nodes.first(where: { !$0.text.isEmpty && $0.text.lowercased().contains(needle) }) else {
            return .init(ok: false,
                         summary: "no OCR node in frame \(fid) matched \"\(query)\"",
                         raw: "no match")
        }
        // Compute screen-pixel bbox from timeline window frame.
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.borderless) }) else {
            return .init(ok: false,
                         summary: "timeline window not visible — call show_frame first",
                         raw: "prerequisite failed")
        }
        let wf = win.frame
        let screen = win.screen ?? NSScreen.main
        let sh = screen?.frame.height ?? 0
        let ix = wf.origin.x
        let iy = sh - wf.origin.y - wf.height
        let bx = ix + m.leftX * wf.width
        let by = iy + m.topY  * wf.height
        let bw = m.width  * wf.width
        let bh = m.height * wf.height
        let summary = "match \"\(m.text.prefix(40))\" at (\(Int(bx)),\(Int(by))) \(Int(bw))×\(Int(bh))"
        let raw = "{\"x\":\(bx),\"y\":\(by),\"width\":\(bw),\"height\":\(bh),\"center_x\":\(bx+bw/2),\"center_y\":\(by+bh/2)}"
        return .init(ok: true, summary: summary, raw: raw)
    }
}
