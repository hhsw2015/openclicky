//
//  OpenClickyPageBridgeTools.swift
//  cursor-buddy
//
//  Phase 7.6+ F35 — MCP tool implementations for page-level automation
//  on top of the OpenDia browser bridge (page_* long-tail).
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//    * src/Everywhere.Mcp/Tools/CaptureTools.cs:313-380 — Everywhere's
//      only two `page_*` tools: `page_extract_by_rule` and
//      `page_save_extraction_rule`. These live inside CaptureTools
//      because they piggyback on the OpenDia extraction-rules cache.
//
//  Note: Everywhere does not ship the higher-level `page_read` /
//  `page_summarise` / `page_inspect` / `page_actions` tools the F35
//  brief mentions — those are openclicky design intent, not
//  Everywhere-upstream tools. Following the F35 fallback clause
//  ("implement as thin OpenDia wrappers per current openclicky
//  design intent"), we ship the four additional tools as OpenDia
//  compositions that route through `OpenClickyOpenDiaSubprocess`.
//
//  Every openclicky-only tool is clearly marked "openclicky
//  extension" in its description so agents pinned against the
//  Everywhere contract can filter.
//
//  Storage:
//    * ~/Library/Application Support/OpenClicky/extraction-rules.json
//      — mirrors Everywhere's `~/.everywhere/extraction-rules.json`.
//

import Foundation
import OpenClickyContextService

enum OpenClickyPageBridgeTools {

    // MARK: - Tool name set

    static let toolNames: Set<String> = [
        // Everywhere upstream:
        "page_extract_by_rule",
        "page_save_extraction_rule",
        // openclicky extensions (thin OpenDia wrappers):
        "page_read",
        "page_summarise",
        "page_inspect",
        "page_actions"
    ]

