//
//  HeyClickyChatToolCallClient.swift
//  cursor-buddy
//
//  POST /chat-tool-call → HigherModelResponse. Bridges the sixth
//  provider arm of analyzeVoiceResponse. See docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §5.2.
//

import AppKit
import ApplicationServices
import Foundation
import OpenClickyContextService

final class HeyClickyChatToolCallClient: @unchecked Sendable {
    static let shared = HeyClickyChatToolCallClient()

    private let stateQueue = DispatchQueue(label: "com.jkneen.openclicky.heyclicky.chat")

    /// PTT-onset preflight snapshot. Captured the moment the user
    /// pushes the voice hotkey (before they even finish speaking),
    /// so the "current window / selected file / clipboard" context
    /// reflects the user's INTENT — not whatever window happens to
    /// be front when the tool_call eventually fires (which can be
    /// 5-10 s later, after focus drifts). Consumed exactly once by
    /// `buildPreflightContext()` when its TTL is fresh (≤ 60 s).
    private var pttSnapshot: FablePreflightContext?
    private var pttSnapshotUnix: TimeInterval = 0
    private static let pttSnapshotTTLSec: TimeInterval = 60

    @MainActor
    static func capturePTTSnapshot() async {
        let snap = await Self.buildPreflightContext()
        Self.shared.pttSnapshot = snap
        Self.shared.pttSnapshotUnix = Date().timeIntervalSince1970
    }

