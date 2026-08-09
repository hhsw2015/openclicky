# Phase 4 Step 1 — Preflight context + [ROUTE] parse — Report

## Files modified
- `cursor-buddy/HeyClickyChatToolCallClient.swift` — added preflight builder, block formatter, directive block, route-parse helper, and gated injection into `query`. Also added `[ROUTE]` parse hook right before `onTextChunk`.

## Files not modified (investigation only)
- `cursor-buddy/CompanionManager+HeyClicky.swift` — the single call site into `analyzeVoiceResponse` benefits automatically since the parse/log happens inside the client. No change needed.
- `cursor-buddy/CompanionManager+AIResponsePipeline.swift` — same. The `.heyclickyFree` arm at line 422-431 just forwards; the client handles context injection and route parsing internally.

## What the proxy actually sees
The `/chat-tool-call` request body does not forward the local `systemPrompt` string (see the existing `_ = systemPromptForBody` line in `HeyClickyChatToolCallClient.swift`). To reach Fable, both the situational context and the routing contract have to ride inside `query`. That is what this change does — it prepends TWO markdown blocks in front of the raw user transcript, still in a single `body["query"]` string.

## Preflight context block format (example)

```
[openclicky-context]
frontmost_app: com.apple.Safari (Safari)
window_title: "GitHub - openclicky/roadmap"
url: https://github.com/openclicky/roadmap
selected_folder: /Users/wowdd1/Dev/openclicky
selected_files: [ROADMAP, README.md, CHANGELOG.md]
selected_text: "func foo() { return 42 }"
[/openclicky-context]
```

Rules:
- Fields with nil/empty values are OMITTED (no `... : null` filler).
- `frontmost_app` collapses to just the bundle id or just the localized name if one side is missing.
- `window_title` and `selected_text` are quoted; embedded backslashes / newlines / double-quotes in `selected_text` are escaped so the block stays one logical line per field.
- `selected_text` is capped at 1000 characters, with `…` suffix on overflow.
- `selected_files` shows the top 3 filenames only (roadmap spec).

## System prompt appendix (verbatim)

Added as a separate `[openclicky-directives]…[/openclicky-directives]` block prepended to `query` after `[openclicky-context]`:

```
[openclicky-directives]
CONTEXT AWARENESS:
You receive an [openclicky-context]...[/openclicky-context] block before each user query. It shows the user's current app / window / selection. Use it to resolve referential language (e.g. "the func you're looking at" refers to selected_text; "this folder" refers to selected_folder; "this page" refers to url).

INTENT ROUTING:
At the END of your reply, emit exactly one JSON line prefixed with [ROUTE]:
[ROUTE] {"kind":"chat"|"short_task"|"long_task_new"|"long_task_existing"|"ambiguous","project_ref":null|string,"slug":null|string,"workdir":null|string,"confidence":0.0-1.0}

Rules:
- kind=chat: Q&A / discussion only, no side-effects — this is the default.
- kind=short_task: one-off single-step action (open an app, take a screenshot, tiny edit).
- kind=long_task_new: build a brand-new project from scratch.
- kind=long_task_existing: modify a known existing project (must match a project_ref keyword the user mentioned).
- kind=ambiguous: unclear intent, low confidence; ask a clarifying question in your spoken text.

Emit exactly one [ROUTE] line, at the end. Do NOT wrap it in code fences. If the intent is pure chat, still emit [ROUTE] {"kind":"chat",...} to signal explicit intent.
[/openclicky-directives]
```

Note: this block is stored as `HeyClickyChatToolCallClient.contextAwarenessDirectiveBlock` (single source of truth). Kept out of the CompanionManager system prompt because the proxy does not forward that prompt anyway.

## RouteParseResult struct + regex

```swift
struct RouteParseResult: Codable, Sendable {
    let kind: String
    let projectRef: String?   // decoded from "project_ref"
    let slug: String?
    let workdir: String?
    let confidence: Double
}

static func parseRouteJSON(_ reply: String) -> RouteParseResult?
```

Regex: `\[ROUTE\]\s*(\{[^\n]*\})`

- Scans the FULL reply, keeps the LAST match (defensive against Fable accidentally emitting more than one).
- Rejects nested braces / multi-line JSON on purpose — the contract is single-line, and a stricter regex avoids matching stray `{...}` text elsewhere in the model's spoken reply.
- JSON decode uses `JSONDecoder`; missing / malformed fields → `nil` return, never throws.

## Toggle
`UserDefaults.standard.object(forKey: "openclicky.contextAwarenessEnabled") as? Bool ?? true`

- Default `true`. When off, `query` is passed through with no preflight or directive block prepended (identical to pre-Phase-4 behaviour).
- Terminal opt-out for the user:
  ```
  defaults write com.jkneen.openclicky openclicky.contextAwarenessEnabled -bool false
  ```

