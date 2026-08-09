//
//  OpenClickyLocalLLMLocator.swift
//  cursor-buddy
//
//  Finds an already-installed llama.cpp server and the GGUF weights it
//  needs. Does NOT package a runtime — same contract as
//  OpenClickyProviderDiscovery ("only probes what is already installed").
//
//  Why a sidecar rather than a vendored library: CLAUDE.md's inference
//  routing section states the discovery layer must auto-detect installed
//  CLIs and not package runtimes. Vendoring llama.cpp as a dylib, or
//  bundling llama-server, are both packaging. The app already spawns six
//  external runtimes, so an HTTP sidecar is the established shape.
//
//  Model provisioning stays manual for now. The download service exists
//  (OpenClickyLocalModelDownloadService) but only fetches and checksums;
//  wiring it to this locator is a separate step and deliberately not done
//  here.
//

import Foundation

/// Where a local multimodal model can be reached, and what it needs.
nonisolated struct OpenClickyLocalLLMRuntime: Equatable, Sendable {
    /// `llama-server` executable.
    let serverExecutable: URL
    /// Main GGUF weights.
    let modelURL: URL
    /// Multimodal projector. Required for vision; absent means text-only.
    let projectorURL: URL?

    var supportsVision: Bool { projectorURL != nil }
}

nonisolated enum OpenClickyLocalLLMLocator {

    /// Default port for the sidecar. Deliberately not 8080 (commonly taken)
    /// and not 32123 (OpenClickyExternalControlBridge.defaultPort).
    static let defaultPort: UInt16 = 8081

    /// Environment overrides, so a developer can point at another build or
    /// another set of weights without touching Settings.
    static let executableOverrideKey = "OPENCLICKY_LLAMA_SERVER"
    static let modelOverrideKey = "OPENCLICKY_LOCAL_MODEL"
    static let projectorOverrideKey = "OPENCLICKY_LOCAL_MMPROJ"

    // MARK: - Executable

    /// Locate `llama-server`. Mirrors the PATH-then-fixed-candidates order
    /// used by `OpenClickyProviderDiscovery.claudeExecutableURL`.
    static func serverExecutableURL(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment[executableOverrideKey],
           fileManager.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map {
                URL(fileURLWithPath: String($0))
                    .appendingPathComponent("llama-server", isDirectory: false)
            }

        let fixedCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/llama-server", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/llama-server", isDirectory: false),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/llama-server", isDirectory: false)
        ]

        return (pathCandidates + fixedCandidates).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    // MARK: - Weights

    /// Directories searched for GGUF weights, in order.
    static func modelSearchDirectories(fileManager: FileManager = .default) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            // Where OpenClickyLocalModelDownloadService puts things.
            home.appendingPathComponent("Library/Application Support/OpenClicky/models",
                                        isDirectory: true),
            // Conventional manual location.
            home.appendingPathComponent("models", isDirectory: true),
            home.appendingPathComponent(".cache/llama.cpp", isDirectory: true)
        ]
    }

    /// Find weights whose file name contains every fragment in `nameContains`
    /// (case-insensitive). Fragments rather than an exact name because GGUF
    /// files carry quantisation and build suffixes that vary by source:
    /// `gemma-4-E4B_q4_0-it.gguf`, `gemma-4-e4b-it-Q4_0.gguf`, and so on.
    static func findModel(
        nameContains fragments: [String],
        excluding excludedFragments: [String] = [],
        fileManager: FileManager = .default
    ) -> URL? {
        for directory in modelSearchDirectories(fileManager: fileManager) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let match = entries
                .filter { $0.pathExtension.lowercased() == "gguf" }
                .first { url in
                    let name = url.lastPathComponent.lowercased()
                    return fragments.allSatisfy { name.contains($0.lowercased()) }
                        && !excludedFragments.contains { name.contains($0.lowercased()) }
                }
            if let match { return match }

            // One level down — downloads often land in a per-model folder.
            let subdirectories = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            for subdirectory in subdirectories {
                guard let nested = try? fileManager.contentsOfDirectory(
                    at: subdirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                if let hit = nested
                    .filter({ $0.pathExtension.lowercased() == "gguf" })
                    .first(where: { url in
                        let name = url.lastPathComponent.lowercased()
                        return fragments.allSatisfy { name.contains($0.lowercased()) }
                            && !excludedFragments.contains { name.contains($0.lowercased()) }
                    }) {
                    return hit
                }
            }
        }
        return nil
    }

    // MARK: - Resolution

    /// Resolve a complete runtime, or nil when anything required is missing.
    ///
    /// `mmproj` is excluded from the main-weights match: the projector sits
    /// beside the model, is also `.gguf`, and also contains the model name,
    /// so without the exclusion it can be picked as the main weights — which
    /// fails at load time with an unhelpful error.
    static func resolve(
        modelNameFragments: [String] = ["gemma-4", "e4b"],
        fileManager: FileManager = .default
    ) -> OpenClickyLocalLLMRuntime? {
        guard let executable = serverExecutableURL(fileManager: fileManager) else { return nil }

        let environment = ProcessInfo.processInfo.environment
        let model: URL?
        if let explicit = environment[modelOverrideKey],
           fileManager.fileExists(atPath: explicit) {
            model = URL(fileURLWithPath: explicit)
        } else {
            model = findModel(nameContains: modelNameFragments,
                              excluding: ["mmproj"],
                              fileManager: fileManager)
        }
        guard let model else { return nil }

        let projector: URL?
        if let explicit = environment[projectorOverrideKey],
           fileManager.fileExists(atPath: explicit) {
            projector = URL(fileURLWithPath: explicit)
        } else {
            projector = findModel(nameContains: modelNameFragments + ["mmproj"],
                                  fileManager: fileManager)
        }

        return OpenClickyLocalLLMRuntime(
            serverExecutable: executable,
            modelURL: model,
            projectorURL: projector
        )
    }

    // MARK: - Launch arguments

    /// Arguments for the sidecar.
    ///
    /// `--reasoning off --reasoning-budget 0` is NOT tuning. Left at the
    /// default, Gemma 4 spends its entire token budget on a reasoning trace
    /// and returns empty `content` — measured 6715 ms and no output, versus
    /// 470 ms with the flags. It reads exactly like model incapability. See
    /// docs/parlor-integration-research/05-integration-plan.md §12.2.
    static func launchArguments(
        for runtime: OpenClickyLocalLLMRuntime,
        port: UInt16 = defaultPort,
        contextSize: Int = 8192
    ) -> [String] {
        var arguments = [
            "-m", runtime.modelURL.path,
            "--port", String(port),
            "--ctx-size", String(contextSize),
            "--n-gpu-layers", "99",
            "--reasoning", "off",
            "--reasoning-budget", "0",
            // Bind loopback only. The whole privacy argument for running
            // locally is that frames do not leave the machine; a sidecar
            // listening on 0.0.0.0 would undo that on any shared network.
            "--host", "127.0.0.1"
        ]
        if let projector = runtime.projectorURL {
            arguments += ["--mmproj", projector.path]
        }
        return arguments
    }

    /// Base URL for the running sidecar.
    static func baseURL(port: UInt16 = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
