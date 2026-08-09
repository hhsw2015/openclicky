//
//  OpenClickyConnectorOAuthCallback.swift
//  cursor-buddy
//
//  Phase 7.5 F29 — Loopback HTTP server that receives OAuth 2.0
//  redirects for open-connector providers (GitHub, Google, Slack, ...).
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Mirrors Everywhere's `OAuthFlowService.HandleCallbackAsync`
//  (Connector/OAuthFlowService.cs). Loopback-only enforcement is
//  achieved via NWParameters.acceptLocalOnly=true.
//
//  Flow:
//    1. Bridge calls `connector_connect` → subprocess exchanges args →
//       Swift stores `state` in `pendingStates` and returns the
//       provider's authorization URL to the caller.
//    2. Caller opens the URL in a browser.
//    3. Provider redirects back to
//       `http://127.0.0.1:<port>/oauth/callback?code=...&state=...`.
//    4. This server matches `state` against `pendingStates`, forwards
//       `{provider, connection, code, state}` to the Node subprocess
//       at `POST /internal/oauth_complete`, which finishes the token
//       exchange and stores the credential.
//    5. We render a small HTML "connected — you can close this tab"
//       response, mirroring Everywhere's UX beat.
//
//  This class is a stripped-down variant of `HeyClickyChromeBridgeServer`,
//  focused solely on the callback route.
//

import Foundation
import Network

@MainActor
final class OpenClickyConnectorOAuthCallback {
    static let shared = OpenClickyConnectorOAuthCallback()

    /// Random port bound at start. Nil until listener enters `.ready`.
    private(set) var boundPort: UInt16?

    /// Pending OAuth `state` values → provider metadata.
    /// Cleared as soon as the callback fires (or after 10 minutes).
    private struct PendingState {
        let providerId: String
        let connectionId: String?
        let createdAt: Date
    }

    private var pendingStates: [String: PendingState] = [:]
    private var listener: NWListener?

    /// Snapshot for the Settings UI.
    var isRunning: Bool { listener != nil }

