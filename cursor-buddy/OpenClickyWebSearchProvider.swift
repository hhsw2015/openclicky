//
//  OpenClickyWebSearchProvider.swift
//  cursor-buddy
//
//  P1 parity fix (domain 2 rows 25-29): user-configurable web-search
//  provider registry that backs the `web_search` MCP tool.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Source parity: src/Everywhere.Mcp/Tools/WebSearchTool.cs — Everywhere
//  routes `web_search` through a user-configurable provider list
//  (Tavily / Brave / Serper / Jina / …). OpenClicky exposes an
//  extensible list here; the first `enabled` row wins.
//
//  Storage: UserDefaults JSON blob under
//  "openclicky.web.searchProviders". API keys are stored in plaintext
//  per user directive — Keychain migration is intentionally skipped
//  to avoid repeated macOS password prompts. Users who care about
//  hardened storage can leave the field empty and set env vars in
//  their shell.
//
//  Wiring: `OpenClickyWebSearchClient.search` consults
//  `activeProvider`. If nil (no enabled row), the tool returns
//  `search_provider_not_configured` unchanged. If present but the
//  HTTP call has not been wired for that provider shape yet, the
//  client still returns not-configured — see the TODO in
//  `OpenClickyWebSearchClient.swift`. This lands the surface without
//  shipping three half-tested provider adapters.
//

import Foundation
import Combine

public struct OpenClickyWebSearchProviderConfig: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    public var apiKey: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        apiKey: String,
        enabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.enabled = enabled
    }
}

@MainActor
public final class OpenClickyWebSearchSettings: ObservableObject {
    public static let shared = OpenClickyWebSearchSettings()

    private let defaults = UserDefaults.standard
    private let storageKey = "openclicky.web.searchProviders"

    @Published public var providers: [OpenClickyWebSearchProviderConfig] {
        didSet { persist() }
    }

    /// First enabled row with a non-empty endpoint. `web_search`
    /// routes to this provider; nil means "not configured".
    public var activeProvider: OpenClickyWebSearchProviderConfig? {
        providers.first(where: { row in
            row.enabled &&
                !row.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private init() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([OpenClickyWebSearchProviderConfig].self, from: data) {
            self.providers = decoded
        } else {
            // Seed common providers, all disabled. Users pick one,
            // paste a key, tick Enabled. Endpoints are the current
            // public documented URLs at the time of seeding — users
            // can override in the UI when providers move.
            self.providers = [
                .init(name: "Brave Search",
                      endpoint: "https://api.search.brave.com/res/v1/web/search",
                      apiKey: ""),
                .init(name: "Serper",
                      endpoint: "https://google.serper.dev/search",
                      apiKey: ""),
                .init(name: "Tavily",
                      endpoint: "https://api.tavily.com/search",
                      apiKey: "")
            ]
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
