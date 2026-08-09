# Chrome Bridge status UI in OpenClicky Settings

Date: 2026-07-23
Scope: Add a Settings pane readout for the local
`HeyClickyChromeBridgeServer` and the merged OpenDia Chrome extension
that drives the account-reset auto-clicker.

## Files touched

- `cursor-buddy/OpenClickyChromeBridgeSettingsSection.swift` (new)
  - SwiftUI `@MainActor` view with four rows: server status, extension
    status, refresh button, explanation caption.
  - Auto-polls the bridge every 4 seconds via `Timer.publish(every: 4,
    on: .main, in: .common).autoconnect()` combined with `.onReceive`.
    SwiftUI tears the timer down when the view is not in the hierarchy,
    so polling stops when the Settings pane is hidden.
  - Snapshots `HeyClickyChromeBridgeServer.shared.activePort`,
    `.isRunning`, and `.isExtensionAlive` on the main actor, then hits
    `http://127.0.0.1:<port>/health` with a 0.5 s URLSession timeout
    and parses the JSON `extAlive` field. If the probe fails, falls
    back to `isExtensionAlive` and surfaces the error underneath the
    extension status.

- `cursor-buddy/OpenClickySettingsWindowManager.swift`
  - New `settingsGroup("Chrome Bridge (account reset)") { ... }`
    inserted directly below the existing `settingsGroup("Browser
    (OpenDia)")` block in `connectionsPanel`.

- `cursor-buddy/HeyClickyChromeBridgeServer.swift`
  - Added two public accessors on the shared singleton (server logic
    untouched):
    - `var activePort: UInt16?` returns `port.rawValue` when the
      listener is bound, `nil` otherwise.
    - `var isRunning: Bool` returns whether the `NWListener` is up.

## Not touched

- F31 OpenDia section (`OpenClickyOpenDiaSettingsSection.swift`).
- Chrome extension source at `~/Dev/opendia/opendia-extension/`.
- Bridge server long-poll / event dispatch logic.

## Visual description of the new Settings section

Inside the "System & Logs" tab of OpenClicky Settings, the
`connectionsPanel` now shows a new grouped card titled "Chrome Bridge
(account reset)", sitting directly below the existing "Browser
(OpenDia)" card and above "Workspace Actions". The card contains four
stacked rows separated by hairline dividers indented 46 pt from the
left, matching the OpenDia card:

1. Server status — leading `checkmark.circle` (running) or
   `pause.circle` (stopped) icon in accent color. Title "Server status"
   in medium 13 pt. Subtitle either "Listening on 127.0.0.1:3011" or
   "Not running" in secondary 11 pt.
2. Extension status — leading `checkmark.circle` /
   `exclamationmark.triangle` / `circle.dashed` icon. Subtitle is one
   of: "Waiting for first check...", "Connected (checked N s ago)",
   "Not connected — extension is not polling the bridge.", or
   "Health check failed: <reason>".
3. Refresh — plain button row with a leading `arrow.clockwise`
   (`hourglass` while a probe is in flight), label "Refresh", trailing
   chevron. Disabled while a probe is running. Manually triggers a
   `/health` re-query.
4. About — `info.circle` icon plus a wrapped caption: "The merged
   OpenDia Chrome extension polls this bridge to handle account reset
   flows. If not connected, load the extension in Chrome from
   ~/Dev/opendia/opendia-extension/dist/chrome/ (via
   chrome://extensions/, Load unpacked)."

The card auto-refreshes silently every 4 seconds while the Settings
window is showing this tab. Pressing Refresh forces an immediate probe.

## Verification

- `swiftc -parse cursor-buddy/OpenClickyChromeBridgeSettingsSection.swift cursor-buddy/HeyClickyChromeBridgeServer.swift` completes with no diagnostics.
- Grep confirms `activePort`, `isRunning`, and the new group title are
  present in exactly one place each.

## User action required

The new Settings section is a SwiftUI view compiled into the app
bundle, so it only appears after an Xcode rebuild of OpenClicky. Per
project rules, `xcodebuild` is not invoked from the terminal — the
user should rebuild in Xcode and open Settings → System & Logs to see
the "Chrome Bridge (account reset)" card between "Browser (OpenDia)"
and "Workspace Actions".
