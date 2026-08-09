#!/usr/bin/env bash
set -euo pipefail

# Usage: capture-openclicky.sh <fixture-id>
#
# Fires openclicky's SnapshotContext hotkey and copies the stash to
# fixtures/<fixture-id>-openclicky.json.
#
# TODO(Layer 3): openclicky does not yet have a stash writer; this
# script is a skeleton so the diff runner has a stable interface. Wire
# it up after docs/ROADMAP/04_LAYER_3_STASH_HOOK.md lands.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <fixture-id>" >&2
  exit 2
fi

FIXTURE="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STASH="$HOME/Library/Application Support/OpenClicky/context-stash.json"
OUT="$SCRIPT_DIR/fixtures/${FIXTURE}-openclicky.json"

if [[ ! -f "$SCRIPT_DIR/hotkeys.env" ]]; then
  echo "error: $SCRIPT_DIR/hotkeys.env is missing" >&2
  echo "hint: cp $SCRIPT_DIR/hotkeys.env.example $SCRIPT_DIR/hotkeys.env" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/hotkeys.env"

if [[ -z "${OPENCLICKY_SNAPSHOT_KEY:-}" ]]; then
  echo "error: OPENCLICKY_SNAPSHOT_KEY not set in hotkeys.env" >&2
  exit 1
fi

# Fixture-to-hotkey mapping — mirrors the Everywhere side.
case "$FIXTURE" in
  snapshotcontext-*)  HOTKEY="${OPENCLICKY_SNAPSHOT_KEY}"    ;;
  pickelement-*)      HOTKEY="${OPENCLICKY_PICKELEMENT_KEY:-alt+s}" ;;
  linkrect-*)         HOTKEY="${OPENCLICKY_LINKRECT_KEY:-alt+l}"    ;;
  whiteboard-*)       HOTKEY="${OPENCLICKY_WHITEBOARD_KEY:-alt+d}"  ;;
  *)                  HOTKEY="${OPENCLICKY_SNAPSHOT_KEY}"    ;;
esac

# TODO(Layer 3): swap this pgrep name for the shipping openclicky
# process name once known.
if ! pgrep -x OpenClicky >/dev/null && ! pgrep -x cursor-buddy >/dev/null; then
  echo "error: OpenClicky is not running (TODO: verify process name)" >&2
  echo "TODO: implement after Phase 6 (Layer 3 stash hook)" >&2
  exit 1
fi

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

prev_mtime=""
if [[ -f "$STASH" ]]; then
  prev_mtime="$(stat -f %m "$STASH")"
fi

parse_hotkey "$HOTKEY"

build_and_send() {
  local key="$_KEYSTROKE_KEY"
  local mods="$_KEYSTROKE_MODS"
  local script
  case "$key" in
    space)  script="tell application \"System Events\" to key code 49 using {$mods}" ;;
    return) script="tell application \"System Events\" to key code 36 using {$mods}" ;;
    tab)    script="tell application \"System Events\" to key code 48 using {$mods}" ;;
    escape) script="tell application \"System Events\" to key code 53 using {$mods}" ;;
    *)
      if [[ -n "$mods" ]]; then
        script="tell application \"System Events\" to keystroke \"$key\" using {$mods}"
      else
        script="tell application \"System Events\" to keystroke \"$key\""
      fi
      ;;
  esac
  # Strip trailing "using {}" if mods happens to be empty for the mapped keys.
  script="${script// using \{\}/}"
  osascript -e "$script"
}

build_and_send

# Commit the pick / drag / whiteboard gesture on the OpenClicky side.
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
  echo "error: openclicky stash never appeared at $STASH" >&2
  echo "TODO: implement after Phase 6 (Layer 3 stash hook)" >&2
  exit 1
fi

cur_mtime="$(stat -f %m "$STASH")"
if [[ "$cur_mtime" == "$prev_mtime" ]]; then
  echo "error: openclicky stash mtime unchanged after 3s — hotkey not bound?" >&2
  exit 1
fi

mkdir -p "$SCRIPT_DIR/fixtures"
cp "$STASH" "$OUT"
echo "captured" >&2
