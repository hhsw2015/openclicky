//
//  OpenClickyScreenHistorySettingsSection.swift
//  cursor-buddy
//
//  Settings surface for the embedded OpenRewind (Screen History)
//  subsystem. Presents the user-facing name "Screen History" — the
//  internal implementation is OpenRewind, but nothing in this panel
//  says "rewind" so the feature reads as a native OpenClicky
//  capability.
//
//  All configuration lives under `openclicky.screenHistory.*` in
//  UserDefaults. Once OpenRewindKit/Capture are wired in, an adapter
//  reads these keys and forwards to the OpenRewind coordinator; the
//  UI itself never touches OpenRewind types.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Defaults keys

enum ScreenHistoryDefaults {
    static let enabledKey            = "openclicky.screenHistory.enabled"
    static let captureScreenKey      = "openclicky.screenHistory.capture.screen"
    static let captureMicKey         = "openclicky.screenHistory.capture.mic"
    static let captureSystemAudioKey = "openclicky.screenHistory.capture.systemAudio"
    static let captureUIEventsKey    = "openclicky.screenHistory.capture.uiEvents"
    static let captureCalendarKey    = "openclicky.screenHistory.capture.calendar"
    static let excludedBundleIDsKey  = "openclicky.screenHistory.excluded.bundleIDs"
    static let retentionDaysKey      = "openclicky.screenHistory.retention.days"
    static let compressionProfileKey = "openclicky.screenHistory.compression.profile"
    // Time picker choices need finer granularity than the default 30/90/180/365
    // dropdown offered. Adds 1-day + 7-day options for users who only want a
    // short rolling window.
    // Hotkey defaults keys — full OpenRewind parity (9 shortcuts).
    // Default values map to `openrewind.<name>` under UserDefaults so
    // the underlying KeyboardShortcuts library reads the same slot the
    // upstream OpenRewind app writes to. showWindow has an upstream
    // default of ⌥Space; the rest ship blank.
    static let hotkeyShowWindowKey     = "openrewind.showWindow"
    static let hotkeyOpenSearchKey     = "openrewind.openSearch"
    static let hotkeyOpenSettingsKey   = "openrewind.openSettings"
    static let hotkeyTogglePlaybackKey = "openrewind.togglePlayback"
    static let hotkeyStarMomentKey     = "openrewind.starMoment"
    static let hotkeyJumpToLatestKey   = "openrewind.jumpToLatest"
    static let hotkeyPrevEntryKey      = "openrewind.prevEntry"
    static let hotkeyNextEntryKey      = "openrewind.nextEntry"
    static let hotkeyJumpToDateTimeKey = "openrewind.jumpToDateTime"
    // OpenClicky-only extras.
    static let hotkeyPauseKey          = "openclicky.screenHistory.hotkey.pauseToggle"
    static let hotkeyJumpFrameKey      = "openclicky.screenHistory.hotkey.jumpToCurrent"
    // Parity with OpenRewind Browser SettingsSheet.
    static let audioRetentionKey     = "openclicky.screenHistory.audio.retention"
    static let vaultModeKey          = "openclicky.screenHistory.vault.mode"
    /// OFF by default. Timeline search stays cheap plain-FTS unless
    /// the user flips this toggle. When on, RRF-fuses FTS with Apple
    /// NLEmbedding vector matches — better recall for paraphrase /
    /// synonym queries at the cost of ~50-100ms per keystroke.
    static let timelineHybridSearchKey = "openclicky.screenHistory.timeline.hybridSearch"

    static func bool(_ key: String, default value: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func int(_ key: String, default value: Int) -> Int {
        if UserDefaults.standard.object(forKey: key) == nil { return value }
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored == 0 ? value : stored
    }

    static func string(_ key: String, default value: String = "") -> String {
        UserDefaults.standard.string(forKey: key) ?? value
    }
}

// MARK: - Section view

struct OpenClickyScreenHistorySettingsSection: View {