    /// Entry point invoked from the AI response pipeline's sixth arm.
    /// Bridges to openclicky primitives (native typing, clipboard write,
    /// POINT / TARGET tag emission).
    @MainActor
    func analyzeVoiceResponse(
        companionManager: CompanionManager,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        intent: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let sessionID = HeyClickyHeaderBuilder.shared.chatSessionID()
        let (widthPx, heightPx) = companionManager.currentScreenshotDimensions()
        let mimeType = "image/jpeg"
        let systemPromptForBody = systemPrompt // Currently unused by proxy; kept for future hardening.
        _ = systemPromptForBody

        var query = userPrompt
        // Force a visual-walkthrough hint when the user's transcript
        // clearly asks for a demo / pointing / highlighting. Without
        // it the server-side model often returns text-only responses
        // for follow-up utterances ("what about the input box?") even
        // when the intent is clearly visual. Multilingual verb list.
        if Self.transcriptRequestsVisualDemo(userPrompt) {
            query = "\(userPrompt) [Client hint: user asked for a visual demo — respond with walkthrough.beats including point/highlight/arrow as appropriate for the elements on screen.]"
        }
        if widthPx > 0, heightPx > 0 {
            query += " (image dimensions: \(widthPx)x\(heightPx) pixels)"
        }

        // Phase 4 Step 1: prepend an [openclicky-context] block plus a
        // directives block so the server-side Fable model sees the user's
        // current scene AND is told to end its reply with a `[ROUTE] {…}`
        // JSON line. The proxy does not forward the local `systemPrompt`
        // to the model (see `systemPromptForBody` unused var above), so
        // BOTH the situational context and the routing contract must ride
        // inside `query`. Gated by `openclicky.contextAwarenessEnabled`
        // (defaults to true; user can flip via `defaults write`).
        let contextEnabled = (UserDefaults.standard.object(forKey: "openclicky.contextAwarenessEnabled") as? Bool) ?? true
        // Preflight snapshot hoisted so Phase 4 Step 2 route dispatch and
        // its context-signal fallback can reuse the same capture — no
        // second Layer-0 roundtrip on the response path.
        var preflightSnapshot: FablePreflightContext?
        if contextEnabled {
            let preflight = await Self.buildPreflightContext()
            preflightSnapshot = preflight
            let contextBlock = Self.formatPreflightBlock(preflight)
            let directives = Self.contextAwarenessDirectiveBlock
            HeyClickyLog.log("openclicky.preflight_context", lane: "voice", direction: "internal", [
                "frontmost": preflight.frontmostBundle ?? "",
                "window_title_len": preflight.windowTitle?.count ?? 0,
                "has_url": preflight.browserURL != nil,
                "has_folder": preflight.selectedFolder != nil,
                "selected_files_count": preflight.selectedFileNames.count,
                "selected_text_len": preflight.selectedText?.count ?? 0
            ])
            query = "\(contextBlock)\n\n\(directives)\n\n\(query)"
        }
        // Long-term memory + query-conditional FTS retrieval. The proxy
        // does NOT forward systemPrompt to the upstream model — LTM has
        // to ride inside `query`. Same content as main dialog / realtime
        // paths, but injected here so `openclicky_use_screen_context`
        // routed turns (the "STT → dialog model" fan-out) don't fly
        // blind.
        // Always run LTM retrieval — hybrid search is cheap
        // (~100ms local NLEmbedding) and the realtime intent
        // classifier can't know what's actually in the user's vault
        // (a "world_knowledge"-looking prompt may still be something
        // the user discussed with us earlier). Empty hits are
        // silently omitted from the prompt so there's no downside
        // to always trying. Intent is logged for later analytics
        // but no longer gates retrieval.
        let ltmNeeded = !AssistAgentBridge.shared.isReentrantRound
        HeyClickyLog.log("chat.intent_routing", lane: "voice",
                         direction: "internal",
                         ["intent": intent ?? "unset",
                          "ltm_used": ltmNeeded,
                          "policy": "always_retrieve"])
        if ltmNeeded {
            // Thread the user's last 2 turns into the retrieval query
            // so multi-turn follow-ups ("怎么修" / "还有别的方式吗")
            // still hit the topic they refer to. Otherwise short
            // pronoun-only follow-ups have zero keywords for FTS/
            // vector to latch onto.
            var threadedQuery = userPrompt
            let priorUserTurns = conversationHistory.suffix(2)
                .map { $0.userPlaceholder }
                .filter { !$0.isEmpty }
            if !priorUserTurns.isEmpty {
                threadedQuery = priorUserTurns.joined(separator: " ") + " " + userPrompt
            }
            let ltmBlock = await LongTermMemoryContext.build(
                query: threadedQuery,
                intent: intent)
            if !ltmBlock.isEmpty {
                query = ltmBlock + "\n\n---\n\n" + query
                HeyClickyLog.log("ltm.injected", lane: "voice", direction: "internal", [
                    "ltmChars": ltmBlock.count,
                    "queryPreview": String(userPrompt.prefix(60))
                ])
            }
        }
        // HeyClicky proxy does not forward `systemPrompt` to the
        // upstream model (see `systemPromptForBody` unused var). So
        // any dispatch contract must ride inside `query`.
        if AssistAgentBridge.shared.isReentrantRound {
            // Inside the assist loop's inner rounds — the caller's
            // systemPrompt already carries the full CN tool-menu
            // schema. Prepend it verbatim so the proxy's UI-action
            // defaults don't override it.
            query = "\(systemPrompt)\n\n\(query)"
        } else if AppBundleConfiguration.assistAgentEnabled()
            && !query.contains(AssistAgentPrompt.requestMarker) {
            // Main-dialog outer round: the [ASSIST] hint was wrapped
            // into `systemPrompt` upstream but the HeyClicky proxy
            // doesn't forward systemPrompt to the model. So prepend
            // the short hint (~130 chars) here. Guard on marker
            // absence to prevent double-injection when a caller has
            // already merged systemPrompt into query.
            query = AssistAgentPrompt.systemPromptBlock + "\n\n" + query
        }

        // Match demo behavior: default capabilities is single-item list;
        // omit screenshotBase64 entirely when there is no image; give
        // width/height sane fallbacks so the proxy always sees positive
        // pixel dimensions (image-coord math on the server assumes it).
        let capabilities = AppBundleConfiguration.heyClickyClientCapabilities()

        // Downscale + re-encode the JPEG before base64 to shrink the
        // request body. Retina displays produce 3456×2160 (~300KB+ b64),
        // which turns every chat.request into a slow upload on flaky
        // networks. 1280 max-dim @ q=0.55 lands around 30-60KB with no
        // model-side accuracy loss (the proxy already downscales again).
        // We report the DOWNSCALED dims so `walkthrough.beat.x/y` land
        // in the same coordinate space that the rescale helper divides
        // by (see `rescale` closure below).
        var payloadWidth = widthPx > 0 ? widthPx : 1280
        var payloadHeight = heightPx > 0 ? heightPx : 800
        var payloadImageData: Data? = images.first?.data
        if let src = payloadImageData, !src.isEmpty,
           let (data, w, h) = Self.downscaleJPEG(src, maxDimension: 1568, quality: 0.75) {
            payloadImageData = data
            payloadWidth = w
            payloadHeight = h
        }

        var body: [String: Any] = [
            "query": query,
            "screenshotWidthInPixels": payloadWidth,
            "screenshotHeightInPixels": payloadHeight,
            "mimeType": mimeType,
            "client_capabilities": capabilities,
            "frontmost_app_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            "environment": Self.buildEnvironmentDict(),
            "session_id": sessionID
        ]
        if let imageData = payloadImageData, !imageData.isEmpty {
            body["screenshotBase64"] = imageData.base64EncodedString()
        }
        let effectiveWidth = payloadWidth
        let effectiveHeight = payloadHeight

        let requestBody: Data
        do {
            requestBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw HeyClickyProxyError.malformedResponse
        }

        let path = AppBundleConfiguration.heyClickyChatToolCallPath()
        HeyClickyLog.log("chat.request", lane: "voice", direction: "outgoing", [
            "query_len": query.count,
            "has_screenshot": (images.first?.data.isEmpty == false),
            "width": effectiveWidth,
            "height": effectiveHeight
        ])
        let (data, _): (Data, HTTPURLResponse)
        do {
            (data, _) = try await HeyClickyProxyClient.shared.postJSON(path: path, body: requestBody, includeDictationReceipt: true)
        } catch let err as HeyClickyProxyError {
            HeyClickyLog.log("chat.error", lane: "voice", direction: "error", [
                "error": "\(err)"
            ])
            switch err {
            case .quotaExhausted:
                // Fire single-account reset (same email, re-auth via
                // Chrome ext); watchers on .heyClickyCredentialsRefreshed
                // pick up the fresh tokens.
                await MainActor.run {
                    _ = HeyClickyAccountResetManager.shared.attemptReset(
                        reason: "chat_lane_quota_exhausted"
                    )
                }
                NotificationCenter.default.postHeyClickyStatus(.refreshing, extra: ["lane": "chat"])
            case .transportError, .upstreamUnavailable:
                NotificationCenter.default.postHeyClickyStatus(.transportError, extra: ["lane": "chat"])
            default:
                break
            }
            // Rethrow so the pipeline's error path handles it — the
            // `.heyClickyStatusChanged` notification carries the human
            // status caption for any UI subscriber. Swallowing as a
            // partial text used to feed the TTS state phrases like a
            // model reply, which was worse than a hard error.
            throw err
        }

        let decoded: HigherModelResponse
        do {
            decoded = try decodeStrict(data: data)
        } catch {
            // Preserve the first 500 bytes of the response for debug so
            // we can see server-side shape changes instead of guessing.
            let sample = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            HeyClickyLog.log("chat.decode_failed", lane: "voice", direction: "error", [
                "body_bytes": data.count,
                "body_sample": sample,
                "swift_error": "\(error)"
            ])
            throw HeyClickyProxyError.malformedResponse
        }
        let beatKinds = (decoded.walkthrough?.beats ?? []).map { $0.kind }.joined(separator: ",")
        let beatCoords = (decoded.walkthrough?.beats ?? []).map { b -> String in
            let x = b.x.map { String(Int($0)) } ?? "-"
            let y = b.y.map { String(Int($0)) } ?? "-"
            let w = b.width.map { String(Int($0)) } ?? "-"
            let h = b.height.map { String(Int($0)) } ?? "-"
            return "\(b.kind):(\(x),\(y),\(w)x\(h))"
        }.joined(separator: " | ")
        HeyClickyLog.log("chat.response", lane: "voice", direction: "incoming", [
            "text_len": decoded.text.count,
            "has_typing": decoded.typing != nil,
            "has_clipboard": decoded.clipboardText != nil,
            "has_point": decoded.point != nil,
            "widgets": decoded.widgets.count,
            "widget_types": decoded.widgets.compactMap { $0.type }.joined(separator: ","),
            "walkthrough_beats": decoded.walkthrough?.beats.count ?? 0,
            "beat_kinds": beatKinds,
            "beat_coords": beatCoords
        ])
        // Stash widgets so the pipeline's card constructor can pick them up.
        // Overwrites the prior turn's stash — one turn = one card.
        // Automation source (simulate_voice_turn) suppresses ALL side effects.
        let suppressSideEffects = companionManager.suppressVoiceResponseSideEffects
        if !suppressSideEffects {
            companionManager.pendingHeyClickyWidgets = decoded.widgets
        }

        var finalText = decoded.text

        // 1. clipboard (preserving prior contents)
        if !suppressSideEffects, let clip = decoded.clipboardText, !clip.isEmpty {
            companionManager.writeToClipboardPreservingUserContents(clip)
        }

        // 2. typing at cursor — REQUIRES explicit user intent.
        // Root-cause fix (2026-07-30): voice-triggered chat responses
        // were occasionally shipping `typing.text = "c"` (or other
        // stray chars) which then got POSTED into the frontmost app as
        // real keyboard events. From the user's POV: a random letter
        // shows up in their editor / terminal every time they hit PTT.
        // Guard: only accept typing when the user's transcript itself
        // contains an explicit "type X" / "输入 X" / "帮我打" cue. Any
        // other typing payload is discarded and logged so we can audit
        // why the server suggested it.
        if !suppressSideEffects, let typing = decoded.typing, !typing.text.isEmpty {
            let intent = userPrompt.lowercased()
            let asksToType =
                intent.contains("type ") || intent.contains("type this") ||
                intent.contains("输入") || intent.contains("打入") ||
                intent.contains("帮我打") || intent.contains("填入") ||
                intent.contains("write ") || intent.contains("paste ")
            if asksToType {
                if let tx = typing.x, let ty = typing.y,
                   let screen = HeyClickyCoordinateTransform.targetScreen(preferredIndex: typing.screen) {
                    let dims = companionManager.currentScreenshotDimensions()
                    let sw = dims.width > 0 ? dims.width : 1280
                    let sh = dims.height > 0 ? dims.height : 800
                    let global = HeyClickyCoordinateTransform.screenshotPixelToGlobalBottomLeft(
                        px: tx, py: ty, screen: screen,
                        screenshotWidth: sw, screenshotHeight: sh
                    )
                    companionManager.clickAtGlobalPointThenType(text: typing.text, globalPoint: global)
                } else {
                    companionManager.typeTextForHeyClickyFree(typing.text)
                }
            } else {
                HeyClickyLog.log("chat.typing_suppressed_no_user_intent",
                                 lane: "voice", direction: "internal", [
                    "text_preview": String(typing.text.prefix(40)),
                    "text_len": typing.text.count,
                    "userPrompt_preview": String(userPrompt.prefix(60))
                ])
            }
        }

        // Coordinate transform prep for walkthrough beats. Server sends
        // beat coordinates in screenshot px (top-left origin, same space
        // as `screenshotBase64`). We need to convert to screen-local
        // top-left points which is what our SwiftUI annotation layer
        // consumes (layer is mounted inside OverlayWindow's ZStack whose
        // coordinate space IS the screen).
        // All rescale/global-point math goes through
        // HeyClickyCoordinateTransform so a point beat and a highlight
        // rect never disagree on where "y=655" is. Same helpers used by
        // Rescale strategy:
        //  1. If a capture context is pinned by the caller
        //     (executeInSessionScreenContextTool sets it before dispatch),
        //     use its exact displayFrame + screenshot dims — this
        //     accounts for focused-window captures where beat coords
        //     live in window space, not screen space.
        //  2. Otherwise fall back to `screen.frame` (for callers who
        //     didn't populate a capture context).
        let captureCtx = companionManager.pendingHeyClickyCaptureContext
        func screenForBeat(_ beat: WalkthroughBeat) -> NSScreen? {
            let idx = beat.screen ?? captureCtx?.nsScreenIndex
            return HeyClickyCoordinateTransform.targetScreen(preferredIndex: idx)
        }
        func rescale(_ p: CGPoint, on screen: NSScreen) -> CGPoint {
            let (frame, sw, sh) = captureCtx.map {
                ($0.displayFrame, $0.screenshotWidth, $0.screenshotHeight)
            } ?? (screen.frame, effectiveWidth, effectiveHeight)
            let width = CGFloat(max(1, sw))
            let height = CGFloat(max(1, sh))
            return CGPoint(
                x: p.x * (frame.width / width),
                y: p.y * (frame.height / height)
            )
        }
        func rescaleR(_ r: Double, on screen: NSScreen) -> CGFloat {
            let (frame, sw, sh) = captureCtx.map {
                ($0.displayFrame, $0.screenshotWidth, $0.screenshotHeight)
            } ?? (screen.frame, effectiveWidth, effectiveHeight)
            let sx = frame.width / CGFloat(max(1, sw))
            let sy = frame.height / CGFloat(max(1, sh))
            return CGFloat(r) * ((sx + sy) / 2)
        }
        func rescaleRect(x: Double, y: Double, w: Double, h: Double, on screen: NSScreen) -> CGRect {
            let tl = rescale(CGPoint(x: x, y: y), on: screen)
            let br = rescale(CGPoint(x: x + w, y: y + h), on: screen)
            return CGRect(
                x: min(tl.x, br.x),
                y: min(tl.y, br.y),
                width: abs(br.x - tl.x),
                height: abs(br.y - tl.y)
            )
        }
        func globalPoint(_ local: CGPoint, on screen: NSScreen) -> CGPoint {
            // Use the capture frame origin (may equal screen.frame or
            // a window frame) so the buddy flies to the correct absolute
            // point when the capture wasn't full-screen. displayFrame is
            // AppKit bottom-left; flip Y within its height.
            let baseFrame = captureCtx?.displayFrame ?? screen.frame
            return CGPoint(
                x: baseFrame.origin.x + local.x,
                y: baseFrame.origin.y + (baseFrame.height - local.y)
            )
        }

        // 3. Walkthrough beat kinds. See clicky-mac
        //    AgentToolBridge.applyBeat: point / target / hover / highlight /
        //    arrow / curve / type. openclicky wires the interactive kinds
        //    (target arms guided click; point flies buddy; type performs a
        //    click-and-type). Purely visual annotations (hover / highlight /
        //    arrow / curve) do not have an overlay layer yet — they still
        //    ride out to the LLM as a text tag so the model can talk about
        //    them, but no graphics get drawn.
        let beats = decoded.walkthrough?.beats ?? []
        var didEmitTargetTag = false
        // annotationText (IDA-verified sibling of `text` in the response
        // struct) is a short caption meant to sit next to a screen
        // annotation. If a beat doesn't have its own `label`, fall back
        // to this. Uses a captured copy so the escape doesn't force it
        // through the loop's mutation.
        let annotationCaption = decoded.annotationText
        func caption(for beat: WalkthroughBeat) -> String? {
            if let label = beat.label, !label.isEmpty { return label }
            return annotationCaption
        }
        for beat in beats {
            switch beat.kind {
            case "target":
                guard let bx = beat.x, let by = beat.y,
                      let screen = screenForBeat(beat) else { continue }
                // clicky-mac parity: default radius = 40 when the server
                // omits it. Previously we hard-required beat.r, silently
                // dropping any radiusless target beat.
                let br = beat.r ?? 40
                if !didEmitTargetTag, !finalText.contains("[TARGET:") {
                    let label = beat.label ?? decoded.point?.label ?? ""
                    let screenSuffix = beat.screen.map { ":screen\($0)" } ?? ""
                    finalText += "\n[TARGET:\(bx),\(by),\(br):\(label)\(screenSuffix)]"
                    didEmitTargetTag = true
                }
                // GuidedClickManager already handles px→screen conversion
                // internally using its own capture, so pass px through.
                HeyClickyGuidedClickManager.shared.arm(x: bx, y: by, radius: br, label: beat.label ?? "", screen: beat.screen)
                _ = screen
            case "point":
                guard let bx = beat.x, let by = beat.y,
                      let screen = screenForBeat(beat) else { continue }
                let label = beat.label ?? "here"
                let screenSuffix = beat.screen.map { ":screen\($0)" } ?? ""
                if !finalText.contains("[POINT:") {
                    finalText += "\n[POINT:\(bx),\(by):\(label)\(screenSuffix)]"
                }
                let localPt = rescale(CGPoint(x: bx, y: by), on: screen)
                companionManager.overlayWindowManager.flyBuddyTo(globalPoint(localPt, on: screen))
            case "type":
                // Same guard as the top-level `typing` handler above.
                // Silent typing on every PTT turn is a UX disaster.
                if let txt = beat.text, !txt.isEmpty {
                    let intent = userPrompt.lowercased()
                    let asksToType =
                        intent.contains("type ") || intent.contains("type this") ||
                        intent.contains("输入") || intent.contains("打入") ||
                        intent.contains("帮我打") || intent.contains("填入") ||
                        intent.contains("write ") || intent.contains("paste ")
                    if asksToType {
                        companionManager.typeTextForHeyClickyFree(txt)
                    } else {
                        HeyClickyLog.log("walkthrough.type_beat_suppressed",
                                         lane: "voice", direction: "internal", [
                            "text_preview": String(txt.prefix(40)),
                            "userPrompt_preview": String(userPrompt.prefix(60))
                        ])
                    }
                }
            case "hover":
                guard let bx = beat.x, let by = beat.y,
                      let screen = screenForBeat(beat) else { continue }
                let center = rescale(CGPoint(x: bx, y: by), on: screen)
                let radius = rescaleR(beat.r ?? 30, on: screen)
                HeyClickyAnnotationState.shared.add(
                    .circle(center: center, radius: radius),
                    on: screen,
                    caption: caption(for: beat)
                )
            case "highlight":
                guard let bx = beat.x, let by = beat.y,
                      let bw = beat.width, let bh = beat.height,
                      let screen = screenForBeat(beat) else { continue }
                // Sanity-check beat coords against the raw screenshot
                // dimensions. Realtime models occasionally hallucinate
                // coordinates outside the frame they scored against;
                // rescaling those garbage numbers positions the highlight
                // rect far offscreen where the user can't see it.
                // Byte-parity with HeyClicky binary `ElementLocationDetector`
                // (sub_100995694): `mapped = raw / imageSize × displaySize`.
                // Direct division, no bounds check, no reinterpret. If the
                // model returns garbage coords the mapped rect lands
                // offscreen — same behavior as HeyClicky.
                let rect = rescaleRect(x: bx, y: by, w: bw, h: bh, on: screen)
                HeyClickyAnnotationState.shared.add(
                    .highlight(rect: rect),
                    on: screen,
                    caption: caption(for: beat)
                )
            case "arrow":
                guard let fx = beat.fromX, let fy = beat.fromY,
                      let tx = beat.toX, let ty = beat.toY,
                      let screen = screenForBeat(beat) else { continue }
                let from = rescale(CGPoint(x: fx, y: fy), on: screen)
                let to = rescale(CGPoint(x: tx, y: ty), on: screen)
                HeyClickyAnnotationState.shared.add(
                    .arrow(from: from, to: to),
                    on: screen,
                    caption: caption(for: beat)
                )
            case "curve":
                guard let raw = beat.points, raw.count >= 2,
                      let screen = screenForBeat(beat) else { continue }
                let pts = raw.compactMap { pair -> CGPoint? in
                    guard pair.count >= 2 else { return nil }
                    return rescale(CGPoint(x: pair[0], y: pair[1]), on: screen)
                }
                guard pts.count >= 2 else { continue }
                HeyClickyAnnotationState.shared.add(
                    .curve(points: pts),
                    on: screen,
                    caption: caption(for: beat)
                )
            case "shape":
                // Server-verified schema (all shapeKind variants use
                // `points` — an array of {x,y} objects. Decoder above
                // already normalised those into `[[x, y], ...]`):
                //   line    → points[0] → points[1]           (endpoints)
                //   arrow   → points[0] → points[1]           (arrow head at last)
                //   circle  → points[0] center, points[1] on the circumference
                //             (radius = distance between the two points)
                //   curve   → 2-6 points, first + last are anchors
                //   polygon → 2-6 verts, client auto-closes back to points[0]
                // Optional `filled: Bool` only meaningful for circle/polygon.
                guard let screen = screenForBeat(beat) else { continue }
                let cap = caption(for: beat)
                let rawPts = beat.points ?? []
                let scaledPts: [CGPoint] = rawPts.compactMap { pair in
                    guard pair.count >= 2 else { return nil }
                    return rescale(CGPoint(x: pair[0], y: pair[1]), on: screen)
                }
                switch beat.shapeKind ?? "polygon" {
                case "line":
                    if scaledPts.count >= 2 {
                        HeyClickyAnnotationState.shared.add(
                            .line(from: scaledPts[0], to: scaledPts[1]),
                            on: screen, caption: cap
                        )
                    }
                case "arrow":
                    if scaledPts.count >= 2 {
                        HeyClickyAnnotationState.shared.add(
                            .arrow(from: scaledPts[0], to: scaledPts[1]),
                            on: screen, caption: cap
                        )
                    }
                case "circle":
                    if scaledPts.count >= 2 {
                        let center = scaledPts[0]
                        let edge = scaledPts[1]
                        let radius = hypot(edge.x - center.x, edge.y - center.y)
                        HeyClickyAnnotationState.shared.add(
                            .circle(center: center, radius: radius),
                            on: screen, caption: cap
                        )
                    }
                case "curve":
                    if scaledPts.count >= 2 {
                        HeyClickyAnnotationState.shared.add(
                            .curve(points: scaledPts), on: screen, caption: cap
                        )
                    }
                default:  // polygon (and unknown fallback)
                    if scaledPts.count >= 2 {
                        HeyClickyAnnotationState.shared.add(
                            .polygon(points: scaledPts), on: screen, caption: cap
                        )
                    }
                }
            default:
                break
            }
        }

        // No walkthrough at all: fall back to a plain point tag from the
        // top-level `point` field.
        if beats.isEmpty, let pt = decoded.point, !finalText.contains("[POINT:") {
            let screenSuffix = pt.screen.map { ":screen\($0)" } ?? ""
            finalText += "\n[POINT:\(pt.x),\(pt.y):\(pt.label)\(screenSuffix)]"
        }

        // Server may emit `[TARGET:x,y,r:label]` inside `annotationText`
        // instead of (or in addition to) a walkthrough target beat.
        // clicky-mac AgentToolBridge.swift:582 parses this from response
        // text; do the same across both text and annotationText so guided
        // click arms in every case.
        if !didEmitTargetTag,
           let tag = Self.parseTargetTag(finalText + "\n" + (decoded.annotationText ?? "")) {
            HeyClickyGuidedClickManager.shared.arm(
                x: tag.x, y: tag.y, radius: tag.r,
                label: tag.label ?? "", screen: tag.screen
            )
            if !finalText.contains("[TARGET:") {
                let screenSuffix = tag.screen.map { ":screen\($0)" } ?? ""
                finalText += "\n[TARGET:\(Int(tag.x)),\(Int(tag.y)),\(Int(tag.r)):\(tag.label ?? "")\(screenSuffix)]"
            }
        }

        // [ROUTE] JSON dispatch removed. Chat replies stay chat replies;
        // agent-lane routing lives entirely on the client side in
        // `routeFinalVoiceTranscriptActionIfNeeded` (Layer 0 "free agent"
        // keyword + upstream agent detectors).
        // Assist-agent interception: if the model emitted [ASSIST]
        // {"goal":...} we run the assist loop inline and splice its
        // summary into the reply text. Bypassed inside re-entrant
        // rounds so the assist loop itself doesn't recurse. Also
        // bypassed when the user has flipped the Settings toggle off.
        if !AssistAgentBridge.shared.isReentrantRound
            && AppBundleConfiguration.assistAgentEnabled() {
            // Pipe assist-loop stage updates into the shared TTS
            // queue so the user hears "reading foo.py..." instead of
            // waiting silently through 5-15 s of tool loops.
            let cm = companionManager
            finalText = await AssistAgentBridge.shared.handleModelReply(
                finalText,
                userPrompt: query,
                progressChannel: { phrase in
                    Task { @MainActor in
                        cm.speakAssistAgentProgress(phrase)
                    }
                })
        }
        onTextChunk(finalText)
        return finalText
    }

