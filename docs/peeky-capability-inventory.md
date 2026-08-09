# Peeky Capability Inventory (v0.1.10)

Source-of-truth extraction for what Peeky.app v0.1.10 does end-to-end. Runtime pipeline and prompts are from `/tmp/Peeky/peeky/src/` (GitHub `main`) but tool schemas in section 4 are from `strings /Users/wowdd1/Downloads/Peeky.app/Contents/MacOS/peeky` because `main` has drifted from the shipping binary.

- `Peeky.app/Contents/Info.plist`: `CFBundleIdentifier=com.peeky.settings`, `CFBundleExecutable=console`, `LSUIElement=true`, `LSMinimumSystemVersion=10.13`.
- Two binaries: `MacOS/console` (~10MB, Tauri 2.11 tray/settings shell) and `MacOS/peeky` (~30MB, Rust voice loop).
- Resources: `models/routelet/{embedder.onnx (127MB), tokenizer.json (695KB), head.json (51KB)}`, `icon.icns (116KB)`.

---

## 1. Runtime pipeline (push-to-talk to TTS)

Entry: `hotkey::wait_for_press()` in `orchestrator::run_one_turn`. Hotkey on macOS = `Ctrl+Space` via the `global-hotkey` crate.

| Phase | Trigger | Input | Output | Notes / approx timing |
|---|---|---|---|---|
| 0. Pre-turn screenshot spawn | hotkey pressed | monitor geometry | JPEG b64 (queued in `JoinHandle`) | Fires in parallel with recording; `xcap::Monitor` capture, resized to declared res, JPEG q85, base64. "Thrown-away pixels" when path is chat/integration/memory. |
| 1. Record + transcribe | key still down | mic PCM via `cpal` | live SSE from Deepgram WS | `AUDIO_PREROLL_MS=0`, `AUDIO_POST_RELEASE_GRACE_MS=200`. Deepgram WS URL: `wss://api.deepgram.com/v1/listen?model=nova-3&language=en&encoding=linear16&sample_rate=X&channels=Y&punctuate=true&interim_results=true&smart_format=true`. |
| 2. Await final transcript | key released | Deepgram finals | plain string | Waits `STT_QUIESCENCE_MS=150` after first non-empty final. Empty transcript short-circuits the turn. |
| 3a. Agent-cue check | transcript ready | full transcript | `Option<Intent::Agent>` | Deterministic prefix `"peeky agent"` (case-insensitive) with word-boundary after. Overrides classifiers. |
| 3b. Keyword allowlist | if no cue | trimmed lowercased utterance | `Option<Intent>` | Exact match against 13 transport words (see section 2). Sub-microsecond. Overrides routelet. |
| 3c. Routelet ONNX | every turn (logged even if skipped) | transcript | `(Intent, confidence)` | Synchronous CPU BERT-mini embed + logistic head, ~30-45ms release. `ROUTELET_CONFIDENCE_THRESHOLD=0.95`. |
| 3d. Claude Haiku classifier | routelet <0.95 OR label=`none` | transcript | Intent | `~250-400ms` after cache warm. Forced-tool call. |
| 4. Per-turn infra | intent chosen | | `BargeIn` token, `early_exit` token, TTS mpsc channel, rodio player | `BargeIn` spawns 1-ms poll thread on the hotkey; cancels every `select!` in the turn. |
| 5. Intent dispatch | | transcript + b64 screenshot (some paths) | streamed text deltas | See section 3. Each path pushes text into `sentence_tx` for TTS. |
| 5b. TTS synth | first sentence boundary | text sentence | raw PCM 24kHz mono | Cartesia SSE `sonic-2` model, default voice `a0e99841-438c-4a64-b679-ae501e7d6091` ("Barbershop Man"). `TTS_FIRST_FLUSH_MIN_CHARS=12` (accept `,`/`;`/`:` as flush points for first flush only). |
| 5c. Audio playback | PCM chunk | `i16le` -> `f32` | rodio `SamplesBuffer` | Player empty check every 20ms until drained or barge-in. |
| 6. Wait + cleanup | stream end | | | `tokio::select!` on `barge_in.token()` vs `tts_handle`. Cursor set to `Idle` unless hotkey held again. |

### Barge-in

`barge_in.rs` spawns an OS thread that polls `hotkey::is_recording()` every 1ms after the initial release. A second press flips the shared `CancellationToken`, which every HTTP stream (`claude.chat`, `claude.integration`, `claude.run_agent_loop`, `cartesia.synthesize_stream`, `rodio player.stop()`) races against via `tokio::select! { biased; _ = cancel.cancelled() => ..., }`. `Drop for BargeIn` cancels on end of turn.

### Cancellation tokens

- `barge_in.token()`: fires on next hotkey press. Aborts Claude + TTS + player.
- `early_exit`: separate token flipped by `dispatch_action` after firing any visible action (cursor move/click/type/open_url/launch_app/switch_to_window). Stops the agent loop from doing another round-trip once the user already has feedback. Integration actions do NOT flip it (they still need the summary).

### Pre-screenshot strategy

Screenshot is captured immediately on hotkey press, in a `spawn_blocking` task started before STT. When the classifier lands, Chat and Agent/FindAction receive the pixels; Integration and Memory drop them. Cost when unused = pixels only; the JPEG encode already happened in the background.

### STT WS session reuse

`providers/token_cache.rs`: `Arc<Mutex<Option<Cached { value, expires_at }>>>`. On startup `SttDeepgram::warm()` mints a Deepgram JWT from `https://<AEGIS_PROXY_HOST>/v1/deepgram/token` and seeds the cache with `PROXY_TOKEN_REFRESH_MARGIN_SECS=120` margin. The proxy mints 3600s tokens, so effective session ~= 58 min per mint. Each new turn opens a fresh WS connection to `api.deepgram.com` but reuses the same bearer JWT until it nears expiry.

### TTS mint reuse

Cartesia mint is `https://<AEGIS_PROXY_HOST>/v1/cartesia/token` via same `TokenCache`. Multi-sentence turns reuse the token across every synthesize call. `X-API-Key: <bearer>` header + `Cartesia-Version: 2026-03-01`.

### Per-phase approximate timing (from source comments / eprintlns)

| Phase | ~Cost |
|---|---|
| STT quiescence after last final | 150 ms |
| Post-release audio grace | 200 ms |
| Routelet inference | 30-45 ms |
| Claude classifier (Haiku, cache warm) | 250-400 ms |
| Chat path (release -> speech) target | ~800-1000 ms |
| Agent settle between steps | 600 ms (`AGENT_SETTLE_MS`) |
| Agent max steps | 10 (`AGENT_MAX_STEPS`) |
| Kept screenshots in history | 3 (`AGENT_KEEP_RECENT_SCREENSHOTS`) |
| Integration max tool calls / turn | 3 (`INTEGRATION_MAX_TOOL_CALLS`) |
| Working-context recent turns | 6 (`WORKING_CONTEXT_RECENT_TURNS`); compact at 10 |

---

## 2. Intent routing (three tiers)

### Tier A: keyword allowlist (`intent.rs::keyword_classify`)

Exact match after `trim().to_lowercase().trim_end_matches(['.','!','?'])`. All map to `Intent::Integration`:

```
play, pause, resume, stop, mute, unmute,
skip, next, next song, next track,
previous, previous song, previous track
```

Anything else, including `play sicko mode` or `skip to the chorus`, returns `None` and falls through.

### Tier B: routelet ONNX (`routelet/mod.rs`)

Pipeline:
```
text -> redact::preprocess -> tokenizer (WordPiece, add_special_tokens=true)
     -> embedder.onnx run([input_ids, attention_mask, token_type_ids])
     -> [1, 384] f32 embedding
     -> head: coef[C][384] · emb + intercept[C] -> logits/temperature -> softmax
     -> argmax label
```

- Model: BERT-mini embedder, int8-dynamic-quantized, opset 14 (LayerNorm decomposed). Inputs: three i64 [1, seq] tensors named `input_ids`, `attention_mask`, `token_type_ids`. Output: `embedding` f32 [1, 384].
- `head.json` shipped (extracted): `coef` [5, 384], `intercept` [5], `labels: ["chat","find_action","integration","memory","none"]`, `temperature: 1.0`.
- `agent` label deliberately absent -- agent is only via `agent_cue` short-circuit.
- Confidence gate: `conf >= 0.95` AND label != `none` accepts on-device; else fall through to Claude.
- Startup drops any `agent` label if head still ships it (`labels.iter().position(|l| l == "agent")` remove).

