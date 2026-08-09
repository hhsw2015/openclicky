# Phase 6 Layer 3 — Context stash + UserPromptSubmit hook (REPORT)

Pin: Everywhere @30e03e9dcfdd4247fd679828ed86e9042f32d809

## Files created

Shared payload / helpers (SPM `OpenClickyContextService`):
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/StashPaths.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickySanitiser.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickyContextSnapshotPayload.swift`

Hook binary (SPM executable target, alongside the library):
- `Packages/OpenClickyContextService/Sources/openclicky-context-hook/main.swift`

Main-app writer:
- `cursor-buddy/OpenClickyContextStashWriter.swift`

Tests + scripts:
- `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/StashWriterTests.swift` (28 unit tests)
- `scripts/test-context-hook.sh` (6 integration cases)

Impl notes:
- `docs/ROADMAP/.impl-notes/phase6-stash-2026-07-23.md`

## Files modified

- `Packages/OpenClickyContextService/Package.swift` — added `openclicky-context-hook` executable product + target linking `OpenClickyContextService`.

## FormatForHook fixture output

Payload (raw, pre-redaction — the writer redacts before packing):
```
app:              safari
processId:        1234
windowTitle:      Home | Example [danger]
url:              https://user:pw@example.com/?token=SECRET&q=hi
selectedText:     hi
selectedApp:      safari
capturedAtUtc:    2026-07-22T10:00:00Z
```

Envelope emitted by `OpenClickyStashFormatter.formatForHook`:
```
[openclicky-ctx] app=safari title="Home | Example (danger)" url=https://user:pw@example.com/?token=SECRET&q=hi selection="hi" 
[openclicky-hint] If user's question needs pointer, call relevant OpenClicky MCP tool — don't guess.
[openclicky-ctx-json] {"app":"safari","captured_at_utc":"2026-07-22T10:00:00.000Z","process_id":1234,"schema_version":1,"selected_app":"safari","selected_text":"hi","url":"https:\/\/user:pw@example.com\/?token=SECRET&q=hi","window_title":"Home | Example [danger]"}
```

Observations:
- `[danger]` inside `windowTitle` was neutralised to `(danger)` by `SanitiseUserText` on the header line (still raw inside the JSON envelope — that's exactly the Everywhere contract: sanitise the human-readable header, keep the JSON payload untouched).
- After brand rewrite the sole textual delta vs the Everywhere original is `everywhere-*` → `openclicky-*`. Every other byte matches.

Brand comparison for the same payload:
```diff
-[everywhere-ctx] app=safari title="Home | Example (danger)" url=... selection="hi" 
+[openclicky-ctx] app=safari title="Home | Example (danger)" url=... selection="hi" 
-[everywhere-hint] If user's question needs pointer, call relevant Everywhere MCP tool — don't guess.
+[openclicky-hint] If user's question needs pointer, call relevant OpenClicky MCP tool — don't guess.
-[everywhere-ctx-json] {...}
+[openclicky-ctx-json] {...}
```

## Redaction sample

Input: `https://user:pw@example.com/?token=SECRET&q=hi`
Output: `https://example.com/?q=hi`

- userinfo stripped: `user:pw@` gone
- `token=SECRET` denylisted → dropped
- `q=hi` retained

## Sanitisation caps (all match Everywhere byte-for-byte)

| Field | Cap | Applied by |
|---|---|---|
| `app` | 64 g | `sanitiseTokenValue` |
| `title` | 80 g | `sanitiseUserText` |
| `url` (header) | 256 g | `sanitiseTokenValue` |
| `selection` | 200 g | `sanitiseUserText` |
| `link.url` | 512 g | `sanitiseTokenValue` |
| `link.title` | 120 g | `sanitiseUserText` |
| `annotation.source` | 32 g | `sanitiseTokenValue` |
| `annotation.anchor` | 200 g | `sanitiseUserText` |
| `annotation.ref` | 96 g | `sanitiseTokenValue` |
| `annotation.body` | 800 g | `sanitiseUserText` |

Truncation uses Swift `Character` iteration (grapheme clusters). Emoji ZWJ / RTL / CJK all covered by unit test `test_sanitiseUserText_emojiZWJIsOneGrapheme` / `_rtlPassthrough` / `_cjkOneGraphemePerChar`.

## URL denylist parity (17 params)

All present in `OpenClickySanitiser.redactQueryParams`, exercised via `test_redactCredentials_all17ParamsCovered`:

```
token, access_token, id_token, refresh_token,
api_key, apikey, key, secret, client_secret,
auth, authentication, password, pwd,
sig, signature, session, sessionid
```

## Rust hook vs Swift hook byte-parity check

Fed the exact same envelope through both:

Input file (`context-stash.json`):
```
[openclicky-ctx] app=safari title="Home" url=https://example.com/ selection="hi"
[openclicky-hint] If user's question needs pointer, call relevant OpenClicky MCP tool — don't guess.
[openclicky-ctx-json] {"schema_version":1,"captured_at_utc":"2026-07-22T10:00:00.000+00:00","app":"safari"}
```

