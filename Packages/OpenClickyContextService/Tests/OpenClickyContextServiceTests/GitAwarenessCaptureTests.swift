// OpenClicky-unique capability. See docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 30.
//
// Filesystem fixtures live under NSTemporaryDirectory() and are torn down
// in tearDown. Every test that mutates a real git repo skips itself if
// `git` is not on PATH so CI / minimal dev boxes stay green.

import XCTest
@testable import OpenClickyContextService

final class GitAwarenessCaptureTests: XCTestCase {

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

    private func makeTempDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent(
            "openclicky-gitawareness-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        tempRoots.append(dir)
        // On macOS the temp dir often lives under /var, a symlink to
        // /private/var. Resolve so path comparisons match git's toplevel.
        return dir.resolvingSymlinksInPath()
    }

    private func gitAvailable() -> Bool {
        return runShell("/usr/bin/env", args: ["which", "git"]).status == 0
    }

    @discardableResult
    private func runGit(_ args: [String], cwd: URL) throws -> ShellResult {
        let result = runShell(
            "/usr/bin/env",
            args: ["git"] + args,
            cwd: cwd,
            env: [
                "GIT_AUTHOR_NAME": "OpenClicky Test",
                "GIT_AUTHOR_EMAIL": "test@openclicky.local",
                "GIT_COMMITTER_NAME": "OpenClicky Test",
                "GIT_COMMITTER_EMAIL": "test@openclicky.local",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
                "LANG": "C"
            ]
        )
        return result
    }

    private struct ShellResult { let status: Int32; let stdout: String }

