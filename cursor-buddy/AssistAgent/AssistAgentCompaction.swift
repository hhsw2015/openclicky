//
//  AssistAgentCompaction.swift
//  cursor-buddy
//
//  Text-compaction stack ported from heyclicky_agent/agent.py.
//
//  Layers (called in-loop before each ask):
//    1. per-tool result summariser — done inline by AssistAgentTools
//       (already returns compacted `summary` alongside `raw`).
//    2. dedup stale reads — same-file re-reads collapse to the newest.
//    3. compact_source / compact_json / compact_diff / compact_stdout —
//       applied when a step's raw body is picked up for prior injection.
//    4. microcompact_session — clear old tool bodies, keep last-N intact.
//    5. trim_digest_if_bloated — drop the oldest half of `digest`.
//    6. deep microcompact — shrink kept-recent to KEEP_RECENT_MIN.
//
//  Together these give the multi-turn dialog its ability to keep
//  going past the raw context window.
//

import Foundation

public enum AssistAgentCompactionConstants {
    public static let digestMaxChars = 20_000
    public static let microcompactKeepRecent = 4    // matches Python agent.py
    public static let keepRecentMin = 3
    public static let microcompactClearedMarker = "[body cleared by microcompact]"
    public static let editKinds: Set<String> = ["写入完成", "局部替换", "追加片段", "批量替换", "差量应用"]

    /// Model-aware budget tuple. Python parity
    /// `compute_budget_for_model(model)` returns `(soft, micro, hard)`
    /// derived from the model's context window minus output reserve
    /// (16k) minus system-prompt overhead (12k), times 4 chars/token.
    ///
    /// Ratios (INFINITE_DIALOG.md §0):
    ///   soft  ≈ 35% of working → proactive trim
    ///   micro ≈ 60% of working → clear tool_result bodies
    ///   hard  ≈ 100% of working → model-summary fold
    ///
    /// Fall back to the empirical Fable-5 tier (20k/30k/42k) when the
    /// resolved working budget would be tighter than that — real
    /// evidence beats extrapolation for the free-tier proxy.
    public static func budget(for modelID: String?)
        -> (soft: Int, micro: Int, hard: Int)
    {
        let working = AssistAgentBudget.priorCharBudget(for: modelID)
        let soft = max(20_000, Int(Double(working) * 0.35))
        let micro = max(30_000, Int(Double(working) * 0.60))
        let hard = max(42_000, working)
        return (soft, micro, hard)
    }

    /// Kinds whose result body is a MODEL instruction (recovery hint /
    /// done rejection / plan reminder) — never demote below medium
    /// because a truncated instruction misleads the model.
    public static let stickyKinds: Set<String> = ["_reminder"]

    /// Layered-compression budgets (matches Python agent.py:432).
    /// Prior char count crosses these thresholds → progressively
    /// aggressive tier demotion applies.
    public static let softBudget = 20_000        // proactive-trim floor
    public static let microcompactTrigger = 30_000  // start clearing bodies
    public static let hardBudget = 42_000        // last band before cliff

    /// Empirical per-session ceiling — the authoritative Python
    /// constant is 45_000 (agent.py:445 `EMPIRICAL_EMPTY_CEILING_CHARS`,
    /// SUMMARY.md finding #1: "Real per-session ceiling: ~45k input
    /// chars"). Above 45k, success rate cliffs to 17% (PATTERNS input
    /// buckets 45-50k). Do not push higher — the 60-64k number in
    /// FINDINGS #2 was the "5-consecutive-empty kill" threshold, a
    /// different, larger metric that is NOT what triggers empty replies.
    /// Preemptive shrink triggers at 42k (aim to stay under ceiling)
    /// and targets 20k (well inside the 100% zone).
    public static let empiricalEmptyCeiling = 45_000
    public static let preemptiveShrinkTrigger = 42_000
    public static let preemptiveShrinkTarget = 20_000