    // MARK: - Tool descriptors (MCP tools/list shape)

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "page_extract_by_rule",
                "description":
                    "Apply the extraction rulebook to the current tab's URL. If no rule matches, falls back " +
                    "to browser_get_text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Optional URL to match against the rulebook. Defaults to the active tab's URL."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "page_save_extraction_rule",
                "description":
                    "Persist a URL-pattern → CSS/XPath selector rule to " +
                    "~/Library/Application Support/OpenClicky/extraction-rules.json. First match wins at read time; " +
                    "higher priority sorts first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url_pattern": ["type": "string", "description": "Regex applied to the page URL (case-insensitive)."],
                        "kind": ["type": "string", "description": "Selector kind: 'css' or 'xpath'."],
                        "selector": ["type": "string", "description": "Selector body."],
                        "priority": ["type": "integer", "description": "Optional priority — higher applies first."]
                    ] as [String: Any],
                    "required": ["url_pattern", "kind", "selector"]
                ]
            ],
            [
                "name": "page_read",
                "description":
                    "openclicky extension: navigate to `url` (or reuse the active tab), then return the readable " +
                    "text of the page via browser_get_text. Composes OpenDia browser_open + browser_wait_for_load + browser_get_text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Optional URL to navigate to before reading. Uses the active tab when omitted."],
                        "format": ["type": "string", "description": "Reserved (currently only 'text' is emitted)."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "page_summarise",
                "description":
                    "openclicky extension: return the tab title + URL + full visible text so an LLM caller can " +
                    "summarise. Model-neutral: no summarisation happens server-side.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "page_inspect",
                "description":
                    "openclicky extension: return the aria/DOM snapshot of the active tab via browser_snapshot. " +
                    "Pair with browser_click(ref) to interact.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "selector": ["type": "string", "description": "Optional CSS selector to scope the snapshot (forwarded to browser_snapshot when supported)."]
                    ] as [String: Any],
                    "required": [] as [Any]
                ]
            ],
            [
                "name": "page_actions",
                "description":
                    "openclicky extension: list clickable / actionable elements on the active tab. Derived from " +
                    "browser_snapshot — returns the raw snapshot response for the caller to filter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    /// Executes one `page_*` tool. Returns an MCP `content` envelope
    /// plus `isError` matching `executeSensorTool` return shape.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            return errorEnvelope(code: "SELFEXPAND_DISABLED",
                                 message: "page tools are gated by OPENCLICKY_MCP_SELFEXPAND=0",
                                 extras: ["tool": name])
        }
        guard toolNames.contains(name) else {
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "'\(name)' is not a registered page_* tool",
                                 extras: ["tool": name])
        }

        // page_save_extraction_rule is a pure disk write — no OpenDia
        // required. Every other page_* tool needs the OpenDia
        // subprocess running.
        if name == "page_save_extraction_rule" {
            return handleSaveExtractionRule(args: arguments)
        }

        let running = await MainActor.run { OpenClickyOpenDiaSubprocess.shared.isRunning }
        guard running else {
            return errorEnvelope(code: "OPENDIA_NOT_CONNECTED",
                                 message: "OpenDia Node subprocess is not running. Enable OpenDia in Settings.",
                                 extras: ["tool": name])
        }

        switch name {
        case "page_extract_by_rule": return await handleExtractByRule(args: arguments)
        case "page_read":            return await handleRead(args: arguments)
        case "page_summarise":       return await handleSummarise(args: arguments)
        case "page_inspect":         return await handleInspect(args: arguments)
        case "page_actions":         return await handleActions(args: arguments)
        default:
            return errorEnvelope(code: "UNKNOWN_TOOL",
                                 message: "unhandled page_* tool '\(name)'",
                                 extras: ["tool": name])
        }
    }

    // MARK: - Handlers

    /// Mirror of Everywhere CaptureTools.PageExtractByRule
    /// (CaptureTools.cs:313-354).
    ///
    /// Everywhere calls `.ToJsonString()` on the browser response so
    /// `text` on the wire is a scalar string. We do the same:
    /// `serialiseEnvelope` folds the `[String: Any]` OpenDia envelope
    /// down to its JSON representation before assigning to `text`.
    private static func handleExtractByRule(args: [String: Any]) async -> ([String: Any], Bool) {
        var currentUrl = args["url"] as? String ?? ""
        do {
            if currentUrl.isEmpty {
                let urlEnvelope = try await callBrowser(tool: "browser_get_url", arguments: [:])
                if let result = urlEnvelope["result"] as? [String: Any],
                   let u = result["url"] as? String {
                    currentUrl = u
                } else if let u = urlEnvelope["url"] as? String {
                    currentUrl = u
                }
            }
            let rule = ExtractionRulesStore.shared.match(currentUrl)
            if let rule {
                let extractArgs: [String: Any] = [
                    "selector": rule.selector,
                    "kind": rule.kind
                ]
                let extracted = try await callBrowser(tool: "browser_get_text", arguments: extractArgs)
                let ruleObj: [String: Any] = [
                    "url_pattern": rule.urlPattern,
                    "kind": rule.kind,
                    "selector": rule.selector,
                    "priority": rule.priority
                ]
                let body: [String: Any] = [
                    "schema_version": "1",
                    "ok": true,
                    "matched": true,
                    "rule": ruleObj,
                    "text": serialiseEnvelope(extracted)
                ]
                return (textEnvelope(from: body), false)
            }
            let text = try await callBrowser(tool: "browser_get_text", arguments: [:])
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "matched": false,
                "text": serialiseEnvelope(text)
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "EXTRACT_FAILED",
                                 message: error.localizedDescription,
                                 extras: ["url": currentUrl])
        }
    }

    /// Mirror of Everywhere CaptureTools.PageSaveExtractionRule
    /// (CaptureTools.cs:356-380).
    private static func handleSaveExtractionRule(args: [String: Any]) -> ([String: Any], Bool) {
        guard let urlPattern = args["url_pattern"] as? String,
              !urlPattern.trimmingCharacters(in: .whitespaces).isEmpty,
              let selector = args["selector"] as? String,
              !selector.trimmingCharacters(in: .whitespaces).isEmpty else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "url_pattern and selector are required.")
        }
        guard let kind = args["kind"] as? String, kind == "css" || kind == "xpath" else {
            return errorEnvelope(code: "ARGUMENT_ERROR",
                                 message: "kind must be 'css' or 'xpath'.")
        }
        let priority = (args["priority"] as? Int) ?? {
            if let n = args["priority"] as? NSNumber { return n.intValue }
            return 0
        }()
        do {
            try ExtractionRulesStore.shared.upsert(ExtractionRulesStore.Rule(
                urlPattern: urlPattern,
                kind: kind,
                selector: selector,
                priority: priority
            ))
            let body: [String: Any] = ["schema_version": "1", "ok": true]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "STORE_ERROR",
                                 message: error.localizedDescription)
        }
    }

    /// openclicky extension: navigate then read.
    ///
    /// `text` is a scalar string — the browser envelope is flattened
    /// via `serialiseEnvelope` before assignment (matches
    /// Everywhere's `text?.ToJsonString()` behaviour).
    private static func handleRead(args: [String: Any]) async -> ([String: Any], Bool) {
        do {
            if let url = args["url"] as? String,
               !url.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = try await callBrowser(tool: "browser_open", arguments: ["url": url])
                _ = try await callBrowser(tool: "browser_wait_for_load", arguments: [:])
            }
            let text = try await callBrowser(tool: "browser_get_text", arguments: [:])
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "text": serialiseEnvelope(text),
                "format": (args["format"] as? String) ?? "text"
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "PAGE_READ_FAILED",
                                 message: error.localizedDescription)
        }
    }

    /// openclicky extension: title + url + text bundle.
    ///
    /// `text` is a scalar string — the browser envelope is flattened
    /// via `serialiseEnvelope` before assignment (matches
    /// Everywhere's `text?.ToJsonString()` behaviour at
    /// CaptureTools.cs:338-351).
    private static func handleSummarise(args: [String: Any]) async -> ([String: Any], Bool) {
        do {
            let urlRes = try await callBrowser(tool: "browser_get_url", arguments: [:])
            let titleRes = try await callBrowser(tool: "browser_get_title", arguments: [:])
            let textRes = try await callBrowser(tool: "browser_get_text", arguments: [:])
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "url": extractScalar(urlRes, key: "url"),
                "title": extractScalar(titleRes, key: "title"),
                "text": serialiseEnvelope(textRes)
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "PAGE_SUMMARISE_FAILED",
                                 message: error.localizedDescription)
        }
    }

    /// openclicky extension: return a snapshot for structural inspection.
    private static func handleInspect(args: [String: Any]) async -> ([String: Any], Bool) {
        do {
            var snapArgs: [String: Any] = [:]
            if let selector = args["selector"] as? String,
               !selector.trimmingCharacters(in: .whitespaces).isEmpty {
                snapArgs["selector"] = selector
            }
            let snapshot = try await callBrowser(tool: "browser_snapshot", arguments: snapArgs)
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "snapshot": snapshot
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "PAGE_INSPECT_FAILED",
                                 message: error.localizedDescription)
        }
    }

    /// openclicky extension: raw snapshot for caller-side action-filtering.
    private static func handleActions(args: [String: Any]) async -> ([String: Any], Bool) {
        do {
            let snapshot = try await callBrowser(tool: "browser_snapshot", arguments: [:])
            let body: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "snapshot": snapshot,
                "note": "Caller filters snapshot for clickable/actionable elements — server does not classify."
            ]
            return (textEnvelope(from: body), false)
        } catch {
            return errorEnvelope(code: "PAGE_ACTIONS_FAILED",
                                 message: error.localizedDescription)
        }
    }

    // MARK: - OpenDia helper

    @discardableResult
    private static func callBrowser(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        // OpenClickyOpenDiaSubprocess is @MainActor; the implicit hop is
        // safe because we're in an async context (mirrors F31 usage in
        // OpenClickyOpenDiaBridgeTools.execute).
        return try await OpenClickyOpenDiaSubprocess.shared.callTool(name: tool, arguments: arguments)
    }

    private static func extractScalar(_ envelope: [String: Any], key: String) -> Any {
        if let v = envelope[key] { return v }
        if let result = envelope["result"] as? [String: Any], let v = result[key] { return v }
        return NSNull()
    }

    /// Flatten a browser response envelope down to a scalar JSON string
    /// so `text` on the wire remains a string (matches Everywhere's
    /// `text?.ToJsonString()` at CaptureTools.cs:338-351). If the
    /// envelope already carries a `text` scalar, prefer that; otherwise
    /// serialise the whole envelope.
    private static func serialiseEnvelope(_ envelope: [String: Any]) -> String {
        if let s = envelope["text"] as? String { return s }
        if let result = envelope["result"] as? [String: Any], let s = result["text"] as? String {
            return s
        }
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }

    // MARK: - Envelope helpers

    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    /// Error envelope aligned to Everywhere's shape
    /// (`{ok:false, code, message}` — see `GeneratorTools.cs:451`,
    /// `GateTools.cs:127`, `CaptureTools.cs:420`). Openclicky adds
    /// `schema_version` so callers can pin future migrations.
    private static func errorEnvelope(code: String, message: String, extras: [String: Any] = [:]) -> ([String: Any], Bool) {
        var body: [String: Any] = [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "message": message
        ]
        for (k, v) in extras { body[k] = v }
        return (textEnvelope(from: body), true)
    }
}

