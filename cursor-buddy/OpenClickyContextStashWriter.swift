// Ported from Everywhere: src/Everywhere.Mcp/Snapshot/ContextStashWriter.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// On the SnapshotContext hotkey press (or an explicit `captureAsync()` call
// from openclicky voice / menu flows), captures a minimal pointer to whatever
// the user is looking at — focused app key, window title, browser URL, cached
// text selection — and atomically writes it to a well-known JSON envelope.
// An external Claude Code / cmux UserPromptSubmit hook reads and deletes the
// envelope on the next Enter press.
//
// This is the Swift-side port of Everywhere's `ContextStashWriter`. The
// on-disk envelope is byte-identical to Everywhere apart from two rewrites:
//   1. Line prefixes rebranded `everywhere-*` -> `openclicky-*` so an
//      openclicky-authored stash never confuses an Everywhere-authored hook
//      and vice versa (Everywhere's Rust hook looks for `[everywhere-ctx] `).
//   2. Stash directory `Everywhere` -> `OpenClicky`.
//
// The reusable payload records, `formatForHook` serialiser, sanitisation
// helpers, and stash path resolution live in `OpenClickyContextService`
// (SPM) so the openclicky-context-hook binary AND the unit tests can share
// one implementation. This file owns the orchestration: single-flight guard,
// Phase 1 capture wiring, atomic write, `.consumed-*.json` sweep, and
// Phase 7 wiring stubs.

import Foundation
import Darwin
import OpenClickyContextService

public extension Notification.Name {
    /// Posted after a successful *manual* SnapshotContext write (the
    /// user pressed the hotkey / hit Fire test snapshot / shipped a
    /// LinkRect batch). Mirrors Everywhere's `ContextStashWriter`
    /// `ManualCaptureCompleted` event (`ContextStashWriter.cs:49, 207,
    /// 343`). Annotation badges observe this to tear themselves down
    /// once the pins have been shipped to the agent
    /// (`AnnotationOverlayHost.cs:63-64, 218-237`). Object is the
    /// writer instance; userInfo is empty.
    static let openClickyManualCaptureCompleted = Notification.Name(
        "com.jkneen.openclicky.ContextStashWriter.ManualCaptureCompleted"
    )
}

/// 1:1 port of Everywhere's `ContextStashWriter`. Phase 6 wires Phase 1
/// captures only (frontmost app, focused window, browser URL, cached
/// selection). PickStash / WhiteboardStash / AnnotationStash / LinkRect /
/// launch-phrase / AppActivator all defer to Phase 7 — payload fields stay
/// `nil` and the hint block always falls through to the generic branch.
public final class OpenClickyContextStashWriter: @unchecked Sendable {

    /// Process-wide singleton so auto-capture triggers (whiteboard commit,
    /// pin release) can reach the same writeLock the SnapshotContext hotkey
    /// uses. Everywhere holds a single `ContextStashWriter` DI'd across all
    /// call sites (`WhiteboardHotkeyInitializer.cs:735` reaches for its
    /// injected `_contextWriter` — the same instance the hotkey manager
    /// injects into every other capture path).
    @MainActor
    public static let shared = OpenClickyContextStashWriter()

    /// Bumped whenever the on-disk schema changes incompatibly. Matches
    /// C# `CurrentSchemaVersion`.
    public static let currentSchemaVersion: Int = OpenClickyStashFormatter.currentSchemaVersion

    /// Overridable for tests / DI. Defaults to the well-known
    /// `~/Library/Application Support/OpenClicky/context-stash.json`.
    public let stashPath: URL

    /// Injected clock so tests can freeze `captured_at_utc` in the JSON.
    private let clock: () -> Date

    /// Non-blocking single-flight guard. Everywhere uses
    /// `SemaphoreSlim(1,1).WaitAsync(0)`: a rapid hotkey re-fire returns
    /// immediately instead of serialising behind an in-flight write.
    private let writeLock = NSLock()