### Tier C: Claude Haiku classifier (`providers/claude/classifier.rs`)

Model: `claude-haiku-4-5`, `max_tokens: 80`, `stream: true`, `tool_choice: { type: "tool", name: "classify" }`.

Tool schema:
```json
{
  "name": "classify",
  "description": "Emit the single best category for the user's voice command.",
  "input_schema": {
    "type": "object",
    "properties": {
      "category": {
        "type": "string",
        "enum": ["find_action", "integration", "chat", "memory", "agent"]
      }
    },
    "required": ["category"]
  }
}
```

System prompt (verbatim from `classifier_system_prompt()`):
> You are a voice-command router for a desktop voice assistant. Read the user's transcript and pick ONE category by calling the `classify` tool. Never respond in plain text.
>
> Categories:
> - find_action: move the cursor to, or operate on, a UI element visible on the screen right now. Needs a locate-or-operate command: "click X", "select X", "type X", "scroll down", "point at X", "show me X", "find X", or "where is X" when the user wants to go there. Naming a visible element in the command is find_action even if an app is named ("click the skip button").
> - integration: one discrete action against a connected service (Gmail, Spotify, GitHub, YouTube) without looking at the screen: "play <song>", "pause", "skip", "next", "volume up", "check my email", "how many unread emails", "what are my open PRs". INCLUDES remember/note/save: [omitted -- see source]. Recall: "what's my Z", "what did I tell you about R". A fact of world knowledge is chat, not memory.
> - agent: two or more chained actions, OR a single task that needs planning to finish: "open youtube, search lofi, play the top result", "book me a restaurant". Not only when the user spells out steps.
>
> If a command fits more than one, pick the first match in the order: agent, memory, integration, find_action, chat. chat is the default; when unsure between find_action and chat, choose chat. Always call the tool. Never refuse to classify.

### Fallback order

```
agent_cue → keyword_allowlist → routelet (>=0.95 && !none) → claude → speak_error
```

`Intent::None` from routelet or a Claude-None result reaches `speak_error("I'm not sure how to handle that. Try rephrasing.")` (unless `upgrade::take_announcement()` returns a proxy-quota message).

Loud-fail contract: an unresolved intent speaks an error rather than silently defaulting to Agent.

---

## 3. Per-intent path detail

Every path uses `POST` to `https://<AEGIS_PROXY_HOST>/v1/anthropic/messages` (proxy mode) or `https://api.anthropic.com/v1/messages` (direct mode, requires `PEEKY_ANTHROPIC_DIRECT=1` + `ANTHROPIC_API_KEY`). Headers always include `anthropic-version: 2023-06-01` and one of:
- `x-peeky-device-id: <uuid>` (proxy mode, plus optional `x-peeky-invite-code` and `Authorization: Bearer <session_jwt>`)
- `x-api-key: <key>` (direct mode)

### 3.1 Chat (`providers/claude/chat.rs`)

- Model: `claude-haiku-4-5`, `max_tokens: 1024`, `stream: true`.
- No tools. No `anthropic-beta` header.
- Screenshot IS attached (image block, `image/jpeg` base64, before the text block).
- System blocks (in order, `cache_control: { type: "ephemeral" }` on the stable ones):
  1. Behavioral prompt (cached)
  2. Optional user profile from memory (cached, per-session)
  3. Optional Claude Code handoff text (cached)
  4. Optional live working-context conversation (NOT cached; changes each turn)

System prompt (verbatim):
> You are peeky, a voice assistant running on the user's desktop. A screenshot of the user's current screen is attached. The user is speaking to you and hearing your replies via TTS, so:
> - Be concise. Aim for 1-3 sentences unless the user asks for detail.
> - Plain prose only. No markdown, no lists, no code blocks. They sound weird when read aloud.
> - Conversational tone. Imagine you're talking, not writing.
> - Don't restate the question. Just answer it.
> - If the user asks something you don't know, say so briefly. Don't guess and don't pad with disclaimers.
>
> You CAN see the user's screen in the attached image. Use it to provide contextual help. If they ask "how do I do X" and you can see the app they're using, guide them through the UI you see. Reference specific buttons, menus, or elements visible on screen. Be helpful and specific.

### 3.2 FindAction (`providers/claude/find_action.rs`)

- Model: `claude-haiku-4-5`, `max_tokens: 500`, `stream: true`.
- `anthropic-beta: computer-use-2025-01-24`.
- `tool_choice: { type: "any" }` (forces some tool call; no text-only replies allowed).
- Screenshot attached.
- Tools: `computer` (v2 `computer_20250124`, with `display_width_px`/`display_height_px` from `pick_declared_resolution`), plus custom `open_url`, `launch_app`, `switch_to_window`. NO integration tools -- classifier already routed those.
- On-action callback fires the moment each tool's input JSON completes streaming, so cursor moves while later bytes are still arriving.
- Fallback: if the response emits zero valid actions (unknown tool, forbidden `screenshot` action, or provider error), the orchestrator re-routes the same transcript to Chat (never re-enters find_action).

System prompt (verbatim):
> You are a desktop voice-assistant action dispatcher. A screenshot of the user's screen is attached. You MUST respond with tool calls only, never a descriptive text response. Most requests take exactly one call; typing takes two (left_click the target field, then type). The user wants the cursor to MOVE and the action to FIRE, not to read coordinates in a description.
>
> Tool selection:
> - `computer` mouse_move(coordinate=[x,y]): user wants to SEE where something is on screen with NO click ("where is X", "show me X", "find X", "point at X"). Cursor moves visually, no input fires.
> - `computer` left_click(coordinate=[x,y]): user wants to actually CLICK something visible ("click X", "press X", "select X"). Cursor moves AND a real click fires.
> - `computer` type(text="..."): type into the focused field. End with \n if the user wants it submitted. For multi-step "search for X" queries, emit BOTH left_click on the input AND type with \n.
> - `computer` key(text="..."): press a key or combo (Return, Tab, Escape, ctrl+a, ctrl+f, etc.). Use for hotkeys.
> - `computer` scroll(scroll_direction="up"|"down"|"left"|"right", scroll_amount=N): scroll the focused area.
> - `open_url`: navigate to a fully-qualified https:// URL.
> - `launch_app`: start an app that isn't running.
> - `switch_to_window`: focus an already-running app by window class.
>
> FORBIDDEN: action="screenshot" on the computer tool. You already have a screenshot. Calling screenshot wastes ~6s of latency.

### 3.3 Integration (`providers/claude/integration.rs`)

- Model: `claude-haiku-4-5`, `max_tokens: 1024`, `stream: true`.
- No `anthropic-beta`.
- No screenshot (saves ~270 KB / ~1500 input tokens).
- `tool_choice: { type: "any" }` on first call; `auto` on follow-ups.
- Tools: `integrations::all_tools()` filtered by each module's `is_available()` (see section 4).
- Bounded chain: up to `INTEGRATION_MAX_TOOL_CALLS=3` dispatches, then a forced spoken text summary. Narration text alongside a tool call is streamed to TTS as it arrives.

System prompt (verbatim, with optional profile appended):
> You are peeky, a voice assistant that operates connected services (Gmail, Spotify, GitHub, YouTube) on behalf of the user via tool calls. The user is speaking to you and hearing your replies via TTS, so:
> - Chain tool calls when the task needs more than one (e.g. find a file, then open it). Finish the task before summarizing.
> - After the last tool result, compose a short spoken summary. 1-2 sentences. Plain prose, no markdown.
> - Confirm what you did or report what you found. Don't restate the request.
> - If the tool result is an error, say what went wrong briefly, not the raw error message.
> - The user can't see the screen here. Translate any technical details into something natural to hear.

### 3.4 Memory (`providers/claude/memory.rs`)

Two-stage: (a) router picks one of three sub-tools, then (b) reply is either a Rust-templated string (fastest path) or a follow-up Claude call for `recall_conversation`.

Router call: `claude-haiku-4-5`, `max_tokens: 200`, `stream: true`, `tool_choice: { type: "any" }`, no screenshot.

