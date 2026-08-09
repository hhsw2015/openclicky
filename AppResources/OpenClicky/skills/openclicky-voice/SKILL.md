---
name: openclicky-voice
description: Voice loop with the local OpenClicky app. The user speaks into a floating macOS notch/bubble; transcripts land in the current project's .oc/events.jsonl. You respond by appending tts.speak commands to .oc/commands.jsonl. OpenClicky shows the reply in a bubble and speaks it. Trigger when the user asks to "start OpenClicky voice", "use SKI mode", "talk to me via the notch", or similar. Based on SKI's ski skill; adapted to OpenClicky paths.
---

# openclicky-voice — Voice loop with the local OpenClicky app

You are now the agent-side of a bidirectional voice bridge. The user speaks into a floating notch/bubble on their desktop; their speech arrives here as `utterance.final` events. You reply by writing `tts.speak` commands.

## Files (per-project)

Each project that wants to participate has its own `.oc/` folder inside it. OpenClicky can bind multiple projects at once; each project's agent operates against its own folder and only sees its own traffic.

- **Events from the user** (read): `$PWD/.oc/events.jsonl`
- **Commands to the app** (write): `$PWD/.oc/commands.jsonl`

Where `$PWD` is your current working directory — the project you're running in. Resolve the absolute path once via `pwd` and use the same path throughout the session.

> You do NOT need the user to pick this project in OpenClicky first. When you start the loop (below), the heartbeat announces this folder to OpenClicky over its global socket (`~/.openclicky/agents.sock`) and OpenClicky **auto-binds** it — the project appears in OpenClicky's list on its own and `.oc/` is created. Just make sure the OpenClicky app is running with SKI Mode profile active. (If OpenClicky has not yet enabled the socket path, the loop still works via `.oc/events.jsonl` tailing alone.)

## Event schema (you receive)

```json
{"event":"session.started","session_id":"<16 hex chars>","project":"<name>","ts":1731510000.0}
{"event":"utterance.final","session_id":"<id>","text":"hey can you check the build","duration_ms":2400,"audio_seconds":2.4,"ts":1731510003.6}
{"event":"utterance.final","session_id":"<id>","text":"what's wrong with this layout","duration_ms":1800,"audio_seconds":1.8,"ts":1731510004.2,"screenshots":["/abs/project/.oc/screenshots/2026-07-15-121314.png"]}
{"event":"tts.done","session_id":"<id>","ts":1731510010.1}
{"event":"tts.interrupted","session_id":"<id>","ts":1731510010.1}
{"event":"screen.captured","session_id":"<id>","path":"/abs/project/.oc/screenshots/2026-07-10-121314.png","ts":1731510400.0}
{"event":"screen.capture_failed","session_id":"<id>","reason":"screen_recording_permission","ts":1731510400.0}
```

`session_id` is deterministic per project (SHA-256 of the absolute project path, truncated to 16 hex chars — OpenClicky computes it, you just pass it through or omit).

**OpenClicky-specific context field.** An `utterance.final` event may
carry an OpenClicky-specific `context` object with per-turn signals
gathered by the app. Unknown fields are safe to ignore.

```json
{"event":"utterance.final","session_id":"…","text":"…",
 "context":{
   "focused_window":"Cursor - main.swift",
   "stash":"<recent-screen OCR markdown, last ~60 s>",
   "xlb_suggested_topics":[{"name":"Vibe Coding","browse_cmd":">Vibe Coding/"}],
   "openclicky_mcp_url":"http://127.0.0.1:32123/mcp/sensor",
   "openclicky_mcp_token":"<bearer>"
 }
}
```

Use `stash` and `focused_window` as free-of-charge context. For deeper needs (long-term memory, fresh screenshot, xlb topic browse) call `openclicky_mcp_url` with the bearer token — OpenClicky exposes ~130 sensor tools under that endpoint.

**System notices:** an `utterance.final` event carrying `"system": true` is a message FROM OPENCLICKY, not the user speaking — its text starts with `[OpenClicky system message …]`. Follow its instruction (typically: OpenClicky just refreshed this skill after an app update — re-read SKILL.md at the given path, then continue). Do not reply to it, do not treat it as conversation.

Two event kinds require action:

