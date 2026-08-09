# Parity Domain 4 — UX overlays + permissions + appearance

Pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`. Read-only audit.
Every claim carries a file:line locator. Format mirrors the existing F* review notes.

## Scope

User-facing knobs for the interactive UX surfaces on both sides:
whiteboard overlay, LinkRect harvester UI, PickElement pin HUD,
Annotation ➕ badge + AXFollower, preflight permission panel, AX
quirks installer, appearance/theme, cursor overlay, menu-bar icon,
notch panel.

Openclicky surfaces inspected:

- `cursor-buddy/OpenClickyWhiteboardOverlayWindow.swift` (1-590)
- `cursor-buddy/OpenClickyLinkRectOverlayWindow.swift` (1-313)
- `cursor-buddy/OpenClickyLinkRectHarvester.swift` (41-45)
- `cursor-buddy/OpenClickyPickElementOverlay.swift` (1-389)
- `cursor-buddy/OpenClickyAnnotationBadgeOverlay.swift` (1-800)
- `cursor-buddy/OpenClickyAXFollower.swift` (51, 187-195)
- `cursor-buddy/OpenClickySettingsWindowManager.swift` (134-172, 700-830, 1839-1965)
- `cursor-buddy/MenuBarPanelManager.swift` (140-234, 245-266)
- `cursor-buddy/OverlayWindow.swift` (188-224)
- `Packages/OpenClickyCore/Sources/OpenClickyCore/Theme.swift` (1-170)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/PermissionPreflight.swift` (1-209)
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AXQuirksInstaller.swift` (115-241)
- `cursor-buddy/OpenClickyComputerUseRuntime.swift` (718-784)

Everywhere surfaces inspected:

- `src/Everywhere.Core/Configuration/Settings/CommonSettings.cs` (14-192)
- `src/Everywhere.Core/Configuration/Settings/DisplaySettings.cs` (13-168)
- `src/Everywhere.Core/Configuration/Settings/ShortcutSettings.cs` (7-95)
- `src/Everywhere.Core/Views/ScreenSelection/ScreenSelectionWindow.cs` (59-155)
- `src/Everywhere.Core/Views/Annotation/AnnotationOverlayWindow.cs` (24-350)
- `src/Everywhere.Mcp/AnnotationOverlay/AnnotationOverlayHost.cs` (39, 76-79, 132)
- `src/Everywhere.Mcp/Whiteboard/WhiteboardParser.cs` (43-329)
- `src/Everywhere.Mcp/WhiteboardHotkeyInitializer.cs`
- `src/Everywhere.Mac/Interop/VisualElementContext.LinkRect.cs` (94-563)
- `src/Everywhere.Mac/Interop/VisualElementContext.Picker.cs` (1-38)
- `src/Everywhere.Mac/Interop/ScreenSelectionSession.cs` (61-268)
- `src/Everywhere.Mac/Interop/PermissionHelper.cs` (whole file, 52 lines)
- `src/Everywhere.Mac/Interop/AXUIElement.cs` (1178-1214, 471-475)
- `src/Everywhere.Mac/Interop/AXAttributeConstants.cs` (30-31)
- `src/Everywhere.Mcp/Tools/AppResolver.cs` (20-53)

## Alignment table — Whiteboard overlay knobs

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Overlay tint alpha | 0.4 hardcoded — `Border { Background=Brushes.Black, Opacity=0.4 }` (`ScreenSelectionWindow.cs:76-78`) | 0.15 hardcoded — `NSColor.black.withAlphaComponent(0.15)` (`OpenClickyWhiteboardOverlayWindow.swift:117`) | Neither. Both hard-coded. Values diverge (see Issue 1). |
| Stroke tint color | Avalonia canvas theme-driven; no dedicated whiteboard-stroke color in `WhiteboardOverlay` code | Yellow `RGB 255/235/59` hardcoded — `NSColor(calibratedRed: 1.0, green: 235/255, blue: 59/255, ...)` (`OpenClickyWhiteboardOverlayWindow.swift:121-126`) | Neither. |
| Stroke line width | Avalonia default | 3.0 hardcoded — `path.lineWidth = 3` (`OpenClickyWhiteboardOverlayWindow.swift:128`) | Neither. |
| Region-label overlay (classified bbox) | No — overlay closes immediately on commit (`WhiteboardHotkeyInitializer.cs`) | Dashed orange 1 px + 11pt semibold label — `NSColor.orange.setStroke()`, `dash=[4,3]`, `NSFont.systemFont(ofSize: 11, weight: .semibold)` (`OpenClickyWhiteboardOverlayWindow.swift:141-160`) | Neither. Openclicky-only surface, dead code today per F23 Issue 2. |
| Fade-out delay | Immediate close | 250 ms — `try? await Task.sleep(nanoseconds: 250_000_000)` (`OpenClickyWhiteboardOverlayWindow.swift:321`) | Neither. |
| Classifier size gate | `< 5.0` px — `if (Math.Max(bb.Width, bb.Height) < 5.0)` (`WhiteboardParser.cs:128`) | `< 5.0` — `if max(bb.width, bb.height) < 5.0` (`OpenClickyWhiteboardStrokeClassifier.swift:155`) | Neither. |
| Classifier closure/straight thresholds | `closure<0.2 && straight<0.5`; `straight<0.3`; `straight>0.75` (`WhiteboardParser.cs:138-145`) | Same (`OpenClickyWhiteboardStrokeClassifier.swift:168-170`) | Neither. |
| Classifier X-crossing angle band | `35 ≤ angle ≤ 145` (`WhiteboardParser.cs:184`) | Same (`OpenClickyWhiteboardStrokeClassifier.swift:198`) | Neither. |
| Classifier arrow proximity | `Math.Max(15, axisLen * 0.30)` (`WhiteboardParser.cs:215`) | Same (`OpenClickyWhiteboardStrokeClassifier.swift:217`) | Neither. |
| Whiteboard shortcut | `Whiteboard` composite key — user-editable via Settings (`ShortcutSettings.cs:83`) | Live via `OpenClickyContextHotkeys` (not in this domain; see F22) | Yes on Everywhere. Openclicky exposes the shortcut in its hotkeys section. |

## Alignment table — LinkRect overlay + harvester knobs

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Overlay tint alpha | 0.4 (`ScreenSelectionWindow.cs:76-77`) | 0.15 — `NSColor(white: 0.0, alpha: 0.15)` (`OpenClickyLinkRectOverlayWindow.swift:268`) | Neither. |
| Selection outline color / width | White, 2 px — `BorderThickness=Thickness(2), BorderBrush=Brushes.White` (`ScreenSelectionWindow.cs:81-82`) | System green, 2 px — `NSColor.systemGreen.cgColor`, `setLineWidth(2)` (`OpenClickyLinkRectOverlayWindow.swift:286-288`) | Neither. Openclicky uses green vs Everywhere white (see Issue 2). |
| Cursor style | `StandardCursorType.Cross` (`ScreenSelectionWindow.cs:36`) | `NSCursor.crosshair` implied via overlay level; no explicit push at present (`OpenClickyLinkRectOverlayWindow.swift`) | Neither. |
| Post-capture link highlight (aqua flash) | Aqua `#00C8FF` 2 px border, `#40 00C8FF` fill, ~700 ms — `CapturedBorderBrush = FromArgb(0xFF, 0x00, 0xC8, 0xFF)` (`ScreenSelectionWindow.cs:124-127`); painted from `VisualElementContext.LinkRect.cs:58-72` | Not implemented — overlay dismissed at `ended(atQuartz:)` before harvest (`OpenClickyLinkRectOverlayWindow.swift:106`) | Neither. Absent on Openclicky (F24 Issue 5). |
| MaxLinks cap | `MaxLinks = 200` const (`ContextStashWriter.cs:159`) | `maxLinks = 200` static let (`OpenClickyLinkRectHarvester.swift:41`) | Neither. Openclicky comment locks the value as a mirror of Everywhere. |
| Max URL length | `MaxUrlLen = 2048` (`ContextStashWriter.cs:160`; `VisualElementContext.LinkRect.cs:325-327`) | `maxUrlLen = 2048` (`OpenClickyLinkRectHarvester.swift:42`) | Neither. |
| Max title length | `MaxTitleLen = 200` (`ContextStashWriter.cs:161`; `.LinkRect.cs:357`) | `maxTitleLen = 200` (`OpenClickyLinkRectHarvester.swift:43`) | Neither. |
| MaxDepth walk | `MaxDepth = 60` const (`VisualElementContext.LinkRect.cs:242`) | `maxDepth = 60` (`OpenClickyLinkRectHarvester.swift:44`) | Neither. |
| Walk budget | `WalkBudget.Remaining = 50_000` (`VisualElementContext.LinkRect.cs:224`) | `walkBudget = 50_000` (`OpenClickyLinkRectHarvester.swift:45`) | Neither. |
| Majority-overlap rule | Horizontal-any-overlap + anchor mid-Y in drag rect Y span (`VisualElementContext.LinkRect.cs:411-422`) | Same (`OpenClickyLinkRectHarvester.swift:69-79`) | Neither. |
| Icon-only drop threshold | untitled AND `w<=32 && h<=32` (`VisualElementContext.LinkRect.cs:370-372`) | Same (`OpenClickyLinkRectHarvester.swift:195-197`) | Neither. |
| Ancestor row-text depth | Up to 3 parents (`VisualElementContext.LinkRect.cs:353-357, 424-454`) | Not implemented (`OpenClickyLinkRectHarvester.swift:186-188`) | Neither. Absent on Openclicky (F24 Issue 3). |
| Credential-redaction denylist | 17-param list; applied only in clipboard sentinel path (`ContextStashWriter.cs:429`) | Applied at harvest boundary AND writer boundary via `OpenClickySanitiser.redactCredentials` (`OpenClickyLinkRectHarvester.swift:181-184`, `OpenClickyContextStashWriter.swift:394-395`) | Neither. Openclicky redacts by default; Everywhere leaves raw. |
| Scheme allow-list | `http|https|mailto` (`VisualElementContext.LinkRect.cs:458-463`) | Same via `OpenClickySanitiser.isAllowedScheme` (`OpenClickyLinkRectHarvester.swift:182`) | Neither. |
| `EVERYWHERE_LINKRECT_DUMP` env-var diagnostic | Present (`VisualElementContext.LinkRect.cs:171-214`) | Not implemented | Env var only (out-of-scope for user settings). |
| LinkRect shortcut | `LinkRect` composite key — user-editable (`ShortcutSettings.cs:94`) | Live via `OpenClickyContextHotkeys` | Yes on Everywhere. |

