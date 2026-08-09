//
//  HeyClickyChromeBridgeServer.swift
//  cursor-buddy
//
//  Local HTTP server on 127.0.0.1:3011 that drives our Chrome extension.
//  Used to automate the Google account-chooser click during quota reset
//  so the user only ever types their password ONCE (first sign-in);
//  every reset after that is fully driven by the extension.
//
//  Endpoints:
//    POST /event   — extension pushes { type, ... } events
//    GET  /cmd     — long-poll (25s), returns pending command JSON or 204
//    GET  /health  — quick liveness probe
//
//  Ported from clicky-mac ChromeBridgeServer.swift (port 3001 → 3011 so
//  we can coexist with the shipping HeyClicky.app on this machine).
//

import Foundation
import Network

@MainActor
final class HeyClickyChromeBridgeServer {
    static let shared = HeyClickyChromeBridgeServer()

    private let port: NWEndpoint.Port = 3011
    private var listener: NWListener?

    /// The port the bridge is currently bound to. `nil` when the
    /// listener has not been started yet or has been stopped.
    var activePort: UInt16? {
        guard listener != nil else { return nil }
        return port.rawValue
    }

    /// Whether the local HTTP listener is currently up.
    var isRunning: Bool { listener != nil }

    private var pending: [[String: Any]] = []
    private var waiters: [NWConnection] = []

    private var eventLog: [[String: Any]] = []
    /// Cap on `eventLog` to prevent unbounded growth over long sessions.
    /// The log is only consulted for recent history (`closeTabsMatching`,
    /// `waitForEvent` bootstrap check), so 500 entries is well past what
    /// any single flow needs while keeping worst-case memory bounded.
    private let eventLogMaxEntries = 500
    private var eventListeners: [(([String: Any]) -> Bool)] = []
    private var listenerContinuations: [CheckedContinuation<[String: Any], Never>] = []
    private var listenerTags: [String] = []

    private var lastHelloAt: Date?

