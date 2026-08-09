# Layer 2 — MCP `/mcp/sensor` (对外 agent 消费)

**目的**: openclicky bridge 通过 SSE Streamable HTTP 暴露一组 MCP tools, codex agent 和外部 MCP client (Claude Code / cmux / Cursor) 都能用.

**位置**: 现有 `cursor-buddy/OpenClickyExternalControlBridge.swift` 已有 MCP 基础 (`/mcp/advisor`, `/mcp/orchestrate`, SSE + notifications/initialized 202).

**Transport (对齐 Everywhere)**: Everywhere 用 stdio (`everywhere --mcp`) + Streamable HTTP (`http://localhost:7878/mcp`, `EVERYWHERE_MCP_PORT` 可换, 冲突 fallback 7879..7888). openclicky 现只有 HTTP `:32123`. 后期可加 stdio mode (`openclicky --mcp`), 与外部 Claude Code 客户端配置更贴近 Everywhere 使用习惯:
```jsonc
{ "mcpServers": { "openclicky": { "command": "/Applications/OpenClicky.app/Contents/MacOS/OpenClicky", "args": ["--mcp"] } } }
```
默认 HTTP; stdio 仅当被显式 spawn 时启动 (照 Everywhere `Program.cs` mode dispatch).

**新增端点**: `/mcp/sensor`

**config.toml (openclicky 内部 codex)**:
```toml
[mcp_servers.sensor]
url = "http://127.0.0.1:32123/mcp/sensor"
[mcp_servers.sensor.http_headers]
x-openclicky-token = "..."
```

**config.toml (外部 Claude Code)**:
```json
{
  "mcpServers": {
    "openclicky-sensor": {
      "url": "http://127.0.0.1:32123/mcp/sensor",
      "headers": {"x-openclicky-token": "..."}
    }
  }
}
```

---

## 完整 tool 列表 (Everywhere-parity)

Everywhere 实际 tool 名 (来自 `Everywhere.Mcp/Tools/`, **96 unique `McpServerTool` name** 实测, 品牌 rewrite 前抄这个清单; 权威源: `grep -rh 'Name = "' Everywhere.Mcp/`):

```
activate_domain, adapter_delete_local, adapter_drift_check, adapter_lint,
adapter_list_local, adapter_regenerate, adapter_save, adapter_scaffold,
adapter_verify, add_annotation, batch, browser_captcha_present, call_tool,
capture_current, capture_export, capture_start, capture_stop,
chat_create, chat_delete, chat_list, chat_read, chat_send, chat_subscribe,
clear_annotations, click, clipboard_copy, clipboard_paste, clipboard_read, clipboard_write,
connector_connect, connector_describe, connector_disconnect,
connector_list_connections, connector_list, connector_run,
doc_read_docx, doc_read_epub, doc_read_html, doc_read_pdf, doc_read_pptx,
doc_read_txt, doc_read_xlsx, drag, expand_element,
get_app_context, get_app_state, get_browser_tabs, get_browser_url,
get_clipboard, get_finder_selection, get_focused_context, get_idle_time,
get_selected_text, get_terminal_output, list_apps, list_domains, list_more_tools,
memory_append_note, memory_freshness, memory_read_endpoint, memory_read,
memory_snapshot, memory_write_endpoint, memory_write_field_map, memory_write_verify_fixture,
opencli_describe, opencli_list, opencli_run, opendia_smoke_check,
page_extract_by_rule, page_save_extraction_rule, perform_secondary_action,
pick_element, press_key, read_annotations, read_pick,
read_whiteboard_image, read_whiteboard, screenshot, scroll,
search_adapters, search_tools, set_value,
strategy_note_get, strategy_note_write, type_text,
web_crypto_scan, web_fetch_url, web_js_fetch_same_origin, web_js_search,
web_search, web_signature_scheme, web_sourcemap_list_candidates,
web_sourcemap_resolve, web_techstack, web_verdict_score
```

**注意**:
- 服务器 `ServerInfo.Name = "everywhere"` (`EverywhereMcpHttpHost.cs`, `EverywhereMcpServer.cs` 里的 metadata, **不是** tool). `tools/list` 只暴露 **96 个真实 tool**, `everywhere` 不在其中
- **没有** `gate_*` 命名空间 (`GateTools.cs` 内容其实是 `strategy_note_*` + `adapter_lint`)