Tools:
```json
{"name":"store_fact","description":"User wants to remember a fact about themselves. Extract a short snake_case key and the literal value.","input_schema":{"type":"object","properties":{"key":{"type":"string","description":"snake_case identifier, e.g. 'favorite_color', 'allergic_to', 'home_city'"},"value":{"type":"string","description":"the literal value the user provided"}},"required":["key","value"]}}
{"name":"recall_fact","description":"User wants to recall a previously-stored fact. Provide the snake_case key they're asking about (best guess based on phrasing).","input_schema":{"type":"object","properties":{"key":{"type":"string","description":"snake_case key matching whatever 'remember X' might have stored"}},"required":["key"]}}
{"name":"recall_conversation","description":"User is asking about the conversation you are having right now, not a stored fact. E.g. 'what did I just ask you', 'what were we talking about', 'what did you just say'. Takes no input.","input_schema":{"type":"object","properties":{}}}
```

Router system prompt (verbatim):
> You are the memory router for peeky, a desktop voice assistant. The user is either asking to remember a fact about themselves or asking to recall one they previously stored.
>
> Call EXACTLY ONE of:
> - store_fact(key, value): user said "remember my X is Y" or stated a fact about themselves directly. Extract snake_case key + literal value.
> - recall_fact(key): user is asking "what's my X" or "what did I tell you about X". Provide the snake_case key you'd expect a prior store to have used.
> - recall_conversation(): user is asking about the conversation happening right now, not a stored fact. E.g. "what did I just ask you", "what were we talking about", "what did you just say".
>
> Examples: (omitted -- see source)
>
> Always call a tool. Never respond in plain text.

Reply generation:
- `store_fact` -> local JSONL append; templated reply `Got it. I'll remember your {key} is {value}.`.
- `recall_fact` -> in-memory lookup; templated `Your {key} is {value}.` or `I don't have your {key} on file. You can tell me by saying 'remember my {key} is...'`.
- `recall_conversation` -> second Claude call (`claude-haiku-4-5`, `max_tokens: 300`) with the working-context conversation in the system prompt, streamed to TTS.

### 3.5 Agent (`providers/claude/agent_loop.rs`, invoked only via `peeky agent` cue)

- Model: `claude-haiku-4-5`, `max_tokens: 1024`, `stream: true`.
- `anthropic-beta: computer-use-2025-01-24`.
- Screenshot attached in first user turn AND appended to every non-integration tool_result.
- Tools: `computer_20250124` + `open_url` + `launch_app` + `switch_to_window` + all integration tools (`integrations::all_tools()`).
- Loop: capture -> Claude -> execute actions (visual + integrations) -> `AGENT_SETTLE_MS=600` -> re-capture -> feed tool_results back. Terminates when Claude returns text-only, or `AGENT_MAX_STEPS=10`, or barge-in.
- `trim_old_screenshots` strips image bytes from tool_results older than `AGENT_KEEP_RECENT_SCREENSHOTS=3` (or 0 after an integration-only step).
- `system_prompt_for_actions()` from `providers/claude/prompt.rs`, with an optional appended line: `The user's own Gmail address is <email>...` if `gmail::user_email()` is set.

Agent system prompt (verbatim from `system_prompt_for_actions`):
> You are peeky's multi-step task executor. The user gave a voice request that needs two or more chained actions, e.g. "open YouTube, search for X, play the top result" or "check my email then read the latest one to me." Simpler single-step requests get routed elsewhere before they reach you.
>
> Tools available: the `computer` tool (mouse_move, left_click, type, key, scroll), `open_url`, `launch_app`, `switch_to_window`, and integration tools (gmail_*, spotify_*, github_*, youtube_*). Each tool's description explains when to call it. Read the descriptions, don't guess.
>
> CRITICAL: never call action="screenshot" on the computer tool. A fresh screenshot is attached to every tool_result. Calling screenshot wastes ~6 seconds of latency and produces no new information.
>
> Planning loop:
> - Emit only the tools needed for the CURRENT step. After they run, you'll see a fresh screenshot and the tool_results, then pick the next step.
> - When the whole task is done, respond with plain text under 100 words to end the chain. That text gets spoken aloud.
> - No preamble. No "I'll open that for you" narration. Just call the tools.
>
> Prefer deep-link URLs over UI navigation. "Open YouTube, search for dogs" should be ONE `open_url` call to https://www.youtube.com/results?search_query=dogs, NOT open_url home then click + type. Known search patterns:
>   - YouTube: `https://www.youtube.com/results?search_query=<q>`
>   - Google: `https://www.google.com/search?q=<q>`
>   - GitHub: `https://github.com/search?q=<q>`
>   - Spotify: `https://open.spotify.com/search/<q>`
>   - Wikipedia: `https://en.wikipedia.org/wiki/<Title_With_Underscores>`
>   - Amazon: `https://www.amazon.com/s?k=<q>`
> URL-encode spaces as + or %20. Fall back to click + type only when no deep-link pattern exists for the target.

