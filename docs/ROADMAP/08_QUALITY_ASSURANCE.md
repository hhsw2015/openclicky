# 翻译代码质量保证

**目的**: 从 C# (Everywhere) 翻到 Swift, 避免 silent 语义偏差. **工作量大, 代码全现成 — 关键是翻译过程 bug 最少.**

---

## 翻译 bug 最少化策略 (总纲)

### 🔴 最核心原则

**Everywhere 源代码 + 相关上游项目代码 = 唯一事实依据.**

一切其他材料都可能有幻觉 / 错误 / 过时, **不作为决策依据**:
- Everywhere 自己的 `docs/`
- openclicky roadmap doc (00-10)
- 任何 AI 生成的分析 / impl-notes / summary
- 任何 SPEC / HANDOFF / README / PARITY_MATRIX

**doc 与代码冲突 → 代码赢. 记忆与代码冲突 → 代码赢. 一切与代码冲突 → 代码赢.**

任何 doc 断言若无法从代码 verify, 视为可疑. 决策前必回代码亲眼确认.

### 并行 agent 策略 — 独立任务并发, 依赖任务串行

**核心方针**: 能并行则并行 (多 agent), 加速开发. 但**并行前提是任务完全独立** — 无 file / 依赖 / 状态冲突.

#### 独立性判定 (all must hold)

一组任务可并行, 必须同时满足:

1. **File 无重叠**: 每个 agent 编辑的 file 集合两两不相交 (不同 Swift file, 不同 doc section)
2. **无 build 依赖**: A 的 output (类型 / 函数 / 常量) 不是 B 的 input
3. **无运行时状态冲突**: 不同时抢 hotkey / port / stash file / process singleton
4. **无 doc reconcile 冲突**: 若都要改同一份 doc, 不能并行 (先后 commit 冲突)
5. **无 fixture 冲突**: golden-diff 若两个都要触发 Everywhere hotkey, 不能并行 (Everywhere 单飞)

**任一条不满足** → 串行.

#### 独立任务示例 (可并行)

| Agent 1 | Agent 2 | 为什么独立 |
|---|---|---|
| Port `MacFinderReader.cs` → `FinderSelectionCapture.swift` | Port `MacBrowserUrlReader.cs` → `BrowserURLCapture.swift` | 不同 file, 不同 AppleScript, 无 build 依赖 |
| Port `MacIdleTimeReader.cs` → `IdleTimeCapture.swift` | Port `MacClipboardReader.cs` → `ClipboardCapture.swift` | 完全独立 |
| Port `DocReadPdfTool.cs` → `DocReadPdf.swift` | Port `DocReadDocxTool.cs` → `DocReadDocx.swift` | 完全独立 |
| Write unit tests for `URLRedaction.swift` | Write unit tests for `TextSanitisation.swift` | 不同测试 file, 无依赖 |
| Impl `open-connector` Node subprocess | Impl `OpenCLI` runtime | 若共享 Node runtime, 有依赖 → 串行; 若各自独立 subprocess, 可并行 |
| Doc review of `01_LAYER_0` | Doc review of `03_LAYER_2` | 不同 doc file |

#### 依赖任务示例 (必须串行)

| Task A | Task B | 依赖 |
|---|---|---|
| Doc reconcile `04_LAYER_3` | Impl `ContextStashWriter.swift` | B 要读修正后的 A |
| Port `AXQuirksInstaller.swift` | Port `AXTreeCapture.swift` | B 依赖 A 的 flip |
| Build Node runtime bundle | open-connector / OpenCLI 都用它 | 共享 |
| Golden diff fixture 采 Everywhere | Golden diff 采 openclicky | Everywhere 需先跑 (但不同 fixture 可并行) |
| Update doc line X | Update doc line X | 同 file 同 section |

#### Agent launch 规则

- **一条 message 里可以 launch 多个独立 Agent** (Claude Code 支持 parallel tool calls, 用多个 Agent tool 块)
- 每 agent prompt 必须明确: 该 agent 的 file 边界 / 允许改的目录 / 禁止碰的 file
- 每 agent 有独立 fixture / 独立 test target, 避免锁竞争
- **Foreground vs background**: 若结果影响后续决策 → foreground; 若纯执行任务 (port + test) → background
- 用 subagent isolation (worktree) 隔离并行的 code 改动, 避免 git 冲突: `Agent({ isolation: "worktree" })`

