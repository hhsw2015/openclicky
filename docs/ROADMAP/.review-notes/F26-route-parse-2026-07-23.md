# F26 — Dialog reply `[ROUTE]` parse + RouteDispatcher + fallback classifier

Review pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809` (informational only — F26 is openclicky-native).
Reviewer: code-only, file:line for every claim.

Openclicky files under review:
- `cursor-buddy/HeyClickyChatToolCallClient.swift` — Fable-lane preflight + directive block emit + `[ROUTE]` regex parse (`analyzeVoiceResponse`, `contextAwarenessDirectiveBlock`, `parseRouteJSON`)
- `cursor-buddy/OpenClickyRouteDispatcher.swift` — `RouteDispatcher.dispatch` + `classifyFallback` + `spawnCodex`
- `cursor-buddy/CompanionManager.swift` — wiring (`RouteDispatcher.shared.companionManager = self`) and codex-spawn entry (`dispatchRoutedAgentTask` → `startVoiceAgentTaskPlan` → `startVoiceAgentTask` with `workingDirectoryOverride`)

Everywhere counterparts: **none applicable.** Everywhere is capture+MCP, not agent+voice. `[ROUTE]` is an openclicky-native contract emitted by openclicky's own dialog model prompt (see `cursor-buddy/HeyClickyChatToolCallClient.swift:861-879`) and consumed by openclicky's dispatcher. Cross-check against `docs/ROADMAP/02_LAYER_1_INTENT_ROUTER.md` (design doc only — treated as informational, not authoritative per checklist Standard 1).

---

## Alignment table (openclicky code vs `02_LAYER_1_INTENT_ROUTER.md` design)

| Aspect | Design doc | Openclicky (file:line) | Status |
|---|---|---|---|
| Preflight snapshot injected as `[openclicky-context]` block | doc:196-218 | `HeyClickyChatToolCallClient.swift:58-77` | OK |
| Preflight fields: frontmost_app + window_title + browser_url + finder_selection + selected_text | doc:198-203 | `HeyClickyChatToolCallClient.swift:801-810, 886-938` (bundleId, name, windowTitle, browserURL, selectedFolder, selectedFileNames, selectedText) | OK — 5-field parity |
| Directive block teaches model `[ROUTE] {…}` tail contract | doc:57-86 | `HeyClickyChatToolCallClient.swift:861-879` | OK |
| Five valid `kind` values: chat / short_task / long_task_new / long_task_existing / ambiguous | doc:60-71, 124-149 | `HeyClickyChatToolCallClient.swift:868`, dispatcher `OpenClickyRouteDispatcher.swift:55-66` | OK |
| Parse regex extracts `[ROUTE] { … }` from reply tail | doc:291-295 | `HeyClickyChatToolCallClient.swift:1046-1060` (`\[ROUTE\]\s*(\{[^\n]*\})`, last-match wins) | OK — see Issue 4 |
| Missing `[ROUTE]` ⇒ log + fallback (design says "视为 chat, 无害") | doc:117 | `HeyClickyChatToolCallClient.swift:495-521` (logs `openclicky.route_missing`, calls `classifyFallback`; when fallback returns `chat`, no-ops) | OK — stronger than design (context-signal fallback before defaulting to chat) |
| Invalid `[ROUTE]` JSON ⇒ same as missing | doc:118 | `HeyClickyChatToolCallClient.swift:1059` `try?` on `JSONDecoder.decode` returns nil → same fallback branch | OK |
| chat / ambiguous ⇒ no codex spawn | doc:126-127, 146-149 | `OpenClickyRouteDispatcher.swift:55-58` | OK |
| short_task ⇒ workdir = selected_folder or `~/Library/Application Support/OpenClicky/EphemeralTasks/<slug>/` | doc:130-133 | `OpenClickyRouteDispatcher.swift:155-172` (explicit route.workdir → preflight.selectedFolder → `~/Library/Application Support/OpenClicky/EphemeralTasks/<slug>/`) | OK — matches path convention |
| long_task_new / long_task_existing ⇒ codex spawn | doc:135-144 | `OpenClickyRouteDispatcher.swift:59-60`, spawns via `companion.dispatchRoutedAgentTask` (`CompanionManager.swift:14459-14473`) | Partial — see Issue 1 |
| `startVoiceAgentTaskPlan` params `workingDirectoryHint / projectRef / slug / progressDriven / completionMarker` | doc:298-310 | `CompanionManager.swift:14396-14403` only exposes `workingDirectoryOverride` (via `dispatchRoutedAgentTask` at :14459-14473) | **DIVERGES** — Issue 1 |
| Fallback classifier: no keyword tables, only context signals | dispatcher header comment `OpenClickyRouteDispatcher.swift:13-16, 79-80` | `OpenClickyRouteDispatcher.swift:81-139` (WorkdirProbe empty ⇒ new; detected type ⇒ existing; ProjectRegistry lookup on transcript then window title, score ≥ 0.75) | OK |
| Fallback defaults to `chat` (no spawn) when no signal fires | design:117 (safe default) | `OpenClickyRouteDispatcher.swift:132-138` | OK |
| Preflight reused between prompt-build and dispatch (no second Layer-0 capture) | design:281-289 (implicit) | `HeyClickyChatToolCallClient.swift:59-62` (`preflightSnapshot` hoisted), passed to `dispatch(..., preflight: snapshot)` at :488-493 and :513-518 | OK |
| Codex agent receives an INITIAL SCENE CONTEXT block (composed from preflight snapshot) | doc:19-24 ("Codex 完全暴露 MCP, 不 preflight"; scene context is orchestrator-side hint, not preflight) | `OpenClickyRouteDispatcher.swift:197-246` (`composeAgentPrompt` embeds frontmost/window/url/selected_folder/selected_text + intent) | OK |
| RouteDispatcher wired to CompanionManager at init | doc:281-289 | `CompanionManager.swift:1784-1787` (`RouteDispatcher.shared.companionManager = self`) | OK |
| Workdir override validated as existing directory before applying | design does not specify; openclicky adds guard | `CompanionManager.swift:14612-14628` (`FileManager.fileExists(_:isDirectory:)` + `isDir.boolValue`); invalid path logs `openclicky.route_workdir_invalid` and falls through to session default | OK |
| Parse runs on completed reply (not mid-stream) | doc:291-295 implies post-completion | `HeyClickyChatToolCallClient.swift:135` uses `postJSON` (non-streaming POST) + `decodeStrict(data:)` at :160 — single JSON reply, no chunked delta. Parse at :478 runs on the fully-materialised `finalText` before the single `onTextChunk` call at :523. | OK — no partial-stream race |
| Dispatch hop returns to `MainActor` before touching companion state | Swift `@MainActor` invariants | `HeyClickyChatToolCallClient.swift:488-494, 513-519` wraps `dispatch(...)` in `await MainActor.run { ... }`; `RouteDispatcher` itself is `@MainActor` (`OpenClickyRouteDispatcher.swift:26-27`) | OK |
| Fallback classifier reuses snapshot rather than re-capturing | design:281-289 | `HeyClickyChatToolCallClient.swift:499-502` passes `preflightSnapshot` into `classifyFallback` | OK |

---

## Issues

### CRITICAL

None. The core happy path (parse → dispatch → codex spawn with workdir override) is coherent and race-free within a single non-streaming request.

### HIGH

#### Issue 1 — `startVoiceAgentTaskPlan` does not expose `workingDirectoryHint / projectRef / slug / progressDriven / completionMarker`

Task brief expects the signature `startVoiceAgentTaskPlan(instruction:workingDirectoryHint:projectRef:slug:progressDriven:completionMarker:)`. Actual signature:

```
CompanionManager.swift:14396-14403
private func startVoiceAgentTaskPlan(
    instruction: String,
    acknowledgement: String? = nil,
    route: String = "agent.start",
    speakAcknowledgement: Bool = true,
    interruptVoiceResponse: Bool = false,
    voiceContextUserTranscript: String? = nil,
    workingDirectoryOverride: String? = nil
)
```

- **`workingDirectoryHint` → `workingDirectoryOverride`.** Different name, same semantic (an override applied only when the path resolves to an existing directory, `CompanionManager.swift:14612-14628`). Naming divergence, no functional break.
- **`projectRef` / `slug`: NOT propagated to the codex spawn.** `RouteDispatcher.spawnCodex` receives them from `RouteParseResult` (`OpenClickyRouteDispatcher.swift:143-192`) and **embeds them only inside the agent's INITIAL SCENE CONTEXT text block** (`OpenClickyRouteDispatcher.swift:235-240`) — they never reach `CodexAgentSession` as structured fields. `dispatchRoutedAgentTask` (`CompanionManager.swift:14459-14473`) exposes no such params either. Design doc:298-310 shows both as first-class args.
- **`progressDriven` / `completionMarker`: NOT implemented.** `grep -n "progressDriven\|completionMarker" cursor-buddy/*.swift` → 0 matches. The `MARKER-END` completion contract exists **only in the bundled AGENTS-longrun template** (`AppResources/OpenClicky/AGENTS-longrun-template.md:92,121,151`), not as a Swift-side observer. No `turn/completed` observer that reads `progress.md` and fires a continuation exists (`grep autoContinue cursor-buddy/CodexAgentSession.swift` → only `HeyClickyTurnLeaseClient.autoContinue` at :1618, which is cost-cap auto-continue, not progress-driven).

Impact: F26 is roughly two-thirds shipped. Route parse + dispatch + workdir hint work; the progress-driven autonomy loop (`progress.md not DONE → auto-fire`) is not present in code. Any long-running task started via `[ROUTE]` will run one turn, wait for user input, then stop — same as a manually-typed agent task.

**Fix**: either (a) add `progressDriven: Bool` and `completionMarker: String?` args to `startVoiceAgentTaskPlan`, plumb them into `CodexAgentSession`, and register a `turn/completed`-notification observer that re-fires when `<workdir>/progress.md` lacks the marker; or (b) update the design doc / task brief to explicitly punt progress-driven autonomy to a later feature (F27) and mark F26 as parse+dispatch only.

#### Issue 2 — `workdir` field is not tilde-expanded

`OpenClickyRouteDispatcher.swift:157-159`:
```
let workdir: String
if let w = route.workdir?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty {
    workdir = w
}
```

`CompanionManager.swift:14612-14615` then validates with `FileManager.default.fileExists(atPath: overridePath, isDirectory:)`. `fileExists` does **not** expand `~`. If Fable emits `"workdir":"~/Projects/foo"` (a reasonable model output given how paths appear in preflight), the validator rejects it and the agent lands in `$HOME` (or the session default).

**Fix**: `NSString(string: w).expandingTildeInPath` before both the existence-guard and the store into `session.workingDirectoryPath`. Also relative-path resolution against `preflight.selectedFolder` when route.workdir is not absolute — currently unmentioned in doc, but low-cost to add.

### MEDIUM

#### Issue 3 — Slug not filesystem-sanitised when it comes from the model

When Fable emits a slug, it flows unchanged into the ephemeral path (`OpenClickyRouteDispatcher.swift:163-165`):
```
let slug = route.slug?.isEmpty == false ? route.slug! : UUID().uuidString
let base = "\(NSHomeDirectory())/Library/Application Support/OpenClicky/EphemeralTasks"
workdir = "\(base)/\(slug)"
```

`sanitizedSlug(from:)` (`OpenClickyRouteDispatcher.swift:251-263`) exists but is only called by the **fallback classifier** (`:95`) when it synthesises a slug from the transcript. Model-supplied slugs skip it entirely, so a slug like `"my project / v2"` becomes a two-segment path and `createDirectory` at :168-171 will succeed at creating `.../my project/ v2/`, silently landing the agent in a nested dir.

**Fix**: call `sanitizedSlug(from: slug)` on model-supplied slugs before joining into `base`. Also cap length before feeding to `FileManager`.

#### Issue 4 — `parseRouteJSON` last-match-wins may pick a spurious `[ROUTE]` inside the model's spoken text

Regex `\[ROUTE\]\s*(\{[^\n]*\})` (`HeyClickyChatToolCallClient.swift:1047`) then `matches.last` (:1053). If the model, in the middle of its spoken reply, quotes an example (`'you can emit something like [ROUTE] {"kind":"chat"...} at the end'`) and **also** appends a real trailing `[ROUTE] {…}`, last-wins picks the real one — fine.

But if it quotes an example and forgets the real trailing tag, the example is parsed as authoritative. Also, `[^\n]*` requires the JSON on one physical line: if the model wraps it (line-break inside braces), no match, fallback fires — probably preferable, but note the regex is stricter than the directive suggests.

Impact: low; the directive at `HeyClickyChatToolCallClient.swift:877` forbids code fences and multi-line, so real Fable behaviour rarely triggers this. Log `openclicky.route_parsed` (:479-485) will show the parsed values so drift is visible.

**Fix**: optionally anchor the regex to end-of-reply: `\[ROUTE\]\s*(\{[^\n]*\})\s*$` with `.anchorsMatchLines`. Keep last-wins as a belt-and-braces default.

#### Issue 5 — Multiple `[ROUTE]` in the same reply: last wins, but duplicate fields inside one JSON are not defended

`matches.last` (`HeyClickyChatToolCallClient.swift:1053`) resolves multiple tags. But `JSONDecoder` on a payload with duplicate keys uses **last value wins by default** in Swift; there is no schema-level rejection. A malicious/malformed reply `{"kind":"chat","kind":"long_task_new",...}` would parse as `long_task_new`.

Impact: negligible (Fable is our own model, not adversarial). Note only.

#### Issue 6 — `progressDriven=true` + `completionMarker` empty case not defensible (feature absent)

Related to Issue 1. Even if the fields existed, the design implies `progressDriven` gates on a non-empty marker. No such gate is present because the whole loop is missing.

### LOW

#### Issue L1 — `RouteParseResult.confidence` has no lower-bound validation

`OpenClickyRouteDispatcher.swift:47-53` logs confidence; `dispatch` (:55-66) does **not** consult it — it dispatches based on `kind` alone. Design doc:119 says "confidence < 0.6 → 视为 ambiguous, openclicky 不 spawn task". Not enforced in code.

Impact: model self-reports `kind="short_task", confidence=0.3` → we spawn anyway. Note only.

**Fix**: add a `guard route.confidence >= 0.6 else { treat as chat; return }` after the switch on kind for the task branches.

#### Issue L2 — `project_ref` is not verified against ProjectRegistry when the model provides it

When Fable emits `long_task_existing` with a `project_ref`, `spawnCodex` passes it through into the composed prompt (`OpenClickyRouteDispatcher.swift:235-237`) but never round-trips through `ProjectRegistry.shared.lookup(_:)` to resolve to a concrete workdir. If `route.workdir` is nil and `preflight.selectedFolder` is nil, the code falls back to the ephemeral-task dir under `Application Support/EphemeralTasks/<slug>/` — which for an *existing* project is wrong.

Impact: rare (Fable is trained to also emit workdir when it names a project_ref, and the doc directive at `:868` requires it), but silent-fall-through into a wrong dir will confuse a user who said "resume clicky mac".

**Fix**: in the `long_task_existing` branch, if `route.workdir` is empty, call `ProjectRegistry.shared.lookup(route.projectRef ?? "", limit: 1).first` and use `match.entry.path` when score ≥ 0.75.

#### Issue L3 — No visible "prompt is stable across model choices" check

The `contextAwarenessDirectiveBlock` at `HeyClickyChatToolCallClient.swift:861-879` is only injected on the Fable / `.heyclickyFree` provider arm (via `analyzeVoiceResponse` at `CompanionManager+AIResponsePipeline.swift:422-430`). Direct Claude (`.anthropic` at :385-394), OpenAI (`.openAI` at :395-406), and Codex-provider (`.codex` at :413-421) code paths **do not** inject the block. Consequently, when the user selects a non-Fable model from `OpenClickyModelCatalog`, the dialog reply carries no `[ROUTE]` line and the fallback classifier fires for every turn.

Impact: functional — but by design (per `docs/CLAUDE.md` "Inference Routing", Fable is openclicky's own dialog model and the primary `[ROUTE]` emitter). Note only.

**Fix**: if the intent is that `[ROUTE]` should work across providers, hoist the directive block into the shared system-prompt path. If Fable-only is the intent, add a doc note pointing this out; the fallback classifier's context-signal path is arguably the correct behaviour for non-Fable turns.

#### Issue L4 — Memory / Fable `remember` integration not verified for `[ROUTE]` persistence

Task brief §6 asks whether Fable's memory endpoint preserves `[ROUTE]` guidance across sessions. `HeyClickyAccountResetManager.swift:20` exists (grep shows it manages account/consent reset, `:129` "remembered email"), but no code path was found that persists the `[ROUTE]` directive into a memory store or reads it back. The directive block travels inside every `query` (`HeyClickyChatToolCallClient.swift:67, 76`), so it is stateless-across-turns by design — no memory dependency.

Impact: none observed. The claim in the task brief that "Fable can `remember` via MCP memory endpoint" was not verifiable from grep of the current tree — leaving this Issue L4 open for the person who wrote the memory integration.

---

## Bug-hunt checklist

- **Race: `[ROUTE]` parsed on main actor?** — Dispatcher is `@MainActor` (`OpenClickyRouteDispatcher.swift:26`), parse runs on the caller (Task pool), dispatch is wrapped in `await MainActor.run { ... }` (`HeyClickyChatToolCallClient.swift:488-494, 513-519`). OK.
- **Partial-stream parse race?** — `postJSON` at `:135` is a blocking single-request POST; `decodeStrict` at :160 parses the full body; parse runs at :478 on `finalText` which is finalised before the single `onTextChunk` call at :523. **No streaming**, so no partial-reply parse can happen. OK.
- **Completion-marker file race** — N/A, feature not implemented (see Issue 1).
- **Fallback + real ROUTE double-dispatch?** — The if/else at `HeyClickyChatToolCallClient.swift:478-521` is mutually exclusive. OK.

---

## Structural gaps vs Everywhere's intent-classification approach

F26 is openclicky-native, so byte-parity is not applicable. Two structural notes:

1. **Everywhere never classifies intent on the model side.** Everywhere's flow is user → hotkey → capture bundle → MCP tool → agent (no intermediate dialog model). Openclicky inserts a Fable turn that both speaks a reply AND emits `[ROUTE]`. The design is intentional (see `02_LAYER_1_INTENT_ROUTER.md:1-9`, decision doc-only, but the code enforces it). No divergence to fix.
2. **Openclicky's fallback classifier is stricter than Everywhere's implicit routing.** Everywhere always spawns an agent; there is no `chat` vs `task` gate. Openclicky's `classifyFallback` (`OpenClickyRouteDispatcher.swift:81-139`) intentionally defaults to `chat` when no context signal fires, so a bare "hello there" via voice does not spawn a codex process. This is a strict, openclicky-only feature. No divergence.

---

## Verdict

**INCOMPLETE (roughly two-thirds shipped).**

Working:
- `[ROUTE]` regex parse with last-match-wins (`HeyClickyChatToolCallClient.swift:1046-1060`)
- Dispatcher routing on `kind` for chat / ambiguous / short_task / long_task_new / long_task_existing (`OpenClickyRouteDispatcher.swift:55-66`)
- Context-only fallback classifier (WorkdirProbe + ProjectRegistry, no keyword tables) (`OpenClickyRouteDispatcher.swift:81-139`)
- Preflight snapshot re-use across parse and dispatch (no second Layer-0 capture) (`HeyClickyChatToolCallClient.swift:59-62`)
- Workdir override guard against non-existent path (`CompanionManager.swift:14612-14628`)
- Wiring at CompanionManager init (`CompanionManager.swift:1784-1787`)
- MainActor safety for dispatch (`OpenClickyRouteDispatcher.swift:26`, `HeyClickyChatToolCallClient.swift:488-494`)

Missing / broken:
- **HIGH Issue 1**: `progressDriven` + `completionMarker` not implemented; `projectRef` and `slug` not first-class args on `startVoiceAgentTaskPlan`. Long-task autonomy loop is absent.
- **HIGH Issue 2**: `route.workdir` not tilde-expanded before validation.
- **MEDIUM Issue 3**: Model-supplied `slug` skips `sanitizedSlug(from:)` before path-joining.
- **MEDIUM Issue 4**: `parseRouteJSON` last-match-wins is not anchored to end-of-reply (rare mis-parse possible on model self-quoting).
- **LOW Issue L1**: `confidence < 0.6` gate from design not enforced.
- **LOW Issue L2**: `project_ref` not resolved via ProjectRegistry when `route.workdir` is empty.
- **LOW Issue L3**: Directive block only wired on `.heyclickyFree` provider arm; non-Fable providers get no `[ROUTE]` teaching.
- **LOW Issue L4**: Fable `remember` integration for `[ROUTE]` persistence not verifiable from current tree.

Recommend: land the two HIGH fixes (progress-driven autonomy loop + tilde expansion) plus the slug sanitisation before considering F26 done. The remaining MEDIUM/LOW items can ride as follow-ups.
