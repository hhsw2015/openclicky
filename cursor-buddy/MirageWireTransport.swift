//
//  MirageWireTransport.swift
//  cursor-buddy
//
//  Low-level HTTP/2 client for the mirage protocol. Purpose: emit exactly the
//  header set the caller specifies, nothing more. URLSession/CFNetwork insist
//  on adding `Accept-Encoding: gzip, deflate, br`, `Accept-Language`,
//  `Priority`, and their own `User-Agent`. Those extras are the fingerprint we
//  are trying to erase, so we bypass Foundation's HTTP stack entirely and
//  drive the connection through SwiftNIO's HTTP/2 stack — the same posture
//  CPA uses on the Go side (`internal/runtime/executor/helps/utls_client.go`).
//
//  TLS is left to NIOSSL against the system trust store; the JA3 fingerprint
//  will still be Apple SecureTransport / BoringSSL (whichever NIOSSL binds).
//  This is a known limitation shared with the CPA Go path when uTLS is off:
//  the aegis-proxy Worker cannot inspect JA3 (Cloudflare Workers do not
//  surface TLS layer metadata to the JS runtime), and Cloudflare's edge
//  bot-management is not currently enabled on that hostname. If the upstream
//  ever gates on JA3, we swap in a rustls-shaped ClientHello via a native
//  binding.
//
//  This file compiles to an empty type when SwiftNIO is not yet linked so the
//  rest of the target keeps building. Add the SPM deps (swift-nio,
//  swift-nio-http2, swift-nio-ssl) and the real implementation lights up.
//
//  Reference: docs/mirage-openclicky-integration-plan.md §4.5.3.

import Foundation

#if canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOHTTP2) && canImport(NIOSSL) && canImport(NIOHPACK)
import NIOCore
import NIOPosix
import NIOHTTP2
import NIOSSL
import NIOHPACK

/// One HTTP request against a mirage-style upstream. The caller supplies the
/// exact wire header set; the transport does not add or reorder anything.
/// Header names must be lowercase (HTTP/2 forbids uppercase names on the
/// wire; NIOHPACK will encode whatever we give it).
struct MirageWireRequest {
    /// Fully-qualified URL. Only https:// is supported (upstream is TLS).
    let url: URL
    /// HTTP method, uppercase (e.g. "POST").
    let method: String
    /// Lowercase header pairs in insertion order. NIOHPACK preserves order.
    let headers: [(String, String)]
    /// Body bytes. Empty Data() for GET/HEAD.
    let body: Data
}

/// The response: status + headers + streaming body.
struct MirageWireResponse {
    let status: Int
    let headers: HPACKHeaders
    /// AsyncSequence of body chunks as they arrive from the peer.
    let body: AsyncThrowingStream<ByteBuffer, Error>
}

/// One-shot HTTP/2 client. Each request opens a fresh connection — no pool,
/// no keep-alive, matching how the reference Rust client behaves under
/// reqwest's default connection settings (a single stream per turn).
/// Connection pooling is a future optimization; correctness first.
///
/// Thread-safety: this is a stateless factory. All state lives on the
/// per-request `MultiThreadedEventLoopGroup` we tear down at the end of
/// each send. That is cheap for our low-QPS use case (one request per voice
/// turn, plus token mints).
enum MirageWireTransport {
    // Process-wide event loop group and NIOSSLContext. Building these
    // per-request costs 150-350 ms (thread spawn + TLS ctx init) and, on
    // integration turns that fire two or three Anthropic calls back to
    // back, that adds up to ~1.5 s of pure setup latency vs. Peeky Rust's
    // shared `reqwest::Client`. The connection itself is still opened
    // fresh per request (no HTTP/2 pooling yet) so we do not accumulate
    // long-lived state on the socket — but the loop and TLS context are
    // safe to reuse across requests.
    private static let sharedGroup: MultiThreadedEventLoopGroup = {
        MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }()

    private static let sharedSSLContext: NIOSSLContext = {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.applicationProtocols = ["h2"]
        // If TLS context construction fails at boot, fall through with a
        // default config so the transport can still surface a clean
        // `.tls` error on send() instead of trapping the whole process.
        do {
            return try NIOSSLContext(configuration: tlsConfig)
        } catch {
            NSLog("[MirageWire] SSL context init failed: %@ — falling back to default", "\(error)")
            return try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        }
    }()