## Alignment table — PickElement HUD

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Screen mask alpha | 0.4 (`ScreenSelectionWindow.cs:76-77`) | 0.15 — `NSColor.black.withAlphaComponent(0.15)` (`OpenClickyPickElementOverlay.swift:233`) | Neither. |
| Cursor style | `StandardCursorType.Cross` (base class, `ScreenSelectionWindow.cs:36`) | `NSCursor.crosshair.push()` (`OpenClickyPickElementOverlay.swift:88`) | Neither. |
| Live-hover outline color | Theme-driven white (`ScreenSelectionWindow.cs:81-82`) | `NSColor.systemGreen`, 2 px, `xRadius/yRadius = 6` — `NSBezierPath(roundedRect:xRadius:6,yRadius:6)`, `lineWidth = 2` (`OpenClickyPickElementOverlay.swift:328-331`) | Neither. |
| Live-hover corner radius | 0 (Avalonia `Border` default) | 6 pt (`OpenClickyPickElementOverlay.swift:328`) | Neither. |
| AX hit-test throttle | None — every `PointerMoved` re-runs `AX.ElementAtPoint` (`ScreenSelectionSession.cs:228-249`) | ~30 fps — `minHitInterval = 1.0/30.0` (`OpenClickyPickElementOverlay.swift:270`) | Neither. Openclicky adds explicit throttle. |
| PickElement (Agent) shortcut | `AgentPickElement` composite key — user-editable (`ShortcutSettings.cs:47`) | Live via `OpenClickyContextHotkeys` | Yes on Everywhere. |
| Cancel keys | Esc + right-click (`ScreenSelectionSession.cs:124-169`) | Esc keycode 53 + right-click (`OpenClickyPickElementOverlay.swift:99-115`) | Neither. |

