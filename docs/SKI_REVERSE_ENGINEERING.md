# SKI Reverse-Engineering Spec

Blueprint for a native OpenClicky reimplementation of SKI's local voice loop, extracted from the shipped binary `/Applications/SKI.app/Contents/MacOS/ski` (a copy is at `/Users/wowdd1/Dev/heyclicky/ski`, Mach-O arm64, 82.8 MB, version 1.0.1, bundle id `com.patternailabs.ski`).

SKI is a **Tauri 2.11.1** desktop app built from a single Rust crate `ski_lib` (originally `Dictator`). Function anchors below reference Rust module paths and `event src/…rs:LINE` markers embedded in the binary's tracing spans; when a specific IDA address is needed the same string can be located in the binary with `grep -abo` on `ski.i64` and cross-referenced through the plugin bridge (`ida_decompile` accepts either a demangled Rust symbol like `ski_lib::stt::models::…` or the raw file:line span emitted by `tracing::event!`).

Cargo crates that materially shape behaviour (versions from embedded paths):

| Crate | Version | Role |
|---|---|---|
| `tauri` / `tauri-runtime-wry` / `tauri-nspanel` | 2.11.1 | Shell, WKWebView, floating panel |
| `tao` | 0.35.2 | Window primitives |
| `cpal` | 0.15.3 | Fallback audio host |
| `coreaudio-rs` | 0.11.3 | Raw AudioUnit / VPIO |
| `webrtc-audio-processing` (`-sys`) | git snapshot | AEC3 fallback |
| `ort` | 2.0.0-rc.12 | ONNX Runtime (Silero VAD, Kokoro, Parakeet) |
| `whisper-rs-sys` | ~0.14 (build id `aceeee97ef8ba6f3`) | whisper.cpp (Metal) |
| `transcribe-rs` | 0.3.11 | Whisper + Parakeet wrappers |
| `kokoro-en` | 0.1.4 | Native Kokoro TTS pipeline (g2p → synth) |
| `misaki-rs` | 0.3.0 | English g2p fallback / lexicon |
| `rubato` | 0.16.2 | SR conversion |
| `global-hotkey` | 0.7.0 | RegisterEventHotKey |
| `notify` | 7.0.0 | fs-event watcher for `commands.jsonl` |
| `hyper` / `reqwest` 0.12.28 + `rustls` 0.23.40 | — | HTTPS for downloads & OAuth |
| `tauri-plugin-updater` | 2.10.1 | App updates via `https://heyski.io/latest.json` |

Bundle: `LSUIElement=true`, `LSMinimumSystemVersion=14.4`. Entitlements requested: mic, camera-audio-capture (meetings), calendars, screen capture.

---

## A. Model download system  (`src/stt/models.rs`)

**Storage root** (single source of truth): `~/Library/Application Support/SKI/models/`. Resolved by `dirs::data_dir()`; string literal `Application Support/SKI` at `src/stt/models.rs:257`. Kokoro TTS ships inside the bundle at `SKI.app/Contents/Resources/resources/kokoro/`, so only Whisper/Parakeet weights are downloadable.

**Tier catalogue** — enum `ModelTier { Bundled, Downloaded }` (Rust name only; the wire ids are lowercase):

