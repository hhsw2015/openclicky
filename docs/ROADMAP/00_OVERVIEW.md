# OpenClicky - 下一阶段路线图

**目标**: 让 openclicky 成为 macOS 上一站式的 "感知 + agent" 平台. **完整替代** Everywhere (不依赖它, 不共存, drop-in 独立替换), 后端对接本地 codex + 外部 Claude Code / cmux.

## 🔴 最核心原则 (unbreakable)

**Everywhere 源代码 + 相关上游项目代码 (`open-connector` / `OpenCLI` / `OpenDia` / `OCCU` / `xlinkBook` / etc) = 唯一事实依据.**

一切其他材料都可能有幻觉 / 错误 / 过时, **不能作为决策依据**, 包括:
- Everywhere 自己的 `docs/specs/*.md` / `docs/Mcp/*.md` / `HANDOFF.md` / `PARITY_MATRIX.md`
- openclicky 自己的 roadmap doc (00-10, 包括这份)
- 任何我 (Claude / agent) 写的 impl-notes / summary / analysis
- 任何 skill / SPEC / README

**执行规则**:
- doc 与代码冲突 → **代码赢**
- doc 与 doc 冲突 → 都不作数, 回代码看
- 我写的分析与代码冲突 → 我的分析扔掉, 回代码看
- Everywhere 上游 doc 与 Everywhere 代码冲突 → 代码赢
- 上游项目 (open-connector 等) doc 与其代码冲突 → 代码赢

**行动规则**:
- 任何决策前, 先打开 Everywhere / 上游对应源 file 亲眼确认
- 任何 doc 断言若无法从代码 verify, 视为可疑, 需 mark `⚠️ unverified` 或删除
- 任何"我记得代码是这样"→ 一定回代码 grep 一次, 不信记忆
- 五步流程 (调研 / 修文档 / 实现 / 对齐 / 测试) 中每一步的"事实"都来自代码, 不来自 doc

---

**移植方针 (次要, 服从核心原则)**:
1. **Everywhere 有的能力全都要移植** (以 Everywhere 源代码里实际存在的为准, 不以 doc 里声称的为准) — 不选择性丢弃
2. **原封不动搬能力, 品牌 rewrite** (`everywhere-*` → `openclicky-*`)
3. **保留 Everywhere 的使用习惯** (hotkey 语义 / Settings 结构 / 默认行为, 全部以 Everywhere 源代码为准)
4. **KnownApps hint 协议必须实现** — 协议细节 (URL 转换规则 / regex timeout / 匹配顺序) 全以 `Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` 源码为准
5. **代码为源, 文档为影, zero-drift** — 五步流程, 详见 `08_QUALITY_ASSURANCE.md`
6. **自动化优先, 减少人工** — 一切能自动化的测试都自动化 (单元 / Golden diff / 集成 / 端到端 MCP curl diff). Agent 自建自跑, 自发现问题自修. 人工只做自动化覆盖不到的最后验收 (TCC 授权 / 视觉验证 / 上游 fixture 重录). 详见 `08_QUALITY_ASSURANCE.md` Step 5
7. **并行独立任务, 加速开发** — 能并行则多 agent 并行 (parallel Agent tool calls). 并行前提: 任务完全独立 (file 无重叠 / 无 build 依赖 / 无运行时冲突 / 无 doc reconcile 冲突 / 无 fixture 冲突). 主 orchestrator (本 session) 负责分解 + 判定 + 冲突时回串行. 用 subagent worktree isolation 隔离并行代码改动. 详见 `08_QUALITY_ASSURANCE.md` "并行 agent 策略"

详见 `08_QUALITY_ASSURANCE.md` (翻译策略 + 五步流程) + `10_OVERLAP_ANALYSIS.md` (能力覆盖清单, 但**清单里数字都需回代码 verify**).

---

## 大方向

- 用户按 hotkey 说话 → openclicky 自动采集当下上下文 → **高级模型的回复** 里附带意图分类 (副产物, 非独立 Router 前置调用) → codex agent 分流执行, **一句语音零学习成本**.
- 对外也是 MCP 服务提供者: Claude Code / cmux / Cursor 可以把 openclicky 当 Everywhere 用.
- 复用 Everywhere 的感知能力 (26 项对等 + 4 项 openclicky 独有 = 30 项) 与它对外的 MCP tools (**96 unique tool name, 53 file** 实测).

---

## 分层架构

