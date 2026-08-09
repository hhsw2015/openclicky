//
//  ConversationLogger.swift
//  cursor-buddy
//
//  Persists every voice-based user turn and every AI reply into the
//  OpenRewind vault's transcript table. Turns the AI conversation
//  itself into searchable long-term memory — so later the assistant
//  can answer "what did I ask you about kafka last week" the same
//  way it answers "what was on screen last week".
//
//  Reader.transcriptText(segmentID:) + Reader.search() surface it
//  automatically; MCP `openrewind.transcript` returns segment text.
//
//  Speaker id convention:
//    1 = user
//    2 = assistant
//
//  Cheap and best-effort. Silently no-ops when Screen History is off
//  (bridge nil) or the writer refuses (schema missing speakerId col
//  on an older vault — Writer already handles that gracefully).
//

import Foundation

@MainActor
public enum ConversationLogger {

    public enum Speaker: Int64 {
        case user = 1
        case assistant = 2
    }

    /// FIX(task #308 2026-08-04): short-window dedup so a text logged
    /// twice from two call sites within `dedupWindowSeconds` doesn't
    /// produce two `transcript_word` rows. Real duplication seen with
    /// PTT: BuddyDictationManager -> notification -> rememberUserUtteranceOnly
    /// wrote row A, then rememberVoiceExchange wrote row B for the same
    /// text. Realtime lane had the same issue between the observer at
    /// CompanionManager.swift and HeyClickyRealtimeSession's direct
    /// ConversationLogger.log call.
    private static var recentEntries: [(hash: Int, at: Date)] = []
    private static let dedupWindowSeconds: TimeInterval = 30

    /// Log one utterance. `text` is a single fully-formed sentence /
    /// paragraph from the user or assistant. Timestamp defaults to now.
    /// Segment attachment: uses the newest OpenRewind segment (the
    /// current focused-app session), so voice turns land alongside
    /// what the user was looking at when they spoke.
    public static func log(_ text: String,
                           by speaker: Speaker,
                           at when: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // FIX(perf-2026-08-01): whole ConversationLogger is MainActor
        // because OpenRewindBridge.shared is. Detaching the caller
        // still helps: log() returns immediately, and the actual
        // SQLite / NLEmbedding work is enqueued at the tail of the
        // main-actor queue instead of running INLINE with the voice
        // turn's caller. Deep fix would be making Bridge/Writer an
        // actor; that's the XPC helper task.
        Task { @MainActor in
            await Self.logImpl(trimmed: trimmed, speaker: speaker, when: when)
        }
    }

    private static func logImpl(trimmed: String,
                                 speaker: Speaker,
                                 when: Date) async {
        // Dedup: caller sites can double-log the same utterance
        // (BuddyDictationManager notification observer + rememberVoiceExchange
        // when an assistant reply lands; HeyClickyRealtimeSession +
        // the CompanionManager Realtime observer). Drop the second
        // insert if we've seen (speaker, text) within
        // `dedupWindowSeconds`.
        let key = trimmed.hashValue ^ Int(speaker.rawValue) &* 0x9E3779B1
        recentEntries.removeAll { when.timeIntervalSince($0.at) > dedupWindowSeconds }
        if recentEntries.contains(where: { $0.hash == key }) {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "conversation_logger.dedup_dropped",
                fields: ["speaker": speaker == .user ? "user" : "assistant",
                         "textLen": String(trimmed.count),
                         "preview": String(trimmed.prefix(60))]
            )
            return
        }
        recentEntries.append((hash: key, at: when))
        // Cap ring so it stays small in idle sessions.
        if recentEntries.count > 128 {
            recentEntries.removeFirst(recentEntries.count - 128)
        }

