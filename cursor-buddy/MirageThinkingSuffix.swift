//
//  MirageThinkingSuffix.swift
//  cursor-buddy
//
//  Client-side port of the CPA `internal/thinking` pipeline, restricted to
//  what mirage-routed Claude 4+ models actually accept. Purpose: give
//  callers the same suffix ergonomics they get through CPA — `mirage/
//  claude-fable-5(max)`, `(xhigh)`, `(16384)` — while OpenClicky owns the
//  entire body-shape rewrite in-process.
//
//  Reference spec: docs/mirage-cpa-callflow-spec.md §2.4.
//
//  Behaviour matrix for adaptive-capable models (mirage's whole catalog is
//  Claude 4+, all adaptive):
//
//    Suffix       | thinking.type | thinking.budget_tokens | output_config.effort
//    -------------|---------------|------------------------|---------------------
//    (none)       | "disabled"    | (deleted)              | (deleted)
//    (auto)/(-1)  | "adaptive"    | (deleted)              | (deleted)
//    (minimal)    | "adaptive"    | (deleted)              | "minimal"
//    (low)…(max)  | "adaptive"    | (deleted)              | <level>
//    (N > 0)      | "enabled"     | N (clamped)            | (deleted)
//    (0)          | "disabled"    | (deleted)              | (deleted)
//    no suffix    | passthrough   | passthrough            | passthrough
//
//  For Opus 4.7 with a raw `thinking.type=enabled` + budget (no suffix,
//  caller sent the enabled shape directly), CPA also up-converts to
//  adaptive using the reverse table (docs §2.4). We port that too so
//  behaviour matches when the caller skips the suffix but sets thinking in
//  the body manually.

import Foundation

/// Level suffix identifiers, in the order upstream accepts them. Backed by
/// the string spelling because that is what lands in `output_config.effort`.
enum MirageThinkingLevel: String, CaseIterable {
    case minimal, low, medium, high, xhigh, max
}

/// Result of parsing a model id like `mirage/claude-fable-5(max)`.
struct MirageThinkingSuffix {
    /// Bare upstream model id — `claude-fable-5`.
    let modelName: String
    /// What kind of suffix was present. `.none` = raw model id with no `(…)`.
    let mode: Mode

    enum Mode: Equatable {
        /// No `(…)` in the id.
        case passthrough
        /// `(none)` or `(0)` — disable thinking entirely.
        case disabled
        /// `(auto)` or `(-1)` — enable adaptive with upstream defaults.
        case adaptiveAuto
        /// `(minimal/low/medium/high/xhigh/max)`.
        case adaptiveLevel(MirageThinkingLevel)
        /// `(N)` with `N > 0` — legacy enabled-mode with explicit budget.
        case budget(Int)
    }

    /// Parse `[namespace/]<model>[(SUFFIX)]`. `mirage/` and any other
    /// leading `<segment>/` are stripped since the transport layer already
    /// removed them, but we accept them here for robustness. Unknown suffix
    /// values (e.g. gibberish) fall back to `.passthrough`, matching CPA's
    /// `parseSuffixToConfig` (`internal/thinking/apply.go:406-437`).
    static func parse(_ modelID: String) -> MirageThinkingSuffix {
        // Strip any leading `foo/` namespace so `mirage/claude-fable-5(max)`
        // and `claude-fable-5(max)` produce identical results.
        var body = modelID
        if let slash = body.firstIndex(of: "/") {
            body = String(body[body.index(after: slash)...])
        }

        // Match trailing `(…)`. Everything up to the opening paren is the
        // bare model name.
        guard let paren = body.firstIndex(of: "("),
              body.hasSuffix(")") else {
            return MirageThinkingSuffix(modelName: body, mode: .passthrough)
        }
        let base = String(body[..<paren]).trimmingCharacters(in: .whitespaces)
        let rawInner = String(body[body.index(after: paren)..<body.index(before: body.endIndex)])
        let raw = rawInner.trimmingCharacters(in: .whitespaces).lowercased()

        // Special values first, matching CPA's ParseSpecialSuffix.
        switch raw {
        case "none":
            return MirageThinkingSuffix(modelName: base, mode: .disabled)
        case "auto", "-1":
            return MirageThinkingSuffix(modelName: base, mode: .adaptiveAuto)
        default:
            break
        }

        // Level suffix.
        if let level = MirageThinkingLevel(rawValue: raw) {
            return MirageThinkingSuffix(modelName: base, mode: .adaptiveLevel(level))
        }

        // Numeric budget.
        if let n = Int(raw) {
            if n <= 0 {
                return MirageThinkingSuffix(modelName: base, mode: .disabled)
            }
            return MirageThinkingSuffix(modelName: base, mode: .budget(n))
        }

        // Anything else: passthrough, but note the base id had the paren
        // stripped so the outbound request uses the clean model name.
        return MirageThinkingSuffix(modelName: base, mode: .passthrough)
    }

