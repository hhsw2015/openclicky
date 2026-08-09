# Phase 6 Layer 3 — Context stash + UserPromptSubmit hook

Investigation notes, port strategy, and alignment checklist.

Pin: Everywhere @30e03e9dcfdd4247fd679828ed86e9042f32d809

## Ground-truth files read

1. `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` — 1001 lines
2. `src/Everywhere.Mcp/Snapshot/StashPaths.cs` — 42 lines
3. `tools/everywhere-context-hook/src/main.rs` — 227 lines
4. `src/Everywhere.Mcp/SnapshotContextHotkeyInitializer.cs` — 160 lines

## FormatForHook byte layout (order matters)

Line 1: `[everywhere-ctx] ` (trailing space, header prefix)
  - `app=<SanitiseTokenValue(App,64)> ` — only if App has length
  - `title="<SanitiseUserText(WindowTitle,80)>" ` — only if WindowTitle set
  - `url=<SanitiseTokenValue(Url,256)> ` — only if Url set
  - `selection="<SanitiseUserText(SelectedText,200)>" ` — only if SelectedText set
  - `pin_pending=true ` — only if PinPending == true
  - `whiteboard_pending=true regions=<n>` — only if WhiteboardPending == true (NB: no trailing space in C# emit at line 637)
  - `picked_links=<count> ` — only if PickedLinks.Count > 0
  - `annotations=<count> ` — only if Annotations.Count > 0
  - trailing `\n`

Lines 2..N (only if PickedLinks not empty), one per link:
  `[everywhere-ctx-link] #<i> url=<SanitiseTokenValue(url,512)> title="<SanitiseUserText(title,120)>"\n`
  (title suffix only if title has length; no trailing space before newline)

Lines (only if Annotations not empty), one per annotation:
  `[everywhere-ctx-annotation] #<i> source=<SanitiseTokenValue(source,32)> anchor="<SanitiseUserText(label,200)>" ref=<SanitiseTokenValue(ref,96)> body="<SanitiseUserText(body,800)>"\n`
  (ref segment omitted if AnchorRef null/empty)

Hint block (exactly one of five, in this priority order — checked as `if / else if / else if / else`, C# lines 701-732):
  1. `WhiteboardPending == true` → `[everywhere-hint] User drew N annotated region(s) ... mcp__everywhere__read_whiteboard ...` (multi-sentence, ends `\n`)
  2. `PinPending == true && statePath != null` → `[everywhere-hint] User pinned UI element AND known local web app. PREFER: GET <statePath>?consume=1 ...`
  3. `PinPending == true` → `[everywhere-hint] user pinned UI element ... mcp__everywhere__read_pick ...`
  4. `statePath != null` → `[everywhere-discover] xlb-style local app self-describes at <discoveryUrl>. Fast path: GET <statePath>?consume=1 ...`
  5. else → `[everywhere-hint] If user's question needs more pointer, call relevant Everywhere MCP tool — don't guess.\n`

Trailing line:
  `[everywhere-ctx-json] <JsonSerializer.Serialize(payload)>` (no trailing newline; StringBuilder ends here)

Openclicky rewrite: replace all `everywhere-` prefixes → `openclicky-`, and `mcp__everywhere__*` → `mcp__openclicky__*`. Everything else byte-identical.

## ContextSnapshotPayload JSON schema

Keys (snake_case, `WhenWritingNull` on all nullables):
- `schema_version` (int, always 1)
- `captured_at_utc` (ISO8601 with timezone offset)
- `app` (string?)
- `process_id` (int?)
- `window_title` (string?)
- `url` (string?)
- `selected_text` (string?)
- `selected_app` (string?)
- `pin_pending` (bool?)
- `whiteboard_pending` (bool?)
- `whiteboard_region_count` (int?)
- `picked_links` ([{url:string,title:string?}]?)
- `annotations` ([{source:string,body:string,anchor_label:string,anchor_ref:string?,captured_at:iso8601}]?)

## Sanitisation constants (exact C# values)

Header line: app=64, title=80, url=256, selection=200
`[everywhere-ctx-link]`: url=512, title=120
`[everywhere-ctx-annotation]`: source=32, anchor=200, ref=96, body=800

## SanitiseUserText (C# line 798-817)

1. TruncateGraphemes to N graphemes; append `…` if truncated.
2. For each Char (UTF-16 code unit — not grapheme):
   - if in ControlCharsToStrip (`\0 \n \r \t \v \f \b`) → replace with space
   - else if `char.IsControl(c)` → replace with space
   - else if `[` → `(`
   - else if `]` → `)`
   - else if `"` → `'`
   - else pass through unchanged

## SanitiseTokenValue (C# line 836-847)

1. TruncateGraphemes to N graphemes; append `…` if truncated.
2. For each Char:
   - if `char.IsControl(c) || c == '\t'` → drop (skip)
   - else if `c == '[' || c == ']'` → drop (skip) — WARNING: strips IPv6 brackets in URLs; Everywhere-intentional; preserve
   - else pass through

## URL redaction (C# line 448-481, exact 17 params)

Denylist (case-insensitive, after URL-unescape of the param name):
```
token
access_token
id_token
refresh_token
api_key
apikey
key
secret
client_secret
auth
authentication
password
pwd
sig
signature
session
sessionid
```

Operations, in order:
1. UriBuilder with UserName = "" and Password = "" (strip userinfo)
2. If query non-empty: split on `&`, keep entries whose UnescapeDataString(name-before-=) is NOT in denylist
3. Return `b.Uri.AbsoluteUri` (preserves original percent-encoding)

Scheme allowlist for XLB multi-pick harvest: `http | https | mailto`.

## Atomic write protocol (C# line 901-927)

1. Ensure directory exists.
2. Sweep stale `.consumed-*.json` (>10 min).
3. Write tmp = `<StashPath>.tmp` (`File.WriteAllTextAsync`).
4. `File.SetUnixFileMode(tmp, UserRead|UserWrite)` — 0o600.
5. `File.Move(tmp, StashPath, overwrite: true)` — Swift equivalent = `Darwin.rename(_:_:)` because `FileManager.moveItem` refuses to overwrite.

## Rust hook protocol (main.rs)

1. Resolve stash path; missing HOME → exit 0.
2. `fs::metadata(&path)` → NotFound → exit 0 silently.
3. If mtime > 5 min old: `fs::remove_file(&path); return 0`.
4. Atomic claim: `rename(path → context-stash.consumed-<pid>-<unix_nanos>.json)`. NotFound → exit 0 (race with another hook).
5. Read claimed file into bytes.
6. `fs::remove_file(&claimed)` — always try, even on read error.
7. Validate: reject empty, `> 64 * 1024`, or bytes not starting with `[everywhere-ctx] ` (with trailing space).
8. Build JSON `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":<body>},"systemMessage":<summary>}\n` — hand-rolled JSON (no serde_json).
9. Summary = extract `app=` (until space) and `title="..."` (up to 60 chars) and `+selection` flag from first `[everywhere-ctx] ` line.
10. Write payload to stdout; exit 0.

Stale sweep in the writer covers `.consumed-*.json > 10 min` (not the hook).

## OpenClicky adaptation

### ContextStashWriter.swift (main app)

- Path: `~/Library/Application Support/OpenClicky/context-stash.json`
- All prefixes rebranded: `[openclicky-ctx]`, `[openclicky-ctx-link]`, `[openclicky-ctx-annotation]`, `[openclicky-hint]`, `[openclicky-discover]`, `[openclicky-ctx-json]`.
- MCP tool names in hint block: `mcp__openclicky__read_whiteboard`, `mcp__openclicky__read_pick`.
- CaptureCoreAsync order:
  1. Frontmost app (`FrontmostAppCapture.capture()`), also derive pid + AppKey.
  2. Focused window title (`FocusedWindowCapture.capture(processId:)`).
  3. Browser URL (`BrowserURLCapture.capture(processId:)`).
  4. Selection: `SelectionCache.shared.getFresh()` first; on miss, `SelectedTextCapture.capture(cache:)` (Cache short-circuit + AX-first strategy — never Cmd-C during preflight is not enforced by our capture directly; skip Cmd-C path by ignoring `.clipboardCmdC` source via a helper wrapper — see Note below).
  5. Redact URL through `RedactCredentials` (userinfo strip + denylist filter).
  6. XLB multi-pick clipboard harvest (sentinel `xlb-multi-pick://`) via `ClipboardCapture`.
  7. If all fields empty → early-return, no write.
  8. Build payload, `FormatForHook`, `WriteAtomic`.
- Single-flight: `NSLock.try()` (non-blocking, matches C# `SemaphoreSlim(1,1).WaitAsync(0)`).
- Atomic write: temp → chmod 0600 → `Darwin.rename(_:_:)`. Sweep `.consumed-*.json > 10 min` first.
- Phase 6 skip markers (Phase 7 UX layer): PickStash, WhiteboardStash, AnnotationStash, LinkRect harvest, launch phrase, AppActivator, KnownApps discovery. All payload fields nil, hint block always generic.

Note on Cmd-C: To avoid the disruption Everywhere calls out (Cmd-C poll on preflight), we pass `SelectionCache.shared` and accept whatever the cache holds. If cache is empty we do NOT invoke `SelectedTextCapture.capture` in the preflight path — instead we return `nil` for `selected_text`. Live focused selection via focused-element AX comes for free from `SelectedTextCapture` when `.axFocused` is used; we short-circuit before the `.clipboardCmdC` branch by only using `.cache` and `.axFocused` sources.

### openclicky-context-hook (SPM executable)

Add executable target to existing `Packages/OpenClickyContextService/Package.swift`:
```swift
.executableTarget(
    name: "openclicky-context-hook",
    dependencies: [],
    path: "Sources/openclicky-context-hook"
)
```

`Sources/openclicky-context-hook/main.swift` (pure Foundation + Darwin, zero library imports):
- Resolve path from `HOME` env → `<HOME>/Library/Application Support/OpenClicky/context-stash.json`.
- Stat via `stat(2)`; missing → exit 0. Other error → stderr + exit 0.
- mtime check: > 5 min → unlink + exit 0.
- Atomic claim: `rename(path, path.consumed-<pid>-<nanos>.json)`. ENOENT → exit 0.
- Read claimed file bytes; unlink; validate.
- Reject: empty, len > 64 * 1024, not `.hasPrefix([openclicky-ctx] )` (with trailing space).
- Build hand-rolled JSON envelope (no JSONEncoder — mirror Rust's compact string escaping).
- Extract summary from first line: `app=` and `title="..."` (60-char cap) and `+selection`.
- Stdout: `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":<esc>},"systemMessage":<esc>}\n`.
- Stderr: one short summary line, only on rejection or unexpected error paths.

### Bundle path (documented; Phase 7 wiring)

Release build lands at `.build/release/openclicky-context-hook`. Install target for `sign-and-install.sh` (future patch): copy to `/Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook`.

## Alignment checklist

- [x] All 17 URL redaction params
- [x] Sanitisation caps: 64/80/256/200/512/120/32/200/96/800
- [x] Grapheme-safe truncation via `enumerateSubstrings(byComposedCharacterSequences:)`
- [x] SanitiseUserText: control → space, `[→(`, `]→)`, `"→'`
- [x] SanitiseTokenValue: skip control + `\t` + `[` + `]`
- [x] Ellipsis `…` on truncation
- [x] Field order in `[openclicky-ctx]` line: app, title, url, selection, pin_pending, whiteboard_pending+regions, picked_links, annotations
- [x] Line separators: header line + link rows + annotation rows + hint (one of 5) + ctx-json (no final newline after json)
- [x] `WhenWritingNull` JSON semantics
- [x] Atomic rename via `Darwin.rename`
- [x] chmod 0600 on temp before rename
- [x] Sweep `.consumed-*.json > 10 min` in writer directory
- [x] Hook: rename claim with `<pid>-<nanos>` sibling
- [x] Hook: >5 min → unlink + exit 0
- [x] Hook: empty / >64KB / prefix check
- [x] Hook: stdout JSON envelope with `hookSpecificOutput.hookEventName=UserPromptSubmit`
- [x] Hook: stderr = summary
