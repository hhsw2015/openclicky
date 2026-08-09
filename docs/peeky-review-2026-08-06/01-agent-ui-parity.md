# Peeky Free (mirage) Agent — Dock/Chat UI Parity Audit

Date: 2026-08-06
Scope: Verify Peeky Free's newly-added `CodexAgentSession` shim / dock-item wiring for the `.agent` branch matches what SKI + HeyClicky Codex sessions surface. Focus: dock bubble state, Chat/MiniChat resolution, per-event transcript rendering.

Files inspected:
- `cursor-buddy/CompanionManager+AIResponsePipeline.swift` (`analyzeMirageResponse` — lines 2521-2785)
- `cursor-buddy/MiragePeekyOrchestrator.swift` (`runTurn`, `runAgent` — lines 67-140, 558-607)
- `cursor-buddy/CompanionManager+SKIModeDockMirror.swift` (canonical shim reconciler — full file)
- `cursor-buddy/CodexAgentSession.swift` (shim API surface — lines 192-270, 1122)
- `cursor-buddy/ClaudeAgentRunner.swift` (event schema — lines 62-65, 551-564)
- `cursor-buddy/CompanionManager.swift` (dock-item resolvers — lines 5686-5698, 6227-6245, 17192-17212)
- `cursor-buddy/MenuBarPanelManager.swift` (popover chat/mini callbacks — lines 1215-1245)

---

## Parity Verified

1. Shim construction matches SKI shape.
   - `analyzeMirageResponse` builds `CodexAgentSession(id: dockID, title: "Peeky Free", accentTheme: .rose)` and calls `forceVisibleForSKIShim()` + `registerSKIShimAgentSession(s)` — same 4-step sequence used in `SKIModeDockMirror.reconcile` (SKIModeDockMirror.swift:83-94). (AIResponsePipeline.swift:2555-2558)

2. Initial dock item is wired to the shim's UUID.
   - `ClickyAgentDockItem(id: dockID, sessionID: dockID, ...)` at AIResponsePipeline.swift:2560-2573. Chat/MiniChat popover callbacks in MenuBarPanelManager.swift:1215-1226 route through `openMiniChatForAgentDockItem` / `selectCodexAgentSession(sessionID)` which resolve via `agentDockItems.first(...).sessionID` → `codexAgentSessions.first { $0.id == sessionID }` (CompanionManager.swift:6238-6245, 17192-17212). During the turn this resolution finds the shim correctly.

3. Streamed CLI events are mapped to transcript entries.
   - `runAgent` yields raw `MirageAgentEvent` values through `onAgentEvent` (MiragePeekyOrchestrator.swift:590-604). The pipeline callback (AIResponsePipeline.swift:2655-2712) handles `assistant` (text / tool_use / thinking) and `user` (tool_result) block kinds, calling `shim.appendRemoteTranscriptEntry(...)` for each. Event IDs are keyed on the CLI message/block ID so re-yields don't duplicate. This is functionally equivalent to what SKI's `mapMessageToEntry → setEntriesForSKIShim` pipe does (SKIModeDockMirror.swift:97-99, 196-211), just event-streamed instead of state-diffed.

4. Final rememberVoiceExchange + shared codex sidebar mirror mirrors HeyClicky.
   - AIResponsePipeline.swift:2770-2781 appends both the user turn and assistant text (and each tool call) into `shim` and into `self.codexAgentSession`, matching the HeyClicky pattern cited in the comment (`CompanionManager+HeyClicky.swift:1482`).

5. MirageAgentEvent contract lines up.
   - `struct MirageAgentEvent { type: String; raw: [String: Any] }` (ClaudeAgentRunner.swift:62-65) — pipeline consumers pattern-match on `event.type` exactly as ClaudeAgentRunner emits `cont.yield(MirageAgentEvent(type: type, raw: obj))` (ClaudeAgentRunner.swift:558-563).

---

## Gaps

### G1. Final dock-item update nulls `sessionID`, breaking Chat/MiniChat post-turn

AIResponsePipeline.swift:2726-2741 rebuilds the dock item on completion with `sessionID: nil`. After a Peeky Free agent turn ends the bubble is still visible with status `.done` / `.failed`, but tapping Chat or MiniChat silently no-ops because:

- `openMiniChatForAgentDockItem` (CompanionManager.swift:6239) guards on `agentDockItems.first(...).sessionID` → returns immediately when nil.
- `openAgentDockItem` (CompanionManager.swift:17197) falls through to the generic `showMainInterfacePanel` and never selects the shim.

Codex/SKI dock items keep `sessionID: shimUUID` for the `.done` state too (SKIModeDockMirror.swift:117-119), which is why Codex bubbles remain interactive after completion.

Impact: The user can see the "one bubble = one session" transcript only while the turn is running. As soon as the CLI wraps, the bubble becomes a dead artifact.

