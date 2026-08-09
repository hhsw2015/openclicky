//
//  AssistAgentSubagentRunner.swift
//  cursor-buddy
//
//  Concrete runner for `AssistAgentParallelDispatcher`. Each sub-agent
//  gets its own AssistAgentDirectTransport bound to a specific
//  exported account, its own session, and its own tool dispatcher.
//  Parent context is NEVER shared — each sub starts fresh with just
//  the prompt text (Python parity: parallel.py).
//
//  Wire path:
//    tool call `dispatch_parallel` → AssistAgentBuiltInTools →
//    AssistAgentParallelDispatcher.dispatchWaitAll(tasks:, primary:) →
//    this runner (per task) → AssistAgentLoop.run() →
//    subagent result → aggregated summary
//

import Foundation

/// Default runner used by the assist agent's `dispatch_parallel`
/// tool. Each spawn constructs a fresh loop bound to `credential`.
public struct AssistAgentDefaultSubagentRunner: AssistAgentSubagentRunner {
    public init() {}

    public func run(task: AssistAgentSubTask,
                    credential: AssistAgentCredential) async throws -> AssistAgentSubResult
    {
        let started = Date()
        // Fresh transport pinned to the credential's account.
        let transport = await MainActor.run {
            AssistAgentDirectTransport.forCredential(credential)
        }
        let dispatcher = await MainActor.run { AssistAgentBuiltInTools() }
        let session = await MainActor.run {
            AssistAgentSession(userTask: task.prompt)
        }
        let system = AssistAgentPrompt.loopSystemPrompt(
            goal: task.prompt,
            workdir: task.workdir,
            maxRounds: task.maxRounds)
        let loop = await MainActor.run {
            AssistAgentLoop(session: session,
                            transport: transport,
                            dispatcher: dispatcher,
                            systemPrompt: system,
                            maxRounds: task.maxRounds)
        }
        // Register with UI so notch shows sub-agent progress rows.
        _ = await MainActor.run {
            AssistAgentRegistry.shared.bindEventStream(
                session, label: "sub:\(task.id)", email: credential.email)
        }
        do {
            let result = try await loop.run()
            let filesTouched = await MainActor.run {
                session.steps.compactMap { step -> String? in
                    guard AssistAgentCompactionConstants.editKinds.contains(step.kind),
                          step.ok else { return nil }
                    return step.args["path"]
                }
            }
            return AssistAgentSubResult(
                id: task.id, ok: true,
                rounds: result.rounds,
                elapsedSec: Date().timeIntervalSince(started),
                filesTouched: Array(Set(filesTouched)),
                finalText: result.summary,
                errorText: "",
                credential: credential.email)
        } catch {
            return AssistAgentSubResult(
                id: task.id, ok: false, rounds: 0,
                elapsedSec: Date().timeIntervalSince(started),
                filesTouched: [], finalText: "",
                errorText: "\(error)",
                credential: credential.email)
        }
    }
}