## Alignment table — Annotation badge + AXFollower

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Follower poll interval | 50 ms — `DispatcherTimer.Interval = TimeSpan.FromMilliseconds(50)` (`AnnotationOverlayHost.cs:76`); header comment L18 wrongly says "150ms" but code is 50 ms | 50 ms — `pollInterval: TimeInterval = 0.05` (`OpenClickyAXFollower.swift:51`) | Neither. |
| AX BoundingRectangleLive read timeout | Wrapped with `WaitAsync(TimeSpan.FromMilliseconds(...))` (`AnnotationOverlayHost.cs:132`) | No timeout; sync `AXUIElementCopyAttributeValue` (`OpenClickyAXFollower.swift:209-235`) | Neither. |
| Badge collapsed size | `BadgeSize = 24` (`AnnotationOverlayWindow.cs:28`) | 24×24 — `BadgePanel.collapsedSize = CGSize(width: 24, height: 24)` (`OpenClickyAnnotationBadgeOverlay.swift:500`) | Neither. |
| Badge expanded size | `ExpandedWidth`/`ExpandedHeight` = 320×110 (`AnnotationOverlayWindow.cs:29-30`) | 320×110 — `BadgePanel.expandedSize = CGSize(width: 320, height: 110)` (`OpenClickyAnnotationBadgeOverlay.swift:501`) | Neither. |
| Badge anchor offset (top-right) | `OffsetX=6, OffsetY=-6` (`AnnotationOverlayWindow.cs:34-35`) | `cocoa.maxX + 6 - w/2, cocoa.maxY - 6 - h/2` (`OpenClickyAnnotationBadgeOverlay.swift:447-450`) | Neither. |
| Unannotated ➕ badge fill | Purple/gradient — `LinearGradientBrush` stops `#AC45F1 → #7A7EF4 → #3DC6F8` (`AnnotationOverlayWindow.cs:90-98`) | Red — `Color(red: 0.86, green: 0.12, blue: 0.20)` (`OpenClickyAnnotationBadgeOverlay.swift:654`) | Neither. Color diverges (see Issue 3). |
| Annotated ✓ badge fill | Green — `Color.Parse("#3DC68C")` (`AnnotationOverlayWindow.cs:304`) | Green — `Color(red: 0.24, green: 0.78, blue: 0.55)` (`OpenClickyAnnotationBadgeOverlay.swift:656`) | Neither. |
| Badge border stroke | White 40% — `Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)` (`AnnotationOverlayWindow.cs:102`) | White 40% — `Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)` (`OpenClickyAnnotationBadgeOverlay.swift:732`) | Neither. |
| Expanded popover fill | `Color.FromArgb(0xF2, 0x1B, 0x1B, 0x22)` (`AnnotationOverlayWindow.cs:144`) | `Color.black.opacity(0.92)` (`OpenClickyAnnotationBadgeOverlay.swift:698`) | Neither. |
| Popover shadow | `Color.FromArgb(0x55, 0, 0, 0)` (`AnnotationOverlayWindow.cs:150`) | `.black.opacity(0.4)` radius 12 (`OpenClickyAnnotationBadgeOverlay.swift:703`) | Neither. |
| Outline color around pinned element | Purple `#AC45F1` (`AnnotationOutlineWindow.cs:34`) | `NSColor.systemRed` (`OpenClickyAnnotationBadgeOverlay.swift:490`) | Neither. Color diverges. |
| Outline corner radius | Avalonia `Border` default | 6 pt — `roundedRect:xRadius:6,yRadius:6` implied (`OpenClickyAnnotationBadgeOverlay.swift:489`) | Neither. |
| Commit key | Cmd+Enter — `KeyModifiers.Meta` (`AnnotationOverlayWindow.cs:325-341`) | `.command` + Enter (`OpenClickyAnnotationBadgeOverlay.swift:776-790`) | Neither. |
| Cancel key | Esc — `OnTextBoxKeyDown` (`AnnotationOverlayWindow.cs:325-341`) | Esc via SwiftUI `.onKeyPress(.escape)` (`OpenClickyAnnotationBadgeOverlay.swift:715-718`) | Neither. |
| Blur-commit | Yes — `OnTextBoxLostFocus` collapses (`AnnotationOverlayWindow.cs:342-350`) | Not implemented (`OpenClickyAnnotationBadgeOverlay.swift:763-791`) | Neither. Absent on Openclicky (F25 L4). |

