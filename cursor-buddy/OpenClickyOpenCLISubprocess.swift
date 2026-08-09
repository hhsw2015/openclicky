//
//  OpenClickyOpenCLISubprocess.swift
//  cursor-buddy
//
//  Phase 7.6a F30 — Node subprocess manager for the OpenCLI site
//  adapter runtime.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  OpenCLI upstream pin:    9161d99d96ec107cd77f13a30315614129179a1a
//
//  Structural clone of `OpenClickyConnectorSubprocess` (F29) — the two
//  subprocesses are intentionally independent: separate binaries,
//  separate ports, separate auth tokens. Sharing state would defeat
//  the crash-isolation guarantee. The only implementation detail we
//  share with F29 is the `resolveNodePath()` search order (settings
//  override -> Homebrew -> nvm -> PATH); reusing F29's static keeps
//  a single source of truth.
//
//  Lifecycle contract mirrors F29:
//    * `start()` -> spawns `node boot.js`, waits for `READY <port>` on
//      stdout, health-probes `GET /health`, records site count.
//    * `stop()` closes pipes, sends SIGTERM, waits up to 3s, then
//      SIGKILL.
//    * Termination while `desiredEnabled == true` triggers one
//      restart with a 2s backoff.
//

import Foundation
import os

/// Structured logger for F30 subprocess lifecycle. Subsystem
/// `com.jkneen.openclicky`, category `Layer7-OpenCLI` — mirrors F29/F31
/// pattern for the layer-7 audit trace surface.
private let f30Log = Logger(subsystem: "com.jkneen.openclicky", category: "Layer7-OpenCLI")

/// Errors raised by the OpenCLI subprocess.
enum OpenClickyOpenCLISubprocessError: Error, LocalizedError {
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
            return "OpenCLIRuntime/boot.js missing at \(url.path). Reinstall OpenClicky."
        case .launchFailed(let msg):
            return "Failed to launch Node OpenCLI subprocess: \(msg)"
        case .startupTimeout:
            return "OpenCLI subprocess did not signal READY within 10 seconds."
        case .healthCheckFailed(let msg):
            return "OpenCLI subprocess health check failed: \(msg)"
        case .notRunning:
            return "OpenCLI subprocess is not running."
        case .requestFailed(let status, let msg):
            return "OpenCLI subprocess HTTP \(status): \(msg)"
        case .invalidResponse:
            return "OpenCLI subprocess returned a malformed response."
        }
    }
}

@MainActor
final class OpenClickyOpenCLISubprocess {
    static let shared = OpenClickyOpenCLISubprocess()

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

    private(set) var siteCount: Int?
    private(set) var adapterCount: Int?
    private(set) var lastStatusMessage: String = "idle"
    private var desiredEnabled: Bool = false