    /// Per-step tier caps.
    public static let fullResultChars = 3_000    // full tier body cap
    public static let mediumResultChars = 500    // medium tier body cap
    public static let onelineResultChars = 120   // oneline tier cap

    /// BLOB image offload — models with small context benefit from
    /// rendering long tool bodies to an ASCII bitmap and reading via
    /// the vision channel (Python `_build_prior_with_offload`).
    /// Anthropic-family models with 200k context see no benefit and
    /// pay vision-decode cost. Opt-in per model.
    public static let blobOffloadEligibleModels: Set<String> = [
        "claude-fable-5",
    ]
    public static let blobOffloadMinPriorChars = 15_000
    public static let blobOffloadPerStepMinChars = 400
    public static let blobOffloadJPEGMaxBytes = 80_000
}

/// Step render tier. Full-detail early rounds ↓ oneline-summary
/// after the loop grows too long. Determined per-step, per-round
/// by `assistCompactionAssignTiers` based on prior char count.
public enum AssistAgentStepTier: Sendable {
    case full       // whole result summary (up to fullResultChars)
    case medium     // trimmed to mediumResultChars
    case oneline    // one-line label + kind + path/cmd only
}

// MARK: - Stale-read dedup

/// Return the indices of `steps` whose `read_file` result is superseded
/// by a later read of the same path. Callers may skip these indices when
/// building prior. Mirrors Python `_dedup_stale_reads`.
public func assistCompactionStaleReadIndices(_ steps: [AssistAgentSession.Step]) -> Set<Int> {
    // Python parity (agent.py:946): only `文件内容` (read_file) counts
    // for stale-read dedup. `file_outline` returns a strict subset of
    // read_file content, so dedup'ing outline against content would
    // hide fresh signal. Restrict to the same op_kind.
    var lastReadByPath: [String: Int] = [:]
    for (i, s) in steps.enumerated() {
        guard s.kind == "文件内容",
              let path = s.args["path"] else { continue }
        lastReadByPath[path] = i
    }
    var stale = Set<Int>()
    for (i, s) in steps.enumerated() {
        guard s.kind == "文件内容",
              let path = s.args["path"],
              let newest = lastReadByPath[path] else { continue }
        if i != newest { stale.insert(i) }
    }
    return stale
}

// MARK: - JSON compaction

/// Parse JSON, keep keys + short scalars, truncate long strings, prune
/// deep arrays. Returns nil when `text` is not JSON. Mirrors Python
/// `_compact_json_string`.
public func assistCompactionCompactJSON(_ text: String, budget: Int = 2_000) -> String? {
    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = stripped.first, first == "{" || first == "[" else { return nil }
    guard let data = stripped.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let compacted = _jsonCompactValue(parsed, depth: 0)
    guard let outData = try? JSONSerialization.data(
        withJSONObject: compacted, options: [.prettyPrinted]),
          var out = String(data: outData, encoding: .utf8) else { return nil }
    if out.count > budget {
        let headN = Int(Double(budget) * 0.7)
        let tailN = Int(Double(budget) * 0.25)
        let head = String(out.prefix(headN))
        let tail = String(out.suffix(tailN))
        out = head + "\n...(json truncated)...\n" + tail
    }
    return out
}

private func _jsonCompactValue(_ v: Any, depth: Int) -> Any {
    if depth > 6 { return "...(too deep)..." }
    if let s = v as? String {
        if s.count > 100 {
            let prefix = String(s.prefix(80))
            return "\(prefix)...(\(s.count - 80) chars omitted)"
        }
        return s
    }
    if let arr = v as? [Any] {
        if arr.count > 5 {
            let head = arr.prefix(3).map { _jsonCompactValue($0, depth: depth + 1) }
            return head + ["...(\(arr.count - 3) more items)"]
        }
        return arr.map { _jsonCompactValue($0, depth: depth + 1) }
    }
    if let dict = v as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, vv) in dict {
            out[k] = _jsonCompactValue(vv, depth: depth + 1)
        }
        return out
    }
    return v
}

