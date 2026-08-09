# Layer 4 — UX (Whiteboard / LinkRect / PickStash) + Settings

**目的**: 补齐 Everywhere 的三大交互式采集 UX. 用户按 hotkey 后可以画圈/框选链接/pin 元素.

---

## A. Whiteboard 手势

Hotkey → 全屏 overlay 出现 → 用户画笔勾选屏幕上东西 → OCR + 手势识别 → 存 stash → dialog model 用.

### 手势类型 (Everywhere-parity)

| 手势 | 语义 |
|---|---|
| 圈 (circle) | 强调 / 关注 |
| 叉 (X) | 排除 / 不要 |
| 箭头 (arrow) | 指向 / point to |
| 下划线 (underline) | 聚焦这行文字 |

### 实现

- Overlay window: `WhiteboardOverlayWindow.swift` (透明, click-through 除笔画外)
- 笔画捕捉: NSEvent mouseDown/Dragged/mouseUp
- 手势分类: 简单几何 heuristic (Everywhere `SemanticEnricher.cs` 提示: 圆度 / bounding box aspect / 起点终点距离)
- 区域 OCR: 每笔画包围矩形 → Vision OCR → 文本 + bbox
- Stash: **内存 only**, `DefaultTtl = TimeSpan.FromMinutes(5)` (照 Everywhere `WhiteboardStash.cs:14`, 无 file I/O). `SnapshotContext` hotkey 触发时才把 pending regions 序列化到 `context-stash.json` 里 `whiteboard_pending / whiteboard_region_count` 字段
- **易漏细节**: `WhiteboardStash` 有 `_imageBytesById` side-table 存 PNG bytes 同 TTL, 服务 `read_whiteboard_image(id)` 二次查询. `Take()` 消费 region 后 PNG bytes 仍存活到 TTL 过期. 参考 `WhiteboardStash.cs:22-24, 56-64, 151-164`. Swift port 必须复制这个双 map 语义 (独立于 context-stash)

### 冲突处理

- 与 openclicky 现有 `CircleSelectSession` 圈选功能**共存**:
  - CircleSelect: Alt+drag 现有截屏
  - Whiteboard: 独立 hotkey (可配置, 用户自选; 见 Settings 里 "推荐组合"), overlay 更浓, 支持多笔画
- 视觉层次: Whiteboard overlay 优先, 若正 CircleSelect 则忽略 Whiteboard hotkey

---

## B. LinkRect harvest

Hotkey + drag → 拉一个矩形 → 采集所有相交的**hyperlink 元素** (URL + label) → 存 stash.

### 实现

- Overlay: `LinkRectOverlayWindow.swift` (类似 Whiteboard, 但只画一个矩形)
- 采集: 遍历前屏所有 on-screen pid → AX walk (50k 节点预算) → 找 role=`AXLink` → 与用户 rect 交 (majority-overlap) → 收 URL + AXTitle/AXDescription
- Dedup by URL, cap 200 links × 2048 char URL × 200 char title (仿 Everywhere)
- URL redaction 复用 Layer 3 的 `RedactCredentials`
- Stash: 加入到 `context-stash.json` 的 `picked_links[]` 字段

### 用例

浏览器里看长列表 → 用户框选 5 个新闻链接 → hotkey 触发 → 全部 URL/title 存 stash → Claude Code 一次拿到

---

## B.5 Annotation ➕ badge + delta-follow (Everywhere-parity)

wowdd1 2026-06-27 在 Everywhere 里补的 UX. Whiteboard / LinkRect / Pin 三通道**共用一套 UI 覆盖**:

- **红色 badge** 悬浮在被 pin / whiteboard 圈中 / linkrect 命中的元素旁
- **➕ 按钮**: 点开展开成 textarea, 用户可写 free-text annotation body → 落 `AnnotationStash`
- **持久 ✓ badge**: 已提交注释的元素永久标 ✓
- **Multi-pin accumulation**: 多个元素同时 pin, badge 都保留
- **Delta-follow**: 用户滚屏 / 元素移动时, badge 跟着元素. 焦点 root 变为 null 时优雅处理
- **Clear hotkey**: `ClearContextStash` 一键清 stash + 抹去所有 overlay

**为什么关键**: 让用户对多元素积累 context, 一次发给 agent. 没有 delta-follow, 用户看到的 badge 会飘走, 看不出对应关系.

Everywhere commit chain (~7 个 feat):
- `feat(annotation): backend MVP — AnnotationStash + payload + 3 MCP tools`
- `feat(annotation): UI spike — red badge floats next to pinned element`
- `feat(annotation): ➕ badge expands to textarea, commits to AnnotationStash`
- `feat(annotation): persistent ✓ badges + multi-pin accumulation`
- `feat(annotation): follow element on scroll; clear hotkey wipes overlays`
- `feat(annotation): extend ➕ to whiteboard + linkrect channels`
- `feat(annotation): delta-follow model + handle focusedRoot=null`

**openclicky 移植**: SwiftUI overlay + AXObserver 监听 element 移动 (走 OCCU 的 AX 抽象).

---

## C. PickStash (Pin Element)

Hotkey → 用户点击一个 UI 元素 → 该元素 (AX 快照) 被 pin, 5min TTL → 后续用户再对话时, dialog model 自动看到 pinned element.

### 实现

- Hotkey → openclicky 显示 "Pin element..." 覆盖层 (半透明高亮跟随鼠标)
- 用户点击 → `AXUIElementCopyElementAtPosition` 获取元素 → 序列化 (role, name, value, bounds, ancestors) → 存 pin store
- 5min TTL, 到期或用户再 pin 或用户 clear → 移除
- `PickStash.HasFreshPin` → dialog model prompt 里加 `pin_pending: true` 提示
- MCP tool `read_pick` → 消费 (返回后 clear)