    // MARK: - Private state

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?
    private var stdoutBuffer: Data = Data()
    private var readyContinuation: CheckedContinuation<Int, Error>?
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.opencli-subprocess")
    /// Consecutive crash count used by the exponential-backoff auto-restart
    /// path in `handleTermination`. Reset on a successful health probe.
    private var restartAttempts: Int = 0
    /// Fail-open cap on auto-restart attempts before we surface a persistent
    /// failure to the settings pane / notification center.
    private static let maxRestartAttempts = 10
    /// Broadcast when the subprocess has given up auto-restarting after
    /// hitting `maxRestartAttempts`. Settings UI listens to surface it.
    static let subprocessFailedNotification = Notification.Name(
        "com.jkneen.openclicky.opencli.subprocess.failed"
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

    func start() async throws {
        desiredEnabled = true
        if isRunning {
            lastStatusMessage = "already running on port \(boundPort ?? 0)"
            return
        }

        // Reuse F29's Node-path resolver — same search order, same
        // Settings key. We deliberately do not add a second override
        // knob; users get one Node discovery UX, not two.
        let nodeURL = try OpenClickyConnectorSubprocess.resolveNodePath()
        let bootURL = try Self.resolveBootScriptURL()

        let bootStartedAt = Date()
        f30Log.info("openclicky.opencli.subprocess.start_attempt node_path=\(nodeURL.path, privacy: .public) port_range=55000-56000 attempt=\(self.restartAttempts, privacy: .public)")

        authToken = UUID().uuidString
        boundPort = nil
        siteCount = nil
        adapterCount = nil
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
        env["OPENCLICKY_OPENCLI_TOKEN"] = authToken
        env["OPENCLICKY_OPENCLI_PORT_MIN"] = "55000"
        env["OPENCLICKY_OPENCLI_PORT_MAX"] = "56000"
        env["OPENCLICKY_OPENCLI_ROOT"] = bootURL.deletingLastPathComponent().path
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
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            FileHandle.standardError.write(Data("[opencli] \(text)".utf8))
        }

        do {
            try proc.run()
        } catch {
            handleTermination(reason: "launch error: \(error)")
            throw OpenClickyOpenCLISubprocessError.launchFailed("\(error)")
        }

        let port: Int
        do {
            port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                self.readyContinuation = cont
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self else { return }
                    if let waiter = self.readyContinuation {
                        self.readyContinuation = nil
                        waiter.resume(throwing: OpenClickyOpenCLISubprocessError.startupTimeout)
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
            let health = try await request(path: "/health", method: "GET", body: nil)
            if let obj = try? JSONSerialization.jsonObject(with: health) as? [String: Any] {
                if let sites = obj["sites"] as? Int { siteCount = sites }
                if let adapters = obj["adapters"] as? Int { adapterCount = adapters }
            }
            lastStatusMessage = "running on port \(port), \(siteCount ?? 0) sites, \(adapterCount ?? 0) adapters"
            let bootMs = Int(Date().timeIntervalSince(bootStartedAt) * 1000)
            f30Log.info("openclicky.opencli.subprocess.ready port=\(port, privacy: .public) node_path=\(nodeURL.path, privacy: .public) boot_ms=\(bootMs, privacy: .public) sites=\(self.siteCount ?? 0, privacy: .public) adapters=\(self.adapterCount ?? 0, privacy: .public)")
            f30Log.info("openclicky.opencli.subprocess.health_probe status=ok retry_count=0")
            // Runtime is up end-to-end; clear crash counter so a later
            // failure gets its full backoff budget again.
            restartAttempts = 0
        } catch {
            f30Log.error("openclicky.opencli.subprocess.health_probe status=fail retry_count=1 reason=\(String(describing: error), privacy: .public)")
            stop()
            throw OpenClickyOpenCLISubprocessError.healthCheckFailed("\(error)")
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

    func request(path: String, method: String = "POST", body: Data? = nil) async throws -> Data {
        guard let base = localhostURL else {
            throw OpenClickyOpenCLISubprocessError.notRunning
        }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw OpenClickyOpenCLISubprocessError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OpenClickyOpenCLISubprocessError.requestFailed(-1, "\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenClickyOpenCLISubprocessError.invalidResponse
        }
        if http.statusCode >= 400 {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            throw OpenClickyOpenCLISubprocessError.requestFailed(http.statusCode, text)
        }
        return data
    }

    func requestJSON(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> [String: Any] {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await request(path: path, method: method, body: payload)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClickyOpenCLISubprocessError.invalidResponse
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
        siteCount = nil
        adapterCount = nil
        lastStatusMessage = "stopped (\(reason))"

        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: OpenClickyOpenCLISubprocessError.launchFailed(reason))
        }

        if desiredEnabled {
            // Exponential backoff capped at 60s: 2, 4, 8, 16, 32, 60, 60...
            // Prevents the pre-fix 2s spin loop on persistent failure.
            f30Log.notice("openclicky.opencli.subprocess.crash exit_reason=\(reason, privacy: .public) restart_attempts=\(self.restartAttempts, privacy: .public)")
            if restartAttempts >= Self.maxRestartAttempts {
                let message = "OpenCLI runtime failed \(restartAttempts) times; auto-restart disabled."
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
            f30Log.notice("openclicky.opencli.subprocess.crash backoff_seconds=\(delaySeconds, privacy: .public) next_attempt=\(attempt + 1, privacy: .public)")
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

    /// Resolve `AppResources/OpenClicky/OpenCLIRuntime/boot.js`.
    static func resolveBootScriptURL() throws -> URL {
        if let bundleURL = Bundle.main.resourceURL {
            let bundled = bundleURL
                .appendingPathComponent("OpenCLIRuntime")
                .appendingPathComponent("boot.js")
            if FileManager.default.isReadableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppResources/OpenClicky/OpenCLIRuntime/boot.js")
        if FileManager.default.isReadableFile(atPath: devPath.path) {
            return devPath
        }
        throw OpenClickyOpenCLISubprocessError.bootScriptMissing(devPath)
    }
}