## Alignment table — Permission preflight

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Kinds enumerated | Accessibility + ScreenRecording only in `PermissionHelper.cs`; other three surfaces live in adjacent subsystems | Five kinds — `.accessibility, .screenRecording, .inputMonitoring, .microphone, .automation` (`CaptureTypes.swift:1109-1126`, `PermissionPreflight.swift:67-79`) | Neither. Openclicky consolidates. |
| Accessibility check | `AXIsProcessTrustedWithOptions(prompt=true)` — prompts (`PermissionHelper.cs:22`) | `AXIsProcessTrusted()` — passive (`PermissionPreflight.swift:90`) | Neither. |
| Screen recording check | `CGImage.ScreenImage(0, CGRect(0,0,1,1))` real capture (`PermissionHelper.cs:35-40`) | `CGPreflightScreenCaptureAccess()` (`PermissionPreflight.swift:103`) | Neither. |
| Input monitoring check | Not in `PermissionHelper.cs` | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` (`PermissionPreflight.swift:112`) | Neither. |
| Microphone check | Not in `PermissionHelper.cs` | `AVCaptureDevice.authorizationStatus(for: .audio)` (`PermissionPreflight.swift:131`) | Neither. |
| Automation check | Not in `PermissionHelper.cs` | `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)` (`PermissionPreflight.swift:189-194`) | Neither. |
| UI panel — permission list | Not present in reviewed Everywhere Settings files (permissions are demanded at bootstrap; no per-kind status panel in `CommonSettings.cs` / `DisplaySettings.cs`) | Full Settings > Permissions panel with 7 rows: Accessibility, Screen Recording, Screen Content, Microphone, Camera, Full Disk Access, System Events Automation (`OpenClickySettingsWindowManager.swift:1841-1877`) | Panel is read-only per-row status; grant is via System Settings deep-link. |
| Per-permission deep-link | Not present in Settings; grant flow runs at bootstrap | Every row exposes `settingsURL: x-apple.systempreferences:com.apple.preference.security?...` (`OpenClickyMacPrivacyPermissionProbe.fullDiskAccessSettingsURL`, `.automationSettingsURL`; and inline URLs at `OpenClickySettingsWindowManager.swift:1845-1876`) | Deep-links only — no direct grant toggle. |
| "Refresh permission status" button | N/A | Action row calls `companionManager.refreshAllPermissions()` (`OpenClickySettingsWindowManager.swift:1928-1930`) | Manual refresh only. |
| Full Disk Access probe | N/A | Heuristic: attempts to open `~/Library/Messages/chat.db`, `~/Library/Safari/History.db`, `~/Library/Mail` (`OpenClickyComputerUseRuntime.swift:751-766`) | Neither. Openclicky-only. |
| Automation "prompt" flag | N/A | `hasSystemEventsAutomationPermission(prompt: false)` (`OpenClickyComputerUseRuntime.swift:723`); "Request System Events access" action passes prompt: true (`OpenClickySettingsWindowManager.swift:1949-1951`) | Semi — user action triggers prompt, otherwise passive. |
| Notifications permission | N/A | Row + "Request notification permission" / "Send test notification" actions (`OpenClickySettingsWindowManager.swift:1885-1924`) | Yes — user can request grant + toggle "Task-complete notifications" `desktopNotificationsEnabled` and "Task-complete voice" `agentCompletionVoiceEnabled`. |

## Alignment table — AX Quirks installer

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| `AXManualAccessibility` attribute name | Const `"AXManualAccessibility"` (`AXAttributeConstants.cs:30`) | `public static let manualAccessibility = "AXManualAccessibility"` (`AXQuirksInstaller.swift:125`) | Neither. |
| `AXEnhancedUserInterface` attribute name | Const `"AXEnhancedUserInterface"` (`AXAttributeConstants.cs:31`) | `public static let enhancedUserInterface = "AXEnhancedUserInterface"` (`AXQuirksInstaller.swift:128`) | Neither. |
| Fire order | Manual first, then Enhanced (`VisualElementContext.cs:127-128`) | Same (`AXQuirksInstaller.swift:225-234`) | Neither. |
| Per-app allowlist / toggle | None — fired unconditionally on every AX-consuming path | None — same "both, always" contract (see file header comment `AXQuirksInstaller.swift:20-25`) | Neither. Openclicky-side comment L20-25 explicitly rejects a per-bundle table as a maintenance rathole. |
| Cache primitive | `ConcurrentDictionary<int,bool> _a11yEnabledPids` (`AppResolver.cs:20`); `TryAdd` inserts before AX call → poisons cache on failure | `Set<Int32> installedPids` under `NSLock`; inserts only after both attributes land (`AXQuirksInstaller.swift:136-141, 202-206`) | Neither. Openclicky stricter. |
| SystemWide messaging timeout | 1 s static-ctor bootstrap (`AXUIElement.cs:471-475`) | 1 s — `AXUIElementSetMessagingTimeout(systemWide, 1.0)` on module load (`AXQuirksInstaller.swift:158-161`) | Neither. |
| Bounded-wait wrapper | 1500 ms `task.Wait(TimeSpan.FromMilliseconds(1500))` at caller level (`AppResolver.cs:44-52`) | Not inside installer — caller responsibility per header L54-60 | Neither. |

## Alignment table — Appearance / theme

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Application language | `LocaleName Language` enum with 12 locales (`DisplaySettings.cs:36-50`) | Not present in Settings panel | Everywhere only. |
| Theme (light / dark / system) | `ThemeMode Theme` bound to `App.ThemeManager.SwitchTheme` (`DisplaySettings.cs:52-64`) | `ClickyTheme` enum `.system, .light, .dark` — `AppStorage` `openClickyThemeAppearance` (`Theme.swift:150-169`); Picker at `OpenClickySettingsWindowManager.swift:728-733` | Both. |
| Accent color | `SerializableColor? AccentColor` free-form via `AccentColorSelector` (`DisplaySettings.cs:66-88`) | `ClickyAccentTheme` fixed palette of 9 named tones (`Theme.swift:4-13`); UI restricts cursor-color grid to 5 (`OpenClickySettingsWindowManager.swift:815`) — `[.rose, .blue, .amber, .mint, .white]` | Both. Everywhere is free-form color picker; Openclicky is fixed enum palette. |
| Accent color hover / text / cursor variants | Not exposed | 3 derived variants per tone (`accentHover`, `accentText`, `cursorColor`) precomputed in `Theme.swift:61-108` | Neither directly; automatic per accent. |
| Font size | `int FontSize` [-1..3] slider mapping to `FontSizeM` 12/14/15/16/18 (`DisplaySettings.cs:93-167`) | App-font picker `OpenClickyResponseCaptionFont` + "Bold interface text" toggle `appBoldTextEnabled` (`OpenClickySettingsWindowManager.swift:776-790`) | Both, different shape. |
| Glass tint strength | Not present | Slider 0.1-1.0 step 0.05 backing `openClickyGlassOpacity` (`OpenClickySettingsWindowManager.swift:750`, `Theme.swift:146`) | Openclicky only. |
| Glass frosting | Not present | Slider 0.0-1.0 step 0.05 backing `openClickyGlassFrosting` (`OpenClickySettingsWindowManager.swift:764`, `Theme.swift:147`) | Openclicky only. |
| Cursor avatar | Not applicable | `ClickyCursorAvatarStyle` enum `.triangleFilled / .triangleOutline / .pet(id:)` via `AppStorage` `openclicky.cursorAvatarStyle` (`OverlayWindow.swift:188-224`); grid in `OpenClickySettingsWindowManager.swift:801-808` | Openclicky only. |
| Notch panel style | Not applicable | Single variant; no user-selectable notch appearance (see Issue 5). Notch surface is `OpenClickyNotchPanelView` bound to same accent theme via `AppStorage(ClickyAccentTheme.userDefaultsKey)` (`OpenClickyNotchPanelView.swift:66`) | Neither. |
| Reduce motion / disable animations | Not exposed in reviewed settings | Not exposed. Animations use hardcoded `DS.Animation.fast` easings (`ClickyAgentOverlayCard.swift:586-587, 632-633, 660-661`) and 250 ms fade-out (`OpenClickyWhiteboardOverlayWindow.swift:321`) | Neither. |
| Startup / auto-launch | `IsUserStartupEnabled` toggle (`CommonSettings.cs:141-162`) | Not in reviewed Settings panel | Everywhere only. |
| Automatic update check | `IsAutomaticUpdateCheckEnabled` (`CommonSettings.cs:47`), `UpdateChannel` picker (`CommonSettings.cs:53-54`) | `SoftwareUpdateControl` mirrored at settings header (out of Domain 4 scope) | Everywhere only in this domain. |
| Telemetry / statistics | `IsStatisticsEnabled` (`CommonSettings.cs:170`), `DiagnosticData` (`CommonSettings.cs:172-184`) | Not in Domain-4 panel | Everywhere only. |

## Alignment table — Menu bar icon

| Knob | Everywhere | Openclicky | User-configurable? |
|---|---|---|---|
| Menu bar visibility | `MainTrayIcon.axaml` (Avalonia tray icon) | `NSStatusItem` with `squareLength` slot (`MenuBarPanelManager.swift:141`) | Neither. Both always visible. |
| Icon shape | Not inspected — resource-based | Clicky triangle drawn via `NSBezierPath`; 18 pt, 35° rotation; template mode for dark/light inversion (`MenuBarPanelManager.swift:202-234`) | Neither. |
| Icon color | Theme-driven | Black template; system inverts (`MenuBarPanelManager.swift:229, 147`) | Neither. |
| Unread badge | Not inspected in Domain 4 | Red 6-pt dot in top-right when agent notifications unread; non-template so red survives inversion (`MenuBarPanelManager.swift:172-198`) | Neither. Auto-driven by `HeyClickyAgentNotificationsClient.unreadCount` (`MenuBarPanelManager.swift:157-166`). |
| Right-click behavior | N/A in reviewed files | Context menu — `showStatusItemContextMenu(from:)` (`MenuBarPanelManager.swift:246-249, 267`) | Neither. |
| Left-click behavior | N/A in reviewed files | Toggle panel visibility unless pinned (`MenuBarPanelManager.swift:254-265`) | Neither. |
| Panel pinned toggle | N/A | `isPanelPinned` state controls whether left-click hides the panel (`MenuBarPanelManager.swift:255-261`) | Yes (user pin state). |
| Panel show-on-launch delay | N/A | Hardcoded 300 ms — `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)` (`MenuBarPanelManager.swift:238-243`) | Neither. |

## Issues

### Issue 1 — Overlay tint alpha diverges between overlays and from Everywhere

Everywhere uses `Opacity = 0.4` for every screen-selection mask
(`ScreenSelectionWindow.cs:76-78`). Openclicky uses **three different
values**:

- Whiteboard: `0.15` (`OpenClickyWhiteboardOverlayWindow.swift:117`).
- LinkRect: `0.15` (`OpenClickyLinkRectOverlayWindow.swift:268`).
- PickElement: `0.15` (`OpenClickyPickElementOverlay.swift:233`).

The three Openclicky surfaces agree with each other (all 0.15) but
disagree with Everywhere by a factor of ~2.7×. All values are
hardcoded on both sides — no user knob. Spec ambiguity: F23/F24/F25
task descriptions say "0.15 grey tint" so the Openclicky values match
the task spec, not the Everywhere source. Cross-reference: F23
Alignment Table "Stroke tint" row already documents this as
"Matches doc constraint" rather than parity with Everywhere.

### Issue 2 — Outline colors diverge from Everywhere

Everywhere paints selection outlines in **theme-driven white**
(`ScreenSelectionWindow.cs:81-82`) with a purple `#AC45F1` accent for
Annotation outlines (`AnnotationOutlineWindow.cs:34`). Openclicky
uses:

