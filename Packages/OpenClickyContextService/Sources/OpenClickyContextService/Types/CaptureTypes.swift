// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/AppKey.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Shared data types for OpenClicky ContextService captures. Corresponds
// conceptually to Everywhere's per-snapshot value types. Everywhere models
// its "app key" as a single `string` (see `AppKey.FromProcessId`); openclicky
// instead carries the richer NSRunningApplication tuple documented in
// docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 24, with the Everywhere-
// compatible key kept as one field so downstream tools can round-trip.

import Foundation
import AppKit
import CoreGraphics

/// Mirrors `NSApplicationActivationPolicy` as a Codable, Sendable enum so
/// FrontmostAppInfo can be serialised to JSON (for stash / IPC).
///
/// Everywhere reference: `NSApplicationActivationPolicy.Prohibited` filter
/// in `src/Everywhere.Mac/Interop/VisualElementContext.cs:85, 103`.
public enum FrontmostActivationPolicy: String, Codable, Sendable {
    case regular      // NSApplicationActivationPolicy.regular
    case accessory    // NSApplicationActivationPolicy.accessory
    case prohibited   // NSApplicationActivationPolicy.prohibited
    case unknown      // future-proofing against new AppKit cases

    init(_ policy: NSApplication.ActivationPolicy) {
        switch policy {
        case .regular: self = .regular
        case .accessory: self = .accessory
        case .prohibited: self = .prohibited
        @unknown default: self = .unknown
        }
    }
}

/// Snapshot of the currently frontmost application on macOS.
///
/// Corresponds to Everywhere's `AppKey.FromProcessId` output enriched with
/// the NSRunningApplication fields Everywhere reads elsewhere
/// (see `VisualElementContext.cs:82-111`). `appKey` preserves the exact
/// string identifier `AppKey.FromProcessId` would emit for the same pid,
/// so snapshots stay cross-compatible with Everywhere tooling.
public struct FrontmostAppInfo: Codable, Equatable, Sendable {
    /// Process identifier. Matches `NSRunningApplication.processIdentifier`
    /// (`pid_t` == `Int32`). Always > 0 when this struct exists — a pid <= 0
    /// would have caused `FrontmostAppCapture.capture()` to return nil.
    public let processId: Int32

    /// Application bundle identifier (e.g. `com.apple.finder`).
    /// Nil for helpers / anonymous CLI processes that have no bundle.
    public let bundleId: String?

    /// User-visible localised app name (e.g. "Finder").
    /// Nil for daemons / helpers without an Info.plist name.
    public let localizedName: String?

    /// Full POSIX path of the executable, if resolvable.
    public let executablePath: String?

    /// Stable per-process key, 1:1 compatible with Everywhere's
    /// `AppKey.FromProcessId(pid)`. Never nil; falls back through the same
    /// pid-name-lowercase / pid-string chain the C# implementation uses.
    public let appKey: String

    /// Preserved so callers can replicate Everywhere's
    /// `activationPolicy == Prohibited` filter without re-querying AppKit.
    public let activationPolicy: FrontmostActivationPolicy

    public init(
        processId: Int32,
        bundleId: String?,
        localizedName: String?,
        executablePath: String?,
        appKey: String,
        activationPolicy: FrontmostActivationPolicy
    ) {
        self.processId = processId
        self.bundleId = bundleId
        self.localizedName = localizedName
        self.executablePath = executablePath
        self.appKey = appKey
        self.activationPolicy = activationPolicy
    }
}

// MARK: - Running apps
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809 (`TryFastListApps`, L97-111).
//
// Everywhere models each running-app entry as
// `(IVisualElement Window, int ProcessId)` — only the AX window ref plus
// pid make it into the downstream list. openclicky exposes the richer
// NSRunningApplication surface instead, because our stash / IPC layer wants
// enough fields to reproduce the Everywhere `TryFastResolveByName` name /
// bundle-id match (`VisualElementContext.cs:79-95`) without a second AppKit
// round-trip. The Everywhere-visible fields (`processId`, `activationPolicy`)
// are exactly as Everywhere reads them; the remaining fields (`isHidden`,
// `isFinishedLaunching`, `ownsMenuBar`, `launchDate`, `executableName`) are
// pass-through reads of documented NSRunningApplication properties.
//
// See `docs/ROADMAP/.impl-notes/phase5-runningapps-2026-07-23.md` for the
// deviation table: openclicky's list DOES include apps that Everywhere would
// have discarded via the `AXUIElement.FreshFocusedWindowOf(pid) is null`
// gate. That gate belongs in a separate AX layer; downstream callers can
// re-apply it by cross-referencing this list with `FocusedWindowCapture`.

/// Snapshot of one running application as reported by
/// `NSWorkspace.shared.runningApplications`.
///
/// One `RunningAppInfo` corresponds to one `NSRunningApplication` at the
/// moment `RunningAppsCapture.list()` was called. The struct is immutable —
/// a re-read of the same pid moments later can yield a different
/// `RunningAppInfo` (e.g. `isFinishedLaunching` flipping from false to true,
/// `ownsMenuBar` flipping when the user switches apps).
///
/// Everywhere field mapping:
///   * `processId`         — `NSRunningApplication.processIdentifier`
///                           (int32, matches C# `int ProcessIdentifier`).
///   * `activationPolicy`  — `NSRunningApplication.activationPolicy`,
///                           bridged through the shared
///                           `FrontmostActivationPolicy` enum. Callers can
///                           replicate Everywhere's Prohibited filter without
///                           a second AppKit call.
///
/// openclicky-only fields:
///   * `bundleId` / `name` / `executableName` — same reads Everywhere
///     does ad-hoc in `TryFastResolveByName` (L86-89).
///   * `isHidden` / `isFinishedLaunching` / `ownsMenuBar` / `launchDate` —
///     pass-through of the NSRunningApplication properties of the same name.
///     Not read by Everywhere here; carried because openclicky's ranker
///     (Layer 3) uses `ownsMenuBar` and `launchDate` to break ties when the
///     user asks for "the last thing I opened".
public struct RunningAppInfo: Codable, Sendable, Equatable {
    /// `NSRunningApplication.processIdentifier`. Always `> 0` for entries
    /// returned by `RunningAppsCapture.list()` — the capture drops pids of
    /// `<= 0`, matching `VisualElementContext.cs:105`.
    public let processId: Int32

    /// `NSRunningApplication.bundleIdentifier`. `nil` for CLI helpers /
    /// anonymous processes without an Info.plist bundle id.
    public let bundleId: String?

    /// `NSRunningApplication.localizedName`. `nil` for daemons whose
    /// Info.plist carries no user-facing name.
    public let name: String?

    /// `NSRunningApplication.executableURL.lastPathComponent`. Everywhere's
    /// `AppKey.FromProcessId` uses the same string (via `Process.ProcessName`).
    /// `nil` when `executableURL` is missing.
    public let executableName: String?

    /// `NSRunningApplication.activationPolicy`. Everywhere skips
    /// `.prohibited` entries at the capture boundary
    /// (`VisualElementContext.cs:103`); openclicky mirrors that filter — an
    /// entry with `activationPolicy == .prohibited` will NEVER appear in
    /// `list()` output. The field is still surfaced so callers can tell
    /// `.regular` from `.accessory` (menu-bar-only apps like Bartender).
    public let activationPolicy: FrontmostActivationPolicy

    /// `NSRunningApplication.isHidden`. True when the user has hidden the
    /// app via Cmd-H. Not read by Everywhere.
    public let isHidden: Bool

    /// `NSRunningApplication.isFinishedLaunching`. False during the brief
    /// window between fork/exec and the app's NSApplicationDidFinishLaunching
    /// posting. Callers should treat `false` here as "may not yet have any
    /// AX-addressable windows".
    public let isFinishedLaunching: Bool

    /// `NSRunningApplication.ownsMenuBar`. True when this app is currently
    /// providing the top-of-screen menu (usually equivalent to "frontmost
    /// non-accessory app").
    public let ownsMenuBar: Bool

    /// `NSRunningApplication.launchDate`. `nil` when AppKit did not record
    /// a launch date (system daemons launched before the WindowServer
    /// session started).
    public let launchDate: Date?

    public init(
        processId: Int32,
        bundleId: String?,
        name: String?,
        executableName: String?,
        activationPolicy: FrontmostActivationPolicy,
        isHidden: Bool,
        isFinishedLaunching: Bool,
        ownsMenuBar: Bool,
        launchDate: Date?
    ) {
        self.processId = processId
        self.bundleId = bundleId
        self.name = name
        self.executableName = executableName
        self.activationPolicy = activationPolicy
        self.isHidden = isHidden
        self.isFinishedLaunching = isFinishedLaunching
        self.ownsMenuBar = ownsMenuBar
        self.launchDate = launchDate
    }
}

// MARK: - Finder selection

/// One item in the current Finder selection.
///
/// Everywhere reference: `FinderItem` record in
/// `src/Everywhere.Mcp/Snapshot/FinderSnapshot.cs` (path/name/isDir).
/// `kindHint` is not on Everywhere's core record — it is derived at MCP-tool
/// serialization time by `GetFinderSelectionTool.KindHintFromExtension`. We
/// materialise it eagerly here because the mapping is a pure function of
/// `(name, isDirectory)` and downstream callers all need it.
public struct FinderItem: Codable, Equatable, Sendable {
    /// Absolute POSIX path as reported by Finder (`POSIX path of (i as alias)`).
    public let path: String

    /// Filename component of `path`. Falls back to full path when the
    /// filename is empty (matches C# behavior in `MacFinderReader.cs:58-59`).
    public let name: String

    /// True when the selection item is a directory. Determined first from
    /// the trailing `/` Finder emits for folders, then confirmed via
    /// `FileManager.fileExists(atPath:isDirectory:)` for entries missing
    /// the trailing slash (matches `Directory.Exists` in the C# port).
    public let isDirectory: Bool

    /// Coarse content hint used by the intent router and MCP surface. One of
    /// `pdf` / `docx` / `xlsx` / `pptx` / `epub` / `html` / `image` / `text`
    /// / `folder` / `unknown`. Never nil in practice — kept optional to match
    /// the docs/ROADMAP data-model spec exactly and to permit future
    /// upstream sources that cannot infer it.
    public let kindHint: String?

    public init(path: String, name: String, isDirectory: Bool, kindHint: String?) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.kindHint = kindHint
    }
}

/// Snapshot of the user's current Finder selection.
///
/// Everywhere reference: `FinderSelection` record in
/// `src/Everywhere.Mcp/Snapshot/FinderSnapshot.cs`, populated by
/// `MacFinderReader.GetSelection` (see the AppleScript captured in the
/// port header of `Capture/FinderSelectionCapture.swift`).
///
/// An instance with `selectedFiles.isEmpty` and `currentFolder == nil` is
/// legitimate — it means Finder is reachable but there is neither an active
/// window nor a selection. Callers should treat that case as "no context".
public struct FinderSelectionInfo: Codable, Equatable, Sendable {
    /// POSIX path of the folder shown by Finder's frontmost window, if any.
    /// `nil` when no Finder window is open OR AppleScript hit an internal
    /// error resolving the target.
    public let currentFolder: String?

    /// Items in the current selection, in the order Finder reported them.
    /// Empty when nothing is selected (still a valid, non-error case).
    public let selectedFiles: [FinderItem]

    public init(currentFolder: String?, selectedFiles: [FinderItem]) {
        self.currentFolder = currentFolder
        self.selectedFiles = selectedFiles
    }
}

/// Snapshot of the macOS general pasteboard.
///
/// Corresponds to Everywhere's `IClipboardReader.GetText()` output
/// (`src/Everywhere.Mac/Mcp/MacClipboardReader.cs`), which only returns
/// `string?` for `public.utf8-plain-text`. openclicky's `ClipboardInfo`
/// widens the surface to the doc row 13 target (text / file / image / rtf),
/// but only the `text` field is P0 — the rest are P1 stubs populated by
/// later work. When populated, each field's semantics MUST match the
/// corresponding NSPasteboard type Everywhere's C# reader would have
/// observed on the same pasteboard.
public struct ClipboardInfo: Codable, Equatable, Sendable {
    /// Plain UTF-8 text content of the pasteboard.
    ///
    /// 1:1 with Everywhere's `MacClipboardReader.GetText()`:
    ///   * populated when `NSPasteboard.general.string(forType: .string)`
    ///     yields a non-nil value
    ///   * `nil` when the pasteboard is empty OR contains only non-text
    ///     data (image / file / rtf without a text representation) OR any
    ///     underlying AppKit call fails
    ///
    /// Note: Everywhere passes the modern UTI `public.utf8-plain-text`;
    /// `NSPasteboard.PasteboardType.string.rawValue` is that same UTI.
    public let text: String?

    // TODO(P1): implement filePaths capture from NSPasteboard.PasteboardType.fileURL.
    // Everywhere's `MacClipboardReader.cs` does not read this today; adding
    // it here is an openclicky-side extension flagged as P1 in
    // docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 13.
    public let filePaths: [String]?

    // TODO(P1): implement imageData capture (NSPasteboard.PasteboardType.tiff / .png).
    // Not present in Everywhere's reader; P1 in the roadmap.
    public let imageData: Data?

    // TODO(P1): implement rtfData capture (NSPasteboard.PasteboardType.rtf).
    // Not present in Everywhere's reader; P1 in the roadmap.
    public let rtfData: Data?

    public init(
        text: String?,
        filePaths: [String]? = nil,
        imageData: Data? = nil,
        rtfData: Data? = nil
    ) {
        self.text = text
        self.filePaths = filePaths
        self.imageData = imageData
        self.rtfData = rtfData
    }
}