| id (serde) | Label | Files | Size | URL |
|---|---|---|---|---|
| `tiny_en` | `tiny.en` | `ggml-tiny.en-q5_1.bin` | ~32 MB (bundled in `resources/models/`) | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin` |
| `small_en` | *(not shipped label — only URL known)* | `ggml-small.en-q5_1.bin` | ~180 MB | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin` |
| `large_v3_turbo` | `large-v3-turbo` | `ggml-large-v3-turbo-q5_0.bin` | ~547 MB | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin` |
| `parakeet_tdt_0_6b_v3` | `parakeet-tdt-0.6b-v3` | `nemo128.onnx`, `encoder-model.int8.onnx`, `decoder_joint-model.int8.onnx`, `vocab.txt` | ~600 MB | `https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/{filename}` |

Default preference for a new profile: `preferred_stt_tier = "large_v3_turbo"` (verified in `settings.json`). `tiny.en` is available immediately because it is bundled at `resources/models/ggml-tiny.en-q5_1.bin`.

**Downloader** — `reqwest::Client` (HTTP/1.1+2 over rustls). Status shape emitted to the frontend as JSON:

```json
{"tier":"large_v3_turbo","status":"downloading","bytes_done":123456,"bytes_total":574000000}
{"tier":"large_v3_turbo","status":"ready","done":true}
{"tier":"parakeet_tdt_0_6b_v3","status":"error","error":"…"}
```

Field names verified: `tier`, `bundled`, `downloaded`, `size_bytes`, `approx_size_bytes`, `bytes_done`, `bytes_total`, `done`, `error`. **Resumable**: HTTP `Range: bytes=` requests are supported (`content-range` handling present at `src/stt/models.rs:345`, and `http-range 0.1.5` is linked). The downloader writes to `<file>.part` then renames on completion — no separate manifest, no external checksum. **No cryptographic verification** of Whisper/Parakeet payloads; SHA-256 signatures embedded in the binary belong to Tauri CSP hashes for the WebView, not model files. Model integrity is de facto trust-on-Hugging-Face.

Anchors: `event src/stt/models.rs:257` (root dir), `:345`/`:355`/`:397`/`:414` (progress emit points), `bytes_done`/`bytes_total` and `content-range` string block.

UX copy embedded: `"downloading"`, `"ready"`, `"Missing model"` variants; "Metal accelerates the high-quality whisper tier." shown when a Metal device is detected. There is **no `Verifying` / checksum step** in the UI.

---

## B. Audio capture pipeline  (`src/audio/{capture,vpio,vad,aec,process_mute}.rs`)

**Primary path — VoiceProcessingIO** (`src/audio/vpio.rs`). SKI creates a raw AudioUnit of subtype `kAudioUnitSubType_VoiceProcessingIO` (via `coreaudio-rs` `AudioUnit::new(kAudioUnitType_Output, kAudioUnitSubType_VoiceProcessingIO)`); mic AEC is delegated to Apple, and userspace AEC3 is skipped (`vad: mic is system-echo-cancelled (VPIO); skipping userspace AEC`, `src/audio/aec.rs:126`). Output side of the same unit is used for TTS playback so the render buffer is the AEC reference (`audio sink: VoiceProcessingIO render (system AEC reference)`, `src/tts/playback.rs`). The unit is torn down and rebuilt on device switch (`rebuild VoiceProcessingIO`), suspended when mic is muted, and pumps zeros through the mic queue when starving so any in-flight TTS closes cleanly (`feeding silence so in-flight speech closes`).

**Fallback path** — plain `cpal` input stream + WebRTC APM `EchoCanceller3` (`AEC3 Full @ 48 kHz`) when VPIO cannot be created. AEC3 render delay is user-configurable via `aec_stream_delay_ms` (default 100 in `settings.json`). Ducking: VPIO advanced property `"other-audio ducking set to Min, advanced (voice-activity-gated)"` at `src/audio/vpio.rs:206`.

**Sample rate & framing** — Mic is captured at the device's native rate, then resampled to **16 kHz mono f32** via `rubato` (`ski-vpio-resample` thread). Silero VAD operates on 16 kHz frames; the ONNX model file is `resources/models/silero_vad.onnx` (v4-era, 2.3 MB). Whisper/Parakeet also consume the same 16 kHz stream.

**VAD** (`src/audio/vad.rs`). Config from `settings.json`:

- `vad_threshold` — default **0.3** (Silero speech probability).
- `vad_silence_ms` — default **2000 ms**; this is the end-of-speech hangover. When the smoothed probability stays below threshold for that many ms after speech has begun, the utterance is closed and forwarded to STT.

Emitted spans: `src/audio/vad.rs:80/117/144/199/208/243/262/264/282/289`. VAD also drives the `duck-other-audio` gate on VPIO.

**Input device selection** — `mic_device` in `settings.json` (default `"MacBook Pro Microphone"`) is a plain device-name match against the CoreAudio device list. Missing device → falls back to system default; `"no default input device"` is a fatal-but-recoverable state.

**Mute mechanics** — soft mute (`fn_key_mute = true`) records `mic_muted_ranges` in the session manifest so the transcript can mark those regions as system rather than user (`SessionTurn.who: "mic" | "system"`).

---

## C. Whisper.cpp / Parakeet integration  (`src/stt/whisper.rs`, `transcribe-rs 0.3.11`)

Rust wrapper is `transcribe-rs`; `whisper-rs-sys` links whisper.cpp with Metal enabled. Model selection is by tier id from `preferred_stt_tier`. Streaming is done by running whisper on VAD-closed utterances (not incrementally over rolling audio); the emitter distinguishes `partial` vs `final` (`"partial": false` in `~/.ski/transcripts.jsonl`).

Whisper params observed (embedded strings): `n_threads` set from CPU count; greedy sampling only. No `initial_prompt`. Language is **not autodetected** for English models (`tiny_en`, `small_en` are English-only builds); `large-v3-turbo` runs multilingual with autodetect enabled — evidence: recorded transcripts contain "您好" / "你好" segments alongside English, so language is left at auto for the multilingual tier.

For Parakeet TDT (0.6B v3): ONNX inputs `audio_signal`, `length`, `encoder_outputs`, `targets`, `target_length`, `input_states_1/2`, outputs `outputs`, `output_states_1/2`. `vocab.txt` includes a `<blk>` token; missing it aborts. Decoding is greedy joint (RNN-T style). Anchors: `transcribe_rs::onnx::parakeet`, `transcribe-rs-0.3.11/src/onnx/parakeet/mod.rs`.

Emit shape (per `~/.ski/transcripts.jsonl`, verified live):

```json
{"text":"You'll see you.","duration_ms":539,"audio_seconds":2.72,"ts":1785810005.641,"partial":false}
```

Post-processing is minimal: whisper's punctuation is kept as-is; SKI drops empty strings silently but still writes an empty-text line for correlation. There is no manual deduplication layer.

---

## D. Agent forwarding — `~/.ski/agents.sock` and per-project JSONL  (`src/ipc/{agent_socket,bridge}.rs`)

**Global socket** `~/.ski/agents.sock` (`AF_UNIX`, `SOCK_STREAM`, non-blocking listener). Handshake is a single newline-terminated JSON hello from the agent side, verified against the shipped `heartbeat.py`:

```json
{"hello":"ski-heartbeat","project_root":"/abs/path","skill_dir":"/abs/skill/path","pid":12345}
```

Widget then holds the socket open and drains up to 64 B every 5 s. Close = agent shell died. On accept the widget auto-binds `project_root` into its list (`~/.ski/projects.json`) and (Phase AS) touches `skill_dir/SKILL.md` when it needs to heal an install.

Ancillary session id embedded in outgoing events: `session_id = SHA-256(absolute project path)[:16 hex]` (documented in `SKILL.md`; deterministic, so restarts reuse it).

**Per-project transport** — for each bound project, SKI watches `<project>/.ski/commands.jsonl` (via `notify` fs-events, ~500 ms debounce) and appends to `<project>/.ski/events.jsonl`. Line format is one JSON object per line, always ending `\n`. Fields verified in binary tag tables:

- Common: `session_id`, `ts` (unix seconds, f64), `text`, `duration_ms`, `audio_seconds`, `system`, `screenshots` (array of absolute PNG paths), `reason`, `path`.
- Meeting-specific: `url`, `bot_name`, `notetaker` (bool), `mode`, `transcript_path`, `summary_path`.
- Voice command: `voice`, `prefix_project_name` (bool), `speed` (float, TTS only).

Rust enums (`internally tagged enum AgentCommand`) — variant list confirmed in binary at "struct variant AgentCommand::{TtsSpeak,TtsCancel,VoiceSet,AgentHeartbeat,AgentCallJoined,AgentCallLeft,SummaryFailed,SummaryReady,ScreenCapture}". Wire form uses the dotted lowercase name:

Events → agent (append-only to `events.jsonl`):
`session.started`, `utterance.final`, `tts.done`, `tts.interrupted`, `meeting.join_request`, `agentcall.leave`, `screen.captured`, `screen.capture_failed`, `summarize`.

Commands ← agent (append-only to `commands.jsonl`):
`tts.speak`, `tts.cancel`, `voice.set`, `agentcall.joined`, `agentcall.left`, `screen.capture`, `agent.heartbeat`, `summary.ready`, `summary.failed`.

Sample lines (from `SKILL.md`, matched to binary):

```json
{"event":"session.started","session_id":"…","project":"…","voice":"af_heart","ts":…}
{"event":"utterance.final","session_id":"…","text":"…","duration_ms":2400,"audio_seconds":2.4,"ts":…,"screenshots":["/abs/.ski/screenshots/2026-07-15-121314.png"]}
{"event":"meeting.join_request","url":"https://meet.google.com/…","mode":"webpage-av-screenshare","bot_name":"SKI","notetaker":false,"ts":…}
{"command":"tts.speak","text":"…","session_id":"…","prefix_project_name":false}
{"command":"screen.capture","session_id":"…"}
```

**No ack**: commands are fire-and-forget. Idempotency comes from the fs watcher only reading new tail bytes. There is **no rotation** in the current build — files grow unbounded — but a `ski-shots-sweeper` thread does prune old screenshots on a schedule (interval not printed).

Session metadata additionally lives at `~/.ski/sessions/<slug>/manifest.json` (per-project) with:

```json
{"dir":"law-7cc6d9d0","project_name":"law","project_root":"/abs","started_ts":…,"last_ts":…,"turns":33}
```

Anchors: `src/ipc/agent_socket.rs:123/126/130/178/183`, `src/ipc/bridge.rs:40/46/84/98/140/150/152/173/180/187/229/231/234`.

---

## E. TTS pipeline (Kokoro)  (`src/tts/{mod,native,playback,sidecar}.rs`)

**Two engines coexist. The native Rust path is primary; the Python sidecar is the fallback** ("tts speak worker offline; falling back to sidecar", `src/lib.rs:795`).

### Native engine (`src/tts/native.rs` + `kokoro-en 0.1.4`)

- Runtime: `ort 2.0.0-rc.12` with `CoreMLExecutionProvider` first-choice, `CPUExecutionProvider` fallback (`"kokoro ort | using CoreML execution provider (model_format=…, using NeuralNetwork)"` vs `"kokoro ort | CoreML unavailable, falling back to CPU provider"`).
- CoreML config: `MLProgram` requested, downgrades to `NeuralNetwork` when unsupported nodes are hit ("exceeds CoreML convolution memory limit of 16384"); compute units `CPUAndNeuralEngine` / `CPUAndGPU` / `CPUOnly`.
- Model file: `resources/kokoro/models/model_quantized.onnx` (88.1 MB, INT8-quantised Kokoro 82M). The binary also references `kokoro-v1.0.onnx` and `voices-v1.0.bin` names for compatibility, but only the quantised model plus 4 individual voice bin files are shipped.
- Voice packs: `resources/kokoro/voices/{af_heart,am_adam,bf_emma,bm_george}.bin`, each **522,240 bytes** = a `[510 × 1 × 256]` f32 style tensor (255 mel-position × 512 chan compressed; layout is the Kokoro reference voice pack format). Header-less raw f32 little-endian.
- Grapheme-to-phoneme: `kokoro-en` uses `misaki-rs` as its lexicon + POS tagger; the huge POS/tag JSON dumps embedded in the binary (~5 MB of `{"i-1 suffix X": {...}}` entries) are the misaki tagger weights. When a token has no lexicon entry, `kokoro-en` shells out to `espeak-ng` (env vars `KOKORO_ESPEAK_NG`, `KOKORO_G2P_REQUIRE_ESPEAK`, `KOKORO_G2P_SEGMENT_ESPEAK`). SKI **does not bundle** an espeak binary; the fallback is only used if the user has one on PATH.
- Sample rate output: Kokoro emits **24 kHz f32 mono** (embedded in the ONNX model's sample_size metadata). Playback resamples through `rubato` if the output device is at a different rate.
- Synthesis is **utterance-scoped, not streaming**: one text → one f32 buffer → played on the VPIO output side. The `synthesizer.rs` / `pipeline.rs` modules chunk long strings on sentence boundaries via `text_split.rs`.

### Python sidecar (`resources/scripts/tts_sidecar.py`, `src/tts/sidecar.rs`)

Long-lived process managed by `std::process::Command`. Loaded on demand only when the native path fails. Protocol (verified in source):

- stdin (JSONL): `{"text":"…","voice":"af_heart","speed":1.0}`, `{"cmd":"stop"}`, `{"cmd":"exit"}`.
- stdout (JSONL): `{"event":"ready"}`, `{"event":"speak.start","id":…}`, `{"event":"speak.done","id":…,"interrupted":true|false}`, `{"event":"speak.error","id":…,"reason":…}`.
- Deps: `kokoro_onnx`, `sounddevice`, `numpy`. Invoked as `python3 tts_sidecar.py <model_path> <voices_path>` — Rust locates a system Python 3 (no bundled interpreter) and expects `voices-v1.0.bin` layout when this path is used. Spawn is retry-once on failure.

Rust IPC to sidecar: three named threads `ski-tts-stdin`, `ski-tts-stdout`, `ski-tts-stderr`.

---

## F. Playback + barge-in  (`src/tts/playback.rs`, `src/audio/vpio.rs`)

The output side of the same `VoiceProcessingIO` AudioUnit that captures the mic is also the TTS sink (`build_output_stream<f32>` / `<i16>` / `<u16>` branches, `event src/tts/playback.rs:70/156/216/226/281`). This is intentional: because the render buffer is fed back to AEC3-in-the-Apple-side as the reference, TTS audio never leaks into the transcribed mic path.

**Barge-in**:

1. VAD signals `speech_start` while TTS is in-flight → `TtsController::interrupt()` is called (`tts_interrupt` Tauri command exists for UI too).
2. Native path clears the pending sample queue and lets the current callback drain (~10 ms) then submits silence; `tts.interrupted` event is emitted with the current session id.
3. Sidecar path sends `{"cmd":"stop"}\n`, the Python worker calls `sd.stop()` and returns `speak.done{"interrupted":true}`.

There is **no crossfade** — the queue is truncated hard, and one buffer's worth of silence is fed before the next utterance can start. The mic starvation feeder (`feeding silence so in-flight speech closes`) exists specifically for the case where the mic thread is stalled and TTS would otherwise loop; it forces VPIO to close the render side gracefully.

---

## G. Screen capture  (`src/lib.rs` around lines 2046/2203)

Yes — shell out to `/usr/sbin/screencapture -x -Z --out <path>` (verified strings: `/usr/sbin/screencapture`, `-x`, `-Z`, `--out`). `-x` disables the shutter sound, `-Z` prevents dropping to disk in the interactive picker. Full-resolution PNG.

**Path** — `<project_root>/.ski/screenshots/<YYYY-MM-DD-HHMMSS>.png` (format string `%Y-%m-%d-%H%M%S`). Old screenshots are pruned by a `ski-shots-sweeper` background thread.

**Thumbnail** — `/usr/bin/sips -s format jpeg -s formatOptions 80 -Z <size> --out <thumb>`. The 80 is JPEG quality, `-Z` is max-dimension resize. This is used for the notch/session preview.

**Hotkey binding** — `global-hotkey 0.7.0` on macOS uses Carbon `RegisterEventHotKey` (`RegisterEventHotKey failed for` error string present). Default binding from `settings.json`: `capture_screen: "Control+Shift+S"`; other bindings: `toggle_mute` (`Control+Shift+A`), `next_project` (`Control+Shift+D`), `toggle_silent` (`Control+Shift+V`), `toggle_widget` (null). No `NSEvent.addGlobalMonitor` path — everything is Carbon.

**Fn-key** — a separate path (`src/fn_key.rs`) reads `com.apple.HIToolbox` `AppleFnUsageType` via `/usr/bin/defaults read` and installs a CGEventTap-style listener requiring Accessibility (`AXTrustedCheckOptionPrompt`). Fn tap toggles mute, Fn hold acts as push-to-talk. Config: `fn_key_mute` (settings default `true`). "Screen Recording" permission gating uses `screen_recording_permission` error reason emitted on `screen.capture_failed`.

---

## H. Notch / pill UI  (`src/window/macos_nspanel.rs`, `tauri-nspanel` custom fork)

**Runtime is Tauri 2.11.1 over WKWebView** — there is no SwiftUI. The main webview loads `index.html` (dev URL `http://localhost:1420/` when built locally). Windows: `main` (hidden shell), `notch-caption`, `onboarding` ("Welcome to SKI"), `preferences` ("SKI Preferences"), `meeting-transcripts`, and a menu-bar tray.

