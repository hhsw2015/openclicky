# HeyClicky Agent Turn Lifecycle — IDA 1.0.42 逆向纪要

用于指导 OpenClicky 的长时间运行、不跑偏、省配额三个目标。

## 一次 turn 的完整时序

```
用户输入
  │
  ▼
[launchTask] (sub_1007B4688)
  │
  ├─→ ensureCodexAgentReady   (codex daemon 起来 + 授权)
  │
  ├─→ awaitingHaikuLaunchLabelGate  (paywall / 内容审核 gate)
  │     └─ 免费用户可能被这里拦；deny → 直接 abort，不消耗 quota
  │
  ├─→ decision:
  │     ┌─ session.activeTasks[threadId] != nil?
  │     │    → step=steerTask (active thread)
  │     │      → sub_100548EF8 → turn/steer(threadId, expectedTurnId, input)
  │     │      → 0 quota  ✅
  │     │
  │     ├─ threadId 存在但 activeTasks 里没有?
  │     │    → step=resumeThread + submitTurn
  │     │      → thread/resume + turn/start
  │     │      → +1 quota
  │     │
  │     └─ 无 threadId?
  │          → step=submitTask (brand new thread)
  │          → thread/start + turn/start
  │          → +1 quota
  │
  └─→ record-agent-usage (analytics only)

Turn 运行中
  │
  ├─→ codex.rpc: turn/started (learn turnId)
  ├─→ codex.rpc: reasoning / commandExecution / item.completed (任意多次)
  │
  ├─→ 服务端计算 cost 到达 turn 内 cap:
  │     ├─ requires_extra_effort=true
  │     │   └─ extra_usage_auto_approve=true 时服务端可能直接抬 cap 不询问
  │     └─ else fires  `agent_extra_effort_required` error
  │
  ├─→ 客户端 POST /agent/turn-lease/{id}/continue with extra_usage_approval:true
  │     └─ 同 lease 继续，NO NEW quota
  │
  └─→ turn/completed (activeTasks 里此 task 移除)

Turn 结束方式
  │
  ├─ 正常：turn/completed → status=completed
  ├─ Turn quota 到 25/25 服务端限制：agent_turn_limit_exceeded → 需要 reset
  ├─ 网络/上游错误：codex.rpc error → 客户端可 replay
  └─ 客户端主动断：turn/interrupt(threadId, turnId) → 服务端立刻结束
```

## 关键 endpoints (IDA-verified)

| 端点 | 方法 | 消耗 quota | 用途 |
|---|---|---|---|
| `/codex-thread-launch` | POST | 0 (只记 thread) | 建/复用 thread；body 7 字段（见下） |
| `/agent/record-agent-launch` | POST | **+1** | 分配 turn lease（credit 在这里扣） |
| `/agent/turn-lease/{id}/status` | GET | 0 | heartbeat (每 15s) |
| `/agent/turn-lease/{id}/continue` | POST | 0 | 同 lease 内 extra_effort approval |
| `/agent/turn-lease/{id}/complete` | POST | 0 | 显式结算 turn |
| `/agent/session-token` | POST | 0 | mint codex-scoped ephemeral（4h TTL） |
| `/me/plan` | GET | 0 | 查当前 quota (agents X/25) |
| `/agent/account/delete` | POST | 0 | 触发 reset，配合 OAuth chooser |

## codex daemon 内 RPC 方法 (openai/codex 官方 schema)

| 方法 | 消耗 quota | 用途 |
|---|---|---|
| `thread/start` | +1 | 新 thread + 新 turn |
| `thread/resume` | 0 (但 launch 会 +1) | 恢复已有 thread |
| `thread/fork` | +1 | 分叉 thread |
| `thread/inject_items` | 0 | 塞任意 Responses items 到 history（不启动 turn） |
| `turn/start` | +1 | 新 turn（客户端触发） |
| `turn/steer` | **0** | 同 turn 内追加输入 (requires activeTurnId) |
| `turn/interrupt` | 0 | 主动断当前 turn |

## Request body 完整字段 (IDA-verified)

### `/codex-thread-launch` (POST)
```
{
  "thread_id": string,
  "role": "text" | "voice",         // 通道，不是消息 author
  "content": string,
  "is_follow_up": bool,
  "is_demo": false,
  "is_proactive": false,
  "proactive_suggestion_id": null
}
```
Response: `{spoken_start_cue, text_start_cue, title}` — **不 echo thread_id**（客户端持有）

### `/agent/record-agent-launch` (POST)
```
{
  "supports_agent_turn_lease": true,
  "thread_id": string,
  "turn_id": string,               // 客户端生成
  "task_id": string,               // 客户端生成
  "is_follow_up": bool,
  "launch_source": "codex" | ...,
  "idempotency_key": string,
  "extra_usage_auto_approve": true // 关键：设 true 让服务端不 pause 询问
}
```
Response: `{lease_id, turn_id, expires_at, credits_used, included_credits, cost_usd?, cost_limit_usd?, requires_extra_effort, status}`

### `/agent/turn-lease/{id}/continue` (POST)
```
{
  "extra_usage_approval": true
}
```

## 客户端状态数据

