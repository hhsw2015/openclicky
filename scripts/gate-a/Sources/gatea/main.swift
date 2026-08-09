// Gate A harness — scores the SHIPPED OpenClickyIntentClassifier across four
// input arms to answer one question: does resolving deixis (and/or rendering
// in English) improve routelet's accuracy enough to justify an E4B frontend?
//
// The classifier source is copied verbatim from the app except for one
// build-time rewrite: SwiftPM exposes ONNX Runtime as `OnnxRuntimeBindings`,
// while the Xcode target sees `onnxruntime`. Without the rewrite,
// `#if canImport(onnxruntime)` is false, `embed()` silently returns nil, and
// every arm scores identically at zero — a false negative that looks exactly
// like "grounding doesn't help". Arm 4 exists to catch that class of failure.

import Foundation

struct Item: Decodable {
    let gold: String
    let arm1_zh_raw: String
    let arm2_zh_grounded: String
    let arm3_en_grounded: String
    let arm4_en_raw: String
}

struct Corpus: Decodable { let items: [Item] }

struct ArmResult {
    let name: String
    var correct = 0
    var total = 0
    var none = 0            // reject class — the classifier declining
    var nilResult = 0       // embed() failed outright
    var confSum: Double = 0
    var perIntent: [String: (hit: Int, n: Int)] = [:]

    var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
    var noneRate: Double { total == 0 ? 0 : Double(none) / Double(total) }
    var meanConf: Double { total == 0 ? 0 : confSum / Double(total) }
}

func loadCorpus() throws -> Corpus {
    let path = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : FileManager.default.currentDirectoryPath + "/corpus.json"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(Corpus.self, from: data)
}

@MainActor
func run() async {
    let corpus: Corpus
    do { corpus = try loadCorpus() }
    catch { print("corpus load failed: \(error)"); exit(2) }

    let clf = OpenClickyIntentClassifier.shared
    let ok = await clf.bootstrap()
    guard ok else {
        print("""
        bootstrap FAILED — head.json not found via Bundle.main.

        For a CLI binary, Bundle.main.resourcePath is the binary's own
        directory, so the assets must sit beside the executable:
            ln -s <repo>/AppResources/OpenClicky/mirage-routelet \\
                  .build/debug/mirage-routelet
        """)
        exit(2)
    }

    let arms: [(String, (Item) -> String)] = [
        ("1 zh-raw      ", { $0.arm1_zh_raw }),
        ("2 zh-grounded ", { $0.arm2_zh_grounded }),
        ("3 en-grounded ", { $0.arm3_en_grounded }),
        ("4 en-raw CTRL ", { $0.arm4_en_raw }),
    ]

    var results: [ArmResult] = []
    var misses: [(arm: String, text: String, gold: String, got: String, conf: Float)] = []

    for (name, pick) in arms {
        var r = ArmResult(name: name)
        for item in corpus.items {
            let text = pick(item)
            r.total += 1
            var bucket = r.perIntent[item.gold] ?? (0, 0)
            bucket.n += 1

            guard let pred = await clf.classify(text) else {
                r.nilResult += 1
                r.perIntent[item.gold] = bucket
                continue
            }
            r.confSum += Double(pred.confidence)
            let got = pred.intent.rawValue
            if got == "none" { r.none += 1 }
            if got == item.gold {
                r.correct += 1
                bucket.hit += 1
            } else {
                misses.append((name.trimmingCharacters(in: .whitespaces),
                               text, item.gold, got, pred.confidence))
            }
            r.perIntent[item.gold] = bucket
        }
        results.append(r)
    }

    // ---- report ----
    print("\nGate A — routelet accuracy by input arm  (n=\(corpus.items.count))\n")
    print("arm             acc     none%   meanConf  nil")
    print("--------------------------------------------------")
    for r in results {
        print(String(format: "%@  %5.1f%%  %5.1f%%     %.3f   %d",
                     r.name, r.accuracy * 100, r.noneRate * 100, r.meanConf, r.nilResult))
    }

    let intents = ["chat", "find_action", "integration", "memory"]
    print("\nper-intent accuracy")
    print("arm             " + intents.map { $0.padding(toLength: 13, withPad: " ", startingAt: 0) }.joined())
    for r in results {
        var line = r.name + "  "
        for i in intents {
            let b = r.perIntent[i] ?? (0, 0)
            let pct = b.n == 0 ? 0 : Double(b.hit) / Double(b.n) * 100
            line += String(format: "%5.0f%% (%d/%d) ", pct, b.hit, b.n)
        }
        print(line)
    }

    // ---- verdict ----
    let a1 = results[0].accuracy, a2 = results[1].accuracy
    let a3 = results[2].accuracy, a4 = results[3].accuracy

    print("\n" + String(repeating: "=", count: 50))
    if a4 < 0.60 {
        print("""
        HARNESS BROKEN — control arm (en-raw) scored \(Int(a4 * 100))%.

        These are routelet's own holdout lines; the published model scores
        far higher. Something upstream is wrong (ONNX session, vocab lookup,
        head weights). Do NOT read anything into the other arms.
        """)
        exit(3)
    }

    print("control (en-raw) \(Int(a4 * 100))% — harness sane, other arms are meaningful.\n")
    print(String(format: "zh-raw       %.0f%%", a1 * 100))
    print(String(format: "zh-grounded  %.0f%%  (delta vs zh-raw: %+.0f pts)", a2 * 100, (a2 - a1) * 100))
    print(String(format: "en-grounded  %.0f%%  (delta vs zh-raw: %+.0f pts)", a3 * 100, (a3 - a1) * 100))

    print("\nreading:")
    if a3 - a1 >= 0.25 {
        print("  * en-grounded is a large win over zh-raw. An E4B frontend that")
        print("    emits grounded ENGLISH makes routelet usable for Chinese input.")
    } else if a3 - a1 >= 0.10 {
        print("  * en-grounded helps moderately. Worth having, not decisive alone.")
    } else {
        print("  * en-grounded does not rescue Chinese input. Retraining on a")
        print("    multilingual base is the only real fix.")
    }
    if a2 - a1 >= 0.10 {
        print("  * zh-grounded also helps — some signal survives the English vocab.")
    } else {
        print("  * zh-grounded ~= zh-raw: the English vocab is the binding")
        print("    constraint, not deixis. Grounding alone cannot fix Chinese.")
    }
    if a3 >= a4 - 0.10 {
        print("  * en-grounded reaches control-arm level: grounding costs nothing")
        print("    in accuracy versus naturally-written English.")
    }

    if !misses.isEmpty {
        print("\nmisclassifications (first 24 of \(misses.count)):")
        for m in misses.prefix(24) {
            print(String(format: "  [%@] %@\n      gold=%@ got=%@ conf=%.2f",
                         m.arm, m.text, m.gold, m.got, m.conf))
        }
    }
}

await run()