The notch pill is implemented by **converting the `notch-caption` window to an `NSPanel`** through the pinned `tauri-nspanel` fork (`/Users/patternailabs/.cargo/git/checkouts/tauri-nspanel-cab3955568b3504c/a3122e8/src/lib.rs`). Once converted the panel becomes:

- Non-activating (`NSWindowStyleMaskNonactivatingPanel`), floating, fullscreen-auxiliary — visible over full-screen apps.
- Windowless-chrome: `decorations:false`, `transparent:true`, `alwaysOnTop:true`, `visibleOnAllWorkspaces:true`, `skipTaskbar:true`.
- Uses `NSVisualEffectView` (custom subclass in `src/macos/ns_visual_effect_view_tagged.rs`) to get the frosted "live-glass" look. Not a MacOS 14.4-only NSMenuBar API — the notch shape is just a rounded rectangle NSPanel positioned under the physical notch. Live-glass is `NSVisualEffectMaterial` `.hudWindow` or `.sidebar` with radius applied via a CAShapeLayer.
- `widget_mode` setting toggles between `"notch"` (top-center pill) and `"pill"` (floating chip elsewhere). Command `notch_set_size` (Tauri IPC) drives resize animations.

Menu bar item is `NSStatusBar.system` with items `ski_menu_prefs`, `ski_menu_switch_notch`, `ski_menu_switch_pill`, `ski_menu_restart`, `ski_menu_quit`, `ski_menu_update`.