    /// Apply this suffix to a JSON body (parsed as `[String: Any]`). Mutates
    /// in place. Also strips sampling params when thinking is active
    /// (mirrors CPA `normalizeClaudeSamplingForUpstream`, P1 item in spec).
    ///
    /// - Parameter body: parsed JSON body dict. `model` field is rewritten to
    ///   the bare `modelName`.
    /// - Parameter clampMaxTokens: upper bound for `thinking.budget_tokens`
    ///   in budget mode. Passed through from `body["max_tokens"]` if the
    ///   caller supplied one. Nil = no clamp beyond the raw value.
    func apply(to body: inout [String: Any], clampMaxTokens: Int? = nil) {
        // Always rewrite model to the bare id so aegis-proxy sees a valid
        // upstream identifier.
        body["model"] = modelName

        switch mode {
        case .passthrough:
            // Body-level `thinking.type=enabled` + budget on adaptive Opus 4.7
            // gets up-converted; other adaptive models tolerate it as-is.
            upConvertOpus47IfNeeded(body: &body)
            return

        case .disabled:
            setThinking(&body, ["type": "disabled"])
            body.removeValue(forKey: "output_config")
            return

        case .adaptiveAuto:
            setThinking(&body, ["type": "adaptive"])
            // Drop any effort — upstream picks default.
            if var oc = body["output_config"] as? [String: Any] {
                oc.removeValue(forKey: "effort")
                if oc.isEmpty {
                    body.removeValue(forKey: "output_config")
                } else {
                    body["output_config"] = oc
                }
            }
            stripSamplingParams(&body)
            return

        case .adaptiveLevel(let level):
            setThinking(&body, ["type": "adaptive"])
            var oc = (body["output_config"] as? [String: Any]) ?? [:]
            oc["effort"] = level.rawValue
            body["output_config"] = oc
            stripSamplingParams(&body)
            return

        case .budget(let n):
            var budget = n
            // Clamp so `max_tokens > budget_tokens`. Upstream 400s otherwise.
            if let cap = clampMaxTokens, cap > 0 {
                let ceiling = cap - 1
                if budget > ceiling { budget = ceiling }
                if budget < 1 { budget = 1 }
            }
            setThinking(&body, ["type": "enabled", "budget_tokens": budget])
            // Legacy enabled mode: drop any output_config.effort so upstream
            // doesn't see conflicting signals.
            if var oc = body["output_config"] as? [String: Any] {
                oc.removeValue(forKey: "effort")
                if oc.isEmpty {
                    body.removeValue(forKey: "output_config")
                } else {
                    body["output_config"] = oc
                }
            }
            stripSamplingParams(&body)
            return
        }
    }

    /// Serialize a JSON body dict back to `Data`. Convenience wrapper the
    /// call sites use so they don't need to import `JSONSerialization`.
    static func encode(_ body: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: body, options: [])
    }

    // MARK: - Helpers

    private func setThinking(_ body: inout [String: Any], _ value: [String: Any]) {
        body["thinking"] = value
    }

    /// Match CPA `normalizeClaudeSamplingForUpstream` (P1 in spec): when
    /// thinking is active, strip temperature / top_p / top_k so Anthropic
    /// doesn't 400 with "sampling params incompatible with extended
    /// thinking".
    private func stripSamplingParams(_ body: inout [String: Any]) {
        body.removeValue(forKey: "temperature")
        body.removeValue(forKey: "top_p")
        body.removeValue(forKey: "top_k")
    }

    /// Reverse-lookup helper matching CPA
    /// `normalizeThinkingForAdaptiveModels` (`claude_executor.go:1425-1462`).
    /// Only Opus 4.7 needs this today — other adaptive-capable models
    /// accept `thinking.type=enabled` directly. When the caller sent an
    /// `enabled` shape on Opus 4.7 without going through the suffix parser,
    /// convert to adaptive + mapped effort so the request doesn't fall into
    /// legacy quality tier.
    private func upConvertOpus47IfNeeded(body: inout [String: Any]) {
        guard modelName.contains("opus-4-7") else { return }
        guard var thinking = body["thinking"] as? [String: Any],
              (thinking["type"] as? String)?.lowercased() == "enabled" else { return }
        let budget = (thinking["budget_tokens"] as? Int)
            ?? Int((thinking["budget_tokens"] as? Double) ?? 0)
        thinking["type"] = "adaptive"
        thinking.removeValue(forKey: "budget_tokens")
        body["thinking"] = thinking
        let effort = MirageThinkingSuffix.effortForBudget(budget)
        var oc = (body["output_config"] as? [String: Any]) ?? [:]
        oc["effort"] = effort.rawValue
        body["output_config"] = oc
        stripSamplingParams(&body)
    }

    /// Budget → effort mapping from CPA `claude_executor.go:1438-1454`.
    /// Bounds are inclusive of the upper number and strict below.
    static func effortForBudget(_ budget: Int) -> MirageThinkingLevel {
        switch budget {
        case _ where budget >= 128_000: return .max
        case _ where budget >= 32_768:  return .xhigh
        case _ where budget >= 24_576:  return .high
        case _ where budget >= 8_192:   return .medium
        case _ where budget >= 1_024:   return .low
        case _ where budget > 0:        return .low
        default:                        return .high  // 0 or missing → default
        }
    }
}
