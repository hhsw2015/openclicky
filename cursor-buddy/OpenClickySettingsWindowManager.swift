import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class OpenClickySettingsWindowManager {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OpenClickySettingsView>?
    private var glassBackdrop: OpenClickyLiquidGlassBackdropView?
    private let windowSize = NSSize(width: 1120, height: 760)
    private let minimumWindowSize = NSSize(width: 1040, height: 660)

    func show(companionManager: CompanionManager) {
        let targetScreen = NSScreen.openClickyActiveInteractionScreen()
        if window == nil {
            createWindow(companionManager: companionManager, targetScreen: targetScreen)
        } else if let hostingView {
            hostingView.rootView = OpenClickySettingsView(companionManager: companionManager)
        }

        guard let settingsWindow = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        bringSettingsWindowToFront(settingsWindow, shouldCenter: true, targetScreen: targetScreen)

        DispatchQueue.main.async { [weak self, weak settingsWindow] in
            guard let self, let settingsWindow else { return }
            self.bringSettingsWindowToFront(settingsWindow, shouldCenter: false, targetScreen: targetScreen)
        }
    }

    private func bringSettingsWindowToFront(_ settingsWindow: NSWindow, shouldCenter: Bool, targetScreen: NSScreen?) {
        // The main OpenClicky panel uses `.statusBar`, so Settings must sit one
        // level above it instead of the default floating level.
        OpenClickyWindowLevels.applyPanelDialogLevel(to: settingsWindow)
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        ensureSettingsWindowFitsContent(settingsWindow, shouldCenter: shouldCenter, targetScreen: targetScreen)
        if shouldCenter {
            center(settingsWindow, on: targetScreen)
        }
        settingsWindow.deminiaturize(nil)
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()
    }

    private func ensureSettingsWindowFitsContent(_ settingsWindow: NSWindow, shouldCenter: Bool, targetScreen: NSScreen?) {
        let visibleFrame = (targetScreen ?? settingsWindow.screen ?? NSScreen.openClickyActiveInteractionScreen())?.visibleFrame
        let currentFrame = settingsWindow.frame
        let targetWidth = max(currentFrame.width, windowSize.width)
        let targetHeight = max(currentFrame.height, windowSize.height)
        let fittedWidth = visibleFrame.map { min(targetWidth, $0.width - 32) } ?? targetWidth
        let fittedHeight = visibleFrame.map { min(targetHeight, $0.height - 32) } ?? targetHeight
        guard fittedWidth > currentFrame.width || fittedHeight > currentFrame.height else { return }

        let targetSize = NSSize(width: fittedWidth, height: fittedHeight)
        if shouldCenter {
            settingsWindow.setContentSize(targetSize)
        } else {
            var targetFrame = currentFrame
            targetFrame.size = targetSize
            if let visibleFrame {
                targetFrame.origin.x = min(max(targetFrame.origin.x, visibleFrame.minX + 16), visibleFrame.maxX - targetSize.width - 16)
                targetFrame.origin.y = min(max(targetFrame.origin.y, visibleFrame.minY + 16), visibleFrame.maxY - targetSize.height - 16)
            }
            settingsWindow.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func center(_ settingsWindow: NSWindow, on targetScreen: NSScreen?) {
        guard let targetScreen else {
            settingsWindow.center()
            return
        }
        settingsWindow.setFrame(
            NSScreen.centerFrame(size: settingsWindow.frame.size, on: targetScreen),
            display: true,
            animate: false
        )
    }

    private func createWindow(companionManager: CompanionManager, targetScreen: NSScreen?) {
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = ""
        settingsWindow.titleVisibility = .hidden
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.toolbarStyle = .unified
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.hasShadow = false
        OpenClickyWindowLevels.applyPanelDialogLevel(to: settingsWindow)
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        center(settingsWindow, on: targetScreen)

        let containerView = OpenClickyGlassContainerView(frame: NSRect(origin: .zero, size: windowSize))
        containerView.autoresizingMask = [.width, .height]
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        let backdrop = OpenClickyLiquidGlassBackdropView(cornerRadius: 22)
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.configure(
            cornerRadius: 22,
            roundsTopCorners: true,
            accentColor: OpenClickyNotchCaptureWindowManager.nsAccentColor(for: nil),
            strength: .expanded
        )
        containerView.addSubview(backdrop)

        let hostingView = NSHostingView(rootView: OpenClickySettingsView(companionManager: companionManager))
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(hostingView)

        settingsWindow.contentView = containerView
        self.hostingView = hostingView
        glassBackdrop = backdrop

        window = settingsWindow
    }
}

private enum OpenClickySettingsSection: String, CaseIterable, Identifiable {
    // Grouped by relatedness: user basics → voice/CLI → providers/models →
    // permissions → extensions → awareness/history.
    case basic
    // Profile-specific tabs, ordered to match OpenClickyProfileCatalog.all:
    // heyclickyFree → skiMode → mirage (Peeky Free). One tab per free
    // lane so users can see all knobs / status for that lane in one place.
    case heyclickyFree
    case skiMode
    case peekyFree
    case advancedProviders
    case models
    case permissions
    case computerUse
    case agents
    case automations
    case mcpSubsystems
    case connections
    case contextAwareness
    case screenHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return "Basic"
        case .advancedProviders: return "Advanced Providers"
        case .skiMode: return "SKI Mode"
        case .peekyFree:
            return OpenClickyLocaleManager.shared.currentLanguage.hasPrefix("zh")
                ? "Peeky 免费" : "Peeky Free"
        case .heyclickyFree:
            return OpenClickyLocaleManager.shared.currentLanguage.hasPrefix("zh")
                ? "HeyClicky 免费" : "HeyClicky Free"
        case .computerUse: return "Computer Use"
        case .permissions: return "Permissions"
        case .agents: return "Agents"
        case .automations: return "Automations"
        case .connections: return "System & Logs"
        case .mcpSubsystems: return "MCP subsystems"
        case .models: return "Models"
        case .contextAwareness: return "Context Awareness"
        case .screenHistory: return "Screen History"
        }
    }

    var systemImageName: String {
        switch self {
        case .basic: return "gearshape"
        case .advancedProviders: return "key"
        case .skiMode: return "waveform.and.person.filled"
        case .peekyFree: return "sparkle.magnifyingglass"
        case .heyclickyFree: return "cloud.bolt.fill"
        case .computerUse: return "macwindow.and.cursorarrow"
        case .permissions: return "hand.raised"
        case .agents: return "person.2"
        case .automations: return "calendar.badge.clock"
        case .connections: return "server.rack"
        case .mcpSubsystems: return "puzzlepiece.extension"
        case .models: return "cpu"
        case .contextAwareness: return "eye"
        case .screenHistory: return "clock.arrow.circlepath"
        }
    }
}

private enum OpenClickySettingsValidationError: Error {
    case invalidAgentBaseURL
}