### 用例

用户看 Figma 里一个组件 → hotkey → 点击组件 → 说 "把这改成红色" → openclicky 已知你 pin 了哪个 (bounds + label), dialog model 有 context

---

## D. Auto text-selection observer (可选, 默认 off)

被动监听 `CGEventListener` mouse-up + I-beam 光标 sniff + AX selected_text 变化 → 自动 push `TextSelectionAttachment` 到 chat 面板.

### 实现

- ref-counted `IObservable<TextSelectionData>` (仿 Everywhere)
- Subscribers ≥1 才装 hook, ==0 就卸 (节能)
- **默认 off**, Settings 里可开
- 若开: mini chat 面板顶部自动出现"Selected: [preview...]" 卡片, 用户可 dismiss / attach

---

## E. Settings 面板 "Context Awareness"

新增 Settings tab. 集中管理:

### Hotkey 配置 (matched against real Everywhere config @ 2026-07-23)

**Update 2026-07-23**: openclicky is a drop-in replacement for the
user's Everywhere install, so first-launch defaults now byte-match the
values in `~/Library/Application Support/Everywhere/settings.json`.
Muscle memory carries over — hitting Shift+Space fires SnapshotContext
without any manual re-bind. A one-shot sentinel key
(`openclicky.contextAwareness.seededEverywhereDefaults`) guarantees the
seed only runs once; every subsequent launch respects the user's
overrides (including an explicit clear).

| Everywhere 字段 | openclicky 字段 | 默认 (first launch) |
|---|---|---|
| `SnapshotContext` (`Shift+Space`, `IsEnabled=true`) | `snapshotContext` | Shift+Space, enabled |
| `ClearContextStash` (`Alt+C`) | `clearContextStash` | Alt+C, enabled |
| `AgentPickElement` (`Alt+S`) | `agentPickElement` | Alt+S, enabled |
| `Whiteboard` (`Alt+D`) | `whiteboard` | Alt+D, enabled |
| `LinkRect` (`Alt+L`) | `linkRect` | Alt+L, enabled |

Master toggle `openclicky.contextAwareness.hotkeysEnabled` defaults to
**true** (the user runs Everywhere with hotkeys live). A
"Reset to Everywhere defaults" button in Settings re-applies every
value if the user has wandered off. See
`docs/ROADMAP/.impl-notes/phase7-defaults-2026-07-23.md`.

### Target 配置 (matched against real Everywhere config @ 2026-07-23)

Defaults now seeded from Everywhere's `McpServer` block:

- `agentAppId` = `"cmux"` (LaunchPhrase target)
- `launchPhrase` = `"take a look"`
- `autoCaptureContext` = `true` (fires on pin / whiteboard finish)
- `openDiaEnabled` = `true`
- `cursorOverlayEnabled` = `false`
- `knownApps` = `[{ titlePattern: "^xlinkBook",
                    discoverUrl: "http://localhost:5000/.well-known/agent-skills" }]`

```
Launch phrase target app:
  ( ) OpenClicky (this app)
  (•) cmux                        [seeded from Everywhere]
  ( ) Claude Code (com.anthropic.claude)
  ( ) Custom: [__________________________]

Launch phrase text: [take a look_______________]  [√] Enable   (seeded from Everywhere)
```

### Stash 文件

固定路径 `~/Library/Application Support/OpenClicky/context-stash.json`, 不可配 (设计上 openclicky 独立, 无 Everywhere 兼容开关).

### 行为

```
[ ] Auto text-selection observer (passive mouse-up detect)
[√] AXManualAccessibility flip for Electron apps (breaks through opaque trees)
[√] Cmd-C fallback for selection (~100ms, restores clipboard)
[√] Include screenshot in context snapshots
[ ] Include focused AX tree (large, ~5k tokens)
Cmd-C fallback timeout: [100] ms
```

### 隐私

```
URL redaction extra denylist (comma-separated):
  [customer_id, internal_ref]

Max stash payload size: [64] KB
Max selection text: [200] chars
Max title: [80] chars

[ ] Log all captured context to ~/Library/Application Support/OpenClicky/Logs/context.log
```

### Domain gating

```
Enable domains:
  [√] core          get_focused_context, screenshot, ...
  [√] browser       get_browser_tabs, ...
  [ ] terminal      get_terminal_output
  [ ] finder        get_finder_selection
  [ ] whiteboard    read_whiteboard
  [ ] doc_readers   doc_read_pdf, doc_read_docx, ...
  [ ] web           web_search, web_fetch_url
```

---

## F. Everywhere 独有的**先不做**

- OpenDia browser extension bridge (Chrome extension)
- Open-Connector SaaS provider runtime
- OpenCLI adapter runtime + generator
- Self-expanding adapter authoring
- Chat bus (`chat_send`, `chat_subscribe`)
- Capture / adapter authoring UX

这些是 Everywhere 独有的**生态构建**, 我们哲学不同 (openclicky 是 agent 平台, 不是 adapter marketplace). 后期若有需求再评估.

---

## 实施顺序 (Phase D)

1. **Settings 面板骨架** — 加 tab, 布局静态先
2. **PickStash** (最简单, 单点点击就完)
3. **Whiteboard** (多笔画 + OCR + 手势分类)
4. **LinkRect** (drag rect + 多 pid AX walk)
5. **Auto text-selection observer** (最后, 默认 off)

**每项独立**, 不影响任何现有功能. Settings tag 可显示 "beta" 直到验证稳定.
