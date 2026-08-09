# HeyClicky Full-Parity Roadmap

**Status**: STEP 2 of 2 in the "OpenClicky becomes the HeyClicky
replacement" roadmap. Depends on `HEYCLICKY_FREE_TIER_INTEGRATION.md`
being green.

## The bar

**OpenClicky becomes a functional replacement for
`/Applications/HeyClicky.app`.** A user should be able to uninstall
HeyClicky.app, use OpenClicky in its place, and not notice a missing
feature or workflow. UI does NOT have to match pixel-for-pixel;
OpenClicky's design language is its own and stays its own. What must
match is: feature coverage, keyboard shortcuts, activation model, the
mental model of "one small companion sitting in the menu bar".

Explicit non-goals:
- No pixel-level Notch shape reproduction
- No copy-string verbatim match — OpenClicky's own copy stays
- No color-palette identity — swap the cursor picker to the 4 HC
  colors (§F.20) but everything else keeps OpenClicky's theme
- Not removing OpenClicky's own value-add surfaces (§4.4)

## Starting point

- **OpenClicky** is the codebase — ~55% of HeyClicky's specific
  view-set exists, but OpenClicky ships extensive extra features
  (rich provider integrations, wake word, tutor mode, local models,
  automations, external-control bridge) that we keep
- **STEP 1 (`HEYCLICKY_FREE_TIER_INTEGRATION.md`)** fills the backend
  gap — proxy path, A/B accounts, memory sync, auto-reset — as a new
  profile alongside Local / Realtime / Quality
- **This roadmap (STEP 2)** closes remaining HeyClicky-specific
  functional gaps and hardens known issues

## Companion documents (do NOT duplicate their content, cite them)

- `design-notes/settings-profiles-spec.md` — parent design for the
  profile system. STEP 1 adds the 4th profile per §4 of that doc.
- `design-notes/scribble-rectangle-overlays-plan.md` — independent
  design; keep. Not a HeyClicky feature but a legitimate OpenClicky
  differentiator.
- `docs/OpenClickySkillCompatibilityAudit.md` (2026-07-08) —
  authoritative for HeyClicky skill parity. This roadmap DOES NOT
  re-audit skills. Any skill gap surfaces in that doc, not here.
- `docs/CLICKY_SOURCE_SKILL_EXTRACTION_AUDIT.md` (2026-06-17) — origin
  inventory of HeyClicky's bundled skills.
- `docs/APP_UPDATES.md` — Sparkle release flow. F.24 defers to it.
- `docs/FULL_SYSTEM_CODE_REVIEW_2026-06.md` — 4 critical + 15 high
  findings. §R below owns closing them.
- `docs/OPENCLICKY_ARCHITECTURE_REVIEW.md` — provider routing / CUA
  wiring / money rule.

## Source-of-truth resolution

For any "what does HeyClicky do here?" question, consult in order,
first that answers wins:

