# Parity Domain 2: MCP tool ecosystem settings

Audit pin: Everywhere `30e03e9dcfdd4247fd679828ed86e9042f32d809`.
Openclicky HEAD as of 2026-07-23.

Scope: user-facing knobs for the MCP subsystems that expose the openclicky
sensor bridge and its tool families — OpenDia (F31 / 120 `browser_*`),
OpenCLI (F30 / `opencli_*`), open-connector (F29 / `connector_*`), chat
bus (F32 / `chat_*`), web (F34 / `web_*`), adapter authoring (F33 /
`adapter_*`), capture (F36 / `capture_*`), page (F35 / `page_*`), plus
the external-control bridge itself (bridge port + bearer token) and the
merged HeyClicky Chrome bridge (F31 companion). Not tool byte-parity —
that lives in F29-F36 review notes.

Verdicts:
- **A** — parity: same knob, same storage + UI surface.
- **B** — wire gap: storage exists in openclicky but no UI to reach it.
- **C** — feature gap: neither storage nor UI in openclicky.
- **D** — openclicky extra (not present in Everywhere).
- **E** — intentional drop (does not apply / product-shape divergence).

## Everywhere inventory (this domain)

MCP HTTP transport (`Everywhere.Core/Configuration/Settings/McpServerSettings.cs`,
`Everywhere.Mcp/Transport/EverywhereMcpHttpHost.cs` for defaults):

1. `McpServer.HttpEnabled` — `McpServerSettings.cs:40`, default `true`, auto-generated toggle via `[SettingsItem]`. Master enable for the loopback Kestrel listener.
2. `McpServer.HttpPort` — `McpServerSettings.cs:48`, default `7878`, `[SettingsIntegerItem(Min=1, Max=65535)]`, visible when `HttpEnabled` is on. User-editable in the auto-generated Settings page.

OpenDia bridge (`McpServerSettings.cs:56-76`, `Everywhere.Mcp/OpenDia/OpenDiaBridge.cs`,
`Everywhere.Mcp/OpenDia/OpenDiaBridgeInitializer.cs`):

3. `McpServer.OpenDiaEnabled` — `McpServerSettings.cs:68`, default `false`, `[SettingsItem]` auto-generated toggle. Master enable for the loopback WebSocket bridge.
4. `McpServer.OpenDiaPort` — `McpServerSettings.cs:76`, default `5555`, integer editor visible when `OpenDiaEnabled` is on.
5. Extension install helper — Everywhere does NOT bundle an install-status UI. The user sideloads the unmodified upstream OpenDia extension. Referenced only in `docs/specs/opendia-cebian-merge.md:463` ("`OpenDiaBridgeSection` inside Cebian settings — one button, 'Open Connector Manager'"), which is post-merge (Cebian). For Everywhere-baseline audit, treat as absent.
6. Extension connection status — Not surfaced as a UI row in `Everywhere.Core/Views/`. `OpenDiaBridge.cs` exposes `IsConnected` for internal listing (drives `browser_*` tool visibility), but there is no user-visible readout.

OpenCLI adapter runtime (`Everywhere.Mcp/OpenCli/OpenCliRuntime.cs`,
`Everywhere.Mcp/Tools/OpenCliTools.cs`):

7. Enable toggle — none. OpenCLI runtime is always registered
   (`EverywhereMcpServiceExtensions.cs:59-96` — `TryAddSingleton<OpenCli.OpenCliRuntime>` with no gate). V8 isolate is lazy-booted on first `opencli_*` call.
8. Port override — none. OpenCLI is in-process (V8 via ClearScript), not a network service.
9. Adapter workspace — none. Adapters live in `3rd/opencli/clis/` (bundle) or, when Phase 5 self-expand generator saves one, under `~/.everywhere/opencli/adapters/`. No UI editor.
10. Site count / adapter count readout — none.
11. Node path override — N/A (no Node subprocess).

Open-connector runtime (`Everywhere.Mcp/Connector/ConnectorRuntime.cs`,
`Everywhere.Mcp/Connector/JsonCredentialStore.cs`,
`Everywhere.Mcp/Connector/OAuthFlowService.cs`):

12. Enable toggle — none. Runtime always registered
    (`EverywhereMcpServiceExtensions.cs:118-154`).
