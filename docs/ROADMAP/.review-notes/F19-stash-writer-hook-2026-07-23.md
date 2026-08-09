# F19 — Stash writer + Hook + URL redaction

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`
Reviewer: code-only, file:line for every claim.

Openclicky files under review:
- `cursor-buddy/OpenClickyContextStashWriter.swift` (490 lines, git:untracked)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickyContextSnapshotPayload.swift` (319 lines)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/OpenClickySanitiser.swift` (147 lines)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Stash/StashPaths.swift` (24 lines)
- `Packages/OpenClickyContextService/Sources/openclicky-context-hook/main.swift` (199 lines)

Everywhere counterparts:
- `src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs` (1001 lines)
- `src/Everywhere.Mcp/Snapshot/StashPaths.cs` (43 lines)
- `tools/everywhere-context-hook/src/main.rs` (227 lines)

---

## Alignment table

| Aspect | Everywhere (file:line) | Openclicky (file:line) | Status |
|---|---|---|---|
| Schema version constant | ContextStashWriter.cs:27 `CurrentSchemaVersion = 1` | OpenClickyContextSnapshotPayload.swift:210 `currentSchemaVersion = 1` | OK |
| Stash directory | StashPaths.cs:17-22 `~/Library/Application Support/Everywhere/context-stash.json` | StashPaths.swift:13-23 `~/Library/Application Support/OpenClicky/context-stash.json` | OK (rebrand documented) |
| Envelope header prefix | ContextStashWriter.cs:621 `"[everywhere-ctx] "` | OpenClickyContextSnapshotPayload.swift:216 `"[openclicky-ctx] "` | OK (rebrand) |
| Hook prefix check | main.rs:146 `b"[everywhere-ctx] "` | main.swift:31 `"[openclicky-ctx] "` | OK (rebrand, both writer↔hook agree) |
| Header field: `app=`, cap 64 | ContextStashWriter.cs:622 `SanitiseTokenValue(p.App, 64)` | OpenClickyContextSnapshotPayload.swift:218 `sanitiseTokenValue(app, maxChars: 64)` | OK |
| Header field: `title="…"`, cap 80 | ContextStashWriter.cs:625 `SanitiseUserText(p.WindowTitle, 80)` | OpenClickyContextSnapshotPayload.swift:221 `sanitiseUserText(t, maxChars: 80)` | OK |
| Header field: `url=`, cap 256 | ContextStashWriter.cs:629 `SanitiseTokenValue(p.Url, 256)` | OpenClickyContextSnapshotPayload.swift:224 `sanitiseTokenValue(u, maxChars: 256)` | OK |
| Header field: `selection="…"`, cap 200 | ContextStashWriter.cs:633 `SanitiseUserText(p.SelectedText, 200)` | OpenClickyContextSnapshotPayload.swift:227 `sanitiseUserText(s, maxChars: 200)` | OK |
| `pin_pending=true` (trailing space) | ContextStashWriter.cs:635 | OpenClickyContextSnapshotPayload.swift:230 | OK |
| `whiteboard_pending=true regions=N` (no trailing space) | ContextStashWriter.cs:636-637 | OpenClickyContextSnapshotPayload.swift:232-236 (comment acknowledges) | OK |
| `picked_links=N` | ContextStashWriter.cs:638-639 | OpenClickyContextSnapshotPayload.swift:237-239 | OK |
| `annotations=N` | ContextStashWriter.cs:640-641 | OpenClickyContextSnapshotPayload.swift:240-242 | OK |
| Link row prefix `[everywhere-ctx-link] #<i> ` | ContextStashWriter.cs:651 | OpenClickyContextSnapshotPayload.swift:248 `[openclicky-ctx-link] #\(i) ` | OK (rebrand) |
| Link cap: `url=` 512, `title=` 120 | ContextStashWriter.cs:652,654 | OpenClickyContextSnapshotPayload.swift:249,251 | OK |
| Annotation row prefix + caps: source=32 anchor=200 ref=96 body=800 | ContextStashWriter.cs:667-672 | OpenClickyContextSnapshotPayload.swift:260-266 | OK |
| Envelope body layout order | header → links → annotations → **JSON+\n** → hint | header → links → annotations → **hint** → JSON (no \n) | **DIVERGES** — see Issue 1 |
| JSON encoder options | ContextStashWriter.cs:986-989 `DefaultIgnoreCondition=WhenWritingNull` (insertion order) | OpenClickyContextSnapshotPayload.swift:311 `.sortedKeys` (alphabetical) | **DIVERGES** — see Issue 2 |
| JSON date format | System.Text.Json default `DateTimeOffset` round-trip (fractional seconds) | OpenClickyContextSnapshotPayload.swift:187-201 `[.withInternetDateTime, .withFractionalSeconds]` | Matches shape |
| Hint text (5 branches) | ContextStashWriter.cs:701-732 | OpenClickyContextSnapshotPayload.swift:276-297 | **DIVERGES** — paraphrased, see Issue 3 |
| 5-branch discriminator conditions | whiteboard→pin+state→pin→state→generic | Same 5 branches, same conditions (statePath always nil, TODO) | Structural OK |
| Discovery URL / statePath resolution | ContextStashWriter.cs:684-685,756-791 `ResolveDiscoveryUrl` + `ToStatePath` | OpenClickyContextSnapshotPayload.swift:273-274 hardcoded `nil, nil` (Phase 7 TODO comment :272) | Deferred — always falls through non-state branches |
| Sanitise controls-to-strip list | ContextStashWriter.cs:30 `['\0','\n','\r','\t','\v','\f','\b']` | OpenClickySanitiser.swift:19-21 same 7 chars | OK |
| SanitiseUserText: replace `[`→`(`, `]`→`)`, `"`→`'` | ContextStashWriter.cs:808-813 | OpenClickySanitiser.swift:46-51 | OK |
| SanitiseTokenValue: drop control + tab + `[` + `]` | ContextStashWriter.cs:842-843 `IsControl \|\| ' ' \|\| '\t'`, then `[`/`]` | OpenClickySanitiser.swift:69-70 `isControl \|\| '\t'`, then `[`/`]` | **DIVERGES** — Swift misses space-drop, see Issue 4 |
| SanitiseTokenValue IPv6 bracket-strip semantics | ContextStashWriter.cs:843 (intentional) | OpenClickySanitiser.swift:70 (comment acknowledges) | OK (preserved verbatim) |
| TruncateGraphemes | ContextStashWriter.cs:849-864 `StringInfo.GetTextElementEnumerator`, append `…` | OpenClickySanitiser.swift:82-97 `for c in s` (Swift `Character` = grapheme cluster), append `…` | OK |
| URL redaction denylist (17 params) | ContextStashWriter.cs:448-455 | OpenClickySanitiser.swift:113-118 | OK — byte-match verified |
| Scheme allowlist http/https/mailto | ContextStashWriter.cs:824-829 | OpenClickySanitiser.swift:143-146 | OK |
| RedactCredentials strips userinfo | ContextStashWriter.cs:461 `UriBuilder{UserName="",Password=""}` | OpenClickySanitiser.swift:128-129 `comps.user=nil; comps.password=nil` | OK |
| RedactCredentials query filter | ContextStashWriter.cs:462-473 case-insensitive after `Uri.UnescapeDataString` | OpenClickySanitiser.swift:130-136 `removingPercentEncoding.lowercased()` | OK semantically |
| RedactCredentials returns AbsoluteUri (preserves percent-encoding) | ContextStashWriter.cs:475 `b.Uri.AbsoluteUri` | OpenClickySanitiser.swift:137 `comps.string` | Roughly OK — see Issue 5 |
| Atomic write: tmp → chmod 0600 → rename | ContextStashWriter.cs:911-926 | OpenClickyContextStashWriter.swift:453-471 | OK (uses `Darwin.rename(2)` as spec asked) |
| Single-flight lock | ContextStashWriter.cs:55,219 `SemaphoreSlim(1,1).WaitAsync(0)` | OpenClickyContextStashWriter.swift:49,97 `NSLock().try()` | OK — non-blocking |
| Sweep stale `.consumed-*.json` >10 min | ContextStashWriter.cs:929-949 | OpenClickyContextStashWriter.swift:475-488 | OK |
| Hint text: `[…-discover]` label for pin-less state branch | ContextStashWriter.cs:721-728 `[everywhere-discover]` | OpenClickyContextSnapshotPayload.swift:289-294 `[openclicky-discover]` | OK label |
| Whiteboard-pending priority (branch 0) | ContextStashWriter.cs:701 | OpenClickyContextSnapshotPayload.swift:276 | OK |
| Manual capture entrypoint | ContextStashWriter.cs:105 `CaptureAsync` | OpenClickyContextStashWriter.swift:66 `captureAsync()` | OK |
| Auto-capture entrypoint (seed) | ContextStashWriter.cs:115 `CaptureAsync(IVisualElement seed)` | Absent — Phase 7 TODO (writer.swift:133-138 comment) | Deferred |
| Manual raise + phrase (after successful write only) | ContextStashWriter.cs:340-344,367-388 | OpenClickyContextStashWriter.swift:200-202,422-438 | OK |
| Auto-capture path suppresses activation | ContextStashWriter.cs:335-344 comment | Writer only has manual path today (Phase 7 stub for auto) | OK — currently unreachable |
| LinkRect direct-ship: `MaxLinks=200`, `MaxUrlLen=2048`, `MaxTitleLen=200` | ContextStashWriter.cs:159-161 | OpenClickyContextStashWriter.swift:359-361 | OK |
| LinkRect direct-ship: `IsNullOrWhiteSpace` + length check + scheme allowlist + dedup + cap | ContextStashWriter.cs:167-181 | OpenClickyContextStashWriter.swift:379-402 | OK structurally |
| LinkRect direct-ship: credential redaction on URL | ContextStashWriter.cs:175 (no redaction — raw `linkUrl` stored) | OpenClickyContextStashWriter.swift:385-386 (redacts) | **DIVERGES** — see Issue 6 (Swift is safer) |
| LinkRect direct-ship: title trim | ContextStashWriter.cs:172-174 raw `title[..MaxTitleLen]` when >200 | OpenClickyContextStashWriter.swift:391-399 `trimmingCharacters` then `prefix(200)` | Divergence, see Issue 7 |
| LinkRect activate after write | ContextStashWriter.cs:206-207 | OpenClickyContextStashWriter.swift:350-352 | OK |
| Rust hook constants `TTL_SECS = 5*60`, `MAX_BYTES = 64*1024` | main.rs:16,143 | main.swift:23,27 | OK |
| Rust hook rename-claim `context-stash.consumed-<pid>-<nanos>.json` | main.rs:54-61 | main.swift:49-51 | OK |
| Rust hook read+unlink + always unlink claimed | main.rs:69-81 | main.swift:63-71 | OK |
| Rust hook stale >5 min TTL → unlink + noop | main.rs:39-48 | main.swift:41-45 | OK |
| Rust hook is_valid_payload: empty/oversize/wrong-prefix rejected | main.rs:142-148 | main.swift:100-105 | OK |
| Rust hook stdout JSON envelope shape | main.rs:107-117 `hookSpecificOutput.additionalContext` + `systemMessage` | main.swift:113-117 same shape | OK |
| Rust hook `systemMessage` prefix `"✓ Everywhere context injected: {summary}"` | main.rs:115 | main.swift:114 raw `summary` | **DIVERGES** — see Issue 8 |
| Rust hook json_escape (\", \\, \n, \r, \t, \b, \f, \u{04x}) | main.rs:119-137 | main.swift:120-142 | OK |
| Rust hook stderr summary_first_ctx_line | main.rs:153-174 | main.swift:147-171 | OK |
| Rust hook sweep >10 min `.consumed-*.json` | main.rs — NOT DONE (only writer sweeps) | main.swift — NOT DONE (only writer sweeps) | OK (matches Rust — spec item is writer-side, already listed) |

---

## Issues

### Issue 1 — Envelope body order differs from Everywhere (structural byte-parity break)

Everywhere emits, in order:
1. header line
2. link rows
3. annotation rows
4. `[everywhere-ctx-json] {…}\n`
5. `[everywhere-hint]` / `[everywhere-discover]` line

`ContextStashWriter.cs:677-732` — the `sb.Append("[everywhere-ctx-json] ")` block (677-679) executes **before** the hint if/else chain (701-732). Line 679 explicitly appends `\n` after the JSON.

Openclicky emits:
1. header
2. link rows
3. annotation rows
4. `[openclicky-hint]` / `[openclicky-discover]`
5. `[openclicky-ctx-json] {…}` — **no trailing `\n`**

`OpenClickyContextSnapshotPayload.swift:271-303`: the hint block (276-297) runs first, then the JSON line (300-301) with no `sb += "\n"` afterwards.

Impact: writer↔hook envelope layout no longer byte-matches Everywhere. Everywhere-authored hooks that grep for `\n[everywhere-ctx-json]` at the file tail won't find our JSON in the same relative position, and any consumer treating `[…-hint]` as terminal will now see it before the JSON. Also the missing trailing newline means the file doesn't end with `\n` — POSIX text convention, and grep-based line consumers may drop the last line silently.

Note: the F19 spec description in the task itself matches the Swift order (hint before JSON). If the deviation is intentional and blessed, remove the "1:1 port" claim from `OpenClickyContextSnapshotPayload.swift:205`.

---

### Issue 2 — JSON key ordering differs from Everywhere

`OpenClickyContextSnapshotPayload.swift:307-317`: `encoder.outputFormatting = [.sortedKeys]` (alphabetical). The inline comment (:308-310) acknowledges this: *"Everywhere uses `System.Text.Json` default (insertion order), but tests only need stable serialisation given a stable payload."*

`ContextStashWriter.cs:986-989`: `JsonSerializerOptions { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull }` — no key sort; System.Text.Json emits properties in the record's declaration order (`schema_version, captured_at_utc, app, process_id, window_title, url, selected_text, selected_app, pin_pending, whiteboard_pending, whiteboard_region_count, picked_links, annotations`).

Impact: the JSON blob inside `[openclicky-ctx-json] {…}` is a byte-different substring vs. Everywhere for the same logical payload. Downstream fingerprint / diff tests will fail cross-project byte-parity. Semantically equivalent JSON; parsers work fine.

---

### Issue 3 — Hint copy is heavily paraphrased ("token-savings edit"), not a byte-port

`OpenClickyContextSnapshotPayload.swift:276-297` vs `ContextStashWriter.cs:701-732`. Every hint branch has been rewritten:

- Whiteboard branch (Swift:277-282 vs C#:703-709): drops articles ("a", "the"), drops "for this agent" → "for agent", "and the text the gesture captured" → "text gesture captured", "This is one-shot" → "This one-shot", "for whiteboard content" → "whiteboard content", "it's a different stash" → "it's different stash".
- Pin+state branch (Swift:283-286 vs C#:713-715): drops "a UI element" → "UI element", "For deeper exploration of the topic" → "deeper exploration topic", "with the same URL" → "same URL", "the app's browse skill on the topic" → "app's browse skill on topic", "the user actually needs" → "user actually needs".
- Pin-only branch (Swift:287-288 vs C#:719): "The user pinned a UI element for this question" → "user pinned UI element question" (drops connective; produces run-together sentence).
- Discover branch (Swift:289-294 vs C#:723-727): "xlb-style" → "openclicky-style", "recent view + interactions as markdown" → "recent view + interactions markdown", "For deeper exploration" → "deeper exploration".
- Generic branch (Swift:296 vs C#:731): "If the user's question needs more than this pointer" → "If user's question needs pointer" (deletes a critical clause — "more than" is what makes the sentence conditional).

Impact: (a) not byte-parity with Everywhere; (b) the paraphrase in the generic branch changes semantics — the original hint says "call MCP tool ONLY IF question needs more than this pointer", the port says "call MCP tool IF question needs pointer" — different threshold. Whether this is a blessed openclicky-flavored copy edit or a drift is a policy question. Remove the "1:1 port" language on :205 either way.

---

### Issue 4 — `sanitiseTokenValue` does not drop space

`OpenClickySanitiser.swift:68-72`:
```
for c in truncated {
    if isControlCharacter(c) || c == "\t" { continue }
    if c == "[" || c == "]" { continue }
    out.append(c)
}
```

C# `ContextStashWriter.cs:840-844`:
```
foreach (var c in truncated) {
    if (char.IsControl(c) || c == ' ' || c == '\t') continue;
    if (c == '[' || c == ']') continue;
    buf.Append(c);
}
```

Swift misses the `c == ' '` drop. `isControlCharacter` (Swift:102-107) uses `CharacterSet.controlCharacters`, which does NOT include space (0x20 is not a control character).

Impact: token fields are `app=`, `url=`, `[…-link] url=`, `[…-ctx-annotation] source=`, `ref=`. All are space-terminated in the envelope. If any value contains a raw space, C# strips it (safe); Swift preserves it, which breaks the space-terminated key=value parse rule the envelope depends on. Real-world hit likelihood:
- `app=`: `AppKey.fromProcessId` returns a bundle id like `com.jkneen.openclicky` — no space. Fallback exec basename could contain a space (`My App`) → real hazard.
- `url=`: URLs are percent-encoded so spaces are `%20` — safe in normal browsers, but `URLComponents.string` output for some inputs can leave literal spaces (e.g. `mailto:` with `?subject=`).
- `annotation.source`: hard-coded enum wire values (`pin`/`whiteboard`/`selected`/`linkrect`) — safe.

Recommend adding `c == " "` to the skip clause.

---

### Issue 5 — Query redaction re-encoding via URLComponents may differ from C# UriBuilder

`OpenClickySanitiser.swift:130-137`:
```
if let items = comps.queryItems, !items.isEmpty {
    let kept = items.filter { item in
        let name = item.name.removingPercentEncoding ?? item.name
        return !redactQueryParams.contains(name.lowercased())
    }
    comps.queryItems = kept.isEmpty ? nil : kept
}
return comps.string ?? u.absoluteString
```

C# `ContextStashWriter.cs:462-475`:
```
var pairs = b.Query.TrimStart('?').Split('&');
var kept = new List<string>(pairs.Length);
foreach (var pair in pairs) {
    var eq = pair.IndexOf('=');
    var name = eq < 0 ? pair : pair[..eq];
    if (_redactQueryParams.Contains(Uri.UnescapeDataString(name))) continue;
    kept.Add(pair);
}
b.Query = string.Join('&', kept);
```

Two behavioural differences:
1. **`+` handling**: `URLComponents.queryItems` returns `+` as literal `+` in `name`/`value`. When re-serialised via `comps.string`, `+` is preserved. C# treats the raw `pair` string and preserves everything verbatim, but `Uri.UnescapeDataString("foo+bar")` returns `"foo+bar"` unchanged (unlike `HttpUtility.UrlDecode` which turns `+`→space). So this is *usually* fine — but if a query has `token+extra=…`, Swift compares `"token+extra"` against the denylist and misses the `token` variant; C# does the same. Equivalent.
2. **Bare params (`?foo`)**: C# preserves `pair = "foo"` verbatim. Swift's `queryItems` returns `URLQueryItem(name: "foo", value: nil)`; re-serialising gives `?foo`. Also equivalent.
3. **Percent-encoding of retained values on re-emit**: `URLComponents.string` may re-encode `%20` → `%20` (identity), but some code paths re-encode `%2B` → differently. `Uri.AbsoluteUri` in C# is very strict about round-tripping; `URLComponents.string` is *slightly* looser. Not a hazard for the common denylisted-param cases, but a byte-parity dropper for pathological URLs.

No functional bug; a byte-parity edge case to note.

---

### Issue 6 — Openclicky's `captureLinks(...(title,url))` redacts credentials; Everywhere's `CaptureLinksAsync` does not

`OpenClickyContextStashWriter.swift:383-386`: on the direct LinkRect ship, calls `OpenClickySanitiser.redactCredentials(parsed)` and stores the redacted URL in `PickedLink.url`.

`ContextStashWriter.cs:169-175`: only checks `IsAllowedScheme(linkUrl)`; the raw `linkUrl` is passed straight into `new PickedLink(linkUrl, trimmedTitle)`. No credential filter.

Impact: Swift is safer (URL denylist strips `token=`, `api_key=`, userinfo). Deviates from Everywhere but matches the F19 spec's "LinkRect captureLinks path: Redaction" requirement. Recommend making this deviation explicit in the file header, or file a bug against Everywhere.

---

### Issue 7 — LinkRect direct-ship title trimming order differs

`OpenClickyContextStashWriter.swift:391-399`:
```
let trimmedTitleRaw = title.trimmingCharacters(in: .whitespacesAndNewlines)
let trimmedTitle: String?
if trimmedTitleRaw.isEmpty { trimmedTitle = nil }
else if trimmedTitleRaw.count > maxLinkRectTitleLen {
    trimmedTitle = String(trimmedTitleRaw.prefix(maxLinkRectTitleLen))
} ...
```

`ContextStashWriter.cs:172-174`:
```
var trimmedTitle = string.IsNullOrWhiteSpace(title)
    ? null
    : (title.Length > MaxTitleLen ? title[..MaxTitleLen] : title);
```

Swift trims leading/trailing whitespace before length-checking and slicing; C# takes the raw title. For a 210-char title `" foo … bar "`, C# emits `title[..200]` (still has leading space); Swift emits `foo … bar`.prefix(200). Minor; both are within the same cap, both feed through `SanitiseUserText` again at envelope-emit time. Byte-diff, no functional risk.

Also: C#'s length check uses UTF-16 code units (`title.Length` — surrogate pairs count as 2); Swift's uses `Character` counts (grapheme clusters). For a 210-emoji title, C# might trim at 200 UTF-16 units mid-surrogate — but then `SanitiseUserText`/`TruncateGraphemes` at envelope emit would still land on grapheme boundaries. So no crash risk; byte-diff only.

---

### Issue 8 — Hook `systemMessage` drops the "✓ Everywhere context injected:" prefix

`main.rs:115`:
```
msg = json_escape(&format!("✓ Everywhere context injected: {summary}")),
```

`main.swift:113-117`:
```
let ctx = jsonEscape(additionalContext)
let msg = jsonEscape(summary)
return "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\(ctx)},\"systemMessage\":\(msg)}\n"
```

The Swift port never wraps `summary` in a `"✓ Openclicky context injected: {…}"` template. Result: the user-visible warning line above the prompt is the raw `app=… title="…"` fragment, with no "context injected" affordance.

Impact: user has no visual confirmation that the hook actually injected anything. Recommend either matching Everywhere's prefix (rebranded), or documenting that we intentionally show the raw summary. The task spec says: "Output: stdout JSON, stderr summary" — but Rust actually emits the summary on **stdout** as `systemMessage`, and stderr only carries error messages (`main.rs:64,72,80,88`). Openclicky's Swift hook does the same routing (`main.swift:55-56,66-67,76-77` stderr for errors; `main.swift:86` stdout for the JSON envelope). Routing matches; prefix is missing.

---

## Verdict

**Functionally sound, byte-parity has known gaps.**

- Header line, link rows, annotation rows: full byte-parity (modulo the `everywhere-*` → `openclicky-*` prefix rebrand, which is intentional).
- Sanitisation, redaction denylist (17 params byte-match), scheme allowlist, grapheme-safe truncation, atomic write (chmod 0600 + `Darwin.rename`), single-flight `NSLock.try()`, sweep of `.consumed-*.json` >10 min: all correct.
- Rust↔Swift hook: rename-claim, TTL 5 min, MAX_BYTES 64 KB, `json_escape`, `is_valid_payload`, `summarise_first_ctx_line`, stdout↔stderr routing: correct.
- Envelope tail ORDER diverges (Issue 1) — hint before JSON, missing trailing `\n`. Structural.
- JSON key order diverges (Issue 2) — alphabetical vs insertion. Cross-project fingerprint tests will fail.
- Hint copy is paraphrased across all 5 branches (Issue 3). Not byte-parity; one branch has a semantic drift ("If user's question needs pointer" vs "needs more than this pointer").
- `sanitiseTokenValue` fails to drop literal space (Issue 4). Envelope space-terminated key=value grammar is at risk for exec-name `app=` values and any URL containing an unencoded space.
- LinkRect direct-ship: Swift adds credential redaction that Everywhere doesn't (Issue 6, spec-compliant improvement); title trimming order differs (Issue 7, cosmetic).
- Hook `systemMessage` drops the "✓ Everywhere context injected:" prefix (Issue 8). User UX regression relative to Rust.

**Recommended before merge:**
1. Fix Issue 4 (`sanitiseTokenValue` space-drop) — smallest, real hazard.
2. Fix Issue 1 (JSON before hint, trailing `\n`) OR update the "1:1 port" claim in the file headers of `OpenClickyContextSnapshotPayload.swift:1-10,203-207`.
3. Fix Issue 8 (hook `systemMessage` prefix) — one line.
4. Decide Issue 3 policy: byte-port the hint copy or explicitly bless the paraphrase.
5. Note Issues 2, 5, 7 in the porting log; harmless in isolation.