### G2. Dock item status is never advanced to `.running` during the turn

The initial upsert seeds status `.starting` with `progressStageLabel: "Classifying intent"` (AIResponsePipeline.swift:2566-2568). Nothing in the `onAgentEvent` handler (AIResponsePipeline.swift:2655-2712) calls `upsertSKIModeDockItem` or `shim.updateSKIShimState(...)` while CLI events stream. The bubble jumps `.starting` → `.done` in one step.

Contrast with SKIModeDockMirror.swift:106-131, where `deriveShimState` maps the last SKIMessage kind (`.toolCall` → `.running/.composing`, `.final` → `.ready/.idle`) and the dock item's `status` / `progressStageLabel` are refreshed on every reconcile pass. This is how the SKI bubble renders the "thinking → tool → responding" spinner states that the Peeky Free bubble is missing.

Impact: No visible progress signal on the dock bubble during the (30-60s) agent loop. Only the notch heartbeat caption at AIResponsePipeline.swift:2618-2619 conveys liveness; the bubble itself looks frozen.

### G3. Shim `CodexAgentSession.status` never leaves `.ready` (from `forceVisibleForSKIShim`)

`forceVisibleForSKIShim()` (CodexAgentSession.swift:249-253) bumps status from `.stopped` to `.ready`. The mirage path never calls `updateSKIShimState(...)` afterward, so the Chat / MiniChat panels render the shim as "Ready" for the entire lifetime of the turn. SKI drives this via `shim.updateSKIShimState(status: statusValue, ...)` on every reconcile (SKIModeDockMirror.swift:107). The `.running` pill and progress-stage chip in `CodexAgentOverlayCard` / `MiniChatPanel` therefore stay static on Peeky.

### G4. Shim leaks — never removed

SKI removes both the dock item and the shim session when its underlying SKI session goes away (SKIModeDockMirror.swift:135-140: `removeSKIModeDockItem` + `removeSKIShimAgentSession`). Mirage's `analyzeMirageResponse` never calls `removeSKIShimAgentSession(id: dockID)`. Each Peeky Free voice turn accretes a permanent `CodexAgentSession` entry in `codexAgentSessions`, cluttering the Agents sidebar and the conversation list.

### G5. `progressStageLabel` frozen during the turn

The initial label `"Classifying intent"` never advances even though the orchestrator moves through `classify → runChat/runIntegration/runMemory/runAgent` (MiragePeekyOrchestrator.swift:82-136). At the SKI/Codex parity level this string is used to render the sub-caption under the bubble title — Peeky Free just shows "Classifying intent" for the entire (potentially 60s) agent loop.

### G6. `.chat` / `.integration` / `.memory` branches emit no `onAgentEvent`