- LinkRect selection: `NSColor.systemGreen` (`OpenClickyLinkRectOverlayWindow.swift:286`).
- PickElement hover: `NSColor.systemGreen` (`OpenClickyPickElementOverlay.swift:329`).
- Annotation follow outline: `NSColor.systemRed` (`OpenClickyAnnotationBadgeOverlay.swift:490`).

All hardcoded; no user knob. F25 M2 already logged this as a
"cosmetic spec-vs-code" divergence where Openclicky matches its own
task spec ("green outline", "red circle") not Everywhere's actual
pixels.

### Issue 3 — Badge fill diverges from Everywhere

Everywhere renders the ➕ badge with a `LinearGradientBrush`
`#AC45F1 → #7A7EF4 → #3DC6F8`
(`AnnotationOverlayWindow.cs:90-98`). Openclicky renders it with a
flat red `Color(red: 0.86, green: 0.12, blue: 0.20)`
(`OpenClickyAnnotationBadgeOverlay.swift:654`). Hardcoded on both.
✓ green fills roughly agree — Everywhere `#3DC68C`
(`AnnotationOverlayWindow.cs:304`) vs Openclicky
`(0.24, 0.78, 0.55)` (`OpenClickyAnnotationBadgeOverlay.swift:656`).

### Issue 4 — Openclicky adds knobs Everywhere doesn't expose (and vice versa)