- **`utterance.final`** — the user spoke. Reply via `tts.speak`. It may carry a `screenshots` array (absolute PNG paths in this project's `.oc/screenshots/`): the user grabbed screenshots with OpenClicky's screenshot hotkey to go with what they said. **Read each image** and use them as visual context. **Never skip an utterance that has `screenshots`, even if its `text` is empty** — an empty-text utterance carrying screenshots means the user shared them without speaking (decide what to do with them; no acknowledgment is required).

The other events (`session.started`, `tts.done`, `tts.interrupted`, `screen.*`) are status signals — log or ignore.

**Multi-project routing:** OpenClicky routes the user's voice to whichever project the user has picked as the "active speak target". If you stop receiving `utterance.final` events, the user has likely switched the active target to another project; just wait — when they switch back, events resume.

## Command schema (you write)

One JSON object per line, appended to `$PWD/.oc/commands.jsonl`. OpenClicky's file watcher picks up new lines within ~500 ms.

| Command | Fields | Effect |
|---|---|---|
| `tts.speak` | `text` (required), `session_id` (optional), `prefix_project_name` (optional bool) | OpenClicky shows the text in a bubble and speaks it via the configured TTS (Edge / Realtime / Kokoro). Replies from non-active projects are auto-prefixed with `From <project>:` — you don't need to add the prefix yourself. |
| `tts.cancel` | `session_id` (optional) | Clears the current spoken reply and flushes the playback queue. |
| `screen.capture` | `session_id` (optional) | OpenClicky captures the user's MAIN display under its own macOS Screen Recording grant and replies on events.jsonl with `screen.captured {path}` (full-res PNG inside this project) or `screen.capture_failed {reason}`. |
| `agent.thinking` | `text` (optional; free-form) | OpenClicky shows a "thinking" line in the agent bubble transcript. Emit before a long tool call so the user can see what you are working on. |
| `agent.tool_call` | `name` (required), `args` (optional object) | OpenClicky shows a monospaced `→ <name>  <arg_summary>` line in the agent bubble transcript. Emit once per tool invocation. |
| `agent.tool_result` | `name` (required), `text` (optional; result preview) | OpenClicky shows a monospaced `← <name>  <preview>` line paired with the tool_call. Keep `text` short (a few hundred chars max). |
| `agent.done` | `text` (optional) | OpenClicky marks the current turn as complete in the transcript. |
| `agent.heartbeat` | `ts` (optional, unix seconds) | **Emitted automatically by `heartbeat.py` — do not write by hand.** Fallback liveness signal when the Unix socket is unreachable. |

**Surfacing the middle process.** The user can open OpenClicky's Agent bubble (Chat / Mini Chat) to see the transcript. `tts.speak` alone only shows final replies — that leaves the user staring at silence during long tool chains. Emit `agent.thinking`, `agent.tool_call`, and `agent.tool_result` while you work so the middle steps show up as monospaced badge lines between the user's turn and the final `tts.speak` reply. Rule of thumb: any tool call that takes more than ~2 s deserves a `tool_call` line, and any tool that produces useful output deserves a `tool_result` line.

```bash
# Example reply (resolve path once)
EVENTS="$PWD/.oc/events.jsonl"
COMMANDS="$PWD/.oc/commands.jsonl"

echo '{"command":"tts.speak","text":"Build is green on main."}' >> "$COMMANDS"
```

## How to run the loop

Use the **Monitor + `tail -f` + `grep`** pattern. It is kernel-driven — zero idle tokens between utterances, instant reaction when the user speaks.

**1. Start a persistent Monitor.** The skill ships an optional `heartbeat.py` sibling next to this SKILL.md. It connects to OpenClicky's global socket (`~/.openclicky/agents.sock`), announces this project, and holds the connection so the "connected" dot turns green. Launch it INSIDE the Monitor command so its lifetime is anchored to the monitor shell (`$$` below IS the monitor shell — do NOT background the heartbeat from a separate one-off Bash call):

### Primary loop for Claude Code (Bash tool only, no Monitor)

Claude Code's Bash tool does NOT return promptly from `tail -F | grep -m 1`
(empirically verified: `grep -m 1` exits but the outer pipeline blocks
on idle `tail` until `timeout` kills it — ~40 s wake latency). Use a
**polling loop** — 0.5 s tick, exits cleanly on the first new line,
sub-500ms latency:

Bootstrap once (detach heartbeat):

```bash
# One-time bootstrap (run once per session).
mkdir -p "$PWD/.oc"; : >> "$PWD/.oc/events.jsonl"; : >> "$PWD/.oc/commands.jsonl"
SKILL_DIR="$HOME/.agents/skills/openclicky-voice"
[ -f "$SKILL_DIR/heartbeat.py" ] || SKILL_DIR="$HOME/.claude/skills/openclicky-voice"
[ -f "$SKILL_DIR/heartbeat.py" ] || SKILL_DIR="$PWD/.claude/skills/openclicky-voice"

# Detach heartbeat from this Bash's session so it survives the tool exit.
if [ -f "$SKILL_DIR/heartbeat.py" ] && ! pgrep -f "heartbeat.py.*$PWD" >/dev/null; then
    # Anchor to $PPID (this Bash's parent = the Claude Code / CLI
    # process). When Claude Code exits, heartbeat.py detects the dead
    # anchor within ~30 s and exits — no orphan processes, no leaked
    # UDS connections. Using `1` here (as older docs did) makes the
    # heartbeat immortal because anchor_alive(1) is always true.
    ANCHOR_PID="$PPID"
    nohup python3 "$SKILL_DIR/heartbeat.py" "$HOME/.openclicky/agents.sock" "$PWD" "$ANCHOR_PID" \
        >/tmp/oc-heartbeat-$$.log 2>&1 </dev/null &
    disown
fi
```

Track the last-seen file offset in `.oc/.tail_offset` and poll on
every turn. This is polling (not push), but each Bash tool call is
short-lived which is what Claude Code prefers:

```bash
# Poll: read anything new since our last check.
OFFSET_FILE="$PWD/.oc/.tail_offset"
OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
CURSIZE=$(wc -c < "$PWD/.oc/events.jsonl")
if [ "$CURSIZE" -le "$OFFSET" ]; then
    # No new bytes yet. Wait up to 30 s for new content, then exit.
    for i in $(seq 1 60); do
        sleep 0.5
        CURSIZE=$(wc -c < "$PWD/.oc/events.jsonl")
        [ "$CURSIZE" -gt "$OFFSET" ] && break
    done
fi
if [ "$CURSIZE" -gt "$OFFSET" ]; then
    dd if="$PWD/.oc/events.jsonl" bs=1 skip="$OFFSET" 2>/dev/null \
        | grep -E '"event": *"utterance\.final"'
    echo "$CURSIZE" > "$OFFSET_FILE"
fi
```

Parse each printed line's JSON `text` field. For each utterance:
1. Append an immediate ack `{"command":"tts.speak","text":"好, 我看看"}` to `commands.jsonl`.
2. Run any tools you need.
3. Append the substantive reply as another `tts.speak` line.

After processing, re-run the poll Bash to await the next turn.
Each iteration is bounded (30 s max) so Bash tool won't stall
indefinitely.

Heartbeat lifecycle — what you get for free:
- **Auto-binds this project.** Announcing over the global socket adds the project to OpenClicky's list (green dot) even if the user never picked it there.
- **Lives exactly as long as the loop.** The monitor shell stays alive for the whole `tail | grep` pipeline; when the Monitor is stopped, the shell dies and heartbeat.py exits within ~5 s → dot goes grey.
- **Survives OpenClicky restarts.** If OpenClicky quits or relaunches, the script loses the socket and automatically reconnects (and re-announces) when OpenClicky returns.
- **Zero tokens** after the initial spawn — it's all kernel-driven.

**If the heartbeat dies or the dot stays grey:** check with `pgrep -f "heartbeat.py.*$PWD"`. If nothing is running, the simplest recovery is to restart the whole Monitor (TaskStop the old one, re-run the command above).

**2. For every `utterance.final` notification:**
   - Parse the JSON, extract `text` and (if present) `context`.
   - Decide if this is a question/request (respond) or just acknowledgment (skip — keep the reply file quiet).
   - If responding, generate a SHORT reply (1–3 sentences max — the bubble is small and the user is in a real-time conversation).
   - Append one `tts.speak` line to `commands.jsonl`. Use a Bash `echo` with the JSON inside single quotes, or a HEREDOC for replies containing single quotes.
   - **Match the language** of the user's speech: Chinese in → Chinese out; English in → English out. Kokoro local TTS is English-only; Chinese replies go through OpenClicky's cloud TTS automatically.

**3. If the user asks for something requiring tool use** (read a file, search the codebase, run a command):
   - **First acknowledge with a quick reply**: `{"command":"tts.speak","text":"Let me check."}` or `{"command":"tts.speak","text":"好, 我看看"}` — so OpenClicky shows immediate feedback within ~1 s.
   - **Emit the middle process to the bubble transcript.** For EVERY tool call you make in service of this turn, append two lines to `commands.jsonl`:
     - Before the call: `{"command":"agent.tool_call","name":"<toolName>","args":{...}}`
     - After the call: `{"command":"agent.tool_result","name":"<toolName>","text":"<short preview of the result, <240 chars>"}`
     These render as monospaced `→ toolName args` / `← toolName preview` lines in the OpenClicky Chat / Mini Chat bubble so the user can see what you are actually doing. REQUIRED, not optional.
   - When done, send a second `tts.speak` with the result. Keep it short; offer details if the user asks.
   - Optional: `{"command":"agent.done"}` to mark the turn complete.

Concrete example — user asks "看看 README 里的第一段":

```bash
COMMANDS="$PWD/.oc/commands.jsonl"
echo '{"command":"tts.speak","text":"好, 我看看"}' >> "$COMMANDS"
echo '{"command":"agent.tool_call","name":"Read","args":{"file_path":"README.md"}}' >> "$COMMANDS"
# ... run your Read tool here ...
echo '{"command":"agent.tool_result","name":"Read","text":"# ProjectX\n\nA voice-first companion..."}' >> "$COMMANDS"
echo '{"command":"tts.speak","text":"README 开头是一个 voice-first macOS 助手的介绍。"}' >> "$COMMANDS"
echo '{"command":"agent.done"}' >> "$COMMANDS"
```

The immediate-ack rule is critical: without it, OpenClicky sits silent for the full tool-loop duration (potentially 5-30 s) and the user perceives the system as broken. The `agent.tool_call` / `agent.tool_result` pairs are the visual side of that same rule — they keep the transcript alive during that window.

**4. If the user asks you to look at THEIR OWN screen** —
their desktop, an app, their editor, "what I'm looking at":
   - **Always capture through OpenClicky:** append
     `{"command":"screen.capture"}` to `commands.jsonl`. **Do NOT run
     `screencapture` — or any other screenshot tool — yourself, even if
     it works in your terminal.** Only the OpenClicky path (a) records
     the shot in the OpenClicky transcript (a permanent record), and
     (b) grabs the user's real main display under OpenClicky's own
     Screen Recording grant.
   - OpenClicky captures the main display and replies on events.jsonl
     with `screen.captured {path}` (your Monitor delivers it). Read the
     PNG and answer the user's question.
   - On `screen.capture_failed` with reason `screen_recording_permission`,
     tell the user: enable OpenClicky under System Settings → Privacy
     & Security → Screen Recording, then quit and relaunch OpenClicky.
     Do NOT fall back to `screencapture` yourself.

**5. Keep the loop alive until the user explicitly ends it.** Stop the Monitor via `TaskStop` only when:
   - The user says "stop", "exit", "end", "quit", "close" via voice or chat, OR
   - The user kills OpenClicky (you'll stop receiving events).

## Conversation style

- **Short replies.** This is voice; long replies feel robotic.
- **No preamble.** Don't say "Sure, here's what I found." Say the thing.
- **Mid-task acknowledgments** when an action will take >2 s: `{"command":"tts.speak","text":"On it."}` — then do the work.
- **Don't echo the user's question back.** The user already knows what they said.
- **Match language.** Chinese in → Chinese out. English in → English out.

## Activating

Once the user asks you to start (or you detect a voice-loop intent), do these in order:

1. Start the Monitor as described in "How to run the loop" above.
2. Send a hello so the user knows the loop is live:
   ```bash
   echo '{"command":"tts.speak","text":"Connected. What do you need?"}' >> "$PWD/.oc/commands.jsonl"
   ```
3. From here on, react to each `utterance.final` notification as they arrive.

## Multi-project notes

- Multiple agents can run simultaneously in different projects. Each tails its own `.oc/events.jsonl` and writes to its own `commands.jsonl`. OpenClicky aggregates: only the active project receives the user's speech, but ALL projects' replies are queued and played back FIFO with a `From <project>:` prefix on the bubble + spoken audio (unless the reply is from the active project).
- You don't need to coordinate with other projects' agents — they operate independently.

## Not in this skill (OpenClicky-specific)

OpenClicky is a menu-bar voice companion — not a meeting bot host. The following SKI-only concepts are intentionally absent:

- **No** `meeting.join_request` / `agentcall.leave` / `summarize` events — OpenClicky does not host AgentCall meetings.
- **No** `voice.set` command — voice selection lives in OpenClicky's Settings (Advanced Providers), not the file bridge.

If a user asks you to join a meeting or summarize a recording, respond with `tts.speak` explaining that OpenClicky's SKI Mode does not currently host meetings and suggest they use the underlying CLI agent directly for the meeting join.
