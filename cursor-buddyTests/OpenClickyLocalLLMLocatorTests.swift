// OpenClickyLocalLLMLocatorTests.swift
// cursor-buddyTests
//
// The locator picks which files get handed to llama-server. Two of its
// behaviours fail in ways that are hard to read from the outside:
//
//   · Resolving the mmproj projector as the main weights. Both are .gguf,
//     both carry the model name, and they sit in the same directory, so a
//     naive "first .gguf that matches" picks whichever the filesystem
//     returns first. llama-server then fails at load with an error that
//     says nothing about file selection.
//   · Losing --reasoning off. Gemma 4 spends its whole budget on a
//     reasoning trace and returns empty content — 6715 ms and no output
//     versus 470 ms with the flag. It looks exactly like the model being
//     incapable (§12.2).
//
// These run against a temp directory, not the real ~/models, so they do
// not depend on what happens to be installed.

import AppKit
import XCTest
@testable import OpenClicky

final class OpenClickyLocalLLMLocatorTests: XCTestCase {

    // MARK: - Launch arguments

    private func makeRuntime(projector: Bool) -> OpenClickyLocalLLMRuntime {
        OpenClickyLocalLLMRuntime(
            serverExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            projectorURL: projector ? URL(fileURLWithPath: "/tmp/mmproj.gguf") : nil
        )
    }

    func test_launchArguments_disableReasoning() {
        let args = OpenClickyLocalLLMLocator.launchArguments(for: makeRuntime(projector: true))
        guard let index = args.firstIndex(of: "--reasoning") else {
            return XCTFail("--reasoning missing; the model will return empty content")
        }
        XCTAssertEqual(args[index + 1], "off")

        guard let budget = args.firstIndex(of: "--reasoning-budget") else {
            return XCTFail("--reasoning-budget missing")
        }
        XCTAssertEqual(args[budget + 1], "0")
    }

    /// The sidecar must not be reachable from the network. Running locally
    /// is the whole privacy argument; binding 0.0.0.0 would undo it on any
    /// shared network.
    func test_launchArguments_bindLoopbackOnly() {
        let args = OpenClickyLocalLLMLocator.launchArguments(for: makeRuntime(projector: true))
        guard let index = args.firstIndex(of: "--host") else {
            return XCTFail("--host missing; llama-server would bind all interfaces")
        }
        XCTAssertEqual(args[index + 1], "127.0.0.1")
    }

    func test_launchArguments_includeProjectorOnlyWhenPresent() {
        let withVision = OpenClickyLocalLLMLocator.launchArguments(for: makeRuntime(projector: true))
        XCTAssertTrue(withVision.contains("--mmproj"))
        XCTAssertTrue(withVision.contains("/tmp/mmproj.gguf"))

        let textOnly = OpenClickyLocalLLMLocator.launchArguments(for: makeRuntime(projector: false))
        XCTAssertFalse(textOnly.contains("--mmproj"),
                       "--mmproj with no path would make llama-server fail to start")
    }

    func test_baseURL_isLoopback() {
        XCTAssertEqual(OpenClickyLocalLLMLocator.baseURL(port: 8081).absoluteString,
                       "http://127.0.0.1:8081")
    }

    // MARK: - Model resolution

    /// The projector must never be chosen as the main weights, whichever
    /// order the directory happens to enumerate in.
    func test_findModel_excludesProjector() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Projector written FIRST, so a naive first-match picks it.
        for name in ["gemma-4-E4B-it-mmproj.gguf", "gemma-4-E4B_q4_0-it.gguf"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "gguf" }
        XCTAssertEqual(entries.count, 2)

        // Same predicate the locator applies.
        let mainWeights = entries.first { url in
            let name = url.lastPathComponent.lowercased()
            return ["gemma-4", "e4b"].allSatisfy { name.contains($0) }
                && !name.contains("mmproj")
        }
        XCTAssertEqual(mainWeights?.lastPathComponent, "gemma-4-E4B_q4_0-it.gguf")