#### 并行度控制

- 同一 Phase 内允许 2-4 个 agent 并行 (更多需评估 CPU / API rate limit)
- 跨 Phase 若上游未完成不能启下游 agent (依赖破坏)
- 每 agent 完成后必跑该 agent 负责范围的自动化测试 (5.1-5.4 subset), pass 后才 commit

#### 冲突预防

- 每 agent 用独立 branch 或 worktree, 完成后 rebase 主 branch
- 若 doc reconcile 是共享工作, 单线程一个 agent 全部改完, 才 fan out 并行 port
- Golden diff fixture 目录若并行采集, 每 agent 用独立 fixture-id (避免文件覆盖)

#### 主 orchestrator (Claude Code 主 session) 责任

- 分解 Phase 到独立任务列表
- 判定哪些可并行, 哪些必须串行
- 一次 launch 一组独立 agent
- 收集结果, 合并结果, 决定下一组
- 冲突时终止并行, 回串行重跑

---

### 每个移植任务的强制流程 (五步, 代码为源, zero-drift)

Step 1 调研时**只**从 Everywhere 源 file + 上游代码 (open-connector / OpenCLI / OpenDia / OCCU / xlinkBook 等对应源) 提取事实. **不**基于本 roadmap doc / Everywhere docs/ / AI 分析结论.

发现文档与代码不符 → 一律以 Everywhere 源代码为准, 修文档.

**每个 Phase / file / 能力的移植分五步**:

#### Step 1: 调研 (Investigation) — 事实来源仅限代码

**允许的事实源**:
- Everywhere `.cs` / `.rs` / `.ts` / `.swift` 源 file
- 上游 (open-connector / OpenCLI / OpenDia / OCCU / xlinkBook) 的源 file
- Everywhere `git log --author=... -- <path>` (commit 元数据本身)

