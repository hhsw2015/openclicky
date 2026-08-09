//
//  OpenClickyWebBridgeTools.swift
//  cursor-buddy
//
//  F34 landing — MCP descriptor + dispatch for `web_search` and
//  `web_fetch_url`.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Source: src/Everywhere.Mcp/Tools/WebSearchTool.cs
//
//  Wire contract:
//    web_search(query, max_results=10)
//        -> {schema_version, ok, count, results:[{title, url, snippet}]}
//    web_fetch_url(url, max_bytes=1_000_000, format="text")
//        -> {schema_version, ok, title, text, warnings:[...], bytes_read, mime}
//    On failure both tools return {schema_version, ok:false, code, message}.
//
//  All returns are wrapped in the MCP `{type:"text", text:"<json>"}`
//  content envelope, matching the shape produced by every other bridge
//  tool family (Connector, OpenCLI, OpenDia, adapter, page, capture).
//

import Foundation

/// MCP descriptors + async dispatch for the two `web_*` tools.
enum OpenClickyWebBridgeTools {

    static let toolNames: Set<String> = ["web_search", "web_fetch_url"]

    // MARK: - Descriptors

    static var descriptorsRaw: [[String: Any]] {
        return [
            [
                "name": "web_search",
                "description":
                    "Web search via OpenClicky's free lane. If no search provider is configured this returns {ok:false, code:'search_provider_not_configured'}.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query."],
                        "max_results": ["type": "integer", "description": "Max hits to return (default 10)."]
                    ] as [String: Any],
                    "required": ["query"]
                ]
            ],
            [
                "name": "web_fetch_url",
                "description":
                    "Fetch a public http(s) URL and return its textual body. HTML is stripped to plain text; other MIME types come back as decoded UTF-8. " +
                    "Response is capped at max_bytes (default 1MB); credentials are redacted from the outbound URL before the request. Timeout 15s.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Absolute http(s) URL."],
                        "max_bytes": ["type": "integer", "description": "Response size cap in bytes (default 1_000_000)."],
                        "format": ["type": "string", "description": "'text' (default) strips HTML; 'raw' returns bytes as UTF-8."]
                    ] as [String: Any],
                    "required": ["url"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    /// Match the shape used by other bridge tool families
    /// (`([String: Any], Bool)`) so `executeSensorTool` can compose it
    /// without special-casing.
    static func execute(name: String, arguments: [String: Any]) async -> ([String: Any], Bool) {
        switch name {
        case "web_search":
            return await handleSearch(arguments: arguments)
        case "web_fetch_url":
            return await handleFetch(arguments: arguments)
        default:
            return (textEnvelope(from: failBody(code: "UNKNOWN_TOOL", message: "unknown web tool '\(name)'")), true)
        }
    }

    // MARK: - Handlers

    private static func handleSearch(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return (textEnvelope(from: failBody(code: "invalid_input", message: "query is required")), true)
        }
        let max = intArg(arguments["max_results"]) ?? 10
        do {
            let hits = try await OpenClickyWebSearchClient.search(query: query, maxResults: max)
            let results = hits.map { hit -> [String: Any] in
                return [
                    "title": hit.title,
                    "url": hit.url,
                    "snippet": hit.snippet
                ]
            }
            let payload: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "count": results.count,
                "results": results
            ]
            return (textEnvelope(from: payload), false)
        } catch OpenClickyWebSearchClient.SearchError.providerNotConfigured {
            return (textEnvelope(from: failBody(code: "search_provider_not_configured",
                                                message: "No web-search provider is wired. Free-lane search is TODO — see docs/ROADMAP/.impl-notes/f32-f34-landing-report-2026-07-23.md.")), true)
        } catch {
            return (textEnvelope(from: failBody(code: "WEB_SEARCH_ERROR", message: error.localizedDescription)), true)
        }
    }

    private static func handleFetch(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let urlString = arguments["url"] as? String, !urlString.isEmpty else {
            return (textEnvelope(from: failBody(code: "invalid_input", message: "url is required")), true)
        }
        let maxBytes = intArg(arguments["max_bytes"]) ?? OpenClickyWebFetchClient.defaultMaxBytes
        let format = (arguments["format"] as? String) ?? "text"
        do {
            let result = try await OpenClickyWebFetchClient.fetch(
                url: urlString,
                maxBytes: max(1024, maxBytes),
                format: format
            )
            var payload: [String: Any] = [
                "schema_version": "1",
                "ok": true,
                "text": result.text,
                "warnings": result.warnings,
                "bytes_read": result.bytesRead
            ]
            if let t = result.title { payload["title"] = t }
            if let m = result.mime { payload["mime"] = m }
            return (textEnvelope(from: payload), false)
        } catch let err as OpenClickyWebFetchClient.FetchError {
            let code: String
            switch err {
            case .invalidURL:         code = "invalid_input"
            case .disallowedScheme:   code = "disallowed_scheme"
            case .httpError:          code = "http_error"
            case .network:            code = "network_error"
            }
            return (textEnvelope(from: failBody(code: code, message: err.errorDescription ?? "fetch failed")), true)
        } catch {
            return (textEnvelope(from: failBody(code: "WEB_FETCH_ERROR", message: error.localizedDescription)), true)
        }
    }

    // MARK: - Helpers

    private static func failBody(code: String, message: String) -> [String: Any] {
        return [
            "schema_version": "1",
            "ok": false,
            "code": code,
            "message": message
        ]
    }

    /// Wrap a JSON-serialisable dict into the MCP content text envelope
    /// (`{type:"text", text:"<json>"}`). Mirrors the pattern used by
    /// every other bridge tool family so `executeSensorTool` can
    /// splice the return straight into `result.content[]`.
    private static func textEnvelope(from obj: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["type": "text", "text": text]
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let s = value as? String, let v = Int(s) { return v }
        return nil
    }
}
