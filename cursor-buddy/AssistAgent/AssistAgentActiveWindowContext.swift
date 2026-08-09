//
//  AssistAgentActiveWindowContext.swift
//  cursor-buddy
//
//  Snapshot of the frontmost application at push-to-talk onset,
//  formatted as a compact context block the dialog model can use to
//  interpret ambiguous requests like "summarise this" or "open the
//  next one in the folder".
//
//  Special cases:
//    · Browsers (Safari, Chrome, Chromium, Edge, Arc, Brave, Vivaldi,
//      Orion, Opera) → URL + title of the active tab, via AppleScript.
//    · Finder → path of the frontmost window's folder → also becomes
//      the implicit workdir for the assist agent.
//    · Editors (Xcode, VSCode, Sublime, JetBrains) → best-effort file
//      path from the window title.
//    · Fallback: app name + window title from AX API.
//

import AppKit
import ApplicationServices
import Foundation
import OpenClickyContextService

public struct AssistAgentActiveWindowContext: Sendable {
    public let appName: String
    public let bundleID: String
    public let windowTitle: String?
    /// Browser tab URL (browsers only).
    public let browserURL: String?
    /// Filesystem path implied by the active window — Finder folder,
    /// editor document path, etc. Consumed by the assist agent as an
    /// implicit workdir.
    public let inferredWorkdir: String?
    public let filePath: String?
    /// Compact snapshot of whatever the user last stashed via
    /// shift+space (or another everywhere trigger). Each entry is one
    /// `PickedElement` reduced to `<bundle> title="..." value="..."`.
    /// Empty when the stash has nothing fresh.
    public let pickedItems: [String]

    /// Compact one-block string suitable for prompt injection.
    public var promptBlock: String {
        var parts: [String] = []
        parts.append("app=\(appName)")
        if let t = windowTitle, !t.isEmpty { parts.append("window=\"\(t.prefix(160))\"") }
        if let u = browserURL, !u.isEmpty { parts.append("url=\(u)") }
        if let p = filePath, !p.isEmpty { parts.append("file=\(p)") }
        if let w = inferredWorkdir, !w.isEmpty, w != filePath { parts.append("workdir=\(w)") }
        var block = "[active-window] " + parts.joined(separator: " · ")
        if !pickedItems.isEmpty {
            block += "\n[picked-context]\n" +
                pickedItems.prefix(6).map { "  · " + $0 }.joined(separator: "\n")
        }
        return block
    }
}

public enum AssistAgentActiveWindow {