13. Provider allowlist — none in user-facing Settings. The Phase-1 `PROVIDERS = ["github"]` bundle-time allowlist mentioned in `docs/specs/everywhere-connector.md:176` is a BUILD-time constant in `3rd/open-connector/vite.config.ts`, not a runtime setting.
14. Provider disallowlist — none.
15. Connections list UI — none in Everywhere Avalonia settings. Users open the upstream connector Web Console `http://127.0.0.1:7878/connector-ui/` in a browser tab (`docs/specs/everywhere-connector.md:459-464`). Even that is a Phase-4 SPA static-hosted by upstream; Everywhere's contribution is a settings link, but no such link exists in the shipping settings page today (no `.axaml` reference).
16. OAuth flow buttons — none. Flow is agent-driven via `connector_start_oauth` MCP tool.
17. Credential storage location — `~/.everywhere/connector/connections.json`, path is not user-editable.
18. Encryption key — `~/.everywhere/connector/.keyring`, not user-editable.
19. Run log — `Everywhere.Mcp/Connector/RunLogStore.cs`, no user-visible clear/inspect UI.
20. Transit files base URL — hard-coded to `http://127.0.0.1:7878` (`EverywhereMcpServiceExtensions.cs:112`).

Chat bus (`Everywhere.Mcp/OpenDia/OpenDiaChatBus.cs`,
`Everywhere.Mcp/Tools/ChatBusTools.cs`):

21. Subscribers view — none. Registered as singleton (`EverywhereMcpServiceExtensions.cs:41`), no UI.
22. Message queue inspect — none.
23. Timeout / clear queue — none (defaults live in `ChatBusTools.cs:timeout_ms=30000` argument default).

Web search / fetch (`Everywhere.Core/Configuration/Settings/WebSearchEnginePluginSettings.cs`,
`Everywhere.Mcp/Tools/WebSearchTool.cs`):

24. Provider selector — `WebSearchEngineSettings.SelectedProviderId` at `WebSearchEnginePluginSettings.cs:354`. 10 providers registered in `WebSearchEngineSettings` ctor (`:439-524`): Official / AnySearch / Bocha / Brave / Google / Jina / SearXNG / Tavily / UniFuncs / TinyFish. Rendered as `WebSearchEnginePage.axaml`.
25. Per-provider endpoint — `Customizable<string> EndPoint` on every third-party provider (`WebSearchEnginePluginSettings.cs:156, 240, 295, 342` etc), user-editable.
26. Per-provider API key(s) — `ObservableCollection<ApiKey> ApiKeys` on every third-party provider (`:171, 250, 303`). `ApiKeyListEditor` control lets user add/remove/rotate keys per provider (`:189, 263, 316`).
27. Google-specific SearchEngineId — `GoogleWebSearchEngineProvider.SearchEngineId` at `:199`.
28. Official provider knobs — Depth / Topic / TimeRange (`OfficialWebSearchEngineSettings` at `:47-65`).
29. Legacy key vault migration — automatic (`MigrateLegacyVault`, `:385-437`). No UI.

Adapter authoring surface (`Everywhere.Mcp/Tools/GeneratorTools.cs`,
`Everywhere.Mcp/Tools/GateTools.cs`):

30. Adapter workspace — none in Settings UI. Adapters saved to
    `~/.everywhere/opencli/adapters/<site>/<name>.js` via
    `adapter_save` MCP tool (spec `docs/specs/everywhere-self-expanding.md`).
31. Draft / publish / verify buttons — none. Agents drive it via
    the eight `adapter_*` tools.

Capture template surface (`Everywhere.Mcp/Tools/CaptureTools.cs`,
`Everywhere.Mcp/OpenCli/Observation/CaptureSessionStore.cs`):

32. Capture list / saved templates UI — none. Sessions live in in-memory `CaptureSessionStore` (server-restart invalidates, per SPEC).
33. Capture session inspector — none.

Chrome bridge (Phase 3+ of `docs/specs/opendia-cebian-merge.md`,
merged extension polling the daemon):

34. Chrome bridge status — Not applicable to Everywhere-baseline. Everywhere daemon is the OpenDia WebSocket server itself; there is no separate HTTP long-poll bridge.

Bridge external-control auth (Everywhere N/A — internal transport is HTTP loopback, no bearer token on `/mcp`; see `EverywhereMcpHttpHost.cs` — but Codex spawn uses `bearer_token_env_var` per openclicky F27 review, which is upstream-parity for **openclicky**, not Everywhere):

35. Bridge bearer token — Everywhere: not required (loopback-only listener).

## Openclicky parity table