// MARK: - Diff compaction

/// Drop context lines, keep hunk headers + `+`/`-` lines.
/// Mirrors Python `_compact_diff`.
public func assistCompactionCompactDiff(_ text: String, budget: Int = 2_000) -> String? {
    if !text.contains("@@") && !text.contains("---") { return nil }
    var kept: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        if s.hasPrefix("@@") || s.hasPrefix("---") || s.hasPrefix("+++")
            || s.hasPrefix("+") || s.hasPrefix("-") {
            kept.append(s)
        }
    }
    var out = kept.joined(separator: "\n")
    if out.count > budget {
        let headN = Int(Double(budget) * 0.6)
        let tailN = Int(Double(budget) * 0.3)
        out = String(out.prefix(headN)) + "\n...(diff mid trimmed)...\n" + String(out.suffix(tailN))
    }
    return out
}

// MARK: - Stdout compaction (rtk-style noise strip)

private let _stdoutNoiseCommon: [String] = [
    "^\\s*$",
    "^\\x1b\\["
]

private let _stdoutNoiseByTool: [String: [String]] = [
    "pytest": [
        "^platform ", "^cachedir:", "^metadata: ", "^rootdir: ", "^plugins: ",
        "^collecting \\.\\.\\.", "^collected \\d+ items?",
        "^={5,}", "^\\.+\\s*$", "^\\s*\\[?\\s*\\d+%\\]?\\s*$"
    ],
    "xcodebuild": [
        "^CompileC ", "^CompileSwift ", "^Ld ", "^Touch ", "^CodeSign ",
        "^ProcessInfoPlist", "^CreateBuildDirectory", "^MkDir ", "^CopySwiftLibs",
        "^Signing Identity", "^RegisterWithLaunchServices"
    ],
    "npm": ["^npm WARN ", "^\\s*added \\d+ packages", "^\\s*audited \\d+"],
    "cargo": ["^\\s*Compiling ", "^\\s*Downloaded ", "^\\s*Downloading ", "^\\s*Fresh "],
    "git": ["^On branch ", "^Your branch is"]
]

/// Strip well-known noise from command output before length capping.
/// Mirrors Python `_compact_stdout`.
public func assistCompactionCompactStdout(cmd: String,
                                          stdout: String,
                                          budget: Int = 3_000) -> String {
    if stdout.isEmpty { return stdout }
    // If stdout parses as JSON, route through JSON compressor.
    let head = stdout.trimmingCharacters(in: .whitespacesAndNewlines).first
    if head == "{" || head == "[" {
        if let jc = assistCompactionCompactJSON(stdout, budget: budget),
           Double(jc.count) < Double(stdout.count) * 0.6 {
            return jc + "\n(json-compact: \(stdout.count)→\(jc.count) chars)"
        }
    }

    var patterns = _stdoutNoiseCommon
    let cmdLow = cmd.lowercased()
    for (tool, pats) in _stdoutNoiseByTool where cmdLow.contains(tool) {
        patterns.append(contentsOf: pats)
    }
    let re = try? NSRegularExpression(
        pattern: patterns.joined(separator: "|"),
        options: [.anchorsMatchLines])

    var filtered: [String] = []
    var dropped = 0
    for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        if let re {
            let ns = s as NSString
            if re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
                dropped += 1
                continue
            }
        }
        // Collapse runs of same char: ============ → ==================...
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if s.count > 20 && Set(trimmed).count == 1 {
            filtered.append(String(s.prefix(20)) + "...")
            continue
        }
        filtered.append(s)
    }

    var out = filtered.joined(separator: "\n")

    // Normalise timings/timestamps/UUIDs/hex addresses.
    if let r = try? NSRegularExpression(pattern: "\\bin \\d+\\.\\d+s\\b") {
        out = r.stringByReplacingMatches(
            in: out, range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: "in T.T s")
    }
    if let r = try? NSRegularExpression(
        pattern: "\\b\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:[Zz]|[+-]\\d{2}:?\\d{2})?\\b") {
        out = r.stringByReplacingMatches(
            in: out, range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: "<TS>")
    }
    if let r = try? NSRegularExpression(pattern: "\\b\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?\\b") {
        out = r.stringByReplacingMatches(
            in: out, range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: "<TS>")
    }
    if let r = try? NSRegularExpression(pattern: "0x[0-9a-fA-F]{6,}") {
        out = r.stringByReplacingMatches(
            in: out, range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: "<ADDR>")
    }
    if let r = try? NSRegularExpression(
        pattern: "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b") {
        out = r.stringByReplacingMatches(
            in: out, range: NSRange(location: 0, length: (out as NSString).length),
            withTemplate: "<UUID>")
    }

    if dropped > 0 { out += "\n(rtk-style filter dropped \(dropped) noise lines)" }
    if out.count <= budget { return out }
    let headN = Int(Double(budget) * 0.6)
    let tailN = budget - headN - 100
    return String(out.prefix(headN))
        + "\n...(middle \(out.count - headN - tailN) chars omitted)...\n"
        + String(out.suffix(tailN))
}

