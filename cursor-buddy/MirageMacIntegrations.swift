//
//  MirageMacIntegrations.swift
//  cursor-buddy
//
//  Native macOS impl for the Peeky integration tools ported verbatim
//  from peeky/src/integrations/*.rs. Every tool follows the same shape:
//  osascript (or mdfind for spotlight) → parse tab/linefeed lines →
//  JSON body Claude can read as tool_result. Errors surface as
//  `{"error": "..."}` matching Peeky's convention.
//
//  Availability probe (`availability()`) mirrors Peeky's `is_available()`
//  functions so `MiragePeekyTools.integrationTools(available:)` only
//  advertises tools we can execute — Claude never sees a tool it can't
//  call.

import AppKit
import Foundation

enum MirageMacIntegrations {

    // MARK: - Availability

    static func availability() -> MirageIntegrationAvailability {
        var av = MirageIntegrationAvailability()

        av.spotify = FileManager.default.fileExists(atPath: "/Applications/Spotify.app")
            || isExecutableOnPath("spotify_player")

        // Every Peeky is_available() for these returns true on macOS.
        // We are macOS-only, so mirror that.
        av.calendar = true
        av.reminders = true
        av.contacts = true
        av.facetime = true
        av.shortcuts = true
        av.spotlight = true
        av.clipboard = true

        av.messages = FileManager.default.fileExists(atPath: "/System/Applications/Messages.app")
            || FileManager.default.fileExists(atPath: "/Applications/Messages.app")
        av.safari = FileManager.default.fileExists(atPath: "/Applications/Safari.app")

        return av
    }

    // MARK: - Dispatch

    static func dispatch(name: String, input: [String: Any]) async -> MirageToolResult {
        switch name {
        // Spotify — AppleScript wrapper. Non-search cases are trivial.
        case "spotify_pause":    return await runAppleScript("tell application \"Spotify\" to pause")
        case "spotify_resume":   return await runAppleScript("tell application \"Spotify\" to play")
        case "spotify_next":     return await runAppleScript("tell application \"Spotify\" to next track")
        case "spotify_previous": return await runAppleScript("tell application \"Spotify\" to previous track")

        // Safari
        case "safari_open_url":
            guard let url = input["url"] as? String else { return .error("safari_open_url: missing 'url'") }
            return await runAppleScript("tell application \"Safari\" to open location \"\(applescriptEscape(url))\"")

        // Calendar
        case "calendar_add_event":  return await calendarAddEvent(input: input)
        case "calendar_list_today": return await calendarListToday()

        // Contacts
        case "contacts_lookup": return await contactsLookup(input: input)

        // Messages
        case "messages_send": return await messagesSend(input: input)

        // FaceTime
        case "facetime_call": return await facetimeCall(input: input)

        // Reminders
        case "reminders_add": return await remindersAdd(input: input)

        // Shortcuts
        case "shortcuts_list": return await shortcutsList()
        case "shortcuts_run":  return await shortcutsRun(input: input)

        // Spotlight
        case "spotlight_search": return await spotlightSearch(input: input)

        default:
            return .error("\(name) is defined but not wired yet on this build")
        }
    }

    // MARK: - Calendar

    private static func calendarAddEvent(input: [String: Any]) async -> MirageToolResult {
        guard let title = input["title"] as? String else {
            return .error("calendar_add_event missing 'title' field")
        }
        let offset: Int64
        if let n = input["offset_minutes"] as? Int { offset = Int64(n) }
        else if let n = input["offset_minutes"] as? Int64 { offset = n }
        else if let d = input["offset_minutes"] as? Double { offset = Int64(d) }
        else { return .error("calendar_add_event missing 'offset_minutes' field") }

        let duration: Int64 = {
            if let n = input["duration_minutes"] as? Int { return Int64(n) }
            if let d = input["duration_minutes"] as? Double { return Int64(d) }
            return 60
        }()
        if duration <= 0 { return .error("calendar_add_event 'duration_minutes' must be positive") }

        let script = """
        set startDate to (current date) + (\(offset) * minutes)
        set endDate to startDate + (\(duration) * minutes)
        tell application "Calendar"
        tell (first calendar whose writable is true)
        make new event with properties {summary:"\(applescriptEscape(title))", start date:startDate, end date:endDate}
        end tell
        end tell
        """
        switch await runAppleScriptRaw(script) {
        case .ok: return .ok("{}")
        case .fail(let e): return .error("calendar_add_event failed: \(e)")
        }
    }

