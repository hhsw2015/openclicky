// JSONRPC.swift — hand-rolled JSON-RPC 2.0 wire format for MCP stdio.
//
// The Model Context Protocol frames messages with LSP-style headers:
//
//     Content-Length: <N>\r\n
//     \r\n
//     <N bytes of UTF-8 JSON>
//
// We do NOT depend on any third-party library. Encoding uses
// `JSONSerialization` because tool results are heterogeneous
// `[String: Any]` dicts and forcing everything through `Codable`
// generic containers would balloon this file.
//
// Message shapes (JSON-RPC 2.0):
//   • request       : {jsonrpc, id, method, params?}
//   • notification  : {jsonrpc, method, params?}         (no id)
//   • response      : {jsonrpc, id, result}
//   • error         : {jsonrpc, id, error: {code, message, data?}}

import Foundation

// MARK: - IDs

/// JSON-RPC ids may be integers, strings, or null. We preserve the
/// original wire form so responses echo the same shape.
public enum RPCID: Sendable, Hashable {
    case int(Int64)
    case string(String)
    case null

    static func decode(_ any: Any?) -> RPCID {
        if let n = any as? NSNumber { return .int(n.int64Value) }
        if let s = any as? String { return .string(s) }
        return .null
    }

    var jsonValue: Any {
        switch self {
        case .int(let n):    return NSNumber(value: n)
        case .string(let s): return s
        case .null:          return NSNull()
        }
    }
}

// MARK: - Errors

public struct RPCError: Error, Sendable {
    public let code: Int
    public let message: String
    public let data: [String: String]?

    public init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code; self.message = message; self.data = data
    }

    // Standard codes.
    public static func parseError(_ msg: String) -> RPCError {
        .init(code: -32700, message: "Parse error: \(msg)")
    }
    public static func invalidRequest(_ msg: String) -> RPCError {
        .init(code: -32600, message: "Invalid request: \(msg)")
    }
    public static func methodNotFound(_ name: String) -> RPCError {
        .init(code: -32601, message: "Method not found: \(name)")
    }
    public static func invalidParams(_ msg: String) -> RPCError {
        .init(code: -32602, message: "Invalid params: \(msg)")
    }
    public static func internalError(_ msg: String) -> RPCError {
        .init(code: -32603, message: "Internal error: \(msg)")
    }
}

// MARK: - Message model

public struct RPCRequest: Sendable {
    public let id: RPCID?          // nil == notification
    public let method: String
    public let params: [String: Any]

    public var isNotification: Bool { id == nil }
}

extension RPCRequest {
    // `[String: Any]` isn't Sendable but each `RPCRequest` value crosses
    // the actor boundary once and is treated as immutable. The two
    // callers that construct one both build a fresh dictionary.
}

// MARK: - Parsing

public enum JSONRPC {

    /// Parse a single JSON-RPC message from a UTF-8 byte buffer.
    public static func decode(_ data: Data) throws -> RPCRequest {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw RPCError.parseError(error.localizedDescription)
        }
        guard let obj = raw as? [String: Any] else {
            throw RPCError.invalidRequest("top-level JSON must be an object")
        }
        guard let version = obj["jsonrpc"] as? String, version == "2.0" else {
            throw RPCError.invalidRequest("missing or wrong jsonrpc version")
        }
        guard let method = obj["method"] as? String else {
            throw RPCError.invalidRequest("missing method")
        }
        let id: RPCID? = obj["id"].map { RPCID.decode($0) }
        let params = (obj["params"] as? [String: Any]) ?? [:]
        return RPCRequest(id: id, method: method, params: params)
    }

    /// Encode a successful response.
    public static func encodeResult(id: RPCID, result: Any) throws -> Data {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result
        ]
        return try JSONSerialization.data(withJSONObject: envelope,
                                          options: [.sortedKeys])
    }

    /// Encode an error response. `id` may be null when the incoming
    /// message could not be parsed.
    public static func encodeError(id: RPCID, error: RPCError) throws -> Data {
        var errObj: [String: Any] = [
            "code": error.code,
            "message": error.message
        ]
        if let data = error.data { errObj["data"] = data }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": errObj
        ]
        return try JSONSerialization.data(withJSONObject: envelope,
                                          options: [.sortedKeys])
    }
}

// MARK: - Framing

/// LSP-style `Content-Length` framing over an arbitrary byte stream.
/// This is the exact wire format used by the Model Context Protocol.
///
/// We keep the state machine in a class because it owns a mutable
/// buffer; it lives on the main-thread reader loop and is never shared.
public final class MessageFramer {

    public enum FramerError: Error, Sendable {
        case badHeader(String)
    }

    private var buffer = Data()

    public init() {}

    /// Feed raw bytes; return zero-or-more complete message payloads.
    public func consume(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        while true {
            // Find header terminator.
            guard let headerEnd = range(of: [0x0d, 0x0a, 0x0d, 0x0a]) else {
                break
            }
            let headerBytes = buffer.prefix(headerEnd.lowerBound)
            guard let header = String(data: headerBytes, encoding: .utf8) else {
                throw FramerError.badHeader("non-utf8 header")
            }
            var length: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if name == "content-length" {
                    length = Int(value)
                }
            }
            guard let n = length, n >= 0 else {
                throw FramerError.badHeader("no Content-Length")
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + n
            guard buffer.count >= bodyEnd else { break }
            let body = buffer.subdata(in: bodyStart ..< bodyEnd)
            out.append(body)
            buffer.removeSubrange(0 ..< bodyEnd)
        }
        return out
    }

    /// Locate the CRLFCRLF terminator inside the current buffer.
    private func range(of needle: [UInt8]) -> Range<Int>? {
        guard buffer.count >= needle.count else { return nil }
        let last = buffer.count - needle.count
        var i = 0
        while i <= last {
            var match = true
            for j in 0 ..< needle.count where buffer[i + j] != needle[j] {
                match = false; break
            }
            if match { return i ..< (i + needle.count) }
            i += 1
        }
        return nil
    }

    /// Wrap an already-encoded payload with a Content-Length header.
    public static func frame(_ payload: Data) -> Data {
        var out = Data()
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        out.append(header.data(using: .utf8)!)
        out.append(payload)
        return out
    }
}
