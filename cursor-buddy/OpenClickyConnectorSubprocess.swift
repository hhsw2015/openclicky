//
//  OpenClickyConnectorSubprocess.swift
//  cursor-buddy
//
//  Phase 7.5 F29 — Node subprocess manager for open-connector.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  Replaces Everywhere's ClearScript V8 isolate with an out-of-process
//  Node.js runtime (documented divergence, see
//  `docs/ROADMAP/.impl-notes/phase7-5-open-connector-2026-07-23.md`).
//
//  Lifecycle:
//    * `start()` finds a `node` binary (settings override, /opt/homebrew,
//      /usr/local, ~/.nvm, PATH), spawns `node boot.js` with a random
//      port in [52000, 53000) + auth token in env, waits for a
//      `READY <port>` line on stdout, then health-checks
//      `GET /health`.
//    * All subsequent requests use `request(path:body:)` which appends
//      the `Authorization: Bearer <token>` header.
//    * `stop()` closes pipes, sends SIGTERM, waits up to 3s, then
//      SIGKILL if the process is still alive.
//    * Crash recovery: `restart()` if the Process termination handler
//      fires while `isDesiredRunning == true` (called from the Settings
//      panel or on an MCP dispatch attempt).
//
//  This class mirrors CodexProcessManager's structure — stateQueue-
//  guarded Process/Pipe fields, stdout line parsing — so future
//  maintainers only need to understand one subprocess shape.
//

import Foundation
import os

/// Structured logger for F29 subprocess lifecycle + bridge dispatch.
/// Emits to the unified logging system so Console.app / `log stream
/// --predicate 'subsystem == "com.jkneen.openclicky"'` can trace boot
/// timing, crash backoff, and tool-call latency for the layer-7 audit.
private let f29Log = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-Connector")

/// Errors raised by the connector subprocess.
enum OpenClickyConnectorSubprocessError: Error, LocalizedError {
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
            return "OpenConnectorRuntime/boot.js missing at \(url.path). Reinstall OpenClicky or run the vendor script."
        case .launchFailed(let msg):
            return "Failed to launch Node connector subprocess: \(msg)"
        case .startupTimeout:
            return "Connector subprocess did not signal READY within 10 seconds."
        case .healthCheckFailed(let msg):
            return "Connector subprocess health check failed: \(msg)"
        case .notRunning:
            return "Connector subprocess is not running."
        case .requestFailed(let status, let msg):
            return "Connector subprocess HTTP \(status): \(msg)"
        case .invalidResponse:
            return "Connector subprocess returned a malformed response."
        }
    }
}

/// Manages the open-connector Node.js subprocess and provides a thin
/// HTTP RPC wrapper for the bridge tools.
@MainActor
final class OpenClickyConnectorSubprocess {
    static let shared = OpenClickyConnectorSubprocess()

    // MARK: - Public state

    /// Random port bound by the subprocess. Nil until `READY` seen.
    private(set) var boundPort: Int?

    /// Auth token generated per launch. Sent as `Authorization: Bearer`.
    private(set) var authToken: String = UUID().uuidString

