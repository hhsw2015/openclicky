// openclicky-ocr-helper — XPCService bundle entry point.
//
// Runs Vision OCR + SQLCipher FTS writes off the main OpenClicky
// process. Registered as com.jkneen.openclicky.ocr; the main app
// opens the connection via NSXPCConnection(serviceName:).
//
// Lifecycle:
//   1. Main-app OCRHelperClient sends a `process(...)` request per
//      captured frame.
//   2. This process wakes on-demand (launchd starts an XPCService
//      instance when the connection resumes), runs Vision, writes
//      one FTS transaction, replies (ok,error?).
//   3. launchd tears the helper back down after ~15s idle to keep
//      resident memory zero when the user isn't capturing.
//
// Vault path: fixed to ~/Library/Application Support/OpenClicky/rewind,
// matching what the main app configures via
// `OpenRewindStorage.defaultAppSupportName = "OpenClicky/rewind"`. The
// helper reads the SQLCipher passphrase itself from
// `<vault>/key`; the main app never ships the key across XPC.

import Foundation

// MARK: - Vault handle (opened lazily on first request)

/// Simple `Error` wrapper so `Result` can carry a plain message.
/// String itself does not conform to `Error` under Swift 6.
struct HelperMessageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class HelperState: @unchecked Sendable {
    static let shared = HelperState()

    private let lock = NSLock()
    private var vault: VaultAccess?
    private var openError: String?

    private init() {}

    /// Returns the process-wide vault handle, opening it on first
    /// call. Subsequent callers get the cached handle. On failure the
    /// error string is memoized so we don't hammer keychain / disk
    /// on every request.
    func vaultAccess() -> Result<VaultAccess, HelperMessageError> {
        lock.lock()
        defer { lock.unlock() }
        if let v = vault {
            return .success(v)
        }
        if let e = openError {
            return .failure(HelperMessageError(message: e))
        }
        do {
            let root = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/OpenClicky/rewind")
            let v = try VaultAccess(vaultRoot: root)
            vault = v
            return .success(v)
        } catch {
            let msg = "\(error)"
            openError = msg
            return .failure(HelperMessageError(message: msg))
        }
    }
}

// MARK: - XPC service exported object

final class OCRService: NSObject, OpenClickyOCRHelperProtocol {

    func ping(reply: @escaping (Int32) -> Void) {
        reply(getpid())
    }

    func process(cgImagePNG: Data,
                 bundleID: String?,
                 frameID: Int64,
                 segmentID: Int64,
                 tsMillis: Int64,
                 title: String?,
                 reply: @escaping (Bool, String?) -> Void) {
        // Hop off the XPC callback queue so a slow Vision run doesn't
        // block the reply thread; the helper still executes one frame
        // at a time to keep peak memory bounded.
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            let regions: [OCRRegion]
            do {
                regions = try OCRRunner.recognize(pngData: cgImagePNG)
            } catch {
                reply(false, "ocr: \(error)")
                return
            }

            let joined = regions.map(\.text).joined(separator: "\n")
            let nodes = regions.map { r in
                VaultAccess.NodeInput(
                    text: r.text,
                    leftX: r.leftX,
                    topY: r.topY,
                    width: r.width,
                    height: r.height)
            }

            switch HelperState.shared.vaultAccess() {
            case .failure(let msg):
                reply(false, "vault: \(msg)")
            case .success(let vault):
                do {
                    try vault.insertSearchRanking(
                        frameID: frameID,
                        segmentID: segmentID,
                        text: joined,
                        otherText: "",
                        title: title,
                        nodes: nodes)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    // Log to stderr so `log show` on
                    // com.apple.xpc.launchd shows the helper's
                    // per-frame trace when debugging.
                    let bundleTag = bundleID ?? "-"
                    FileHandle.standardError.write(Data(
                        "openclicky-ocr-helper: fid=\(frameID) regions=\(regions.count) chars=\(joined.count) ms=\(ms) bundle=\(bundleTag)\n".utf8))
                    // Silence bundleID unused-warning in Release when
                    // the log format changes.
                    _ = bundleID
                    _ = tsMillis
                    reply(true, nil)
                } catch {
                    reply(false, "insert: \(error)")
                }
            }
        }
    }
}

// MARK: - XPC listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let iface = NSXPCInterface(with: OpenClickyOCRHelperProtocol.self)
        newConnection.exportedInterface = iface
        newConnection.exportedObject = OCRService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
// NSXPCListener.service() never returns; RunLoop is driven internally.
RunLoop.current.run()