Initial user text (appended after the screenshot block, formatted per turn):
> The user said: "<transcript>".
>
> Currently-running app window classes (from Hyprland): <list>.
>
> Tool preference order for actions targeting an app:
> 1. SERVICE-SPECIFIC INTEGRATION TOOLS FIRST (e.g. spotify_play, spotify_pause, gmail_search, gmail_read, gmail_send, gmail_unread_count). These let you access the service's data and actions directly via API, regardless of what is visible on screen. Dramatically faster than visual automation: one tool call vs. 5-10 steps of click+type. If a gmail_ or spotify_ tool exists for what the user is asking for, USE IT, even if the screen shows something unrelated like a terminal. Do NOT tell the user you cannot access their email/music when these tools are available; just call the tool.
> 2. If no integration tool exists and the target app IS in the running list above, prefer switch_to_window to focus it and interact via click+type.
> 3. If no integration tool exists and the app is NOT running, use launch_app to start it (or open_url for web services).
> 4. open_url is for pure web destinations: sites without a desktop app, or when the user explicitly says "in the browser".
>
> Pick the best action(s) and invoke their tools. If the request needs multiple steps, call multiple tools across iterations (you'll get a fresh screenshot after each batch). When the task is fully done, respond with plain text and no tool calls to end the chain.

---

## 4. Tool catalog (v0.1.10 binary)

Enumerated from `strings /Users/wowdd1/Downloads/Peeky.app/Contents/MacOS/peeky`. The shipping binary carries the following integration modules present: `apps`, `calendar`, `contacts`, `gmail`, `health` (probe-only), `safari`, `shortcuts`, `spotlight`. The strings additionally include tool schemas for tools whose descriptions were compiled in even though their modules were not wired into `all_tools()` in the runtime `main` at that snapshot -- notably every `music_*`, `mail_*`, `keynote_*`, `spotify_*`, `youtube_*`, `photos_*`, `notes_*`, `reminders_*`, `messages_*`, `finder_*`, `facetime_*`, `maps_*`, `clipboard_*`, `type_text`, and `system_*` string is present verbatim, plus the `gh_*` GitHub set.

Descriptions below are literal excerpts from `.rodata`; input schemas are inferred from surrounding property strings in the same segment.

### Universal computer + browser + app tools (from find_action / agent)

| Name | Description | Input schema | Backing |
|---|---|---|---|
| `computer` (Anthropic Computer Use v2 `computer_20250124`) | mouse_move / left_click / type / key / scroll | Anthropic-defined | macOS CGEvent (`objc2-core-graphics`) |
| `open_url` | Open a fully-qualified https:// URL in the default browser. | `{ "url": string }` req `url` | macOS `open` command |
| `launch_app` | Launch a desktop application by name (e.g. 'spotify'). | `{ "app": string }` req `app` | macOS `open -a` |
| `switch_to_window` | Focus an already-running app by window class or title substring. | `{ "target": string }` req `target` | no-op on macOS in v0.1.10 (Hyprland-only implementation) |

### App control (`apps.rs`)

| Name | Description | Input schema | Backing |
|---|---|---|---|
| `app_open` | Open (launch or bring to front) a macOS application by name. Use for 'open slack', 'launch zoom', 'switch to chrome'. | `{ "app": string }` req `app` -- "The application name as it appears in /Applications, e.g. 'Slack', 'Google Chrome'." | AppleScript / `open -a` |
| `app_quit` | Quit a running macOS application by name. Use for 'quit zoom', 'close spotify'. | `{ "app": string }` req `app` -- "The application name, e.g. 'Zoom', 'Spotify'." | AppleScript |
| `app_list_running` | List the names of all running apps with a visible UI. Use for 'what apps are open', 'what's running'. | `{}` | AppleScript `System Events` |

### Apple Mail (`mail.rs`)

| Name | Description | Input schema | Backing |
|---|---|---|---|
| `mail_send` | Send an email from Apple Mail. Use for 'email dan the notes'. The recipient must be an email address; resolve a contact name with contacts_lookup first. This sends immediately. | `{ "to": string, "subject": string, "body": string }` all required | AppleScript `tell application "Mail" ... make new outgoing message` |
| `mail_unread_count` | Get the number of unread emails in the Apple Mail inbox. Use for 'how many unread emails do I have'. | `{}` | AppleScript `tell application "Mail" to get unread count of inbox` |

### Apple Maps (`maps.rs`)

| Name | Description | Input schema | Backing |
|---|---|---|---|
| `maps_directions` | Open Apple Maps with directions to a destination from the current location. Use for 'directions to the airport', 'navigate to 123 main street'. | `{ "destination": string }` req -- "Address or place name, e.g. 'Boston Logan Airport'." | URL scheme `maps://?daddr=` |
| `maps_search` | Search Apple Maps for a place. Use for 'find coffee near me', 'show thai restaurants on the map'. | `{ "query": string }` req -- "What to search for, e.g. 'coffee'." | URL scheme `maps://?q=` |

### Gmail (`gmail.rs`, OAuth 2.0)

Backing: direct HTTP against `https://gmail.googleapis.com/gmail/v1/users/me/...`. OAuth flow requires `PEEKY_GMAIL_CLIENT_ID` + `PEEKY_GMAIL_CLIENT_SECRET`. Auth endpoint `https://accounts.google.com/o/oauth2/auth`, token endpoint `https://oauth2.googleapis.com/token`. Scopes: `gmail.readonly`, `gmail.modify`, `gmail.compose`, `gmail.send`. Refresh tokens cached locally.

| Name | Description | Input schema |
|---|---|---|
| `gmail_search` | Search the user's Gmail inbox via the Gmail API. Works regardless of what window is visible on screen. ALWAYS use this when the user asks about their email/mail/inbox, even if no email client is open. Gmail query syntax: 'from:alice', 'subject:report', 'is:unread', 'has:attachment', 'newer_than:7d', etc. Combine with spaces. Returns a JSON array of {id, threadId, from, subject, snippet, date}. | `{ "query": string, "max_results"?: integer (default 10, cap 25) }` req `query` |
| `gmail_read` | Fetch the full content of one Gmail message by ID. Use after gmail_search returns hits, with the id from a result. Returns from/to/cc/subject/date/body. | `{ "id": string }` req `id` |
| `gmail_send` | Send a real email from the user's Gmail. Goes out immediately. For drafts use gmail_draft instead. | `{ "to": string, "subject": string, "body": string, "cc"?: string }` req to/subject/body |
| `gmail_draft` | Save an email as a Gmail draft without sending. Use when the user says 'draft', 'compose', or wants to review before sending. | Same shape as `gmail_send` |
| `gmail_unread_count` | Return the user's Gmail INBOX unread count. Works regardless of what is on screen. Use for 'do I have new mail?' / 'how many unread?' queries. | `{}` |
| `gmail_mark_read` | Mark a Gmail message as read (remove the UNREAD label). | `{ "id": string }` req `id` |
| `gmail_archive` | Archive a Gmail message (remove from INBOX, keeps in All Mail). | `{ "id": string }` req `id` |

### GitHub (`github.rs`, via `gh` CLI)

Backing: shells out to `gh` (`which gh` gates `is_available`). Uses `gh --json` for structured output.

| Name | Description | Input schema |
|---|---|---|
| `gh_my_prs` | List the user's pull requests across ALL of GitHub (not just one repo). Use for 'show me my PRs', 'do I have open pull requests', 'what's pending review'. Returns id/title/repo/state/url/createdAt for each match. | `{ "state"?: string (default "open"), "limit"?: integer (default 10, cap 25) }` |
| `gh_pr_view` | Fetch detailed info about a specific pull request: body, state, status checks, reviews, diff size. Use after gh_my_prs returns a hit, or when the user names a specific PR. | `{ "repo": string ("owner/name"), "number": integer }` req both |
| `gh_my_issues` | List the user's issues across ALL of GitHub. Use for 'what issues do I have open', 'show me my GitHub issues'. | `{ "state"?: string, "limit"?: integer }` |
| `gh_issue_view` | Fetch detailed info about a specific GitHub issue: body, state, labels, comment count. | `{ "repo": string, "number": integer }` req both |
| `gh_actions_status` | Get the last 5 GitHub Actions workflow runs for a repo. Use for 'is CI passing for X', 'what's the build status of X'. | `{ "repo": string }` req |
| `gh_notifications` | Fetch the user's GitHub notification inbox: review requests, mentions, CI failures, etc. Use for 'do I have GitHub notifications', 'any review requests'. | `{ "limit"?: integer (default 10, cap 25) }` |
| `gh_repo_view` | Summary of a GitHub repository: name, description, stars, default branch, visibility. | `{ "repo": string }` req |

### Apple Music (`music.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `music_play` | Resume playback in Apple Music. Use for 'play' / 'resume' when the user means Apple Music. | `{}` |
| `music_pause` | Pause Apple Music playback. | `{}` |
| `music_next` | Skip to the next track in Apple Music. | `{}` |
| `music_previous` | Go back to the previous track in Apple Music. | `{}` |
| `music_current_track` | Get the name and artist of the track now playing in Apple Music. Use for 'what song is this'. | `{}` |
| `music_play_track` | Search the user's Apple Music library for a track by name and play the first match. Library only, not the streaming catalog. Use for 'play bohemian rhapsody on apple music'. | `{ "query": string }` req -- "Part of the track name, e.g. 'bohemian rhapsody'." |

### Notes (`notes.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `notes_create` | Create a note in the Notes app. Use for 'make a note', 'note that X', 'write down Y'. | `{ "text": string }` req -- "The note content. The first line becomes the title." |

### Finder (`finder.rs`)

| Name | Description | Input schema |
|---|---|---|
| `finder_open` | Open a file or folder in Finder. A folder opens as a Finder window, a file opens in its default app. Use for 'open my downloads folder', 'open that pdf'. | `{ "path": string }` req -- "Absolute POSIX path, e.g. /Users/me/Downloads. A leading ~ is expanded." |
| `finder_reveal` | Reveal (select) a file or folder in a Finder window without opening it. Use for 'show me that file in finder', 'where is this file'. | `{ "path": string }` req |
| `finder_trash` | Move a file or folder to the Trash (reversible, does not empty the Trash). Use for 'delete that file', 'trash the old build'. | `{ "path": string }` req |

### Photos (`photos.rs`)

| Name | Description | Input schema |
|---|---|---|
| `photos_show_album` | Open the Photos app and show an album by name. Use for 'show me my vacation photos', 'open the dogs album'. | `{ "album": string }` req -- "The album name, e.g. 'Vacation 2025'." |

### Safari (`safari.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `safari_open_url` | Open a URL in Safari (new tab). Use when the user wants to visit or open a website, e.g. 'open github', 'go to nytimes.com'. | `{ "url": string }` req -- "The full URL including scheme, e.g. https://github.com" |
| `safari_current_tab` | Get the URL and title of the active Safari tab. Use for 'what page am I on', 'what is this tab'. | `{}` |
| `safari_list_tabs` | List title and URL of every open tab in the front Safari window. Use for 'what tabs do I have open'. | `{}` |
| `safari_close_tab` | Close the active Safari tab. | `{}` |

### System (`system.rs`, AppleScript + shell)

| Name | Description | Input schema |
|---|---|---|
| `system_set_volume` | Set system output volume, 0 (silent) to 100 (max). Use for 'turn it up', 'turn it down', 'set volume to 50'. | `{ "level": integer 0..100 }` req |
| `system_mute` | Mute system audio output. | `{}` |
| `system_unmute` | Unmute system audio output. | `{}` |
| `system_dark_mode` | Switch system appearance. Use for 'turn on dark mode', 'switch to light mode', 'toggle dark mode'. 'on' is dark, 'off' is light, 'toggle' flips. | `{ "mode": "on" \| "off" \| "toggle" }` req |
| `system_sleep` | Put the Mac to sleep. Use for 'go to sleep', 'sleep my mac'. | `{}` |
| `system_screensaver` | Start the screen saver, locks the screen when password-on-wake is set. | `{}` |
| `system_notify` | Post a macOS notification. | `{ "title": string, "message": string }` req both |
| `system_keep_awake` | Keep the Mac awake for N minutes. Use for 'don't sleep for an hour', 'don't let the screen sleep'. | `{ "minutes": integer 1..1440 }` req -- via `caffeinate` |
| `system_allow_sleep` | Cancel a previous keep-awake and let the Mac sleep normally again. Use for 'let my mac sleep again'. | `{}` -- kills `caffeinate` |
| `system_wifi` | Turn Wi-Fi on or off. Use for 'turn off wifi', 'turn wifi back on'. true for on, false for off. | `{ "on": boolean }` req -- via `networksetup -setairportpower` |
| `system_set_wallpaper` | (Referenced in error strings: `system_set_wallpaper missing 'path' field`.) | `{ "path": string }` req |

### Reminders (`reminders.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `reminders_add` | Add a reminder. Use for 'remind me to X', 'add a reminder Y'. | `{ "text": string }` req -- "The reminder text, e.g. 'buy milk'." |

### Calendar (`calendar.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `calendar_add_event` | Add an event to the calendar, starting a given number of minutes from now. Use for 'add a meeting in an hour', 'block 30 minutes for lunch'. Only relative times are supported. | `{ "title": string, "offset_minutes": integer, "duration_minutes"?: integer (default 60) }` req title/offset_minutes |
| `calendar_list_today` | List today's calendar events (title and start time) across all calendars. Use for 'what's on my calendar', 'what do I have today'. | `{}` |

### Contacts (`contacts.rs`)

| Name | Description | Input schema |
|---|---|---|
| `contacts_lookup` | Look up a person in Contacts by (partial) name and get their phone numbers and email addresses. Use before messages_send or mail_send when the user names a person, e.g. 'text mom' or 'email dan'. | `{ "name": string }` req -- "Full or partial contact name, e.g. 'mom', 'Dan Brooks'." |

### FaceTime (`facetime.rs`)

| Name | Description | Input schema |
|---|---|---|
| `facetime_call` | Start a FaceTime call (the user confirms in FaceTime before it dials). Use for 'facetime mom', 'call dan on facetime'. The recipient must be a phone number or email handle; resolve a contact name with contacts_lookup first. | `{ "recipient": string, "audio_only"?: boolean (default false) }` req `recipient` -- URL schemes `facetime://` and `facetime-audio://` |

### Messages / iMessage (`messages.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `messages_send` | Send an iMessage. Use for 'text mom I'm on my way', 'message dan the address'. The recipient must be a phone number or email handle; resolve a contact name with contacts_lookup first. This sends immediately. | `{ "recipient": string, "body": string }` req both |

### Shortcuts (`shortcuts.rs`)

| Name | Description | Input schema |
|---|---|---|
| `shortcuts_run` | Run one of the user's Shortcuts by exact name, in the background. Use when the user names a shortcut, e.g. 'run my morning routine shortcut'. Use shortcuts_list first if unsure of the exact name. | `{ "name": string, "input"?: string }` req `name` |
| `shortcuts_list` | List the names of all the user's Shortcuts. Use for 'what shortcuts do I have', or to find the exact name before shortcuts_run. | `{}` |

### Spotlight (`spotlight.rs`, `mdfind -name`)

| Name | Description | Input schema |
|---|---|---|
| `spotlight_search` | Search files by name with Spotlight. Use for 'find that tax pdf', 'where is my resume'. Returns up to 10 matching paths; follow up with finder_reveal or finder_open on the right one. | `{ "name": string }` req -- "Part of the file name, e.g. 'resume' or 'tax 2025'." |

### Keynote (`keynote.rs`, AppleScript)

| Name | Description | Input schema |
|---|---|---|
| `keynote_start` | Start presenting the frontmost Keynote document. Use for 'start presentation', 'present my slides'. | `{}` |
| `keynote_next` | Advance to the next slide or build in the running Keynote presentation. Use for 'next slide'. | `{}` |
| `keynote_previous` | Go back to the previous slide in the running Keynote presentation. Use for 'previous slide', 'go back a slide'. | `{}` |
| `keynote_stop` | Stop the running Keynote presentation. Use for 'stop presenting', 'end the slideshow'. | `{}` |

### Clipboard (`clipboard.rs`)

| Name | Description | Input schema |
|---|---|---|
| `clipboard_read` | Read the current text on the macOS pasteboard. | `{}` |
| `clipboard_write` | Replace the macOS pasteboard with the provided text. | `{ "text": string }` req |

### Type text (`type_text.rs`)

| Name | Description | Input schema |
|---|---|---|
| `type_text` | Type text into the currently focused field via CGEvent. Distinct from the `computer.type` action; used when the intent already picked "type this exact text". | `{ "text": string }` req |

### Spotify (`spotify.rs`, requires `spotify_player` CLI on PATH + Premium)

Backing: shells out to `spotify_player` (Rust CLI, OAuth via `spotify_player authenticate`).

| Name | Description | Input schema |
|---|---|---|
| `spotify_play` | Search Spotify and play the top result. Use for ANY 'play X on Spotify' / 'play song X' intent when the user has Spotify installed. Dramatically faster than visually clicking through the Spotify UI. query can be song name, artist, album, or a combination (e.g. 'sicko mode travis scott'). Requires Spotify Premium. | `{ "query": string }` req |
| `spotify_pause` | Pause Spotify playback. | `{}` |
| `spotify_resume` | Resume Spotify playback after pause. | `{}` |
| `spotify_next` | Skip to the next track on Spotify. | `{}` |
| `spotify_previous` | Go to the previous track on Spotify. | `{}` |

### YouTube (`youtube.rs`, requires `yt-dlp` on PATH)

Backing: `yt-dlp` resolves search -> video ID; then `open` on the resulting URL.

| Name | Description | Input schema |
|---|---|---|
| `youtube_play` | Search YouTube and open the top video in the user's browser. Dramatically faster than navigating youtube.com and clicking through search results: yt-dlp resolves the video ID server-side and the browser opens directly on the video, NOT on youtube.com/results?search_query=X. | `{ "query": string }` req |

---

## 5. Memory system

Path (`providers/claude/memory.rs`):
- File: `<config_dir>/peeky/memory.jsonl` (macOS: `~/Library/Application Support/peeky/memory.jsonl`).
- Format: one JSON object per line: `{ "key": <lowercase snake_case>, "value": <literal string>, "ts": "epoch:<seconds>" }`.
- Load: read entire file on startup, malformed lines silently skipped, latest write wins per key.
- Write: append-only. `store_fact` opens with `create(true).append(true)`, writes one line, and updates the in-memory `Vec<(key, value)>` slot.
- Injection: `MemoryStore::as_prompt_block()` renders `- {key}: {value}\n` lines, injected as a system block with `cache_control: ephemeral` on Chat / Integration / Agent turns.
- Router: see section 3.4. Tool call decides `store_fact` vs `recall_fact` vs `recall_conversation`.

### Redaction (`routelet/redact.rs`)

Applied identically on training and inference (no train/serve skew) BEFORE anything reaches the classifier or the sample log.

Rules:
1. Lowercase, strip trailing `.!?` and whitespace (retain question-mark state).
2. `password|passcode|pin|ssn|secret|token|api\s*key|api\s*secret|credit card|card number\b.*$` -> `<keyword> <SECRET>` (case-insensitive).
3. Email regex `(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}` -> `<EMAIL>`.
4. Digit runs `\b\d{4,}\b` -> `<NUM>`.
5. Memory-only assign-cue: after preprocess, on `Memory` intent, `\b(is|are|=|equals)\b\s+\S.*$` -> `<verb> <SECRET>` (masks "my name is Daniel", etc.).
6. `redact_intent(routelet_pred, claude_label)` picks Memory whenever either classifier picks Memory (least-redaction wins for Memory intent).

Applied for offline distillation sample logging (`sample.rs`), which optionally uploads redacted pairs to the proxy.

---

## 6. Routelet detailed spec

Files shipped:
- `models/routelet/embedder.onnx` -- 127 MB, opset 14, BERT-mini int8-dynamic-quantized.
- `models/routelet/tokenizer.json` -- 695 KB, HuggingFace WordPiece.
- `models/routelet/head.json` -- 51 KB, logistic-regression head.

Inputs to the ONNX graph: three i64 tensors of shape `[1, seq]` from the tokenizer:
- `input_ids`
- `attention_mask`
- `token_type_ids`

Tokenizer configuration (from `tokenizer.json`):
- `model.type = WordPiece`
- vocab size 30522 (bert-base uncased vocab)
- `normalizer.type = Sequence`
- `pre_tokenizer.type = BertPreTokenizer`
- `truncation: { direction: "Right", max_length: 512, strategy: "LongestFirst", stride: 0 }`
- `encode(text, add_special_tokens=true)` prepends `[CLS]` and appends `[SEP]`.

Output: `embedding` f32 of shape `[1, 384]`, L2-normalized.

Head (from `head.json`):
- `coef`: `f32[5][384]`
- `intercept`: `f32[5] = [0.006229, -0.007656, -0.019651, 0.009143, 0.011936]`
- `labels`: `["chat", "find_action", "integration", "memory", "none"]`
- `temperature`: `1.0`

Note: `agent` is NOT in labels (it is a cue-only intent).

Classify math (from `head_predict_with_confidence`):
```
logits[c] = dot(coef[c], embedding) + intercept[c]
logits[c] /= temperature
softmax with subtract-max stabilization
argmax -> (label, softmax_prob)
```

Gate: `ROUTELET_CONFIDENCE_THRESHOLD = 0.95` AND label != `none`. Below either -> defer to Claude classifier.

Distillation loop (`routelet/sample.rs`):
- Every classified turn logs `{redacted_transcript, routelet_pred, routelet_conf, claude_label}` locally.
- Optional uploader batches up to `ROUTELET_UPLOAD_BATCH_MAX = 32` per wakeup and POSTs to a proxy endpoint.

---

## 7. Screenshot + AI cursor

### Screenshot (`screenshot/crossplatform.rs`, macOS path)

Uses the `xcap` crate exclusively -- no direct `CGWindowList` or `ScreenCaptureKit` calls in shipping code.

- `active_workspace_geometry()`: `xcap::Monitor::all()` -> pick `is_primary()`, return `(x, y, width, height)` in logical points. Warns once at startup if `scale_factor != 1.0` because CGEvent clicks use logical points.
- `capture_resized_for_claude(x, y, w, h, target_w, target_h)`:
  1. `xcap::Monitor::from_point(x, y)` -> capture region.
  2. Convert RGBA -> RGB (drop alpha).
  3. Resize via `fast_image_resize::Resizer` with `Bilinear` convolution.
  4. JPEG encode at quality 85 (`JpegEncoder::new_with_quality(_, 85)`).
  5. Base64 encode.
- Permission gate: `ensure_screen_recording_access()` calls `CGPreflightScreenCaptureAccess()` then `CGRequestScreenCaptureAccess()` from `objc2-core-graphics`. `open_screen_recording_settings()` shells out `open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.

### `pick_declared_resolution` (`screenshot/shared.rs`)

Anthropic Computer Use recommends one of three input resolutions. Peeky picks whichever ratio best matches the source and never scales up:

| Candidate | Aspect |
|---|---|
| 1024x768 | 4:3 |
| 1280x800 | 16:10 |
| 1366x768 | 16:9 |

Compute `abs(width/height - ratio)` for each, pick min. Default fallback is 1280x800 (16:10).

### AI cursor overlay (`ai_cursor/macos.rs` + `winit.rs` + `renderer.rs` + `painter.rs`)

macOS overlay is a `winit` window with `wgpu` pixel presentation (softbuffer strips alpha on macOS, so wgpu is required for transparency).

Configuration highlights:
- Window sized to the union bounding box of all monitors (spans displays).
- `setOpaque:NO`, `backgroundColor = NSColor clearColor`.
- `setIgnoresMouseEvents:YES` (click-through).
- `setLevel:NSScreenSaverWindowLevel (1000)`.
- `setHidesOnDeactivate:NO`, `setHasShadow:NO`.
- `collectionBehavior = CanJoinAllSpaces | Stationary | IgnoresCycle | FullScreenAuxiliary` (`1 | 16 | 64 | 256`).
- Fullscreen deliberately avoided (macOS puts fullscreen windows in their own opaque Space).

Cursor states:
```rust
pub enum CursorState { Idle, Listening, Thinking }
```

- `Idle`: default sprite.
- `Listening`: 5-bar animated soundwave, colour `(1.00, 0.55, 0.00, 0.95)`, height driven by mic RMS via `painter::AUDIO_LEVEL_SOURCE` (`f32::from_bits` on an `AtomicU32`).
- `Thinking`: rotating loading animation.

`ai_cursor::point_at(x, y)` moves the overlay to `(x, y+10)` (offset to visually center on UI elements).

### `painter.rs`

Backend abstraction over `tiny_skia::Pixmap` (winit path) and `cairo` (Hyprland path). Renders three states:
- **Cursor sprite**: PNG decoded via `Pixmap::decode_png`, scaled with `PEEKY_CURSOR_SCALE` (0.5-4.0 env override) for demo recordings.
- **Soundwave**: N=5 bars, `BAR_WIDTH=3.0`, `BAR_GAP=1.5`, `MIN_HEIGHT=6.0`, `MAX_HEIGHT=28.0`, `CORNER_RADIUS=1.5`, 3 sine harmonics `(1.5, 0.0, 0.55)`, `(3.1, 1.0, 0.30)`, `(5.7, 2.4, 0.15)`, bell-curve shape floor 0.4, scroll speed 0.7.
- **Loading spinner**: rotating dot ring.

All three states share `overlay_scale()` so demo footage remains legible.

---

## 8. Console binary (`Contents/MacOS/console`)

Framework: Tauri 2.11.2 + tao 0.35.2 + muda 0.19.1 + wry. This is the app's tray/settings/onboarding UI shell and it is the actual `CFBundleExecutable` (Info.plist).

Responsibilities identified from strings:
- Spawns and monitors `peeky`. Search paths tried in order: `PEEKY_CONSOLE_BIN` env, `../../target/{debug,release}/peeky`, `target/{debug,release}/peeky`, and (in bundled builds) the sibling binary at `Contents/MacOS/peeky`.
- Sets `PEEKY_ROUTELET_DIR` to `../Resources/models/routelet` (or fallbacks `resources/models/routelet`, `../../models/routelet`, `models/routelet`).
- Runs `peeky integrations-status` on demand and displays results.
- Onboarding / invite-code entry: `console/src-tauri/src/invite.rs`. Regex validation `/^[A-Z0-9][A-Z0-9-]{6,62}[A-Z0-9]$/`. Writes accepted code to `<config>/peeky/invite_code`.
- Invite verification POST: `https://<AEGIS_PROXY_HOST>/v1/invite/verify` with `x-peeky-device-id` and `x-peeky-invite-code`. Handles `invalid invite code` / `invalid invite code format` / `Couldn't reach the server. Check your connection.` errors.
- Sign-in flow: hits `https://<AEGIS_PROXY_HOST>/auth/github/session?state=<state>`. Response fields `token` + `email`. On success writes `<config>/peeky/session_jwt` (0600 permissions on Unix) and `<config>/peeky/session_email`. Errors: `sign-in timed out, try again`, `sign-in link expired, try again`, `sign-in failed: empty token`.
- Uses `objc2-app-kit` `NSMenuItem` / `activateIgnoringOtherApps:` -> menu-bar tray icon (via `muda`), can `performWindowDragWithEvent:` for custom titleless windows.
- Bundles a HTML/JS webview inside Tauri's `__TAURI_INTERNALS__.invoke(...)` bridge for the settings UI.
- Purpose summary: onboarding (invite entry OR GitHub OAuth via the proxy), tray settings, spawning/supervising `peeky`, showing integration health.

---

## 9. System permissions

Info.plist declares:
- `NSMicrophoneUsageDescription = "Peeky needs microphone access for voice commands"`
- `NSScreenCaptureUsageDescription = "Peeky needs screen recording to see what you are working on"`
- `LSUIElement = true` (no Dock icon)
- `LSMinimumSystemVersion = 10.13`

Runtime permission demands beyond those two (from source):
- **Accessibility (`AXIsProcessTrusted`)** -- not explicitly triggered in `main.rs`, but CGEvent posting (mouse click, keyboard synthesis via `CGEvent::keyboard_set_unicode_string`, key combos via `CGEventFlags`) is silently blocked by TCC unless the user grants Accessibility. `actions::check_input_injection_available()` runs at startup to surface this.
- **Contacts** -- required by `contacts_lookup` (uses macOS AddressBook framework via AppleScript). No Info.plist string ships; TCC will prompt on first call. This is a gap.
- **Calendar / Reminders** -- `calendar_add_event`, `calendar_list_today`, `reminders_add` use AppleScript. TCC prompts on first call. No Info.plist strings.
- **Apple Events / Automation** -- required to control Music, Mail, Safari, Notes, Messages, FaceTime, Keynote, Photos, Spotify (via `spotify_player` CLI hopping through AppleScript is not used, but Music/Mail/Safari/etc. all are). macOS will prompt "Peeky wants to control Music.app" per target on first call.
- **Input Monitoring** -- global hotkey via `global-hotkey` crate. Ctrl+Space registration works on macOS without this permission because global-hotkey uses Carbon RegisterEventHotKey, but see below.
- **Full Disk Access** -- not required; nothing reads protected directories.
- **Notifications** -- `system_notify` uses AppleScript display notification (implicit permission on macOS 10.14+).

Screen Recording is explicitly prompted at launch (`ensure_screen_recording_access` -> `CGRequestScreenCaptureAccess`); microphone is triggered via `audio::trigger_mic_permission()`.

---

## 10. Bundled resources

`Peeky.app/Contents/Resources/`:

| Path | Size | Purpose | Required at runtime? |
|---|---|---|---|
| `icon.icns` | 116 KB | Dock/menu-bar icon | Yes |
| `models/routelet/embedder.onnx` | 127 MB | BERT-mini int8 embedder | Yes (routelet load fails startup otherwise) |
| `models/routelet/tokenizer.json` | 695 KB | WordPiece tokenizer + normalizer + max_length=512 | Yes |
| `models/routelet/head.json` | 51 KB | 5x384 coef + intercept + labels + temperature | Yes |

`Peeky.app/Contents/MacOS/`:

| Path | Size | Purpose | Required? |
|---|---|---|---|
| `console` | ~10 MB | Tauri tray/settings/onboarding UI, spawns `peeky` | Yes (this is CFBundleExecutable) |
| `peeky` | ~30 MB | Voice loop binary | Yes |

**Runtime-external artifacts (not bundled)**:
- Deepgram JWT: minted per-session via `POST https://<AEGIS_PROXY_HOST>/v1/deepgram/token` (proxy mode) OR `DEEPGRAM_API_KEY` env (direct mode).
- Cartesia JWT: minted per-session via `POST https://<AEGIS_PROXY_HOST>/v1/cartesia/token` (proxy) OR `CARTESIA_API_KEY` env.
- Anthropic key: `x-peeky-device-id: <UUID>` header (proxy) OR `ANTHROPIC_API_KEY` env (direct).
- Gmail OAuth: `PEEKY_GMAIL_CLIENT_ID` + `PEEKY_GMAIL_CLIENT_SECRET` env vars; refresh tokens cached at `<config>/peeky/gmail_token`.
- Session JWT (proxy account tier): `<config>/peeky/session_jwt`, written by console after GitHub OAuth.
- Invite code: `<config>/peeky/invite_code`.
- Device ID: `<config>/peeky/device_id` (UUID v4, auto-generated first run).
- Memory store: `<config>/peeky/memory.jsonl`.
- Handoff (one-shot): `<config>/peeky/handoff.md`, written by `/peeky` Claude Code command, consumed and deleted on startup.
- No local model download at runtime. All models are shipped in the bundle.
- No fonts / no PNG cursor sprites are shipped separately in `Resources/`; the cursor sprite must be compiled into the peeky binary (`Pixmap::decode_png(bytes)` from a `&[u8]` constant).

Config dir on macOS: `~/Library/Application Support/peeky/` (`dirs::config_dir()`).

---

## Appendix A: Endpoints

| Endpoint | Method | Notes |
|---|---|---|
| `https://<AEGIS_PROXY_HOST>/v1/anthropic/messages` | POST | All Claude calls (proxy) |
| `https://<AEGIS_PROXY_HOST>/v1/deepgram/token` | POST | STT JWT mint |
| `https://<AEGIS_PROXY_HOST>/v1/cartesia/token` | POST | TTS JWT mint |
| `https://<AEGIS_PROXY_HOST>/v1/invite/verify` | POST | Console invite check |
| `https://<AEGIS_PROXY_HOST>/auth/github/session?state=X` | GET | Console sign-in polling |
| `https://api.deepgram.com/v1/listen` | WSS | STT stream, `model=nova-3`, `linear16` |
| `https://api.cartesia.ai/tts/...` | POST SSE | Model `sonic-2`, 24 kHz mono PCM, voice `a0e99841-438c-4a64-b679-ae501e7d6091` |
| `https://api.anthropic.com/v1/messages` | POST | Direct mode only |
| `https://gmail.googleapis.com/gmail/v1/users/me/...` | GET/POST | Gmail integration |
| `https://accounts.google.com/o/oauth2/auth` | (browser) | Gmail OAuth start |
| `https://oauth2.googleapis.com/token` | POST | Gmail OAuth token exchange |

## Appendix B: Proxy contract headers

- `x-peeky-device-id`: per-install UUID v4 (always sent in proxy mode).
- `x-peeky-invite-code`: optional, upgrades user to demo tier.
- `Authorization: Bearer <session_jwt>`: optional, upgrades to account tier.
- `x-peeky-force-exhausted`: dev-only, triggered by env `PEEKY_FORCE_EXHAUSTED=1`, makes proxy return the "budget exhausted" response with no upstream call.
- Invite code regex: `^[A-Z0-9][A-Z0-9-]{6,62}[A-Z0-9]$` (8-64 chars).

## Appendix C: v0.1.10 vs source-main integration delta

The user-provided background says v0.1.10 wired 8 integrations vs source-main's 26. The `strings` dump shows the shipping binary embeds tool DESCRIPTIONS for effectively every integration (all 24 tools' description strings + input-field error messages), but the runtime `is_available()` gates decide which appear in Claude's tools array. In v0.1.10, `[integration:...]` startup log tags only fire for `gmail`, `spotify`, `youtube`, and the `health` probe additionally checks `github`. Verified module symbols present in the binary via `strings ... | grep -oE 'integrations/[a-z_]+\.rs'`:

