//
//  OpenClickyAgentsSocketServer.swift
//  cursor-buddy
//
//  AF_UNIX presence server at ~/.openclicky/agents.sock. CLI-side
//  heartbeat scripts connect, send a newline JSON hello, and hold the
//  socket open. Peer close = agent gone. Mirrors SKI's agents.sock.
//

import Combine
import Foundation
import Darwin

struct OpenClickyAgentPresence: Identifiable, Equatable {
    let id: Int32          // client fd (unique while alive)
    let pid: Int
    let projectRoot: String
    let skillDir: String
    let connectedAt: Date
    let sessionID: String
}

@MainActor
final class OpenClickyAgentsPresenceStore: ObservableObject {
    static let shared = OpenClickyAgentsPresenceStore()
    @Published private(set) var connected: [OpenClickyAgentPresence] = []
    /// User-picked "active speak target" project root. When nil,
    /// utterances follow the frontmost window's git root (auto).
    @Published private(set) var pinnedActiveProjectRoot: String?

    private static let pinnedRootDefaultsKey = "openclicky.voice.pinnedActiveProjectRoot"

    init() {
        pinnedActiveProjectRoot = UserDefaults.standard.string(forKey: Self.pinnedRootDefaultsKey)
    }

    func upsert(_ presence: OpenClickyAgentPresence) {
        if let idx = connected.firstIndex(where: { $0.id == presence.id }) {
            connected[idx] = presence
        } else {
            connected.append(presence)
        }
    }

    func remove(fd: Int32) {
        connected.removeAll { $0.id == fd }
    }

    func setPinnedActiveProject(_ root: String?) {
        pinnedActiveProjectRoot = root
        if let root, !root.isEmpty {
            UserDefaults.standard.set(root, forKey: Self.pinnedRootDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pinnedRootDefaultsKey)
        }
    }

    /// The effective active workspace url used by the file bridge.
    /// Priority: user pin → auto-resolve.
    func effectiveActiveWorkspace() -> URL? {
        if let pinned = pinnedActiveProjectRoot, !pinned.isEmpty {
            return URL(fileURLWithPath: pinned)
        }
        return OpenClickyWorkspaceResolver.resolveActiveWorkspace()
    }
}

