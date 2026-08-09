//
//  FramePreviewCard.swift
//  cursor-buddy
//
//  Single-frame detail view. Shown when the assist agent cites a
//  historical frame and the user taps "view screen at this moment".
//
//  Uses OpenClicky's response-card visual language: rounded corners,
//  subtle shadow, glass-adjacent tint — visually cohesive with other
//  panels rather than rewind Browser's stock macOS sheet.
//

import SwiftUI
import AppKit

public struct FramePreviewCard: View {

    let frameID: Int64
    let onDismiss: () -> Void

    @State private var thumbnail: NSImage?
    @State private var metadata: FrameMetadata?
    @State private var ocrText: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    public init(frameID: Int64, onDismiss: @escaping () -> Void = {}) {
        self.frameID = frameID
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBar
            content
                .frame(minHeight: 320)
        }
        .padding(16)
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task { await load() }
    }

    private var titleBar: some View {
        HStack {
            if let meta = metadata {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.app ?? "Unknown app")
                        .font(.headline)
                    if let win = meta.window, !win.isEmpty {
                        Text(win).font(.caption).foregroundColor(.secondary)
                    }
                    Text(meta.timestampFormatted).font(.caption2).foregroundColor(.secondary)
                }
            } else {
                Text("Loading frame \(frameID)…").font(.headline)
            }
            Spacer()
            Button("Close", action: onDismiss)
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text(error).font(.body).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                ocrPane
            }
        }
    }

    private var ocrPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen text").font(.caption).foregroundColor(.secondary)
                Text(ocrText.isEmpty ? "No OCR text captured for this frame." : ocrText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard let reader = await MainActor.run(body: { OpenRewindBridge.shared?.reader }) else {
            loadError = "Screen History is not enabled."
            isLoading = false
            return
        }
        do {
            let entries = try reader.recentEntries(limit: 20000)
            guard let entry = entries.first(where: { $0.id == frameID }) else {
                loadError = "Frame \(frameID) not found."
                isLoading = false
                return
            }
            let (text, _) = try reader.ocr(for: entry.id)
            let thumb = try? reader.thumbnail(for: entry, maxDim: 640)
            metadata = FrameMetadata(from: entry)
            ocrText = text
            thumbnail = thumb
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

public struct FrameMetadata: Sendable {
    public var app: String?
    public var window: String?
    public var url: String?
    public var timestamp: Date

    public var timestampFormatted: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: timestamp)
    }

    init(from entry: OpenRewindEntry) {
        self.app = entry.bundleID
        self.window = entry.windowName
        self.url = entry.browserUrl
        self.timestamp = entry.createdAt
    }
}