    private static func calendarListToday() async -> MirageToolResult {
        let script = """
        set dayStart to current date
        set time of dayStart to 0
        set dayEnd to dayStart + (1 * days)
        set out to ""
        tell application "Calendar"
            repeat with c in calendars
                repeat with e in (every event of c whose start date is greater than or equal to dayStart and start date is less than dayEnd)
                    set out to out & (summary of e) & tab & (time string of (start date of e)) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        switch await runAppleScriptRaw(script) {
        case .ok(let raw): return .ok(parseCalendarLines(raw))
        case .fail(let e): return .error("calendar_list_today failed: \(e)")
        }
    }

    static func parseCalendarLines(_ raw: String) -> String {
        let events: [[String: Any]] = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let title = parts.first.map(String.init) ?? ""
                let time  = parts.count > 1 ? String(parts[1]) : ""
                return ["title": title, "time": time]
            }
        return encodeJSON(["events": events])
    }

    // MARK: - Contacts

    private static func contactsLookup(input: [String: Any]) async -> MirageToolResult {
        guard let query = input["name"] as? String else {
            return .error("contacts_lookup missing 'name' field")
        }
        let script = """
        set out to ""
        tell application "Contacts"
            repeat with p in (people whose name contains "\(applescriptEscape(query))")
                set phoneList to ""
                repeat with ph in phones of p
                    set phoneList to phoneList & (value of ph) & "; "
                end repeat
                set emailList to ""
                repeat with em in emails of p
                    set emailList to emailList & (value of em) & "; "
                end repeat
                set out to out & (name of p) & tab & phoneList & tab & emailList & linefeed
            end repeat
        end tell
        return out
        """
        switch await runAppleScriptRaw(script) {
        case .ok(let raw): return .ok(parseContactLines(raw))
        case .fail(let e): return .error("contacts_lookup failed: \(e)")
        }
    }

    static func parseContactLines(_ raw: String) -> String {
        let contacts: [[String: Any]] = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                let name   = parts.count > 0 ? String(parts[0]) : ""
                let phones = parts.count > 1 ? splitJoined(String(parts[1])) : []
                let emails = parts.count > 2 ? splitJoined(String(parts[2])) : []
                return ["name": name, "phones": phones, "emails": emails]
            }
        return encodeJSON(["contacts": contacts])
    }

    private static func splitJoined(_ field: String) -> [String] {
        field.components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Messages

    private static func messagesSend(input: [String: Any]) async -> MirageToolResult {
        guard let recipient = input["recipient"] as? String else {
            return .error("messages_send missing 'recipient' field")
        }
        guard let text = input["text"] as? String else {
            return .error("messages_send missing 'text' field")
        }
        let script = """
        tell application "Messages"
        set targetService to 1st service whose service type = iMessage
        set targetBuddy to buddy "\(applescriptEscape(recipient))" of targetService
        send "\(applescriptEscape(text))" to targetBuddy
        end tell
        """
        switch await runAppleScriptRaw(script) {
        case .ok: return .ok("{}")
        case .fail(let e): return .error("messages_send failed: \(e)")
        }
    }

    // MARK: - FaceTime

    private static func facetimeCall(input: [String: Any]) async -> MirageToolResult {
        guard let recipient = input["recipient"] as? String else {
            return .error("facetime_call missing 'recipient' field")
        }
        let audioOnly = (input["audio_only"] as? Bool) ?? false
        let scheme = audioOnly ? "facetime-audio" : "facetime"
        let handle = recipient.components(separatedBy: .whitespaces).joined()
        let url = "\(scheme)://\(handle)"
        switch await runAppleScriptRaw("open location \"\(applescriptEscape(url))\"") {
        case .ok: return .ok("{}")
        case .fail(let e): return .error("facetime_call failed: \(e)")
        }
    }

    // MARK: - Reminders

    private static func remindersAdd(input: [String: Any]) async -> MirageToolResult {
        guard let text = input["text"] as? String else {
            return .error("reminders_add missing 'text' field")
        }
        let script = """
        tell application "Reminders" to make new reminder with properties {name:"\(applescriptEscape(text))"}
        """
        switch await runAppleScriptRaw(script) {
        case .ok: return .ok("{}")
        case .fail(let e): return .error("reminders_add failed: \(e)")
        }
    }

    // MARK: - Shortcuts

    private static func shortcutsRun(input: [String: Any]) async -> MirageToolResult {
        guard let name = input["name"] as? String else {
            return .error("shortcuts_run missing 'name' field")
        }
        let script: String
        if let text = input["input"] as? String, !text.isEmpty {
            script = "tell application \"Shortcuts Events\" to run shortcut named \"\(applescriptEscape(name))\" with input \"\(applescriptEscape(text))\""
        } else {
            script = "tell application \"Shortcuts Events\" to run shortcut named \"\(applescriptEscape(name))\""
        }
        switch await runAppleScriptRaw(script) {
        case .ok(let out):
            if out.isEmpty { return .ok("{}") }
            return .ok(encodeJSON(["result": out]))
        case .fail(let e):
            return .error("shortcuts_run failed: \(e)")
        }
    }

    private static func shortcutsList() async -> MirageToolResult {
        let script = """
        set out to ""
        tell application "Shortcuts Events"
            repeat with s in shortcuts
                set out to out & (name of s) & linefeed
            end repeat
        end tell
        return out
        """
        switch await runAppleScriptRaw(script) {
        case .ok(let raw):
            let names = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return .ok(encodeJSON(["shortcuts": names]))
        case .fail(let e):
            return .error("shortcuts_list failed: \(e)")
        }
    }

    // MARK: - Spotlight

    private static let spotlightMaxResults = 10

    private static func spotlightSearch(input: [String: Any]) async -> MirageToolResult {
        guard let query = input["name"] as? String else {
            return .error("spotlight_search missing 'name' field")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<MirageToolResult, Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            task.arguments = ["-name", query]
            let out = Pipe()
            let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do {
                try task.run()
                task.waitUntilExit()
                let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    let all = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    let truncated = all.count > spotlightMaxResults
                    let paths = Array(all.prefix(spotlightMaxResults))
                    cont.resume(returning: .ok(encodeJSON(["paths": paths, "truncated": truncated])))
                } else {
                    cont.resume(returning: .error("spotlight_search mdfind failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            } catch {
                cont.resume(returning: .error("spotlight_search spawn failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Helpers

    private static func isExecutableOnPath(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Escape a value before it goes inside an AppleScript double-quoted
    /// string. Order matters: escape backslashes first, then quotes.
    static func applescriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Result of an osascript run. `.ok(stdout)` on rc==0, `.fail(stderr)`
    /// otherwise. We roll our own enum instead of `Result<String, String>`
    /// so we don't need `String: Error`.
    enum AppleScriptOutcome {
        case ok(String)
        case fail(String)
    }

    /// Legacy wrapper for the two simple Spotify/Safari callers that only
    /// care about ok/error and don't need stdout. Trims whitespace.
    private static func runAppleScript(_ source: String) async -> MirageToolResult {
        switch await runAppleScriptRaw(source) {
        case .ok(let s):   return .ok(s)
        case .fail(let e): return .error(e)
        }
    }

    /// Run an osascript snippet. `.ok(trimmed_stdout)` on rc==0,
    /// `.fail(trimmed_stderr)` otherwise. Async — osascript takes
    /// 30-100ms even for one-liners.
    private static func runAppleScriptRaw(_ source: String) async -> AppleScriptOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<AppleScriptOutcome, Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            let out = Pipe()
            let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do {
                try task.run()
                task.waitUntilExit()
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    cont.resume(returning: .ok(stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    cont.resume(returning: .fail(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                cont.resume(returning: .fail("osascript spawn failed: \(error.localizedDescription)"))
            }
        }
    }

    private static func encodeJSON(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
