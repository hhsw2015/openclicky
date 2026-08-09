// AudioCapture — AVAudioEngine tap on default input. Emits PCM buffers.
// Optional system-audio path via SCStream .audio output (not started by
// default; enable via `enableSystemAudio` when SC is running elsewhere).
//
// Transcription is out of scope for Phase 2 — we expose a `Transcriber`
// protocol hook so Phase 4 can drop WhisperKit in without touching this
// file. Default impl is `NoopTranscriber` that ignores buffers.

import Foundation
import AVFoundation

/// Transcriber hook. Phase 4 will plug WhisperKit in here.
public protocol Transcriber: AnyObject, Sendable {
    func transcribe(_ buffer: AVAudioPCMBuffer, at ts: Date) async
}

/// Default no-op transcriber. Silently drops audio buffers.
public final class NoopTranscriber: Transcriber, @unchecked Sendable {
    public init() {}
    public func transcribe(_ buffer: AVAudioPCMBuffer, at ts: Date) async {}
}

public actor AudioCapture {

    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer, Date) -> Void

    private let engine = AVAudioEngine()
    private var handler: BufferHandler?
    private var transcriber: Transcriber = NoopTranscriber()
    private var installed = false

    public init() {}

    public func setBufferHandler(_ handler: @escaping BufferHandler) {
        self.handler = handler
    }

    public func setTranscriber(_ t: Transcriber) {
        self.transcriber = t
    }

    /// Start audio capture. Uses the default input node at native format.
    public func start() throws {
        if engine.isRunning { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 4096 = ~93 ms at 44.1kHz — small enough for near-realtime
        // transcription, large enough to keep CPU quiet.
        if !installed {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
                guard let self else { return }
                let ts = Date()
                Task { await self.dispatch(buf, at: ts) }
            }
            installed = true
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        if installed {
            engine.inputNode.removeTap(onBus: 0)
            installed = false
        }
    }

    private func dispatch(_ buf: AVAudioPCMBuffer, at ts: Date) async {
        handler?(buf, ts)
        await transcriber.transcribe(buf, at: ts)
    }
}