```
┌────────────────────────────────────────────────────────┐
│  Layer 4 - UX (Everywhere-parity)                       │
│    Whiteboard 手势 · LinkRect · PickStash · Settings 面板 │
├────────────────────────────────────────────────────────┤
│  Layer 3 - Context Stash + Hook (对外生态兼容)          │
│    ~/Library/Application Support/OpenClicky/            │
│      context-stash.json + hook CLI                       │
├────────────────────────────────────────────────────────┤
│  Layer 2 - MCP `/mcp/sensor` (对外 agent 消费)          │
│    96 tools: get_focused_context / screenshot / click ...│
├────────────────────────────────────────────────────────┤
│  Layer 1 - 意图分类 (由高级模型回复副产, 非独立 Router) │
│    voice + prefetched ctx → 模型回复末尾 [ROUTE] JSON   │
├────────────────────────────────────────────────────────┤
│  Layer 0 - ContextService (Swift 采集能力)              │
│    30 项 (26 Everywhere-parity + 4 openclicky 独有)     │
└────────────────────────────────────────────────────────┘
```

**关键设计原则**:
1. Layer 0-3 完全独立新代码; Layer 1 (意图分类) 只轻量修改现有 voice pipeline (加 prompt + reply parse)
2. 每 phase 完成后能独立运行 + revert
3. 每 capture 项**默认可关**, 走 Settings 面板配置 hotkey / target app
4. **golden diff** 与 Everywhere 逐项验证

---

## Everywhere 参考资料 (读源码 + 读 spec)

**代码源**:
- `~/Dev/Everywhere/src/Everywhere.Mac/` — 平台层, 逐 file port
- `~/Dev/Everywhere/src/Everywhere.Mcp/Tools/` — MCP tool 实现 (53 file, 96 unique tool 名照抄)
- `~/Dev/Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` — stash writer 主逻辑
- `~/Dev/Everywhere/tools/everywhere-context-hook/src/main.rs` — Rust hook 协议参考
- `~/Dev/Everywhere/src/Everywhere.Core/Configuration/Settings/ShortcutSettings.cs` — 8 hotkey 定义 + 默认值
- `~/Dev/Everywhere/3rd/open-codex-computer-use/packages/OpenComputerUseKit/` — Swift package, openclicky 直接 SPM 依赖

**Spec 文档**:
- `~/Dev/Everywhere/docs/Mcp/SPEC.md` — MCP server 完整 spec (transport / tool 边界 / port 7878)
- `~/Dev/Everywhere/docs/Mcp/USAGE.md` — 客户端配置 (Claude Desktop / Codex CLI / HTTP)
- `~/Dev/Everywhere/docs/specs/PARITY_MATRIX.md` — 151 tool 完整清单 (含 browser_* 转发到 OpenDia; 本 App 侧实测 96 unique `McpServerTool` name, 见 `Everywhere.Mcp/Tools/`)
- `~/Dev/Everywhere/docs/specs/everywhere-self-expanding.md` — Self-expanding tools + core-tool gate (53KB, wowdd1 SPEC v3)
- `~/Dev/Everywhere/docs/specs/everywhere-doc-readers-mcp.md` — 7 doc readers (pdf/docx/xlsx/pptx/epub/html/txt)
- `~/Dev/Everywhere/docs/specs/everywhere-opencli-adapters.md` — OpenCLI 站点适配器
- `~/Dev/Everywhere/docs/specs/everywhere-connector.md` — Open-Connector (**831 provider** 实测 `3rd/open-connector/src/providers/`, spec 里写 840)
- `~/Dev/Everywhere/docs/specs/everywhere-replace-agent-browser.md` — OpenDia browser bridge (85 WS ops)
- `~/Dev/Everywhere/docs/specs/HANDOFF.md` — 各 phase 完成状态
- `~/Dev/Everywhere/docs/StrategyEngine/` — Skills / matching / preprocessor (StrategyEngine 完整 6 file)
- `~/Dev/Everywhere/docs/SettingsEngine/` — Settings source-gen / JsonDocument store (6 file)

**wowdd1 开发脉络** (2026-06 to 07):
1. `mac/ax` — AX bridge + descendant-click + typeText 补正
2. `snapshot` — a11y 树渲染 (formattedLabelSegment / displayRoleText / AXLink markdown)
3. `ax` — Swift dylib bridge over OpenComputerUseKit (关键: openclicky 可直接 SPM 依赖 OCCU)
4. `annotation` — AnnotationStash 后端 + red badge UI + ➕ textarea + ✓ 持久 + delta-follow (7 commit)
5. `mcp` — core-tool gate (tools/list 25K→6K) + self-expanding tools + chat bus
6. `opencli` — 站点适配器 + Node builtin polyfill + site-scoped fuzzy list
7. `connector` — 12 phase, OAuth + credential encryption + 831 providers 实测 (spec 里 840) + Web Console

