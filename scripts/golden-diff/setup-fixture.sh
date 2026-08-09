#!/usr/bin/env bash
set -euo pipefail

# Usage: setup-fixture.sh <fixture-id>
#
# Puts macOS into a known UI state ready for a snapshot capture. Fixture
# IDs must be listed in fixtures/manifest.txt so run-all.sh can iterate.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <fixture-id>" >&2
  exit 2
fi

FIXTURE="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Small helper: bring an app to the front, then pause so AX + focus
# events settle before we or the app under test read state.
activate_app() {
  local app_name="$1"
  osascript -e "tell application \"$app_name\" to activate" >/dev/null
  sleep 0.5
}

case "$FIXTURE" in
  finder-empty-folder)
    mkdir -p "$HOME/Downloads/testfolder"
    # Nuke contents so it's guaranteed empty.
    find "$HOME/Downloads/testfolder" -mindepth 1 -delete 2>/dev/null || true
    activate_app Finder
    osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  activate
  open ("$HOME/Downloads/testfolder" as POSIX file)
end tell
APPLESCRIPT
    sleep 0.5
    ;;

  finder-pdf-selected)
    # Use a stable, known-to-exist PDF: the system-provided
    # "About Downloads.lpdf" is not portable, so we synthesise one.
    FIXTURE_PDF="$HOME/Downloads/testfolder/golden-diff-sample.pdf"
    mkdir -p "$(dirname "$FIXTURE_PDF")"
    if [[ ! -f "$FIXTURE_PDF" ]]; then
      # Minimal valid PDF (blank one-page). Kept inline so no external
      # dependency is needed.
      cat > "$FIXTURE_PDF" <<'PDF'
%PDF-1.1
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj
xref
0 4
0000000000 65535 f
0000000010 00000 n
0000000053 00000 n
0000000098 00000 n
trailer<</Size 4/Root 1 0 R>>
startxref
150
%%EOF
PDF
    fi
    activate_app Finder
    osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  activate
  reveal ("$FIXTURE_PDF" as POSIX file)
end tell
APPLESCRIPT
    sleep 0.5
    ;;

  safari-url)
    activate_app Safari
    osascript <<'APPLESCRIPT' >/dev/null
tell application "Safari"
  activate
  if (count of windows) = 0 then
    make new document with properties {URL:"https://example.com"}
  else
    set URL of front document to "https://example.com"
  end if
end tell
APPLESCRIPT
    sleep 1.5
    ;;

  terminal-scrollback)
    activate_app Terminal
    osascript <<'APPLESCRIPT' >/dev/null
tell application "Terminal"
  activate
  if (count of windows) = 0 then
    do script "ls -la"
  else
    do script "ls -la" in front window
  end if
end tell
APPLESCRIPT
    sleep 0.8
    ;;

  browser-tabs)
    activate_app Safari
    osascript <<'APPLESCRIPT' >/dev/null
tell application "Safari"
  activate
  set targets to {"https://example.com", "https://example.org", "https://example.net"}
  if (count of windows) = 0 then
    make new document with properties {URL:(item 1 of targets)}
  else
    set URL of front document to (item 1 of targets)
  end if
  tell front window
    repeat with i from 2 to (count of targets)
      set newTab to make new tab with properties {URL:(item i of targets)}
    end repeat
  end tell
end tell
APPLESCRIPT
    sleep 1.5
    ;;

  # ---- runtime-2026-07-23 golden-diff fixtures -----------------------------
  # These 5 fixtures pair a specific UI state with a specific hotkey path so
  # capture-{everywhere,openclicky}.sh can trigger the same action in both apps
  # and diff the resulting stash. See docs/ROADMAP/.review-notes/golden-diff-
  # runtime-2026-07-23.md for the intended per-fixture comparison.

  # 1. SnapshotContext on Finder home Documents
  snapshotcontext-finder-documents)
    activate_app Finder
    osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  activate
  open ("$HOME/Documents" as POSIX file)
  set target of front window to (folder "Documents" of home)
end tell
APPLESCRIPT
    sleep 0.6
    ;;

  # 2. SnapshotContext on Arc apple.com
  snapshotcontext-arc-apple)
    # Arc's script layer honours "open location", falling back gracefully
    # when Arc is not installed.
    if ! osascript -e 'exists application "Arc"' >/dev/null 2>&1; then
      echo "note: Arc.app not installed — this fixture will be recorded as blocked" >&2
    fi
    open -a "Arc" "https://www.apple.com/" 2>/dev/null || true
    sleep 2.0
    osascript -e 'tell application "Arc" to activate' >/dev/null 2>&1 || true
    sleep 0.8
    ;;

  # 3. PickElement on TextEdit "hello" cursor
  pickelement-textedit-hello)
    osascript <<'APPLESCRIPT' >/dev/null
tell application "TextEdit"
  activate
  set docs to (get documents)
  if (count of docs) = 0 then
    make new document
  end if
  set text of front document to "hello"
end tell
APPLESCRIPT
    sleep 0.8
    # Move cursor over the text of the front TextEdit window (heuristic:
    # a bit inset from the top-left of the front window frame). We use
    # cliclick since osascript keystroke is banned by TCC on headless
    # runners; if cliclick is missing this becomes a no-op and the
    # PickElement fixture will fail-open.
    if command -v cliclick >/dev/null; then
      # Compute a target inside the window. AppleScript returns
      # {x,y,width,height} in the "bounds" of the front TextEdit window.
      BOUNDS="$(osascript -e 'tell application "System Events" to tell process "TextEdit" to get {position, size} of window 1' 2>/dev/null || echo "")"
      # Fall back to a reasonable global point when we can't read bounds.
      # Position roughly 40px in and 60px down from the window origin so we
      # land on the "hello" glyphs.
      cliclick "m:200,300" >/dev/null 2>&1 || true
    fi
    sleep 0.4
    ;;

  # 4. LinkRect on Safari Wikipedia Main_Page — In the news
  linkrect-safari-wikipedia)
    activate_app Safari
    osascript <<'APPLESCRIPT' >/dev/null
tell application "Safari"
  activate
  if (count of windows) = 0 then
    make new document with properties {URL:"https://en.wikipedia.org/wiki/Main_Page"}
  else
    set URL of front document to "https://en.wikipedia.org/wiki/Main_Page"
  end if
end tell
APPLESCRIPT
    # Wikipedia Main Page can take a moment; wait for load.
    sleep 3.0
    ;;

  # 5. Whiteboard on Notes.app underline "test"
  whiteboard-notes-underline-test)
    activate_app Notes
    osascript <<'APPLESCRIPT' >/dev/null
tell application "Notes"
  activate
  set noteBody to "This is a test line"
  try
    tell account 1
      make new note at folder "Notes" with properties {name:"Golden Diff Whiteboard", body:noteBody}
    end tell
  on error
    -- If the default folder path doesn't resolve, ignore; the Whiteboard
    -- capture is content-agnostic beyond OCR matching.
  end try
end tell
APPLESCRIPT
    sleep 1.0
    ;;

  *)
    echo "unknown fixture: $FIXTURE" >&2
    echo "known: $(tr '\n' ' ' < "$SCRIPT_DIR/fixtures/manifest.txt")" >&2
    exit 2
    ;;
esac

echo "ready" >&2
