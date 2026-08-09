//
//  MirageBodyPipeline.swift
//  cursor-buddy
//
//  Swift port of CPA `internal/runtime/executor/claude_executor.go` body
//  normalization stack, restricted to the mirage-relevant subset. Same
//  input → same wire output as CPA, so a request that flows through
//  OpenClicky's Mirage transport and one that flows through CPA's mirage
//  auth-style produce byte-identical bodies (modulo JSON key ordering,
//  which HTTP/2 servers do not observe).
//
//  Reference: docs/mirage-cpa-callflow-spec.md §2.2 (22-step body pipeline).
//  Each function is annotated with the CPA source line so a diff against
//  future CPA revisions is straightforward.
//
//  Not ported (see spec §6 P2 column for rationale):
//   * `injectOpenRouterProvider` — mirage upstream is Anthropic, not
//     OpenRouter.
//   * `injectFakeUserID` / cloaking — mirage is anonymous by definition,
//     the whole rotating-UUID design already provides identity opacity.
//   * `prepareClaudeOAuthToolNamesForUpstream` — no OAuth path.
//   * CCH signing — same, OAuth-only.
//   * `context_management` stripping is auto-triggered because mirage's
//     base URL is not `anthropic.com` and CPA already handles that; we
//     replicate the behaviour here (`stripContextManagement`).

import Foundation

/// Grouped body helpers. Every function takes the parsed JSON dict and
/// mutates it in place — matches CPA's stateless-transform composition
/// where a sequence of `body = fnN(body)` calls chain through the whole
/// pipeline. Compose all of them in `apply(_:)` for the full sequence.
enum MirageBodyPipeline {

    /// Run the full pipeline against a parsed JSON dict. Order matches CPA
    /// `Execute` / `ExecuteStream` line 359-424:
    ///   1. `disableThinkingIfToolChoiceForced` (before sampling normalise)
    ///   2. `normalizeThinkingForAdaptiveModels` (Opus 4.7 up-convert)
    ///   3. `normalizeClaudeSamplingForUpstream`
    ///   4. `stripContextManagement` (mirage base URL is non-Anthropic)
    ///   5. `ensureClaudeThinkingDisplay`
    ///   6. Cache control auto-injection + limit enforcement
    ///   7. `extractAndRemoveBetas` — returns collected betas separately
    ///      so the caller can lift them to the anthropic-beta header
    ///
    /// - Parameters:
    ///   - body: the request JSON dict (from `[String: Any]`).
    ///   - model: the resolved model id (bare, e.g. `claude-fable-5`)
    ///     needed for the Opus 4.7 up-conversion branch.
    /// - Returns: extracted beta strings the caller should merge into the
    ///   `anthropic-beta` header. Empty when the body carried no `betas`.
    @discardableResult
    static func apply(_ body: inout [String: Any], model: String) -> [String] {
        // Cache-safety detection: if the caller already wrote at least
        // one `cache_control` block, they are opting into Anthropic's
        // prompt cache and any body mutation risks changing the hash
        // that aegis / Anthropic computes over the cacheable prefix.
        // In that mode we run ONLY the beta extraction and the hard
        // 4-block cap — nothing that touches content bytes.
        //
        // See CPA `docs/mirage-cache-issue.md` (commit fff1d154): body
        // mutators are the entire reason "same body direct to aegis
        // hits cache, through CPA misses 100%". Client-side we
        // reproduce the exact byte layout Claude Code CLI (or a direct
        // API caller) prepared, and only lift the beta headers the
        // wire layer needs.
        // `stripContextManagement` is safe in both modes: the key lives
        // at top level of the request, not inside any cacheable block,
        // so removing it never shifts a cache-hash prefix. And upstream
        // requires it removed (aegis-proxy 400s if left in).
        //
        // TODO(cache-hash-verify): Anthropic docs do not explicitly
        // state that top-level metadata is excluded from the cache
        // hash — the current guarantee comes from empirical testing
        // (docs/mirage-cache-issue.md verified cache still hits with
        // this stripped). If Anthropic ever tightens the hash scope,
        // switch to leaving `context_management` in place and rely on
        // aegis-proxy to strip it upstream (aegis already does — the
        // 400 was pre-2026-08 behaviour, may already be relaxed).
        stripContextManagement(&body)

        // `normalizeSampling` only removes top-level `temperature` /
        // `top_p` / `top_k` — same-tier as `context_management`, does
        // not shift cache-prefix hash. Safe in cache-prepped mode too.
        // Aegis-proxy rejects these fields when thinking is active, so
        // removing them unconditionally is required, not optional.
        normalizeSampling(&body)

        let cachePrepped = countCacheControls(body) > 0
        if !cachePrepped {
            // Thinking-related mutators change body bytes in places
            // that CAN affect cache hash (e.g. `thinking.type` on
            // Opus-4.7 up-convert). Only run when the client did not
            // opt into caching.
            disableThinkingIfToolChoiceForced(&body)
            normalizeThinkingForAdaptiveModels(&body, model: model)
            ensureThinkingDisplay(&body)
        }
        // Anthropic hard-caps `cache_control` breakpoints at 4 — a 5th
        // returns 400. Two policies depending on mode:
        //   * non-cache-prepped: pipeline may have written extra
        //     breakpoints itself, so silently reap down to 4.
        //   * cache-prepped: the CLI wrote them; silently dropping the
        //     early ones would shift the cache prefix hash and turn a
        //     hit into a miss. Instead we log and let the request go
        //     through — upstream 400 is the correct fail-fast signal
        //     that the client is misbehaving, and no cache was going
        //     to work anyway.
        if cachePrepped {
            let cc = countCacheControls(body)
            if cc > 4 {
                NSLog("[MiragePipeline] cache-prepped body has %d cache_control blocks (>4). Upstream will 400. Trim client-side.", cc)
            }
        } else {
            enforceCacheControlLimit(&body, maxBlocks: 4)
        }
        var betas = extractAndRemoveBetas(&body)
        // If any cache_control block carries a ttl (Claude CLI adds
        // `"ttl": "1h"` when ENABLE_PROMPT_CACHING_1H=true), lift the
        // 1-hour cache beta header so Anthropic actually honors the ttl.
        // Without this header, upstream silently downgrades to the 5-minute
        // tier and the CLI wonders why hits never land.
        if bodyRequestsExtendedCacheTTL(body),
           !betas.contains("extended-cache-ttl-2025-04-11") {
            betas.append("extended-cache-ttl-2025-04-11")
        }
        return betas
    }