    /// Capture the frontmost app's context. Non-blocking, best-effort.
    /// Returns nil when the frontmost app is OpenClicky itself (so we
    /// don't inject our own overlay's context).
    @MainActor
    public static func capture() -> AssistAgentActiveWindowContext? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        let name = front.localizedName ?? "?"
        let bid = front.bundleIdentifier ?? ""
        let (windowTitle, filePathFromAX) = axWindowTitleAndDoc(pid: front.processIdentifier)
        let browserURL = browserURLFor(bundleID: bid)
        let (workdir, filePath) = inferPaths(bundleID: bid,
                                             windowTitle: windowTitle,
                                             docPathFromAX: filePathFromAX)
        return AssistAgentActiveWindowContext(
            appName: name, bundleID: bid,
            windowTitle: windowTitle,
            browserURL: browserURL,
            inferredWorkdir: workdir,
            filePath: filePath,
            pickedItems: capturePickStash())
    }

    /// Reduce PickStash.shared.peekAll() to short prompt-friendly
    /// strings so the dialog model sees whatever the user last
    /// stashed via shift+space or other everywhere triggers.
    /// Non-destructive — we peek, we don't drain.
    private static func capturePickStash(maxItems: Int = 6) -> [String] {
        let picks = PickStash.shared.peekAll()
        guard !picks.isEmpty else { return [] }
        var out: [String] = []
        for p in picks.suffix(maxItems) {
            var line = ""
            if let bid = p.bundleId, !bid.isEmpty { line += "\(bid) " }
            if let title = p.title?.trimmingCharacters(in: .whitespaces),
               !title.isEmpty {
                line += "title=\"\(title.prefix(120))\" "
            }
            if let value = p.value?.trimmingCharacters(in: .whitespaces),
               !value.isEmpty {
                line += "value=\"\(value.prefix(200))\""
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }

    // MARK: - AX helpers

    private static func axWindowTitleAndDoc(pid: pid_t) -> (title: String?, doc: String?) {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl,
                                            kAXFocusedWindowAttribute as CFString,
                                            &winRef) == .success,
              let winRaw = winRef else { return (nil, nil) }
        // In Swift 6 this is treated as opaque CFTypeRef; the concrete
        // AXUIElement bridges through unsafeBitCast.
        let win = winRaw as! AXUIElement
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String
        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef)
        var doc = docRef as? String
        // AXDocument may be file:// URL — unwrap.
        if let s = doc, s.hasPrefix("file://"),
           let url = URL(string: s) {
            doc = url.path
        }
        return (title, doc)
    }

    // MARK: - Browser URL via AppleScript

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "company.thebrowser.Browser",   // Arc
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "org.mozilla.firefox",           // no scripting bridge but keep for logging
        "com.chromium.Chromium"
    ]

    private static func browserURLFor(bundleID: String) -> String? {
        guard browserBundleIDs.contains(bundleID) else { return nil }
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return URL of current tab of front window"
        case "org.mozilla.firefox":
            return nil    // Firefox has no AppleScript URL exposure
        default:
            // Chrome-family + Arc + Opera + Vivaldi + Brave — same JS bridge.
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName ?? bundleID
            script = "tell application \"\(appName)\" to return URL of active tab of front window"
        }
        return runAppleScript(script)
    }

    private static func runAppleScript(_ src: String) -> String? {
        var error: NSDictionary?
        guard let scr = NSAppleScript(source: src) else { return nil }
        let result = scr.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Path inference

    private static func inferPaths(bundleID: String,
                                   windowTitle: String?,
                                   docPathFromAX: String?)
        -> (workdir: String?, filePath: String?)
    {
        // Finder → frontmost window target folder.
        if bundleID == "com.apple.finder" {
            let src = "tell application \"Finder\" to return POSIX path of (target of front window as alias)"
            if let p = runAppleScript(src) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                   isDir.boolValue { return (p, nil) }
            }
        }
        // Editors — AXDocument is authoritative when the app exposes it.
        if let doc = docPathFromAX, !doc.isEmpty {
            let file = doc
            let parent = (file as NSString).deletingLastPathComponent
            return (parent.isEmpty ? nil : parent, file)
        }
        // Xcode / VSCode / Sublime — title usually has "filename — project".
        if bundleID.hasPrefix("com.microsoft.VSCode")
            || bundleID.hasPrefix("com.sublimetext")
            || bundleID.hasPrefix("com.apple.dt.Xcode")
            || bundleID.hasPrefix("com.jetbrains.")
            || bundleID.hasPrefix("com.todesktop.230313mzl4w4u92") {   // Cursor
            if let title = windowTitle {
                // Heuristic: last "—" separates project name from file.
                let parts = title.components(separatedBy: " — ")
                if let candidate = parts.first,
                   candidate.contains("."),
                   let expanded = expandFileMention(candidate) {
                    let parent = (expanded as NSString).deletingLastPathComponent
                    return (parent, expanded)
                }
            }
        }
        return (nil, nil)
    }

    /// Very cheap heuristic to turn `foo.swift` in a title into a real
    /// path when the containing folder is discoverable. Falls back to
    /// nil — we never guess.
    private static func expandFileMention(_ mention: String) -> String? {
        // Bare name; no directory. Not enough to expand safely.
        if !mention.contains("/") { return nil }
        let candidate = (mention as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}