/// Snapshot of how long since the user last touched any input device.
///
/// Corresponds to Everywhere's `MacIdleTimeReader.GetIdleSeconds()`
/// (`src/Everywhere.Mac/Mcp/MacIdleTimeReader.cs`), which returns a bare
/// `double` seconds value. openclicky wraps it in a struct so downstream
/// stash / IPC layers can round-trip the reading and the unit is explicit
/// at the type level.
///
/// Backing API: `CGEventSourceSecondsSinceLastEventType` with
/// `combinedSessionState` and the "any input event" sentinel. Value is
/// the age of the most recent keyboard / mouse / trackpad / etc. event.
public struct IdleTimeInfo: Codable, Equatable, Sendable {
    /// Seconds since the last input event of any type.
    ///
    /// Always >= 0. Everywhere's C# path returns `0` for both "user just
    /// typed" and "the CoreGraphics call threw"; openclicky preserves the
    /// numeric contract but disambiguates the error path via `nil` on
    /// `IdleTimeCapture.capture()`.
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }
}

// MARK: - Browser URL

/// Snapshot of the URL exposed by the focused element of a browser
/// (or any AX-accessible app that publishes `AXURL`).
///
/// Corresponds to `IBrowserUrlReader.GetUrl(int)` in
/// `src/Everywhere.Mcp/Snapshot/IBrowserUrlReader.cs`, whose macOS
/// implementation `MacBrowserUrlReader` returns a bare `string?`.
/// Everywhere's MCP tool then combines that URL with
/// `AppKey.FromProcessId(pid)` at the JSON envelope layer (see
/// `GetBrowserUrlTool.GetBrowserUrl`). openclicky wraps the URL in a
/// struct so downstream stash / IPC callers can round-trip the reading
/// alongside the pid it was drawn from — the semantics of the URL
/// string itself are unchanged.
///
/// An instance always represents a successful read: the `url` is
/// non-empty and was pulled from `AXURL` on either the focused element
/// or one of its ancestors (up to 16 hops). Failure cases (pid <= 0,
/// missing focus chain, no `AXURL` in range, empty attribute) surface
/// as a nil return from `BrowserURLCapture.capture(processId:)`.
public struct BrowserURLInfo: Codable, Equatable, Sendable {
    /// Process identifier the URL was resolved against. Matches the
    /// pid supplied to `BrowserURLCapture.capture(processId:)`.
    public let processId: Int32

    /// URL string exactly as `AXURL` reported it. Everywhere's C# path
    /// preserves scheme + query + fragment verbatim; openclicky does
    /// the same — no percent-decoding, no credential redaction, no
    /// trailing-slash normalisation.
    public let url: String

    public init(processId: Int32, url: String) {
        self.processId = processId
        self.url = url
    }
}

// MARK: - Focused window

/// Snapshot of the "focused window" for a given process, resolved through the
/// macOS Accessibility API.
///
/// Everywhere reference: `AXUIElement.FreshFocusedWindowOf(int pid)` in
/// `src/Everywhere.Mac/Interop/AXUIElement.cs:1153-1176`. That method returns a
/// bare `AXUIElement?`; the fields exposed here are the ones Everywhere reads
/// off the resulting ref elsewhere in the codebase:
/// - `title` is `AXUIElement.Name` (title/description/help cascade,
///   `AXUIElement.cs:257-`);
/// - `frame` is `AXUIElement.BoundingRectangle` (`AXPosition` + `AXSize`,
///   `AXUIElement.cs:430-465`, Quartz top-left global coords);
/// - `isMinimized` / `isMainWindow` are bool AX attributes referenced from
///   `AXAttributeConstants.cs:81-82`.
///
/// `displayIndex` is the Swift-side convenience add-on. Everywhere computes
/// per-window screen membership ad-hoc in `NSScreenVisualElement.Children`
/// (`NSScreenVisualElement.cs:22-45`) by intersecting the window rect against
/// each `NSScreen.Frame` (with the Cocoa-to-Quartz Y-flip on L57-67). We fold
/// that computation into the capture so callers don't have to re-run it.
///
/// A `nil` return from `FocusedWindowCapture.capture(processId:)` means:
/// - the pid was `<= 0`, OR
/// - the AX app element could not be created (rare, e.g. Accessibility perm
///   denied), OR
/// - both `AXFocusedWindow` AND `AXMainWindow` were absent (matches the two-
///   step resolution in `FreshFocusedWindowOf`).
public struct FocusedWindowInfo: Codable, Equatable, Sendable {
    /// The pid the capture was resolved against. Always > 0.
    /// Matches `AXUIElement.ProcessId` on the resolved window ref.
    public let processId: Int32

    /// Window title as reported by AX. Applies the `AXTitle` -> `AXDescription`
    /// -> `AXHelp` cascade from `AXUIElement.Name`
    /// (`AXUIElement.cs:257-283`) — the label-bearing-role branch is dropped
    /// because AXWindow is never a label-bearing role.
    ///
    /// `nil` when no attribute yields a non-empty string. Legitimate for
    /// untitled documents in some apps.
    public let title: String?

    /// Window geometry in Quartz top-left global screen coordinates.
    /// Comes from `AXPosition` (CGPoint) + `AXSize` (CGSize), 1:1 with
    /// `AXUIElement.BoundingRectangle` (`AXUIElement.cs:448-465`).
    ///
    /// `.zero` when either attribute is missing or unwrap fails — matches
    /// Everywhere's `return default;` on the exception path (L461-464).
    public let frame: CGRect

    /// Index into `NSScreen.screens` of the display containing the window.
    /// Computed by intersecting `frame` against each screen's Quartz-flipped
    /// frame (mirrors `NSScreenVisualElement.Children` intersection at
    /// `NSScreenVisualElement.cs:37-42`, plus the Cocoa->Quartz flip at
    /// L57-67).
    ///
    /// `nil` when `frame` is `.zero`, the window has no positive-area
    /// intersection with any current `NSScreen`, or there are no screens.
    public let displayIndex: Int?

    /// `AXMinimized` on the resolved window ref
    /// (constant declared at `AXAttributeConstants.cs:82`).
    /// Defaults to `false` when the attribute is absent or unreadable —
    /// matches Everywhere's implicit behaviour (a missing bool AX attribute
    /// is treated as `false` throughout `AXUIElement.cs`).
    public let isMinimized: Bool

    /// `AXMain` on the resolved window ref
    /// (constant declared at `AXAttributeConstants.cs:81`).
    /// Distinguishes the app's main document window from floating panels /
    /// inspectors. False when the attribute is absent.
    public let isMainWindow: Bool

    public init(
        processId: Int32,
        title: String?,
        frame: CGRect,
        displayIndex: Int?,
        isMinimized: Bool,
        isMainWindow: Bool
    ) {
        self.processId = processId
        self.title = title
        self.frame = frame
        self.displayIndex = displayIndex
        self.isMinimized = isMinimized
        self.isMainWindow = isMainWindow
    }
}

// MARK: - Workdir probe
//
// OpenClicky-unique capability (no Everywhere source). See
// docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 27 for the data-model spec
// and docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md for how these signals feed the
// intent classifier before spawning Codex on a folder.

/// Coarse project-type classification produced by `WorkdirProbe`.
///
/// The set is intentionally small; the intent-classifier at
/// `docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md` fans out from these coarse
/// categories to task types. `unknown` is a first-class value, not an error
/// signal, and means "no recognised marker file was present at the top of
/// the directory".
public enum ProjectType: String, Codable, Sendable {
    case rust
    case nodejs
    case python
    case go
    case swift
    case xcode
    case unknown
}

/// Snapshot of the on-disk state of a candidate workdir before OpenClicky
/// hands it to a Codex / agent run.
///
/// All boolean fields are false and `detectedProjectType` is `.unknown`
/// when the path does not exist. See `WorkdirProbe.probe(_:)` for the
/// detection precedence and the exact rules used for `isEmpty` / `fileCount`.
public struct WorkdirProbeResult: Codable, Sendable, Equatable {
    /// Absolute POSIX path (`URL.path`) as supplied to `probe`.
    public let path: String

    /// True when Foundation reports the path exists on disk. Symlinks are
    /// followed; a broken symlink surfaces as `exists == false`.
    public let exists: Bool

    /// True when the resolved target is a directory (i.e. `exists == true`
    /// and the underlying inode is `.typeDirectory`).
    public let isDirectory: Bool

    /// True when the directory contains no user-visible entries. `.DS_Store`
    /// is ignored for this check; dot-files are counted.
    public let isEmpty: Bool

    /// Number of top-level entries in the directory, excluding `.DS_Store`.
    /// Files, symlinks, and dot-files (including `.git`, `.openclicky`) all
    /// count. For a non-directory the value is `0`.
    public let fileCount: Int

    /// Best-effort project-type classification (see `ProjectType`).
    public let detectedProjectType: ProjectType

    /// True when a `.git` directory sits at the top level.
    public let hasGit: Bool

    /// True when a `.openclicky` directory sits at the top level.
    public let hasOpenClickyState: Bool

    /// True when an `AGENTS.md` file sits at the top level.
    public let hasAgentsMd: Bool

    public init(
        path: String,
        exists: Bool,
        isDirectory: Bool,
        isEmpty: Bool,
        fileCount: Int,
        detectedProjectType: ProjectType,
        hasGit: Bool,
        hasOpenClickyState: Bool,
        hasAgentsMd: Bool
    ) {
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.isEmpty = isEmpty
        self.fileCount = fileCount
        self.detectedProjectType = detectedProjectType
        self.hasGit = hasGit
        self.hasOpenClickyState = hasOpenClickyState
        self.hasAgentsMd = hasAgentsMd
    }
}

