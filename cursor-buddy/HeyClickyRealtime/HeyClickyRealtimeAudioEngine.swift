//
//  HeyClickyRealtimeAudioEngine.swift
//  cursor-buddy
//
//  Direct port of clicky-mac RealtimeAudioEngine.swift.
//  Mic capture + speaker playback for the persistent Realtime WS.
//  Captures PCM16 mono @ 24 kHz, streams in 1-second base64 chunks,
//  plays back inbound audio deltas via AVAudioPlayerNode with tight
//  scheduling gaps so barge-in feels instant.
//

import AVFoundation
import Foundation

private final class HeyClickySuppliedFlag {
    var hasSupplied = false
}

@MainActor
final class HeyClickyRealtimeAudioEngine: NSObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var micConverter: AVAudioConverter?
    private var pendingCapturedBytes: [UInt8] = []
    private var sendChunkSize: Int
    private let sampleRate: Double
    private var isCapturing = false
    private var onCapturedBase64: ((String) -> Void)?

    private let playbackFormat: AVAudioFormat

    init(sampleRate: Int = 24_000) {
        self.sampleRate = Double(sampleRate)
        self.sendChunkSize = sampleRate * 2 // 1 second of PCM16 mono
        self.playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    }

    // MARK: - Mic capture

    func startCapture(onChunk: @escaping (String) -> Void) throws {
        guard !isCapturing else { return }
        onCapturedBase64 = onChunk

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(
                domain: "HeyClickyRealtimeAudioEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "cannot build target format"]
            )
        }
        micConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.convertAndDispatchInputBuffer(buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
            playerNode.play()
        } catch {
            throw NSError(
                domain: "HeyClickyRealtimeAudioEngine",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "engine.start failed: \(error)"]
            )
        }
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        onCapturedBase64 = nil
        pendingCapturedBytes.removeAll()
    }

    /// Drop any queued assistant audio so barge-in feels instant.
    func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
        playerNode.play()
    }

    private func convertAndDispatchInputBuffer(_ input: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter = micConverter else { return }
        let outCapacity = AVAudioFrameCount(
            Double(input.frameLength) * (targetFormat.sampleRate / input.format.sampleRate) + 1024
        )
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        let suppliedBox = HeyClickySuppliedFlag()
        let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
            if suppliedBox.hasSupplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            suppliedBox.hasSupplied = true
            statusPtr.pointee = .haveData
            return input
        }
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if status == .error || status == .endOfStream { return }
        guard let channelData = outBuffer.int16ChannelData, outBuffer.frameLength > 0 else { return }
        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        let ptr = channelData[0]
        pendingCapturedBytes.append(
            contentsOf: UnsafeBufferPointer(
                start: UnsafePointer<UInt8>(OpaquePointer(ptr)),
                count: byteCount
            )
        )
        while pendingCapturedBytes.count >= sendChunkSize {
            let chunk = Array(pendingCapturedBytes.prefix(sendChunkSize))
            pendingCapturedBytes.removeFirst(sendChunkSize)
            let base64 = Data(chunk).base64EncodedString()
            onCapturedBase64?(base64)
        }
    }

    /// Emit whatever is left below one full 1s chunk. Called on PTT release
    /// so <100 ms tails still get delivered (server rejects <100 ms commits
    /// so caller must combine with the byte-count guard).
    func flushPending() {
        guard !pendingCapturedBytes.isEmpty else { return }
        let base64 = Data(pendingCapturedBytes).base64EncodedString()
        pendingCapturedBytes.removeAll()
        onCapturedBase64?(base64)
    }

    // MARK: - Playback

    func schedulePlayback(base64: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        schedulePlayback(pcm16: data)
    }

    func schedulePlayback(pcm16 data: Data) {
        let frameCount = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let float = buffer.floatChannelData?[0] else { return }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let sample = Double(int16[i]) / 32768.0
                float[i] = Float(sample)
                sumSquares += sample * sample
            }
        }
        if frameCount > 0 {
            lastPlaybackRMS = CGFloat(sqrt(sumSquares / Double(frameCount)))
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// RMS of the most recently scheduled playback buffer. Used to
    /// drive the speaking-pulse ring so its amplitude tracks the TTS
    /// stream instead of stale mic input.
    private(set) var lastPlaybackRMS: CGFloat = 0

    // MARK: - RMS for waveform / power level

    var currentInputRMS: CGFloat {
        guard !pendingCapturedBytes.isEmpty else { return 0 }
        let sampleCount = min(pendingCapturedBytes.count / 2, 512)
        guard sampleCount > 0 else { return 0 }
        let base = pendingCapturedBytes.suffix(sampleCount * 2)
        var sumSquares: Double = 0
        base.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int16.self, capacity: sampleCount) { intPtr in
                for i in 0..<sampleCount {
                    let sample = Double(intPtr[i]) / 32768.0
                    sumSquares += sample * sample
                }
            }
        }
        return CGFloat(sqrt(sumSquares / Double(sampleCount)))
    }
}
