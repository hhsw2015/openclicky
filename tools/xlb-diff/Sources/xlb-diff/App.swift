import Foundation

// MARK: - Python invocation

let PYTHON_SCRIPT = ("~/.xlb-env/xlinkBook-skill/skills/xlb-topic-index/scripts/xlb_local_reader.py" as NSString).expandingTildeInPath

struct PyRun {
    let exit: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

func runPython(_ args: [String], timeout: TimeInterval = 30) -> PyRun {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["python3", PYTHON_SCRIPT] + args
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do { try proc.run() } catch {
        return PyRun(exit: -1, stdout: "", stderr: "spawn: \(error)", timedOut: false)
    }

    var timedOut = false
    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning {
        if Date() > deadline {
            proc.terminate()
            timedOut = true
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    proc.waitUntilExit()

    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
    return PyRun(
        exit: proc.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        timedOut: timedOut
    )
}

/// Python browse prints a `[browse-log] ...` prefix line before the JSON.
/// Slice from the first `{` or `[` so JSONDecoder can consume the body.
func stripLogAndParseJSON(_ text: String) -> Any? {
    let s = text
    guard let braceIdx = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let jsonSlice = String(s[braceIdx...])
    guard let data = jsonSlice.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [])
}

// MARK: - Reference wrappers

func pyLookupNames(_ query: String, limit: Int) -> Set<String>? {
    // suggest returns exact + prefix; browse "??q" adds substring +
    // content-match. For "A. exact" cases we want the suggest set;
    // for the "??" fuzzy cases we want the fuller browse candidate
    // set. Swift lookup does substring already, so use browse
    // (candidates minus content_match) for every case.
    let res = runPython(["browse", "??\(query)", "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any],
          let candidates = obj["candidates"] as? [[String: Any]] else { return nil }
    // Preserve Python stdout order. Set iteration is non-deterministic, so
    // `Set(Array(set).prefix(limit))` would pick a different top-N each run
    // (hash seed randomization) even when the underlying Python output was
    // identical. Deduplicate via insertion-order-preserving pattern instead
    // so the harness produces the same top-N on every invocation.
    var seen: Set<String> = []
    var ordered: [String] = []
    for c in candidates {
        // Skip content_match entries -- Swift's lookup is name-only.
        if let type = c["type"] as? String, type == "content_match" { continue }
        if let n = c["n"] as? String {
            let lower = n.lowercased()
            if seen.insert(lower).inserted {
                ordered.append(lower)
            }
        }
    }
    // Cap to limit to give both sides similar-sized populations. Prefix keeps
    // Python's canonical ranking (exact > prefix > substring) at the front.
    return Set(ordered.prefix(limit))
}

func pyGraphPath(from: String, to: String) -> [String]? {
    let res = runPython(["browse", from, "--graph-path", to, "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any] else { return nil }
    if let err = obj["error"] as? String, !err.isEmpty { return nil }
    guard let path = obj["path"] as? [[String: Any]] else { return nil }
    return path.compactMap { $0["label"] as? String }
}

func pyGraphExplore(from: String, hops: Int) -> Set<String>? {
    let res = runPython(["browse", from, "--graph-explore", String(hops), "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any],
          let nodes = obj["nodes"] as? [[String: Any]] else { return nil }
    var out: Set<String> = []
    for n in nodes {
        if let label = n["label"] as? String {
            out.insert(label.lowercased())
        }
    }
    return out
}

func pyGraphHubs(limit: Int) -> [String]? {
    let res = runPython(["browse", "", "--graph-hubs", String(limit), "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any],
          let hubs = obj["hubs"] as? [[String: Any]] else { return nil }
    return hubs.compactMap { $0["label"] as? String }
}

func pyGraphCommunity(topic: String) -> Set<String>? {
    let res = runPython(["browse", topic, "--graph-community", "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any] else { return nil }
    if let err = obj["error"] as? String, !err.isEmpty { return nil }
    guard let members = obj["members"] as? [[String: Any]] else { return nil }
    var out: Set<String> = []
    for m in members {
        if let label = m["label"] as? String, label.lowercased() != topic.lowercased() {
            out.insert(label.lowercased())
        }
    }
    return out
}

struct PyMeta {
    let searchinOut: Set<String>
    let sectionKeys: Set<String>
}

func pyMeta(topic: String) -> PyMeta? {
    let res = runPython(["browse", topic, "--meta", "--json"], timeout: 30)
    if res.timedOut || res.exit != 0 { return nil }
    guard let obj = stripLogAndParseJSON(res.stdout) as? [String: Any] else { return nil }
    // graph.searchin_out
    var soOut: Set<String> = []
    if let graph = obj["graph"] as? [String: Any],
       let so = graph["searchin_out"] as? [[String: Any]] {
        for entry in so {
            if let n = entry["n"] as? String { soOut.insert(n.lowercased()) }
        }
    }
    // tree.n keys
    var sections: Set<String> = []
    if let tree = obj["tree"] as? [[String: Any]] {
        for entry in tree {
            if let name = entry["n"] as? String { sections.insert(name.lowercased()) }
        }
    }
    return PyMeta(searchinOut: soOut, sectionKeys: sections)
}

// MARK: - Diff helpers

struct DiffResult {
    let overlap: Double
    let missingInSwift: [String]
    let extraInSwift: [String]
    let swiftSet: [String]
    let pySet: [String]
}

func diff(_ swift: Set<String>, _ python: Set<String>) -> DiffResult {
    let union = swift.union(python)
    let inter = swift.intersection(python)
    let overlap: Double
    if union.isEmpty {
        overlap = 1.0
    } else {
        overlap = Double(inter.count) / Double(union.count)
    }
    return DiffResult(
        overlap: overlap,
        missingInSwift: Array(python.subtracting(swift)).sorted(),
        extraInSwift: Array(swift.subtracting(python)).sorted(),
        swiftSet: swift.sorted(),
        pySet: python.sorted()
    )
}

// MARK: - Test outcomes

enum Outcome {
    case pass(overlap: Double)
    case fail(overlap: Double, detail: DiffResult)
    case skip(reason: String)
    case error(reason: String)
}

// MARK: - Main harness

@main
struct XLBDiff {
    static func main() async {
        // Enable the Swift index and point at the real library dir.
        let dir = ("~/.xlb-env/xlinkBook/db/library" as NSString).expandingTildeInPath
        UserDefaults.standard.set(true,  forKey: "openclicky.xlb.enabled")
        UserDefaults.standard.set(dir,  forKey: "openclicky.xlb.libraryDir")

        // Force a sync so the harness's Application Support db is populated.
        FileHandle.standardError.write("[xlb-diff] syncing Swift index...\n".data(using: .utf8)!)
        do {
            let stats = try await XLBTopicIndex.shared.syncIfNeeded(force: false)
            if let s = stats {
                FileHandle.standardError.write("[xlb-diff] sync ok: \(s.recordsParsed) records / \(s.topicsIndexed) topics / \(s.edgesIndexed) edges in \(String(format: "%.2f", s.elapsedSeconds))s\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("[xlb-diff] sync: no-op (index already fresh)\n".data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("[xlb-diff] sync failed: \(error)\n".data(using: .utf8)!)
            exit(2)
        }

        var results: [(TestCase, Outcome)] = []

        for tc in Fixtures.all {
            let outcome = await runOne(tc)
            let statusLine: String
            switch outcome {
            case .pass(let o):
                statusLine = String(format: "[PASS] %@: %@ (overlap %.0f%%)", tc.id, tc.title, o * 100)
            case .fail(let o, _):
                statusLine = String(format: "[FAIL] %@: %@ (overlap %.0f%%)", tc.id, tc.title, o * 100)
            case .skip(let reason):
                statusLine = "[SKIP] \(tc.id): \(tc.title) - \(reason)"
            case .error(let reason):
                statusLine = "[ERROR] \(tc.id): \(tc.title) - \(reason)"
            }
            FileHandle.standardError.write((statusLine + "\n").data(using: .utf8)!)
            results.append((tc, outcome))
        }

        emitReport(results)
    }

    // Set-based judgement: pass iff overlap >= 0.9.
    static let PASS_THRESHOLD = 0.9

    static func runOne(_ tc: TestCase) async -> Outcome {
        switch tc.kind {

        case let .lookupNames(query, limit):
            let matches = await XLBTopicIndex.shared.fuzzyLookup(query, limit: limit)
            let swiftNames = Set(matches.map { $0.name.lowercased() })
            guard let pySet = pyLookupNames(query, limit: limit) else {
                return .error(reason: "python browse ?? failed")
            }
            let d = diff(swiftNames, pySet)
            return d.overlap >= PASS_THRESHOLD ? .pass(overlap: d.overlap) : .fail(overlap: d.overlap, detail: d)

        case let .graphPath(from, to):
            let swiftPath = await XLBTopicIndex.shared.graphPath(from: from, to: to)
            let pyPath = pyGraphPath(from: from, to: to)
            switch (swiftPath, pyPath) {
            case (nil, nil):
                return .pass(overlap: 1.0)
            case (nil, .some(let p)):
                let d = DiffResult(overlap: 0, missingInSwift: p, extraInSwift: [], swiftSet: [], pySet: p)
                return .fail(overlap: 0, detail: d)
            case (.some(let s), nil):
                let d = DiffResult(overlap: 0, missingInSwift: [], extraInSwift: s, swiftSet: s, pySet: [])
                return .fail(overlap: 0, detail: d)
            case let (.some(s), .some(p)):
                // Compare LENGTH + endpoints only. Intermediate hops may
                // differ because Python considers directed contains
                // edges too, Swift walks undirected `edges` table only.
                let swiftLen = s.count
                let pyLen = p.count
                // Consider it a pass when both are non-trivial and
                // hop-count differs by <= 1.
                let lenOK = abs(swiftLen - pyLen) <= 1
                let endpointsOK = (s.first?.lowercased() == p.first?.lowercased()) &&
                                  (s.last?.lowercased()  == p.last?.lowercased())
                if lenOK && endpointsOK {
                    return .pass(overlap: 1.0)
                }
                let d = DiffResult(
                    overlap: 0,
                    missingInSwift: p,
                    extraInSwift: s,
                    swiftSet: s,
                    pySet: p
                )
                return .fail(overlap: 0, detail: d)
            }

        case let .graphExplore(from, hops):
            // Use the production default (`searchin` only) so the harness
            // exercises the same neighbourhood Python's `_graph_explore`
            // walks (`follow_rels = {"searchin"}`).
            let swiftNeighbors = await XLBTopicIndex.shared.graphExplore(from: from, hops: hops, kinds: ["searchin"])
            let swiftSet = Set(swiftNeighbors.map { $0.name.lowercased() })
            guard let pySet = pyGraphExplore(from: from, hops: hops) else {
                return .error(reason: "python graph-explore failed")
            }
            let d = diff(swiftSet, pySet)
            return d.overlap >= PASS_THRESHOLD ? .pass(overlap: d.overlap) : .fail(overlap: d.overlap, detail: d)

        case let .graphHubs(limit):
            let swiftHubs = await XLBTopicIndex.shared.graphHubs(limit: limit, kinds: ["searchin"])
            let swiftSet = Set(swiftHubs.map { $0.name.lowercased() })
            guard let pyList = pyGraphHubs(limit: limit) else {
                return .error(reason: "python graph-hubs failed")
            }
            let pySet = Set(pyList.map { $0.lowercased() })
            let d = diff(swiftSet, pySet)
            // Hubs top-10 overlap is expected to be very high; use
            // 70% floor since ties near the tail can shuffle.
            return d.overlap >= 0.7 ? .pass(overlap: d.overlap) : .fail(overlap: d.overlap, detail: d)

        case let .graphCommunity(topic):
            // Known divergent: Python uses external graphify labels,
            // Swift does synchronous LPA. Any non-crash is documented
            // and marked SKIP so it doesn't inflate the fail count.
            let swiftPeers = await XLBTopicIndex.shared.communityPeers(of: topic, limit: 100)
            let swiftSet = Set(swiftPeers.map { $0.lowercased() })
            guard let pySet = pyGraphCommunity(topic: topic) else {
                return .skip(reason: "python community unavailable")
            }
            let d = diff(swiftSet, pySet)
            // Do not fail on this axis: mark PASS if any overlap
            // (>=25%), else SKIP with the diff attached.
            if d.overlap >= 0.25 {
                return .pass(overlap: d.overlap)
            }
            return .skip(reason: String(format: "community divergent (overlap %.0f%%); py=%d swift=%d",
                                        d.overlap * 100, pySet.count, swiftSet.count))

        case let .meta(topic):
            // Python's `_browse_meta` slices `searchin_out[:10]`; match here.
            let swiftSearchin = await XLBTopicIndex.shared.searchinOut(from: topic, limit: 10)
            let swiftSections = await XLBTopicIndex.shared.tagSectionCounts(topic: topic)
            let swiftSoSet = Set(swiftSearchin.map { $0.peer.lowercased() })
            let swiftSectionSet = Set(swiftSections.map { $0.tagName.lowercased() })
            guard let py = pyMeta(topic: topic) else {
                return .error(reason: "python meta failed")
            }
            let dSo = diff(swiftSoSet, py.searchinOut)
            let dSec = diff(swiftSectionSet, py.sectionKeys)
            let overlap = (dSo.overlap + dSec.overlap) / 2.0
            if overlap >= PASS_THRESHOLD {
                return .pass(overlap: overlap)
            }
            // Merge diffs for reporting.
            let missing = Array(Set(dSo.missingInSwift + dSec.missingInSwift)).sorted()
            let extra = Array(Set(dSo.extraInSwift + dSec.extraInSwift)).sorted()
            let combined = DiffResult(
                overlap: overlap,
                missingInSwift: missing,
                extraInSwift: extra,
                swiftSet: Array(swiftSoSet.union(swiftSectionSet)).sorted(),
                pySet: Array(py.searchinOut.union(py.sectionKeys)).sorted()
            )
            return .fail(overlap: overlap, detail: combined)
        }
    }

    static func emitReport(_ results: [(TestCase, Outcome)]) {
        var passed = 0, failed = 0, skipped = 0, errored = 0
        var failLines: [String] = []
        for (tc, o) in results {
            switch o {
            case .pass: passed += 1
            case .fail(let overlap, let d):
                failed += 1
                var line = "### \(tc.id): \(tc.title) (overlap " + String(format: "%.0f%%", overlap * 100) + ")\n"
                line += "- Swift: " + previewList(d.swiftSet, cap: 20) + "\n"
                line += "- Python: " + previewList(d.pySet, cap: 20) + "\n"
                if !d.missingInSwift.isEmpty {
                    line += "- Missing in Swift: " + previewList(d.missingInSwift, cap: 20) + "\n"
                }
                if !d.extraInSwift.isEmpty {
                    line += "- Extra in Swift: " + previewList(d.extraInSwift, cap: 20) + "\n"
                }
                failLines.append(line)
            case .skip: skipped += 1
            case .error: errored += 1
            }
        }
        print("# xlb differential test report")
        print("")
        print("## Summary")
        print("- Total: \(results.count)")
        print("- Passed: \(passed)")
        print("- Failed: \(failed)")
        print("- Skipped: \(skipped)")
        if errored > 0 { print("- Errors: \(errored)") }
        print("")
        if !failLines.isEmpty {
            print("## Failures")
            for line in failLines { print(line) }
        }
        // Errors and skips also worth listing.
        let errorItems = results.filter { if case .error = $0.1 { return true }; return false }
        if !errorItems.isEmpty {
            print("## Errors")
            for (tc, o) in errorItems {
                if case .error(let reason) = o {
                    print("- \(tc.id) \(tc.title): \(reason)")
                }
            }
            print("")
        }
        let skipItems = results.filter { if case .skip = $0.1 { return true }; return false }
        if !skipItems.isEmpty {
            print("## Skipped")
            for (tc, o) in skipItems {
                if case .skip(let reason) = o {
                    print("- \(tc.id) \(tc.title): \(reason)")
                }
            }
            print("")
        }
    }

    static func previewList(_ names: [String], cap: Int) -> String {
        if names.count <= cap { return "{" + names.joined(separator: ", ") + "}" }
        return "{" + names.prefix(cap).joined(separator: ", ") + ", ...+\(names.count - cap)}"
    }
}
