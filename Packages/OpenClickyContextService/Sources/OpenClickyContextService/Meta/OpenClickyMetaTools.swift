// Ported from Everywhere: src/Everywhere.Mcp/Tools/MetaTools.cs + GateTools.cs + BatchTool.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Self-expanding tool registry + core-tool gate for the openclicky
// `/mcp/sensor` MCP bridge. This file is intentionally pure logic:
//   * BM25 index over `(tool_name, description)` — 1:1 with
//     `Everywhere.Mcp.Meta.Bm25Index` (k1=1.5, b=0.75, tokenizer
//     splits on non-alphanumeric after lowercase; no stemming, no
//     stopwords).
//   * Domain grouping + activation set — mirrors
//     `Everywhere.Mcp.Meta.TierGate` + `SessionActivations`, with
//     `UserDefaults` persistence in place of Everywhere's per-HTTP-
//     session dict.
//   * Self-expand + core-tool gates — mirror
//     `Everywhere.Mcp.OpenCli.Observation.SelfExpandGate` and
//     `Everywhere.Mcp.CoreToolGate`. Env vars are renamed
//     `EVERYWHERE_MCP_*` -> `OPENCLICKY_MCP_*` with identical
//     semantics.
//   * Reflective `call_tool` + sequential `batch` — delegated to
//     `MetaToolDispatchDelegate` so the bridge can inject its wire-
//     level dispatcher without dragging HTTP or MCP protocol shapes
//     into the context service.
//
// The bridge (`cursor-buddy/OpenClickyExternalControlBridge.swift`)
// wraps the returned values into MCP envelopes; this module only
// produces `[MetaToolDescriptor]` / `[ScoredToolMatch]` / `[DomainInfo]`
// / `[BatchResult]` typed values.

import Foundation

// MARK: - Env-var gates

/// SPEC §2.5 self-expand kill switch. Mirrors
/// `SelfExpandGate.Enabled` (`OpenCli/Observation/SelfExpandGate.cs`).
/// Env-var default is "enabled"; only the literal string `"0"` opts
/// out. Reads the env-var on every access so tests that override with
/// `setenv` observe the change (parity with Everywhere).
public enum OpenClickyMetaSelfExpandGate {
    /// Environment-variable name. Everywhere uses
    /// `EVERYWHERE_MCP_SELFEXPAND`; openclicky renames it while
    /// preserving semantics.
    public static let envVar = "OPENCLICKY_MCP_SELFEXPAND"

    public static var isEnabled: Bool {
        return ProcessInfo.processInfo.environment[envVar] != "0"
    }
}

/// Mirrors `CoreToolGate.FilterEnabled`
/// (`src/Everywhere.Mcp/CoreToolGate.cs:75-78`). Setting
/// `OPENCLICKY_MCP_FULL=1` disables the core-tool gate so every
/// registered descriptor is treated as visible in `tools/list`.
public enum OpenClickyMetaCoreToolGate {
    public static let envVar = "OPENCLICKY_MCP_FULL"

    /// `true` when the gate is active (long-tail hidden).
    public static var filterEnabled: Bool {
        return ProcessInfo.processInfo.environment[envVar] != "1"
    }
}

// MARK: - Domain roster

/// Canonical openclicky domain roster. Corresponds conceptually to
/// Everywhere's `TierGate.Domains` (`Meta/TierGate.cs:13-55`) but is
/// aligned to the openclicky sensor surface documented in
/// `docs/ROADMAP/03_LAYER_2_MCP_SENSOR.md`.
///
/// `core` is the "always active" search-tier domain — its tools appear
/// in the default `tools/list` regardless of activation state
/// (parallel to Everywhere's `SearchTierTools`).
public enum OpenClickyMetaDomain {
    public static let core = "core"
    public static let browser = "browser"
    public static let terminal = "terminal"
    public static let finder = "finder"
    public static let whiteboard = "whiteboard"
    public static let docReaders = "doc_readers"
    public static let web = "web"
    public static let memory = "memory"
    public static let orchestrate = "orchestrate"
    /// F32 chat_bus — pub/sub side-channel MCP surface. Hidden by
    /// default; activated via `activate_domain name=chat`.
    public static let chat = "chat"
    /// Screen History (embedded OpenRewind) — historical OCR search
    /// + timeline + aiContext + daily recap. Hidden until
    /// `activate_domain name=screen_history` fires.
    public static let screenHistory = "screen_history"

