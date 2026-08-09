//
//  AssistAgentTools.swift
//  cursor-buddy
//
//  Port of heyclicky_agent/tools.py — the built-in tool set the
//  assist agent can dispatch. Every handler takes String args and
//  returns AssistAgentToolOutcome (ok flag + compact summary + raw
//  detail) so the loop can inject the summary into the next prior.
//
//  Notes vs Python:
//    · Full permissions, no sandbox (same policy — user's machine).
//    · Big-file threshold = 8 KB, matches Python OUTLINE_THRESHOLD_BYTES.
//    · append_chunk carries the same 30 s content-hash dedup that
//      Python Root Cause #13 introduced.
//    · Runs on the main actor — Swift Concurrency handles the async
//      shell/http calls without dragging blocking threads.
//

import AppKit
import Foundation
import CryptoKit

public enum AssistAgentToolsConstants {
    public static let outlineThresholdBytes = 8_000
    public static let outlineHeadLines = 25
    public static let writeSingleShotCap = 1_500
    public static let appendDedupWindowSec: TimeInterval = 30
    /// Hard ceiling on a single read_file call. Anything larger has
    /// to go through offset+length slicing or grep. Keeps a runaway
    /// path from blowing up assist agent memory.
    public static let readMaxBytes = 20 * 1024 * 1024   // 20 MB
    /// Threshold above which text file content flows through the
    /// language-aware compaction stack (Stage 3) before being
    /// injected as tool result. Below this we return the raw text.
    public static let compactSourceThresholdBytes = 20_000
    /// Budget passed to `assistCompactionCompactSource` when the
    /// text file is large — keeps the injected step_log entry
    /// under ~4k chars so prior stays lean across many rounds.
    public static let compactSourceBudgetChars = 4_000
    public static let memoryFileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("OpenClicky/heyclicky-agent-memory.jsonl")
}

@MainActor
public final class AssistAgentBuiltInTools: AssistAgentToolDispatcher {

    /// (path → recent [(sha1prefix, timestamp)])
    private var appendDedup: [String: [(sig: String, ts: Date)]] = [:]

    /// Pending image payload (JPEG bytes + real pixel dimensions)
    /// produced by `截屏` or `文件内容`-on-image-path. The loop reads
    /// this on the next round and passes it as `priorImage` through
    /// the transport so the model can literally see the image
    /// alongside the text prior. Dimensions are the ACTUAL pixel
    /// dims after downscale — the server keys coordinate transforms
    /// off these, so passing the pixel-font page size (as I did
    /// before) causes every point beat to land in the wrong place.
    public struct PendingImage: Sendable {
        public let jpeg: Data
        public let width: Int
        public let height: Int
    }
    public var pendingImage: PendingImage?

    /// Cache of the most recent JPEG we produced so `重新获取图片` can
    /// re-attach it on demand. Distinct from `pendingImage` which is
    /// consumed once — this survives consumption. Python parity:
    /// `client.get_latest_image()` (client.py).
    private var lastImage: PendingImage?

    /// Rate-limit repeat screenshots inside a single loop invocation
    /// — the model sometimes keeps re-requesting screenshots when
    /// the round couldn't parse the image, which burns capture time.
    private var lastScreenshotAt: Date = .distantPast
    private static let screenshotDebounceSec: TimeInterval = 2.0

    public init() {}

    /// Shared todos list — TaskListV2 semantics. Rewritten wholesale
    /// on each `todo_write`. In-memory; cleared when the agent exits.
    private var todos: [[String: String]] = []

    public func dispatch(kind: String,
                         tool: String,
                         args: [String: String]) async throws -> AssistAgentToolOutcome
    {
        switch tool {
        case "screenshot":    return await handleScreenshot(args)
        case "read_file":     return await handleReadFile(args)
        case "file_outline":  return handleFileOutline(args)
        case "list_dir":      return handleListDir(args)
        case "glob":          return handleGlob(args)
        case "grep":          return await handleGrep(args)
        case "write_file":    return handleWriteFile(args)
        case "edit_file":     return handleEditFile(args)
        case "multi_edit":    return handleMultiEdit(args)
        case "append_chunk":  return handleAppendChunk(args)
        case "apply_diff":    return await handleApplyDiff(args)
        case "run_shell":     return await handleRunShell(args)
        case "http_get":      return await handleHttpGet(args)
        case "web_fetch":     return await handleHttpGet(args) // alias
        case "web_search":    return handleBuiltinSearch(args)
        case "save_memory":   return handleSaveMemory(args)
        case "read_memory":   return handleReadMemory(args)
        case "pin_memory":    return handlePinMemory(args)
        case "query_history": return handleQueryHistory(args)
        case "todo_write":    return handleTodoWrite(args)
        case "dispatch_parallel":
            return await handleDispatchParallel(args)
        case "rewind_search", "rewind_frame", "rewind_recap",
             "rewind_coverage", "rewind_last", "rewind_app_usage",
             "rewind_meetings", "rewind_browser_history", "rewind_top_domains",
             "rewind_ocr":
            return await AssistAgentRewindTools.run(tool: tool, args: args)
        case "xlb_search_topic", "xlb_get_topic", "xlb_get_topic_meta",
             "xlb_get_topic_section", "xlb_graph", "xlb_agent_state",
             "xlb_execute_command":
            return await handleXLBSensor(tool: tool, args: args)
        case "xlb_grammar_help":
            return handleXLBGrammarHelp()
        case "_reupload_image":
            // Python parity: 重新获取图片 replays the most-recent JPEG
            // through the vision channel by re-arming `pendingImage`.
            // Useful when the previous round dropped the image after
            // consumption and the model wants to re-inspect it.
            if let cached = lastImage {
                pendingImage = cached
                return .init(ok: true,
                             summary: "已排队,下一轮会把之前上传过的位图重新附上,请稍等再读。",
                             raw: "reupload_image: cached bitmap re-armed (\(cached.jpeg.count) bytes, \(cached.width)x\(cached.height))")
            }
            return .init(ok: false,
                         summary: "本地没有缓存的图片可以重传,请让用户重新触发生成。",
                         raw: "reupload_image: no cached bitmap available")
        default:
            // MCP fallthrough — `mcp:<server>:<tool>` canonicalised
            // names route through `AssistAgentMCPRegistry.call(...)`.
            if tool.hasPrefix("mcp:") {
                return await handleMCPCall(tool: tool, args: args)
            }
            return .init(ok: false,
                         summary: "unknown_tool: \(tool)",
                         raw: "no dispatch entry for \(tool)")
        }
    }