| # | Everywhere setting | Everywhere source | Openclicky storage | Openclicky UI | Verdict |
|---|---|---|---|---|---|
| 1 | McpServer.HttpEnabled | `McpServerSettings.cs:40` (auto UI) | `OpenClickyExternalControlBridge.swift:148-227` — bridge always constructed, no `enabled` bool | none | **C** — Feature gap. Openclicky's external-control bridge has no user-facing enable toggle. Autostart is unconditional (`CompanionManager.swift` constructs it on init). Env var override `OPENCLICKY_MCP_PORT` (`OpenClickyExternalControlBridge.swift:161-167`) is not a Settings knob. |
| 2 | McpServer.HttpPort (default 7878) | `McpServerSettings.cs:48` (auto UI, integer editor 1..65535) | `OpenClickyExternalControlBridge.swift:152` `defaultPort: UInt16 = 32123`; env override `OPENCLICKY_MCP_PORT` at `:161-167`; fallback ladder `+1..+10` at `:154-156, 231-278`; runtime port at `:184-188` `activePort` | none | **B** — Wire gap. The port is env-only. No `TextField` / `IntStepper` in `OpenClickySettingsWindowManager.swift` or notch panel. `activePort` is read internally to render Codex `config.toml` but never rendered as a settings row. |
| 3 | McpServer.OpenDiaEnabled | `McpServerSettings.cs:68` (auto UI) | `OpenClickyOpenDiaSettings.swift:24, 28-33` `enabled` @Published, defaults key `openclicky.opendia.enabled`, env force `OPENCLICKY_MCP_OPENDIA=1` (`:49`), default-on (`:52-57`) | Section view `OpenClickyOpenDiaSettingsSection.swift:43-64` EXISTS with a toggle row, but grep confirms **zero call sites** in the shipping app (`grep -rn OpenClickyOpenDiaSettingsSection cursor-buddy/*.swift` returns only the definition). | **B** — Wire gap. Storage exists, section view is written, but nothing instantiates the section in `OpenClickySettingsWindowManager.swift`, `OpenClickyNotchPanelView.swift`, or `OpenClickyNotchPanelView+Sections.swift`. The user's only ways to flip the master toggle are (a) hand-writing UserDefaults, (b) the `OPENCLICKY_MCP_OPENDIA=1` env var. Duplicated observation from `F31-opendia-integration-2026-07-23.md:I1` and this domain 2 audit — still unfixed at HEAD. |
| 4 | McpServer.OpenDiaPort (default 5555) | `McpServerSettings.cs:76` (auto UI, integer editor) | `OpenClickyOpenDiaSubprocess.swift:66` `boundPort` — allocated by the Node subprocess in a random range `[56000, 57000)` (`OpenClickyOpenDiaSubprocess.swift:134-135`, `boot.js:72-73`); no user override. | none | **C** — Feature gap. Openclicky auto-allocates and re-binds each launch. Different design from Everywhere's fixed 5555. Acceptable given openclicky owns the extension config out-of-band, but users cannot pin the port for firewall / proxy setups. |
| 5 | OpenDia extension install helper | `docs/specs/opendia-cebian-merge.md:463` (post-merge only) | none | Copy in `OpenClickyOpenDiaSettingsSection.swift:47-53` mentions "load the sideloaded OpenDia browser extension" but section is unreachable (see #3). Also `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md` (docs only) — user reads a text README. | **B** — Wire gap. The install-helper copy exists in the unreachable section. |
| 6 | OpenDia extension connection status | not user-visible in Everywhere | `OpenClickyOpenDiaSubprocess.swift:78-81` `extensionConnected: Bool?` + `availableToolCount: Int?`; `OpenClickyOpenDiaSettings.swift` `syncRuntimeSnapshot()` republishes | Rendered in unreachable section (`OpenClickyOpenDiaSettingsSection.swift:66-82`, `:163-173`); rendered in notch panel `OpenClickyNotchPanelView.swift:387-405` "Browser (OpenDia)" row (this IS reachable). | **D+partial** — Notch surfaces the state (openclicky extra vs. Everywhere; positive). Settings section duplicates the readout but section itself is unreachable per #3. |
| 7 | OpenDia Test Connection button | none in Everywhere | none in storage; ad-hoc probe in `OpenClickyOpenDiaSubprocess.swift:testConnection()` (referenced from `OpenClickyOpenDiaSettingsSection.swift:194`) | Only inside the unreachable section (`OpenClickyOpenDiaSettingsSection.swift:108-127`). | **D** — Openclicky-extra affordance; unreachable in shipping UI. |
| 8 | OpenDia Node path override | none in Everywhere (Everywhere uses in-process ClearScript, no Node subprocess) | `OpenClickyOpenDiaSettings.swift:25, 36-44` `nodePathOverride: String?`, defaults key `openclicky.opendia.nodePathOverride` (parsed from compressed source header); used by `OpenClickyOpenDiaSubprocess.swift:423`. | none — the unreachable section doesn't even render this field. | **B** — Wire gap. Openclicky-extra field with no editor; user must hand-write UserDefaults. |
| 9 | OpenCLI enable toggle | none in Everywhere (always-on) | `OpenClickyOpenCLISettings.swift:25, 28-33` `enabled` @Published, defaults key `openclicky.opencli.enabled`, env force `OPENCLICKY_MCP_OPENCLI=1` (`:38`), default-on (`:40-45`) | none — no section, no notch row, no settings row | **B** — Wire gap. Storage present, no UI to reach it. Because openclicky spawns a Node subprocess (not in-process V8), the toggle materially affects startup cost — worse asymmetry than Everywhere's always-on. |
| 10 | OpenCLI port | Everywhere: N/A (in-process) | `OpenClickyOpenCLISubprocess.swift` random `[55000, 56000)` allocation; no override | none | **E** — Not applicable. Everywhere has no equivalent; openclicky auto-allocates. Acceptable. |
| 11 | OpenCLI runtime status | none in Everywhere | `OpenClickyOpenCLISettings.swift:51-54` `runtimeStatus`, `siteCount`, `adapterCount`, `lastError`; `OpenClickyOpenCLISubprocess.swift:81-83` `lastStatusMessage`, `siteCount`, `adapterCount` | none — nothing consumes these | **B** — Wire gap. Storage published, no reader. |
| 12 | OpenCLI adapter workspace UI | none in Everywhere | `OpenClickyAdapterAuthoringBridgeTools.swift:37` documents storage `~/Library/Application Support/OpenClicky/adapters/<site>/<name>.js` and `:36-40` isolates from bundled tree; all eight tools currently return `NOT_IMPLEMENTED` (`:269, :86, :118`) | none | **E** — Not applicable to Everywhere. Openclicky's adapter authoring surface is MCP-tool-only, matching Everywhere. No user-visible workspace either. Note the `NOT_IMPLEMENTED` state: even if a UI existed there's nothing to author against yet. |
| 13 | Open-connector enable toggle | none in Everywhere (always-on) | `OpenClickyConnectorSettings.swift:26, 32-37` `enabled` @Published, defaults key `openclicky.connector.enabled`, env force `OPENCLICKY_MCP_CONNECTOR=1` (`:71`), default-on (`:73-77`) | none — no section, no notch row | **B** — Wire gap. Same structural asymmetry as #9. Openclicky spawns a Node subprocess (heavier than Everywhere's in-process ClearScript), so a toggle matters more but is unreachable. |
| 14 | Connector Node path override | Everywhere N/A | `OpenClickyConnectorSettings.swift:27, 42-50` `nodePathOverride: String?`, defaults key `openclicky.connector.nodePathOverride`; used by `OpenClickyConnectorSubprocess.swift:364` | none | **B** — Wire gap. |
| 15 | Connector provider allowlist | none in Everywhere runtime (bundle-time only) | `OpenClickyConnectorSettings.swift:28, 54-58` `providerAllowlist: [String]`, defaults key `openclicky.connector.providerAllowlist` | none — no editor | **D+B** — Openclicky-extra concept (runtime allowlist, not bundle-time), but storage-without-UI. Add a list editor. Empty means allow-all (per comment `:53`). |
| 16 | Connector provider disallowlist | none in Everywhere | `OpenClickyConnectorSettings.swift:29, 61-65` `providerDisallowlist: [String]`, defaults key `openclicky.connector.providerDisallowlist` | none | **D+B** — Openclicky-extra, storage-without-UI. |
| 17 | Connector connections list (which SaaS providers user is authenticated with) | Web Console at `/connector-ui/`, Phase-4 external SPA | `OpenClickyConnectorBridgeTools.swift:44, 160-161, 183, 467` MCP tool `connector_list_connections` exists and works; `OpenClickyConnectorCredentialStore.swift` holds credentials in `~/Library/Application Support/OpenClicky/connector/connections.json` (implied from filename and F29 impl notes) | none — no Settings row, no in-app browser tab, no `NSWorkspace.shared.open(URL)` link to a local console | **C** — Feature gap for the shipping UI. Everywhere ships a Web Console; openclicky ships neither the console nor a native list. Users must use the MCP tool from an agent to inspect. |
| 18 | Connector OAuth callback URL | Everywhere loopback URL bound at Kestrel level | `OpenClickyConnectorOAuthCallback.swift:35, :localhostURL()` — dedicated loopback server, called by the subprocess (`OpenClickyConnectorSubprocess.swift:137`) | none — no readout, no user-supplied redirect URI override | **B** — Wire gap. Users cannot see or copy the callback URL if their provider requires whitelisting it. |
| 19 | Connector runtime status readout | none in Everywhere UI | `OpenClickyConnectorSettings.swift:88-90` `runtimeStatus`, `providerCount`, `lastError`; `OpenClickyConnectorSubprocess.swift:96-100` published values | none | **B** — Storage-without-UI. |
| 20 | Connector Node subprocess port | Everywhere in-process, N/A | `OpenClickyConnectorSubprocess.swift` random `[52000, 53000)` allocation | none | **E** — Not applicable to Everywhere; openclicky auto-allocates. |
| 21 | Connector bearer token | Everywhere N/A (in-process) | `OpenClickyConnectorSubprocess.swift:79` `authToken: String = UUID().uuidString` regenerated per launch; sent as `Authorization: Bearer` on every RPC to the subprocess | none — token is process-internal, never surfaced | **E** — Openclicky implementation detail (subprocess RPC auth), no user-facing knob needed. |
| 22 | Connector run log inspect | none | `OpenClickyConnectorBridgeTools.swift` — `run_log` write API not present; no local RunLogStore mirror. Note Everywhere has `RunLogStore.cs` but no user surface either. | none | **E** — Both lack UI. Symmetric. |
| 23 | Chat bus subscribers view | none in Everywhere | `OpenClickyChatBridgeTools.swift:1-28` shim delegating to `Packages/OpenClickyContextService/.../Chat/OpenClickyChatBusTools.swift`; tools `chat_send`, `chat_subscribe` registered in `OpenClickyExternalControlBridge.swift:1793-1795, 3042-3044` | none | **E** — Symmetric. Both are MCP-tool-only. |
| 24 | Chat bus queue inspect / clear | none in Everywhere | none | none | **E** — Symmetric. |
| 25 | Web search provider selector | `WebSearchEnginePluginSettings.cs:354` (10 providers), `WebSearchEnginePage.axaml` | `OpenClickyWebSearchClient.swift:27-54` — hard-coded to throw `providerNotConfigured` (`:49-53`). No provider registry, no selector. | none — no page, no picker | **C** — Feature gap. Openclicky's `web_search` MCP tool returns `{ok:false, code:"search_provider_not_configured"}` at `OpenClickyWebBridgeTools.swift:106-108`. Comment at `OpenClickyWebSearchClient.swift:8-19` explicitly acknowledges Everywhere routes through user-configurable providers and openclicky "has no equivalent user-facing search-provider settings surface". Aligns with the task brief's note ("openclicky returns not_configured — Everywhere has actual provider selection?"). |
| 26 | Web search per-provider endpoint | `ThirdPartyWebSearchEngineProvider.EndPoint` at `WebSearchEnginePluginSettings.cs:156, 240, 295, 342` (Customizable) | none | none | **C** — Depends on #25. |
| 27 | Web search per-provider API keys | `WebSearchEnginePluginSettings.cs:171, 250, 303` (`ObservableCollection<ApiKey>` + `ApiKeyListEditor`) | none | none | **C** — Depends on #25. |
| 28 | Web search Google SearchEngineId | `WebSearchEnginePluginSettings.cs:199` | none | none | **C** — Depends on #25. |
| 29 | Official provider Depth / Topic / TimeRange | `WebSearchEnginePluginSettings.cs:47-65` | none | none | **C** — Depends on #25. Openclicky has no equivalent "official" free-lane search provider yet. |
| 30 | Web fetch config | Everywhere uses same provider registry; `WebSearchTool.cs` handles both | `OpenClickyWebFetchClient.swift` (10.4 KB) exists; not user-configurable | none | **C** — Fetch works (raw HTTP), no config surface. Acceptable minimum. |
| 31 | Adapter authoring workspace UI (draft / publish / verify) | none in Everywhere (MCP-only) | `OpenClickyAdapterAuthoringBridgeTools.swift:37-40` documents storage `~/Library/Application Support/OpenClicky/adapters/<site>/<name>.js` but every tool returns `NOT_IMPLEMENTED` (`:269, :86, :118, :425` etc) | none | **E** — Symmetric absence, plus openclicky's backing services aren't wired (see `:20-31, :269`). |
| 32 | Capture template workspace UI | none in Everywhere | `OpenClickyCaptureAuthoringBridgeTools.swift:181, 228-266` — all four Everywhere-parity `capture_*` return `NOT_IMPLEMENTED`; openclicky-extension five (`capture_draft, capture_publish, capture_list, capture_delete, capture_run`) added at `OpenClickyExternalControlBridge.swift:3072-3081` | none | **E** — Symmetric. Both MCP-only. |
| 33 | Chrome bridge server status | Everywhere N/A | `HeyClickyChromeBridgeServer.swift:23-24, activePort, isRunning, isExtensionAlive` | Section `OpenClickyChromeBridgeSettingsSection.swift:23` EXISTS with server + extension + refresh + about rows, but grep confirms **zero call sites** in the shipping app (only in this section file itself and the docs). Notch panel does render this at `OpenClickyNotchPanelView.swift:407-425` "Chrome Bridge" row. | **B** — Section view unreachable from Settings; notch panel has a status row. Same pattern as #3 / OpenDia section. |
| 34 | Chrome bridge port (3011) | Everywhere N/A | `HeyClickyChromeBridgeServer.swift:23` (port referenced at `OpenClickyChromeBridgeSettingsSection.swift:8`) — hard-coded 3011 in the server + comment | none — port is not configurable in either | **D+partial** — Openclicky-only feature; readout visible in notch but not editable. |
| 35 | Chrome bridge extension install helper | Everywhere N/A | `OpenClickyChromeBridgeSettingsSection.swift:106-119` — "load the extension in Chrome from `~/Dev/opendia/opendia-extension/dist/chrome/` (via chrome://extensions/, Load unpacked)" — inside the unreachable section | none reachable | **B** — Openclicky-extra copy, unreachable. |
| 36 | External-control bridge bearer token | Everywhere N/A (loopback listener, no auth on `/mcp`) | `AppBundleConfiguration.swift:76, 206-208` defaults key `openClickyExternalControlBridgeToken`, backing storage in UserDefaults + string keychain fallback; used by `OpenClickyExternalControlBridge.swift:346, 699, 711` (bridge auth) and by `ClickyCodexConfigTemplate.swift:19, 214, 243, 369` (Codex spawn via `bearer_token_env_var = "OPENCLICKY_BRIDGE_TOKEN"`) | none — grep of the settings window and notch panel returns zero for `externalControlBridgeToken` | **D+B** — Openclicky-extra concept (Everywhere doesn't need it), storage present with keychain fallback, but no UI to see / rotate / paste the token. F27 review Issue 3 fix routes it via env var but leaves the user unable to inspect or rotate from the app. |
| 37 | "Regenerate bridge token" | Everywhere N/A | none — grep for `regenerate`, `rotate.*token` in openclicky UI returns 0 hits | none | **B/C** — Feature gap for the token lifecycle. |
| 38 | "Test bridge connection" | Everywhere N/A | none | none | **C** — No self-test button for the sensor bridge. |
| 39 | Codex config path readout (target for MCP block writes) | Everywhere N/A | `CodexHomeManager.codexHomeDirectory.appendingPathComponent("config.toml")` | Yes — `OpenClickySettingsWindowManager.swift:2140-2143` "Codex config" row with `openPath` under System & Logs → MCP servers group. | **A+extra** — Openclicky covers what Everywhere doesn't need. |
| 40 | MCP servers group in Settings | `[SettingsItem]` auto-generation on `McpServerSettings.cs` | `OpenClickySettingsWindowManager.swift:2084-2151` `settingsGroup("MCP servers")` — but its rows expose OpenAI developer docs, GitHub connected-app, computer-use MCP, cua-driver command, Codex config path, sync status. **Not** OpenDia / OpenCLI / open-connector / chat / web / adapter / capture. | See same file, same lines. | **B** — The group exists and is discoverable, but its contents are the *legacy* Codex-side MCP servers (developer docs, Composio, cua-driver). None of the F29 / F30 / F31 / F32 / F33 / F34 / F35 / F36 subsystems has a row here. Adding one row per subsystem (or embedding the two written but unused section views) would close #3, #9, #13, #33 simultaneously. |
| 41 | KnownApps discovery URLs (agent-skills endpoint list) | `McpServerSettings.cs:109` (SettingsItemIgnore, no auto UI) | `OpenClickyContextAwarenessSettings.swift:196, 260-265` (see domain 1 report row 20) | none | **B** — Documented in domain 1; called out again because it is the user's only avenue to teach the writer new local apps, and openclicky lacks a `settings.json` fallback. Not double-counted for the domain 2 gap total. |

## Gap priority ordering

### CRITICAL wire gaps (storage exists, UI missing, user cannot reach)

- **Row 3 — OpenDia master toggle**. Section view is written (`OpenClickyOpenDiaSettingsSection.swift`), the settings singleton is real (`OpenClickyOpenDiaSettings.shared`), but the section is never instantiated. Zero grep hits for `OpenClickyOpenDiaSettingsSection(` outside the definition. Fastest fix: embed the section inside `OpenClickySettingsWindowManager.swift`'s `settingsGroup("MCP servers")` block at `:2084-2151`. Duplicates F31 review Issue 1.
- **Row 9 — OpenCLI master toggle**. `OpenClickyOpenCLISettings` has no section view at all; the settings class publishes `runtimeStatus / siteCount / adapterCount / lastError` that nothing consumes. Users cannot disable the F30 subprocess without env var.
- **Row 13 — Connector master toggle** (+ Node path override, allowlists, callback URL, status). Same story: `OpenClickyConnectorSettings` is fully wired to storage and to the subprocess but has no consumer view. This one is the most impactful because the connector subprocess spawns a V8 isolate on start.
- **Row 33 — Chrome bridge status section unreachable** (parallel to Row 3). Notch panel does surface the state, so partial mitigation.
- **Row 36 — Bridge bearer token invisible**. Users cannot inspect or rotate the token from the app; env var override happens but there is no UI to see what the current token is or to trigger a rotation.

### HIGH feature gaps

- **Row 2 — Bridge HTTP port**. Only editable via `OPENCLICKY_MCP_PORT`. Everywhere users have `HttpPort` on the auto-generated Settings page. Consider a `TextField` bound to a UserDefaults key that the bridge reads at start (currently only env is read at `OpenClickyExternalControlBridge.swift:162`).
- **Row 25 / 26 / 27 / 28 / 29 — Web search provider selection**. Openclicky has zero equivalent. `web_search` MCP tool returns `not_configured`. This is a first-class parity gap called out in the task brief. Options: (a) implement one of Everywhere's 10 providers with the same `EndPoint + ApiKey` shape, (b) route through HeyClicky msgs free lane per the client's own TODO comment, (c) delete the tool from the sensor set. Recommendation: (a) with just Tavily + SearXNG as MVP.
- **Row 17 — Connector connections list**. No visibility into which providers a user has authenticated with. Add a native list bound to `connector_list_connections`.

### MEDIUM feature gaps

- **Row 37 — Regenerate bridge token** button. Sensible affordance once #36's readout lands.
- **Row 38 — Test bridge connection** button. Mirrors the OpenDia "Test connection" that already exists (unreachably) in row 7.
- **Row 4 — OpenDia port pinning**. Random `[56000, 57000)` allocation is fine for most users but blocks firewall / proxy setups.
- **Row 8 / 14 — Node path override editors**. Both `OpenClickyOpenDiaSettings.nodePathOverride` and `OpenClickyConnectorSettings.nodePathOverride` are `String?` fields already; needs a text field + validate-file-exists.
- **Row 41 — KnownApps editor**. Recounted from domain 1; keep tracking in domain 1.

### LOW / documented drops

- Rows 22 / 23 / 24 / 31 / 32 (run log / chat subscribers / adapter workspace / capture workspace UIs). Everywhere doesn't ship them either — both are MCP-tool-only surfaces. Symmetric absence; no action.
- Row 5 (OpenDia extension install helper). Copy exists in the unreachable section; will land when #3 lands.
- Row 10 / 20 (OpenCLI / connector port). Openclicky auto-allocates; different design; documented.

### Openclicky extras (verify intentional)

- **Row 6 — Notch panel "Browser (OpenDia)" and "Chrome Bridge" status rows** (`OpenClickyNotchPanelView.swift:387-426`). Nice-to-have status readouts absent from Everywhere. Keep.
- **Row 39 — Codex config file readout under MCP servers group** (`OpenClickySettingsWindowManager.swift:2140-2143`). Openclicky-specific because Everywhere doesn't write to a separate Codex config; keep.
- **Row 15 / 16 — Runtime provider allowlist / disallowlist**. Everywhere only has a bundle-time allowlist; runtime lists are an openclicky extra. Storage present, needs UI (see gap section).

## Notes on the "two settings section" phenomenon

Two SwiftUI section views (`OpenClickyOpenDiaSettingsSection`,
`OpenClickyChromeBridgeSettingsSection`) live in the source tree but
no `View.body` in the shipping app instantiates them. They are also
NOT registered in `cursor-buddy.xcodeproj/project.pbxproj` beyond
compilation (`grep OpenClickyOpenDiaSettingsSection cursor-buddy.xcodeproj/project.pbxproj`
returns 0). That is: they compile, they type-check (per `.impl-notes/f31-opendia-fix-report-2026-07-23.md:200`),
they never render. This is the "wired to storage, not wired to UI"
pattern flagged three times in this table (#3, #33, and implicitly #7).

## Files inspected

Everywhere (baseline)
- `src/Everywhere.Core/Configuration/Settings/McpServerSettings.cs`
- `src/Everywhere.Core/Configuration/Settings/WebSearchEnginePluginSettings.cs`
- `src/Everywhere.Mcp/EverywhereMcpServiceExtensions.cs`
- `src/Everywhere.Mcp/Transport/EverywhereMcpHttpHost.cs` (referenced)
- `src/Everywhere.Mcp/OpenDia/OpenDiaBridge.cs`, `OpenDiaChatBus.cs`, `OpenDiaBridgeInitializer.cs`
- `src/Everywhere.Mcp/OpenCli/OpenCliRuntime.cs`
- `src/Everywhere.Mcp/Connector/{ConnectorRuntime,JsonCredentialStore,OAuthFlowService,RunLogStore,TransitFileStore}.cs`
- `src/Everywhere.Mcp/Tools/{OpenCliTools,ConnectorTools,ChatBusTools,WebSearchTool,CaptureTools,GeneratorTools,GateTools}.cs`
- `src/Everywhere.Core/Views/Pages/WebSearchEnginePage.axaml`
- `docs/specs/everywhere-connector.md`
- `docs/specs/opendia-cebian-merge.md`
- `~/Library/Application Support/Everywhere/settings.json` (user's live McpServer block)

Openclicky
- `cursor-buddy/OpenClickyOpenDiaSettings.swift`, `OpenClickyOpenDiaSettingsSection.swift`, `OpenClickyOpenDiaSubprocess.swift`, `OpenClickyOpenDiaBridgeTools.swift`
- `cursor-buddy/OpenClickyOpenCLISettings.swift`, `OpenClickyOpenCLISubprocess.swift`
- `cursor-buddy/OpenClickyConnectorSettings.swift`, `OpenClickyConnectorSubprocess.swift`, `OpenClickyConnectorBridgeTools.swift`, `OpenClickyConnectorOAuthCallback.swift`, `OpenClickyConnectorCredentialStore.swift`
- `cursor-buddy/OpenClickyChatBridgeTools.swift`
- `cursor-buddy/OpenClickyWebBridgeTools.swift`, `OpenClickyWebSearchClient.swift`, `OpenClickyWebFetchClient.swift`
- `cursor-buddy/OpenClickyAdapterAuthoringBridgeTools.swift`
- `cursor-buddy/OpenClickyCaptureAuthoringBridgeTools.swift`
- `cursor-buddy/OpenClickyPageBridgeTools.swift`
- `cursor-buddy/HeyClickyChromeBridgeServer.swift`, `OpenClickyChromeBridgeSettingsSection.swift`
- `cursor-buddy/OpenClickyExternalControlBridge.swift`
- `cursor-buddy/ClickyCodexConfigTemplate.swift`
- `cursor-buddy/AppBundleConfiguration.swift`
- `cursor-buddy/OpenClickySettingsWindowManager.swift`
- `cursor-buddy/OpenClickyNotchPanelView.swift`
- `cursor-buddy/OpenClickyNotchPanelView+Sections.swift`
- `cursor-buddy/cursor_buddyApp.swift`

Grep sweeps
- `OpenClickyOpenDiaSettingsSection\(` — zero matches outside the definition file.
- `OpenClickyChromeBridgeSettingsSection\(` — zero matches outside the definition file.
- `OpenClickyOpenCLISettings.shared` — one match (self, `:85`); no view reads it.
- `OpenClickyConnectorSettings.shared` — two matches (`cursor_buddyApp.swift:134` autostart, `OpenClickyConnectorSubprocess.swift:364` node path); no view reads it.
- `externalControlBridgeToken` in settings window / notch panel — zero matches.

No code modified. Read-only audit.
