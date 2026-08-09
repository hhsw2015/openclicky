//
//  CompanionManager+AIResponsePipeline.swift
//  cursor-buddy
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OpenClickyCore
import OpenClickyUI
@preconcurrency import OpenClickyBrowser
import OpenClickyMarkdown
import OpenClickyMemory
import OpenClickyContextService

extension CompanionManager {
    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        rememberMainConversationUserPrompt(transcript, source: "voice_response")
        interruptCurrentVoiceResponse()
        let timing = activeRequestTiming
        let plannedVoiceAnalysisModelID: String? = {
            let selectedVoiceResponseModel = OpenClickyModelCatalog.voiceResponseModel(withID: selectedModel)
            guard OpenClickyModelCatalog.isSpeechModelID(selectedVoiceResponseModel.id),
                  Self.shouldAttachScreenContext(to: transcript) else {
                return nil
            }
            return OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedVoiceResponseModel.id).id
        }()
        var executionFields = voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
        executionFields["transcriptLength"] = transcript.count
        let executionStartedAt = markRequestExecutionStarted(
            route: "voice.response",
            timing: timing,
            extra: executionFields
        )
        let requestID = timing?.requestID
        let completionToken = UUID()
        let completionState = OpenClickyRequestCompletionState()
        currentVoiceResponseRequestID = requestID
        currentVoiceResponseCompletionToken = completionToken
        currentVoiceResponseCancellationHandler = { [weak self] reason in
            guard let self, !completionState.didComplete else { return }
            completionState.didComplete = true
            var completionFields = self.voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
            completionFields["cancelledAt"] = reason
            completionFields["audioPlaybackState"] = "interrupted"
            self.markRequestCompleted(
                route: "voice.response",
                executionStartedAt: executionStartedAt,
                timing: timing,
                status: "cancelled",
                extra: completionFields
            )
            if self.currentVoiceResponseCompletionToken == completionToken {
                self.currentVoiceResponseCancellationHandler = nil
                self.currentVoiceResponseRequestID = nil
                self.currentVoiceResponseCompletionToken = nil
            }
        }

        let responseTaskToken = UUID()
        currentResponseTaskToken = responseTaskToken
        currentResponseTask = Task { [weak self] in
            await self?.runAIResponsePipeline(
                transcript: transcript,
                plannedVoiceAnalysisModelID: plannedVoiceAnalysisModelID,
                timing: timing,
                executionStartedAt: executionStartedAt,
                requestID: requestID,
                completionToken: completionToken,
                completionState: completionState,
                responseTaskToken: responseTaskToken
            )
        }
    }

    func startTutorIdleObservation() {
        userActivityIdleDetector.start()
        bindTutorIdleObservation()
    }

    func stopTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = nil
        userActivityIdleDetector.stop()
        tutorTargetClickTracker.disarm()
        isTutorObservationInFlight = false
    }

    private func bindTutorIdleObservation() {
        tutorIdleCancellable?.cancel()
        tutorIdleCancellable = userActivityIdleDetector.$isUserIdle
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self,
                      self.isTutorModeEnabled,
                      self.voiceState == .idle,
                      !self.voiceTTSClient.isPlaying,
                      !self.isTutorObservationInFlight,
                      Date().timeIntervalSince(self.lastVoiceInteractionCompletedAt) >= Self.tutorObservationVoiceCooldown else { return }

                self.isTutorObservationInFlight = true
                Task {
                    await self.performTutorObservation()
                    self.userActivityIdleDetector.observationDidComplete()
                    self.isTutorObservationInFlight = false
                }
            }
    }

    private func performTutorObservation() async {
        do {
            tutorTargetClickTracker.disarm()
            ensureCursorOverlayVisibleForAgentTask()
            voiceState = .processing

            let screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
            let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let historyForAPI = voiceConversationHistoryForAPI()

            let fullResponseText = try await analyzeVoiceResponse(
                images: labeledImages,
                systemPrompt: self.currentTutorModeSystemPrompt(),
                conversationHistory: historyForAPI,
                userPrompt: "observe the focused window and guide me to the next useful learning step.",
                onTextChunk: { _ in }
            )

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let spokenText = parseResult.spokenText

            if let pointCoordinate = parseResult.coordinate,
               let targetScreenCapture = tutorTargetScreenCapture(from: screenCaptures, screenNumber: parseResult.screenNumber) {
                let globalLocation = globalPoint(
                    fromScreenshotPoint: pointCoordinate,
                    in: targetScreenCapture
                )
                voiceState = .idle
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = targetScreenCapture.displayFrame
                detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                rememberPointedElement(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                armTutorTargetClickTracking(
                    at: globalLocation,
                    displayFrame: targetScreenCapture.displayFrame,
                    label: parseResult.elementLabel
                )
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("Tutor pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
            }

            rememberVoiceExchange(
                userTranscript: "[tutor observation]",
                assistantResponse: spokenText,
                reason: "tutor_observation"
            )

            if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await voiceTTSClient.speakText(spokenText) {
                    self.voiceState = .responding
                }
            }
        } catch is CancellationError {
            // A normal voice interaction interrupted the tutor observation.
        } catch where Self.isExpectedCancellation(error) {
            // A normal voice interaction interrupted the tutor observation.
        } catch {
            print("Tutor observation error: \(error)")
        }

        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func armTutorTargetClickTracking(at point: CGPoint, displayFrame: CGRect?, label: String?) {
        guard isTutorModeEnabled else { return }
        tutorTargetClickTracker.arm(targetPoint: point, targetRect: nil) { [weak self] clickPoint in
            guard let self else { return }
            self.lastVoiceInteractionCompletedAt = .distantPast
            self.userActivityIdleDetector.recordTutorStepCompleted()
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "tutor.target_clicked",
                fields: [
                    "label": label ?? "",
                    "targetX": Int(point.x),
                    "targetY": Int(point.y),
                    "clickX": Int(clickPoint.x),
                    "clickY": Int(clickPoint.y),
                    "displayFrame": displayFrame.map { frame in
                        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
                    } ?? ""
                ]
            )
        }
    }

    private func tutorTargetScreenCapture(from screenCaptures: [CompanionScreenCapture], screenNumber: Int?) -> CompanionScreenCapture? {
        // Resolution order:
        //   1. If Claude returned a screenNumber tag, trust it — that's a
        //      deliberate signal about which screen the element lives on.
        //   2. Otherwise, fall back to the cursor's live current screen
        //      (re-read so we don't use a stale `isCursorScreen` flag from
        //      capture time).
        //   3. Last resort: the captured `isCursorScreen` flag.
        if let screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }

        let liveMouseLocation = NSEvent.mouseLocation
        let liveCursorCapture = screenCaptures.first { $0.displayFrame.contains(liveMouseLocation) }

        return liveCursorCapture
            ?? screenCaptures.first(where: { $0.isCursorScreen })
            ?? screenCaptures.first
    }

    func globalPoint(
        fromScreenshotPoint point: CGPoint,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let calibrationOffset = applyingCalibration
            ? Self.visualGuidanceCalibrationOffset(for: capture.displayFrame)
            : .zero
        return CGPoint(
            x: displayLocalX + capture.displayFrame.origin.x,
            y: (displayHeight - displayLocalY) + capture.displayFrame.origin.y
        ).applying(
            CGAffineTransform(
                translationX: calibrationOffset.width,
                y: calibrationOffset.height
            )
        )
    }

    private func globalRect(
        fromScreenshotRect rect: CGRect,
        in capture: CompanionScreenCapture,
        applyingCalibration: Bool = true
    ) -> CGRect {
        let origin = globalPoint(fromScreenshotPoint: rect.origin, in: capture, applyingCalibration: applyingCalibration)
        let opposite = globalPoint(fromScreenshotPoint: CGPoint(x: rect.maxX, y: rect.maxY), in: capture, applyingCalibration: applyingCalibration)
        return CGRect(
            x: min(origin.x, opposite.x),
            y: min(origin.y, opposite.y),
            width: abs(opposite.x - origin.x),
            height: abs(opposite.y - origin.y)
        )
    }

    private func globalVisualGuidanceOverlay(
        fromScreenshotOverlay overlay: OpenClickyVisualGuidanceOverlay,
        in capture: CompanionScreenCapture
    ) -> OpenClickyVisualGuidanceOverlay {
        switch overlay.kind {
        case .scribble:
            return OpenClickyVisualGuidanceOverlay.scribble(
                points: overlay.points.map { globalPoint(fromScreenshotPoint: $0.cgPoint, in: capture) },
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        case .rectangle:
            guard let rect = overlay.rect else {
                return overlay
            }
            let isCalibrationAnchor = Self.isVisualGuidanceCalibrationCaption(overlay.style.caption)
            return OpenClickyVisualGuidanceOverlay.rectangle(
                rect: globalRect(
                    fromScreenshotRect: rect.cgRect,
                    in: capture,
                    applyingCalibration: !isCalibrationAnchor
                ),
                accentHex: overlay.style.accentHex,
                lineWidth: overlay.style.lineWidth,
                fillOpacity: overlay.style.fillOpacity,
                caption: overlay.style.caption,
                duration: overlay.duration
            )
        }
    }

    func analyzeVisualWorkspace(
        images: [(data: Data, label: String)],
        userPrompt: String,
        source: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Persist PTT-triggered screenshots into Screen History so they
        // become part of the AI's long-term memory. These are the
        // exact frames the user was looking at when they hit PTT — a
        // higher-signal record than the auto-captured 0.5 fps stream
        // which may have missed the moment.
        for image in images {
            PTTScreenshotArchive.persist(jpeg: image.data,
                                          label: image.label,
                                          userPrompt: userPrompt)
        }
        let modelID = OpenClickyModelCatalog.voiceAnalysisModel(withID: selectedModel).id

        OpenClickyMessageLogStore.shared.append(
            lane: "visual",
            direction: "outgoing",
            event: "visual.workspace.request",
            fields: [
                "source": source,
                "model": modelID,
                "imageCount": images.count,
                "promptLength": userPrompt.count
            ]
        )

        let systemPrompt = """
        You are OpenClicky's Visual Intelligence workspace. Analyze attached camera and screen images carefully and answer the user's prompt.

        Capabilities to apply when relevant:
        - identify objects, products, devices, people-present/not-present, scene, setting, actions, and situations.
        - scan and transcribe visible text, labels, prices, dates, codes, warnings, UI text, document snippets, and important information.
        - infer useful lookup/search terms for visible objects, logos, documents, books, products, or places. Do not claim live web browsing unless a separate Agent Mode task actually performed it.
        - call out uncertainty, ambiguous visual evidence, and what detail would verify an identification.

        Output style:
        - concise markdown is allowed.
        - no [POINT] tags, no hidden routing syntax, no spoken-TTS constraints.
        - prioritize details that help the user act now.
        """

        // xlb hint injection lives in `_analyzeVoiceResponseCore` so
        // every AI path (voice, visual, automation, text chat) picks it
        // up uniformly. Do NOT re-apply here or the hint doubles.
        return try await analyzeVoiceResponse(
            images: images,
            modelID: modelID,
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: userPrompt,
            assistantPrefill: nil,
            onTextChunk: onTextChunk
        )
    }

    // MARK: - xlinkBook (xlb) context hint injection
    //
    // When Settings > xlinkBook Integration is enabled, prepend a compact
    // [xlb-context] block to the user prompt so the model can decide to
    // call the xlb_* tools before answering. Never fails the pipeline —
    // any error from fuzzy lookup or the /agent-state fetch is swallowed
    // and the original prompt is returned unchanged.
    private static let xlbContextMaxChars = 1500
    private static let xlbAgentStateTimeout: TimeInterval = 0.2

    /// Detect a voice-triggered profile switch. Matches short bare keywords
    /// ("peeky" / "ski" / "heyclicky") AND longer phrases ("switch to peeky"
    /// / "切到 SKI" / "切换到 heyclicky"). Returns the spoken confirmation
    /// when a switch fires, nil otherwise. Applies the profile via
    /// `applyProfile` so the STT / TTS / response model + subsystems all
    /// reconcile the same way the Settings selector does.
    func handleVoiceProfileSwitch(_ userPrompt: String) -> String? {
        // Normalise: lowercase + strip trailing punctuation. Keep spaces
        // so we can match phrase forms too.
        let norm = userPrompt
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？，,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !norm.isEmpty else { return nil }

        // Require an explicit switch verb — bare "peeky" would collide
        // with chat like "let's talk about peeky". Verbs are:
        //   zh: 切换到 / 切到 / 换到 / 切换 (verb + optional 到) / 切
        //   en: switch to / switch / change to / go to / use / run
        // The keyword tail must be one of the profile names.
        let peekyKeys = ["peeky free", "peeky", "mirage", "皮基", "pky"]
        let skiKeys = ["ski mode", "ski", "斯基", "斯克"]
        let heyclickyKeys = ["heyclicky free", "heyclicky", "hey clicky", "clicky", "嘿咔哩"]

        func matchesAny(_ keys: [String]) -> Bool {
            let phrasePrefixes = [
                // English — MUST include a switch verb.
                "switch to ", "switch ", "change to ", "go to ",
                "use ", "run ",
                // Chinese — MUST include 切换/切到/换到. Note there is no
                // space after Chinese verbs so match both with/without.
                "切换到 ", "切换到", "切换 ", "切换",
                "切到 ", "切到",
                "换到 ", "换到",
                "切 "
            ]
            for prefix in phrasePrefixes {
                if norm.hasPrefix(prefix) {
                    let rest = String(norm.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    // Rest must be exactly a keyword — refuse partial
                    // matches so "switch to peeky free chat mode" (long
                    // sentence) does NOT switch; only "switch to peeky".
                    for k in keys where rest == k { return true }
                }
            }
            return false
        }

        let targetProfileID: String
        let displayEN: String
        let displayZH: String
        if matchesAny(peekyKeys) {
            targetProfileID = "mirage"
            displayEN = "Peeky Free"
            displayZH = "Peeky 免费"
        } else if matchesAny(skiKeys) {
            targetProfileID = "ski_mode"
            displayEN = "SKI Mode"
            displayZH = "SKI 模式"
        } else if matchesAny(heyclickyKeys) {
            targetProfileID = "heyclicky_free"
            displayEN = "HeyClicky Free"
            displayZH = "HeyClicky 免费"
        } else {
            return nil
        }

        let profile = OpenClickyProfileCatalog.profile(withID: targetProfileID)
        // No-op if already active — just confirm politely so the user
        // knows the app heard them.
        let already = OpenClickyProfileCatalog.activeProfile().id == targetProfileID
        if !already {
            applyProfile(profile)
        }
        OpenClickyMessageLogStore.shared.append(
            lane: "voice", direction: "internal",
            event: "openclicky.profile.voice_switch",
            fields: [
                "target_profile": targetProfileID,
                "already_active": already,
                "utterance": userPrompt
            ]
        )

        let isChinese = OpenClickyLocaleManager.shared.currentLanguage.hasPrefix("zh")
        let name = isChinese ? displayZH : displayEN
        if already {
            return isChinese ? "已经在 \(name) 了。" : "Already on \(name)."
        } else {
            return isChinese ? "已切换到 \(name)。" : "Switched to \(name)."
        }
    }

    nonisolated static func applyXLBHintIfEnabled(to userPrompt: String) async -> String {
        guard AppBundleConfiguration.xlbEnabled() else { return userPrompt }
        guard let block = await buildXLBContextBlock(userPrompt: userPrompt) else {
            return userPrompt
        }
        return block + "\n\n" + userPrompt
    }

    nonisolated private static func buildXLBContextBlock(userPrompt: String) async -> String? {
        // Focused window title is sync + cheap; grab it up front so the
        // regex check can gate the HTTP fetch.
        let focusedWindowTitle: String? = focusedWindowTitleForXLB()
        let wantsAgentState: Bool = {
            guard let title = focusedWindowTitle, !title.isEmpty else { return false }
            return title.range(of: "^xlinkBook", options: [.regularExpression, .caseInsensitive]) != nil
        }()

        async let candidates: [XLBTopicIndex.FuzzyCandidate] = fetchXLBCandidates(userPrompt: userPrompt)
        async let agentState: String? = wantsAgentState ? fetchXLBAgentState() : nil
        let (cands, state) = await (candidates, agentState)

        let hasCandidates = !cands.isEmpty
        let hasState = (state?.isEmpty == false)
        guard hasCandidates || hasState else { return nil }

        var lines: [String] = []
        lines.append("[xlb-context]")
        if let state, !state.isEmpty {
            lines.append(state)
            lines.append("")
        }
        if hasCandidates {
            lines.append("Topics you have curated in xlinkBook that may be relevant to this question:")
            for c in cands {
                var line = "- \(c.name)"
                if let parent = c.parentTopic, !parent.isEmpty {
                    line += " (topic in \(parent), browse: \(c.browseCmd))"
                } else {
                    line += " (browse: \(c.browseCmd))"
                }
                lines.append(line)
            }
            lines.append("")
            lines.append("Use the xlb_search_topic / xlb_get_topic / xlb_get_topic_section / xlb_graph tools to explore these before answering if they seem relevant.")
        }
        lines.append("[/xlb-context]")

        let assembled = lines.joined(separator: "\n")
        let finalBlock: String
        if assembled.count <= xlbContextMaxChars {
            finalBlock = assembled
        } else {
            // Cap at xlbContextMaxChars, reserving room for the truncation
            // marker so the total stays inside the budget.
            let marker = "\n[truncated]\n[/xlb-context]"
            let sliceLen = max(0, xlbContextMaxChars - marker.count)
            finalBlock = String(assembled.prefix(sliceLen)) + marker
        }

        let agentStateBytes = state?.utf8.count ?? 0
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "internal",
            event: "xlb.hint.injected",
            fields: [
                "candidateCount": cands.count,
                "agentStateBytes": agentStateBytes,
                "totalHintBytes": finalBlock.utf8.count
            ]
        )
        return finalBlock
    }

    nonisolated private static func fetchXLBCandidates(
        userPrompt: String
    ) async -> [XLBTopicIndex.FuzzyCandidate] {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await XLBTopicIndex.shared.fuzzyLookup(trimmed, limit: 5)
    }

    nonisolated private static func focusedWindowTitleForXLB() -> String? {
        guard let front = FrontmostAppCapture.capture(), front.processId > 0 else {
            return nil
        }
        return FocusedWindowCapture.capture(processId: front.processId)?.title
    }

    nonisolated private static func fetchXLBAgentState() async -> String? {
        let host = AppBundleConfiguration.xlbHostUrl()
        guard !host.isEmpty else { return nil }
        var comps = URLComponents(string: host + "/.well-known/agent-state")
        comps?.queryItems = [
            URLQueryItem(name: "with_meta", value: "1"),
            URLQueryItem(name: "consume", value: "0"),
            URLQueryItem(name: "mode", value: "summary")
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = xlbAgentStateTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let body = String(data: data, encoding: .utf8) ?? ""
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "visual",
                direction: "error",
                event: "xlb.agent_state.fetch_failed",
                fields: ["detail": String(describing: error)]
            )
            return nil
        }
    }

    func analyzeVoiceResponse(
        images: [(data: Data, label: String)],
        modelID: String? = nil,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Voice-triggered profile switch. Matches "switch to X" / "切换到 X"
        // / "切到 X" in any of the three free lanes so the user can hop
        // between profiles without opening Settings. Runs BEFORE model
        // dispatch so it never touches quota. Returns a spoken
        // confirmation string that the shared TTS pipeline speaks like
        // any other assistant reply.
        if let switched = self.handleVoiceProfileSwitch(userPrompt) {
            onTextChunk(switched)
            self.rememberVoiceExchange(
                userTranscript: userPrompt,
                assistantResponse: switched,
                reason: "voice_profile_switch"
            )
            return switched
        }

        let rawReply = try await _analyzeVoiceResponseCore(
            images: images, modelID: modelID, systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt, assistantPrefill: assistantPrefill,
            onTextChunk: onTextChunk)
        // Assist-agent reply interception: if the model requested an
        // assist-agent run via [ASSIST] {...}, execute it now and
        // replace the marker with the summary. Reentrant rounds skip.
        if AssistAgentBridge.shared.isReentrantRound { return rawReply }
        // Wire progress phrases into the shared TTS queue so the user
        // hears stage updates while the loop runs.
        weak var weakSelf = self
        return await AssistAgentBridge.shared.handleModelReply(
            rawReply,
            userPrompt: userPrompt,
            progressChannel: { phrase in
                Task { @MainActor in
                    weakSelf?.speakAssistAgentProgress(phrase)
                }
            })
    }

    /// Debounced TTS narration of assist-agent progress. Same throttle
    /// applied by the notch progress speaker so the user hears at most
    /// Assist agent progress channel. Audio is FULLY suppressed —
    /// realtime speech already owns the voice channel in the voice
    /// scene, and mixing TTS with realtime creates the double-voice
    /// bug the user reported. Progress lives on the notch badge
    /// (silent, always visible during a run).
    ///
    /// The signature is kept identical so existing callers work
    /// without change; the function is now a no-op sink. Set the
    /// AssistAgentBridge's registry entry instead — that's what the
    /// notch reads.
    func speakAssistAgentProgress(_ line: String) {
        // Deliberately silent. Notch UI is authoritative for
        // per-run progress. Terminal messages (content-filter /
        // network error) still surface via the notch's orange
        // error banner that stays visible for 15 seconds.
        _ = line
    }

    private func _analyzeVoiceResponseCore(
        images: [(data: Data, label: String)],
        modelID: String? = nil,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Reset the xlb per-turn budget at each turn entry so the
        // 20k cap does not accumulate across turns (was: monotonic).
        await XLBSensorTools.resetTurnBudget()
        // Two-tier context injection:
        //   STABLE layer (system prompt): identity + tool contracts.
        //   DYNAMIC layer (prepended to userPrompt): per-turn memory
        //     (LTM), preflight (Everywhere AX context), stash.
        //
        // Keeping dynamic bits close to the actual user question means
        // the model's attention lands on them at inference time rather
        // than being diluted across a massive system prompt.

        // Stable layer — assist-agent contract only. No LTM here.
        let systemPrompt: String = AssistAgentBridge.shared.isReentrantRound
            ? systemPrompt
            : AssistAgentBridge.effectiveSystemPrompt(systemPrompt)

        // xlb hint — injected here (not per-caller) so every AI path
        // (voice, visual, automation, text chat) that routes through
        // the core sees it uniformly. Applied to the raw user prompt
        // BEFORE the dynamic prefix is assembled, so LTM / stash /
        // active-window blocks land in front of it, and the hint stays
        // adjacent to the user's actual question.
        let xlbInjectedUserPrompt: String = await Self.applyXLBHintIfEnabled(to: userPrompt)

        // Dynamic layer — assemble in front of the user's utterance.
        let userPrompt: String = await {
            if AssistAgentBridge.shared.isReentrantRound { return xlbInjectedUserPrompt }
            var prefix = ""

            // Long-term memory (cached 5 min) + LIVE query-conditional
            // retrieval: FTS hits for the user's actual question are
            // inlined so the model reasons over Screen History without
            // needing to tool-call rewind_search first.
            //
            // NOTE: not gated on screen-capture — LTM's transcript_word
            // vault is populated from PTT / SKI / voice replies too,
            // independently of screen recording. Same for the stash
            // aggregator (PickStash / AnnotationStash / etc. come from
            // hotkey actions, not screen frames).
            let ltmBlock = await LongTermMemoryContext.build(query: userPrompt)
            if !ltmBlock.isEmpty {
                prefix += ltmBlock + "\n\n"
            }

            // Stash aggregator — same source realtime voice model sees.
            // (PickStash + LinkRectStash + WhiteboardStash + AnnotationStash
            //  + selected text + frontmost app / window / URL)
            let stashCtx = self.currentStashContextForVoicePrompt()
            if !stashCtx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prefix += stashCtx + "\n\n"
            }
            // Active-window helper (adds browser URL via AppleScript).
            if let block = AssistAgentActiveWindow.capture()?.promptBlock,
               !block.isEmpty {
                prefix += block + "\n\n"
            }
            if prefix.isEmpty { return xlbInjectedUserPrompt }
            return prefix + "---\n\nCurrent request:\n" + xlbInjectedUserPrompt
        }()
        let requestedModelID = modelID ?? selectedModel
        let selectedVoiceResponseModel = OpenClickyModelCatalog.isSpeechModelID(requestedModelID)
            ? OpenClickyModelCatalog.voiceAnalysisModel(withID: requestedModelID)
            : OpenClickyModelCatalog.voiceResponseModel(withID: requestedModelID)
        applyVoiceResponseModelSettings(selectedVoiceResponseModel)

        // SKI Mode short-circuit: if the active profile is skiMode AND
        // we can resolve an active project workspace, hand the utterance
        // to the user's CLI agent via .oc/ file bridge instead of the
        // normal provider switch. Falls through to the switch below on
        // no workspace or bridge timeout so users are never silent.
        if OpenClickyProfileCatalog.activeProfile().id == "ski_mode",
           let workspace = await OpenClickyAgentsPresenceStore.shared.effectiveActiveWorkspace() {
            let dirName = workspace.lastPathComponent
            // Mark the turn in flight so the pipeline's tail .idle
            // reset doesn't erase the processing state while the CLI
            // is still running tool calls. Caption format:
            //   "<workspace> · thinking"
            // (drops the SKI prefix — profile-dot already conveys
            // that — but keeps workspace so multi-project users know
            // which folder the turn is targeting.)
            await MainActor.run {
                self.isSKITurnInFlight = true
                self.voiceState = .processing
                self.notchCaptureWindowManager.updateBackendStatusCaption("\(dirName) · thinking")
            }
            // Bridge sends the RAW user transcript in event.text;
            // enrichment (LTM/xlb/stash/active-window) is emitted as
            // a structured `context` object on the same event — see
            // OpenClickyFileBridge.writeUtteranceAndAwait (task #307).
            let rawText = await MainActor.run {
                self.lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let bridgeText = rawText.isEmpty ? userPrompt : rawText
            // SKI-parity: fire-and-forget the utterance. The reply
            // (whenever it arrives, unbounded) is caught by our
            // continuous tail on commands.jsonl in
            // SKIModeConversationStore, which posts agentDidSpeak;
            // CompanionManager's observer then plays the TTS +
            // surfaces the response card. This matches SKI's own
            // model: no timeout, no fallback message, just wait for
            // the fs-event watcher to fire.
            //
            // approve_before_send gate — when enabled, publish the
            // pending utterance and wait for the user to confirm
            // (they either say "send it" / click send, or say "cancel").
            let approveBeforeSend = UserDefaults.standard.bool(forKey: "openclicky.ski.approveBeforeSend")
            if approveBeforeSend {
                await MainActor.run {
                    self.pendingSKIUtterance = (text: bridgeText, workspace: workspace)
                    self.notchCaptureWindowManager.updateBackendStatusCaption(
                        "SKI · pending: \(String(bridgeText.prefix(60)))"
                    )
                    NotificationCenter.default.post(
                        name: Notification.Name("com.openclicky.ski.utterancePendingApproval"),
                        object: nil,
                        userInfo: [
                            "text": bridgeText,
                            "workspace": workspace.path
                        ]
                    )
                    OpenClickyMessageLogStore.shared.append(
                        lane: "voice", direction: "internal",
                        event: "openclicky.ski.utterance_pending_approval",
                        fields: ["preview": String(bridgeText.prefix(60))]
                    )
                }
                return "" // wait for confirm to actually write
            }
            // Build context hints from the same signals Lane A uses.
            // Only signals that HIT this turn are included (short
            // natural-language brief). Each hint is additionally gated
            // on its corresponding capture/enable toggle so we don't
            // advertise a capability the app is currently NOT
            // producing (e.g. openrewind_ocr_hits when screen capture
            // is off). CLI expands via MCP tools as needed.
            let ctx = await self.buildSKIUtteranceContext(
                userQuery: rawText.isEmpty ? bridgeText : rawText
            )
            _ = await OpenClickyFileBridge.shared.writeUtteranceAndAwait(
                workspace: workspace,
                text: bridgeText,
                context: ctx,
                timeoutSeconds: 0.1
            )
            // Persist the user's utterance to transcript_word (vault
            // LTM) so subsequent xlb / stash context looks it up.
            // The assistant side lands via speakSKIModeAgentReply's
            // response-card path; here we only remember the user turn.
            if !rawText.isEmpty {
                await MainActor.run {
                    self.rememberVoiceExchange(
                        userTranscript: rawText,
                        assistantResponse: "",
                        reason: "ski_mode_utterance_only"
                    )
                }
            }
            // Keep the "SKI · thinking" caption on-screen — the reply
            // will arrive async through the tail loop and clear it via
            // speakSKIModeAgentReply -> voice pipeline's own status.
            // Return an empty text so the voice pipeline knows this
            // turn is "handled elsewhere" — no TTS via voice pipeline
            // (the tail-driven speakSKIModeAgentReply will play the
            // actual reply when the CLI agent gets around to writing
            // it). Return "" prevents Claude Agent SDK fallback.
            return ""
        }

        // Provider dispatch — every provider is now served by an
        // `LLMClient` adapter that forwards to the same `analyze*`
        // helper the old switch used to call. Byte-equivalence is
        // documented in docs/peeky-review-2026-08-06/10-llmclient-equivalence.md.
        //
        // ROUTE-directive scope note (was inline in the `.heyclickyFree`
        // arm): the `[ROUTE]` tail contract is emitted by our own Fable
        // dialog model and is only injected inside
        // `HeyClickyChatToolCallClient.analyzeVoiceResponse`. Non-Fable
        // arms rely on `OpenClickyRouteDispatcher.classifyFallback`.
        // See `docs/ROADMAP/.review-notes/F26-route-parse-2026-07-23.md`
        // Issue L3.
        let req = LLMRequest(
            model: selectedVoiceResponseModel.id,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            images: images,
            assistantPrefill: assistantPrefill
        )
        return try await dispatchViaLLMRegistry(
            provider: selectedVoiceResponseModel.provider,
            request: req,
            onTextChunk: onTextChunk)
    }

    // MARK: - LLMClient dispatch hooks
    //
    // These closures adapt the private `analyze*` helpers below to the
    // `LLMClient` protocol without widening their access. Every voice
    // response turn now dispatches through `LLMClientRegistry` — the
    // old provider switch was deleted after byte-equivalence was
    // documented in docs/peeky-review-2026-08-06/10-llmclient-equivalence.md.
    func makeLLMDispatchHooks() -> LLMDispatchHooks {
        LLMDispatchHooks(
            apple: { req, cb in
                try await AppleFoundationModelsVoiceClient.analyzeVoiceResponse(
                    images: req.images,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    onTextChunk: cb)
            },
            anthropic: { [weak self] req, cb in
                // Fail loud on torn-down manager. Returning "" would look
// like a legitimate empty reply and the caller would happily
// speak silence; the pipeline should treat this as cancelled.
guard let self else { throw CancellationError() }
                return try await self.analyzeClaudeResponse(
                    images: req.images,
                    model: req.model,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    assistantPrefill: req.assistantPrefill,
                    onTextChunk: cb)
            },
            openAI: { [weak self] req, cb in
                // Fail loud on torn-down manager. Returning "" would look
// like a legitimate empty reply and the caller would happily
// speak silence; the pipeline should treat this as cancelled.
guard let self else { throw CancellationError() }
                return try await self.analyzeOpenAIOrCodexVoiceResponse(
                    images: req.images,
                    model: req.model,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    onTextChunk: cb)
            },
            codex: { [weak self] req, cb in
                // Fail loud on torn-down manager. Returning "" would look
// like a legitimate empty reply and the caller would happily
// speak silence; the pipeline should treat this as cancelled.
guard let self else { throw CancellationError() }
                return try await self.analyzeCodexVoiceResponse(
                    images: req.images,
                    model: req.model,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    onTextChunk: cb)
            },
            mirage: { [weak self] req, cb in
                // Fail loud on torn-down manager. Returning "" would look
// like a legitimate empty reply and the caller would happily
// speak silence; the pipeline should treat this as cancelled.
guard let self else { throw CancellationError() }
                return try await self.analyzeMirageResponse(
                    images: req.images,
                    model: req.model,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    onTextChunk: cb)
            },
            heyclicky: { [weak self] req, cb in
                // Fail loud on torn-down manager. Returning "" would look
// like a legitimate empty reply and the caller would happily
// speak silence; the pipeline should treat this as cancelled.
guard let self else { throw CancellationError() }
                return try await HeyClickyChatToolCallClient.shared.analyzeVoiceResponse(
                    companionManager: self,
                    images: req.images,
                    systemPrompt: req.systemPrompt,
                    conversationHistory: req.conversationHistory,
                    userPrompt: req.userPrompt,
                    onTextChunk: cb)
            }
        )
    }

    /// Registry-based dispatch. Sole voice-response entry after the
    /// LLMClient cutover — the old provider switch was deleted after
    /// static equivalence verification (see
    /// `docs/peeky-review-2026-08-06/10-llmclient-equivalence.md`).
    /// Isolated in one method so tests / debug callers can invoke it
    /// directly.
    func dispatchViaLLMRegistry(
        provider: OpenClickyModelProvider,
        request: LLMRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let client = LLMClientRegistry.client(for: provider, hooks: makeLLMDispatchHooks())
        return try await client.send(request, onTextChunk: onTextChunk)
    }

    private func analyzeClaudeResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // Inference routing rule: Claude Agent SDK FIRST (uses the local
        // Claude Code sign-in the user already pays for), direct ClaudeAPI
        // HTTP only as fallback when the SDK is unavailable or throws.
        // Never short-circuit to HTTP for latency or capability reasons —
        // direct REST bills per token on the user's card.
        print("🧠 analyzeClaudeResponse: model=\(model) sdkAvailable=\(claudeAgentSDKAPI != nil) httpKey=\(AppBundleConfiguration.anthropicAPIKey() != nil) prefill=\(assistantPrefill?.isEmpty == false)")
        let modelOption = OpenClickyModelCatalog.voiceResponseModel(withID: model)

        if let claudeAgentSDKAPI {
            do {
                claudeAgentSDKAPI.model = modelOption.id
                claudeAgentSDKAPI.maxOutputTokens = modelOption.maxOutputTokens
                print("🧠 analyzeClaudeResponse: using Agent SDK bridge")
                let (text, _) = try await claudeAgentSDKAPI.analyzeImageStreaming(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    // M16: forward prefill to the SDK (primary) path so it behaves
                    // like the HTTP fallback below.
                    assistantPrefill: assistantPrefill,
                    onTextChunk: onTextChunk
                )
                return text
            } catch is CancellationError {
                // Cancellation means the user interrupted the primary SDK path;
                // it is not an availability failure and must never trigger a
                // paid direct-HTTP fallback.
                throw CancellationError()
            } catch {
                guard AppBundleConfiguration.anthropicAPIKey() != nil else { throw error }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "voice.response_fallback",
                    fields: [
                        "from": "claude_agent_sdk",
                        "to": "anthropic_api_key",
                        "error": error.localizedDescription
                    ]
                )
                print("🔁 analyzeClaudeResponse: Agent SDK failed, falling back to direct HTTP: \(error.localizedDescription)")
            }
        }

        if AppBundleConfiguration.anthropicAPIKey() != nil {
            claudeAPI.model = modelOption.id
            claudeAPI.maxOutputTokens = modelOption.maxOutputTokens
            print("🧠 analyzeClaudeResponse: using direct HTTP streaming (ClaudeAPI fallback)")
            let (text, _) = try await claudeAPI.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                assistantPrefill: assistantPrefill,
                onTextChunk: onTextChunk
            )
            return text
        }

        print("❌ analyzeClaudeResponse: no SDK and no HTTP key — Claude not configured")
        throw NSError(
            domain: "ClaudeAgentSDKAPI",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Claude is not configured. Sign in to Claude Code locally or set an Anthropic API key."]
        )
    }

    private func analyzeOpenAIOrCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let modelOption = OpenClickyModelCatalog.voiceAnalysisModel(withID: model)
        if !OpenClickyModelCatalog.isSpeechModelID(modelOption.id) {
            do {
                return try await analyzeCodexVoiceResponse(
                    images: images,
                    model: modelOption.id,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            } catch {
                guard AppBundleConfiguration.openAIAPIKey() != nil else { throw error }
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "error",
                    event: "voice.response_fallback",
                    fields: [
                        "from": "codex_voice_session",
                        "to": "openai_api_key",
                        "model": modelOption.id,
                        "codexModel": OpenClickyModelCatalog.codexVoiceSessionModel(withID: modelOption.id).id,
                        "error": error.localizedDescription
                    ]
                )
            }
        }

        guard AppBundleConfiguration.openAIAPIKey() != nil else {
            throw NSError(
                domain: "OpenAIAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI is not configured for this voice analysis request."]
            )
        }

        openAIAPI.model = modelOption.id
        openAIAPI.maxOutputTokens = modelOption.maxOutputTokens
        let (text, _) = try await openAIAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private func analyzeCodexVoiceResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let modelOption = OpenClickyModelCatalog.codexVoiceSessionModel(withID: model)
        codexVoiceSession.model = modelOption.id
        let (text, _) = try await codexVoiceSession.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
        return text
    }

    private static func shouldUsePreResponseFiller(
        transcript: String,
        screenContextNeeded: Bool,
        modelProvider: OpenClickyModelProvider,
        ttsProvider: OpenClickyTTSProvider
    ) -> Bool {
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let wordCount = commandText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count

        // Never prepend filler to acknowledgements, corrections, or very
        // short replies. These are exactly the cases where the filler
        // sounds like Clicky is inventing work: "one moment. sounds good."
        if wordCount <= 4 { return false }
        let acknowledgementPhrases: Set<String> = [
            "yes", "yeah", "yep", "no", "nope", "ok", "okay",
            "alright", "all right", "sounds good", "thanks", "thank you",
            "continue", "go on", "stop", "cancel", "nevermind", "never mind"
        ]
        if acknowledgementPhrases.contains(commandText) { return false }

        // Do not put spoken filler in front of direct control commands.
        // Those turns should either execute immediately or produce a
        // concrete handoff/status, not "yeah, that makes sense."
        let directActionPrefixes = [
            "open ", "play ", "pause ", "click ", "press ", "type ",
            "select ", "scroll ", "switch ", "bring ", "move ",
            "close ", "quit ", "launch "
        ]
        if directActionPrefixes.contains(where: commandText.hasPrefix) {
            return false
        }

        // Speech-to-speech Realtime already provides its own immediate
        // audio path; adding cached TTS filler would create a double voice.
        if ttsProvider == .openAIRealtime {
            return false
        }

        // Deepgram Voice Agent owns the whole voice turn when selected as
        // the response model. If this path is reached for analysis only,
        // keep fillers off to avoid cross-provider audio seams.
        if modelProvider == .deepgram {
            return false
        }

        if screenContextNeeded {
            return true
        }

        // For Cartesia/ElevenLabs/Edge/Deepgram-TTS text turns, use a
        // cached opener only when the user has asked a real multi-word
        // question or investigation. Short acknowledgements stay crisp.
        switch ttsProvider {
        case .cartesia, .elevenLabs, .microsoftEdge, .deepgram, .mirageCartesia:
            return wordCount >= 6
        case .openAIRealtime:
            return false
        }
    }

    private static let visualFollowUpHistoryDepth = 3

    static func shouldAttachScreenContext(
        to transcript: String,
        recentConversationHistory: [(userPlaceholder: String, assistantResponse: String)] = []
    ) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)

        if shouldForceAgentClipboardSelection(for: transcript) {
            return true
        }

        if isVisualGuidanceDrawingRequest(normalized: normalized, commandText: commandText) {
            return true
        }

        let explicitVisualPhrases = [
            "my screen", "the screen", "on screen", "on the screen", "this screen",
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor",
            "what am i looking", "what's on", "what is on", "what do you see",
            "look at", "take a look", "can you see", "do you see",
            "this window", "that window", "current window", "active window",
            "this app", "that app", "this page", "that page", "this button", "that button",
            "this field", "that field", "this menu", "that menu",
            "where is", "where's", "point to", "show me where", "highlight",
            "draw around", "draw round", "circle around", "circle round", "rectangle around",
            "rectangle round", "box around", "box round", "outline", "scribble", "trace",
            "selection around", "shape around", "shapes around", "logo",
            "layout", "spacing", "padding", "margin", "margins", "green symbol",
            "green mark",
            "click", "press", "select", "open this", "open that"
        ]
        if explicitVisualPhrases.contains(where: { normalized.contains($0) || commandText.contains($0) }) {
            return true
        }

        // FIX(ai-audit-2026-08-01 context-#1): CJK + JA + ES phrases.
        // `normalized` above used `.diacriticInsensitive.lowercased()`
        // which drops CJK chars, so all Chinese/Japanese "屏幕上"/
        // "画面" queries silently skipped screen attach. Scan raw
        // transcript against multilingual phrase list.
        let rawLower = transcript.lowercased()
        let multilingualVisualPhrases: [String] = [
            // Simplified Chinese
            "屏幕", "屏幕上", "这个屏幕", "这个窗口", "当前窗口", "这个页面",
            "这个应用", "这个按钮", "看到", "看看", "看一下", "指出", "指向",
            "点击", "标出", "圈出", "画一个", "画个", "画个圈", "在哪里", "哪里",
            "高亮", "突出显示", "示范", "演示", "指导", "指引",
            // Traditional Chinese
            "螢幕", "這個螢幕", "這個視窗", "看到什麼",
            // Japanese
            "画面", "この画面", "このウィンドウ", "見えて", "見せて", "どこ",
            "クリック", "指して", "囲んで", "ハイライト",
            // Spanish
            "en la pantalla", "esta ventana", "esta página", "muéstrame",
            "señala", "haz clic", "dónde está",
            // French
            "à l'écran", "sur l'écran", "cette fenêtre", "montre-moi",
            "où est", "cliquez"
        ]
        if multilingualVisualPhrases.contains(where: { transcript.contains($0) || rawLower.contains($0) }) {
            return true
        }

        let visualTokens: Set<String> = [
            "screen", "window", "button", "field", "menu", "dialog", "popup",
            "page", "tab", "cursor", "visible", "shown", "displayed", "image",
            "screenshot", "icon", "link", "sidebar", "toolbar", "dock", "logo",
            "layout", "spacing", "padding", "margin", "margins", "size", "sized",
            "highlight", "rectangle", "rectangles", "circle", "circles",
            "shape", "shapes", "box", "outline", "scribble", "scribbles", "trace",
            "left", "right", "top", "bottom", "symbol", "green", "calibrate", "calibration"
        ]
        let tokens = commandText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: { visualTokens.contains($0) }) { return true }

        let visualFollowUps: Set<String> = [
            "how about now",
            "what about now",
            "try again",
            "check again",
            "look again",
            "can you try again",
            "can you check again",
            "can you look again"
        ]
        if visualFollowUps.contains(commandText),
           recentConversationHistory
           .suffix(visualFollowUpHistoryDepth)
           .contains(where: { turn in
               let recentText = "\(turn.userPlaceholder) \(turn.assistantResponse)"
                   .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                   .lowercased()
               return explicitVisualPhrases.contains(where: recentText.contains)
                   || recentText
                   .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                   .contains(where: { visualTokens.contains(String($0)) })
           }) {
            return true
        }

        return false
    }

    static func isScreenCalibrationRequest(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let calibrationPhrases = [
            "start screen calibration", "begin screen calibration", "run screen calibration",
            "enter calibration mode", "calibration mode",
            "calibrate the screen", "calibrate screen", "calibrate this display",
            "calibrate our screens", "calibrate screens", "calibrate display",
            "screen calibration", "calibration anchor"
        ]
        return calibrationPhrases.contains { normalized.contains($0) || commandText.contains($0) }
    }

    private static func isVisualGuidanceDrawingRequest(normalized: String, commandText: String) -> Bool {
        let visualDrawPatterns = [
            #"\b(?:draw|put|place|add|show|make)\s+(?:a\s+|an\s+|the\s+)?(?:rectangle|rect|box|circle|oval|ring|outline|shape)\s+(?:around|round|over|on|onto)\b"#,
            // `mark` is deliberately NOT in this list. Unlike circle / box /
            // outline / highlight, it is overloaded: "mark this task as done
            // later" and "mark this as read" are to-do phrasing, not drawing
            // requests, and matched here they forced a screenshot capture on
            // every such utterance. The unambiguous verbs stay.
            #"\b(?:circle|box|outline|highlight)\s+(?:the\s+|this\s+|that\s+|a\s+|an\s+)?[a-z0-9][a-z0-9\s-]{0,80}\b"#,
            // `mark` only counts when a drawing preposition follows the
            // target — "mark around the icon", "mark over the button".
            #"\bmark\s+(?:around|round|over|onto)\b"#,
            #"\b(?:draw|trace|scribble)\s+(?:around|round|over|on|onto)\b"#
        ]

        for text in [normalized, commandText] {
            for pattern in visualDrawPatterns {
                if text.range(of: pattern, options: .regularExpression) != nil {
                    return true
                }
            }
        }

        return false
    }

    private static func shouldAttachCameraContext(to transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let commandText = SpokenText.normalizedSpokenCommandText(transcript)
        let cameraPhrases = [
            "camera", "webcam", "cam", "through the camera", "from the camera",
            "what am i holding", "what is this object", "what's this object",
            "what is in my hand", "what's in my hand", "on my desk", "behind me",
            "in the room", "in front of me", "scan this", "read this label",
            "look at this item", "identify this", "identify that", "what product is this"
        ]
        return cameraPhrases.contains { normalized.contains($0) || commandText.contains($0) }
    }

    private func captureCameraFrameForVoiceResponseIfAvailable(transcript: String) async -> OpenClickyCameraFrame? {
        let userEnabledCameraContext = UserDefaults.standard.bool(forKey: AppBundleConfiguration.userCameraVoiceContextEnabledDefaultsKey)
        guard userEnabledCameraContext || Self.shouldAttachCameraContext(to: transcript) else { return nil }
        do {
            return try await OpenClickyCameraCaptureController.shared.captureJPEGFrame(labelPrefix: "camera context")
        } catch {
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "error",
                event: "voice.camera_context_unavailable",
                fields: [
                    "error": error.localizedDescription,
                    "userEnabledCameraContext": userEnabledCameraContext
                ]
            )
            return nil
        }
    }

    func captureAllScreensForVoiceResponseIfAvailable() async throws -> [CompanionScreenCapture] {
        // Prefer the prewarmed capture started at keyDown if it's fresh.
        // Otherwise fall back to a synchronous capture so the AI still
        // gets a screenshot when the prewarm path was skipped (e.g. text
        // input, programmatic transcript).
        if let prewarmed = prewarmedScreenshotTask,
           let startedAt = prewarmedScreenshotStartedAt,
           Date().timeIntervalSince(startedAt) <= Self.prewarmedScreenshotMaxAge {
            prewarmedScreenshotTask = nil
            prewarmedScreenshotStartedAt = nil
            do {
                return try await prewarmed.value
            } catch {
                print("⚠️ Prewarmed screenshot failed, falling back to fresh capture: \(error)")
                return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }
        }

        // Stale or missing prewarm — discard and capture fresh.
        prewarmedScreenshotTask?.cancel()
        prewarmedScreenshotTask = nil
        prewarmedScreenshotStartedAt = nil
        return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
    }

    /// Starts capturing a screenshot in parallel with audio recording.
    /// Called from `.pressed` so the JPEG-encoded captures are usually
    /// ready by the time the user releases the key. No-op when screen
    /// recording permission is missing — the response path falls back
    /// to text-only in that case.
    func startPrewarmedScreenshotCaptureIfPossible() {
        guard hasScreenContentPermission else { return }

        // Cancel any stale capture from a prior press that never landed
        // (e.g. user pressed and released without speaking).
        prewarmedScreenshotTask?.cancel()

        prewarmedScreenshotStartedAt = Date()
        prewarmedScreenshotTask = Task.detached(priority: .userInitiated) {
            try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        }
    }

    func analyzeComputerUsePointingResponse(
        image: (data: Data, label: String),
        capture: CompanionScreenCapture,
        systemPrompt: String,
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let resolver = Self.computerUsePointingResolver(
            selectedVoiceModelID: selectedModel,
            selectedComputerUseModelID: selectedComputerUseModel
        )

        switch resolver {
        case .openAIRealtime:
            let text = try await openAIRealtimeSpeechClient.analyzeImageResponse(
                images: [image],
                modelID: selectedPointingModel.id,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
            return text
        case .anthropicAPI:
            return try await analyzeClaudeResponse(
                images: [image],
                model: selectedPointingModel.id,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        case .codexCLI:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            let text = try await detector.detectPointTag(
                screenshotData: image.data,
                screenshotLabel: image.label,
                userQuestion: userPrompt,
                systemPrompt: systemPrompt,
                displayWidthInPixels: capture.screenshotWidthInPixels,
                displayHeightInPixels: capture.screenshotHeightInPixels
            )
            onTextChunk(text)
            return text
        case .openAIResponses:
            openAIAPI.model = selectedPointingModel.id
            let (text, _) = try await openAIAPI.analyzeImage(
                images: [image],
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            onTextChunk(text)
            return text
        case .unsupported:
            throw NSError(
                domain: "OpenClickyComputerUsePointing",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedPointingModel.id) is not a supported pointing model."]
            )
        }
    }

    static func computerUsePointingResolver(
        selectedVoiceModelID: String,
        selectedComputerUseModelID: String
    ) -> OpenClickyComputerUsePointingResolver {
        // The voice model was accepted and discarded (`selectedVoiceModelID _`),
        // so a live realtime voice session still routed pointing through
        // whatever the computer-use setting said — typically Codex CLI. That
        // means leaving the open realtime socket mid-turn to spawn a separate
        // process, when the session already has vision and can answer inline.
        //
        // Realtime speech models take the direct Realtime API path (CLAUDE.md
        // "Inference Routing", the stated exemption to the money rule), and
        // that applies to pointing within such a session too.
        // Test the id directly. `voiceAnalysisModel(withID:)` searches
        // voiceResponseModels, and realtime ids live in speechModels, so it
        // silently falls back to the default (gpt-5.5) for exactly the ids
        // this check cares about.
        if OpenClickyModelCatalog.isSpeechModelID(selectedVoiceModelID) {
            return .openAIRealtime
        }

        let pointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModelID)
        if pointingModel.provider == .openAI,
           OpenClickyModelCatalog.isSpeechModelID(pointingModel.id) {
            return .openAIRealtime
        }

        switch pointingModel.provider {
        case .anthropic:
            return .anthropicAPI
        case .codex:
            return .codexCLI
        case .openAI:
            return .openAIResponses
        case .apple, .deepgram, .heyclickyFree, .peekyFree:
            // Mirage is Claude underneath but its rotating-UUID transport
            // does not go through ElementLocationDetector (which assumes a
            // direct Anthropic API key). Pointing on mirage is unsupported
            // until the detector is refactored to accept a pluggable client.
            return .unsupported
        }
    }

    static let nativeClickPointingSystemPrompt = """
    You are OpenClicky's visual click target resolver. The user wants OpenClicky to actually click in the visible app, not merely point or explain.

    Identify the single clickable UI element only when it visibly and directly matches the user's request. Do not choose unrelated, nearby, generic, decorative, or merely available controls. Return exactly one short phrase followed by one [POINT:x,y:label] tag. Use screenshot pixel coordinates with origin at the top-left. If there is no safe directly relevant matching target, return [POINT:none].
    """

    private func attemptProactiveElementPointingIfUseful(
        transcript: String,
        spokenText: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard Self.shouldAttemptProactivePointing(for: transcript) else { return }
        guard let targetScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else { return }

        let selectedPointingModel = OpenClickyModelCatalog.computerUseModel(withID: selectedComputerUseModel)
        let userQuestion = "\(transcript)\n\nOpenClicky's answer: \(spokenText)"
        let displayLocalLocation: CGPoint?

        switch selectedPointingModel.provider {
        case .anthropic:
            guard let anthropicAPIKey = AppBundleConfiguration.anthropicAPIKey() else { return }
            let detector = ElementLocationDetector(apiKey: anthropicAPIKey, model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectElementLocation(
                screenshotData: targetScreenCapture.imageData,
                userQuestion: userQuestion,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .codex:
            let detector = CodexPointDetector(model: selectedPointingModel.id)
            displayLocalLocation = await detector.detectDisplayLocalPoint(
                screenshotData: targetScreenCapture.imageData,
                screenshotLabel: targetScreenCapture.label,
                userQuestion: userQuestion,
                displayWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                displayHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints
            )
        case .apple, .openAI, .deepgram, .heyclickyFree, .peekyFree:
            // Pointing on mirage not yet wired (see selectedPointingBackend
            // above).
            return
        }

        guard let displayLocalLocation else { return }

        let displayFrame = targetScreenCapture.displayFrame
        let globalLocation = CGPoint(
            x: displayLocalLocation.x + displayFrame.origin.x,
            y: displayLocalLocation.y + displayFrame.origin.y
        )

        voiceState = .idle
        detectedElementBubbleText = Self.shortPointingCaption(from: spokenText)
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = globalLocation
        rememberPointedElement(at: globalLocation, displayFrame: displayFrame, label: "proactive")
        ClickyAnalytics.trackElementPointed(elementLabel: "proactive")
        print("🎯 Proactive element pointing: (\(Int(displayLocalLocation.x)), \(Int(displayLocalLocation.y)))")
    }

    private static func shouldAttemptProactivePointing(for transcript: String) -> Bool {
        let normalizedTranscript = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let normalizedCommandText = SpokenText.normalizedSpokenCommandText(transcript)

        let voiceStatusPhrases = [
            "can you hear",
            "hear me",
            "mic",
            "microphone",
            "not speaking",
            "speaking",
            "voice",
            "audio",
            "responding",
            "response",
            "slow",
            "taking so long",
            "lag"
        ]
        if voiceStatusPhrases.contains(where: { normalizedCommandText.contains($0) }) {
            return false
        }

        let screenRelatedPhrases = [
            "screen",
            "window",
            "button",
            "menu",
            "setting",
            "permission",
            "file",
            "folder",
            "tab",
            "click",
            "open",
            "where",
            "how do i",
            "what is this",
            "what's this",
            "this screen",
            "this window",
            "this button",
            "this menu",
            "this file",
            "this folder",
            "this tab",
            "this setting",
            "that screen",
            "that window",
            "that button",
            "that menu",
            "that file",
            "that folder",
            "that tab",
            "that setting",
            "right here",
            "over here",
            "up here",
            "down here",
            "what am i looking at",
            "show me",
            "point",
            "cursor"
        ]

        return screenRelatedPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func pointingBubbleText(for elementLabel: String?) -> String {
        let trimmedLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedLabel.isEmpty else {
            return "right here"
        }
        return "right here: \(trimmedLabel)"
    }

    private static func shortPointingCaption(from spokenText: String) -> String {
        let flattenedText = spokenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattenedText.count > 76 else {
            return flattenedText.isEmpty ? "right here" : flattenedText
        }

        let endIndex = flattenedText.index(flattenedText.startIndex, offsetBy: 76)
        let prefix = String(flattenedText[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return prefix + "..."
    }

    /// If the cursor is in transient mode (user toggled "Show OpenClicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while voiceTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Logs a response failure but stays SILENT. We never speak with
    /// the macOS system TTS — that introduces a second voice that the
    /// user doesn't recognize. Errors surface through logs and the
    /// response card; the agent simply doesn't speak this turn.
    func speakResponseFailureFallback(_ error: Error) {
        guard !Self.isExpectedCancellation(error) else { return }
        let message = userFacingResponseFailureMessage(for: error)
        print("⚠️ Voice response failure (silent — no system-voice fallback): \(message)")
        var fields: [String: Any] = [
            "error": error.localizedDescription,
            "message": message
        ]
        fields.merge(ttsFailureDiagnosticFields(for: error), uniquingKeysWith: { _, new in new })
        OpenClickyMessageLogStore.shared.append(
            lane: "voice",
            direction: "incoming",
            event: "voice.response_failure_silent",
            fields: fields
        )
        latestVoiceResponseCard = ClickyResponseCard(
            source: .voice,
            rawText: message,
            contextTitle: lastTranscript ?? ""
        )
    }

    static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        let description = String(describing: error).lowercased()
        return description == "cancellationerror()" || description.contains("cancelled") || description.contains("canceled")
    }

    private func userFacingResponseFailureMessage(for error: Error) -> String {
        // Peeky Free's `MirageError.quotaExhausted` propagates as a
        // Swift error, not an NSError bridge, so pattern-match it
        // BEFORE falling through to the NSError-domain switch.
        if case let MirageError.quotaExhausted(retryAfter) = error {
            if let retry = retryAfter, retry > 0 {
                let mins = Int(retry / 60)
                if mins >= 1 {
                    return "Peeky Free's free-tier quota is exhausted for now. Try again in ~\(mins) min, or switch to a paid provider in Settings."
                }
                return "Peeky Free's free-tier quota is exhausted for now. Try again in \(Int(retry))s, or switch to a paid provider in Settings."
            }
            return "Peeky Free's free-tier daily quota is exhausted. Try again tomorrow, or switch to a paid provider in Settings."
        }

        let nsError = error as NSError

        switch nsError.domain {
        case "ClaudeAPI":
            if nsError.code == -1000 {
                return "Anthropic is not configured. Set the Anthropic API key and relaunch."
            }
            return "Claude returned an error. Check the app log for the exact response."
        case "ElevenLabsTTS":
            return "Voice playback failed, but the Claude response completed. Check the app log for the TTS error."
        case "DeepgramTTS":
            if nsError.code == Self.deepgramNotConfiguredErrorCode {
                return "Deepgram is not configured. Add a Deepgram API key in Settings."
            }
            return "Deepgram voice playback failed. Check the app log for the TTS error."
        case "CompanionScreenCapture":
            return "Screen capture failed. Grant Screen Recording to this exact app, then quit and reopen."
        default:
            return "Something went wrong. Check the app log for the exact error."
        }
    }

    private func ttsFailureDiagnosticFields(for error: Error) -> [String: Any] {
        let nsError = error as NSError
        var fields: [String: Any] = [
            "ttsProvider": selectedTTSProvider.rawValue
        ]

        if selectedTTSProvider == .deepgram || nsError.domain == "DeepgramTTS" {
            let currentSnapshot = DeepgramTTSConfigurationSnapshot.current()
            fields["deepgramKeyConfigured"] = currentSnapshot.hasAPIKey
            fields["deepgramVoiceID"] = currentSnapshot.voiceID
            fields["deepgramSnapshotMatchesClient"] = (cachedDeepgramTTSSnapshot == currentSnapshot)

            if nsError.domain == "DeepgramTTS", nsError.code == Self.deepgramNotConfiguredErrorCode {
                fields["ttsFailureKind"] = currentSnapshot.hasAPIKey ? "stale_client" : "missing_key"
            } else if nsError.domain == "DeepgramTTS" {
                fields["ttsFailureKind"] = "playback_failure"
            } else {
                fields["ttsFailureKind"] = "unknown"
            }
            return fields
        }

        if nsError.domain == "ElevenLabsTTS" || nsError.domain == "CartesiaTTS" {
            fields["ttsFailureKind"] = "playback_failure"
        }
        return fields
    }

    /// Extracted from `sendTranscriptToClaudeWithScreenshot(...)` Task closure
    /// to keep Swift's type-checker within its per-expression budget on
    /// Xcode 26.0.1. Behavior is 1:1 identical to the inline closure.
    @MainActor
    private func runAIResponsePipeline(
        transcript: String,
        plannedVoiceAnalysisModelID: String?,
        timing: OpenClickyRequestTiming?,
        executionStartedAt: Date?,
        requestID: String?,
        completionToken: UUID,
        completionState: OpenClickyRequestCompletionState,
        responseTaskToken: UUID
    ) async {
        defer { self.clearCurrentResponseTask(ifMatches: responseTaskToken) }
        // Stay in processing (spinner) state — no streaming text displayed
        self.voiceState = .processing

        func completeRequest(status: String = "success", extra: [String: Any] = [:]) async {
            await MainActor.run {
                guard !completionState.didComplete else { return }
                completionState.didComplete = true
                if self.currentVoiceResponseCompletionToken == completionToken {
                    self.currentVoiceResponseCancellationHandler = nil
                    self.currentVoiceResponseRequestID = nil
                    self.currentVoiceResponseCompletionToken = nil
                }
                self.scheduleVoiceResponseCaptionClear()
                var completionFields = self.voiceResponseExecutionFields(effectiveModelID: plannedVoiceAnalysisModelID)
                extra.forEach { completionFields[$0.key] = $0.value }
                self.markRequestCompleted(
                    route: "voice.response",
                    executionStartedAt: executionStartedAt,
                    timing: timing,
                    status: status,
                    extra: completionFields
                )
            }
        }

        do {
            OpenClickyApplicationUsageLogStore.shared.recordFrontmostApplication(source: "voice_question")
            let historyForAPI = self.voiceConversationHistoryForAPI()

            // Circle-while-talking: if the user drew a freehand trail during
            // this PTT hold, always attach visual context (crop + full screen).
            let circleHandoff = await self.consumePendingCircleSelectHandoff(instruction: transcript)

            // Only attach screenshots when the utterance actually needs
            // visual context. Text-only turns should not pay the capture,
            // base64, upload, and vision-processing latency tax.
            let captureStartedAt = Date()
            // HeyClicky Free selections always attach screen context —
            // the free tier prices vision the same as text, and users
            // expect "look at this" to just work in any language,
            // without matching an English keyword list.
            let isHeyClickyFreeVoiceModel = OpenClickyModelCatalog
                .voiceResponseModel(withID: selectedModel).provider == .heyclickyFree
            // Peeky Free / mirage always attaches the current screen —
            // matches Peeky reference client behaviour (chat.rs assumes a
            // screenshot is available). Without this the user asking
            // "怎么看待这个视频" gets Claude blind and it hallucinates
            // (e.g. rambling about the mouse cursor).
            let isMirageVoiceModel = OpenClickyModelCatalog
                .voiceResponseModel(withID: selectedModel).provider == .peekyFree
            let shouldAttachScreenContext = circleHandoff != nil
                || isHeyClickyFreeVoiceModel
                || isMirageVoiceModel
                || Self.shouldAttachScreenContext(
                    to: transcript,
                    recentConversationHistory: historyForAPI
                )
            let screenCaptures: [CompanionScreenCapture]
            if shouldAttachScreenContext {
                screenCaptures = try await captureAllScreensForVoiceResponseIfAvailable()
            } else {
                prewarmedScreenshotTask?.cancel()
                prewarmedScreenshotTask = nil
                prewarmedScreenshotStartedAt = nil
                screenCaptures = []
            }
            let cameraFrame = await captureCameraFrameForVoiceResponseIfAvailable(transcript: transcript)
            // Pre-compute to help Swift 5.10+ type-checker stay within budget.
            let screenshotsImageBytes: Int = screenCaptures.reduce(0) { $0 + $1.imageData.count }
            let circleImageBytes: Int = circleHandoff?.imageData.count ?? 0
            let cameraImageBytes: Int = cameraFrame?.data.count ?? 0
            let totalImageBytes: Int = screenshotsImageBytes + circleImageBytes + cameraImageBytes
            let executionMethodString: String = shouldAttachScreenContext
                ? "captureAllScreensForVoiceResponseIfAvailable"
                : "skipped_text_only_turn"
            var stageExtra: [String: Any] = [:]
            stageExtra["executor"] = "screen_capture"
            stageExtra["executionMethod"] = executionMethodString
            stageExtra["controller"] = "ScreenCaptureKit"
            stageExtra["screenContextNeeded"] = shouldAttachScreenContext
            stageExtra["screenCount"] = screenCaptures.count
            stageExtra["circleSelectAttached"] = circleHandoff != nil
            stageExtra["cameraContextAttached"] = cameraFrame != nil
            stageExtra["imageBytes"] = totalImageBytes
            self.markRequestStageCompleted(
                route: "voice.response",
                stage: "screen_capture",
                stageStartedAt: captureStartedAt,
                timing: timing,
                extra: stageExtra
            )

            guard !Task.isCancelled else {
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_screen_capture"])
                return
            }

            // Build image labels with the actual screenshot pixel dimensions
            // so Claude's coordinate space matches the image it sees. We
            // scale from screenshot pixels to display points ourselves.
            var labeledImages: [(data: Data, label: String)] = []
            if let circleHandoff {
                let rect = circleHandoff.selection.captureRect
                labeledImages.append((
                    data: circleHandoff.imageData,
                    label: "circled region crop (primary focus; \(Int(rect.width))x\(Int(rect.height)) pt) — user freehand-selected this area while speaking"
                ))
            }
            labeledImages.append(contentsOf: screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            })
            if let cameraFrame {
                labeledImages.append((data: cameraFrame.data, label: cameraFrame.label))
            }

            let userPromptForClaude: String
            if labeledImages.isEmpty {
                userPromptForClaude = "\(transcript)\n\nNo screenshot is available. Answer from the transcript only and use [POINT:none]."
            } else if let circleHandoff {
                let note = circleHandoff.selection.ambientSummary.isEmpty
                    ? "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context."
                    : "The user circled a screen region while speaking. The first image is the cropped circled area; following images show broader screen context.\n\(circleHandoff.selection.ambientSummary)"
                userPromptForClaude = "\(transcript)\n\n\(note)"
            } else {
                userPromptForClaude = transcript
            }

            let hasVisualContext = !labeledImages.isEmpty
            let isRealtimeResponseModel = OpenClickyModelCatalog.isSpeechModelID(self.selectedModel)
            let visualAnalysisModelID = isRealtimeResponseModel && hasVisualContext
                ? OpenClickyModelCatalog.voiceAnalysisModel(withID: self.selectedModel).id
                : self.selectedModel

            // Realtime speech turns are audio-first. They do not currently
            // carry OpenClicky's screenshot payload into the response model,
            // so visual requests must continue through the screenshot-aware
            // voice path below. The playback engine can still be Realtime.
            if isRealtimeResponseModel && !hasVisualContext {
                let realtimeStartedAt = Date()
                var didMarkRealtimeAudioStarted = false
                let realtimeText = try await self.openAIRealtimeSpeechClient.speakResponse(
                    systemPrompt: currentRealtimeVoiceSystemPrompt(),
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptForClaude,
                    onTextChunk: { accumulatedText in
                        let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        self.latestVoiceResponseCard = ClickyResponseCard(
                            source: .voice,
                            rawText: trimmed,
                            contextTitle: transcript
                        )
                        self.updateVoiceResponseCaption(trimmed)
                    },
                    onPlaybackStarted: {
                        guard !didMarkRealtimeAudioStarted else { return }
                        didMarkRealtimeAudioStarted = true
                        self.voiceState = .responding
                        self.markRequestStageCompleted(
                            route: "voice.response",
                            stage: "tts_audio_started",
                            stageStartedAt: realtimeStartedAt,
                            timing: timing,
                            extra: [
                                "executor": "realtime_voice",
                                "executionMethod": "OpenAIRealtimeSpeechClient.speakResponse",
                                "controller": "OpenAIRealtimeSpeechClient",
                                "speechModel": self.selectedModel,
                                "speechVoice": self.openAIRealtimeSpeechClient.voiceID
                            ]
                        )
                    }
                )
                let spokenText = realtimeText.isEmpty ? "Done." : realtimeText
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "model_response",
                    stageStartedAt: realtimeStartedAt,
                    timing: timing,
                    extra: {
                        var fields = self.voiceResponseExecutionFields()
                        fields["responseLength"] = spokenText.count
                        fields["imageCount"] = labeledImages.count
                        fields["realtimeResponseModelOverride"] = true
                        return fields
                    }()
                )

                self.rememberVoiceExchange(
                    userTranscript: transcript,
                    assistantResponse: spokenText,
                    reason: "realtime_response"
                )
                do {
                    try codexHomeManager.appendPersistentMemoryEvent(
                        userRequest: transcript,
                        agentResponse: spokenText
                    )
                } catch {
                    print("⚠️ OpenClicky memory update failed: \(error)")
                }
                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.updateVoiceResponseCaption(spokenText)
                self.scheduleWidgetSnapshotPublish()
                self.pendingAgentOfferInstruction = nil
                self.pendingAgentOfferAt = nil
                await completeRequest(extra: [
                    "audioPlaybackState": "finished",
                    "realtimeResponseModelOverride": true
                ])
                return
            }

            // Only use a pre-response filler when it is buying real
            // latency cover. For text-only Haiku turns the logs show
            // first audio is already ~1s away, and prepended phrases
            // sound unnatural on short replies ("one moment. sounds
            // good..."). Screen/visual turns still benefit from a
            // neutral filler while capture + vision processing happens.
            let shouldUseFiller = Self.shouldUsePreResponseFiller(
                transcript: transcript,
                screenContextNeeded: hasVisualContext,
                modelProvider: OpenClickyModelCatalog.voiceResponseModel(withID: visualAnalysisModelID).provider,
                ttsProvider: self.selectedTTSProvider
            )
            let chosenFiller = shouldUseFiller
                ? FillerPhraseLibrary.shared.contextualFiller(
                    for: transcript,
                    screenContextNeeded: hasVisualContext
                )
                : nil
            let voiceSystemPrompt: String = {
                let base = currentVoiceResponseSystemPrompt()
                guard let chosenFiller else { return base }
                return base + """


                OPENER ALREADY SPOKEN:
                The user has already heard you say: "\(chosenFiller.phrase)" — that audio plays the instant they release the push-to-talk key, before you have produced a single token. Your reply will be appended directly after it, so write a NATURAL CONTINUATION:
                - Do NOT repeat or paraphrase the opener (no "one moment", "give me a second", "let me check", "take a look", "that makes sense", "working on it", "checking now", "okay", "alright", "got it", "let's see").
                - Start with the substance, not a greeting. The first words you generate should be the next words the user hears after the opener.
                """
            }()

            let modelStartedAt = Date()
            var modelResponseFields = self.voiceResponseExecutionFields(
                effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
            )
            if visualAnalysisModelID != self.selectedModel {
                modelResponseFields["visualAnalysisModel"] = visualAnalysisModelID
                modelResponseFields["realtimeVisualPathOverride"] = true
            }
            let ttsStartedAt = Date()
            var didMarkAudioStarted = false

            // Open a sentence-pipelined TTS session BEFORE the LLM
            // call starts. As tokens arrive, we push deltas to the
            // session, which fires per-sentence TTS requests in
            // parallel and plays them in order. First audio reaches
            // the speaker as soon as the FIRST sentence completes,
            // not after the whole response.
            let streamingTTSSession = self.voiceTTSClient.beginStreamingResponse {
                guard !didMarkAudioStarted else { return }
                didMarkAudioStarted = true
                self.voiceState = .responding
                self.markRequestStageCompleted(
                    route: "voice.response",
                    stage: "tts_audio_started",
                    stageStartedAt: ttsStartedAt,
                    timing: timing,
                    extra: [
                        "executor": "tts",
                        "executionMethod": self.activeTTSExecutionMethodBeginStreaming,
                        "controller": self.activeTTSControllerName,
                        "preResponseFillerUsed": chosenFiller != nil,
                        "preResponseFillerPhrase": chosenFiller?.phrase ?? "",
                        "preResponseFillerDelayMs": chosenFiller == nil
                            ? 0
                            : StreamingTTSSession.preResponseFillerDelayMilliseconds
                    ]
                )
            }

            // Schedule the pre-baked filler after a short natural
            // thinking beat. The first LLM sentence enqueues behind
            // it via the chain ordering, so the user hears the filler
            // at roughly 300-500ms, then the substantive continuation.
            // The system prompt was already augmented above with the
            // exact text of this filler so Haiku's reply continues
            // from it instead of restarting.
            if let chosenFiller {
                streamingTTSSession.enqueuePrebakedSamples(chosenFiller.samples)
            }

            // Track the cumulative spoken text we've already pushed
            // into the TTS pipeline. We only emit a delta when the
            // newly-parsed safe-spoken text strictly extends what
            // we've emitted — never re-emit, never speak retracted
            // text (e.g. when a `[POINT:...]` tag completes mid-
            // stream and the parser strips it).
            var emittedSpokenSoFar = ""
            // Throttle the response-card publish so we don't re-render
            // SwiftUI on every LLM token (which can be 10+ per second).
            // Each publish hits the main actor, contending with the
            // cursor-tracking timer and audio scheduler. 100ms cadence
            // is plenty for visible "live caption" feedback.
            var lastCardPublishedAt: Date = .distantPast
            let cardPublishInterval: TimeInterval = 0.1
            // Build the assistant prefill so Haiku's reply continues
            // from the spoken filler at the autoregressive level
            // (Anthropic-only; OpenAI/Codex paths fall back to the
            // system-prompt directive). We keep the prefill trimmed
            // for Anthropic's assistant-prefix rules, then rejoin it
            // with the continuation when building local display text.
            //
            // The streamed `accumulatedText` we get back from the
            // Claude API path is ONLY the continuation; the prefill
            // is not echoed. That matches our pipeline exactly: the
            // filler is already playing from the pre-baked PCM, so
            // we only want to push the continuation through the
            // sentence-streaming TTS. The prefill text is folded
            // back into `fullResponseText` AFTER streaming so logs
            // and conversation history record the complete utterance.
            let assistantPrefillText: String? = chosenFiller.map {
                $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let continuationText = try await analyzeVoiceResponse(
                images: labeledImages,
                modelID: visualAnalysisModelID,
                systemPrompt: voiceSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: userPromptForClaude,
                assistantPrefill: assistantPrefillText,
                onTextChunk: { accumulatedText in
                    let parsedSpoken = Self.parsePointingCoordinates(from: accumulatedText).spokenText
                    let trimmed = parsedSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let now = Date()
                        if now.timeIntervalSince(lastCardPublishedAt) >= cardPublishInterval {
                            lastCardPublishedAt = now
                            // Prepend the filler text so the card
                            // matches what the user actually hears
                            // (cached filler PCM plays before the
                            // continuation).
                            let displayed: String
                            if let prefill = assistantPrefillText {
                                displayed = Self.combinedVoiceResponseText(
                                    prefill: prefill,
                                    continuation: trimmed
                                )
                            } else {
                                displayed = trimmed
                            }
                            self.latestVoiceResponseCard = ClickyResponseCard(
                                source: .voice,
                                rawText: displayed,
                                contextTitle: transcript
                            )
                            self.updateVoiceResponseCaption(displayed)
                        }
                    }

                    // Strip a trailing partial visual-guidance tag so we
                    // never push "[POI", "[RECT", or "[SCRIBBLE" into TTS.
                    let safeSpoken = Self.stripTrailingVisualGuidanceTagFragment(parsedSpoken)

                    guard safeSpoken.hasPrefix(emittedSpokenSoFar),
                          safeSpoken.count > emittedSpokenSoFar.count else {
                        return
                    }
                    let delta = String(safeSpoken.dropFirst(emittedSpokenSoFar.count))
                    emittedSpokenSoFar = safeSpoken
                    streamingTTSSession.appendText(delta)
                }
            )
            // Reassemble the full utterance: filler text (already
            // spoken from cached PCM) + Claude's continuation.
            // Used for [POINT:...] parsing, conversation history,
            // and logging. Without this, the next turn's history
            // would be missing the opener and Claude would drift.
            let fullResponseText: String = {
                if let prefill = assistantPrefillText, !prefill.isEmpty {
                    return Self.combinedVoiceResponseText(
                        prefill: prefill,
                        continuation: continuationText
                    )
                }
                return continuationText
            }()
            self.markRequestStageCompleted(
                route: "voice.response",
                stage: "model_response",
                stageStartedAt: modelStartedAt,
                timing: timing,
                extra: {
                    modelResponseFields["responseLength"] = fullResponseText.count
                    modelResponseFields["imageCount"] = labeledImages.count
                    modelResponseFields["assistantPrefillUsed"] = assistantPrefillText != nil
                    modelResponseFields["preResponseFillerUsed"] = chosenFiller != nil
                    modelResponseFields["preResponseFillerPhrase"] = chosenFiller?.phrase ?? ""
                    modelResponseFields["preResponseFillerDelayMs"] = chosenFiller == nil
                        ? 0
                        : StreamingTTSSession.preResponseFillerDelayMilliseconds
                    return modelResponseFields
                }()
            )

            guard !Task.isCancelled else {
                await completeRequest(status: "cancelled", extra: ["cancelledAt": "after_model_response"])
                return
            }

            // Parse the visual guidance tag from Claude's response.
            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let spokenText = parseResult.spokenText

            if self.autoEscalateVoiceResponseToAgentIfNeeded(
                responseText: spokenText,
                transcript: transcript,
                source: "voice_response"
            ) {
                streamingTTSSession.cancel()
                await completeRequest(
                    status: "cancelled",
                    extra: [
                        "cancelledAt": "auto_escalated_to_agent",
                        "autoEscalatedToAgent": true
                    ]
                )
                return
            }

            // Handle element pointing if Claude returned coordinates.
            // Switch to idle BEFORE setting the location so the triangle
            // becomes visible and can fly to the target. Without this, the
            // spinner hides the triangle and the flight animation is invisible.
            let hasVisualGuidance = parseResult.coordinate != nil || parseResult.visualOverlay != nil
            if hasVisualGuidance {
                self.voiceState = .idle
            }

            // Pick the screen capture for the buddy to point on.
            //
            // Resolution order:
            //   1. If Claude returned a screenNumber tag, trust it —
            //      that's a deliberate signal that the element lives on
            //      that specific screen. Honor it even when the cursor
            //      is on a different display (the user may have looked
            //      at screen 2 while the cursor stayed on screen 1).
            //   2. If no screenNumber, use the cursor's current screen
            //      (re-read live, not the stale `isCursorScreen` flag
            //      from capture time — Claude can take several seconds
            //      to respond and the user may have moved in that window).
            //   3. Last resort: the captured `isCursorScreen` flag.
            //
            // Earlier versions of this logic preferred the cursor screen
            // even when Claude returned screenNumber, which broke the
            // common "Claude correctly identified an element on the
            // other screen" case. The current logic keeps the live-cursor
            // benefit when Claude *didn't* tag a screen, and trusts
            // Claude when it did.
            let liveMouseLocation = NSEvent.mouseLocation
            let liveCursorCapture = screenCaptures.first { capture in
                capture.displayFrame.contains(liveMouseLocation)
            }
            let targetScreenCapture: CompanionScreenCapture? = {
                if let screenNumber = parseResult.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenCaptures[screenNumber - 1]
                }
                return liveCursorCapture
                    ?? screenCaptures.first(where: { $0.isCursorScreen })
            }()

            if let pointCoordinate = parseResult.coordinate,
               let targetScreenCapture {
                // Claude's coordinates are in the screenshot's pixel space
                // (top-left origin, e.g. 1280x831). Scale to the display's
                // point space (e.g. 1512x982), then convert to AppKit global coords.
                let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                let displayFrame = targetScreenCapture.displayFrame

                // Clamp to screenshot coordinate space
                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                // Scale from screenshot pixels to display points
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                let appKitY = displayHeight - displayLocalY

                // Convert display-local coords to global screen coords
                let calibrationOffset = Self.visualGuidanceCalibrationOffset(for: displayFrame)
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                ).applying(
                    CGAffineTransform(
                        translationX: calibrationOffset.width,
                        y: calibrationOffset.height
                    )
                )

                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                detectedElementBubbleText = Self.pointingBubbleText(for: parseResult.elementLabel)
                rememberPointedElement(
                    at: globalLocation,
                    displayFrame: displayFrame,
                    label: parseResult.elementLabel
                )
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
            } else if let visualOverlay = parseResult.visualOverlay,
                      let targetScreenCapture {
                self.showVisualGuidanceOverlay(
                    self.globalVisualGuidanceOverlay(
                        fromScreenshotOverlay: visualOverlay,
                        in: targetScreenCapture
                    ),
                    sourceCapture: targetScreenCapture
                )
                print("🎯 Visual guidance overlay: \(visualOverlay.kind.rawValue) → \"\(parseResult.elementLabel ?? "overlay")\"")
            } else {
                print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                await attemptProactiveElementPointingIfUseful(
                    transcript: transcript,
                    spokenText: spokenText,
                    screenCaptures: screenCaptures
                )
            }

            // Save this exchange to conversation history (with the point tag
            // stripped so it doesn't confuse future context)
            self.rememberVoiceExchange(
                userTranscript: transcript,
                assistantResponse: spokenText,
                reason: "voice_response"
            )

            print("🧠 Conversation history: \(self.conversationHistory.count) active exchanges")
            do {
                try codexHomeManager.appendPersistentMemoryEvent(
                    userRequest: transcript,
                    agentResponse: spokenText
                )
            } catch {
                print("⚠️ OpenClicky memory update failed: \(error)")
            }

            ClickyAnalytics.trackAIResponseReceived(response: spokenText)
            self.latestVoiceResponseCard = ClickyResponseCard(
                source: .voice,
                rawText: spokenText,
                contextTitle: transcript,
                widgets: self.drainPendingHeyClickyWidgets()
            )
            self.updateVoiceResponseCaption(spokenText)
            self.scheduleWidgetSnapshotPublish()

            // If Haiku just offered to spin up an agent, remember
            // the user's transcript as the candidate task so a
            // confirmation on the next turn ("yes", "okay then")
            // can actually spawn an agent. Otherwise clear any
            // stale offer so a much-later "yes" doesn't suddenly
            // launch unrelated work.
            if Self.responseOffersAgentSpawn(spokenText) {
                self.pendingAgentOfferInstruction = transcript
                self.pendingAgentOfferAt = Date()
            } else {
                self.pendingAgentOfferInstruction = nil
                self.pendingAgentOfferAt = nil
            }

            // The streaming TTS session has already been speaking
            // sentences as the LLM generated them. We just need to
            // flush whatever's left in the pending buffer (e.g. a
            // tail with no sentence terminator) and wait for the
            // last sentence to finish playing before marking the
            // request done.
            if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Sync the session's view of "what was spoken" to the
                // final parsed text. If the parser stripped a POINT
                // tag at the end, our streaming-time emit may have
                // stopped a few characters short — push the remainder
                // here so finish() flushes the full sentence.
                //
                // `emittedSpokenSoFar` only contains the LLM
                // continuation (the filler is enqueued separately
                // as pre-baked PCM and never goes through
                // streamingTTSSession.appendText), so we compare
                // against the continuation portion of spokenText —
                // i.e. spokenText with the prefill prefix stripped.
                let continuationSpoken: String
                if assistantPrefillText != nil {
                    continuationSpoken = Self.parsePointingCoordinates(from: continuationText).spokenText
                } else {
                    continuationSpoken = spokenText
                }
                if continuationSpoken.hasPrefix(emittedSpokenSoFar),
                   continuationSpoken.count > emittedSpokenSoFar.count {
                    let tailDelta = String(continuationSpoken.dropFirst(emittedSpokenSoFar.count))
                    emittedSpokenSoFar = continuationSpoken
                    streamingTTSSession.appendText(tailDelta)
                }

                do {
                    try await streamingTTSSession.finish()
                    guard !Task.isCancelled else {
                        await completeRequest(
                            status: "cancelled",
                            extra: [
                                "cancelledAt": "after_tts_finish",
                                "spokenTextLength": spokenText.count,
                                "pointed": parseResult.coordinate != nil,
                                "audioPlaybackState": Self.voiceResponseCompletionAudioPlaybackState(
                                    spokenText: spokenText,
                                    playbackFinished: false
                                )
                            ]
                        )
                        return
                    }
                    self.markRequestStageCompleted(
                        route: "voice.response",
                        stage: "tts_playback_finished",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        extra: [
                            "executor": "tts",
                            "executionMethod": "StreamingTTSSession.finish",
                            "controller": self.activeTTSControllerName,
                            "spokenTextLength": spokenText.count
                        ]
                    )
                } catch {
                    guard !Self.isExpectedCancellation(error) else {
                        await completeRequest(
                            status: "cancelled",
                            extra: [
                                "cancelledAt": "tts",
                                "spokenTextLength": spokenText.count,
                                "pointed": parseResult.coordinate != nil,
                                "audioPlaybackState": Self.voiceResponseCompletionAudioPlaybackState(
                                    spokenText: spokenText,
                                    playbackFinished: false
                                )
                            ]
                        )
                        return
                    }
                    ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                    print("⚠️ ElevenLabs streaming TTS error: \(error)")
                    speakResponseFailureFallback(error)
                    self.markRequestStageCompleted(
                        route: "voice.response",
                        stage: didMarkAudioStarted ? "tts_playback_finished" : "tts_audio_started",
                        stageStartedAt: ttsStartedAt,
                        timing: timing,
                        status: "failed",
                        extra: [
                            "executor": "tts",
                            "executionMethod": "StreamingTTSSession.finish",
                            "controller": self.activeTTSControllerName,
                            "error": error.localizedDescription
                        ]
                    )
                }
            } else {
                // No spoken text — discard the streaming session so
                // its engine tears down cleanly.
                streamingTTSSession.cancel()
            }
            var completionFields = self.voiceResponseExecutionFields(
                effectiveModelID: visualAnalysisModelID == self.selectedModel ? nil : visualAnalysisModelID
            )
            completionFields["spokenTextLength"] = spokenText.count
            completionFields["pointed"] = parseResult.coordinate != nil
            let audioPlaybackState = Self.voiceResponseCompletionAudioPlaybackState(
                spokenText: spokenText,
                playbackFinished: true,
                audioStarted: didMarkAudioStarted
            )
            completionFields["audioPlaybackState"] = audioPlaybackState
            if audioPlaybackState == "never_started" {
                OpenClickyMessageLogStore.shared.append(
                    lane: "voice",
                    direction: "internal",
                    event: "voice.response.audio_never_started",
                    fields: [
                        "transcript": transcript,
                        "spokenTextLength": spokenText.count,
                        "controller": self.activeTTSControllerName,
                        "requestID": timing?.requestID ?? "none"
                    ]
                )
                self.latestVoiceResponseCard = ClickyResponseCard(
                    source: .voice,
                    rawText: spokenText,
                    contextTitle: transcript
                )
                self.updateVoiceResponseCaption(spokenText, force: true)
            }
            await completeRequest(extra: completionFields)
        } catch is CancellationError {
            // User spoke again — response was interrupted
            await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
        } catch where Self.isExpectedCancellation(error) {
            // User spoke again — URLSession/AVFoundation surfaced cancellation as NSError.
            await completeRequest(status: "cancelled", extra: ["cancelledAt": "task"])
        } catch {
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Companion response error: \(error)")
            OpenClickyMessageLogStore.shared.append(
                lane: "voice",
                direction: "incoming",
                event: "voice.response_error",
                fields: [
                    "transcript": transcript,
                    "error": error.localizedDescription
                ]
            )
            speakResponseFailureFallback(error)
            await completeRequest(
                status: "failed",
                extra: [
                    "error": error.localizedDescription
                ]
            )
        }

        if !Task.isCancelled {
            self.lastVoiceInteractionCompletedAt = Date()
            // FIX(task #322 2026-08-04): SKI fire-and-forget hands off
            // to an external CLI. The turn is NOT over when the
            // pipeline function returns — the CLI is still running
            // tool calls and will emit `agent.done` when truly done.
            // `wireSKITurnLifecycle` observes that and clears the flag
            // + voiceState. Without this guard the UI flipped to
            // "Ready" while the CLI was still working.
            if !self.isSKITurnInFlight {
                self.voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Mirage voice response. Builds a standard Anthropic Messages body and
    /// sends it through `MirageBackendClient`, which handles UUID rotation,
    /// wire-exact headers, and 429-triggered rotation. Streams `text_delta`
    /// events into `onTextChunk` for early TTS. Same signature shape as the
    /// paid `.anthropic` path (`analyzeClaudeResponse`) so the caller doesn't
    /// need to know the request went through the free aegis-proxy.
    ///
    /// `model` is a catalog id with a `mirage/` namespace (e.g.
    /// `mirage/claude-fable-5`). `MirageBackendClient.normalizeBody` strips
    /// the prefix before the outbound request so upstream still sees a bare
    /// `claude-*` identifier. The prefix keeps these catalog entries distinct
    /// from the paid Anthropic ones (`claude-haiku-4-5`, etc.) which live in
    /// the same `voiceResponseModels` list.
    private func analyzeMirageResponse(
        images: [(data: Data, label: String)],
        model: String,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping (String) -> Void
    ) async throws -> String {
        // CompanionScreenCaptureUtility already resizes to maxDimension=1280
        // during capture (SCStreamConfiguration.width/height), so images
        // arriving here are already appropriately sized — same code path
        // HeyClicky Free uses. No extra resize needed on the mirage lane.
        // Route through the Peeky 5-intent orchestrator when the user is on
        // the Peeky Free profile — that gets the on-device routelet + tool
        // dispatch (integration / find_action / memory / agent) instead of
        // a bare Claude call. History is intentionally dropped here because
        // the orchestrator constructs branch-specific message shapes; the
        // recall_conversation tool covers "what did we talk about" queries
        // by reading OpenClickyMessageLogStore directly.
        //
        // Assemble the full OpenClicky context brief the same way SKI does —
        // focused window, LTM memories, xlb topics, stash, openrewind hits,
        // clipboard, MCP endpoint. Fed to the orchestrator as an appended
        // context block so classifier + agent branches can see everything a
        // SKI CLI session would.
        let contextBrief = await buildMirageContextBrief(userQuery: userPrompt)

        // Surface the mirage turn as a real dock agent, mirroring SKI's
        // shim pattern (CompanionManager+SKIModeDockMirror.swift:80-129):
        // the shared `makeShimForTurn` builder registers a
        // CodexAgentSession and seeds the dock item so Chat / MiniChat
        // buttons can find the transcript.
        let dockTitle = "Peeky Free"
        let (shim, dockID) = await MainActor.run { () -> (CodexAgentSession, UUID) in
            let built = self.makeShimForTurn(
                title: dockTitle,
                userInstruction: userPrompt,
                accentTheme: .rose,
                initialStageLabel: "Classifying intent"
            )
            self.notchCaptureWindowManager.updateBackendStatusCaption(Self.mirageCaptionThinking())
            return (built.shim, built.dockID)
        }

        // Pre-response filler is handled by the outer voice pipeline via
        // `streamingTTSSession.enqueuePrebakedSamples(chosenFiller.samples)`
        // (`_analyzeVoiceResponseCore` around line 2047) — it enqueues
        // FillerPhraseLibrary PCM onto the same StreamingTTSSession that
        // will play the model's reply, so timing is coherent and there is
        // no engine collision. Do NOT start a second `speakFillerIsolated`
        // task here: it double-plays the opener and (before the streaming
        // session opens) can drop the first sentence.

        // Notch heartbeat: while the turn is in-flight (which can take
        // 3-50s depending on effort tier), tick the caption every second
        // with an elapsed counter so the user knows work is happening.
        // Without this the notch reverts to idle mid-turn and looks
        // hung. Cancelled the moment the turn returns.
        let turnStarted = Date()
        let heartbeatTask = Task { @MainActor [weak self] in
            var firstChunkReceived = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                let elapsed = Int(Date().timeIntervalSince(turnStarted))
                let stage = firstChunkReceived
                    ? Self.mirageCaptionResponding()
                    : Self.mirageCaptionThinking()
                // Force voice phase back to .processing/.responding every
                // tick — the filler's short TTS clip completes and the
                // audio-done callback flips voiceState to .idle, which
                // hides the notch. We re-assert non-idle here so the
                // notch stays visible for the entire mirage turn.
                let targetPhase: CompanionVoiceState = firstChunkReceived ? .responding : .processing
                if self.voiceState != targetPhase {
                    self.voiceState = targetPhase
                }
                self.notchCaptureWindowManager.updateBackendStatusCaption(
                    "\(stage) \(elapsed)s")
                if !firstChunkReceived, self.mirageFirstChunkAt != nil {
                    firstChunkReceived = true
                }
            }
        }
        defer {
            heartbeatTask.cancel()
            mirageFirstChunkAt = nil
            // Give the user ~30s to click Chat / MiniChat on the bubble
            // after the turn wraps, then clean up the per-turn dock item
            // and shim CodexAgentSession. Mirrors SKIModeDockMirror's
            // inactiveGraceSeconds pattern. Without this, every Peeky
            // Free turn leaves a permanent shim in codexAgentSessions.
            // dockID is per-turn UUID so this cleanup can never
            // accidentally remove a *later* turn's shim — different
            // ids, remove is a no-op. Task is intentionally
            // unhandled: worst case we leak a sleeping continuation
            // for 30s. Storing the handle to enable cancellation on a
            // rapid-fire second turn would be complexity without
            // payoff (dockIDs never collide).
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                try? Task.checkCancellation()
                guard let self else { return }
                self.removeSKIModeDockItem(id: dockID)
                self.removeSKIShimAgentSession(id: dockID)
            }
        }

        let firstImageBase64 = images.first?.data.base64EncodedString()
        // Bridge the orchestrator (which runs on a background executor) back
        // to the main actor for every text chunk. The upstream chunk
        // callback expects @MainActor because it can create AppKit
        // panels + update @Published state. Without this hop the crash
        // is `_CFBundleGetValueForInfoKey` → NSPanel init on non-main
        // thread (see crash report OpenClicky-2026-08-06-171423.ips).
        // Serial queue for chunk bridging — guarantees appendText fires
        // in order. Task{@MainActor} spawned per-chunk lost ordering
        // AND lost chunks that arrived after runTurn returned but
        // before the pipeline finished. DispatchQueue.main.async
        // preserves both.
        let result = await MiragePeekyOrchestrator.shared.runTurn(
            transcript: userPrompt,
            screenshotJPEGBase64: firstImageBase64,
            modelForBranches: model,
            contextBrief: contextBrief,
            onTextChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in
                    if self?.mirageFirstChunkAt == nil {
                        self?.mirageFirstChunkAt = Date()
                    }
                    onTextChunk(chunk)
                }
            },
            onAgentEvent: { event in
                // Mirror Claude Code CLI events into the shim so the
                // dock bubble + Chat/MiniChat panel show live progress
                // exactly like a Codex agent session (tool_use markers,
                // thinking summaries, assistant text). Each block gets
                // its own transcript entry keyed on the CLI event id,
                // AND the dock item's `progressStageLabel` / status is
                // advanced so the bubble caption reflects the current
                // work instead of freezing on "Classifying intent" for
                // the entire 30-60 s agent loop.
                Task { @MainActor in
                    let raw = event.raw
                    let type = event.type
                    switch type {
                    case "assistant":
                        // Content array — a mix of text / tool_use /
                        // thinking blocks. Coalesce the dock advance:
                        // append every block to the shim transcript,
                        // but publish ONE dock caption update at the
                        // end (priority tool_use > thinking > text) to
                        // avoid the "3 mutations per event" flicker.
                        guard let msg = raw["message"] as? [String: Any],
                              let content = msg["content"] as? [[String: Any]] else { return }
                        var pendingStage: (label: String, activity: String?)? = nil
                        // Priority ranking so a later-block tool_use
                        // wins over an earlier-block text.
                        func promote(_ new: (label: String, activity: String?, rank: Int)) {
                            let currentRank = pendingStage.map { $0.label.hasPrefix("🔧") ? 3 : ($0.label.hasPrefix("💭") ? 2 : 1) } ?? 0
                            if new.rank >= currentRank {
                                pendingStage = (new.label, new.activity)
                            }
                        }
                        for block in content {
                            let btype = block["type"] as? String
                            if btype == "text", let t = block["text"] as? String, !t.isEmpty {
                                let id = "peeky-agent-a-\(msg["id"] as? String ?? UUID().uuidString)"
                                shim.appendRemoteTranscriptEntry(role: .assistant, text: t, id: id)
                                promote(("Composing reply", nil, 1))
                            } else if btype == "tool_use",
                                      let name = block["name"] as? String {
                                let inputPreview: String = {
                                    if let input = block["input"] as? [String: Any],
                                       let data = try? JSONSerialization.data(withJSONObject: input),
                                       let s = String(data: data, encoding: .utf8) {
                                        return String(s.prefix(200))
                                    }
                                    return ""
                                }()
                                let toolText = "🔧 \(name)\(inputPreview.isEmpty ? "" : " \(inputPreview)")"
                                let id = "peeky-agent-tu-\(block["id"] as? String ?? UUID().uuidString)"
                                shim.appendRemoteTranscriptEntry(role: .assistant, text: toolText, id: id)
                                promote(("🔧 \(name)", "Working: \(name)", 3))
                            } else if btype == "thinking", let t = block["thinking"] as? String, !t.isEmpty {
                                let id = "peeky-agent-th-\(UUID().uuidString)"
                                shim.appendRemoteTranscriptEntry(role: .assistant, text: "💭 \(t.prefix(200))", id: id)
                                promote(("💭 Thinking…", nil, 2))
                            }
                        }
                        if let stage = pendingStage {
                            self.advanceMiragePeekyDock(
                                dockID: dockID, shim: shim,
                                title: dockTitle,
                                userInstruction: userPrompt,
                                stageLabel: stage.label,
                                activityLine: stage.activity,
                                dockStatus: .running)
                        }
                    case "user":
                        // Contains tool_result content; surface the result.
                        guard let msg = raw["message"] as? [String: Any],
                              let content = msg["content"] as? [[String: Any]] else { return }
                        for block in content where (block["type"] as? String) == "tool_result" {
                            let payload: String = {
                                if let s = block["content"] as? String { return s }
                                if let arr = block["content"] as? [[String: Any]] {
                                    let joined = arr.compactMap { $0["text"] as? String }.joined()
                                    if !joined.isEmpty { return joined }
                                }
                                return ""
                            }()
                            let text = "↳ \(String(payload.prefix(200)))"
                            let id = "peeky-agent-tr-\(block["tool_use_id"] as? String ?? UUID().uuidString)"
                            shim.appendRemoteTranscriptEntry(role: .assistant, text: text, id: id)
                            // Tool result received → back to composing.
                            self.advanceMiragePeekyDock(
                                dockID: dockID, shim: shim,
                                title: dockTitle,
                                userInstruction: userPrompt,
                                stageLabel: "Composing reply",
                                activityLine: nil,
                                dockStatus: .running)
                        }
                    default:
                        break
                    }
                }
            }
        )

        // Clear the classifying caption + record the round-trip.
        await MainActor.run {
            let intentLabel = result.error == nil ? result.intent.rawValue : "error"
            // Keep the finish caption short too — intent name only,
            // locale-aware so English users don't see Chinese labels.
            let caption = result.error == nil
                ? Self.mirageCaptionForIntent(result.intent)
                : Self.mirageCaptionError()
            self.notchCaptureWindowManager.updateBackendStatusCaption(caption)
            _ = intentLabel
            let dockStatus: ClickyAgentDockStatus = result.error == nil ? .done : .failed
            let toolLines = result.toolCalls.map { "\($0.name) → \($0.result.stringValue.prefix(80))" }
            self.upsertSKIModeDockItem(ClickyAgentDockItem(
                id: dockID,
                sessionID: dockID,
                title: dockTitle,
                userInstruction: userPrompt,
                accentTheme: .rose,
                status: dockStatus,
                progressStageLabel: "Intent · \(intentLabel)",
                progressStepText: result.toolCalls.isEmpty ? nil : "\(result.toolCalls.count) tool call(s)",
                activityStatusLines: toolLines,
                caption: result.text.isEmpty ? nil : String(result.text.prefix(200)),
                suggestedNextActions: [],
                createdAt: Date()
            ))
        }
        if let err = result.error {
            // Chat path or classifier failed. Fall through to the raw Claude
            // proxy below so the user still gets a reply even when the
            // orchestrator's tool loop errored.
            NSLog("[MiragePeeky] orchestrator error, falling back to raw claude proxy: \(err)")
        } else {
            // Persist the voice exchange so recall_conversation and the
            // conversation sidebar both see mirage turns (non-mirage paths
            // do the same via rememberVoiceExchange after their reply).
            if !result.text.trimmingCharacters(in: .whitespaces).isEmpty {
                await MainActor.run {
                    self.rememberVoiceExchange(
                        userTranscript: userPrompt,
                        assistantResponse: result.text,
                        reason: "peeky_free_\(result.intent.rawValue)"
                    )
                    // Also push into the shared Codex chat transcript so the
                    // bubble → Chat button and Mini Chat panel render mirage
                    // turns using the same UI as HeyClicky Free. Parity with
                    // HeyClicky (see CompanionManager+HeyClicky.swift:1482:
                    // codexAgentSession.appendRemoteTranscriptEntry).
                    let userID = "peeky-user-\(UUID().uuidString)"
                    let assistantID = "peeky-assistant-\(UUID().uuidString)"
                    // Shim already received streamed assistant text +
                    // tool_use blocks via onAgentEvent during the turn, so
                    // only the user prompt needs a terminal append there
                    // (otherwise the transcript double-renders the reply).
                    shim.appendRemoteTranscriptEntry(
                        role: .user, text: userPrompt, id: userID)
                    // Shared codex sidebar wasn't part of the event stream;
                    // give it the full exchange so recall_conversation +
                    // the conversation sidebar have a canonical record.
                    self.codexAgentSession.appendRemoteTranscriptEntry(
                        role: .user, text: userPrompt, id: userID)
                    self.codexAgentSession.appendRemoteTranscriptEntry(
                        role: .assistant, text: result.text, id: assistantID)
                    for call in result.toolCalls {
                        let toolText = "\(call.name): \(call.result.stringValue.prefix(200))"
                        let toolID = "peeky-tool-\(UUID().uuidString)"
                        self.codexAgentSession.appendRemoteTranscriptEntry(
                            role: .assistant, text: toolText, id: toolID)
                    }
                }
            }
            return result.text
        }

        // Fallback path: plain Claude via mirage. Assemble messages: history
        // first (each prior turn = user + assistant pair), then the current
        // user turn (screenshots + text).
        var messages: [[String: Any]] = []
        for turn in conversationHistory {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }
        var currentContent: [[String: Any]] = images.map { pair in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": pair.data.base64EncodedString()
                ]
            ]
        }
        currentContent.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": currentContent])

        // Split system prompt into a byte-STABLE prefix (identity,
        // tools, style — the same for every turn in a session) and a
        // DYNAMIC suffix (frontmost app hints, memory, calibration,
        // web-search availability — changes per turn). Only the stable
        // prefix carries `cache_control`; Anthropic hashes exact bytes
        // up to the cache marker, so putting volatile content BEFORE
        // the marker would make the cache miss on every turn.
        //
        // Anthropic accepts multiple system blocks; the cached prefix
        // is the first, the volatile part follows without a marker.
        // 1h TTL gives a full session of hits; the pipeline layer
        // auto-attaches the extended-cache-ttl beta when it sees the
        // ttl field.
        let stablePrefix = self.stableVoiceResponseSystemPrompt()
        // Peel the stable prefix off the caller's already-merged
        // systemPrompt to recover the dynamic tail. Match is exact
        // string equality — the same accessor built the input, so this
        // is a safe substring op.
        let dynamicTail: String = {
            if systemPrompt.hasPrefix(stablePrefix) {
                return String(systemPrompt.dropFirst(stablePrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Caller passed a custom prompt (visual-analysis path,
            // assist-agent reentrant round). Treat the whole thing as
            // stable — if the caller's prompt IS byte-stable across
            // turns of THAT flow, cache still hits.
            return ""
        }()
        var systemBlocks: [[String: Any]] = [
            [
                "type": "text",
                "text": systemPrompt.hasPrefix(stablePrefix) ? stablePrefix : systemPrompt,
                "cache_control": ["type": "ephemeral", "ttl": "1h"]
            ]
        ]
        if !dynamicTail.isEmpty {
            systemBlocks.append([
                "type": "text",
                "text": dynamicTail
                // NO cache_control here — this block changes per turn
                // and cache-hashing it would break the prefix hit.
            ])
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": systemBlocks,
            "messages": messages
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

        let (chunkStream, status) = try await MirageBackendClient.shared.sendStreamingChunks(body: bodyData)
        guard status == 200 else {
            var buf = Data()
            for try await c in chunkStream { buf.append(c) }
            throw MirageError.upstreamStatus(status, body: buf)
        }

        // Anthropic SSE: `event: ...\ndata: {...}\n\n`. Shared parser in
        // `AnthropicSSEStream.drainTextDeltas` fans `content_block_delta.
        // text_delta` values through `onTextChunk` and returns the full
        // accumulated assistant text once the stream terminates.
        return try await AnthropicSSEStream.drainTextDeltas(
            chunkStream, onTextChunk: onTextChunk)
    }

    /// Build the same OpenClicky context signals SKI Mode passes to its CLI,
    /// but rendered as a compact plain-text block suitable for appending to
    /// the Peeky orchestrator's system prompt. Reuses `buildSKIUtteranceContext`
    /// so LTM / XLB / stash / everywhere / OpenRewind / clipboard signals stay
    /// in one place. Skipped signals return nil; caller trims empties.
    func buildMirageContextBrief(userQuery: String) async -> String? {
        let ctx = await buildSKIUtteranceContext(userQuery: userQuery)
        var lines: [String] = []
        if let s = ctx.focusedWindowLine, !s.isEmpty {
            lines.append("focused_window: \(s)")
        }
        if let s = ctx.everywhereActiveWindowBrief, !s.isEmpty {
            lines.append("everywhere: \(s)")
        }
        if let s = ctx.ltmMemoriesBrief, !s.isEmpty {
            lines.append("ltm: \(s)")
        }
        if let s = ctx.xlbTopicsBrief, !s.isEmpty {
            lines.append("xlb: \(s)")
        }
        if let s = ctx.screenOCRStashBrief, !s.isEmpty {
            lines.append("stash: \(s)")
        }
        if let s = ctx.openrewindOCRHitsBrief, !s.isEmpty {
            lines.append("openrewind: \(s)")
        }
        if let s = ctx.clipboardBrief, !s.isEmpty {
            lines.append("clipboard: \(s)")
        }
        if let url = ctx.mcpURL, !url.isEmpty {
            let token = ctx.mcpToken.map { " token=\($0.prefix(8))…" } ?? ""
            lines.append("mcp: \(url)\(token) — tools: openclicky_point, show_cursor, get_focused_context, openrewind.*, xlb_*, get_clipboard")
        }
        guard !lines.isEmpty else { return nil }
        return "OpenClicky context (available signals — expand via MCP tools when useful):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Notch captions (locale-aware, short, no hard-coded language)

    /// Bundled translations for the mirage notch captions + fillers.
    /// Kept as a static table because the app does not yet ship a
    /// `Localizable.xcstrings` catalogue; lookup goes through
    /// `OpenClickyLocaleManager.t(_:in:)` so the caller/reader keeps
    /// working when it does.
    private static let mirageCaptions: [String: [String: String]] = [
        // key                  language codes
        "thinking":  ["en": "Thinking", "zh": "思考中", "ja": "考え中", "es": "Pensando", "fr": "Réflexion", "de": "Denke"],
        "replying":  ["en": "Replying", "zh": "回复中", "ja": "返信中",  "es": "Respondiendo", "fr": "Réponse", "de": "Antworte"],
        "error":     ["en": "Error",    "zh": "出错",   "ja": "エラー", "es": "Error", "fr": "Erreur", "de": "Fehler"],
        "chat":      ["en": "Chat",     "zh": "对话",   "ja": "会話",   "es": "Chat", "fr": "Chat", "de": "Chat"],
        "findUI":    ["en": "Find UI",  "zh": "找按钮", "ja": "UI検索", "es": "Buscar UI", "fr": "Trouver UI", "de": "UI suchen"],
        "tool":      ["en": "Tool",     "zh": "工具",   "ja": "ツール", "es": "Herramienta", "fr": "Outil", "de": "Werkzeug"],
        "memory":    ["en": "Memory",   "zh": "记忆",   "ja": "記憶",   "es": "Memoria", "fr": "Mémoire", "de": "Speicher"]
    ]

    private static func mirageLocalized(_ key: String) -> String {
        OpenClickyLocaleManager.shared.t(key, in: mirageCaptions)
    }

    static func mirageCaptionThinking() -> String { mirageLocalized("thinking") }
    static func mirageCaptionResponding() -> String { mirageLocalized("replying") }
    static func mirageCaptionError() -> String { mirageLocalized("error") }

    // Pre-response mirage filler was removed in the double-filler fix
    // (see history around 2026-08-06): the outer voice pipeline already
    // enqueues `FillerPhraseLibrary` PCM onto the shared streaming TTS
    // session, so the mirage-side isolated filler was double-playing.
    // The locale-aware short-phrase table lived here for that path only
    // — removed with the caller.

    static func mirageCaptionForIntent(_ intent: MirageIntent) -> String {
        switch intent {
        case .chat:        return mirageLocalized("chat")
        case .findAction:  return mirageLocalized("findUI")
        case .integration: return mirageLocalized("tool")
        case .memory:      return mirageLocalized("memory")
        case .agent:       return "Agent"
        }
    }
}
