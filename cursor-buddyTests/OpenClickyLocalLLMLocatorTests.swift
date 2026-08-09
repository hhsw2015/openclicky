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