    public init(
        stashPath: URL = OpenClickyStashPaths.contextStash(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.stashPath = stashPath
        self.clock = clock
    }

    // MARK: - Public entry points

    /// Ported from `ContextStashWriter.CaptureAsync()` (`ContextStashWriter.cs:105`).
    /// Manual user-driven capture path — drains queued annotations after the
    /// on-disk write succeeds and (Phase 7 TODO) activates the configured
    /// agent app plus fires the launch phrase.
    @MainActor
    public func captureAsync() async {
        await captureCoreAsync(drainAnnotations: true, extraLinks: nil)
    }

    /// Phase 7.1 LinkRect entry point. Runs the standard snapshot but
    /// pre-seeds `picked_links[]` with the harvested drag-rect batch.
    /// Merges with the XLB clipboard sentinel harvest so nothing gets
    /// lost when the two paths fire back-to-back, capped at Everywhere-
    /// parity 200 links.
    @MainActor
    public func captureLinks(_ links: [OpenClickyPickedLink]) async {
        await captureCoreAsync(drainAnnotations: false, extraLinks: links)
    }

    /// Auto-capture entry point driven by `OpenClickyAutoCaptureService`
    /// on a fresh pin. Mirrors Everywhere's `CaptureAsync(IVisualElement seed)`
    /// (ContextStashWriter.cs:167-180) which passes `drainAnnotations: false`
    /// so annotations queued for the *next* manual SnapshotContext press
    /// survive this pin-triggered write. Manual capture path stays
    /// `captureAsync()`.
    @MainActor
    public func captureAutoPin() async {
        await captureCoreAsync(drainAnnotations: false, extraLinks: nil)
    }

    /// Ported from `ContextStashWriter.ClearStash()` (`ContextStashWriter.cs:89`).
    /// Wipes the on-disk stash plus any orphaned `.tmp` sidecar. Idempotent.
    public func clearStash() {
        for path in [stashPath.path, stashPath.path + ".tmp"] {
            _ = Darwin.unlink(path)
        }
    }

    // MARK: - Core capture

    @MainActor
    private func captureCoreAsync(
        drainAnnotations: Bool,
        extraLinks: [OpenClickyPickedLink]? = nil
    ) async {
        // Non-blocking single-flight. NSLock.try() returns false if already
        // held. Matches C# `SemaphoreSlim.WaitAsync(0)`.
        let acquireStart = Date()
        guard writeLock.try() else {
            HeyClickyLog.log(
                "openclicky.stash.writer.acquire_lock",
                lane: "system",
                ["caller": "captureCoreAsync", "acquired": "false"]
            )
            return
        }
        HeyClickyLog.log(
            "openclicky.stash.writer.acquire_lock",
            lane: "system",
            ["caller": "captureCoreAsync", "acquired": "true"]
        )
        defer {
            writeLock.unlock()
            HeyClickyLog.log(
                "openclicky.stash.writer.release_lock",
                lane: "system",
                [
                    "caller": "captureCoreAsync",
                    "duration_ms": String(Int(Date().timeIntervalSince(acquireStart) * 1000)),
                ]
            )
        }

        // 1. Frontmost app -> appKey + pid.
        let front = FrontmostAppCapture.capture()
        let pid: Int32 = front?.processId ?? 0
        let appKey: String? = front?.appKey

        // 2. Focused window title.
        var title: String? = nil
        if pid > 0 {
            title = FocusedWindowCapture.capture(processId: pid)?.title
        }

        // 3. Browser URL — redact userinfo + denylisted query params.
        var url: String? = nil
        if pid > 0 {
            if let raw = await BrowserURLCapture.capture(processId: pid)?.url,
               !raw.isEmpty,
               let parsed = URL(string: raw) {
                let redacted = OpenClickySanitiser.redactCredentials(parsed)
                if !redacted.isEmpty { url = redacted }
            }
        }

        // 4. Selection: cache-only for the manual-preflight path so we never
        //    disrupt the user's clipboard with a Cmd-C poll on hotkey press.
        //    Phase 7 wiring may reintroduce a focused-AX read here once the
        //    Cmd-C branch of SelectedTextCapture is factored out.
        var selectionText: String? = nil
        var selectionApp: String? = nil
        if let cached = SelectionCache.shared.getFresh() {
            selectionText = cached.text
            selectionApp = cached.appKey
        }

        // PickStash -> pin_pending. Task spec (byte-exact port fix):
        // "true iff PickStash.shared has a picked element". Mirrors
        // `ContextStashWriter.cs:269` (`_pickStash.HasFreshPin`) except
        // this port intentionally drops the `seed is not null` guard so
        // any live pin surfaces on both manual and auto captures --
        // AutoCaptureService supplies the pin freshness by firing the
        // capture on `pickStashDidChange`.
        let pinPending: Bool? = PickStash.shared.hasFreshPin ? true : nil

        // WhiteboardStash -> whiteboard_pending + whiteboard_region_count.
        // Peek (not take) so a failed write leaves the session intact --
        // mirrors `ContextStashWriter.cs:274-275`. region_count only
        // emitted when pending is true (`ContextStashWriter.cs:324`).
        let whiteboardRegions = WhiteboardStash.shared.peek()
        let whiteboardPending: Bool? = (whiteboardRegions?.isEmpty == false) ? true : nil
        let whiteboardRegionCount: Int? = whiteboardPending == true ? whiteboardRegions!.count : nil

        // 5. Clipboard XLB multi-pick harvest (sentinel-guarded).
        let clipboardLinks = Self.tryReadXlbMultiPick()

        // 5a. LinkRectStash (Alt+L drag results). Divergence from
        // Everywhere: Alt+L no longer direct-ships; it queues links
        // here and Shift+Space flushes them into the envelope so
        // both cmux and voice consumers see the same bundle.
        // captureCoreAsync is @MainActor and LinkRectStash is
        // @MainActor — direct call, no hop needed.
        let linkRectLinks: [OpenClickyPickedLink]? = LinkRectStash.shared.peek()

        // 5b. Merge LinkRect-harvested picks with clipboard picks.
        // Everywhere-parity cap of 200; dedup by lowercase URL.
        let mergedLinks = Self.mergeLinks(
            Self.mergeLinks(clipboardLinks, linkRectLinks),
            extraLinks
        )

        // Early-return when there is literally nothing worth writing —
        // matches C# `ContextStashWriter.cs:277-286`.
        if (appKey?.isEmpty ?? true)
            && (title?.isEmpty ?? true)
            && (url?.isEmpty ?? true)
            && (selectionText?.isEmpty ?? true)
            && pinPending != true
            && whiteboardPending != true
            && (mergedLinks?.isEmpty ?? true)
        {
            return
        }

        // AnnotationStash: peek (not consume) into the payload so a
        // failed write leaves the queue intact. Auto-capture paths
        // (drainAnnotations=false) skip the peek entirely -- they
        // neither include nor consume queued annotations. Mirrors
        // `ContextStashWriter.cs:308-311, 875-890`.
        let annoPeek: (payload: [OpenClickyPayloadAnnotation]?, source: [AnnotationItem]) =
            drainAnnotations ? Self.peekAnnotationsForPayload() : (nil, [])
        let annotations: [OpenClickyPayloadAnnotation]? = annoPeek.payload
        let annoSource: [AnnotationItem] = annoPeek.source

        let payload = OpenClickyContextSnapshotPayload(
            schemaVersion: Self.currentSchemaVersion,
            capturedAtUtc: clock(),
            app: appKey,
            processId: pid > 0 ? pid : nil,
            windowTitle: title,
            url: url,
            selectedText: selectionText,
            selectedApp: selectionApp,
            pinPending: pinPending,
            whiteboardPending: whiteboardPending,
            whiteboardRegionCount: whiteboardRegionCount,
            pickedLinks: mergedLinks,
            annotations: annotations
        )

        var wrote = false
        var writeBytes = 0
        var writeErrno: Int32 = 0
        do {
            let composed = OpenClickyStashFormatter.formatForHook(
                payload,
                knownApps: Self.currentKnownAppRules()
            )
            writeBytes = composed.utf8.count
            HeyClickyLog.log(
                "openclicky.stash.writer.envelope_composed",
                lane: "system",
                [
                    "section_bytes": String(writeBytes),
                    "hint_kind": Self.hintKind(for: payload),
                    "links_count": String(payload.pickedLinks?.count ?? 0),
                    "annotations_count": String(payload.annotations?.count ?? 0),
                ]
            )
            try Self.writeAtomic(
                stashPath: stashPath,
                payload: payload,
                knownApps: Self.currentKnownAppRules()
            )
            wrote = true
        } catch {
            NSLog("OpenClickyContextStashWriter: write failed: \(error)")
            if let ns = error as NSError? {
                writeErrno = Int32(ns.code)
            }
        }
        HeyClickyLog.log(
            "openclicky.stash.writer.atomic_write",
            lane: "system",
            direction: wrote ? "internal" : "error",
            [
                "bytes": String(writeBytes),
                "path_hash": String(stashPath.path.hashValue),
                "ok": wrote ? "true" : "false",
                "errno_if_fail": String(writeErrno),
            ]
        )

        // Drain-on-successful-write: only consume the exact items we
        // peeked above so any AnnotationStash appends that raced between
        // peek and consume survive. Mirrors `ContextStashWriter.cs:329-332`.
        if wrote && drainAnnotations && !annoSource.isEmpty {
            AnnotationStash.shared.consume(annoSource)
        }

        // Drain LinkRectStash on successful Shift+Space so the next
        // capture starts clean — otherwise the same batch would be
        // re-injected into every subsequent envelope until TTL expiry.
        // Only drain on the manual (drainAnnotations=true) path, not
        // the auto-pin path.
        if wrote && drainAnnotations && linkRectLinks != nil {
            LinkRectStash.shared.clearWithEvent()
        }

        // Manual-hotkey path (drainAnnotations=true) raises the
        // configured agent app after a successful write and, if the
        // user set a launch phrase, types it plus Return so the
        // agent immediately acts on the freshly-written stash.
        // Auto-capture paths (pin / whiteboard) MUST NOT raise the
        // agent app — the user is still working in the source app
        // and switching their window out from under them would be a
        // surprise (mirrors ContextStashWriter.cs:335-344 comment).
        if wrote && drainAnnotations {
            // Fan-out the ManualCaptureCompleted event so the badge
            // overlay tears its pairs down (Everywhere:
            // `ContextStashWriter.cs:343`,
            // `AnnotationOverlayHost.cs:218-237`).
            NotificationCenter.default.post(
                name: .openClickyManualCaptureCompleted,
                object: self
            )
            // Fire-and-forget: Everywhere runs the settle-loop + injection
            // via `Task.Run` (ContextStashWriter.cs:527) so the capture
            // pipeline releases its single-flight lock immediately. If we
            // `await` here the writeLock stays held for ~3s (16 × 150ms
            // settle + type + Return), silently dropping any hotkey re-fire
            // during that window. Task(detached-ish) matches C# semantics.
            Task { await activateAgentAndFirePhrase() }
        }
    }

    // MARK: - XLB multi-pick clipboard harvest

    static let xlbMultiPickSentinel = "xlb-multi-pick://"
    static let maxClipboardLinks = 200
    static let maxClipboardUrlLen = 2048

    /// Ported from `TryReadXlbMultiPick` (`ContextStashWriter.cs:406-439`).
    /// Sentinel-guarded so arbitrary clipboard text never lands in the agent
    /// context.
    static func tryReadXlbMultiPick() -> [OpenClickyPickedLink]? {
        guard let raw = ClipboardCapture.capture()?.text else { return nil }
        let trimmed = String(raw.drop(while: { $0.isWhitespace }))
        guard trimmed.lowercased().hasPrefix(xlbMultiPickSentinel) else { return nil }
        let normalised = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var picked: [OpenClickyPickedLink] = []
        var seen = Set<String>()
        for line in lines {
            if line.lowercased().hasPrefix(xlbMultiPickSentinel) { continue }
            if line.count > maxClipboardUrlLen { continue }
            guard let u = URL(string: line), u.scheme != nil,
                  OpenClickySanitiser.isAllowedScheme(u) else { continue }
            let redacted = OpenClickySanitiser.redactCredentials(u)
            if redacted.isEmpty { continue }
            if !seen.insert(redacted.lowercased()).inserted { continue }
            picked.append(OpenClickyPickedLink(url: redacted, title: nil))
            if picked.count >= maxClipboardLinks { break }
        }
        return picked.isEmpty ? nil : picked
    }

    // MARK: - Link merge

    /// Union two `picked_links[]` sources (clipboard sentinel harvest
    /// + LinkRect drag-harvest) preserving insertion order, deduping
    /// by lowercase URL, capped at `maxClipboardLinks = 200`. Returns
    /// nil when both inputs are empty so the "nothing to write"
    /// early-return above keeps behaving.
    static func mergeLinks(
        _ a: [OpenClickyPickedLink]?,
        _ b: [OpenClickyPickedLink]?
    ) -> [OpenClickyPickedLink]? {
        let all = (a ?? []) + (b ?? [])
        if all.isEmpty { return nil }
        var seen = Set<String>()
        var out: [OpenClickyPickedLink] = []
        for link in all {
            let key = link.url.lowercased()
            if !seen.insert(key).inserted { continue }
            out.append(link)
            if out.count >= maxClipboardLinks { break }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - LinkRect direct entry (Everywhere-parity `CaptureLinksAsync`)

    /// Ported from `ContextStashWriter.CaptureLinksAsync`
    /// (ContextStashWriter.cs:130-213).
    ///
    /// Direct entry for the LinkRect harvest overlay: writes a batch
    /// of `(title, url)` tuples straight into `picked_links[]`
    /// without running the full context snapshot pipeline. Snapshot
    /// still captures frontmost app + window title + browser URL so
    /// the receiving agent knows *where* the links were harvested
    /// from, but selection / pin / whiteboard fields stay nil — a
    /// LinkRect drag is not a "full context" event.
    ///
    /// After a successful atomic write, raises the configured agent
    /// app and fires the launch phrase (LinkRect harvest is a
    /// user-driven event, same treatment as the manual SnapshotContext
    /// hotkey).
    ///
    /// Distinct from the existing `captureLinks([OpenClickyPickedLink])`
    /// overload — that path goes through `captureCoreAsync` and merges
    /// with clipboard XLB harvest. This one is the "direct ship" path
    /// Everywhere added when it split LinkRect off from the clipboard
    /// sentinel channel.
    @MainActor
    public func captureLinks(_ links: [(title: String, url: String)]) async {
        guard !links.isEmpty else { return }

        // Non-blocking single-flight — same guard the full snapshot
        // uses so a rapid LinkRect drag on top of a still-writing
        // SnapshotContext press collapses to one write.
        let acquireStart = Date()
        guard writeLock.try() else {
            NSLog("OpenClickyContextStashWriter: context capture in progress; dropping LinkRect batch.")
            HeyClickyLog.log(
                "openclicky.stash.writer.acquire_lock",
                lane: "system",
                ["caller": "captureLinks", "acquired": "false"]
            )
            return
        }
        HeyClickyLog.log(
            "openclicky.stash.writer.acquire_lock",
            lane: "system",
            ["caller": "captureLinks", "acquired": "true"]
        )
        defer {
            writeLock.unlock()
            HeyClickyLog.log(
                "openclicky.stash.writer.release_lock",
                lane: "system",
                [
                    "caller": "captureLinks",
                    "duration_ms": String(Int(Date().timeIntervalSince(acquireStart) * 1000)),
                ]
            )
        }

        // Snapshot frontmost + url. Same helpers the full snapshot
        // uses; we don't need selection / pin / whiteboard fields.
        let front = FrontmostAppCapture.capture()
        let pid: Int32 = front?.processId ?? 0
        let appKey: String? = front?.appKey

        var title: String? = nil
        if pid > 0 {
            title = FocusedWindowCapture.capture(processId: pid)?.title
        }

        var url: String? = nil
        if pid > 0 {
            if let raw = await BrowserURLCapture.capture(processId: pid)?.url,
               !raw.isEmpty,
               let parsed = URL(string: raw) {
                let redacted = OpenClickySanitiser.redactCredentials(parsed)
                if !redacted.isEmpty { url = redacted }
            }
        }

        // Filter + cap + dedup. Matches ContextStashWriter.cs:159-181.
        let filtered = Self.filterCapAndDedupLinks(links)
        if filtered.isEmpty { return }

        let payload = OpenClickyContextSnapshotPayload(
            schemaVersion: Self.currentSchemaVersion,
            capturedAtUtc: clock(),
            app: appKey,
            processId: pid > 0 ? pid : nil,
            windowTitle: title,
            url: url,
            selectedText: nil,
            selectedApp: nil,
            pinPending: nil,
            whiteboardPending: nil,
            whiteboardRegionCount: nil,
            pickedLinks: filtered,
            annotations: nil
        )

        var wrote = false
        do {
            try Self.writeAtomic(
                stashPath: stashPath,
                payload: payload,
                knownApps: Self.currentKnownAppRules()
            )
            wrote = true
            NSLog("OpenClickyContextStashWriter: captured \(filtered.count) links from \(appKey ?? "unknown app").")
        } catch {
            NSLog("OpenClickyContextStashWriter: LinkRect write failed: \(error)")
        }

        if wrote {
            // LinkRect direct-ship is also a user-driven event, so
            // fan out ManualCaptureCompleted — Everywhere's parity
            // path fires it at `ContextStashWriter.cs:207`.
            NotificationCenter.default.post(
                name: .openClickyManualCaptureCompleted,
                object: self
            )
            // Fire-and-forget — see rationale in `captureCoreAsync`. Keeping
            // the writeLock held while the settle loop churns would drop
            // any LinkRect drag that lands during the 2-3s activation window.
            Task { await activateAgentAndFirePhrase() }
        }
    }

    // MARK: - LinkRect filter / cap / dedup

    /// Everywhere-parity bounds for the direct LinkRect ship
    /// (ContextStashWriter.cs:159-161).
    static let maxLinkRectLinks = 200
    static let maxLinkRectUrlLen = 2048
    static let maxLinkRectTitleLen = 200

    /// Ported from ContextStashWriter.cs:165-181.
    ///
    /// - Drops empty URLs, oversize URLs, disallowed schemes.
    /// - Dedups by `url + "\0" + (title ?? "")` (case-insensitive).
    /// - Trims titles to `maxLinkRectTitleLen` characters.
    /// - Caps at `maxLinkRectLinks`; further entries are dropped.
    /// - Redacts credentials on each surviving URL so `picked_links[]`
    ///   never carries tokens to disk (openclicky-ctx envelope
    ///   requirement, docs/ROADMAP/04_LAYER_3_STASH_HOOK.md:67-71).
    static func filterCapAndDedupLinks(
        _ links: [(title: String, url: String)]
    ) -> [OpenClickyPickedLink] {
        var picked: [OpenClickyPickedLink] = []
        picked.reserveCapacity(min(links.count, maxLinkRectLinks))
        var seen = Set<String>()

        for (title, linkUrl) in links {
            let trimmedUrl = linkUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUrl.isEmpty { continue }
            if trimmedUrl.count > maxLinkRectUrlLen { continue }
            guard let parsed = URL(string: trimmedUrl),
                  OpenClickySanitiser.isAllowedScheme(parsed) else { continue }
            let redacted = OpenClickySanitiser.redactCredentials(parsed)
            if redacted.isEmpty { continue }

            let dedupKey = redacted.lowercased() + "\u{0}" + title.lowercased()
            if !seen.insert(dedupKey).inserted { continue }

            let trimmedTitleRaw = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTitle: String?
            if trimmedTitleRaw.isEmpty {
                trimmedTitle = nil
            } else if trimmedTitleRaw.count > maxLinkRectTitleLen {
                trimmedTitle = String(trimmedTitleRaw.prefix(maxLinkRectTitleLen))
            } else {
                trimmedTitle = trimmedTitleRaw
            }

            picked.append(OpenClickyPickedLink(url: redacted, title: trimmedTitle))
            if picked.count >= maxLinkRectLinks { break }
        }

        return picked
    }

    // MARK: - Agent activation + launch phrase

    /// Ported from `ContextStashWriter.ActivateAgentApp` +
    /// `TryFireLaunchPhrase` (ContextStashWriter.cs:367-388, :509-609).
    ///
    /// Called after every successful *user-driven* write (manual
    /// SnapshotContext + LinkRect direct ship). Reads settings live
    /// from `OpenClickyContextAwarenessSettings.shared` so a rebind
    /// in Settings takes effect on the very next fire without any
    /// wiring. Empty agent bundle id → no-op (matches C# guard).
    /// Non-empty phrase → hand off to the shared activator's settle-
    /// loop + injection pipeline; the activator itself handles the
    /// `_phraseInFlight` interlock and focus-steal guards.
    @MainActor
    private func activateAgentAndFirePhrase() async {
        let settings = OpenClickyContextAwarenessSettings.shared
        let bundleId = settings.agentAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty else {
            // Everywhere logs an "agent app id is empty" info line here
            // (ContextStashWriter.cs:372) so a user with a misconfigured
            // Settings pane can trace the silent skip in Console.app.
            HeyClickyLog.log(
                "openclicky.launch_phrase.no_agent_app",
                lane: "system",
                direction: "internal",
                ["reason": "agent_app_id_empty"]
            )
            return
        }

        let raised = OpenClickyAppActivator.shared.activate(bundleId)
        NSLog("OpenClickyContextStashWriter: agent activate(\(bundleId)) returned \(raised).")
        if !raised { return }

        // Match Everywhere `IsNullOrWhiteSpace` (ContextStashWriter.cs:512):
        // trim whitespace/newlines before the empty check so a user who
        // configured `launchPhrase = "  "` doesn't get a blank line typed
        // + Return pressed into their agent.
        let phrase = settings.launchPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }

        await OpenClickyAppActivator.shared.fireLaunchPhrase(
            bundleId: bundleId,
            phrase: phrase
        )
    }

    // MARK: - Envelope diagnostics helper

    /// Derive the same 5-way hint-branch discriminator that
    /// `OpenClickyStashFormatter.formatForHook` uses (payload:423-444),
    /// so instrumentation surfaces which hint variant a given write
    /// emitted without re-parsing the envelope. Read-only.
    static func hintKind(for p: OpenClickyContextSnapshotPayload) -> String {
        if p.whiteboardPending == true { return "whiteboard" }
        // Discovery URL resolution requires knownApps; the writer's
        // instrumentation is emitted BEFORE the formatter runs so we
        // report the discriminator ignoring KnownApps hit — the
        // formatter's own byte order is what actually ships.
        if p.pinPending == true { return "pin" }
        return "generic"
    }

    // MARK: - Annotation payload helper

    /// Ported from `ContextStashWriter.PeekAnnotationsForPayload`
    /// (`ContextStashWriter.cs:875-890`). Snapshots `AnnotationStash.shared`
    /// without consuming: caller drains via `AnnotationStash.consume`
    /// only AFTER the on-disk write succeeds, so a transient I/O failure
    /// leaves the user's queued notes available for the next hotkey press.
    /// Returns `(nil, [])` on empty queue so the JSON serialiser omits
    /// the field entirely.
    static func peekAnnotationsForPayload() -> (payload: [OpenClickyPayloadAnnotation]?, source: [AnnotationItem]) {
        let items = AnnotationStash.shared.peek()
        if items.isEmpty { return (nil, []) }
        let payload = items.map { item in
            OpenClickyPayloadAnnotation(
                source: annotationSourceToWire(item.source),
                body: item.body,
                anchorLabel: item.anchorLabel,
                anchorRef: item.anchorRef,
                capturedAtUtc: item.capturedAt
            )
        }
        return (payload, items)
    }

    /// Ported from `ContextStashWriter.AnnotationSourceToWire`
    /// (`ContextStashWriter.cs:892-899`). The enum's `rawValue` already
    /// matches Everywhere's wire strings (see `AnnotationSource` in
    /// `CaptureTypes.swift:1639-1644`, `linkRect = "linkrect"`), so this
    /// is a thin trampoline preserved for byte-parity fidelity.
    static func annotationSourceToWire(_ source: AnnotationSource) -> String {
        source.rawValue
    }

    // MARK: - KnownApps bridge

    /// Bridge the UI-side `[OpenClickyKnownApp]` table (Codable/Identifiable
    /// SwiftUI type used by the Settings pane) to the pure
    /// `[OpenClickyKnownAppRule]` value type the SPM formatter expects.
    /// Read on every write so a Settings-pane edit takes effect on the
    /// very next SnapshotContext press without any explicit re-register.
    ///
    /// Reads from `OpenClickyContextAwarenessSettings.shared` — the same
    /// singleton `activateAgentAndFirePhrase` reaches for. `@MainActor`
    /// because `@Published` snapshot access on the ObservableObject is
    /// main-actor-isolated.
    @MainActor
    static func currentKnownAppRules() -> [OpenClickyKnownAppRule] {
        OpenClickyContextAwarenessSettings.shared.knownApps.map {
            OpenClickyKnownAppRule(
                titlePattern: $0.titlePattern,
                discoverUrl: $0.discoverUrl
            )
        }
    }

    // MARK: - Atomic write

    /// Ported from `WriteAtomicAsync` (`ContextStashWriter.cs:901-927`).
    /// Sweeps stale `.consumed-*.json` first, writes tmp + chmod 0600, then
    /// `rename(2)` overwrite. Swift's `FileManager.moveItem` refuses to
    /// overwrite, so we drop straight to `Darwin.rename` — matches Rust hook
    /// semantics too.
    static func writeAtomic(
        stashPath: URL,
        payload: OpenClickyContextSnapshotPayload,
        knownApps: [OpenClickyKnownAppRule] = []
    ) throws {
        let dir = stashPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sweepStaleClaimFiles(in: dir)

        let body = OpenClickyStashFormatter.formatForHook(payload, knownApps: knownApps)
        let tmpPath = stashPath.path + ".tmp"
        let tmpURL = URL(fileURLWithPath: tmpPath)
        try body.data(using: .utf8)!.write(to: tmpURL, options: .atomic)

        // 0600 = owner read/write. Same POSIX permission Everywhere applies
        // (ContextStashWriter.cs:916-924).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath)

        // POSIX rename(2) — atomic overwrite. Not FileManager.moveItem
        // because that throws when the destination exists.
        if Darwin.rename(tmpPath, stashPath.path) != 0 {
            let err = errno
            _ = Darwin.unlink(tmpPath)
            throw NSError(
                domain: "OpenClickyContextStashWriter",
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "rename(2) failed: \(String(cString: strerror(err)))"]
            )
        }
    }

    /// Ported from `SweepStaleClaimFiles` (`ContextStashWriter.cs:929-949`).
    static func sweepStaleClaimFiles(in dir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-10 * 60)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("context-stash.consumed-"), name.hasSuffix(".json") else { continue }
            if let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                _ = try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
