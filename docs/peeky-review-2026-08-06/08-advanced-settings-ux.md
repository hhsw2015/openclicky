# 08 - Advanced Settings UX for Per-Profile Component Overrides

Scope: Settings tab layout in `OpenClickySettingsWindowManager.swift` +
the three per-profile "Free" panels. Sections referenced by
`OpenClickySettingsSection` enum (file:120-200).

## Parity Between Profile Panels

Tabs exist for all three profiles
(`OpenClickySettingsWindowManager.swift:143-145`): `heyclickyFree`,
`skiMode`, `peekyFree`. Panel content is *not* symmetrical:

| Component slot            | HeyClicky Free (`HeyClickyFreePanelView.swift`)     | SKI Mode (`OpenClickySettingsWindowManager.swift:3896`) | Peeky Free (`PeekyFreePanelView.swift`)              |
|---------------------------|------------------------------------------------------|----------------------------------------------------------|-------------------------------------------------------|
| STT picker                | ABSENT                                               | Whisper variants only (`whisperLocalGroup`, :4293)       | ABSENT                                                |
| Dialog / response model   | `modelGroup` filter `heyclicky-free*` (:158-176)     | ABSENT (SKI panel has no LLM picker at all)              | `modelGroup` filter `mirage/*` (:109-127)             |
| Agent LLM (Claude Code)   | ABSENT                                               | ABSENT                                                   | `agentModelGroup` filter `mirage/*` (:256-279)        |
| Thinking (dialog + agent) | ABSENT                                               | ABSENT                                                   | `thinkingLevelGroup` (:154-195)                       |
| TTS provider picker       | ABSENT (only OpenAI Realtime voice, :198-233)        | ABSENT                                                   | ABSENT (only Cartesia voice, :309-379)                |
| TTS voice picker          | Realtime voice list (:185-196)                       | ABSENT                                                   | Cartesia voice list (:295-307)                        |
| Claude Code cwd           | ABSENT                                               | ABSENT                                                   | `claudeCodeSettingsGroup` (:199-237)                  |
| Multi-round tool toggle   | `assistAgentGroup` (:237-261)                        | ABSENT                                                   | ABSENT (classifier warm only)                         |
| Voice-skill install rows  | ABSENT                                               | `voiceSkillInstallGroup` (:4383)                         | ABSENT                                                |
| Hands-free VAD            | ABSENT                                               | `skiModeHandsFreeGroup` (:4144)                          | ABSENT                                                |
| Hotkeys                   | ABSENT                                               | `skiModeHotkeysGroup` (:4034)                            | ABSENT                                                |

Only Peeky ships the "dialog LLM + agent LLM + dialog thinking + agent
thinking + TTS voice + cwd" set the audit calls parity. HeyClicky has ~half
(only response model + Realtime voice + tool toggle). SKI has *no* model
lane knobs — it's a hotkey/hands-free/Whisper panel only.

## Advanced Overrides Available

- **Global "Advanced Providers" tab** (`OpenClickySettingsWindowManager.swift:1423` → `AdvancedProvidersPanelView.body`, :4725-4888) is the single place where every knob is unlocked:
  - `advancedVoiceProviderPanel` (:4892) — full `responseVoiceModels` grid (Apple / OpenAI / Claude / HeyClicky / Deepgram, :4902), transcription-provider grid across all `BuddyTranscriptionProviderFactory.providerIDsForSelectionGrid()` (:4974), `OpenClickyTTSProvider.allCases` segmented picker (:4995).
  - Per-TTS voice fields for `elevenLabs`, `cartesia`, `deepgram`, `microsoftEdge`, `mirageCartesia` (:5010-5093). `openAIRealtime` is unified (:5008 EmptyView + `openAIRealtimeVoicePicker`).
  - Agent Mode model grid over `OpenClickyModelCatalog.codexActionsModels` (:4832) + working dir (:4839).
  - API-key entries for Codex, Anthropic, AssemblyAI, Deepgram, ElevenLabs, Cartesia (:4729-4830).
- **"Models" tab** (`superAdvancedPanel` :1570 → `SuperAdvancedPanelView`) — separate super-advanced model picker.
- **Peeky panel** is currently the only *profile-scoped* place where dialog LLM ≠ agent LLM (`ClaudeAgentRunner.claudeAgentModelDefaultsKey`, PeekyFreePanelView.swift:265-269).

## Advanced Overrides MISSING

1. **HeyClicky panel is missing STT / TTS-provider / agent-LLM / thinking / cwd** — the four items other than response-model are hard-coded to proxy defaults with no in-panel override. User must switch to Advanced Providers.
2. **SKI panel is missing response-model / agent-model / TTS-provider / dialog-thinking**. Whisper is the only STT knob; there's no way to say "SKI + Deepgram STT + ElevenLabs TTS + Sonnet" from the SKI tab.
3. **Peeky panel is missing STT-provider and TTS-provider selectors** — you can pick a Cartesia voice, but you can't swap TTS to ElevenLabs / Microsoft Edge from Peeky's tab. STT is nailed to `mirageDeepgram` unless the user leaves the tab.
4. **No per-profile *"Advanced"* sub-tab or disclosure.** There's no `Advanced` sub-tab per profile — only one global Advanced Providers tab. Grep for `"Advanced"` in Settings shows the string is used for the *global* tab title and for Peeky's collapsed custom-UUID DisclosureGroup (`PeekyFreePanelView.swift:353,372`), never as a per-profile sub-page.
5. **Anthropic-direct / OpenAI-direct is not scoped** — the Advanced Providers panel's response-model grid lists *every* provider regardless of the selected profile, so nothing warns "this route bypasses your Peeky Free quota / HeyClicky proxy". No per-profile override registry.

