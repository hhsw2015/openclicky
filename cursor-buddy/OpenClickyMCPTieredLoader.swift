//
//  OpenClickyMCPTieredLoader.swift
//  cursor-buddy
//
//  Pass B of the MCP token-optimization. Adds a tiered/lazy tool
//  registry on top of the existing descriptor pool emitted by
//  `OpenClickyExternalControlBridgeServer.mcpToolDescriptors`.
//
//  Design:
//    * Descriptor -> domain mapping lives here (single source of truth)
//      so bridge-tool sub-files stay untouched. The `filter(...)` entry
//      point injects `"domain"` into each emitted descriptor at
//      emission time.
//    * Default (lazy) mode: only descriptors mapped to `core` plus the
//      contents of `activatedTools` are surfaced by `tools/list`.
//    * `OPENCLICKY_MCP_FULL=1` env or `openclicky.mcp.disableLazyLoad`
//      UserDefault opts back into the pre-Pass-B behavior (everything).
//    * `activate_domain` / `activate_tools` / `deactivate_tools` mutate
//      `activatedTools` and bump a version counter used to invalidate
//      any cached tools/list on the primary bridge.
//    * TTL expiry is opportunistic: entries are dropped on the next
//      `activeToolSet()` read whose wall-clock time is past the TTL.
//

import Foundation

/// Canonical domain names for Pass B tiered loading. Values are stable
/// wire strings so `activate_domain` calls survive across launches.
enum OpenClickyTieredDomain {
    static let core = "core"
    static let pointing = "pointing"
    static let overlay = "overlay"
    static let clipboard = "clipboard"
    static let screenshot = "screenshot"
    static let context = "context"
    static let advisor = "advisor"
    static let openrewind = "openrewind"
    static let opencli = "opencli"
    static let connector = "connector"
    static let capture = "capture"
    static let adapter = "adapter"
    static let page = "page"
    static let memory = "memory"
    static let annotation = "annotation"
    static let codex = "codex"
    static let permissions = "permissions"
    static let git = "git"
    static let openclickyRealtime = "openclicky_realtime"
    static let docReaders = "doc_readers"
    static let browser = "browser"
    static let chat = "chat"
    static let web = "web"
    static let xlb = "xlb"

    static let all: [String] = [
        core, pointing, overlay, clipboard, screenshot, context,
        advisor, openrewind, opencli, connector, capture, adapter,
        page, memory, annotation, codex, permissions, git,
        openclickyRealtime, docReaders, browser, chat, web, xlb
    ]
}

/// Shared registry state for the primary MCP bridge. One instance is
/// used process-wide via `OpenClickyMCPTieredLoader.shared`.
final class OpenClickyMCPTieredLoader: @unchecked Sendable {
    static let shared = OpenClickyMCPTieredLoader()

    /// Env var that flips the tiered loader off — everything visible.
    static let envDisableLazy = "OPENCLICKY_MCP_FULL"

    /// UserDefaults key equivalent of the env override. Either turns
    /// the tiered gate off.
    static let userDefaultDisableLazy = "openclicky.mcp.disableLazyLoad"

    /// Default TTL for `activate_domain`. `0` = no expiry.
    static let defaultTTLMinutes: Int = 30

    private let lock = NSLock()
    private var activated: Set<String> = []
    private var expiries: [String: Date] = [:]
    private var listVersion: Int = 0

    private init() {}

    /// True when the tiered gate is disabled (all tools always visible).
    /// Read on every access so tests overriding env vars observe it.
    var bypassGate: Bool {
        if ProcessInfo.processInfo.environment[Self.envDisableLazy] == "1" {
            return true
        }
        if UserDefaults.standard.bool(forKey: Self.userDefaultDisableLazy) {
            return true
        }
        return false
    }

    /// Bumped by every state-change so callers can detect and drop any
    /// cached tools/list emission. Not tied to MCP `list_changed`
    /// notifications; the primary bridge emits fresh lists per request.
    var version: Int {
        lock.lock(); defer { lock.unlock() }
        return listVersion
    }

    // MARK: - State mutation

