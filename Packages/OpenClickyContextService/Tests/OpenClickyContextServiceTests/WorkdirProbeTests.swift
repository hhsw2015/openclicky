// OpenClicky-unique capability (no Everywhere source). See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 27.
//
// XCTest coverage for WorkdirProbe. All filesystem fixtures are created
// under `NSTemporaryDirectory()` and torn down in `tearDown` so the tests
// remain hermetic and safe to run under `swift test` on CI.

import XCTest
@testable import OpenClickyContextService

final class WorkdirProbeTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for root in tempRoots {
            try? fm.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a fresh, unique directory under `NSTemporaryDirectory()`
    /// and records it for teardown.
    private func makeTempDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "openclicky-workdirprobe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        tempRoots.append(dir)
        return dir
    }

    /// Writes a zero- or trivially-sized file at the given path.
    private func touch(_ url: URL, contents: String = "") throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Creates a sub-directory (recursively) at the given URL.
    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }

    // MARK: - Existence / shape

    func test_probe_nonExistentPath() {
        let missing = URL(
            fileURLWithPath: NSTemporaryDirectory()
        ).appendingPathComponent("openclicky-does-not-exist-\(UUID().uuidString)")

        let result = WorkdirProbe.probe(missing)

        XCTAssertEqual(result.path, missing.path)
        XCTAssertFalse(result.exists)
        XCTAssertFalse(result.isDirectory)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(result.detectedProjectType, .unknown)
        XCTAssertFalse(result.hasGit)
        XCTAssertFalse(result.hasOpenClickyState)
        XCTAssertFalse(result.hasAgentsMd)
    }

    func test_probe_regularFile() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("README.md")
        try touch(file, contents: "hello")

        let result = WorkdirProbe.probe(file)

        XCTAssertTrue(result.exists)
        XCTAssertFalse(result.isDirectory)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(result.detectedProjectType, .unknown)
    }

    func test_probe_emptyDirectory() throws {
        let dir = try makeTempDir()

        let result = WorkdirProbe.probe(dir)

        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isDirectory)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(result.detectedProjectType, .unknown)
    }

    func test_probe_dsStoreOnlyStillEmpty() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent(".DS_Store"), contents: "junk")

        let result = WorkdirProbe.probe(dir)

        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isDirectory)
        XCTAssertTrue(result.isEmpty, ".DS_Store must be ignored for isEmpty")
        XCTAssertEqual(result.fileCount, 0, ".DS_Store must be ignored in fileCount")
    }

    // MARK: - Project type detection

    func test_probe_rustProject() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("Cargo.toml"), contents: "[package]\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .rust)
    }

    func test_probe_swiftPackage() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("Package.swift"), contents: "// swift-tools-version: 5.9\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .swift)
    }

    func test_probe_xcodeProject() throws {
        let dir = try makeTempDir()
        try mkdir(dir.appendingPathComponent("MyApp.xcodeproj"))

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .xcode)
    }

    func test_probe_xcodeWorkspace() throws {
        let dir = try makeTempDir()
        try mkdir(dir.appendingPathComponent("MyApp.xcworkspace"))

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .xcode)
    }

    func test_probe_xcodeWinsOverSwiftPackage() throws {
        let dir = try makeTempDir()
        try mkdir(dir.appendingPathComponent("MyApp.xcodeproj"))
        try touch(dir.appendingPathComponent("Package.swift"))

        XCTAssertEqual(
            WorkdirProbe.probe(dir).detectedProjectType, .xcode,
            "Xcode project bundle must win over Package.swift"
        )
    }

    func test_probe_nodejsProject() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("package.json"), contents: "{}")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .nodejs)
    }

    func test_probe_goProject() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("go.mod"), contents: "module x\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .go)
    }

    func test_probe_pythonPyprojectToml() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("pyproject.toml"), contents: "[project]\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .python)
    }

    func test_probe_pythonRequirementsTxt() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("requirements.txt"), contents: "requests\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .python)
    }

    func test_probe_pythonSetupPy() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("setup.py"), contents: "from setuptools import setup\n")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .python)
    }

    func test_probe_unknownProject() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("random.txt"), contents: "just a note")

        XCTAssertEqual(WorkdirProbe.probe(dir).detectedProjectType, .unknown)
    }

    // MARK: - Marker files

    func test_probe_hasGit() throws {
        let dir = try makeTempDir()
        try mkdir(dir.appendingPathComponent(".git"))

        let result = WorkdirProbe.probe(dir)

        XCTAssertTrue(result.hasGit)
        XCTAssertFalse(result.hasOpenClickyState)
        XCTAssertFalse(result.hasAgentsMd)
    }

    func test_probe_hasOpenClickyState() throws {
        let dir = try makeTempDir()
        try mkdir(dir.appendingPathComponent(".openclicky"))

        let result = WorkdirProbe.probe(dir)

        XCTAssertTrue(result.hasOpenClickyState)
        XCTAssertFalse(result.hasGit)
        XCTAssertFalse(result.hasAgentsMd)
    }

    func test_probe_hasAgentsMd() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent("AGENTS.md"), contents: "# Agents\n")

        let result = WorkdirProbe.probe(dir)

        XCTAssertTrue(result.hasAgentsMd)
        XCTAssertFalse(result.hasGit)
        XCTAssertFalse(result.hasOpenClickyState)
    }

    // MARK: - Counting

    func test_probe_fileCountIncludesDotFiles() throws {
        let dir = try makeTempDir()
        try touch(dir.appendingPathComponent(".env"), contents: "SECRET=1")
        try touch(dir.appendingPathComponent("README.md"), contents: "hi")
        try mkdir(dir.appendingPathComponent(".git"))
        try touch(dir.appendingPathComponent(".DS_Store"), contents: "junk")

        let result = WorkdirProbe.probe(dir)

        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.fileCount, 3, "dot-files count, .DS_Store does not")
        XCTAssertTrue(result.hasGit)
    }

    // MARK: - Codable round-trip

    func test_workdirProbeResult_roundTripsJSON() throws {
        let sample = WorkdirProbeResult(
            path: "/tmp/example",
            exists: true,
            isDirectory: true,
            isEmpty: false,
            fileCount: 4,
            detectedProjectType: .rust,
            hasGit: true,
            hasOpenClickyState: false,
            hasAgentsMd: true
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WorkdirProbeResult.self, from: data)
        XCTAssertEqual(decoded, sample)
    }
}
