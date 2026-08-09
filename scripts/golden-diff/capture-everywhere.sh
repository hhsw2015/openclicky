#!/usr/bin/env bash
set -euo pipefail

# Usage: capture-everywhere.sh <fixture-id>
#
# Fires Everywhere's SnapshotContext hotkey, waits for the stash file to
# be updated, and copies it into fixtures/<fixture-id>-everywhere.json.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <fixture-id>" >&2
  exit 2
fi

FIXTURE="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STASH="$HOME/Library/Application Support/Everywhere/context-stash.json"
OUT="$SCRIPT_DIR/fixtures/${FIXTURE}-everywhere.json"

if [[ ! -f "$SCRIPT_DIR/hotkeys.env" ]]; then
  echo "error: $SCRIPT_DIR/hotkeys.env is missing" >&2
  echo "hint: cp $SCRIPT_DIR/hotkeys.env.example $SCRIPT_DIR/hotkeys.env" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/hotkeys.env"

if [[ -z "${EVERYWHERE_SNAPSHOT_KEY:-}" ]]; then
  echo "error: EVERYWHERE_SNAPSHOT_KEY not set in hotkeys.env" >&2
  exit 1
fi

# Fixture ↔ hotkey mapping for the runtime-2026-07-23 golden-diff run.
# Fixtures we already had (finder-*, safari-url, terminal-scrollback, browser-tabs)
# all use SnapshotContext, so they fall through to the default.
case "$FIXTURE" in
  snapshotcontext-*)  HOTKEY="${EVERYWHERE_SNAPSHOT_KEY}"    ;;
  pickelement-*)      HOTKEY="${EVERYWHERE_PICKELEMENT_KEY:-alt+s}" ;;
  linkrect-*)         HOTKEY="${EVERYWHERE_LINKRECT_KEY:-alt+l}"    ;;
  whiteboard-*)       HOTKEY="${EVERYWHERE_WHITEBOARD_KEY:-alt+d}"  ;;
  *)                  HOTKEY="${EVERYWHERE_SNAPSHOT_KEY}"    ;;
esac

if ! pgrep -x Everywhere >/dev/null; then
  echo "error: Everywhere.app is not running (pgrep -x Everywhere)" >&2
  exit 1
fi

# Convert "shift+space" style shorthand into an osascript key press.
# Returns two values via globals: _KEYSTROKE_KEY and _KEYSTROKE_MODS.
parse_hotkey() {
  local raw="$1"
  local -a parts
  IFS='+' read -r -a parts <<< "$(echo "$raw" | tr '[:upper:]' '[:lower:]')"
  local mods=()
  local key=""
  for p in "${parts[@]}"; do
    p="${p// /}"
    case "$p" in
      cmd|command)  mods+=("command down") ;;
      ctrl|control) mods+=("control down") ;;
      alt|option)   mods+=("option down")  ;;
      shift)        mods+=("shift down")   ;;
      "")           ;;
      *)            key="$p" ;;
    esac
  done
  if [[ -z "$key" ]]; then
    echo "error: could not parse key from '$raw'" >&2
    return 1
  fi
  _KEYSTROKE_KEY="$key"
  _KEYSTROKE_MODS="$(IFS=,; echo "${mods[*]}")"
}

# Snapshot mtime before we fire so we can detect the update.
prev_mtime=""
if [[ -f "$STASH" ]]; then
  prev_mtime="$(stat -f %m "$STASH")"
fi

parse_hotkey "$HOTKEY"

# Build the AppleScript. Use key code 49 for space and 36 for return so
# we don't depend on keystroke's US-layout key mapping for symbol keys.
build_and_send() {
  local key="$_KEYSTROKE_KEY"
  local mods="$_KEYSTROKE_MODS"
  local script
  case "$key" in
    space)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to key code 49 using {$mods}"
      else
        script="tell application \"System Events\" to key code 49"
      fi
      ;;
    return)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to key code 36 using {$mods}"
      else
        script="tell application \"System Events\" to key code 36"
      fi
      ;;
    tab)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to key code 48 using {$mods}"
      else
        script="tell application \"System Events\" to key code 48"
      fi
      ;;
    escape)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to key code 53 using {$mods}"
      else
        script="tell application \"System Events\" to key code 53"
      fi
      ;;
    *)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to keystroke \"$key\" using {$mods}"
      else
        script="tell application \"System Events\" to keystroke \"$key\""
      fi
      ;;
  esac
  osascript -e "$script"
}

build_and_send

# For picking / dragging fixtures the hotkey enters an interactive mode
# that only commits once the user clicks (PickElement) or drags
# (LinkRect / Whiteboard). Emit the commit gesture with cliclick when
# available; otherwise leave it to a human operator.
commit_gesture() {
  local kind="$1"
  if ! command -v cliclick >/dev/null; then
    return 0
  fi
  case "$kind" in
    pickelement-*)
      cliclick "c:." >/dev/null 2>&1 || true
      ;;
    linkrect-*)
      cliclick "dd:220,300" "dm:900,700" "du:900,700" >/dev/null 2>&1 || true
      ;;
    whiteboard-notes-underline-test)
      cliclick "dd:400,320" "dm:520,320" "du:520,320" >/dev/null 2>&1 || true
      osascript -e "tell application \"System Events\" to key code 2 using {option down}" >/dev/null 2>&1 || true
      ;;
  esac
}

commit_gesture "$FIXTURE"

# Poll for stash update. 3s cap keeps us from hanging when the hotkey
# is bound wrong.
deadline=$((SECONDS + 3))
while (( SECONDS < deadline )); do
  if [[ -f "$STASH" ]]; then
    cur_mtime="$(stat -f %m "$STASH")"
    if [[ "$cur_mtime" != "$prev_mtime" ]]; then
      break
    fi
  fi
  sleep 0.1
done

if [[ ! -f "$STASH" ]]; then
  echo "error: stash never appeared at $STASH" >&2
  exit 1
fi

cur_mtime="$(stat -f %m "$STASH")"
if [[ "$cur_mtime" == "$prev_mtime" ]]; then
  echo "error: stash mtime unchanged after 3s — hotkey may not be bound" >&2
  exit 1
fi

mkdir -p "$SCRIPT_DIR/fixtures"
cp "$STASH" "$OUT"
echo "captured" >&2
