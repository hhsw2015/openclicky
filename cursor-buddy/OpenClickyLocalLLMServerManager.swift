//
//  OpenClickyLocalLLMServerManager.swift
//  cursor-buddy
//
//  Lifecycle for the llama.cpp sidecar. Follows CodexProcessManager's shape
//  (nonisolated final class, state serialised on a private queue, terminate
//  on deinit) with three differences that come from what this process is:
//
//   1. It is an HTTP server, not a stdio JSON-RPC peer, so readiness means
//      "/health answers 200", not "we wrote a line".
//   2. It holds ~5 GB resident. A stdio helper can sit idle for free; this
//      one cannot, so it shuts down after an idle period.
//   3. The user may already be running their own `llama-server` — that is
//      exactly how every measurement in §12 was taken. Adopting an existing
//      server instead of fighting it for the port is the common case during
//      development, not an edge case.
//

import Foundation

nonisolated final class OpenClickyLocalLLMServerManager: @unchecked Sendable {

    static let shared = OpenClickyLocalLLMServerManager()

    enum State: Equatable {
        case stopped
        case starting
        /// Running as our child process.
        case running
        /// A server was already listening on the port; we did not start it
        /// and must not stop it.
        case adopted
        case failed(String)
    }

    private var process: Process?
    private var stderrBuffer = Data()
    private var lastUseAt = Date.distantPast
    private var idleTimer: DispatchSourceTimer?
    private var currentState: State = .stopped
    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.local-llm-server")

    /// Shut the sidecar down after this long without a request. ~5 GB
    /// resident is too much to hold for a feature the user may have touched
    /// once. Model load is a few seconds, so restarting is cheap relative to
    /// the memory.
    var idleShutdownInterval: TimeInterval = 10 * 60

    /// Last stderr from a failed launch, for surfacing in Settings. Nil once
    /// a start succeeds.
    private(set) var lastLaunchError: String?

    var state: State { stateQueue.sync { currentState } }
    var isUsable: Bool {
        switch state {
        case .running, .adopted: return true
        case .stopped, .starting, .failed: return false
        }
    }

    // MARK: - Start

    /// Ensure a server is reachable, starting one if needed.
    ///
    /// Idempotent and safe to call before every request — that is the
    /// intended usage, since it also refreshes the idle deadline.
    @discardableResult
    func ensureRunning(
        port: UInt16 = OpenClickyLocalLLMLocator.defaultPort,
        readinessTimeout: TimeInterval = 90
    ) async -> State {
        touch()

        // Someone else's server, or ours from a previous call.
        if await isHealthy(port: port) {
            stateQueue.sync {
                if currentState != .running { currentState = .adopted }
            }
            return state
        }

        let alreadyStarting: Bool = stateQueue.sync {
            if currentState == .starting { return true }
            currentState = .starting
            return false
        }
        if alreadyStarting {
            // Another caller is mid-launch; wait for the same readiness.
            return await waitForReadiness(port: port, timeout: readinessTimeout)
        }

        guard let runtime = OpenClickyLocalLLMLocator.resolve() else {
            return fail("llama-server or GGUF weights not found. Install llama.cpp and place weights in ~/models.")
        }

        let process = Process()
        process.executableURL = runtime.serverExecutable
        process.arguments = OpenClickyLocalLLMLocator.launchArguments(for: runtime, port: port)

        // Capture stderr: llama.cpp reports load failures there and exits,
        // so without it a failed start is an unexplained timeout.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.stateQueue.async {
                self.stderrBuffer.append(chunk)
                // Keep only the tail; llama.cpp is verbose at load.
                if self.stderrBuffer.count > 8_192 {
                    self.stderrBuffer = self.stderrBuffer.suffix(8_192)
                }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.stateQueue.async {
                // Only react if this is still the process we track — a
                // restart may have replaced it.
                guard self.process == terminated else { return }
                self.process = nil
                if case .failed = self.currentState {} else {
                    self.currentState = .stopped
                }
            }
        }

        do {
            try process.run()
        } catch {
            return fail("Could not launch llama-server: \(error.localizedDescription)")
        }
        stateQueue.sync { self.process = process }

        let result = await waitForReadiness(port: port, timeout: readinessTimeout)
        if case .failed = result {
            // Surface why, rather than just "timed out".
            let tail = stateQueue.sync { String(data: stderrBuffer, encoding: .utf8) ?? "" }
            if !tail.isEmpty {
                stateQueue.sync { lastLaunchError = String(tail.suffix(500)) }
            }
            stop()
        }
        return result
    }

    private func waitForReadiness(port: UInt16, timeout: TimeInterval) async -> State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy(port: port) {
                stateQueue.sync {
                    currentState = .running
                    lastLaunchError = nil
                }
                startIdleTimerIfNeeded()
                return .running
            }
            // Give up early if the process died — no point waiting out the
            // full timeout on a model that failed to load.
            let alive = stateQueue.sync { process?.isRunning ?? false }
            if !alive { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return fail("llama-server did not become ready within \(Int(timeout))s.")
    }

    private func isHealthy(port: UInt16) async -> Bool {
        var request = URLRequest(
            url: OpenClickyLocalLLMLocator.baseURL(port: port).appendingPathComponent("health")
        )
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    @discardableResult
    private func fail(_ message: String) -> State {
        stateQueue.sync {
            currentState = .failed(message)
            lastLaunchError = message
        }
        return .failed(message)
    }

    // MARK: - Idle shutdown

    /// Mark the server as in use. Called on every request so the idle clock
    /// measures time since last use, not time since launch.
    func touch() {
        stateQueue.sync { lastUseAt = Date() }
    }

    private func startIdleTimerIfNeeded() {
        stateQueue.sync {
            guard idleTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // Already on stateQueue.
                guard self.currentState == .running,
                      Date().timeIntervalSince(self.lastUseAt) > self.idleShutdownInterval
                else { return }
                self.stopLocked()
            }
            idleTimer = timer
            timer.resume()
        }
    }

    // MARK: - Stop

    /// Stop the sidecar if we started it.
    ///
    /// An adopted server belongs to the user — killing it because our idle
    /// timer fired would take down a terminal they are using.
    func stop() {
        stateQueue.sync { stopLocked() }
    }

    /// Caller must hold `stateQueue`.
    private func stopLocked() {
        idleTimer?.cancel()
        idleTimer = nil

        if currentState == .adopted {
            currentState = .stopped
            return
        }

        if let process, process.isRunning {
            process.terminate()
        }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stderrBuffer = Data()
        if case .failed = currentState {} else {
            currentState = .stopped
        }
    }

    deinit {
        stop()
    }
}
