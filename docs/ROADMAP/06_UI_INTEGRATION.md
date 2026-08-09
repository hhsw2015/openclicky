# Layer - UI 流程整合方案

**目的**: 把新的 Context + Router + Codex 分流机制**嵌到现有 openclicky UI 流程里**, 不改用户已熟悉的交互.

---

## 现有 UI 流程 (不动)

- **F1 或用户配 hotkey** — 语音 PTT → STT → 转录送 dialog model → 回复
- **前台 dock icon** — codex agent sessions 各占一格
- **mini chat panel** — 文本输入 + 显示 agent 对话
- **notch panel** — 状态显示
- **agent screen** — 详细 agent 对话页

**这些完全保留**, 只在**信息流入口和出口**加钩子.

---

## 入口: hotkey → Layer 0 + Prompt 增强

**位置**: `CompanionManager.swift` 现有 hotkey handler.

```swift
// 现有 hotkey handler
func onHotkeyPress() {
    // 语音识别开始
    startVoiceCapture()
}

// 增强
func onHotkeyPress() {
    // (a) Layer 0 快照采集 (300ms 内, 并行 STT)
    contextService.snapshotForRouterAsync()
    
    // (b) 语音识别开始 (现有)
    startVoiceCapture()
}
```

STT 完成 → 转录 + 快照都在手 → 拼 prompt 发给高级模型.

---

## 出口: Dialog reply → Route parse → Agent 分流

**位置**: dialog model reply 完成处.

```swift
// 现有 dialog reply handler
func onDialogReplyComplete(reply: String) {
    speakReply(reply)  // 现有 TTS
}

// 增强
func onDialogReplyComplete(reply: String, transcript: String) {
    speakReply(reply)  // 现有 TTS 不动
    
    // 新: 从 reply 里 parse [ROUTE], 分流
    if let route = parseRouteJSON(reply) {
        dispatchByRoute(route, transcript: transcript)
    }
}

func dispatchByRoute(_ route: RouterDecision, transcript: String) {
    switch route.kind {
    case .chat: break  // 已 TTS 完
    case .short_task, .long_task_new, .long_task_existing:
        // 复用现有 startVoiceAgentTaskPlan, 只是加了几个可选参数
        startVoiceAgentTaskPlan(
            instruction: transcript,
            workingDirectoryHint: route.workdir,
            projectRef: route.projectRef,
            slug: route.slug,
            progressDriven: true,
            completionMarker: "MARKER-END"
        )
    case .ambiguous: break  // dialog reply 里已 ask 了
    }
}
```

**核心**: 不新建 UI, 复用 `startVoiceAgentTaskPlan`.

---

## `startVoiceAgentTaskPlan` 扩参数

现有签名:
```swift
func startVoiceAgentTaskPlan(instruction: String,
                             acknowledgement: String? = nil,
                             route: String = "agent.start",
                             speakAcknowledgement: Bool = true, ...) 
```

加几个可选参数:
```swift
func startVoiceAgentTaskPlan(
    instruction: String,
    acknowledgement: String? = nil,
    route: String = "agent.start",
    speakAcknowledgement: Bool = true,
    // 新增:
    workingDirectoryHint: String? = nil,
    projectRef: String? = nil,
    slug: String? = nil,
    progressDriven: Bool = false,      // Layer 1 新概念
    completionMarker: String? = nil,   // "MARKER-END"
    watchdogNudge: Bool = true,         // 默认开
    ...)
```

内部:
- 若 `workingDirectoryHint`, 创建 session 时 `session.workingDirectoryPath = hint`
- 若 `progressDriven`, `session.progressDriven = true`, auto-continue observer gate 生效
- 若 `completionMarker`, `session.completionMarker = "MARKER-END"`, 检查完成时用这个

**session 类扩字段** (`CodexAgentSession.swift`):
```swift
@Published var progressDriven: Bool = false
@Published var completionMarker: String? = nil
@Published var watchdogNudgeEnabled: Bool = true
```

---

## Auto-continue observer (F28) — **Landed 2026-07-23**

See `docs/ROADMAP/.impl-notes/f28-landing-report-2026-07-23.md` for the full landing report.

**Trigger site**: `turn/completed` handler in `cursor-buddy/CodexAgentSession.swift:1995-2038` (single sole dispatch point for progress-driven auto-continue). The prior speculative "extend the existing observer" design was superseded — the observer body still gates non-progress paths, but the fire decision now happens in the session's `turn/completed` case where the outcome is authoritative.

**Gate** (all must hold, else the handler no-ops):
- `session.progressDriven == true`
- `session.workingDirectoryPath.isEmpty == false`
- `session.model.hasPrefix("heyclicky-free-")` (lane gate; Anthropic / OpenAI / Codex-direct sessions never trigger)

**Marker check** — `cursor-buddy/OpenClickyProgressMarkerCheck.swift`:
- Path: `<workingDirectoryPath>/PROGRESS.md`
- Marker string: `session.completionMarker ?? "LAST_COMPLETED: DONE"`
- Match: line-anchored, case-sensitive regex `^\s*<escaped marker>\s*$` with `.anchorsMatchLines`. Whitespace-tolerant, but substring / mid-line / different-case matches are rejected (`NOTES: not DONE yet` → not done; `last_completed: done` → not done; `prefix LAST_COMPLETED: DONE suffix` → not done).
- Missing PROGRESS.md → treated as not-done (fires continue).
- Unreadable / regex compile failure → treated as not-done, logs `openclicky.f28.progress_read_failed`; still falls through the existing 3-attempt / 300 s cooldown budget so a stuck read cannot loop forever.

