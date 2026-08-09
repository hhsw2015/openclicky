# Layer 3 — Context Stash + UserPromptSubmit Hook

**目的**: 兼容 Claude Code / cmux 生态. 用户按 openclicky hotkey → 采集 → 原子写 stash 文件 → 外部 Claude Code 通过 hook 消费 → 塞进 prompt.

**对标**: Everywhere `ContextStashWriter.cs` + `tools/everywhere-context-hook`.

---

## Stash 文件路径

**目标**: 完全替代 Everywhere, **不依赖** Everywhere 的路径 / 二进制 / 品牌.

**openclicky 路径 (only)**: `~/Library/Application Support/OpenClicky/context-stash.json`

**Everywhere 兼容**: 不做. 用户装 openclicky = 卸 Everywhere. 用户改一次 `~/.claude/settings.json` 指向 `openclicky-context-hook`, 之后完全脱离 Everywhere.

参考实现: `Everywhere/src/Everywhere.Mcp/Snapshot/StashPaths.cs`. Swift 端翻译 `StashPaths.contextStash()` → 单一分支 (macOS-only, openclicky 本来就 macOS-only), 硬编码常量 `FileName = "context-stash.json"`.

---

## Payload 格式 (openclicky-ctx envelope)

**结构照抄 Everywhere `ContextStashWriter.FormatForHook`, 品牌全部改成 `openclicky-*`.** openclicky-context-hook 直接按 `openclicky-*` 前缀 parse.

按顺序输出以下行 (缺项跳过):

```
[openclicky-ctx] app=<key> title="<80g>" url=<256g> selection="<200g>" pin_pending=true whiteboard_pending=true regions=<n> picked_links=<n> annotations=<n>
[openclicky-ctx-link] #<i> url=<512g> title="<120g>"
[openclicky-ctx-annotation] #<i> source=<32g> anchor="<200g>" ref=<96g> body="<800g>"
[openclicky-hint] ...   (whiteboard / pin+state / pin-only / state-only / generic 五选一)
[openclicky-discover] openclicky-style local app self-describes at <discovery_url>. Fast path: GET <state_url>?consume=1 — ...
[openclicky-ctx-json] {"schema_version":1,"captured_at_utc":"...","app":"...",...}
```

`80g / 200g / 800g` = grapheme cluster 数. Sanitisation: 控制字符 → 空格; `[`→`(`, `]`→`)`, `"`→`'`.

**MCP tool 名前缀**: `mcp__openclicky__read_whiteboard` 等 (代替 Everywhere 的 `mcp__everywhere__*`), 与 openclicky sensor endpoint 一致.

JSON schema (`ContextSnapshotPayload`, `JsonIgnoreCondition.WhenWritingNull`):

```json
{
  "schema_version": 1,
  "captured_at_utc": "2026-07-22T10:00:00.000+00:00",
  "app": "com.apple.Safari",
  "process_id": 1234,
  "window_title": "...",
  "url": "https://...",
  "selected_text": "...",
  "selected_app": "com.apple.Safari",
  "pin_pending": true,
  "whiteboard_pending": true,
  "whiteboard_region_count": 3,
  "picked_links": [{"url": "...", "title": "..."}],
  "annotations": [{"source": "pin|whiteboard|selected|linkrect", "body": "...", "anchor_label": "...", "anchor_ref": "...", "captured_at": "..."}]
}
```

**Sanitisation** (`SanitiseUserText` / `SanitiseTokenValue`):
- Header-line caps: `app`≤64, `title`≤80, `url`≤256, `selection`≤200, `link.url`≤512, `link.title`≤120, `annotation.source`≤32, `annotation.anchor`≤200, `annotation.ref`≤96, `annotation.body`≤800
- Grapheme-cluster truncate + trailing `…` (Everywhere 用 `StringInfo.GetTextElementEnumerator`, 按 Unicode extended grapheme boundary. **Swift 正确 API**: 直接迭代 `String.Character` (Swift `Character` 已经是 grapheme cluster) 或 `str.enumerateSubstrings(in: str.startIndex..<str.endIndex, options: .byComposedCharacterSequences) { ... }`. **禁用**: `str.unicodeScalars` (是 code point 不是 grapheme, emoji ZWJ / 组合字符会被切开))
- Strip control chars (`\0\n\r\t\v\f\b` + `Char.IsControl`) → 用户文本转空格, token 值直接跳过
- Envelope neutralise (仅 UserText): `[`→`(`, `]`→`)`, `"`→`'`
- `SanitiseTokenValue` **不做**换字符, 但**直接跳过** `[` / `]` / ` ` / `\t` / 控制字符 (源码 `ContextStashWriter.cs:836-847`). **注意**: 这会**破坏 IPv6 URL** (如 `http://[::1]/`); 这是 Everywhere 上游行为, 移植时**保留**, 不修. `SanitiseUserText` 与之不同, 控制字符 → 空格