    /// Add every tool mapped to `domain` to the active set. Returns the
    /// tool names newly activated. Unknown domains yield `[]`.
    @discardableResult
    func activateDomain(_ domain: String, ttlMinutes: Int? = nil) -> [String] {
        let names = OpenClickyMCPTieredDomainMap.names(forDomain: domain)
        guard !names.isEmpty else { return [] }
        let ttl = ttlMinutes ?? Self.defaultTTLMinutes
        let expiryDate: Date?
        if ttl > 0 {
            expiryDate = Date().addingTimeInterval(TimeInterval(ttl * 60))
        } else {
            expiryDate = nil
        }
        lock.lock()
        for name in names {
            activated.insert(name)
            if let expiryDate {
                expiries[name] = expiryDate
            } else {
                expiries.removeValue(forKey: name)
            }
        }
        listVersion &+= 1
        lock.unlock()
        return names
    }

    /// Add specific tool names to the active set.
    @discardableResult
    func activateTools(_ names: [String]) -> [String] {
        let filtered = names.filter { OpenClickyMCPTieredDomainMap.domain(forTool: $0) != nil }
        guard !filtered.isEmpty else { return [] }
        lock.lock()
        for name in filtered {
            activated.insert(name)
            expiries.removeValue(forKey: name)
        }
        listVersion &+= 1
        lock.unlock()
        return filtered
    }

    /// Drop specific tool names from the active set.
    @discardableResult
    func deactivateTools(_ names: [String]) -> [String] {
        lock.lock()
        var dropped: [String] = []
        for name in names {
            if activated.remove(name) != nil {
                dropped.append(name)
                expiries.removeValue(forKey: name)
            }
        }
        if !dropped.isEmpty {
            listVersion &+= 1
        }
        lock.unlock()
        return dropped
    }

    /// Reset all activations. Test helper.
    func resetActivations() {
        lock.lock()
        activated.removeAll()
        expiries.removeAll()
        listVersion &+= 1
        lock.unlock()
    }

    /// Current active tool names, with expired entries evicted lazily.
    func activeToolSet() -> Set<String> {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        if !expiries.isEmpty {
            var evicted: [String] = []
            for (name, deadline) in expiries where deadline <= now {
                evicted.append(name)
            }
            for name in evicted {
                activated.remove(name)
                expiries.removeValue(forKey: name)
            }
            if !evicted.isEmpty {
                listVersion &+= 1
            }
        }
        return activated
    }

    // MARK: - Filter + describe

    /// Applies the tiered gate to `pool`. Also injects a `"domain"` key
    /// into every returned descriptor so clients see which domain owns
    /// a given tool.
    func filter(_ pool: [[String: Any]]) -> [[String: Any]] {
        let allowAll = bypassGate
        let active = allowAll ? [] : activeToolSet()
        var out: [[String: Any]] = []
        out.reserveCapacity(pool.count)
        for descriptor in pool {
            guard let name = descriptor["name"] as? String else { continue }
            let domain = OpenClickyMCPTieredDomainMap.domain(forTool: name) ?? OpenClickyTieredDomain.core
            let visible = allowAll || domain == OpenClickyTieredDomain.core || active.contains(name)
            if !visible { continue }
            var enriched = descriptor
            if enriched["domain"] == nil {
                enriched["domain"] = domain
            }
            out.append(enriched)
        }
        return out
    }

    /// Look up one descriptor by name, ignoring the tiered gate. Used
    /// by `describe_tool`. `pool` is the un-filtered descriptor list.
    func describe(_ name: String, in pool: [[String: Any]]) -> [String: Any]? {
        guard let descriptor = pool.first(where: { ($0["name"] as? String) == name }) else {
            return nil
        }
        var enriched = descriptor
        if enriched["domain"] == nil {
            enriched["domain"] = OpenClickyMCPTieredDomainMap.domain(forTool: name) ?? OpenClickyTieredDomain.core
        }
        return enriched
    }