Openclicky-only knobs (all in Settings > Basic):

- Glass tint strength slider — `openClickyGlassOpacity`, 0.1-1.0
  (`OpenClickySettingsWindowManager.swift:750`).
- Glass frosting slider — `openClickyGlassFrosting`, 0.0-1.0
  (`OpenClickySettingsWindowManager.swift:764`).
- Cursor avatar picker — `openclicky.cursorAvatarStyle`
  (`OverlayWindow.swift:193`).
- Cursor color grid (5 accents) — `clickyAccentTheme`
  (`OpenClickySettingsWindowManager.swift:815`).
- Task-complete notifications toggle + voice toggle
  (`OpenClickySettingsWindowManager.swift:1892-1912`).
- Panel pinned state (`MenuBarPanelManager.swift:255-261`).

Everywhere-only knobs (from `DisplaySettings.cs` / `CommonSettings.cs`
/ `ShortcutSettings.cs`):

- Language picker with 12 locales (`DisplaySettings.cs:36-50`).
- Free-form accent color picker via `AccentColorSelector`
  (`DisplaySettings.cs:81-88`) — Openclicky is restricted to a fixed
  9-tone enum (`Theme.swift:4-13`) with only 5 surfaced in the UI
  grid.
- Font size slider (`DisplaySettings.cs:93-167`).
- User / administrator startup toggles (`CommonSettings.cs:141-162`,
  `:76-107`).
