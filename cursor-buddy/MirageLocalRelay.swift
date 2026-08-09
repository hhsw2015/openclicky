//
//  MirageLocalRelay.swift
//  cursor-buddy
//
//  In-process HTTP/1.1 loopback server that Claude Code CLI talks to via
//  ANTHROPIC_BASE_URL. Purpose: accept the standard Anthropic Messages
//  request (POST /v1/messages) from Claude Code, strip its telltale
//  fingerprint headers (X-Stainless-*, X-App, X-Claude-Code-Session-Id, its
//  User-Agent, etc.), and forward the body through MirageBackendClient so
//  the outbound leg to aegis-proxy stays byte-identical to a stock reqwest
//  0.13.4 request.
//
//  Design mirrors CPA's `internal/runtime/executor/claude_executor.go`
//  mirage case (see docs/mirage-porting-guide.md §Layer 1). Same delete
//  list, same 5-header emit set. The difference: CPA sees the fingerprint
//  headers because Claude Code hits its shared endpoint; we see them
//  because our relay sits on a per-turn loopback socket.
//
//  Why HTTP/1.1 inbound (not HTTP/2): Claude Code opens plain-text HTTP to
//  http://127.0.0.1:<port>. Loopback is TCP anyway; TLS + HTTP/2 buys
//  nothing on this hop. Outbound to aegis-proxy remains HTTP/2 via
//  MirageWireTransport.
//
//  Lifecycle: start() reserves a random loopback port, spins up the
//  listener, returns the URL. stop() tears down. Each `MirageAgentRunner`
//  turn owns one relay instance and disposes at end-of-turn.
//
//  Threading: uses Network.framework NWListener which delivers callbacks on
//  the supplied dispatch queue. All internal state is confined to the
//  actor.

import Foundation
import Network