    /// Scan every `cache_control` in the body for a non-nil `ttl` field.
    /// Anthropic recognises `"5m"` (default) and `"1h"` — anything with
    /// an explicit ttl needs the extended-cache-ttl beta header, so we
    /// return true for any non-empty ttl string.
    static func bodyRequestsExtendedCacheTTL(_ body: [String: Any]) -> Bool {
        func hasTTL(_ blocks: [[String: Any]]) -> Bool {
            for b in blocks {
                if let cc = b["cache_control"] as? [String: Any],
                   let ttl = cc["ttl"] as? String,
                   !ttl.isEmpty { return true }
            }
            return false
        }
        if let system = body["system"] as? [[String: Any]], hasTTL(system) { return true }
        if let tools = body["tools"] as? [[String: Any]], hasTTL(tools) { return true }
        if let messages = body["messages"] as? [[String: Any]] {
            for msg in messages {
                if let content = msg["content"] as? [[String: Any]], hasTTL(content) { return true }
            }
        }
        return false
    }

    // MARK: - Thinking + sampling

    /// CPA `claude_executor.go:1406`. When `tool_choice.type` forces tool
    /// use (values `any` / `tool`), Anthropic rejects requests that also
    /// carry a `thinking` block. Strip both `thinking` and any
    /// `output_config.effort` so the request goes through cleanly.
    static func disableThinkingIfToolChoiceForced(_ body: inout [String: Any]) {
        guard let tc = body["tool_choice"] as? [String: Any],
              let type = tc["type"] as? String,
              type == "any" || type == "tool" else { return }
        body.removeValue(forKey: "thinking")
        if var oc = body["output_config"] as? [String: Any] {
            oc.removeValue(forKey: "effort")
            if oc.isEmpty {
                body.removeValue(forKey: "output_config")
            } else {
                body["output_config"] = oc
            }
        }
    }