    @AppStorage(ScreenHistoryDefaults.enabledKey)            private var enabled: Bool = false
    @AppStorage(ScreenHistoryDefaults.captureScreenKey)      private var captureScreen: Bool = true
    @AppStorage(ScreenHistoryDefaults.captureMicKey)         private var captureMic: Bool = false
    @AppStorage(ScreenHistoryDefaults.captureSystemAudioKey) private var captureSystemAudio: Bool = false
    @AppStorage(ScreenHistoryDefaults.captureUIEventsKey)    private var captureUIEvents: Bool = false
    @AppStorage(ScreenHistoryDefaults.captureCalendarKey)    private var captureCalendar: Bool = false
    @AppStorage(ScreenHistoryDefaults.excludedBundleIDsKey)  private var excludedRaw: String = ""
    // FIX(retrace-#15+#7-2026-07-31): custom private-title & redaction patterns.
    @AppStorage("openrewind.privateTitleFragments.raw")       private var privateTitleRaw: String = ""
    @AppStorage("openrewind.redactWindowTitlePatterns.raw")   private var redactTitleRaw: String = ""
    @AppStorage("openrewind.redactBrowserURLPatterns.raw")    private var redactURLRaw: String = ""
    /// FIX(product-polish-2026-07-31 #6): vault-bytes cached so the
    /// Settings pane doesn't stall on a whole-tree du every rebuild.
    /// Updated asynchronously; UI shows the last known value while
    /// the next probe runs off-main.
    @State private var cachedVaultBytes: Int64 = 0
    @State private var vaultBytesRefreshing: Bool = false
    @AppStorage(ScreenHistoryDefaults.retentionDaysKey)      private var retentionDays: Int = 90
    @AppStorage(ScreenHistoryDefaults.compressionProfileKey) private var compressionProfile: String = "integration"
    @AppStorage(ScreenHistoryDefaults.hotkeyShowWindowKey)     private var hotkeyShowWindow: String = "⌥Space"
    @AppStorage(ScreenHistoryDefaults.hotkeyOpenSearchKey)     private var hotkeyOpenSearch: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyOpenSettingsKey)   private var hotkeyOpenSettings: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyTogglePlaybackKey) private var hotkeyTogglePlayback: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyStarMomentKey)     private var hotkeyStarMoment: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyJumpToLatestKey)   private var hotkeyJumpToLatest: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyPrevEntryKey)      private var hotkeyPrevEntry: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyNextEntryKey)      private var hotkeyNextEntry: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyJumpToDateTimeKey) private var hotkeyJumpToDateTime: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyPauseKey)          private var hotkeyPause: String = ""
    @AppStorage(ScreenHistoryDefaults.hotkeyJumpFrameKey)      private var hotkeyJumpFrame: String = ""
    @AppStorage(ScreenHistoryDefaults.audioRetentionKey)     private var audioRetention: String = "textOnly"
    @AppStorage(ScreenHistoryDefaults.vaultModeKey)          private var vaultMode: String = "openclicky"
    @AppStorage(ScreenHistoryAIBackend.defaultsKey)          private var aiBackendRaw: String = ScreenHistoryAIBackend.heyClickyFree.rawValue

    @State private var cleanupStatus: String = ""
    @State private var isCleaning: Bool = false

    private var aiBackend: ScreenHistoryAIBackend {
        get { ScreenHistoryAIBackend(rawValue: aiBackendRaw) ?? .heyClickyFree }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                mainToggle
                if enabled {
                    settingsTabs
                } else {
                    // When Screen History is off the tabs collapse,
                    // but the AI backend selector is still useful
                    // (some users want to pre-pick a model before
                    // enabling capture). Keep it visible then only.
                    aiBackendGroup
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    // MARK: tabs

    @State private var activeTab: SettingsTab = .overview

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case overview  = "Overview"
        case privacy   = "Privacy"
        case advanced  = "Advanced"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .overview: return "square.stack.3d.up"
            case .privacy:  return "lock.shield"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    @ViewBuilder
    private var settingsTabs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $activeTab) {
                ForEach(SettingsTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch activeTab {
            case .overview:
                VStack(alignment: .leading, spacing: 14) {
                    storageGroup
                    captureGroup
                }
            case .privacy:
                VStack(alignment: .leading, spacing: 14) {
                    exclusionsGroup
                    redactionPatternsGroup
                    audioRetentionGroup
                }
            case .advanced:
                VStack(alignment: .leading, spacing: 14) {
                    aiBackendGroup
                    vaultModeGroup
                    compressionGroup
                    hotkeyGroup
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen History")
                .font(.title2).bold()
            Text("Records the screen every 2 seconds and indexes it so OpenClicky can answer questions about what you've seen. Everything stays on-device.")
                .foregroundColor(.secondary)
                .font(.callout)
        }
    }

    // MARK: main toggle

    private var mainToggle: some View {
        sectionCard(title: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $enabled) {
                    Text("Enable Screen History")
                        .font(.system(size: 14, weight: .semibold))
                }
                .toggleStyle(.switch)
                Text("Capture your screen in the background and let the assistant recall it later.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: capture

    private var captureGroup: some View {
        sectionCard(title: "What to record",
                    subtitle: "Anything off does not request its macOS permission.") {
            VStack(alignment: .leading, spacing: 10) {
                captureToggleRow(icon: "display",       label: "Screen",                bind: $captureScreen)
                // FIX(mic-toggle-removed-2026-08-01): passive mic capture
                // dropped from UI. See MenuBarPanelManager rationale.
                // PTT (Ctrl+Option) audio still transcribes via Realtime
                // and lands in the vault.
                let _ = captureMic
                captureToggleRow(icon: "speaker.wave.2",label: "System audio (meetings)",bind: $captureSystemAudio)
                captureToggleRow(icon: "keyboard",      label: "Keyboard / mouse events",bind: $captureUIEvents)
                captureToggleRow(icon: "calendar",      label: "Calendar sync",         bind: $captureCalendar)
            }
        }
    }

    // MARK: shared visual helpers

    /// Shared card container — replaces raw GroupBox so every
    /// section in this pane feels like it's from the same design
    /// system: soft rounded rect, subtle 1-pt stroke, tight
    /// title/subtitle typography, generous inner padding.
    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func captureToggleRow(icon: String, label: String,
                                   bind: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: bind).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: exclusions

    private var exclusionsGroup: some View {
        sectionCard(title: "Excluded apps",
                    subtitle: "Screen History skips capture while any of these are focused — good for passwords, private chats.") {
            VStack(alignment: .leading, spacing: 10) {
                let items = excludedList()
                if items.isEmpty {
                    Text("No exclusions.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.vertical, 6)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(items, id: \.self) { bid in
                            exclusionChip(bid: bid)
                        }
                    }
                }
                HStack {
                    Button {
                        pickAppToExclude()
                    } label: {
                        Label("Add app…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if !items.isEmpty {
                        Button("Clear all") { excludedRaw = "" }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private func exclusionChip(bid: String) -> some View {
        HStack(spacing: 6) {
            appIcon(for: bid)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(appDisplayName(for: bid))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(bid)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                removeExclusion(bid: bid)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func excludedList() -> [String] {
        excludedRaw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func removeExclusion(bid: String) {
        let kept = excludedList().filter { $0 != bid }
        excludedRaw = kept.joined(separator: "\n")
    }

    private func pickAppToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to exclude from Screen History"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.applicationBundle]
        guard panel.runModal() == .OK else { return }
        var kept = excludedList()
        for url in panel.urls {
            guard let bundle = Bundle(url: url),
                  let bid = bundle.bundleIdentifier,
                  !bid.isEmpty else { continue }
            if !kept.contains(bid) { kept.append(bid) }
        }
        excludedRaw = kept.joined(separator: "\n")
    }

    private func appDisplayName(for bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           let bundle = Bundle(url: url),
           let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
                        as? String) ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
                        as? String
        {
            return name
        }
        // Fall back to last dotted segment.
        return bid.split(separator: ".").last.map(String.init) ?? bid
    }

    private func appIcon(for bid: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let ns = NSWorkspace.shared.icon(forFile: url.path)
            return Image(nsImage: ns)
        }
        return Image(systemName: "app.dashed")
    }

    /// Everything storage-related lives in one card now — size,
    /// location, retention window, and manual cleanup. The old
    /// separate `retentionGroup` used to be its own card in the
    /// Privacy tab and users had to hop between two places to
    /// understand "am I using too much disk / how do I clean it".
    private var retentionGroup: some View { EmptyView() }

    // MARK: privacy / redaction patterns

    /// FIX(retrace-#15+#7-2026-07-31): user-configurable private-title
    /// fragments (add-on to built-in list) + regex patterns that skip
    /// OCR on matching frames. All three lists are newline-separated.
    private var redactionPatternsGroup: some View {
        sectionCard(title: "Private windows & redaction",
                    subtitle: "Custom rules that block OCR for sensitive apps or windows.") {
            VStack(alignment: .leading, spacing: 12) {
                labelledTextEditor(
                    title: "Extra private-window title keywords",
                    hint: "One per line. Case-insensitive substring match added to built-in list (incognito, 隱私, …).",
                    binding: $privateTitleRaw,
                    onChange: syncPrivateTitles)
                labelledTextEditor(
                    title: "Redact window title regex",
                    hint: "One regex per line. Matching frame skips OCR and stamps redactionReason.",
                    binding: $redactTitleRaw,
                    onChange: syncRedactTitle)
                labelledTextEditor(
                    title: "Redact browser URL regex",
                    hint: "One regex per line. Matches against frontmost tab's URL.",
                    binding: $redactURLRaw,
                    onChange: syncRedactURL)
            }
        }
    }

    private func labelledTextEditor(title: String,
                                    hint: String,
                                    binding: Binding<String>,
                                    onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).fontWeight(.medium)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: binding)
                .font(.system(.body, design: .monospaced))
                .frame(height: 60)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: binding.wrappedValue) { _, _ in onChange() }
        }
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private func syncPrivateTitles() {
        UserDefaults.standard.set(parseLines(privateTitleRaw),
                                  forKey: "openrewind.privateTitleFragments")
    }
    private func syncRedactTitle() {
        UserDefaults.standard.set(parseLines(redactTitleRaw),
                                  forKey: "openrewind.redactWindowTitlePatterns")
    }
    private func syncRedactURL() {
        UserDefaults.standard.set(parseLines(redactURLRaw),
                                  forKey: "openrewind.redactBrowserURLPatterns")
    }

    // MARK: audio retention (parity with OpenRewind)

    private var audioRetentionGroup: some View {
        sectionCard(title: "Audio retention",
                    subtitle: "'Text transcript only' keeps searchable transcripts but discards raw audio after processing. Uses less disk.") {
            Picker("Keep audio as", selection: $audioRetention) {
                Text("Text transcript only (recommended)").tag("textOnly")
                Text("Text + audio files").tag("textAndAudio")
                Text("Do not record audio").tag("none")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: vault mode (parity with OpenRewind)

    private var vaultModeGroup: some View {
        sectionCard(title: "Vault",
                    subtitle: "Changing vault applies on the next Screen History restart.") {
            Picker("Data source", selection: $vaultMode) {
                Text("OpenClicky vault (default)").tag("openclicky")
                Text("Read existing Rewind.app data (compat)").tag("rewind")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: compression

    private var compressionGroup: some View {
        sectionCard(title: "Compression profile",
                    subtitle: "Integration keeps frames crisp with adaptive bitrate. Rewind parity produces bit-identical chunks — usable by Rewind.app.") {
            Picker("Profile", selection: $compressionProfile) {
                Text("Integration — optimized (~3 GB/month, default)").tag("integration")
                Text("Rewind parity — bit-identical hvcC (~10 GB/month)").tag("rewindParity")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: storage usage

    private var storageGroup: some View {
        sectionCard(title: "Storage",
                    subtitle: "Auto-cleanup runs every 6 h and reclaims media once the vault exceeds 2 GB. Memory index survives — only Clear everything wipes the DB.") {
            VStack(alignment: .leading, spacing: 12) {
                // FIX(product-polish-2026-07-31 #6): async measurement
                // with cached value shown immediately. Was blocking
                // the main actor with a whole-tree du (seconds on
                // 20 GB vaults).
                let bytes = cachedVaultBytes
                HStack {
                    Text("Vault size")
                    Spacer()
                    if vaultBytesRefreshing && bytes == 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(bytes > 0
                             ? ByteCountFormatter.string(fromByteCount: bytes,
                                                         countStyle: .file)
                             : "empty")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("Frames indexed")
                    Spacer()
                    Text("\(ScreenHistoryState.shared.frameCount)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let root = OpenRewindBridge.shared?.storage.root {
                    HStack {
                        Text("Location")
                        Spacer()
                        Text(root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Show") {
                            NSWorkspace.shared.activateFileViewerSelecting([root])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider().padding(.vertical, 2)

                HStack {
                    Text("Auto-delete older than")
                    Spacer()
                    Picker("", selection: $retentionDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("1 year").tag(365)
                        Text("Never").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("Clean up now") { runCleanup(mediaOnly: false) }
                            .disabled(isCleaning)
                        Button("Reclaim disk (keep memory)") { runCleanup(mediaOnly: true) }
                            .disabled(isCleaning)
                            .help("Delete video/JPEG files older than the retention window but KEEP OCR text and metadata. Timeline scrub thumbnails will be lost; the AI's long-term memory is preserved.")
                        Spacer()
                        Button("Clear everything…") { runCleanup(wipeAll: true) }
                            .foregroundColor(.red)
                            .disabled(isCleaning)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if !cleanupStatus.isEmpty {
                        Text(cleanupStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    /// Whole-tree du of the vault. Matches Finder's "Get Info" size
    /// for the folder. Runs synchronously — the settings pane is
    /// user-driven, not on a hot path, so a few ms of enumeration
    /// is fine here.
    private func measureVaultBytes() -> Int64 {
        guard let root = OpenRewindBridge.shared?.storage.root else { return 0 }
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                if let s = try? f.resourceValues(
                        forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(s)
                }
            }
        }
        return total
    }

    // MARK: hotkeys

    private var hotkeyGroup: some View {
        sectionCard(title: "Shortcuts",
                    subtitle: "Click a row and press the shortcut you want. Bindings route through OpenClicky's CGEvent tap, so they work while any app is frontmost.") {
            VStack(alignment: .leading, spacing: 8) {
                CGEventTapHotkeyRow(
                    label: "Open Screen History search",
                    action: .screenHistoryOpenSearch)
                CGEventTapHotkeyRow(
                    label: "Pause / resume recording",
                    action: .screenHistoryPauseToggle)
                CGEventTapHotkeyRow(
                    label: "Open Screen History settings",
                    action: .screenHistoryOpenSettings)
            }
        }
    }

    private func hotkeyRow(label: String,
                           binding: Binding<String>,
                           placeholder: String) -> some View {
        HStack {
            Text(label).frame(width: 180, alignment: .leading)
            HotkeyRecorderField(text: binding, placeholder: placeholder)
                .frame(minWidth: 140)
            Button {
                binding.wrappedValue = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear")
        }
    }

    // MARK: AI backend

    private var aiBackendGroup: some View {
        sectionCard(title: "Internal AI backend",
                    subtitle: "Used for daily recap summaries and keyword extraction. Independent of the main dialog model.") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Backend", selection: Binding(
                    get: { ScreenHistoryAIBackend(rawValue: aiBackendRaw) ?? .heyClickyFree },
                    set: { aiBackendRaw = $0.rawValue }
                )) {
                    ForEach(ScreenHistoryAIBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(backendHint(for: ScreenHistoryAIBackend(rawValue: aiBackendRaw) ?? .heyClickyFree))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func backendHint(for backend: ScreenHistoryAIBackend) -> String {
        switch backend {
        case .heyClickyFree:
            return "Free path. Requires HeyClicky sign-in (already used by the main dialog)."
        case .claudeSDK:
            return "Uses your local Claude Code sign-in (subscription). No per-token cost."
        case .claudeAPI:
            return "Direct Anthropic API. Charges against ANTHROPIC_API_KEY. Advanced Providers → API Keys."
        case .openAI:
            return "Direct OpenAI API. Charges against OPENAI_API_KEY."
        case .apple:
            return "On-device foundation model. Free, but slower on some inputs. macOS 26+."
        case .none:
            return "Screen History still records and searches. Only the recap / keyword summaries are skipped."
        }
    }

    // MARK: cleanup actions

    private func runCleanup(mediaOnly: Bool = false, wipeAll: Bool = false) {
        guard let bridge = OpenRewindBridge.shared else {
            cleanupStatus = "Screen History is off — enable capture first."
            return
        }
        isCleaning = true
        cleanupStatus = "Cleaning..."
        let days = retentionDays
        let cutoff = days > 0
            ? Calendar.current.date(byAdding: .day, value: -days, to: Date())
            : nil
        Task {
            defer { Task { @MainActor in isCleaning = false } }
            let mgr = RetentionManager(reader: bridge.reader,
                                       storage: bridge.storage)
            await mgr.setOwnsDatabase(true)
            do {
                let report: OpenRewindRetentionReport
                if wipeAll {
                    report = try await mgr.deleteBefore(
                        cutoffDate: Date().addingTimeInterval(60),
                        deleteChunkFiles: true,
                        excludeHidden: false)
                } else if mediaOnly {
                    report = try await mgr.pruneMediaOnly(olderThan: cutoff)
                } else {
                    // Full cascade: frames + video + chunks older than window.
                    let policy: OpenRewindRetentionPolicy = {
                        switch days {
                        case 1:   return .oneDay
                        case 7:   return .oneWeek
                        case 30:  return .oneMonth
                        case 90:  return .threeMonths
                        case 180: return .sixMonths
                        case 365: return .oneYear
                        default:  return .forever
                        }
                    }()
                    report = try await mgr.runCleanup(policy: policy)
                }
                let mb = Double(report.chunkBytesReclaimed) / (1024 * 1024)
                let msg = String(
                    format: "Freed %.1f MB · %d files · %d frames · %d segments · %d videos",
                    mb, report.chunkFilesDeleted,
                    report.framesDeleted, report.segmentsDeleted,
                    report.videosDeleted)
                await MainActor.run { cleanupStatus = msg }
            } catch {
                await MainActor.run {
                    cleanupStatus = "Cleanup failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Focusable text field that captures the next real key combo and
/// serialises it back to the string form the parser understands
/// (e.g. "⌥⌘R"). Blank while focused. Loses focus after capture.
struct HotkeyRecorderField: View {
    @Binding var text: String
    let placeholder: String
    @State private var listening: Bool = false

    var body: some View {
        Button {
            listening.toggle()
        } label: {
            HStack {
                Text(displayText).font(.system(.body, design: .monospaced))
                Spacer()
                if listening {
                    Text("Press…").foregroundColor(.secondary).font(.caption)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).stroke(
                listening ? Color.accentColor : Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .background(KeyCaptureBackground(isActive: $listening, text: $text))
    }

    private var displayText: String {
        text.isEmpty ? placeholder : text
    }
}

/// Invisible NSView that installs a local key-monitor while active.
/// Serialises the first matched combo back into the binding.
struct KeyCaptureBackground: NSViewRepresentable {
    @Binding var isActive: Bool
    @Binding var text: String

    func makeNSView(context: Context) -> _KeyCaptureView {
        _KeyCaptureView { combo in
            self.text = combo
            self.isActive = false
        }
    }

    func updateNSView(_ nsView: _KeyCaptureView, context: Context) {
        nsView.armed = isActive
    }

    final class _KeyCaptureView: NSView {
        var onCombo: (String) -> Void
        private var monitor: Any?
        var armed: Bool = false {
            didSet {
                if armed && monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self, self.armed else { return event }
                        let combo = Self.serialize(event)
                        self.onCombo(combo)
                        return nil
                    }
                } else if !armed, let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
            }
        }

        init(_ onCombo: @escaping (String) -> Void) {
            self.onCombo = onCombo
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }

        static func serialize(_ event: NSEvent) -> String {
            var s = ""
            let flags = event.modifierFlags
            if flags.contains(.control) { s += "⌃" }
            if flags.contains(.option)  { s += "⌥" }
            if flags.contains(.shift)   { s += "⇧" }
            if flags.contains(.command) { s += "⌘" }
            let key = event.charactersIgnoringModifiers ?? ""
            let normalized: String = {
                if key == " " { return "Space" }
                return key.uppercased()
            }()
            s += normalized
            return s
        }
    }
}