**openclicky 首批移植 (核心 sensor + UX 消费)**:

### A. 焦点/当前窗口 context (读)

| Tool | Params | Returns | 参考 Everywhere |
|---|---|---|---|
| `get_focused_context` | `budget?:int, include_screenshot?:bool, include_tree_json?:bool` | app, window_title, window_bounds, tree_text, focused_summary, selected_text, omitted_children, tree_json?, screenshot_png_b64? | `GetFocusedContextTool.cs` |
| `get_app_context` | `app_hint:string, show_full_text?, raise_if_needed?, include_screenshot?, include_tree_json?` | 匹配 app 的完整 `AppStateResult` | `GetAppContextTool.cs` |
| `get_app_state` | `app:string, show_full_text?` | 渲染 a11y 树带 `[<idx>]` 前缀 | `GetAppStateTool.cs` (via **OCCU** `LibAxHelper.dylib` → Swift `OpenComputerUseKit`) |
| `list_apps` | — | 运行中 app 列表 | `ListAppsTool.cs` (via **OCCU** dylib) |
| `expand_element` | `element_index:string, budget?:int, include_tree_json?:bool` | 该 subtree | `ExpandElementTool.cs` |
| `pick_element` | `mode?: "element"\|"window"\|"screen"` | 用户点击后选中的元素 | `PickElementTool.cs` |

### B. 选择 / 剪贴板 / idle

| Tool | Params | Returns | 参考 |
|---|---|---|---|
| `get_selected_text` | — | selected, text, app, source | `GetSelectedTextTool.cs` |
| `get_clipboard` | — | has_text, text | `GetClipboardTool.cs` |
| `clipboard_read` | — | 同上 (long-tail alias) | `ClipboardTools.cs` (合并 read/write/paste/copy) |
| `clipboard_paste` | — | 同上 (alias) | `ClipboardTools.cs` |
| `clipboard_write` | `text:string` | ok, bytes | `ClipboardTools.cs` |
| `clipboard_copy` | `text:string` | 同上 (alias) | `ClipboardTools.cs` |
| `get_idle_time` | — | idle_seconds | `GetIdleTimeTool.cs` |

### C. Terminal / Browser / Finder

| Tool | Params | Returns |
|---|---|---|
| `get_terminal_output` | `lines_back?:int (1-10000)` | is_terminal, lines_returned, text |
| `get_browser_url` | `app_hint?:string` | app, url |
| `get_browser_tabs` | `app_hint?:string` | app, status, tabs:[{title,url,active}] |
| `get_finder_selection` | — | status, selected, count, current_folder, files:[{path,name,is_dir,mime,kind_hint}] |

### D. 屏幕 / OCR

| Tool | Params | Returns |
|---|---|---|
| `screenshot` | `element_index?, app_hint?, format?, quality?, max_width?, max_height?, raise_if_needed?` | screenshot_png_b64, format |

### E. Pin / Whiteboard 消费

| Tool | Params | Returns |
|---|---|---|
| `read_pick` | `mode?: auto\|links\|text\|full, include_tree_json?` | pinned, picked_index, app, element (消费 PickStash) |
| `read_whiteboard` | — | drawn, region_count, markdown (消费 WhiteboardStash) |
| `read_whiteboard_image` | `image_id:string` | ImageContentBlock (png bytes) |
| `add_annotation` | `source, body, anchor_label, anchor_ref?` | queued |
| `read_annotations` | — | count, annotations:[] |
| `clear_annotations` | — | cleared |

### F. 交互动作 (side-effect) — 复用 OCCU Swift Kit