    /// All domains in stable enumeration order.
    public static let all: [String] = [
        core, browser, terminal, finder, whiteboard,
        docReaders, web, memory, orchestrate, chat, screenHistory,
    ]
}

// MARK: - BM25 index

/// Minimal, stdlib-only BM25 index over tool `(name, description)`
/// pairs. Ported from `Everywhere.Mcp.Meta.Bm25Index`
/// (`Meta/Bm25Index.cs`).
///
/// Parameters match Everywhere exactly:
///   * `k1 = 1.5`, `b = 0.75`.
///   * IDF = `log(1 + (N - df + 0.5) / (df + 0.5))`.
///   * Tokenizer: lowercase then split on any non-alphanumeric run.
///     No stemming, no stop-words.
public struct OpenClickyBM25Index: Sendable {
    private static let k1: Double = 1.5
    private static let b: Double = 0.75

    private struct Doc: Sendable {
        let name: String
        let description: String
        let domain: String
        let length: Int
    }

    private var docs: [Doc] = []
    /// Name -> docIndex, so duplicate `add` calls replace the existing
    /// Doc entry in place instead of appending a second row (which
    /// would inflate `N` and skew IDF / avg_doc_len).
    private var indexByName: [String: Int] = [:]
    /// term -> [docIndex: term-frequency]
    private var postings: [String: [Int: Int]] = [:]
    private var averageLength: Double = 0

    public init() {}

    /// Adds a descriptor to the index. Re-adding a tool with the same
    /// `name` REPLACES the existing entry in place — we track a
    /// `name -> index` map so the total document count stays correct
    /// after re-registration (parity with Everywhere's
    /// `SearchTools.BuildIndex`, which de-dupes upstream via a
    /// `HashSet<string>` before pushing into `Bm25Index`).
    public mutating func add(_ descriptor: MetaToolDescriptor) {
        let tokens = Self.tokenize(descriptor.name + " " + descriptor.description)
        let newDoc = Doc(
            name: descriptor.name,
            description: descriptor.description,
            domain: descriptor.domain,
            length: tokens.count
        )
        let idx: Int
        if let existing = indexByName[descriptor.name] {
            // Strip old postings for this doc, then replace.
            for (term, docFreqs) in postings {
                if docFreqs[existing] != nil {
                    var updated = docFreqs
                    updated.removeValue(forKey: existing)
                    postings[term] = updated.isEmpty ? nil : updated
                }
            }
            docs[existing] = newDoc
            idx = existing
        } else {
            idx = docs.count
            docs.append(newDoc)
            indexByName[descriptor.name] = idx
        }
        for token in tokens {
            postings[token, default: [:]][idx, default: 0] += 1
        }
        // Rolling average over `docs.count`. Empty index averages to 0.
        var total = 0
        for doc in docs { total += doc.length }
        averageLength = docs.isEmpty ? 0 : Double(total) / Double(docs.count)
    }

    /// Number of unique documents currently in the index. Used by
    /// tests to prove that a duplicate `add` did not inflate `N`.
    public var documentCount: Int { docs.count }

