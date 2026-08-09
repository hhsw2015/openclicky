# Golden Diff Infrastructure

Automated behavioural parity tests for openclicky's port of Everywhere's
`SnapshotContext` stash hook. Phase 0 prerequisite for the port.

The runner sets up a known macOS UI state (a *fixture*), triggers each
app's snapshot hotkey, captures the resulting `context-stash.json`, and
structurally diffs the two files after normalising away pid /
timestamp / brand-prefix differences.

## Prerequisites

1. macOS with `osascript` and `python3` on `PATH` (both ship in the OS).
2. Everywhere.app installed, running, and permitted for Accessibility +
   Screen Recording. Its `SnapshotContext` hotkey must be bound (default
   is `Shift-Space`, see `~/Library/Application Support/Everywhere/settings.json`
   under `Shortcut.SnapshotContext.Main`).
3. openclicky built and running (only required for the openclicky
   capture path; see "Known gaps" below).
4. Copy `hotkeys.env.example` to `hotkeys.env` and adjust to match the
   hotkeys you actually bound.

```sh
cp scripts/golden-diff/hotkeys.env.example scripts/golden-diff/hotkeys.env
```

## Fresh setup (once)

```sh
cd /Users/wowdd1/Dev/openclicky
cp scripts/golden-diff/hotkeys.env.example scripts/golden-diff/hotkeys.env
# edit hotkeys.env if defaults do not match your bindings
open -a Everywhere    # or launch from Finder / Xcode
```

Verify Everywhere's stash writes correctly by running:

```sh
scripts/golden-diff/capture-everywhere.sh finder-empty-folder
ls scripts/golden-diff/fixtures/
```

## Day-to-day usage

Run the full suite:

```sh
scripts/golden-diff/run-all.sh
```

Or a single fixture:

```sh
scripts/golden-diff/setup-fixture.sh safari-url
scripts/golden-diff/capture-everywhere.sh safari-url
scripts/golden-diff/capture-openclicky.sh safari-url
python3 scripts/golden-diff/diff-fixture.py safari-url
```

## When tests fail

The diff script prints one line per divergence. Common patterns:

- `missing field X in openclicky`: openclicky's writer did not populate
  a field that Everywhere did. Check `FormatForHook` port for that
  branch.
- `value diff: field=app everywhere=... openclicky=...`: focused app
  detection diverged. Confirm both apps see the same frontmost window.
- `line count diff: [openclicky-ctx-link] 3 vs 0`: link harvest was
  not integrated on one side.

If Everywhere's capture times out, its stash file mtime did not update
within 3s of the keystroke. Check:

- Hotkey binding matches `hotkeys.env`.
- Everywhere.app is actually running (`pgrep -x Everywhere`).
- Accessibility permission for Terminal / iTerm / VSCode (whichever
  runs osascript) is granted so keystrokes reach `System Events`.

## Files

| Path | Purpose |
|------|---------|
| `setup-fixture.sh <id>` | Put macOS UI into a known state |
| `capture-everywhere.sh <id>` | Send hotkey to Everywhere, snapshot stash |
| `capture-openclicky.sh <id>` | Send hotkey to openclicky, snapshot stash |
| `diff-fixture.py <id>` | Structurally diff the two captures |
| `run-all.sh` | Loop over `fixtures/manifest.txt` and report pass/fail |
| `fixtures/manifest.txt` | Fixture IDs, one per line |
| `hotkeys.env.example` | Template config for hotkeys |

Fixture captures (`fixtures/*.json`) are gitignored because their
content is environment-specific (pids, window titles, home paths).

## Known gaps

- `capture-openclicky.sh` is a skeleton with TODO markers because
  openclicky does not yet have Layer 3 (stash hook). Wire it up after
  Phase 6 in `docs/ROADMAP/04_LAYER_3_STASH_HOOK.md` lands.
- Fixtures assume US English keyboard layout for `osascript keystroke`.
  International keyboards may need per-fixture overrides.
- `terminal-scrollback` uses Apple Terminal.app. If you use iTerm2,
  edit the fixture setup to target it.