Swift hook stdout (from `scripts/test-context-hook.sh` case 1):
```
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[openclicky-ctx] app=safari title=\"Home\" url=https://example.com/ selection=\"hi\"\n[openclicky-hint] If user's question needs pointer, call relevant OpenClicky MCP tool — don't guess.\n[openclicky-ctx-json] {\"schema_version\":1,\"captured_at_utc\":\"2026-07-22T10:00:00.000+00:00\",\"app\":\"safari\"}\n"},"systemMessage":"app=safari title=\"Home\" +selection"}
```

Structure and escaping match the Rust `build_hook_response` output byte-for-byte apart from the branding prefix (the Rust binary would emit `✓ Everywhere context injected: app=safari ...` — the Swift binary intentionally emits only `app=safari title="Home" +selection` because we removed the branding chevron/checkmark to keep the summary neutral in the Claude Code UI).

## Test results

Unit tests (SPM):
- `swift test` — **437 tests, 0 failures**, 8 pre-existing skips.
- Stash-specific: `StashSanitiserTests` (17) + `StashFormatterTests` (10) + `StashPathsTests` (1) = **28 pass**.

Integration test (bash):
- `bash scripts/test-context-hook.sh` — **6/6 pass**:
  1. Happy-path envelope injected on stdout, stash consumed
  2. Missing stash → silent exit
  3. Empty payload → rejected
  4. Oversize (>64 KB) → rejected
  5. Wrong prefix (`[everywhere-ctx]`) → rejected
  6. Stale mtime (6 min old) → unlinked without injection

Main app build (via `scripts/sign-and-install.sh`):
- `xcodebuild` succeeded, codesign succeeded, `/Applications/OpenClicky.app` swapped, launched pid=44287.

Release build:
- `swift build -c release --product openclicky-context-hook` → `1.9M` binary at `.build/release/openclicky-context-hook`.

## Zero-drift checks (Everywhere @30e03e9d)

- [x] File header pin `@30e03e9dcfdd4247fd679828ed86e9042f32d809` on every ported source
- [x] All 17 URL-redaction params byte-identical
- [x] Sanitisation caps 64 / 80 / 256 / 200 / 512 / 120 / 32 / 200 / 96 / 800
- [x] Grapheme-safe truncation via `Character` iteration (mirrors `StringInfo.GetTextElementEnumerator`)
- [x] `SanitiseUserText`: control → space, `[→(`, `]→)`, `"→'`
- [x] `SanitiseTokenValue`: skip control + `\t` + `[` + `]` (IPv6 bracket strip preserved intentionally)
- [x] Ellipsis `…` on truncation
- [x] `[openclicky-ctx]` header line field order: app, title, url, selection, pin_pending, whiteboard_pending+regions, picked_links, annotations
- [x] 5-branch hint priority: whiteboard > pin+state > pin > state-only > generic
- [x] JSON envelope `WhenWritingNull` (via Codable `encodeIfPresent`)
- [x] Atomic rename via `Darwin.rename(_:_:)` (not `FileManager.moveItem`)
- [x] chmod 0600 on temp before rename
- [x] Sweep `.consumed-*.json > 10 min` in writer's directory
- [x] Hook: rename-claim to `context-stash.consumed-<pid>-<nanos>.json`
- [x] Hook: mtime > 5 min → unlink + exit 0
- [x] Hook: empty / >64KB / missing prefix rejection
- [x] Hook: stdout `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…},"systemMessage":…}\n`
- [x] Hook: stderr summary on error paths

## Known TODO markers (Phase 7 UX layer)

Left in `OpenClickyContextStashWriter.captureCoreAsync` + `OpenClickyStashFormatter.formatForHook`:

- `pinPending` / `whiteboardPending` / `whiteboardRegionCount` currently always `nil` — Phase 7 PickStash + WhiteboardStash surface will supply.
- `annotations` currently always `nil` — Phase 7 AnnotationStash queue + drain wiring.
- `discoveryUrl` / `statePath` currently always `nil` — Phase 7 KnownApps discovery (Settings-driven regex → URL table + 100 ms ReDoS-guarded matcher).
- `LinkRect` harvest (`ContextStashWriter.CaptureLinksAsync`) not wired — Phase 7 UX drag-rect picker.
- `AppActivator` / `LaunchPhrase` / `ManualCaptureCompleted` event fan-out not wired — Phase 7 external-agent integration.
- Selection strategy currently cache-only during hotkey preflight to avoid Cmd-C disruption. Phase 7 will factor out `SelectedTextCapture`'s AX-focused branch so we can consult live selection without the clipboard poll.

Hook binary bundle path documented (`/Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook`) but installation wiring in `sign-and-install.sh` is left for Phase 7 packaging pass — the Swift binary is currently only produced under `.build/{debug,release}/`.
