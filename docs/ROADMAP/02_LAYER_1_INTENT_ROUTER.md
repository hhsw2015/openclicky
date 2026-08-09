# Layer 1 — Intent 分类 (由高级模型副产, 而非独立 Router)

**关键澄清**: 语音模型 (STT / 语音识别) 很弱, 只做转录. 判定意图的是**高级对话模型** (Fable advisor 免费通道, 或 codex 主模型).

**决策位置**: 高级对话模型的回复中. openclicky 不做独立 Router 前置调用.

**避免**: 独立 Router 前置调 advisor (~5s) → 拖延回复时间.

---

## 两条不同 context 路径

### 路径 A: 语音 dialog model (需 preflight)

**为什么**: 语音 dialog model (Fable advisor / realtime API) 在 stream 生成回复时**不易 pause 调 MCP tool** — 边说边思, 中断会打断 TTS. 且 Fable msgs 通道协议不 native 支持 function calling. 因此**必须预注 minimal context**, model 一次拿全.

**策略**: preflight 4 项 → prompt 注入 → model 用它判意图 + 决定 reply.

### 路径 B: Codex agent (完全暴露 MCP, 不 preflight)

**为什么**: Codex agent 是**长跑任务**, 通过 stdio JSON-RPC 与 openclicky 通信, native 支持 MCP function calling. Agent 自己知道何时需要 context, 主动 call `/mcp/sensor` 的 10 tool + `/mcp/orchestrate` + doc readers + etc. 预注反而浪费 token.

**策略**: Codex config `[mcp_servers.sensor]` 已配 (Phase 3), agent 通过 `tools/list` 发现所有 sensor tool, 需要时 `tools/call`. Openclicky 侧**零上下文预注**.

**边界**:
- Voice hotkey → dialog model (路径 A, preflight)
- Voice → dialog reply 里 `[ROUTE]` 触发 codex spawn → codex agent (路径 B, 无 preflight)
- Chat 面板文本输入 → dialog model 或 codex (取决模式, 分别走 A / B)

---

## 完整流程

```
[t=0]    hotkey 按下
[t+50ms] Layer 0 上下文快照 (frontmost/finder/selected_text/...)
[t+100ms] STT 开始转录 (增量流)
[t+500ms] STT 完成
[t+500ms] 转录 + 快照 → 高级模型 (advisor msgs / 或 realtime API 主模型)
[t+1s]   高级模型 stream 开始
[t+1s]   前几字 TTS 播放, 用户开始听
[t+3s]   模型说完, reply 末尾一行 [ROUTE] {...}
[t+3s]   openclicky 后台 parse → 分流:
           - kind==chat → 已 TTS 完, 无 codex
           - kind==short/long_task → spawn codex, dock item
```

**用户视角**: 1s 后开始听 openclicky 讲话, 感觉不到任何 "分类" 步骤.

---

## Prompt 增强 (给高级模型)

在给高级模型的 system prompt 里加:

```
You are OpenClicky's high-quality assistant. Handle each voice hotkey input as follows:

1. First, respond conversationally (this will be spoken via TTS).
2. AT THE END of every reply, emit exactly one JSON line:
   [ROUTE] {"kind":"chat"|"short_task"|"long_task_new"|"long_task_existing"|"ambiguous",
            "project_ref":null|string,
            "slug":null|string,
            "workdir":null|string,
            "confidence":0.0-1.0}

CLASSIFICATION RULES:
- chat: Q&A/conversation, no side-effects, model can answer directly
- short_task: single-step action (open app, screenshot, tiny edit)
- long_task_new: build brand-new project from scratch
- long_task_existing: modify a known existing project (must match a keyword)

CONTEXT PREFETCHED THIS HOTKEY (use to resolve referents):
- frontmost_app: ...
- selected_folder: ...
- selected_text: ...
- browser_url: ...
- recent_agent_session: ...
- known_projects: [openclicky, ccline, clicky-mac, ...] (with keyword hints)

CONFIDENCE:
- Under-specified / referential without ctx → confidence <= 0.5, kind="ambiguous"
- Clear intent with ctx → confidence >= 0.9

Never omit [ROUTE]. Never wrap it in code fences.
```

---

## 若高级模型太快没 reply 前 openclicky 想立刻反应

**替代**: 高级模型 return 后再判定:
- 高级模型说话时 openclicky 只 TTS + 不做 codex 分流
- Reply 完成 → openclicky parse `[ROUTE]` → 分流
- 分流开始时可 TTS 一句 "开始做..." (可选)

**优点**: 高级模型不必仓促做判定, 有整个回复长度思考.

**缺点**: codex spawn 稍晚一点 (但用户听着回复, 感觉不到).

---

## 未来: 若语音使用 realtime API (双向流式)

Realtime API (gpt-realtime-2.1) 边听边说边思考. 我们只需要:
- 系统 prompt 里注入 Layer 0 上下文
- realtime API stream 输出音频 + text delta
- 最后一句 `[ROUTE]` 从 text stream 里 detect
- **中间过程无需 STT/TTS 分离**

