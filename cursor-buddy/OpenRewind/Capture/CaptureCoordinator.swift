// CaptureCoordinator — top-level actor that wires the whole capture
// pipeline: ScreenCapture → FrameDedup → Chunker → Writer,
// plus AXCapture + UIEventsMonitor + AudioCapture as side channels.

import Foundation
import Darwin
import CoreGraphics
import ImageIO
import Vision

public actor OpenRewindCaptureCoordinator {

    public enum Status: String, Sendable {
        case stopped, starting, running, degraded, stopping
    }

    public struct Config: Sendable {
        public var vaultRoot: URL
        public var chunker: Chunker.Config
        public init(vaultRoot: URL,
                    chunker: Chunker.Config? = nil) {
            self.vaultRoot = vaultRoot
            self.chunker = chunker ?? Chunker.Config(vaultRoot: vaultRoot)
        }
    }

    // Wiring
    private let permissions = PermissionsManager()
    private let screen = ScreenCapture()
    private let ax = AXCapture()
    private let ui = UIEventsMonitor()
    private let audio = AudioCapture()
    /// System-audio (video playback, meetings, music). Off by default —
    /// callers turn it on with `enableSystemAudio()` after user consent.
    private let systemAudio = SystemAudioCapture()
    private var systemAudioEnabled = false
    /// Phase-2 audio: VAD + segmenter + optional transcriber. Set on
    /// first call to `enableAudioSegmenter(_:)`; host injects its own
    /// AudioTranscriber (whisper.cpp / OpenAI / Ollama).
    private var audioSegmenter: AudioSegmenter?
    private let dedup = FrameDedup()
    /// Extracts the active browser tab URL via AXURL / AppleScript.
    /// Rewind (`BrowserURLAppleScriptCoordinator`) stamps this on every
    /// segment so `openrewind.search websites:["github.com"]` works.
    private let browserURL = BrowserURLCoordinator()
    /// (bundleID → (url, timestamp)). Used by `enrichSegment` to
    /// skip the AppleScript round-trip when the same browser
    /// window is still frontmost after the last capture.
    private var browserURLCache: [String: (String?, Date)] = [:]
    /// Most-recent (bundleID, url) seen — used to detect a segment
    /// boundary and roll to a new segment row when the user tabs or
    /// switches apps mid-chunk.
    private var lastSegmentKey: String?
    /// Event-driven trigger gate — drops SCStream frames when no user
    /// event / interval fallback fired. Profile-agnostic; the largest
    /// storage win (matches Rewind AI's ~15 GB/mo target).
    private let scheduler = CaptureScheduler()
    private let screenLock = ScreenLockStateMonitor()
    private let idleMonitor = IdleMonitor()
    private let privateWin = PrivateWindowDetector()
    private let chunker: Chunker

    private let writer: OpenRewindWriting
    private var currentSegmentId: Int64?
    /// Cached most-recent window title for the OCR row's title column.
    private var currentWindowName: String?
    // FIX(backfill-2026-07-29): (frameId, order-in-chunk) for frames
    // written to disk but not yet linked to a video. On coldChunk we
    // walk this in insertion order and call updateFrameVideoLink so
    // frame rows stop pointing at deleted PNGs.
    private var pendingFrameLinks: [(frameId: Int64, index: Int)] = []
    private var segmentStartedAt: Date = Date()
    private var frameCounter: Int64 = 0
    /// Cap concurrent OCR tasks. 4 Vision requests × 55MB CGImage
    /// per frame flooded ANE (mach_vm_allocate failed 0x4) and
    /// starved SCStream. 1 in-flight is enough at 2 fps.
    private var ocrInFlight: Bool = false
    private var ocrThrottleCounter: Int = 0
    /// FIX(retrace-#2-2026-07-31): stateful hysteresis flag for OCR
    /// memory backpressure. Once set (RSS crossed pause threshold),
    /// only cleared when RSS drops to the resume threshold. Prevents
    /// rapid on/off flap around the boundary.
    private var ocrPausedByMemory: Bool = false
    /// Tile-based incremental OCR — retrace's `TileOCRProcessor`
    /// port. Dices the frame into 64px tiles, diffs each tile
    /// against the previous frame, only OCRs the tiles that
    /// changed. A typing/scrolling desk mutates ~10 % of tiles so
    /// cache hit rate ~90 % → ~5× less OCR CPU + ANE energy.
    /// Falls back to full-frame OCR on the first frame + on
    /// resolution or foreground-app changes (cache is invalidated).
    private let tileOCR = TileOCRProcessor()
    /// Power-aware OCR gate — retrace parity, top 2 in
    /// docs/review-2026-07-29/17-retrace-comparison.md. Defaults
    /// pause OCR under Low Power Mode; battery-only pause is opt-in
    /// (users may want the full pipeline on a laptop off-charger).
    private let powerPolicy: OpenRewindPowerPolicy = .default
    /// FIX(capture-trigger-2026-07-29): one-shot cursor set by the
    /// scheduler / UI-event bridge just before a frame lands. Reset
    /// after each insert. Values: 'scheduled' (2s tick, default),
    /// 'window_change' (frontmost app change), 'click' (leftMouseUp),
    /// 'idle_wake' (came back from idle), 'manual' (⌘R force capture).
    private var pendingTrigger: String?

    /// Callers on the event bus stamp the next frame's trigger.
    /// Race-safe under actor isolation.
    public func noteTrigger(_ t: String) { pendingTrigger = t }
    /// User-controlled pause switch. When true, hot-frame handlers
    /// return early so no PNGs land on disk and no DB rows are written.
    /// Menu-bar toggle flips this via `setCapturePaused(_:)`.
    private var capturePaused: Bool = false
    public func setCapturePaused(_ paused: Bool) { capturePaused = paused }

    /// Ask the internal ScreenCapture actor to re-snapshot
    /// `SCShareableContent` and rebuild its exclusion filter. Host
    /// (OpenClicky) calls this a few seconds after boot so late-opened
    /// host UI (notch, virtual cursor overlays) gets excluded.
    public func refreshExclusionFilter() async {
        await screen.refreshExclusionFilter()
    }
    func markOCRDone() { ocrInFlight = false }
    public func isPaused() -> Bool { capturePaused }
    /// Aggregate: what's currently being captured (bundle id, window
    /// title, frames written since coordinator start).
    public struct CaptureStatus: Sendable {
        public let paused: Bool
        public let bundleID: String?
        public let windowName: String?
        public let framesTotal: Int64
        public let segmentStartedAt: Date
    }
    public func captureStatus() -> CaptureStatus {
        CaptureStatus(paused: capturePaused,
                      bundleID: currentBundleID,
                      windowName: currentWindowName,
                      framesTotal: frameCounter,
                      segmentStartedAt: segmentStartedAt)
    }
    private var currentBundleID: String?

    public private(set) var status: Status = .stopped

    /// FIX(spm-port-2026-07-29): expose the vault root so flag files
    /// can live inside the same directory as the DB. SPM hosts get
    /// their own flag dir; the standalone app is unchanged.
    private let vaultRoot: URL

    public init(config: Config, writer: OpenRewindWriting) {
        self.chunker = Chunker(config: config.chunker)
        self.writer = writer
        self.vaultRoot = config.vaultRoot
    }

    /// Start the whole pipeline. Set `encoder` to plug OpenRewindKit's
    /// Compressor into the cold-chunk rollover.
    public func start(profile: OpenRewindCompressionProfile = .integration,
                      encoder: ChunkEncoder? = nil) async throws {
        status = .starting

        // Permissions
        let snap = await permissions.requestAll()
        if !snap.allGranted {
            status = .degraded
            // Continue anyway — some capture paths (e.g. AX only) may still work.
        }

        // Chunker wiring
        if let encoder = encoder {
            await chunker.setEncoder(encoder)
        }
        await chunker.setHotFrameCallback { [weak self] pngURL, ts in
            guard let self else { return }
            Task { await self.onHotFrame(pngURL: pngURL, ts: ts) }
        }
        await chunker.setColdChunkCallback { [weak self] mp4URL, first, last, sources in
            guard let self else { return }
            Task { await self.onColdChunk(mp4URL: mp4URL,
                                          first: first, last: last,
                                          sourcePNGs: sources) }
        }

        // ScreenCapture wiring — respect user's screen toggle. If the
        // toggle is off we skip SCStream entirely so the recording
        // indicator never lights up.
        let toggles = OpenRewindCaptureToggles.loadFromDefaults()
        if toggles.screenEnabled {
            await screen.setFrameHandler { [weak self] frame in
                guard let self else { return }
                Task { await self.onScreenFrame(frame) }
            }
            // Retrace/Rewind capture rate: 1 frame every 2 seconds (0.5 fps).
// Previously ran 2 fps which flooded ANE and produced blurry
// mid-motion frames.
try await screen.start(fps: 1)
        await screen.startHealthWatchdog(fps: 1)
        }

        // AXCapture wiring
        await ax.setHandler { [weak self] snap in
            guard let self else { return }
            Task { await self.onAXSnapshot(snap) }
        }
        await ax.start(pollInterval: 1.0)

        // UIEventsMonitor wiring
        await ui.setHandler { [weak self] event in
            guard let self else { return }
            Task { await self.onUIEvent(event) }
        }
        await ui.start()

        // Audio (no-op transcriber by default; Phase 4 injects WhisperKit)
        // Microphone — user toggle. Rewind exposes this as a separate
        // Preferences switch from screen recording.
        // FIX(audio-2026-07-31): also spin up the AudioSegmenter so
        // captured PCM turns into m4a segments + Apple Speech
        // transcripts + audio table rows + transcript_word rows +
        // searchable text. Previously `enableAudioSegmenter` existed
        // but nothing called it — user hit the mic toggle and got
        // AVAudioEngine running with zero downstream persistence.
        if toggles.micEnabled {
            // FIX(audio-mic-diag-2026-08-01): mic capture was silently
            // failing to start (probably due to an input-method process
            // holding the mic in exclusive-access mode). Surface the
            // failure to the message log so users can see why their
            // mic never produced any utterances.
            do {
                try await audio.start()
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "openclicky.audio.mic_start_ok",
                    fields: ["provider": "audio_capture"])
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "error",
                    event: "openclicky.audio.mic_start_failed",
                    fields: ["error": "\(error)"])
            }
            await enableAudioSegmenter(vaultRoot: self.vaultRoot)
            // FIX(audio-source-2026-07-31): stamp `mic` on every
            // buffer so downstream `transcript_word.audioSource`
            // reflects the true route. Previous wiring dropped the
            // source arg → every mic transcript wrote audioSource='',
            // indistinguishable from system-audio.
            let seg = self.audioSegmenter
            await audio.setBufferHandler { buf, ts in
                Task { await seg?.ingest(buf, at: ts, source: "mic") }
            }
        }
        if toggles.systemAudioEnabled {
            do {
                try await systemAudio.start()
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "openclicky.audio.systemaudio_start_ok",
                    fields: ["provider": "system_audio"])
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "error",
                    event: "openclicky.audio.systemaudio_start_failed",
                    fields: ["error": "\(error)"])
            }
            systemAudioEnabled = true
            if audioSegmenter == nil {
                await enableAudioSegmenter(vaultRoot: self.vaultRoot)
            }
            let seg = self.audioSegmenter
            await systemAudio.setHandler { buf, ts in
                Task { await seg?.ingest(buf, at: ts, source: "system") }
            }
        }

        // Storage-saving side channels — all feed the same scheduler
        // gate so `.rewindParity` and the aggressive profiles alike get
        // Rewind AI-level daily footprint.
        screenLock.start { [weak self] locked in
            Task { await self?.scheduler.setScreenLocked(locked) }
        }
        idleMonitor.start { [weak self] idle in
            Task { await self?.scheduler.setIdle(idle) }
        }
        privateWin.start { [weak self] active in
            Task { await self?.scheduler.setPrivateWindowActive(active) }
        }

        // Open a segment row up front.
        // FIX(review-2026-07-28) C-2: stamp endedAt = startedAt; stop() will
        // finalise the endDate via updateSegmentEnd. Previously we wrote
        // now+3600s, which puts a bogus future timestamp in the DB.
        let now = Date()
        currentSegmentId = try? writer.insertSegment(
            startedAt: now,
            endedAt: now,
            app: nil, title: nil, url: nil
        )
        segmentStartedAt = now

        status = (status == .degraded) ? .degraded : .running
    }

    /// Opt-in system audio (video playback, meetings, music). Requires
    /// the same Screen Recording TCC permission as video capture.
    /// Rewind gates this behind an explicit consent prompt (see
    /// audio-audit report §5); host apps must obtain consent before
    /// calling this method.
    public func enableSystemAudio(handler: SystemAudioCapture.PCMHandler?
                                            = nil) async throws {
        if let h = handler { await systemAudio.setHandler(h) }
        try await systemAudio.start()
        systemAudioEnabled = true
    }

    /// Enable the phase-2 audio pipeline: VAD + M4A segmentation +
    /// downmix to Whisper 16 kHz mono Int16 + on-device transcription.
    /// When `transcriber` is `nil`, defaults to `AppleSpeechTranscriber`
    /// — Apple's on-device Speech framework, zero extra binary + zero
    /// model download (the OS ships and shares the model with Siri /
    /// system dictation). Host apps that want OpenAI Whisper / Groq /
    /// whisper.cpp instead pass their own `AudioTranscriber`.
    public func enableAudioSegmenter(vaultRoot: URL,
                                     transcriber: AudioTranscriber? = nil)
        async {
        // Pick up the user's audio retention preference so text-only
        // deletes the M4A after transcription completes.
        let retention = OpenRewindCaptureToggles.loadFromDefaults().audioRetention
        let seg = AudioSegmenter(config: AudioSegmenter.Config(
            writer: AudioSegmentWriter.Config(vaultRoot: vaultRoot),
            retention: retention))
        await seg.start()
        // FIX(whisper-2026-07-31): prefer Whisper.cpp local transcription
        // for CER 5% zh-CN quality (vs Apple Speech ~15-20% CER — the
        // one that produced "祝福窗户数学" for "北京大学数学系").
        // Whisper Small model auto-downloads on first use into
        //   ~/Library/Application Support/OpenClicky/models/whisper-small.bin
        // Runs fully on-device via Metal. Fallback to Apple Speech if
        // download / init fails so the pipeline never blocks.
        // FIX(whisper-abi-crash-2026-08-01, RESOLVED 2026-08-04):
        // Vendored libwhisper rebuilt to 1.9.1 matched libggml
        // (see Task #259), and language="auto" bug fixed (nil pointer,
        // not literal string) — Whisper now runs cleanly with
        // large-v3-turbo-q5_0 as the default provider. The
        // `openclicky.transcriber.useWhisper` toggle stays as an
        // opt-OUT so power users can fall back to AppleSpeech, but the
        // default flips to true.
        let useWhisper = (UserDefaults.standard.object(
            forKey: "openclicky.transcriber.useWhisper") as? Bool) ?? true
        let effective: AudioTranscriber
        if let t = transcriber {
            effective = t
        } else if useWhisper {
            // Route through WhisperLocalPreferences so this shares the
            // same model + language settings the PTT lane uses — user
            // picks in Settings → Advanced Providers → Whisper Local.
            // Default model: large-v3-turbo-q5_0 (~547 MB, CER ~3-5%
            // zh-CN, best free option). Language: `auto` (whisper
            // detects zh/en/etc per utterance).
            let modelName = WhisperLocalPreferences.modelName()
            // WhisperCppTranscriber's ctor takes a String; internally
            // it treats empty / "auto" as nil pointer for
            // whisper_full_params.language (the fix landed with
            // Task #260 to stop YouTube-subtitle hallucinations).
            let langPref = WhisperLocalPreferences.language()
            effective = WhisperCppTranscriber.shared(modelName: modelName, language: langPref)
        } else {
            effective = AppleSpeechTranscriber(locale: Locale(identifier: "zh-CN"))
        }
        await seg.setTranscriber(effective)
        // FIX(2026-07-29): wire transcript-word output to the writer.
        // Previously the words handler was never set, so Apple Speech
        // results fell on the floor and `transcript_word` stayed empty.
        // Words also land in `searchRanking.otherText` so ⌘F can find
        // spoken content.
        let writer = self.writer
        await seg.setWordsHandler { [weak self, writer] utt, words in
            guard let self else { return }
            let segId = await self.currentSegmentId ?? 0
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "openclicky.background_transcribe.words_handler_fired",
                fields: [
                    "source": utt.source,
                    "duration_s": String(format: "%.1f", utt.duration),
                    "word_count": String(words.count),
                    "seg_id": String(segId),
                    "preview": String(words.prefix(6).map(\.text).joined(separator: " ").prefix(60))
                ]
            )
            guard segId > 0 else {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice", direction: "internal",
                    event: "openclicky.background_transcribe.dropped_no_segment",
                    fields: ["source": utt.source, "words": String(words.count)]
                )
                return
            }
            // FIX(audio-row-2026-07-29): retention was writing
            // transcript_word rows but never populating the `audio`
            // table, so the m4a on disk had no DB pointer. Insert
            // one audio row per utterance the first time we see it.
            if let url = utt.onDiskURL {
                _ = try? writer.insertAudio(
                    segmentId: segId,
                    path: url.path,
                    startTime: utt.startedAt,
                    duration: utt.duration)
            }
            var offset = 0
            var joined = ""
            for w in words {
                _ = try? writer.insertTranscriptWord(
                    segmentId: segId,
                    word: w.text,
                    startTime: w.start,
                    endTime: w.end,
                    fullTextOffset: offset,
                    speakerId: Int64?.none,
                    audioSource: utt.source)
                if !joined.isEmpty { joined += " " }
                joined += w.text
                offset = joined.count
            }
            if !joined.isEmpty {
                // Also index the transcript so ⌘F can locate spoken
                // content. `otherText` is the FTS5 slot Rewind uses
                // for audio-derived text (title = window name stays
                // OCR-derived).
                // FIX(perf-2026-08-01): detach transcript-index write so
                // the audio segmenter actor is not tied up waiting on
                // SQLite FTS insert (`insertOCR` -> `insertSearchRanking`
                // -> `cjkBigrams` sample-shows ~10 ms on CJK-heavy text).
                let capturedJoined = joined
                let capturedSegId = segId
                Task.detached(priority: .background) { [writer] in
                    let fid = (try? writer.latestFrameId(inSegment: capturedSegId)) ?? 0
                    if fid > 0 {
                        _ = try? writer.insertOCR(
                            frameId: fid,
                            segmentId: capturedSegId,
                            text: "",
                            otherText: capturedJoined,
                            title: nil,
                            nodes: [])
                    }
                }
                _ = utt
            }
        }
        audioSegmenter = seg
        // Route every mic + system-audio buffer into the segmenter.
        await audio.setBufferHandler { [seg] buf, ts in
            Task { await seg.ingest(buf, at: ts, source: "mic") }
        }
        await systemAudio.setHandler { [seg] buf, ts in
            Task { await seg.ingest(buf, at: ts, source: "system") }
        }
    }

    public func stop() async {
        status = .stopping
        await screen.stop()
        await ax.stop()
        await ui.stop()
        await audio.stop()
        await systemAudio.stop()
        await audioSegmenter?.flush()
        screenLock.stop()
        idleMonitor.stop()
        privateWin.stop()
        await chunker.flush()
        // FIX(review-2026-07-28) C-2: close the open segment row so the DB
        // never carries a "runs forever" future endDate.
        if let segId = currentSegmentId {
            _ = try? writer.updateSegmentEnd(id: segId, endedAt: Date())
        }
        status = .stopped
    }

    // MARK: - Pipeline handlers

    private func onScreenFrame(_ frame: CapturedFrame) async {
        // Layer 0: event-driven scheduler. Rewind AI's ~15 GB/mo target
        // needs this — SCStream alone at 2 fps is 173k frames/day, far
        // above what any codec can compress into 500 MB/day. Scheduler
        // drops frames unless a mouseClick / windowChange / interval
        // trigger fired.
        guard await scheduler.shouldCaptureFrame() else { return }

        // FIX(retrace-parity-2026-07-31 #1): feed current cursor into
        // FrameDedup so the mouse-movement bypass can rescue drag /
        // highlight sequences where pixels barely change but the user
        // is actively interacting. CGEvent(source:nil) is a Quartz IPC
        // getter — cheap (<50µs), thread-safe, no AppKit dependency.
        if let ev = CGEvent(source: nil) {
            dedup.setCurrentMousePosition(ev.location)
        }

        // Layer 1: FrameDedup on the frames that pass the gate.
        // FIX(review-2026-07-28) C-3: hop dedup to a background executor
        // so AX / UI / hot / cold callbacks don't queue behind SHA-256.
        let img = frame.image
        let shouldEncode: Bool = await Task.detached(priority: .userInitiated) { [dedup] in
            return dedup.shouldEncode(img)
        }.value
        guard shouldEncode else { return }
        await chunker.ingest(frame)
        // Enrich segment with frontmost app + URL. Rewind's segments
        // are (bundleID, browserUrl) runs; rotate the row when either
        // changes so search-by-site works.
        await enrichSegment(with: frame)
    }

    /// Look up frontmost app + browser URL, roll a new segment row
    /// when either changes vs the last frame's key. Bumps the open
    /// row's endedAt on every frame so external readers see a live
    /// growing window rather than zero-duration until stop() closes.
    /// Actor-safe helper for the fire-and-forget URL refresh Task.
    /// Wrapping in a method keeps the mutation on the coordinator's
    /// isolation domain without exposing `browserURLCache`.
    private func updateBrowserURLCache(bundleID: String, url: String?, stamp: Date) {
        browserURLCache[bundleID] = (url, stamp)
    }

    private func enrichSegment(with frame: CapturedFrame) async {
        // FIX(timeline-app-icon-2026-08-01): frame.windowInfo.bundleID
        // is often nil for SCStream-captured frames. Fall back to the
        // actual frontmost app via NSWorkspace so segment.bundleID is
        // populated correctly (otherwise timeline shows "unknown"
        // blocks with no app icon).
        let frontBundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let bundleID = frame.windowInfo?.bundleID ?? frontBundleID ?? "unknown"
        // FIX(segment-title-2026-07-30): frame.windowInfo?.title is
        // always nil (StreamOutput.frontmostWindowInfo never populates
        // it). Pull a real title from AX so segment rotation reflects
        // intra-app window changes (VS Code file switch, browser tab
        // switch) and the timeline block metadata is complete. AX
        // call is background-threaded and self-skipped to avoid the
        // SwiftUI accessibility crash we hit earlier.
        let axTitle = await Task.detached(priority: .userInitiated) {
            AXCapture.focusedWindowTitle()
        }.value
        let windowName = frame.windowInfo?.title
            ?? axTitle
            ?? "Untitled"
        currentWindowName = windowName
        currentBundleID = bundleID
        // Cache last URL per bundle for 3 s. Browser URL resolution
        // fires AppleScript (~50-300 ms per call, serialised through
        // Apple Events); at 0.5 fps we don't need a fresh URL every
        // frame — window title changes are the real signal for
        // navigation, and the URL rarely changes without a title
        // change. If it does, the 3 s cache eats the staleness.
        let cacheKey = bundleID
        let now = frame.timestamp
        let url: String?
        if let (cachedURL, stamp) = browserURLCache[cacheKey],
           now.timeIntervalSince(stamp) < 3 {
            url = cachedURL
        } else {
            // FIX(perf-audit-2026-07-31): fire-and-forget URL refresh.
            // AppleScript takes 50-300 ms — awaiting it inline blocks
            // subsequent frames through the coordinator actor, causing
            // capture backpressure. Use whatever's in the cache (even
            // stale) for THIS frame's segment; the async task refreshes
            // the cache in the background so the next frame with a new
            // segment key picks up the fresh URL.
            url = browserURLCache[cacheKey]?.0
            let bID = bundleID
            let bURL = browserURL
            Task { [weak self] in
                let fresh = await bURL.urlForFrontmost(bundleID: bID)
                await self?.updateBrowserURLCache(
                    bundleID: bID, url: fresh, stamp: Date())
            }
        }
        let key = "\(bundleID)|\(windowName)|\(url ?? "")"
        if key != lastSegmentKey {
            // Close the previous segment (if any) at this frame's
            // timestamp, then open a new one with the fresh app/url.
            if let prev = currentSegmentId {
                _ = try? writer.updateSegmentEnd(id: prev,
                                                 endedAt: frame.timestamp)
            }
            let now = frame.timestamp
            currentSegmentId = try? writer.insertSegment(
                startedAt: now,
                endedAt: now,
                app: bundleID,
                title: windowName,
                url: url)
            lastSegmentKey = key
        } else if let segId = currentSegmentId {
            _ = try? writer.updateSegmentEnd(id: segId,
                                             endedAt: frame.timestamp)
        }
    }

    /// Poll `<vault>/paused` — presence = paused. Cheap `stat` each
    /// frame; the Browser toggles the flag file from the menu bar.
    private var lastPauseCheck: Date = .distantPast
    private var videoOff: Bool = false
    private var audioOff: Bool = false
    private func checkPauseFile() {
        let now = Date()
        guard now.timeIntervalSince(lastPauseCheck) > 1.0 else { return }
        lastPauseCheck = now
        // FIX(spm-port-2026-07-29): flag files now live under
        // `Config.vaultRoot` so a SPM host with its own vault gets
        // its own flag directory. Falls back to the OpenRewind default
        // path only when Config.vaultRoot points at that default —
        // preserves the Menu Bar's fast-toggle for the standalone app.
        let base = vaultRoot.path + "/"
        capturePaused = FileManager.default.fileExists(atPath: base + "paused")
        videoOff = FileManager.default.fileExists(atPath: base + "video-off")
        audioOff = FileManager.default.fileExists(atPath: base + "audio-off")
    }
    public func isVideoOff() -> Bool { videoOff }
    public func isAudioOff() -> Bool { audioOff }

    private func onHotFrame(pngURL: URL, ts: Date) async {
        checkPauseFile()
        if capturePaused || videoOff {
            // Discard the PNG so paused state doesn't leave orphans.
            try? FileManager.default.removeItem(at: pngURL)
            return
        }
        guard let segId = currentSegmentId else { return }
        frameCounter += 1
        // FIX(capture-trigger-2026-07-29): stamp the trigger source so
        // downstream analytics can distinguish "click landed a frame"
        // from "the 2s scheduler tick fired". Cheapest signal we have
        // is the pendingTrigger cursor (set by `noteTrigger`); default
        // to 'scheduled' when nothing else has claimed the frame.
        let trigger = self.pendingTrigger ?? "scheduled"
        self.pendingTrigger = nil
        let frameId = try? writer.insertFrame(
            segmentId: segId,
            videoId: nil,
            frameIndex: frameCounter,
            capturedAt: ts,
            tempPath: pngURL.path,
            captureTrigger: trigger
        )
        // FIX(review-2026-07-28) C-L: after a frame row lands, stamp
        // frame_processing('ocr') so Rewind's reconciler doesn't re-OCR
        // the same PNG on next start. Writer's INSERT OR IGNORE is
        // idempotent under retries. The OCR pipeline itself lives in
        // OpenRewindKit's ContextExtractor and is invoked upstream — this
        // just records that the frame is downstream-ready.
        guard let fid = frameId else { return }
        pendingFrameLinks.append((fid, pendingFrameLinks.count))
        // Cap: chunker might not close (encoder fault, permission
        // revoke). Prevents unbounded growth over hours/days.
        if pendingFrameLinks.count > 5_000 {
            pendingFrameLinks.removeFirst(pendingFrameLinks.count - 5_000)
        }

        // Capture segment + window title for the OCR row's title slot.
        // BM25 weights title 3× vs text; leaving it nil kills ranking.
        let ocrSegId = currentSegmentId ?? 0
        let winTitle = currentWindowName

        // Concurrency cap: skip OCR if one is still in flight, and
        // gate on process memory (borrowed idea from retrace's
        // VisionOCRMemoryLedger — skip when resident is close to
        // dirtying jetsam). Prevents ANE OOM (mach_vm_allocate 0x4)
        // starving SCStream.
        // FIX(retrace-#7-2026-07-31): redactionReasonPipeline. If the
        // frame's window title or browser URL matches user-configured
        // sensitive patterns, skip OCR entirely (no node/searchRanking
        // rows). Preserves privacy AND saves DB per-frame. Patterns are
        // regex strings in UserDefaults:
        //   openrewind.redactWindowTitlePatterns  → [String]
        //   openrewind.redactBrowserURLPatterns   → [String]
        if let reason = Self.redactionReason(
            title: currentWindowName,
            url: browserURLCache[currentBundleID ?? ""]?.0) {
            _ = try? writer.stampRedactionReason(
                frameId: fid, reason: reason)
            return
        }
        if ocrInFlight { return }
        // FIX(ane-pressure-2026-07-31 v2): throttling REMOVED — the
        // real cause of the ANE mach_vm_allocate storm was the tile
        // size (64 px → 1836 Vision requests per frame). After raising
        // tile size to 384 px (54 requests/frame), the storm is gone
        // and full-recall OCR is affordable again. Every kept frame
        // gets OCR → no gaps in FTS search recall.
        // FIX(power-aware-2026-07-29): retrace `Processing/
        // FrameProcessingQueue.swift:534-550` pauses OCR when the user
        // has toggled `pauseOnBattery` / `pauseOnLowPowerMode`. Same
        // frame keeps writing to disk + FTS metadata; only the Vision
        // pass is skipped, so the timeline stays populated but doesn't
        // eat battery when unplugged.
        if powerPolicy.shouldPauseOCR() {
            NSLog("openrewind-capture: skipping OCR — power policy (battery=%d lpm=%d)",
                  OpenRewindPowerStateMonitor.shared.isOnBattery ? 1 : 0,
                  OpenRewindPowerStateMonitor.shared.isLowPowerMode ? 1 : 0)
            return
        }
        // FIX(retrace-#2-2026-07-31): hysteresis backpressure gate.
        // retrace FrameProcessingQueue.swift:3327-3400 pauses OCR
        // workers at `paused` threshold, resumes ONLY when memory
        // drops to `resume` — prevents thrash between rising/falling
        // memory. Our stateful `ocrPausedByMemory` flag mirrors that.
        // Thresholds scaled for OpenClicky's smaller working set
        // (900 → pause, 750 → resume; retrace uses 1536/1434 for a
        // larger context window).
        let rss = Self.residentMemoryMB()
        if ocrPausedByMemory {
            if rss <= 750 {
                ocrPausedByMemory = false
                NSLog("openrewind-capture: OCR resume — resident %d MB", Int(rss))
            } else {
                return
            }
        } else if rss > 900 {
            ocrPausedByMemory = true
            NSLog("openrewind-capture: OCR pause — resident %d MB (hysteresis 900→750)", Int(rss))
            return
        }
        ocrInFlight = true
        let tileOCR = self.tileOCR
        let curBundleID = currentBundleID
        // FIX(xpc-helper-2026-07-31): route Vision + FTS write through
        // openclicky-ocr-helper (see helpers/openclicky-ocr-helper).
        // The helper runs Vision CPU-only at background QoS in its
        // own address space; the main app pays only a PNG encode +
        // XPC send. That eliminates the 60-80 % CPU spike every ~15 s
        // that felt as virtual-cursor jank when the user scrubbed.
        //
        // The fallback path below (Task.detached running TileOCR +
        // writer.insertOCR directly) is preserved intentionally so a
        // missing / crashing helper degrades to the pre-helper
        // behaviour rather than dropping OCR entirely.
        Task.detached(priority: .background) { [weak self, writer] in
            defer {
                Task { [weak self] in
                    await self?.markOCRDone()
                }
            }
            guard let cg = Self.loadCGImage(pngURL) else { return }
            // Try the XPC helper first. On success we return early
            // and skip the local Vision + FTS path.
            OpenClickyMessageLogStore.shared.append(
                lane: "capture", direction: "internal",
                event: "openclicky.ocr.helper_attempt",
                fields: ["fid": fid])
            do {
                try await OCRHelperClient.shared.process(
                    cgImage: cg,
                    bundleID: curBundleID,
                    frameID: fid,
                    segmentID: ocrSegId,
                    ts: ts,
                    title: winTitle)
                OpenClickyMessageLogStore.shared.append(
                    lane: "capture", direction: "internal",
                    event: "openclicky.ocr.helper_ok",
                    fields: ["fid": fid])
                return
            } catch OCRHelperClient.ClientError.disabledCoolingDown {
                OpenClickyMessageLogStore.shared.append(
                    lane: "capture", direction: "internal",
                    event: "openclicky.ocr.helper_cooling",
                    fields: ["fid": fid])
            } catch {
                OpenClickyMessageLogStore.shared.append(
                    lane: "capture", direction: "error",
                    event: "openclicky.ocr.helper_error_fallback",
                    fields: ["fid": fid, "error": "\(error)"])
            }
            // FIX(memory-ledger-2026-07-29): retrace `VisionOCR.swift:38-100`
            // takes a memory lease before every Vision call and refuses
            // to run when the estimated footprint would push resident
            // past the budget. Complements the crude 900 MB probe by
            // giving a *pre-flight* estimate (Vision working set can
            // spike after we've already committed) and by attributing
            // leaks to tags so we can spot them in logs. See Top 9 in
            // docs/review-2026-07-29/17-retrace-comparison.md.
            guard let ocrLease = OpenRewindVisionOCRMemoryLedger.shared
                .leaseForFrame(width: cg.width, height: cg.height,
                               tag: "ocr.tile.\(fid)") else {
                NSLog("openrewind-capture: OCR refused by memory ledger: %@",
                      OpenRewindVisionOCRMemoryLedger.shared.describe())
                return
            }
            defer { ocrLease.release() }
            do {
                // Tile-based incremental OCR — reuses last frame's
                // per-tile text for unchanged tiles. Typing/scrolling
                // desk mutates <15 % of tiles so 85-90 % of Vision
                // requests are skipped. Cache invalidates on resolution
                // or foreground-app change.
                let pass = try await tileOCR.process(cgImage: cg,
                                                      bundleID: curBundleID)
                let joinedText = pass.regions.map(\.text).joined(separator: "\n")
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let preNodes = pass.regions.map { r in
                    OpenRewindExtractedContext.OCRNode(
                        text: r.text,
                        leftX: Double(r.bbox.origin.x),
                        topY: Double(r.bbox.origin.y),
                        width: Double(r.bbox.width),
                        height: Double(r.bbox.height),
                        confidence: r.confidence)
                }
                let pre = OpenRewindContextExtractor.PrecomputedOCR(
                    text: joinedText, nodes: preNodes)
                let ctx = try await OpenRewindContextExtractor.extract(
                    image: cg,
                    capturedAt: ts,
                    bundleID: curBundleID,
                    ambient: .empty,
                    recognitionLevel: .accurate,
                    thumbnailWidth: 1280,
                    precomputedOCR: pre)
                _ = (w, h)
                let nodes = ctx.ocrNodes.map { OCRNode(text: $0.text,
                                                       bbox: CGRect(
                                                          x: $0.leftX, y: $0.topY,
                                                          width: $0.width, height: $0.height),
                                                       role: "text") }
                do {
                    _ = try writer.insertOCR(
                        frameId: fid,
                        segmentId: ocrSegId,
                        text: ctx.ocrText,
                        otherText: "",
                        title: winTitle,
                        nodes: nodes)
                    _ = try? writer.markFrameProcessed(frameId: fid, type: "ocr")
                    NSLog("openrewind-capture: OCR inserted fid=%lld chars=%d tiles=%d/%d reused=%d",
                          fid, ctx.ocrText.count,
                          pass.changedTiles, pass.totalTiles, pass.reusedTiles)
                } catch {
                    NSLog("openrewind-capture: OCR insert failed fid=%lld err=%@", fid, "\(error)")
                }
                _ = self
            } catch {
                // best-effort
            }
        }
    }

    /// Load a PNG at `url` as CGImage, downscaled to `maxWidth`.
    /// A retina 5K frame is ~55 MB; four concurrent Vision handlers
    /// (OCR + barcode + rect + face) will each retain their copy.
    /// Downscaling once here cuts peak memory ~10×.
    /// Read process resident-set size (MB). Cheap; ~5µs per call.
    /// Used to short-circuit OCR when we're approaching the jetsam
    /// threshold rather than letting ANE OOM the SCStream.
    /// FIX(retrace-#7-2026-07-31): return a redaction reason string
    /// when `title` or `url` matches a user-configured regex; nil to
    /// let the OCR pass proceed normally. Regexes are compiled from
    /// UserDefaults on each call — cheap enough at 2-fps.
    private static func redactionReason(title: String?, url: String?) -> String? {
        let d = UserDefaults.standard
        let titlePats = (d.array(forKey: "openrewind.redactWindowTitlePatterns")
                          as? [String]) ?? []
        let urlPats = (d.array(forKey: "openrewind.redactBrowserURLPatterns")
                        as? [String]) ?? []
        guard !titlePats.isEmpty || !urlPats.isEmpty else { return nil }
        if let t = title, !t.isEmpty {
            for pat in titlePats {
                if t.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil {
                    return "title_pattern"
                }
            }
        }
        if let u = url, !u.isEmpty {
            for pat in urlPats {
                if u.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil {
                    return "url_pattern"
                }
            }
        }
        return nil
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    /// Load full-res CGImage. Retina 3456×2160 ≈ 55MB — heavy, but
    /// downscaling below ~1600 costs OCR quality on small UI text
    /// (6-8px source pixels map to 1-2px after 4× shrink and become
    /// unrecognizable). Retrace keeps native res and offsets memory
    /// with tile-level OCR caching (`TileOCRProcessor`); we currently
    /// pay the memory but preserve accuracy. Resident-memory gate in
    /// `onHotFrame` prevents ANE OOM by skipping OCR when we're close
    /// to jetsam.
    private static func loadCGImage(_ url: URL, maxWidth: Int = 2000) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return img
    }

    private func onColdChunk(mp4URL: URL,
                             first: Date,
                             last: Date,
                             sourcePNGs: [URL]) async {
        let durMs = Int64(last.timeIntervalSince(first) * 1000)
        guard let videoId = try? writer.insertVideo(
            chunkPath: mp4URL.path,
            startedAt: first,
            endedAt: last,
            durationMs: durMs
        ) else { return }
        // Backfill: link every hot frame written to disk while this
        // chunk was open. Matches retrace's `updateFrameVideoLink`
        // (Database/Queries/FrameQueries.swift:76). Without this the
        // frames become orphans — PNG deleted by chunker, videoId
        // never set, `image(for:)` throws "chunk missing".
        let toLink = pendingFrameLinks
        pendingFrameLinks.removeAll(keepingCapacity: true)
        for entry in toLink {
            _ = try? writer.updateFrameVideoLink(
                frameId: entry.frameId,
                videoId: videoId,
                videoFrameIndex: entry.index)
            // Rewind's frame_processing marker — "this frame lives in
            // an mp4, not a hot PNG". Reconciler uses this to skip
            // re-encoding. Type is the string `video`, not `ocr`.
            _ = try? writer.markFrameProcessed(frameId: entry.frameId,
                                              type: "video")
        }
        // FIX(root-cause-2026-07-30): the in-memory `pendingFrameLinks`
        // only survives one process lifetime. Any pending DB row whose
        // frameId got lost (crash, force-quit, cold restart between
        // insertFrame and flush) would sit unlinked forever, showing
        // "no local chunk". Retro-link by TIMESTAMP window as a
        // belt-and-braces backup — noop for rows the in-memory path
        // already covered.
        _ = try? writer.linkPendingFramesToVideo(
            videoId: videoId, startedAt: first, endedAt: last)
    }

    private func onAXSnapshot(_ snap: AXSnapshot) async {
        guard let segId = currentSegmentId, !snap.nodes.isEmpty else { return }
        // Use a placeholder frameId of 0 — the writer knows to attach AX
        // text to the nearest frame by (segment, timestamp) window.
        let joined = snap.nodes.map(\.text).joined(separator: "\n")
        let ocrNodes = snap.nodes.map {
            OCRNode(text: $0.text, bbox: $0.bbox, role: $0.role)
        }
        // AX path: pass frameId=0; writer resolves to newest frame in
        // segment. `otherText` slot carries AX text so bm25 weights
        // it separately from OCR text.
        //
        // FIX(perf-root-2026-08-01): AX snapshots fire ~1 Hz on active
        // apps AND `insertOCR` runs synchronously through
        // `insertSearchRanking` -> `cjkBigrams` -> FTS insert. Sample
        // shows Writer.insertSearchRanking + cjkBigrams as top hitters
        // on the actor executor. Detach so the coordinator actor
        // isn't tied up.
        let capturedTitle = snap.window.title
        let capturedNodes = ocrNodes
        let capturedJoined = joined
        Task.detached(priority: .background) { [writer] in
            _ = try? writer.insertOCR(
                frameId: 0,
                segmentId: segId,
                text: "",
                otherText: capturedJoined,
                title: capturedTitle,
                nodes: capturedNodes
            )
        }
    }

    private func onUIEvent(_ event: UIEvent) async {
        // FIX(perf-2026-08-01): UI events (mouseDown, appSwitch, keyDown)
        // fire many times per second during active use. insertEvent
        // runs SQLite write on the coordinator actor executor — that
        // blocks screen frame ingestion behind it. Detach to a
        // background queue so the actor stays fluid.
        let type = "ui_\(event.kind.rawValue)"
        let ts = event.timestamp
        let app = event.app
        let meta = event.meta
        Task.detached(priority: .utility) { [writer] in
            _ = try? writer.insertEvent(
                type: type, status: "ok",
                capturedAt: ts, app: app, meta: meta
            )
        }
        // Trigger the capture scheduler. mouseDown = highest priority
        // (retrace/Rewind IDA weight 3), appSwitch = windowChange (2).
        // Keyboard input doesn't force a capture — Rewind treats typing
        // as low-signal for visual state changes.
        switch event.kind {
        case .mouseDown:
            await scheduler.onMouseClick()
        case .appSwitch:
            // FIX(retrace-parity-2026-07-31 #2): pass app-switch signature
            // so the scheduler can suppress A→B→A storms.
            let sig = "\(event.app ?? "?")|\(event.meta["title"] ?? "")"
            await scheduler.onWindowChange(signature: sig)
        case .keyDown, .keyUp, .mouseUp, .scroll:
            break
        }
    }
}