    /// CPA `claude_executor.go:1425`. Opus 4.7 (adaptive-only) rejects
    /// `thinking.type=enabled` + `budget_tokens`; we up-convert to
    /// `adaptive` + mapped `effort`. Delegates the mapping to
    /// `MirageThinkingSuffix.effortForBudget` for a single source of truth.
    static func normalizeThinkingForAdaptiveModels(_ body: inout [String: Any], model: String) {
        guard model.contains("opus-4-7") else { return }
        guard var thinking = body["thinking"] as? [String: Any],
              (thinking["type"] as? String)?.lowercased() == "enabled" else { return }
        let budget = (thinking["budget_tokens"] as? Int)
            ?? Int((thinking["budget_tokens"] as? Double) ?? 0)
        thinking["type"] = "adaptive"
        thinking.removeValue(forKey: "budget_tokens")
        body["thinking"] = thinking
        var oc = (body["output_config"] as? [String: Any]) ?? [:]
        oc["effort"] = MirageThinkingSuffix.effortForBudget(budget).rawValue
        body["output_config"] = oc
    }

    /// CPA `claude_executor.go:1475`. Anthropic refuses `top_p` /
    /// `top_k` while thinking is active. Also unconditionally drops
    /// `temperature` because CPA does (empirically some upstreams 400 on
    /// non-default temperatures when thinking is on).
    static func normalizeSampling(_ body: inout [String: Any]) {
        body.removeValue(forKey: "temperature")
        body.removeValue(forKey: "top_p")
        if let thinkingType = (body["thinking"] as? [String: Any])?["type"] as? String {
            switch thinkingType.lowercased() {
            case "enabled", "adaptive", "auto":
                body.removeValue(forKey: "top_p")
                body.removeValue(forKey: "top_k")
            default:
                break
            }
        }
    }

    /// CPA `claude_executor.go:369-371` (called only when base URL is
    /// non-Anthropic). Third-party relays 400 on the Claude-Code-specific
    /// `context_management` compaction hint. Mirage always talks to
    /// aegis-proxy → api.anthropic.com under someone else's key, so the
    /// hint would arrive without the caller's user id present in the
    /// relay-injected auth — safest to strip so no request ever surfaces
    /// the caller-specific `context_management` payload upstream.
    static func stripContextManagement(_ body: inout [String: Any]) {
        body.removeValue(forKey: "context_management")
    }

    /// CPA `claude_executor.go:1492`. When thinking is active and the
    /// caller did not set `thinking.display`, default it to `summarized`
    /// so upstreams with redact-thinking enabled return non-empty
    /// thinking text.
    static func ensureThinkingDisplay(_ body: inout [String: Any]) {
        guard var thinking = body["thinking"] as? [String: Any],
              let type = thinking["type"] as? String else { return }
        switch type.lowercased() {
        case "enabled", "adaptive", "auto":
            break
        default:
            return
        }
        if let existing = thinking["display"] as? String,
           !existing.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        thinking["display"] = "summarized"
        body["thinking"] = thinking
    }

    // MARK: - Cache control

    /// CPA `claude_executor.go:2881`. Auto-injects `cache_control` into
    /// (a) the last non-deferred tool, (b) the last system element,
    /// (c) the second-to-last user message. Only fires when no
    /// cache_control exists in the whole payload — respects a caller
    /// that already decided where to break.
    static func ensureCacheControl(_ body: inout [String: Any]) {
        if countCacheControls(body) > 0 { return }
        injectToolsCacheControl(&body)
        injectSystemCacheControl(&body)
        injectMessagesCacheControl(&body)
    }

    /// CPA `claude_executor.go:2897`.
    static func countCacheControls(_ body: [String: Any]) -> Int {
        var count = 0
        if let system = body["system"] as? [[String: Any]] {
            for item in system where item["cache_control"] != nil { count += 1 }
        }
        if let tools = body["tools"] as? [[String: Any]] {
            for tool in tools where tool["cache_control"] != nil { count += 1 }
        }
        if let messages = body["messages"] as? [[String: Any]] {
            for msg in messages {
                if let content = msg["content"] as? [[String: Any]] {
                    for item in content where item["cache_control"] != nil { count += 1 }
                }
            }
        }
        return count
    }