这条路和 advisor msgs 通道并行走. openclicky 主路径 (voice → realtime → 分流) 是这个.

---

## Fallback / degraded 模式

- **模型忘 emit [ROUTE]**: 视为 chat (无害). 记 log `openclicky.route_missing` 后调 prompt.
- **[ROUTE] JSON 无效**: 同上, 视为 chat.
- **confidence < 0.6**: 视为 ambiguous, dialog reply 里模型应已自然反问, openclicky 不 spawn task.
- **kind=ambiguous 但 model 没反问**: openclicky 后备 TTS "在哪里做?" 让用户下句语音接续.

---

## 4 类分流细节

### chat
- **无 codex 动作**
- TTS 已完成, 结束

### short_task
- workdir: `selected_folder` (Finder 里选中) 或 `~/Library/Application Support/OpenClicky/EphemeralTasks/<slug>/`
- prompt: 用户原话 + "Break into ≤5 checklist items in progress.md, MARKER-END when done"
- **spawn codex, dock item**

### long_task_new
- workdir: `selected_folder` (空目录) 或 `~/OpenClickyTasks/<slug>/`
- **advisor 一次调用**生成 spec.md (免费 msgs 通道, ~5s)
- **spawn codex** with `Follow spec.md, MARKER-END when all done`

### long_task_existing
- 定位 project (project_ref → known_projects lookup, fuzzy 匹配)
- workdir: `<project>/.openclicky/tasks/<slug>/`
- prompt: `Read codebase, plan changes for <voice>. Write spec.md/progress.md in <taskDir>. Execute.`
- **spawn codex**

### ambiguous
- Dialog reply 里模型已问 clarify question
- 用户下句语音继续, 走同一 pipeline

---

## Prefetched context 组成 (**每次注 minimal, on-demand via MCP**)

**核心原则**: 硬编码意图判定 (关键词表 "这" / "帮我" / "打开") 脆弱, 不可持续. 改用**model-driven** 策略:

1. **每次都注 minimal 上下文** (~4 项, <10ms 采集, ~50-100 token). 让高级模型自己看到"用户在哪个 app / 什么窗口 / 选中什么文件夹".
2. **需要更多时 model 主动 call MCP sensor tool** — 已经在 Phase 2 完成, model 通过 codex config 里 `mcp_servers.sensor` 或 realtime API function-calling 看得到 10 tool.
3. **Settings toggle** 保护, 用户可关.

### 为什么 preflight 必须每次都做 (不能缓存)

用户会**跨 app 切换讲话**. 同一 voice session 里:
- t=0 在 Xcode 里问 "这段代码怎么优化" → context.frontmost = Xcode
- t=30s Cmd+Tab 到 Figma 说 "这个按钮怎么做" → context.frontmost = **Figma** (变了)
- t=60s 再到 Terminal 说 "跑一下测试" → context.frontmost = **Terminal** (又变了)

Dialog model **必须**每次看到当前 frontmost, 否则会误以为用户还在上一个 app 说话, 回复南辕北辙 (e.g. 在 Figma 里问按钮, model 却按 Swift protocol 回).

**Preflight 每次采集, 不缓存**. Frontmost app 是 O(1) NSWorkspace 查询 (1ms), 不 cache 也不贵.

**RecentAgentSession** 也要每次刷新 (running session 状态可能变化).

### 核心定位: Fable 是**推理器**, 不是 agent

Openclicky 不把 Fable 改造成 agent. Fable 只做**一次性推理** — 拿到 openclicky 提供的 context + 用户 utterance + screenshot → 回一次性 reply.

**Openclicky 是 context 供应商**, 每 turn 主动决定 Fable 需要看什么, 一次性塞好.

**不做**:
- Fable 主动 request 更多 context (`[SENSOR:...]` 协议) — Fable 拿不到 tool 结果继续 reason, 协议无意义
- Turn-N → Turn-N+1 sensor result 编排 — 增加复杂度, 无 payoff
- Fable 触发 openclicky 补采 → 重发 Fable — 就是 fake agent loop, 不做

**只做**:
- 每 turn openclicky 采 preflight (推理辅助信息) → 塞 prompt
- Fable emit `[ROUTE]` 让 openclicky orchestrate → openclicky dispatch codex agent (**codex 才是真 agent**)
- Fable emit `[TOOL:...]` fire-and-forget side-effect (clipboard_copy 等)

### Preflight 分两组 (关键澄清)

**Fable (text-only dialog model, `/chat-tool-call`) 拿不到 tool 结果**, 无法基于结果继续 reasoning. 所以只能注入**帮它读懂 screenshot + 用户 utterance 的辅助信息**, 不注 orchestrator-only 信号.

#### 组 1: 给 Fable (每 turn prepend, <10ms 采集)

推理辅助 — Fable 用来读懂 "用户在哪 / 看什么 / 选什么":

```
FrontmostApp        (bundle_id, name) — 1ms
FocusedWindow.title (title only, no geometry) — 5ms
BrowserURL          (若前台=浏览器, 通过 sensor tool 拿) — 5ms
FinderSelection     (若前台=Finder, currentFolder + first 3 file names) — 30ms
SelectedText        (AX strat 1 only, 无 Cmd-C 副作用) — 5ms
ClipboardPreview    (前 200 字符, 可选, 默认 skip) — 1ms
```

