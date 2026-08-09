import Foundation

/// Sensor-side dispatch for the six read-only xlinkBook tools:
/// xlb_search_topic, xlb_get_topic, xlb_get_topic_meta,
/// xlb_get_topic_section, xlb_graph, xlb_agent_state.
///
/// Descriptors + tiered-domain mapping live in
/// OpenClickyExternalControlBridge and OpenClickyMCPTieredLoader.
/// This file owns the handlers and the subprocess/HTTP plumbing.
enum XLBSensorTools {

    static let toolNames: [String] = [
        "xlb_search_topic",
        "xlb_get_topic",
        "xlb_get_topic_meta",
        "xlb_get_topic_section",
        "xlb_graph",
        "xlb_agent_state",
        "xlb_grammar_help",
        "xlb_execute_command",
        "xlb_extract_links"
    ]

    static func handles(_ name: String) -> Bool {
        return toolNames.contains(name)
    }

    static func execute(name: String, arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let raw: ([String: Any], Bool)
        switch name {
        case "xlb_search_topic":
            raw = await handleSearchTopic(arguments: arguments)
        case "xlb_get_topic":
            raw = await handleGetTopic(arguments: arguments)
        case "xlb_get_topic_meta":
            raw = await handleGetTopicMeta(arguments: arguments)
        case "xlb_get_topic_section":
            raw = await handleGetTopicSection(arguments: arguments)
        case "xlb_graph":
            raw = await handleGraph(arguments: arguments)
        case "xlb_agent_state":
            raw = await handleAgentState(arguments: arguments)
        case "xlb_grammar_help":
            raw = handleGrammarHelp()
        case "xlb_execute_command":
            raw = await handleExecuteCommand(arguments: arguments)
        case "xlb_extract_links":
            raw = await handleExtractLinks(arguments: arguments)
        default:
            raw = textEnvelope(["error": "unknown xlb tool: \(name)"], isError: true)
        }
        return await applyTurnBudget(to: raw)
    }

    /// Reset the per-turn cumulative token budget. Intended to be called by
    /// CompanionManager at the start of each user turn. Currently unwired.
    static func resetTurnBudget() async {
        await turnBudget.reset()
    }

    /// Approximate token count as `text.count / 4` and truncate if the
    /// response exceeds `cap` tokens. Truncated payloads keep a trailing
    /// marker so downstream models can steer their next call.
    static func enforceTokenCap(_ text: String, cap: Int, hint: String) -> String {
        let approxTokens = text.count / 4
        if approxTokens <= cap { return text }
        let charCap = cap * 4
        let idx = text.index(text.startIndex, offsetBy: charCap, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[..<idx])
            + "\n\n[TRUNCATED: response exceeded \(cap) tokens. \(hint)]"
    }

    // MARK: - Tool descriptors