struct OpenClickySettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var wakeWordManager: OpenClickyWakeWordManager
    @ObservedObject private var session: CodexAgentSession
    @ObservedObject private var nativeComputerUseController: OpenClickyNativeComputerUseController
    @ObservedObject private var petLibrary = ClickyBuddyPetLibrary.shared
    @ObservedObject private var heyClickyPlan = HeyClickyPlanClient.shared
    @StateObject private var openPetsCatalog = OpenPetsCatalogStore()
    @StateObject private var localSpeechModelManager = OpenClickyLocalSpeechModelManager.shared
    @StateObject private var routerSettings = OpenClickyRouterSettings.shared
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(ClickyCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = ClickyCursorAvatarStyle.default.storageValue
    @State private var userAnthropicAPIKey = ""
    @State private var codexAgentBaseURL = ""
    @State private var userElevenLabsAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @State private var userCartesiaAPIKey = ""
    @AppStorage(AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) private var userCartesiaVoiceID = ""
    @AppStorage(AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey) private var userOpenAIRealtimeVoiceID = "cedar"
    @AppStorage(AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey) private var userMicrosoftEdgeVoiceID = "en-US-EmmaMultilingualNeural"
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey) private var userDeepgramVoiceAgentThinkModel = "gpt-4o-mini"
    @State private var heyClickyAdvancedExpanded: Bool = false
    /// Bumped on every HeyClicky lifecycle notification so any SwiftUI
    /// binding that reads `AppBundleConfiguration.heyClicky*` gets a
    /// fresh render. Actual auth state is always read directly, not
    /// cached — caching bit us when the Keychain→file migration left
    /// stale State values behind. See UI bug report 2026-07-20.
    @State private var heyClickyRefreshTick: Int = 0
    @State private var heyClickyStatusMessage: String = ""
    /// Ticked whenever the active profile changes; views gated by the
    /// active profile id read this so SwiftUI re-runs their body.
    @State private var activeProfileRefreshTick: Int = 0

    /// Live language state so a picker change re-runs body immediately
    /// and every `Text("...")` looks up the new locale.
    @ObservedObject private var openClickyLocale: OpenClickyLocaleManager = .shared

    /// Picker selection backing. Initialised from the stored value on
    /// first render; `.onChange` writes back through OpenClickyLocaleManager.
    /// Using @State (not an inline Binding{get,set}) is the shape SwiftUI
    /// actually notices Picker changes on for macOS 14/15.
    @State private var languagePickerSelection: String = {
        UserDefaults.standard.string(forKey: OpenClickyLocaleManager.userDefaultsKey) ?? "system"
    }()

    private var heyClickySignedInState: Bool {
        _ = heyClickyRefreshTick   // read to establish view dependency
        return AppBundleConfiguration.heyClickySignedIn()
    }
    @State private var heyClickyApplyConfirming: Bool = false
    /// Snapshot of the 4 lane defaults captured just before applying
    /// the HeyClicky Free profile — used by "Revert" to roll back
    /// exactly one step.
    @State private var heyClickyPreProfileSnapshot: [String: String?]? = nil
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionsEnabledDefaultsKey) private var voiceResponseCaptionsEnabled = false
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionFontDefaultsKey) private var voiceResponseCaptionFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionOpacityDefaultsKey) private var voiceResponseCaptionOpacity = AppBundleConfiguration.defaultVoiceResponseCaptionOpacity
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppTitleFontSizeDefaultsKey) private var appTitleFontSize = 26.0
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppLineSpacingDefaultsKey) private var appLineSpacing = 2.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @AppStorage(AppBundleConfiguration.openClickyVoicePlaybackVolumeDefaultsKey) private var openClickyVoicePlaybackVolume = AppBundleConfiguration.voicePlaybackVolume()
    @State private var userCodexAgentAPIKey = ""
    @State private var userAssemblyAIAPIKey = ""
    @State private var userDeepgramAPIKey = ""
    @AppStorage(AppBundleConfiguration.userMCPDeveloperDocsEnabledDefaultsKey) private var mcpDeveloperDocsEnabled = false
    @AppStorage(AppBundleConfiguration.userMCPComposioConnectEnabledDefaultsKey) private var mcpComposioConnectEnabled = false
    @AppStorage(AppBundleConfiguration.userMCPComputerUseEnabledDefaultsKey) private var mcpComputerUseEnabled = false
    @AppStorage(AppBundleConfiguration.userMCPCuaDriverCommandDefaultsKey) private var mcpCuaDriverCommand = CuaDriverMCPConfiguration.resolvedCommandPath() ?? ""
    @AppStorage(AppBundleConfiguration.userDesktopNotificationsEnabledDefaultsKey) private var desktopNotificationsEnabled = true
    @AppStorage(AppBundleConfiguration.userAgentCompletionVoiceEnabledDefaultsKey) private var agentCompletionVoiceEnabled = true
    @AppStorage(AppBundleConfiguration.userWidgetsEnabledDefaultsKey) private var widgetsEnabled = true
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey) private var widgetsIncludeAgentTaskNames = true
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey) private var widgetsIncludeMemorySnippets = true
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey) private var widgetsIncludeFocusedAppContext = true
    @AppStorage(AppBundleConfiguration.userGlassOpacityDefaultsKey) private var glassOpacity = 0.75
    @AppStorage(AppBundleConfiguration.userGlassFrostingDefaultsKey) private var glassFrosting = 0.20
    @AppStorage(AppBundleConfiguration.userThemeDefaultsKey) private var clickyTheme = ClickyTheme.system.rawValue
    @AppStorage(AppBundleConfiguration.userCircleWhileTalkingEnabledDefaultsKey) private var circleWhileTalkingEnabled = true
    @AppStorage(AppBundleConfiguration.userCircleWhileTalkingRequireClickDefaultsKey) private var circleWhileTalkingRequireClick = true
    @State private var selectedSection: OpenClickySettingsSection = .basic
    @State private var gogCLIStatus = OpenClickyGogCLIStatus.unknown
    @State private var isRefreshingGogCLIStatus = false
    @State private var codexConfigSyncMessage = "MCP servers are written into Codex config.toml for new Agent Mode sessions."
    @State private var notificationAuthorizationSummary = "Checking..."
    @State private var notificationAuthorizationGranted = false
    private static let openAIRealtimeVoiceIDs = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse"
    ]
    private static let notificationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.wakeWordManager = companionManager.wakeWordManager
        self.session = companionManager.codexAgentSession
        self.nativeComputerUseController = companionManager.nativeComputerUseController
    }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private var titleFontSize: CGFloat { CGFloat(appTitleFontSize) }
    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }
    private var appTextLineSpacing: CGFloat { CGFloat(appLineSpacing) }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular:
                return .medium
            case .medium:
                return .semibold
            case .semibold:
                return .bold
            case .bold, .heavy, .black:
                return .black
            default:
                return weight
            }
        } else {
            switch weight {
            case .black, .heavy:
                return .semibold
            case .bold:
                return .medium
            case .semibold:
                return .medium
            case .medium:
                return .regular
            case .regular:
                return .regular
            default:
                return weight
            }
        }
    }

    var body: some View {
        // SwiftUI only tracks @State reads that happen directly in a
        // View body. `heyClickyRefreshTick` is read here at the root
        // so subtrees that use `heyClickySignedInState` (via computed
        // property, not tracked otherwise) rebuild on notification.
        let _ = heyClickyRefreshTick
        let _ = activeProfileRefreshTick
        return GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                sidebar

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if selectedSection != .models && selectedSection != .permissions && selectedSection != .agents {
                            OpenClickyProfileSelectorView(companionManager: companionManager)
                        }
                        sectionHeader
                        selectedPanel
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.03))
            }
        }
        .frame(minWidth: 1040, minHeight: 660)
        .font(appUIFont(size: bodyFontSize, weight: .regular))
        .lineSpacing(appTextLineSpacing)
        .background(Color.clear)
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .connections, !gogCLIStatus.isInstalled, !isRefreshingGogCLIStatus {
                refreshGogCLIStatus()
            }
            if newSection == .permissions {
                refreshNotificationAuthorizationStatus()
            }
        }
        .onAppear {
            refreshNotificationAuthorizationStatus()
            loadConfiguredSecretsForEditing()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            // Poll the active profile id. Ticking the state var makes
            // SwiftUI re-run any body that reads `activeProfileRefreshTick`
            // so profile-gated groups (HeyClicky, SKI-only) show/hide
            // immediately when the user picks a different profile.
            activeProfileRefreshTick &+= 1
        }
        // Inject the user-selected UI locale into every child view so
        // formatters + `Text(verbatim:)` sites reflect the choice.
        // Literal-key `Text("…")` still needs a relaunch (Apple's
        // recommended path); see OpenClickyLocaleManager.
        .environment(\.locale, openClickyLocale.currentLocale)
    }

    private func loadConfiguredSecretsForEditing() {
        userCodexAgentAPIKey = AppBundleConfiguration.openAIAPIKey() ?? ""
        userAnthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() ?? ""
        userAssemblyAIAPIKey = AppBundleConfiguration.assemblyAIAPIKey() ?? ""
        userDeepgramAPIKey = AppBundleConfiguration.deepgramAPIKey() ?? ""
        userElevenLabsAPIKey = AppBundleConfiguration.elevenLabsAPIKey() ?? ""
        userCartesiaAPIKey = AppBundleConfiguration.cartesiaAPIKey() ?? ""
        codexAgentBaseURL = UserDefaults.standard.string(forKey: "clickyAgentBaseURL") ?? ""
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenClicky")
                .font(appUIFont(size: bodyFontSize + 5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ForEach(OpenClickySettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImageName)
                            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
                            .frame(width: 20)
                        Text(LocalizedStringKey(section.title))
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(selectedSection == section ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedSection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(width: 190)
        .glassEffect(
            .regular.tint(DS.Colors.accent.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .padding(8)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(selectedSection.title))
                .font(appUIFont(size: titleFontSize, weight: .semibold))
            Text(LocalizedStringKey(sectionSubtitle))
                .font(appUIFont(size: bodyFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .basic:
            return "Working defaults, voice status, permission status, and everyday OpenClicky controls."
        case .advancedProviders:
            return "Provider credentials, voice services, Agent Mode defaults, and external service configuration."
        case .skiMode:
            return "SKI Mode voice bridge: whisper.cpp STT model, skill install per CLI agent, workspace picker, and file-bridge diagnostics."
        case .peekyFree:
            return "Peeky Free lane: free-tier Claude / Deepgram / Cartesia via aegis-proxy, on-device ONNX intent classifier, and Peeky Mac integrations."
        case .heyclickyFree:
            return "HeyClicky Free lane: OpenAI Realtime WS through the HeyClicky proxy, sign-in status, quota, and Assist Agent controls."
        case .computerUse:
            return "In-app Native Computer Use, pointing models, and cuaDriver configuration."
        case .permissions:
            return "macOS access permissions for voice, screen content, pointing, and system automation."
        case .agents:
            return "Specialist agents with their own soul, memory, instructions, and inherited or custom skills and tools."
        case .automations:
            return "Scheduled prompts and workflows. Interval (every N minutes) or 5-field cron, optionally bound to a specialist agent."
        case .connections:
            return "Google Workspace, persistent memory folders, logs, widgets, and utilities."
        case .mcpSubsystems:
            return "Browser (OpenDia), OpenCLI site adapters, open-connector providers, Chrome bridge, and external-control bridge auth."
        case .models:
            return "Offline model installs and the local inference runtime that gets models ready for use."
        case .contextAwareness:
            return "Global hotkeys that capture context snapshots, pin UI elements, and clear stashes. All defaults are unbound."
        case .screenHistory:
            return "Screen memory (OpenRewind embedded) — capture / retention / exclusions / internal AI backend for daily recap and keyword extraction."
        }
    }

    private var liquidGlassPreview: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DS.Colors.accent.opacity(0.34),
                    Color.white.opacity(0.16 + glassFrosting * 0.18),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blur(radius: 0.4 + glassFrosting * 2.4)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((DS.Colors.isDarkMode ? Color.black : Color.white).opacity(glassOpacity * 0.18))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10 + glassFrosting * 0.30), lineWidth: 1)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(appUIFont(size: bodyFontSize + 3, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live glass preview")
                        .font(appUIFont(size: bodyFontSize, weight: .semibold))
                    Text("Opacity and frosting update immediately here and on OpenClicky panels.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 78)
        .glassEffect(
            .regular.tint(DS.Colors.accent.opacity(0.04 + glassOpacity * 0.04 + glassFrosting * 0.10)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selectedSection {
        case .basic:
            basicPanel
        case .advancedProviders:
            advancedProvidersPanel
        case .skiMode:
            skiModePanel
        case .peekyFree:
            peekyFreePanel
        case .heyclickyFree:
            heyClickyFreePanel
        case .computerUse:
            computerUsePanel
        case .permissions:
            permissionsPanel
        case .agents:
            agentsPanel
        case .automations:
            automationsPanel
        case .connections:
            connectionsPanel
        case .mcpSubsystems:
            mcpSubsystemsPanel
        case .models:
            superAdvancedPanel
        case .contextAwareness:
            contextAwarenessPanel
        case .screenHistory:
            OpenClickyScreenHistorySettingsSection()
        }
    }

    /// Language picker + relaunch button. macOS resolves the SwiftUI
    /// `Text("…")` literals against `Bundle.main.localizedString`, which
    /// reads `AppleLanguages` at process start — so switching languages
    /// for those literal strings needs an app relaunch. We record the
    /// choice in `AppleLanguages` immediately; a "Relaunch" button
    /// applies it. Formatters and `Text(verbatim:)` sites that read
    /// `\.locale` will pick up the change without a relaunch because
    /// we also inject the environment locale.
    @ViewBuilder
    private var openClickyLanguagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                    Text("Choose the UI language. Relaunch to apply.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $languagePickerSelection) {
                    Text("System").tag("system")
                    // Dynamic list — every language in Localizable.xcstrings
                    // that has resources in the bundle shows up here.
                    // Adding a new locale needs zero code change; drop
                    // it into the string catalog + Info.plist and it
                    // appears automatically.
                    ForEach(openClickyLocale.availableLanguages, id: \.self) { tag in
                        Text(openClickyLocale.displayName(for: tag)).tag(tag)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: languagePickerSelection) { _, newValue in
                    openClickyLocale.setLanguage(newValue)
                }
            }
            if openClickyLocale.needsRelaunchToApply {
                HStack {
                    Spacer()
                    Button("Relaunch to apply") {
                        openClickyLocale.relaunchToApply()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Launch-at-login opt-in toggle. Previously the app auto-registered
    /// itself as a login item on every launch (opt-out); now the user
    /// decides. Absent preference → toggle reads OFF and SMAppService
    /// is left untouched.
    @ViewBuilder
    private var openClickyLaunchAtLoginToggle: some View {
        let key = CompanionAppDelegate.launchAtLoginDefaultsKey
        toggleRow(
            title: "Launch OpenClicky at login",
            subtitle: "Off by default. Turn on to have OpenClicky start automatically after login.",
            systemImageName: "power",
            isOn: Binding<Bool>(
                get: { UserDefaults.standard.bool(forKey: key) },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: key)
                    let service = SMAppService.mainApp
                    do {
                        if newValue && service.status != .enabled {
                            try service.register()
                        } else if !newValue && service.status == .enabled {
                            try service.unregister()
                        }
                    } catch {
                        NSLog("openclicky: login-item toggle failed: %@", "\(error)")
                    }
                }
            )
        )
    }

    private var basicPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heyClickyBasicPromo
            voiceRouteOverview

            settingsGroup("Voice controls") {
                LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                    ForEach(OpenClickyVoiceActivationMode.allCases) { mode in
                        optionButton(
                            title: mode.label,
                            subtitle: mode.subtitle,
                            isSelected: companionManager.voiceActivationMode == mode,
                            action: { companionManager.setVoiceActivationMode(mode) }
                        )
                    }
                }
                .padding(14)

                valueRow(
                    title: wakeWordManager.isListening ? "Wake word armed" : "Wake word",
                    subtitle: companionManager.voiceActivationMode.usesWakeWord
                        ? (wakeWordManager.isListening
                            ? "Say \"Hey Clicky\" to start a voice turn. Wake detection uses on-device Apple Speech."
                            : "Activation keys toggle the local Hey Clicky listener; always-listening mode starts it automatically.")
                        : "Disabled while Push to talk is selected.",
                    systemImageName: wakeWordManager.isListening ? "ear.badge.waveform" : "ear"
                )

                if let wakeWordError = wakeWordManager.lastErrorMessage,
                   !wakeWordError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Wake-word listener",
                        subtitle: wakeWordError
                    )
                }

                valueRow(
                    title: "Current transcription",
                    subtitle: OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Bypassed because the selected response model owns live speech input."
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "waveform"
                )

                if let transcriptionError = companionManager.buddyDictationManager.lastErrorMessage,
                   !transcriptionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Transcription error",
                        subtitle: transcriptionError
                    )
                }

                editableFieldRow(
                    title: "OpenClicky volume",
                    subtitle: "Controls spoken reply playback without changing macOS system volume.",
                    systemImageName: "speaker.wave.2"
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { openClickyVoicePlaybackVolume },
                                set: { openClickyVoicePlaybackVolume = min(max($0, 0.0), 1.0) }
                            ),
                            in: 0...1
                        )
                        Text("\(Int((openClickyVoicePlaybackVolume * 100).rounded()))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                toggleRow(
                    title: "Caption every spoken response",
                    subtitle: "Shows OpenClicky's spoken reply beside the cursor while voice playback runs.",
                    systemImageName: "captions.bubble",
                    isOn: $voiceResponseCaptionsEnabled
                )

                toggleRow(
                    title: "Circle while talking",
                    subtitle: "Hold push-to-talk, then click and drag a red trail around something while speaking. On release, the region goes with your instruction to voice and Agent Mode.",
                    systemImageName: "pencil.tip.crop.circle",
                    isOn: $circleWhileTalkingEnabled
                )

                if circleWhileTalkingEnabled {
                    toggleRow(
                        title: "Click and drag to draw",
                        subtitle: "On (default): click and drag while holding the key. Off: any mouse movement while holding the key draws.",
                        systemImageName: "hand.draw",
                        isOn: $circleWhileTalkingRequireClick
                    )
                }

                actionRow(title: "Test caption playback", systemImageName: "play.circle") {
                    companionManager.testVoiceResponseCaptionPlayback()
                }
            }

            settingsGroup("Local listening") {
                localSpeechModelStatusRow

                basicLocalListeningActionRow

                if OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    warningRow(
                        title: "Realtime bypasses local STT",
                        subtitle: "GPT Realtime listens directly to the microphone. Use the local listening route when you want Parakeet to transcribe first."
                    )
                    actionRow(title: "Use local listening route", systemImageName: "waveform.badge.mic") {
                        useLocalListeningRoute()
                    }
                }

                if let localSpeechError = localSpeechModelManager.lastErrorMessage,
                   !localSpeechError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Parakeet model",
                        subtitle: localSpeechError
                    )
                }
            }

            settingsGroup("Permission status") {
                permissionRow(
                    title: "Accessibility",
                    isGranted: companionManager.hasAccessibilityPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
                permissionRow(
                    title: "Screen Recording",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Microphone",
                    isGranted: companionManager.hasMicrophonePermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
            }

            settingsGroup("General") {
                openClickyLanguagePicker
                openClickyLaunchAtLoginToggle
            }

            settingsGroup("Companion") {
                toggleRow(
                    title: "Show OpenClicky cursor",
                    subtitle: "Keeps the cursor companion visible and ready for push-to-talk.",
                    systemImageName: "cursorarrow",
                    isOn: Binding(
                        get: { companionManager.isClickyCursorEnabled },
                        set: { companionManager.setClickyCursorEnabled($0) }
                    )
                )

                toggleRow(
                    title: "Tutor mode",
                    subtitle: "Watches for short pauses and offers small next-step guidance.",
                    systemImageName: "graduationcap",
                    isOn: Binding(
                        get: { companionManager.isTutorModeEnabled },
                        set: { companionManager.setTutorModeEnabled($0) }
                    )
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 14))
                            .foregroundColor(DS.Colors.accentText)
                            .frame(width: 20, alignment: .center)
                        
                        Text("Appearance theme")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        
                        Spacer()
                        
                        Picker("", selection: $clickyTheme) {
                            ForEach(ClickyTheme.allCases) { theme in
                                Text(LocalizedStringKey(theme.title)).tag(theme.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Text("Choose between light glass, dark glass, or match system appearance.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.leading, 28)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                editableFieldRow(
                    title: "Glass tint strength",
                    subtitle: "Adjusts the native Liquid Glass tint without fading the system refraction layer.",
                    systemImageName: "eyedropper"
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $glassOpacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int((glassOpacity * 100).rounded()))%")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                editableFieldRow(
                    title: "Glass frosting",
                    subtitle: "Adjusts the native Liquid Glass tint intensity used by OpenClicky glass surfaces.",
                    systemImageName: "sparkles"
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $glassFrosting, in: 0.0...1.0, step: 0.05)
                        Text("\(Int((glassFrosting * 100).rounded()))%")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                liquidGlassPreview
            }

            settingsGroup("Typography") {
                Picker("App font", selection: $appFontRawValue) {
                    ForEach(OpenClickyResponseCaptionFont.allCases) { appFont in
                        Text(LocalizedStringKey(appFont.label)).tag(appFont.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                toggleRow(
                    title: "Bold interface text",
                    subtitle: "Makes normal OpenClicky labels and messages use a stronger weight.",
                    systemImageName: "bold",
                    isOn: $appBoldTextEnabled
                )
            }

            settingsGroup("Cursor appearance") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pick OpenClicky’s cursor buddy and accent color. Pets ignore the color tint, but the accent still drives glows, buttons, and task badges.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        cursorAvatarButton(.triangleFilled, label: "Triangle")
                        cursorAvatarButton(.triangleOutline, label: "Outline")
                        ForEach(petLibrary.pets) { pet in
                            cursorPetButton(pet)
                        }
                        if petLibrary.pets.isEmpty {
                            emptyPetLibraryTile
                        }
                    }

                    Divider()
                        .opacity(0.45)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach([ClickyAccentTheme.rose, .blue, .amber, .mint, .white]) { accentTheme in
                            cursorColorButton(accentTheme)
                        }
                    }

                    Divider()
                        .opacity(0.45)

                    openPetsCatalogSection
                }
                .padding(14)
            }
        }
    }

    private var localSpeechModelStatusRow: some View {
        let selectedVersion = localSpeechModelManager.selectedVersion
        let state = localSpeechModelManager.state(for: selectedVersion)
        let title = localSpeechModelManager.isAppleSilicon ? "Parakeet local STT" : "Parakeet local STT unavailable"
        let subtitle: String
        if localSpeechModelManager.isAppleSilicon {
            subtitle = "\(selectedVersion.label): \(state.label). \(localSpeechRouteDetail)"
        } else {
            subtitle = "Parakeet requires Apple Silicon. Use Apple Speech or a configured cloud STT provider on this Mac."
        }
        return valueRow(
            title: title,
            subtitle: subtitle,
            systemImageName: state.isReady ? "checkmark.circle" : "waveform"
        )
    }

    private var localSpeechRouteDetail: String {
        if companionManager.buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.parakeet.rawValue {
            return "Selected for local listening."
        }
        if companionManager.buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.automatic.rawValue {
            return localSpeechModelManager.isSelectedModelReady
                ? "Automatic can use Parakeet because the selected local model is ready."
                : "Automatic stays on configured cloud or Apple Speech until a local Parakeet model is ready."
        }
        return localSpeechModelManager.isSelectedModelReady
            ? "Parakeet is ready if you want to switch local listening to it."
            : "Download a Parakeet model in Advanced Providers before selecting it."
    }

    private func localSpeechModelSubtitle(for version: OpenClickyLocalSpeechModelVersion) -> String {
        "\(version.subtitle) - \(localSpeechModelManager.state(for: version).label)"
    }

    @ViewBuilder
    private var basicLocalListeningActionRow: some View {
        let selectedVersion = localSpeechModelManager.selectedVersion
        switch localSpeechModelManager.state(for: selectedVersion) {
        case .ready:
            actionRow(title: "Use Parakeet for local listening input", systemImageName: "waveform.badge.mic") {
                companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.parakeet.rawValue)
            }
        case .downloading:
            actionRow(title: "Cancel Parakeet download", systemImageName: "xmark.circle") {
                localSpeechModelManager.cancelDownload(selectedVersion)
            }
        case .notDownloaded, .failed:
            actionRow(title: "Open Advanced Providers", systemImageName: "slider.horizontal.3") {
                selectedSection = .advancedProviders
            }
        }
    }

    private var detailedLocalListeningGroup: some View {
        settingsGroup("Local listening installs") {
            localSpeechModelStatusRow

            if localSpeechModelManager.isAppleSilicon {
                LazyVGrid(columns: settingsOptionColumns(2), spacing: 8) {
                    ForEach(OpenClickyLocalSpeechModelVersion.allCases) { version in
                        optionButton(
                            title: version.label,
                            subtitle: localSpeechModelSubtitle(for: version),
                            isSelected: localSpeechModelManager.selectedVersion == version,
                            action: {
                                localSpeechModelManager.setSelectedVersion(version)
                                if companionManager.buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.parakeet.rawValue,
                                   !localSpeechModelManager.state(for: version).isReady {
                                    companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.appleSpeech.rawValue)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)

                localSpeechModelActionRow
            }
        }
    }

    @ViewBuilder
    private var localSpeechModelActionRow: some View {
        let selectedVersion = localSpeechModelManager.selectedVersion
        switch localSpeechModelManager.state(for: selectedVersion) {
        case .downloading:
            actionRow(title: "Cancel Parakeet download", systemImageName: "xmark.circle") {
                localSpeechModelManager.cancelDownload(selectedVersion)
            }
        case .ready:
            actionRow(title: "Use Parakeet for local listening input", systemImageName: "waveform.badge.mic") {
                companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.parakeet.rawValue)
            }
        case .notDownloaded, .failed:
            actionRow(title: "Download selected Parakeet model", systemImageName: "arrow.down.circle") {
                localSpeechModelManager.downloadSelectedModel()
            }
        }
    }

    private func useLocalListeningRoute() {
        companionManager.setVoiceTranscriptionProvider(localListeningProviderID.rawValue)
        if OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
            companionManager.setSelectedModel(OpenClickyModelCatalog.defaultCodexActionsModelID)
        }
        if companionManager.selectedTTSProvider == .openAIRealtime {
            companionManager.setTTSProvider(.microsoftEdge)
        }
    }

    private var localListeningProviderID: BuddyTranscriptionProviderID {
        localSpeechModelManager.isSelectedModelReady ? .parakeet : .appleSpeech
    }

    private var advancedVoiceProviderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceRouteOverview

            settingsGroup("Response voice model") {
                Text("Pick Realtime when one model should listen and speak live, or use a normal model when OpenClicky should think first and hand the reply to a playback engine.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                modelOptionGrid(
                    options: OpenClickyModelCatalog.responseVoiceModels,
                    selectedModelID: companionManager.selectedModel,
                    columns: 3,
                    select: { companionManager.setSelectedModel($0) }
                )

                if OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .openAI,
                   OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    openAIRealtimeVoicePicker
                }
                // HeyClicky Free selections speak via GPT Realtime with
                // a proxy-minted ephemeral (spec §5.3), so surface the
                // same voice picker as native realtime speech models.
                if OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .heyclickyFree {
                    Text("Speak plays through GPT Realtime using your HeyClicky Free session. Pick a voice below.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    openAIRealtimeVoicePicker
                }

                if OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .deepgram {
                    Text("Deepgram Voice Agent uses one WebSocket for listening, thinking, and speaking; it reuses the Deepgram key configured in Advanced Providers.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    textFieldRow(
                        title: "Deepgram voice",
                        subtitle: "Aura model identifier for the speak stage.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                    textFieldRow(
                        title: "Deepgram think model",
                        subtitle: "LLM model Deepgram should use inside the Voice Agent.",
                        systemImageName: "brain.head.profile",
                        placeholder: "gpt-4o-mini",
                        text: Binding(
                            get: { userDeepgramVoiceAgentThinkModel },
                            set: { userDeepgramVoiceAgentThinkModel = $0; companionManager.setDeepgramVoiceAgentThinkModel($0) }
                        )
                    )
                }
            }

            settingsGroup("Transcription provider") {
                if OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    valueRow(
                        title: "Current input path",
                        subtitle: "GPT Realtime is selected, so OpenClicky streams microphone audio directly to Realtime instead of using Whisper or another speech-to-text provider.",
                        systemImageName: "waveform.badge.mic"
                    )
                }

                valueRow(
                    title: "Current provider",
                    subtitle: OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Bypassed while GPT Realtime is the response voice model"
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "waveform"
                )

                if let transcriptionError = companionManager.buddyDictationManager.lastErrorMessage,
                   !transcriptionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Transcription error",
                        subtitle: transcriptionError
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BuddyTranscriptionProviderFactory.providerIDsForSelectionGrid()) { provider in
                        optionButton(
                            title: provider.label,
                            subtitle: provider.subtitle,
                            isSelected: companionManager.buddyDictationManager.transcriptionProviderID == provider.rawValue,
                            action: { companionManager.setVoiceTranscriptionProvider(provider.rawValue) }
                        )
                    }
                }
            }

            settingsGroup("Playback") {
                Text(OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
                    ? "GPT Realtime is selected as the response voice model, so it owns playback for voice replies."
                    : "Choose the separate TTS provider used when a normal text model generates OpenClicky's reply.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    Picker("Playback engine", selection: Binding(
                        get: { companionManager.selectedTTSProvider },
                        set: { companionManager.setTTSProvider($0) }
                    )) {
                        ForEach(OpenClickyTTSProvider.allCases.filter { $0 != .openAIRealtime }) { provider in
                            Text(LocalizedStringKey(provider.displayName)).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)
                }

                switch companionManager.selectedTTSProvider {
                case .openAIRealtime:
                    EmptyView()
                case .elevenLabs:
                    textFieldRow(
                        title: "ElevenLabs voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userElevenLabsVoiceID },
                            set: { userElevenLabsVoiceID = $0; companionManager.setElevenLabsVoiceID($0) }
                        )
                    )
                case .cartesia:
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userCartesiaVoiceID },
                            set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                case .deepgram:
                    Text("Deepgram TTS reuses the Deepgram API key configured in Advanced Providers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    textFieldRow(
                        title: "Deepgram TTS voice",
                        subtitle: "Aura model identifier — e.g. aura-2-thalia-en, aura-2-orion-en, aura-2-luna-en.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                case .microsoftEdge:
                    Text("Microsoft Edge voices are the free online Read Aloud voices and do not need an API key.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(MicrosoftEdgeVoiceOption.recommended) { voice in
                            optionButton(
                                title: voice.label,
                                subtitle: voice.subtitle,
                                isSelected: AppBundleConfiguration.microsoftEdgeVoiceID() == voice.id,
                                action: {
                                    userMicrosoftEdgeVoiceID = voice.id
                                    companionManager.setMicrosoftEdgeVoiceID(voice.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)

                    textFieldRow(
                        title: "Microsoft Edge voice ID",
                        subtitle: "Optional override for any Edge voice, e.g. en-US-AriaNeural.",
                        systemImageName: "person.wave.2",
                        placeholder: "en-US-EmmaMultilingualNeural",
                        text: Binding(
                            get: { userMicrosoftEdgeVoiceID },
                            set: { userMicrosoftEdgeVoiceID = $0; companionManager.setMicrosoftEdgeVoiceID($0) }
                        )
                    )
                case .mirageCartesia:
                    // Peeky Free TTS reuses the Cartesia voice-id knob but
                    // mints its token via aegis-proxy — nothing extra to
                    // configure locally. Users can still override the voice
                    // id when they want a specific Cartesia voice.
                    Text("Peeky Free TTS uses free-tier Cartesia. No API key required — voice minted per-session via the aegis-proxy endpoint.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional override; defaults to the shipped Peeky Free voice.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userCartesiaVoiceID },
                            set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                }
            }
        }
    }

    private var voiceRouteOverview: some View {
        settingsGroup("Voice route") {
            LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                voiceRouteStep(title: "Listen", value: listenLaneLabel, systemImageName: "mic")
                voiceRouteStep(title: "Think", value: thinkLaneLabel, systemImageName: "brain.head.profile")
                voiceRouteStep(title: "Speak", value: speakLaneLabel, systemImageName: "speaker.wave.2")
            }
            .padding(14)
        }
    }

    /// Voice-route labels. HeyClicky Free is a bundled experience —
    /// Listen / Think / Speak are all served by the same account and
    /// quota, so all three tiles collapse to the brand name. Advanced
    /// Providers keeps the raw technical labels (GPT Realtime, etc.)
    /// for users who want to see or override the underlying transport.
    private var isHeyClickyFreeLane: Bool {
        OpenClickyModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .heyclickyFree
    }

    private var listenLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
            ? "Realtime audio"
            : companionManager.buddyDictationManager.transcriptionProviderDisplayName
    }

    private var thinkLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return selectedResponseVoiceModelLabel
    }

    private var speakLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return OpenClickyModelCatalog.isSpeechModelID(companionManager.selectedModel)
            ? "Realtime voice"
            : companionManager.selectedTTSProvider.displayName
    }

    private var selectedResponseVoiceModelLabel: String {
        OpenClickyModelCatalog.responseVoiceModels.first { $0.id == companionManager.selectedModel }?.label
            ?? companionManager.selectedModel
    }

    private var openAIRealtimeVoiceSelection: Binding<String> {
        Binding(
            get: {
                userOpenAIRealtimeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "cedar"
                    : userOpenAIRealtimeVoiceID
            },
            set: {
                userOpenAIRealtimeVoiceID = $0
                companionManager.setOpenAIRealtimeVoiceID($0)
            }
        )
    }

    private var openAIRealtimeVoicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Realtime voice", selection: openAIRealtimeVoiceSelection) {
                    ForEach(Self.openAIRealtimeVoiceIDs, id: \.self) { voiceID in
                        Text(Self.voiceDisplayName(voiceID)).tag(voiceID)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    Task { await companionManager.previewOpenAIRealtimeVoice(voiceID: openAIRealtimeVoiceSelection.wrappedValue) }
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .help("Preview this voice")
            }
            Text("marin / coral / shimmer / sage sound feminine. cedar / ash / echo / verse sound masculine.")
                .font(appUIFont(size: subtextFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Reply language", selection: responseLanguageSelection) {
                Text("Auto (follow user)").tag("auto")
                Text("简体中文 Chinese").tag("zh")
                Text("English").tag("en")
                Text("日本語 Japanese").tag("ja")
                Text("Español Spanish").tag("es")
                Text("Français French").tag("fr")
                Text("Deutsch German").tag("de")
            }
            .pickerStyle(.menu)
            Text("Forces the assistant to speak in the chosen language. Applied on the next voice turn.")
                .font(appUIFont(size: subtextFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private static func voiceDisplayName(_ voiceID: String) -> String {
        switch voiceID {
        case "marin": return "Marin (feminine)"
        case "coral": return "Coral (feminine)"
        case "shimmer": return "Shimmer (feminine)"
        case "sage": return "Sage (feminine)"
        case "cedar": return "Cedar (masculine)"
        case "ash": return "Ash (masculine)"
        case "echo": return "Echo (masculine)"
        case "verse": return "Verse (masculine)"
        case "ballad": return "Ballad"
        case "alloy": return "Alloy"
        default: return voiceID.capitalized
        }
    }

    private var responseLanguageSelection: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceResponseLanguageDefaultsKey) ?? "auto" },
            set: { UserDefaults.standard.set($0, forKey: AppBundleConfiguration.userVoiceResponseLanguageDefaultsKey) }
        )
    }

    private var skiModePanel: some View {
        SKIModePanelView(
            companionManager: companionManager,
            buddyDictationManager: companionManager.buddyDictationManager
        )
    }

    private var peekyFreePanel: some View {
        PeekyFreePanelView(companionManager: companionManager)
    }

    private var heyClickyFreePanel: some View {
        HeyClickyFreePanelView(companionManager: companionManager)
    }

    private var advancedProvidersPanel: some View {
        AdvancedProvidersPanelView(
            companionManager: companionManager,
            session: session,
            buddyDictationManager: companionManager.buddyDictationManager,
            userCodexAgentAPIKey: $userCodexAgentAPIKey,
            userAnthropicAPIKey: $userAnthropicAPIKey,
            userAssemblyAIAPIKey: $userAssemblyAIAPIKey,
            userDeepgramAPIKey: $userDeepgramAPIKey,
            userElevenLabsAPIKey: $userElevenLabsAPIKey,
            userCartesiaAPIKey: $userCartesiaAPIKey,
            codexAgentBaseURL: $codexAgentBaseURL,
            codexConfigSyncMessage: $codexConfigSyncMessage,
            heyClickyRefreshTick: $heyClickyRefreshTick
        )
    }

    /// Basic-panel promo: first-time users see this before scrolling
    /// through Advanced Providers. Hidden once the user is signed in
    /// to avoid duplicating the state shown in Advanced Providers.
    @ViewBuilder
    private var heyClickyBasicPromo: some View {
        // See note in `heyClickyFreeGroup`.
        let _ = heyClickyRefreshTick
        let _ = activeProfileRefreshTick
        // Hide HeyClicky Free entirely when a non-HeyClicky profile is
        // active (e.g. SKI Mode) — the user has explicitly picked a
        // different backend and should not see promo/quota/sign-in UI
        // for a lane they aren't using.
        if OpenClickyProfileCatalog.activeProfile().id != "heyclicky_free" {
            EmptyView()
        } else if heyClickySignedInState {
            settingsGroup("HeyClicky Free") {
                let email = AppBundleConfiguration.heyClickySessionUserEmail() ?? ""
                valueRow(
                    title: "Signed in",
                    subtitle: email.isEmpty ? "HeyClicky Free is ready." : email,
                    systemImageName: "checkmark.circle.fill"
                )
                if let plan = heyClickyPlan.latest {
                    valueRow(
                        title: "Free quota",
                        subtitle: plan.remainingText,
                        systemImageName: "gauge.with.dots.needle.67percent"
                    )
                } else if heyClickyPlan.isRefreshing {
                    valueRow(
                        title: "Free quota",
                        subtitle: "Loading…",
                        systemImageName: "gauge.with.dots.needle.67percent"
                    )
                } else {
                    valueRow(
                        title: "Free quota",
                        subtitle: "Tap Refresh quota to load — proxy may be cold-starting.",
                        systemImageName: "gauge.with.dots.needle.67percent"
                    )
                }
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Assist Agent (multi-round tools)")
                            .font(.system(size: 13))
                        Text("Lets the model drive extra tool calls for deeper answers. Off = context-only injection.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { AppBundleConfiguration.assistAgentEnabled() },
                        set: { AppBundleConfiguration.setAssistAgentEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                actionRow(title: "Reset free quota now", systemImageName: "arrow.clockwise") {
                    _ = HeyClickyAccountResetManager.shared.attemptReset(reason: "manual_basic")
                }
                actionRow(title: "Refresh quota", systemImageName: "gauge.badge.plus") {
                    Task { await heyClickyPlan.refresh() }
                }
            }
            .onAppear {
                // .onAppear survives view-body rebuilds triggered by
                // heyClickyRefreshTick; a `.task { }` here would get
                // its request cancelled every rebuild (URLError -999).
                Task { await heyClickyPlan.refresh() }
            }
        } else {
            settingsGroup("Try HeyClicky Free (no API key needed)") {
                Text("One Google sign-in unlocks listening, voice replies, and Agent Mode. Configure it any time in Advanced Providers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                actionRow(title: "Sign in with Google", systemImageName: "person.badge.key") {
                    try? HeyClickyOAuthHandler.shared.startSignIn()
                }
            }
        }
    }


    /// Route every lane through HeyClicky Free. Delegates to the
    /// existing profile-application path so this button behaves like
    /// any other built-in profile switch.
    private func applyHeyClickyFreeProfile() {
        let profile = OpenClickyProfileCatalog.heyclickyFree
        OpenClickyProfileCatalog.apply(profile)
        companionManager.setSelectedModel(profile.responseModelID)
    }

    /// Capture the four lane UserDefaults values so "Revert" can put
    /// them back byte-for-byte, including the "originally nil" case.
    private func captureLaneSnapshot() -> [String: String?] {
        let defaults = UserDefaults.standard
        return [
            AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey:
                defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey),
            OpenClickyProfileCatalog.voiceResponseModelDefaultsKey:
                defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey),
            AppBundleConfiguration.userTTSProviderDefaultsKey:
                defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey),
            "clickyCodexModel": defaults.string(forKey: "clickyCodexModel")
        ]
    }

    private func revertHeyClickyProfileApplication() {
        guard let snapshot = heyClickyPreProfileSnapshot else { return }
        let defaults = UserDefaults.standard
        for (key, value) in snapshot {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let restoredModel = snapshot[OpenClickyProfileCatalog.voiceResponseModelDefaultsKey] ?? nil {
            companionManager.setSelectedModel(restoredModel)
        }
        heyClickyPreProfileSnapshot = nil
    }

    private var superAdvancedPanel: some View {
        SuperAdvancedPanelView()
    }

    private var codexAgentEndpointSummary: String {
        let trimmed = codexAgentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Default OpenAI endpoint. Codex uses ChatGPT sign-in unless an OpenAI key is configured."
        }
        guard let url = ClickyCodexBackend.validatedWorkerBaseURL(trimmed) else {
            return "Enter a full http:// or https:// URL before syncing. Agent Mode keeps the previous valid provider config until then."
        }
        let endpoint = ClickyCodexConfigTemplate(workerBaseURL: url).openAICompatibleEndpoint.absoluteString
        return "Custom OpenAI-compatible endpoint to apply on sync: \(endpoint)"
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Core permissions") {
                permissionRow(
                    title: "Accessibility",
                    isGranted: companionManager.hasAccessibilityPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
                permissionRow(
                    title: "Screen Recording",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Screen Content",
                    isGranted: companionManager.hasScreenContentPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Microphone",
                    isGranted: companionManager.hasMicrophonePermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
                permissionRow(
                    title: "Camera",
                    isGranted: companionManager.hasCameraPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
                )
                permissionRow(
                    title: "Full Disk Access",
                    isGranted: companionManager.hasFullDiskAccessPermission,
                    settingsURL: OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL
                )
                permissionRow(
                    title: "System Events Automation",
                    statusText: companionManager.hasSystemEventsAutomationPermission ? "Granted for System Events" : "Needs Automation approval",
                    isGranted: companionManager.hasSystemEventsAutomationPermission,
                    settingsURL: OpenClickyMacPrivacyPermissionProbe.automationSettingsURL
                )
                valueRow(
                    title: "System volume commands",
                    subtitle: "Ready through CoreAudio; no Accessibility or System Events approval needed.",
                    systemImageName: "speaker.wave.2"
                )
            }

            settingsGroup("Desktop notifications") {
                permissionRow(
                    title: "Notifications",
                    statusText: notificationAuthorizationSummary,
                    isGranted: notificationAuthorizationGranted,
                    settingsURL: Self.notificationSettingsURL
                )
                toggleRow(
                    title: "Task-complete notifications",
                    subtitle: "Shows native macOS banners when OpenClicky background agents finish, stop, or are cancelled.",
                    systemImageName: "bell.badge",
                    isOn: Binding(
                        get: { desktopNotificationsEnabled },
                        set: { newValue in
                            desktopNotificationsEnabled = newValue
                            if newValue {
                                OpenClickyDesktopNotificationCenter.shared.requestAuthorizationForUserAction { _ in
                                    refreshNotificationAuthorizationStatus()
                                }
                            }
                        }
                    )
                )
                toggleRow(
                    title: "Task-complete voice",
                    subtitle: "Speaks a short finish summary after an OpenClicky background agent completes. Handoff speech stays separate.",
                    systemImageName: "speaker.wave.2",
                    isOn: $agentCompletionVoiceEnabled
                )
                actionRow(title: "Request notification permission", systemImageName: "bell.badge") {
                    desktopNotificationsEnabled = true
                    OpenClickyDesktopNotificationCenter.shared.requestAuthorizationForUserAction { _ in
                        refreshNotificationAuthorizationStatus()
                    }
                }
                actionRow(title: "Send test notification", systemImageName: "bell") {
                    desktopNotificationsEnabled = true
                    OpenClickyDesktopNotificationCenter.shared.postTestNotification()
                    refreshNotificationAuthorizationStatus()
                }
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshAllPermissions()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                actionRow(title: "Open Microphone settings", systemImageName: "mic") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                actionRow(title: "Open Camera settings", systemImageName: "camera") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                actionRow(title: "Open Full Disk Access settings", systemImageName: "externaldrive.badge.checkmark") {
                    companionManager.openFullDiskAccessSettings()
                }
                actionRow(title: "Open Automation settings", systemImageName: "terminal") {
                    companionManager.openAutomationSettings()
                }
                actionRow(title: "Request System Events access", systemImageName: "gearshape.2") {
                    companionManager.requestSystemEventsAutomationPermission()
                }
            }

            settingsGroup("If macOS shows access but OpenClicky does not") {
                warningRow(
                    title: "Check for stale privacy entries",
                    subtitle: "In Privacy & Security, inspect Accessibility, Full Disk Access, and Automation for older Clicky/OpenClicky entries or separate helper paths. Keep the current OpenClicky entry enabled; remove or disable stale duplicates, then quit and reopen OpenClicky."
                )
                warningRow(
                    title: "Safe re-prompt",
                    subtitle: "If a stored grant is invalid, do not edit the TCC database directly. Remove or toggle the stale macOS entry, relaunch OpenClicky, then use Request System Events access or the relevant Open Settings button to let macOS issue a fresh prompt."
                )
            }
        }
    }

    private var computerUsePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Screen pointing model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.computerUseModels,
                    selectedModelID: companionManager.selectedComputerUseModel,
                    select: { companionManager.setSelectedComputerUseModel($0) }
                )
            }

            settingsGroup("Computer use backend") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(OpenClickyComputerUseBackendID.allCases) { backend in
                        optionButton(
                            title: backend.label,
                            subtitle: backend.subtitle,
                            isSelected: companionManager.selectedComputerUseBackendID == backend.rawValue,
                            action: { companionManager.setSelectedComputerUseBackend(backend.rawValue) }
                        )
                    }
                }
                .padding(14)
            }

            settingsGroup("Native CUA Swift") {
                toggleRow(
                    title: "Enable in-app computer use",
                    subtitle: "Uses OpenClicky's own signed app permissions for focused-window context and targeted keyboard actions.",
                    systemImageName: "macwindow.and.cursorarrow",
                    isOn: Binding(
                        get: { nativeComputerUseController.isEnabled },
                        set: { companionManager.setNativeComputerUseEnabled($0) }
                    )
                )

                valueRow(
                    title: "Runtime status",
                    subtitle: nativeComputerUseController.status.summary,
                    systemImageName: nativeComputerUseController.status.isReadyForComputerUse ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "Focused target",
                    subtitle: nativeComputerUseController.status.focusedTargetSummary,
                    systemImageName: "scope"
                )
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh focused target", systemImageName: "arrow.clockwise") {
                    companionManager.refreshNativeComputerUseFocusedTarget()
                }
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshNativeComputerUseStatus()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }

        }
    }

    private var connectionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Google Workspace") {
                googleConnectionHeader

                valueRow(
                    title: "gogcli",
                    subtitle: gogCLIStatus.isInstalled
                        ? "\(gogCLIStatus.version ?? "Installed") — \(gogCLIStatus.executablePath ?? "gog")"
                        : "Not installed. Install with Homebrew: brew install gogcli",
                    systemImageName: gogCLIStatus.isInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "OAuth credentials",
                    subtitle: gogCLIStatus.credentialsExist
                        ? "Desktop OAuth client is stored locally in gogcli."
                        : "Add a Google Cloud Desktop OAuth client JSON with gog auth credentials.",
                    systemImageName: gogCLIStatus.credentialsExist ? "checkmark.seal" : "key"
                )

                valueRow(
                    title: "Account",
                    subtitle: gogCLIStatus.accountEmail ?? "No default Google account authorized yet.",
                    systemImageName: gogCLIStatus.isReadyForUserAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
                )

                valueRow(
                    title: "Storage",
                    subtitle: gogCLIStatus.configPath ?? "gogcli manages its own local config and keyring.",
                    systemImageName: "externaldrive.badge.person.crop",
                    openPath: gogCLIStatus.configPath
                )
            }

            settingsGroup("MCP servers") {
                toggleRow(
                    title: "OpenAI developer docs",
                    subtitle: "Optional. Adds official OpenAI docs to new agents, but can slow agent startup.",
                    systemImageName: "book.pages",
                    isOn: Binding(
                        get: { mcpDeveloperDocsEnabled },
                        set: { newValue in
                            mcpDeveloperDocsEnabled = newValue
                            syncCodexMCPSettings()
                        }
                    )
                )

                toggleRow(
                    title: "Composio connected apps",
                    subtitle: "Adds Composio Connect MCP for GitHub and other connected-app actions.",
                    systemImageName: "link.badge.plus",
                    isOn: Binding(
                        get: { mcpComposioConnectEnabled },
                        set: { newValue in
                            mcpComposioConnectEnabled = newValue
                            syncCodexMCPSettings()
                        }
                    )
                )

                toggleRow(
                    title: "OpenClicky computer-use MCP",
                    subtitle: "Optional. Exposes the local cuaDriver bridge to new agents when installed.",
                    systemImageName: "cursorarrow.motionlines",
                    isOn: Binding(
                        get: { mcpComputerUseEnabled },
                        set: { newValue in
                            mcpComputerUseEnabled = newValue
                            syncCodexMCPSettings()
                        }
                    )
                )

                textFieldRow(
                    title: "cuaDriver command",
                    subtitle: mcpCuaDriverStatusText,
                    systemImageName: "terminal",
                    placeholder: CuaDriverMCPConfiguration.resolvedCommandPath() ?? "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
                    text: Binding(
                        get: { mcpCuaDriverCommand },
                        set: { newValue in
                            mcpCuaDriverCommand = newValue
                            syncCodexMCPSettings()
                        }
                    ),
                    openPath: { mcpCuaDriverEffectiveCommand }
                )

                valueRow(
                    title: "Codex config",
                    subtitle: companionManager.codexHomeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path,
                    systemImageName: "doc.text",
                    openPath: companionManager.codexHomeManager.codexHomeDirectory.appendingPathComponent("config.toml", isDirectory: false).path
                )

                valueRow(
                    title: "Sync status",
                    subtitle: codexConfigSyncMessage,
                    systemImageName: "checkmark.circle"
                )
            }

            settingsGroup("Workspace actions") {
                actionRow(title: isRefreshingGogCLIStatus ? "Refresh Google status…" : "Refresh Google status", systemImageName: "arrow.clockwise") {
                    refreshGogCLIStatus()
                }
                actionRow(title: "Sync MCP config", systemImageName: "arrow.clockwise") {
                    syncCodexMCPSettings()
                }
                if !gogCLIStatus.isInstalled || !gogCLIStatus.credentialsExist {
                    actionRow(title: "Copy Google setup commands", systemImageName: "doc.on.doc") {
                        copyGoogleWorkspaceSetupCommands()
                    }
                }
            }

            settingsGroup("Persistent memory") {
                valueRow(
                    title: "Memory file",
                    subtitle: companionManager.codexHomeManager.persistentMemoryFile.path,
                    systemImageName: "doc.text",
                    openPath: companionManager.codexHomeManager.persistentMemoryFile.path
                )
                valueRow(
                    title: "Learned skills",
                    subtitle: companionManager.codexHomeManager.learnedSkillsDirectory.path,
                    systemImageName: "wand.and.stars",
                    openPath: companionManager.codexHomeManager.learnedSkillsDirectory.path
                )
                valueRow(
                    title: "Knowledge index",
                    subtitle: "\(companionManager.bundledKnowledgeIndex.articles.count) articles, \(companionManager.bundledKnowledgeIndex.skills.count) skills",
                    systemImageName: "books.vertical"
                )
            }

            settingsGroup("Memory tools") {
                actionRow(title: "Open memory browser", systemImageName: "books.vertical") {
                    companionManager.showMemoryWindow()
                }
                actionRow(title: "Open memory file", systemImageName: "doc.text") {
                    companionManager.openOpenClickyDocument(companionManager.codexHomeManager.persistentMemoryFile)
                }
                actionRow(title: "Open memory archive folder", systemImageName: "archivebox") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryArchivesDirectory)
                }
                actionRow(title: "Open learned skills folder", systemImageName: "folder") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }

            settingsGroup("Logs") {
                valueRow(
                    title: "Message log",
                    subtitle: OpenClickyMessageLogStore.shared.currentLogFile.path,
                    systemImageName: "doc.text.magnifyingglass",
                    openPath: OpenClickyMessageLogStore.shared.currentLogFile.path
                )
                actionRow(title: "Open log viewer", systemImageName: "list.bullet.rectangle") {
                    companionManager.showLogViewerWindow()
                }
                actionRow(title: "Open raw message log", systemImageName: "doc.text") {
                    openMessageLog()
                }
                actionRow(title: "Open logs folder", systemImageName: "folder") {
                    openLogsFolder()
                }
                actionRow(title: "Open widget snapshot", systemImageName: "rectangle.grid.1x2") {
                    companionManager.publishWidgetSnapshot()
                    NSWorkspace.shared.open(OpenClickyWidgetStateStore.snapshotURL)
                }
            }

            settingsGroup("Onboarding") {
                actionRow(title: "Show OpenClicky cursor now", systemImageName: "cursorarrow.rays") {
                    companionManager.triggerOnboarding()
                }
                actionRow(title: "Replay onboarding cleanup", systemImageName: "play.circle") {
                    companionManager.replayOnboarding()
                }
            }

            settingsGroup("Support") {
                actionRow(title: "Report issues and star on GitHub", systemImageName: "star.bubble") {
                    openFeedbackInbox()
                }
            }

            settingsGroup("App") {
                actionRow(title: "Quit OpenClicky", systemImageName: "power", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var googleConnectionHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        Circle()
                            .stroke(
                                AngularGradient(
                                    colors: [.blue, .red, .yellow, .green, .blue],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                    )
                Text("G")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(gogCLIStatus.readinessTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(gogCLIStatus.readinessDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var agentsPanel: some View {
        OpenClickyAgentsSettingsSection(companion: companionManager)
    }

    private var automationsPanel: some View {
        OpenClickyAutomationsSettingsSection(companion: companionManager)
    }

    private var mcpCuaDriverEffectiveCommand: String {
        let trimmed = mcpCuaDriverCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return CuaDriverMCPConfiguration.resolvedCommandPath() ?? ""
    }

    private var mcpCuaDriverStatusText: String {
        guard mcpComputerUseEnabled else {
            return "Disabled. Turn this on to expose OpenClicky's computer-use path to Agent Mode."
        }

        let command = mcpCuaDriverEffectiveCommand
        guard !command.isEmpty else {
            return "No cuaDriver command found. Install cuaDriver or paste the command path."
        }

        if FileManager.default.fileExists(atPath: normalizedSettingsPath(command)) {
            return "Ready: \(command)"
        }

        return "Command will be written to config.toml, but the path was not found yet."
    }

    private func commitCodexAgentBaseURLDraft() throws -> URL {
        let trimmed = codexAgentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "clickyAgentBaseURL")
            codexAgentBaseURL = ""
            return ClickyCodexBackend.defaultOpenAIBaseURL
        }

        guard let url = ClickyCodexBackend.validatedWorkerBaseURL(trimmed) else {
            throw OpenClickySettingsValidationError.invalidAgentBaseURL
        }

        let normalized = url.absoluteString
        UserDefaults.standard.set(normalized, forKey: "clickyAgentBaseURL")
        codexAgentBaseURL = normalized
        return url
    }

    private func applyCodexAgentBaseURLToSessions(_ url: URL) {
        companionManager.codexAgentSessions.forEach { $0.setWorkerBaseURL(url) }
    }

    private func settingsCodexHomeManager() -> CodexHomeManager {
        CodexHomeManager(
            applicationSupportDirectory: companionManager.codexHomeManager.applicationSupportDirectory,
            workerBaseURL: ClickyCodexBackend.configuredWorkerBaseURL(),
            model: session.model,
            reasoningEffort: UserDefaults.standard.string(forKey: "clickyCodexReasoningEffort") ?? "medium"
        )
    }

    private func syncCodexProviderSettings() {
        do {
            let workerBaseURL = try commitCodexAgentBaseURLDraft()
            applyCodexAgentBaseURLToSessions(workerBaseURL)
            let configFile = try session.syncProviderConfigurationFromCurrentSettings()
            let endpoint = ClickyCodexConfigTemplate(workerBaseURL: workerBaseURL).openAICompatibleEndpoint.absoluteString
            codexConfigSyncMessage = "Synced provider config to \(configFile.path). Agent Mode will use \(endpoint) on the next session start."
        } catch OpenClickySettingsValidationError.invalidAgentBaseURL {
            codexConfigSyncMessage = "Could not sync provider config: enter a full http:// or https:// URL with a host. Saved endpoint unchanged."
        } catch {
            codexConfigSyncMessage = "Could not sync provider config: \(error.localizedDescription)"
        }
    }

    private func syncCodexMCPSettings() {
        do {
            let configFile = try settingsCodexHomeManager().writeCodexConfigFromSettings()
            codexConfigSyncMessage = "Synced MCP settings to \(configFile.path). Restart active agents to pick up changes."
        } catch {
            codexConfigSyncMessage = "Could not sync MCP settings: \(error.localizedDescription)"
        }
    }

    private func refreshGogCLIStatus() {
        guard !isRefreshingGogCLIStatus else { return }
        isRefreshingGogCLIStatus = true
        Task {
            let status = await OpenClickyGogCLIStatusResolver.refresh()
            gogCLIStatus = status
            isRefreshingGogCLIStatus = false
        }
    }

    private func copyGoogleWorkspaceSetupCommands() {
        let commands = """
        # Install gogcli if needed
        brew install gogcli

        # Store a Google Cloud Desktop OAuth client JSON locally in gogcli
        gog auth credentials ~/Downloads/client_secret_....json

        # Authorize least-privilege scopes for common agent reads
        gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly
        gog auth add you@example.com --services calendar,tasks --readonly

        # Optional Workspace alias
        gog auth alias set work you@example.com
        gog auth status --json
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    private func openURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }

        openSettingsFile(url)
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")

        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsFile(_ url: URL) {
        if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
            companionManager.openOpenClickyDocument(url)
            return
        }

        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Context Awareness (Phase 7 Layer 4 UX)

    private var contextAwarenessPanel: some View {
        OpenClickyContextAwarenessPanel(
            settings: OpenClickyContextAwarenessSettings.shared,
            hotkeys: companionManager.contextAwarenessHotkeys
        )
    }

    // MARK: - MCP subsystems (Parity P0 wire-in 2026-07-23)
    //
    // Dedicated tab for the four MCP subsystem panels that were previously
    // orphan views compiled into the binary but never called from any
    // parent SwiftUI view (`OpenClickyOpenDiaSettingsSection`,
    // `OpenClickyChromeBridgeSettingsSection`,
    // `OpenClickyOpenCLISettingsSection`,
    // `OpenClickyConnectorSettingsSection`). Also surfaces the
    // external-control bridge bearer token so the user can view / copy
    // / rotate it without editing UserDefaults from Terminal.
    //
    // Everywhere pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
    // (informational — none of these subsystems have upstream
    // Everywhere counterparts.)

    private var mcpSubsystemsPanel: some View {
        MCPSubsystemsPanelView()
    }

    // MARK: - Router settings section (P1 parity — domain 3)

    private var routerSettingsGroup: some View {
        settingsGroup("Router (voice intent classification)") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $routerSettings.routeTagEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable [ROUTE] tag parsing")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                        Text("When off, OpenClicky ignores the model's [ROUTE] tag and routes on context signals only.")
                            .font(appUIFont(size: subtextFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Confidence gate")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                            .frame(width: 140, alignment: .leading)
                        Slider(value: $routerSettings.confidenceGate, in: 0.0...1.0, step: 0.05)
                        Text(String(format: "%.2f", routerSettings.confidenceGate))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Below this confidence, OpenClicky falls back to the context classifier instead of spawning codex.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Default completion marker")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                            .frame(width: 190, alignment: .leading)
                        TextField(
                            OpenClickyRouterSettings.defaultCompletionMarkerFallback,
                            text: $routerSettings.defaultCompletionMarker
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                    Text("Marker OpenClicky's F28 observer polls to know a long-run task is done. Case-sensitive.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.025))
            )
            .glassEffect(
                .regular.tint(DS.Colors.accent.opacity(0.035)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func fontSizeSliderRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = " pt"
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 1)
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                    .font(appUIFont(size: subtextFontSize, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func settingsOptionColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func voiceRouteStep(title: String, value: String, systemImageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.6)
            }

            Text(LocalizedStringKey(value))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle)).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("exclamationmark.triangle")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func textFieldRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        placeholder: String,
        text: Binding<String>,
        openPath: (() -> String)? = nil
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 8) {
                TextField(LocalizedStringKey(placeholder), text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
                if let openPath {
                    settingsPathOpenButton(openPath())
                }
            }
        }
    }

    private func secureFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            SecureField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
        }
    }

    private func editableFieldRow<Field: View>(
        title: String,
        subtitle: String,
        systemImageName: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle)).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
                field()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                rowIcon(systemImageName)
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        Button {
            openSettingsPath(rawPath)
        } label: {
            Image(systemName: settingsPathOpenIconName(for: rawPath))
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "doc.richtext"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "Open in OpenClicky Markdown viewer"
        }
        return "Open in TextEdit"
    }

    private func refreshNotificationAuthorizationStatus() {
        OpenClickyDesktopNotificationCenter.shared.refreshAuthorizationStatus { summary, isGranted in
            DispatchQueue.main.async {
                notificationAuthorizationSummary = summary
                notificationAuthorizationGranted = isGranted
            }
        }
    }

    private func permissionRow(title: String, isGranted: Bool, settingsURL: URL) -> some View {
        permissionRow(
            title: title,
            statusText: isGranted ? "Granted" : "Needs permission",
            isGranted: isGranted,
            settingsURL: settingsURL
        )
    }

    private func permissionRow(title: String, statusText: String, isGranted: Bool, settingsURL: URL) -> some View {
        HStack(spacing: 12) {
            rowIcon(isGranted ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(statusText))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func modelOptionGrid(
        options: [OpenClickyModelOption],
        selectedModelID: String,
        columns: Int = 2,
        select: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: settingsOptionColumns(columns), spacing: 8) {
            ForEach(options) { option in
                optionButton(
                    title: option.label,
                    subtitle: option.provider.displayName,
                    isSelected: selectedModelID == option.id,
                    action: { select(option.id) }
                )
            }
        }
        .padding(14)
    }

    private func optionButton(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(subtitle))
                        .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    private var currentCursorAvatarStyle: ClickyCursorAvatarStyle {
        ClickyCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    private func cursorColorButton(_ accentTheme: ClickyAccentTheme) -> some View {
        let isSelected = selectedAccentThemeID == accentTheme.rawValue
        return Button {
            selectedAccentThemeID = accentTheme.rawValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentTheme.cursorColor.opacity(0.15))
                    Triangle()
                        .fill(accentTheme.cursorColor)
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(-25))
                }
                .frame(width: 46, height: 46)

                Text(LocalizedStringKey(accentTheme.title))
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accentTheme.cursorColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accentTheme.cursorColor.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    private func cursorAvatarButton(_ style: ClickyCursorAvatarStyle, label: String) -> some View {
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button {
            avatarStyleRawValue = style.storageValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.045))
                        .frame(width: 46, height: 46)

                    switch style {
                    case .triangleFilled:
                        Triangle()
                            .fill(accent)
                            .frame(width: 19, height: 19)
                            .rotationEffect(.degrees(-25))
                            .shadow(color: accent.opacity(0.55), radius: 7)
                    case .triangleOutline:
                        Triangle()
                            .stroke(accent, lineWidth: 2.2)
                            .frame(width: 19, height: 19)
                            .rotationEffect(.degrees(-25))
                    case .pet:
                        EmptyView()
                    }
                }

                Text(LocalizedStringKey(label))
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func cursorPetButton(_ pet: ClickyBuddyPet) -> some View {
        let style = ClickyCursorAvatarStyle.pet(id: pet.id)
        let isSelected = currentCursorAvatarStyle == style
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return Button {
            avatarStyleRawValue = style.storageValue
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.045))
                        .frame(width: 46, height: 46)
                    ClickyPetThumbnailView(pet: pet)
                        .frame(width: 34, height: 36)
                }

                Text(LocalizedStringKey(pet.displayName))
                    .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(pet.petDescription)
    }

    private var openPetsCatalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenPets gallery")
                        .font(appUIFont(size: bodyFontSize, weight: .semibold))
                    Text("Browse installable pets from openpets.dev. Installed packs land in the same local pet library OpenClicky already watches.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(openPetsCatalog.isLoading ? "Loading…" : "Refresh") {
                    openPetsCatalog.refreshCatalog()
                }
                .disabled(openPetsCatalog.isLoading)
                .controlSize(.small)
            }

            TextField("Search loaded OpenPets", text: $openPetsCatalog.searchText)
                .textFieldStyle(.roundedBorder)
                .font(appUIFont(size: bodyFontSize, weight: .regular))

            if let error = openPetsCatalog.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(openPetsCatalog.visiblePets) { pet in
                    openPetsCatalogCard(pet)
                }
            }

            HStack {
                let loaded = max(openPetsCatalog.pets.count, openPetsCatalog.visiblePets.count)
                Text(openPetsCatalog.totalCount > 0 ? "\(loaded) of \(openPetsCatalog.totalCount) OpenPets loaded" : "OpenPets catalog")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)

                Spacer()

                if openPetsCatalog.loadedPageCount < openPetsCatalog.pageCount {
                    Button(openPetsCatalog.isLoading ? "Loading…" : "Load more") {
                        openPetsCatalog.loadMore()
                    }
                    .disabled(openPetsCatalog.isLoading)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            openPetsCatalog.loadInitialCatalogIfNeeded()
        }
    }

    private func openPetsCatalogCard(_ pet: OpenPetsCatalogPet) -> some View {
        let isInstalled = petLibrary.pet(withID: pet.id) != nil
        let isInstalling = openPetsCatalog.installingPetIDs.contains(pet.id)
        let accent = (ClickyAccentTheme(rawValue: selectedAccentThemeID) ?? .blue).cursorColor

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: 76)

                if let url = pet.previewURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "pawprint")
                                .foregroundColor(.secondary)
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 58, height: 62)
                } else {
                    Image(systemName: "pawprint")
                        .foregroundColor(.secondary)
                }
            }

            Text(LocalizedStringKey(pet.displayName))
                .font(appUIFont(size: max(10, subtextFontSize), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(LocalizedStringKey(pet.description))
                .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(2)

            Button {
                if isInstalled {
                    avatarStyleRawValue = ClickyCursorAvatarStyle.pet(id: pet.id).storageValue
                } else {
                    openPetsCatalog.install(pet, into: petLibrary)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    Text(isInstalled ? "Use" : isInstalling ? "Installing…" : "Install")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isInstalled ? accent : DS.Colors.accent)
            .controlSize(.small)
            .disabled(isInstalling)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(pet.description)
    }

    private var emptyPetLibraryTile: some View {
        VStack(spacing: 7) {
            Image(systemName: "pawprint")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            Text("No pets")
                .font(appUIFont(size: max(10, subtextFontSize), weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
    }

    private func openFeedbackInbox() {
        guard let url = URL(string: "https://github.com/jasonkneen/openclicky/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openMessageLog() {
        OpenClickyMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_message_log"
        )
        NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.currentLogFile)
    }

    private func openLogsFolder() {
        OpenClickyMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_logs_folder"
        )
        NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.logDirectory)
    }
}

// MARK: - MCPSubsystemsPanelView
//
// Isolated from OpenClickySettingsView so it does not rebuild every
// time CompanionManager publishes (e.g. 30 Hz audio power). Owns
// its own @State and reads settings singletons directly. Any
// @AppStorage bindings here read UserDefaults, so they do not tie
// this subtree to the parent view.
private struct MCPSubsystemsPanelView: View {
    @StateObject private var webSearchSettings = OpenClickyWebSearchSettings.shared
    @AppStorage("openclicky.xlb.libraryDir") private var xlbLibraryDirUserDefault: String = ""
    @AppStorage(AppBundleConfiguration.userXLBEnabledDefaultsKey) private var xlbEnabledUserDefault = false
    @AppStorage(AppBundleConfiguration.userXLBHostUrlDefaultsKey) private var xlbHostUrlUserDefault = ""
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @State private var bridgeTokenPreviewTick: Int = 0
    @State private var cachedBridgeToken: String = ""
    @State private var xlbIndexStatsTick: Int = 0
    @State private var xlbIndexStats: XLBTopicIndex.IndexStats?
    @State private var xlbBusy: Bool = false
    @State private var xlbBanner: String?

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular:
                return .medium
            case .medium:
                return .semibold
            case .semibold:
                return .bold
            case .bold, .heavy, .black:
                return .black
            default:
                return weight
            }
        } else {
            switch weight {
            case .black, .heavy:
                return .semibold
            case .bold:
                return .medium
            case .semibold:
                return .medium
            case .medium:
                return .regular
            case .regular:
                return .regular
            default:
                return weight
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("Browser (OpenDia)") {
                OpenClickyOpenDiaSettingsSection(settings: OpenClickyOpenDiaSettings.shared)
            }
            settingsGroup("OpenCLI (site adapters)") {
                OpenClickyOpenCLISettingsSection(settings: OpenClickyOpenCLISettings.shared)
            }
            settingsGroup("Connectors (open-connector)") {
                OpenClickyConnectorSettingsSection(settings: OpenClickyConnectorSettings.shared)
            }
            settingsGroup("Chrome Bridge (account reset)") {
                OpenClickyChromeBridgeSettingsSection()
            }
            settingsGroup("External-control bridge auth") {
                externalControlBridgeAuthRow
            }
            settingsGroup("xlinkBook Integration") {
                xlinkBookIntegrationRow
            }
            webSearchProvidersSettingsGroup
        }
        .onAppear {
            cachedBridgeToken = AppBundleConfiguration.externalControlBridgeToken() ?? ""
        }
        .onChange(of: bridgeTokenPreviewTick) { _, _ in
            cachedBridgeToken = AppBundleConfiguration.externalControlBridgeToken() ?? ""
        }
    }

    private var externalControlBridgeAuthRow: some View {
        let _ = bridgeTokenPreviewTick
        let tokenPreview: String = {
            let token = cachedBridgeToken
            if !token.isEmpty {
                let head = String(token.prefix(8))
                return "\(head)… (\(token.count) chars)"
            }
            return "not set"
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bearer token")
                        .font(.system(size: 13, weight: .medium))
                    Text(LocalizedStringKey(tokenPreview))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("Written into the Codex MCP config so external tools can drive OpenClicky. Rotate if you suspect the token is leaked.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Copy") {
                    let token = cachedBridgeToken
                    if !token.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cachedBridgeToken.isEmpty)
                Button("Regenerate") {
                    _ = AppBundleConfiguration.regenerateExternalControlBridgeToken()
                    bridgeTokenPreviewTick &+= 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var xlinkBookIntegrationRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $xlbEnabledUserDefault) {
                Text("Enable xlinkBook integration")
                    .font(appUIFont(size: bodyFontSize, weight: .regular))
            }
            .toggleStyle(.switch)
            .onChange(of: xlbEnabledUserDefault) { _, _ in refreshXLBStats() }

            VStack(alignment: .leading, spacing: 4) {
                Text("Library Directory")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                TextField("~/.xlb-env/xlinkBook/db/library", text: $xlbLibraryDirUserDefault)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!xlbEnabledUserDefault)
                Text("Path to xlinkBook `*-library` files. Empty uses default. Swift-native parser + local sqlite; no external CLI dependency.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text("xlinkBook Host URL")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                TextField("http://localhost:5000", text: $xlbHostUrlUserDefault)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!xlbEnabledUserDefault)
                Text("Optional. xlinkBook Flask server (default port 5000). Used by xlb_get_topic / _section / _agent_state / _execute_command MCP tools to fetch topic content. Local parser + graph still work offline.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Graph output: ~/Library/Application Support/OpenClicky/xlb-graph.json")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            Text(LocalizedStringKey(xlbStatusLine))
                .font(appUIFont(size: subtextFontSize, weight: .regular))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button {
                    guard xlbEnabledUserDefault else { return }
                    xlbBusy = true
                    xlbBanner = nil
                    Task {
                        do {
                            _ = try await XLBTopicIndex.shared.syncIfNeeded(force: true)
                            await MainActor.run {
                                xlbBanner = "Rebuild complete."
                                xlbBusy = false
                                refreshXLBStats()
                            }
                        } catch {
                            await MainActor.run {
                                xlbBanner = "Rebuild failed: \(error.localizedDescription)"
                                xlbBusy = false
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if xlbBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text("Rebuild Index")
                            .font(appUIFont(size: bodyFontSize, weight: .medium))
                    }
                }
                .disabled(!xlbEnabledUserDefault || xlbBusy)

                Button {
                    guard xlbEnabledUserDefault else { return }
                    xlbBusy = true
                    xlbBanner = nil
                    Task {
                        do {
                            let url = try await XLBTopicIndex.shared.regenerateGraphJson()
                            await MainActor.run {
                                xlbBanner = "graph.json written to \(url.path)"
                                xlbBusy = false
                            }
                        } catch {
                            await MainActor.run {
                                xlbBanner = "graph.json export failed: \(error.localizedDescription)"
                                xlbBusy = false
                            }
                        }
                    }
                } label: {
                    Text("Regenerate graph.json")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                }
                .disabled(!xlbEnabledUserDefault || xlbBusy)
            }

            if !xlbEnabledUserDefault {
                Text("Enable xlinkBook integration first.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.orange)
            }

            if let banner = xlbBanner {
                Text(LocalizedStringKey(banner))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(banner.hasPrefix("Rebuild failed") || banner.hasPrefix("graph.json export failed") ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .onAppear { refreshXLBStats() }
    }

    private static let xlbRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var xlbStatusLine: String {
        guard xlbEnabledUserDefault else {
            return "Local index: unavailable (integration disabled)."
        }
        guard let stats = xlbIndexStats else {
            return "Local index: not yet built. Click Rebuild Index."
        }
        let syncedText: String
        if let date = stats.lastSyncedAt {
            syncedText = Self.xlbRelativeFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            syncedText = "never"
        }
        return "Local index: \(stats.topicCount) topics, \(stats.edgeCount) edges. Last synced: \(syncedText)."
    }

    private func refreshXLBStats() {
        Task {
            let stats = await XLBTopicIndex.shared.indexStats()
            await MainActor.run {
                self.xlbIndexStats = stats
            }
        }
    }

    private var webSearchProvidersSettingsGroup: some View {
        settingsGroup("Web search providers") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($webSearchSettings.providers) { $provider in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $provider.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        TextField("Name", text: $provider.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("Endpoint URL", text: $provider.endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        SecureField("API Key", text: $provider.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Button {
                            webSearchSettings.providers.removeAll { $0.id == provider.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button {
                        webSearchSettings.providers.append(
                            OpenClickyWebSearchProviderConfig(
                                name: "",
                                endpoint: "",
                                apiKey: ""
                            )
                        )
                    } label: {
                        Label("Add provider", systemImage: "plus.circle")
                    }
                    Spacer()
                    if let active = webSearchSettings.activeProvider {
                        Text("Active: \(active.name.isEmpty ? "(unnamed)" : active.name)")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text("No enabled provider — web_search returns not_configured.")
                            .font(appUIFont(size: subtextFontSize, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Text("Only one provider is active at a time (first enabled row with a non-empty endpoint). API keys are stored in UserDefaults; leave blank to skip.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - SuperAdvancedPanelView
//
// Isolated from OpenClickySettingsView so it does not rebuild every
// time CompanionManager publishes (e.g. 30 Hz audio power). Owns
// its own @State and reads singletons directly. Any @AppStorage
// bindings read UserDefaults, so they do not tie this subtree to
// the parent view. Uses local `settingsGroup` with regularMaterial
// background instead of stacked glassEffect groups.
private struct SuperAdvancedPanelView: View {
    @StateObject private var localModelDownloadService = OpenClickyLocalModelDownloadService.shared
    @StateObject private var localInferenceRuntime = OpenClickyLocalInferenceRuntimeManager.shared
    @AppStorage("clickyAgentBaseURL") private var codexAgentBaseURL: String = ""
    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false
    @State private var pendingLocalModelDeletion: OpenClickyLocalModel?
    @State private var localModelDeletionError: String?

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular: return .medium
            case .medium: return .semibold
            case .semibold: return .bold
            case .bold, .heavy, .black: return .black
            default: return weight
            }
        } else {
            switch weight {
            case .black, .heavy: return .semibold
            case .bold: return .medium
            case .semibold: return .medium
            case .medium: return .regular
            case .regular: return .regular
            default: return weight
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Local inference runtime") {
                valueRow(
                    title: "OpenClicky local endpoint",
                    subtitle: localInferenceRuntime.state.message,
                    systemImageName: "server.rack"
                )

                valueRow(
                    title: "Agent Mode endpoint",
                    subtitle: codexAgentEndpointSummary,
                    systemImageName: "network"
                )
            }

            localModelInstallsGroup
        }
        .confirmationDialog(
            "Remove downloaded model?",
            isPresented: Binding(
                get: { pendingLocalModelDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingLocalModelDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let model = pendingLocalModelDeletion {
                Button("Delete \(model.name)", role: .destructive) {
                    deleteLocalModel(model)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let model = pendingLocalModelDeletion {
                Text("OpenClicky will remove the local files for \(model.name) from disk.")
            }
        }
        .alert("Could not remove model", isPresented: Binding(
            get: { localModelDeletionError != nil },
            set: { newValue in
                if !newValue { localModelDeletionError = nil }
            }
        )) {
            Button("OK", role: .cancel) {
                localModelDeletionError = nil
            }
        } message: {
            Text(localModelDeletionError ?? "")
        }
    }

    private var codexAgentEndpointSummary: String {
        let trimmed = codexAgentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Default OpenAI endpoint. Codex uses ChatGPT sign-in unless an OpenAI key is configured."
        }
        guard let url = ClickyCodexBackend.validatedWorkerBaseURL(trimmed) else {
            return "Enter a full http:// or https:// URL before syncing. Agent Mode keeps the previous valid provider config until then."
        }
        let endpoint = ClickyCodexConfigTemplate(workerBaseURL: url).openAICompatibleEndpoint.absoluteString
        return "Custom OpenAI-compatible endpoint to apply on sync: \(endpoint)"
    }

    private var localModelInstallsGroup: some View {
        settingsGroup("Local model installs") {
            valueRow(
                title: "Model store",
                subtitle: OpenClickyLocalModelStore.modelsDirectory().path,
                systemImageName: "externaldrive",
                openPath: OpenClickyLocalModelStore.modelsDirectory().path
            )

            ForEach(OpenClickyLocalModelCatalog.models) { model in
                localModelInstallRow(model)
            }

            valueRow(
                title: "Inference runtime",
                subtitle: "Installed bundles can be launched by OpenClicky at \(ClickyCodexConfigTemplate(workerBaseURL: ClickyCodexBackend.openClickyLocalModelBaseURL).openAICompatibleEndpoint.absoluteString). Downloaded rows show a green tick, and Delete removes the local bundle.",
                systemImageName: "server.rack"
            )

            if let failure = localModelDownloadService.lastFailure {
                warningRow(
                    title: "Latest installer failure",
                    subtitle: failure.diagnosticLine
                )
            }
        }
    }

    private func localModelInstallRow(_ model: OpenClickyLocalModel) -> some View {
        let status = localModelDownloadService.installStatuses[model.id]
            ?? OpenClickyLocalModelStore.status(for: model)
        let state = localModelDownloadService.downloadStates[model.id]
            ?? OpenClickyLocalModelDownloadState(
                modelID: model.id,
                phase: .notStarted,
                metrics: nil,
                updatedAt: Date()
            )

        return HStack(alignment: .top, spacing: 12) {
            localModelRowIcon(isInstalled: status.state.isInstalled)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(model.name))
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    if model.isRecommended {
                        Text("Recommended")
                            .font(appUIFont(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                }

                Text(localModelInstallSubtitle(model: model, status: status, state: state))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            localModelInstallButton(model: model, status: status, state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func localModelInstallSubtitle(
        model: OpenClickyLocalModel,
        status: OpenClickyLocalModelStatus,
        state: OpenClickyLocalModelDownloadState
    ) -> String {
        var parts: [String] = [status.state.label]
        switch state.phase {
        case .notStarted, .completed:
            break
        case .downloading:
            parts.append(state.phase.label)
            if let metrics = state.metrics {
                parts.append(metrics.formattedLine)
            }
        case .resolvingManifest, .verifying:
            parts.append(state.phase.label)
        case .cancelled:
            parts.append("Cancelled")
        case .failed(let message):
            parts.append("Failed: \(message)")
        }

        if case .notStarted = state.phase, let size = model.formattedEstimatedDownloadSize {
            parts.append(size)
        }
        if let memory = model.minimumRecommendedMemoryGB {
            parts.append("\(memory) GB RAM recommended")
        }
        parts.append("OpenClicky model \(model.agentModeModelID)")
        return parts.joined(separator: " - ")
    }

    @ViewBuilder
    private func localModelInstallButton(
        model: OpenClickyLocalModel,
        status: OpenClickyLocalModelStatus,
        state: OpenClickyLocalModelDownloadState
    ) -> some View {
        if status.state.isInstalled {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(appUIFont(size: bodyFontSize + 1, weight: .semibold))
                    .accessibilityLabel("\(model.name) downloaded")

                Button("Delete") {
                    pendingLocalModelDeletion = model
                }
                .buttonStyle(.bordered)
            }
        } else {
            switch state.phase {
            case .resolvingManifest, .verifying:
                Button(state.phase.label) {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            case .downloading:
                Button("Cancel") {
                    localModelDownloadService.cancel(modelID: model.id)
                }
                .buttonStyle(.bordered)
            default:
                Button("Download") {
                    localModelDownloadService.download(model)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func deleteLocalModel(_ model: OpenClickyLocalModel) {
        pendingLocalModelDeletion = nil
        do {
            if case let .running(modelID) = localInferenceRuntime.state.phase,
               modelID == model.agentModeModelID {
                localInferenceRuntime.stop()
            }
            try localModelDownloadService.delete(model)
        } catch {
            localModelDeletionError = error.localizedDescription
        }
    }

    private func localModelRowIcon(isInstalled: Bool) -> some View {
        Image(systemName: isInstalled ? "checkmark.circle.fill" : "externaldrive.badge.plus")
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
            .foregroundStyle(isInstalled ? Color.green : Color.secondary)
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("exclamationmark.triangle")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        Button {
            openSettingsPath(rawPath)
        } label: {
            Image(systemName: settingsPathOpenIconName(for: rawPath))
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "doc.richtext"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "Open in OpenClicky Markdown viewer"
        }
        return "Open in TextEdit"
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")
        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - AgentParkingPositionPicker

/// A screen-shaped preview with eight tappable anchor points. Tapping
/// any dot selects that parking position and updates the binding.
struct AgentParkingPositionPicker: View {
    @Binding var selection: AgentParkingPosition
    var calibrationChanged: (AgentParkingPosition, CGSize) -> Void = { _, _ in }
    @State private var activeDragPosition: AgentParkingPosition?
    @State private var dragPreviewOffsets: [AgentParkingPosition: CGSize] = [:]

    private let dotSize: CGFloat = 18
    private let hitTargetSize: CGFloat = 36
    private let outlineColor = Color.secondary.opacity(0.55)
    private let selectedColor = Color.accentColor
    private let coordinateSpaceName = "AgentParkingPositionPreview"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where agents park")
                .font(.headline)

            Text("Pick where the agent dock parks, or drag a dot to fine-tune the corner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let frame = previewRect(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(outlineColor, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    Rectangle()
                        .fill(outlineColor.opacity(0.25))
                        .frame(width: frame.width, height: 6)
                        .position(x: frame.midX, y: frame.minY + 3)

                    ForEach(AgentParkingPosition.allCases) { position in
                        let dotPosition = absolutePoint(for: position, in: frame)
                        Button {
                            selection = position
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.primary.opacity(0.001))
                                    .frame(width: hitTargetSize, height: hitTargetSize)

                                Circle()
                                    .fill(position == selection ? selectedColor : Color.clear)
                                    .overlay(
                                        Circle().stroke(
                                            position == selection ? selectedColor : outlineColor,
                                            lineWidth: position == selection ? 0 : 1.5
                                        )
                                    )
                                    .frame(width: dotSize, height: dotSize)

                                if position == selection || position == activeDragPosition {
                                    ParkingCornerDragIndicator(
                                        tint: position == activeDragPosition ? selectedColor : outlineColor.opacity(0.82),
                                        isActive: position == activeDragPosition
                                    )
                                }
                            }
                            .frame(width: hitTargetSize, height: hitTargetSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .position(x: dotPosition.x, y: dotPosition.y)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
                                .onChanged { value in
                                    let clampedLocation = CGPoint(
                                        x: min(max(value.location.x, frame.minX), frame.maxX),
                                        y: min(max(value.location.y, frame.minY), frame.maxY)
                                    )
                                    let basePoint = baseAbsolutePoint(for: position, in: frame)
                                    let previewOffset = CGSize(
                                        width: clampedLocation.x - basePoint.x,
                                        height: clampedLocation.y - basePoint.y
                                    )
                                    selection = position
                                    activeDragPosition = position
                                    dragPreviewOffsets[position] = previewOffset
                                    calibrationChanged(
                                        position,
                                        screenOffset(from: previewOffset, previewFrame: frame)
                                    )
                                }
                                .onEnded { _ in
                                    activeDragPosition = nil
                                }
                        )
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
            }
            .frame(height: 176)
            .padding(.vertical, 6)

            Text(activeDragPosition == selection ? "\(selection.label) — drag to correct placement" : selection.label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var mainScreenAspectRatio: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return 16.0 / 10.0
        }
        return frame.width / frame.height
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let availableHeight = size.height
        let availableWidth = size.width
        let aspectRatio = mainScreenAspectRatio
        let widthFromHeight = availableHeight * aspectRatio
        let heightFromWidth = availableWidth / aspectRatio
        let width: CGFloat
        let height: CGFloat
        if widthFromHeight <= availableWidth {
            width = widthFromHeight
            height = availableHeight
        } else {
            width = availableWidth
            height = heightFromWidth
        }
        let originX = (availableWidth - width) / 2
        let originY = (availableHeight - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func absolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let basePoint = baseAbsolutePoint(for: position, in: frame)
        let previewOffset = dragPreviewOffsets[position]
            ?? previewOffset(from: AgentParkingPosition.calibrationOffset(for: position), previewFrame: frame)
        return CGPoint(
            x: min(max(basePoint.x + previewOffset.width, frame.minX), frame.maxX),
            y: min(max(basePoint.y + previewOffset.height, frame.minY), frame.maxY)
        )
    }

    private func baseAbsolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let anchor = position.normalizedAnchor
        return CGPoint(
            x: frame.minX + anchor.x * frame.width,
            y: frame.minY + anchor.y * frame.height
        )
    }

    private func previewOffset(from screenOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: screenOffset.width * frame.width / max(mainScreenSize.width, 1),
            height: -screenOffset.height * frame.height / max(mainScreenSize.height, 1)
        )
    }

    private func screenOffset(from previewOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: previewOffset.width / max(frame.width, 1) * mainScreenSize.width,
            height: -previewOffset.height / max(frame.height, 1) * mainScreenSize.height
        )
    }

    private var mainScreenSize: CGSize {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return CGSize(width: 1600, height: 1000)
        }
        return frame.size
    }
}

private struct ParkingCornerDragIndicator: View {
    let tint: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                ParkingCornerBracket()
                    .stroke(tint, style: StrokeStyle(lineWidth: isActive ? 2.2 : 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(Double(index) * 90))
                    .offset(x: index == 0 || index == 3 ? -13 : 13, y: index < 2 ? -13 : 13)
            }
        }
        .frame(width: 44, height: 44)
        .opacity(isActive ? 1 : 0.72)
    }
}

private struct ParkingCornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

// MARK: - SKIModePanelView

private struct SKIModePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var buddyDictationManager: BuddyDictationManager
    @StateObject private var whisperLocalModelManager = WhisperLocalModelManager.shared
    @StateObject private var agentsPresence = OpenClickyAgentsPresenceStore.shared
    @State private var detectedVoiceSkillAgents: [OpenClickyDetectedAgent] = OpenClickyVoiceSkillInstaller.detectAgents()

    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular: return .medium
            case .medium: return .semibold
            case .semibold: return .bold
            case .bold, .heavy, .black: return .black
            default: return weight
            }
        } else {
            switch weight {
            case .black, .heavy: return .semibold
            case .bold: return .medium
            case .semibold: return .medium
            case .medium: return .regular
            case .regular: return .regular
            default: return weight
            }
        }
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        Button {
            openSettingsPath(rawPath)
        } label: {
            Image(systemName: settingsPathOpenIconName(for: rawPath))
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "doc.richtext"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "Open in OpenClicky Markdown viewer"
        }
        return "Open in TextEdit"
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")
        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                voiceSkillInstallGroup
                whisperLocalGroup
                skiModeSTTGroup
                skiModeAgentModelGroup
                skiModeWorkspacesGroup
                skiModeHandsFreeGroup
                skiModePreferencesGroup
                skiModeHotkeysGroup
            }
            .padding(24)
        }
    }

    // MARK: - STT lane (parity with HeyClicky / Peeky panels)

    /// SKI's recommended STT is local Whisper (offline, matches SKI's
    /// hands-free posture). Users who want a hosted lane can override
    /// per-profile; choice persists across profile switches.
    private var skiModeSTTGroup: some View {
        settingsGroup("Speech-to-text") {
            Text("Which STT engine SKI uses to hear your dictation. Recommended: local Whisper for offline privacy. Override here for a hosted lane on this profile only.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("STT", selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
                        ?? BuddyTranscriptionProviderID.whisperLocal.rawValue
                },
                set: { companionManager.setVoiceTranscriptionProviderPreservingOverride($0) }
            )) {
                ForEach(BuddyTranscriptionProviderID.allCases, id: \.rawValue) { p in
                    Text(p.label).tag(p.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    // MARK: - Agent model (parity with HeyClicky / Peeky panels)

    /// Which model handles Codex Agent Mode tool-call turns when SKI is
    /// the active profile. Stored under `clickyCodexModel` — same key
    /// HeyClicky writes to. Peeky Free routes its equivalent to a
    /// separate storage key because it uses the mirage/… namespace.
    private var skiModeAgentModelGroup: some View {
        settingsGroup("Agent model") {
            Text("Which model handles multi-turn Codex Agent runs (planning, edits, tool calls). Independent of any dialog model — pick by the reasoning depth you want.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Agent model", selection: Binding<String>(
                get: {
                    UserDefaults.standard.string(forKey: "clickyCodexModel")
                        ?? OpenClickyModelCatalog.defaultCodexActionsModelID
                },
                set: { companionManager.setAgentModelPreservingOverride($0) }
            )) {
                ForEach(OpenClickyModelCatalog.codexActionsModels, id: \.id) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    // MARK: - SKI Hotkeys (parity with ~/.ski/settings.json `hotkeys`)

    @AppStorage(SKIModeHotkeyKeys.nextProject)   private var hkNextProject: String = ""
    @AppStorage(SKIModeHotkeyKeys.toggleSilent)  private var hkToggleSilent: String = ""
    @AppStorage(SKIModeHotkeyKeys.captureScreen) private var hkCaptureScreen: String = ""
    @AppStorage(SKIModeHotkeyKeys.toggleWidget)  private var hkToggleWidget: String = ""
    @AppStorage(SKIModeHotkeyKeys.isSilent)      private var hkSilentMode: Bool = false

    private var skiModeHotkeysGroup: some View {
        settingsGroup("SKI Mode hotkeys") {
            hotkeyRow(
                title: "Next project (cycle)",
                subtitle: "Cycle through connected CLI workspaces. Auto → each pinned → back to Auto.",
                systemImageName: "arrow.triangle.2.circlepath",
                binding: $hkNextProject,
                defaultKey: SKIModeHotkeyKeys.nextProject
            )
            hotkeyRow(
                title: "Silent reply (mute TTS)",
                subtitle: "Bubble still shows the reply; TTS playback is skipped. Currently: \(hkSilentMode ? "silent" : "audible").",
                systemImageName: hkSilentMode ? "speaker.slash.fill" : "speaker.wave.2",
                binding: $hkToggleSilent,
                defaultKey: SKIModeHotkeyKeys.toggleSilent
            )
            hotkeyRow(
                title: "Capture screen",
                subtitle: "Snapshot main display → active workspace's `.oc/screenshots/` + `screen.captured` event.",
                systemImageName: "camera.viewfinder",
                binding: $hkCaptureScreen,
                defaultKey: SKIModeHotkeyKeys.captureScreen
            )
            hotkeyRow(
                title: "Toggle widget",
                subtitle: "Hide or re-show the OpenClicky notch panel.",
                systemImageName: "rectangle.on.rectangle.slash",
                binding: $hkToggleWidget,
                defaultKey: SKIModeHotkeyKeys.toggleWidget
            )
        }
    }

    private func hotkeyRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        binding: Binding<String>,
        defaultKey: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowIcon(systemImageName)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            Text(hotkeyDisplay(binding.wrappedValue))
                .font(.system(size: max(11, subtextFontSize), design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.12))
                )
                .textSelection(.enabled)
            Button {
                binding.wrappedValue = SKIModeHotkeyMonitor.defaults[defaultKey] ?? ""
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .help("Reset to default binding")
            Button {
                binding.wrappedValue = ""
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Clear binding")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hotkeyDisplay(_ raw: String) -> String {
        guard !raw.isEmpty else { return "Unbound" }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let flagsRaw = UInt64(parts[0]),
              let keycode = UInt16(parts[1]) else {
            return raw
        }
        var pieces: [String] = []
        if flagsRaw & CGEventFlags.maskControl.rawValue   != 0 { pieces.append("⌃") }
        if flagsRaw & CGEventFlags.maskAlternate.rawValue != 0 { pieces.append("⌥") }
        if flagsRaw & CGEventFlags.maskShift.rawValue     != 0 { pieces.append("⇧") }
        if flagsRaw & CGEventFlags.maskCommand.rawValue   != 0 { pieces.append("⌘") }
        pieces.append(keyName(for: keycode))
        return pieces.joined()
    }

    private func keyName(for keycode: UInt16) -> String {
        // Handful of common ANSI mappings; unknown keycodes fall
        // through as "key<N>" so nothing crashes for exotic bindings.
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"
        ]
        return map[keycode] ?? "key\(keycode)"
    }

    // MARK: - Hands-free mode (VAD-driven, no PTT)

    private var skiModeHandsFreeGroup: some View {
        settingsGroup("Hands-free mode (VAD)") {
            Toggle(isOn: $prefHandsFreeMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable hands-free mode")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Text("Keep the mic open and auto-segment speech with Silero VAD instead of press-to-talk. Warning: mic is always active while SKI Mode is selected; false triggers on ambient talk / videos are possible.")
                        .font(appUIFont(size: subtextFontSize))
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: prefHandsFreeMode) { _, _ in
                SKIModeHandsFreeSession.shared.reconcile()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    rowIcon("timer").frame(width: 28)
                    Text("Silence hangover")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Spacer()
                    Stepper(value: $prefVadSilenceMs, in: 200...5000, step: 100) {
                        Text("\(prefVadSilenceMs) ms")
                            .font(.system(size: max(11, subtextFontSize), design: .monospaced))
                    }
                    .labelsHidden()
                }
                Text("How long the mic must be quiet before hands-free mode ends the utterance. SKI default is 2000 ms.")
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    rowIcon("waveform.badge.magnifyingglass").frame(width: 28)
                    Text("End turns on intonation")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Spacer()
                    Toggle("", isOn: $prefSmartTurnEnabled)
                        .labelsHidden()
                        .disabled(!OpenClickySmartTurnDetector.isModelAvailable)
                }
                Text(OpenClickySmartTurnDetector.isModelAvailable
                     ? "Listens to how a sentence ends instead of just how long the mic has been quiet, so a finished sentence stops about 1.7 s sooner. Only ever ends a turn early — a pause mid-sentence still waits out the hangover above (measured: 0/6 premature cuts)."
                     : "Needs smart-turn-v3.2-cpu.onnx (8 MB) in ~/models/smart-turn/. Without it, the hangover above decides on its own.")
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    rowIcon("waveform").frame(width: 28)
                    Text("Speech threshold")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Spacer()
                    Slider(value: $prefVadThreshold, in: 0.1...0.9, step: 0.05)
                        .frame(width: 160)
                    Text(String(format: "%.2f", prefVadThreshold))
                        .font(.system(size: max(11, subtextFontSize), design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Higher = requires louder / clearer speech to trigger. Raise if you get false triggers on room noise.")
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - SKI Preferences (bubble_fade_ms / show_preview / notch_history_turns)

    @AppStorage("openclicky.ski.bubbleFadeMs")      private var prefBubbleFadeMs: Int = 3000
    @AppStorage("openclicky.ski.showPreview")       private var prefShowPreview: Bool = true
    @AppStorage("openclicky.ski.tapToDismiss")      private var prefTapToDismiss: Bool = true
    @AppStorage("openclicky.ski.approveBeforeSend") private var prefApproveBeforeSend: Bool = false
    @AppStorage("openclicky.ski.notchHistoryTurns") private var prefNotchHistoryTurns: Int = 20
    @AppStorage("openclicky.ski.preferredVoice")    private var prefPreferredVoice: String = ""
    @AppStorage("openclicky.ski.handsFreeMode")     private var prefHandsFreeMode: Bool = false
    @AppStorage("openclicky.ski.vadSilenceMs")      private var prefVadSilenceMs: Int = 2000
    @AppStorage("openclicky.ski.vadThreshold")      private var prefVadThreshold: Double = 0.5
    @AppStorage("openclicky.ski.smartTurnEnabled")  private var prefSmartTurnEnabled: Bool = false

    private var skiModePreferencesGroup: some View {
        settingsGroup("SKI Mode preferences") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    rowIcon("timer").frame(width: 28)
                    Text("Bubble auto-fade")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Spacer()
                    Stepper(value: $prefBubbleFadeMs, in: 500...15000, step: 500) {
                        Text("\(prefBubbleFadeMs) ms")
                            .font(.system(size: max(11, subtextFontSize), design: .monospaced))
                    }
                    .labelsHidden()
                }
                Text("How long the reply bubble stays on-screen before fading. Matches SKI `bubble_fade_ms`.")
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Toggle(isOn: $prefShowPreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show live preview while listening")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Text("Streams partial transcript into the notch as you speak. Matches SKI `show_preview`.")
                        .font(appUIFont(size: subtextFontSize))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Toggle(isOn: $prefTapToDismiss) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tap bubble to dismiss")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Text("Click the reply bubble to hide it immediately. Matches SKI `tap_to_dismiss`.")
                        .font(appUIFont(size: subtextFontSize))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Toggle(isOn: $prefApproveBeforeSend) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approve transcript before sending")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Text("Show the transcript inline first; you press Enter to send it to the CLI agent. Matches SKI `approve_before_send`.")
                        .font(appUIFont(size: subtextFontSize))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    rowIcon("list.bullet.rectangle").frame(width: 28)
                    Text("Notch history turns")
                        .font(appUIFont(size: bodyFontSize, weight: .medium))
                    Spacer()
                    Stepper(value: $prefNotchHistoryTurns, in: 5...200, step: 5) {
                        Text("\(prefNotchHistoryTurns)")
                            .font(.system(size: max(11, subtextFontSize), design: .monospaced))
                    }
                    .labelsHidden()
                }
                Text("Max turns kept per session in the SKI conversation bubble. Matches SKI `notch_history_turns`.")
                    .font(appUIFont(size: subtextFontSize))
                    .foregroundColor(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Whisper local

    private var whisperLocalGroup: some View {
        settingsGroup("Whisper local install") {
            whisperLocalStatusRow

            LazyVGrid(columns: settingsOptionColumns(2), spacing: 8) {
                ForEach(WhisperLocalModelVariant.allCases) { variant in
                    optionButton(
                        title: variant.label,
                        subtitle: whisperLocalSubtitle(for: variant),
                        isSelected: whisperLocalModelManager.selectedVariant == variant,
                        action: {
                            whisperLocalModelManager.setSelectedVariant(variant)
                            if buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.whisperLocal.rawValue,
                               !whisperLocalModelManager.state(for: variant).isReady {
                                companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.appleSpeech.rawValue)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 10)

            whisperLocalActionRow

            if let error = whisperLocalModelManager.lastErrorMessage,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                valueRow(
                    title: "Whisper model",
                    subtitle: error,
                    systemImageName: "exclamationmark.triangle"
                )
            }
        }
    }

    private var whisperLocalStatusRow: some View {
        let variant = whisperLocalModelManager.selectedVariant
        let state = whisperLocalModelManager.state(for: variant)
        let route: String = {
            if buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.whisperLocal.rawValue {
                return "Selected for local listening."
            }
            return state.isReady
                ? "Whisper is ready if you want to switch local listening to it."
                : "Download a Whisper model before selecting it."
        }()
        return valueRow(
            title: "Whisper local STT",
            subtitle: "\(variant.label): \(state.label). \(route)",
            systemImageName: state.isReady ? "checkmark.circle" : "waveform"
        )
    }

    private func whisperLocalSubtitle(for variant: WhisperLocalModelVariant) -> String {
        "\(variant.subtitle) - \(whisperLocalModelManager.state(for: variant).label)"
    }

    @ViewBuilder
    private var whisperLocalActionRow: some View {
        let variant = whisperLocalModelManager.selectedVariant
        switch whisperLocalModelManager.state(for: variant) {
        case .downloading(let fraction):
            actionRow(
                title: "Cancel Whisper download (\(Int(fraction * 100))%)",
                systemImageName: "xmark.circle"
            ) {
                whisperLocalModelManager.cancelDownload(variant)
            }
        case .ready:
            actionRow(
                title: "Use Whisper (local) for listening",
                systemImageName: "waveform.badge.mic"
            ) {
                companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.whisperLocal.rawValue)
            }
        case .notDownloaded, .failed:
            let sizeLabel = ByteCountFormatter.string(fromByteCount: variant.estimatedBytes, countStyle: .file)
            actionRow(
                title: "Download \(variant.label) (\(sizeLabel))",
                systemImageName: "arrow.down.circle"
            ) {
                whisperLocalModelManager.downloadSelected()
            }
        }
    }

    // MARK: - Voice skill install

    private var voiceSkillInstallGroup: some View {
        settingsGroup("OpenClicky voice skill") {
            Text("Install the openclicky-voice skill into each CLI agent you use. In SKI Mode, OpenClicky writes your speech to `.oc/events.jsonl` in the active project and the CLI agent replies through `.oc/commands.jsonl`. Nothing is written to a CLI agent's home directory without your explicit click.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(detectedVoiceSkillAgents) { agent in
                voiceSkillAgentRow(agent)
            }

            actionRow(title: "Re-detect installed agents", systemImageName: "arrow.clockwise.circle") {
                detectedVoiceSkillAgents = OpenClickyVoiceSkillInstaller.detectAgents()
            }
        }
    }

    @ViewBuilder
    private func voiceSkillAgentRow(_ agent: OpenClickyDetectedAgent) -> some View {
        let systemImage: String = {
            if agent.lastError != nil { return "exclamationmark.triangle.fill" }
            if agent.isInstalled { return "checkmark.circle.fill" }
            if agent.isPresent { return "circle.dashed" }
            return "questionmark.circle"
        }()
        let iconColor: Color = {
            if agent.lastError != nil { return .orange }
            if agent.isInstalled { return .green }
            if agent.isPresent { return .primary }
            return .secondary
        }()
        let subtitle: String = {
            if let err = agent.lastError { return "Error: \(err)" }
            if agent.isInstalled { return "Installed at \(agent.skillTargetDirectory.path)" }
            if agent.isPresent { return "Detected. Not installed." }
            return "Not detected on this Mac."
        }()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(agent.label)).font(.body)
                Text(LocalizedStringKey(subtitle)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if agent.isPresent {
                Button(agent.isInstalled ? "Remove" : "Install") {
                    let updated = agent.isInstalled
                        ? OpenClickyVoiceSkillInstaller.uninstall(agent)
                        : OpenClickyVoiceSkillInstaller.install(agent)
                    if let idx = detectedVoiceSkillAgents.firstIndex(where: { $0.id == agent.id }) {
                        detectedVoiceSkillAgents[idx] = updated
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - SKI Mode workspaces (connected agents + active pick)

    private var skiModeWorkspacesGroup: some View {
        settingsGroup("SKI Mode workspaces") {
            Text("Live view of CLI agents that have connected to OpenClicky's local socket (~/.openclicky/agents.sock). The active workspace is the one that receives your voice; utterances follow the focused window when \"Auto\" is on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            skiModeAutoRow

            if agentsPresence.connected.isEmpty {
                valueRow(
                    title: "No connected agents",
                    subtitle: "Start your CLI agent inside a project (e.g. `claude` in a git repo). Once the openclicky-voice skill's heartbeat connects, the project will appear here.",
                    systemImageName: "circle.dashed"
                )
            } else {
                ForEach(agentsPresence.connected) { presence in
                    skiModeWorkspaceRow(presence)
                }
            }
        }
    }

    @ViewBuilder
    private var skiModeAutoRow: some View {
        let isAuto = agentsPresence.pinnedActiveProjectRoot == nil
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isAuto ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isAuto ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto — follow the focused window").font(.body)
                if isAuto,
                   let auto = OpenClickyWorkspaceResolver.resolveActiveWorkspace() {
                    Text("Currently: \(auto.path)").font(.footnote).foregroundStyle(.secondary)
                } else if isAuto {
                    Text("No git project detected from the focused window").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isAuto {
                Button("Use Auto") {
                    agentsPresence.setPinnedActiveProject(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func skiModeWorkspaceRow(_ presence: OpenClickyAgentPresence) -> some View {
        let isActive = agentsPresence.pinnedActiveProjectRoot == presence.projectRoot
        let dirName = (presence.projectRoot as NSString).lastPathComponent
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(dirName.isEmpty ? presence.projectRoot : dirName).font(.body)
                Text(presence.projectRoot).font(.footnote).foregroundStyle(.secondary)
                Text("pid \(presence.pid) - connected \(shortRelative(presence.connectedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Button("Active") {
                    agentsPresence.setPinnedActiveProject(nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Pick") {
                    agentsPresence.setPinnedActiveProject(presence.projectRoot)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func shortRelative(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs/60)m ago" }
        return "\(secs/3600)h ago"
    }

    // MARK: - Shared UI helpers (copied from AdvancedProvidersPanelView)

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func settingsOptionColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                rowIcon(systemImageName)
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionButton(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(subtitle))
                        .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AdvancedProvidersPanelView
//
// Isolated from OpenClickySettingsView so it does not rebuild every
// time CompanionManager publishes (e.g. 30 Hz audio power). The
// companionManager reference is a plain `let`, not @ObservedObject,
// so reads do not tie this subtree to the parent's publisher. Reactive
// pieces (session, buddyDictationManager) are explicit @ObservedObject.
// Any @AppStorage bindings read UserDefaults, which does not tie the
// subtree to the parent view either.
private struct AdvancedProvidersPanelView: View {
    let companionManager: CompanionManager
    @ObservedObject var session: CodexAgentSession
    @ObservedObject var buddyDictationManager: BuddyDictationManager
    @StateObject private var localSpeechModelManager = OpenClickyLocalSpeechModelManager.shared
    @StateObject private var whisperLocalModelManager = WhisperLocalModelManager.shared
    @StateObject private var agentsPresence = OpenClickyAgentsPresenceStore.shared
    @State private var detectedVoiceSkillAgents: [OpenClickyDetectedAgent] = OpenClickyVoiceSkillInstaller.detectAgents()
    @StateObject private var heyClickyPlan = HeyClickyPlanClient.shared

    @Binding var userCodexAgentAPIKey: String
    @Binding var userAnthropicAPIKey: String
    @Binding var userAssemblyAIAPIKey: String
    @Binding var userDeepgramAPIKey: String
    @Binding var userElevenLabsAPIKey: String
    @Binding var userCartesiaAPIKey: String
    @Binding var codexAgentBaseURL: String
    @Binding var codexConfigSyncMessage: String
    @Binding var heyClickyRefreshTick: Int

    @AppStorage("selectedVoiceResponseModel") private var selectedVoiceResponseModelID: String = OpenClickyModelCatalog.defaultVoiceResponseModelID
    @AppStorage(AppBundleConfiguration.userTTSProviderDefaultsKey) private var ttsProviderRaw: String = "openai_realtime"
    @AppStorage(AgentParkingPosition.userDefaultsKey) private var agentParkingPositionRaw: String = AgentParkingPosition.topRight.rawValue

    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @AppStorage(AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) private var userCartesiaVoiceID = ""
    @AppStorage(AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey) private var userOpenAIRealtimeVoiceID = ""
    @AppStorage(AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey) private var userMicrosoftEdgeVoiceID = "en-US-EmmaMultilingualNeural"
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey) private var userDeepgramVoiceAgentThinkModel = "gpt-4o-mini"

    @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
    @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
    @AppStorage(AppBundleConfiguration.userAppBoldTextDefaultsKey) private var appBoldTextEnabled = false

    @State private var heyClickyAdvancedExpanded: Bool = false
    @State private var heyClickyStatusMessage: String = ""
    @State private var heyClickyApplyConfirming: Bool = false
    @State private var heyClickyPreProfileSnapshot: [String: String?]? = nil

    private static let openAIRealtimeVoiceIDs = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse"
    ]

    private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
    private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

    private var appFont: OpenClickyResponseCaptionFont {
        OpenClickyResponseCaptionFont.resolved(appFontRawValue)
    }

    private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        appFont.swiftUIFont(size: size, weight: appResolvedWeight(weight))
    }

    private func appResolvedWeight(_ weight: Font.Weight) -> Font.Weight {
        if appBoldTextEnabled {
            switch weight {
            case .light, .regular: return .medium
            case .medium: return .semibold
            case .semibold: return .bold
            case .bold, .heavy, .black: return .black
            default: return weight
            }
        } else {
            switch weight {
            case .black, .heavy: return .semibold
            case .bold: return .medium
            case .semibold: return .medium
            case .medium: return .regular
            case .regular: return .regular
            default: return weight
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            advancedVoiceProviderPanel

            settingsGroup("OpenAI and Claude") {
                secureFieldRow(
                    title: "Codex/OpenAI API key",
                    subtitle: "Used for Agent Mode overrides and GPT Realtime voice when a key is needed.",
                    systemImageName: "key",
                    placeholder: "OpenAI key",
                    text: Binding(
                        get: { userCodexAgentAPIKey },
                        set: { userCodexAgentAPIKey = $0; companionManager.setCodexAgentAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Anthropic API key",
                    subtitle: "Optional key for Claude voice and pointing providers.",
                    systemImageName: "key",
                    placeholder: "Anthropic key",
                    text: Binding(
                        get: { userAnthropicAPIKey },
                        set: { userAnthropicAPIKey = $0; companionManager.setAnthropicAPIKey($0) }
                    )
                )
            }

            settingsGroup("Hosted endpoints") {
                valueRow(
                    title: "Agent Mode provider",
                    subtitle: codexAgentEndpointSummary,
                    systemImageName: "network"
                )

                textFieldRow(
                    title: "OpenAI-compatible base URL",
                    subtitle: "Optional endpoint for Agent Mode and Codex-compatible hosted or local servers. Leave empty for OpenAI/ChatGPT auth.",
                    systemImageName: "link",
                    placeholder: "https://api.openai.com/v1 or http://127.0.0.1:8000",
                    text: Binding(
                        get: { codexAgentBaseURL },
                        set: { codexAgentBaseURL = $0 }
                    )
                )

                actionRow(title: "Sync Agent Mode provider config", systemImageName: "arrow.clockwise") {
                    syncCodexProviderSettings()
                }

                valueRow(
                    title: "Config sync",
                    subtitle: codexConfigSyncMessage,
                    systemImageName: "doc.text"
                )
            }

            detailedLocalListeningGroup

            settingsGroup("Listening providers") {
                secureFieldRow(
                    title: "AssemblyAI listening key",
                    subtitle: "Used by the AssemblyAI streaming transcription provider.",
                    systemImageName: "key",
                    placeholder: "AssemblyAI key",
                    text: Binding(
                        get: { userAssemblyAIAPIKey },
                        set: { userAssemblyAIAPIKey = $0; companionManager.setAssemblyAIAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Deepgram listening key",
                    subtitle: "Used by Deepgram streaming transcription, Aura TTS, and Deepgram Voice Agent.",
                    systemImageName: "key",
                    placeholder: "Deepgram key",
                    text: Binding(
                        get: { userDeepgramAPIKey },
                        set: { userDeepgramAPIKey = $0; companionManager.setDeepgramAPIKey($0) }
                    )
                )
            }

            settingsGroup("Playback providers") {
                secureFieldRow(
                    title: "ElevenLabs API key",
                    subtitle: "Used for spoken OpenClicky replies when ElevenLabs is selected.",
                    systemImageName: "key",
                    placeholder: "ElevenLabs key",
                    text: Binding(
                        get: { userElevenLabsAPIKey },
                        set: { userElevenLabsAPIKey = $0; companionManager.setElevenLabsAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Cartesia API key",
                    subtitle: "Used for spoken OpenClicky replies when Cartesia is selected.",
                    systemImageName: "key",
                    placeholder: "Cartesia key",
                    text: Binding(
                        get: { userCartesiaAPIKey },
                        set: { userCartesiaAPIKey = $0; companionManager.setCartesiaAPIKey($0) }
                    )
                )
            }

            settingsGroup("Agent Mode model") {
                modelOptionGrid(
                    options: OpenClickyModelCatalog.codexActionsModels,
                    selectedModelID: session.model,
                    select: { session.setModel($0) }
                )

                textFieldRow(
                    title: "Working directory",
                    subtitle: "Default folder used by new agent turns.",
                    systemImageName: "folder",
                    placeholder: FileManager.default.homeDirectoryForCurrentUser.path,
                    text: Binding(
                        get: { session.workingDirectoryPath },
                        set: { newValue in
                            session.workingDirectoryPath = newValue
                            UserDefaults.standard.set(newValue, forKey: "clickyCodexWorkingDirectory")
                        }
                    ),
                    openPath: { session.workingDirectoryPath }
                )
            }

            settingsGroup("Agent dock position") {
                AgentParkingPositionPicker(
                    selection: Binding(
                        get: { AgentParkingPosition(rawValue: agentParkingPositionRaw) ?? .topRight },
                        set: { companionManager.setAgentParkingPosition($0) }
                    ),
                    calibrationChanged: { position, offset in
                        companionManager.setAgentParkingCalibrationOffset(offset, for: position)
                    }
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }

            settingsGroup("Agent tools") {
                actionRow(title: "Warm up Agent Mode", systemImageName: "bolt") {
                    companionManager.warmUpCodexAgentMode()
                }
            }

            if OpenClickyProfileCatalog.activeProfile().id == "heyclicky_free" {
                heyClickyFreeGroup
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
        ) { _ in
            // Tick heyClickyRefreshTick on any UserDefaults change so the
            // profile-gated groups re-evaluate their branch when the
            // user switches profiles from the Basic tab picker.
            heyClickyRefreshTick &+= 1
        }
    }

    // MARK: - Advanced voice provider panel

    private var advancedVoiceProviderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceRouteOverview

            settingsGroup("Response voice model") {
                Text("Pick Realtime when one model should listen and speak live, or use a normal model when OpenClicky should think first and hand the reply to a playback engine.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                modelOptionGrid(
                    options: OpenClickyModelCatalog.responseVoiceModels,
                    selectedModelID: selectedVoiceResponseModelID,
                    columns: 3,
                    select: { companionManager.setSelectedModel($0) }
                )

                if OpenClickyModelCatalog.voiceResponseModel(withID: selectedVoiceResponseModelID).provider == .openAI,
                   OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID) {
                    openAIRealtimeVoicePicker
                }
                if OpenClickyModelCatalog.voiceResponseModel(withID: selectedVoiceResponseModelID).provider == .heyclickyFree {
                    Text("Speak plays through GPT Realtime using your HeyClicky Free session. Pick a voice below.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    openAIRealtimeVoicePicker
                }

                if OpenClickyModelCatalog.voiceResponseModel(withID: selectedVoiceResponseModelID).provider == .deepgram {
                    Text("Deepgram Voice Agent uses one WebSocket for listening, thinking, and speaking; it reuses the Deepgram key configured in Advanced Providers.")
                        .font(appUIFont(size: subtextFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    textFieldRow(
                        title: "Deepgram voice",
                        subtitle: "Aura model identifier for the speak stage.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                    textFieldRow(
                        title: "Deepgram think model",
                        subtitle: "LLM model Deepgram should use inside the Voice Agent.",
                        systemImageName: "brain.head.profile",
                        placeholder: "gpt-4o-mini",
                        text: Binding(
                            get: { userDeepgramVoiceAgentThinkModel },
                            set: { userDeepgramVoiceAgentThinkModel = $0; companionManager.setDeepgramVoiceAgentThinkModel($0) }
                        )
                    )
                }
            }

            settingsGroup("Transcription provider") {
                if OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID) {
                    valueRow(
                        title: "Current input path",
                        subtitle: "GPT Realtime is selected, so OpenClicky streams microphone audio directly to Realtime instead of using Whisper or another speech-to-text provider.",
                        systemImageName: "waveform.badge.mic"
                    )
                }

                valueRow(
                    title: "Current provider",
                    subtitle: OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID)
                        ? "Bypassed while GPT Realtime is the response voice model"
                        : buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "waveform"
                )

                if let transcriptionError = buddyDictationManager.lastErrorMessage,
                   !transcriptionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Transcription error",
                        subtitle: transcriptionError
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BuddyTranscriptionProviderFactory.providerIDsForSelectionGrid()) { provider in
                        optionButton(
                            title: provider.label,
                            subtitle: provider.subtitle,
                            isSelected: buddyDictationManager.transcriptionProviderID == provider.rawValue,
                            action: { companionManager.setVoiceTranscriptionProvider(provider.rawValue) }
                        )
                    }
                }
            }

            settingsGroup("Playback") {
                Text(OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID)
                    ? "GPT Realtime is selected as the response voice model, so it owns playback for voice replies."
                    : "Choose the separate TTS provider used when a normal text model generates OpenClicky's reply.")
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID) {
                    Picker("Playback engine", selection: Binding(
                        get: { OpenClickyTTSProvider(rawValue: ttsProviderRaw) ?? .openAIRealtime },
                        set: { companionManager.setTTSProvider($0) }
                    )) {
                        ForEach(OpenClickyTTSProvider.allCases.filter { $0 != .openAIRealtime }) { provider in
                            Text(LocalizedStringKey(provider.displayName)).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)
                }

                switch OpenClickyTTSProvider(rawValue: ttsProviderRaw) ?? .openAIRealtime {
                case .openAIRealtime:
                    EmptyView()
                case .elevenLabs:
                    textFieldRow(
                        title: "ElevenLabs voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userElevenLabsVoiceID },
                            set: { userElevenLabsVoiceID = $0; companionManager.setElevenLabsVoiceID($0) }
                        )
                    )
                case .cartesia:
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional custom voice override.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userCartesiaVoiceID },
                            set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                case .deepgram:
                    Text("Deepgram TTS reuses the Deepgram API key configured in Advanced Providers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    textFieldRow(
                        title: "Deepgram TTS voice",
                        subtitle: "Aura model identifier - e.g. aura-2-thalia-en, aura-2-orion-en, aura-2-luna-en.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                case .microsoftEdge:
                    Text("Microsoft Edge voices are the free online Read Aloud voices and do not need an API key.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(MicrosoftEdgeVoiceOption.recommended) { voice in
                            optionButton(
                                title: voice.label,
                                subtitle: voice.subtitle,
                                isSelected: AppBundleConfiguration.microsoftEdgeVoiceID() == voice.id,
                                action: {
                                    userMicrosoftEdgeVoiceID = voice.id
                                    companionManager.setMicrosoftEdgeVoiceID(voice.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)

                    textFieldRow(
                        title: "Microsoft Edge voice ID",
                        subtitle: "Optional override for any Edge voice, e.g. en-US-AriaNeural.",
                        systemImageName: "person.wave.2",
                        placeholder: "en-US-EmmaMultilingualNeural",
                        text: Binding(
                            get: { userMicrosoftEdgeVoiceID },
                            set: { userMicrosoftEdgeVoiceID = $0; companionManager.setMicrosoftEdgeVoiceID($0) }
                        )
                    )
                case .mirageCartesia:
                    Text("Peeky Free TTS uses free-tier Cartesia through the aegis-proxy. No API key required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    textFieldRow(
                        title: "Cartesia voice ID",
                        subtitle: "Optional override; defaults to the shipped Peeky Free voice.",
                        systemImageName: "person.wave.2",
                        placeholder: "Voice ID",
                        text: Binding(
                            get: { userCartesiaVoiceID },
                            set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Voice route helpers

    private var voiceRouteOverview: some View {
        settingsGroup("Voice route") {
            LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                voiceRouteStep(title: "Listen", value: listenLaneLabel, systemImageName: "mic")
                voiceRouteStep(title: "Think", value: thinkLaneLabel, systemImageName: "brain.head.profile")
                voiceRouteStep(title: "Speak", value: speakLaneLabel, systemImageName: "speaker.wave.2")
            }
            .padding(14)
        }
    }

    private var isHeyClickyFreeLane: Bool {
        OpenClickyModelCatalog.voiceResponseModel(withID: selectedVoiceResponseModelID).provider == .heyclickyFree
    }

    private var listenLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID)
            ? "Realtime audio"
            : buddyDictationManager.transcriptionProviderDisplayName
    }

    private var thinkLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return selectedResponseVoiceModelLabel
    }

    private var speakLaneLabel: String {
        if isHeyClickyFreeLane { return "HeyClicky Free" }
        return OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModelID)
            ? "Realtime voice"
            : (OpenClickyTTSProvider(rawValue: ttsProviderRaw) ?? .openAIRealtime).displayName
    }

    private var selectedResponseVoiceModelLabel: String {
        OpenClickyModelCatalog.responseVoiceModels.first { $0.id == selectedVoiceResponseModelID }?.label
            ?? selectedVoiceResponseModelID
    }

    private func voiceRouteStep(title: String, value: String, systemImageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.6)
            }

            Text(LocalizedStringKey(value))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Realtime voice picker

    private var openAIRealtimeVoiceSelection: Binding<String> {
        Binding(
            get: {
                userOpenAIRealtimeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "cedar"
                    : userOpenAIRealtimeVoiceID
            },
            set: {
                userOpenAIRealtimeVoiceID = $0
                companionManager.setOpenAIRealtimeVoiceID($0)
            }
        )
    }

    private var openAIRealtimeVoicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Realtime voice", selection: openAIRealtimeVoiceSelection) {
                    ForEach(Self.openAIRealtimeVoiceIDs, id: \.self) { voiceID in
                        Text(Self.voiceDisplayName(voiceID)).tag(voiceID)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    Task { await companionManager.previewOpenAIRealtimeVoice(voiceID: openAIRealtimeVoiceSelection.wrappedValue) }
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .help("Preview this voice")
            }
            Text("marin / coral / shimmer / sage sound feminine. cedar / ash / echo / verse sound masculine.")
                .font(appUIFont(size: subtextFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Reply language", selection: responseLanguageSelection) {
                Text("Auto (follow user)").tag("auto")
                Text("简体中文 Chinese").tag("zh")
                Text("English").tag("en")
                Text("日本語 Japanese").tag("ja")
                Text("Español Spanish").tag("es")
                Text("Français French").tag("fr")
                Text("Deutsch German").tag("de")
            }
            .pickerStyle(.menu)
            Text("Forces the assistant to speak in the chosen language. Applied on the next voice turn.")
                .font(appUIFont(size: subtextFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private static func voiceDisplayName(_ voiceID: String) -> String {
        switch voiceID {
        case "marin": return "Marin (feminine)"
        case "coral": return "Coral (feminine)"
        case "shimmer": return "Shimmer (feminine)"
        case "sage": return "Sage (feminine)"
        case "cedar": return "Cedar (masculine)"
        case "ash": return "Ash (masculine)"
        case "echo": return "Echo (masculine)"
        case "verse": return "Verse (masculine)"
        case "ballad": return "Ballad"
        case "alloy": return "Alloy"
        default: return voiceID.capitalized
        }
    }

    private var responseLanguageSelection: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceResponseLanguageDefaultsKey) ?? "auto" },
            set: { UserDefaults.standard.set($0, forKey: AppBundleConfiguration.userVoiceResponseLanguageDefaultsKey) }
        )
    }

    // MARK: - Local listening

    private var localSpeechModelStatusRow: some View {
        let selectedVersion = localSpeechModelManager.selectedVersion
        let state = localSpeechModelManager.state(for: selectedVersion)
        let title = localSpeechModelManager.isAppleSilicon ? "Parakeet local STT" : "Parakeet local STT unavailable"
        let subtitle: String
        if localSpeechModelManager.isAppleSilicon {
            subtitle = "\(selectedVersion.label): \(state.label). \(localSpeechRouteDetail)"
        } else {
            subtitle = "Parakeet requires Apple Silicon. Use Apple Speech or a configured cloud STT provider on this Mac."
        }
        return valueRow(
            title: title,
            subtitle: subtitle,
            systemImageName: state.isReady ? "checkmark.circle" : "waveform"
        )
    }

    private var localSpeechRouteDetail: String {
        if buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.parakeet.rawValue {
            return "Selected for local listening."
        }
        if buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.automatic.rawValue {
            return localSpeechModelManager.isSelectedModelReady
                ? "Automatic can use Parakeet because the selected local model is ready."
                : "Automatic stays on configured cloud or Apple Speech until a local Parakeet model is ready."
        }
        return localSpeechModelManager.isSelectedModelReady
            ? "Parakeet is ready if you want to switch local listening to it."
            : "Download a Parakeet model in Advanced Providers before selecting it."
    }

    private func localSpeechModelSubtitle(for version: OpenClickyLocalSpeechModelVersion) -> String {
        "\(version.subtitle) - \(localSpeechModelManager.state(for: version).label)"
    }

    private var detailedLocalListeningGroup: some View {
        settingsGroup("Local listening installs") {
            localSpeechModelStatusRow

            if localSpeechModelManager.isAppleSilicon {
                LazyVGrid(columns: settingsOptionColumns(2), spacing: 8) {
                    ForEach(OpenClickyLocalSpeechModelVersion.allCases) { version in
                        optionButton(
                            title: version.label,
                            subtitle: localSpeechModelSubtitle(for: version),
                            isSelected: localSpeechModelManager.selectedVersion == version,
                            action: {
                                localSpeechModelManager.setSelectedVersion(version)
                                if buddyDictationManager.transcriptionProviderID == BuddyTranscriptionProviderID.parakeet.rawValue,
                                   !localSpeechModelManager.state(for: version).isReady {
                                    companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.appleSpeech.rawValue)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)

                localSpeechModelActionRow
            }
        }
    }

    @ViewBuilder
    private var localSpeechModelActionRow: some View {
        let selectedVersion = localSpeechModelManager.selectedVersion
        switch localSpeechModelManager.state(for: selectedVersion) {
        case .downloading:
            actionRow(title: "Cancel Parakeet download", systemImageName: "xmark.circle") {
                localSpeechModelManager.cancelDownload(selectedVersion)
            }
        case .ready:
            actionRow(title: "Use Parakeet for local listening input", systemImageName: "waveform.badge.mic") {
                companionManager.setVoiceTranscriptionProvider(BuddyTranscriptionProviderID.parakeet.rawValue)
            }
        case .notDownloaded, .failed:
            actionRow(title: "Download selected Parakeet model", systemImageName: "arrow.down.circle") {
                localSpeechModelManager.downloadSelectedModel()
            }
        }
    }

    // MARK: - HeyClicky Free

    private var heyClickySignedInState: Bool {
        _ = heyClickyRefreshTick
        return AppBundleConfiguration.heyClickySignedIn()
    }

    private var heyClickyFreeGroup: some View {
        _ = heyClickyRefreshTick
        return settingsGroup("HeyClicky Free") {
            Text("Free listening, voice responses, TTS, and Agent Mode through the HeyClicky proxy. One sign-in with Google covers everything, including multi-voice speech via GPT Realtime.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if !heyClickyStatusMessage.isEmpty {
                Text(heyClickyStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }

            if heyClickySignedInState {
                let signedInSubtitle: String = {
                    if let email = AppBundleConfiguration.heyClickySessionUserEmail(), !email.isEmpty {
                        return "Signed in as \(email)"
                    }
                    return "HeyClicky Free is ready."
                }()
                valueRow(
                    title: "Signed in",
                    subtitle: signedInSubtitle,
                    systemImageName: "checkmark.circle"
                )
                actionRow(title: "Use HeyClicky Free for everything", systemImageName: "wand.and.stars") {
                    heyClickyApplyConfirming = true
                }
                if heyClickyPreProfileSnapshot != nil {
                    actionRow(title: "Revert lane changes", systemImageName: "arrow.uturn.backward") {
                        revertHeyClickyProfileApplication()
                    }
                }
                actionRow(title: "Reset free quota now", systemImageName: "arrow.clockwise") {
                    _ = HeyClickyAccountResetManager.shared.attemptReset(reason: "manual")
                }
                actionRow(
                    title: "Add another account (assist agent pool)",
                    systemImageName: "person.badge.plus"
                ) {
                    try? HeyClickyOAuthHandler.shared.startSignIn(mode: .additive)
                }
                let currentEmail = AppBundleConfiguration.heyClickyReadKeychainSecret(
                    forKey: AppBundleConfiguration.heyClickySessionUserEmailDefaultsKey) ?? ""
                let extraAccounts = HeyClickyAccountSwitcher.loadAll()
                    .filter { $0.email != currentEmail }
                if !extraAccounts.isEmpty {
                    ForEach(extraAccounts, id: \.email) { acc in
                        HStack(spacing: 10) {
                            Image(systemName: acc.refreshExpired
                                  ? "exclamationmark.triangle"
                                  : "person.circle")
                                .foregroundColor(acc.refreshExpired ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(acc.email)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if acc.refreshExpired {
                                    Text("Refresh token likely expired - click Re-auth")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if acc.refreshExpired {
                                Button("Re-auth") {
                                    HeyClickyAccountSwitcher.reauthenticate(acc)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            } else {
                                Button("Make primary") {
                                    HeyClickyAccountSwitcher.applyAccount(acc)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.blue)
                                .font(.system(size: 12))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                actionRow(title: "Sign out", systemImageName: "arrow.right.square") {
                    AppBundleConfiguration.heyClickyWipeSession()
                    HeyClickySessionTokenClient.shared.invalidateAll()
                }
            } else {
                actionRow(title: "Sign in with Google", systemImageName: "person.badge.key") {
                    try? HeyClickyOAuthHandler.shared.startSignIn()
                }
            }

            DisclosureGroup(isExpanded: $heyClickyAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    textFieldRow(
                        title: "Proxy base URL",
                        subtitle: "Leave blank to use the default HeyClicky proxy.",
                        systemImageName: "link",
                        placeholder: "https://api.heyclicky.com",
                        text: Binding(
                            get: { UserDefaults.standard.string(forKey: AppBundleConfiguration.heyClickyProxyBaseURLDefaultsKey) ?? "" },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.heyClickyProxyBaseURLDefaultsKey)
                                } else {
                                    UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.heyClickyProxyBaseURLDefaultsKey)
                                }
                            }
                        )
                    )
                    textFieldRow(
                        title: "OAuth authorize URL",
                        subtitle: "Leave blank to use the default authorize endpoint.",
                        systemImageName: "person.crop.circle",
                        placeholder: "https://api.heyclicky.com/auth/authorize",
                        text: Binding(
                            get: { UserDefaults.standard.string(forKey: AppBundleConfiguration.heyClickyOAuthAuthorizeURLDefaultsKey) ?? "" },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    UserDefaults.standard.removeObject(forKey: AppBundleConfiguration.heyClickyOAuthAuthorizeURLDefaultsKey)
                                } else {
                                    UserDefaults.standard.set(trimmed, forKey: AppBundleConfiguration.heyClickyOAuthAuthorizeURLDefaultsKey)
                                }
                            }
                        )
                    )
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced (self-hosted proxy)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Route STT, voice response, TTS, and Agent Mode through HeyClicky Free?",
            isPresented: $heyClickyApplyConfirming,
            titleVisibility: .visible
        ) {
            Button("Apply to all four lanes") {
                heyClickyPreProfileSnapshot = captureLaneSnapshot()
                applyHeyClickyFreeProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let p = OpenClickyProfileCatalog.heyclickyFree
            Text("""
            STT -> \(p.sttProvider)
            Voice response -> \(p.responseModelID)
            TTS -> \(p.ttsProvider)
            Agent -> \(p.agentModelID ?? "unchanged")

            You can revert this in one click afterwards.
            """)
        }
        .onReceive(NotificationCenter.default.publisher(for: .heyClickyCredentialsRefreshed)) { _ in
            heyClickyRefreshTick &+= 1
            heyClickyStatusMessage = ""
            Task { await HeyClickyPlanClient.shared.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .heyClickySessionExpired)) { _ in
            heyClickyRefreshTick &+= 1
            heyClickyStatusMessage = HeyClickyStatus.signInRequired.userMessage
        }
        .onReceive(NotificationCenter.default.publisher(for: .heyClickyStatusChanged)) { note in
            if let msg = note.userInfo?["message"] as? String {
                heyClickyStatusMessage = msg
            }
        }
    }

    private func applyHeyClickyFreeProfile() {
        let profile = OpenClickyProfileCatalog.heyclickyFree
        OpenClickyProfileCatalog.apply(profile)
        companionManager.setSelectedModel(profile.responseModelID)
    }

    private func captureLaneSnapshot() -> [String: String?] {
        let defaults = UserDefaults.standard
        return [
            AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey:
                defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey),
            OpenClickyProfileCatalog.voiceResponseModelDefaultsKey:
                defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey),
            AppBundleConfiguration.userTTSProviderDefaultsKey:
                defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey),
            "clickyCodexModel": defaults.string(forKey: "clickyCodexModel")
        ]
    }

    private func revertHeyClickyProfileApplication() {
        guard let snapshot = heyClickyPreProfileSnapshot else { return }
        let defaults = UserDefaults.standard
        for (key, value) in snapshot {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let restoredModel = snapshot[OpenClickyProfileCatalog.voiceResponseModelDefaultsKey] ?? nil {
            companionManager.setSelectedModel(restoredModel)
        }
        heyClickyPreProfileSnapshot = nil
    }

    // MARK: - Codex config helpers

    private var codexAgentEndpointSummary: String {
        let trimmed = codexAgentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Default OpenAI endpoint. Codex uses ChatGPT sign-in unless an OpenAI key is configured."
        }
        guard let url = ClickyCodexBackend.validatedWorkerBaseURL(trimmed) else {
            return "Enter a full http:// or https:// URL before syncing. Agent Mode keeps the previous valid provider config until then."
        }
        let endpoint = ClickyCodexConfigTemplate(workerBaseURL: url).openAICompatibleEndpoint.absoluteString
        return "Custom OpenAI-compatible endpoint to apply on sync: \(endpoint)"
    }

    private func commitCodexAgentBaseURLDraft() throws -> URL {
        let trimmed = codexAgentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "clickyAgentBaseURL")
            codexAgentBaseURL = ""
            return ClickyCodexBackend.defaultOpenAIBaseURL
        }

        guard let url = ClickyCodexBackend.validatedWorkerBaseURL(trimmed) else {
            throw OpenClickySettingsValidationError.invalidAgentBaseURL
        }

        let normalized = url.absoluteString
        UserDefaults.standard.set(normalized, forKey: "clickyAgentBaseURL")
        codexAgentBaseURL = normalized
        return url
    }

    private func applyCodexAgentBaseURLToSessions(_ url: URL) {
        companionManager.codexAgentSessions.forEach { $0.setWorkerBaseURL(url) }
    }

    private func syncCodexProviderSettings() {
        do {
            let workerBaseURL = try commitCodexAgentBaseURLDraft()
            applyCodexAgentBaseURLToSessions(workerBaseURL)
            let configFile = try session.syncProviderConfigurationFromCurrentSettings()
            let endpoint = ClickyCodexConfigTemplate(workerBaseURL: workerBaseURL).openAICompatibleEndpoint.absoluteString
            codexConfigSyncMessage = "Synced provider config to \(configFile.path). Agent Mode will use \(endpoint) on the next session start."
        } catch OpenClickySettingsValidationError.invalidAgentBaseURL {
            codexConfigSyncMessage = "Could not sync provider config: enter a full http:// or https:// URL with a host. Saved endpoint unchanged."
        } catch {
            codexConfigSyncMessage = "Could not sync provider config: \(error.localizedDescription)"
        }
    }

    // MARK: - Local UI helpers (copied from parent to avoid observing publisher)

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(appUIFont(size: bodyFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func settingsOptionColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(appUIFont(size: bodyFontSize + 1, weight: .medium))
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon("exclamationmark.triangle")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle))
                    .font(appUIFont(size: subtextFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle)).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func editableFieldRow<Field: View>(
        title: String,
        subtitle: String,
        systemImageName: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title)).font(appUIFont(size: bodyFontSize, weight: .medium))
                Text(LocalizedStringKey(subtitle)).font(appUIFont(size: subtextFontSize, weight: .regular)).foregroundColor(.secondary)
                field()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func textFieldRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        placeholder: String,
        text: Binding<String>,
        openPath: (() -> String)? = nil
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 8) {
                TextField(LocalizedStringKey(placeholder), text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
                if let openPath {
                    settingsPathOpenButton(openPath())
                }
            }
        }
    }

    private func secureFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            SecureField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .regular))
        }
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                rowIcon(systemImageName)
                Text(LocalizedStringKey(title))
                    .font(appUIFont(size: bodyFontSize, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelOptionGrid(
        options: [OpenClickyModelOption],
        selectedModelID: String,
        columns: Int = 2,
        select: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: settingsOptionColumns(columns), spacing: 8) {
            ForEach(options) { option in
                optionButton(
                    title: option.label,
                    subtitle: option.provider.displayName,
                    isSelected: selectedModelID == option.id,
                    action: { select(option.id) }
                )
            }
        }
        .padding(14)
    }

    private func optionButton(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(LocalizedStringKey(subtitle))
                        .font(appUIFont(size: max(9, subtextFontSize - 1), weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        Button {
            openSettingsPath(rawPath)
        } label: {
            Image(systemName: settingsPathOpenIconName(for: rawPath))
                .font(appUIFont(size: max(11, bodyFontSize - 1), weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "doc.richtext"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
            return "Open in OpenClicky Markdown viewer"
        }
        return "Open in TextEdit"
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")
        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