/// A loopback HTTP/1.1 relay that shims Claude Code → aegis-proxy.
///
/// Usage:
/// ```
/// let relay = MirageLocalRelay()
/// let baseURL = try await relay.start()
/// // spawn `claude` with ANTHROPIC_BASE_URL=baseURL
/// // wait for the CLI to exit
/// await relay.stop()
/// ```
actor MirageLocalRelay {
    /// Long-lived relay shared by the Peeky panel's "Copy Claude
    /// config" button. Every `ClaudeAgentRunner` turn spawns its own
    /// per-turn relay (isolated to that agent run); this shared one is
    /// only for the user-facing "point YOUR external Claude CLI at
    /// OpenClicky" flow. Started on demand, kept running until the app
    /// exits.
    static let shared = MirageLocalRelay()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "mirage.relay", qos: .userInitiated)

    /// Returns the base URL if the relay is running, nil otherwise.
    /// Used by UI to avoid re-starting an already-running relay.
    var runningBaseURL: URL? {
        guard listener != nil, port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Start on demand; returns the same URL on repeat calls without
    /// binding a second listener.
    func startIfNeeded() async throws -> URL {
        if let existing = runningBaseURL { return existing }
        return try await start()
    }

    /// Start the listener on a random loopback port. Returns the base URL
    /// Claude Code should point at.
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        // NWEndpoint.Port(rawValue: 0) → OS-assigned free port.
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 0)!)
        self.listener = listener

        // Bind before we know the port; the state handler reveals it.
        let readyContinuation = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port {
                    readyContinuation.continuation.yield(p.rawValue)
                    readyContinuation.continuation.finish()
                }
            case .failed(let err):
                NSLog("[MirageLocalRelay] listener failed: \(err)")
                readyContinuation.continuation.finish()
            default:
                break
            }
            _ = self
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)

        for await p in readyContinuation.stream {
            self.port = p
            return URL(string: "http://127.0.0.1:\(p)")!
        }
        throw MirageRelayError.startFailed
    }

    /// Tear down. Idempotent.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let e):
                NSLog("[MirageLocalRelay] conn failed: \(e)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    /// Read until we have a complete HTTP request (headers + Content-Length
    /// body). No streaming request bodies from Claude Code — its request is
    /// one JSON blob. Response side does stream.
    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("[MirageLocalRelay] recv error: \(error)")
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            // Look for header terminator.
            guard let headerEnd = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                if isComplete { connection.cancel(); return }
                Task { await self.continueRead(on: connection, buffer: buf) }
                return
            }
            let headerData = buf.prefix(headerEnd.lowerBound)
            let bodyStart = headerEnd.upperBound
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                Task { await self.reply(on: connection, status: 400, body: Data("Bad Request\n".utf8), close: true) }
                return
            }
            let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else {
                Task { await self.reply(on: connection, status: 400, body: Data("Bad Request\n".utf8), close: true) }
                return
            }
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else {
                Task { await self.reply(on: connection, status: 400, body: Data("Bad Request\n".utf8), close: true) }
                return
            }
            let method = String(parts[0]).uppercased()
            let path = String(parts[1])

            // Parse headers.
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0

            // Read the rest of the body if not fully buffered.
            let already = buf.count - bodyStart
            if already >= contentLength {
                let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
                Task { await self.dispatch(method: method, path: path, headers: headers, body: body, on: connection) }
            } else {
                let missing = contentLength - already
                Task { await self.readBodyRest(on: connection, method: method, path: path, headers: headers, sofar: buf.subdata(in: bodyStart..<buf.count), missing: missing) }
            }
        }
    }

    private func continueRead(on connection: NWConnection, buffer: Data) {
        readRequest(on: connection, buffer: buffer)
    }

    private func readBodyRest(on connection: NWConnection, method: String, path: String, headers: [String: String], sofar: Data, missing: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: missing) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("[MirageLocalRelay] body recv: \(error)")
                connection.cancel()
                return
            }
            var acc = sofar
            if let data { acc.append(data) }
            let remain = missing - (data?.count ?? 0)
            if remain > 0 && !isComplete {
                Task { await self.readBodyRest(on: connection, method: method, path: path, headers: headers, sofar: acc, missing: remain) }
                return
            }
            Task { await self.dispatch(method: method, path: path, headers: headers, body: acc, on: connection) }
        }
    }

    // MARK: - Dispatch

    private func dispatch(method: String, path: String, headers: [String: String], body: Data, on connection: NWConnection) async {
        // Claude Code always sends POST /v1/messages. Anything else is
        // rejected with 404 so misconfigured clients notice fast.
        guard method == "POST",
              path.hasPrefix("/v1/messages") else {
            await reply(on: connection, status: 404, body: Data("Not found\n".utf8), close: true)
            return
        }
        // At this point `headers` contains Claude Code's fingerprint set. We
        // do NOT forward any of it; MirageBackendClient rebuilds the exact
        // 5-6-header wire set from scratch. The whole point of this relay is
        // to isolate the CLI-side fingerprint from the outbound leg.
        //
        // We do forward the body verbatim — it is a standard Anthropic
        // Messages payload that MirageBackendClient handles as-is (including
        // the `mirage/` prefix strip should the caller ever specify one).
        do {
            let stream = try await forwardStreaming(body: body, on: connection)
            _ = stream
        } catch let e as MirageError {
            // Map mirage errors to distinct HTTP statuses so upstream
            // callers (Claude Code CLI, MiragePeekyOrchestrator) can
            // pattern-match instead of every failure looking like a
            // generic 502.
            //
            // 429 quota → return 429 with retry-after so the CLI can
            //             back off deterministically.
            // 5xx upstream → keep 502 (gateway can't reach upstream).
            // anything else → 500 (proxy-internal / malformed).
            let (status, errType, extraHeaders): (Int, String, [String: String]) = {
                switch e {
                case .quotaExhausted(let retry):
                    var h: [String: String] = [:]
                    if let retry { h["retry-after"] = String(Int(retry)) }
                    return (429, "quota_exhausted", h)
                case .upstreamStatus(let code, _) where code >= 500:
                    return (502, "upstream_error", [:])
                case .upstreamStatus(let code, _):
                    return (code, "upstream_error", [:])
                default:
                    return (500, "mirage_error", [:])
                }
            }()
            let payload = (try? JSONSerialization.data(withJSONObject: [
                "error": ["type": errType, "message": e.errorDescription ?? "unknown"]
            ], options: [])) ?? Data("{}".utf8)
            await reply(on: connection, status: status, body: payload, close: true,
                        contentType: "application/json", extraHeaders: extraHeaders)
        } catch {
            let payload = (try? JSONSerialization.data(withJSONObject: ["error": ["type": "transport_error", "message": String(describing: error)]], options: [])) ?? Data("{}".utf8)
            await reply(on: connection, status: 502, body: payload, close: true, contentType: "application/json")
        }
    }

    /// Forward the request body to MirageBackendClient (streaming) and pipe
    /// the SSE bytes straight back to the loopback connection. HTTP/1.1
    /// chunked transfer keeps Claude Code's SSE parser happy.
    private func forwardStreaming(body: Data, on connection: NWConnection) async throws -> Bool {
        let (chunks, status) = try await MirageBackendClient.shared.sendStreamingChunks(body: body)
        // Emit status line + headers. Claude Code's SDK reads
        // `content-type: text/event-stream` and switches to SSE parse mode.
        let headerBlock =
            "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n" +
            "content-type: text/event-stream\r\n" +
            "cache-control: no-cache\r\n" +
            "transfer-encoding: chunked\r\n" +
            "\r\n"
        try await send(connection: connection, data: Data(headerBlock.utf8))
        for try await chunk in chunks {
            let sizeLine = String(format: "%X\r\n", chunk.count)
            var out = Data(sizeLine.utf8)
            out.append(chunk)
            out.append(Data("\r\n".utf8))
            try await send(connection: connection, data: out)
        }
        // Chunked-transfer terminator + connection close.
        try await send(connection: connection, data: Data("0\r\n\r\n".utf8))
        connection.cancel()
        return true
    }

    // MARK: - Low-level TCP send

    private func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Send a fixed-length HTTP/1.1 response (used for errors + 404).
    private func reply(
        on connection: NWConnection,
        status: Int,
        body: Data,
        close: Bool,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String: String] = [:]
    ) async {
        var header =
            "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n" +
            "content-type: \(contentType)\r\n" +
            "content-length: \(body.count)\r\n" +
            (close ? "connection: close\r\n" : "")
        // extraHeaders carries HTTP hints callers should surface — e.g.
        // Retry-After on 429 so the CLI can back off instead of hammering.
        for (name, value) in extraHeaders {
            header += "\(name.lowercased()): \(value)\r\n"
        }
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        try? await send(connection: connection, data: out)
        if close { connection.cancel() }
    }

    private func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default:  return "Status"
        }
    }
}

enum MirageRelayError: Error, LocalizedError {
    case startFailed
    var errorDescription: String? { "MirageLocalRelay failed to start" }
}
