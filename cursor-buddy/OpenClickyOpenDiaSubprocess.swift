//
//  OpenClickyOpenDiaSubprocess.swift
//  cursor-buddy
//
//  Phase 7.6b F31 — Node subprocess manager for OpenDia browser control.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  OpenDia upstream (MIT) pin recorded in
//  AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA.
//
//  Mirrors F29 (OpenClickyConnectorSubprocess) and F30
//  (OpenClickyOpenCLISubprocess) structurally — stateQueue-guarded
//  Process/Pipe fields, `READY <port>` stdout handshake, `/health`
//  probe, `Authorization: Bearer` on every non-health request. Port
//  range is [56000, 57000).
//
//  This process boots a Node script that owns TWO networking layers:
//    1. Loopback HTTP (Swift <-> Node) — the surface this class talks to.
//    2. WebSocket server (Node <-> Chrome/Firefox extension) — the
//       actual browser-control channel. Swift never speaks WS.
//

import Foundation
import os

/// Structured logger for F31 subprocess lifecycle. Subsystem
/// `com.jkneen.openclicky`, category `Layer7-OpenDia`.
private let f31Log = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-OpenDia")

/// Errors raised by the OpenDia subprocess.
enum OpenClickyOpenDiaSubprocessError: Error, LocalizedError {
    case nodeNotFound
    case bootScriptMissing(URL)
    case launchFailed(String)
    case startupTimeout
    case healthCheckFailed(String)
    case notRunning
    case requestFailed(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            return "Node.js not found. Install with `brew install node` or set the Node path in Settings."
        case .bootScriptMissing(let url):
            return "OpenDiaRuntime/boot.js missing at \(url.path). Reinstall OpenClicky."
        case .launchFailed(let msg):
            return "Failed to launch Node OpenDia subprocess: \(msg)"
        case .startupTimeout:
            return "OpenDia subprocess did not signal READY within 10 seconds."
        case .healthCheckFailed(let msg):
            return "OpenDia subprocess health check failed: \(msg)"
        case .notRunning:
            return "OpenDia subprocess is not running."
        case .requestFailed(let status, let msg):
            return "OpenDia subprocess HTTP \(status): \(msg)"
        case .invalidResponse:
            return "OpenDia subprocess returned a malformed response."
        }
    }
}

/// Manages the OpenDia Node subprocess and provides an HTTP RPC wrapper
/// for `OpenClickyOpenDiaBridgeTools`.
@MainActor
final class OpenClickyOpenDiaSubprocess {
    static let shared = OpenClickyOpenDiaSubprocess()

    // MARK: - Public state

    private(set) var boundPort: Int?
    private(set) var authToken: String = UUID().uuidString

    var localhostURL: URL? {
        guard let port = boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    var isRunning: Bool {
        stateQueue.sync { process?.isRunning == true }
    }

    /// Last announced extension-connected flag from `/health`. Nil until
    /// the first successful health check.
    private(set) var extensionConnected: Bool?
    private(set) var availableToolCount: Int?
    private(set) var lastStatusMessage: String = "idle"
    private var desiredEnabled: Bool = false

    // MARK: - Private state

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private var readyContinuation: CheckedContinuation<Int, Error>?
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.opendia-subprocess")
    /// Consecutive crash count used by the exponential-backoff auto-restart
    /// path in `handleTermination`. Reset on a successful health probe.
    private var restartAttempts: Int = 0
    /// Fail-open cap on auto-restart attempts before we surface a persistent
    /// failure to the settings pane / notification center.
    private static let maxRestartAttempts = 10
    /// Broadcast when the subprocess has given up auto-restarting after
    /// hitting `maxRestartAttempts`. Settings UI listens to surface it.
    static let subprocessFailedNotification = Notification.Name(
        "com.jkneen.openclicky.opendia.subprocess.failed"
    )
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    /// Attempt to launch the Node subprocess. Idempotent.
    func start() async throws {
        desiredEnabled = true
        if isRunning {
            lastStatusMessage = "already running on port \(boundPort ?? 0)"
            return
        }

        let nodeURL = try Self.resolveNodePath()
        let bootURL = try Self.resolveBootScriptURL()

        let bootStartedAt = Date()
        f31Log.info("openclicky.opendia.subprocess.start_attempt node_path=\(nodeURL.path, privacy: .public) port_range=56000-57000 attempt=\(self.restartAttempts, privacy: .public)")

        authToken = UUID().uuidString
        boundPort = nil
        extensionConnected = nil
        availableToolCount = nil
        stdoutBuffer.removeAll()

        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        proc.executableURL = nodeURL
        proc.arguments = [bootURL.path]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["OPENCLICKY_OPENDIA_TOKEN"] = authToken
        env["OPENCLICKY_OPENDIA_PORT_MIN"] = "56000"
        env["OPENCLICKY_OPENDIA_PORT_MAX"] = "57000"
        proc.environment = env

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleTermination(reason: "exit \(terminated.terminationStatus)")
            }
        }