    /// Parse `[TARGET:x,y,r:label]` (or `[TARGET:x,y,r]` / `:screenN`
    /// suffix) from a text blob. Mirrors clicky-mac
    /// AgentToolBridge.parseRadiusTag.
    static func parseTargetTag(_ text: String) -> (x: Double, y: Double, r: Double, label: String?, screen: Int?)? {
        let pattern = #"\[TARGET:\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(\d+)(?::([^\]:]+?))?(?::screen(\d+))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 4,
              let xR = Range(match.range(at: 1), in: text),
              let yR = Range(match.range(at: 2), in: text),
              let rR = Range(match.range(at: 3), in: text),
              let x = Double(text[xR]),
              let y = Double(text[yR]),
              let r = Double(text[rR]) else {
            return nil
        }
        var label: String? = nil
        if match.numberOfRanges >= 5, let lr = Range(match.range(at: 4), in: text) {
            let s = text[lr].trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { label = String(s) }
        }
        var screen: Int? = nil
        if match.numberOfRanges >= 6, let sr = Range(match.range(at: 5), in: text) {
            screen = Int(text[sr])
        }
        return (x, y, r, label, screen)
    }

    /// Downscale + re-encode a JPEG so the base64-inline chat.request
    /// stays under ~50KB even on Retina screens. Returns (data, w, h)
    /// on success; nil when the source isn't a decodable image (in
    /// which case the caller falls back to the raw bytes).
    ///
    /// The proxy already downscales again server-side; sending 300KB
    /// of pixels client-side is pure upload latency for zero accuracy
    /// win. 1280 max-dim @ q=0.55 comes out to ~30-60KB and matches
    /// the coord space the model reasons in.
    static func downscaleJPEG(_ src: Data, maxDimension: CGFloat, quality: Double) -> (Data, Int, Int)? {
        // Delegates to the shared `OpenClickyImagePreprocessor`. Kept as
        // a wrapper because several call sites take the tuple form; the
        // preprocessor returns a labeled tuple for readability but the
        // underlying pixels are byte-identical to the previous local
        // implementation.
        guard let out = OpenClickyImagePreprocessor.resizedJPEG(
            source: src, maxDimension: maxDimension, quality: quality) else { return nil }
        return (out.data, out.width, out.height)
    }