// MARK: - Selected text
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.TextSelection.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809 (three-strategy fallback in
// `GetTextViaAXAPI` + `GetTextViaClipboardAsync`) plus the JSON envelope
// shape from `src/Everywhere.Mcp/Tools/GetSelectedTextTool.cs`.
//
// Data-model spec lives at docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md
// "SelectedTextInfo" section. `.cache` / `.ax` are Everywhere-visible
// (via `GetSelectedTextTool.cs` `source: "cache" | "focused"`);
// `.child` and `.clipboardCmdC` are openclicky-side subdivisions of the
// same three-strategy fallback so callers can tell which branch fired.

/// Which of the three strategies produced the selected text.
///
/// Wire-level compatibility with Everywhere's `source` string:
///   * `.ax`  -> "focused" (Strategy 1: `AXSelectedText` on focused element)
///   * `.child` -> "focused" (Strategy 2: same but on an AXChildren entry)
///   * `.clipboardCmdC` -> "clipboard" (Strategy 3: synthesized Cmd+C)
///   * `.cache` -> "cache" (matches Everywhere's `SelectionCache.GetFresh`)
///
/// Everywhere itself does not distinguish `.ax` from `.child`; openclicky
/// keeps the split because the child walk is a documented failure mode
/// (Chromium / Electron / SwiftUI TextField). Downstream JSON tooling
/// that must round-trip with Everywhere should collapse both to
/// `"focused"` at the envelope layer.
public enum SelectedTextSource: String, Codable, Sendable {
    case ax
    case child
    case clipboardCmdC
    case cache
}

/// Snapshot of the user's current text selection anywhere on macOS.
///
/// 1:1 with Everywhere's `GetSelectedTextTool` output plus the source
/// discrimination described on `SelectedTextSource`. The `text` field
/// is always non-empty when this struct exists — an empty selection
/// produces a `nil` return from `SelectedTextCapture.capture()`, matching
/// Everywhere's `string.IsNullOrEmpty(text)` short-circuits in
/// `VisualElementContext.TextSelection.cs:246, 255, 280`.
public struct SelectedTextInfo: Codable, Equatable, Sendable {
    /// Selected text as reported by the underlying source (`AXSelectedText`
    /// value or clipboard string after Cmd+C). Never empty. Grapheme-safe
    /// UTF-8; RTL / emoji / ZWJ sequences pass through unchanged, matching
    /// Everywhere's no-normalisation contract.
    public let text: String

    /// Which of the three strategies (plus cache) produced this reading.
    public let source: SelectedTextSource

    /// `AppKey.FromProcessId(pid)` output for the app that owned the
    /// focused UI element at capture time. `nil` when the capture came
    /// from the cache with no recorded app, or the pid was
    /// unresolvable at capture time.
    public let sourceApp: String?

    /// `text.count` (grapheme-cluster count), pre-computed once so
    /// downstream tools can length-guard without touching the string.
    /// Matches the roadmap spec (`SelectedTextInfo.length: Int`).
    public let length: Int

    public init(
        text: String,
        source: SelectedTextSource,
        sourceApp: String?,
        length: Int
    ) {
        self.text = text
        self.source = source
        self.sourceApp = sourceApp
        self.length = length
    }
}

// MARK: - Project registry
//
// OpenClicky-unique capability (no Everywhere source). See
// docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 29. Consumed by
// `ProjectRegistry` to fuzzy-match project names heard in voice
// transcripts (long_task_existing intent classification).

/// One entry in the local project registry — a project name, its
/// canonical on-disk path, and optional aliases the user might utter.
///
/// `slug` is the canonical single-token identifier (lowercase, no
/// spaces). `aliases` are additional strings that should route to the
/// same entry (spelled-out variants, common shortenings). Matching is
/// case-insensitive and punctuation-tolerant — see
/// `ProjectRegistry.lookup` for the algorithm.
public struct ProjectEntry: Codable, Sendable, Equatable {
    public let slug: String
    public let path: String
    public let aliases: [String]
    public let projectType: ProjectType

    public init(
        slug: String,
        path: String,
        aliases: [String],
        projectType: ProjectType
    ) {
        self.slug = slug
        self.path = path
        self.aliases = aliases
        self.projectType = projectType
    }
}

/// One match produced by `ProjectRegistry.lookup`.
///
/// `score` is a 0.0-1.0 confidence value; higher is better. Callers can
/// use `matchedTerm` to explain to the user *why* an entry was picked
/// (e.g. "matched alias 'clicky'").
public struct ProjectMatch: Codable, Sendable, Equatable {
    public let entry: ProjectEntry
    public let score: Double
    public let matchedTerm: String

    public init(
        entry: ProjectEntry,
        score: Double,
        matchedTerm: String
    ) {
        self.entry = entry
        self.score = score
        self.matchedTerm = matchedTerm
    }
}

// MARK: - Git awareness
//
// OpenClicky-unique capability (no Everywhere source). See
// docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 30. Feeds the intent
// classifier so a request that would open Codex on a dirty branch can
// nudge "commit first" before spawning the agent.

/// Snapshot of a git working tree's state, as observed by a series of
/// short-lived `git` subprocess invocations under a bounded 3s timeout.
///
/// All fields describe the tree at capture time. There is no attempt to
/// reconcile races with concurrent mutations (rebase in flight, another
/// process staging files, etc.) — callers only need a coarse signal.
public struct GitAwarenessInfo: Codable, Sendable, Equatable {
    /// Absolute POSIX path of the directory that contains `.git`
    /// (or, for a linked worktree, the path returned by
    /// `git rev-parse --show-toplevel`).
    public let repoRoot: String

    /// Short branch name (e.g. `main`, `feature/x`). `nil` when HEAD is
    /// detached — the caller can inspect `detachedHead` to distinguish
    /// "not on a branch" from "capture failed".
    public let currentBranch: String?

    /// True iff HEAD points at a commit rather than a symbolic ref.
    public let detachedHead: Bool

    /// True iff there is any staged, modified, or untracked change.
    /// Equivalent to `untrackedCount + modifiedCount + stagedCount > 0`.
    public let isDirty: Bool

    /// Count of untracked entries (porcelain `??`).
    public let untrackedCount: Int

    /// Count of files with unstaged modifications (porcelain second
    /// column in `[MD]`).
    public let modifiedCount: Int

    /// Count of files with staged changes (porcelain first column in
    /// `[MADRC]`).
    public let stagedCount: Int

    /// Number of entries reported by `git stash list`.
    public let stashCount: Int

    /// Commits on HEAD not yet in upstream. `nil` when no upstream is
    /// configured for the current branch (or when HEAD is detached).
    public let aheadOfUpstream: Int?

    /// Commits on upstream not yet in HEAD. Same nil semantics as
    /// `aheadOfUpstream`.
    public let behindUpstream: Int?

    /// 7-character abbreviated SHA of HEAD. `nil` for an empty repo
    /// (initial commit not yet made).
    public let lastCommitSha: String?

    /// First line (subject) of HEAD's commit message. `nil` for an
    /// empty repo.
    public let lastCommitSubject: String?

    /// Committer timestamp of HEAD. `nil` for an empty repo.
    public let lastCommitTimestamp: Date?

    public init(
        repoRoot: String,
        currentBranch: String?,
        detachedHead: Bool,
        isDirty: Bool,
        untrackedCount: Int,
        modifiedCount: Int,
        stagedCount: Int,
        stashCount: Int,
        aheadOfUpstream: Int?,
        behindUpstream: Int?,
        lastCommitSha: String?,
        lastCommitSubject: String?,
        lastCommitTimestamp: Date?
    ) {
        self.repoRoot = repoRoot
        self.currentBranch = currentBranch
        self.detachedHead = detachedHead
        self.isDirty = isDirty
        self.untrackedCount = untrackedCount
        self.modifiedCount = modifiedCount
        self.stagedCount = stagedCount
        self.stashCount = stashCount
        self.aheadOfUpstream = aheadOfUpstream
        self.behindUpstream = behindUpstream
        self.lastCommitSha = lastCommitSha
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitTimestamp = lastCommitTimestamp
    }
}

// MARK: - Terminal output
//
// Ported from Everywhere: src/Everywhere.Mcp/Tools/GetTerminalOutputTool.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809 (JSON envelope shape at
// lines 32-38 and 46-51). See `Capture/TerminalCapture.swift` for the
// port and `docs/ROADMAP/.impl-notes/phase5-terminal-2026-07-22.md` for
// the alignment audit.

/// Snapshot of the currently-focused terminal's visible scrollback.
///
/// 1:1 with Everywhere's `get_terminal_output` MCP tool payload:
///   * `isTerminal` - true iff the focused app's process name matched
///     one of the terminal heuristics (see `TerminalCapture.looksLikeTerminal`).
///   * `linesReturned` - the length of the trailing `\n`-split slice
///     actually returned. Matches C#'s `slice.Length`. NB: an empty
///     buffer produces `linesReturned == 1`, because C# `"".Split('\n')`
///     returns a single empty element - not zero. openclicky preserves
///     that quirk verbatim.
///   * `text` - the trailing-lines slice joined with `\n`. Never nil;
///     `""` is a legitimate value for empty terminals.
///
/// Wire keys are `is_terminal` / `lines_returned` / `text` (snake_case)
/// so the JSON matches the exact payload Everywhere's C# tool emits.
public struct TerminalOutputInfo: Codable, Equatable, Sendable {
    /// Did the focused app pass the terminal heuristic?
    ///
    /// Executable-name based: contains `term` / `iterm` / `ghostty` /
    /// `warp` / `alacritty` / `kitty` / `konsole` / `xterm` (case-insensitive).
    /// See `Capture/TerminalCapture.swift` for the exact substring list -
    /// it is ported verbatim from `GetTerminalOutputTool.cs:66-74`.
    public let isTerminal: Bool

    /// Number of lines actually returned in `text`. Equivalent to
    /// `text.split("\n", omittingEmptySubsequences: false).count` on
    /// success, `0` when `isTerminal == false`.
    public let linesReturned: Int

    /// Trailing-lines slice of the focused terminal's `AXValue`,
    /// joined with `\n`. Empty string when there is no terminal or
    /// the buffer is empty.
    public let text: String

    public init(isTerminal: Bool, linesReturned: Int, text: String) {
        self.isTerminal = isTerminal
        self.linesReturned = linesReturned
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case isTerminal = "is_terminal"
        case linesReturned = "lines_returned"
        case text
    }
}

// MARK: - Recent agent sessions
//
// OpenClicky-unique capability (no Everywhere source). See
// docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md row 28. Feeds the intent
// classifier so a phrase like "继续之前的" can be resolved to a specific
// prior Codex session (`long_task_existing` branch of the taxonomy at
// docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md).

/// A trimmed reference to one prior OpenClicky Codex agent session as
/// enumerated by `RecentSessionsCapture`.
///
/// Only the fields the dialog / intent-classifier layer needs are
/// carried — never the full transcript. The projectPath / projectSlug
/// pair is optional because openclicky also has "unattached" chats
/// (agent sessions with no explicit workdir, e.g. the initial
/// menu-bar session before the user drops a folder).
public struct AgentSessionRef: Codable, Sendable, Equatable {
    /// Session identifier as persisted by openclicky. Usually a UUID
    /// string (`CodexAgentSession.id.uuidString`) but callers must not
    /// rely on the exact shape — future storage formats may switch to
    /// timestamp-based IDs.
    public let id: String

    /// Absolute POSIX path of the project the session was scoped to,
    /// if any. `nil` for unscoped / free-form agent chats.
    public let projectPath: String?

    /// Canonical single-token slug for the project (matches the
    /// `.openclicky/tasks/<slug>/` layout documented in
    /// docs/ROADMAP/07_TASK_TYPE_TAXONOMY.md). `nil` when the session
    /// carries no project context.
    public let projectSlug: String?

    /// When the session was first created (its `createdAt`).
    public let startedAt: Date

    /// Most recent activity timestamp — sort key for
    /// `RecentSessionsCapture.recent`. Falls back to `startedAt` when
    /// no per-entry activity date was persisted.
    public let lastUpdatedAt: Date

    /// Coarse lifecycle state: `"running"` / `"completed"` /
    /// `"errored"` / `"unknown"`. Derived from what the persistence
    /// layer stored (e.g. `wasRelaunchResumeCandidate`), not from a
    /// live probe of the codex process.
    public let status: String

    /// First 80 characters of the user's initial task prompt, if
    /// available. Whitespace is trimmed and newlines collapsed.
    public let taskSummary: String?

    public init(
        id: String,
        projectPath: String?,
        projectSlug: String?,
        startedAt: Date,
        lastUpdatedAt: Date,
        status: String,
        taskSummary: String?
    ) {
        self.id = id
        self.projectPath = projectPath
        self.projectSlug = projectSlug
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.status = status
        self.taskSummary = taskSummary
    }
}

// MARK: - Window enumeration
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/WindowHelper.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809 (RaiseOverlayAboveTarget,
// L272-292). Everywhere's own reader only pulls pid/wid/layer off each
// CGWindowInfo dict; openclicky materialises the remaining
// documented CGWindow.h fields (title, ownerName, bounds, isOnScreen,
// alpha) so downstream tools (intent classifier, task router) can
// filter without a second CG round-trip.

/// One entry produced by `WindowEnumerationCapture.enumerateAll`.
///
/// Corresponds to one dictionary in the CFArray returned by
/// `CGWindowListCopyWindowInfo`. Fields cover the CoreGraphics
/// documented payload; `screenIndex` is a Swift-side convenience
/// (same math as `FocusedWindowCapture.displayIndex(for:)`).
///
/// Order in `[EnumeratedWindow]` matches CoreGraphics's front-to-back
/// documented ordering (see `WindowHelper.cs:291`).
public struct EnumeratedWindow: Codable, Sendable, Equatable {
    /// `kCGWindowOwnerPID` — owning process. Always > 0 for entries
    /// returned by `enumerateAll`; dicts missing this key are dropped.
    public let pid: Int32

    /// `kCGWindowNumber` — stable window ID within the WindowServer
    /// session (`CGWindowID` == `UInt32`). Always > 0; dicts missing
    /// this key are dropped, matching Everywhere's `continue` on
    /// `WindowHelper.cs:288`.
    public let wid: UInt32

    /// `kCGWindowName` when present. Missing for windows the caller
    /// isn't allowed to inspect (Screen Recording gate on macOS 15+
    /// hides titles of windows owned by other apps) or for windows
    /// that never set a title (e.g. transient popovers).
    public let title: String?

    /// `kCGWindowOwnerName` — localised app name as WindowServer
    /// sees it. Missing when the owning process has no Info.plist
    /// or is running headless.
    public let ownerName: String?

    /// `kCGWindowBounds` — window rect in Quartz global coords
    /// (top-left origin, same space as `AXPosition`). Empty
    /// (`.zero`) when the bounds dict is malformed.
    public let bounds: CGRect

    /// Largest-intersection `NSScreen.screens` index, computed with
    /// the same Cocoa->Quartz Y-flip as
    /// `FocusedWindowCapture.displayIndex(for:)`. `nil` when the
    /// window doesn't intersect any current screen (off-screen /
    /// on a disconnected display) or when `NSScreen.screens` is
    /// empty (headless).
    public let screenIndex: Int?

    /// `kCGWindowIsOnscreen`. Defaults to `true` when the enumerate
    /// call used `.optionOnScreenOnly` and the key is absent, since
    /// CoreGraphics only surfaces on-screen entries in that mode.
    public let isOnScreen: Bool

    /// `kCGWindowLayer` — WindowServer layer. 0 = normal app
    /// window; negative = below-desktop; 25 = status bar; higher
    /// = menu / dock / dragging etc. Used by
    /// `WindowHelper.RaiseOverlayAboveTarget` (L310) to pin an
    /// overlay at the same layer as its target.
    public let layer: Int

    /// `kCGWindowAlpha` in `[0.0, 1.0]`. Windows the user has
    /// made fully transparent still enumerate; caller can filter
    /// on `alpha > 0` if needed.
    public let alpha: Double

    public init(
        pid: Int32,
        wid: UInt32,
        title: String?,
        ownerName: String?,
        bounds: CGRect,
        screenIndex: Int?,
        isOnScreen: Bool,
        layer: Int,
        alpha: Double
    ) {
        self.pid = pid
        self.wid = wid
        self.title = title
        self.ownerName = ownerName
        self.bounds = bounds
        self.screenIndex = screenIndex
        self.isOnScreen = isOnScreen
        self.layer = layer
        self.alpha = alpha
    }
}


// MARK: - Screenshot
//
// Ported from Everywhere:
//   src/Everywhere.Mcp/Snapshot/ScreenshotEncoder.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//   src/Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere's `ScreenshotEncoder.cs` defines both the format enum and
// the encode-options record (Jpeg default, quality 70, 1920x1080 cap).
// We split into three public types here so callers can pass a fixed
// format without carrying the encode-options tuple, and so downstream
// stash / IPC layers can round-trip a `ScreenshotResult` (bytes + format
// + pixel dims). Numerical defaults track `ScreenshotEncodeOptions`
// verbatim.

/// Output encoding for a captured screenshot.
///
/// 1:1 with `ScreenshotFormat` (`ScreenshotEncoder.cs:7-13`):
///   * `.jpeg` — default for agent context; ~3-5x smaller than PNG,
///     lossy.
///   * `.png`  — lossless; use only when bit-perfect (OCR / diff)
///     matters.
public enum ScreenshotFormat: String, Codable, Sendable {
    case jpeg
    case png
}

/// A Quartz-space rectangle to capture. Origin is top-left (matching
/// `AXPosition` and the rect passed to `CGImage.ScreenImage` in
/// `VisualElementContext.Screenshot.cs:166-212`).
///
/// Callers can construct this directly from a `CGRect` via
/// `ScreenshotRegion(cgRect:)` — the split exists so the JSON wire
/// shape is stable (Codable Doubles) rather than depending on
/// `CGRect`'s Codable synthesis.
public struct ScreenshotRegion: Codable, Sendable, Equatable {
    /// Quartz X (top-left origin of the primary display).
    public let x: CGFloat
    /// Quartz Y (top-left origin of the primary display).
    public let y: CGFloat
    /// Width in Quartz points (must be > 0).
    public let width: CGFloat
    /// Height in Quartz points (must be > 0).
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(cgRect: CGRect) {
        self.x = cgRect.origin.x
        self.y = cgRect.origin.y
        self.width = cgRect.size.width
        self.height = cgRect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A captured screenshot ready for base64 encoding, stash write, or
/// direct upload. Corresponds to the byte payload
/// `ScreenshotEncoder.Encode` produces (`ScreenshotEncoder.cs:71-102`)
/// plus the pixel dimensions of the encoded image (Everywhere returns
/// only the byte array; we tack on dims so tests / stash callers can
/// avoid a decode round-trip).
///
/// `data` is the encoded byte stream in the reported `format`:
///   * `.jpeg` — `kUTTypeJPEG` + `kCGImageDestinationLossyCompressionQuality`.
///   * `.png`  — `kUTTypePNG`, quality flag ignored.
public struct ScreenshotResult: Sendable, Equatable {
    /// Encoded image bytes (JPEG or PNG per `format`).
    public let data: Data
    /// Encoding actually used. Matches whatever the caller requested,
    /// unless the fallback path re-encoded from a PNG (in which case
    /// the format is preserved by re-encoding through ImageIO).
    public let format: ScreenshotFormat
    /// Pixel width of the encoded image (after `ComputeSize` shrink,
    /// matches `ScreenshotEncoder.cs:104-118`).
    public let pixelWidth: Int
    /// Pixel height of the encoded image (after `ComputeSize` shrink).
    public let pixelHeight: Int

    public init(data: Data, format: ScreenshotFormat, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - Permission preflight
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/PermissionHelper.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809 (Accessibility + Screen
// Recording). openclicky extends the surface with three additional
// kinds (InputMonitoring, Microphone, Automation) that Everywhere
// checks in adjacent subsystems rather than PermissionHelper. See
// docs/ROADMAP/.impl-notes/phase5-permission-2026-07-22.md.

/// Which macOS Transparency, Consent, and Control (TCC) permission we
/// are querying. All kinds are check-only from the preflight's point of
/// view - `PermissionPreflight.check(_:)` never triggers a system
/// prompt.
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    /// AX API access. Backed by `AXIsProcessTrusted()`.
    case accessibility
    /// `CGWindowList*` / `SCScreenCapture*`. Backed by
    /// `CGPreflightScreenCaptureAccess()`.
    case screenRecording
    /// Global keyboard / hotkey listening. Backed by
    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
    case inputMonitoring
    /// AVCaptureDevice audio input. Backed by
    /// `AVCaptureDevice.authorizationStatus(for: .audio)`.
    case microphone
    /// AppleEvents automation of another app. Backed by
    /// `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`.
    /// Requires a target bundle id supplied through
    /// `PermissionPreflight.check(_:automationTargetBundleId:)`.
    case automation
}

/// Result of a permission preflight check. Values map to the union of
/// the states surfaced by TCC-facing APIs on macOS. For APIs that only
/// return a `Bool` (`AXIsProcessTrusted`,
/// `CGPreflightScreenCaptureAccess`), only `.granted` and `.denied`
/// are reachable.
public enum PermissionStatus: String, Codable, Sendable, Equatable {
    /// Access is confirmed available.
    case granted
    /// Access is confirmed unavailable (user explicitly denied or the
    /// bool-only API reported "not trusted").
    case denied
    /// The user has not been asked yet. Only reachable through APIs
    /// that expose this state explicitly (Microphone, InputMonitoring,
    /// Automation with error code -1744).
    case notDetermined
    /// MDM / parental controls / config-profile block the grant.
    /// Reachable through `AVAuthorizationStatus.restricted`.
    case restricted
    /// The underlying API returned a value we cannot classify (future
    /// AVAuthorizationStatus case, unrecognised OSStatus, missing
    /// automation target).
    case unknown
}

// MARK: - Vision OCR
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/MacVisionOcrEngine.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Everywhere models one recognised text line as `OcrLine(Text, Bounds,
// Confidence)` in `Everywhere.Interop.Whiteboard`. openclicky mirrors
// that record and adds a wrapper `OCRResult` so callers can distinguish
// "OCR failed" (nil) from "OCR succeeded but yielded zero lines"
// (`OCRResult(lines: [])`). Everywhere collapses both to an empty list.

/// One recognised text line returned by Vision OCR.
///
/// 1:1 with Everywhere's `OcrLine` record (`Text`, `Bounds`,
/// `Confidence`). The `bounds` field is in image-local pixel space
/// (origin at the image's upper-left corner, integer-rounded,
/// width/height clamped to `>= 1`). Everywhere translates the bounding
/// box by an `originPx` argument so the output ends up in screen-pixel
/// space; openclicky keeps the box in image-local space and lets
/// callers translate to screen coordinates themselves (they already
/// know the crop origin).
public struct OCRLine: Codable, Equatable, Sendable {
    /// Recognised text from the top-1 Vision candidate. May be empty
    /// when Vision returned a candidate with a nil string
    /// (matches Everywhere's `cands[0].String ?? string.Empty`).
    public let text: String

    /// Axis-aligned bounding box in image-local pixel space, upper-left
    /// origin. Width and height are clamped to `>= 1`; x/y are the
    /// integer-rounded translation of Vision's normalised
    /// `boundingBox`. Stored as `CGRect` for downstream drawing / hit
    /// testing.
    public let bounds: CGRect

    /// Confidence of the top-1 candidate as reported by Vision
    /// (`VNRecognizedText.confidence`), in the range `0.0 ... 1.0`.
    public let confidence: Float

    public init(text: String, bounds: CGRect, confidence: Float) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
    }
}

/// Result of a single OCR pass over one image.
///
/// A non-nil `OCRResult` means Vision ran to completion. `lines.isEmpty`
/// is a valid, non-error state (e.g. blank image, no legible text).
/// `OCRCapture.ocr` returns `nil` when the image could not be decoded
/// or when Vision itself threw — see the header of `OCRCapture.swift`.
///
/// Lines are ordered by ascending `bounds.origin.y` (top-to-bottom on
/// upper-left origin axes), matching Everywhere's final sort:
///   `lines.Sort((a, b) => a.Bounds.Y.CompareTo(b.Bounds.Y))`.
public struct OCRResult: Codable, Equatable, Sendable {
    public let lines: [OCRLine]

    public init(lines: [OCRLine]) {
        self.lines = lines
    }
}

// MARK: - Browser tabs
//
// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/IBrowserTabsReader.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809. Everywhere models
// `BrowserTabsResult(Status, Tabs, ErrorMessage?)` with a tri-state
// status enum (Ok/PermissionDenied/NotSupported). Layer 0 in openclicky
// collapses non-Ok statuses to `nil` at the capture boundary — matching
// sibling captures (FinderSelection, BrowserURL) — so we only surface
// the `Ok` shape here. Callers needing the finer distinction can build
// on the stub-friendly internal entry point in `BrowserTabsCapture`.

/// One tab reported by a browser via AppleScript.
///
/// 1:1 with Everywhere's `BrowserTab(Title, Url, IsActive)` record.
/// `isActive` is `true` on the frontmost tab of its window; Arc reports
/// every entry with `isActive == false` because its scripting dictionary
/// exposes no active-tab query (see comment on `BrowserTabsCapture.buildArcScript`).
public struct BrowserTab: Codable, Equatable, Sendable {
    /// Tab title. Safari uses `name of t`, Chromium/Arc use `title of t`.
    /// Never contains `\u{1E}` or `\u{1F}` (those bytes are wire separators).
    public let title: String

    /// Tab URL as reported by AppleScript (no scheme normalisation).
    public let url: String

    /// Whether this tab is the active/foreground one in its window.
    /// Always `false` for Arc entries.
    public let isActive: Bool

    public init(title: String, url: String, isActive: Bool) {
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

/// Snapshot of every open tab across every window of a supported browser.
///
/// Corresponds to Everywhere's `BrowserTabsResult` in the `Ok` branch. A
/// non-nil instance means the AppleScript ran; `tabs` may still be empty
/// (browser is running but has no windows / no tabs). `app` is the
/// canonical AppleScript application name (e.g. `Google Chrome`, `Safari`,
/// `Arc`) rather than a bundle identifier, matching what was actually
/// tell'd against.
public struct BrowserTabsInfo: Codable, Equatable, Sendable {
    /// Canonical AppleScript app name the tabs were read from.
    /// One of: `Safari`, `Arc`, `Google Chrome`, `Brave Browser`,
    /// `Microsoft Edge`, `Chromium`, `Vivaldi`, `Opera`.
    public let app: String

    /// Tabs in Finder-style enumeration order: outer loop over `windows`,
    /// inner loop over `tabs of w`. Empty means the browser is running
    /// but has no open tabs (or all windows were closed between the
    /// `windows` enumeration and the `tabs of w` call).
    public let tabs: [BrowserTab]

    public init(app: String, tabs: [BrowserTab]) {
        self.app = app
        self.tabs = tabs
    }
}

// MARK: - AX quirks installer
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/AXUIElement.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809, backing types for
// `Capture/AXQuirksInstaller.swift`.
//
// Everywhere's counterpart (`SetAppBoolAttribute`, L1178-1203) is a bool-
// returning primitive with no accompanying value type — the caller
// (`VisualElementContext.TryEnableBestEffortAccessibility` +
// `AppResolver.EnsureA11yEnabledOnce`) simply memoises the pid in a
// `ConcurrentDictionary<int, bool>`. Openclicky surfaces that
// per-pid memoisation state as a Codable struct so router / stash
// callers can read "did we already install quirks for this pid" without
// probing the installer lock — see roadmap row 20 in
// `docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`.

/// Per-pid record of a completed accessibility-quirks install.
///
/// Emitted by `AXQuirksInstaller.installIfNeeded(pid:)` on the first
/// successful call for a given process. Never mutated afterwards —
/// re-installing on the same pid is a no-op in Everywhere and this
/// port, so the timestamp is authoritative for "when did we upgrade
/// this app's AX subsystem".
///
/// Field semantics mirror Everywhere's implicit contract:
///   * `pid` — always the value passed to `installIfNeeded`; `> 0`.
///   * `manualAccessibilityApplied` / `enhancedUserInterfaceApplied` —
///     both `true` when this struct exists, because openclicky's
///     installer is all-or-nothing (see the "Deviations" table in
///     `.impl-notes/phase5-axquirks-2026-07-22.md`). The fields are
///     modelled explicitly rather than collapsed to a single flag so
///     future ports of Everywhere's partial-success semantic can
///     land here without a schema change.
///   * `installedAt` — Unix timestamp (seconds) of the successful
///     install. Same clock domain as the other capture info tuples
///     (`Date().timeIntervalSince1970`).
public struct AXQuirkInfo: Codable, Equatable, Sendable {
    public let pid: Int32
    public let manualAccessibilityApplied: Bool
    public let enhancedUserInterfaceApplied: Bool
    public let installedAt: Double

    public init(
        pid: Int32,
        manualAccessibilityApplied: Bool,
        enhancedUserInterfaceApplied: Bool,
        installedAt: Double
    ) {
        self.pid = pid
        self.manualAccessibilityApplied = manualAccessibilityApplied
        self.enhancedUserInterfaceApplied = enhancedUserInterfaceApplied
        self.installedAt = installedAt
    }
}

// MARK: - Cursor + Element under cursor
//
// Ported from Everywhere: `src/Everywhere.Mac/Interop/VisualElementContext.cs`
// (`ElementFromPointer` / `ElementFromPoint`) and
// `src/Everywhere.Mac/Interop/AXUIElement.cs` (`ElementAtPosition`,
// `BoundingRectangle`) @30e03e9dcfdd4247fd679828ed86e9042f32d809.

/// Global cursor position at the moment of capture.
///
/// `point` is a **global Quartz** CGPoint (top-left origin) — the same
/// space that `AXUIElementCopyElementAtPosition` accepts. Callers that
/// need Cocoa coordinates (bottom-left origin) can convert via
/// `NSScreen.main`.
///
/// Everywhere reference: `VisualElementContext.ElementFromPointer`
/// (`VisualElementContext.cs:48-67`) which reads `NSEvent.CurrentMouseLocation`
/// (Cocoa) and flips Y before handing to AX.
public struct CursorPosition: Codable, Sendable, Equatable {
    /// Global Quartz coordinate (top-left origin). Matches Everywhere's
    /// `PixelPoint` argument to `ElementFromPoint`.
    public let point: CGPoint

    /// Index into `NSScreen.screens` for the display containing the cursor.
    /// Same computation as `FocusedWindowCapture.displayIndex`; largest
    /// positive-area intersection wins in an overlap. `-1` when there are
    /// no screens (headless).
    public let displayIndex: Int

    /// Unix timestamp (seconds) of the capture. Same clock domain as the
    /// other capture info tuples (`Date().timeIntervalSince1970`).
    public let capturedAtUnix: Double

    public init(point: CGPoint, displayIndex: Int, capturedAtUnix: Double) {
        self.point = point
        self.displayIndex = displayIndex
        self.capturedAtUnix = capturedAtUnix
    }
}

/// Snapshot of the AX element under a given screen point.
///
/// Everywhere reference: `VisualElementContext.ElementFromPoint`
/// (`VisualElementContext.cs:16-46`) invoking
/// `AXUIElement.SystemWide.ElementAtPosition(x, y)`
/// (`AXUIElement.cs:1135-1139`). The individual fields correspond to
/// the getters Everywhere exposes on the returned `AXUIElement`:
/// `ProcessId` / `Role` / `Subrole` / `Name` / `Value` /
/// `BoundingRectangle` (`AXUIElement.cs:116,118,257-283,448-465,467`).
///
/// All fields except `pid` and `bounds` are optional because the AX
/// element may legitimately omit them (matches Everywhere's implicit
/// null returns from `GetAttribute<T>`).
public struct ElementUnderCursorInfo: Codable, Sendable, Equatable {
    /// Owning process id, from `AXUIElementGetPid`. `0` when the ref
    /// belongs to no process (systemwide sentinel).
    public let pid: Int32

    /// `AXRole` string (e.g. `"AXButton"`, `"AXWindow"`).
    public let role: String?

    /// `AXSubrole` string (e.g. `"AXCloseButton"`).
    public let subrole: String?

    /// `AXTitle` string. Narrow port of Everywhere's `Name` cascade —
    /// see the port header of `ElementUnderCursorCapture.swift` for why
    /// only `AXTitle` is read on the hit-test path.
    public let title: String?

    /// `AXValue` coerced to a string. Matches
    /// `AXUIElement.cs:281 var v = GetAttribute<NSObject>(Value)?.ToString()`.
    public let value: String?

    /// `AXPosition` + `AXSize` combined into a Quartz-top-left `CGRect`.
    /// Falls back to `.zero` when either attribute is missing/unreadable,
    /// mirroring `QueryBoundingRectangle` (`AXUIElement.cs:448-465`).
    public let bounds: CGRect

    /// Owning app's bundle identifier, resolved via
    /// `NSRunningApplication(processIdentifier:)`. Nil for helpers /
    /// CLI processes without an Info.plist.
    public let bundleId: String?

    public init(
        pid: Int32,
        role: String?,
        subrole: String?,
        title: String?,
        value: String?,
        bounds: CGRect,
        bundleId: String?
    ) {
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.bounds = bounds
        self.bundleId = bundleId
    }
}

// MARK: - Focused element
//
// Ported from Everywhere:
//   src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//   src/Everywhere.Mac/Interop/AXUIElement.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Focused-element detail snapshot. Everywhere models the focused element
// through the same `IVisualElement` interface it uses for every AX node
// (see `VisualElementContext.FocusedElement`, VisualElementContext.cs:12),
// then reads the per-attribute getters ad hoc in SnapshotRenderer + tree
// walker. openclicky materialises the interesting subset into a Codable
// value type so downstream stash / IPC / route dispatch can round-trip
// the reading without holding a live AX ref.
//
// Field extraction 1:1 with AXUIElement.cs:
//   * role         - `AXRole`                                (L494)
//   * subrole      - `AXSubrole`                             (L496)
//   * title        - `AXTitle` raw                           (L268)
//   * name         - `Name` cascade (title/desc/help/value/  (L257-315)
//                     titleUIElement/first-static-text/id)
//   * value        - `AXValue` (checkbox 0/1 mapping,        (L549-556)
//                     nil for AXSecureTextField subrole)
//   * placeholder  - `AXPlaceholderValue`                    (L374)
//   * help         - `AXHelp`                                (L272)
//   * description  - `AXDescription`                         (L369)
//   * states       - `States` bit flags flattened to        (L218-251)
//                     lowercase string list
//   * actions      - `SupportedActions` filtered through    (L507+ /
//                     SnapshotActionFilter                    SnapshotActionFilter.cs)
//   * bounds       - `BoundingRectangle`                    (L430-465)
//   * isSecure     - `Subrole == AXSecureTextField`         (L242)
//
// Deviation from Everywhere: password fields return value=nil (never
// leak). Everywhere's raw `GetText` returns the AXValue verbatim; the
// snapshot writer elides it downstream. We eliminate the leak at the
// capture boundary.

/// Snapshot of the AX element that currently owns keyboard focus for a
/// given process. Populated by `FocusedElementCapture.capture(pid:)`.
///
/// A `nil` return from `capture` means the pid was `<= 0`, the AX app
/// element could not be created (rare — usually AX consent missing), or
/// `AXFocusedUIElement` was absent. Present instance guarantees `role`
/// is non-empty; every other field may legitimately be nil / empty.
public struct FocusedElementInfo: Codable, Sendable, Equatable {
    /// Owning process id.
    public let pid: Int32

    /// `AXRole` string (e.g. `"AXTextField"`). Always non-empty when
    /// this struct exists.
    public let role: String

    /// `AXSubrole` string (e.g. `"AXSecureTextField"`, `"AXSearchField"`).
    /// Nil when the element advertises no subrole.
    public let subrole: String?

    /// Raw `AXTitle`. May be nil while `name` is non-nil (label came
    /// from a later cascade step).
    public let title: String?

    /// Best-effort human-visible label. Cascade order matches
    /// `AXUIElement.Name` (AXUIElement.cs:257-315):
    /// `AXTitle` -> `AXDescription` -> `AXHelp` -> (label-bearing role)
    /// `AXValue` -> `AXTitleUIElement.Value` -> `AXTitleUIElement.Title`
    /// -> first `AXStaticText` child value/title -> `AXIdentifier`.
    public let name: String?

    /// `AXValue` coerced to a string. `nil` when the value is missing,
    /// unrecoverable, OR the element is a secure text field
    /// (`subrole == "AXSecureTextField"`) — the latter is a deliberate
    /// leak guard, stricter than Everywhere's implicit behaviour.
    /// `AXCheckBox` values map `"0"` -> `"false"` else `"true"`, matching
    /// `AXUIElement.GetText` (AXUIElement.cs:555).
    public let value: String?

    /// `AXPlaceholderValue` — placeholder copy on text fields / search
    /// bars (AXUIElement.cs:374).
    public let placeholder: String?

    /// Raw `AXHelp` — tooltip / accessibility hint copy.
    public let help: String?

    /// Raw `AXDescription` — VoiceOver-friendly extended description
    /// (AXUIElement.cs:369).
    public let description: String?

    /// Flag bits from `AXUIElement.States` (AXUIElement.cs:218-251) as
    /// lowercase strings. Possible entries, in the enum order Everywhere
    /// emits: `disabled`, `selected`, `expanded`, `focused`, `offscreen`
    /// (== `AXHidden`), `password` (== `AXSecureTextField` subrole),
    /// `checked` (numeric `AXValue > 0` on `AXCheckBox` / `AXRadioButton`).
    /// Empty when the element carries none of the tracked traits.
    public let states: [String]

    /// Meaningful action verbs advertised by the element, filtered
    /// through Everywhere's `SnapshotActionFilter.Filter` whitelist
    /// (`SnapshotActionFilter.cs:17-21`): `Press`, `Confirm`, `Open`,
    /// `ShowMenu`, `Increment`, `Decrement`, `Pick`, `Cancel`, `Delete`,
    /// `Raise`. `AX` prefix stripped, order-preserving, deduped.
    public let actions: [String]

    /// `AXPosition` + `AXSize` combined into a Quartz top-left `CGRect`
    /// via `AXValueGetValue` (`AXUIElement.cs:430-465`). `.zero` when
    /// either attribute is missing or unwrap fails.
    public let bounds: CGRect

    /// Convenience mirror of `subrole == "AXSecureTextField"`
    /// (AXUIElement.cs:242). When true, `value` is always nil regardless
    /// of what AX reports — never leak keystrokes.
    public let isSecure: Bool

    public init(
        pid: Int32,
        role: String,
        subrole: String?,
        title: String?,
        name: String?,
        value: String?,
        placeholder: String?,
        help: String?,
        description: String?,
        states: [String],
        actions: [String],
        bounds: CGRect,
        isSecure: Bool
    ) {
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.title = title
        self.name = name
        self.value = value
        self.placeholder = placeholder
        self.help = help
        self.description = description
        self.states = states
        self.actions = actions
        self.bounds = bounds
        self.isSecure = isSecure
    }
}

// MARK: - Layer 4 UX stash types (PickStash / AnnotationStash)
//
// Ported from Everywhere: src/Everywhere.Core/Interop/PickStash.cs +
// src/Everywhere.Core/Interop/AnnotationStash.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere's `PickStash` holds an `IVisualElement` (heavy AX object).
// openclicky's port stores a lightweight value snapshot instead so the
// stash stays UI-actor-free and portable across Swift concurrency
// boundaries. Fields track what `PickStash` callers actually read
// downstream (`ProcessId`, role, `Name`, `BoundingRectangle`, bundle id
// resolved from pid). Rich AX walk-and-render still happens on the
// live element at MCP `read_pick` time; the stash just carries the id.

/// Value snapshot of a UI element the user just "pinned" via the
/// Agent Pick hotkey. Populated by the AX capture path, consumed by
/// downstream MCP tooling. Immutable so the stash slot can be handed
/// across threads without copy hazards.
///
/// Corresponds to Everywhere's `IVisualElement` reference stored in
/// `PickStash._current` (PickStash.cs:18, 42-51).
public struct PickedElement: Codable, Sendable, Equatable {
    /// Owning process id, matches `IVisualElement.ProcessId`.
    public let pid: Int32
    /// `AXRole` string (e.g. `"AXButton"`).
    public let role: String?
    /// `AXTitle` or accessibility name.
    public let title: String?
    /// `AXValue` coerced to string when available.
    public let value: String?
    /// Bounding rectangle in Quartz top-left coordinates.
    public let bounds: CGRect
    /// Owning app's bundle id resolved via `NSRunningApplication`.
    public let bundleId: String?
    /// UTC capture instant.
    public let capturedAt: Date

    public init(
        pid: Int32,
        role: String?,
        title: String?,
        value: String?,
        bounds: CGRect,
        bundleId: String?,
        capturedAt: Date = Date()
    ) {
        self.pid = pid
        self.role = role
        self.title = title
        self.value = value
        self.bounds = bounds
        self.bundleId = bundleId
        self.capturedAt = capturedAt
    }
}

/// Kind of perception channel the annotation is anchored to. Lets the
/// LLM tell at a glance whether the user pointed (pin), framed
/// (whiteboard), highlighted (selected) or harvested (linkrect).
///
/// 1:1 with Everywhere's `AnnotationSource` enum
/// (AnnotationStash.cs:10-16). Wire strings picked to match
/// `ReadAnnotationsTool.SourceToWire` (ReadAnnotationsTool.cs:35-42)
/// so JSON payloads round-trip unchanged.
public enum AnnotationSource: String, Codable, Sendable, CaseIterable {
    case pin
    case whiteboard
    case selected
    case linkRect = "linkrect"
}

/// One user-authored annotation attached to a perception anchor.
///
/// 1:1 with Everywhere's `AnnotationItem` record
/// (AnnotationStash.cs:37-42). `anchorLabel` is resolved at append
/// time and never re-resolved, so the label survives even after the
/// underlying source stash (pin, whiteboard, ...) expires.
public struct AnnotationItem: Codable, Sendable, Equatable {
    /// Which perception channel produced this anchor.
    public let source: AnnotationSource
    /// The free-form note the user typed (or dictated).
    public let body: String
    /// Opaque id the source-specific stash uses to look the anchor
    /// back up (e.g. `element_index` for a pin). May be nil for
    /// sources that use a latest-only model.
    public let anchorRef: String?
    /// Short human-readable description shown to the LLM verbatim
    /// (e.g. `AXButton "Submit"`). Frozen at capture time.
    public let anchorLabel: String
    /// UTC time the annotation was authored.
    public let capturedAt: Date

    public init(
        source: AnnotationSource,
        body: String,
        anchorRef: String?,
        anchorLabel: String,
        capturedAt: Date = Date()
    ) {
        self.source = source
        self.body = body
        self.anchorRef = anchorRef
        self.anchorLabel = anchorLabel
        self.capturedAt = capturedAt
    }
}

// MARK: - Screen list
//
// Ported from Everywhere: src/Everywhere.Mac/Interop/NSScreenVisualElement.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Everywhere's `NSScreenVisualElement` wraps one `NSScreen` and exposes
// `Id`, `Name`, and `BoundingRectangle` (the Cocoa->Quartz y-flip lives
// at L57-67). openclicky materialises those fields into a plain value
// type so the enumeration result can be Codable, cross-process, and
// stash-writable.
//
// Field extraction order matches the C# getters exactly:
//   * displayID <- NSScreenNumber (L167 GetScreenNumber)
//   * name      <- LocalizedName (L51)
//   * frame*    <- Frame with the y-flip at L62-64
// Openclicky-side additions (`index`, `isPrimary`, `visibleFrameQuartz`,
// `backingScaleFactor`) are documented in
// `docs/ROADMAP/.impl-notes/phase5-screenlist-2026-07-23.md`.

/// Snapshot of one connected display.
///
/// One-to-one with Everywhere's `NSScreenVisualElement`:
///   * `displayID` — `CGDirectDisplayID` decoded from
///     `deviceDescription[NSScreenNumber]`, matching `GetScreenNumber`
///     in `NSScreenVisualElement.cs:165-168`.
///   * `name` — `NSScreen.localizedName` (macOS 10.15+), same source
///     as `Name` (L51).
///   * `frameCocoa` — raw `NSScreen.frame` (Cocoa bottom-left origin),
///     kept for round-trip debug so callers can verify the y-flip.
///   * `frameQuartz` — global Quartz top-left rect after the
///     `primary.height - (frame.y + frame.height)` flip
///     (`NSScreenVisualElement.cs:62-64`).
///   * `visibleFrameQuartz` — `NSScreen.visibleFrame` (frame minus menu
///     bar / dock) with the same y-flip. Not present in Everywhere;
///     openclicky needs it so the HUD placer does not reintroduce the
///     Cocoa->Quartz math per call site.
///   * `backingScaleFactor` — `NSScreen.backingScaleFactor`. Not read
///     by Everywhere here (it lives on `SnapshotRenderer`); carried
///     because the Screenshot path needs it for pixel dims.
///
/// `index` and `isPrimary` are pure functions of position in
/// `NSScreen.screens` (`isPrimary == index == 0`). Everywhere computes
/// them ad-hoc in `ScreenSiblingAccessor.EnsureResources`
/// (`NSScreenVisualElement.cs:175-180`); we materialise both so
/// downstream code does not have to reproduce the AppKit invariant that
/// `NSScreen.screens[0]` is the menu-bar / primary display.
///
/// An entry may have a negative `frameQuartz.origin.y` — that happens
/// when a secondary display is positioned *above* the primary in the
/// user's Cocoa arrangement. Callers must not assert non-negativity.
public struct ScreenInfo: Codable, Sendable, Equatable {
    /// `CGDirectDisplayID`, decoded from `NSScreenNumber`.
    /// Zero would be the "no display" sentinel; entries returned by
    /// `ScreenListCapture.enumerateAll()` always carry a non-zero id
    /// (missing / non-numeric `NSScreenNumber` short-circuits the entry).
    public let displayID: UInt32

    /// Position in `NSScreen.screens` at capture time. `0` == primary.
    public let index: Int

    /// `NSScreen.localizedName`. `nil` when the OS reports an empty or
    /// whitespace-only string (rare, but observed on some virtual
    /// displays and headless bridges).
    public let name: String?

    /// Global Quartz-space rect, top-left origin. Same coordinate
    /// space as `AXPosition`, `kCGWindowBounds`, and the rect passed
    /// to `CGImage.ScreenImage`.
    public let frameQuartz: CGRect

    /// Global Cocoa-space rect, bottom-left origin. Preserved verbatim
    /// so a caller can independently re-derive `frameQuartz` via
    /// `primaryCocoaHeight - (y + height)`.
    public let frameCocoa: CGRect

    /// `NSScreen.visibleFrame` with the Cocoa->Quartz y-flip applied.
    /// Excludes menu-bar and dock reservations on displays that have
    /// them.
    public let visibleFrameQuartz: CGRect

    /// `NSScreen.backingScaleFactor` (1.0 non-Retina, 2.0 Retina).
    public let backingScaleFactor: CGFloat

    /// `index == 0`. Cached for callers.
    public let isPrimary: Bool

    public init(
        displayID: UInt32,
        index: Int,
        name: String?,
        frameQuartz: CGRect,
        frameCocoa: CGRect,
        visibleFrameQuartz: CGRect,
        backingScaleFactor: CGFloat,
        isPrimary: Bool
    ) {
        self.displayID = displayID
        self.index = index
        self.name = name
        self.frameQuartz = frameQuartz
        self.frameCocoa = frameCocoa
        self.visibleFrameQuartz = visibleFrameQuartz
        self.backingScaleFactor = backingScaleFactor
        self.isPrimary = isPrimary
    }
}

// MARK: - DocReaderResult
//
// Corresponds to Everywhere's `DocReaderResult` shared helper in
// `src/Everywhere.Mcp/Tools/DocReaderResult.cs @30e03e9d`. That helper
// returns a JSON blob shaped `{text, metadata:{...}}`; the OpenClicky
// captures instead surface a strongly-typed value so callers do not have
// to reparse JSON. Per-format metadata (paragraphs, sheets, slides,
// chapters, title, author) that does not slot into `pageCount` or
// `wordCount` is emitted as `warnings` entries with a `key=value` prefix
// so no signal is lost.

/// Result of any Layer-2 doc reader (`DocReadPdf`, `DocReadDocx`, ...).
///
/// Mirrors the Everywhere `{text, metadata}` shape but flattens the
/// metadata to two typed slots (`pageCount`, `wordCount`) plus a
/// free-form `warnings` list. `mimeType` is always populated so callers
/// can round-trip the reader identity without re-inspecting the path.
public struct DocReaderResult: Codable, Sendable, Equatable {
    public let text: String
    public let pageCount: Int?
    public let wordCount: Int?
    public let mimeType: String
    public let warnings: [String]

    public init(
        text: String,
        pageCount: Int? = nil,
        wordCount: Int? = nil,
        mimeType: String,
        warnings: [String] = []
    ) {
        self.text = text
        self.pageCount = pageCount
        self.wordCount = wordCount
        self.mimeType = mimeType
        self.warnings = warnings
    }
}

/// Structured error surface for the doc readers. Everywhere's `.cs`
/// files swallow all exceptions into `ToolErrors.Error("...")`; the
/// Swift port keeps the reasons discriminable so tests can assert on
/// them.
public enum DocReaderError: Error, Equatable, Sendable {
    case fileNotFound(String)
    case archiveInvalid(String)
    case parseFailed(String)
    case encodingFailed(String)
}

// MARK: - Meta tools (self-expanding registry, BM25 search, batch, strategy notes)
//
// Ported from Everywhere: src/Everywhere.Mcp/Tools/MetaTools.cs +
// src/Everywhere.Mcp/Tools/GateTools.cs +
// src/Everywhere.Mcp/Tools/BatchTool.cs +
// src/Everywhere.Mcp/Meta/Bm25Index.cs +
// src/Everywhere.Mcp/Meta/TierGate.cs +
// src/Everywhere.Mcp/OpenCli/Memory/Schemas.cs (StrategyNote)
// @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// These value types back the meta-tool surface used by the sensor MCP
// bridge (`/mcp/sensor`). Pure value types only — no I/O, no bridge
// coupling. The bridge integration lives in
// `OpenClickyExternalControlBridge.swift` (a separate Phase-2 task).

/// One entry in the meta-tool registry. Corresponds conceptually to
/// Everywhere's per-tool `[McpServerTool]` descriptor pair (name +
/// `[Description]`) plus the `TierGate.Domains` bucket the tool lives
/// in. `isHidden` reflects whether the CoreToolGate/self-expand gate
/// would hide it from the default `tools/list`.
public struct MetaToolDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    /// Domain the tool is filed under (e.g. `core`, `browser`,
    /// `doc_readers`). See `OpenClickyMetaTools.knownDomains`.
    public let domain: String
    /// True when the tool is hidden from the default `tools/list`.
    /// Core-tier tools have `isHidden == false`; long-tail tools
    /// default to `true` until the enclosing domain is activated (or
    /// `OPENCLICKY_MCP_FULL=1` is set).
    public let isHidden: Bool

    public init(name: String, description: String, domain: String, isHidden: Bool) {
        self.name = name
        self.description = description
        self.domain = domain
        self.isHidden = isHidden
    }
}

/// Domain grouping + activation status. Mirrors the entries returned by
/// Everywhere `list_domains` (`SearchTools.cs:143-166`). The `active`
/// flag is process-persistent via `UserDefaults` (Everywhere keeps it
/// per HTTP session in `SessionActivations`; openclicky's sensor bridge
/// is single-session per process).
public struct DomainInfo: Codable, Equatable, Sendable {
    public let name: String
    public let toolCount: Int
    public let isActive: Bool

    public init(name: String, toolCount: Int, isActive: Bool) {
        self.name = name
        self.toolCount = toolCount
        self.isActive = isActive
    }
}

/// One BM25 hit. 1:1 with Everywhere `Bm25Index.Hit` (`Bm25Index.cs:14`)
/// with a `domain` tag added so callers can render the tier chip
/// without a second lookup.
public struct ScoredToolMatch: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let score: Double
    public let domain: String

    public init(name: String, description: String, score: Double, domain: String) {
        self.name = name
        self.description = description
        self.score = score
        self.domain = domain
    }
}

/// One entry in a batched tool sequence. Mirrors Everywhere
/// `BatchTool.Batch`'s per-step `{tool, args}` shape
/// (`BatchTool.cs:62-67`).
public struct BatchStep: Codable, Equatable, Sendable {
    public let tool: String
    /// Raw JSON string for the arguments object. Kept as a string to
    /// avoid dragging a JSON-value type into the shared type module;
    /// callers parse via `JSONSerialization` as needed. May be nil for
    /// tools that take no args (equivalent to Everywhere's absent
    /// `args` node).
    public let argumentsJson: String?

    public init(tool: String, argumentsJson: String? = nil) {
        self.tool = tool
        self.argumentsJson = argumentsJson
    }
}

/// Outcome of one step in a batched call. Mirrors the per-index entry
/// in Everywhere `BatchTool.Batch`'s `results` array
/// (`BatchTool.cs:96-100`). `resultJson` is the raw JSON returned by
/// the target tool; `errorMessage` is populated iff the step failed.
public struct BatchResult: Codable, Equatable, Sendable {
    public let tool: String
    public let ok: Bool
    public let resultJson: String?
    public let errorMessage: String?

    public init(tool: String, ok: Bool, resultJson: String? = nil, errorMessage: String? = nil) {
        self.tool = tool
        self.ok = ok
        self.resultJson = resultJson
        self.errorMessage = errorMessage
    }
}

/// SPEC §Phase 3 evidence-backed strategy note. 1:1 with Everywhere
/// `StrategyNote` (`OpenCli/Memory/Schemas.cs:30-48`). Openclicky
/// stores these under the same JSON shape so notes round-trip with
/// Everywhere's memory store.
public struct StrategyNote: Codable, Equatable, Sendable {
    public let strategy: String
    public let contract: String
    public let evidence: [String]
    public let replay: String
    public let mutation: Bool
    public let createdAt: Int64

    public init(
        strategy: String = "public",
        contract: String = "stable",
        evidence: [String] = [],
        replay: String = "",
        mutation: Bool = false,
        createdAt: Int64 = 0
    ) {
        self.strategy = strategy
        self.contract = contract
        self.evidence = evidence
        self.replay = replay
        self.mutation = mutation
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case strategy
        case contract
        case evidence
        case replay
        case mutation
        case createdAt = "created_at"
    }

    /// Returns `true` when every required field passes the SPEC §Phase 3
    /// completeness rules (`Schemas.cs:39-47`):
    /// * evidence: >= 3 items, each >= 20 chars.
    /// * replay: >= 50 chars.
    /// * strategy in {public, cookie, intercept, ui}.
    /// * contract in {stable, visible-ui, internal-unstable}.
    /// Populates `missing` with the failing field names on `false`.
    public func isComplete(missing: inout [String]) -> Bool {
        missing = []
        if evidence.count < 3 || evidence.contains(where: { $0.count < 20 }) {
            missing.append("evidence")
        }
        if replay.count < 50 {
            missing.append("replay")
        }
        if !["public", "cookie", "intercept", "ui"].contains(strategy) {
            missing.append("strategy")
        }
        if !["stable", "visible-ui", "internal-unstable"].contains(contract) {
            missing.append("contract")
        }
        return missing.isEmpty
    }
}

// MARK: - Whiteboard stash payload
//
// Ported from Everywhere: src/Everywhere.Core/Interop/Whiteboard/WhiteboardRegion.cs
// and WhiteboardStash.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// The Everywhere `WhiteboardRegion` record ships the AnnotationKind enum
// plus the a11y leaves, per-line OCR detections, and image leaves. The
// Layer-4 stash only needs the ship-across-the-wire shape (id, bbox,
// gesture, ocr text, captured-at). Overlay / gesture-classifier types
// live in Phase 7 as separate value types so this file stays scoped to
// the stash contract.

/// One annotated region a user just drew on the whiteboard.
///
/// Field semantics track the Everywhere source:
///   * `id` — assigned when the region is committed by the overlay so
///     the image side-table can key by it (Everywhere uses `image_id`
///     strings; the Swift port uses `UUID` and stringifies at the JSON
///     boundary).
///   * `bboxScreen` — Quartz global rect (top-left origin), matching
///     Everywhere `WhiteboardRegion.Rect` after Cocoa→Quartz flip.
///   * `gestureKind` — one of `"circle"`, `"x"`, `"arrow"`,
///     `"underline"`. String rather than an enum here because the
///     classifier's exact taxonomy is still Phase 7 work; the stash
///     just round-trips whatever the overlay recorded.
///   * `ocrText` — merged OCR text covering the region, or `nil` if the
///     OCR engine returned nothing / was the no-op stub.
///   * `capturedAtUnix` — POSIX seconds when the overlay committed the
///     region. The stash uses its own expiry timestamp (TTL from the
///     `set()` call time), so this field is diagnostic only.
public struct WhiteboardRegion: Codable, Sendable, Equatable {
    public let id: UUID
    public let bboxScreen: CGRect
    public let gestureKind: String
    public let ocrText: String?
    public let capturedAtUnix: Double

    public init(
        id: UUID = UUID(),
        bboxScreen: CGRect,
        gestureKind: String,
        ocrText: String? = nil,
        capturedAtUnix: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.bboxScreen = bboxScreen
        self.gestureKind = gestureKind
        self.ocrText = ocrText
        self.capturedAtUnix = capturedAtUnix
    }
}

/// One image bytes entry in the WhiteboardStash side-table. Mirrors the
/// `Dictionary<string, byte[]>` + `_imageBytesExpiresAtUtc` pair in
/// `WhiteboardStash.cs:23-24` but folds the shared TTL into each entry
/// so the Swift stash can do a single-map lookup with per-entry expiry
/// checks (semantically equivalent — every entry inserted by one `set`
/// call carries the same `expiresAtUnix`).
public struct WhiteboardImageEntry: Sendable, Equatable {
    public let id: UUID
    public let pngBytes: Data
    public let expiresAtUnix: Double

    public init(id: UUID, pngBytes: Data, expiresAtUnix: Double) {
        self.id = id
        self.pngBytes = pngBytes
        self.expiresAtUnix = expiresAtUnix
    }
}

// MARK: - Picked link stash item
//
// LinkRect stash decision (documented in
// docs/ROADMAP/.impl-notes/phase5-whiteboard-linkrect-stash-2026-07-23.md):
// Everywhere does NOT have a stand-alone `LinkRectStash` class. The
// harvest path in `VisualElementContext.LinkRect.cs` produces a
// `HarvestResult` that flows directly into `ContextStashWriter` and is
// serialised to `context-stash.json` as `picked_links[]`. No in-memory
// stash class is required.
//
// `PickedLinkStashItem` is the wire-format record used when the Phase 6
// stash writer emits `picked_links[]`. Data-only type; consumers are
// the ContextStashWriter (Phase 6) and Layer-2 MCP tools that read the
// on-disk stash.

/// One entry in the `context-stash.json` `picked_links[]` array — a
/// hyperlink harvested by the LinkRect overlay drag. Field naming
/// tracks the Everywhere `HarvestedLink` record so the JSON shape is
/// interoperable across the port.
public struct PickedLinkStashItem: Codable, Sendable, Equatable {
    /// Absolute URL after redaction (credentials stripped by the
    /// Layer-3 redactor before the item lands here).
    public let url: String

    /// Anchor label — `AXTitle` if present else `AXDescription`, capped
    /// at 200 chars per Everywhere convention.
    public let title: String?

    /// POSIX seconds when the harvest completed. Consumers use this to
    /// order stash entries by recency; no TTL is enforced on-disk.
    public let capturedAtUnix: Double

    public init(url: String, title: String?, capturedAtUnix: Double = Date().timeIntervalSince1970) {
        self.url = url
        self.title = title
        self.capturedAtUnix = capturedAtUnix
    }
}

// MARK: - Semantic focus path
//
// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/SemanticExtractor.cs
// and src/Everywhere.Mcp/Tools/Schemas/SemanticItem.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809.
//
// Everywhere's `SemanticExtractor` runs after an ElementIndexer BFS walk
// and pulls three first-class views (selected / focused-leaf /
// focused-path) out of the flat `IndexedNode` list. openclicky delegates
// the tree walk to `open-codex-computer-use`, so the port operates
// directly against `AXUIElement` refs and exposes the same output shape
// as `SemanticItem`, minus `element_index` (there is no pre-walked
// index space to point back into).
//
// See docs/ROADMAP/.impl-notes/phase5-semantic-2026-07-23.md for the
// deviation notes and the Everywhere -> Swift API mapping.

/// One node in a semantic view of the accessibility tree.
///
/// 1:1 with Everywhere's `SemanticItem` payload:
///   * `type` — stringified `VisualElementType` enum name (`"Button"`,
///     `"TextEdit"`, `"Panel"`, ...). Mapping table follows
///     `AXUIElement.Type` in `AXUIElement.cs:120-213`.
///   * `text` — cascade `Name -> GetText(200) -> first labelled
///     descendant (depth 3)` from `SemanticExtractor.BuildItem`.
///   * `states` — string list of `VisualElementStates` flag names
///     currently asserted on the element (see `StatesToList`).
///   * `availableActions` — role-driven suggestion table from
///     `SuggestActions` (`"click"`, `"set_value"`, ...).
///
/// The `element_index` field on Everywhere's `SemanticItem` is
/// deliberately dropped — the Swift port has no pre-walked flat list to
/// index into (openclicky delegates the AX tree walk to OCCU). Callers
/// that need to talk back to the AX layer hold their own `AXUIElement`
/// reference; the `SemanticNode` is a pure Codable value type.
public struct SemanticNode: Codable, Sendable, Equatable {
    /// Stringified `VisualElementType`. Never empty; the AX role
    /// mapping falls back to `"Unknown"` for roles Everywhere does not
    /// recognise (matches `AXUIElement.cs:212 _ => VisualElementType.Unknown`).
    public let type: String

    /// Inline label text. Cascade order matches
    /// `SemanticExtractor.BuildItem` (`SemanticExtractor.cs:75-84`):
    /// `Name` -> `GetText(200)` -> first labelled child (depth 3). Nil
    /// when every source is empty / whitespace.
    public let text: String?

    /// `VisualElementStates` flag names asserted on the element. Nil
    /// when no flag is set (matches
    /// `SemanticExtractor.cs:96-98`).
    public let states: [String]?

    /// Suggested MCP tools derived from `type`. Nil for element types
    /// with no defined suggestions (matches
    /// `SemanticExtractor.cs:137 _ => null`).
    public let availableActions: [String]?

    public init(
        type: String,
        text: String? = nil,
        states: [String]? = nil,
        availableActions: [String]? = nil
    ) {
        self.type = type
        self.text = text
        self.states = states
        self.availableActions = availableActions
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case states
        case availableActions = "available_actions"
    }

    /// Explicit `encode(to:)` matches Everywhere's `SemanticItem`
    /// `[JsonIgnore(Condition = WhenWritingNull)]` wire semantic — nil
    /// optional fields are OMITTED from the JSON output rather than
    /// emitted as explicit `null`. Downstream tools depend on this shape
    /// (a `null` in `states` reads differently from missing to some
    /// consumers that use presence-of-key as an existence check).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(states, forKey: .states)
        try c.encodeIfPresent(availableActions, forKey: .availableActions)
    }

    /// Explicit `init(from:)` preserved so Swift does not lose
    /// synthesised decoding when a custom encoder is provided.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        states = try c.decodeIfPresent([String].self, forKey: .states)
        availableActions = try c.decodeIfPresent([String].self, forKey: .availableActions)
    }
}

/// Semantic breadcrumb from an application's root AX element down to
/// the currently focused leaf.
///
/// 1:1 with Everywhere's `BuildFocusedPath`
/// (`SemanticExtractor.cs:49-70`) output: index 0 is the outermost
/// ancestor (the app / window), the last entry is the deepest
/// `Focused` node. Empty when no focused element could be resolved.
///
/// The `pid` is kept alongside so downstream stash writers can pair
/// the path with the app it was resolved against (Everywhere never
/// separates them because `SemanticExtractor` runs inside a snapshot
/// that already knows the pid).
public struct SemanticFocusPath: Codable, Sendable, Equatable {
    /// The pid this path was resolved against. Always `> 0` when the
    /// path is non-empty.
    public let pid: Int32

    /// Root-to-leaf chain of semantic nodes. Empty when no focused
    /// leaf could be located (missing AX consent, no focused element,
    /// or app not running).
    public let nodes: [SemanticNode]

    public init(pid: Int32, nodes: [SemanticNode]) {
        self.pid = pid
        self.nodes = nodes
    }
}

// MARK: - Memory tools (Everywhere `MemoryTools.cs` port)
//
// See Sources/OpenClickyContextService/Memory/MemoryStore.swift. The
// shapes below mirror the C# `SiteMetadata` / `EndpointSpec` /
// `FieldMapEntry` envelope, collapsed into a single-tenant JSON blob at
// `~/Library/Application Support/OpenClicky/memory.json`.

/// A single named endpoint's memory. Fields are free-form string map
/// (parallels Everywhere's `FieldMapEntry` bag). Notes are ISO-timestamped
/// strings appended in order.
public struct MemoryEndpoint: Codable, Equatable, Sendable {
    public var name: String
    public var fields: [String: String]
    public var notes: [String]
    /// Unix milliseconds when this endpoint was last mutated. Mirrors
    /// Everywhere's `SiteMetadata.VerifiedAt`.
    public var lastWriteAt: Int64

    public init(
        name: String,
        fields: [String: String] = [:],
        notes: [String] = [],
        lastWriteAt: Int64 = 0
    ) {
        self.name = name
        self.fields = fields
        self.notes = notes
        self.lastWriteAt = lastWriteAt
    }
}

/// Full store dump returned by `memory_snapshot`. Mirrors the on-disk
/// envelope written by `MemoryStore`.
public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var endpoints: [String: MemoryEndpoint]
    public var fieldMap: [String: String]
    public var notes: [String]
    public var verifyFixtures: [String: String]
    public var lastWriteAt: Int64

    public init(
        endpoints: [String: MemoryEndpoint] = [:],
        fieldMap: [String: String] = [:],
        notes: [String] = [],
        verifyFixtures: [String: String] = [:],
        lastWriteAt: Int64 = 0
    ) {
        self.endpoints = endpoints
        self.fieldMap = fieldMap
        self.notes = notes
        self.verifyFixtures = verifyFixtures
        self.lastWriteAt = lastWriteAt
    }
}

/// Categorical freshness bucket for `memory_freshness`. Mirrors
/// Everywhere's `Freshness.Classify` string enum
/// (`Freshness.cs:11-17`):
///   * `fresh` — age < 30d
///   * `stale` — 30d <= age < 90d
///   * `cold`  — age >= 90d, or nothing written yet
///     (`MemoryStore.cs:191` returns "cold" when `VerifiedAt == 0`).
public enum MemoryFreshnessBucket: String, Codable, Equatable, Sendable {
    case fresh
    case stale
    case cold
}

/// Return shape of `memory_freshness`. Superset of Everywhere's wire
/// shape:
///   * `freshness` — the categorical bucket string (`fresh` / `stale`
///     / `cold`), byte-matching Everywhere's `MemoryTools.MemoryFreshness`
///     (`MemoryTools.cs:158`).
///   * `lastWriteAt` — unix milliseconds of the most recent mutation
///     (openclicky superset; Everywhere reads `VerifiedAt` off metadata
///     internally but does not surface it on this tool).
///   * `stalenessSeconds` — `now - lastWriteAt` in seconds, clamped to
///     zero when nothing has been written yet (openclicky superset).
///
/// The numeric fields are retained so downstream clients relying on the
/// pre-fix shape keep working while new callers can switch to the
/// categorical string.
public struct MemoryFreshnessInfo: Codable, Equatable, Sendable {
    public var freshness: MemoryFreshnessBucket
    public var lastWriteAt: Int64
    public var stalenessSeconds: Int64

    public init(
        freshness: MemoryFreshnessBucket = .cold,
        lastWriteAt: Int64 = 0,
        stalenessSeconds: Int64 = 0
    ) {
        self.freshness = freshness
        self.lastWriteAt = lastWriteAt
        self.stalenessSeconds = stalenessSeconds
    }
}

/// Return shape of `ClipboardWriter.writeText` and the MCP
/// `clipboard_write` / `clipboard_copy` tools.
///
/// Mirrors Everywhere's `ClipboardTools.DoWrite` envelope
/// (`{ ok, bytes }`) with one semantic tightening: `bytes` is the true
/// UTF-8 byte count of the payload placed on the pasteboard, not
/// `string.Length` (UTF-16 code units, which is what the C# side
/// reports as an advisory number).
public struct ClipboardWriteResult: Codable, Equatable, Sendable {
    /// `true` when the pasteboard accepted the string. Everywhere's
    /// `SetText` has no return value — it silently no-ops when
    /// `declareTypes:owner:` fails — but openclicky surfaces the
    /// `setString(_:forType:)` `Bool` result so the caller can react.
    public let ok: Bool

    /// UTF-8 byte count of the payload actually written. `0` when the
    /// input is empty or when `ok == false`.
    public let bytes: Int

    public init(ok: Bool, bytes: Int) {
        self.ok = ok
        self.bytes = bytes
    }
}

// MARK: - Stash tool return shapes
//
// Ported from Everywhere: src/Everywhere.Mcp/Tools/ReadPickTool.cs +
// AddAnnotationTool.cs + ReadAnnotationsTool.cs + ClearAnnotationsTool.cs +
// ReadWhiteboardTool.cs + ReadWhiteboardImageTool.cs
// @30e03e9dcfdd4247fd679828ed86e9042f32d809.

/// Return shape of `OpenClickyStashTools.readPick`.
///
/// Mirrors Everywhere's `ReadPickTool` JSON envelope
/// (`{pinned, picked_index, app, element, ...}`) plus one Swift-side
/// convenience field (`consumedPin`) so tests / callers can differentiate
/// "stash was empty" from "we consumed a fresh pin" without a second
/// `hasFreshPin` probe.
public struct ReadPickResult: Codable, Equatable, Sendable {
    /// `true` when the stash held a fresh (non-expired) pin at read
    /// time. Mirrors Everywhere `pinned:true|false`
    /// (`ReadPickTool.cs:38, 86`).
    public let pinned: Bool

    /// Rendered pick payload — mode-dependent formatting of the picked
    /// element (markdown for `links`/`text`, JSON-serialised structured
    /// dump for `auto`/`full`). `nil` when `pinned == false`.
    ///
    /// Field name matches Everywhere's `picked_index` on the wire, but
    /// the semantic is different in the Swift port: openclicky has no
    /// pre-walked node list, so this carries the mode-rendered content
    /// rather than a numeric index. Kept under the same key so JSON
    /// consumers using the wire tag round-trip cleanly.
    public let pickedIndex: String?

    /// `AppKey.FromProcessId` output for the pinned element's owning
    /// process. Nil when `pinned == false`. Uses `bundleId` when
    /// available, falls back to the raw pid string.
    public let app: String?

    /// Opaque snapshot of the picked element (role/name/value/bounds).
    /// Nil when `pinned == false`. Keys mirror Everywhere's
    /// `FocusedContextResult` fields (`role`, `title`, `value`,
    /// `bounds`) but flattened to strings so the envelope stays JSON
    /// primitive-only.
    ///
    /// Legacy single-element view (latest pin). When multiple pins
    /// are present, this is the newest; `elements` carries the full
    /// list.
    public let element: [String: String]?

    /// All pins drained in one call. Divergence from Everywhere
    /// (`ReadPickTool.cs` returns one element only) — OpenClicky
    /// PickStash is multi-slot, so agents receive every accumulated
    /// pin. Ordered oldest → newest. Nil when `pinned == false`.
    public let elements: [[String: String]]?

    /// JSON encoding of the picked element when `include_tree_json`
    /// was requested. Nil otherwise. Mirrors Everywhere's
    /// `TreeJsonBuilder.Build(nodes)` output but scoped to the single
    /// snapshot (no walked tree in the Swift port).
    public let treeJson: String?

    /// `true` iff the stash consumed a value on this read (i.e. the
    /// pre-take stash had a fresh pin). Distinguishes "stash was
    /// empty" (`pinned == false, consumedPin == false`) from
    /// "consumed a pin" (`pinned == true, consumedPin == true`).
    /// Not present in Everywhere; Swift-side convenience.
    public let consumedPin: Bool

    public init(
        pinned: Bool,
        pickedIndex: String? = nil,
        app: String? = nil,
        element: [String: String]? = nil,
        elements: [[String: String]]? = nil,
        treeJson: String? = nil,
        consumedPin: Bool = false
    ) {
        self.pinned = pinned
        self.pickedIndex = pickedIndex
        self.app = app
        self.element = element
        self.elements = elements
        self.treeJson = treeJson
        self.consumedPin = consumedPin
    }

    private enum CodingKeys: String, CodingKey {
        case pinned
        case pickedIndex = "picked_index"
        case app
        case element
        case elements
        case treeJson = "tree_json"
        case consumedPin = "consumed_pin"
    }
}

/// Return shape of `OpenClickyStashTools.readWhiteboard`.
///
/// Mirrors Everywhere's `ReadWhiteboardTool` JSON envelope
/// (`{drawn, region_count, markdown}`) plus one Swift-side
/// convenience field (`consumed`) so callers can tell a consumed read
/// (regions were present) from an empty read.
public struct ReadWhiteboardResult: Codable, Equatable, Sendable {
    /// `true` when the stash held a fresh (non-expired) session at
    /// read time. Mirrors Everywhere `drawn:true|false`
    /// (`ReadWhiteboardTool.cs:33, 176`).
    public let drawn: Bool

    /// Number of regions in the consumed session. `0` when
    /// `drawn == false`.
    public let regionCount: Int

    /// Rendered markdown, one `## Region N (...)` block per region.
    /// Empty string when `drawn == false`.
    public let markdown: String

    /// `true` iff the stash consumed a session on this read. Not
    /// present in Everywhere; Swift-side convenience.
    public let consumed: Bool

    public init(drawn: Bool, regionCount: Int, markdown: String, consumed: Bool) {
        self.drawn = drawn
        self.regionCount = regionCount
        self.markdown = markdown
        self.consumed = consumed
    }

    private enum CodingKeys: String, CodingKey {
        case drawn
        case regionCount = "region_count"
        case markdown
        case consumed
    }
}

/// Return shape of `OpenClickyStashTools.addAnnotation` and
/// `.clearAnnotations`.
///
/// Mirrors Everywhere's `{queued:<int>}` (AddAnnotation) and
/// `{cleared:<int>}` (ClearAnnotations) envelopes collapsed to one
/// `{ok, count}` shape. `count` is the post-op live count for
/// `addAnnotation` (matches `AnnotationStash.Add` return value) and
/// the pre-clear count for `clearAnnotations` (matches Everywhere's
/// `cleared` value).
public struct AnnotationOpResult: Codable, Equatable, Sendable {
    /// `true` on success, `false` when the stash rejected the input
    /// (e.g. queue depth exceeded, oversize body).
    public let ok: Bool

    /// Post-op live count for `addAnnotation`; pre-clear count for
    /// `clearAnnotations`. Always `>= 0`.
    public let count: Int

    public init(ok: Bool, count: Int) {
        self.ok = ok
        self.count = count
    }
}

// MARK: - KeyCode
//
// Appended for `InputSimulator`. Ported from
// `Everywhere/src/Everywhere.Mac/Mcp/MacKeyCodes.cs` @30e03e9d — the
// Carbon `kVK_*` virtual-key constants inlined so `InputSimulator` and
// its callers (LaunchPhrase / macro dispatch) can round-trip a chord as
// Codable JSON without pulling in the Carbon header. Each raw value is
// the ANSI `kVK_*` constant and is directly usable as a `CGKeyCode`
// (both are `UInt16`).

/// Carbon `kVK_*` virtual-key codes used by `InputSimulator`. Raw values
/// match `<Carbon/HIToolbox/Events.h>` and are byte-identical to the
/// values in Everywhere's `MacKeyCodes.cs`.
public enum KeyCode: UInt16, Codable, Sendable {
    // Letters
    case a = 0x00, b = 0x0B, c = 0x08, d = 0x02
    case e = 0x0E, f = 0x03, g = 0x05, h = 0x04
    case i = 0x22, j = 0x26, k = 0x28, l = 0x25
    case m = 0x2E, n = 0x2D, o = 0x1F, p = 0x23
    case q = 0x0C, r = 0x0F, s = 0x01, t = 0x11
    case u = 0x20, v = 0x09, w = 0x0D, x = 0x07
    case y = 0x10, z = 0x06

    // Digits (ANSI row)
    case digit0 = 0x1D, digit1 = 0x12, digit2 = 0x13, digit3 = 0x14
    case digit4 = 0x15, digit5 = 0x17, digit6 = 0x16, digit7 = 0x1A
    case digit8 = 0x1C, digit9 = 0x19

    // Editing / navigation
    case `return` = 0x24
    case tab = 0x30
    case space = 0x31
    case delete = 0x33
    case escape = 0x35
    case forwardDelete = 0x75
    case help = 0x72
    case home = 0x73
    case pageUp = 0x74
    case end = 0x77
    case pageDown = 0x79
    case leftArrow = 0x7B
    case rightArrow = 0x7C
    case downArrow = 0x7D
    case upArrow = 0x7E
    case capsLock = 0x39

    // Function keys
    case f1 = 0x7A, f2 = 0x78, f3 = 0x63, f4 = 0x76
    case f5 = 0x60, f6 = 0x61, f7 = 0x62, f8 = 0x64
    case f9 = 0x65, f10 = 0x6D, f11 = 0x67, f12 = 0x6F

    // Keypad
    case keypad0 = 0x52, keypad1 = 0x53, keypad2 = 0x54, keypad3 = 0x55
    case keypad4 = 0x56, keypad5 = 0x57, keypad6 = 0x58, keypad7 = 0x59
    case keypad8 = 0x5B, keypad9 = 0x5C
    case keypadEnter = 0x4C
    case keypadEquals = 0x51
    case keypadMultiply = 0x43
    case keypadPlus = 0x45
    case keypadMinus = 0x4E
    case keypadDecimal = 0x41
    case keypadDivide = 0x4B

    // Modifier keys (left-hand only, matching MacKeyCodes.cs)
    case command = 0x37
    case shift = 0x38
    case option = 0x3A
    case control = 0x3B
}

// MARK: - F32 chat_bus types
//
// Ported from Everywhere:
//   src/Everywhere.Mcp/Tools/ChatBusTools.cs      @ 30e03e9dcfdd4247fd679828ed86e9042f32d809
//   src/Everywhere.Mcp/OpenDia/OpenDiaChatBus.cs  @ 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere's chat bus is a WebSocket proxy to an OpenDia extension —
// upstream owns storage, we own only per-subscriber cursors. OpenClicky
// has no extension counterpart, so we implement the bus in-process as
// an in-memory pub/sub with per-message TTL and a bounded queue.
//
// Envelope fields align with Everywhere's `{msg_id, chat_id, role,
// text, metadata, tool_call, created_at}` frame shape, but stay
// snake_case at the wire boundary. `kind` maps to Everywhere's `role`
// slot; `from` / `to` are optional peer identifiers so agents can
// direct messages at a specific recipient without leaking a UUID
// scheme.
//
// TTL: 5 minutes per message. Queue cap: 200. On overflow the oldest
// unread messages are dropped (FIFO).

/// One chat_bus message, delivered to any subscriber whose filter
/// accepts it. All fields are optional except `kind` and `body` so
/// simple pings ({"kind":"toast","body":"hi"}) stay ergonomic.
public struct ChatBusMessage: Codable, Equatable, Sendable {
    public let messageID: String
    public let kind: String
    public let body: String
    public let from: String?
    public let to: String?
    /// Unix seconds when the message was accepted by the bus. Wire
    /// key `ts` mirrors Everywhere's `created_at` semantics but stays
    /// short.
    public let ts: Double
    /// Free-form envelope for structured payloads. Encoded via
    /// `JSONSerialization` on the boundary; keep values JSON-safe
    /// (String / Number / Bool / Array / Dict / Null).
    public let metadata: [String: MetadataValue]?

    public init(
        messageID: String,
        kind: String,
        body: String,
        from: String? = nil,
        to: String? = nil,
        ts: Double,
        metadata: [String: MetadataValue]? = nil
    ) {
        self.messageID = messageID
        self.kind = kind
        self.body = body
        self.from = from
        self.to = to
        self.ts = ts
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case kind
        case body
        case from
        case to
        case ts
        case metadata
    }

    /// JSON-safe scalar envelope. Reuses Foundation types so a caller
    /// can decode from `[String: Any]` without a bespoke unwrap.
    public enum MetadataValue: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let s = try? container.decode(String.self) { self = .string(s); return }
            if let b = try? container.decode(Bool.self) { self = .bool(b); return }
            if let n = try? container.decode(Double.self) { self = .number(n); return }
            throw DecodingError.typeMismatch(MetadataValue.self, .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported chat_bus metadata value"
            ))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .number(let n): try container.encode(n)
            case .bool(let b): try container.encode(b)
            case .null: try container.encodeNil()
            }
        }
    }
}