    /// Public URL suitable for env-var injection into the Node
    /// subprocess. Returns nil when the listener isn't ready.
    func localhostURL() -> URL? {
        guard let port = boundPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/oauth/callback")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else { return }
        var lastError: Error?
        for _ in 0..<10 {
            // Random port in [54000, 55000).
            let port = UInt16.random(in: 54000..<55000)
            do {
                let params = NWParameters.tcp
                params.acceptLocalOnly = true
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
                let listener = try NWListener(using: params, on: nwPort)
                listener.newConnectionHandler = { [weak self] conn in
                    Task { @MainActor in self?.handle(connection: conn) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in
                        if case .ready = state {
                            self.boundPort = port
                        }
                        if case .failed = state {
                            self.listener?.cancel()
                            self.listener = nil
                            self.boundPort = nil
                        }
                    }
                }
                listener.start(queue: .main)
                self.listener = listener
                // Preemptive port cache — the NWListener may still be
                // in `.setup` here, but by the time a caller reads
                // `localhostURL()` after `await start()` returns it
                // will have transitioned. Setting it here means the
                // Node subprocess env-var is populated on first spawn.
                self.boundPort = port
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? OpenClickyConnectorSubprocessError.launchFailed("no free OAuth callback port in [54000,55000)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        pendingStates.removeAll()
    }

    // MARK: - Pending-state registration

    /// Register a pending OAuth `state` so the callback route can
    /// validate it. Called by `OpenClickyConnectorBridgeTools` right
    /// after the subprocess returns an authorization URL.
    func registerPendingState(_ state: String, providerId: String, connectionId: String?) {
        pruneExpired()
        pendingStates[state] = PendingState(providerId: providerId,
                                            connectionId: connectionId,
                                            createdAt: Date())
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-600) // 10 min TTL
        for (state, meta) in pendingStates where meta.createdAt < cutoff {
            pendingStates.removeValue(forKey: state)
        }
    }

    // MARK: - HTTP handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection: connection, accumulated: Data())
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, err in
            guard let self else { connection.cancel(); return }
            var buf = accumulated
            if let chunk { buf.append(chunk) }
            let text = String(data: buf, encoding: .utf8) ?? ""
            guard let headerEnd = text.range(of: "\r\n\r\n") else {
                if err != nil || isComplete { connection.cancel(); return }
                Task { @MainActor in self.readRequest(connection: connection, accumulated: buf) }
                return
            }
            let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respondPlain("bad", on: connection, status: "400 Bad Request")
                return
            }
            let method = String(parts[0])
            let rawPath = String(parts[1])
            _ = headerEnd
            Task { @MainActor in self.route(method: method, rawPath: rawPath, on: connection) }
        }
    }

    private func route(method: String, rawPath: String, on connection: NWConnection) {
        if method == "OPTIONS" {
            respondPlain("", on: connection, status: "204 No Content")
            return
        }
        // Split path from query.
        let (path, query) = splitPathAndQuery(rawPath)
        switch (method, path) {
        case ("GET", "/oauth/callback"):
            handleCallback(query: query, on: connection)
        case ("GET", "/health"):
            respondJSON(["ok": true, "pending_states": pendingStates.count], on: connection)
        default:
            respondPlain("not found", on: connection, status: "404 Not Found")
        }
    }

    private func handleCallback(query: [String: String], on connection: NWConnection) {
        guard let state = query["state"] else {
            respondCallbackHTML(title: "OpenClicky OAuth error",
                                message: "Missing `state` parameter.",
                                success: false, on: connection)
            return
        }
        guard let pending = pendingStates.removeValue(forKey: state) else {
            respondCallbackHTML(title: "OpenClicky OAuth error",
                                message: "Unknown or expired `state`.",
                                success: false, on: connection)
            return
        }
        let code = query["code"] ?? ""
        let errorParam = query["error"]
        if let errorParam, !errorParam.isEmpty {
            respondCallbackHTML(title: "OpenClicky OAuth error",
                                message: "Provider reported error: \(errorParam).",
                                success: false, on: connection)
            return
        }

        // Forward to Node subprocess. Failure surfaces to the caller;
        // the browser sees a generic success/failure page.
        let body: [String: Any] = [
            "provider": pending.providerId,
            "connection": pending.connectionId as Any,
            "code": code,
            "state": state
        ]
        Task { @MainActor in
            do {
                _ = try await OpenClickyConnectorSubprocess.shared.request(
                    path: "/internal/oauth_complete",
                    method: "POST",
                    body: body
                )
                self.respondCallbackHTML(title: "OpenClicky",
                                         message: "Connected \(pending.providerId). You can close this tab.",
                                         success: true, on: connection)
            } catch {
                self.respondCallbackHTML(title: "OpenClicky OAuth error",
                                         message: "Token exchange failed: \(error.localizedDescription)",
                                         success: false, on: connection)
            }
        }
    }

    // MARK: - Response helpers

    private func respondPlain(_ text: String, on connection: NWConnection, status: String = "200 OK") {
        let hdr = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(text.utf8.count)\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(Data(text.utf8))
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respondJSON(_ obj: [String: Any], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respondCallbackHTML(title: String, message: String, success: Bool, on connection: NWConnection) {
        let color = success ? "#1c8b34" : "#a4262c"
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 480px;
               margin: 96px auto; padding: 0 24px; color: #1d1d1f; text-align: center; }
        h1 { font-size: 20px; margin: 0 0 12px; }
        p  { color: \(color); margin: 0; font-size: 15px; line-height: 1.5; }
        </style>
        </head>
        <body>
        <h1>\(escapeHTML(title))</h1>
        <p>\(escapeHTML(message))</p>
        </body>
        </html>
        """
        let data = Data(html.utf8)
        let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\n\r\n"
        var out = Data(hdr.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func splitPathAndQuery(_ raw: String) -> (String, [String: String]) {
        if let q = raw.firstIndex(of: "?") {
            let path = String(raw[..<q])
            let queryPart = String(raw[raw.index(after: q)...])
            return (path, parseQuery(queryPart))
        }
        return (raw, [:])
    }

    private func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    private func escapeHTML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }
}