**禁止**作为事实源:
- Everywhere `docs/` 目录 (SPEC.md / USAGE.md / HANDOFF.md / PARITY_MATRIX.md / specs/*.md)
- openclicky roadmap doc (00-10, 包括本文档)
- AI 生成的 impl-notes / summary
- 记忆 / "我记得代码是这样"

流程:
- 打开 Everywhere 对应源 file, 完整读一遍 (不跳段)
- 打开对应上游 (open-connector / OpenCLI / OpenDia / xlb / OCCU) 相关代码
- `git log -- <path>` 看最近 commit, 看是否有近期修 bug
- 若需 doc 辅助理解, 可读 Everywhere `docs/`, 但**任何 doc 声称的事实必须从代码 verify**才能采用
- 记录: 代码与我们 docs (00-10) 是否一致? 找出所有 divergence
- 产出物: `.impl-notes/<phase>-<file>.md` 记录来自**代码**的要点 (每行注明 file + line number), 以及 docs 错误列表

#### Step 2: 修文档 (Doc reconciliation)

- 发现 doc 与代码不符 → **先改 doc** 到与代码一致
- 发现 doc 遗漏关键细节 (edge case / env var / config field / error handling / magic constant) → 补进去
- Commit: `docs(<layer>): reconcile with Everywhere <path>@<rev>`
- 产出物: 更新后的 doc, 精确匹配当前 Everywhere 源码状态
- **禁止跳过此步骤直接写代码**. 即使只有一个字段偏差也要 commit doc 修正

#### Step 3: 实现 (Implementation)

- 按修正后的 doc 落 Swift 代码
- 每 file 头 `// Ported from Everywhere: <path>@<rev>` 记录来源
- 保留原注释 (翻译成中英双语), 特别是 `///` warning / TODO / hack 说明
- 若实现中又发现新的代码/doc divergence → 回 Step 2 (不允许边写边改 doc 不 commit)
- Commit: `feat(<layer>): port <FileName> from Everywhere <path>@<rev>`

#### Step 4: 对齐审查 (Alignment audit)

**实现完成后, 强制回读对照**:

- 打开 Everywhere 源 file 与 Swift port side-by-side
- 逐段 diff, 检查:
  - [ ] 每个 method 签名一致 (参数顺序 / 类型 / 默认值)
  - [ ] 每个 magic constant 一致 (`MaxLinks=200`, `MaxUrlLen=2048`, `RepeatSuppressionMs=1500`, etc)
  - [ ] 每个 sanitisation 边界一致 (title≤80, selection≤200, annotation.body≤800, ...)
  - [ ] 每个 redaction 规则一致 (userinfo strip, denylist query params 完整列表)
  - [ ] 每个 error path 一致 (return null vs throw, log level, retry)
  - [ ] 每个 lock / semaphore 语义一致 (Everywhere `WaitAsync(0)` 立即返回 false vs `.WaitAsync()` 阻塞)
  - [ ] JSON 字段名与序列化顺序一致 (`WhenWritingNull` 语义, `snake_case`)
  - [ ] 注释里 Everywhere 提到的 warning / hack 都在 Swift 里保留
- 记录任何"故意 divergence"(必要的 Swift-specific 调整) 到 file header 注释
- 若发现任何**非故意**的 divergence → 回 Step 3 修
- Commit: `chore(<layer>): align <FileName> to Everywhere <path>@<rev>` (若有修改)

#### Step 5: 测试 (Test) — **自动化优先, 减少人工**

**核心方针**: 能自动化的一律自动化. 人工只做自动化覆盖不到的最后一步验收. 目标: **agent 自己发现问题 + 自己修正**.

**Test 责任等级 (全部自动化)**:

##### 5.1 纯逻辑单元测试 (XCTest, 全自动)

sanitisation / redaction / grapheme truncate / JSON serialize / URL parse 等纯函数.

每 corner case 独立 test case:
- Emoji (single / ZWJ 组合 / flag / skin-tone)
- RTL (阿拉伯 / 希伯来)
- 空字符串 / null / undefined
- 超长 (刚好边界 / 边界+1 / 边界×10)
- 中文 / 日文 / 韩文
- Password field 类字段
- IPv6 URL (含 `[::1]`)
- URL userinfo (`user:pass@`)
- 每个 denylist query param (16 个逐个测)
- 控制字符 `\0\n\r\t\v\f\b`
- 组合 (emoji + RTL + 控制字符 + 边界长度)

**运行**: `xcodebuild test` (但按 CLAUDE.md 规则不由 agent 直接跑 xcodebuild, 而是 agent 用 `swift test` 于纯 SPM package, 或用 `swiftc -parse` verify 语法 + 单独 test target).

##### 5.2 Golden diff 自动化 (核心保证, 全自动)

`scripts/golden-diff/` 目录, agent 自建自跑:

- `setup-fixture.sh <fixture-id>` — osascript 布状态 (Safari 打开 URL / Finder 选文件 / xlb 点 topic 等)
- `capture-everywhere.sh <fixture-id>` — 触发 Everywhere hotkey (osascript key event), 等 stash 写完, 复制到 `fixtures/<id>-everywhere.json`
- `capture-openclicky.sh <fixture-id>` — 同上, openclicky 侧
- `diff-fixture.py <fixture-id>` — 对比 JSON, 忽略 pid/timestamp/品牌前缀, 输出 structural diff. Exit 0 = pass, non-zero + report = fail
- `run-all.sh` — 跑所有 fixture, 汇总
- Agent 每次改代码后自动跑一次, 有失败自动进入 debug 循环 (回 Step 3/4 修 + 再跑)

**Fixture 目录**: `scripts/golden-diff/fixtures/` 保存历史 golden output, git 管理. Everywhere 侧 fixture 只采一次 (Everywhere 输出是 ground truth), openclicky 侧每次 rebuild 采一次做 diff.

##### 5.3 集成测试自动化 (半自动)

`scripts/verify-context/<capability>.sh`:
- 前置状态用 osascript / AppleScript 布 (非人工点击)
- Swift 采集
- XCTest assert 结构 / 字段 / 边界
- 用 `swift test --filter <TestName>` agent 直接跑

例:
```bash
# scripts/verify-context/finder-selection.sh
osascript -e 'tell app "Finder" to reveal file "~/Downloads/test.pdf"'
osascript -e 'tell app "Finder" to activate'
sleep 0.3
swift test --filter FinderSelectionCaptureTests
```

Agent 编 fixture 脚本, 跑, 分析 XCTest 输出, 修 bug, 再跑.

##### 5.4 端到端 MCP 自动化 (curl-based, 全自动)

`scripts/e2e-mcp/`:
- `test-tool.sh <tool_name> <args_json>` — curl openclicky MCP endpoint + Everywhere MCP endpoint, diff response
- 每个 sensor tool 至少 3 个 test case (happy / edge / error)
- 输出 diff report, 自动判 pass/fail

**Everywhere 侧需先启用它的 HTTP MCP**: 用户装了 Everywhere, 我们脚本自动 curl `http://localhost:7878/mcp`.

##### 5.5 CI 集成 (强制)

`.github/workflows/golden-diff.yml` (或类似):
- Push 触发
- 跑 5.1 单元测试
- 跑 5.3 集成测试
- 5.2 / 5.4 因需要另装 Everywhere, 只在本地跑, PR 里贴 diff 结果

##### 自动化优先级

**必须自动化** (不允许人工):
- 5.1 单元测试
- 5.2 Golden diff (agent 自建自跑循环)
- 5.3 集成测试
- 5.4 端到端 MCP curl diff

**只在这些场景允许人工**:
- macOS 权限首次授予 (TCC prompt, 无法脚本化)
- 视觉验证 (UX 层 badge 位置 / animation 平滑度)
- 上游 Everywhere 版本升级时的一次性 fixture 重录

**Golden diff 是核心保证**. Everywhere 的行为是 ground truth. openclicky 输出偏差 = bug. Agent 循环: 跑 diff → 有偏差 → 自动读 diff → 定位代码 → 修 → 再跑 → pass.

**测试通过标准**:
- 单元测试 100% pass
- Golden diff structural fields 100% 一致
- 端到端 MCP curl diff 3 fixture 全 pass
- 集成测试 100% pass

**若测试发现 bug**: agent 自动回 Step 3 或 Step 4 修. 不允许失败合并.

Commit: `test(<layer>): add auto golden-diff + unit tests for <FileName>`

#### 交付 checklist (每 file 完成前签字)

- [ ] `.impl-notes/<phase>-<file>.md` 已写 (Step 1 产出)
- [ ] docs (00-10) 与代码一致, 有 reconcile commit (Step 2)
- [ ] Swift port 有 `// Ported from Everywhere: <path>@<rev>` header
- [ ] Side-by-side diff 完成, 无非故意 divergence (Step 4)
- [ ] 单元测试 100% pass, corner case 全覆盖
- [ ] Golden diff 与 Everywhere 输出对齐
- [ ] Alignment audit 记录已归档 (Step 4 产出)

**原则**: 文档滞后 vs 代码超前时, 代码赢. 允许 doc 被修正很多次, 不允许代码基于错误 doc 实现. 允许 test 反推 doc/实现修正, 不允许有失败 test 混入 main.

---

## 补充 QA 措施 (15 条完整清单)

已实施的 3 条 (前面章节):
1. 实现前调研 (Step 1)
2. 实现后与源代码对比 (Step 4 + Step 5 Golden diff)
3. 以参考项目为准 (最核心原则)

补充 12 条:

### 4. 分层小步交付 (P0)

- 每 file 独立 PR (200-400 行), 每 PR 走完五步 + 通过 Golden diff, 才 merge
- 一个 bug 只影响一 file, 定位快, revert 便宜
- **禁止**批量提交多 file (一次 >800 行的 PR 拒收)

### 5. Property-based random fuzz (P0)

除固定 fixture, 用**随机输入**打纯逻辑函数:
- 随机 Unicode string (含 ZWJ / surrogate pair / control char / RTL / emoji flag / skin-tone)
- 随机 URL (含 IPv6 / userinfo / 各种 query param 组合 / long path / percent-encoded)
- 随机 sanitisation input (超长 / 全控制字符 / 全 bracket / 空)

Swift `SwiftCheck` 或简单 `for _ in 0..<10000` 循环生成, 同一输入喂 Everywhere binary + openclicky, output 应字节一致. Agent 自动跑, diverge 就自动缩小反例.

`scripts/fuzz/`:
- `fuzz-sanitisation.swift` — random string → SanitiseUserText / SanitiseTokenValue
- `fuzz-redaction.swift` — random URL → RedactCredentials
- `fuzz-grapheme.swift` — random string → TruncateGraphemes
- 每个 fuzzer 循环若干轮, 差异保存到 `fuzz-failures/`, agent 读取自动修

### 6. Byte-level Golden diff (P0)

Golden diff 现在是 JSON 结构对比. 更严: **byte-for-byte** diff stash file 本身. 只忽略 pid / timestamp / 品牌前缀 (前缀 rewrite 规则明确). 字节偏差 = bug.

抓 JSON 字段顺序 / 空白 / 编码差异 (Everywhere `WhenWritingNull` vs Swift `Codable` 默认 `null`, JSON 空格, escape 等).

`scripts/golden-diff/byte-diff.py`: 加载两文件 → 字符级 diff → 除 whitelist 项外 report.

### 7. 反向测试用 Everywhere hook (P1)

用户装的 `everywhere-context-hook` (Rust binary) 应能消费 openclicky 写的 stash (若 openclicky 支持双写或用户显式配 Everywhere 前缀).

Openclicky 用自己的 hook 时, 反向验证:
- openclicky 写 stash → openclicky-context-hook 输出 X
- Everywhere 写 stash (相同 fixture) → everywhere-context-hook 输出 Y
- X 与 Y 应结构一致 (除品牌前缀)

证明两 hook 语义等价.

### 8. Coverage-guided fuzz (P1)

XCTest coverage report → 找到未 hit 的分支 → 生成对应输入 → 补 test.

Agent 循环:
1. `swift test --enable-code-coverage`
2. `xcrun llvm-cov report ...` 找 uncovered branches
3. 对每 uncovered branch, 生成对应输入 (基于代码路径反推)
4. 补 test case, 再跑
5. Coverage ≥95% 才算完成该 file

### 9. 静态分析 + 自定义 linter (P2)

Swift 自定义 lint 规则捕捉常见移植陷阱:
- `String.count` 用于 grapheme 语义 (应用 `count` 明确注释是 Character count)
- `unicodeScalars.count` 用作 length cap (会截断 emoji)
- `FileManager.moveItem` 无 remove/replace guard (会 throw)
- 异步 AX API 主线程 assertion 缺失
- `try?` 吞了 error 没 log
- NSException 未包裹

`.swiftlint.yml` + `openclicky-rules/*.swift` 定义规则. CI 强制. PR 里违规必修.

### 10. 版本 pin + 上游 drift check (P1)

- OCCU / open-connector / OpenCLI / OpenDia / Everywhere: SPM `.exact("<hash>")` 或 submodule commit 锁死
- CI 定期 (weekly) 跑 `git ls-remote` + `sha` 对比, 有上游新 commit 就自动 open issue "上游更新, 需评估"
- **不** auto-update. 手动升级时重跑全套 Golden diff.

### 11. Attacker agent 演练 (P1)

主 agent 完成 port → 派另一 agent 扮 "attacker":
- 只看代码 (不看 impl-notes), 独立编 fuzz 输入
- 专找 edge case: overflow / underflow / empty / all-special-char / concurrency / re-entrancy
- 发现 diverge 反馈主 agent 修
- Attacker 完成前 code 不 merge

### 12. Runtime canonicalization (P2)

同一 test 输入喂 Everywhere 和 openclicky 时, 预处理消除环境差异:
- 系统时钟 → mock 到固定值
- User home → 换成 `/tmp/test-home`
- Locale → 强制 `en_US.UTF-8`
- Timezone → UTC

避免 flakiness. 见 `scripts/canonicalize.sh`.

### 13. 关键路径 assertion (P0)

Runtime `assert()` 保关键不变量, 生产环境保留 (Debug 开, Release 可关):

```swift
assert(sanitised.count <= maxChars, "sanitise cap violated")
assert(!query.contains { denylist.contains($0.name) }, "redaction leaked")
assert(payload.count <= 64 * 1024, "stash too large")
assert(FileManager.default.fileExists(atPath: tmp.path), "atomic write pre-condition")
```

任何 assert 触发 = 定位精确 bug.

### 14. Everywhere upstream 回馈 (P2)

移植中发现 Everywhere 里的 bug (edge case / 拼写错 / 逻辑漏洞) → 提 issue / PR 回 Everywhere.
- 上游 accept = 我们理解正确
- Upstream 修了, 未来 sync 更省事
- 双向验证

`.impl-notes/upstream-feedback.md` 记 pending issue.

### 15. Runtime compat daemon (P3, 可选)

Debug build 或用户显式启用: openclicky 每次 tool call **同时**调 Everywhere 对应 tool (若用户装了 Everywhere), diff response, 差异记 log.

- 只在 debug build 或 "compat check" toggle 开
- 用户可 opt-in 提交 diff report (匿名) 给 openclicky 团队
- 覆盖 fixture 覆盖不到的真实使用场景

---

## QA 措施执行优先级

**P0 (must, Phase 1 前)**:
- #4 分层小步 PR (每 file 独立)
- #5 property-based random fuzz (纯逻辑函数)
- #6 byte-level Golden diff
- #13 关键路径 assert

**P1 (Phase 1 中)**:
- #7 反向测试用 Everywhere hook
- #8 coverage-guided fuzz
- #10 上游 drift check CI
- #11 attacker agent 演练

**P2 (Phase 3+ 之后加, 或 Phase 后期)**:
- #9 自定义 linter
- #12 canonicalization
- #14 上游回馈

**P3 (可选)**:
- #15 runtime compat daemon

---

### 原则

0. **能不翻就不翻**. Everywhere 里的 AX / 输入模拟 / snapshot 渲染部分是通过 `libAxHelper.dylib` (Swift wrapper) 调 [`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use) 的 `OpenComputerUseKit`. openclicky 直接 SPM 依赖同一个包, 免翻 ~80KB C#. 只翻 OCCU 未覆盖项 (AppleScript readers / stash / hotkey / UX / URL redaction).

1. **不重构**. 保留 Everywhere 的类边界 / 方法签名 / 命名 (`FooBar` C# → `FooBar` Swift). Diff 一目了然.
2. **保留原注释**. C# 的 `///` 全部翻成 Swift `///`, 包括 warning / TODO / hack 说明. 这些是 Everywhere 作者填坑的记录.
3. **每 file 顶部 comment**: `// Ported from Everywhere: <relative path>@<git-rev>` — 未来 Everywhere 更新时能 sync.
4. **一个 PR 一个 file**, 一段一段抄, 每段可独立 review. 一 PR 500+ 行的直接拒.
5. **对齐单元**: C# class → Swift class (不改成 struct 不改成 actor 除非必要). C# `IFoo` interface → Swift `protocol Foo`. C# `sealed record` → Swift `struct: Equatable, Hashable, Codable`.

### 工具辅助

- **AI-assisted 首翻**: 用 Claude 打第一遍, 但**必须**逐行 diff review, 不能盲信
- **Golden diff 对比**: 每个 capture 项都要跑对比 (见下)
- **XCTest 覆盖每个纯逻辑函数**: sanitisation / redaction / grapheme truncate / JSON serialize — 这些语义偏差最难肉眼发现

### 高风险区域 (bug 密度 topN)

| 区域 | 为什么高危 |
|---|---|
| **AX API 调用** | C# 通过 `AXUIElement.cs` 63KB 手写 P/Invoke, Swift 用 `ApplicationServices` framework — API 一对多映射, 参数打包不同 |
| **CFType 转 Swift** | C# `Marshal.PtrToStructure`, Swift `as!` — 类型不匹配直接 crash, 必须 `CFGetTypeID` check |
| **NSException** | AX API 会抛 Objective-C 异常, Swift `try` 不抓, 必须包裹 `@objc` shim 或 `try?` + defensive |
| **主线程要求** | AX / AppleScript / NSPasteboard 全主线程强制, Swift 里 `@MainActor` 或 `DispatchQueue.main.sync` |
| **Sanitisation 语义** | `StringInfo.GetTextElementEnumerator` vs Swift `String.enumerateSubstrings(options: .byComposedCharacterSequences)` — emoji ZWJ / 组合字符 truncate 边界易错 |
| **JSON 空字段** | Everywhere `WhenWritingNull` 丢空字段, Swift `Codable` 默认序列化 `nil` 为 `null`, 必须 `encodeIfPresent` 每字段 |
| **Timing / lock** | `SemaphoreSlim(1,1) WaitAsync(0)` 立即返回 false 语义, Swift `NSLock.try()` 语义微差 (Everywhere 用 `.WaitAsync(0)` 明确不排队, Swift 要用 `NSLock.try()` 不是 `.lock()`) |

### 每 file 交付 checklist

- [ ] `// Ported from Everywhere: <path>@<rev>` header
- [ ] 逐段翻, 保留原注释 (可翻成中文/双语)
- [ ] XCTest 每个 public / internal method (至少 happy path + 1 corner)
- [ ] Fixture 脚本 (`scripts/verify-context/<file>.sh`) — 若涉及外部环境 (Finder/Safari/...)
- [ ] Golden diff 与 Everywhere 相同环境输出一致 (见 🅒)
- [ ] Corner case 表 (emoji / RTL / 空 / 超长 / 中文 / password field)

### PR review checklist (reviewer 侧)

- [ ] 每段 diff 能对到 Everywhere 源里对应位置
- [ ] 注释保留了 Everywhere 里的 warning
- [ ] 没有把 mutable 改成 immutable / class 改成 struct / async 改 sync (除非有明确理由)
- [ ] JSON 序列化字段名与 Everywhere 完全一致
- [ ] Sanitisation 边界 (byte cap / grapheme cap / control char neutralise) 完全一致

---

## 3 层保证

### 🅐 逐块 side-by-side 翻译, 不重写

- 打开 C# 源 (`~/Dev/Everywhere/src/Everywhere.Mac/...`) 
- 逐段抄, 保留**所有注释** (含 warning / TODO / hack rationale)
- 变语法, 不变逻辑
- 每 file 顶部标 `// Ported from Everywhere: <file path in Everywhere>`

### 🅑 每模块 fixture + XCTest

- **fixture 脚本**: `scripts/verify-context/<capture>.sh` — osascript 前置状态 + Swift CLI 采集 + assert 输出
- **XCTest**: 纯逻辑部分单测 (URL redaction, sanitisation, JSON serialize, grapheme truncate)
- **corner case 表**: 空/None/超长/中文/emoji/RTL/password/Electron/SwiftUI

### 🅒 Golden diff vs Everywhere (**开发期**, 不是运行期依赖)

**目的**: 验证翻译正确性. 完成后 openclicky 不再需要 Everywhere 存在.

- 开发机同时装 Everywhere + openclicky
- 同一环境 fixture (Safari 打开某 URL / Finder 选中某文件 / ...)
- 同时触发两边 hotkey
- Diff `~/Library/Application Support/Everywhere/context-stash.json` vs `~/Library/Application Support/OpenClicky/context-stash.json`
- 差异 = bug (忽略 pid / timestamp / 品牌前缀本身)

**运行期**: openclicky 独立, 不装 Everywhere 也能跑.

---

## C# → Swift 翻译陷阱

### 1. 参数默认值

C# 常见 `= null` 默认, Swift 需要 `= nil` 或 `Optional`. 检查每个 API 边界.

### 2. 异常语义

- C# `try { } catch (Exception ex) { }` 抓一切
- Swift `do { try ... } catch { }` **不抓 NSException**
- **AX API 会抛 NSException** — Everywhere 特别用 AxHelper Swift shim 隔离. 我们 Swift 原生调 AX, 但**不能让 NSException 冲出 Swift** (会 crash). 用 `try?` + defensive check.

### 3. Unicode

- C# `StringInfo.LengthInTextElements` = 用户可见字符数
- Swift `String.count` = 也是 grapheme cluster 数
- 但 truncation 时: C# `SubstringByTextElements(n)` vs Swift `prefix(n)` — 都 grapheme-safe, **验证 emoji ZWJ sequence** 一致

### 4. Bool 平台常量

`AXManualAccessibility` 必须 `kCFBooleanTrue` singleton, 不是 NSNumber. Swift:
```swift
let cfTrue = kCFBooleanTrue!  // 是的必须 !
AXUIElementSetAttributeValue(elem, "AXManualAccessibility" as CFString, cfTrue)
```
用 NSNumber 是 silently 拒收.

### 5. AppleScript 转义

C# 用 escape sequence + backslash. Swift 里字符串插值时要 escape:
```swift
let script = """
tell application "Finder"
    return POSIX path of (selection as alias)
end tell
"""
```
用户输入拼进去时**必须** escape (防 injection).

### 6. JSON key naming

- 我们的 stash 文件用 snake_case (与 Everywhere 兼容)
- Swift `Codable` 默认 camelCase → 必须显式 `CodingKeys`
- 或 encoder 设 `.convertToSnakeCase`

### 7. 异步模型

- C# `Task.Run(...)` + `await`
- Swift `Task { ... }` + `await`
- 平台 API 死锁: **AX 必须主线程**. Swift 里用 `@MainActor` 标注 or `DispatchQueue.main.sync`.

### 8. CFType marshalling

C# 有 `Marshal.PtrToStructure`. Swift 里:
```swift
let url = someCFObj as! URL   // CFURLRef → URL, but 只在 CFGetTypeID(x) == CFURLGetTypeID() 时成立
```
类型不检查会 crash. 每个 CFType 转 Swift 前 check `CFGetTypeID`.

### 9. Nil vs empty

- C# `null` != `""` — 明确区分
- Swift `nil` != `""` — 一样
- 但 JSON encode 时 Everywhere 用 `WhenWritingNull` 丢弃空字段. Swift 用 `encodeIfPresent` + `Optional`.

### 10. Locks / concurrency

- C# `SemaphoreSlim(1,1)` = mutex
- Swift `NSLock` 或 `actor` isolation
- 用 `actor` 更安全 (compiler check), 但 need Swift 5.5+

---

## Golden diff 具体流程

```bash
# 1. 装 Everywhere (from official install or dev build)
# 2. Build openclicky with our Layer 3 stash writer

# 3. 环境 fixture
osascript -e 'tell application "Safari" to open location "https://example.com/article"'
osascript -e 'tell application "Finder" to activate'
osascript -e 'tell application "Finder" to reveal (POSIX file "/Users/wowdd1/Dev/openclicky/README.md")'
sleep 1

# 4. 触发 Everywhere hotkey (模拟)
osascript -e 'tell application "System Events" to keystroke space using {command down, shift down}'
sleep 2

# 5. 拿 Everywhere 写的 stash
cp "~/Library/Application Support/Everywhere/context-stash.json" /tmp/everywhere.json

# 6. 触发 openclicky hotkey
osascript -e 'tell application "System Events" to keystroke "s" using {control down, shift down}'
sleep 2

# 7. 拿 openclicky 写的 stash
cp "~/Library/Application Support/OpenClicky/context-stash.json" /tmp/openclicky.json

# 8. Diff
python3 scripts/compare-stash.py /tmp/everywhere.json /tmp/openclicky.json
```

`compare-stash.py`: **开发期脚本**. 忽略:
- 时间戳 / pid / session_id
- 品牌前缀差异 (`[everywhere-*]` vs `[openclicky-*]`, `mcp__everywhere__*` vs `mcp__openclicky__*`)
- Header 里 `everywhere-hint` / `openclicky-hint` 文本差异

Diff `schema_version` / `app` / `url` / `selection` / `picked_links` / `annotations` / sanitisation 结构字段. 结构差异 = bug.

**只用于开发阶段验证**. Release 后不需要 Everywhere.

---

## 每 capture 项交付清单

给每个 Layer 0 项目, 完成后必须:

- [ ] Swift 源 (从 C# 逐段翻译)
- [ ] XCTest unit test 覆盖纯逻辑
- [ ] Fixture 脚本 setup + assert
- [ ] Golden diff pass (与 Everywhere 同 environment 输出一致)
- [ ] Corner case 表格 fixtures 全过
- [ ] Log event 加到 `HeyClickyLog` (`context.capture.X`, `context.capture.X_failed`)

---

## Risk 分级

**Low risk** (纯 fs / API 直调):
- FrontmostApp, RunningApps, IdleTime, Clipboard text, ScreenList

**Medium risk** (AppleScript / TCC):
- FinderSelection, BrowserURL, BrowserTabsList — 需要 TCC 权限, 用户第一次触发会弹窗

**High risk** (侵入性):
- AXManualAccessibility flip — 全局副作用, 影响其他 app AX 树
- Cmd-C fallback — 干扰用户剪贴板, 必须先备份再恢复
- CGEventTap — 与现有 openclicky voice PTT 共存, 事件顺序敏感

**测试重点**: High risk 项**必须**在真实环境跑 fixture, 不只单测.

---

## Fallback / graceful degradation

- AX API 返回 error → 记 log, 返回 nil, 不 crash
- AppleScript 无权限 → 返回 `{"status":"permission_denied"}`, dialog model 可看到
- 高级模型 forget [ROUTE] → 视为 chat (无害)
- Layer 0 采集超时 (>500ms) → 跳过, 用现有部分数据

**永远不 crash 用户 session**.