// MARK: - Extraction rules store

/// Persistent extraction-rules cache. Everywhere stores this at
/// `~/.everywhere/extraction-rules.json`; openclicky uses
/// `~/Library/Application Support/OpenClicky/extraction-rules.json` to
/// stay inside the sandbox-friendly Application Support tree.
///
/// Everywhere reference: `Everywhere.Mcp.OpenCli.Observation.ExtractionRules`
/// (accessed via `new ExtractionRules().Match(url)` /
/// `Upsert(rule)` in CaptureTools.cs:334/371).
final class ExtractionRulesStore: @unchecked Sendable {

    struct Rule: Codable, Sendable {
        let urlPattern: String
        let kind: String   // "css" | "xpath"
        let selector: String
        let priority: Int

        enum CodingKeys: String, CodingKey {
            case urlPattern = "url_pattern"
            case kind
            case selector
            case priority
        }
    }

    static let shared = ExtractionRulesStore()

    // NSLock is not reentrant; internal methods suffixed `Locked`
    // assume the caller already holds the lock and MUST NOT re-lock.
    // Public methods take the lock once, then call the `Locked`
    // helper. Re-entrant locking here caused an actual deadlock
    // during `upsert -> loadUnsafe` before the F32/F35 fix
    // (review-notes/F33-F35-F36-adapter-page-capture-2026-07-23.md
    // §"Issue 3").
    private let lock = NSLock()
    private let storeURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OpenClicky", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("extraction-rules.json", isDirectory: false)
    }

    func match(_ url: String) -> Rule? {
        lock.lock(); defer { lock.unlock() }
        let rules = loadLocked()
        // Higher priority first; earlier at same priority first.
        let sorted = rules.sorted { a, b in a.priority > b.priority }
        for rule in sorted {
            if let rx = try? NSRegularExpression(
                pattern: rule.urlPattern,
                options: [.caseInsensitive]),
               rx.firstMatch(
                    in: url,
                    range: NSRange(location: 0, length: (url as NSString).length)) != nil {
                return rule
            }
        }
        return nil
    }

    func upsert(_ rule: Rule) throws {
        // Acquire the lock ONCE. `loadLocked` and `saveLocked` both
        // assume the caller already holds it; they must not re-lock.
        lock.lock(); defer { lock.unlock() }
        var rules = loadLocked()
        rules.removeAll {
            $0.urlPattern == rule.urlPattern &&
            $0.kind == rule.kind &&
            $0.selector == rule.selector
        }
        rules.append(rule)
        try saveLocked(rules)
    }

    /// Load rules from disk. Caller MUST hold `lock`.
    private func loadLocked() -> [Rule] {
        guard FileManager.default.isReadableFile(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            return []
        }
        return rules
    }

    /// Persist rules to disk atomically. Caller MUST hold `lock`.
    private func saveLocked(_ rules: [Rule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)
        let tmp = storeURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: storeURL)
        }
    }
}
