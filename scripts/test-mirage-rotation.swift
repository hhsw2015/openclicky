#!/usr/bin/env swift
//
//  test-mirage-rotation.swift
//  Verify counter-based UUID rotation: same UUID reused across N requests,
//  auto-rotates at rotateAt threshold, forceRotate on 429.
//

import Foundation

let endpoint = URL(string:
    (ProcessInfo.processInfo.environment["AEGIS_PROXY_BASE"] ?? "") + "/v1/anthropic/messages"
)!
let userAgent = "reqwest/0.13.4"

// Actor mirroring MirageBackendClient's core rotation semantics.
actor Pool {
    private var deviceID = UUID().uuidString.lowercased()
    private var counter = 0
    private let rotateAt: Int

    init(rotateAt: Int) { self.rotateAt = rotateAt }

    func next() -> (id: String, counter: Int, rotated: Bool) {
        var rotated = false
        if counter >= rotateAt {
            deviceID = UUID().uuidString.lowercased()
            counter = 0
            rotated = true
        }
        counter += 1
        return (deviceID, counter, rotated)
    }

    func forceRotate() {
        deviceID = UUID().uuidString.lowercased()
        counter = 1
    }
}

let pool = Pool(rotateAt: 17)
let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = 30
let session = URLSession(configuration: cfg)

func hit(prompt: String) async -> (status: Int, uuid: String, counter: Int, rotated: Bool) {
    let (uuid, cnt, rotated) = await pool.next()
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json",    forHTTPHeaderField: "content-type")
    req.setValue("2023-06-01",          forHTTPHeaderField: "anthropic-version")
    req.setValue(uuid,                  forHTTPHeaderField: "x-peeky-device-id")
    req.setValue(userAgent,             forHTTPHeaderField: "user-agent")
    req.setValue("*/*",                 forHTTPHeaderField: "accept")
    req.httpBody = try! JSONSerialization.data(withJSONObject: [
        "model": "claude-haiku-4-5-20251001",  // cheapest for counting
        "max_tokens": 5,
        "stream": false,
        "messages": [["role": "user", "content": prompt]]
    ])
    let status: Int
    do {
        let (_, resp) = try await session.data(for: req)
        status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    } catch {
        status = -2
    }
    if status == 429 { await pool.forceRotate() }
    return (status, uuid, cnt, rotated)
}

let sema = DispatchSemaphore(value: 0)
Task {
    print("Sending 22 requests to observe rotation…\n")
    print("req | status | uuid (first 8)      | counter | rotated")
    print("----+--------+---------------------+---------+--------")
    var uniqueUUIDs = Set<String>()
    for i in 1...22 {
        let r = await hit(prompt: "hi")
        uniqueUUIDs.insert(r.uuid)
        let short = String(r.uuid.prefix(8))
        print(String(format: "%3d | %6d | %@ | %7d | %@",
                     i, r.status, short, r.counter, r.rotated ? "YES" : "-"))
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms pacing
    }
    print("\nUnique UUIDs seen: \(uniqueUUIDs.count)")
    print("Expected: 2 (rotation at count 18 → new UUID for reqs 18-22)")
    sema.signal()
}
sema.wait()
