// Ported from Everywhere: src/Everywhere.Mcp/Tools/MetaTools.cs + GateTools.cs + BatchTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for OpenClickyMetaToolRegistry + OpenClickyBM25Index.
// Non-interactive; no networking, no MCP transport — the dispatch
// delegate is mocked so tests can exercise call_tool / batch without
// running the openclicky bridge.

import XCTest
@testable import OpenClickyContextService

final class OpenClickyMetaToolsTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Fresh UserDefaults suite per test — activation state is
    /// persisted, so shared suites would leak across tests.
    private func makeDefaults(suffix: String = UUID().uuidString) -> UserDefaults {
        let suite = "openclicky.meta.tests.\(suffix)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeRegistry(delegate: MetaToolDispatchDelegate? = nil) -> OpenClickyMetaToolRegistry {
        return OpenClickyMetaToolRegistry(userDefaults: makeDefaults(), dispatchDelegate: delegate)
    }

    /// Sample descriptors modelled after openclicky sensor tools per
    /// `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md`. 20 entries so
    /// `search_tools` has enough signal for BM25 to rank against.
    private func sampleDescriptors() -> [MetaToolDescriptor] {
        return [
            .init(name: "list_more_tools", description: "List long-tail tools by category.", domain: OpenClickyMetaDomain.core, isHidden: false),
            .init(name: "call_tool", description: "Invoke any registered tool by name.", domain: OpenClickyMetaDomain.core, isHidden: false),
            .init(name: "search_tools", description: "BM25 keyword search over the self-expanding tool catalog.", domain: OpenClickyMetaDomain.core, isHidden: false),
            .init(name: "activate_domain", description: "Activate a domain group so its tools appear in tools/list.", domain: OpenClickyMetaDomain.core, isHidden: false),
            .init(name: "list_domains", description: "Enumerate available domain groups and activation state.", domain: OpenClickyMetaDomain.core, isHidden: false),
            .init(name: "browser_snapshot", description: "DOM ARIA tree of the active browser tab.", domain: OpenClickyMetaDomain.browser, isHidden: true),
            .init(name: "browser_click", description: "Click an element in the active tab by ref.", domain: OpenClickyMetaDomain.browser, isHidden: true),
            .init(name: "browser_fill", description: "Fill an input in the active browser tab.", domain: OpenClickyMetaDomain.browser, isHidden: true),
            .init(name: "terminal_scrollback", description: "Read scrollback from Terminal.app.", domain: OpenClickyMetaDomain.terminal, isHidden: true),
            .init(name: "finder_selection", description: "Read the current Finder selection.", domain: OpenClickyMetaDomain.finder, isHidden: true),
            .init(name: "read_whiteboard", description: "Consume whiteboard stash markdown.", domain: OpenClickyMetaDomain.whiteboard, isHidden: true),
            .init(name: "read_whiteboard_image", description: "Fetch one image from a prior whiteboard payload.", domain: OpenClickyMetaDomain.whiteboard, isHidden: true),
            .init(name: "doc_read_pdf", description: "Extract text from a PDF document file.", domain: OpenClickyMetaDomain.docReaders, isHidden: true),
            .init(name: "doc_read_docx", description: "Extract text from a DOCX Word document.", domain: OpenClickyMetaDomain.docReaders, isHidden: true),
            .init(name: "doc_read_xlsx", description: "Extract sheets from an XLSX spreadsheet as CSV.", domain: OpenClickyMetaDomain.docReaders, isHidden: true),
            .init(name: "web_search", description: "Search the web using the configured search provider.", domain: OpenClickyMetaDomain.web, isHidden: false),
            .init(name: "web_fetch_url", description: "Fetch a URL and return the readable article body.", domain: OpenClickyMetaDomain.web, isHidden: false),
            .init(name: "memory_read", description: "Read a site memory summary.", domain: OpenClickyMetaDomain.memory, isHidden: true),
            .init(name: "memory_freshness", description: "Classify site memory freshness stale or fresh.", domain: OpenClickyMetaDomain.memory, isHidden: true),
            .init(name: "orchestrate_dispatch", description: "Dispatch a plan step to the orchestrator.", domain: OpenClickyMetaDomain.orchestrate, isHidden: true),
        ]
    }

    // MARK: - BM25

    func test_bm25_tokenizer_matches_everywhere_alphanumeric_split() {
        // Everywhere: `foreach c in s.ToLowerInvariant(): IsLetterOrDigit(c) ...`
        let out = OpenClickyBM25Index.tokenize("Hello, World! search_tools v2.0")
        XCTAssertEqual(out, ["hello", "world", "search", "tools", "v2", "0"])
    }

    func test_search_tools_returns_topK_ranked_results() {
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        // Query "browser click" should rank the two browser_* entries
        // above unrelated tools; browser_click should be #1 because
        // it matches both tokens.
        let hits = registry.searchTools(query: "browser click", topK: 5)
        XCTAssertFalse(hits.isEmpty, "expected BM25 hits for a well-formed query")
        XCTAssertEqual(hits.first?.name, "browser_click",
            "top hit should be browser_click (matches both query tokens); got \(hits.map(\.name))")
        XCTAssertLessThanOrEqual(hits.count, 5, "topK must cap the result set")
    }

    func test_search_tools_known_query_returns_known_top_result() {
        // Task-required probe: given a known query, we should get a
        // known top result. Everywhere `SearchTools.cs:78-96` returns
        // top-K by score desc; openclicky mirrors that.
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        let hits = registry.searchTools(query: "pdf extract", topK: 3)
        XCTAssertEqual(hits.first?.name, "doc_read_pdf",
            "top hit for 'pdf extract' must be doc_read_pdf")
    }

    func test_search_tools_returns_empty_for_no_match() {
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        let hits = registry.searchTools(query: "quantum kubernetes zeppelin", topK: 5)
        XCTAssertEqual(hits, [], "no-match query should yield empty")
    }

    /// Regression for the Wave-2 review bug: re-registering the same
    /// tool name used to append a fresh Doc row on every call,
    /// inflating BM25 `N` (and therefore skewing IDF + avg_doc_len).
    /// After the fix a duplicate `register` must overwrite in place.
    func test_bm25_duplicate_register_does_not_inflate_N() {
        let registry = makeRegistry()
        let descriptor = MetaToolDescriptor(
            name: "foo",
            description: "Read a foo widget.",
            domain: OpenClickyMetaDomain.core,
            isHidden: false
        )
        registry.register(descriptor)
        registry.register(descriptor)
        registry.register(descriptor)

        XCTAssertEqual(registry.bm25DocumentCount, 1,
            "duplicate register must not append additional Doc rows to the BM25 index")
        XCTAssertEqual(registry.allDescriptors().count, 1,
            "registry must dedupe by tool name")

        let hits = registry.searchTools(query: "foo widget", topK: 5)
        XCTAssertEqual(hits.count, 1,
            "duplicate register must produce a single search result, not one per registration")
        XCTAssertEqual(hits.first?.name, "foo")
    }

    /// Follow-up: after re-registering with a different description,
    /// the stored Doc should reflect the latest description (not the
    /// original), and BM25 tokens from the OLD description should no
    /// longer contribute to search.
    func test_bm25_duplicate_register_overwrites_description() {
        let registry = makeRegistry()
        registry.register(.init(
            name: "foo",
            description: "obsolete apple documentation",
            domain: OpenClickyMetaDomain.core,
            isHidden: false
        ))
        registry.register(.init(
            name: "foo",
            description: "current banana catalog",
            domain: OpenClickyMetaDomain.core,
            isHidden: false
        ))

        XCTAssertEqual(registry.bm25DocumentCount, 1)
        // "banana" is only in the new description; must be findable.
        XCTAssertEqual(registry.searchTools(query: "banana", topK: 5).first?.name, "foo")
        // "apple" was only in the old description; must be gone.
        XCTAssertTrue(registry.searchTools(query: "apple", topK: 5).isEmpty,
            "tokens from the overwritten description must not linger in postings")
    }

    // MARK: - list_more_tools

    func test_list_more_tools_filters_by_category() {
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        let browserTools = registry.listMoreTools(category: OpenClickyMetaDomain.browser)
        XCTAssertFalse(browserTools.isEmpty)
        for tool in browserTools {
            XCTAssertEqual(tool.domain, OpenClickyMetaDomain.browser)
            XCTAssertTrue(tool.isHidden, "list_more_tools without FULL should return only hidden long-tail entries")
        }
        // Unknown category → empty.
        XCTAssertEqual(registry.listMoreTools(category: "nonsense"), [])
    }

    func test_list_more_tools_hides_core_tier_by_default() {
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        let out = registry.listMoreTools(category: OpenClickyMetaDomain.core)
        XCTAssertTrue(out.isEmpty,
            "core-tier entries are never hidden, so list_more_tools(core) is empty by default")
    }

    // MARK: - activate_domain / list_domains

    func test_activate_domain_unknown_returns_false() {
        let registry = makeRegistry()
        XCTAssertFalse(registry.activateDomain("banana"))
        XCTAssertFalse(registry.activatedDomains().contains("banana"))
    }

    func test_activate_domain_known_persists_across_registry_instances() {
        let defaults = makeDefaults(suffix: "persist")
        let r1 = OpenClickyMetaToolRegistry(userDefaults: defaults)
        XCTAssertTrue(r1.activateDomain(OpenClickyMetaDomain.browser))
        // New registry over the same defaults should see the persisted set.
        let r2 = OpenClickyMetaToolRegistry(userDefaults: defaults)
        XCTAssertTrue(r2.activatedDomains().contains(OpenClickyMetaDomain.browser))
        XCTAssertTrue(r2.activatedDomains().contains(OpenClickyMetaDomain.core),
            "core is always active")
    }

    func test_list_domains_reflects_registered_counts_and_activation() {
        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        _ = registry.activateDomain(OpenClickyMetaDomain.docReaders)

        let list = registry.listDomains()
        XCTAssertEqual(list.count, OpenClickyMetaDomain.all.count)
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        XCTAssertEqual(byName[OpenClickyMetaDomain.docReaders]?.toolCount, 3)
        XCTAssertEqual(byName[OpenClickyMetaDomain.docReaders]?.isActive, true)
        XCTAssertEqual(byName[OpenClickyMetaDomain.core]?.isActive, true, "core is always active")
        XCTAssertEqual(byName[OpenClickyMetaDomain.browser]?.isActive, false)
    }

    // MARK: - Env-var gates

    func test_env_full_gate_exposes_all_tools_via_list_more_tools() {
        // Set env then read via the API. ProcessInfo re-reads env on each
        // access, so setting via setenv works without process restart.
        setenv(OpenClickyMetaCoreToolGate.envVar, "1", 1)
        defer { unsetenv(OpenClickyMetaCoreToolGate.envVar) }

        XCTAssertFalse(OpenClickyMetaCoreToolGate.filterEnabled,
            "OPENCLICKY_MCP_FULL=1 must disable the gate (parity with EVERYWHERE_MCP_FULL=1)")

        let registry = makeRegistry()
        registry.register(sampleDescriptors())
        let out = registry.listMoreTools()
        // With gate off, every registered descriptor should surface.
        XCTAssertEqual(out.count, sampleDescriptors().count,
            "gate off should surface every registered tool; got \(out.map(\.name))")
    }

    func test_env_selfexpand_disabled_is_reflected_by_gate() {
        setenv(OpenClickyMetaSelfExpandGate.envVar, "0", 1)
        defer { unsetenv(OpenClickyMetaSelfExpandGate.envVar) }
        XCTAssertFalse(OpenClickyMetaSelfExpandGate.isEnabled)
    }

    func test_env_selfexpand_default_enabled() {
        unsetenv(OpenClickyMetaSelfExpandGate.envVar)
        XCTAssertTrue(OpenClickyMetaSelfExpandGate.isEnabled,
            "SELFEXPAND default must be ON (parity with SelfExpandGate.Enabled)")
    }

    // MARK: - Batch + call_tool

    /// Sequential dispatcher that records the order it was invoked in
    /// so tests can assert step-by-step execution.
    final class MockDispatch: MetaToolDispatchDelegate, @unchecked Sendable {
        private let lock = NSLock()
        var invocations: [(name: String, args: String?)] = []
        var responses: [String: String] = [:]
        var failFor: Set<String> = []

        func dispatch(name: String, argumentsJson: String?) async throws -> String {
            lock.lock()
            invocations.append((name, argumentsJson))
            let shouldFail = failFor.contains(name)
            let resp = responses[name] ?? "{}"
            lock.unlock()
            if shouldFail { throw MetaToolError.dispatchFailed(name: name, underlying: "mock failure") }
            return resp
        }
    }

    func test_batch_executes_sequentially_and_returns_results_in_order() async {
        let mock = MockDispatch()
        mock.responses = [
            "browser_click": "{\"ok\":true,\"step\":\"click\"}",
            "browser_fill": "{\"ok\":true,\"step\":\"fill\"}",
            "browser_snapshot": "{\"ok\":true,\"step\":\"snapshot\"}",
        ]
        let registry = makeRegistry(delegate: mock)
        registry.register(sampleDescriptors())

        let results = await registry.batch([
            .init(tool: "browser_click", argumentsJson: "{\"ref\":\"@ref1\"}"),
            .init(tool: "browser_fill", argumentsJson: "{\"ref\":\"@ref2\",\"value\":\"jason\"}"),
            .init(tool: "browser_snapshot", argumentsJson: nil),
        ])
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.tool), ["browser_click", "browser_fill", "browser_snapshot"])
        XCTAssertTrue(results.allSatisfy(\.ok))
        XCTAssertEqual(mock.invocations.map(\.name), ["browser_click", "browser_fill", "browser_snapshot"],
            "batch must dispatch steps in submission order")
    }

    func test_batch_stops_on_first_error() async {
        let mock = MockDispatch()
        mock.responses = ["browser_click": "{\"ok\":true}"]
        mock.failFor = ["browser_fill"]
        let registry = makeRegistry(delegate: mock)
        registry.register(sampleDescriptors())

        let results = await registry.batch([
            .init(tool: "browser_click", argumentsJson: nil),
            .init(tool: "browser_fill", argumentsJson: nil),
            .init(tool: "browser_snapshot", argumentsJson: nil),
        ])
        XCTAssertEqual(results.count, 2, "stops on first error — snapshot should not be attempted")
        XCTAssertTrue(results[0].ok)
        XCTAssertFalse(results[1].ok)
        XCTAssertNotNil(results[1].errorMessage)
        XCTAssertEqual(mock.invocations.map(\.name), ["browser_click", "browser_fill"])
    }

    func test_call_tool_unknown_throws() async {
        let mock = MockDispatch()
        let registry = makeRegistry(delegate: mock)
        registry.register(sampleDescriptors())
        do {
            _ = try await registry.callTool(name: "no_such_tool", argumentsJson: nil)
            XCTFail("expected unknownTool error")
        } catch let err as MetaToolError {
            guard case .unknownTool = err else {
                XCTFail("wrong error kind: \(err)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - StrategyNote

    func test_strategy_note_isComplete_rejects_short_evidence() {
        let note = StrategyNote(
            strategy: "public",
            contract: "stable",
            evidence: ["short"],
            replay: String(repeating: "x", count: 60),
            mutation: false,
            createdAt: 1
        )
        var missing: [String] = []
        XCTAssertFalse(note.isComplete(missing: &missing))
        XCTAssertTrue(missing.contains("evidence"))
    }

    func test_strategy_note_isComplete_accepts_valid_shape() {
        let note = StrategyNote(
            strategy: "public",
            contract: "stable",
            evidence: [
                "GET /api/items returns JSON list",
                "Response Content-Type application/json",
                "No auth cookies required for read",
            ],
            replay: String(repeating: "curl -sSL https://example.com/api/items | jq .", count: 2),
            mutation: false,
            createdAt: 1
        )
        var missing: [String] = []
        XCTAssertTrue(note.isComplete(missing: &missing))
        XCTAssertTrue(missing.isEmpty)
    }

    func test_validate_strategy_note_rejects_mutation_verb_without_flag() {
        let registry = makeRegistry()
        let note = StrategyNote(
            strategy: "public",
            contract: "stable",
            evidence: [
                "POST /api/items creates a new record",
                "Response 201 with Location header",
                "Requires session cookie sessionid",
            ],
            replay: String(repeating: "curl -X POST https://example.com/api/items -d '{}'", count: 2),
            mutation: false,
            createdAt: 1
        )
        do {
            try registry.validateStrategyNote(note)
            XCTFail("expected MUTATION_UNAPPROVED")
        } catch let err as MetaToolError {
            XCTAssertEqual(err.code, "MUTATION_UNAPPROVED")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Regression for the Wave-2 review bug: G7 used substring
    /// `.contains(verb)` which fired on "POSTAL", "OUTPUT", etc. After
    /// the fix a `\b(POST|PUT|DELETE|PATCH)\b` regex is used, so
    /// non-verb tokens embedding the substring must NOT trigger.
    func test_validate_strategy_note_g7_false_positives_do_not_trigger() throws {
        let registry = makeRegistry()
        let noiseLines: [[String]] = [
            [
                // "POSTAL" embeds POST but is not a verb.
                "postal address on record for user account is 1600 Amphitheatre Pkwy",
                "record persists after the checkout confirmation email is delivered",
                "no session cookie is required for the postal address read path",
            ],
            [
                // "OUTPUT" embeds PUT.
                "output shape from GET /api/items is a JSON list of objects",
                "the endpoint responds with cache headers on repeat reads",
                "no auth cookies are required for read-only access here",
            ],
            [
                // "PATCHY" embeds PATCH; "REPUTATIONAL" embeds PUT.
                "coverage remains patchy across the reputational metrics dashboard",
                "the dashboard renders even when telemetry has minor gaps",
                "no auth cookies are required for viewing aggregated metrics",
            ],
            [
                // "DELETES" embeds DELETE only if the guard is naive
                // (substring). With `\b(...)\b` word-boundary, DELETES
                // does NOT match because the word boundary is between
                // `E` and `S`.
                "the client-side cache DELETES stale entries after ten minutes",
                "no server round-trip is issued for evictions during idle state",
                "no auth cookies are required for the eviction path itself",
            ],
        ]
        for evidence in noiseLines {
            let note = StrategyNote(
                strategy: "public",
                contract: "stable",
                evidence: evidence,
                replay: String(repeating: "curl -sSL https://example.com/api/items | jq .", count: 2),
                mutation: false,
                createdAt: 1
            )
            XCTAssertNoThrow(try registry.validateStrategyNote(note),
                "evidence \(evidence) must not trigger G7 — no bare mutating verb present")
        }
    }

    /// Verify the fixed G7 still fires on genuine mutating verbs.
    func test_validate_strategy_note_g7_true_positives_still_trigger() {
        let registry = makeRegistry()
        let mutatingLines: [[String]] = [
            [
                "handler sends POST request to /api/items on submit",
                "response is 201 with a Location header pointing at the new row",
                "requires session cookie sessionid for authentication",
            ],
            [
                "the DELETE endpoint at /api/items/:id soft-deletes the row",
                "response is 204 with an empty body on success",
                "requires session cookie sessionid for authentication",
            ],
            [
                "PATCH /api/items/:id merges the given JSON body over the row",
                "response is 200 with the merged representation echoed back",
                "requires session cookie sessionid for authentication",
            ],
            [
                "PUT /api/items/:id replaces the row wholesale",
                "response is 200 with the new representation echoed back",
                "requires session cookie sessionid for authentication",
            ],
        ]
        for evidence in mutatingLines {
            let note = StrategyNote(
                strategy: "public",
                contract: "stable",
                evidence: evidence,
                replay: String(repeating: "curl -X POST https://example.com/api/items -d '{}'", count: 2),
                mutation: false,
                createdAt: 1
            )
            do {
                try registry.validateStrategyNote(note)
                XCTFail("expected MUTATION_UNAPPROVED for evidence \(evidence)")
            } catch let err as MetaToolError {
                XCTAssertEqual(err.code, "MUTATION_UNAPPROVED",
                    "evidence \(evidence) should trigger G7")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func test_validate_strategy_note_accepts_mutation_verb_when_flagged() {
        let registry = makeRegistry()
        let note = StrategyNote(
            strategy: "public",
            contract: "stable",
            evidence: [
                "POST /api/items creates a new record",
                "Response 201 with Location header",
                "Requires session cookie sessionid",
            ],
            replay: String(repeating: "curl -X POST https://example.com/api/items -d '{}'", count: 2),
            mutation: true,
            createdAt: 1
        )
        XCTAssertNoThrow(try registry.validateStrategyNote(note))
    }
}