        stateQueue.sync {
            self.process = proc
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            self.stdinPipe = inPipe
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            Task { @MainActor [weak self] in
                self?.appendStdout(chunk)
            }
        }
        let redactionToken = authToken
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            // Defence in depth: the token should never appear on stderr
            // because boot.js does not log it, but redact anyway so a
            // future logging change cannot leak it through Console.app.
            let redacted = text.replacingOccurrences(of: redactionToken, with: "<redacted-token>")
            FileHandle.standardError.write(Data("[opendia] \(redacted)".utf8))
        }

        do {
            try proc.run()
        } catch {
            handleTermination(reason: "launch error: \(error)")
            throw OpenClickyOpenDiaSubprocessError.launchFailed("\(error)")
        }

        let port: Int
        do {
            port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                self.readyContinuation = cont
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                    guard let self else { return }
                    if let waiter = self.readyContinuation {
                        self.readyContinuation = nil
                        waiter.resume(throwing: OpenClickyOpenDiaSubprocessError.startupTimeout)
                    }
                }
            }
        } catch {
            stop()
            throw error
        }

        boundPort = port
        lastStatusMessage = "starting"

        do {
            let health = try await probeHealthWithRetry()
            if let connected = health["extension_connected"] as? Bool {
                extensionConnected = connected
            }
            if let count = health["available_tools"] as? Int {
                availableToolCount = count
            }
            let connectedStr = (extensionConnected == true) ? "ext connected" : "ext not connected"
            lastStatusMessage = "running on port \(port), \(connectedStr)"
            let bootMs = Int(Date().timeIntervalSince(bootStartedAt) * 1000)
            f31Log.info("openclicky.opendia.subprocess.ready port=\(port, privacy: .public) node_path=\(nodeURL.path, privacy: .public) boot_ms=\(bootMs, privacy: .public) ext_connected=\(self.extensionConnected == true, privacy: .public) available_tools=\(self.availableToolCount ?? 0, privacy: .public)")
            f31Log.info("openclicky.opendia.subprocess.health_probe status=ok retry_count=0")
            // Runtime is up end-to-end; clear crash counter so a later
            // failure gets its full backoff budget again.
            restartAttempts = 0
        } catch {
            f31Log.error("openclicky.opendia.subprocess.health_probe status=fail retry_count=3 reason=\(String(describing: error), privacy: .public)")
            stop()
            throw OpenClickyOpenDiaSubprocessError.healthCheckFailed("\(error)")
        }
    }

    /// Poll `/health` up to three times, 500ms apart. Guards against the
    /// race where the HTTP listener is bound but not yet accepting, and
    /// against single-shot transient failures right after boot.
    private func probeHealthWithRetry() async throws -> [String: Any] {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await requestJSON(path: "/health", method: "GET", body: nil)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? OpenClickyOpenDiaSubprocessError.healthCheckFailed("unknown")
    }

    /// Stop the subprocess. Idempotent.
    /// Cancels auto-restart intent, drains stderr/stdout readers, then
    /// waits up to 3s off the caller thread for graceful termination
    /// before falling back to SIGKILL.
    func stop() {
        desiredEnabled = false
        // Reset backoff so the next explicit start() gets a fresh window.
        restartAttempts = 0
        stateQueue.sync {
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
        }
        guard let proc = stateQueue.sync(execute: { self.process }) else { return }
        if proc.isRunning {
            proc.terminate()
            // Wait off the main actor so callers on @MainActor (settings
            // panel toggle etc) don't stall the UI for up to 3s.
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(3)
                while proc.isRunning && Date() < deadline {
                    // 50ms poll — same cadence as the previous impl,
                    // but on a background queue so main isn't blocked.
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        handleTermination(reason: "stop()")
    }

    /// Forward an HTTP request to the Node subprocess. Returns the raw
    /// response body.
    func request(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> Data {
        guard let base = localhostURL else {
            throw OpenClickyOpenDiaSubprocessError.notRunning
        }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw OpenClickyOpenDiaSubprocessError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OpenClickyOpenDiaSubprocessError.requestFailed(-1, "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenClickyOpenDiaSubprocessError.invalidResponse
        }
        if http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenClickyOpenDiaSubprocessError.requestFailed(http.statusCode, text)
        }
        return data
    }

    /// Convenience: JSON dict response.
    func requestJSON(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path: path, method: method, body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClickyOpenDiaSubprocessError.invalidResponse
        }
        return obj
    }

    /// Settings-pane test button entry point. Hits `/health` (with the
    /// same retry policy used at startup) and returns a human-readable
    /// summary. Never throws — packages failures into the string.
    func testConnection() async -> String {
        guard isRunning else { return "Not running." }
        do {
            let health = try await probeHealthWithRetry()
            let connected = (health["extension_connected"] as? Bool) == true
            let count = (health["available_tools"] as? Int) ?? 0
            if connected {
                return "OK — extension connected, \(count) tools."
            }
            return "OK — runtime responding, but no browser extension connected yet."
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }

    /// Invoke one browser_* tool through the Node bridge. Returns the
    /// extension's raw result envelope (opaque JSON).
    func callTool(name: String, arguments: [String: Any], timeoutMs: Int? = nil) async throws -> [String: Any] {
        var body: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        if let t = timeoutMs { body["timeout_ms"] = t }
        return try await requestJSON(path: "/call", method: "POST", body: body)
    }

    // MARK: - Termination

    private func handleTermination(reason: String) {
        stateQueue.sync {
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.stdinPipe = nil
        }
        boundPort = nil
        extensionConnected = nil
        availableToolCount = nil
        lastStatusMessage = "stopped (\(reason))"

        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: OpenClickyOpenDiaSubprocessError.launchFailed(reason))
        }

        if desiredEnabled {
            // Exponential backoff capped at 60s: 2, 4, 8, 16, 32, 60, 60...
            // Prevents the pre-fix EPERM / bad-config spin loop.
            f31Log.notice("openclicky.opendia.subprocess.crash exit_reason=\(reason, privacy: .public) restart_attempts=\(self.restartAttempts, privacy: .public)")
            if restartAttempts >= Self.maxRestartAttempts {
                let message = "OpenDia runtime failed \(restartAttempts) times; auto-restart disabled."
                lastStatusMessage = message
                NotificationCenter.default.post(
                    name: Self.subprocessFailedNotification,
                    object: self,
                    userInfo: ["reason": reason, "attempts": restartAttempts]
                )
                return
            }
            let attempt = restartAttempts
            restartAttempts += 1
            let base = pow(2.0, Double(min(attempt, 6)))
            let delaySeconds = min(base, 60.0)
            let delayNs = UInt64(delaySeconds * 1_000_000_000)
            f31Log.notice("openclicky.opendia.subprocess.crash backoff_seconds=\(delaySeconds, privacy: .public) next_attempt=\(attempt + 1, privacy: .public)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, self.desiredEnabled else { return }
                try? await self.start()
            }
        }
    }

    // MARK: - stdout parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineRange = stdoutBuffer.range(of: Data([0x0a])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0..<newlineRange.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleStdoutLine(line)
        }
    }

    private func handleStdoutLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("READY ") {
            let parts = trimmed.split(separator: " ")
            if parts.count >= 2, let port = Int(parts[1]),
               let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: port)
                return
            }
        }
    }

    // MARK: - Path resolution

    /// Discover a `node` executable. Order mirrors F29 for consistency.
    static func resolveNodePath() throws -> URL {
        if let override = OpenClickyOpenDiaSettings.shared.nodePathOverride,
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let nvmRoot = URL(fileURLWithPath: NSString("~/.nvm/versions/node").expandingTildeInPath as String)
        if let entries = try? FileManager.default.contentsOfDirectory(at: nvmRoot,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = entries.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            for entry in sorted {
                let candidate = entry.appendingPathComponent("bin/node")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let env = Process()
        env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        env.arguments = ["which", "node"]
        let out = Pipe()
        env.standardOutput = out
        env.standardError = Pipe()
        do {
            try env.run()
            env.waitUntilExit()
            if env.terminationStatus == 0 {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: data, encoding: .utf8) {
                    let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                        return URL(fileURLWithPath: path)
                    }
                }
            }
        } catch {
            // fall through
        }
        throw OpenClickyOpenDiaSubprocessError.nodeNotFound
    }

    /// Resolve `AppResources/OpenClicky/OpenDiaRuntime/boot.js`.
    /// Bundle-first (production), source-tree fallback (dev builds).
    static func resolveBootScriptURL() throws -> URL {
        if let bundleURL = Bundle.main.resourceURL {
            let bundled = bundleURL
                .appendingPathComponent("OpenDiaRuntime")
                .appendingPathComponent("boot.js")
            if FileManager.default.isReadableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()             // cursor-buddy/
            .deletingLastPathComponent()             // openclicky/
            .appendingPathComponent("AppResources/OpenClicky/OpenDiaRuntime/boot.js")
        if FileManager.default.isReadableFile(atPath: devPath.path) {
            return devPath
        }
        throw OpenClickyOpenDiaSubprocessError.bootScriptMissing(devPath)
    }
}
