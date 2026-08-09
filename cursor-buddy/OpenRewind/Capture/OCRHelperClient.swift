// OCRHelperClient — thin NSXPCConnection wrapper around the
// openclicky-ocr-helper XPCService.
//
// The main-app CaptureCoordinator hands each captured frame to this
// client instead of running Vision + FTS writes inline. Encoding the
// frame to PNG on the caller side is cheap (~5 ms) and lets us ship
// the pixels across the XPC boundary without shared memory. Once the
// XPC send returns, the main-app runloop is free again; the helper
// runs Vision at background QoS with usesCPUOnly = true so it never
// competes with WindowServer or the main app's cursor overlay.
//
// Connection lifecycle:
//   * On first `process(...)` call we open the NSXPCConnection.
//   * The helper is an XPCService bundle inside OpenClicky.app;
//     launchd handles instance start / stop.
//   * On invalidation or interruption we drop the cached connection
//     and re-connect on the next request. The helper is stateless
//     across frames (it opens the vault handle lazily) so a reconnect
//     just costs a fork + open once.
//
// The @objc protocol declared here must stay byte-identical to the
// one shipped inside the helper at
// helpers/openclicky-ocr-helper/Sources/openclicky-ocr-helper/OCRHelperProtocol.swift.
// NSXPCConnection binds by protocol name at runtime.

import Foundation
import CoreGraphics
import ImageIO

@objc protocol OpenClickyOCRHelperProtocol {
    func process(cgImagePNG: Data,
                 bundleID: String?,
                 frameID: Int64,
                 segmentID: Int64,
                 tsMillis: Int64,
                 title: String?,
                 reply: @escaping (_ ok: Bool, _ error: String?) -> Void)
    func ping(reply: @escaping (_ pid: Int32) -> Void)
}

public final class OCRHelperClient: @unchecked Sendable {

    public static let shared = OCRHelperClient()