```
integrations/apps.rs
integrations/calendar.rs
integrations/contacts.rs
integrations/gmail.rs
integrations/health.rs
integrations/safari.rs
integrations/shortcuts.rs
integrations/spotlight.rs
```

The remaining modules (facetime, finder, keynote, mail, maps, messages, music, notes, photos, reminders, spotify, system, type_text, youtube, clipboard, github, applescript) have their tool description strings in `.rodata` but the module file names do not appear in the binary's panic-path debug strings. That suggests either they were compiled in but had all `is_available()` return false at boot (e.g. gated on env vars or CLI presence), OR they were compiled but dead-stripped and only string constants survived. Either way, from a black-box standpoint the shipping tool surface for any given user depends on which of the following are installed / configured:

- `gh` CLI in PATH -> GitHub tools appear.
- `spotify_player` CLI in PATH -> Spotify tools appear.
- `yt-dlp` in PATH -> YouTube tool appears.
- `PEEKY_GMAIL_CLIENT_ID` + `PEEKY_GMAIL_CLIENT_SECRET` env -> Gmail tools appear.
- macOS host -> all AppleScript-based tools would be available if wired.

---

## 11. Hidden network / paid calls audit

Full enumeration of every outbound HTTP(S)/WSS endpoint reachable from `peeky` and `console`, obtained by cross-checking `grep -REn "https?://"` in the source with `strings` on both binaries.

