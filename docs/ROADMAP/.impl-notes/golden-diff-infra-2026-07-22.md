# Golden Diff Infrastructure — 2026-07-22

Phase 0 prerequisite for openclicky's port of Everywhere's context
stash / sensor tools. All work lives under
`/Users/wowdd1/Dev/openclicky/scripts/golden-diff/`.

## Files created

| Path | Purpose |
|------|---------|
| `scripts/golden-diff/README.md` | Fresh setup, day-to-day, when-tests-fail. |
| `scripts/golden-diff/setup-fixture.sh` | Bash + osascript, 5 fixtures (`finder-empty-folder`, `finder-pdf-selected`, `safari-url`, `terminal-scrollback`, `browser-tabs`). |
| `scripts/golden-diff/capture-everywhere.sh` | Fires hotkey via `osascript`, waits on mtime change on `~/Library/Application Support/Everywhere/context-stash.json`, copies to `fixtures/<id>-everywhere.json`. |
| `scripts/golden-diff/capture-openclicky.sh` | Same shape for openclicky; skeleton with TODO markers because Layer 3 does not yet exist. |
| `scripts/golden-diff/diff-fixture.py` | Stdlib-only structural diff: parses envelope lines and JSON body, normalises brand-prefix + `captured_at_utc` + `process_id` + `pid`, reports one issue per line. Exit 0 pass / 1 fail. |
| `scripts/golden-diff/run-all.sh` | Loops `fixtures/manifest.txt`, aggregates pass/fail. |
| `scripts/golden-diff/fixtures/manifest.txt` | The five fixture IDs. |
| `scripts/golden-diff/hotkeys.env.example` | Template config; `EVERYWHERE_SNAPSHOT_KEY` defaults to `shift+space` (matches user's Everywhere settings.json). |
| `scripts/golden-diff/.gitignore` | Ignores `fixtures/*.json` and `hotkeys.env`. |

All shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
Everything is `chmod +x`.

## Deviations from spec

- **Hotkey shorthand parser.** Spec suggested reading Everywhere's
  hotkey directly from `settings.json`. Everywhere stores it as
  `{Key:"Space", Modifiers:"Shift"}`, which is a separate parse job
  from the human-friendly `shift+space` shorthand the user writes in
  `hotkeys.env`. I implemented the shorthand parser only because the
  user must configure `hotkeys.env` anyway for openclicky, and mixing
  two parsers doubles the failure surface. README documents that the
  default matches the user's current binding.
- **osascript key codes for `space`/`return`/`tab`/`escape`.**
  `keystroke " "` is layout-sensitive and unreliable, so I used
  `key code 49/36/48/53`. Other keys go through `keystroke` as spec'd.
- **Sample PDF for `finder-pdf-selected`.** Rather than relying on a
  hardcoded system PDF path that may or may not exist, the fixture
  writes a 4-object blank PDF inline the first time it runs. Idempotent.

## Known gaps (TODO after Layer 3 exists)

- `capture-openclicky.sh` currently exits with a clear TODO error
  because openclicky has no stash writer. The process check even
  probes for both `OpenClicky` and `cursor-buddy` (legacy binary name)
  — pick one when Phase 6 lands.
- The diff script assumes openclicky will use `openclicky-*` bracket
  prefixes symmetric to Everywhere. If a different prefix is chosen,
  update `rebrand()` in `diff-fixture.py`.
- Fixtures are US-keyboard, English UI. International layouts may
  need per-fixture overrides.
- `terminal-scrollback` targets Apple Terminal.app. iTerm2 users must
  edit that branch.
- No fixture yet for whiteboard-pending / pin_pending / annotations /
  picked_links / hint-vs-discover branches. Add once the openclicky
  writer covers those code paths so the golden diff can lock in
  parity.

## Sample fixture output (synthetic diff format)

Verified with a synthetic pair. When the header title differs, the
openclicky side is missing links, the hint line is missing, and the
JSON has an extra field, the report is:

```
header: value diff field=title everywhere='Downloads' openclicky='Different'
links: line count diff everywhere=1 openclicky=0
hint: presence diff everywhere=True openclicky=False
json extra_field: extra in openclicky: 'x'
json window_title: value diff everywhere='Downloads' openclicky='Different'
FAIL: 5 issue(s) for fixture smoketest
```

A clean match prints:

```
PASS: fixture smoketest matches
```

The runner in a fix loop only needs to check exit code (0/1) and can
parse the first token of each issue line to categorise problems
(`header`, `links`, `annotations`, `hint`, `discover`, `json`).

## Verification performed

- `bash -n` on all four shell scripts: clean.
- `python3 -c "import ast; ast.parse(...)"` on the diff script: clean.
- `python3 diff-fixture.py --help`: prints usage.
- Synthetic PASS + FAIL fixtures run end-to-end with correct exit
  codes and expected issue enumeration.
- `chmod +x` verified via `ls -la` on all four executables.

Not run (would activate Finder / Safari / Terminal and touch the
user's foreground state):

- `setup-fixture.sh` against a real fixture.
- `capture-everywhere.sh` end-to-end (would fire the user's
  Shift-Space binding).
