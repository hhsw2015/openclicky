# Task 分类判据

高级模型判定用. 参考此文档校准 prompt.

---

## 4 类 + 1 fallback

### 1. `chat` — 对话/问答

**特征**:
- 无副作用: 不读文件系统, 不改状态, 不启动进程
- 用户等一句回答就满足
- 模型直接答就行 (可能用 knowledge / advisor 内置能力如 web_search)

**例**:
- "现在几点"
- "讲个笑话"
- "解释一下 Rust ownership"
- "查下今天纽约天气"
- "这段错误信息啥意思" (若 selected_text/clipboard 给了)

**动作**: TTS 回答, 无 codex, 无文件, 无 dock item.

---

### 2. `short_task` — 短任务

**特征**:
- 有观察性副作用 (打开 app, 截屏, 改一处代码, 调音量)
- 1-3 步就完
- 结果快, 用户等着看
- 不需要 checklist 追踪

**例**:
- "打开 Safari"
- "截个屏"
- "把桌面这个 pdf 放到下载"
- "改一下这行 typo"
- "调音量到 30"
- "复制这段代码"

**动作**: 
- Workdir: `selected_folder` (若 Finder 选了) 或 `~/Library/Application Support/OpenClicky/EphemeralTasks/<slug>/` 
- Codex prompt: 用户原话 + "Build a ≤5 checklist in progress.md, MARKER-END done"
- Codex 自建 checklist + 执行 + MARKER-END
- Dock item, `progressDriven = true`

---

### 3. `long_task_new` — 新项目

**特征**:
- 从零建 (没有 codebase 依赖)
- 多文件, 需要架构决策
- 用户能容忍规划步骤

**例**:
- "帮我做个 Rust CLI grep"
- "建一个 Vue todo list 前端"
- "写一个 Python HTTP REST server"

**动作**:
- Workdir: 
  - 若用户 Finder 选了空目录 → 用该目录
  - 否则 → `~/OpenClickyTasks/<slug>/`
- **advisor 一次调用** 生成完整 spec.md (免费 msgs 通道)
- Codex spawn, `Follow spec.md, MARKER-END done`
- Dock item, `progressDriven = true`

---

### 4. `long_task_existing` — 已有项目改动

**特征**:
- 用户指名一个 project (通过关键词命中 known_projects)
- 需要 codex 探索 codebase 才能规划
- 多轮 turn, 可能触发 lease 边界

**例**:
- "在 openclicky 里加截屏工具" (openclicky match keyword)
- "重构 CompanionManager 的 voice pipeline" (CompanionManager → openclicky)
- "给 ccline 加个新 subcommand" (ccline match)
- "把 clicky-mac 的 OAuth 改成 PKCE"

**动作**:
- Project registry 查 project_ref → path
- Workdir: `<project>/.openclicky/tasks/<slug>/`
- Codex prompt: `Read codebase in <project>. Plan changes for <voice>. Write spec.md + progress.md in <taskDir>. Execute.`
- **不预生成 spec** — codex 探索后自建 (它能读文件, advisor 不能)
- Dock item, `progressDriven = true`

---

### 5. `ambiguous` — 无法判定

**触发条件**:
- 用户指代不明 ("那个 bug 修一下" 没上下文)
- 项目名找不到 (说 "在 foo 加一下" 但 foo 不在 known_projects)
- 用户话太短 ("帮我", "写代码")

**动作**:
- 高级模型自然反问 clarify (回复里已问)
- openclicky **不 spawn codex**, 等用户下一句语音
- 用户答完 → 走同一 pipeline 重新判定

**Confidence 阈值**: model 输出 `confidence < 0.6` → 视为 ambiguous.

---

## 判定辅助 signals

### 从 Layer 0 prefetch 拿的:

| Signal | 用于判 | 例 |
|---|---|---|
| `selected_folder` | short/long_task | Finder 选空目录 → long_task_new; 选已有项目 → long_task_existing |
| `selected_text` | 消除引用 | "改这段" + selected_text 有内容 → short_task |
| `frontmost_app` = IDE/编辑器 | 提示当前是开发场景 | 前台 Xcode + "改这行" → short_task 或 long_task_existing |
| `browser_url` | 相关话题 | 前台 Github + "clone 这个 repo" → short_task |
| `recent_agent_session` | resume | "继续之前的" + recent_session != nil → long_task_existing on that project |
| `clipboard_preview` | 引用 | "帮我看这段" + clipboard 有 error → chat 或 short_task |

### 关键词 (英文/中文混合)

| 关键词 | 提示 |
|---|---|
| build/create/make/新建/建一个/做一个 + object | long_task_new |
| refactor/rewrite/重构/改造 + module/class | long_task_existing |
| add/加/新增 + feature + 项目名 | long_task_existing |
| fix/修/修一下 + specific target | short_task 或 long_task_existing |
| open/打开/启动 + app | short_task |
| screenshot/截屏/copy/复制/paste/粘贴 | short_task |
| explain/解释/what is/是什么/为什么 | chat |
| continue/继续/接着 (无对象) | ambiguous_resume, 查 recent_session |

---

## Confidence 校准

- **>= 0.9**: 关键词明显 + 上下文一致 (`long_task_existing on openclicky` when selected_text 显示 CompanionManager.swift)
- **0.7-0.9**: 意图清晰, 但缺一部分信息 (如 slug 需要 model 自造)
- **0.5-0.7**: 需要额外确认 (project 有 2 个可能) — model 应在 reply 里问
- **< 0.5**: ambiguous, 反问

---

## 特殊场景

### resume/continue

用户: "继续之前的"
- 若 `recent_agent_session` 存在 + 未 DONE → long_task_existing 到该 session 的 project, prompt = "继续 progress.md 中未完成的 checklist"
- 若 recent_session 为空 → ambiguous, 反问 "继续什么?"

### referential (this/that)

用户: "改这个" / "重构那段"
- 若 `selected_text` 有 → 该文本是引用对象 → short_task
- 若 `selected_folder` 有 → 该目录 → long_task
- 都无 → ambiguous

### 多项目歧义

用户: "在 openclicky 里改..."  
known_projects 有 `openclicky` 和 `openclicky-fork`:
- model 应问 "openclicky 还是 openclicky-fork?"
- 或用 recent_session 或 frontmost 窗口标题辅助定
