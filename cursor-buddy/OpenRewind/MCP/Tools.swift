// Tools.swift — one implementation per registered MCP tool.
//
// Each impl takes the raw params dict (from JSON-RPC) plus a reader,
// validates arguments, calls the reader, and returns a JSON-serialisable
// `[String: Any]` (or an array under the "items" key — MCP wraps tool
// results in a `content` envelope which MCPServer handles).
//
// Handlers are pure `async throws` free functions so they can run
// concurrently. All shared state lives behind the `OpenRewindReading`
// protocol (which the actor MCPServer owns).

import Foundation

// MARK: - Small helpers

enum ToolError: Error {
    case badParam(String)
}

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoNoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func requireString(_ params: [String: Any], _ key: String) throws -> String {
    guard let v = params[key] as? String, !v.isEmpty else {
        throw ToolError.badParam("missing string param '\(key)'")
    }
    return v
}

private func optString(_ params: [String: Any], _ key: String) -> String? {
    params[key] as? String
}

private func optInt(_ params: [String: Any], _ key: String) -> Int? {
    if let n = params[key] as? Int { return n }
    if let n = params[key] as? NSNumber { return n.intValue }
    return nil
}

private func optBool(_ params: [String: Any], _ key: String) -> Bool? {
    if let b = params[key] as? Bool { return b }
    if let n = params[key] as? NSNumber { return n.boolValue }
    return nil
}

/// Accepts RFC-3339 with or without `Z`, with or without fractional
/// seconds, and naive datetimes / calendar days. See `DateParsing.swift`.
private func parseISO(_ s: String) -> Date? {
    parseFlexibleDate(s)
}

private func parseCalendarDay(_ s: String) throws -> Date {
    guard let d = parseFlexibleDate(s) else {
        throw ToolError.badParam("bad date, want YYYY-MM-DD")
    }
    return d
}

// MARK: - Frame -> wire dict

private func frameToWire(_ f: MCPFrame, snippet: String? = nil,
                         thumbnail: String? = nil) -> [String: Any] {
    var d: [String: Any] = [
        "frameId":   f.frameId,
        "createdAt": iso.string(from: f.createdAt)
    ]
    if let s = f.bundleID { d["bundleID"] = s }
    if let s = f.windowName { d["windowName"] = s }
    if let s = f.browserUrl { d["browserUrl"] = s }
    if let v = f.videoId { d["videoId"] = v }
    if let v = f.videoFrameIndex { d["videoFrameIndex"] = v }
    if let snippet { d["snippet"] = snippet }
    if let thumbnail { d["thumbnailBase64"] = thumbnail }
    return d
}

// MARK: - Tool implementations

enum Tools {

    // openrewind.search
    static func search(params: [String: Any],
                       reader: OpenRewindReading) async throws -> [String: Any] {
        let query = try requireString(params, "query")
        let from = optString(params, "from").flatMap(parseISO)
        let to = optString(params, "to").flatMap(parseISO)
        let limit = optInt(params, "limit") ?? 50

        // FIX(rewind-align-#5-2026-07-28): Rewind AskRewind's query
        // planner JSON schema (IDA @ 0x100eb1ad0) mandates keywords +
        // apps[] + websites[] + meeting:bool + starred filters. Widen
        // the FTS window and post-filter — cheaper than SQL surgery
        // and works with our existing Reader.search shape.
        let apps = optStringArray(params, "apps")
        let websites = optStringArray(params, "websites")
        let meeting = optBool(params, "meeting") ?? false
        let starredOnly = optBool(params, "starredOnly") ?? false
        let hasFilters = !(apps ?? []).isEmpty || !(websites ?? []).isEmpty
                         || meeting || starredOnly
        // Widen the raw fetch when filters will reject most rows.
        let rawLimit = hasFilters ? max(limit * 5, 200) : limit
        var hits = try await reader.search(query: query,
                                           from: from, to: to,
                                           limit: rawLimit)
        if let apps = apps, !apps.isEmpty {
            let set = Set(apps)
            hits = hits.filter { set.contains($0.frame.bundleID ?? "") }
        }
        if let websites = websites, !websites.isEmpty {
            hits = hits.filter { hit in
                guard let url = hit.frame.browserUrl?.lowercased() else { return false }
                return websites.contains { url.contains($0.lowercased()) }
            }
        }
        // meeting=true — Rewind stores meeting segments via the `event`
        // table; approximate here by browser URL hosting a known meeting
        // provider until we surface event joins.
        if meeting {
            let providers = ["zoom.us", "meet.google.com", "teams.microsoft.com",
                             "teams.live.com", "webex.com"]
            hits = hits.filter { hit in
                guard let url = hit.frame.browserUrl?.lowercased() else { return false }
                return providers.contains { url.contains($0) }
            }
        }
        // Star filter reads from sidecar JSON (StarStore), if available.
        if starredOnly {
            let stars = loadStarredIDs()
            hits = hits.filter { stars.contains($0.frame.frameId) }
        }
        let items = hits.prefix(limit).map { hit -> [String: Any] in
            frameToWire(hit.frame, snippet: hit.snippet)
        }
        return ["items": items, "count": items.count]
    }