// MARK: - Source compaction (skeleton via language-aware regexes)

private let _skeletonByExt: [String: [String]] = [
    "js": [
        "^\\s*import ", "^\\s*const ", "^\\s*let ", "^\\s*export ",
        "^\\s*(?:async\\s+)?function ", "^\\s*class ", "^\\s*type ",
        "^\\s*interface ", "^\\s*[A-Za-z_$][\\w$]*\\s*:\\s*(?:function|async)"
    ],
    "ts": [
        "^\\s*import ", "^\\s*export ", "^\\s*const ", "^\\s*let ",
        "^\\s*(?:async\\s+)?function ", "^\\s*class ", "^\\s*interface ",
        "^\\s*type ", "^\\s*enum ", "^\\s*declare ",
        "^\\s*(?:public|private|protected)\\s+"
    ],
    "rs": [
        "^\\s*use ", "^\\s*mod ", "^\\s*pub ",
        "^\\s*(?:pub\\s+)?(?:async\\s+)?fn ", "^\\s*(?:pub\\s+)?struct ",
        "^\\s*(?:pub\\s+)?enum ", "^\\s*(?:pub\\s+)?trait ",
        "^\\s*impl ", "^\\s*(?:pub\\s+)?const ", "^\\s*(?:pub\\s+)?static "
    ],
    "go": [
        "^import ", "^\\s*package ", "^\\s*type ", "^\\s*func ",
        "^\\s*const ", "^\\s*var "
    ],
    "py": [
        "^\\s*import ", "^\\s*from ",
        "^\\s*(?:async\\s+)?def ", "^\\s*class ",
        "^\\s*[A-Z_][A-Z0-9_]*\\s*="
    ],
    "swift": [
        "^\\s*import ",
        "^\\s*(?:public|open|internal|private|fileprivate)?\\s*(?:final\\s+)?(?:class|struct|enum|protocol|extension|actor)\\b",
        "^\\s*(?:public|open|internal|private|fileprivate)?\\s*func\\b",
        "^\\s*(?:public|open|internal|private|fileprivate)?\\s*(?:static\\s+)?(?:var|let)\\b",
        "^\\s*(?:public|open|internal|private|fileprivate)?\\s*typealias\\b"
    ]
]

