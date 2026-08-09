//
//  AssistAgentMCP.swift
//  cursor-buddy
//
//  Minimal MCP (Model Context Protocol) client. Spawns configured
//  servers as stdio subprocesses, discovers their tools, and exposes
//  them under names like `mcp:<server>:<tool>` so the assist agent's
//  dispatcher can invoke them the same way as built-in tools.
//
//  Config at ~/.heyclicky-agent/mcp.json:
//    { "servers": { "fs": { "command": "npx",
//                            "args": ["@modelcontextprotocol/server-filesystem", "/tmp"],
//                            "env": {"FOO":"bar"} } } }
//
//  Framing: line-delimited JSON-RPC 2.0 over stdin/stdout.
//  Trimmed vs Python: stdio transport only (no HTTP variant here — App
//  can add later if needed).
//

import Foundation

public struct AssistAgentMCPTool: Sendable {
    public let server: String
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public var canonicalName: String { "mcp:\(server):\(name)" }

    public init(server: String, name: String, description: String,
                inputSchema: [String: Any] = [:]) {
        self.server = server
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}
extension AssistAgentMCPTool: @unchecked Sendable {}

public actor AssistAgentMCPServer {
    public let name: String
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var reqID: Int = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer: Data = Data()
    private var alive: Bool = false
    public private(set) var tools: [AssistAgentMCPTool] = []

    public init(name: String, command: String, args: [String], env: [String: String]) {
        self.name = name
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()
        process.launchPath = command
        process.arguments = args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        process.environment = mergedEnv
    }

    public func start(initTimeout: TimeInterval = 10) async throws {
        try process.run()
        Task.detached { [weak self] in
            await self?.readLoop()
        }
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "openclicky-assist-agent", "version": "0.1"]
        ], timeout: initTimeout)
        notify("notifications/initialized", params: [:])
        alive = true
        let listResp = try await request("tools/list", params: [:], timeout: initTimeout)
        var discovered: [AssistAgentMCPTool] = []
        if let arr = listResp["tools"] as? [[String: Any]] {
            for t in arr {
                let name = (t["name"] as? String) ?? ""
                if name.isEmpty { continue }
                discovered.append(AssistAgentMCPTool(
                    server: self.name, name: name,
                    description: (t["description"] as? String) ?? "",
                    inputSchema: (t["inputSchema"] as? [String: Any]) ?? [:]))
            }
        }
        tools = discovered
    }

    public func callTool(name: String, args: [String: Any],
                        timeout: TimeInterval = 60) async throws -> [String: Any] {
        try await request("tools/call",
                          params: ["name": name, "arguments": args],
                          timeout: timeout)
    }

    public func stop() {
        alive = false
        if process.isRunning { process.terminate() }
    }

    // MARK: - JSON-RPC transport

    private func nextID() -> Int { reqID += 1; return reqID }

    private func writeLine(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    private func notify(_ method: String, params: [String: Any]) {
        writeLine(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func request(_ method: String, params: [String: Any],
                        timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID()
        writeLine(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerPending(id: id, cont: cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPError.timeout(method: method)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func registerPending(id: Int,
                                cont: CheckedContinuation<[String: Any], Error>) {
        pending[id] = cont
    }

    private func resolvePending(_ id: Int, result: [String: Any]) {
        if let c = pending.removeValue(forKey: id) { c.resume(returning: result) }
    }

    private func failPending(_ id: Int, error: Error) {
        if let c = pending.removeValue(forKey: id) { c.resume(throwing: error) }
    }

    private func readLoop() async {
        let handle = stdoutPipe.fileHandleForReading
        while process.isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000); continue }
            await ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let idNum = obj["id"] as? Int {
                if let error = obj["error"] as? [String: Any] {
                    failPending(idNum, error: MCPError.remote(error))
                } else {
                    let result = (obj["result"] as? [String: Any]) ?? [:]
                    resolvePending(idNum, result: result)
                }
            }
        }
    }
}

public enum MCPError: Error, Sendable {
    case timeout(method: String)
    case remote([String: Any])
    case configInvalid(String)
}
extension MCPError: @unchecked Sendable {}

/// Registry of started MCP servers. Shared singleton to match Python
/// `mcp.get_registry()` semantics.
public actor AssistAgentMCPRegistry {
    public static let shared = AssistAgentMCPRegistry()

    private var servers: [String: AssistAgentMCPServer] = [:]

    public static let configPath: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".heyclicky-agent/mcp.json")

    /// Load config + start every server. Idempotent — already-started
    /// servers are skipped.
    public func startAll() async {
        guard let data = try? Data(contentsOf: Self.configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = obj["servers"] as? [String: [String: Any]] else {
            return
        }
        for (name, cfg) in dict {
            if servers[name] != nil { continue }
            let command = (cfg["command"] as? String) ?? ""
            let args = (cfg["args"] as? [String]) ?? []
            let env = (cfg["env"] as? [String: String]) ?? [:]
            guard !command.isEmpty else { continue }
            let srv = AssistAgentMCPServer(
                name: name, command: command, args: args, env: env)
            do {
                try await srv.start()
                servers[name] = srv
            } catch {
                // Non-fatal — one bad MCP server shouldn't block agent boot.
                continue
            }
        }
    }

    public func allTools() async -> [AssistAgentMCPTool] {
        var out: [AssistAgentMCPTool] = []
        for (_, srv) in servers {
            out.append(contentsOf: await srv.tools)
        }
        return out
    }

    /// Route a canonical `mcp:<server>:<tool>` call.
    public func call(canonical: String, args: [String: Any]) async throws -> [String: Any] {
        let parts = canonical.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "mcp",
              let srv = servers[parts[1]] else {
            throw MCPError.configInvalid("unknown MCP tool: \(canonical)")
        }
        return try await srv.callTool(name: parts[2], args: args)
    }

    public func stopAll() async {
        for (_, srv) in servers { await srv.stop() }
        servers.removeAll()
    }
}