**URL redaction** (`RedactCredentials`, 与 Everywhere 完全同):
- Scheme allowlist: `http` / `https` / `mailto`
- 移除 userinfo (`user:pass@`)
- Denylist query params (case-insensitive): `token`, `access_token`, `id_token`, `refresh_token`, `api_key`, `apikey`, `key`, `secret`, `client_secret`, `auth`, `authentication`, `password`, `pwd`, `sig`, `signature`, `session`, `sessionid`
- 返回 `AbsoluteUri` (保留原始 percent-encoding)

---

## 写入协议 (atomic)

```
1. `SemaphoreSlim(1,1).WaitAsync(0)` 单飞 (Everywhere `ContextStashWriter.cs:55` + `:135`; 非阻塞 try-acquire, held 就 drop). Swift 翻译: `NSLock.try()` 非阻塞获取; **禁用** `.lock()` (会阻塞排队, 与 Everywhere 语义不同). 快速二次 hotkey → 丢, 不排队.
2. write to `<path>.tmp`
3. chmod 0600
4. rename(2) to `<path>` (POSIX atomic)
5. Sweep stale `.consumed-*.json` >10min
```

Swift:
```swift
let tmp = path.appendingPathExtension("tmp")
try data.write(to: tmp, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
// FileManager.moveItem throws when destination exists — Everywhere 的 C# File.Move(overwrite:true)
// 语义要靠 replaceItem 或 remove-then-move 复现:
if FileManager.default.fileExists(atPath: path.path) {
    _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
} else {
    try FileManager.default.moveItem(at: tmp, to: path)
}
// 或者用 POSIX rename(2) 直调 (真正原子, 与 Rust hook 语义一致):
//   rename(tmp.path, path.path)
```

**注意**: `FileManager.moveItem(at:to:)` 当 destination 已存在时**会 throw**. Everywhere Rust hook 用 `rename(2)` (POSIX 原子 overwrite). Swift `replaceItemAt` 更接近原语义, 但推荐用 `Darwin.rename(_:_:)` 直调保证与 Everywhere 字节一致.

---

## Hook 二进制

**名字**: `openclicky-context-hook` (openclicky 自建, 不依赖 Everywhere)

**语言选择**:
- **Swift CLI** (推荐): openclicky 已用 Swift, 无新工具链. Cold-start ~10-30ms 对 UserPromptSubmit 完全够用
- **Rust** (次选): 若严苛 latency 要求 (~3ms), 直接照 Everywhere `tools/everywhere-context-hook/src/main.rs` 翻译 (~230 行), 但需引入 Rust 工具链

**推荐 Swift**. 翻译时最大的坑:
- Everywhere Rust `rename → open → read → unlink` 是 syscall 级原子. Swift `FileManager.moveItem` **不覆盖**已存在文件 (会 throw); 用 `Darwin.rename(_:_:)` 直调保 POSIX 原子 overwrite 与 Everywhere 语义完全一致
- `mtime > 5min` 判断: Rust `std::fs::metadata().modified()`, Swift `URLResourceValues.contentModificationDate`
- 严格 stderr 输出 (Claude Code 只读 stdout JSON)

**Bundle 路径**: `/Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook`

**源码参考**: `Everywhere/tools/everywhere-context-hook/src/main.rs` — 直接照抄 struct, 改 stash 文件名和前缀常量 (`everywhere-ctx` → `openclicky-ctx`).

**协议 (Claude Code UserPromptSubmit, 照 Everywhere Rust hook 协议实现)**:
1. Claude Code 每次 Enter 调 hook
2. Hook: `rename(context-stash.json → context-stash.consumed-<pid>-<nanos>.json)` (POSIX atomic claim)
3. Read + `unlink` 该 sibling
4. `mtime > 5min` → 不读直接删 (stale)
5. 拒绝 (照 Everywhere Rust hook `is_valid_payload`, `main.rs:142-148`): empty / `>64KB` / 缺 `[openclicky-ctx] ` 前缀 (注意末尾空格). **不**验 schema_version — Rust hook 没这个检查
6. 输出到 stdout:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "<full stash body>"
  },
  "systemMessage": "app=... title=... +selection"
}
```

---

## Claude Code / cmux 配置

用户添加到 `~/.claude/settings.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "command": "/Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook" }
    ]
  }
}
```

cmux 内嵌 Claude Code, 继承同一 hook 配置.

**首启引导**: openclicky 装完后, Settings "Context Awareness" tab 显示配置片段, 一键复制到剪贴板 + "打开 `~/.claude/settings.json`" 按钮.

---

## KnownApps discovery (xlb-style 本地 App fast-path)

**目的**: 支持 xlinkBook (`http://localhost:5000`) 及任何自描述的本地 App. 用户在这类 App 里按 hotkey → openclicky 识别 → stash 里附 `[openclicky-discover]` hint, 下游 agent 一次 GET `agent-state?consume=1` 拿到 App 内部 view/interaction markdown, 免去 scrape HTML.