/// Language-aware source skeleton: keep imports, def/class/struct
/// signatures, module-level constants. Mirrors Python `_compact_source`.
public func assistCompactionCompactSource(_ text: String,
                                          path: String = "",
                                          budget: Int = 4_000) -> String {
    if text.count <= budget { return text }
    let ext = (path as NSString).pathExtension.lowercased()
    let normalisedExt: String = {
        switch ext {
        case "jsx": return "js"
        case "tsx": return "ts"
        default: return ext
        }
    }()
    guard let patterns = _skeletonByExt[normalisedExt] else {
        // Fallback: keep head + tail.
        let headN = Int(Double(budget) * 0.6)
        let tailN = budget - headN - 100
        return String(text.prefix(headN))
            + "\n...(source middle trimmed)...\n"
            + String(text.suffix(tailN))
    }
    let combined = patterns.joined(separator: "|")
    guard let re = try? NSRegularExpression(pattern: combined, options: []) else {
        return String(text.prefix(budget))
    }
    var kept: [String] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    // Always keep the top of the file.
    kept.append(contentsOf: lines.prefix(20).map(String.init))
    for (idx, line) in lines.enumerated() where idx >= 20 {
        let s = String(line)
        let ns = s as NSString
        if re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil {
            kept.append(s)
        }
        if kept.count > 400 { break }
    }
    var out = kept.joined(separator: "\n")
    if out.count > budget {
        out = String(out.prefix(budget - 50)) + "\n...(skeleton trimmed)..."
    }
    return out
}

// MARK: - Session-level microcompact / digest trim

/// Clear old tool_result bodies in place, keeping the last N steps
/// intact. Returns how many steps got cleared. Mirrors Python
/// `_microcompact_session` (mutates `session`).
@MainActor
@discardableResult
public func assistCompactionMicrocompactSession(
    _ session: AssistAgentSession,
    keepRecent: Int = AssistAgentCompactionConstants.microcompactKeepRecent
) -> Int {
    let n = session.steps.count
    guard n > keepRecent + 1 else { return 0 }
    let stop = n - keepRecent
    var cleared = 0
    for i in 0..<stop {
        let step = session.steps[i]
        if AssistAgentCompactionConstants.editKinds.contains(step.kind) { continue }
        if AssistAgentCompactionConstants.stickyKinds.contains(step.kind) { continue }
        if step.raw == AssistAgentCompactionConstants.microcompactClearedMarker { continue }
        let slim = AssistAgentSession.Step(
            kind: step.kind, tool: step.tool, args: step.args,
            why: step.why,
            result: step.result,   // keep the short summary
            raw: AssistAgentCompactionConstants.microcompactClearedMarker,
            ok: step.ok,
            startedAt: step.startedAt,
            elapsedMs: step.elapsedMs,
            id: step.id)
        session.steps[i] = slim
        cleared += 1
    }
    return cleared
}

/// Adaptive keep-window for the digest tail.
/// Bounds: [3k, 15k] chars. Mirrors Python `_compute_digest_keep_target`.
@MainActor
public func assistCompactionComputeDigestKeepTarget(_ session: AssistAgentSession,
                                                    modelID: String? = nil) -> Int {
    let hard = AssistAgentBudget.priorCharBudget(for: modelID)
    let hardCap = Int(Double(hard) * 0.06)
    let base = 6_000
    let taskBonus = min(3_000, session.userTask.count * 8)
    let workBonus = min(4_000, session.steps.count * 300)
    let pinRelief = min(2_000, session.pinnedMemory.count * 100)
    let target = base + taskBonus + workBonus - pinRelief
    return max(3_000, min(target, hardCap, 15_000))
}

/// Drop the ancient tail of `digest` when it exceeds DIGEST_MAX_CHARS.
/// Mirrors Python `_trim_digest_if_bloated`. Returns true when it trimmed.
@MainActor
@discardableResult
public func assistCompactionTrimDigestIfBloated(_ session: AssistAgentSession,
                                                modelID: String? = nil) -> Bool {
    if session.digest.count < AssistAgentCompactionConstants.digestMaxChars { return false }
    let keep = assistCompactionComputeDigestKeepTarget(session, modelID: modelID)
    var recent = String(session.digest.suffix(keep))
    // Snap to first newline so we don't cut mid-sentence.
    if let nl = recent.firstIndex(of: "\n"),
       recent.distance(from: recent.startIndex, to: nl) < 200 {
        recent = String(recent[recent.index(after: nl)...])
    }
    let marker = "[older digest trimmed — earlier progress is archived on disk; " +
                 "call query_history({\"pattern\":\"...\"}) to retrieve specifics]\n"
    session.digest = marker + recent
    return true
}