    /// Full loopback URL, e.g. `http://127.0.0.1:52347`. Nil when not
    /// running.
    var localhostURL: URL? {
        guard let port = boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// True whenever we have a live Process handle. Independent of the
    /// user's Settings toggle — Settings should read `desiredEnabled`.
    var isRunning: Bool {
        stateQueue.sync { process?.isRunning == true }
    }

    /// The last announced provider count from `/health`. Nil until the
    /// first successful health check.
    private(set) var providerCount: Int?

    /// Latest human-readable status string, exposed via
    /// `OpenClickyConnectorSettings` for the UI.
    private(set) var lastStatusMessage: String = "idle"

    /// User's opt-in for the subprocess. When true, crash recovery
    /// attempts a restart; when false, `stop()` is authoritative.
    private var desiredEnabled: Bool = false

    // MARK: - Private state

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private var readyContinuation: CheckedContinuation<Int, Error>?
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.connector-subprocess")
    /// Consecutive crash count used by the exponential-backoff auto-restart
    /// path in `handleTermination`. Reset on a successful health probe.
    private var restartAttempts: Int = 0
    /// Fail-open cap on auto-restart attempts before we surface a persistent
    /// failure to the settings pane / notification center.
    private static let maxRestartAttempts = 10
    /// Broadcast when the subprocess has given up auto-restarting after
    /// hitting `maxRestartAttempts`. Settings UI listens to surface it.
    static let subprocessFailedNotification = Notification.Name(
        "com.jkneen.openclicky.connector.subprocess.failed"
    )
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    /// Attempt to launch the Node subprocess. Idempotent — if already
    /// running, returns immediately.
    func start() async throws {
        desiredEnabled = true
        if isRunning {
            lastStatusMessage = "already running on port \(boundPort ?? 0)"
            return
        }

        let nodeURL = try Self.resolveNodePath()
        let bootURL = try Self.resolveBootScriptURL()
        let callbackURL = OpenClickyConnectorOAuthCallback.shared.localhostURL()

        let bootStartedAt = Date()
        f29Log.info("openclicky.connector.subprocess.start_attempt node_path=\(nodeURL.path, privacy: .public) port_range=52000-53000 attempt=\(self.restartAttempts, privacy: .public)")

        authToken = UUID().uuidString
        boundPort = nil
        providerCount = nil
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
        env["OPENCLICKY_CONNECTOR_TOKEN"] = authToken
        env["OPENCLICKY_CONNECTOR_PORT_MIN"] = "52000"
        env["OPENCLICKY_CONNECTOR_PORT_MAX"] = "53000"
        if let callbackURL {
            env["OPENCLICKY_CONNECTOR_OAUTH_CALLBACK"] = callbackURL.absoluteString
        }
        env["OPENCLICKY_CONNECTOR_ROOT"] = bootURL.deletingLastPathComponent().path
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

        // Wire pipe readers BEFORE launching so we don't miss the
        // READY line on fast startups.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            Task { @MainActor [weak self] in
                self?.appendStdout(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            // Best-effort logging — stderr is diagnostic only.
            FileHandle.standardError.write(Data("[connector] \(text)".utf8))
        }

        do {
            try proc.run()
        } catch {
            handleTermination(reason: "launch error: \(error)")
            throw OpenClickyConnectorSubprocessError.launchFailed("\(error)")
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
                        waiter.resume(throwing: OpenClickyConnectorSubprocessError.startupTimeout)
                    }
                }
            }
        } catch {
            stop()
            throw error
        }

        boundPort = port
        lastStatusMessage = "starting"

        // Verify with a health probe.
        do {
            let health = try await request(path: "/health", method: "GET", body: nil)
            if let obj = try? JSONSerialization.jsonObject(with: health) as? [String: Any] {
                if let count = obj["providers"] as? Int {
                    providerCount = count
                }
            }
            lastStatusMessage = "running on port \(port), \(providerCount ?? 0) providers"
            let bootMs = Int(Date().timeIntervalSince(bootStartedAt) * 1000)
            f29Log.info("openclicky.connector.subprocess.ready port=\(port, privacy: .public) node_path=\(nodeURL.path, privacy: .public) boot_ms=\(bootMs, privacy: .public) providers=\(self.providerCount ?? 0, privacy: .public)")
            f29Log.info("openclicky.connector.subprocess.health_probe status=ok retry_count=0")
            // Runtime is up end-to-end; clear crash counter so a later
            // failure gets its full backoff budget again.
            restartAttempts = 0
        } catch {
            f29Log.error("openclicky.connector.subprocess.health_probe status=fail retry_count=1 reason=\(String(describing: error), privacy: .public)")
            stop()
            throw OpenClickyConnectorSubprocessError.healthCheckFailed("\(error)")
        }
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

    /// Forward a JSON request to the Node subprocess. Returns the raw
    /// response body. `body` may be nil for GET-shaped calls.
    func request(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> Data {
        guard let base = localhostURL else {
            throw OpenClickyConnectorSubprocessError.notRunning
        }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw OpenClickyConnectorSubprocessError.invalidResponse
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
            throw OpenClickyConnectorSubprocessError.requestFailed(-1, "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenClickyConnectorSubprocessError.invalidResponse
        }
        if http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenClickyConnectorSubprocessError.requestFailed(http.statusCode, text)
        }
        return data
    }

    /// Convenience wrapper: perform a request and decode as a JSON
    /// dictionary.
    func requestJSON(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await request(path: path, method: method, body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClickyConnectorSubprocessError.invalidResponse
        }
        return obj
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
        providerCount = nil
        lastStatusMessage = "stopped (\(reason))"

        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: OpenClickyConnectorSubprocessError.launchFailed(reason))
        }

        if desiredEnabled {
            // Exponential backoff capped at 60s: 2, 4, 8, 16, 32, 60, 60...
            // Prevents the pre-fix 2s spin loop on persistent failure.
            f29Log.notice("openclicky.connector.subprocess.crash exit_reason=\(reason, privacy: .public) restart_attempts=\(self.restartAttempts, privacy: .public)")
            if restartAttempts >= Self.maxRestartAttempts {
                let message = "Connector runtime failed \(restartAttempts) times; auto-restart disabled."
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
            f29Log.notice("openclicky.connector.subprocess.crash backoff_seconds=\(delaySeconds, privacy: .public) next_attempt=\(attempt + 1, privacy: .public)")
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
        // Other lines are diagnostic; drop.
    }

    // MARK: - Path resolution

    /// Discover a `node` executable. Order (documented in impl-notes):
    ///   1. Settings override (`OpenClickyConnectorSettings.nodePathOverride`).
    ///   2. `/opt/homebrew/bin/node`.
    ///   3. `/usr/local/bin/node`.
    ///   4. `~/.nvm/versions/node/*/bin/node` (latest by mtime).
    ///   5. `PATH` lookup fallback.
    static func resolveNodePath() throws -> URL {
        if let override = OpenClickyConnectorSettings.shared.nodePathOverride,
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
        // ~/.nvm/versions/node/*/bin/node
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
        // PATH fallback via /usr/bin/env node --version — cheap probe.
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
        throw OpenClickyConnectorSubprocessError.nodeNotFound
    }

    /// Resolve `AppResources/OpenClicky/OpenConnectorRuntime/boot.js`.
    /// Checks the .app bundle first (production), then the source tree
    /// (dev builds running from Xcode).
    static func resolveBootScriptURL() throws -> URL {
        // Bundled path: Contents/Resources/OpenConnectorRuntime/boot.js
        if let bundleURL = Bundle.main.resourceURL {
            let bundled = bundleURL
                .appendingPathComponent("OpenConnectorRuntime")
                .appendingPathComponent("boot.js")
            if FileManager.default.isReadableFile(atPath: bundled.path) {
                return bundled
            }
        }
        // Dev path: walk up from the bundle to the source tree root.
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()             // cursor-buddy/
            .deletingLastPathComponent()             // openclicky/
            .appendingPathComponent("AppResources/OpenClicky/OpenConnectorRuntime/boot.js")
        if FileManager.default.isReadableFile(atPath: devPath.path) {
            return devPath
        }
        throw OpenClickyConnectorSubprocessError.bootScriptMissing(devPath)
    }
}