1. Live **frida** capture against `/Applications/HeyClicky.app`
2. **IDA** on `HeyClicky-1.0.40.i64` (MCP `si48`)
3. `/Users/wowdd1/Dev/clicky-mac/docs/heyclicky-ui.md` + refs (extracted refs)
4. `/Users/wowdd1/Dev/clicky-mac/docs/protocol.md`
5. `/Users/wowdd1/Dev/clicky-mac/docs/py-parity.md`
6. This OpenClicky codebase (working reference, ~55% coverage — cite
   only when 1–5 don't answer)

When two disagree, higher rank wins. Never guess: use `TODO(S.5)` +
`exit 77` in acceptance scripts. Match-vs-improve policy: **match
HeyClicky** for user-observable behavior; deviate only for security
fixes (§R) or documented SKIP (§F).

---

## F. Feature parity table

Status legend:
- **DONE (OC)** — implemented in OpenClicky main
- **DONE (STEP1)** — added by `HEYCLICKY_FREE_TIER_INTEGRATION.md`
- **PARTIAL** — some code exists; ladder subsection completes
- **TODO** — new work here; ladder subsection
- **SKIP** — not implementing; user-visible replacement documented
- **REMOVE** — feature exists in OpenClicky but departs from HC ethos; delete

Rows below verified against audit 2026-07 (see `docs/HEYCLICKY_FULL_PARITY_AUDIT_NOTES.md`
if we later split the audit into its own doc).

| # | Feature | Status | Notes |
|---|---|---|---|
| F.1 | Realtime voice WS + PTT + ephemeral tokens | DONE (STEP1 for Free profile) | `OpenAIRealtimeSpeechClient` for BYOK; `HeyClickySessionTokenClient` for Free |
| F.2 | send_to_higher_model → chat-tool-call | DONE (STEP1) | via `HeyClickyProxyRouter` |
| F.3 | `[POINT:x,y]` overlay + bezier arc | DONE (OC) | verify visual delta via `OverlayWindow.swift` |
| F.4 | LSUIElement (menu-bar-only) | DONE (OC) | |
| F.5 | Multi-monitor overlay | DONE (OC) | |
| F.6 | Supabase-compat auth + Keychain session | DONE (STEP1) | `HeyClickySessionAuthenticator` |
| F.7 | A→B sync | DONE (STEP1) | `HeyClickyMemorySyncService` |
| F.8 | B→A memory reflection (retryVerified 3×) | DONE (STEP1) | `HeyClickyMemoryMigrator` |
| F.9 | Auto-reset A when quota hits 0 | DONE (STEP1) | `HeyClickyAccountResetManager` + chrome bridge |
| F.10 | `x-clicky-*` 6 headers | DONE (STEP1) | `HeyClickyHeaderBuilder` |
| F.11 | BYOK-Anthropic agent loop | DONE (OC) | `ClaudeAgentSDKAPI` — see M16 caveat re assistantPrefill |
| F.12 | Codex app-server JSON-RPC stdio | DONE (OC) | `CodexAgentSession` — see R.C4 for sandbox flags |
| F.13 | ScreenCaptureKit multi-monitor | DONE (OC) | |
| F.14 | Notch UI (silhouette + hover-expand + tabs) | PARTIAL | Real notch via `DynamicNotchKit` (`OpenClickyDynamicNotchKitBridge.swift:60,427-526`). Tabs `[home, agents, connections, settings]` (`OpenClickyNotchPanelView.swift:453`). Missing: **History, Threads, Crons** (see §F.14 detail) |
| F.15 | Text composer + follow-up pill | DONE (OC), structure differs | HUD `ChatWorkspaceView` + notch `homeTab` with `OpenClickyQuickPromptMode` ask/agent/chat. Add follow-up pill (§F.15) |
| F.16 | Dictation | DONE (OC) | `BuddyDictationManager.swift` — verify hands-free wiring |
| F.17 | Hands-free (triple-tap Ctrl) | DONE (OC) | in dictation manager |
| F.18 | Text-trigger shortcut → composer | DONE (OC) | |
| F.19 | Screen annotation (drag circle) | DONE (OC) | `CircleSelectSession.swift` |
| F.20 | Cursor color picker | PARTIAL — palette mismatch | OpenClicky ships 5 (`rose/blue/amber/mint/white`, `OpenClickySettingsWindowManager.swift:783`); HeyClicky ships 4 (red/blue/yellow/green). Swap palette |
| F.21 | Mic device picker + level meter | DONE (OC) | |
| F.22 | Realtime voice picker | DONE (OC) | 10 OpenAI voices (`:235-238`) |
| F.23 | Shortcut re-mapping UI | TODO | HeyClicky ships 4 rows (Talk/Text/Dictate/Hands-free). OpenClicky hardcodes Ctrl+Option (`GlobalPushToTalkShortcutMonitor.swift`); no recorder. Build recorder (§F.23) |
| F.24 | Sparkle auto-updater | DONE (wiring) / OPS (feed empty) | Plumbing complete; publishing first release governed by `docs/APP_UPDATES.md` |
| F.25 | History tab (in notch) | PARTIAL | Backing store exists (`OpenClickyMessageLogStore` + `ConversationSidebarView` + `OpenClickyLogViewerWindowManager`); needs `history` case in `OpenClickyNotchTab` |
| F.26 | Codex HUD (FloatingAgentChip capsule) | PARTIAL | `CodexHUDWindowManager.swift` renders **980×560 workspace** panel, no small transient chip. Split off chip form (§F.26) |
| F.27 | Skills library | See `OpenClickySkillCompatibilityAudit.md` | OpenClicky ships every HeyClicky bundled skill + more; audit is authoritative |
| F.28 | Handoff | SKIP → user Cmd+C via response card | |
| F.29 | Live-event surfaces (meeting/spotify/sidecar) | SKIP → OpenClicky ships no integrations | |
| F.30 | Third-party integrations (30+) | SKIP → agent drives apps via skills; `OpenClickySkillCompatibilityAudit.md` |
| F.31 | Paywall / subscription | SKIP → replaced by profile system (§F.T free-tier profile) |
| F.32 | Onboarding tutorial video | SKIP → OpenClicky's `CompanionManager+Onboarding.swift` inline flow |
| F.33 | Discovery survey | SKIP → dropped |
| F.34 | Analytics (PostHog) | SKIP → `ClickyAnalytics` |
| F.35 | Auto-approve extra usage toggle | SKIP → superseded by reset |
| F.36 | Delete account (user-initiated) | TODO | Modal + `HeyClickyAccountResetManager.deleteAccountPermanently` (STEP 1 provides the engine; UI here) |
| F.37 | Report bug / Request feature / Support links | DONE (OC), verify wiring | Menu-bar items exist per `README.md` |
| F.38 | Places/stocks widgets | SKIP → not primary UX |
| F.39 | Guided-click `[TARGET:...]` follow-up | DONE (OC) | verify regex parity |
| F.40 | Cursor message bubble during response | TODO | Add small transient bubble tied to cursor overlay |
| F.41 | Auto-copy response to clipboard | TODO | danpeg/clicky fork gap; small toggle in Settings |
| F.42 | Notch ambient surfaces | TODO (subset) | HeyClicky has ~15 `Notch*Surface` types (`heyclicky-ui.md §2.10`). Ship the 5 highest-value: NotchActivitySurface, NotchTextResponseSurface, NotchDictationClipboardSurface, NotchAgentSurface, NotchSignedOutPlaceholder |

Every TODO/PARTIAL row has a matching `verify/heyclicky/F<n>.sh`
acceptance script.

---

## R. Regression fixes (from `FULL_SYSTEM_CODE_REVIEW_2026-06.md`)

These block ship-readiness. STEP 2 owns closure of every finding.

**Critical (must fix before release):**

- **R.C1** Browser agent `evaluate` = arbitrary JS on untrusted pages
  (`Packages/OpenClickyBrowser/.../OpenClickyBrowserAgent.swift:268-296`).
  Fix: remove unrestricted `evaluate` OR gate every call behind
  user-confirmation + navigation allow-list + never run agent on
  cookie-imported data store.
- **R.C2** Chrome cookie wholesale import into shared default
  `WKWebsiteDataStore` (`BrowserWorkspace.swift:1870-1889`).
  Fix: per-task store, drop `.all` scope, fix cookie-domain matching.
- **R.C3** BCU HTTP server no auth (`OpenClickyComputerUseRuntime.swift:518-540`).
  Fix: bearer token (mirror external-control bridge's constant-time
  compare pattern from `OpenClickyExternalControlBridge.swift`).
- **R.C4** Codex voice / point detector run `danger-full-access` +
  `approval_policy="never"` on untrusted input
  (`CodexProcessManager.swift:32-34`, `CodexVoiceSession.swift:214-222`,
  `ClickyCodexConfigTemplate.swift:55-58`). Fix: drop those flags or
  add sandbox on untrusted paths.

**High (15 findings)**: enumerated in `FULL_SYSTEM_CODE_REVIEW_2026-06.md`.
Each becomes `R.H<n>.sh` with a regression test in
`cursor-buddyTests/RegressionH<n>Tests.swift` that fails on
pre-fix HEAD and passes post-fix.

---

## A. Additions (TODO from §F)

Cross-referenced with the deep audit; batched by priority.

**P0 (block ship):**
- **A.F14.history** — add `history` case to `OpenClickyNotchTab`, wire
  `OpenClickyMessageLogStore` → notch history rail
- **A.F14.crons** — expose `OpenClickyAutomationStore` as `crons` tab
- **A.F20** — swap cursor palette to `[red, blue, yellow, green]`
- **A.F23** — build shortcut recorder UI (4 rows: Talk / Text /
  Dictate / Hands-free)
- **A.F26** — split `FloatingAgentChip` (small capsule) from
  `CodexHUDWindowManager`'s 980×560 workspace
- **A.F36** — delete-account confirmation modal + wire
  `HeyClickyAccountResetManager.deleteAccountPermanently`
- **A.F42.activity** — `NotchActivitySurface` (Listening / Working /
  Reasoning)
- **A.F42.response** — `NotchTextResponseSurface` with Copy /
  Read Task Report

**P1 (spiritual successor):**
- **A.F14.threads** — thread model + `threads` tab
- **A.F41** — auto-copy toggle
- **A.F40** — cursor message bubble
- **A.F42.dictation** — `NotchDictationClipboardSurface` toast
- **A.F42.agent** — `NotchAgentSurface` with progress + suggested-next

**P2 (polish):**
- `agentSearchButton` for notch tab bar
- `NotchEyeView` idle atom
- `NotchAutoDismissClockButton`
- Menu-bar dropdown items: "Show in Dock", "Undock Cursor",
  "Give me a home"

---

## X. Removals (OpenClicky features that dilute HC minimal ethos)

Deletion candidates. Each is a self-contained subsystem; removal cost
is low; risk is low if no dependent skills exist.

- **X.1 ThreeDViewer / spatial** — `cursor-buddy/ThreeD*.swift` (7
  files) + `TripoThreeDProvider.swift` + `docs/THREE_D_INTEGRATION.md`.
  Zero HC analog. **P1 remove**.
- **X.2 VisualIntelligence workspace** — `OpenClickyVisualIntelligenceWorkspace.swift`
  (40KB). Zero HC analog. **P1 remove**.
- **X.3 Advanced typography sliders** (font, opacity, frosting)
  under `OpenClickySettingsWindowManager.swift:222-224`. Move to
  "Advanced" tab (hide by default). **P2 hide, not delete**.
- **X.4 Widget-content toggles** — hide behind Advanced. **P2**.

Kept as OpenClicky value-add (do NOT remove):
- All extra provider clients (Deepgram, ElevenLabs, Cartesia,
  AssemblyAI, Edge TTS, Apple Speech, Apple FoundationModels,
  Parakeet, OpenAI transcription) — enable the Local / Quality profiles
- Local model downloader
- External-control bridge on 127.0.0.1:32123
- Tutor mode + wake word ("Hey Clicky")
- Pets library (aligns with HC's hatching intent)
- Wiki + memory drawer + log viewer
- Automations engine (promoted to notch tab per A.F14.crons)
- Native + Background CUA runtimes (after R.C3 hardening)
- Browser workspace (after R.C1/C2 hardening)
- OpenClickySDK
- Profile selector + Agent Definition system
- Scribble+rectangle overlays (`design-notes/scribble-rectangle-overlays-plan.md`)

---

## D. Adaptations (feature exists on both sides but implemented differently)

- **D.1** Realtime voice: HeyClicky uses ephemeral tokens; OpenClicky
  uses long-lived WS key. STEP 1 adds ephemeral-token client for the
  HeyClicky Free profile; keep BYOK-WS for Realtime profile.
- **D.2** Codex sandbox: drop `danger-full-access` etc. (R.C4).
- **D.3** Cursor overlay: fix `Color(hex:)` failable init (H11) +
  timer leaks (H8/H9/H10). Then a visual pass; **no pixel-SSIM
  requirement** per the "no pixel-level parity" scope.
- **D.4** Composer: rename `OpenClickyQuickPromptMode` labels to
  HeyClicky-aligned terms; add follow-up pill (A.F42.response
  already covers response side).
- **D.5** Onboarding: keep inline flow. Optionally reuse pet-hatch
  atlas as a first-launch flourish. P2.
- **D.6** Settings navigation: OpenClicky's sidebar window is
  intentionally kept over HeyClicky's notch nav. Combined with
  `design-notes/settings-profiles-spec.md` simplification, this
  becomes ~10 controls with profiles, not ~50 scattered toggles.

---

## §T. Test contract

Three layers (per file):
- **L1 unit** — pure logic, view models, parsers. Snapshot tests via
  `swift-snapshot-testing` (add via `scripts/add-spm.rb` if not present)
- **L2 integration** — mock server + actor round-trips
- **L3 E2E** — signed app + `cliclick` / `CGEventPost` + log-grep

Fixtures under `cursor-buddyTests/Fixtures/` with `.meta.json` sidecar
tracking `heyclicky_version` for staleness detection.

Coverage floor: 60% for new files (`cursor-buddy/HeyClicky*.swift`
and any file this roadmap touches). Baseline OpenClicky today (audit
2026-07) is ~2.7% test-LOC / product-LOC (2111 / 78745, 98 `@Test`
occurrences in 7 files). This roadmap does NOT require raising
baseline — only requires new work meets the 60% floor.

`swift-snapshot-testing` is NOT currently in `project.pbxproj`;
adding it is a real preflight step.

---

## §5. Termination

Roadmap complete when ALL of:
1. STEP 1 (`HEYCLICKY_FREE_TIER_INTEGRATION.md` §9) all green
2. All §R.C* + §R.H* findings closed with regression tests
3. Every P0 §A item shipped
4. Every P0 §X removal done
5. `scripts/sign-and-install.sh` succeeds; TCC preserved
6. `no_collisions.sh` — bundle id / keychain / URL scheme distinct
   from HeyClicky's
7. HeyClicky Free profile e2e passes; other profiles unregressed
8. AGENTS.md + CLAUDE.md rules honored; `xcodebuild` only via
   the sign+install wrapper

P1 items may defer to a follow-up milestone. P2 items are
opportunistic.

---

## §6. Execution order

1. Preflight — IDA snapshot, primitives adapter map cached
2. §R.C1–C4 (security first, unblocks §D.3 too)
3. §R.H* (15 highs)
4. STEP 1 backend (`HEYCLICKY_FREE_TIER_INTEGRATION.md`)
5. §A.F20 palette swap (fast visible win)
6. §A.F14 History + Crons tabs (existing stores → tabs)
7. §A.F26 FloatingAgentChip split
8. §A.F42.activity + §A.F42.response
9. §A.F23 shortcut recorder (largest single feature)
10. §A.F36 delete-account modal
11. §X.1, §X.2 removals
12. §A.F41 auto-copy, §A.F40 cursor bubble
13. §A.F14.threads (last, biggest scope)
14. Polish (P2)

Runtime driver: Claude Code `/loop` skill.

---

## §7. Non-negotiables

Inherits:
- `AGENTS.md` + `CLAUDE.md` (both projects)
- `OpenClickySkillCompatibilityAudit.md` policy items 3–7 (approvals,
  credentials, capability checks, TCC safety)
- Product build+install via `scripts/sign-and-install.sh` (avoid TCC
  reset); test-only `xcodebuild test` permitted
- Never bare `xcodebuild` for product builds
- Every fix to a `FULL_SYSTEM_CODE_REVIEW_2026-06.md` finding ships
  with a regression test that fails on pre-fix HEAD
- No pixel-SSIM requirement (design-language divergence is explicit)
- No skill re-audit; defer to `OpenClickySkillCompatibilityAudit.md`
- No Sparkle release-flow duplication; defer to `docs/APP_UPDATES.md`