nonisolated final class OpenClickyAgentsSocketServer: @unchecked Sendable {
    static let shared = OpenClickyAgentsSocketServer()

    static var socketPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openclicky/agents.sock")
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptQueue: DispatchQueue?
    private var isRunning = false

    /// Nonisolated per-workspace live counter. Keyed by absolute
    /// project-root path (matches OpenClickyAgentPresence.projectRoot).
    /// Read from any thread by UI helpers that can't jump to
    /// MainActor. Updated by handleClient on connect / disconnect.
    private static let connectionsLock = NSLock()
    private static var _connectionsByRoot: [String: Int] = [:]

    static func connectionCount(forRoot root: String) -> Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return _connectionsByRoot[root] ?? 0
    }

    static func hasAnyConnection() -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return _connectionsByRoot.values.contains { $0 > 0 }
    }

    static let connectionsDidChange = Notification.Name("com.openclicky.agents.connectionsDidChange")

    static func bumpConnection(forRoot root: String, delta: Int) {
        connectionsLock.lock()
        let next = max(0, (_connectionsByRoot[root] ?? 0) + delta)
        if next == 0 {
            _connectionsByRoot.removeValue(forKey: root)
        } else {
            _connectionsByRoot[root] = next
        }
        connectionsLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: connectionsDidChange, object: nil, userInfo: ["root": root])
        }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let socketURL = Self.socketPath
        let dir = socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Best-effort remove stale socket file.
        try? FileManager.default.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { rawPathPtr in
                rawPathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { pathPtr in
                    _ = strlcpy(pathPtr, cstr, 104)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            log("bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        if listen(fd, 8) != 0 {
            log("listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        isRunning = true
        let queue = DispatchQueue(label: "com.openclicky.agents.socket", qos: .utility)
        acceptQueue = queue
        queue.async { [weak self] in
            self?.acceptLoop()
        }
        log("listening at \(socketURL.path)")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        try? FileManager.default.removeItem(at: Self.socketPath)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let running = isRunning
            lock.unlock()
            guard running, fd >= 0 else { return }

            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                accept(fd, ptr, &len)
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EBADF { return } // socket closed on stop()
                usleep(50_000)
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        // Read up to 4 KB looking for the newline-terminated hello.
        let capacity = 4096
        let bufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { bufferPtr.deallocate() }
        var received = 0
        while received < capacity {
            let n = read(fd, bufferPtr.advanced(by: received), capacity - received)
            if n <= 0 { return }
            received += n
            var found = false
            for i in 0..<received where bufferPtr[i] == 0x0A { found = true; break }
            if found { break }
        }
        var newlineIdx: Int? = nil
        for i in 0..<received where bufferPtr[i] == 0x0A { newlineIdx = i; break }
        guard let idx = newlineIdx else { return }
        let data = Data(bytes: bufferPtr, count: idx)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let hello = (obj["hello"] as? String) ?? ""
        // Accept both openclicky-heartbeat (native) AND ski-heartbeat
        // (users pointing existing SKI skill at our socket).
        guard hello == "openclicky-heartbeat" || hello == "ski-heartbeat" else {
            return
        }

        let presence = OpenClickyAgentPresence(
            id: fd,
            pid: (obj["pid"] as? Int) ?? -1,
            projectRoot: (obj["project_root"] as? String) ?? "",
            skillDir: (obj["skill_dir"] as? String) ?? "",
            connectedAt: Date(),
            sessionID: UUID().uuidString
        )
        let sessionID = presence.sessionID
        Self.bumpConnection(forRoot: presence.projectRoot, delta: 1)
        let projectRoot = presence.projectRoot
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.agents_socket.handshake",
            fields: [
                "pid": String(presence.pid),
                "project_root": projectRoot,
                "session_id": sessionID
            ]
        )
        Task { @MainActor in
            OpenClickyAgentsPresenceStore.shared.upsert(presence)
            // As soon as an agent announces itself, start tailing that
            // workspace's commands.jsonl AND open a fresh
            // SKIConversationSession keyed by the UDS session id.
            // Every UDS handshake == new session bubble.
            if !projectRoot.isEmpty {
                SKIModeConversationStore.shared.beginSession(id: sessionID, workspace: projectRoot)
                SKIModeConversationStore.shared.startTailing(workspace: projectRoot)
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "openclicky.ski.started_tailing",
                    fields: ["workspace": projectRoot]
                )
                // Emit `session.started` event to the workspace so the
                // CLI skill's tail loop can see the new session.
                let root = projectRoot
                let sid = sessionID
                Task {
                    await OpenClickyFileBridge.shared.emitEventLine(
                        workspace: URL(fileURLWithPath: root),
                        payload: [
                            "event": "session.started",
                            "session_id": sid,
                            "project": (root as NSString).lastPathComponent,
                            "ts": Date().timeIntervalSince1970
                        ]
                    )
                }
            }
        }

        // Ack.
        let ackDict: [String: Any] = ["ok": true, "session_id": sessionID]
        if let ackData = try? JSONSerialization.data(withJSONObject: ackDict) {
            var payload = ackData
            payload.append(0x0A)
            let count = payload.count
            payload.withUnsafeBytes { rawBuf in
                if let base = rawBuf.baseAddress {
                    _ = write(fd, base, count)
                }
            }
        }

        // Hold the connection as a liveness pipe. Peer close = agent gone.
        // Drain any spurious bytes (SKI-compatible: up to 64 B every 5 s
        // as heartbeat ticks; we ignore contents).
        let scratchPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer { scratchPtr.deallocate() }
        while true {
            let n = read(fd, scratchPtr, 64)
            if n <= 0 { break }
        }
        // Cleanup.
        Self.bumpConnection(forRoot: presence.projectRoot, delta: -1)
        let presenceSessionID = presence.sessionID
        Task { @MainActor in
            OpenClickyAgentsPresenceStore.shared.remove(fd: fd)
            SKIModeConversationStore.shared.endSession(id: presenceSessionID)
        }
    }

    private func log(_ msg: String) {
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "openclicky.agents_socket.\(msg.split(separator: " ").first.map(String.init) ?? "log")",
            fields: ["message": msg]
        )
    }
}