Only the `.agent` branch of `runTurn` (MiragePeekyOrchestrator.swift:124-135) forwards `onAgentEvent`. The other three branches (chat/integration/memory) still surface a dock bubble via `analyzeMirageResponse`, but the bubble receives no per-step transcript entries and stays at `.starting` until the turn ends. This is arguably by-design (they're single-shot Claude calls), but the dock item is misleading — it advertises an agent-like session that has zero live activity.

### G7. Potential transcript duplication on the assistant text

Pipeline:2671-2673 appends every streamed `text` block during the turn via `onAgentEvent`. Pipeline:2770-2781 then appends the aggregated `result.text` as a single entry after the turn returns. When Claude Code streams a single assistant message the shim ends up with both the incremental fragments and the final consolidated string — the Chat/MiniChat transcript renders the reply twice, back-to-back. (Codex's real path stores a single canonical entry.)

---

## Suggested Fix

Below, minimal edits keyed to `cursor-buddy/CompanionManager+AIResponsePipeline.swift` (line numbers reflect current file at time of audit).

### F1 (fix G1) — keep `sessionID` populated on the terminal upsert

At AIResponsePipeline.swift:2730 change:

```swift
self.upsertSKIModeDockItem(ClickyAgentDockItem(
    id: dockID,
    sessionID: nil,                       // <-- BUG: breaks Chat/MiniChat
    title: dockTitle,
    ...
```

to:

```swift
self.upsertSKIModeDockItem(ClickyAgentDockItem(
    id: dockID,
    sessionID: dockID,                    // keep Chat/MiniChat reachable
    title: dockTitle,
    ...
```

### F2 (fix G2 + G3 + G5) — drive shim + dock status from the event stream

Extract a helper next to `analyzeMirageResponse` and call it from the `onAgentEvent` handler and from the classify → branch dispatch. Skeleton:

```swift
// Add near AIResponsePipeline.swift:2655
@MainActor
private func advanceMiragePeekyDock(
    dockID: UUID,
    shim: CodexAgentSession,
    userPrompt: String,
    stageLabel: String,
    activityLine: String?,
    status: ClickyAgentDockStatus,
    sessionStatus: CodexAgentSessionStatus,
    sessionStage: CodexAgentProgressStage
) {
    shim.updateSKIShimState(
        status: sessionStatus,
        progressStage: sessionStage,
        activityStatus: activityLine
    )
    self.upsertSKIModeDockItem(ClickyAgentDockItem(
        id: dockID,
        sessionID: dockID,
        title: "Peeky Free",
        userInstruction: userPrompt,
        accentTheme: .rose,
        status: status,
        progressStageLabel: stageLabel,
        progressStepText: nil,
        activityStatusLines: shim.activityStatusLines,
        caption: nil,
        suggestedNextActions: [],
        createdAt: Date()
    ))
}
```

Then in the `onAgentEvent` switch (AIResponsePipeline.swift:2664):

```swift
case "assistant":
    ...
    // First assistant block on this turn → running/composing
    self.advanceMiragePeekyDock(
        dockID: dockID, shim: shim, userPrompt: userPrompt,
        stageLabel: "Composing reply",
        activityLine: nil,
        status: .running,
        sessionStatus: .running,
        sessionStage: .composing
    )
    ... existing per-block append ...
    if btype == "tool_use", let name = block["name"] as? String {
        self.advanceMiragePeekyDock(
            dockID: dockID, shim: shim, userPrompt: userPrompt,
            stageLabel: "Tool: \(name)",
            activityLine: "Working: \(name)",
            status: .running,
            sessionStatus: .running,
            sessionStage: .executing
        )
    }
case "user":
    // tool_result → back to composing
    self.advanceMiragePeekyDock(
        dockID: dockID, shim: shim, userPrompt: userPrompt,
        stageLabel: "Composing reply",
        activityLine: nil,
        status: .running,
        sessionStatus: .running,
        sessionStage: .composing
    )
    ... existing append ...
```

And call it once after `classify` returns but before branch dispatch, to move the bubble from "Classifying intent" to something like "Intent · agent" while the CLI spins up. (Requires a small refactor: hoist `classify` out of `runTurn` or return the resolved intent via a callback.)

### F3 (fix G4) — remove the shim when the turn wraps

At the very end of `analyzeMirageResponse` — both the success return path (AIResponsePipeline.swift:2784 `return result.text`) and the raw-Claude fallback return path — schedule a delayed cleanup so the user has a few seconds to click Chat / MiniChat before the shim goes away, matching the SKI `inactiveGraceSeconds` pattern (SKIModeDockMirror.swift:54, 135-140):

```swift
Task { @MainActor [weak self] in
    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)  // 30s grace
    guard let self else { return }
    self.removeSKIModeDockItem(id: dockID)
    self.removeSKIShimAgentSession(id: dockID)
}
```

Place this once at the top-level `defer` block near AIResponsePipeline.swift:2625 (alongside `heartbeatTask.cancel()`) so both branches share it.

### F4 (fix G7) — drop the post-turn shim append for assistant text

At AIResponsePipeline.swift:2770-2781, since `onAgentEvent` (F2 above) already streamed every assistant text block into `shim`, the terminal append duplicates. Change to append only the `user` turn into `shim` and mirror only into `self.codexAgentSession` (which needs the whole exchange, since it didn't receive per-event streaming):

```swift
// Shim already has the streamed assistant blocks; just record the user turn.
shim.appendRemoteTranscriptEntry(role: .user, text: userPrompt, id: userID)

// Shared codex sidebar needs the full exchange.
self.codexAgentSession.appendRemoteTranscriptEntry(role: .user, text: userPrompt, id: userID)
self.codexAgentSession.appendRemoteTranscriptEntry(role: .assistant, text: result.text, id: assistantID)
for call in result.toolCalls {
    let toolText = "\(call.name): \(call.result.stringValue.prefix(200))"
    let toolID = "peeky-tool-\(UUID().uuidString)"
    self.codexAgentSession.appendRemoteTranscriptEntry(role: .assistant, text: toolText, id: toolID)
}
```

### F5 (partial fix G6) — surface non-agent branches too

Cheap option: after `runTurn` returns for the non-agent branches, before the terminal upsert, append the user turn + result.text into `shim` (identical to F4's shared-session append) and set `sessionStatus: .ready`, `sessionStage: .completed`. The bubble then behaves the same for chat/integration/memory as it does for agent — no live tool_use rendering, but transcript + state parity with SKI.

---

## Verdict

The shim / dock-item shape is right — the mirage path adopted the SKI pattern faithfully. The parity failures are all in the *lifecycle transitions*: initial state → running states → final state → cleanup. Applying F1-F5 above brings Peeky Free's agent bubble to functional parity with SKI/HeyClicky Codex bubbles at roughly ~30 lines of change in one file. F1 is a one-line hotfix and should ship immediately; F2 is the larger delta.