    /// Cheap BM25-ish scorer for `search_tools`. Score = (token hits in
    /// description) * 2 + (token hits in name) * 5. Zero-scoring
    /// descriptors are excluded. `topK <= 0` returns everything sorted.
    func search(_ query: String, in pool: [[String: Any]], topK: Int) -> [[String: Any]] {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return [] }
        struct Hit { let descriptor: [String: Any]; let score: Int; let name: String }
        var hits: [Hit] = []
        for descriptor in pool {
            guard let name = descriptor["name"] as? String else { continue }
            let description = (descriptor["description"] as? String) ?? ""
            let nameTokens = Self.tokenize(name)
            let descTokens = Self.tokenize(description)
            var score = 0
            for token in tokens {
                score += nameTokens.filter { $0 == token }.count * 5
                score += descTokens.filter { $0 == token }.count * 2
            }
            if score > 0 {
                hits.append(Hit(descriptor: descriptor, score: score, name: name))
            }
        }
        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.name < rhs.name
        }
        let capped = topK > 0 ? Array(hits.prefix(topK)) : hits
        return capped.map { hit -> [String: Any] in
            var row: [String: Any] = [
                "name": hit.name,
                "description": (hit.descriptor["description"] as? String) ?? "",
                "domain": OpenClickyMCPTieredDomainMap.domain(forTool: hit.name) ?? OpenClickyTieredDomain.core,
                "score": hit.score
            ]
            if let compat = hit.descriptor["compatibility"] {
                row["compatibility"] = compat
            }
            return row
        }
    }

    /// Meta tool descriptors injected into every primary-bridge
    /// `tools/list`. These are always in `core` — they're the entry
    /// point clients use to reach hidden domains.
    static var metaToolDescriptors: [[String: Any]] {
        let domainList = OpenClickyTieredDomain.all.joined(separator: ", ")
        return [
            [
                "name": "activate_domain",
                "domain": OpenClickyTieredDomain.core,
                "description":
                    "Activate all tools in a domain at once. Domains: \(domainList). `ttlMinutes` optional (default \(defaultTTLMinutes), 0 = no expiry).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "domain": ["type": "string"],
                        "ttlMinutes": ["type": "integer"]
                    ] as [String: Any],
                    "required": ["domain"]
                ]
            ],
            [
                "name": "activate_tools",
                "domain": OpenClickyTieredDomain.core,
                "description": "Selectively activate individual tools by name.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "names": [
                            "type": "array",
                            "items": ["type": "string"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["names"]
                ]
            ],
            [
                "name": "deactivate_tools",
                "domain": OpenClickyTieredDomain.core,
                "description": "Deactivate previously activated tools to reclaim context.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "names": [
                            "type": "array",
                            "items": ["type": "string"]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["names"]
                ]
            ],
            [
                "name": "search_tools",
                "domain": OpenClickyTieredDomain.core,
                "description":
                    "BM25 search across the full tool catalog. Returns top-k matches with name, one-line description, domain, and score.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "k": ["type": "integer"]
                    ] as [String: Any],
                    "required": ["query"]
                ]
            ],
            [
                "name": "describe_tool",
                "domain": OpenClickyTieredDomain.core,
                "description":
                    "Fetch the full input schema for a tool by name (from any domain, active or not).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ] as [String: Any],
                    "required": ["name"]
                ]
            ]
        ]
    }

    /// The 5 wire names above — used to short-circuit `tools/call`.
    static let metaToolNames: Set<String> = [
        "activate_domain",
        "activate_tools",
        "deactivate_tools",
        "search_tools",
        "describe_tool"
    ]

    // MARK: - Helpers

    private static func tokenize(_ input: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        for scalar in input.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                buffer.append(ch)
            } else if !buffer.isEmpty {
                out.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }
}

/// Static tool -> domain map. Kept in one place so bridge sub-files
/// stay untouched. Everything not listed defaults to `core` — so
/// forgetting to map a tool downgrades gracefully to "always visible"
/// rather than "silently hidden".
enum OpenClickyMCPTieredDomainMap {
    static func domain(forTool name: String) -> String? {
        return table[name]
    }

    static func names(forDomain domain: String) -> [String] {
        return reverseTable[domain] ?? []
    }

    /// Flat name -> domain table. Composed from many sub-tables so
    /// each region is easy to audit.
    static let table: [String: String] = {
        var t: [String: String] = [:]
        for entry in tieredDomainEntries {
            for name in entry.tools {
                t[name] = entry.domain
            }
        }
        return t
    }()

    /// domain -> [tool] inverted view.
    static let reverseTable: [String: [String]] = {
        var t: [String: [String]] = [:]
        for entry in tieredDomainEntries {
            t[entry.domain, default: []].append(contentsOf: entry.tools)
        }
        return t
    }()

    struct Entry {
        let domain: String
        let tools: [String]
    }