    var isExtensionAlive: Bool {
        guard let lastHelloAt else { return false }
        return Date().timeIntervalSince(lastHelloAt) < 30
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: port)
        } catch {
            log(event: "system.heyclicky.bridge_listen_failed", extra: ["error": "\(error)"])
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handle(connection: conn) }
        }
        listener?.start(queue: .main)
        log(event: "system.heyclicky.bridge_started", extra: ["port": "3011"])
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in waiters { c.cancel() }
        waiters.removeAll()
        pending.removeAll()
    }

    // MARK: - Public commands (used by AccountResetManager)

    @discardableResult
    func openTab(url: String, active: Bool = true, timeout: TimeInterval = 8) async -> Int? {
        enqueue(["type": "open-tab", "url": url, "active": active])
        let ev = await waitForEvent(matching: { $0["type"] as? String == "tab-opened" }, timeout: timeout)
        return ev?["tabId"] as? Int
    }

    @discardableResult
    func click(tabId: Int, selector: String, textMatch: String? = nil, timeout: TimeInterval = 6) async -> Bool {
        var cmd: [String: Any] = ["type": "click", "tabId": tabId, "selector": selector]
        if let textMatch { cmd["textMatch"] = textMatch }
        enqueue(cmd)
        let ev = await waitForEvent(matching: { m in
            (m["type"] as? String == "click-result") && (m["tabId"] as? Int == tabId)
        }, timeout: timeout)
        return (ev?["ok"] as? Bool) ?? false
    }

    func waitForNavigation(matching substring: String, timeout: TimeInterval = 30) async -> (tabId: Int, url: String)? {
        let ev = await waitForEvent(matching: { m in
            guard m["type"] as? String == "tab-navigated",
                  let url = m["url"] as? String else { return false }
            return url.contains(substring)
        }, timeout: timeout)
        guard let ev,
              let tabId = ev["tabId"] as? Int,
              let url = ev["url"] as? String else { return nil }
        return (tabId, url)
    }

    func closeTab(tabId: Int) async {
        enqueue(["type": "close-tab", "tabId": tabId])
        _ = await waitForEvent(matching: { $0["type"] as? String == "tab-closed" }, timeout: 3)
    }

    /// Close every tab whose most recent navigation URL contains any
    /// of `substrings`. Uses the eventLog history — no extra command
    /// needed on the extension side (the ext already reports every
    /// tab-navigated event, so we can pick winners locally).
    func closeTabsMatching(_ substrings: [String]) async {
        var tabIds: Set<Int> = []
        for ev in eventLog {
            guard ev["type"] as? String == "tab-navigated",
                  let id = ev["tabId"] as? Int,
                  let url = ev["url"] as? String else { continue }
            if substrings.contains(where: { url.contains($0) }) {
                tabIds.insert(id)
            }
        }
        for id in tabIds {
            await closeTab(tabId: id)
        }
    }

    // MARK: - Queue

    private func enqueue(_ cmd: [String: Any]) {
        HeyClickyLog.log("bridge.cmd", lane: "system", direction: "outgoing", [
            "type": cmd["type"] as? String ?? "?"
        ])
        while !waiters.isEmpty {
            let conn = waiters.removeFirst()
            switch conn.state {
            case .cancelled, .failed: continue
            default:
                send(json: cmd, to: conn, status: "200 OK")
                return
            }
        }
        pending.append(cmd)
    }

    // MARK: - Event dispatch

    private func recordEvent(_ ev: [String: Any]) {
        lastHelloAt = Date()
        eventLog.append(ev)
        // Drop-oldest cap. Runs on @MainActor same as every other
        // eventLog access, so no additional locking needed.
        if eventLog.count > eventLogMaxEntries {
            eventLog.removeFirst(eventLog.count - eventLogMaxEntries)
        }
        HeyClickyLog.log("bridge.event", lane: "system", direction: "incoming", [
            "type": ev["type"] as? String ?? "?",
            "tab": ev["tabId"] as? Int ?? -1
        ])
        var i = 0
        while i < eventListeners.count {
            if eventListeners[i](ev) {
                _ = listenerContinuations.remove(at: i)
                eventListeners.remove(at: i)
                if i < listenerTags.count { listenerTags.remove(at: i) }
            } else {
                i += 1
            }
        }
    }

    private func waitForEvent(matching predicate: @escaping ([String: Any]) -> Bool,
                              timeout: TimeInterval) async -> [String: Any]? {
        for ev in eventLog.reversed() where predicate(ev) { return ev }
        actor Guard {
            var fired = false
            func take() -> Bool { if fired { return false }; fired = true; return true }
        }
        let guardBox = Guard()
        let tag = UUID().uuidString

        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            let listener: ([String: Any]) -> Bool = { ev in
                guard predicate(ev) else { return false }
                Task { if await guardBox.take() { cont.resume(returning: ev) } }
                return true
            }
            eventListeners.append(listener)
            listenerContinuations.append(cont)
            listenerTags.append(tag)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if await guardBox.take() {
                    if let idx = self.listenerTags.firstIndex(of: tag) {
                        self.listenerTags.remove(at: idx)
                        self.eventListeners.remove(at: idx)
                        self.listenerContinuations.remove(at: idx)
                    }
                    cont.resume(returning: [:])
                }
            }
        }
    }

    // MARK: - HTTP

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection: connection, accumulated: Data())
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] chunk, _, isComplete, err in
            guard let self else { connection.cancel(); return }
            var buf = accumulated
            if let chunk { buf.append(chunk) }
            let text = String(data: buf, encoding: .utf8) ?? ""

            guard let headerEnd = text.range(of: "\r\n\r\n") else {
                if err != nil || isComplete { connection.cancel(); return }
                Task { @MainActor in self.readRequest(connection: connection, accumulated: buf) }
                return
            }
            let headers = String(text[..<headerEnd.lowerBound])
            var contentLength = 0
            for line in headers.split(separator: "\r\n") {
                if line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":", maxSplits: 1)[1]
                        .trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = text.distance(from: text.startIndex, to: headerEnd.upperBound)
            let haveBody = buf.count - bodyStart
            if contentLength > 0 && haveBody < contentLength && err == nil && !isComplete {
                Task { @MainActor in self.readRequest(connection: connection, accumulated: buf) }
                return
            }
            Task { @MainActor in self.dispatch(request: text, on: connection) }
        }
    }

    private func dispatch(request: String, on connection: NWConnection) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respondPlain("bad", on: connection); return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let bodyIndex = request.range(of: "\r\n\r\n").map { $0.upperBound } ?? request.endIndex
        let body = String(request[bodyIndex...])

        // Any request from the extension counts as a liveness signal.
        // The `hello` event is only sent on install/startup/action, so
        // relying on it alone made `isExtensionAlive` flip to false after
        // 30s of steady polling. `/cmd` long-poll fires every 25s under
        // normal operation, so bumping the timestamp here keeps alive
        // status accurate for as long as the extension is running.
        if method != "OPTIONS" {
            lastHelloAt = Date()
        }
        switch (method, path) {
        case ("GET", "/health"):
            let json: [String: Any] = ["ok": true, "extAlive": isExtensionAlive]
            send(json: json, to: connection, status: "200 OK")
        case ("GET", "/cmd"):
            handleCmdPoll(on: connection)
        case ("POST", "/event"):
            handleEvent(bodyJSON: body, on: connection)
        case ("OPTIONS", _):
            let hdr = corsHeaders() + "Content-Length: 0\r\n\r\n"
            connection.send(content: Data(("HTTP/1.1 204 No Content\r\n" + hdr).utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        default:
            respondPlain("not found", on: connection, status: "404 Not Found")
        }
    }

    private func handleCmdPoll(on connection: NWConnection) {
        if !pending.isEmpty {
            let cmd = pending.removeFirst()
            send(json: cmd, to: connection, status: "200 OK")
            return
        }
        waiters.append(connection)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self else { return }
            if let idx = self.waiters.firstIndex(where: { $0 === connection }) {
                self.waiters.remove(at: idx)
                self.respondPlain("", on: connection, status: "204 No Content")
            }
        }
    }

    private func handleEvent(bodyJSON: String, on connection: NWConnection) {
        let trimmed = bodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{00}"))
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            recordEvent(obj)
        }
        respondPlain("ok", on: connection)
    }

    private func corsHeaders() -> String {
        return """
        Access-Control-Allow-Origin: *\r\n\
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\
        Access-Control-Allow-Headers: Content-Type\r\n
        """
    }

    private func send(json: [String: Any], to connection: NWConnection, status: String) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let hdr = "HTTP/1.1 \(status)\r\n"
            + corsHeaders()
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(data.count)\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respondPlain(_ text: String, on connection: NWConnection, status: String = "200 OK") {
        let hdr = "HTTP/1.1 \(status)\r\n"
            + corsHeaders()
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(text.utf8.count)\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(Data(text.utf8))
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func log(event: String, extra: [String: String]) {
        HeyClickyLog.log(event, lane: "system", direction: "internal", extra as [String: Any])
    }
}