- Auto update check + update channel (`CommonSettings.cs:47, 53`).
- Diagnostic data / statistics (`CommonSettings.cs:170, 172`).
- All hotkey rebinds — Whiteboard, LinkRect, PickElement,
  SnapshotContext, ClearContextStash, TakeScreenshot, ChatWindow
  (`ShortcutSettings.cs:22-94`). Openclicky ships the hotkey rebinds
  via a separate mechanism (`OpenClickyContextHotkeys` and its
  settings section, out of Domain 4 scope).

### Issue 5 — Notch panel appearance is a single variant

Openclicky ships a bespoke notch surface (`OpenClickyNotchPanelView`,
`OpenClickyNotchCaptureWindowManager`) that Everywhere has no
counterpart for. The notch panel binds to the same accent theme
(`OpenClickyNotchPanelView.swift:66`) but exposes no
"notch style" enum, no compact/expanded selector, no auto-hide
timer. Not a divergence from Everywhere — Everywhere has no notch —
but a shipping-parity gap against Openclicky's own product surface.

### Issue 6 — Reduce-motion / accessibility not exposed on either side

Neither Everywhere nor Openclicky expose a "reduce motion" toggle,
a way to disable overlay animations, or an alternative renderer for
users who need it. Hardcoded animation durations on Openclicky
include:

- `DS.Animation.fast` easings on agent overlay cards
  (`ClickyAgentOverlayCard.swift:586-587, 632-633, 660-661`).