## 各 Layer 详细文档

- `01_LAYER_0_CONTEXT_CAPTURE.md` — 30 项能力 (26 Everywhere-parity + 4 独有)
- `02_LAYER_1_INTENT_ROUTER.md` — voice → 高级模型回复 [ROUTE] → 4 类分流
- `03_LAYER_2_MCP_SENSOR.md` — 96 MCP tool 完整清单
- `04_LAYER_3_STASH_HOOK.md` — stash file + Claude Code hook
- `05_LAYER_4_UX.md` — Whiteboard / LinkRect / PickStash
- `06_UI_INTEGRATION.md` — 现有 UI 与新流程整合方案
- `07_TASK_TYPE_TAXONOMY.md` — chat / short / long_new / long_existing 判据
- `08_QUALITY_ASSURANCE.md` — 翻译代码质量保证策略
- `09_MIGRATION_ORDER.md` — 具体实施顺序

---

## Task 判定验证

**Router POC 已跑通** (26 case, 88% 命中):
- `/tmp/oc-router/router.py` (v4 with UI context)
- `/tmp/oc-router/testcases.json`
- 结论: advisor msgs 通道 (免费) + project keyword hints 可判 chat/short/long_new/long_existing

**待接入正式代码**:
- 现有 voice pipeline 的 system prompt 加 [ROUTE] 指令 + Layer 0 上下文注入
- 现有 `onDialogReplyComplete` 加 `parseRouteJSON` + 分流
- Layer 0 采集真实上下文而非模拟

---

## 优先级

**P0 (核心, 立即)**:
- Layer 0 前 8 项 (frontmost / finder / selected_text / browser_url / clipboard / workdir_probe / recent_sessions / project_registry)
- Layer 1 Router 接入 openclicky voice pipeline
- Layer 2 MCP sensor 端点 + 感知类 tool (get_focused_context, screenshot, get_selected_text, get_clipboard, get_finder_selection, get_browser_url, get_browser_tabs, get_terminal_output)

**P1 (完整感知)**:
- Layer 0 剩余 18 项 (AX tree / OCR / element_under_cursor / idle / etc)
- Layer 2 action tools (click / type_text / press_key / scroll / drag / set_value)
- Layer 2 doc readers (pdf/docx/xlsx/pptx/epub)

**P2 (对外生态)**:
- Layer 3 stash + `openclicky-context-hook` CLI (独立, 不依赖 Everywhere)
- Stash 路径 `~/Library/Application Support/OpenClicky/context-stash.json`
- Payload envelope `[openclicky-ctx*]` (照 Everywhere 结构 rename 品牌)
- Settings 面板 "Context Awareness"

**P3 (UX / 高级)**:
- Layer 4 Whiteboard gesture + OCR
- Layer 4 LinkRect harvest
- Layer 4 PickStash pinning
- Domain gating (SessionActivations / activate_domain)

**P4 (可选)**:
- Web search / web fetch tools
- OpenCLI adapter runtime
- Open-Connector SaaS providers
- Batch multi-tool dispatch
- OpenDia browser extension bridge

---

## 与现有代码交集

已有基础不必重写:
- `cursor-buddy/CircleSelectSnapResolver.swift` — 已有 AX walk 基础
- `cursor-buddy/HeyClickyChatToolCallClient.swift` — 已有 advisor msgs 通道
- `cursor-buddy/HeyClickyFreePlanningClient.swift` — 已有 `/agent/plan/generate`
- `cursor-buddy/OpenClickyExternalControlBridge.swift` — 已有 MCP `/mcp/advisor` + `/mcp/orchestrate` (SSE Streamable HTTP)
- `cursor-buddy/AppResources/OpenClicky/CuaDriverRuntime/cua-driver` — 已 bundled OpenComputerUseKit (与 Everywhere 同源!)

**关键**: OpenComputerUseKit 已经在项目里, Everywhere 的 `OccuAxBridgeBackend.cs` 那套 (list_apps / get_app_state / click / type_text / press_key / scroll / drag / set_value / perform_secondary_action) 我们可以**直接调 bundled cua-driver 二进制**, 不用重写.