    /// Detect a common image format by magic bytes. When it's already
    /// JPEG, return as-is; otherwise transcode through NSBitmapImageRep
    /// so upstream (which expects `image/jpeg`) can consume it.
    /// Returns nil when the file isn't a recognised image — caller
    /// falls back to the normal text path.
    private static func imageBytesForModel(url: URL, raw: Data) -> Data? {
        guard raw.count >= 8 else { return nil }
        let b = [UInt8](raw.prefix(12))
        let isJPEG = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
        let isPNG  = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
        let isGIF  = b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46
        let isWebP = raw.count >= 12
            && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        let isHEIC = raw.count >= 12
            && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70
        let magicMatched = isJPEG || isPNG || isGIF || isWebP || isHEIC
        if !magicMatched {
            // Also treat known extensions as image intent — some CDN
            // images ship without magic bytes we recognise.
            let ext = url.pathExtension.lowercased()
            let isImageExt = ["jpg","jpeg","png","gif","webp","heic","bmp","tiff"].contains(ext)
            if !isImageExt { return nil }
        }
        if isJPEG { return raw }
        // Transcode to JPEG. NSBitmapImageRep JPEG encoder cannot
        // preserve alpha — transparent PNGs render as SOLID BLACK on
        // areas that used to be transparent. Composite onto white
        // first so a Slack icon / UI screenshot with transparency
        // still looks like the human sees it.
        guard let img = NSImage(data: raw) else { return nil }
        let size = img.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let opaqueRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 3,   // no alpha
            hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep = opaqueRep,
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        img.draw(in: NSRect(origin: .zero, size: size),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8])
    }

    // MARK: - screenshot

    private func handleScreenshot(_ args: [String: String]) async -> AssistAgentToolOutcome {
        // Debounce: repeat requests within 2 s reuse the last capture
        // so the model can't accidentally burn capture time in a tight
        // loop.
        let now = Date()
        if let cached = pendingImage,
           now.timeIntervalSince(lastScreenshotAt) < Self.screenshotDebounceSec {
            return .init(ok: true,
                         summary: "reusing recent screenshot \(cached.width)x\(cached.height) (\(cached.jpeg.count / 1024) KB)",
                         raw: "screenshot cached")
        }
        do {
            let captures = try await CompanionScreenCaptureUtility
                .captureCursorScreenAsJPEG()
            guard let first = captures.first else {
                return .init(ok: false,
                             summary: "no screen captured",
                             raw: "SCShareableContent returned no displays")
            }
            // Retina screenshots can be 3456x2160 = way over 200 KB
            // body cap. Downscale through the same pipeline the PTT
            // screenshot path uses.
            let (payload, w, h) = Self.compressForUpload(first.imageData)
            let _pi = PendingImage(jpeg: payload, width: w, height: h); pendingImage = _pi; lastImage = _pi
            lastScreenshotAt = now
            return .init(
                ok: true,
                summary: "captured screen \(w)x\(h) (\(payload.count / 1024) KB) — attached to your next round as image input",
                raw: "screenshot ready")
        } catch {
            return .init(ok: false,
                         summary: "screenshot failed",
                         raw: error.localizedDescription)
        }
    }

    /// Downscale to ≤1568px on the long side and JPEG-recompress at
    /// q=0.75 — matches HeyClickyChatToolCallClient's existing PTT
    /// screenshot path. Keeps body under the proxy's 200 KB cap and
    /// keeps vision-token cost predictable.
    private static func compressForUpload(_ jpeg: Data) -> (data: Data, width: Int, height: Int) {
        if let scaled = HeyClickyChatToolCallClient.downscaleJPEG(
            jpeg, maxDimension: 1568, quality: 0.75) {
            return (scaled.0, scaled.1, scaled.2)
        }
        // Fallback: try to at least read the source dimensions so the
        // model gets accurate "here's what you're seeing" numbers.
        if let img = NSImage(data: jpeg) {
            return (jpeg, Int(img.size.width), Int(img.size.height))
        }
        return (jpeg, 0, 0)
    }

    // MARK: - read_file

    private func handleReadFile(_ args: [String: String]) async -> AssistAgentToolOutcome {
        guard let path = args["path"], !path.isEmpty else {
            return .init(ok: false, summary: "missing path", raw: "path required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        // Hard cap on RAM-resident reads — a 30 MB photo would OOM if
        // we transcoded through NSImage. The 20 MB threshold covers
        // every reasonable text / image use case (Retina photos are
        // 5-8 MB, source code files never approach this).
        let attrs = try? FileManager.default.attributesOfItem(atPath: expanded)
        if let sz = attrs?[.size] as? Int, sz > AssistAgentToolsConstants.readMaxBytes {
            return .init(
                ok: false,
                summary: "file too large: \(path) is \(sz / 1024 / 1024) MB (cap: \(AssistAgentToolsConstants.readMaxBytes / 1024 / 1024) MB)",
                raw: "use grep / head / offset+length to read a slice")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .init(ok: false, summary: "read failed: \(path)",
                         raw: "could not read \(expanded)")
        }

        // Image file path: hand the bytes to the transport as
        // priorImage on the next round so the model can see it.
        // Sniff by magic bytes for JPEG / PNG / GIF / WebP / HEIC —
        // extensions lie, magic bytes don't.
        if let jpegRaw = Self.imageBytesForModel(url: url, raw: data) {
            let (payload, w, h) = Self.compressForUpload(jpegRaw)
            let _pi = PendingImage(jpeg: payload, width: w, height: h); pendingImage = _pi; lastImage = _pi
            lastScreenshotAt = Date()
            let sizeKB = payload.count / 1024
            return .init(
                ok: true,
                summary: "loaded image \(path) — resized to \(w)x\(h), \(sizeKB) KB, attached to your next round as vision input",
                raw: "image ready for vision")
        }

        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let offset = Int(args["offset"] ?? "")
        let length = Int(args["length"] ?? "")

        if offset != nil || length != nil {
            let off = offset ?? 0
            let n = length ?? data.count
            let end = min(off + n, data.count)
            let slice = data.subdata(in: off..<end)
            let sliceText = String(data: slice, encoding: .utf8)
                ?? String(decoding: slice, as: UTF8.self)
            let summary = "read \(path) [\(off)..<\(end)] \(slice.count)B"
            return .init(ok: true, summary: summary, raw: sliceText)
        }

        if data.count <= AssistAgentToolsConstants.outlineThresholdBytes {
            return .init(ok: true,
                         summary: "read \(path) full \(data.count)B",
                         raw: text)
        }

        // Between 8 KB (outline threshold) and 20 KB (compact threshold)
        // we still ship the outline — the model can then slice with
        // offset/length if it needs a specific region.
        if data.count <= AssistAgentToolsConstants.compactSourceThresholdBytes {
            let outline = makeOutline(text)
            let hint = "file mid-size (\(data.count) B); showing outline. Use offset+length or grep for specific regions."
            return .init(ok: true,
                         summary: "read \(path) outline (\(data.count)B)",
                         raw: outline + "\n\n[hint] " + hint)
        }

        // Large file: TWO-CHANNEL delivery.
        //
        //   Channel 1 (text): language-aware skeleton via Stage-3
        //     compaction — Python AST for .py, def/class/fn regex for
        //     Swift/Rust/TS/Go, head+tail fallback otherwise. Bounded
        //     to `compactSourceBudgetChars` so prior stays lean.
        //
        //   Channel 2 (vision, optional): full text rendered to a
        //     grayscale JPEG via the bitmap-font atlas (Stage-4
        //     pipeline). Model can vision-read the whole file when
        //     it needs a line the skeleton dropped — vision tokens
        //     for a same-content JPEG are typically 3-5x cheaper
        //     than equivalent text tokens for long source.
        //
        // The vision channel is skipped when the resulting JPEG
        // exceeds ~150 KB (body cap is 200 KB and we need headroom
        // for the query text). Model then falls back to slicing.
        let compact = assistCompactionCompactSource(
            text,
            path: expanded,
            budget: AssistAgentToolsConstants.compactSourceBudgetChars)
        var visionAttached = false
        var visionInfo = ""
        if let rendered = AssistAgentPriorImage.renderTextToJPEG(text, quality: 0.65),
           rendered.jpeg.count <= 150 * 1024 {
            let _pi = PendingImage(
                jpeg: rendered.jpeg, width: rendered.width, height: rendered.height)
            pendingImage = _pi
            lastImage = _pi
            lastScreenshotAt = Date()
            visionAttached = true
            visionInfo = " · full-text rendered as vision input (\(rendered.jpeg.count / 1024) KB, \(rendered.pageCount) page\(rendered.pageCount == 1 ? "" : "s"))"
        }
        let sizeHint = "file large (\(data.count) B, \(text.count) chars → skeleton \(compact.count) chars)\(visionInfo). For precise slices use offset+length or grep."
        let noVisionHint = visionAttached ? "" : "\n[note] file too long to render as vision — use grep/slice for specifics."
        return .init(ok: true,
                     summary: "read \(path) compacted (\(data.count)B → \(compact.count)B)\(visionAttached ? " + full-text image" : "")",
                     raw: compact + "\n\n[hint] " + sizeHint + noVisionHint)
    }

    private func makeOutline(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        let head = lines.prefix(AssistAgentToolsConstants.outlineHeadLines)
        out.append(contentsOf: head.map(String.init))
        out.append("--- [outline: definitions] ---")

        // Cheap def/class/func detector — same intent as Python DEF_RE.
        let signaturePattern = #"^\s*(?:async\s+def|def|class|func|fn|type|struct|impl|public\s|private\s|protected\s|export\s)"#
        guard let re = try? NSRegularExpression(pattern: signaturePattern,
                                                 options: [.anchorsMatchLines]) else {
            return out.joined(separator: "\n")
        }
        for (i, line) in lines.enumerated().dropFirst(AssistAgentToolsConstants.outlineHeadLines) {
            let s = String(line)
            let ns = s as NSString
            if re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
                out.append("L\(i + 1): \(s.trimmingCharacters(in: .whitespaces))")
                if out.count > 200 { break }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - list_dir

    private func handleListDir(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let path = args["path"] else {
            return .init(ok: false, summary: "missing path", raw: "path required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: expanded) else {
            return .init(ok: false, summary: "cannot list \(path)", raw: "")
        }
        let sorted = entries.sorted()
        let rendered = sorted.map { name -> String in
            let full = (expanded as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
        return .init(ok: true,
                     summary: "list_dir \(path) \(sorted.count) entries",
                     raw: rendered.joined(separator: "\n"))
    }

    // MARK: - grep

    private func handleGrep(_ args: [String: String]) async -> AssistAgentToolOutcome {
        guard let path = args["path"], let pattern = args["pattern"] else {
            return .init(ok: false, summary: "missing args", raw: "path + pattern required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        return await runProcess(
            launchPath: "/usr/bin/grep",
            arguments: ["-rn", "--color=never", pattern, expanded],
            timeoutSec: 20,
            summaryPrefix: "grep '\(pattern)' \(path)"
        )
    }

    // MARK: - write_file

    private func handleWriteFile(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let path = args["path"], let content = args["content"] else {
            return .init(ok: false, summary: "missing args",
                         raw: "path + content required")
        }
        if content.count > AssistAgentToolsConstants.writeSingleShotCap {
            return .init(ok: false,
                         summary: "content > \(AssistAgentToolsConstants.writeSingleShotCap) chars — use append_chunk",
                         raw: "single write cap")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            let mode = args["mode"] ?? "overwrite"
            if mode == "append", let existing = try? String(contentsOf: url, encoding: .utf8) {
                try (existing + content).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
            return .init(ok: true,
                         summary: "wrote \(path) \(content.count)B",
                         raw: "ok")
        } catch {
            return .init(ok: false,
                         summary: "write failed: \(path)",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - edit_file

    private func handleEditFile(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let path = args["path"],
              let old = args["old"], let new = args["new"] else {
            return .init(ok: false, summary: "missing args",
                         raw: "path + old + new required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return .init(ok: false, summary: "read failed: \(path)", raw: "")
        }
        let hits = existing.components(separatedBy: old).count - 1
        if hits == 0 {
            return .init(ok: false, summary: "old text not found in \(path)",
                         raw: "old not found")
        }
        if hits > 1 {
            return .init(ok: false,
                         summary: "old text ambiguous (\(hits) hits) in \(path)",
                         raw: "old must appear exactly once")
        }
        let updated = existing.replacingOccurrences(of: old, with: new)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return .init(ok: true,
                         summary: "edited \(path)",
                         raw: "old→new applied")
        } catch {
            return .init(ok: false,
                         summary: "write failed: \(path)",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - append_chunk (with dedup — Root Cause #13)

    private func handleAppendChunk(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let path = args["path"], let chunk = args["chunk"] else {
            return .init(ok: false, summary: "missing args",
                         raw: "path + chunk required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let first = (args["first"] ?? "").lowercased() == "true"

        // Dedup: sha1(chunk) hit within window → no-op with success.
        let sig = sha1Prefix(chunk)
        let now = Date()
        var recent = (appendDedup[expanded] ?? []).filter {
            now.timeIntervalSince($0.ts) < AssistAgentToolsConstants.appendDedupWindowSec
        }
        if recent.contains(where: { $0.sig == sig }) {
            return .init(ok: true,
                         summary: "append_chunk \(path) DEDUP no-op",
                         raw: "identical chunk within 30s window")
        }
        recent.append((sig: sig, ts: now))
        appendDedup[expanded] = recent

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        do {
            if first {
                try chunk.write(to: url, atomically: true, encoding: .utf8)
            } else if let existing = try? String(contentsOf: url, encoding: .utf8) {
                try (existing + chunk).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try chunk.write(to: url, atomically: true, encoding: .utf8)
            }
            return .init(ok: true,
                         summary: "append_chunk \(path) +\(chunk.count)B",
                         raw: "ok")
        } catch {
            return .init(ok: false,
                         summary: "append_chunk failed: \(path)",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - run_shell

    private func handleRunShell(_ args: [String: String]) async -> AssistAgentToolOutcome {
        guard let cmd = args["cmd"] else {
            return .init(ok: false, summary: "missing cmd", raw: "cmd required")
        }
        let timeout = Double(args["timeout"] ?? "60") ?? 60
        return await runProcess(
            launchPath: "/bin/zsh",
            arguments: ["-lc", cmd],
            timeoutSec: timeout,
            summaryPrefix: "run \(cmd.prefix(40))"
        )
    }

    // MARK: - http_get

    private func handleHttpGet(_ args: [String: String]) async -> AssistAgentToolOutcome {
        guard let raw = args["url"], let url = URL(string: raw) else {
            return .init(ok: false, summary: "bad url", raw: "url required")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("openclicky-assist-agent/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (body, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: body, encoding: .utf8) ?? "<binary \(body.count)B>"
            return .init(
                ok: (200..<300).contains(status),
                summary: "GET \(url.host ?? "?") \(status) \(body.count)B",
                raw: text)
        } catch {
            return .init(ok: false,
                         summary: "http_get failed",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - save_memory / read_memory / pin_memory

    private func handleSaveMemory(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let text = args["text"], !text.isEmpty else {
            return .init(ok: false, summary: "empty text", raw: "text required")
        }
        let entry: [String: String] = [
            "text": text,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try? JSONSerialization.data(withJSONObject: entry)
        let line = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n"
        let url = AssistAgentToolsConstants.memoryFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
        return .init(ok: true, summary: "saved memory (\(text.count)B)", raw: "ok")
    }

    private func handleReadMemory(_ args: [String: String]) -> AssistAgentToolOutcome {
        let limit = Int(args["limit"] ?? "20") ?? 20
        let url = AssistAgentToolsConstants.memoryFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .init(ok: true, summary: "no memory yet", raw: "")
        }
        let lines = text.split(separator: "\n").suffix(limit)
        return .init(ok: true,
                     summary: "memory: \(lines.count) entries",
                     raw: lines.joined(separator: "\n"))
    }

    private func handlePinMemory(_ args: [String: String]) -> AssistAgentToolOutcome {
        // Signal to the loop that this fact should be pinned; the
        // loop's caller inspects `raw` and calls session.pinMemory().
        // For now we just echo — the wiring happens in the loop.
        guard let text = args["text"], !text.isEmpty else {
            return .init(ok: false, summary: "empty pin", raw: "text required")
        }
        return .init(ok: true, summary: "PIN: \(text.prefix(60))", raw: text)
    }

    // MARK: - file_outline (explicit outline of any-size file)

    private func handleFileOutline(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let path = args["path"] else {
            return .init(ok: false, summary: "missing path", raw: "path required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return .init(ok: false, summary: "read failed: \(path)", raw: "")
        }
        return .init(ok: true,
                     summary: "outline \(path)",
                     raw: makeOutline(text))
    }

    // MARK: - glob

    private func handleGlob(_ args: [String: String]) -> AssistAgentToolOutcome {
        let root = (args["root"] ?? ".") as NSString
        guard let pattern = args["pattern"] else {
            return .init(ok: false, summary: "missing pattern", raw: "pattern required")
        }
        let expanded = root.expandingTildeInPath
        // Use /usr/bin/find as a robust portable path — no need to
        // reimplement ** semantics in Swift.
        let findArgs: [String]
        if pattern.contains("**") {
            let leaf = pattern.replacingOccurrences(of: "**/", with: "")
            findArgs = ["-L", expanded, "-type", "f", "-name", leaf]
        } else {
            findArgs = ["-L", expanded, "-type", "f", "-name", pattern]
        }
        let task = Process()
        task.launchPath = "/usr/bin/find"
        task.arguments = findArgs
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do { try task.run() } catch {
            return .init(ok: false,
                         summary: "glob launch failed",
                         raw: error.localizedDescription)
        }
        task.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let matches = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let truncated = matches.count > 500
        let head = Array(matches.prefix(500))
        return .init(ok: true,
                     summary: "glob '\(pattern)' \(matches.count) hits\(truncated ? " (truncated)" : "")",
                     raw: head.joined(separator: "\n"))
    }

    // MARK: - multi_edit (atomic multi-find→replace)

    private func handleMultiEdit(_ args: [String: String]) -> AssistAgentToolOutcome {
        // Args here are the flattened top-level params; the model
        // passes edits as a JSON-encoded string in `edits_json`.
        guard let path = args["path"] else {
            return .init(ok: false, summary: "missing path", raw: "path required")
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let orig = try? String(contentsOf: url, encoding: .utf8) else {
            return .init(ok: false, summary: "read failed: \(path)", raw: "")
        }
        let json = args["edits_json"] ?? args["edits"] ?? ""
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .init(ok: false,
                         summary: "edits_json invalid",
                         raw: "expected JSON array of {old_string,new_string,replace_all?}")
        }
        var text = orig
        var applied: [String] = []
        for (i, edit) in arr.enumerated() {
            let old = edit["old_string"] as? String ?? ""
            let new = edit["new_string"] as? String ?? ""
            let replaceAll = (edit["replace_all"] as? Bool) ?? false
            if old.isEmpty {
                return .init(ok: false,
                             summary: "edit #\(i) missing old_string",
                             raw: "rolled back")
            }
            let hits = text.components(separatedBy: old).count - 1
            if hits == 0 {
                return .init(ok: false,
                             summary: "edit #\(i) old_string not found",
                             raw: "rolled back")
            }
            if replaceAll {
                text = text.replacingOccurrences(of: old, with: new)
                applied.append("#\(i) x\(hits)")
            } else {
                if hits > 1 {
                    return .init(ok: false,
                                 summary: "edit #\(i) ambiguous (\(hits)); set replace_all",
                                 raw: "rolled back")
                }
                if let r = text.range(of: old) {
                    text.replaceSubrange(r, with: new)
                }
                applied.append("#\(i) x1")
            }
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .init(ok: true,
                         summary: "multi_edit \(path) \(applied.count) edits",
                         raw: applied.joined(separator: "\n"))
        } catch {
            return .init(ok: false,
                         summary: "multi_edit write failed",
                         raw: error.localizedDescription)
        }
    }

    // MARK: - apply_diff

    private func handleApplyDiff(_ args: [String: String]) async -> AssistAgentToolOutcome {
        guard let path = args["path"], let diff = args["diff"] else {
            return .init(ok: false, summary: "missing args",
                         raw: "path + diff required")
        }
        // Pipe diff to /usr/bin/patch -p0 <path>
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.launchPath = "/usr/bin/patch"
                task.arguments = ["-p0", (path as NSString).expandingTildeInPath]
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                task.standardInput = inPipe
                task.standardOutput = outPipe
                task.standardError = errPipe
                do { try task.run() } catch {
                    cont.resume(returning: AssistAgentToolOutcome(
                        ok: false,
                        summary: "patch launch failed",
                        raw: error.localizedDescription))
                    return
                }
                inPipe.fileHandleForWriting.write(Data(diff.utf8))
                try? inPipe.fileHandleForWriting.close()
                task.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let ok = task.terminationStatus == 0
                cont.resume(returning: AssistAgentToolOutcome(
                    ok: ok,
                    summary: "apply_diff \(path) exit=\(task.terminationStatus)",
                    raw: out + (err.isEmpty ? "" : "\n[stderr]\n" + err)))
            }
        }
    }

    // MARK: - web_search (built-in signal — no local execution)

    private func handleBuiltinSearch(_ args: [String: String]) -> AssistAgentToolOutcome {
        let query = args["query"] ?? ""
        let hint = "no local search backend. Use your built-in web search and answer in next round."
        return .init(ok: true,
                     summary: "web_search signal: \(query.prefix(60))",
                     raw: hint)
    }

    // MARK: - query_history

    private func handleQueryHistory(_ args: [String: String]) -> AssistAgentToolOutcome {
        guard let query = args["query"], !query.isEmpty else {
            return .init(ok: false, summary: "missing query", raw: "query required")
        }
        let limit = Int(args["limit"] ?? "5") ?? 5
        let histDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".heyclicky-agent-history")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: histDir, includingPropertiesForKeys: nil) else {
            return .init(ok: true, summary: "no history yet", raw: "")
        }
        let files: [URL]
        if let sess = args["session_id"], !sess.isEmpty {
            let candidate = histDir.appendingPathComponent("\(sess).jsonl")
            files = FileManager.default.fileExists(atPath: candidate.path) ? [candidate] : []
        } else {
            files = Array(entries.filter { $0.pathExtension == "jsonl" }
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .suffix(3))
        }
        let regex = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: query),
            options: [.caseInsensitive])
        var matches: [String] = []
        outer: for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let s = String(line)
                if let re = regex,
                   re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
                    matches.append("\(f.lastPathComponent): \(String(s.prefix(300)))")
                    if matches.count >= limit { break outer }
                }
            }
        }
        return .init(ok: true,
                     summary: "query_history '\(query)' \(matches.count) hits",
                     raw: matches.joined(separator: "\n"))
    }

    // MARK: - xlb sensor tools

    /// Route xlb_* tool calls through XLBSensorTools. Chinese arg
    /// names have already been mapped to English by AssistAgentLoop's
    /// cnToTool table. When xlbEnabled() is off, refuse fast so the
    /// model doesn't burn rounds trying to use a disabled subsystem.
    private func handleXLBSensor(tool: String, args: [String: String])
        async -> AssistAgentToolOutcome
    {
        if !AppBundleConfiguration.xlbEnabled() {
            return .init(ok: false,
                         summary: "xlinkBook 未启用 (Settings > MCP subsystems)",
                         raw: "xlb disabled")
        }
        // Convert [String: String] to [String: Any]; parse ints/bools
        // for the numeric/boolean fields XLBSensorTools inspects.
        var payload: [String: Any] = [:]
        let intKeys: Set<String> = ["limit", "offset", "hops", "maxDepth"]
        let boolKeys: Set<String> = ["with_meta", "consume"]
        for (k, v) in args {
            if intKeys.contains(k), let n = Int(v) {
                payload[k] = n
            } else if boolKeys.contains(k) {
                let lo = v.lowercased()
                if lo == "true" || lo == "1" || lo == "yes" {
                    payload[k] = true
                } else if lo == "false" || lo == "0" || lo == "no" {
                    payload[k] = false
                } else {
                    payload[k] = v
                }
            } else {
                payload[k] = v
            }
        }
        let (envelope, isError) = await XLBSensorTools.execute(
            name: tool, arguments: payload)

        // Extract content[0].text (JSON string) from the MCP envelope.
        var rawText = ""
        if let items = envelope["content"] as? [[String: Any]],
           let first = items.first,
           let text = first["text"] as? String {
            rawText = text
        }

        // Try to parse the JSON body and pick a summary field.
        var summary = ""
        if let data = rawText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["results"] as? String {
                summary = s
            } else if let s = obj["content"] as? String {
                summary = s
            } else if let s = obj["state"] as? String {
                summary = s
            } else if let s = obj["meta"] as? String {
                summary = s
            } else if let s = obj["error"] as? String {
                summary = s
            } else {
                summary = rawText
            }
        } else {
            summary = rawText
        }
        // Keep the summary tight for prior injection; raw carries full.
        let capped = summary.count > 800
            ? String(summary.prefix(800)) + "…"
            : summary
        return .init(ok: !isError, summary: capped, raw: rawText)
    }

    // MARK: - xlb grammar help

    /// Static grammar reference for xlb browse_cmd. No sensor, no
    /// network, no sqlite — just a hardcoded const returned via the
    /// standard outcome envelope. The model calls this when it wants
    /// to construct complex browse_cmd expressions like ">>Topic/",
    /// "->Topic/", "??keyword", "=>alias", "#category", or combinators.
    private func handleXLBGrammarHelp() -> AssistAgentToolOutcome {
        let block = """
        xlb browse_cmd 语法参考:
          >Topic/         topic 内容
          >Topic/tag:     只看某 tag section (github/website/youtube/searchin/command/paper 等)
          >Topic/tag:X    tag section 内文本过滤
          >>Topic/        unfold: 展开被引用的主题内联
          >>>Topic/       深展开
          ->Topic/        反向引用 (谁引用 Topic)
          ??keyword       模糊搜
          =>alias         按别名找 canonical topic
          ?>keyword       宽松 fuzzy
          ?=>alias        大小写不敏感 alias
          %>keyword       特殊 fuzzy
          #category       分类查询
          + * & ;         组合操作 (交/并/差/串)
        """
        return AssistAgentToolOutcome(ok: true, summary: block, raw: block)
    }

    // MARK: - MCP tool call

    /// Route `mcp:<server>:<tool>` through the registry actor. Args
    /// are the raw String→String map — we JSON-decode a single `args`
    /// entry if present, else pass all args as-is.
    private func handleMCPCall(tool: String, args: [String: String])
        async -> AssistAgentToolOutcome
    {
        var payload: [String: Any] = [:]
        if let argsJSON = args["args_json"] ?? args["args"],
           let data = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = obj
        } else {
            for (k, v) in args where k != "args_json" && k != "args" {
                payload[k] = v
            }
        }
        do {
            let result = try await AssistAgentMCPRegistry.shared.call(
                canonical: tool, args: payload)
            let bytes = (try? JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted])) ?? Data()
            let raw = String(data: bytes, encoding: .utf8) ?? "\(result)"
            let summary = raw.count > 500 ? String(raw.prefix(500)) + "…" : raw
            return .init(ok: true, summary: summary, raw: raw)
        } catch {
            return .init(ok: false,
                         summary: "mcp 调用失败 \(tool): \(error)",
                         raw: "\(error)")
        }
    }

    // MARK: - dispatch_parallel

    /// Fan out N sub-agent runs against the exported account pool.
    /// Args: `tasks` = JSON array of {id, prompt, workdir?, max_rounds?}.
    /// Guards against nested dispatch (fork-bomb) and refuses when no
    /// primary credential is available. Returns an aggregated summary
    /// suitable for prior injection.
    private func handleDispatchParallel(_ args: [String: String]) async -> AssistAgentToolOutcome {
        let json = args["tasks"] ?? args["tasks_json"] ?? ""
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return .init(ok: false,
                         summary: "dispatch_parallel: 参数 tasks 必须是 JSON 数组 [{id,prompt,workdir?,max_rounds?}]",
                         raw: "invalid tasks json")
        }
        // Build sub-tasks (skip malformed entries silently).
        let subs: [AssistAgentSubTask] = arr.compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty,
                  let prompt = d["prompt"] as? String, !prompt.isEmpty else { return nil }
            return AssistAgentSubTask(
                id: id,
                prompt: prompt,
                workdir: (d["workdir"] as? String)
                    ?? FileManager.default.currentDirectoryPath,
                maxRounds: (d["max_rounds"] as? Int) ?? 5)
        }
        guard !subs.isEmpty else {
            return .init(ok: false,
                         summary: "dispatch_parallel: 未识别出有效子任务",
                         raw: "no valid subtasks")
        }
        // Fetch primary credential from Keychain so at least one lane
        // has auth. Falls back to a blank cred if not signed in — the
        // sub-agent will surface the auth error itself.
        let primaryEmail = AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey) ?? ""
        let primaryToken = AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionAccessTokenDefaultsKey) ?? ""
        let primaryRefresh = AppBundleConfiguration.heyClickyReadKeychainSecret(
            forKey: AppBundleConfiguration.heyClickySessionRefreshTokenDefaultsKey) ?? ""
        let primary = AssistAgentCredential(
            email: primaryEmail, accessToken: primaryToken,
            refreshToken: primaryRefresh)

        let dispatcher = AssistAgentParallelDispatcher(
            runner: AssistAgentDefaultSubagentRunner())
        let started = Date()
        let results: [AssistAgentSubResult]
        do {
            results = try await dispatcher.dispatchWaitAll(
                tasks: subs, primary: primary)
        } catch AssistAgentParallelError.nestedDispatchForbidden {
            return .init(ok: false,
                         summary: "dispatch_parallel: 子任务内不能再次分派并行,避免 fork-bomb。",
                         raw: "nested dispatch")
        } catch {
            return .init(ok: false,
                         summary: "dispatch_parallel 失败: \(error)",
                         raw: "\(error)")
        }
        // Aggregate — Python parity: agent.py::_summarise_result "分派并行".
        let wall = Int(Date().timeIntervalSince(started))
        let nOK = results.filter { $0.ok }.count
        var lines: [String] = []
        lines.append("并行 \(results.count) 子任务 · \(nOK)/\(results.count) 成功 · 挂钟 \(wall)s")
        for r in results {
            let tag = r.ok ? "✓" : "✗"
            let head = (r.finalText.isEmpty ? r.errorText : r.finalText)
                .replacingOccurrences(of: "\n", with: " ")
            let shortHead = head.count > 80 ? String(head.prefix(80)) + "…" : head
            let files = r.filesTouched.isEmpty
                ? ""
                : " [\(r.filesTouched.prefix(2).joined(separator: ","))" +
                  (r.filesTouched.count > 2 ? "…" : "") + "]"
            lines.append("  \(tag) \(r.id) [\(r.credential)]: \(shortHead)\(files)")
        }
        let summary = lines.joined(separator: "\n")
        return .init(ok: nOK > 0, summary: summary, raw: summary)
    }

    // MARK: - todo_write

    private func handleTodoWrite(_ args: [String: String]) -> AssistAgentToolOutcome {
        let json = args["todos_json"] ?? args["todos"] ?? ""
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .init(ok: false,
                         summary: "todos_json invalid",
                         raw: "expected JSON array of {content, status}")
        }
        todos = arr.map { entry in
            [
                "content": (entry["content"] as? String) ?? "",
                "status":  (entry["status"] as? String) ?? "pending"
            ]
        }
        let rendered = todos.enumerated()
            .map { i, t in "[\(t["status"] ?? "")] \(i + 1). \(t["content"] ?? "")" }
            .joined(separator: "\n")
        return .init(ok: true,
                     summary: "todo_write \(todos.count) items",
                     raw: rendered)
    }

    // MARK: - Shared helpers

    private func runProcess(launchPath: String,
                            arguments: [String],
                            timeoutSec: Double,
                            summaryPrefix: String) async -> AssistAgentToolOutcome {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.launchPath = launchPath
                proc.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: AssistAgentToolOutcome(
                        ok: false,
                        summary: "\(summaryPrefix) launch failed",
                        raw: error.localizedDescription))
                    return
                }

                let deadline = Date().addingTimeInterval(timeoutSec)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    proc.terminate()
                    cont.resume(returning: AssistAgentToolOutcome(
                        ok: false,
                        summary: "\(summaryPrefix) timeout \(Int(timeoutSec))s",
                        raw: "process killed after \(timeoutSec)s"))
                    return
                }

                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                let status = proc.terminationStatus
                let combined = out + (err.isEmpty ? "" : "\n[stderr]\n" + err)
                cont.resume(returning: AssistAgentToolOutcome(
                    ok: status == 0,
                    summary: "\(summaryPrefix) exit=\(status) \(combined.count)B",
                    raw: combined))
            }
        }
    }

    private func sha1Prefix(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
