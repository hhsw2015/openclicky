//
//  WhisperLocalModelManager.swift
//  cursor-buddy
//
//  User-visible status/download state for whisper.cpp GGML models.
//  Mirrors OpenClickyLocalSpeechModelManager's shape so the Advanced
//  Providers panel can reuse the same UI patterns.
//

import Combine
import Foundation

nonisolated enum WhisperLocalModelVariant: String, CaseIterable, Identifiable, Sendable {
    case largeV3TurboQ5 = "large-v3-turbo-q5_0"
    case largeV3Turbo = "large-v3-turbo"
    case small = "small"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .largeV3TurboQ5:
            return "Large v3 Turbo (Q5)"
        case .largeV3Turbo:
            return "Large v3 Turbo"
        case .small:
            return "Small"
        }
    }

    var subtitle: String {
        switch self {
        case .largeV3TurboQ5:
            return "547 MB - recommended"
        case .largeV3Turbo:
            return "1.62 GB - highest accuracy"
        case .small:
            return "465 MB - fastest"
        }
    }

    /// Approximate file size shown next to the download button.
    var estimatedBytes: Int64 {
        switch self {
        case .largeV3TurboQ5: return 574_041_600
        case .largeV3Turbo: return 1_624_555_275
        case .small: return 487_601_967
        }
    }

    var fileName: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    static let defaultsKey = WhisperLocalPreferences.modelNameDefaultsKey

    static func configured() -> WhisperLocalModelVariant {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? largeV3TurboQ5.rawValue
        return WhisperLocalModelVariant(rawValue: raw) ?? .largeV3TurboQ5
    }
}

enum WhisperLocalDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double)
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class WhisperLocalModelManager: ObservableObject {
    static let shared = WhisperLocalModelManager()

    @Published private(set) var selectedVariant: WhisperLocalModelVariant
    @Published private(set) var downloadStates: [WhisperLocalModelVariant: WhisperLocalDownloadState] = [:]
    @Published private(set) var lastErrorMessage: String?

    private var activeTasks: [WhisperLocalModelVariant: URLSessionDownloadTask] = [:]
    private var progressObservers: [WhisperLocalModelVariant: NSKeyValueObservation] = [:]
    private var downloadDelegates: [WhisperLocalModelVariant: WhisperDownloadDelegate] = [:]

    init(selectedVariant: WhisperLocalModelVariant = .configured()) {
        self.selectedVariant = selectedVariant
        for variant in WhisperLocalModelVariant.allCases {
            downloadStates[variant] = Self.modelExists(variant) ? .ready : .notDownloaded
        }
    }

    static func modelDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("OpenClicky/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modelURL(_ variant: WhisperLocalModelVariant) -> URL {
        modelDirectory().appendingPathComponent(variant.fileName)
    }

    static func modelExists(_ variant: WhisperLocalModelVariant) -> Bool {
        let url = modelURL(variant)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 10 * 1024 * 1024 else { // >10 MB sanity floor
            return false
        }
        return true
    }

    func setSelectedVariant(_ variant: WhisperLocalModelVariant) {
        selectedVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: WhisperLocalModelVariant.defaultsKey)
    }

    func state(for variant: WhisperLocalModelVariant) -> WhisperLocalDownloadState {
        downloadStates[variant] ?? .notDownloaded
    }

    var isSelectedModelReady: Bool { state(for: selectedVariant).isReady }

    func downloadSelected() {
        download(selectedVariant)
    }

    func download(_ variant: WhisperLocalModelVariant) {
        guard activeTasks[variant] == nil else { return }
        lastErrorMessage = nil
        downloadStates[variant] = .downloading(fraction: 0)

        let target = Self.modelURL(variant)
        let delegate = WhisperDownloadDelegate(
            variant: variant,
            targetURL: target,
            onProgress: { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.downloadStates[variant] {
                        self.downloadStates[variant] = .downloading(fraction: fraction)
                    }
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeTasks[variant] = nil
                    self.progressObservers[variant] = nil
                    self.downloadDelegates[variant] = nil
                    switch result {
                    case .success:
                        self.downloadStates[variant] = .ready
                    case .failure(let error):
                        let message = error.localizedDescription
                        self.lastErrorMessage = message
                        self.downloadStates[variant] = .failed(message)
                    }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: variant.downloadURL)
        activeTasks[variant] = task
        downloadDelegates[variant] = delegate
        task.resume()
    }

    func cancelDownload(_ variant: WhisperLocalModelVariant) {
        activeTasks[variant]?.cancel()
        activeTasks[variant] = nil
        progressObservers[variant] = nil
        downloadDelegates[variant] = nil
        downloadStates[variant] = .notDownloaded
    }

    func deleteModel(_ variant: WhisperLocalModelVariant) {
        cancelDownload(variant)
        try? FileManager.default.removeItem(at: Self.modelURL(variant))
        downloadStates[variant] = .notDownloaded
    }
}

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let variant: WhisperLocalModelVariant
    let targetURL: URL
    let onProgress: (Double) -> Void
    let onFinish: (Result<URL, Error>) -> Void

    init(
        variant: WhisperLocalModelVariant,
        targetURL: URL,
        onProgress: @escaping (Double) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.variant = variant
        self.targetURL = targetURL
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? Double(totalBytesExpectedToWrite)
            : Double(variant.estimatedBytes)
        let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / expected))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            try? FileManager.default.removeItem(at: location)
            onFinish(.failure(NSError(domain: "openclicky-whisper", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])))
            return
        }
        do {
            try? FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: location, to: targetURL)
            onFinish(.success(targetURL))
        } catch {
            onFinish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish(.failure(error))
        }
    }
}
