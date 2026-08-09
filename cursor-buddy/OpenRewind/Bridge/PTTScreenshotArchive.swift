//
//  PTTScreenshotArchive.swift
//  cursor-buddy
//
//  Every time the user hits push-to-talk and the AI receives a
//  screenshot, we also persist that JPEG + its OCR into the Screen
//  History vault. The auto-capture stream runs at 0.5 fps and can
//  miss the exact moment the user asked a question; PTT frames are
//  the highest-signal "what was on screen when I asked" record we
//  can produce, so they belong in long-term memory.
//
//  Best-effort: silently no-ops when Screen History is disabled or
//  the writer refuses. Never blocks or throws to the caller.
//

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

@MainActor
public enum PTTScreenshotArchive {

    public static func persist(jpeg: Data,
                               label: String,
                               userPrompt: String,
                               capturedAt: Date = Date()) {
        guard let bridge = OpenRewindBridge.shared else { return }

        // 1. Save JPEG into vault temp dir so downstream reconcile can
        //    find it if needed.
        let name = "ptt-\(Int64(capturedAt.timeIntervalSince1970 * 1000)).jpg"
        let tempDir = bridge.storage.root.appendingPathComponent("temp",
                                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir,
                                                  withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent(name)
        do { try jpeg.write(to: fileURL) } catch { return }

        // 2. Resolve the current segment (newest one; PTT lands here).
        var segId: Int64 = 0
        if let (_, rows) = try? bridge.reader.rawQuery(
            "SELECT id FROM segment ORDER BY startDate DESC LIMIT 1;", []),
           let first = rows.first, let raw = first.first,
           let id = Int64(raw ?? "") {
            segId = id
        }
        guard segId > 0 else { return }

        // 3. Insert frame row.
        let frameId: Int64
        do {
            let input = OpenRewindFrameInput(
                createdAt: capturedAt,
                imageFileName: "temp/\(name)",
                segmentId: segId,
                videoId: nil,
                videoFrameIndex: nil,
                isStarred: false,
                encodingStatus: "deferred",
                captureTrigger: "manual")
            frameId = try bridge.writer.insertFrame(input)
        } catch { return }

        // 4. Run OCR asynchronously (Vision is background-safe). Once
        //    complete, insert into searchRanking so this frame is
        //    findable by openrewind.search / .ask.
        Task.detached(priority: .utility) {
            guard let cg = cgImageFromJPEG(jpeg) else { return }
            let (text, nodes) = await runOCR(on: cg)
            guard !text.isEmpty else { return }
            await MainActor.run {
                _ = try? bridge.writer.insertSearchRanking(
                    frameId: frameId,
                    segmentId: segId,
                    text: text,
                    otherText: "PTT ctx: \(userPrompt.prefix(200))",
                    title: label,
                    nodes: nodes.map {
                        OpenRewindNodeInput(text: $0.0,
                                            leftX: $0.1.origin.x,
                                            topY: $0.1.origin.y,
                                            width: $0.1.width,
                                            height: $0.1.height,
                                            windowIndex: 0)
                    })
                // Hybrid search: co-index this PTT frame semantically.
                EmbeddingStore.upsert(bridge: bridge, frameId: frameId,
                                      text: text)
                Task { await LongTermMemoryContext.invalidateCache() }
            }
        }
    }

    // MARK: - helpers

    nonisolated private static func cgImageFromJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func runOCR(on image: CGImage) async
        -> (text: String, nodes: [(String, CGRect)]) {
        await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [String] = []
                var nodes: [(String, CGRect)] = []
                for o in obs {
                    guard let best = o.topCandidates(1).first else { continue }
                    lines.append(best.string)
                    // VN bbox is in normalized coords with origin bottom-left;
                    // flip to top-left to match Rewind schema.
                    let b = o.boundingBox
                    let flipped = CGRect(x: b.minX,
                                          y: 1 - b.minY - b.height,
                                          width: b.width,
                                          height: b.height)
                    nodes.append((best.string, flipped))
                }
                cont.resume(returning: (lines.joined(separator: "\n"), nodes))
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([req])
        }
    }
}