    static var descriptors: [[String: Any]] {
        return [
            [
                "name": "xlb_search_topic",
                "description": "Fuzzy-search the user's xlinkBook knowledge graph. Returns up to N candidate topics with browse commands. Call FIRST when the user's question might touch a topic they already curated (331 top-level topics, 2787 aliases, 23k nested subtopics covering AI, engineering, music, travel, etc). Very fast (<1 ms local sqlite lookup).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 20]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "xlb_get_topic",
                "description": "Fetch the full content of an xlinkBook topic by its browse command (e.g. '>Vibe Coding/'). Returns URLs, github repos, YouTube channels, related topics, and semantic hierarchy. Call after xlb_search_topic identifies the right topic. Latency ~500 ms (subprocess).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "browse_cmd": ["type": "string"]
                    ],
                    "required": ["browse_cmd"]
                ]
            ],
            [
                "name": "xlb_get_topic_meta",
                "description": "Topic meta context: hierarchy, tag counts, community peers. Use to understand a topic's shape before drilling in. Latency ~500 ms.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string"]
                    ],
                    "required": ["topic"]
                ]
            ],
            [
                "name": "xlb_get_topic_section",
                "description": "Drill into one tag section of a topic (github, website, youtube, searchin). Optional filter narrows results by text. Supports pagination (limit/offset) and 3-layer response granularity (mode). For high-count sections (>50 items), call with mode='count' first to see totals, then mode='summary' with a filter to narrow down, then mode='full' only for specific items.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string"],
                        "section": ["type": "string"],
                        "filter": ["type": "string"],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 100,
                            "default": 20,
                            "description": "Cap on results returned per call (1..100, default 20)."
                        ],
                        "offset": [
                            "type": "integer",
                            "minimum": 0,
                            "default": 0,
                            "description": "Number of items to skip for pagination."
                        ],
                        "mode": [
                            "type": "string",
                            "enum": ["count", "summary", "full"],
                            "default": "summary",
                            "description": "Response granularity: 'count' returns total + title-only list (cheapest), 'summary' returns title + url per item (default), 'full' returns raw record text."
                        ]
                    ],
                    "required": ["topic", "section"]
                ]
            ],
            [
                "name": "xlb_graph",
                "description": "Graph analysis over the topic graph. mode=path returns shortest edge chain from `from` to `to` (optional maxDepth caps BFS depth, default 12; walks all edge kinds undirected). mode=explore returns N-hop neighbors of `from` (hops up to 10; only `searchin` edges are followed by default to match Python's `_graph_neighbors` behaviour, pass optional `kinds` to widen -- e.g. `[\"searchin\",\"contains\"]` to include contained subtopics). mode=hubs lists highest-connectivity topics measured by searchin-degree only (Python parity). mode=community lists topic clusters. Use when the user asks how topics connect or which are central.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["path", "explore", "hubs", "community"]],
                        "from": ["type": "string"],
                        "to": ["type": "string"],
                        "hops": ["type": "integer", "minimum": 1, "maximum": 10],
                        "maxDepth": ["type": "integer", "minimum": 1, "maximum": 20],
                        "kinds": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 50]
                    ],
                    "required": ["mode"]
                ]
            ],
            [
                "name": "xlb_grammar_help",
                "description": "Return the xlinkBook browse_cmd grammar reference. Use when you need to construct complex commands with operators (>, >>, ->, =>, ??, ?>, ?=>, %>, #, +, *, &, ;) or tag filters. No parameters.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ],
            [
                "name": "xlb_agent_state",
                "description": "Fetch the user's current xlinkBook browsing state (recent view + interactions markdown). Call INSTEAD of xlb_search_topic when the user asks 'what was I just looking at' or 'the topic I just clicked'. Fast (~50 ms HTTP GET).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "with_meta": ["type": "boolean"],
                        "consume": ["type": "boolean"]
                    ]
                ]
            ],
            [
                "name": "xlb_execute_command",
                "description": "Execute an xlinkBook command and return the result markdown. Commands are xlinkBook's internal query DSL: '>Topic/' fetches topic content, '??keyword' does fuzzy search, '=>alias' resolves an alias, '->Topic' finds backreferences, '>Topic/github:' drills into a section, '#category' filters by category, and operators '+ * & ;' compose queries. Use this to execute commands you retrieved from a topic's 'command:' section, or to run any xlb query.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string"],
                        "browse_cmd": ["type": "string", "description": "Alias for command."]
                    ],
                    "required": ["command"]
                ]
            ],
            [
                "name": "xlb_extract_links",
                "description": "Smart link extractor via xlinkBook's /onGetAllLinksFromUrl endpoint. Give it a link-aggregator page and it returns outbound (url, title) pairs. Auto-detects: YouTube playlist/channel, Bilibili space, GitHub (awesome-* README, gist, user/org repos, user-starred, repo issues/pulls/releases/discussions, /topics/X, Trending), Reddit sub/user (RSS), Substack feed, Wikipedia List_of_*, HuggingFace collections / user models, HN item/user (Algolia), Apple Podcasts, Mastodon user, Bluesky profile, Are.na channel, arXiv category listing, StackExchange questions-by-tag, crates.io / npm user packages, generic .rss/.atom/feed URLs, and RSS auto-discovery for arbitrary sites/blogs. Falls back to <a href> scraping on unknown domains. No auth.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "Page to extract links from."],
                        "parent": ["type": "string", "description": "Optional context tag (echoed to xlinkBook logs)."]
                    ],
                    "required": ["url"]
                ]
            ]
        ]
    }

    // MARK: - Handlers

    private static func handleSearchTopic(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let query = argString(arguments["query"]), !query.isEmpty else {
            return textEnvelope(["error": "query argument required"], isError: true)
        }
        let limit = clampInt(argInt(arguments["limit"]) ?? 5, min: 1, max: 20)

        // Route query to fuzzy pipeline when the caller opts in (`??`
        // prefix, Python-style) or the query shape suggests a multi-token
        // fuzzy search (spaces / hyphens / underscores). Single-token
        // queries continue to hit the fast exact-first `lookup` path so
        // the common HUD suggest case stays sub-millisecond.
        let stripped: String
        let forceFuzzy: Bool
        if query.hasPrefix("??") {
            stripped = String(query.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            forceFuzzy = true
        } else {
            stripped = query
            forceFuzzy = false
        }
        let hasSpace = stripped.contains(" ")
        let hasSep = stripped.contains("-") || stripped.contains("_")
        let useFuzzy = forceFuzzy || hasSpace || hasSep

        let searchCap = AppBundleConfiguration.xlbTokenCapSearch()
        let searchHint = "use limit param or a more specific query"
        if useFuzzy, !stripped.isEmpty {
            let cands = await XLBTopicIndex.shared.fuzzyLookup(stripped, limit: limit)
            if !cands.isEmpty {
                let md = cands.map { c -> String in
                    let prefix: String
                    switch c.type {
                    case "topic": prefix = "[topic]"
                    case "subtopic": prefix = "[subtopic]"
                    case "alias":
                        if let a = c.alias, !a.isEmpty {
                            prefix = "[alias->\(a)]"
                        } else {
                            prefix = "[alias]"
                        }
                    case "graph_node": prefix = "[graph]"
                    case "content_match": prefix = "[content]"
                    default: prefix = "[\(c.type)]"
                    }
                    var suffix = ""
                    if let parent = c.parentTopic, !parent.isEmpty {
                        suffix += " under \(parent)"
                    }
                    if let edges = c.edges { suffix += " edges=\(edges)" }
                    return "- \(prefix) \(c.name)\(suffix) (browse: \(c.browseCmd))"
                }.joined(separator: "\n")
                return textEnvelope([
                    "results": enforceTokenCap(md, cap: searchCap, hint: searchHint),
                    "count": cands.count,
                    "source": "sqlite_fuzzy"
                ], isError: false)
            }
        }

        let matches = await XLBTopicIndex.shared.lookup(stripped, limit: limit)
        if !matches.isEmpty {
            let md = matches.map { m -> String in
                let parent = m.parentTopic.map { " under \($0)" } ?? ""
                return "- \(m.name) (\(m.kind.rawValue) in \(m.library)\(parent), browse: \(m.browseCmd))"
            }.joined(separator: "\n")
            return textEnvelope([
                "results": enforceTokenCap(md, cap: searchCap, hint: searchHint),
                "count": matches.count,
                "source": "sqlite"
            ], isError: false)
        }

        do {
            let body = try await postGetPluginInfo(title: "??\(stripped)", markdown: true, timeout: 0.5)
            let rendered = renderPluginInfoAsMarkdown(body)
            return textEnvelope([
                "results": enforceTokenCap(rendered, cap: searchCap, hint: searchHint),
                "source": "http_fuzzy"
            ], isError: false)
        } catch {
            return textEnvelope([
                "error": "xlinkBook HTTP query failed (no sqlite matches, HTTP fallback failed)",
                "detail": String(describing: error)
            ], isError: true)
        }
    }

    /// Execute an arbitrary xlinkBook command through the same
    /// `/getPluginInfo` HTTP path that xlb_get_topic uses, but named
    /// with clearer semantics so the model recognises this as
    /// executing an internal command (fuzzy search, alias resolve,
    /// section drill, etc.) rather than fetching a single topic.
    private static func handleExecuteCommand(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let cmd = argString(arguments["command"])
            ?? argString(arguments["browse_cmd"])
            ?? ""
        guard !cmd.isEmpty else {
            return textEnvelope(["error": "command argument required"], isError: true)
        }
        do {
            let body = try await postGetPluginInfo(title: cmd, markdown: true, timeout: 1.0)
            let rendered = renderPluginInfoAsMarkdown(body)
            let capped = enforceTokenCap(
                rendered,
                cap: AppBundleConfiguration.xlbTokenCapTopic(),
                hint: "narrow the command or use xlb_get_topic_section for a specific tag"
            )
            return textEnvelope(["content": capped], isError: false)
        } catch {
            return textEnvelope(["error": httpErrorMessage(error)], isError: true)
        }
    }

    private static func handleGetTopic(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let cmd = argString(arguments["browse_cmd"]), !cmd.isEmpty else {
            return textEnvelope(["error": "browse_cmd argument required"], isError: true)
        }
        do {
            let body = try await postGetPluginInfo(title: cmd, markdown: true, timeout: 1.0)
            let rendered = renderPluginInfoAsMarkdown(body)
            let capped = enforceTokenCap(
                rendered,
                cap: AppBundleConfiguration.xlbTokenCapTopic(),
                hint: "use xlb_get_topic_section with mode=count to explore sections instead"
            )
            return textEnvelope(["content": capped], isError: false)
        } catch {
            return textEnvelope(["error": httpErrorMessage(error)], isError: true)
        }
    }

    private static func handleGetTopicMeta(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let topic = argString(arguments["topic"]), !topic.isEmpty else {
            return textEnvelope(["error": "topic argument required"], isError: true)
        }
        // F16: compose meta from local sqlite (hierarchy, searchin edges,
        // community peers, section counts) plus one HTTP `/getPluginInfo`
        // call appended at the end. This mirrors the reference Python
        // `--meta` output structure so downstream callers see:
        //   ## Hierarchy   -- library + parent
        //   ## Searchin out / Searchin in  -- directed edge peers
        //   ## Community peers  -- co-cluster members from LPA
        //   ## Tag section counts -- children grouped by tag_name provenance
        //   ## Plugin info      -- upstream HTTP body
        // The wiki `prior_research` pointer from Python is intentionally
        // omitted (out of scope per project directive).
        let idx = XLBTopicIndex.shared
        let hierarchy = await idx.topicHierarchy(name: topic)
        let outEdges = await idx.searchinOut(from: topic, limit: 50)
        let inEdges = await idx.searchinIn(to: topic, limit: 50)
        let peers = await idx.communityPeers(of: topic, limit: 15)
        let tagSections = await idx.tagSectionCounts(topic: topic)

        var chunks: [String] = []

        if let h = hierarchy {
            var block = "## Hierarchy"
            if !h.library.isEmpty {
                block += "\n- Library: \(h.library)"
            }
            if let parent = h.parent, !parent.isEmpty {
                block += "\n- Parent: \(parent)"
            }
            chunks.append(block)
        }

        if !outEdges.isEmpty {
            var block = "## Searchin out (\(outEdges.count))"
            for e in outEdges { block += "\n- \(e.peer)" }
            chunks.append(block)
        }
        if !inEdges.isEmpty {
            var block = "## Searchin in (\(inEdges.count))"
            for e in inEdges { block += "\n- \(e.peer)" }
            chunks.append(block)
        }

        if !peers.isEmpty {
            var block = "## Community peers (\(peers.count))"
            for p in peers { block += "\n- \(p)" }
            block += "\n\nNote: OpenClicky's community detection uses synchronous LPA; xlinkBook-skill uses an external clustering pass. Cluster labels may differ."
            chunks.append(block)
        }

        if !tagSections.isEmpty {
            var block = "### Tag section counts"
            for s in tagSections { block += "\n- \(s.tagName): \(s.count)" }
            chunks.append(block)
        }

        // Fetch upstream plugin info (best-effort; failure downgrades the
        // block to a short note so the local-only sections still return).
        var pluginBlock = "## Plugin info\n(none)"
        do {
            let body = try await postGetPluginInfo(title: topic, markdown: true, timeout: 0.5)
            let rendered = renderPluginInfoAsMarkdown(body)
            if !rendered.isEmpty {
                pluginBlock = "## Plugin info\n\(rendered)"
            }
        } catch {
            pluginBlock = "## Plugin info\n(unavailable: \(httpErrorMessage(error)))"
        }
        chunks.append(pluginBlock)

        let metaHint = "narrow to a more specific topic or drill via xlb_get_topic_section"
        if chunks.count == 1 {
            // Only plugin info survived: still return it so caller isn't
            // left empty-handed.
            return textEnvelope([
                "meta": enforceTokenCap(pluginBlock, cap: AppBundleConfiguration.xlbTokenCapMeta(), hint: metaHint)
            ], isError: false)
        }
        let meta = chunks.joined(separator: "\n\n")
        return textEnvelope([
            "meta": enforceTokenCap(meta, cap: AppBundleConfiguration.xlbTokenCapMeta(), hint: metaHint)
        ], isError: false)
    }

    private static func handleGetTopicSection(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        guard let topic = argString(arguments["topic"]), !topic.isEmpty else {
            return textEnvelope(["error": "topic argument required"], isError: true)
        }
        guard let section = argString(arguments["section"]), !section.isEmpty else {
            return textEnvelope(["error": "section argument required"], isError: true)
        }
        // xlb DSL requires the leading `>` so xlinkBook parses this as
        // "browse into topic Foo, section bar". Missing `>` matched an
        // earlier code path but caused edge-case KeyError responses.
        var title = ">\(topic)/\(section):"
        if let filter = argString(arguments["filter"]), !filter.isEmpty {
            title += filter
        }

        // Pagination + mode arguments. `mode` defaults to `summary` for
        // safe context usage; callers hit `count` first on heavy sections.
        let limit = clampInt(argInt(arguments["limit"]) ?? 20, min: 1, max: 100)
        let offset = max(0, argInt(arguments["offset"]) ?? 0)
        let modeRaw = (argString(arguments["mode"]) ?? "summary").lowercased()
        let mode: String
        switch modeRaw {
        case "count", "summary", "full": mode = modeRaw
        default: mode = "summary"
        }

        // F17: the schema no longer advertises `expand` because
        // xlinkBook's HTTP layer does not expose the CLI's `--expand`
        // semantics. Callers that need URL contents should follow up
        // with `xlb_get_topic` on the browse commands returned here.
        do {
            let body = try await postGetPluginInfo(title: title, markdown: true, timeout: 0.5)
            let rendered = renderPluginInfoAsMarkdown(body)
            let items = parseSectionItems(markdown: rendered)
            let total = items.count
            let sliceStart = min(offset, total)
            let sliceEnd = min(offset + limit, total)
            let slice = (sliceStart < sliceEnd) ? Array(items[sliceStart..<sliceEnd]) : []

            let sectionHint = "raise offset or lower limit; use mode=count for totals"
            switch mode {
            case "count":
                let rawTitles = slice.map { extractTitleAndUrl(item: $0).title }
                let joined = rawTitles.joined(separator: "\n")
                let capped = enforceTokenCap(joined, cap: AppBundleConfiguration.xlbTokenCapSectionCount(), hint: sectionHint)
                let cappedTitles = capped.components(separatedBy: "\n")
                return textEnvelope([
                    "count": total,
                    "shown": slice.count,
                    "offset": offset,
                    "limit": limit,
                    "mode": mode,
                    "titles": cappedTitles
                ], isError: false)
            case "full":
                let content = slice.joined(separator: "\n")
                return textEnvelope([
                    "count": total,
                    "shown": slice.count,
                    "offset": offset,
                    "limit": limit,
                    "mode": mode,
                    "content": enforceTokenCap(content, cap: AppBundleConfiguration.xlbTokenCapSectionFull(), hint: sectionHint)
                ], isError: false)
            default:
                // "summary"
                let entries: [[String: Any]] = slice.map { raw in
                    let parsed = extractTitleAndUrl(item: raw)
                    var entry: [String: Any] = ["title": parsed.title]
                    if let url = parsed.url { entry["url"] = url }
                    return entry
                }
                // Approximate the payload weight from the serialized entries
                // so we can flag oversize summaries without mutating the
                // structured items array.
                let summaryText = entries.map { entry -> String in
                    let title = (entry["title"] as? String) ?? ""
                    let url = (entry["url"] as? String) ?? ""
                    return url.isEmpty ? title : "\(title) \(url)"
                }.joined(separator: "\n")
                let summaryCap = AppBundleConfiguration.xlbTokenCapSectionSummary()
                let capped = enforceTokenCap(summaryText, cap: summaryCap, hint: sectionHint)
                var envelope: [String: Any] = [
                    "count": total,
                    "shown": slice.count,
                    "offset": offset,
                    "limit": limit,
                    "mode": mode,
                    "items": entries
                ]
                if capped.hasSuffix("]") && capped.contains("[TRUNCATED:") {
                    envelope["notice"] = "response exceeded \(summaryCap) tokens; \(sectionHint)"
                }
                return textEnvelope(envelope, isError: false)
            }
        } catch {
            return textEnvelope(["error": httpErrorMessage(error)], isError: true)
        }
    }

    /// Split rendered section text into individual item strings.
    /// Recognises bullet lines (`- foo`, `* foo`) and falls back to
    /// non-empty newline-separated blocks when no bullets are present.
    private static func parseSectionItems(markdown: String) -> [String] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        let rawLines = trimmed.components(separatedBy: "\n")
        var bulletItems: [String] = []
        var current: [String] = []

        func flushCurrent() {
            if !current.isEmpty {
                let joined = current.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { bulletItems.append(joined) }
                current.removeAll(keepingCapacity: true)
            }
        }

        for line in rawLines {
            let ltrim = line.drop { $0 == " " || $0 == "\t" }
            if ltrim.hasPrefix("- ") || ltrim.hasPrefix("* ") {
                flushCurrent()
                let body = String(ltrim.dropFirst(2))
                current.append(body)
            } else if ltrim.hasPrefix("-") || ltrim.hasPrefix("*") {
                // Bare "-" or "*" (no space) as a bullet marker.
                if ltrim.count == 1 {
                    flushCurrent()
                    current.append("")
                } else if !current.isEmpty {
                    current.append(String(line))
                }
            } else if !current.isEmpty {
                current.append(String(line))
            }
        }
        flushCurrent()

        if !bulletItems.isEmpty { return bulletItems }

        // Fallback: split on blank lines; treat each non-empty block as an item.
        var blocks: [String] = []
        var buffer: [String] = []
        for line in rawLines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !buffer.isEmpty {
                    blocks.append(buffer.joined(separator: "\n"))
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(line)
            }
        }
        if !buffer.isEmpty { blocks.append(buffer.joined(separator: "\n")) }
        if !blocks.isEmpty { return blocks }

        // Last resort: each non-empty line becomes its own item.
        return rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Extract a display title and optional URL from a parsed section item.
    /// Recognises markdown `[title](url)` links and bare URLs. Falls back
    /// to the first non-empty line as the title.
    private static func extractTitleAndUrl(item: String) -> (title: String, url: String?) {
        let firstLine = item
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.isEmpty {
            let fallback = item.trimmingCharacters(in: .whitespacesAndNewlines)
            return (fallback, nil)
        }

        // Markdown link: [title](url)
        if let re = try? NSRegularExpression(
            pattern: "\\[([^\\]]+)\\]\\(([^\\)\\s]+)(?:\\s+\"[^\"]*\")?\\)",
            options: []
        ) {
            let ns = firstLine as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: firstLine, options: [], range: range),
               m.numberOfRanges >= 3 {
                let title = ns.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let url = ns.substring(with: m.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (title.isEmpty ? url : title, url.isEmpty ? nil : url)
            }
        }

        // Bare URL fallback.
        if let re = try? NSRegularExpression(
            pattern: "https?://[^\\s\\)\\]]+",
            options: []
        ) {
            let ns = firstLine as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: firstLine, options: [], range: range) {
                let url = ns.substring(with: m.range)
                var title = firstLine.replacingOccurrences(of: url, with: "")
                title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t-:,;()[]"))
                if title.isEmpty { title = url }
                return (title, url)
            }
        }

        return (firstLine, nil)
    }

    private static func handleGraph(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let mode = argString(arguments["mode"]) ?? ""
        switch mode {
        case "path":
            return await handleGraphPath(arguments: arguments)
        case "explore":
            return await handleGraphExplore(arguments: arguments)
        case "hubs":
            return await handleGraphHubs(arguments: arguments)
        case "community":
            return await handleGraphCommunity(arguments: arguments)
        default:
            return textEnvelope([
                "error": "unknown mode: \(mode). Valid modes: path, explore, hubs, community.",
                "mode": mode
            ], isError: true)
        }
    }

    /// F11: parse an optional `kinds` array argument into a validated set
    /// of edge-kind strings. Omission means "server default" (searchin
    /// only, matching Python's `_graph_neighbors`).
    private static func argKindsSet(_ any: Any?) -> Set<String>? {
        guard let raw = any else { return nil }
        if let arr = raw as? [Any] {
            var out = Set<String>()
            for value in arr {
                if let s = value as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !t.isEmpty { out.insert(t) }
                }
            }
            return out.isEmpty ? nil : out
        }
        if let s = raw as? String {
            let split = s.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            return split.isEmpty ? nil : Set(split)
        }
        return nil
    }

    private static func handleGraphHubs(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let requested = argInt(arguments["limit"]) ?? 10
        let limit = min(50, max(1, requested))
        // F12: default to searchin-only degree (Python parity). Callers can
        // pass an explicit `kinds` array to widen the metric.
        let kinds = argKindsSet(arguments["kinds"]) ?? ["searchin"]
        let hubs = await XLBTopicIndex.shared.graphHubs(limit: limit, kinds: kinds)
        if hubs.isEmpty {
            return textEnvelope([
                "content": "No hubs available. Sync the xlinkBook library first (Settings > xlinkBook Integration).",
                "source": "sqlite"
            ], isError: false)
        }
        let kindsLabel = kinds.sorted().joined(separator: ", ")
        var lines: [String] = ["## Top \(hubs.count) hubs by \(kindsLabel)-degree"]
        for h in hubs {
            lines.append("- \(h.name): \(h.degree) connections")
        }
        return textEnvelope([
            "content": enforceTokenCap(
                lines.joined(separator: "\n"),
                cap: AppBundleConfiguration.xlbTokenCapGraph(),
                hint: "lower limit to trim the hub list"
            ),
            "count": hubs.count,
            "source": "sqlite"
        ], isError: false)
    }

    private static func handleGraphCommunity(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let requested = argInt(arguments["limit"]) ?? 10
        let limit = min(50, max(1, requested))
        let clusters = await XLBTopicIndex.shared.graphCommunity(minSize: 3)
        if clusters.isEmpty {
            return textEnvelope([
                "content": "No communities of size >= 3 found. Sync the xlinkBook library first.",
                "source": "sqlite"
            ], isError: false)
        }
        let shown = Array(clusters.prefix(limit))
        var lines: [String] = ["## Communities (\(clusters.count) clusters, showing top \(shown.count))"]
        for (idx, members) in shown.enumerated() {
            let clusterNo = idx + 1
            lines.append("")
            lines.append("### Cluster \(clusterNo) (size \(members.count))")
            let head = members.prefix(15)
            for name in head {
                lines.append("- \(name)")
            }
            if members.count > head.count {
                lines.append("- ...and \(members.count - head.count) more")
            }
        }
        // F13: document the divergence from the reference Python pipeline
        // right in the tool output so downstream callers (or the model
        // reading the output) can reason about the label mismatch.
        lines.append("")
        lines.append("Note: OpenClicky's community detection uses synchronous LPA; xlinkBook-skill uses an external clustering pass. Cluster labels may differ.")
        return textEnvelope([
            "content": enforceTokenCap(
                lines.joined(separator: "\n"),
                cap: AppBundleConfiguration.xlbTokenCapGraph(),
                hint: "lower limit or request a smaller community slice"
            ),
            "clusters": clusters.count,
            "shown": shown.count,
            "source": "sqlite"
        ], isError: false)
    }

    private static func handleGraphPath(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let from = argString(arguments["from"]), !from.isEmpty else {
            return textEnvelope(["error": "from argument required for mode=path"], isError: true)
        }
        guard let to = argString(arguments["to"]), !to.isEmpty else {
            return textEnvelope(["error": "to argument required for mode=path"], isError: true)
        }
        // F15: `maxDepth` is now caller-tunable (1..20, default 12) to
        // remove the arbitrary 6-hop ceiling that the reference Python
        // path solver does not impose.
        let requestedDepth = argInt(arguments["maxDepth"]) ?? 12
        let maxDepth = min(20, max(1, requestedDepth))
        if let path = await XLBTopicIndex.shared.graphPath(from: from, to: to, maxDepth: maxDepth) {
            let hops = max(0, path.count - 1)
            let chain = path.joined(separator: " -> ")
            let md = "Path (\(hops) hops): \(chain)"
            return textEnvelope([
                "content": enforceTokenCap(
                    md,
                    cap: AppBundleConfiguration.xlbTokenCapGraph(),
                    hint: "shorten maxDepth or pick closer endpoints"
                ),
                "hops": hops,
                "source": "sqlite"
            ], isError: false)
        }
        return textEnvelope([
            "content": "No path within \(maxDepth) hops between \(from) and \(to)",
            "source": "sqlite"
        ], isError: false)
    }

    private static func handleGraphExplore(arguments: [String: Any]) async -> ([String: Any], Bool) {
        guard let from = argString(arguments["from"]), !from.isEmpty else {
            return textEnvelope(["error": "from argument required for mode=explore"], isError: true)
        }
        let hopsArg = argInt(arguments["hops"]) ?? 1
        // F14: raise per-call cap from 3 to 10; internal actor still
        // guards against runaway BFS via its own visited-set ceiling.
        let hops = min(10, max(1, hopsArg))
        // Python's `_graph_explore` hard-codes `follow_rels = {"searchin"}`.
        // We keep that default here so a plain `mode=explore` call walks the
        // same edge set as the Python reference. Callers can widen via the
        // `kinds` argument.
        let kinds = argKindsSet(arguments["kinds"]) ?? ["searchin"]
        // Python default limit is 50 (see `_graph_explore(gf, start, ..., limit=50)`).
        // Cap client-supplied values at 200 so a bad prompt cannot force
        // OpenClicky to spool the entire connected component into the UI.
        let limitArg = argInt(arguments["limit"]) ?? 50
        let limit = min(200, max(1, limitArg))
        let neighbors = await XLBTopicIndex.shared.graphExplore(
            from: from, hops: hops, kinds: kinds, limit: limit
        )
        if neighbors.isEmpty {
            return textEnvelope([
                "content": "No neighbors found within \(hops) hop(s) of \(from)",
                "source": "sqlite"
            ], isError: false)
        }
        // Group by distance for readability.
        var lines: [String] = []
        var currentDistance = -1
        for n in neighbors {
            if n.distance != currentDistance {
                if !lines.isEmpty { lines.append("") }
                lines.append("Distance \(n.distance):")
                currentDistance = n.distance
            }
            let hopWord = n.distance == 1 ? "hop" : "hops"
            lines.append("- \(n.name) (\(n.distance) \(hopWord), \(n.kind))")
        }
        let md = lines.joined(separator: "\n")
        return textEnvelope([
            "content": enforceTokenCap(
                md,
                cap: AppBundleConfiguration.xlbTokenCapGraph(),
                hint: "reduce hops or lower limit"
            ),
            "count": neighbors.count,
            "total": neighbors.count,
            "source": "sqlite"
        ], isError: false)
    }

    private static func handleAgentState(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let withMeta = argBool(arguments["with_meta"]) ?? true
        let consume = argBool(arguments["consume"]) ?? false

        let host = AppBundleConfiguration.xlbHostUrl()
        guard !host.isEmpty else {
            return textEnvelope([
                "error": "xlb host url not configured (Settings > xlinkBook Integration)"
            ], isError: true)
        }
        var comps = URLComponents(string: host + "/.well-known/agent-state")
        comps?.queryItems = [
            URLQueryItem(name: "mode", value: "summary"),
            URLQueryItem(name: "with_meta", value: withMeta ? "1" : "0"),
            URLQueryItem(name: "consume", value: consume ? "1" : "0")
        ]
        guard let url = comps?.url else {
            return textEnvelope(["error": "invalid xlb host url"], isError: true)
        }

        do {
            let text = try await fetchString(url: url, timeout: 0.2)
            return textEnvelope([
                "state": enforceTokenCap(
                    text,
                    cap: AppBundleConfiguration.xlbTokenCapState(),
                    hint: "pass with_meta=false or consume=true to trim state"
                )
            ], isError: false)
        } catch {
            return textEnvelope([
                "error": "xlinkBook server not reachable at \(AppBundleConfiguration.xlbHostUrl())",
                "detail": String(describing: error)
            ], isError: true)
        }
    }

    private static func handleGrammarHelp() -> ([String: Any], Bool) {
        let grammar = """
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
        return textEnvelope(["grammar": grammar], isError: false)
    }

    /// Wraps xlinkBook's `POST /onGetAllLinksFromUrl` — a smart link
    /// extractor that auto-detects YouTube / Bilibili / GitHub awesome
    /// READMEs / Reddit / Substack / Wikipedia list pages / HuggingFace
    /// collections / HN threads / generic RSS/Atom feeds, then falls
    /// back to `<a href>` scraping. Advertised in xlinkBook's
    /// `.well-known/agent-skills` catalog as a `fast_path`.
    ///
    /// Response is `*`-joined `url#title` pairs — we parse and return
    /// a structured array so callers don't need to know the wire form.
    private static func handleExtractLinks(arguments: [String: Any]) async
        -> ([String: Any], Bool)
    {
        let url = (arguments["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else {
            return textEnvelope(["error": "url argument required"], isError: true)
        }
        let parent = (arguments["parent"] as? String) ?? ""
        do {
            let body = try await postOnGetAllLinksFromUrl(url: url, parent: parent, timeout: 30)
            let parts = body.split(separator: "*").map(String.init)
            var items: [[String: String]] = []
            for chunk in parts {
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // Split at the FIRST `#` so URLs containing `#` fragments
                // still parse cleanly (fragment lives in the title side of
                // the pair per xlinkBook's convention).
                if let hashIdx = trimmed.firstIndex(of: "#") {
                    let u = String(trimmed[..<hashIdx])
                    let t = String(trimmed[trimmed.index(after: hashIdx)...])
                    items.append(["url": u, "title": t])
                } else {
                    items.append(["url": trimmed, "title": ""])
                }
            }
            return textEnvelope([
                "ok": true,
                "source_url": url,
                "count": items.count,
                "items": items
            ], isError: false)
        } catch {
            return textEnvelope([
                "ok": false,
                "error": error.localizedDescription
            ], isError: true)
        }
    }

    private static func postOnGetAllLinksFromUrl(
        url: String, parent: String, timeout: TimeInterval
    ) async throws -> String {
        let host = AppBundleConfiguration.xlbHostUrl()
        guard !host.isEmpty else {
            throw NSError(domain: "XLBSensorTools", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "xlb host url not configured (Settings > xlinkBook Integration)"
            ])
        }
        guard let endpoint = URL(string: host + "/onGetAllLinksFromUrl") else {
            throw NSError(domain: "XLBSensorTools", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "invalid xlb host url: \(host)"
            ])
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [("url", url)]
        if !parent.isEmpty { fields.append(("parent", parent)) }
        req.httpBody = urlEncodeForm(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "XLBSensorTools", code: status, userInfo: [
                NSLocalizedDescriptionKey: "xlinkBook http \(status)"
            ])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Subprocess + HTTP

    /// POST /getPluginInfo with form-encoded `title` + optional `markdown=1`.
    /// Returns the response body as UTF-8 string.
    private static func postGetPluginInfo(title: String, markdown: Bool, timeout: TimeInterval)
        async throws -> String
    {
        let host = AppBundleConfiguration.xlbHostUrl()
        guard !host.isEmpty else {
            throw NSError(domain: "XLBSensorTools", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "xlb host url not configured (Settings > xlinkBook Integration)"
            ])
        }
        guard let url = URL(string: host + "/getPluginInfo") else {
            throw NSError(domain: "XLBSensorTools", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "invalid xlb host url: \(host)"
            ])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // xlinkBook's handleCommand indexes `requestForm['url']` UNCONDITIONALLY
        // (app.py:2363). Omitting `url` raises KeyError → HTTP 500. The Chrome
        // plugin sends the current tab URL there; for our HTTP calls the
        // field is semantically empty but must exist as a string.
        var fields: [(String, String)] = [("title", title), ("url", "")]
        if markdown { fields.append(("markdown", "1")) }
        req.httpBody = urlEncodeForm(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "XLBSensorTools", code: status, userInfo: [
                NSLocalizedDescriptionKey: "xlinkBook http \(status)"
            ])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// xlinkBook's /getPluginInfo returns either markdown (when markdown=1
    /// is honoured by the record type) or raw HTML. When we get HTML,
    /// strip tags to a compact plain-text form; when markdown, pass through.
    private static func renderPluginInfoAsMarkdown(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let looksHtml = trimmed.hasPrefix("<") ||
            trimmed.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil ||
            trimmed.range(of: "<html", options: .caseInsensitive) != nil
        if !looksHtml { return trimmed }
        return stripHtmlToPlainText(trimmed)
    }

    private static func stripHtmlToPlainText(_ html: String) -> String {
        var text = html
        // Drop script/style/head bodies first (paired open+close form).
        for tag in ["script", "style", "head"] {
            let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                text = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        }
        // F20: some responses ship an unclosed `<script ...>` or `<style ...>`
        // open tag with no matching close; strip those with a second pass
        // so the general tag stripper below doesn't leave the attribute
        // text visible.
        for tag in ["script", "style"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Line breaks for common block tags.
        for tag in ["br", "p", "div", "li", "tr"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // Strip remaining tags.
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression]
        )
        // F19: named-entity map extended to cover the full set that
        // xlinkBook's Flask templates and Python-side servers emit.
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&ndash;", "-"),
            ("&mdash;", "-"),
            ("&hellip;", "..."),
            ("&lsquo;", "'"),
            ("&rsquo;", "'"),
            ("&ldquo;", "\""),
            ("&rdquo;", "\""),
            ("&copy;", "(c)"),
            ("&reg;", "(R)"),
            ("&trade;", "(TM)"),
            ("&middot;", "-"),
            ("&laquo;", "<<"),
            ("&raquo;", ">>")
        ]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        // F19: one generic pass for `&#NNN;` numeric entities. Any
        // undecoded named entities fall through unchanged.
        text = decodeNumericEntities(in: text)
        // Collapse whitespace runs.
        text = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: [.regularExpression]
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace `&#N;` decimal numeric entities with their Unicode scalar
    /// equivalents. Values outside the valid scalar range or that fail to
    /// map are left untouched so surrounding text remains intact.
    private static func decodeNumericEntities(in source: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&#(\\d+);", options: []) else {
            return source
        }
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: source, options: [], range: full)
        if matches.isEmpty { return source }
        var out = ""
        var cursor = 0
        for m in matches {
            let whole = m.range
            let numRange = m.range(at: 1)
            if whole.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            }
            let numStr = ns.substring(with: numRange)
            if let value = UInt32(numStr), let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            } else {
                out += ns.substring(with: whole)
            }
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func httpErrorMessage(_ error: Error) -> String {
        let nsErr = error as NSError
        if let localized = nsErr.userInfo[NSLocalizedDescriptionKey] as? String {
            return "xlinkBook request failed: \(localized)"
        }
        return "xlinkBook request failed: \(nsErr.localizedDescription)"
    }

    private static func urlEncodeForm(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static func fetchString(url: URL, timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "XLBSensorTools", code: status, userInfo: [
                NSLocalizedDescriptionKey: "http \(status)"
            ])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Envelope + arg helpers

    private static func textEnvelope(_ body: [String: Any], isError: Bool)
        -> ([String: Any], Bool)
    {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "{}"
        }
        return ([
            "content": [
                ["type": "text", "text": json]
            ]
        ], isError)
    }

    private static func argString(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func argInt(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func argBool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let lo = s.lowercased()
            if lo == "true" || lo == "1" || lo == "yes" { return true }
            if lo == "false" || lo == "0" || lo == "no" { return false }
        }
        return nil
    }

    private static func clampInt(_ v: Int, min lo: Int, max hi: Int) -> Int {
        return max(lo, min(hi, v))
    }

    // MARK: - Turn budget

    /// Per-turn cumulative token budget shared across all xlb tool calls.
    /// CompanionManager is expected to call `resetTurnBudget()` at the start
    /// of each user turn once the wiring lands.
    private static let turnBudget = TurnBudgetActor()

    private static func turnBudgetErrorHint() -> String {
        let cap = AppBundleConfiguration.xlbTurnBudget()
        return "xlb turn budget (\(cap) tokens) exceeded. Wait for next user turn, or synthesize from existing context."
    }

    /// Charge the completed handler response against the per-turn budget.
    /// If the response would push us past the configured ceiling, replace
    /// it with an error envelope instead of forwarding the payload.
    private static func applyTurnBudget(to result: ([String: Any], Bool)) async
        -> ([String: Any], Bool)
    {
        let (envelope, isError) = result
        let approxTokens = envelopeTokenEstimate(envelope)
        let decision = await turnBudget.consume(approxTokens)
        if decision.allowed { return (envelope, isError) }
        return textEnvelope([
            "error": turnBudgetErrorHint(),
            "consumed_so_far": decision.remaining
        ], isError: true)
    }

    /// Approximate the token cost of an outgoing envelope by walking the
    /// `content[*].text` payloads and summing `count / 4`.
    private static func envelopeTokenEstimate(_ envelope: [String: Any]) -> Int {
        guard let items = envelope["content"] as? [[String: Any]] else { return 0 }
        var chars = 0
        for entry in items {
            if let text = entry["text"] as? String { chars += text.count }
        }
        return chars / 4
    }
}

/// Actor-backed cumulative token counter used to guard against a single
/// user turn spending unbounded context on xlb tool calls.
actor TurnBudgetActor {
    private var totalTokensThisTurn: Int = 0

    func consume(_ tokens: Int) -> (allowed: Bool, remaining: Int) {
        let cap = AppBundleConfiguration.xlbTurnBudget()
        let projected = totalTokensThisTurn + max(0, tokens)
        if projected > cap {
            return (false, totalTokensThisTurn)
        }
        totalTokensThisTurn = projected
        return (true, cap - totalTokensThisTurn)
    }

    func reset() {
        totalTokensThisTurn = 0
    }
}