    /// Scores every document against `query` and returns the top
    /// `topK` results ordered by score descending. Zero-scoring docs
    /// are excluded (Everywhere parity — only docs with at least one
    /// query-term posting contribute to the `scores` dict).
    public func search(_ query: String, topK: Int = 5) -> [ScoredToolMatch] {
        if docs.isEmpty { return [] }
        let tokens = Self.tokenize(query)
        var scores: [Int: Double] = [:]
        for token in tokens {
            guard let posting = postings[token] else { continue }
            let df = Double(posting.count)
            let n = Double(docs.count)
            let idf = log(1.0 + (n - df + 0.5) / (df + 0.5))
            for (docIdx, tf) in posting {
                let len = Double(docs[docIdx].length)
                let avg = max(1.0, averageLength)
                let norm = 1 - Self.b + Self.b * (len / avg)
                let tfDouble = Double(tf)
                let contribution = idf * ((tfDouble * (Self.k1 + 1)) / (tfDouble + Self.k1 * norm))
                scores[docIdx, default: 0] += contribution
            }
        }
        let ranked = scores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            // Deterministic tie-break: stable by insertion order.
            return lhs.key < rhs.key
        }
        return ranked.prefix(topK).map { entry in
            let doc = docs[entry.key]
            return ScoredToolMatch(
                name: doc.name,
                description: doc.description,
                score: entry.value,
                domain: doc.domain
            )
        }
    }

    /// Public for tests. Everywhere's tokenizer:
    ///   `foreach c in s.ToLowerInvariant(): if IsLetterOrDigit(c) append else flush`.
    /// Swift's `isLetter || isNumber` matches C#'s `char.IsLetterOrDigit`
    /// for the ASCII + BMP range used by tool names / descriptions.
    public static func tokenize(_ input: String) -> [String] {
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

// MARK: - Dispatch delegate

/// Bridge-facing dispatch protocol. Everywhere `MetaTools.CallTool`
/// resolves the target by:
///   * OpenDia (`browser_*`) -> `OpenDiaBridge.CallToolAsync`.
///   * Native -> `NativeToolDispatcher.InvokeAsync` (reflection).
/// Openclicky's context service does not know about the MCP bridge,
/// so we push both concerns behind this protocol. The bridge is the
/// single conformer in production; tests use a mock.
public protocol MetaToolDispatchDelegate: AnyObject, Sendable {
    /// Invoke `name` with the JSON-encoded `argumentsJson` (`nil` for
    /// no-arg tools). Return the tool's raw JSON reply as a string.
    /// Throw on transport errors — the wrapper converts thrown errors
    /// into an error envelope on the batch path.
    func dispatch(name: String, argumentsJson: String?) async throws -> String
}

// MARK: - Mutation-verb regex

/// SPEC §2.6 / Phase 4 G7 word-boundary regex. Mirrors Everywhere
/// `GateTools.cs:47` and `MutationGuard.cs:16-18` — `\b(POST|PUT|
/// DELETE|PATCH)\b` (case-sensitive; evidence upper-cases first).
/// Kept as a file-level constant so we compile the regex once.
private let openClickyMetaMutationVerbRegex: NSRegularExpression = {
    // `try!` is safe: literal pattern, no runtime input.
    return try! NSRegularExpression(
        pattern: "\\b(POST|PUT|DELETE|PATCH)\\b",
        options: []
    )
}()

// MARK: - Registry

/// Registry + query surface for the meta tools. One instance per
/// bridge. Thread-safety: all mutating methods take a `nonmutating`
/// reference to an internal `NSLock`-guarded core so a single
/// `OpenClickyMetaToolRegistry` value can be captured by concurrent
/// tasks. Everywhere's SearchTools is likewise process-wide.
public final class OpenClickyMetaToolRegistry: @unchecked Sendable {
    /// UserDefaults key under which the activated-domain set is
    /// persisted across launches. Everywhere keeps this per-HTTP-
    /// session in `SessionActivations`; openclicky is single-session
    /// per process so we persist to `UserDefaults` (test suites pass
    /// a suite-scoped instance).
    public static let activatedDomainsDefaultsKey = "openclicky.meta.activatedDomains"

    private let lock = NSLock()
    private var descriptors: [String: MetaToolDescriptor] = [:]
    private var order: [String] = []
    private var index = OpenClickyBM25Index()
    private let defaults: UserDefaults
    private weak var dispatchDelegate: MetaToolDispatchDelegate?

    public init(userDefaults: UserDefaults = .standard, dispatchDelegate: MetaToolDispatchDelegate? = nil) {
        self.defaults = userDefaults
        self.dispatchDelegate = dispatchDelegate
    }

    /// Attach or swap the dispatch delegate. Weakly held.
    public func setDispatchDelegate(_ delegate: MetaToolDispatchDelegate?) {
        lock.lock(); defer { lock.unlock() }
        self.dispatchDelegate = delegate
    }

    /// Registers or overwrites one descriptor. Duplicate names replace
    /// the prior entry in-place (Everywhere de-dupes at index-build
    /// time via a `HashSet<string>`).
    public func register(_ descriptor: MetaToolDescriptor) {
        lock.lock(); defer { lock.unlock() }
        if descriptors[descriptor.name] == nil {
            order.append(descriptor.name)
        }
        descriptors[descriptor.name] = descriptor
        index.add(descriptor)
    }

    /// Bulk register — convenience for bootstrap.
    public func register(_ items: [MetaToolDescriptor]) {
        for item in items { register(item) }
    }

    /// Snapshot of all registered descriptors in registration order.
    public func allDescriptors() -> [MetaToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { descriptors[$0] }
    }

    /// SPEC §Phase 6 `list_more_tools(category?)`.
    /// * When `OPENCLICKY_MCP_FULL=1`, every registered descriptor is
    ///   returned regardless of `isHidden` — this matches
    ///   `CoreToolGate.FilterEnabled == false`.
    /// * Otherwise, only `isHidden == true` descriptors are returned
    ///   (the whole point of `list_more_tools` is to surface the
    ///   long-tail).
    /// * `category`, when non-nil, filters by matching the
    ///   descriptor's `domain`. Unknown categories yield `[]`.
    public func listMoreTools(category: String? = nil) -> [MetaToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        let gateOn = OpenClickyMetaCoreToolGate.filterEnabled
        return order.compactMap { name in
            guard let desc = descriptors[name] else { return nil }
            if gateOn && !desc.isHidden { return nil }
            if let cat = category, desc.domain != cat { return nil }
            return desc
        }
    }

    /// SPEC §Phase 6 `search_tools`. BM25 over the full index (gated
    /// tools are searchable — the whole point of the meta surface is
    /// to reach hidden tools).
    public func searchTools(query: String, topK: Int = 5) -> [ScoredToolMatch] {
        lock.lock(); defer { lock.unlock() }
        return index.search(query, topK: topK)
    }

    /// Test-only snapshot of BM25 `N` (unique documents in the index).
    /// Kept `internal` — used by
    /// `test_bm25_duplicate_register_does_not_inflate_N` to prove that
    /// re-registering a tool with the same name leaves `N` unchanged.
    internal var bm25DocumentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index.documentCount
    }

    /// SPEC §Phase 6 `activate_domain`. Returns `true` iff the domain
    /// is recognised (in `OpenClickyMetaDomain.all`). `core` is
    /// implicitly active; activating it is a no-op success.
    @discardableResult
    public func activateDomain(_ name: String) -> Bool {
        guard OpenClickyMetaDomain.all.contains(name) else { return false }
        lock.lock(); defer { lock.unlock() }
        var active = loadActivatedDomainsUnlocked()
        active.insert(name)
        persistActivatedDomainsUnlocked(active)
        return true
    }

    /// Snapshot of the current activation state. `core` is always
    /// included even when the persisted set is empty (parity with
    /// Everywhere's "search tier is always visible").
    public func activatedDomains() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var set = loadActivatedDomainsUnlocked()
        set.insert(OpenClickyMetaDomain.core)
        return set
    }

    /// SPEC §Phase 6 `list_domains`. `tool_count` reflects the number
    /// of *registered* descriptors filed under each domain (not the
    /// theoretical roster) — this mirrors Everywhere's
    /// `Domains.Values.SelectMany(s => s).Count` shape.
    public func listDomains() -> [DomainInfo] {
        lock.lock(); defer { lock.unlock() }
        let active = activatedDomainsSetUnlocked()
        var counts: [String: Int] = [:]
        for name in order {
            guard let desc = descriptors[name] else { continue }
            counts[desc.domain, default: 0] += 1
        }
        return OpenClickyMetaDomain.all.map { domain in
            DomainInfo(
                name: domain,
                toolCount: counts[domain] ?? 0,
                isActive: active.contains(domain)
            )
        }
    }

    /// Reset all activations. Test helper; production code has no use
    /// for this (Everywhere `SessionActivations.ResetForDisconnect`
    /// runs on transport disconnect).
    public func resetActivatedDomains() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.activatedDomainsDefaultsKey)
    }

    // MARK: Dispatch

    /// SPEC §MetaTools.CallTool — invoke any registered tool by name.
    /// The wrapper only validates the name is registered; actual
    /// dispatch is delegated to `MetaToolDispatchDelegate`.
    ///
    /// Errors:
    ///   * Unknown tool -> `MetaToolError.unknownTool`.
    ///   * No delegate wired -> `MetaToolError.noDispatchDelegate`.
    ///   * Delegate throws -> re-thrown as `MetaToolError.dispatchFailed`.
    public func callTool(name: String, argumentsJson: String? = nil) async throws -> String {
        let delegate: MetaToolDispatchDelegate?
        let known: Bool
        lock.lock()
        delegate = dispatchDelegate
        known = descriptors[name] != nil
        lock.unlock()

        guard known else { throw MetaToolError.unknownTool(name) }
        guard let delegate else { throw MetaToolError.noDispatchDelegate }
        do {
            return try await delegate.dispatch(name: name, argumentsJson: argumentsJson)
        } catch let err as MetaToolError {
            throw err
        } catch {
            throw MetaToolError.dispatchFailed(name: name, underlying: error.localizedDescription)
        }
    }

    /// SPEC §3.3 `batch`. Sequential; **stops on first error** (parity
    /// with `BatchTool.Batch` — `stopAt`/`err` short-circuit).
    /// The failing step is included in the returned array with
    /// `ok == false`; subsequent steps are omitted.
    public func batch(_ steps: [BatchStep]) async -> [BatchResult] {
        var results: [BatchResult] = []
        results.reserveCapacity(steps.count)
        for step in steps {
            do {
                let raw = try await callTool(name: step.tool, argumentsJson: step.argumentsJson)
                results.append(BatchResult(tool: step.tool, ok: true, resultJson: raw, errorMessage: nil))
            } catch {
                let message: String
                switch error {
                case MetaToolError.unknownTool(let n):
                    message = "unknown tool: \(n)"
                case MetaToolError.noDispatchDelegate:
                    message = "dispatch delegate not configured"
                case MetaToolError.dispatchFailed(let n, let underlying):
                    message = "dispatch failed for \(n): \(underlying)"
                default:
                    message = String(describing: error)
                }
                results.append(BatchResult(tool: step.tool, ok: false, resultJson: nil, errorMessage: message))
                return results
            }
        }
        return results
    }

    // MARK: Strategy notes

    /// SPEC §Phase 4 `strategy_note_write`. Validates completeness
    /// (Evidence>=3*>=20 chars, Replay>=50 chars, enum values) plus
    /// the SPEC §2.6 mutation-verb guard (G7): evidence naming
    /// POST/PUT/DELETE/PATCH without `mutation:true` is rejected.
    /// Persistence itself is the caller's responsibility — this
    /// method returns the validated note so the caller can persist it
    /// under its chosen key scheme.
    public func validateStrategyNote(
        _ note: StrategyNote
    ) throws {
        guard OpenClickyMetaSelfExpandGate.isEnabled else {
            throw MetaToolError.selfExpandDisabled
        }
        var missing: [String] = []
        if !note.isComplete(missing: &missing) {
            throw MetaToolError.strategyNoteIncomplete(missing)
        }
        // SPEC §2.6 / Phase 4 G7 — evidence naming a mutating verb
        // requires mutation:true. Uses a word-boundary regex to match
        // Everywhere `GateTools.cs:47` — the earlier substring form
        // false-triggered on "POSTAL", "OUTPUT", "PATCHY", etc.
        if !note.mutation {
            let hasMutationVerb = note.evidence.contains { evidenceLine in
                let upper = evidenceLine.uppercased()
                let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
                return openClickyMetaMutationVerbRegex.firstMatch(
                    in: upper, options: [], range: range
                ) != nil
            }
            if hasMutationVerb {
                throw MetaToolError.mutationUnapproved
            }
        }
    }

    // MARK: - Private

    private func loadActivatedDomainsUnlocked() -> Set<String> {
        guard let raw = defaults.string(forKey: Self.activatedDomainsDefaultsKey),
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(arr)
    }

    private func activatedDomainsSetUnlocked() -> Set<String> {
        var set = loadActivatedDomainsUnlocked()
        set.insert(OpenClickyMetaDomain.core)
        return set
    }

    private func persistActivatedDomainsUnlocked(_ set: Set<String>) {
        let sorted = set.sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let str = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: Self.activatedDomainsDefaultsKey)
    }
}

// MARK: - Errors

/// Structured error surface mirroring the Everywhere error envelopes:
///   * `SELFEXPAND_DISABLED` (`SelfExpandGate.Enabled == false`).
///   * `STRATEGY_NOTE_INCOMPLETE` (`StrategyNote.IsComplete == false`).
///   * `MUTATION_UNAPPROVED` (G7).
///   * `META_TOOL_ERROR` covers unknown-tool + dispatch failure.
public enum MetaToolError: Error, Equatable, Sendable {
    case selfExpandDisabled
    case unknownTool(String)
    case noDispatchDelegate
    case dispatchFailed(name: String, underlying: String)
    case strategyNoteIncomplete([String])
    case mutationUnapproved

    /// Machine-readable code matching Everywhere's error envelopes.
    public var code: String {
        switch self {
        case .selfExpandDisabled: return "SELFEXPAND_DISABLED"
        case .unknownTool: return "UNKNOWN_TOOL"
        case .noDispatchDelegate: return "META_TOOL_ERROR"
        case .dispatchFailed: return "META_TOOL_ERROR"
        case .strategyNoteIncomplete: return "STRATEGY_NOTE_INCOMPLETE"
        case .mutationUnapproved: return "MUTATION_UNAPPROVED"
        }
    }
}