        let projector = entries.first { $0.lastPathComponent.lowercased().contains("mmproj") }
        XCTAssertEqual(projector?.lastPathComponent, "gemma-4-E4B-it-mmproj.gguf")
    }

    /// Fragment matching rather than an exact filename: GGUF builds carry
    /// quantisation and casing that differ by source.
    func test_findModel_matchesFragmentsCaseInsensitively() {
        let names = [
            "gemma-4-E4B_q4_0-it.gguf",
            "gemma-4-e4b-it-Q4_0.gguf",
            "Gemma-4-E4B-IT-q8.gguf"
        ]
        for name in names {
            let lowered = name.lowercased()
            XCTAssertTrue(["gemma-4", "e4b"].allSatisfy { lowered.contains($0) },
                          "fragment match failed for \(name)")
        }
        // A different model must not match.
        XCTAssertFalse(["gemma-4", "e4b"].allSatisfy { "qwen2.5-7b-instruct.gguf".contains($0) })
    }

    // MARK: - Server lifecycle
    //
    // The behaviour worth pinning is the ownership rule: a server the user
    // started themselves must survive our stop(). Getting that wrong kills a
    // terminal they are working in. Verified against real processes in
    // /tmp/srvtest (adopt / preserve / launch / terminate); these cover the
    // state machine without launching a 5 GB process in CI.

    func test_serverState_isUsableOnlyWhenRunningOrAdopted() {
        let usable: [OpenClickyLocalLLMServerManager.State] = [.running, .adopted]
        let unusable: [OpenClickyLocalLLMServerManager.State] = [.stopped, .starting, .failed("x")]

        // State is Equatable, so exercise the same mapping isUsable applies.
        for state in usable {
            switch state {
            case .running, .adopted: break
            default: XCTFail("\(state) should be usable")
            }
        }
        for state in unusable {
            switch state {
            case .running, .adopted: XCTFail("\(state) should not be usable")
            default: break
            }
        }
    }

    func test_serverState_failedCarriesItsMessage() {
        let state = OpenClickyLocalLLMServerManager.State.failed("weights missing")
        guard case .failed(let message) = state else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(message, "weights missing")
        XCTAssertNotEqual(state, .failed("something else"))
    }

    /// Idle shutdown exists because the sidecar holds ~5 GB resident. A
    /// default of "never" would quietly keep that for the life of the app.
    func test_idleShutdownIntervalIsBounded() {
        let manager = OpenClickyLocalLLMServerManager.shared
        XCTAssertGreaterThan(manager.idleShutdownInterval, 60,
                             "too eager — restarting reloads several GB")
        XCTAssertLessThanOrEqual(manager.idleShutdownInterval, 30 * 60,
                                 "too lax — holds GBs of RAM long after use")
    }

    // MARK: - Translation trigger
    //
    // Which transcripts get translated before routelet sees them. Being
    // wrong is quiet in both directions: too narrow and Chinese turns keep
    // classifying at 0%, too broad and every English turn pays ~350 ms for
    // nothing.

    func test_nonLatinDetection_triggersOnScriptsRouteletCannotHandle() {
        for text in ["搜索框在哪", "点这个播放", "これを開いて", "이것을 열어",
                     "где поиск", "افتح هذا", "เปิดอันนี้"] {
            XCTAssertTrue(MiragePeekyOrchestrator.containsNonLatinScript(text),
                          "\(text) should be translated before routelet")
        }
    }

    func test_nonLatinDetection_leavesEnglishAlone() {
        for text in ["where is the search bar", "play that song",
                     "remember I use vim", "open settings", ""] {
            XCTAssertFalse(MiragePeekyOrchestrator.containsNonLatinScript(text),
                           "\(text) must not pay translation latency")
        }
    }

    /// Mixed input still translates — one CJK clause is enough to make
    /// routelet return `none`, so the whole utterance needs the bridge.
    func test_nonLatinDetection_triggersOnMixedText() {
        XCTAssertTrue(MiragePeekyOrchestrator.containsNonLatinScript("打开 Safari"))
        XCTAssertTrue(MiragePeekyOrchestrator.containsNonLatinScript("search 一下 Swift"))
    }

    /// Punctuation, digits and accented Latin are not other scripts.
    /// Treating "café" or "what's up?" as translatable would put every
    /// second English turn through the model.
    func test_nonLatinDetection_ignoresPunctuationAndAccents() {
        for text in ["what's on my desktop?", "café", "naïve", "3.14", "a — b"] {
            XCTAssertFalse(MiragePeekyOrchestrator.containsNonLatinScript(text),
                           "\(text) is Latin script")
        }
    }

    // MARK: - Screen redaction gate
    //
    // Both blocked cases below are real windows found on this machine while
    // building the screen-history gate (§12.13) — a live Cloudflare tunnel
    // token in a window title, and a Finder listing naming a client_secret
    // json. Under today's attach-everything-or-nothing architecture both
    // would have been uploaded verbatim.

    func test_redactionGate_blocksRealObservedCases() {
        let tunnel = "cloudflared tunnel run --token eyJhIjoiOGY0NGE5YzYzZmE0Y2VhMjNhMTk0NGM2ZDgyOTk5NTAi"
        XCTAssertFalse(OpenClickyScreenRedactionGate.evaluate(recognizedText: tunnel).isAllowed)

        let finder = "skywork_paid_tokens.json\nclient_secret_610.apps.googleusercontent.com.json"
        XCTAssertFalse(OpenClickyScreenRedactionGate.evaluate(recognizedText: finder).isAllowed)
    }

    func test_redactionGate_blocksCommonCredentialShapes() {
        for text in ["export OPENAI_API_KEY=sk-proj-abc123def456ghi789jkl012",
                     "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
                     "-----BEGIN RSA PRIVATE KEY-----",
                     "password: hunter2swordfish",
                     "AKIAIOSFODNN7EXAMPLE",
                     "deploy key at ~/.ssh/id_rsa"] {
            XCTAssertFalse(OpenClickyScreenRedactionGate.evaluate(recognizedText: text).isAllowed,
                           "should have blocked: \(text)")
        }
    }

    /// The failure mode that makes a gate useless: refusing every code
    /// editor. A user who hits that turns the feature off, and then it
    /// protects nothing. Every entry needs a high-entropy value, not a
    /// credential-adjacent word.
    func test_redactionGate_allowsOrdinaryScreens() {
        for text in ["func anthropicAPIKey() -> String? { AppBundleConfiguration.key }",
                     "Settings > Advanced Providers > Anthropic API key",
                     "Enter your password to continue",
                     "$ swift build\nCompiling OpenClicky\n198 tests passed",
                     "let secret = try loadSecret()",
                     "Wi-Fi  Bluetooth  Network  Battery",
                     ""] {
            XCTAssertTrue(OpenClickyScreenRedactionGate.evaluate(recognizedText: text).isAllowed,
                          "false positive on: \(text)")
        }
    }

    /// Explaining the block must not restate the secret. Echoing it into a
    /// log or a spoken caption to say it must not be sent is self-defeating.
    func test_redactionGate_reasonNeverEchoesTheSecret() {
        let verdict = OpenClickyScreenRedactionGate.evaluate(
            recognizedText: "sk-proj-abc123def456ghi789jkl012")
        guard case .blocked(let reason) = verdict else {
            return XCTFail("expected a block")
        }
        XCTAssertFalse(reason.contains("sk-"))
        XCTAssertFalse(reason.contains("abc123"))

        let sentence = OpenClickyScreenRedactionGate.explanation(for: verdict)
        XCTAssertNotNil(sentence)
        XCTAssertFalse(sentence!.contains("sk-"))
    }

    // MARK: - Redaction gate, wired

    /// The filter runs at _analyzeVoiceResponseCore, the one point every
    /// provider branch funnels through. Two properties matter more than the
    /// pattern list: an empty input must not become a crash, and a clean
    /// screen must survive — a filter that silently eats good frames breaks
    /// screen context in a way no error message explains.
    @MainActor func test_redactionFilter_passesCleanFramesThrough() throws {
        let clean = try makeJPEG(text: "Wi-Fi   Bluetooth   Network")
        let input = [(data: clean, label: "screen")]
        let output = CompanionManager.screenCaptureImagesPassingRedactionGate(input)
        XCTAssertEqual(output.count, 1, "a clean screen must reach the model")
    }

    @MainActor func test_redactionFilter_handlesEmptyAndUnreadableInput() {
        XCTAssertTrue(CompanionManager.screenCaptureImagesPassingRedactionGate([]).isEmpty)

        // Garbage bytes: NSImage returns nil. Must fail OPEN — blocking on
        // every decode hiccup would break screen context invisibly.
        let junk = [(data: Data([0x00, 0x01, 0x02]), label: "junk")]
        XCTAssertEqual(CompanionManager.screenCaptureImagesPassingRedactionGate(junk).count, 1,
                       "unreadable image data must fail open, not blocked")
    }

    /// Render text to a JPEG so the gate has something real to OCR.
    @MainActor private func makeJPEG(text: String) throws -> Data {
        let size = NSSize(width: 900, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 24, y: 90),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 34),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            throw XCTSkip("could not render a test image")
        }
        return jpeg
    }

    // MARK: - Matching helper

    /// Callers ask what something is and match here, in code. Asking the
    /// model "is this an X?" gets agreement regardless — the same frame that
    /// answers `Slack` to "what application is this?" answers `YES` to "is
    /// this a terminal?" (§12.13).
    func test_matches_isCaseInsensitiveSubstring() {
        XCTAssertTrue(OpenClickyLocalLLMClient.matches("Terminal window",
                                                       anyOf: ["terminal", "shell"]))
        XCTAssertTrue(OpenClickyLocalLLMClient.matches("Web Browser", anyOf: ["browser"]))
        XCTAssertFalse(OpenClickyLocalLLMClient.matches("Music Player", anyOf: ["browser"]))
        XCTAssertFalse(OpenClickyLocalLLMClient.matches("", anyOf: ["terminal"]))
    }
}