    /// Send one request and return once headers are in. The body stream is
    /// consumed lazily by the caller. When the stream completes or the caller
    /// drops the iterator, the connection tears down.
    ///
    /// Errors:
    /// - MirageWireError.badURL / .unsupportedScheme when URL is malformed
    /// - MirageWireError.tls / .connect on transport failures
    /// - HPACKHeaders may contain no `:status` on a broken peer — we surface
    ///   MirageWireError.missingStatus in that case.
    static func send(_ request: MirageWireRequest) async throws -> MirageWireResponse {
        guard let host = request.url.host else { throw MirageWireError.badURL }
        guard request.url.scheme?.lowercased() == "https" else { throw MirageWireError.unsupportedScheme }
        let port = request.url.port ?? 443
        let pathAndQuery: String = {
            var s = request.url.path.isEmpty ? "/" : request.url.path
            if let q = request.url.query, !q.isEmpty { s += "?" + q }
            return s
        }()

        let group = sharedGroup
        let sslContext = sharedSSLContext

        // Bootstrap a plain TCP client, layer TLS on top, then HTTP/2. We
        // request a single stream, send the request, then close.
        // 15s connect timeout — Rust reqwest defaults to it, without a cap
        // a blackholed route (aegis-proxy unreachable, GFW rst, etc.)
        // hangs the actor forever instead of failing over.
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(15))

        let (headers, bodyStream) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(HPACKHeaders, AsyncThrowingStream<ByteBuffer, Error>), Error>) in
            var didResume = false
            let (bodyStream, bodyContinuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()

            let channelFuture = bootstrap.connect(host: host, port: port).flatMap { channel -> EventLoopFuture<Void> in
                do {
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        // HTTP/2 pipeline. `initialLocalSettings` uses NIO's
                        // built-in defaults when we pass nil (the parameter is
                        // Optional in swift-nio-http2 1.x).
                        return channel.configureHTTP2Pipeline(
                            mode: .client,
                            inboundStreamInitializer: nil
                        ).flatMap { multiplexer in
                            // Create the request stream.
                            let promise = channel.eventLoop.makePromise(of: Channel.self)
                            multiplexer.createStreamChannel(promise: promise) { streamChannel in
                                let requestHandler = MirageStreamHandler(
                                    method: request.method,
                                    scheme: "https",
                                    authority: host + (port == 443 ? "" : ":\(port)"),
                                    path: pathAndQuery,
                                    userHeaders: request.headers,
                                    body: request.body,
                                    onHeaders: { hpack in
                                        if !didResume {
                                            didResume = true
                                            cont.resume(returning: (hpack, bodyStream))
                                        }
                                    },
                                    onData: { chunk in
                                        bodyContinuation.yield(chunk)
                                    },
                                    onEnd: {
                                        bodyContinuation.finish()
                                    },
                                    onError: { error in
                                        if !didResume {
                                            didResume = true
                                            cont.resume(throwing: error)
                                        }
                                        bodyContinuation.finish(throwing: error)
                                    }
                                )
                                return streamChannel.pipeline.addHandler(requestHandler)
                            }
                            return promise.futureResult.map { _ in () }
                        }
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            channelFuture.whenFailure { error in
                if !didResume {
                    didResume = true
                    cont.resume(throwing: MirageWireError.connect(error))
                }
                bodyContinuation.finish(throwing: error)
            }
        }

        // The event-loop group is process-wide (see sharedGroup); do NOT
        // shut it down here. The per-request work happens on one HTTP/2
        // stream inside the shared group; when the peer sends END_STREAM
        // the stream channel closes on its own and the TCP connection is
        // torn down by NIO. `_ = group` keeps the reference alive for
        // readers of this function; nothing else to do.
        _ = group

        guard let statusStr = headers.first(name: ":status"), let status = Int(statusStr) else {
            throw MirageWireError.missingStatus
        }
        return MirageWireResponse(status: status, headers: headers, body: bodyStream)
    }
}

