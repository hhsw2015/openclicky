// OpenRewindDaemon.swift — the top-level composition point for a running
// daemon: Reader + Writer + Compressor settings + an injectable capture
// pipeline. Phase 1 keeps `start()` / `stop()` as thin lifecycle hooks;
// the concrete capture wiring lands in OpenRewindCapture and is injected
// via a protocol (no direct import — that would create a cycle).

import Foundation

/// Protocol OpenRewindKit uses to talk to OpenRewindCapture without
/// importing it directly. OpenRewindCapture will declare a concrete
/// type that conforms.
public protocol OpenRewindCaptureController: AnyObject, Sendable {
    func start(writer: OpenRewindWriter,
               settings: OpenRewindCompressionSettings) throws
    func stop() throws
}

/// Configuration bundle a caller hands to `OpenRewindDaemon`.
public struct OpenRewindDaemonConfig: Sendable {
    public let storage: OpenRewindStorage
    public let passphrase: String
    public let profile: OpenRewindCompressionProfile
    public let captureWidth: Int
    public let captureHeight: Int
    public let captureFrameRate: Double

    public init(storage: OpenRewindStorage = .openRewindDefault,
                passphrase: String,
                profile: OpenRewindCompressionProfile = .integration,
                captureWidth: Int = 3456,
                captureHeight: Int = 2160,
                captureFrameRate: Double = 2.0) {
        self.storage = storage
        self.passphrase = passphrase
        self.profile = profile
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.captureFrameRate = captureFrameRate
    }
}

/// Top-level lifecycle owner. Composes Reader + Writer + Compressor and
/// delegates the actual capture loop to an injected controller (usually
/// `OpenRewindCapture.CaptureCoordinator`).
public final class OpenRewindDaemon: @unchecked Sendable {

    public let config: OpenRewindDaemonConfig
    public let reader: OpenRewindReader
    public let writer: OpenRewindWriter
    public let compressionSettings: OpenRewindCompressionSettings
    private var controller: OpenRewindCaptureController?

    /// AI provider registered by the host app. `nil` means the chat UI
    /// falls back to "no model configured" — OpenRewind itself never
    /// ships or invokes an LLM. Access is guarded by `aiLock`.
    private let aiLock = NSLock()
    private var _aiProvider: OpenRewindAIProvider?
    public var aiProvider: OpenRewindAIProvider? {
        get { aiLock.lock(); defer { aiLock.unlock() }; return _aiProvider }
    }
    public func setAIProvider(_ provider: OpenRewindAIProvider?) {
        aiLock.lock(); defer { aiLock.unlock() }
        _aiProvider = provider
    }

    /// Constructs a daemon and validates the schema up-front. Does NOT
    /// start capture — call `start(controller:)` for that.
    public init(config: OpenRewindDaemonConfig) throws {
        self.config = config
        try OpenRewindSchemaValidator.verify(storage: config.storage,
                                              passphrase: config.passphrase)
        self.reader = try OpenRewindReader(storage: config.storage,
                                             passphrase: config.passphrase)
        self.writer = try OpenRewindWriter(storage: config.storage,
                                             passphrase: config.passphrase)
        self.compressionSettings = OpenRewindCompressionSettings(
            profile: config.profile,
            width: config.captureWidth,
            height: config.captureHeight,
            frameRate: config.captureFrameRate)
    }

    /// Attach a capture controller and begin capture. The controller is
    /// injected so OpenRewindKit doesn't need to import OpenRewindCapture
    /// (would introduce a cycle in Package.swift).
    public func start(controller: OpenRewindCaptureController) throws {
        // TODO(phase-2): kick off HealthMonitor + MCPBridge here.
        self.controller = controller
        try controller.start(writer: writer, settings: compressionSettings)
    }

    /// Stop capture cleanly. Idempotent.
    public func stop() throws {
        try controller?.stop()
        controller = nil
    }
}
