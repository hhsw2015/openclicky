# openclicky-context-hook — Claude Code integration

OpenClicky ships a small Swift binary that Claude Code invokes on every
UserPromptSubmit. If a fresh context stash is present, the hook injects it
as background context in your next Claude Code turn.

## Binary location

    /Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook

(Ported from Everywhere's `everywhere-context-hook` Rust binary.)

## Claude Code config

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook"
          }
        ]
      }
    ]
  }
}
```

## What it does

- Reads `~/Library/Application Support/OpenClicky/context-stash.json` if it
  exists and is fresh (<5 min).
- Atomically claims it (rename to `.consumed-<pid>-<nanos>.json`).
- Emits a Claude Code hook JSON response on stdout with the stashed context
  as `additionalContext` and a `systemMessage` prefix
  `"OpenClicky context injected: <summary>"`.
- Silent exit 0 when no fresh stash — routine Enter presses pay near-zero
  overhead.

## Compatibility with Everywhere

The stash file schema and hook envelope are contract-compatible with
Everywhere. Migrating from Everywhere requires only:

1. Change hook command in `~/.claude/settings.json` from
   `everywhere-context-hook` to `openclicky-context-hook`.
2. Uninstall Everywhere (optional).

## Verification

Prime a stash:

    echo '[openclicky-ctx] app=finder title="Home" ...' > \
      "$HOME/Library/Application Support/OpenClicky/context-stash.json"

Run the hook:

    /Applications/OpenClicky.app/Contents/Helpers/openclicky-context-hook

Should print a JSON envelope on stdout. Exit code 0.