/// Response envelope for `chat_send`.
public struct ChatBusSendResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let messageID: String
    public let deliveredTo: Int

    public init(ok: Bool, messageID: String, deliveredTo: Int) {
        self.ok = ok
        self.messageID = messageID
        self.deliveredTo = deliveredTo
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case messageID = "message_id"
        case deliveredTo = "delivered_to"
    }
}

/// Subscription handle bookkeeping. Not exposed at the MCP wire — it
/// is used by `OpenClickyChatBus` to track active subscribers.
public struct ChatBusSubscription: Sendable {
    public let subscriptionID: String
    public let kindFilter: String?
    public let fromFilter: String?
    public let sinceTs: Double
    public init(subscriptionID: String, kindFilter: String?, fromFilter: String?, sinceTs: Double) {
        self.subscriptionID = subscriptionID
        self.kindFilter = kindFilter
        self.fromFilter = fromFilter
        self.sinceTs = sinceTs
    }
}

/// Failure modes for chat_bus dispatch. Mapped to Everywhere's
/// canonical `{ok:false, code, message}` envelope in the bridge.
public enum ChatBusError: Error, Equatable, Sendable {
    case invalidRole(String)
    case invalidPayload(String)
    case internalError(String)
    /// `CHAT_NOT_FOUND` — matches Everywhere `ChatBusTools.cs:55, 62`.
    case chatNotFound(String)

    public var code: String {
        switch self {
        case .invalidRole: return "INVALID_ROLE"
        case .invalidPayload: return "INVALID_PAYLOAD"
        case .internalError: return "BUS_ERROR"
        case .chatNotFound: return "CHAT_NOT_FOUND"
        }
    }
    public var message: String {
        switch self {
        case .invalidRole(let m), .invalidPayload(let m), .internalError(let m), .chatNotFound(let m):
            return m
        }
    }
}

/// Channel summary emitted by `chat_list`. Wire shape mirrors
/// Everywhere `ChatBusTools.cs:33` `{chat_id, title, updated_at,
/// message_count}`. `updatedAt` is unix-seconds since the bus is
/// in-process and stores no wall-clock ISO string.
public struct ChatBusChannelSummary: Codable, Equatable, Sendable {
    public let chatID: String
    public let title: String
    public let updatedAt: Double
    public let messageCount: Int

    public init(chatID: String, title: String, updatedAt: Double, messageCount: Int) {
        self.chatID = chatID
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case updatedAt = "updated_at"
        case messageCount = "message_count"
    }
}