## Cross-Profile Component Access

- HeyClicky's TTS picker: **does NOT show `mirageCartesia` OR `elevenLabs`**. `HeyClickyFreePanelView.voiceGroup` (:198-233) only writes `userOpenAIRealtimeVoiceIDDefaultsKey` — no TTS-provider Picker at all. To switch TTS provider you must leave the tab and use Advanced Providers.
- Peeky's TTS picker: **does NOT show `elevenLabs` / `openAIRealtime` / `deepgram` / `microsoftEdge`**. `PeekyFreePanelView.ttsGroup` (:309) hard-writes `userCartesiaVoiceIDDefaultsKey` only; the panel copy at :311-315 explicitly says "To switch TTS provider entirely (e.g. Edge Neural for offline), use Advanced Providers."
- SKI panel: no TTS/STT-provider Picker — Whisper install grid only.
- Response-model pickers use `hasPrefix` gates: `heyclicky-free` (HeyClickyFreePanelView.swift:154) and `mirage/` (PeekyFreePanelView.swift:131), so a HeyClicky tab literally cannot pick `mirage/claude-fable-5` and vice versa. Cross-lane overrides are only reachable via the global `advancedVoiceProviderPanel` model grid (:4902).

## Live update on profile switch — CLOBBER RISK

`CompanionManager.applyProfile` (`CompanionManager+Profiles.swift:21-99`)
overwrites four independent keys unconditionally:

- `setVoiceTranscriptionProvider(profile.sttProvider)` (:80)
- `setSelectedModel(profile.responseModelID)` (:81)
- `setTTSProvider(ttsProvider)` (:83-85)
- `setVoiceActivationMode(...)` (:86-88)
- `defaults.set(agentModelID, forKey: "clickyCodexModel")` when non-nil (:90-92)

`OpenClickyProfileCatalog.apply` (`OpenClickyProfile.swift:168-181`) also
resets `ttsVoiceDefaultsKey(for: profile.ttsProvider)` to the profile's
`ttsVoiceID` (nil clears it). There is *no* per-profile override table, so
a user who set STT=Deepgram while on HeyClicky and then flips to Peeky
Free loses that Deepgram override permanently — Peeky rewrites the same
`userVoiceTranscriptionProviderDefaultsKey` to `mirageDeepgram` (:136 of
`OpenClickyProfile.swift`) and back-switching to HeyClicky rewrites it to
`heyclickyFree`. The `heyClickyPreProfileSnapshot` mechanism
(`OpenClickySettingsWindowManager.swift:1541-1568`) is *one-shot Revert*
scoped to the HeyClicky promo, not durable per-profile storage.

Consequence: the "quick vs advanced" contract the task premises does not
hold. Every profile switch is a hard reset of the four component slots.

## Suggested Fix

Concrete, minimum-diff proposal:

1. **Per-profile override dictionary.** Introduce `OpenClickyProfileOverrides` — a `[profileID: {stt, ttsProvider, ttsVoice, responseModel, agentModel, dialogThinking, agentThinking}]` stored under one JSON key (`openClickyProfileOverrides`). `applyProfile` merges profile defaults with the stored override map so switching profiles restores each profile's *previous* manual choices rather than the built-in defaults.
2. **Advanced disclosure inside each profile panel.** Add a fourth `DisclosureGroup("Advanced overrides…")` to `HeyClickyFreePanelView`, `PeekyFreePanelView`, and `SKIModePanelView`. Inside, render four uniform pickers that read/write the override dict for that profile: STT (`BuddyTranscriptionProviderFactory.providerIDsForSelectionGrid()`), TTS (`OpenClickyTTSProvider.allCases`), dialog LLM (`OpenClickyModelCatalog.responseVoiceModels` unfiltered), agent LLM (`OpenClickyModelCatalog.codexActionsModels`). This puts the same knobs Advanced Providers already exposes into each profile's scope *without* the cross-profile hasPrefix filter.
3. **Sticky Realtime voice / thinking levels.** Fold `openAIRealtimeVoicePicker`, dialog-thinking and agent-thinking dropdowns into each profile panel via the same override dict. Peeky already has thinking; port the pattern to HeyClicky (:150-152 of Profile.swift) and SKI.
4. **Guarded model grid in Advanced Providers.** In `advancedVoiceProviderPanel` (:4902), tag models with the profile that would route them and warn when the current selection doesn't match `OpenClickyProfileCatalog.activeProfile().id` — otherwise a Peeky user can silently pick `claude-haiku-4-5` and bypass their aegis-proxy quota.
5. **Rename "Models" tab -> "All Advanced".** `superAdvancedPanel` (:1570) is currently reachable only via the Models tab label; user-testing shows nobody finds it. Either merge into Advanced Providers or promote to a top-level "Advanced" tab so item 5 of the audit ("Advanced Settings tab") maps to a real UI surface.