    private static let tieredDomainEntries: [Entry] = [
        Entry(domain: OpenClickyTieredDomain.core, tools: [
            "sensor_health",
            "get_focused_context",
            "list_more_tools",
            "list_domains",
            "call_tool",
            "batch",
            "activate_domain",
            "activate_tools",
            "deactivate_tools",
            "search_tools",
            "describe_tool"
        ]),
        Entry(domain: OpenClickyTieredDomain.pointing, tools: [
            "openclicky_point",
            "openclicky_point_many",
            "show_cursor",
            "show_cursors",
            "openclicky_click",
            "click",
            "point",
            "clear"
        ]),
        Entry(domain: OpenClickyTieredDomain.overlay, tools: [
            "show_highlight",
            "show_rectangle",
            "show_scribble",
            "show_caption",
            "notify",
            "speak"
        ]),
        Entry(domain: OpenClickyTieredDomain.clipboard, tools: [
            "clipboard_read",
            "clipboard_write",
            "clipboard_paste",
            "clipboard_copy",
            "get_clipboard"
        ]),
        Entry(domain: OpenClickyTieredDomain.screenshot, tools: [
            "screenshot"
        ]),
        Entry(domain: OpenClickyTieredDomain.context, tools: [
            "get_app_state",
            "get_app_context",
            "list_apps",
            "list_windows",
            "element_under_cursor",
            "get_focused_window",
            "get_browser_tabs",
            "get_browser_url",
            "get_terminal_output",
            "get_selected_text",
            "get_finder_selection",
            "cursor_position",
            "get_idle_time",
            "install_ax_quirks"
        ]),
        Entry(domain: OpenClickyTieredDomain.advisor, tools: [
            "advisor_consult",
            "advisor_read_image",
            "advisor_locate_ui",
            "advisor_web_search",
            "advisor_places_lookup",
            "advisor_stock_quote",
            "advisor_walkthrough",
            "advisor_memory_save"
        ]),
        Entry(domain: OpenClickyTieredDomain.openrewind, tools: [
            "openrewind.search",
            "openrewind.searchHybrid",
            "openrewind.timeline",
            "openrewind.frame",
            "openrewind.currentContext",
            "openrewind.recap",
            "openrewind.retentionInfo",
            "openrewind.ask",
            "openrewind.showFrame",
            "openrewind.extractContext",
            "openrewind.events",
            "openrewind.transcript",
            "openrewind.audio",
            "openrewind.thumbnail",
            "openrewind.recentActivity",
            "openrewind.frameScreenRect",
            "openrewind.locateText"
        ]),
        Entry(domain: OpenClickyTieredDomain.opencli, tools: [
            "opencli_list",
            "opencli_describe",
            "opencli_run",
            "opendia_smoke_check"
        ]),
        Entry(domain: OpenClickyTieredDomain.connector, tools: [
            "connector_list",
            "connector_describe",
            "connector_run",
            "connector_connect",
            "connector_disconnect",
            "connector_list_connections"
        ]),
        Entry(domain: OpenClickyTieredDomain.capture, tools: [
            "capture_start",
            "capture_stop",
            "capture_current",
            "capture_export",
            "capture_draft",
            "capture_publish",
            "capture_list",
            "capture_delete",
            "capture_run"
        ]),
        Entry(domain: OpenClickyTieredDomain.adapter, tools: [
            "adapter_scaffold",
            "adapter_save",
            "adapter_verify",
            "adapter_list_local",
            "adapter_drift_check",
            "adapter_delete_local",
            "adapter_regenerate",
            "adapter_lint"
        ]),
        Entry(domain: OpenClickyTieredDomain.page, tools: [
            "page_read",
            "page_inspect",
            "page_actions",
            "page_summarise",
            "page_extract_by_rule",
            "page_save_extraction_rule"
        ]),
        Entry(domain: OpenClickyTieredDomain.memory, tools: [
            "memory_read",
            "memory_read_endpoint",
            "memory_write_endpoint",
            "memory_write_field_map",
            "memory_append_note",
            "memory_snapshot",
            "memory_freshness",
            "memory_write_verify_fixture",
            "strategy_note_get",
            "strategy_note_write"
        ]),
        Entry(domain: OpenClickyTieredDomain.annotation, tools: [
            "add_annotation",
            "read_annotations",
            "clear_annotations",
            "read_pick",
            "read_whiteboard",
            "read_whiteboard_image",
            "pick_element"
        ]),
        Entry(domain: OpenClickyTieredDomain.codex, tools: [
            "codex_task_start",
            "codex_task_followup",
            "codex_task_stop",
            "codex_task_state",
            "codex_task_list",
            "codex_task_delete",
            "codex_task_purge",
            "codex_log_tail",
            "codex_fault_inject",
            "codex_reset_account",
            "codex_auth_status"
        ]),
        Entry(domain: OpenClickyTieredDomain.permissions, tools: [
            "check_permission",
            "ocr_image"
        ]),
        Entry(domain: OpenClickyTieredDomain.git, tools: [
            "git_awareness",
            "project_registry_lookup",
            "probe_workdir",
            "recent_agent_sessions"
        ]),
        Entry(domain: OpenClickyTieredDomain.openclickyRealtime, tools: [
            "openclicky_realtime_text_probe",
            "openclicky_simulate_voice_turn",
            "openclicky_purge_automation_conversations"
        ]),
        Entry(domain: OpenClickyTieredDomain.docReaders, tools: [
            "doc_read_pdf",
            "doc_read_docx",
            "doc_read_xlsx",
            "doc_read_pptx",
            "doc_read_epub",
            "doc_read_html",
            "doc_read_txt"
        ]),
        Entry(domain: OpenClickyTieredDomain.chat, tools: [
            "chat_send",
            "chat_subscribe",
            "chat_list",
            "chat_read",
            "chat_create",
            "chat_delete"
        ]),
        Entry(domain: OpenClickyTieredDomain.web, tools: [
            "web_search",
            "web_fetch_url"
        ]),
        Entry(domain: OpenClickyTieredDomain.xlb, tools: [
            "xlb_search_topic",
            "xlb_get_topic",
            "xlb_get_topic_meta",
            "xlb_get_topic_section",
            "xlb_graph",
            "xlb_agent_state",
            "xlb_execute_command",
            "xlb_grammar_help",
            "xlb_extract_links"
        ])
    ]
}

