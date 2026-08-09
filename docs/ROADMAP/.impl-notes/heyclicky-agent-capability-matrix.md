# HeyClicky Agent — Model Capability Matrix

**Model**: `claude-fable-5` (Anthropic) — 通过 HeyClicky Free 服务
后端 `/chat-tool-call` 暴露。测量日期: 2026-07-24。

## Confirmed capabilities

| 维度 | 观测值 | 备注 |
|---|---|---|
| Model identity | Claude Fable 5 (Anthropic) | 前端 realtime = gpt-realtime-2.1，只做 voice relay |
| Structured JSON 输出稳定性 | **10/10** (100%) | 完美遵守指定 schema，无需 fallback parser |
| Input context capacity | ≥ 200 KB (~50k tokens) | 稳定接收；10-12s 响应；超大 input 拒绝硬凑事实 |
| Single-turn output cap | **2000-4300 chars** | 依任务复杂度；模型自主判断 |
| History 对输出影响 (chat) | 无 (3500 chars history → 3249 chars output) | 自然对话 history 不压制输出 |
| History 对输出影响 (tool_call JSON) | 无明显 (1649 chars JSON history → 2747 chars) | 与 chat history 相近 |
| Session ID 累积效果 | 无负面 (3433 chars 输出) | 反而略高，可能是 warmup |
| 说明式 "fresh session, ignore prior" | 有效 (3260 chars) | 有 escape hatch |

## Anomaly (需再验证)

- POC 3 中第 6 轮 tool call 后追加 "写 3000 字报告" 得 230 chars
- 推测原因：**模型对 "5 次 write 后突然要长写作" 判定为异常**，主动缩短
- **不是通用规律** — 独立测试同样条件（H2）仍得 2747 chars

## Refusals / limitations

- 精确计数任务 (数点、数字符) → **诚实说 "I can't count reliably"**（Anthropic alignment）
- Server 无 SSE streaming（response 一次性返回）
- Server 端 tools 硬编码 5 个 (`web_search`, `show_places`, `show_stock_quote`, `save_memory`, `present_walkthrough`) — `client_capabilities` 声明**无法**注入新 server tool

## Verified feasibility (POC 通过)

1. **POC 2 - 长输出契约分段** ✅
   - 协议：`[NEXT]` / `[DONE]` marker 由模型自主输出
   - 5000 字 Rust 教程用 2 轮完成（Part 1: 5123 chars, Part 2: 4453 chars）
   - 10/10 参轮次模型 100% 遵守 marker 协议

2. **POC 3 - Client-orchestrated agent loop** ✅
   - 协议：`{"action":"tool_call"|"done", ...}`
   - 4 轮完成 mkdir + write_file + read_file + done
   - 决策合理 (先 mkdir 再 write，主动 verify)

3. **POC 4 - 多步 grep** ✅
   - 6 轮完成 create 3 files → grep → 汇报
   - 会 batch (一条 grep 拿多文件)
   - 无死循环

## Verified NOT feasible

- **POC 1 - client_capabilities 扩展 server tools** ❌
   - 声明 `write_file` / `run_shell` / `http_request` 无效
   - Server response schema 固定为 `{text, clipboardText, point, typing, widgets}`
   - Server 端 5 个 tools 硬编码

- **POC 6 - parallel tool_calls array** ⚠ 未验证
   - 服务器返 empty text，可能不适应 array schema
   - 或触发某种 rate limit
   - 需要更多测试

## 最佳定位

**不适合**:
- 替代 Codex（无长程执行环境，output 单轮短）
- 长时 iterative debugging（>10 轮 loop 输出会退化）
- 复杂 refactor（多文件协同 edit）

**最适合** — 定位为**"HeyClicky Agent"**（阉割版 Codex）:
- **需求讨论 + 设计文档生成**
- 多轮对话细化 spec，agent 读代码/文档，输出 PROGRESS.md / DESIGN.md / SPEC.md
- 作为 Codex 长程任务的**上游驱动**
- 独立 Python TUI，也可集成到 OpenClicky App

## 使用模式

1. **单轮长输出**（写完整文档章节）→ 直接 chat，不走 tool loop，走 POC 2 分段
2. **短 agent loop**（≤ 5 轮）→ 读几个上下文源 + 写一个文件 + done
3. **混合**：agent 决定"分析用 chat / 写入走 write_file / 长内容走 chunked write"

## Implementation plan (next)

- 独立 Python TUI 项目 `heyclicky-agent-tui/`
- 参考 GitHub 已有 codex 类 TUI 项目 UI (rich / textual)
- Tool set:
  - `read_file(path, offset?, length?)`
  - `write_file(path, content)`  — 可分段接入 POC 2
  - `apply_diff(path, unified_diff)`
  - `list_dir(path)`
  - `run_shell(cmd)` — 全权限，用户机器
  - `grep(path, pattern)`
  - `save_memory(text)` — 本地 `~/.heyclicky-agent/memory.jsonl`
- 会话模式：REPL 输入 → agent 循环 → 结果打印 + 文件写入
- 中途 Ctrl+C 中断，保留 partial 结果 + transcript

## Open questions

- **Q**: 单轮 output cap 是硬 cap 还是模型自主？（明确请求 5000 字模型仍缩到 947 chars）
- **Q**: POC 3 的第 6 轮 230-char anomaly 什么条件下必然触发？
- **Q**: `save_memory` server tool 我们本地能触发吗？（当前 tool 只在 server prompt 里，client 不能主动调）
