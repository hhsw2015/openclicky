# chrome-ext merge into OpenDia — 2026-07-23

Ported the standalone `openclicky/chrome-ext/background.js` (268 lines JS)
into the local OpenDia extension as a TypeScript side-effect module. The
HTTP contract with `HeyClickyChromeBridgeServer` (port range 3011..3021,
`/health`, `GET /cmd`, `POST /event`) is preserved byte-for-byte.

## Numbers

- Original: `openclicky/chrome-ext/background.js` — 268 lines (JS).
- Ported:   `opendia/opendia-extension/entrypoints/background/openclicky-reset.ts` — 455 lines (TS, typed + JSDoc-style comments).

Line growth is entirely TypeScript interfaces (`BridgeCommand`,
`GrabCommand`, `ClickCommand`, `OpenTabCommand`, `CloseTabCommand`, return
shapes for injected functions) and matching whitespace. No behavior added
or removed.

## Behavior preserved

- Port walk `3011..3021` with `chrome.storage.local.bridgePort` cache.
- Long-poll `GET /cmd` (25 s server-side hold; extension awaits fetch).
- `POST /event` for extension -> app frames.
- `chrome.alarms` keepalive `bridge-keepalive` at 0.5 min.
- 3 consecutive `/cmd` failures -> clear cached port, re-walk range.
- `hello` event on `startPolling`.
- Command dispatch: `ping`, `list-tabs`, `open-tab`, `close-tab`, `grab-page`, `click`.
- `webNavigation.onCommitted` -> `tab-navigated` event.
- Injected `dumpPageStructure` / `clickBySelector` — same selectors, same
  return shape (`page-snapshot` / `click-result` payloads unchanged).

Renamed the alarm to `openclicky-reset-keepalive` to avoid colliding with
any OpenDia alarm named `bridge-keepalive`; storage key stays
`bridgePort` (per §8 spec, HeyClicky bridge continues to read/write it).

## Register point

`opendia/opendia-extension/entrypoints/background/index.ts` line 22:

```
import './openclicky-reset';
```

Positioned immediately after `import './opendia-cebian-article-adapter';`
matching the existing side-effect-import pattern for background modules.

## Typecheck

```
cd /Users/wowdd1/Dev/opendia/opendia-extension
npx tsc --noEmit
# -> TypeScript: No errors found
```

## Deletion

```
rm -rf /Users/wowdd1/Dev/openclicky/chrome-ext/
# -> confirmed gone
```

## User impact

Users now install only the OpenDia extension (`opendia-extension`); there
is no separate `openclicky/chrome-ext/` reset-auto extension to load. The
Swift-side `HeyClickyChromeBridgeServer` HTTP endpoint is untouched — same
port range, same `/cmd` + `/event` verbs, same JSON payloads. No changes
to `AppBundleConfiguration.swift`, Xcode project, or any Swift file.