    /// Read stars.json (StarStore) via file — MCP process is separate
    /// from Browser but they share Application Support.
    private static func loadStarredIDs() -> Set<Int64> {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("OpenRewindBrowser")
            .appendingPathComponent("stars.json")
        guard let data = try? Data(contentsOf: base),
              let arr = try? JSONDecoder().decode([Int64].self, from: data)
        else { return [] }
        return Set(arr)
    }

    private static func optStringArray(_ params: [String: Any],
                                       _ key: String) -> [String]? {
        (params[key] as? [Any])?.compactMap { $0 as? String }
    }

    // openrewind.timeline
    static func timeline(params: [String: Any],
                         reader: OpenRewindReading) async throws -> [String: Any] {
        guard let fromS = optString(params, "from"), let from = parseISO(fromS) else {
            throw ToolError.badParam("bad or missing 'from'")
        }
        guard let toS = optString(params, "to"), let to = parseISO(toS) else {
            throw ToolError.badParam("bad or missing 'to'")
        }
        let limit = optInt(params, "limit") ?? 200
        let frames = try await reader.timeline(from: from, to: to, limit: limit)
        let items = frames.map { frameToWire($0) }
        return ["items": items, "count": items.count]
    }

    // openrewind.aiContext
    static func aiContext(params: [String: Any],
                          reader: OpenRewindReading) async throws -> [String: Any] {
        guard let tsS = optString(params, "timestamp"),
              let ts = parseISO(tsS) else {
            throw ToolError.badParam("bad or missing 'timestamp'")
        }
        let neighborhood = optInt(params, "neighborhood") ?? 5
        let includeOCR = optBool(params, "includeOCR") ?? true
        let ctx = try await reader.aiContext(around: ts, neighborhood: neighborhood)

        // FIX(rewind-align-#4-2026-07-28): Rewind ships OCR text for
        // every ranked frame in AskRewind context. We used to only
        // return `frameId`+meta for neighbours, forcing callers to
        // issue N follow-up `openrewind.frame` calls. Now inline the
        // OCR text (bounded to 4 KB per frame so bundle stays small).
        // Skip when caller sets includeOCR=false.
        var centerWire = frameToWire(ctx.center)
        if includeOCR,
           let d = try? await reader.frame(id: ctx.center.frameId,
                                           includeThumbnail: false) {
            centerWire["ocrText"] = truncate(d.0.ocrText, 4_000)
        }
        var neighborWires: [[String: Any]] = []
        neighborWires.reserveCapacity(ctx.neighbors.count)
        for n in ctx.neighbors {
            var w = frameToWire(n)
            if includeOCR,
               let d = try? await reader.frame(id: n.frameId,
                                               includeThumbnail: false) {
                w["ocrText"] = truncate(d.0.ocrText, 2_000)
            }
            neighborWires.append(w)
        }

        var out: [String: Any] = [
            "center":     centerWire,
            "neighbors":  neighborWires,
            "recentApps": ctx.recentApps.map { ["bundleID": $0.bundleID,
                                                "count": $0.count] as [String: Any] }
        ]
        if let t = ctx.transcriptSnippet { out["transcriptSnippet"] = t }
        return out
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // openrewind.frame
    static func frame(params: [String: Any],
                      reader: OpenRewindReading) async throws -> [String: Any] {
        guard let id = optInt(params, "id") else {
            throw ToolError.badParam("missing integer 'id'")
        }
        let includeThumb = optBool(params, "includeThumbnail") ?? false
        let (detail, thumb) = try await reader.frame(id: Int64(id),
                                                     includeThumbnail: includeThumb)
        var out: [String: Any] = [
            "frameId":   detail.frame.frameId,
            "createdAt": iso.string(from: detail.frame.createdAt),
            "ocrText":   detail.ocrText,
            "nodes":     detail.nodes.map { node -> [String: Any] in
                [
                    "text": node.text,
                    "bbox": [
                        "x": node.x, "y": node.y,
                        "width": node.width, "height": node.height
                    ]
                ]
            }
        ]
        if let s = detail.frame.bundleID { out["bundleID"] = s }
        if let s = detail.frame.windowName { out["windowName"] = s }
        if let s = detail.frame.browserUrl { out["browserUrl"] = s }
        if includeThumb, let t = thumb { out["thumbnailBase64"] = t }
        return out
    }

    // openrewind.currentContext
    /// Reads the Browser's live playhead file
    /// (`~/Library/Application Support/OpenRewindBrowser/current-playhead.json`),
    /// then delegates to `aiContext(around:)` for the neighbourhood.
    /// Returns `{ available: false }` when Browser hasn't published a
    /// playhead this session.
    static func currentContext(params: [String: Any],
                               reader: OpenRewindReading) async throws -> [String: Any] {
        let neighborhood = optInt(params, "neighborhood") ?? 5
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("OpenRewindBrowser", isDirectory: true)
            .appendingPathComponent("current-playhead.json")
        // FIX(size-cap-2026-07-28): defensive read — the snapshot is
        // ~200 bytes; anything larger is malformed. Bound at 64 KB so a
        // bogus / attacker-planted file can't OOM MCP.
        let attrs = try? FileManager.default.attributesOfItem(atPath: base.path)
        let sz = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard sz > 0, sz < 65_536,
              let data = try? Data(contentsOf: base) else {
            return ["available": false,
                    "reason": sz >= 65_536
                              ? "playhead file oversized (\(sz)B)"
                              : "Browser has not published a playhead yet"]
        }
        struct Snap: Codable {
            let frameId: Int64; let timestamp: Date
            let bundleID: String?; let windowName: String?
            let browserUrl: String?
        }
        let dec = JSONDecoder()
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dec.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let s = try c.decode(String.self)
            if let x = isoFmt.date(from: s) { return x }
            isoFmt.formatOptions = [.withInternetDateTime]
            if let x = isoFmt.date(from: s) { return x }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "bad ISO date: \(s)")
        }
        guard let snap = try? dec.decode(Snap.self, from: data) else {
            return ["available": false, "reason": "playhead file corrupt"]
        }
        let ctx = try await reader.aiContext(around: snap.timestamp,
                                             neighborhood: neighborhood)
        var out: [String: Any] = [
            "available":  true,
            "frameId":    snap.frameId,
            "timestamp":  iso.string(from: snap.timestamp),
            "center":     frameToWire(ctx.center),
            "neighbors":  ctx.neighbors.map { frameToWire($0) },
            "recentApps": ctx.recentApps.map {
                ["bundleID": $0.bundleID, "count": $0.count] as [String: Any]
            }
        ]
        if let s = snap.bundleID { out["bundleID"] = s }
        if let s = snap.windowName { out["windowName"] = s }
        if let s = snap.browserUrl { out["browserUrl"] = s }
        if let t = ctx.transcriptSnippet { out["transcriptSnippet"] = t }
        return out
    }

    // openrewind.summary
    static func summary(params: [String: Any],
                        reader: OpenRewindReading) async throws -> [String: Any] {
        let dateStr = try requireString(params, "date")
        let day = try parseCalendarDay(dateStr)
        let s = try await reader.summary(for: day)
        return [
            "summary": s.summary,
            "apps":    s.apps.map { ["bundleID": $0.bundleID,
                                     "minutes": $0.minutes] as [String: Any] },
            "keywords": s.keywords,
            "meetings": s.meetings.map { m -> [String: Any] in
                var out: [String: Any] = [
                    "app":   m.app,
                    "start": iso.string(from: m.start),
                    "end":   iso.string(from: m.end)
                ]
                if let t = m.title { out["title"] = t }
                return out
            }
        ]
    }

    // MARK: - openrewind.resolveCitation

    /// Rewind's AskRewind ships `substituteCitations(text:citations:regexPattern:)`
    /// (IDA @ 0x100e85f90). Our host-side equivalent: one-shot resolve.
    static func resolveCitation(params: [String: Any],
                                reader: OpenRewindReading) async throws -> [String: Any] {
        guard let id = optInt64(params, "frameId") else {
            throw ToolError.badParam("frameId is required")
        }
        let (detail, thumb) = try await reader.frame(id: id,
                                                     includeThumbnail: true)
        var wire = frameToWire(detail.frame, snippet: nil, thumbnail: thumb)
        wire["ocrText"] = detail.ocrText
        wire["deeplink"] = "openrewind://frame/\(id)"
        return wire
    }

    // MARK: - openrewind.recap

    /// Raw signals only — no LLM. Host apps that register an
    /// OpenRewindRecapProvider feed these into their model.
    static func recap(params: [String: Any],
                      reader: OpenRewindReading) async throws -> [String: Any] {
        let dateStr = try requireString(params, "date")
        guard let day = Self.parseYYYYMMDD(dateStr) else {
            throw ToolError.badParam("date must be YYYY-MM-DD")
        }
        let s = try await reader.summary(for: day)
        return [
            "date": dateStr,
            "apps": s.apps.map { ["bundleID": $0.bundleID,
                                   "minutes": $0.minutes] as [String: Any] },
            "keywords": s.keywords,
            "meetings": s.meetings.map { m in [
                "app": m.app,
                "start": iso.string(from: m.start),
                "end": iso.string(from: m.end),
                "title": m.title ?? NSNull()
            ] as [String: Any] }
        ]
    }

    private static func parseYYYYMMDD(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: s)
    }

    private static func optInt64(_ params: [String: Any],
                                 _ key: String) -> Int64? {
        if let n = params[key] as? Int64 { return n }
        if let n = params[key] as? Int { return Int64(n) }
        if let n = params[key] as? NSNumber { return n.int64Value }
        return nil
    }

    // MARK: - openrewind.retentionInfo

    static func retentionInfo(params: [String: Any],
                              reader: OpenRewindReading) async throws -> [String: Any] {
        // Retention policy is set in AppState via @AppStorage, which
        // lives in the Browser process. MCP is a sibling, so read the
        // same defaults suite.
        let raw = UserDefaults.standard.string(forKey: "openrewind.retention.policy")
                  ?? "3 months"
        let policy = OpenRewindRetentionPolicy(rawValue: raw) ?? .default
        var out: [String: Any] = ["policy": policy.rawValue]
        if let days = policy.days {
            let cutoff = Calendar.current.date(byAdding: .day,
                                               value: -days, to: Date()) ?? Date()
            out["days"] = days
            out["cutoff"] = iso.string(from: cutoff)
        } else {
            out["days"] = NSNull()
            out["cutoff"] = NSNull()
        }
        return out
    }
}
