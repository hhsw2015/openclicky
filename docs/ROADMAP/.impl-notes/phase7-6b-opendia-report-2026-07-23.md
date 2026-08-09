# Phase 7.6b F31 — OpenDia integration report

- Date: 2026-07-23
- Everywhere upstream pin: `30e03e9dcfdd4247fd679828ed86e9042f32d809`
- OpenDia upstream pin (MIT, `aaronjmars/opendia`): `304345754cc99b24c07a3289a2e27abd5a5c19bb`
- Parity matrix used: `Everywhere/docs/specs/PARITY_MATRIX.md`
  (parity-matrix.json sha `ed2e10598c9064aecfaeb7cf21b540684db4be2c`)

## Files created

- `AppResources/OpenClicky/OpenDiaRuntime/boot.js` — HTTP + WS boot entry (`node --check` passes; smoke tested).
- `AppResources/OpenClicky/OpenDiaRuntime/README.md`
- `AppResources/OpenClicky/OpenDiaRuntime/UPSTREAM_SHA`
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/server.js` (upstream MIT, unmodified)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/package.json` (upstream)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/LICENSE` (MIT)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-mcp/node_modules/` (installed via `npm install --omit=dev`; `ws@^8.18.0` + transitive)
- `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md` — sideload install pointer to upstream release zips.
- `cursor-buddy/OpenClickyOpenDiaSubprocess.swift`
- `cursor-buddy/OpenClickyOpenDiaBridgeTools.swift`
- `cursor-buddy/OpenClickyOpenDiaSettings.swift`
- `docs/ROADMAP/.impl-notes/phase7-6b-opendia-2026-07-23.md`
- `docs/ROADMAP/.impl-notes/phase7-6b-opendia-report-2026-07-23.md` (this file)

## Files modified

- `cursor-buddy/OpenClickyExternalControlBridge.swift` — 4 extension points:
  1. Renamed literal to `sensorToolNamesBase`; `sensorToolNames` is now
     `sensorToolNamesBase.union(OpenClickyOpenDiaBridgeTools.toolNames)`.
  2. Renamed literal to `sensorToolDomainsBase`; `sensorToolDomains` is
     now a computed static that copies base then adds one row per
     browser_* tool mapped to `OpenClickyMetaDomain.browser`.
  3. Descriptor emit appends `OpenClickyOpenDiaBridgeTools.descriptorsRaw`
     after the F30 opencli descriptors.
  4. `executeSensorTool` default branch prefix-matches `browser_*` and
     dispatches to `OpenClickyOpenDiaBridgeTools.execute`.
- `cursor-buddy/cursor_buddyApp.swift` — autostart + shutdown call sites.
- `docs/ROADMAP/09_MIGRATION_ORDER.md` — Phase 7.6b OpenDia section replaced with landing checklist.
- `docs/ROADMAP/11_REVIEW_CHECKLIST.md` — F31 section replaced with landed-files list.
- `cursor-buddy.xcodeproj/project.pbxproj` — appended `OpenDiaRuntime` to the "Copy OpenClicky App Resources" ditto script.

## Tool list (120 verbatim from PARITY_MATRIX.md, ownership=opendia OR universal)

```
browser_auth_delete            browser_auth_list             browser_auth_login
browser_auth_save              browser_auth_show             browser_back
browser_batch                  browser_check                 browser_click
browser_close                  browser_confirm               browser_console
browser_cookies_clear          browser_cookies_get           browser_cookies_set
browser_cookies_set_curl       browser_dblclick              browser_deny
browser_device                 browser_dialog_accept         browser_dialog_dismiss
browser_dialog_status          browser_diff_screenshot       browser_diff_snapshot
browser_diff_url               browser_download              browser_drag
browser_errors                 browser_eval                  browser_fill
browser_find                   browser_focus                 browser_forward
browser_frame_main             browser_frame_switch          browser_get_attr
browser_get_box                browser_get_cdp_url           browser_get_count
browser_get_html               browser_get_styles            browser_get_text
browser_get_title              browser_get_url               browser_get_value
browser_highlight              browser_hover                 browser_inspect
browser_is_checked             browser_is_enabled            browser_is_visible
browser_keyboard_insert_text   browser_keyboard_type         browser_keydown
browser_keyup                  browser_mouse_down            browser_mouse_move
browser_mouse_up               browser_mouse_wheel           browser_network_har_start
browser_network_har_stop       browser_network_request       browser_network_requests
browser_network_route          browser_network_unroute       browser_open
browser_pdf                    browser_press                 browser_profiler_start
browser_profiler_stop          browser_pushstate             browser_react_inspect
browser_react_renders_start    browser_react_renders_stop    browser_react_suspense
browser_react_tree             browser_read                  browser_reload
browser_remove_init_script     browser_screenshot            browser_scroll
browser_scroll_into_view       browser_select                browser_set_credentials
browser_set_geo                browser_set_headers           browser_set_media
browser_set_offline            browser_set_viewport          browser_snapshot
browser_state_clean            browser_state_clear           browser_state_list
browser_state_load             browser_state_rename          browser_state_save
browser_state_show             browser_storage_clear         browser_storage_get
browser_storage_set            browser_swipe                 browser_tab_close
browser_tab_list               browser_tab_new               browser_tab_switch
browser_tap                    browser_trace_start           browser_trace_stop
browser_type                   browser_uncheck               browser_upload
browser_vitals                 browser_wait_for_download     browser_wait_for_function
browser_wait_for_load          browser_wait_for_selector     browser_wait_for_text
browser_wait_for_url           browser_wait_ms               browser_window_new
```