    /// CPA `claude_executor.go:3041`. Anthropic caps at 4 cache_control
    /// blocks per request. If exceeded, drop from system first (matches
    /// CPA's precedence — keep the last system block + the tool + message
    /// blocks). We drop earlier system blocks, then tools, keeping the
    /// tail intact.
    static func enforceCacheControlLimit(_ body: inout [String: Any], maxBlocks: Int) {
        let total = countCacheControls(body)
        if total <= maxBlocks { return }
        var excess = total - maxBlocks

        // Drop from system (excluding the last one).
        if var system = body["system"] as? [[String: Any]], excess > 0 {
            var lastIdx = -1
            for (i, item) in system.enumerated() where item["cache_control"] != nil {
                lastIdx = i
            }
            for i in 0..<system.count where excess > 0 && i != lastIdx {
                if system[i]["cache_control"] != nil {
                    system[i].removeValue(forKey: "cache_control")
                    excess -= 1
                }
            }
            body["system"] = system
        }
        if excess <= 0 { return }

        // Drop from tools (excluding the last one).
        if var tools = body["tools"] as? [[String: Any]] {
            var lastIdx = -1
            for (i, tool) in tools.enumerated() where tool["cache_control"] != nil {
                lastIdx = i
            }
            for i in 0..<tools.count where excess > 0 && i != lastIdx {
                if tools[i]["cache_control"] != nil {
                    tools[i].removeValue(forKey: "cache_control")
                    excess -= 1
                }
            }
            body["tools"] = tools
        }
    }

    /// CPA `claude_executor.go:3294`. Add cache_control to the last
    /// non-deferred tool if no tool has one yet.
    static func injectToolsCacheControl(_ body: inout [String: Any]) {
        guard var tools = body["tools"] as? [[String: Any]], !tools.isEmpty else { return }
        for tool in tools where tool["cache_control"] != nil { return }
        var lastEligible = -1
        for (i, tool) in tools.enumerated() {
            let deferred = (tool["defer_loading"] as? Bool) ?? false
            if !deferred { lastEligible = i }
        }
        guard lastEligible >= 0 else { return }
        tools[lastEligible]["cache_control"] = ["type": "ephemeral"]
        body["tools"] = tools
    }

    /// CPA `claude_executor.go:3330`. Add cache_control to the last
    /// system element; convert string-form system prompts into the array
    /// form so a cache_control can be attached.
    static func injectSystemCacheControl(_ body: inout [String: Any]) {
        if var system = body["system"] as? [[String: Any]], !system.isEmpty {
            for item in system where item["cache_control"] != nil { return }
            let lastIdx = system.count - 1
            system[lastIdx]["cache_control"] = ["type": "ephemeral"]
            body["system"] = system
            return
        }
        if let systemStr = body["system"] as? String, !systemStr.isEmpty {
            body["system"] = [
                [
                    "type": "text",
                    "text": systemStr,
                    "cache_control": ["type": "ephemeral"]
                ] as [String: Any]
            ]
        }
    }

    /// CPA `claude_executor.go:3210`. Cache the second-to-last user
    /// message so multi-turn history is reused. Needs ≥ 2 user turns.
    static func injectMessagesCacheControl(_ body: inout [String: Any]) {
        guard var messages = body["messages"] as? [[String: Any]] else { return }
        // Scan existing cache_control.
        for msg in messages {
            if let content = msg["content"] as? [[String: Any]] {
                for item in content where item["cache_control"] != nil { return }
            }
        }
        var userIndices: [Int] = []
        for (i, msg) in messages.enumerated() {
            if (msg["role"] as? String) == "user" {
                userIndices.append(i)
            }
        }
        guard userIndices.count >= 2 else { return }
        let target = userIndices[userIndices.count - 2]

        if var content = messages[target]["content"] as? [[String: Any]], !content.isEmpty {
            let lastIdx = content.count - 1
            content[lastIdx]["cache_control"] = ["type": "ephemeral"]
            messages[target]["content"] = content
            body["messages"] = messages
        } else if let contentStr = messages[target]["content"] as? String {
            messages[target]["content"] = [
                [
                    "type": "text",
                    "text": contentStr,
                    "cache_control": ["type": "ephemeral"]
                ] as [String: Any]
            ]
            body["messages"] = messages
        }
    }

    // MARK: - Beta extraction

    /// CPA `claude_executor.go:1314`. Pulls a `betas` field out of the
    /// body (array or single string), returns the collected strings, and
    /// removes the field so the outbound Anthropic request doesn't carry
    /// it. The caller lifts these into the `anthropic-beta` header.
    static func extractAndRemoveBetas(_ body: inout [String: Any]) -> [String] {
        guard let raw = body.removeValue(forKey: "betas") else { return [] }
        if let arr = raw as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let arr = raw as? [Any] {
            return arr.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let single = raw as? String {
            let s = single.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? [] : [s]
        }
        return []
    }
}