/// Per-stream handler: sends the request on activation, forwards inbound
/// HEADERS/DATA to the caller's callbacks. Duplex because we write frames
/// (HEADERS + DATA) to the pipeline in channelActive.
private final class MirageStreamHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let method: String
    private let scheme: String
    private let authority: String
    private let path: String
    private let userHeaders: [(String, String)]
    private let body: Data
    private let onHeaders: (HPACKHeaders) -> Void
    private let onData: (ByteBuffer) -> Void
    private let onEnd: () -> Void
    private let onError: (Error) -> Void

    init(method: String,
         scheme: String,
         authority: String,
         path: String,
         userHeaders: [(String, String)],
         body: Data,
         onHeaders: @escaping (HPACKHeaders) -> Void,
         onData: @escaping (ByteBuffer) -> Void,
         onEnd: @escaping () -> Void,
         onError: @escaping (Error) -> Void) {
        self.method = method
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.userHeaders = userHeaders
        self.body = body
        self.onHeaders = onHeaders
        self.onData = onData
        self.onEnd = onEnd
        self.onError = onError
    }

    func channelActive(context: ChannelHandlerContext) {
        // Build HEADERS frame. Order: pseudo-headers first, then user headers
        // exactly as supplied. NIOHPACK preserves order.
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: method)
        headers.add(name: ":scheme", value: scheme)
        headers.add(name: ":authority", value: authority)
        headers.add(name: ":path", value: path)
        for (k, v) in userHeaders {
            headers.add(name: k, value: v)
        }

        // Debug: log the exact wire header set so we can compare against the
        // CPA reference client. Enabled only when MIRAGE_WIRE_LOG env var is
        // set to avoid burning perf on production paths. Prints once per
        // request; the caller can pattern-match `[mirage-wire]` in Console.app.
        if ProcessInfo.processInfo.environment["MIRAGE_WIRE_LOG"] != nil {
            let dump = headers.map { "  \($0.name): \($0.value)" }.joined(separator: "\n")
            NSLog("[mirage-wire] outbound HEADERS on stream:\n\(dump)")
        }
        let endStream = body.isEmpty
        let headersPayload = HTTP2Frame.FramePayload.Headers(headers: headers, endStream: endStream)
        context.writeAndFlush(self.wrapOutboundOut(.headers(headersPayload)), promise: nil)

        if !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            let dataPayload = HTTP2Frame.FramePayload.Data(data: .byteBuffer(buffer), endStream: true)
            context.writeAndFlush(self.wrapOutboundOut(.data(dataPayload)), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        switch payload {
        case .headers(let h):
            onHeaders(h.headers)
        case .data(let d):
            if case .byteBuffer(let buf) = d.data {
                onData(buf)
            }
            if d.endStream { onEnd() }
        case .rstStream(let code):
            onError(MirageWireError.streamReset(UInt32(code.networkCode)))
        case .goAway(_, let code, _):
            onError(MirageWireError.goAway(UInt32(code.networkCode)))
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

enum MirageWireError: Error, LocalizedError {
    case badURL
    case unsupportedScheme
    case tls(Error)
    case connect(Error)
    case missingStatus
    case streamReset(UInt32)
    case goAway(UInt32)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Mirage transport: malformed URL"
        case .unsupportedScheme: return "Mirage transport: only https is supported"
        case .tls(let e): return "Mirage transport TLS: \(e)"
        case .connect(let e): return "Mirage transport connect: \(e)"
        case .missingStatus: return "Mirage transport: response missing :status"
        case .streamReset(let code): return "Mirage transport: RST_STREAM code=\(code)"
        case .goAway(let code): return "Mirage transport: GOAWAY code=\(code)"
        }
    }
}

#else

// SwiftNIO not linked yet. Provide stubs so the target compiles. When the
// SPM deps land, this branch drops out and the real implementation takes
// over.

struct MirageWireRequest {
    let url: URL
    let method: String
    let headers: [(String, String)]
    let body: Data
}

struct MirageWireResponse {
    let status: Int
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>
}

enum MirageWireTransport {
    static func send(_ request: MirageWireRequest) async throws -> MirageWireResponse {
        throw MirageWireError.notLinked
    }
}

enum MirageWireError: Error, LocalizedError {
    case notLinked
    var errorDescription: String? {
        "MirageWireTransport requires SwiftNIO (swift-nio + swift-nio-http2 + swift-nio-ssl). Add them via File → Add Package Dependencies in Xcode."
    }
}

#endif