### 11.1 Third-party telemetry / analytics / crash reporters

**None.** Grepped source and both binaries for `sentry|posthog|amplitude|mixpanel|bugsnag|crashlytics|firebase|honeycomb|datadog|newrelic|rollbar|telemetry|analytics|segment.io|umami|plausible`: zero real hits. `sample.rs` contains one code-comment mention of the word "telemetry" ("delays telemetry, never a voice turn") describing the routelet distillation uploader, which is a different mechanism (see 11.4).

### 11.2 Update / version / self-update checks

**None.** No `Sparkle`, no `tauri-plugin-updater`, no `check_for_update`, no `latest_version`, no update-manifest URL. Grepped: `check_for_update|update_url|latest_version|self_update|autoupdate|Sparkle|feed\.xml|appcast` -> zero. The Tauri console binary does NOT link the updater plugin (no `tauri-plugin-updater` symbols, no update endpoint strings).

### 11.3 License / entitlement / subscription

Peeky has a tier system (trial / demo / account) but there is **no dedicated license or entitlement endpoint**. Tier is inferred by the proxy from the three request headers (`x-peeky-device-id`, `x-peeky-invite-code`, `Authorization: Bearer <session_jwt>`) on every Claude call. There is no separate subscription-status query, no periodic heartbeat, no receipt validation.