Prepend to query as:

```
[openclicky-context]
frontmost_app: com.apple.Safari (name=Safari)
window_title: "GitHub - openclicky"
url: https://github.com/...
selected_folder: null
selected_text: "func foo() { return 42 }"
[/openclicky-context]

<原用户 query>
```

#### 组 2: 给 openclicky orchestrator (本地 decision, 不外发)

判 `[ROUTE]` dispatch 用. Fable emit `[ROUTE]` 后 openclicky 自己 orchestrate:

```
RecentAgentSession    (最新一条, memory) — 1ms
ProjectRegistry match (基于 selected_folder / window_title, 内存查) — 1ms
WorkdirProbe          (若 selected_folder 存在, fs stat) — 5-10ms
GitAwareness          (若在 git repo, 3 subprocess) — 50-100ms
```

只在 `[ROUTE].kind == long_task_*` 时才需要. 用于 orchestrator:
- `long_task_existing` + project_registry_match → 定位 project 路径
- `long_task_new` + workdir_probe → 判 selected_folder 是否空/已有项目/冲突
- Fable 不用感知这些细节, 只输出 `slug` + `workdir` 希望

**总 ≤10ms** (Finder 前台时 ≤30ms). 与 STT 500ms+ 并行 → 用户零感知. Token 成本 ~50-100 (低).

**不注入**:
- SelectedText 三级 fallback (Cmd-C strat 3 有 100ms 阻塞 + pasteboard 副作用, 且高级模型多数场景不需要)
- ClipboardPreview (同上, 隐私考虑)
- BrowserURL (只在 model 需要时通过 `get_browser_url` MCP 调)
- 完整 AX tree / OCR / screenshot / probe_workdir 深度

### On-demand (via `/mcp/sensor`)

高级模型判断需要更多 context 时, 通过 tool call 拉取. Phase 2 已 ready 的 10 tool:
- `get_focused_context` — 完整快照 (含 selected_text / clipboard / browser_url / finder_selection)
- `get_selected_text` — 三级 fallback (含 Cmd-C, 100ms)
- `get_clipboard`, `get_browser_url`, `get_finder_selection`, `get_idle_time`
- `probe_workdir` (path 参数, 判 project 状态)
- `get_focused_window`, `list_apps`, `sensor_health`

**优势**:
- Model 自己判断是否需要 → 语义 accurate
- 不需要时零成本
- Tool 集可扩 (Phase 5 加 `get_browser_tabs` / `get_terminal_output` / `read_pick` / `read_whiteboard` 时无需改 Preflight)
- Openclicky 侧无硬编码启发式, 不脆弱

### Settings toggle

`[√] Enable context awareness (inject scene context)` — 默认 **on**.
- On: 每 turn 注 4 项 preflight + sensor MCP 可用
- Off: 完全不注 (纯聊天, 与 Phase 4 前行为一致)
- 用户可 opt-out (若嫌 token 成本高 / 隐私顾虑)

### 交互速度保护

**用户视角零延迟**:
- t=0 按 hotkey
- t+10ms preflight 采完 (与 STT 并行开始)
- t+500ms STT 完成 (preflight 早就完了)
- t+500ms dialog model 调用 (prompt 里含 preflight ~50-100 token 增加)
- t+1s dialog model first-token, TTS 开始播放

比 Phase 4 前, first-token latency 可能 +30-50ms (prompt 稍大). **可接受**.

**model 主动 call MCP tool 时**: stream 里一次 pause ~50-200ms. TTS 已经播前面的话, 用户感知有限. 且**只在 model 判需要时**才付这个 cost.

---

## 修改现有代码点

`CompanionManager.swift` 语音回复 hook:

```swift
// 现有: analyzeVoiceResponse → speak
// 增强: 
// 1. 调 analyzeVoiceResponse 前, 采集 Layer 0 快照, 注入 prompt
// 2. Reply 完成后, parse [ROUTE], dispatch

func onDialogReplyComplete(reply: String, transcript: String) {
    guard let route = parseRouteJSON(reply) else {
        HeyClickyLog.log("openclicky.route_missing", ...)
        return
    }
    switch route.kind {
    case "long_task_new", "long_task_existing":
        startVoiceAgentTaskPlan(
            instruction: transcript,
            workingDirectoryHint: route.workdir,
            progressDriven: true,
            completionMarker: "MARKER-END"
        )
    case "short_task":
        startVoiceAgentTaskPlan(
            instruction: transcript,
            workingDirectoryHint: route.workdir ?? ephemeralTaskDir(),
            progressDriven: true,
            completionMarker: "MARKER-END"
        )
    case "chat", "ambiguous":
        break  // 已 TTS 完
    }
}
```

**不改**现有 voice pipeline. **只加**:
1. Layer 0 prefetch 到 prompt
2. Prompt 教 model emit [ROUTE]
3. Reply parse + dispatch