## Rationale: 120 not 85

Task brief mentions "85 WS ops". PARITY_MATRIX.md at Everywhere pin
`30e03e9d…` shows 120 `browser_*` tools with ownership `opendia` (105)
or `universal` (15). The "85" number aligns to a smaller subset (likely
opendia-only minus the value-add + niche tools, or an older snapshot of
the fork). Registering all 120 matches the current parity matrix — the
extension itself decides which subset it implements, and unregistered
tools return `{ok:false, code:"UNKNOWN_TOOL"}`. This zero-drift approach
is documented in `docs/ROADMAP/11_REVIEW_CHECKLIST.md` F31.

## LICENSE decision

Vendored `aaronjmars/opendia` (MIT) rather than the Everywhere fork
`hhsw2015/opendia experiment/replace-ab`:

- MIT permits verbatim redistribution.
- Everywhere fork is not present on the local filesystem — cannot vendor
  what we cannot read.
- The tool *surface* (protocol shape + tool names) is authoritative in
  `PARITY_MATRIX.md`, not in a specific fork's runtime.
- Users can freely swap in the Everywhere-fork extension at load-time —
  the WS protocol is the same, we just register more tool names than the
  MIT upstream extension implements.

## Extension install (manual, one-time)

See `AppResources/OpenClicky/OpenDiaRuntime/opendia-extension/README.md`:

1. Enable OpenDia in OpenClicky Settings (fires `boot.js`).
2. Download `opendia-chrome-<v>.zip` from
   https://github.com/aaronjmars/opendia/releases and unzip.
3. `chrome://extensions/` → Developer mode → Load unpacked → pick the
   folder.
4. Extension auto-discovers the local WS port; if it asks, paste the
   port shown in OpenClicky Settings.

We intentionally do NOT bundle the 500 MB extension source tree.

## Test recipe

### Node boot.js smoke (executed)

```
cd AppResources/OpenClicky/OpenDiaRuntime
OPENCLICKY_OPENDIA_TOKEN=testtoken node boot.js
# Prints: READY 56xxx
```

Curl results (captured during implementation):

```
$ curl -s http://127.0.0.1:56982/health
{"ok":true,"extension_connected":false,"available_tools":0,"upstream_sha":"304345754cc99b24c07a3289a2e27abd5a5c19bb"}

$ curl -s http://127.0.0.1:56982/tools
{"ok":false,"error":"unauthorized"}

$ curl -s -H "Authorization: Bearer testtoken" http://127.0.0.1:56982/tools
{"ok":true,"extension_connected":false,"tools":[]}

$ curl -s -H "Authorization: Bearer testtoken" -H "Content-Type: application/json" \
     -d '{"name":"browser_get_url","arguments":{}}' \
     http://127.0.0.1:56982/call
{"ok":false,"code":"BROWSER_NOT_READY","error":"OpenDia browser extension not connected. Install the extension in Chrome/Firefox — see AppResources/OpenClicky/OpenDiaRuntime/README.md."}
```

### Swift parse check (executed)

```
$ swiftc -parse cursor-buddy/OpenClickyOpenDia*.swift \
    cursor-buddy/cursor_buddyApp.swift \
    cursor-buddy/OpenClickyExternalControlBridge.swift
(no output — clean parse)
```

### End-to-end (requires user action)

1. Xcode build.
2. Toggle OpenDia in Settings → subprocess boots → status "running on
   port 56xxx, ext not connected".
3. Sideload extension per README → status flips to "ext connected".
4. MCP `POST /mcp/sensor` with `activate_domain name=browser`, then
   `tools/list` — 120 `browser_*` tools visible.
5. `tools/call browser_get_url` → returns current Chrome tab URL.

Step 5 needs a browser extension physically installed in the tester's
Chrome/Firefox, so it's a manual verification per the task brief
("If extension install is manual, document + skip live test").

## Known limitations

- The MIT upstream extension implements ~24 top-level tools. Any of the
  120 registered names not in that subset returns `{ok:false,
  code:"UNKNOWN_TOOL"}` (or the extension's own error shape). Users who
  want full 120-tool coverage should install the Everywhere-fork
  extension when it becomes generally available.
- `browser_read` is registered but marked `blocked` upstream — will
  always error.
- First launch requires `npm install --omit=dev` inside
  `opendia-mcp/`. Automating that with a Swift-side "Install
  dependencies" button is deferred to a follow-up (Settings pane hint
  is in the README).
- No first-launch UI prompt for extension install yet. The README + a
  Settings hint are the only entry points. A "Reveal extension folder"
  + "Open chrome://extensions" pair of buttons would be a small
  follow-up.
- WS server accepts any client — no per-extension auth handshake. This
  matches Everywhere upstream (`OpenDiaBridge.cs` binds
  `127.0.0.1:5555` open) and is safe on loopback.
