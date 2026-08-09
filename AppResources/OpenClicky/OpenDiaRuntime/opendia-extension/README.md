# OpenDia extension — install instructions

The Chrome / Firefox extension for OpenDia is not bundled inside the
OpenClicky .app because:

- The upstream source tree (`opendia-extension/`) is ~500 MB with
  `node_modules/` present, and building it requires `wxt` + a full
  npm install.
- Upstream already ships a signed pre-built extension zip (~11 MB) per
  browser, which is a strictly smaller install than a source-based
  build.

## Install steps (Chrome / Chromium / Edge / Brave)

1. Enable **OpenDia** in OpenClicky Settings ("Browser control").
   OpenClicky spawns the Node WS server and exposes it on a random port
   in `[56000, 57000)`.
2. Download the latest Chrome zip from the upstream release page:
   https://github.com/aaronjmars/opendia/releases
   Pick `opendia-chrome-<version>.zip`.
3. Unzip somewhere stable (e.g. `~/Applications/opendia-extension`).
4. Open `chrome://extensions/`, toggle **Developer mode**, click **Load
   unpacked**, and select the unzipped folder.
5. The extension will discover the local WS server automatically. If it
   asks for a port, enter the port shown in OpenClicky Settings.

## Install steps (Firefox)

1. Enable **OpenDia** in OpenClicky Settings.
2. Download `opendia-firefox-<version>.zip` from the upstream release
   page above.
3. `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on** →
   pick the zip's `manifest.json`.

## Verifying the connection

- OpenClicky Settings → "Browser control" panel shows
  `Extension: connected` once the WS handshake completes.
- Or curl the local bridge:
  ```
  curl -s http://127.0.0.1:<port>/health
  # {"ok":true,"extension_connected":true,"available_tools":N,...}
  ```
- Or, from any MCP client wired to `/mcp/sensor`:
  1. `activate_domain name=browser`
  2. `browser_get_url` — returns the current tab URL.

## Uninstalling

Remove the extension from `chrome://extensions/` (or Firefox
`about:addons`) and delete the unzipped folder. Toggle OpenDia off in
OpenClicky Settings.