// MARK: - Tier assignment (layered demotion)

/// For each step, decide the render tier so total prior stays under
/// `softBudget`. Mirrors Python agent.py::`_try_demote`.
///
/// Policy:
///   · Keep the last `keepRecentFullTier` steps at `.full`
///     regardless of budget (they are what the model is reasoning on).
///   · Edit-kind steps (write/edit/append/apply_diff) NEVER demote
///     below `.medium` — dropping their body loses file state.
///   · From the OLDEST forward, demote full → medium → oneline until
///     rendered prior fits under `softBudget`.
///
/// Called by the loop between microcompact and prior render. Returns
/// a parallel tier array (same length as `session.steps`).
@MainActor
public func assistCompactionAssignTiers(
    _ session: AssistAgentSession,
    keepRecentFullTier: Int = 3,
    softBudget: Int = AssistAgentCompactionConstants.softBudget,
    render: (AssistAgentSession.Step, AssistAgentStepTier) -> Int
) -> [AssistAgentStepTier] {
    let n = session.steps.count
    guard n > 0 else { return [] }
    var tiers: [AssistAgentStepTier] = Array(repeating: .full, count: n)

    func totalChars() -> Int {
        var acc = 0
        for i in 0..<n { acc += render(session.steps[i], tiers[i]) }
        return acc
    }

    // Already under budget? Nothing to do.
    if totalChars() <= softBudget { return tiers }

    // First pass: demote OLDEST full-tier steps → medium.
    let recentStart = max(0, n - keepRecentFullTier)
    for i in 0..<recentStart {
        let step = session.steps[i]
        if AssistAgentCompactionConstants.editKinds.contains(step.kind) {
            // Edits: never below medium.
            tiers[i] = .medium
        } else {
            tiers[i] = .medium
        }
        if totalChars() <= softBudget { return tiers }
    }

    // Second pass: further demote non-edit medium → oneline.
    // stickyKinds (recovery reminders) never drop below medium.
    for i in 0..<recentStart {
        let step = session.steps[i]
        if !AssistAgentCompactionConstants.editKinds.contains(step.kind)
            && !AssistAgentCompactionConstants.stickyKinds.contains(step.kind) {
            tiers[i] = .oneline
        }
        if totalChars() <= softBudget { return tiers }
    }

    return tiers
}

/// Render a step's body according to its assigned tier. This is the
/// helper the loop's prior-builder calls to actually cap each step
/// according to the tier decision.
public func assistCompactionRenderStep(_ step: AssistAgentSession.Step,
                                       tier: AssistAgentStepTier) -> String {
    switch tier {
    case .full:
        let cap = AssistAgentCompactionConstants.fullResultChars
        return step.result.count > cap
            ? String(step.result.prefix(cap)) + "…"
            : step.result
    case .medium:
        let cap = AssistAgentCompactionConstants.mediumResultChars
        return step.result.count > cap
            ? String(step.result.prefix(cap)) + "…"
            : step.result
    case .oneline:
        // Take the FIRST non-blank line of the result summary and
        // truncate to onelineResultChars. Matches Python's
        // `_step_oneline`.
        let firstLine = step.result.split(separator: "\n")
            .first(where: { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty })
            .map(String.init) ?? step.result
        let cap = AssistAgentCompactionConstants.onelineResultChars
        return firstLine.count > cap
            ? String(firstLine.prefix(cap)) + "…"
            : firstLine
    }
}

