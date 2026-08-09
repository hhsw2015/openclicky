//
//  CodexAgentSession+HeyClicky.swift
//  cursor-buddy
//
//  HeyClicky Free preamble + teardown for the Codex agent lane.
//  See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §5.4.
//

import Foundation

extension CodexAgentSession {
    /// Runs the four-step §5.4 preamble before Codex spawn. Any post-
    /// acquire failure completes the lease as `.failed` and rolls back
    /// hook/heartbeat state so leases never leak. Callers still see the
    /// original error thrown.
    func heyClickyFreePreamble(generation: UInt64) async throws {
        preambleInProgress = true
        defer { preambleInProgress = false }
        // Wait out any in-flight quota reset before touching the
        // proxy — its wipe would land mid-JWT-refresh otherwise.
        await HeyClickyAccountResetManager.shared.awaitBarrier()

        // Preemptive JWT refresh: without this the codex child would
        // inherit whatever OPENAI_API_KEY the spawn caller passed,
        // which after any auth-refresh cycle is stale → proxy returns
        // 401 Unauthorized on the very first /responses. `refresh()`
        // posts .clickyHeyClickyCredentialsRefreshed, so any live
        // codex also picks up the new JWT before it fails.
        do {
            _ = try await HeyClickySessionAuthenticator.shared.refresh()
            HeyClickyLog.log("codex.preamble_jwt_refreshed", lane: "agent",
                             direction: "internal", [:])
        } catch {
            HeyClickyLog.log("codex.preamble_jwt_refresh_failed", lane: "agent",
                             direction: "error", ["error": "\(error)"])
        }

        // Mint the codex-scoped ephemeral session token BEFORE codex
        // spawns so CodexProcessManager.start() can peek the cache and
        // set OPENAI_API_KEY to the short-lived per-account token
        // (matches HeyClicky-1.0.40's `agentSessionTokenInjectedAtLast
        // ProcessSpawn` pattern). Sending the raw Supabase JWT as the
        // /agent/openai/v1/responses bearer produces
        // 401 "Invalid or expired HeyClicky session token".
        do {
            _ = try await HeyClickySessionTokenClient.shared.mintCodexToken(launchSource: .codex)
            HeyClickyLog.log("codex.preamble_ephemeral_minted", lane: "agent",
                             direction: "internal", [:])
            // If codex is already running (subsequent turns / replays),
            // push the fresh ephemeral into it now — otherwise it
            // keeps sending its spawn-time bearer (raw JWT) and 401s.
            // BUT: if we still have a live lease, the running codex is
            // authenticated with a bearer the proxy currently accepts
            // (otherwise the lease would already be dead), so re-keying
            // is unnecessary AND destructive (rekey nukes the lease,
            // costing +1 credit on the next launch). Skip in that case.
            if currentHeyClickyLease == nil {
                await rekeyLiveCodexWithFreshJWT()
            } else {
                HeyClickyLog.log("codex.preamble_rekey_skipped_lease_alive",
                                 lane: "agent", direction: "internal", [:])
            }
        } catch {
            HeyClickyLog.log("codex.preamble_ephemeral_mint_failed", lane: "agent",
                             direction: "error", ["error": "\(error)"])
        }
        // Ensure the 3.5h codex-ephemeral renewal loop is running so
        // long-lived sessions (multi-hour agent turns, long idle
        // periods) never meet the reactive 401. Idempotent — only
        // installs a timer on the first call.
        HeyClickySessionTokenClient.shared.startProactiveCodexRefreshLoop()

        let launchSource: HeyClickyLaunchSource = .codex
        let prompt = lastSubmittedPromptText ?? ""

        // Thread ID lifecycle per IDA 1.0.42:
        //   - client-generated UUID, stable across a logical
        //     conversation (all follow-ups reuse it)
        //   - server has NO thread_id in the launch response — it
        //     just acknowledges + returns UX fields
        //   - `is_follow_up` distinguishes first turn from subsequent
        //     turns on the SAME thread
        // Prior code relied on codex's `thread/started` notification
        // to set activeThreadID → but the proxy needed the id BEFORE
        // codex started → chicken-and-egg → proxy always saw "new
        // thread every turn" and never hydrated history.
        let resumeIDForThisPreamble = pendingThreadResumeID
        if pendingThreadResumeID != nil {
            HeyClickyLog.log("codex.thread_resume_consumed", lane: "agent",
                             direction: "internal", [
                "thread_prefix": String((resumeIDForThisPreamble ?? "").prefix(8))
            ])
            pendingThreadResumeID = nil
        }
        // Determine the thread_id to send. Order:
        //   1. pendingThreadResumeID (stashed by a prior teardown for
        //      resume-after-crash / resume-after-reset)
        //   2. activeThreadID (in-memory current thread)
        //   3. fresh UUID (brand-new conversation)
        let threadIDToSend: String
        let isFollowUp: Bool
        if let resume = resumeIDForThisPreamble, !resume.isEmpty {
            threadIDToSend = resume
            isFollowUp = true
        } else if let live = activeThreadID, !live.isEmpty {
            threadIDToSend = live
            isFollowUp = true
        } else {
            threadIDToSend = UUID().uuidString.lowercased()
            isFollowUp = false
        }

        // Steps 1-2: thread launch (no lease held yet — free to throw).
        // If proxy returns 402 (quotaExhausted) at this step, the
        // account is truly out of daily quota. Trigger auto-reset via
        // chrome-ext (sign-out+in on same email) and then WAIT for the
        // barrier before retrying. Without this, launchThread throws
        // straight to the UI and the user sees "402 error" instead of
        // silently getting a fresh quota.
        let threadInfo: HeyClickyThreadInfo
        do {
            threadInfo = try await HeyClickyTurnLeaseClient.shared.launchThread(
                userPrompt: prompt,
                launchSource: launchSource,
                threadID: threadIDToSend,
                isFollowUp: isFollowUp
            )
        } catch HeyClickyProxyError.quotaExhausted {
            HeyClickyLog.log("codex.preamble_thread_launch_quota", lane: "agent",
                             direction: "error", ["action": "attempt_reset_and_retry"])
            let didAttempt = await MainActor.run {
                HeyClickyAccountResetManager.shared.attemptReset(
                    reason: "thread_launch_402_quota_exhausted"
                )
            }
            guard didAttempt else {
                HeyClickyLog.log("codex.preamble_reset_declined_soft_fail",
                                 lane: "agent", direction: "error",
                                 ["reason": "cooldown_or_unsigned_or_no_ext"])
                throw HeyClickyProxyError.upstreamUnavailable
            }
            await HeyClickyAccountResetManager.shared.awaitBarrier()
            if !AppBundleConfiguration.heyClickySignedIn() {
                HeyClickyLog.log("codex.preamble_reset_timeout_soft_fail",
                                 lane: "agent", direction: "error", [:])
                throw HeyClickyProxyError.upstreamUnavailable
            }
            HeyClickyLog.log("codex.preamble_retry_after_reset", lane: "agent",
                             direction: "internal", [:])
            threadInfo = try await HeyClickyTurnLeaseClient.shared.launchThread(
                userPrompt: prompt,
                launchSource: launchSource,
                threadID: threadIDToSend,
                isFollowUp: isFollowUp
            )
        }
        // Commit the thread_id we just sent to both header builder AND
        // in-memory state so subsequent turns keep the same id.
        setActiveThreadID(threadInfo.sessionID)
        logLifecycle(
            action: isFollowUp ? "MEMORY_RESUMED" : "MEMORY_FRESH_START",
            reason: isFollowUp
                ? "proxy re-hydrated prior thread history via thread_id"
                : "brand-new thread — no prior conversation to resume",
            extra: [
                "thread_id_sent": threadIDToSend,
                "thread_id_committed": threadInfo.sessionID,
                "resume_id_source": resumeIDForThisPreamble != nil ? "pendingThreadResumeID" : (activeThreadID != nil ? "activeThreadID" : "new_uuid")
            ]
        )
        HeyClickyHeaderBuilder.shared.setAgentThreadID(threadInfo.sessionID)

        // NOTE: thread/goal/set is dispatched later, right before
        // turn/start (see ensureThread's turn/start section). Codex
        // daemon has NOT been spawned yet here — setThreadGoal would
        // silently no-op on the hasInitializedProcess guard. The
        // `pendingThreadGoalObjective` field survives across preamble
        // → codex spawn → thread ready, and is consumed at the
        // guaranteed-spawned point.

        // Step 3: acquire lease. Every failure path after this MUST
        // complete the lease before propagating.
        // Same 402→reset→retry pattern as thread launch above:
        // record-agent-launch is what actually spends the daily agent
        // credit, so a 402 here means the count is real.
        let lease: HeyClickyTurnLease
        do {
            lease = try await HeyClickyTurnLeaseClient.shared.acquire(
                sessionID: threadInfo.sessionID,
                launchSource: launchSource,
                isFollowUp: isFollowUp
            )
        } catch HeyClickyProxyError.quotaExhausted {
            HeyClickyLog.log("codex.preamble_acquire_quota", lane: "agent",
                             direction: "error", ["action": "attempt_reset_and_retry"])
            let didAttempt = await MainActor.run {
                HeyClickyAccountResetManager.shared.attemptReset(
                    reason: "acquire_lease_402_quota_exhausted"
                )
            }
            guard didAttempt else {
                HeyClickyLog.log("codex.preamble_acquire_reset_declined_soft_fail",
                                 lane: "agent", direction: "error",
                                 ["reason": "cooldown_or_unsigned_or_no_ext"])
                throw HeyClickyProxyError.upstreamUnavailable
            }
            await HeyClickyAccountResetManager.shared.awaitBarrier()
            HeyClickyLog.log("codex.preamble_acquire_retry_after_reset",
                             lane: "agent", direction: "internal", [:])
            lease = try await HeyClickyTurnLeaseClient.shared.acquire(
                sessionID: threadInfo.sessionID,
                launchSource: launchSource,
                isFollowUp: isFollowUp
            )
        }

        // If a previous run left a stale lease around, roll it back
        // BEFORE overwriting so we never lose a leaseID.
        if let stale = currentHeyClickyLease {
            let staleLeaseID = stale.leaseID
            // Detached so a fast follow-up app exit doesn't cancel the
            // completion request (which would leak the lease server-side).
            Task.detached(priority: .utility) {
                try? await HeyClickyTurnLeaseClient.shared.complete(
                    leaseID: staleLeaseID,
                    status: .failed,
                    threadID: nil
                )
            }
        }
        currentHeyClickyLease = lease
        // Record lease id + expiry so the app-restart resume path can
        // check whether it's still steerable.
        setActiveLease(id: lease.leaseID, expiresAt: lease.expiresAt)
        logLifecycle(
            action: "LEASE_ACQUIRED",
            reason: isFollowUp
                ? "preamble follow-up (thread resume attempted)"
                : "preamble new thread",
            extra: [
                "credits_used_by_this_lease": lease.creditsUsed,
                "credits_included_in_plan": lease.includedCredits,
                "expires_at_unix": lease.expiresAt?.timeIntervalSince1970 ?? 0,
                "is_follow_up": isFollowUp,
                "thread_id_sent": threadIDToSend
            ]
        )

        do {
            let token = try await HeyClickySessionTokenClient.shared.mintCodexToken(
                launchSource: launchSource
            )
            HeyClickyFreeTierAgentHook.activate(ephemeral: token)
        } catch {
            // Post-acquire rollback.
            let leaseID = lease.leaseID
            Task.detached(priority: .utility) {
                try? await HeyClickyTurnLeaseClient.shared.complete(
                    leaseID: leaseID,
                    status: .failed,
                    threadID: nil
                )
            }
            HeyClickyFreeTierAgentHook.deactivate()
            HeyClickyHeaderBuilder.shared.setAgentThreadID(nil)
            currentHeyClickyLease = nil
            setActiveLease(id: nil, expiresAt: nil)
            throw error
        }
    }