参考 `Everywhere/src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs`:
- `ResolveDiscoveryUrl(windowTitle)` — Settings.KnownApps 里 `TitlePattern` 正则匹配 (100ms timeout 防 ReDoS)
- `ToStatePath(discoveryUrl)` 转 fast-path: `/agent-skills` → `/agent-state`, `/xlb-perception` → `/agent-state`, 其他 leave as-is

Openclicky Settings 里加:
```
KnownApps:
  - TitlePattern: "xlinkBook.*"
    DiscoverUrl:  "http://localhost:5000/agent-skills"
  - (用户可自定义添加更多)
```

Stash payload 里若匹配, emit:
```
[openclicky-discover] xlb-style local app self-describes at http://localhost:5000/agent-skills. Fast path: GET http://localhost:5000/agent-state?consume=1 — recent view + interactions markdown. For deeper exploration (topic graph, tag groups, curated commands), append &with_meta=1 OR fetch discovery URL and call a skill — only if user's question actually needs it.
```

无匹配则通用 hint `[openclicky-hint] If user's question needs a pointer, call a relevant OpenClicky MCP tool — don't guess.`

## Hotkey 触发 (与 Everywhere 完全对齐)

参考 `Everywhere/src/Everywhere.Core/Configuration/Settings/ShortcutSettings.cs` — Everywhere 除 `ChatWindow = Ctrl+Shift+E` 外, 其他 hotkey **全部默认未绑** (`new CompositeKeyboardShortcut()`). openclicky 保持相同默认.

Everywhere 定义的 shortcut (openclicky 需 1:1 移植, 名字/语义/默认值都不变):

| Shortcut | 默认 | 触发 |
|---|---|---|
| `ChatWindow` | `Ctrl+Shift+E` | 打开 chat 窗口 (openclicky 已有等价物) |
| `PickVisualElement` | 未绑 | 打开 chat + 挂 pick 模式 |
| `TakeScreenshot` | 未绑 | 全屏截图 → chat |
| `AgentPickElement` | 未绑 | pin element → 5min TTL (不开 chat) |
| `SnapshotContext` | 未绑 | 采上下文写 stash + 激活 agent app |
| `ClearContextStash` | 未绑 | 清 stash + pin + whiteboard |
| `Whiteboard` | 未绑 | press-hold 画手势 → OCR |
| `LinkRect` | 未绑 | drag rect harvest hyperlinks |

**Repeat suppression**: 1500ms 窗口 (`RepeatSuppressionMs` in `Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs:122`)
**Modifier release delay**: 180ms (macOS 释放 modifier 后再采)

**开关粒度**: openclicky Settings 里每个 hotkey 独立 enable + rebind, 与 Everywhere 一致.

---

## Launch phrase (可选)

采集后可选**激活目标 app + 键盘输入短语**触发 hook.

- Target app 可配: OpenClicky 自己 / cmux / Claude Code / 自定义 bundle
- Launch phrase 可配: **默认空** (`McpServerSettings.LaunchPhrase = string.Empty`, PlaceholderText 提示 "take a look" 供用户参考). 空字符串 → 不 fire launch phrase. 用户主动填才生效
- 双 tick frontmost 稳定 check + pre-Return 稳定 recheck (仿 Everywhere)
- `_phraseInFlight` 单飞 flag 免 "take looktake look" 重复

Openclicky 自己**通常不需要 launch phrase** (语音已经触发), 但**对外**注入 Claude Code 时用得着.

---

## Take-semantics

**只一个消费者拿到**. Hook `rename → read → unlink` guarantee. 快速 Enter 打两次 hook 只有一次拿到内容.

**用户显式清空** hotkey: `ClearContextStash` (Everywhere-parity) — 一键删 stash.

---

## Everywhere 迁移路径 (完全脱离依赖)

**目标**: openclicky 独立. 用户装 openclicky 后**不需要**装 Everywhere.

**用户从 Everywhere 切换步骤**:
1. 卸载 Everywhere
2. 装 openclicky (bundle 含 `openclicky-context-hook`)
3. 改 `~/.claude/settings.json` hook 命令: `everywhere-context-hook` → `openclicky-context-hook`
4. 在 openclicky Settings 里重新绑定原来在 Everywhere 里习惯的 hotkey 组合 (Everywhere 也默认未绑, 用户 muscle memory 是自己配的)

**用户全新装 openclicky**:
1. 装 openclicky
2. 加 hook 到 `~/.claude/settings.json` (首启引导)
3. 按提示配 hotkey

**不做双写 / 不共存**. openclicky 是 Everywhere 的替代品, 不是补充.

---

## 测试

- **格式**: Everywhere Rust hook 直接读 openclicky 写的 stash, 应 parse 成功
- **原子性**: 并发写 100 次, 消费者 rename-claim, 应各拿到独立完整 payload
- **stale sweep**: 手动写 6min 老 `.consumed-*.json`, 触发一次 write, 应被删
- **URL redaction**: `https://user:pass@example.com/?token=SECRET&q=hello` → `https://example.com/?q=hello`
- **Sanitisation**: 含 `]"[` 的 title/selection, 输出应 neutralized