Trial-exhausted handling (`upgrade.rs`): only triggered by an HTTP error body from `/v1/anthropic/messages` carrying a specific error code. On trigger, `run_oauth_flow()` opens the browser to `https://<AEGIS_PROXY_HOST>/auth/github/start?state=<uuid>` and polls `https://<AEGIS_PROXY_HOST>/auth/github/session?state=<uuid>` every 1.5s for up to ~2 minutes. Only fires once per process, only after an actual budget-wall response, and only if the user is not already signed in. No proactive polling.

### 11.4 Routelet distillation uploader (opt-in, off by default)

- Endpoint: `https://<AEGIS_PROXY_HOST>/v1/routelet/sample` (POST).
- Constant: `SAMPLE_URL` in `providers/routelet/sample.rs`.
- Trigger: **BOTH** `PEEKY_ROUTELET_UPLOAD=1` env var AND `init_uploader()` having been called at startup. Default: off.
- Local logging (`PEEKY_ROUTELET_LOG=1`) is a separate opt-in that writes redacted samples to disk with a cap and never networks.
- Content: JSON `{transcript_redacted, routelet_pred, routelet_conf, claude_label}` per turn. All fields have been through the redactor (see section 5).
- Batching: up to `ROUTELET_UPLOAD_BATCH_MAX = 32` per POST.