    /// Heuristic: does the user's raw transcript ask for a visual
    /// walkthrough? Covers CN / EN verbs the server-side model responds
    /// to more reliably with `walkthrough.beats`. Purely additive — a
    /// false negative just means the model decides on its own.
    private static func transcriptRequestsVisualDemo(_ transcript: String) -> Bool {
        let t = transcript.lowercased()
        let verbs = [
            "演示", "标注", "标记", "框出", "圈出", "指出", "画出", "画一", "画个",
            "画箭头", "指一下", "指个", "标出",
            "show me", "point at", "point to", "highlight", "annotate",
            "circle the", "box around", "demo", "demonstrate", "walk me through"
        ]
        return verbs.contains(where: { t.contains($0.lowercased()) })
    }

    /// IDA-verified environment keys (0x1012a81b0..0x1012a81e0 in
    /// HeyClicky-1.0.40): os_version, device_model, display_count,
    /// preferred_languages, plus locale and timezone.
    private static func buildEnvironmentDict() -> [String: Any] {
        // Demo uses the full formatted string (includes build number),
        // e.g. "Version 15.4 (Build 24E263)". Parity keeps server-side
        // OS parsing behavior identical.
        let osVersionString = ProcessInfo.processInfo.operatingSystemVersionString
        let deviceModel: String = {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            guard size > 0 else { return "Mac" }
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            return String(cString: buffer)
        }()
        let displayCount = NSScreen.screens.count
        let preferredLanguages = Locale.preferredLanguages

        return [
            "os_version": osVersionString,
            "device_model": deviceModel,
            "display_count": displayCount,
            "preferred_languages": preferredLanguages,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier
        ]
    }