// MARK: - Preemptive query shrink

/// Last-ditch middle-cut so the outgoing query stays under the
/// empirical empty ceiling. Mirrors Python `_build_query`'s
/// `_SHRINK_TRIGGER` / `_SHRINK_TARGET` block (agent.py:1835).
///
/// Strategy:
///   1. Try to find one of the known section markers ("本轮新增:",
///      "最近步骤(勿重复):"). Cut the middle of that block, keep
///      head 400 chars + tail 600+.
///   2. If no marker matches: blunt middle-truncate the whole query
///      symmetrically so we hit `preemptiveShrinkTarget`.
///
/// Returns (shrunken, savedChars). `savedChars == 0` means no-op.
public func assistCompactionPreemptiveShrink(_ query: String)
    -> (out: String, saved: Int)
{
    let trigger = AssistAgentCompactionConstants.preemptiveShrinkTrigger
    let target  = AssistAgentCompactionConstants.preemptiveShrinkTarget
    guard query.count > trigger else { return (query, 0) }
    let originalLen = query.count

    // Marker-directed section cut.
    let candidates: [(start: String, end: String)] = [
        ("本轮新增:", "\n\n"),
        ("最近步骤(勿重复):", "\n\n"),
        ("摘要:", "\n\n"),
    ]
    var work = query
    for (startMarker, endMarker) in candidates {
        guard let sRange = work.range(of: startMarker) else { continue }
        guard let eRange = work.range(of: endMarker,
                                      range: sRange.upperBound..<work.endIndex)
        else { continue }
        let block = String(work[sRange.lowerBound..<eRange.lowerBound])
        let needToCut = work.count - target
        let headKeep = 400
        let tailKeep = max(600, block.count - 400 - needToCut - 200)
        guard headKeep + tailKeep < block.count else { continue }
        let cutMiddle = block.count - headKeep - tailKeep
        let head = String(block.prefix(headKeep))
        let tail = String(block.suffix(tailKeep))
        let newBlock = head +
            "\n[中间 \(cutMiddle) 字符已自动裁剪 — 完整历史存于本地," +
            "调用 query_history 检索]\n" + tail
        work.replaceSubrange(sRange.lowerBound..<eRange.lowerBound, with: newBlock)
        if work.count <= target { break }
    }

    // Blunt middle-cut fallback.
    if work.count > trigger {
        let excess = work.count - target
        let mid = work.count / 2
        let cutStart = max(500, mid - excess / 2)
        let cutEnd = min(work.count, cutStart + excess)
        let idxS = work.index(work.startIndex, offsetBy: cutStart)
        let idxE = work.index(work.startIndex, offsetBy: cutEnd)
        let marker = "\n[强制中段裁剪 \(cutEnd - cutStart) 字符 — 上下文超上限时的兜底]\n"
        work.replaceSubrange(idxS..<idxE, with: marker)
    }
    return (work, originalLen - work.count)
}

// MARK: - Cascade helper

/// Escalating compaction ladder. Returns (rungName, charsSaved).
/// Rungs: microcompact → deep microcompact.
@MainActor
public func assistCompactionCascade(_ session: AssistAgentSession,
                                    priorLength: (AssistAgentSession) -> Int
) -> (rung: String, saved: Int) {
    let before: Int = priorLength(session)
    if assistCompactionMicrocompactSession(session) > 0 {
        let after: Int = priorLength(session)
        if after < before {
            let saved: Int = before - after
            return (rung: "microcompact", saved: saved)
        }
    }
    // Deep rung: shrink kept-recent window to the min.
    if assistCompactionMicrocompactSession(
        session,
        keepRecent: AssistAgentCompactionConstants.keepRecentMin) > 0 {
        let after: Int = priorLength(session)
        let saved: Int = before - after
        return (rung: "deep_microcompact", saved: saved)
    }
    return (rung: "noop", saved: 0)
}
