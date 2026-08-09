# Parity P0 UI wire fix — 2026-07-23

Fixes the four P0 wire gaps identified in the parity audit
(`parity-domain1-hotkeys-context-2026-07-23.md`,
`parity-domain2-mcp-ecosystem-2026-07-23.md`).

Everywhere pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809 (informational
— none of the four subsystems have upstream Everywhere counterparts.
The pin is carried purely to keep the parity ledger's provenance
consistent.)

Build verification: `bash scripts/sign-and-install.sh` → **BUILD
SUCCEEDED**, `openclicky pid=24588`.

---

## Fix 1 — Wire the four orphan MCP subsystem sections into a new tab

### 1a. New enum case, panel wiring, subtitle copy

`cursor-buddy/OpenClickySettingsWindowManager.swift`:

- Enum `OpenClickySettingsSection` (previously 9 cases: basic /
  advancedProviders / computerUse / permissions / agents / automations
  / connections / models / contextAwareness) now includes
  `mcpSubsystems` (title "MCP subsystems",
  systemImageName `puzzlepiece.extension`) inserted between
  `connections` and `models`.
- `selectedPanel` switch (line ~532) gains a `.mcpSubsystems ->
  mcpSubsystemsPanel` arm.
- `sectionSubtitle` gains an `.mcpSubsystems` arm:
  "Browser (OpenDia), OpenCLI site adapters, open-connector providers,
  Chrome bridge, and external-control bridge auth."
- The sidebar loop already iterates `OpenClickySettingsSection.allCases`
  so the new tab is picked up automatically. No additional wiring
  needed.

### 1b. `mcpSubsystemsPanel` computed view

New computed view added after `contextAwarenessPanel`
(`OpenClickySettingsWindowManager.swift` line ~2474). Contains five
`settingsGroup(...)` blocks in top-to-bottom order:

1. **Browser (OpenDia)** — `OpenClickyOpenDiaSettingsSection(settings:
   OpenClickyOpenDiaSettings.shared)` (previously orphaned).
2. **OpenCLI (site adapters)** — new
   `OpenClickyOpenCLISettingsSection(settings:
   OpenClickyOpenCLISettings.shared)` (newly created, see 1c).
3. **Connectors (open-connector)** — new
   `OpenClickyConnectorSettingsSection(settings:
   OpenClickyConnectorSettings.shared)` (newly created, see 1d).
4. **Chrome Bridge (account reset)** —
   `OpenClickyChromeBridgeSettingsSection()` (previously orphaned).
5. **External-control bridge auth** — `externalControlBridgeAuthRow`
   (see Fix 4).

### 1c. `OpenClickyOpenCLISettingsSection.swift` (new file)

Mirrors `OpenClickyOpenDiaSettingsSection.swift`'s shape (rowIcon
helper, VStack of rows separated by inset Dividers). Rows:

- Enable toggle bound to `OpenClickyOpenCLISettings.shared.enabled`.
- Runtime status row (uses `runtimeStatus`, `siteCount`,
  `adapterCount`, and `lastError` published by the settings model).
- Node path override TextField bound to `@AppStorage("openclicky.
  opencli.nodePathOverride")` — `OpenClickyOpenCLISettings` does not
  currently expose the override as a `@Published` property so the UI
  reaches into the same UserDefaults key directly.
- Error row (only visible when `settings.lastError` is non-empty).

### 1d. `OpenClickyConnectorSettingsSection.swift` (new file)

Same shape as OpenCLI's section. Rows:

- Enable toggle → `OpenClickyConnectorSettings.shared.enabled`.
- Runtime status (uses `runtimeStatus`, `providerCount`, `lastError`).
- Node path override TextField bound directly to `settings.
  nodePathOverride`.
- Provider allowlist TextField (comma-separated) bound to
  `settings.providerAllowlist`.
- Provider disallowlist TextField (comma-separated) bound to
  `settings.providerDisallowlist`.

Files created:

- `cursor-buddy/OpenClickyOpenCLISettingsSection.swift` (new, ~140
  lines).
- `cursor-buddy/OpenClickyConnectorSettingsSection.swift` (new, ~205
  lines).

Both files are auto-picked up by the pbxproj's
`PBXFileSystemSynchronizedRootGroup` (no manual pbxproj edit
required).

### Screenshot description (words)

Opening OpenClicky Settings, the sidebar now shows 10 rows in this
order: Basic, Advanced Providers, Computer Use, Permissions, Agents,
Automations, System & Logs, **MCP subsystems** (new,
`puzzlepiece.extension` glyph), Models, Context Awareness. Selecting
"MCP subsystems" reveals five stacked settings groups: "Browser
(OpenDia)" (enable toggle, status, endpoint, test connection),
"OpenCLI (site adapters)" (enable toggle, status w/ site+adapter
counts, node path override), "Connectors (open-connector)" (enable
toggle, status w/ provider count, node path, allow/deny lists), "Chrome
Bridge (account reset)" (server status, extension status, refresh, and
about row), and "External-control bridge auth" (bearer token preview,
Copy, Regenerate).