- `session.activeTasks: Dictionary<TaskId, CodexRunningTask>` — 内存中的 running-task 表
- `CodexRunningTask` 字段（IDA 观察 offset +5/+6）：`taskId, turnId, threadKey`
- `CodexActiveTaskSnapshot` — 持久化格式，含 turnId + leaseId + expiresAt
- App 退出：`applicationWillTerminate` 写盘
- App 启动：`applicationDidFinishLaunching` → 读盘 hydrate

## 三层省配额最大化策略（我们已实施）

### Level 1: 声明期
- record-agent-launch 时发 `extra_usage_auto_approve:true` → 服务端跑到 cap 自动抬到下 tier
- **省了 pause 询问的往返**，服务端可能直接分配更大 tier

### Level 2: turn 内延长
- 收到 `requires_extra_effort` 事件立即 POST `/turn-lease/{id}/continue`
- **同 lease，0 quota**
- 客户端 `autoContinue()` 已在

### Level 3: turn 间白嫖
- 用户下一条 prompt 到达时：
  - **有 activeTurnID**（内存 or restore 且 expiresAt 未过）→ `turn/steer` = 0 quota
  - **无** → `record-agent-launch` = +1 quota
- 关 app 重开也有效：`activeTurnID + activeLeaseID + leaseExpiresAt` 持久化到 disk

## 关键观察

1. **服务端 `cost_usd` 字段实际不返值** — 客户端不能看 dollar 花销，只能靠 credits/openaiCalls 计数
2. **credits 是 launch 时扣，不是完成时扣** — 已扣的 credit 不退，即使 turn 中断
3. **thread_id 是客户端生成 UUID** — 服务端不 echo 回来，客户端持有为准
4. **服务端按 (account_id, thread_id) 隔离** — 换账号后同 thread_id 拿不回旧记忆（实测确认）
5. **turn/completed 从 activeTasks 里移除** — 之后同 turn 只能 restart（新 quota），steer 会 throw "No active turn"

## 不跑偏关键机制

- Thread 内 codex 内部 `previous_response_id` chain 维持记忆
- 换 thread / 换账号 → 客户端 MEMORY.md/PROGRESS.md/AGENTS.md 兜底
- Steer 在同 turn 内追加输入 → model 看到完整对话前后文，不跑偏

## 长跑最佳实践

1. **不要 followup 直到 turn 真死** — 检查 `activeTurnID + lease heartbeat_ok` 都失效才允许开新 turn
2. **Steer 请求 body 里 input 用完整 UserInput schema** — 支持 text + image + text_elements（尚未验证 image 传递）
3. **AGENTS.md 章程强制 "not stop until DONE"** — 让 model 在同一 turn 内持续产出，塞满 lease cost cap
4. **持久化 lease 元信息** — app 重启也能 0-quota 续
5. **`thread/goal/set` 是长跑防跑偏的真答案** — codex 官方支持，HeyClicky 1.0.42 还没用，我们率先接入

## OpenClicky 相对 HeyClicky 1.0.42 的差异（IDA 论证）

**我们对齐 HeyClicky 有的（14 个）：**

- `turn/steer` + `expectedTurnId` 检查
- `turn/interrupt` 干净退出
- `thread/inject_items` 零 quota 塞背景
- `record-agent-launch` 完整 8 字段 + `extra_usage_auto_approve: true`
- `codex-thread-launch` 7 字段 + `role: "text"`
- `<clicky_agent_turn_lease_metadata>` 内联 tag
- `/agent/session-token` mint ephemeral 作为 codex OPENAI_API_KEY
- `thread/tokenUsage/updated` handler
- `account/rateLimits/updated` handler
- `thread/status/changed` handler + `waitingOnUserInput` 判断
- `CodexActiveTaskSnapshot` 持久化 (`activeTurnID + activeLeaseID + leaseExpiresAt`)
- Chrome ext 驱动 OAuth reset + 8-selector fallback
- turn-lease heartbeat 每 15s
- 三路 launchTask (steer / resumeThread / newThread)

**我们领先 HeyClicky 的（4 个）：**

- **`thread/goal/set`** — codex 官方防跑偏机制，HeyClicky 1.0.42 未使用
- **Per-session recovery budget + 5min cooldown wake** — HeyClicky 无
- **Circuit breaker** (>5 reset fails in 15min → freeze) — HeyClicky 无
- **`MEMORY.md` + `PROGRESS.md` + `AGENTS.md` 文件兜底** — 跨账号 / 跨进程 memory 保全，HeyClicky 无（他们靠服务端 thread hydration，我们证明跨账号不 work）

**HeyClicky 有我们尚未使用但可选的（3 个）：**

- `thread/rollback` — 撤销跑偏的 turn（DEPRECATED 但可用）
- `thread/compact/start` — 压缩 history 省 token
- `thread/shellCommand` — 无沙箱直接跑 shell

## 未验证但可继续挖的方向

- `TurnStartParams.tokenBudget` field —— 单 turn 硬预算，值得实测
- `TurnStartParams.outputSchema` —— 让 model 输出严格 JSON，减少 token 浪费
- `TurnStartParams.effort` —— 提示 codex 降低 reasoning effort，可能省 token
- `TurnStartParams.summary` —— reasoning summary 长度，可以设 auto 或 none
- HeyClicky 的 Haiku launch-label gate —— paywall 前的免费预检，如何绕过或加速