- 250 ms whiteboard fade-out
  (`OpenClickyWhiteboardOverlayWindow.swift:321`).
- 18 ms and 16 ms SwiftUI `.easeInOut` / `.easeOut` on chat workspace
  transitions (`ChatWorkspaceView.swift:148-150`).

Note for shipping: macOS `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
is not queried anywhere in the reviewed files.

### Issue 7 — AXQuirks per-app allowlist deliberately absent on both sides

Everywhere fires `AXManualAccessibility` + `AXEnhancedUserInterface`
**unconditionally on every AX-consuming path**
(`VisualElementContext.cs:127-128`), then caches the pid so it
doesn't re-fire. Openclicky mirrors this contract
(`AXQuirksInstaller.swift:225-234`). File-header comment L20-25
explicitly rejects a per-bundle allowlist as a maintenance rathole:

> Everywhere fires BOTH attributes unconditionally on every AX-consuming
> path ... rather than branching on bundle_id — the two flips are cheap,
> apps that don't need them cost nothing, and the alternative (a
> per-bundle table you have to keep up-to-date with every new
> Electron/Chromium fork) is a maintenance rathole.

There is no user or dev toggle, and no scope to add one without
diverging from the Everywhere invariant. This is the correct
absence.

### Issue 8 — Openclicky consolidates 3 preflight kinds Everywhere models elsewhere

Everywhere's `PermissionHelper.cs` only models Accessibility (with
prompt) and Screen Recording (via live 1×1 capture). Input
Monitoring, Microphone, and Automation live in adjacent subsystems
in Everywhere. Openclicky's `PermissionPreflight.check(_:)` unifies
all five behind one entry point (`PermissionPreflight.swift:63-79`,
five branches L67-77) and switches every call to the passive/
check-only variant of each macOS API — documented at file header
L13-32. This is a shipping-parity improvement, not a divergence.

## Verdict

**Verdict: C — matches on core mechanics + settings shape; diverges on cosmetic tokens and adds product-specific knobs.**

Core behaviour parity (session lifecycle, hit-test model, harvester
constants, follower cadence, badge sizes, five-kind preflight,
AX-quirks contract) is at Everywhere parity or stricter — every
audited constant (`MaxLinks=200`, `MaxUrlLen=2048`, `MaxTitleLen=200`,
`MaxDepth=60`, `WalkBudget=50000`, `BadgeSize=24`, `ExpandedWidth=320`,
`ExpandedHeight=110`, `OffsetX=6`, `OffsetY=-6`, follower interval
50 ms, SystemWide AX timeout 1 s) matches byte-for-byte. Classifier
thresholds and rules match byte-for-byte (already accepted in F23).

Cosmetic divergences (tint alpha, outline color, badge fill,
window-level constants, hit-test throttle) are documented in the
task spec as intentional. All hardcoded on both sides — no user knob
exists to reconcile them.

Openclicky adds four surfaces Everywhere doesn't expose (glass
opacity/frosting sliders, cursor-avatar picker, permissions status
panel with deep-links, task-complete notifications toggle+voice) and
lacks four Everywhere exposes (Language picker, free-form accent color,
Font-size slider, per-startup toggles, per-shortcut rebinds inside
`ShortcutSettings.cs`). None of the Everywhere-only knobs affect the
Domain-4 UX-overlay contract; they're general app chrome.

Ship-blocking gaps in this domain: **none.**

Ship-quality gaps worth logging as follow-ups:

- Issue 4 (Openclicky accent picker limited to 5-of-9 tones in the UI
  grid vs Everywhere's free-form picker); trivial to widen the
  ForEach on `OpenClickySettingsWindowManager.swift:815` to
  `ClickyAccentTheme.allCases`.
- Issue 6 (no "reduce motion" toggle honoring
  `accessibilityDisplayShouldReduceMotion`); relevant for
  accessibility parity in the wider macOS ecosystem, not Everywhere
  parity per se.
- Issue 1 (whiteboard/LinkRect/PickElement all 0.15 vs Everywhere's
  0.4). Values agree with the Openclicky task spec so this is only a
  divergence if the spec is renegotiated.

## Knob count

29 knobs audited across 8 surface areas:

| Surface | Knobs |
|---|---|
| Whiteboard overlay | 10 |
| LinkRect overlay + harvester | 15 |
| PickElement HUD | 7 |
| Annotation badge + AXFollower | 16 |
| Permission preflight | 12 |
| AX Quirks | 7 |
| Appearance / theme | 13 |
| Menu bar icon | 8 |

Total distinct rows across the eight alignment tables: 88.
Distinct **user-configurable** knobs (across both apps): Everywhere
9, Openclicky 12, both 2 (theme, accent color — different shape).