        guard let bridge = OpenRewindBridge.shared else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "conversation_logger.skipped",
                fields: ["reason": "bridge_nil", "speaker": speaker == .user ? "user" : "assistant",
                         "textLen": trimmed.count])
            return
        }

        var segId: Int64 = 0
        if let (_, rows) = try? bridge.reader.rawQuery(
            "SELECT id FROM segment ORDER BY startDate DESC LIMIT 1;", []),
           let first = rows.first,
           let raw = first.first,
           let id = Int64(raw ?? "") {
            segId = id
        }
        // No segment yet? Create a synthetic one so voice turns before
        // capture kicks in still persist. This is the failure mode we
        // hit in real testing: user starts talking before capture has
        // opened its first frame, segId=0, everything drops silently.
        if segId <= 0 {
            if let sid = try? bridge.writer.insertSegment(
                bundleID: "com.jkneen.openclicky.voice",
                startDate: when, endDate: when,
                windowName: "voice") {
                segId = sid
            }
        }
        guard segId > 0 else {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice", direction: "internal",
                event: "conversation_logger.skipped",
                fields: ["reason": "no_segment", "speaker": speaker == .user ? "user" : "assistant"])
            return
        }

        // startTime = seconds since epoch for this row; the schema
        // stores it as ms internally via Writer's conversion.
        let start = when.timeIntervalSince1970
        // FIX(speaker-column-2026-07-30): now that transcript_word has
        // a real `speakerId` column (see SchemaInstaller migration),
        // store the raw utterance in `word` and let the column carry
        // the role. Rewind-parity vaults that predate the migration
        // still get `speakerId` via Writer's opportunistic column
        // check, so no data is lost. The old `[user]`/`[assistant]`
        // prefix was polluting FTS BM25 (every conversation row hit
        // on the role token).
        let stamped = trimmed

        // Two writes so retrieval works from BOTH paths:
        //   (a) transcript_word — LTM block reads this directly for
        //       verbatim replay in the system prompt.
        //   (b) searchRanking (FTS5) linked to newest frame — makes
        //       the conversation findable by openrewind.search / .ask.
        _ = try? bridge.writer.insertTranscriptWord(
            segmentId: segId,
            word: stamped,
            startTime: start,
            endTime: start,
            fullTextOffset: nil,
            speakerId: speaker.rawValue,
            // FIX(audio-source-2026-07-31): conversation-logger rows
            // come from chat / assistant replies, not from any
            // captured audio route. Stamp `chat` so downstream
            // ranking can weight chat context differently from
            // real transcribed audio.
            audioSource: "chat")

        // Attach to the newest frame; if none, synthesize a placeholder
        // frame so FTS still gets a valid link. Same reason as segment:
        // voice-first turns land before capture writes a real frame.
        var frameId: Int64 = 0
        if let (_, rows) = try? bridge.reader.rawQuery(
            "SELECT id FROM frame WHERE segmentId = ? ORDER BY id DESC LIMIT 1;",
            [String(segId)]),
           let first = rows.first, let raw = first.first,
           let id = Int64(raw ?? "") {
            frameId = id
        }
        if frameId <= 0 {
            let synth = OpenRewindFrameInput(
                createdAt: when,
                imageFileName: "voice-\(Int64(when.timeIntervalSince1970 * 1000)).synth",
                segmentId: segId,
                videoId: nil,
                videoFrameIndex: nil,
                isStarred: false,
                encodingStatus: "voice-synth",
                captureTrigger: "voice")
            if let fid = try? bridge.writer.insertFrame(synth) {
                frameId = fid
            }
        }
        var wroteSearch = false
        if frameId > 0 {
            wroteSearch = (try? bridge.writer.insertSearchRanking(
                frameId: frameId,
                segmentId: segId,
                text: stamped,
                otherText: nil,
                title: speaker == .user ? "voice.user" : "voice.assistant",
                nodes: [])) != nil
            // Hybrid search: also index this text semantically. No-op
            // if NLEmbedding can't handle the string (very short /
            // non-supported script). Runs in-actor so timing lines
            // up with the FTS write above.
            EmbeddingStore.upsert(bridge: bridge, frameId: frameId, text: stamped)
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "conversation_logger.wrote",
            fields: ["speaker": speaker == .user ? "user" : "assistant",
                     "segId": segId, "frameId": frameId,
                     "textLen": trimmed.count, "fts": wroteSearch])
        // Bust the LTM cache so the next build picks up this turn.
        Task { await LongTermMemoryContext.invalidateCache() }
    }
}
