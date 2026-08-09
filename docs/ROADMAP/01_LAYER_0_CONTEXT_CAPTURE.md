# Layer 0 — ContextService (30 项: 26 Everywhere 对等 + 4 独有)

**位置**: `Packages/OpenClickyContextService/` (新 SPM package, 与 `OpenClickyCore` / `OpenClickyUI` / `OpenClickyMemory` / `OpenClickyMarkdown` / `OpenClickyBrowser` 平级. 现有代码零改动. Main app 通过 `Package.swift` local dep 引入, 一次性 Xcode add package 后自动 track file)

**Swift 类**: `OpenClickyContextService` — 单例, 提供 protocol `ContextCaptureProvider`

**权限**: 已备齐 (`Info.plist` 里有 `NSAppleEventsUsageDescription`, AX 已请求)

**翻译方针**: 一对一 port 自 `~/Dev/Everywhere/src/Everywhere.Mac/`. 每 Swift file 顶部标 `// Ported from Everywhere: <path>@<rev>`. 保留原注释. 语法变逻辑不变. 见 `08_QUALITY_ASSURANCE.md`.

**大幅缩减范围**: **AX / snapshot / action 全部走 OCCU Swift Kit**, 免翻译.
- Everywhere 走 `libAxHelper.dylib` → `OpenComputerUseKit` (`3rd/open-codex-computer-use/`)
- openclicky 直接 SPM 依赖 [`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use)
- Layer 0 里 **只手工 port** OCCU 未覆盖项: FinderSelection / BrowserURL / BrowserTabs (AppleScript) / TerminalScrollback / Clipboard 多类型 / IdleTime / OCR / Whiteboard / LinkRect / PickStash / AppleScriptRunner / URL redaction / 各种 stash 数据模型

免翻译 (走 OCCU): `AXUIElement` (63KB), `MacInputSimulator` (15KB), `ScreenSelectionSession`, `NSScreenVisualElement`, `SnapshotRenderer`, `ElementIndexer`, `PermissionHelper` (AX 权限检测部分), `CGEventListener`, `MacVisionOcrEngine` 部分 (若 OCCU 已含).

---

## 完整能力清单 (对应 Everywhere `IVisualElementContext`)

| # | 能力 | 参考 Everywhere 源 | Swift 实现文件 | 状态 |
|---|---|---|---|---|
| 1 | FrontmostApp (bundle_id/pid/name) | `AppKey.FromProcessId` | `Capture/FrontmostAppCapture.swift` | P0 |
| 2 | RunningApps (窗口+pid 列表) | `VisualElementContext.TryFastListApps` | `Capture/RunningAppsCapture.swift` | P0 |
| 3 | FocusedWindow (title/geometry/display) | `AXUIElement.FreshFocusedWindowOf(pid)` | `Capture/FocusedWindowCapture.swift` | P0 |
| 4 | FocusedElement (role/name/value/states/actions) | `SnapshotRenderer.cs` | `Capture/FocusedElementCapture.swift` | P1 |
| 5 | IndexedAXTree + budget 压缩 | `ElementIndexer.Walk` + `SnapshotRenderer` | `Capture/AXTreeCapture.swift` | P1 |
| 6 | SelectedText (三级 fallback) | `VisualElementContext.TextSelection.cs` + `SelectionCache.cs` | `Capture/SelectedTextCapture.swift` | P0 |
| 7 | SelectionCache (2min TTL) | `SelectionCache.cs` | `Capture/SelectionCache.swift` | P1 |
| 8 | CursorPosition + ElementAtPoint | `VisualElementContext.ElementFromPoint*` | `Capture/CursorCapture.swift` | P1 |
| 9 | BrowserURL (AX AXURL walk) | `MacBrowserUrlReader.cs` | `Capture/BrowserURLCapture.swift` | P0 |
| 10 | BrowserTabsList (AppleScript) | `MacBrowserTabsReader.cs` | `Capture/BrowserTabsCapture.swift` | P1 |
| 11 | FinderSelection (POSIX + folder) | `MacFinderReader.cs` | `Capture/FinderSelectionCapture.swift` | P0 |
| 12 | TerminalScrollback | `GetTerminalOutputTool.cs` | `Capture/TerminalCapture.swift` | P1 |
| 13 | Clipboard (text/file/image/rtf) | `MacClipboardReader.cs` | `Capture/ClipboardCapture.swift` | P0 (text), P1 (others) |
| 14 | Screenshot (full/window/region) | `NSScreenVisualElement.cs`, `VisualElementContext.Screenshot.cs` | `Capture/ScreenshotCapture.swift` | P0 (extend existing) |
| 15 | ScreenList + MultiDisplay | `NSScreenVisualElement.cs` | `Capture/ScreenListCapture.swift` | P1 |
| 16 | VisionOCR (per-line + bbox) | `MacVisionOcrEngine.cs` | `Capture/OCRCapture.swift` | P1 |
| 17 | LinkRect harvest (drag 框) | `VisualElementContext.LinkRect.cs` | `Capture/LinkRectCapture.swift` | P3 |
| 18 | IdleTime | `MacIdleTimeReader.cs` | `Capture/IdleTimeCapture.swift` | P1 |
| 19 | ContextStash (原子写) | `ContextStashWriter.cs` | 见 Layer 3 | P2 |
| 20 | AXManualAccessibility flip | `AXUIElement.SetAppBoolAttribute` | `Capture/AXQuirksInstaller.swift` | P1 |
| 21 | Per-app quirks (Electron/Chromium/SwiftUI) | `SnapshotRenderer.DisplayRole` etc. | `Capture/AXQuirksInstaller.swift` | P1 |
| 22 | Whiteboard gestures + OCR | `WhiteboardHotkeyInitializer.cs` + `SemanticEnricher` | 见 Layer 4 | P3 |
| 23 | AppleScript runner | `MacAppleScriptRunner.cs` | `Capture/AppleScriptRunner.swift` | P0 (基础) |
| 24 | WindowEnumeration (CGWindowList) | `ScreenSelectionSession.cs` | `Capture/WindowEnumerationCapture.swift` | P1 |
| 25 | ScreenRecording permission preflight | `PermissionHelper.cs` | `Capture/PermissionPreflight.swift` | P1 |
| 26 | SemanticExtractor (焦点路径) | `SemanticExtractor.cs` | `Capture/SemanticExtractor.swift` | P1 |

---

## 补充能力 (openclicky 独有)

超越 Everywhere:

| # | 能力 | Swift 实现文件 |
|---|---|---|
| 27 | ProbeWorkdir (fs stat + project type detect) | `Capture/WorkdirProbe.swift` |
| 28 | RecentAgentSessions (openclicky 内部) | `Capture/RecentSessionsCapture.swift` |
| 29 | ProjectRegistry (fuzzy 匹配 + 别名) | `Capture/ProjectRegistry.swift` |
| 30 | GitAwareness (branch / dirty / stash 提醒) | `Capture/GitAwarenessCapture.swift` |

---

## API 形态

```swift
final class OpenClickyContextService {
    static let shared = OpenClickyContextService()

    // Router 用: 打包"必备预取"
    func snapshotForRouter() async -> RouterContext

    // 单项按需查
    func frontmostApp() -> FrontmostAppInfo?
    func focusedWindow() -> FocusedWindowInfo?
    func finderSelection() async -> FinderSelectionInfo?
    func selectedText() -> SelectedTextInfo?
    func browserURL() -> URL?
    func clipboardText() -> String?
    func probeWorkdir(_ path: URL) -> WorkdirProbe
    func recentAgentSessions(limit: Int) -> [AgentSessionRef]
    func projectRegistryLookup(_ query: String) -> [ProjectMatch]
    // ...

    // 昂贵操作 (供 codex sensor 用)
    func focusedAXTree(budgetTokens: Int) async -> AXTreeSnapshot
    func ocr(image: NSImage, languages: [String]) async -> OCRResult
    func browserTabs(app: String?) async -> [BrowserTab]
    func terminalScrollback(lines: Int) async -> String?
    // ...
}
```

---

## 数据模型

```swift
struct RouterContext: Codable {
    let capturedAtUnix: Double
    let voiceTranscript: String?
    let frontmostApp: FrontmostAppInfo?
    let focusedWindow: FocusedWindowInfo?
    let finderSelection: FinderSelectionInfo?
    let selectedText: SelectedTextInfo?
    let browserURL: URLInfo?
    let clipboardPreview: String?
    let recentAgentSessions: [AgentSessionRef]
    let projectRegistryMatch: ProjectMatch?
}

struct FinderSelectionInfo: Codable {
    let currentFolder: String?      // POSIX path
    let selectedFiles: [FinderItem]
}

struct FinderItem: Codable {
    let path: String
    let name: String
    let isDirectory: Bool
    let kindHint: String?           // "pdf", "xcode-project", "git-repo", ...
}

struct SelectedTextInfo: Codable {
    let text: String
    let source: SelectedTextSource  // .ax | .child | .clipboardCmdC | .cache
    let sourceApp: String?
    let length: Int
}

struct WorkdirProbe: Codable {
    let path: String
    let exists: Bool
    let isDirectory: Bool
    let isEmpty: Bool
    let fileCount: Int
    let detectedProjectType: ProjectType   // non-optional; unknown = .unknown (per implementation, avoids nil branch + compact JSON)
    let hasGit: Bool
    let hasOpenClickyState: Bool
    let hasAgentsMd: Bool
}
```

---

## 采集执行顺序 (仿 Everywhere `CaptureCoreAsync`)

**同步串行, 主线程** (AX API 强制要求):
1. FocusedElement walk to top-level
2. BrowserURL per-pid
3. SelectedText (cache → focused → clipboard Cmd-C fallback)
4. PickStash / WhiteboardStash peek
5. Clipboard multi-pick (若有 sentinel)
6. Annotations peek (不消费)
7. 上面若全空 → return, 不写 stash
8. 原子写文件 (Layer 3 才需)
9. 上面成功后 Consume annotations

**单飞锁** `NSLock` — 快速二次 hotkey 直接丢, 不排队.

---

## 冲突处理

- `AXManualAccessibility` flip 是**全局副作用**, 需要 per-app 一次性 + 幂等 + 记录
- Cmd-C fallback: 先 `NSPasteboard.changeCount`, 复制, poll 100ms, 拿走, **恢复原剪贴板**
- CGEventTap: 与 openclicky voice PTT tap 共存, 只要 `return .passUnretained(event)`
- `NSAppleEventsUsageDescription`: 已配置

---

## 测试策略

- **Golden diff**: 装 Everywhere + openclicky, 同环境 hotkey, diff 双方 stash 文件
- **XCTest** 每项独立测
- **Fixture script**: `scripts/verify-context/` — osascript 前置状态 + Swift 采集 + assert
- **Corner case 表格**: 空目录 / 中文路径 / emoji 名 / URL 带 credential / RTL text / Password field / Electron / SwiftUI