**关键决策**: 不重写 click/type_text/press_key/scroll/drag/set_value/AX walker. 直接依赖 [`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use) 的 `OpenComputerUseKit` Swift package.

- Everywhere 走的是同一个库 (通过 libAxHelper.dylib → OCCU): 见 `Everywhere/src/Everywhere.Mac/AxBridge/OccuAxBridgeBackend.cs`
- openclicky (macOS-only Swift) 更直接: `Package.swift` 里 `.package(url: "https://github.com/iFurySt/open-codex-computer-use", ...)` 加 `OpenComputerUseKit` product
- 或 vendored: `AppResources/OpenClicky/OpenComputerUseKit/` 直接 subrepo
- **好处**: 免翻译 `AXUIElement.cs` (63KB) + `MacInputSimulator.cs` (15KB) + `SnapshotRenderer.cs` (a11y 树渲染) + click auto-detect-SwiftUI 等 wowdd1 在 Everywhere 里花时间填的坑

| Tool | Params | 后端 |
|---|---|---|
| `click` | app, element_index?\|(x,y), click_count?, mouse_button? | OCCU `click` |
| `type_text` | app, text (≤100k) | OCCU `type_text` (grapheme-aware) |
| `press_key` | app, key (xdotool syntax) | OCCU `press_key` |
| `scroll` | app, element_index, direction, pages? | OCCU `scroll` |
| `drag` | app, from_x, from_y, to_x, to_y | OCCU `drag` |
| `set_value` | app, element_index, value | OCCU `set_value` |
| `perform_secondary_action` | app, element_index, action | OCCU |

同理 **AX walker / snapshot 渲染** 也走 OCCU: `list_apps`, `get_app_state`, `get_app_context`, `get_focused_context`, `expand_element`, `pick_element`, `screenshot` 全走 OCCU. Layer 0 里只 port Everywhere 里 OCCU 未覆盖的部分 (FinderSelection AppleScript / BrowserURL / TerminalScrollback / Clipboard / IdleTime / OCR).

### G. 文档 readers (long-tail)

`doc_read_pdf`, `doc_read_docx`, `doc_read_xlsx`, `doc_read_pptx`, `doc_read_epub`, `doc_read_html`, `doc_read_txt` — 都 `path:string` → `{text, metadata}`. 用 Swift 库替代 Everywhere 的 .NET 库 (`PdfPig` → `PDFKit`, `OpenXml` → 第三方 SwiftPackage, 或直接 shell 调 `textutil`/`mdimport`).

### H. Web

| Tool | Params | Returns |
|---|---|---|
| `web_search` | query, count?=5 | ok, count, results:[{title,url,snippet}] |
| `web_fetch_url` | url | markdown (via r.jina.ai) |

### I. Config / discovery / meta

| Tool | Purpose |
|---|---|
| `list_more_tools(category?)` | 分类列 hidden tools + navigation hint |
| `call_tool(name, arguments_json?)` | 反射调任意 tool |
| `search_tools(query, top_k?)` | BM25 关键词搜 |
| `list_domains` | 分组 + 激活状态 |
| `activate_domain(name)` | 激活/隐藏切换 |
| `batch(steps_json)` | 顺序多 tool 调用 |

### J. Memory tools (Everywhere `MemoryTools.cs` — 完整移植)

| Tool | Params | Returns |
|---|---|---|
| `memory_read` | `key?:string` | { entries } — 读 agent 记忆 |
| `memory_read_endpoint` | `endpoint:string` | 特定 endpoint 记忆 |
| `memory_write_endpoint` | `endpoint:string, value:json` | ok — 覆盖 endpoint 记忆 |
| `memory_write_field_map` | `map:{k:v}` | ok — bulk 字段更新 |
| `memory_append_note` | `text:string` | ok |
| `memory_snapshot` | — | 全量 dump (调试) |
| `memory_freshness` | — | { last_write, staleness_seconds } |

### K. 后期移植 (P4, 若确有需求)

- `chat_create/delete/list/read/send/subscribe` — chat bus (Everywhere 生态特性)
- `adapter_*` — self-expanding adapter authoring (Everywhere 独有生态)
- `opencli_*` — OpenCLI adapter runtime
- `connector_*` — Open-Connector SaaS 桥
- `capture_start/stop/current/export` — 会话录制 (Everywhere 后期加的)
- `gate_*` — CoreToolGate 管理

**默认不做**. 与 openclicky 目标错位 (我们是 agent 平台, 不是 adapter marketplace). 用户显式要再加.

### L. openclicky 独有 (超越 Everywhere)

| Tool | Params | Returns |
|---|---|---|
| `probe_workdir` | path:string | is_empty, project_type, has_git, has_openclicky_state, has_agents_md |
| `list_recent_agent_sessions` | limit?:int | [{title, workdir, status, age_seconds}] |
| `project_registry_lookup` | query:string | [{name, path, aliases, last_used}] |
| `project_registry_add` | name:string, path:string, aliases? | ok |
| `git_awareness` | path:string | branch, dirty, uncommitted_count, remote_ahead_behind |

---

## 实现要点

- **端点**: `/mcp/sensor` 新增, 复用现有 `sendMCPStreamableHTTP` (SSE + chunked encoding + notifications/initialized 202)
- **Role gating**: 加 `.sensor` role, `sensor_*` / `get_*` / `read_*` tool 名走这个
- **Backend**: 全部走 Layer 0 `OpenClickyContextService`
- **AX / snapshot / action tools** (list_apps / get_app_state / click / type_text / press_key / scroll / drag / set_value / perform_secondary_action): 走 **OCCU** (`iFurySt/open-codex-computer-use` `OpenComputerUseKit` Swift package, SPM 依赖). Everywhere 通过 `libAxHelper.dylib` C ABI 调它; openclicky Swift 原生直接 SPM 依赖同一个 package
- **区分**: openclicky 现有的 bundled `cua-driver` (22MB, `AppResources/OpenClicky/CuaDriverRuntime/`) 是**不同上游 (trycua/cua)**, 服务 App 内 UI 场景 (visual guidance overlay), **不给 sensor MCP 用**. Sensor MCP 一律走 OCCU
- **Codex 集成**: `mcp_servers` 里挂 openclicky sensor endpoint, 不挂 cua-driver

---

## Self-expanding tools (照 Everywhere SPEC v3, wowdd1 2026-07-01)

**背景**: Everywhere 发现 `tools/list` payload 从 25K token 压到 6K, 只暴露 core tools, 其余通过 `search_tools / list_more_tools / call_tool / activate_domain` 反射拿. 见 commit `feat(mcp): core-tool gate + meta tools`, `feat(mcp): self-expanding context platform (SPEC v3)`.

**openclicky 完全照搬**:
- Core tools 只 8-10 个 (见下)
- Long-tail 隐藏, `list_more_tools(category?)` 可展 category, `search_tools(query, top_k?)` BM25 搜, `activate_domain(name)` 一次开一组, `call_tool(name, args)` 反射调
- Env kill switch: `OPENCLICKY_MCP_SELFEXPAND=0` 全展开 (Everywhere 是 `EVERYWHERE_MCP_SELFEXPAND=0`)
- 参考文档: `Everywhere/docs/specs/everywhere-self-expanding.md` (53KB, 完整 SPEC)

**Meta tool 表**:

| Tool | Purpose |
|---|---|
| `list_more_tools(category?)` | 分类列 hidden tools + navigation hint |
| `search_tools(query, top_k?)` | BM25 关键词搜, 返回 tool name + 一句 description |
| `activate_domain(name)` | 激活 domain, 该 domain 里所有 tool 变成 visible |
| `list_domains` | 列所有 domain + 激活状态 |
| `call_tool(name, arguments_json?)` | 反射调任意 tool (含 hidden) |
| `batch(steps_json)` | 顺序多 tool 调用 |

## Tool gating (照 Everywhere `GateTools.cs` / `CoreToolGate` 语义)

Everywhere 有 CoreToolGate — 默认只暴露基础 tool, `EVERYWHERE_MCP_FULL=1` env 全开. Codex / 弱模型见到 80 个 tool 会乱, 所以默认精选.

openclicky 版 (完全一致语义):
- **Core** (默认可见): `get_focused_context`, `get_selected_text`, `get_clipboard`, `get_browser_url`, `get_finder_selection`, `screenshot`, `read_pick`, `read_whiteboard`, `probe_workdir`, `project_registry_lookup`
- **Hidden** (long-tail, 通过 `list_more_tools` + `call_tool` + `search_tools` + `activate_domain` 反射): `list_apps`, `expand_element`, `pick_element`, `clipboard_write`, `add_annotation`, `read_whiteboard_image`, `doc_read_*`, memory_*, ...
- **Env override**: `OPENCLICKY_MCP_FULL=1` 全展开 (Everywhere 是 `EVERYWHERE_MCP_FULL=1`)

---

## 端到端测试

- 起 openclicky, 用 `curl -X POST http://127.0.0.1:32123/mcp/sensor -H "x-openclicky-token: T" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'` 应见所有 core tool
- Codex 走 mcp_servers.sensor, 应能调 `probe_workdir`
- 外部 Claude Code 也能同样调
- 与 Everywhere 输出 diff (same env, same call, expect same result)