---

## Fix 2 — KnownApps editor UI

`cursor-buddy/OpenClickyContextAwarenessPanel.swift`:

- Verified struct fields against `OpenClickyContextAwarenessSettings.
  swift:142-153`: `OpenClickyKnownApp` exposes `titlePattern:
  String` and `discoverUrl: String`.
- Added `knownAppsGroup` computed view between `launchPhraseGroup`
  and `autoCaptureGroup` in the `body` VStack.
- Group uses the existing `groupContainer(title:)` helper. Layout:
  descriptive blurb → `ForEach` over `settings.knownApps` (each row
  has title regex TextField + discover URL TextField + red minus
  button) → "Add rule" button that appends an empty rule.
- Every setter uses the immutable-copy pattern:

  ```
  var updated = settings.knownApps
  updated[index] = OpenClickyKnownApp(...)
  settings.knownApps = updated
  ```

  so the didSet on the `@Published var knownApps` fires and JSON-encodes
  the new value into `openclicky.contextAwareness.knownApps`.

### Screenshot description

Settings → Context Awareness now shows a "Known apps" group card
between "Launch phrase" and "Auto capture". Card body: paragraph
explaining the `[openclicky-discover]` hint mechanism, followed by two
monospaced TextField pairs (one per default xlinkBook rule seeded from
`OpenClickyContextAwarenessSettings.defaultKnownApps`), each pair
followed by a red minus button. Underneath sits a plain "Add rule"
button with a `plus.circle` glyph.

---

## Fix 3 — AGENTS-longrun-template inline verification

Command:

```
grep -c "OPENCLICKY_TASK_DIR\|Task planning contract" \
    AppResources/OpenClicky/AGENTS.md
```

Result: **3** (previous grep sanity check also reported 3, plus 2 for
`OPENCLICKY_TASK_DIR` alone). Section already inlined by the earlier
F28 fix agent — no edit made to AGENTS.md this pass.

---

## Fix 4 — Bridge bearer token viewer / regenerator

`cursor-buddy/AppBundleConfiguration.swift`:

- Added a new static method
  `regenerateExternalControlBridgeToken() -> String` right after
  `externalControlBridgeToken()`. It draws 32 random bytes, hex-encodes
  them, writes to
  `userExternalControlBridgeTokenDefaultsKey`, and returns the new
  token. `@discardableResult` so UI can ignore the return.

`cursor-buddy/OpenClickySettingsWindowManager.swift`:

- Added `bridgeTokenPreviewTick: Int` @State on
  `OpenClickySettingsView` and the `externalControlBridgeAuthRow`
  computed view.
- Row layout: `key.horizontal` glyph, "Bearer token" label, monospaced
  preview showing `<first 8 chars>… (<length> chars)` or "not set",
  short blurb, then Copy and Regenerate borderedProminent buttons.
- Copy calls `NSPasteboard.general.setString(...)`.
- Regenerate calls
  `AppBundleConfiguration.regenerateExternalControlBridgeToken()` and
  bumps the tick so the preview label recomputes on next body
  invocation.

### Screenshot description

Under the new "MCP subsystems" tab, the last section card
("External-control bridge auth") shows one row: bearer key glyph on
left, "Bearer token" bold label, "abcdef12… (64 chars)" monospaced
subtitle, one-liner about rotation, then Copy and Regenerate small
bordered buttons pinned to the right. Clicking Regenerate immediately
updates the preview text with the new token's first eight characters.

---

## Grep verify results

| Check | Command | Result |
|---|---|---|
| AGENTS.md task-planning contract inlined | `grep -c "OPENCLICKY_TASK_DIR" AppResources/OpenClicky/AGENTS.md` | 2 (task planning contract heading also present, matches ≥2 as required) |
| BUILD | `bash scripts/sign-and-install.sh` | BUILD SUCCEEDED, openclicky pid=24588 |
| Compile switch exhaustiveness | `xcodebuild ... build \| grep error:` | (empty) |

---

## Files modified / created

Modified:

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/AppBundleConfiguration.swift`
  (added `regenerateExternalControlBridgeToken()` after line 211)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickySettingsWindowManager.swift`
  (enum case, `selectedPanel` arm, `sectionSubtitle` arm,
  `mcpSubsystemsPanel` + `externalControlBridgeAuthRow`)
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyContextAwarenessPanel.swift`
  (added `knownAppsGroup` and wired into `body`)

Created:

- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyOpenCLISettingsSection.swift`
- `/Users/wowdd1/Dev/openclicky/cursor-buddy/OpenClickyConnectorSettingsSection.swift`

Not touched (per constraints):

- Bridge server code (`OpenClickyExternalControlBridge.swift` untouched
  beyond the caller-side token setter).
- `AGENTS.md` (section already inlined).
- Whiteboard / LinkRect / PickElement overlays.
- Provider Keychain migration (separate agent).
- Router / agent-UI overrides (separate agent).