**Fire behaviour**: when marker is absent, posts `.heyClickyRequestAutoContinueReplay` with `userInfo: ["source": "f28_progress_driven"]`. Downstream in `CompanionManager+HeyClicky.swift:787-806, 404-430` the observer:
- Skips the "completed = done" bail for progress-driven sessions (previously an unconditional `return`).
- Uses the lightweight `progressDrivenAutoContinuePrompt = "Continue against PROGRESS.md — next unchecked item. Do not summarize."` at both dispatch sites (steer via `submitPromptFromUI`, new-turn via `submitAgentPrompt`).
- Non-progress-driven flows keep the heavier `buildContextfulResumePrompt(session)`.

**No absolute turn cap**: the existing progress-conditioned failure budget (3 attempts / 300 s cooldown) plus the 3 s debounce (`shouldDispatchAutoReplay`) are the only ceilings. Design deferred an explicit `maxTurns` per landing report §Deferred.

**Non-regression**: strictly additive on the `.completed` case. Error-recovery replay from 402/428 turn-limit paths (`CodexAgentSession.swift:1615, 2085`), zombie-completion, cooldown wake, creds-refresh replays are all unchanged.

---

## Dock UI 无变化

现有 `agentDockItems` 每 session 一格. Router 分流后走 `createAndSelectNewCodexAgentSession` (已有) + `agentDockItems.append` (已有). Dock 视觉不改.

---

## Settings 面板整合

**新增 tab**: `Context Awareness`. 独立, 不 touch 现有 tab.

见 `05_LAYER_4_UX.md` 里 Settings 章节.

---

## 与 automation bridge 关系

**automation bridge** (`OpenClickyExternalControlBridge.swift`) 的 `automationStartAgent` 现在也走同一底层 `createAndSelectNewCodexAgentSession`. 我们**给它加同样的参数**:

```
POST /agent/task/start
body: {
  "title": "...",
  "prompt": "...",
  "workingDir": "...",
  "reasoningEffort": "xhigh",
  // 新增:
  "progressDriven": true,
  "completionMarker": "MARKER-END",
  "watchdogNudge": true
}
```

MCP `codex_task_start` 同步扩. 外部驱动和 UI voice 走同一签名.

---

## 命令行 CLI (可选)

```
openclicky task-start --workdir /path --prompt "..." --progress-driven --marker MARKER-END
```

给 shell 用户/CI 用. 走同一 bridge.

---

## 现有代码修改清单

| 文件 | 修改内容 | 兼容性 |
|---|---|---|
| `CompanionManager.swift` | + `onDialogReplyComplete` 加 parse [ROUTE] 分流; extend `startVoiceAgentTaskPlan` 参数 | 完全向后兼容 (新参数都 optional 默认现有行为) |
| `CodexAgentSession.swift` | + `progressDriven` / `completionMarker` / `watchdogNudgeEnabled` 字段 | 默认 false, 现有 session 不受影响 |
| `CompanionManager+HeyClicky.swift` | auto-continue observer 加 progress-driven 分支 | 现有 interrupted 分支不动 |
| `OpenClickyExternalControlBridge.swift` | 加 `progressDriven` 等参数支持; 新 MCP tool signature | 兼容旧 caller |
| **新** `ContextService/` 目录 | 完全新代码 | 现有不感知 |
| **新** Settings tab "Context Awareness" | 完全新 tab | 现有 tab 不动 |

---

## 用户视角

场景 1 — 语音说 "在 openclicky 加个截屏工具":
- 老流程: F1 说 → 送 codex → codex 猜 workdir → 可能乱来
- 新流程: F1 说 → 前置采集 (frontmost=Xcode 打开 openclicky, selected_text=CompanionManager 里某行) → 送高级模型 → 模型回复 "好的, 我在 openclicky 里加截屏, 需要新建一个 CaptureUtility class..." + `[ROUTE] {"kind":"long_task_existing","project_ref":"openclicky","slug":"screenshot-tool"}` → openclicky 后台 `~/Dev/openclicky/.openclicky/tasks/screenshot-tool/` 建目录, spawn codex

场景 2 — 语音说 "现在几点":
- 老流程: F1 说 → 送 dialog model → 回答 → 结束
- 新流程: F1 说 → 送高级模型 → 回答 "现在下午 3 点" + `[ROUTE] {"kind":"chat"}` → openclicky 无动作

场景 3 — 语音说 "在这做个 Todo 网页" (前台 Finder 选中空目录 `~/Dev/todo/`):
- 老流程: F1 说 → 送 codex → codex 用默认 cwd → 建在错地方
- 新流程: F1 说 → 前置采集 (selected_folder=`~/Dev/todo/` empty) → 送高级模型 → 回复 "好的, 在 todo 目录建 landing page" + `[ROUTE] {"kind":"long_task_new","workdir":"/Users/wowdd1/Dev/todo","slug":"todo"}` → 目录 empty, advisor 生成 spec, codex 执行
