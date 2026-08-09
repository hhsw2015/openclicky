//
//  OpenClickyWebSearchClient.swift
//  cursor-buddy
//
//  F34 landing — free-lane web search MCP client.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Source: src/Everywhere.Mcp/Tools/WebSearchTool.cs (`web_search`)
//
//  Everywhere routes `web_search` through user-configurable providers
//  (Tavily / Brave / Google / Jina / Searxng / TinyFish / …).
//  OpenClicky now exposes an editable provider list via
//  `OpenClickyWebSearchSettings` (see `OpenClickyWebSearchProvider.swift`).
//  The Settings UI lets a user paste an endpoint + API key and tick
//  Enabled; the first enabled row wins via `activeProvider`.
//
//  Per landing spec: if there is no configured search provider,
//  return `{ok:false, code:"search_provider_not_configured"}` — DO
//  NOT mock.
//
//  Wiring status:
//    - Provider registry: LANDED (surface visible in Settings).
//    - HTTP call:         NOT WIRED. Each provider (Brave, Serper,
//                         Tavily, …) uses a different request shape
//                         (query field name, auth header, response
//                         schema). Wiring three concrete adapters
//                         and their response decoders is a separate
//                         patch. This file honestly returns
//                         `providerNotConfigured` even when a row is
//                         enabled — the log line makes the reason
//                         visible in the archive.
//

import Foundation

/// Placeholder for `web_search`. Returns a structured "not configured"
/// error so agents can reason about capability presence without
/// hitting a mocked provider.
enum OpenClickyWebSearchClient {

    struct Hit {
        let title: String
        let url: String
        let snippet: String
    }

    enum SearchError: Error, LocalizedError {
        case providerNotConfigured
        case providerAdapterNotImplemented(name: String)
        var errorDescription: String? {
            switch self {
            case .providerNotConfigured:
                return "search_provider_not_configured"
            case .providerAdapterNotImplemented(let name):
                return "search_provider_adapter_not_implemented:\(name)"
            }
        }
    }

    /// Returns hits for `query`, or throws.
    ///
    /// Selection: the first enabled row in
    /// `OpenClickyWebSearchSettings.shared.providers` with a
    /// non-empty endpoint. Nothing enabled → `providerNotConfigured`.
    ///
    /// TODO(parity): implement per-provider HTTP request shapes
    /// (Brave `X-Subscription-Token`, Serper `X-API-KEY`, Tavily
    /// `Authorization: Bearer`) plus their response decoders. Until
    /// then this returns `providerAdapterNotImplemented` so the
    /// caller can distinguish "user hasn't configured anything" from
    /// "user configured a provider we don't speak yet."
    static func search(query: String, maxResults: Int = 10) async throws -> [Hit] {
        _ = query
        _ = maxResults
        let active = await MainActor.run { OpenClickyWebSearchSettings.shared.activeProvider }
        guard let active else {
            throw SearchError.providerNotConfigured
        }
        throw SearchError.providerAdapterNotImplemented(name: active.name)
    }
}
