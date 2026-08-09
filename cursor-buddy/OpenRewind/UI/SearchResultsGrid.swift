//
//  SearchResultsGrid.swift
//  cursor-buddy
//
//  Top-level Screen History search view. Search field at top;
//  grid of matching frames below. Clicking a card opens
//  FramePreviewCard.
//

import SwiftUI

public struct SearchResultsGrid: View {

    @State private var query: String = ""
    @State private var results: [SearchHit] = []
    @State private var isSearching: Bool = false
    @State private var selectedFrame: Int64?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if OpenRewindBridge.shared == nil {
                emptyState(message:
                    "Screen History is not enabled. Turn it on in Settings → Screen History.")
            } else if isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                emptyState(message: query.isEmpty
                    ? "Type in the search bar to look through your screen history."
                    : "No matches for \"\(query)\".")
            } else {
                grid
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .sheet(item: Binding(
            get: { selectedFrame.map { FrameID(id: $0) } },
            set: { selectedFrame = $0?.id }
        )) { wrapped in
            FramePreviewCard(frameID: wrapped.id, onDismiss: { selectedFrame = nil })
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search your screen memory…", text: $query, onCommit: runSearch)
                .textFieldStyle(.plain)
                .font(.title3)
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
    }

    private var grid: some View {
        let cols = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(results, id: \.id) { hit in
                    ResultCard(hit: hit) { selectedFrame = hit.id }
                }
            }
            .padding(12)
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let reader = OpenRewindBridge.shared?.reader else {
            results = []
            return
        }
        isSearching = true
        Task {
            let hits: [SearchHit]
            do {
                let raw = try reader.searchForAI(trimmed, limit: 40, thumbnailSize: 320)
                hits = raw.map { pair in
                    SearchHit(
                        id: pair.hit.entry.id,
                        app: pair.hit.entry.bundleID,
                        window: pair.hit.entry.windowName,
                        timestamp: pair.hit.entry.createdAt,
                        snippet: pair.hit.snippet)
                }
            } catch {
                hits = []
            }
            await MainActor.run {
                self.results = hits
                self.isSearching = false
            }
        }
    }

    fileprivate struct FrameID: Identifiable { let id: Int64 }

    fileprivate struct SearchHit: Identifiable {
        let id: Int64
        let app: String?
        let window: String?
        let timestamp: Date
        let snippet: String
    }

    fileprivate struct ResultCard: View {
        let hit: SearchHit
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hit.app ?? "?")
                        .font(.caption).bold()
                    Text(hit.window ?? "").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    Text(hit.snippet)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(4)
                    Text(hit.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}