    /// Service name registered by the helper's Info.plist.
    private static let serviceName = "com.jkneen.openclicky.ocr"

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Set to true when a hard failure (invalid connection, protocol
    /// mismatch, helper crash) means we should stop retrying for a
    /// while. The main app's OCR path falls back to a silent skip
    /// under this flag so the capture pipeline stays healthy.
    private var disabledUntil: Date?

    public enum ClientError: Error, CustomStringConvertible {
        case pngEncodeFailed
        case xpcInvalid(String)
        case helperFailed(String)
        case disabledCoolingDown

        public var description: String {
            switch self {
            case .pngEncodeFailed:          return "png encode failed"
            case .xpcInvalid(let s):        return "xpc invalid: \(s)"
            case .helperFailed(let s):      return "helper: \(s)"
            case .disabledCoolingDown:      return "helper temporarily disabled"
            }
        }
    }

    private var healthTimer: DispatchSourceTimer?
    private init() {
        startHealthTimer()
    }

    /// FIX(perf-2026-08-01 stability): periodic keep-warm ping. Silent
    /// XPC suspend on macOS 15+ leaves the connection nil until the
    /// next capture — up to tens of seconds of in-process fallback
    /// (running Vision on the main app process → the very jank source
    /// XPC was meant to solve). Ping every 4 min so idle-suspend
    /// (~10 min OS default) never fires without a wake-up.
    private func startHealthTimer() {
        let q = DispatchQueue(label: "openclicky.ocr_helper.health",
                              qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 60, repeating: 240)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                _ = try? await self.ping()
            }
        }
        t.resume()
        self.healthTimer = t
    }

    // MARK: - Public API

    /// Encode `cgImage` to PNG and dispatch to the helper. Returns
    /// once the helper has finished the DB insert (or failed). Errors
    /// bubble up so the caller can log them; the caller is expected
    /// to swallow them (an occasional missed frame is fine).
    public func process(cgImage: CGImage,
                        bundleID: String?,
                        frameID: Int64,
                        segmentID: Int64,
                        ts: Date,
                        title: String?) async throws {
        if let until = readDisabledUntil(), until > Date() {
            throw ClientError.disabledCoolingDown
        }
        guard let png = encodePNG(cgImage) else {
            throw ClientError.pngEncodeFailed
        }
        try await send(pngData: png,
                       bundleID: bundleID,
                       frameID: frameID,
                       segmentID: segmentID,
                       tsMillis: Int64(ts.timeIntervalSince1970 * 1000),
                       title: title)
    }

    /// Cheap health check: returns the helper's pid when reachable.
    public func ping() async throws -> Int32 {
        let proxy = try acquireProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.ping { pid in
                cont.resume(returning: pid)
            }
        }
    }

    // MARK: - Send

    private func send(pngData: Data,
                      bundleID: String?,
                      frameID: Int64,
                      segmentID: Int64,
                      tsMillis: Int64,
                      title: String?) async throws {
        let proxy = try acquireProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.process(cgImagePNG: pngData,
                          bundleID: bundleID,
                          frameID: frameID,
                          segmentID: segmentID,
                          tsMillis: tsMillis,
                          title: title) { ok, err in
                if ok {
                    cont.resume(returning: ())
                } else {
                    cont.resume(throwing: ClientError.helperFailed(err ?? "unknown"))
                }
            }
        }
    }

    // MARK: - Connection management

    private func acquireProxy() throws -> OpenClickyOCRHelperProtocol {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: Self.serviceName)
            let iface = NSXPCInterface(with: OpenClickyOCRHelperProtocol.self)
            conn.remoteObjectInterface = iface
            // On invalidation / interruption drop the cached
            // connection so the next request re-connects. Cool the
            // client down for 5 s under invalidation so we don't
            // storm launchd if the helper is missing entirely.
            conn.invalidationHandler = { [weak self] in
                OpenClickyMessageLogStore.shared.append(
                    lane: "capture", direction: "error",
                    event: "openclicky.ocr_helper.invalidated",
                    fields: ["cooldown_s": 5])
                self?.handleConnectionDrop(coolingDown: 5)
            }
            conn.interruptionHandler = { [weak self] in
                OpenClickyMessageLogStore.shared.append(
                    lane: "capture", direction: "error",
                    event: "openclicky.ocr_helper.interrupted",
                    fields: [:])
                self?.handleConnectionDrop(coolingDown: 0)
            }
            conn.resume()
            connection = conn
        }
        let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            OpenClickyMessageLogStore.shared.append(
                lane: "capture", direction: "error",
                event: "openclicky.ocr_helper.proxy_error",
                fields: ["error": "\(error)"])
            self?.handleConnectionDrop(coolingDown: 1)
        }
        guard let typed = proxy as? OpenClickyOCRHelperProtocol else {
            throw ClientError.xpcInvalid("proxy cast failed")
        }
        return typed
    }

    /// FIX(stability-2026-08-01 error-audit #10): exponential backoff
    /// + permanent disable after too many consecutive crashes so an
    /// XPC service that can't start (missing binary, sandbox denial)
    /// doesn't spam launchd + the message log every 5 s forever.
    private var consecutiveDropCount = 0
    private static let maxConsecutiveDrops = 8

    private func handleConnectionDrop(coolingDown seconds: TimeInterval) {
        lock.lock()
        connection?.invalidate()
        connection = nil
        consecutiveDropCount += 1
        let overrideSeconds: TimeInterval
        if consecutiveDropCount >= Self.maxConsecutiveDrops {
            // Permanent disable — give up on XPC for this session,
            // fall back to in-process forever. User can restart app.
            overrideSeconds = 24 * 3600
            OpenClickyMessageLogStore.shared.append(
                lane: "capture", direction: "error",
                event: "openclicky.ocr_helper.permanent_disable",
                fields: ["consecutive": consecutiveDropCount])
        } else {
            // Exponential backoff: 5, 10, 20, 40, 80 s cap
            overrideSeconds = min(seconds * pow(2, Double(consecutiveDropCount - 1)), 80)
        }
        disabledUntil = Date().addingTimeInterval(overrideSeconds)
        lock.unlock()
        // FIX(perf-2026-08-01 stability): active self-heal. Instead of
        // waiting passively for the next OCR request to re-open a
        // connection, kick a background ping after the cooldown so the
        // XPC subprocess is warm again before the next capture arrives.
        // macOS 15+ suspends idle XPC services aggressively; without
        // this we'd fall back to in-process OCR for tens of seconds
        // after every suspend event.
        let warmDelay = max(seconds, 0.5)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + warmDelay) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let pid = try await self.ping()
                    // Successful reconnect — reset the backoff counter.
                    self.lock.lock()
                    self.consecutiveDropCount = 0
                    self.lock.unlock()
                    OpenClickyMessageLogStore.shared.append(
                        lane: "capture", direction: "internal",
                        event: "openclicky.ocr_helper.re_ready",
                        fields: ["pid": Int(pid)])
                } catch {
                    OpenClickyMessageLogStore.shared.append(
                        lane: "capture", direction: "error",
                        event: "openclicky.ocr_helper.re_ping_failed",
                        fields: ["error": "\(error)"])
                }
            }
        }
    }

    private func readDisabledUntil() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return disabledUntil
    }

    // MARK: - PNG encode

    private func encodePNG(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data as CFMutableData,
                "public.png" as CFString,
                1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return data as Data
    }
}
