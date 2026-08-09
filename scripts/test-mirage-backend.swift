#!/usr/bin/env swift
//
//  test-mirage-backend.swift
//  Standalone verification of MirageBackendClient — no Xcode build needed.
//
//  Runs the same wire-format request MirageBackendClient produces (rotating
//  UUID header, lowercase headers, reqwest/0.13.4 UA, no accept-encoding),
//  hits the live aegis-proxy Worker, and streams a real Claude response.
//
//  Usage:
//    swift scripts/test-mirage-backend.swift
//    swift scripts/test-mirage-backend.swift --model mirage/claude-opus-5
//    swift scripts/test-mirage-backend.swift --model mirage/claude-fable-5 --prompt "count to 5"
//
//  The script duplicates a small, self-contained subset of
//  MirageBackendClient.swift so it can run without importing the OpenClicky
//  target. Keep the two in sync — the header contract in this file MUST
//  match what MirageBackendClient sends on the wire.

import Foundation

// MARK: - Wire constants (mirror MirageBackendClient.swift)

let endpoint = URL(string:
    (ProcessInfo.processInfo.environment["AEGIS_PROXY_BASE"] ?? "") + "/v1/anthropic/messages"
)!
let deviceHeader = "x-peeky-device-id"
let userAgent   = "reqwest/0.13.4"

// MARK: - Argument parsing

var model  = "mirage/claude-fable-5"
var prompt = "Say hi in exactly three words."
var maxTok = 50

var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIt.next() {
    switch a {
    case "--model":  model  = argIt.next() ?? model
    case "--prompt": prompt = argIt.next() ?? prompt
    case "--max":    maxTok = Int(argIt.next() ?? "") ?? maxTok
    case "-h", "--help":
        print("""
        Usage: swift test-mirage-backend.swift [--model X] [--prompt Y] [--max N]
          --model   catalog id, e.g. mirage/claude-fable-5 (default)
          --prompt  user text
          --max     max_tokens (default 50)
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("Unknown flag: \(a)\n".utf8))
        exit(2)
    }
}

// MARK: - Prefix strip (mirror normalizeBody)

let outboundModel: String = {
    if model.hasPrefix("mirage/") { return String(model.dropFirst("mirage/".count)) }
    return model
}()

// MARK: - Body

let bodyDict: [String: Any] = [
    "model":      outboundModel,
    "max_tokens": maxTok,
    "stream":     true,
    "messages":   [["role": "user", "content": prompt]]
]
let bodyData = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

// MARK: - Request

let deviceID = UUID().uuidString.lowercased()
var req = URLRequest(url: endpoint)
req.httpMethod = "POST"
req.httpBody   = bodyData
// Exact same header set MirageBackendClient.mirageHeaders emits.
req.setValue("application/json",  forHTTPHeaderField: "content-type")
req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
req.setValue(deviceID,            forHTTPHeaderField: deviceHeader)
req.setValue(userAgent,           forHTTPHeaderField: "user-agent")
req.setValue("*/*",               forHTTPHeaderField: "accept")

print("┌─ Mirage wire test")
print("│  endpoint: \(endpoint.absoluteString)")
print("│  device:   \(deviceID)")
print("│  model:    catalog=\(model)  →  wire=\(outboundModel)")
print("│  prompt:   \(prompt)")
print("│  max_tok:  \(maxTok)")
print("└─")
print("")

// MARK: - Streaming SSE

let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = 60
let session = URLSession(configuration: cfg)

let sema = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        let start = Date()
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            print("✗ Not HTTPURLResponse")
            exitCode = 1
            sema.signal()
            return
        }
        print("HTTP \(http.statusCode)   ttfb=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        print("─ response headers")
        for (k, v) in http.allHeaderFields {
            print("  \(k): \(v)")
        }
        print("─ stream")

        guard http.statusCode == 200 else {
            var buf = Data()
            for try await b in bytes { buf.append(b) }
            print(String(data: buf, encoding: .utf8) ?? "<non-utf8>")
            exitCode = Int32(http.statusCode == 429 ? 3 : 1)
            sema.signal()
            return
        }

        var acc = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { break }
            guard let jd = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                if let d = obj["delta"] as? [String: Any],
                   d["type"] as? String == "text_delta",
                   let t = d["text"] as? String {
                    acc += t
                    FileHandle.standardOutput.write(Data(t.utf8))
                }
            case "message_stop":
                break
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "?"
                print("\n✗ error event: \(msg)")
                exitCode = 1
            default:
                break
            }
        }
        print("\n─ done  chars=\(acc.count)  elapsed=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    } catch {
        print("✗ transport error: \(error)")
        exitCode = 1
    }
    sema.signal()
}

sema.wait()
exit(exitCode)
