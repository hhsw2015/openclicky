//
//  AssistAgentParallel.swift
//  cursor-buddy
//
//  Parallel sub-agent dispatcher — Swift port of parallel.py.
//  Fires N independent AssistAgentLoop runs concurrently via
//  Swift Concurrency's TaskGroup, one credential per sub-agent
//  (falls back to the primary account when the extra-account
//  pool is empty), then waits for all before returning.
//
//  Guards:
//    · Nested dispatch is blocked (TaskLocal fork-bomb check).
//    · Max 8 concurrent subs — same cap as Python.
//    · Each sub-agent's tools resolve paths against ITS workdir,
//      not the process cwd, so parallel writes don't collide.
//

import Foundation

public struct AssistAgentSubTask: Sendable {
    public let id: String
    public let prompt: String
    /// Absolute path preferred; relative resolves against process cwd.
    public let workdir: String
    public let maxRounds: Int
    public init(id: String, prompt: String, workdir: String, maxRounds: Int = 6) {
        self.id = id
        self.prompt = prompt
        self.workdir = workdir
        self.maxRounds = maxRounds
    }
}

public struct AssistAgentSubResult: Sendable {
    public let id: String
    public let ok: Bool
    public let rounds: Int
    public let elapsedSec: Double
    public let filesTouched: [String]
    public let finalText: String
    public let errorText: String
    public let credential: String
}

public enum AssistAgentParallelError: Error, Sendable {
    case nestedDispatchForbidden
    case noTasks
}

/// Signature for spawning a sub-agent — pluggable so the dispatcher
/// doesn't need to know about `HeyClickyChatToolCallClient`. The
/// concrete implementation (Stage 10) constructs an AssistAgentLoop
/// bound to `credential` and runs it against `task`.
public protocol AssistAgentSubagentRunner: Sendable {
    func run(task: AssistAgentSubTask,
             credential: AssistAgentCredential) async throws -> AssistAgentSubResult
}

/// A credential handle — either the primary signed-in session, or
/// one of the extra accounts exported to disk.
public struct AssistAgentCredential: Sendable {
    public let email: String
    public let accessToken: String
    public let refreshToken: String
    public init(email: String, accessToken: String, refreshToken: String) {
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Convenience — build from a discovered extra account.
    public static func from(_ acc: AssistAgentAccount) -> AssistAgentCredential {
        .init(email: acc.email,
              accessToken: acc.accessToken,
              refreshToken: acc.refreshToken)
    }
}

/// TaskLocal fork-bomb flag. When true, we're already inside a
/// dispatched sub-agent — nested dispatch is rejected.
public enum AssistAgentParallelContext {
    @TaskLocal public static var inDispatch: Bool = false
}

@MainActor
public final class AssistAgentParallelDispatcher {

    private let runner: AssistAgentSubagentRunner
    private let maxConcurrent: Int

    public init(runner: AssistAgentSubagentRunner, maxConcurrent: Int = 8) {
        self.runner = runner
        self.maxConcurrent = maxConcurrent
    }

    /// Fire `tasks` in parallel, wait for all, return in the same
    /// order as input. Each sub-agent gets a distinct credential
    /// (or the primary when the pool is small).
    public func dispatchWaitAll(
        tasks: [AssistAgentSubTask],
        primary: AssistAgentCredential
    ) async throws -> [AssistAgentSubResult] {
        if AssistAgentParallelContext.inDispatch {
            throw AssistAgentParallelError.nestedDispatchForbidden
        }
        if tasks.isEmpty { throw AssistAgentParallelError.noTasks }

        // Build the credential rotation: primary + all extras.
        let extras = AssistAgentAccounts.loadAll().map { AssistAgentCredential.from($0) }
        var pool: [AssistAgentCredential] = [primary] + extras
        // Dedup by email — primary may also appear in `extras` if the
        // user has exported its tokens.
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.email).inserted }
        if pool.isEmpty { pool = [primary] }

        let cap = min(maxConcurrent, tasks.count)
        // Distribute credentials by rotating through the pool.
        var assignments: [(AssistAgentSubTask, AssistAgentCredential)] = []
        for (i, task) in tasks.enumerated() {
            assignments.append((task, pool[i % pool.count]))
        }

        let runner = self.runner
        return try await withThrowingTaskGroup(of: (Int, AssistAgentSubResult).self) { group in
            for (index, pair) in assignments.enumerated() {
                let (task, cred) = pair
                if index >= cap {
                    // Cheap backpressure: wait for one slot before adding more.
                    if let first = try await group.next() {
                        _ = first
                    }
                }
                group.addTask {
                    try await AssistAgentParallelContext.$inDispatch.withValue(true) {
                        let started = Date()
                        AssistAgentAccounts.markUsed(cred.email)
                        do {
                            let result = try await runner.run(task: task, credential: cred)
                            AssistAgentAccounts.recordResult(cred.email, ok: result.ok)
                            return (index, result)
                        } catch {
                            AssistAgentAccounts.recordResult(cred.email, ok: false)
                            return (index, AssistAgentSubResult(
                                id: task.id, ok: false, rounds: 0,
                                elapsedSec: Date().timeIntervalSince(started),
                                filesTouched: [], finalText: "",
                                errorText: "\(error)",
                                credential: cred.email))
                        }
                    }
                }
            }
            var slots = [(Int, AssistAgentSubResult)]()
            for try await pair in group { slots.append(pair) }
            slots.sort { $0.0 < $1.0 }
            return slots.map { $0.1 }
        }
    }
}
