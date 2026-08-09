# Phase 1 — Finder selection capture (investigation)

Ported from Everywhere @30e03e9dcfdd4247fd679828ed86e9042f32d809

## Source files read

- `src/Everywhere.Mac/Mcp/MacFinderReader.cs` (71 lines) — ground truth.
- `src/Everywhere.Mac/Mcp/MacAppleScriptRunner.cs` (72 lines) — dependency.
- `src/Everywhere.Mcp/Tools/GetFinderSelectionTool.cs` (130 lines) — consumer (derives `mime` / `kind_hint` from extension).

## AppleScript source (verbatim)

Everywhere hard-codes the following AppleScript in `MacFinderReader.Source`:

```applescript
tell application "Finder"
            set NUL to (ASCII character 0)
            set RS to (ASCII character 30)
            set sel to selection
            set out to ""
            repeat with i in sel
                set out to out & POSIX path of (i as alias) & NUL
            end repeat
            try
                set fp to POSIX path of ((target of front window) as alias)
            on error
                set fp to ""
            end try
            return out & RS & fp
        end tell
```

Separators are chosen so filenames containing `\n` / `\r` are safe:

- `NUL` (0x00) between selected item paths.
- `RS` (0x1E, ASCII "Record Separator") between the selection block and the folder block.

Return shape (single-line raw stdout, minus the trailing `\n` osascript adds):

```
<path1>\0<path2>\0...\0<pathN>\0<0x1E><frontWindowFolderPOSIX>
```

The trailing `\0` after the last selected item is intentional — the C# split includes an empty string at the end which is skipped by the `IsNullOrEmpty` guard.

## Parsing rules (C# reference)

1. Find first `0x1E` byte. Everything before is `selBlock`, everything after is `folder`.
2. Trim whitespace on folder; empty string -> `null`.
3. Split `selBlock` on `\0`.
4. For each entry: trim trailing `\r\n`, skip empty, skip entries not starting with `/`.
5. `isDir` = path ends with `/`. Canonical path drops trailing `/`.
6. Name = filename component of canonical, fallback to full path when empty.
7. If not marked as dir by trailing `/`, `Directory.Exists(path)` sets `isDir=true` (best-effort, exceptions swallowed).

## Error / status handling

`MacAppleScriptRunner.Run` returns `AppleScriptResult(status, output, error)`:

- `Ok` -> stdout is trimmed of trailing `\n`.
- `NotSupported` -> propagate to `FinderStatus.NotSupported` in `FinderResult`.
- `PermissionDenied` -> propagate.
- `Failed` -> **mapped to `PermissionDenied`** in `MacFinderReader` (see switch case, line 39-40). Historic quirk: any script failure is treated as a permission problem.

Permission detection uses stderr sniffing:

- Contains `-1743` (TCC Apple Events denial).
- Contains `"not allowed assistive access"` (case-insensitive).
- Contains `"not authorized to send Apple events"` (case-insensitive).

Timeout is **15 s**. On timeout the process is killed (with 1s grace), status becomes `Failed`.

## Consumer additions (GetFinderSelectionTool)

The MCP tool augments each item with:

- `mime` (best-effort from extension, e.g. `application/pdf`).
- `kind_hint` in `{pdf, docx, xlsx, pptx, epub, html, image, text, folder, unknown}`.

This is derived at serialize time and NOT stored on `FinderItem`.

## Doc reconciliation

`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md` row 11 + data model section (lines 114-124) specifies:

```swift
struct FinderSelectionInfo: Codable {
    let currentFolder: String?
    let selectedFiles: [FinderItem]
}

struct FinderItem: Codable {
    let path: String
    let name: String
    let isDirectory: Bool
    let kindHint: String?    // "pdf", ...
}
```

Divergence from Everywhere:

- Doc adds `kindHint` on the item. Everywhere only adds it in the JSON serialization layer of `GetFinderSelectionTool`, not the core `FinderItem` record.

Decision: **follow the doc**. `kindHint` is pure `(name, isDirectory) -> String`, no ambiguity, and having it on the model saves every downstream from re-implementing the mapping. We port `KindHintFromExtension` alongside so the value is populated automatically.

No `mime` field on the Swift model — leave to the same downstream layer that adds MCP-tool-specific JSON. (Doc row 11 does not request mime.)

## Signature choice

Swift API: `FinderSelectionCapture.capture() async -> FinderSelectionInfo?`

- `async` because osascript is a subprocess call; keeps `@MainActor` callers off the main thread.
- Returns `nil` when the AppleScript itself fails/times out or when permissions are denied — matches how C# callers currently need to check `FinderStatus`. openclicky Layer 0 doesn't carry a status enum yet, so nil means "no data".
- Returns non-nil with empty `selectedFiles` when Finder is running and reachable but nothing is selected. This matches the "OK, empty" case (`FinderStatus.Ok` + zero-length selection) in Everywhere.

Internal helper `runFinderScript()` returns a richer discriminated result so a future consumer (MCP sensor tool) can distinguish permission-denied without changing the public surface.

## AppleScriptRunner (Swift)

Created at `Sources/OpenClickyContextService/Capture/AppleScriptRunner.swift`. Contract mirrors the C# runner:

- `run(source:) async -> AppleScriptResult`.
- 15 s timeout, kills on expiry.
- Async pipe drain (avoid the >64KB deadlock case) implemented via `Pipe.fileHandleForReading.readabilityHandler`.
- Same permission-sniff heuristic (`-1743`, `"not allowed assistive access"`, `"not authorized to send Apple events"`).
- Uses `/usr/bin/osascript -e <source>` (Process/NSTask). `NSAppleScript`/`OSAKit` is *not* used — the C# runner shells out because osascript's TCC context is what production users have already granted; matching that keeps the permission story identical. Also, subprocess avoids running AppleScript on the app's main thread.

## Next-agent notes

- `AppleScriptRunner.swift` is a new type; the browser-tabs / browser-URL / terminal-scrollback capture ports can reuse it.
- `AppleScriptRunner.run` is `async`; tests can inject a fake by using `AppleScriptRunning` protocol conformance if we later split it.
- Currently `FinderSelectionCapture` uses the default shared runner. If the parity audit later demands DI, hoist to `capture(runner: AppleScriptRunning = .shared)`.