    /// External callers use this to force the next follow-up prompt to
    /// re-run `heyClickyFreePreamble` — invoked on credentials refresh,
    /// codex crash, and turn-limit failures so the session doesn't
    /// keep hitting a dead thread.
    func clearActiveThreadForRelaunch(reason: String) {
        // Stash the current thread_id BEFORE nulling — the next
        // preamble will pass it to /codex-thread-launch as
        // `thread_id + clicky_agent_thread_resumed:true` so the proxy
        // re-hydrates the conversation on the new account. This is
        // what keeps "同一 session 继续聊" true across a reset.
        if let existing = activeThreadID, !existing.isEmpty {
            pendingThreadResumeID = existing
        }
        HeyClickyLog.log("codex.thread_cleared", lane: "agent", direction: "internal", [
            "reason": reason,
            "had_thread": activeThreadID != nil ? "yes" : "no",
            "stashed_for_resume": pendingThreadResumeID != nil ? "yes" : "no"
        ])
        heyClickyFreeTeardown(reason: reason)
        setActiveThreadID(nil)
    }

    /// Called from stop() and on process exit. Idempotent.
    func heyClickyFreeTeardown(reason: String? = nil) {
        guard let lease = currentHeyClickyLease else { return }
        currentHeyClickyLease = nil
        let leaseID = lease.leaseID
        let threadID = activeThreadID
        let status: HeyClickyLeaseStatus = (reason == nil) ? .completed : .cancelled
        Task.detached(priority: .utility) {
            try? await HeyClickyTurnLeaseClient.shared.complete(
                leaseID: leaseID,
                status: status,
                threadID: threadID
            )
        }
        HeyClickyHeaderBuilder.shared.setAgentThreadID(nil)
        HeyClickyFreeTierAgentHook.deactivate()
    }
}