### 11.5 Invite verification (console only)

- Endpoint: `POST https://<AEGIS_PROXY_HOST>/v1/invite/verify`
- Trigger: user submits an invite code in the console's onboarding UI. One request per submission attempt. No polling.

### 11.6 GitHub OAuth session polling (console only)

- Endpoints:
  - browser: `https://<AEGIS_PROXY_HOST>/auth/github/start?state=<uuid>`
  - poll: `https://<AEGIS_PROXY_HOST>/auth/github/session?state=<uuid>`
- Trigger: user clicks "Sign in" in the console tray, OR trial-wall upgrade flow in peeky (see 11.3).
- Behaviour: polls every 1500 ms for ~2 min then gives up.

### 11.7 Voice-turn hot-path endpoints (already covered; listed here for completeness)

| URL | Trigger | Cost side |
|---|---|---|
| `POST https://<AEGIS_PROXY_HOST>/v1/anthropic/messages` | Every voice turn (classifier + intent path) | Proxy meters; `x-peeky-device-id` gates tier |
| `POST https://<AEGIS_PROXY_HOST>/v1/deepgram/token` | Once per session (cached) | Proxy meters |
| `POST https://<AEGIS_PROXY_HOST>/v1/cartesia/token` | Once per session (cached) | Proxy meters |
| `WSS wss://api.deepgram.com/v1/listen?...` | Every voice turn (bearer from cache) | Deepgram bills the proxy tenant |
| `POST https://api.cartesia.ai/tts/sse` | Every sentence-flush during TTS | Cartesia bills the proxy tenant |

Warm-connection preflight calls (fire once at startup, discarded response):
- `GET https://api.deepgram.com/v1/projects` (header `Authorization: Token warm` -- deliberately invalid to fast-fail)
- `GET https://api.cartesia.ai/voices/` (header `X-API-Key: warm` -- same trick)
- `POST https://<AEGIS_PROXY_HOST>/v1/anthropic/messages` with body `{}` (deliberately malformed)

These are pool-warmers only. They do not carry a real key or a real request. They still hit the vendor and leave a log line on Deepgram/Cartesia/Anthropic-proxy side.

### 11.8 Direct-mode fallback (paid API, one-flag opt-in)

If the user sets any of these envs, Peeky routes AROUND the proxy and hits the vendor with a real API key charged to whoever owns that key:

| Env | Effect | Endpoint hit |
|---|---|---|
| `PEEKY_ANTHROPIC_DIRECT=1` + `ANTHROPIC_API_KEY` | Claude direct | `https://api.anthropic.com/v1/messages` |
| `PEEKY_DEEPGRAM_DIRECT=1` + `DEEPGRAM_API_KEY` | Deepgram direct | `wss://api.deepgram.com/v1/listen?...` with `Authorization: Token <key>` |
| `PEEKY_CARTESIA_DIRECT=1` + `CARTESIA_API_KEY` | Cartesia direct | `https://api.cartesia.ai/tts/sse` |

Without those envs, no direct-vendor paid call happens. The proxy is the only path.

### 11.9 Gmail (only when configured)

Only fires if `PEEKY_GMAIL_CLIENT_ID` AND `PEEKY_GMAIL_CLIENT_SECRET` are set:
- `https://accounts.google.com/o/oauth2/auth` (browser, first-run only)
- `POST https://oauth2.googleapis.com/token` (initial + refresh)
- `GET/POST https://gmail.googleapis.com/gmail/v1/users/me/...` (every gmail_* tool call)

### 11.10 Deep-link URLs used in agent prompt

These appear as string literals in the agent system prompt but are **only** produced as `open_url` tool payloads (user's browser opens them, not peeky):
`https://www.youtube.com/results?search_query=...`, `https://www.google.com/search?q=...`, `https://github.com/search?q=...`, `https://open.spotify.com/search/...`, `https://en.wikipedia.org/wiki/...`, `https://www.amazon.com/s?k=...`, `https://www.youtube.com/watch?v=...`. Not peeky network calls.

### 11.11 Library-baked strings (present but never called)

Grep of the peeky/console binaries also surfaces `https://docs.rs/getrandom`, `https://docs.rs/rustls/...`, `https://github.com/gfx-rs/wgpu/...`, `https://github.com/tauri-apps/{muda,tauri,wry,global-hotkey}/...`, `https://github.com/whatwg/html/issues/7428`, `https://iamcredentials.googleapis.com`, `https://www.googleapis.com/auth/cloud-platform`. These are error-message templates or default-scope constants inside vendored crates (rustls, wgpu, yup-oauth2, tao/muda/wry), and none are actually POSTed unless the app deliberately uses that code path (Peeky doesn't). Confirmed by grepping the peeky source: no calls to these URLs.

### 11.12 Console runtime pings

The console app is Tauri; its embedded webview loads content **from disk** (bundled HTML/JS in the app resources), not from a remote. No CDN, no fonts.google.com, no telemetry. Grepped `strings ... console` -- the only `https://` entries that are actionable outbound requests are the aegis-proxy ones covered in 11.5, 11.6, and the trial-wall flow. The `console` binary also references `https://api.cartesia.ai/access-token`, `https://api.deepgram.com/v1/auth/grant`, and `https://api.anthropic.com/v1/models` as strings, plus `PEEKY_SHOW_SIGNIN` env probe. These appear to be helper endpoints available for a dev-mode direct sign-in from the console UI; they are gated behind console UI paths a normal user never hits.

### 11.13 Summary for OpenClicky integration

To ensure zero background contact with Peeky's infrastructure when embedding it:
- Block or nop out every `https://<AEGIS_PROXY_HOST>` call.
- Do **not** import or wire `crate::routelet::sample::init_uploader` or set `PEEKY_ROUTELET_UPLOAD=1`.
- Do **not** invoke `crate::upgrade::on_proxy_error` (this is the trial-wall trigger that opens a browser tab to the GitHub OAuth start URL).
- Skip `SttDeepgram::warm()` / `TtsCartesia::warm()` / `Claude::warm()` calls unless you want the intentional-fastfail pool warmer to actually hit those vendors.
- Do not persist or transmit `<config>/peeky/device_id`; it uniquely fingerprints the install to the proxy.
- If you route Claude/Deepgram/Cartesia through your own credentials, use the `PEEKY_ANTHROPIC_DIRECT=1` / `PEEKY_DEEPGRAM_DIRECT=1` / `PEEKY_CARTESIA_DIRECT=1` code paths, which do **not** send any peeky-specific headers.
- `console/src-tauri/src/invite.rs` and the GitHub OAuth polling in `upgrade.rs` are the only two flows that assume the proxy is up; both are user-initiated (invite entry, or an actual trial-exhausted error) and neither runs on a timer.

No proactive periodic beacon, no analytics ping, no version-check heartbeat, no crash reporter was found in either binary.