/// JSON envelope helpers for the meta tools. Both the primary bridge
/// and the sensor bridge use MCP text content envelopes; this returns
/// the same shape.
enum OpenClickyTieredMetaDispatch {
    /// Handle one meta-tool call and return `(bodyDict, isError)`.
    /// The primary bridge wraps `bodyDict` into the MCP `content` array.
    static func handle(name: String, arguments: [String: Any], primaryPool: [[String: Any]]) -> ([String: Any], Bool) {
        let loader = OpenClickyMCPTieredLoader.shared
        switch name {
        case "activate_domain":
            guard let domain = arguments["domain"] as? String, !domain.isEmpty else {
                return (["ok": false, "error": "domain argument required"], true)
            }
            let ttl: Int?
            if let raw = arguments["ttlMinutes"] as? Int {
                ttl = raw
            } else if let raw = arguments["ttlMinutes"] as? String, let parsed = Int(raw) {
                ttl = parsed
            } else {
                ttl = nil
            }
            let activated = loader.activateDomain(domain, ttlMinutes: ttl)
            if activated.isEmpty {
                return (["ok": false, "error": "unknown domain: \(domain)"], true)
            }
            return ([
                "ok": true,
                "domain": domain,
                "activated": activated,
                "count": activated.count,
                "ttlMinutes": ttl ?? OpenClickyMCPTieredLoader.defaultTTLMinutes
            ], false)
        case "activate_tools":
            let names = stringArray(arguments["names"])
            guard !names.isEmpty else {
                return (["ok": false, "error": "names argument required"], true)
            }
            let activated = loader.activateTools(names)
            return ([
                "ok": true,
                "activated": activated,
                "count": activated.count
            ], false)
        case "deactivate_tools":
            let names = stringArray(arguments["names"])
            guard !names.isEmpty else {
                return (["ok": false, "error": "names argument required"], true)
            }
            let dropped = loader.deactivateTools(names)
            return ([
                "ok": true,
                "deactivated": dropped,
                "count": dropped.count
            ], false)
        case "search_tools":
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                return (["ok": false, "error": "query argument required"], true)
            }
            let k: Int
            if let raw = arguments["k"] as? Int {
                k = max(1, min(raw, 100))
            } else if let raw = arguments["k"] as? String, let parsed = Int(raw) {
                k = max(1, min(parsed, 100))
            } else {
                k = 10
            }
            let matches = loader.search(query, in: primaryPool, topK: k)
            return ([
                "ok": true,
                "matches": matches,
                "count": matches.count
            ], false)
        case "describe_tool":
            guard let name = arguments["name"] as? String, !name.isEmpty else {
                return (["ok": false, "error": "name argument required"], true)
            }
            guard let descriptor = loader.describe(name, in: primaryPool) else {
                return (["ok": false, "error": "unknown tool: \(name)"], true)
            }
            return ([
                "ok": true,
                "tool": descriptor
            ], false)
        default:
            return (["ok": false, "error": "not a meta tool: \(name)"], true)
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let arr = value as? [String] { return arr }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let raw = value as? String {
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}