## Preflight capture list (5 items, main-actor)
1. `FrontmostAppCapture.capture()` — bundle id + localized name.
2. `FocusedWindowCapture.capture(processId:)` — title only.
3. `BrowserURLCapture.capture(processId:)` — GATED on frontmost bundle being in `knownBrowserBundleIDs` (Safari, Chrome family, Arc, Edge, Brave, Firefox family). Silent nil otherwise.
4. `FinderSelectionCapture.capture()` — GATED on frontmost being `com.apple.finder`. Emits `currentFolder` + top-3 filenames.
5. AX-only selected text — inlined helper `selectedTextAXOnly()` that walks `SelectionCache → AXFocusedUIElement → AXSelectedText`. NEVER escalates to `Cmd-C`. Never touches the clipboard.

## Build result

```
[0/5] verify cert exists in login keychain
[1/5] xcodebuild
note: Disabling hardened runtime with ad-hoc codesigning. (in target 'OpenClickyWidgets' from project 'cursor-buddy')
** BUILD SUCCEEDED **
  built: /Users/wowdd1/Library/Developer/Xcode/DerivedData/cursor-buddy-cqfqkyzfmptpmtatmpytdlpwuvad/Build/Products/Debug/OpenClicky.app
[2/5] codesign with OpenClicky Dev Sign
[3/5] kill running + swap /Applications/OpenClicky.app
[4/5] open
  openclicky pid=73142  identifier=com.jkneen.openclicky  Authority=OpenClicky Dev Sign
[5/5] done.
```

Full `bash scripts/sign-and-install.sh` succeeded; the freshly signed app is installed and running.

## Manual test recipe

Prereqs:
- Selected profile is HeyClicky Free (proxied `/chat-tool-call`).
- `openclicky.contextAwarenessEnabled` is unset OR set to `true` (default is on).

Recipe:
1. Open Console.app, filter by subsystem `com.jkneen.openclicky` (or filter on message `openclicky.preflight_context` / `openclicky.route_parsed`).
2. Launch OpenClicky (if not already running).
3. Bring Safari to the front with a real GitHub tab open.
4. Highlight a small block of text in that tab.
5. Push-to-talk hotkey, say something referential like: "explain this function to me".
6. In Console.app you should see:
   - `openclicky.preflight_context` with `frontmost=com.apple.Safari`, `window_title_len>0`, `has_url=true`, `selected_text_len>0`.
   - `openclicky.route_parsed` with `kind=chat` (Fable should classify pure Q&A as chat) after Fable's reply lands.
7. Now put Finder in front with a folder selected. Ask via hotkey: "start a new tool that reads this folder".
   - `openclicky.preflight_context` should carry `has_folder=true`, `selected_files_count>0`.
   - `openclicky.route_parsed` should log `kind=long_task_new` or `short_task` (Fable's judgment).
8. To sanity-check the toggle, run:
   ```
   defaults write com.jkneen.openclicky openclicky.contextAwarenessEnabled -bool false
   ```
   Kill and relaunch OpenClicky, redo the voice turn. Console should NOT show `openclicky.preflight_context`, and `openclicky.route_missing` will fire (because Fable was never told about the `[ROUTE]` contract).
9. Re-enable with:
   ```
   defaults write com.jkneen.openclicky openclicky.contextAwarenessEnabled -bool true
   ```

## Known limitations
- If Fable's reply is very short (e.g. a single acknowledgement word), it may ignore the `[ROUTE]` directive entirely. `openclicky.route_missing` fires and we take no action — matches roadmap doc "若 `[ROUTE]` 缺失 → 视为 chat" section.
- `selected_text` capture is intentionally AX-only. Apps that don't publish `AXSelectedText` on their focused element (VS Code without a11y toggle, some Electron shells) will return `nil` here even when the user obviously has text highlighted. We do not fall back to Cmd-C during preflight because that mutates the pasteboard — instead the user's Cmd-C-earned selection lives in `SelectionCache.shared` (from prior explicit voice turns) and is honored here.
- Secure text fields (password prompts) are handled by the OS: `AXSelectedText` returns nil, so nothing leaks. We never invoke Strategy 3 (Cmd-C) in preflight.
- Finder AppleScript path can be slow (~200 ms cold) on first invocation. Only paid when Finder is actually frontmost.
- Browser URL detection relies on `AXURL` walk (16-hop). Some Electron-based browsers (Zen, some Chromium spinoffs) may need to opt into `AXManualAccessibility` for this to fire; those return `nil` silently.
- Dispatch is intentionally NOT implemented in this step. `[ROUTE].kind` is logged only. Phase 4 Step 2 wires the actual dispatch.

## Regex hardening notes
- The `\{[^\n]*\}` grammar rejects multi-line JSON. Fable is instructed to emit one line, so this is a feature, not a bug — a malformed multi-line emission will surface as `openclicky.route_missing` in logs and prompt a follow-up prompt-engineering pass.
- Last-match-wins protects against duplicate emissions inside the same reply (e.g. Fable copies the example line from the directive into its own reply verbatim). In practice we expect exactly one match.