    private func runShell(
        _ launchPath: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil
    ) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        if let env = env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ShellResult(status: -1, stdout: "")
        }
        p.waitUntilExit()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        return ShellResult(
            status: p.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func touch(_ url: URL, contents: String = "") throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Creates a fresh repo with an initial commit on branch `main`.
    /// Skips the test if git is missing.
    private func makeRepo(
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> URL? {
        guard gitAvailable() else {
            throw XCTSkip("git not on PATH")
        }
        let dir = try makeTempDir()
        _ = try runGit(["init", "-q", "-b", "main"], cwd: dir)
        try touch(dir.appendingPathComponent("README.md"), contents: "hello\n")
        _ = try runGit(["add", "README.md"], cwd: dir)
        _ = try runGit(["commit", "-q", "-m", "initial"], cwd: dir)
        return dir
    }

    // MARK: - Basic shape

    func test_probe_nonRepoPath_returnsNil() throws {
        let dir = try makeTempDir()
        XCTAssertNil(GitAwarenessCapture.probe(dir))
    }

    func test_probe_missingPath_returnsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openclicky-git-missing-\(UUID().uuidString)")
        XCTAssertNil(GitAwarenessCapture.probe(missing))
    }

    func test_probe_freshRepo_reportsCleanState() throws {
        guard let dir = try makeRepo() else { return }

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))

        XCTAssertEqual(URL(fileURLWithPath: info.repoRoot).resolvingSymlinksInPath().path,
                       dir.resolvingSymlinksInPath().path)
        XCTAssertEqual(info.currentBranch, "main")
        XCTAssertFalse(info.detachedHead)
        XCTAssertFalse(info.isDirty)
        XCTAssertEqual(info.untrackedCount, 0)
        XCTAssertEqual(info.modifiedCount, 0)
        XCTAssertEqual(info.stagedCount, 0)
        XCTAssertEqual(info.stashCount, 0)
        // No upstream configured in an offline test repo.
        XCTAssertNil(info.aheadOfUpstream)
        XCTAssertNil(info.behindUpstream)
        XCTAssertNotNil(info.lastCommitSha)
        XCTAssertEqual(info.lastCommitSha?.count, 7)
        XCTAssertEqual(info.lastCommitSubject, "initial")
        XCTAssertNotNil(info.lastCommitTimestamp)
    }

    func test_probe_fromSubdirectory_findsRoot() throws {
        guard let dir = try makeRepo() else { return }
        let sub = dir.appendingPathComponent("nested/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let info = try XCTUnwrap(GitAwarenessCapture.probe(sub))

        XCTAssertEqual(URL(fileURLWithPath: info.repoRoot).resolvingSymlinksInPath().path,
                       dir.resolvingSymlinksInPath().path)
    }

    // MARK: - Dirty flag flavours

    func test_probe_untrackedFile() throws {
        guard let dir = try makeRepo() else { return }
        try touch(dir.appendingPathComponent("new.txt"), contents: "x")

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))
        XCTAssertTrue(info.isDirty)
        XCTAssertEqual(info.untrackedCount, 1)
        XCTAssertEqual(info.modifiedCount, 0)
        XCTAssertEqual(info.stagedCount, 0)
    }

    func test_probe_modifiedFile() throws {
        guard let dir = try makeRepo() else { return }
        try touch(dir.appendingPathComponent("README.md"), contents: "hello world\n")

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))
        XCTAssertTrue(info.isDirty)
        XCTAssertEqual(info.modifiedCount, 1)
        XCTAssertEqual(info.untrackedCount, 0)
        XCTAssertEqual(info.stagedCount, 0)
    }

    func test_probe_stagedFile() throws {
        guard let dir = try makeRepo() else { return }
        try touch(dir.appendingPathComponent("staged.txt"), contents: "s")
        _ = try runGit(["add", "staged.txt"], cwd: dir)

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))
        XCTAssertTrue(info.isDirty)
        XCTAssertEqual(info.stagedCount, 1)
        XCTAssertEqual(info.modifiedCount, 0)
        XCTAssertEqual(info.untrackedCount, 0)
    }

    // MARK: - Stash

    func test_probe_stash_isCounted() throws {
        guard let dir = try makeRepo() else { return }
        try touch(dir.appendingPathComponent("README.md"), contents: "changed\n")
        _ = try runGit(["stash", "push", "-q", "-m", "wip"], cwd: dir)

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))
        XCTAssertEqual(info.stashCount, 1)
        // Stash restored the tree to a clean state.
        XCTAssertFalse(info.isDirty)
    }

    // MARK: - Detached HEAD

    func test_probe_detachedHead() throws {
        guard let dir = try makeRepo() else { return }
        // Add a second commit so we have something to detach onto.
        try touch(dir.appendingPathComponent("two.txt"), contents: "2")
        _ = try runGit(["add", "two.txt"], cwd: dir)
        _ = try runGit(["commit", "-q", "-m", "second"], cwd: dir)
        // Detach onto the current tip.
        let rev = try runGit(["rev-parse", "HEAD"], cwd: dir)
        let sha = rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runGit(["checkout", "-q", "--detach", sha], cwd: dir)

        let info = try XCTUnwrap(GitAwarenessCapture.probe(dir))
        XCTAssertTrue(info.detachedHead)
        XCTAssertNil(info.currentBranch)
    }

    // MARK: - Codable round-trip

    func test_gitAwarenessInfo_roundTripsJSON() throws {
        let sample = GitAwarenessInfo(
            repoRoot: "/tmp/example",
            currentBranch: "feature/x",
            detachedHead: false,
            isDirty: true,
            untrackedCount: 1,
            modifiedCount: 2,
            stagedCount: 3,
            stashCount: 4,
            aheadOfUpstream: 5,
            behindUpstream: 6,
            lastCommitSha: "abc1234",
            lastCommitSubject: "hello",
            lastCommitTimestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GitAwarenessInfo.self, from: encoded)
        XCTAssertEqual(decoded, sample)
    }

    // MARK: - Performance / timeout budget

    /// A giant tracked-file repo must still return within the timeout
    /// budget (3s per call, ~5s wall-clock for the whole probe on a
    /// reasonable dev box). This is a smoke test for the timeout path
    /// — we don't attempt to force a real timeout because that would
    /// require a hostile git shim; instead we make sure the happy-path
    /// budget covers a large-ish repo.
    func test_probe_largeRepo_returnsWithinBudget() throws {
        guard let dir = try makeRepo() else { return }
        let fm = FileManager.default
        // 500 files is plenty to make sure porcelain output has scale
        // without slowing the suite. We generate then commit them so
        // the working tree is clean afterwards.
        for i in 0..<500 {
            try touch(dir.appendingPathComponent("f-\(i).txt"), contents: "x")
        }
        _ = try runGit(["add", "-A"], cwd: dir)
        _ = try runGit(["commit", "-q", "-m", "bulk"], cwd: dir)
        // Sanity: they exist.
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("f-499.txt").path))

        let start = Date()
        let info = GitAwarenessCapture.probe(dir)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNotNil(info)
        XCTAssertLessThan(elapsed, 5.0, "probe took \(elapsed)s, expected <5s")
    }
}