Tauri IPC commands exposed to the webview (from the binary's ACL): `mic_start`, `mic_set_muted`, `mic_status`, `mic_level`, `mic_stop`, `vad_stop`, `stt_stop`, `ipc_bind`, `tts_stop`, `tts_start`, `tts_speak`, `tts_interrupt`, `speak_stub`, `session_load`, `session_delete`, `session_tail`, `settings_load`, `settings_save`, `settings_save_field`, `settings_effective`, `settings_clear_project_field`, `notch_set_size`, `caption_present`, `caption_dismiss`, `widget_mode_begin`, `widget_mode_finalize`, `widget_context_menu`, `hotkey_try_bind`, `fn_key_status`, `fn_key_request_trust`, `fn_key_sync`, `update_check`, `update_apply`, `open_url`, `onboarding_detect_agents`, `onboarding_install_agent`, `onboarding_finish`, `onboarding_take_resume_step`, `onboarding_set_resume_step`, `onboarding_restart_at`, `agentcall_start_email`, `agentcall_verify_email`, `agentcall_leave`, `agentcall_meetings`, `meeting_status`, `meeting_join_request`, `meeting_delete`, `meeting_rename`, `meeting_export`, `calendar_google_connect`, `calendar_google_disconnect`, `calendar_google_create_meeting`, `apple_calendar_status`, `apple_calendar_connect`, `apple_calendar_disconnect`, `calendar_meeting_pref_set`, `calendar_meeting_pref_clear`, `calendar_disarm_all`, `calendar_pending_list`, `calendar_pending_resend`, `calendar_pending_cancel`, `calendar_send_now`, `calendar_open_window`, `dashboard_section_get`, `skill_export`, `summarize_recording`, `calendar_meetings_list`, `refresh`, `screen_capture_take`.

Webview-side events pushed via `emit`: `ski://active-project-changed`, `ski://cal-notify`, `ski://mute-changed`, `ski://onboarding-finished`, `ski://projects-changed`, `ski://screen-flash`, `ski://screen-warn`, `ski://update-state`, `ski://widget-mode-changed`, `ski://menu-quit`, `ski://prefs-opened`, `ski://dashboard-section`.

Content-Security-Policy hashes present in the binary (`'sha256-HmxGE7GTqkALoCyGdUVDjbNo5BNLNdnKvHvfLB1PNS0='` etc.) show that inline scripts in the webview are pinned.

---

## Persistent state files (all under `~/.ski/`)

| File | Purpose |
|---|---|
| `settings.json` | User profile (see keys inline above) |
| `install.json` | `{"first_launch_ts":…,"version":1}` |
| `launches.json` | JSON array of launch timestamps (analytics-lite) |
| `projects.json` | `{"projects":[…],"active":"…"}` |
| `bound.json` | Array of currently-bound project roots |
| `analytics.json` | Counters: `agent_replies`, `tts_words`, `first_reply`, `tts_cancels`, `utterances`, `words`, `talk_seconds`, `first_utterance`, `skill_installed`, `mic_muted_seconds_total` … |
| `transcripts.jsonl` | Global transcript stream (per-session copies also under `sessions/*/transcript.jsonl`) |
| `sessions/<slug>/{manifest,transcript}.json[l]` | Per-project session record |
| `agentcall-meetings/`, `meetings/` | Meeting transcripts + `.summary.md` outputs |
| `agents.sock` | UDS listener |

Cloud endpoints called: Google OAuth (`accounts.google.com/o/oauth2/v2/auth`, `oauth2.googleapis.com/token`, `www.googleapis.com/oauth2/v2/userinfo`, `www.googleapis.com/calendar/v3/…`), AgentCall (`https://api.agentcall.dev`), Tauri updater (`https://heyski.io/latest.json`), PostHog (`https://us.i.posthog.com`, gated by `telemetry_enabled` which defaults to `false`). **No SKI backend is required for the local voice loop** — OAuth, AgentCall, and updater are all optional paths the OpenClicky port can omit.

---

## Reimplementation notes for OpenClicky

1. **Storage layout** — Put models under `~/Library/Application Support/OpenClicky/models/` with the same file names as SKI so migration is a symlink; keep IPC files under `<project>/.openclicky/` to avoid colliding with a running SKI install.
2. **Native audio** — Use `AVAudioEngine` with `.voiceChat` input mode, or the raw `kAudioUnitSubType_VoiceProcessingIO` unit, to inherit Apple AEC. VPIO alone eliminates the WebRTC dependency in OpenClicky (Swift equivalents of `webrtc-audio-processing` don't exist without a C++ pull-in).
3. **VAD / STT** — Silero VAD ONNX plus `whisper.cpp` (Metal build) via a small Swift wrapper covers the same tiers. Model download can reuse `URLSession` background downloads with resume data (equivalent to SKI's Range logic) and identical URLs.
4. **TTS** — CoreML-runnable Kokoro ONNX plus the four bundled voice bins (`.bin` files are raw f32 style tensors, load directly with `Data → [Float]`). If a Rust runtime is unwanted, `MLModel` compiled from the ONNX via `coremlc` is a valid substitute.
5. **IPC** — Keep the same JSONL protocol and `~/.openclicky/agents.sock` name so existing SKILL.md-shaped agents work with minimal changes. The full command / event vocabulary above is small enough to type-check with a Swift enum.
6. **UI** — SKI's pill is `NSPanel` behaviour that SwiftUI can express through `NSHostingController` inside a custom `NSPanel` subclass with `.nonactivatingPanel` style; OpenClicky already has `OpenClickyNotchCaptureWindowManager` and can reuse it.
7. **Hotkeys** — `RegisterEventHotKey` (Carbon) matches SKI 1:1; the `Fn` push-to-talk path needs an `NSEvent` global monitor plus Accessibility trust, matching `com.apple.HIToolbox` `AppleFnUsageType` reads.
8. **Update path** — Skip Tauri updater; hook into the existing OpenClicky Sparkle-less update mechanism.