    /// Manual JSON decode — matches demo `HigherModelClient.swift:165`
    /// exactly. The server mixes Int and Double for numeric fields
    /// depending on the value, which `JSONDecoder` won't reconcile
    /// automatically. Doing it by hand also makes it survive extra
    /// fields the proxy might add later.
    private func decodeStrict(data: Data) throws -> HigherModelResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HeyClickyProxyError.malformedResponse
        }
        guard let text = json["text"] as? String else {
            throw HeyClickyProxyError.malformedResponse
        }
        let clipboardText = json["clipboardText"] as? String
        // `typing` real server shape (verified via probe_protocol.py):
        //   {"x": Int, "y": Int, "text": String, "label": String}
        // Older / degenerate responses might send a bare string —
        // accept both.
        let typing: TypingInstruction? = {
            if let obj = json["typing"] as? [String: Any],
               let text = obj["text"] as? String, !text.isEmpty {
                return TypingInstruction(
                    text: text,
                    x: (obj["x"] as? Double) ?? (obj["x"] as? Int).map(Double.init),
                    y: (obj["y"] as? Double) ?? (obj["y"] as? Int).map(Double.init),
                    label: obj["label"] as? String,
                    screen: obj["screen"] as? Int
                )
            }
            if let bare = json["typing"] as? String, !bare.isEmpty {
                return TypingInstruction(text: bare)
            }
            return nil
        }()

        var point: PointCoordinate?
        if let p = json["point"] as? [String: Any],
           let x = (p["x"] as? Double) ?? (p["x"] as? Int).map(Double.init),
           let y = (p["y"] as? Double) ?? (p["y"] as? Int).map(Double.init) {
            point = PointCoordinate(
                x: x, y: y,
                label: (p["label"] as? String) ?? "",
                screen: p["screen"] as? Int
            )
        }

        var widgets: [WidgetPayload] = []
        if let list = json["widgets"] as? [[String: Any]] {
            for item in list {
                // Real server shape (verified via curl probe):
                //   {"kind": "stock", "payload": {...}}
                //   {"kind": "places", "payload": [...]}
                // Older / degenerate shape (kept for backward compat):
                //   {"type": "stock", ...flat payload...}
                let type = (item["kind"] as? String) ?? (item["type"] as? String)
                var payload: [String: OpenClickyJSONValue] = [:]
                if let nested = item["payload"] as? [String: Any] {
                    for (k, v) in nested {
                        payload[k] = jsonAny(v)
                    }
                } else if let arr = item["payload"] as? [Any] {
                    // "places" payload is an array of place objects —
                    // wrap under a synthetic `items` key so the view
                    // layer can still see it inside the same payload dict.
                    payload["items"] = jsonAny(arr)
                } else {
                    for (k, v) in item where k != "type" && k != "kind" {
                        payload[k] = jsonAny(v)
                    }
                }
                widgets.append(WidgetPayload(type: type, payload: payload))
            }
        }

        var walkthrough: Walkthrough?
        if let wt = json["walkthrough"] as? [String: Any],
           let beatsArray = wt["beats"] as? [[String: Any]] {
            let beats: [WalkthroughBeat] = beatsArray.map { b in
                WalkthroughBeat(
                    kind: (b["kind"] as? String) ?? "",
                    label: b["label"] as? String,
                    speech: b["speech"] as? String,
                    x: (b["x"] as? Double) ?? (b["x"] as? Int).map(Double.init),
                    y: (b["y"] as? Double) ?? (b["y"] as? Int).map(Double.init),
                    // Real server payload uses `radius` for target/hover
                    // beats (verified via direct curl). Older docs
                    // called it `r` — accept both for safety.
                    r: (b["radius"] as? Double) ?? (b["radius"] as? Int).map(Double.init)
                        ?? (b["r"] as? Double) ?? (b["r"] as? Int).map(Double.init),
                    width: (b["width"] as? Double) ?? (b["width"] as? Int).map(Double.init),
                    height: (b["height"] as? Double) ?? (b["height"] as? Int).map(Double.init),
                    text: b["text"] as? String,
                    screen: b["screen"] as? Int,
                    fromX: (b["fromX"] as? Double) ?? (b["fromX"] as? Int).map(Double.init),
                    fromY: (b["fromY"] as? Double) ?? (b["fromY"] as? Int).map(Double.init),
                    toX: (b["toX"] as? Double) ?? (b["toX"] as? Int).map(Double.init),
                    toY: (b["toY"] as? Double) ?? (b["toY"] as? Int).map(Double.init),
                    // Server-verified: shape points arrive as an array
                    // of `{x, y}` objects, e.g.
                    // [{"x":100,"y":50},{"x":200,"y":80}].
                    // For backward-compat also accept the older array-
                    // of-arrays format `[[100,50],[200,80]]` seen in
                    // earlier proxy revisions.
                    points: {
                        if let objs = b["points"] as? [[String: Any]] {
                            return objs.compactMap { obj -> [Double]? in
                                let xv: Double? = (obj["x"] as? Double) ?? (obj["x"] as? Int).map(Double.init)
                                let yv: Double? = (obj["y"] as? Double) ?? (obj["y"] as? Int).map(Double.init)
                                guard let x = xv, let y = yv else { return nil }
                                return [x, y]
                            }
                        }
                        return b["points"] as? [[Double]]
                    }(),
                    shapeKind: b["shapeKind"] as? String,
                    filled: b["filled"] as? Bool
                )
            }
            walkthrough = Walkthrough(
                language: wt["language"] as? String,
                beats: beats
            )
        }

        let annotationText = json["annotationText"] as? String

        return HigherModelResponse(
            text: text,
            clipboardText: clipboardText,
            typing: typing,
            point: point,
            widgets: widgets,
            walkthrough: walkthrough,
            annotationText: annotationText
        )
    }

    // MARK: - Phase 4 Step 1: preflight context + [ROUTE] parsing

    /// Snapshot of "where the user is right now" that we prepend to every
    /// Fable turn (behind `openclicky.contextAwarenessEnabled`). All five
    /// capture calls are cheap; total wall time <30 ms on a warm system
    /// (Finder AppleScript is the long pole at ~30 ms — see
    /// `docs/ROADMAP/02_LAYER_1_INTENT_ROUTER.md`).
    struct FablePreflightContext: Codable, Sendable {
        let frontmostBundle: String?
        let frontmostName: String?
        let windowTitle: String?
        let browserURL: String?
        let selectedFolder: String?
        let selectedFileNames: [String]
        /// Absolute POSIX paths of the Finder selection (parallel to
        /// `selectedFileNames`). Populated only when Finder is the
        /// frontmost app; empty otherwise. Assist agent uses these
        /// as candidate inputs for read_file / grep.
        let selectedFilePaths: [String]
        let selectedText: String?
        let capturedAtUnix: Double
    }

    /// Parsed `[ROUTE] {...}` line from a Fable reply.
    ///
    /// `progressDriven` / `completionMarker` form the F28 substrate: they
    /// are structured hints that a long-running task should keep firing
    /// turns until the agent writes the completion marker (default
    /// `"LAST_COMPLETED: DONE"`) into its progress file. F26 only threads
    /// these fields through the dispatch chain — the actual auto-continue
    /// observer that reads `progress.md` and re-fires lands separately
    /// (Task #203 / F28).
    struct RouteParseResult: Codable, Sendable {
        let kind: String
        let projectRef: String?
        let slug: String?
        let workdir: String?
        let confidence: Double
        let progressDriven: Bool
        let completionMarker: String?

        init(
            kind: String,
            projectRef: String?,
            slug: String?,
            workdir: String?,
            confidence: Double,
            progressDriven: Bool = false,
            completionMarker: String? = nil
        ) {
            self.kind = kind
            self.projectRef = projectRef
            self.slug = slug
            self.workdir = workdir
            self.confidence = confidence
            self.progressDriven = progressDriven
            self.completionMarker = completionMarker
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try c.decode(String.self, forKey: .kind)
            self.projectRef = try c.decodeIfPresent(String.self, forKey: .projectRef)
            self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
            self.workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
            self.confidence = try c.decode(Double.self, forKey: .confidence)
            self.progressDriven = try c.decodeIfPresent(Bool.self, forKey: .progressDriven) ?? false
            self.completionMarker = try c.decodeIfPresent(String.self, forKey: .completionMarker)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(projectRef, forKey: .projectRef)
            try c.encodeIfPresent(slug, forKey: .slug)
            try c.encodeIfPresent(workdir, forKey: .workdir)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(progressDriven, forKey: .progressDriven)
            try c.encodeIfPresent(completionMarker, forKey: .completionMarker)
        }

        /// Convention: when the model flags `progressDriven=true` but omits
        /// an explicit marker, fall back to the AGENTS-longrun-template
        /// contract (`LAST_COMPLETED: DONE`). Kept as a helper rather than
        /// mutating the parsed value at decode time so the log line
        /// `openclicky.route_parsed` reflects exactly what the model said.
        var effectiveCompletionMarker: String? {
            if let m = completionMarker?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return m
            }
            return progressDriven ? "LAST_COMPLETED: DONE" : nil
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case projectRef = "project_ref"
            case slug
            case workdir
            case confidence
            case progressDriven = "progress_driven"
            case completionMarker = "completion_marker"
        }
    }

    /// Bundle identifiers we consider "known browsers" for the purpose
    /// of pulling `AXURL` off their focused web area. Anything not on
    /// this list gets `browserURL = nil` even when the AX call would
    /// have succeeded — matches the roadmap "if frontmost=browser" gate.
    private static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",      // Arc
        "company.thebrowser.dia",           // Arc/Dia
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly"
    ]

    /// Finder's bundle id — gates the AppleScript Finder-selection probe.
    private static let finderBundleID = "com.apple.finder"

    /// Directive block appended once per `query`. Explains the scene-context
    /// contract to Fable. The proxy does not forward the local system prompt
    /// to the model, so the contract has to travel inside `query` itself.
    ///
    /// NOTE: The [ROUTE] JSON tail contract used to live here — it has been
    /// removed. Chat is just chat, we no longer ask the model to classify
    /// its own reply into short/long-task kinds. Agent-lane routing happens
    /// entirely on the client side (Layer 0 "free agent" keyword + upstream
    /// agent detectors).
    static let contextAwarenessDirectiveBlock: String = """
    [openclicky-directives]
    CONTEXT AWARENESS:
    You receive an [openclicky-context]...[/openclicky-context] block before each user query. It shows the user's current app / window / selection. Use it to resolve referential language (e.g. "the func you're looking at" refers to selected_text; "this folder" refers to selected_folder; "this page" refers to url).
    [/openclicky-directives]
    """

    /// Gather the 5-item preflight snapshot. Runs each capture in-place
    /// (they are all cheap and non-blocking apart from Finder's
    /// AppleScript, which sits on `AppleScriptRunner`'s dedicated queue).
    /// Total budget: <30 ms warm, <100 ms cold Finder.
    @MainActor
    static func buildPreflightContext() async -> FablePreflightContext {
        let capturedAt = Date().timeIntervalSince1970

        // If we captured a fresh snapshot at PTT-onset, prefer that
        // over a live re-capture. The user's INTENT was formed with
        // whatever window was front then, not now (focus may have
        // drifted to the terminal/menubar while the model thinks).
        // TTL guards against reusing very stale snapshots.
        if let cached = Self.shared.pttSnapshot,
           capturedAt - Self.shared.pttSnapshotUnix <= Self.pttSnapshotTTLSec {
            HeyClickyLog.log("openclicky.preflight_context.used_ptt_snapshot",
                             lane: "voice", direction: "internal",
                             ["age_sec": Int(capturedAt - Self.shared.pttSnapshotUnix),
                              "frontmost": cached.frontmostBundle ?? "",
                              "has_folder": cached.selectedFolder != nil,
                              "selected_files_count": cached.selectedFilePaths.count])
            // Consume — one snapshot per PTT.
            Self.shared.pttSnapshot = nil
            return cached
        }

        // 1. Frontmost app (sync, NSWorkspace).
        let frontmost = FrontmostAppCapture.capture()
        let pid = frontmost?.processId
        let bundleID = frontmost?.bundleId
        let bundleIDLower = bundleID?.lowercased()
        let localizedName = frontmost?.localizedName

        // 2. Focused window title (AX, sync — safe from any thread).
        var windowTitle: String?
        if let pid, pid > 0 {
            windowTitle = FocusedWindowCapture.capture(processId: pid)?.title
        }

        // 3. Browser URL — only if frontmost is a known browser bundle.
        var browserURL: String?
        if let pid, pid > 0,
           let bundleID,
           Self.knownBrowserBundleIDs.contains(bundleID) {
            browserURL = await BrowserURLCapture.capture(processId: pid)?.url
        }

        // 4. Finder selection — only when Finder is frontmost. AppleScript
        //    latency is ~30 ms warm, ~200 ms cold. Skip entirely otherwise.
        var selectedFolder: String?
        var selectedFileNames: [String] = []
        var selectedFilePaths: [String] = []
        if bundleIDLower == Self.finderBundleID,
           let info = await FinderSelectionCapture.capture() {
            selectedFolder = info.currentFolder
            selectedFileNames = Array(info.selectedFiles.prefix(3).map { $0.name })
            selectedFilePaths = Array(info.selectedFiles.prefix(3).map { $0.path })
        }

        // 5. Selected text — AX strategy 1 ONLY (never Cmd-C). We inline
        //    the AX-only read here rather than calling `SelectedTextCapture`
        //    because that helper will fall through to Cmd-C on empty AX,
        //    which mutates the user's clipboard even with restore-on-exit.
        //    We still consult the shared SelectionCache first so recent
        //    Cmd-C-earned text survives focus changes.
        let selectedText = Self.selectedTextAXOnly()

        return FablePreflightContext(
            frontmostBundle: bundleID,
            frontmostName: localizedName,
            windowTitle: windowTitle,
            browserURL: browserURL,
            selectedFolder: selectedFolder,
            selectedFileNames: selectedFileNames,
            selectedFilePaths: selectedFilePaths,
            selectedText: selectedText,
            capturedAtUnix: capturedAt
        )
    }

    /// Serialise the preflight snapshot into the token-cheap
    /// `[openclicky-context]…[/openclicky-context]` markdown block. Lines
    /// whose value is nil/empty are omitted so the model doesn't waste
    /// attention on `null` filler.
    static func formatPreflightBlock(_ ctx: FablePreflightContext) -> String {
        var lines: [String] = ["[openclicky-context]"]

        if let bundle = ctx.frontmostBundle, !bundle.isEmpty {
            if let name = ctx.frontmostName, !name.isEmpty {
                lines.append("frontmost_app: \(bundle) (\(name))")
            } else {
                lines.append("frontmost_app: \(bundle)")
            }
        } else if let name = ctx.frontmostName, !name.isEmpty {
            lines.append("frontmost_app: \(name)")
        }

        if let title = ctx.windowTitle, !title.isEmpty {
            // Wrap in quotes so a title containing colons doesn't confuse
            // the model's line parser (Fable is fairly forgiving but
            // parity with the doc example matters).
            lines.append("window_title: \"\(title)\"")
        }

        if let url = ctx.browserURL, !url.isEmpty {
            lines.append("url: \(url)")
        }

        if let folder = ctx.selectedFolder, !folder.isEmpty {
            lines.append("selected_folder: \(folder)")
        }

        if !ctx.selectedFileNames.isEmpty {
            let joined = ctx.selectedFileNames.joined(separator: ", ")
            lines.append("selected_files: [\(joined)]")
        }
        if !ctx.selectedFilePaths.isEmpty {
            // Full POSIX paths — the assist agent can pass these
            // straight to read_file / grep without disambiguation.
            let joined = ctx.selectedFilePaths.joined(separator: ", ")
            lines.append("selected_file_paths: [\(joined)]")
        }

        if let text = ctx.selectedText, !text.isEmpty {
            // Cap selected_text at 1000 chars so a massive selection
            // doesn't blow the prompt budget. The model just needs a
            // fingerprint, not the whole document.
            let trimmed = text.count > 1000 ? String(text.prefix(1000)) + "…" : text
            // Escape embedded newlines so the block stays one line per
            // field — mirrors the doc example.
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("selected_text: \"\(escaped)\"")
        }

        // Stash content: pin / whiteboard / links / annotations.
        // HeyClicky Free forwards `[openclicky-context]` blocks to
        // the backend higher-model via /chat-tool-call, but does NOT
        // forward client-injected `conversation.item.create` items.
        // So this block is the only channel the backend sees.
        let stashLines = Self.stashContextLinesForBackend()
        for l in stashLines {
            lines.append(l)
        }

        lines.append("[/openclicky-context]")
        return lines.joined(separator: "\n")
    }

    /// Peek every stash (pin / whiteboard / linkrect / annotations)
    /// and emit compact lines for the preflight block. Empty stashes
    /// yield no lines. Same shape as
    /// `CompanionManager.buildStashContextForVoicePrompt` but flatter
    /// so it fits inside a single `[openclicky-context]` envelope.
    /// Dispatch ONLY the clipboard field from a raw `/chat-tool-call`
    /// response inside the assist loop's reentrant rounds. Typing
    /// with x/y coordinates and walkthrough beats are deliberately
    /// skipped:
    ///   · typing.x/y expects the same screenshot dims that the
    ///     server-side coordinate transform assumed. Assist loop's
    ///     screenshot may or may not be the frontmost display —
    ///     replaying the click at those pixel coords is a UX
    ///     accident waiting to happen.
    ///   · walkthrough beats need pendingHeyClickyCaptureContext
    ///     which only the outer voice pipeline sets up.
    ///
    /// Clipboard is safe: it's a data write, not a screen action,
    /// and the write helper already preserves the user's current
    /// clipboard so nothing is destroyed if the model got it wrong.
    @MainActor
    static func dispatchSimpleUIActions(
        rawJSON data: Data,
        companion: CompanionManager
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return }
        if let clip = obj["clipboardText"] as? String, !clip.isEmpty {
            companion.writeToClipboardPreservingUserContents(clip)
        }
    }

    static func stashContextLinesForBackend() -> [String] {
        var out: [String] = []
        let picks = PickStash.shared.peekAll()
        for (i, p) in picks.enumerated() {
            let role = p.role ?? "?"
            let title = p.title ?? ""
            let value = p.value ?? ""
            let displayText: String
            if !title.isEmpty {
                displayText = title
            } else if !value.isEmpty {
                displayText = value.count > 500 ? String(value.prefix(500)) + "…" : value
            } else {
                displayText = ""
            }
            let escaped = displayText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out.append("pinned_element_\(i): role=\(role) text=\"\(escaped)\"")
        }
        if let links = LinkRectStash.shared.peek(), !links.isEmpty {
            for (i, l) in links.prefix(20).enumerated() {
                let titleBit: String
                if let t = l.title, !t.isEmpty {
                    titleBit = " title=\"\(t.replacingOccurrences(of: "\"", with: "\\\""))\""
                } else {
                    titleBit = ""
                }
                out.append("harvested_link_\(i): \(l.url)\(titleBit)")
            }
        }
        if let regions = WhiteboardStash.shared.peek(), !regions.isEmpty {
            let nonEmpty = regions.filter { ($0.ocrText ?? "").isEmpty == false }
            for (i, r) in nonEmpty.prefix(8).enumerated() {
                let text = (r.ocrText ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                out.append("whiteboard_\(i): kind=\(r.gestureKind) text=\"\(text)\"")
            }
        }
        let annos = AnnotationStash.shared.peek()
        for (i, a) in annos.prefix(20).enumerated() {
            let body = a.body
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out.append("annotation_\(i): source=\(a.source.rawValue) anchor=\"\(a.anchorLabel ?? "?")\" body=\"\(body)\"")
        }
        return out
    }

    /// AX-only "read current selection" — Strategy 1 from
    /// `SelectedTextCapture`, minus the Cmd-C fallback. Consults the
    /// shared `SelectionCache` first so recent captures survive focus
    /// changes. Never touches the clipboard.
    private static func selectedTextAXOnly() -> String? {
        // Cache short-circuit (matches SelectedTextCapture.capture).
        if let cached = SelectionCache.shared.getFresh() {
            return cached.text
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedStatus == .success, let focusedRaw = focusedRef,
              CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = focusedRaw as! AXUIElement
        var selectedRef: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        )
        guard selectedStatus == .success, let selectedRaw = selectedRef,
              CFGetTypeID(selectedRaw) == CFStringGetTypeID() else {
            return nil
        }
        let text = selectedRaw as! CFString as String
        return text.isEmpty ? nil : text
    }

/// Wraps a raw `JSONSerialization` value into `OpenClickyJSONValue`.
    private func jsonAny(_ value: Any) -> OpenClickyJSONValue {
        if value is NSNull { return .null }
        if let s = value as? String { return .string(s) }
        if let b = value as? Bool { return .bool(b) }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let arr = value as? [Any] { return .array(arr.map { jsonAny($0) }) }
        if let obj = value as? [String: Any] {
            var out: [String: OpenClickyJSONValue] = [:]
            for (k, v) in obj { out[k] = jsonAny(v) }
            return .object(out)
        }
        return .null
    }
}
