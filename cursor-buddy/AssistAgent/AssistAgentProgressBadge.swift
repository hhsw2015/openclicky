//
//  AssistAgentProgressBadge.swift
//  cursor-buddy
//
//  Compact SwiftUI row that renders live assist-agent progress —
//  one line per running sub-agent, with round count, last tool, and
//  status glyph. Renders NOTHING when no agent is running, so it
//  disappears cleanly the moment the loop finishes.
//

import SwiftUI

public struct AssistAgentProgressBadge: View {
    @ObservedObject var registry = AssistAgentRegistry.shared

    public init() {}

    /// Entries to show:
    ///   - all `.running` (main use case)
    ///   - `.error` entries within the last 15s so the user sees WHY
    ///     the loop stopped (content filter / no-response / cap hit)
    ///     instead of the badge silently vanishing.
    private var visible: [AssistAgentRegistry.Entry] {
        let cutoff = Date().addingTimeInterval(-15)
        return registry.agents.filter { entry in
            entry.status == .running
                || (entry.status == .error && entry.startedAt > cutoff)
        }
    }

    public var body: some View {
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visible) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.status == .error
                                          ? "exclamationmark.triangle.fill"
                                          : "sparkles")
                            .font(.system(size: 12))
                            .foregroundColor(entry.status == .error ? .orange : .accentColor)
                        if entry.status == .running {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.status == .running
                                 ? "助理探索中 · 第 \(entry.round) 步"
                                 : "助理已停下")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if !entry.lastMessage.isEmpty {
                                Text(entry.lastMessage)
                                    .font(.system(size: 10))
                                    .foregroundColor(entry.status == .error
                                                     ? .orange
                                                     : .secondary)
                                    .lineLimit(2)  // filter reason can wrap
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 4)
                        if entry.toolsRun > 0 {
                            Text("\(entry.toolsRun) 次调用")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(entry.status == .error
                                  ? Color.orange.opacity(0.10)
                                  : Color.primary.opacity(0.06))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.2), value: visible.count)
        }
    }
}
