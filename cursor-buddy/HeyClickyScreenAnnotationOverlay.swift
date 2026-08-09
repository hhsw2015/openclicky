//
//  HeyClickyScreenAnnotationOverlay.swift
//  cursor-buddy
//
//  ScreenAnnotationManager + Overlay port from clicky-mac
//  (which itself parity-reversed the HeyClicky binary). Draws
//  hover circles, highlight rects, arrows, curves, polygons over
//  the user's screen from walkthrough.beats.
//
//  Feeds:
//   - HeyClickyChatToolCallClient parses walkthrough beats and
//     calls ScreenAnnotationState.shared.add(...) for
//     hover/highlight/arrow/curve/shape kinds.
//   - OverlayWindow mounts ScreenAnnotationLayer inside its ZStack
//     so entries render on top of every screen.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import OpenClickyUI

enum HeyClickyAnnotationShape: Sendable {
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    case curve(points: [CGPoint])
    case polygon(points: [CGPoint])
    case highlight(rect: CGRect)
}

/// Global observable state for annotations. TTL=8s matches demo.
/// One entry per beat; multiple entries can be active concurrently.
@MainActor
final class HeyClickyAnnotationState: ObservableObject {
    static let shared = HeyClickyAnnotationState()

    struct Entry: Identifiable {
        let id = UUID()
        let shape: HeyClickyAnnotationShape
        let screenFrame: CGRect
        let caption: String?
        let insertedAt: Date
    }

    @Published private(set) var entries: [Entry] = []
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    func add(
        _ shape: HeyClickyAnnotationShape,
        on screen: NSScreen,
        caption: String? = nil,
        ttl: TimeInterval = 8
    ) {
        let entry = Entry(
            shape: shape,
            screenFrame: screen.frame,
            caption: caption,
            insertedAt: Date()
        )
        entries.append(entry)
        expiryTasks[entry.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.entries.removeAll { $0.id == entry.id }
            self.expiryTasks.removeValue(forKey: entry.id)
        }
    }

    func clearAll() {
        for (_, task) in expiryTasks { task.cancel() }
        expiryTasks.removeAll()
        entries.removeAll()
    }
}

/// SwiftUI overlay layer that renders every annotation matching a
/// specific screen. Mount inside OverlayWindow's ZStack.
struct HeyClickyScreenAnnotationLayer: View {
    let screenFrame: CGRect
    @ObservedObject var state = HeyClickyAnnotationState.shared

    var body: some View {
        ZStack {
            ForEach(entries) { entry in
                shapeView(for: entry, in: entry.screenFrame)
            }
        }
        .allowsHitTesting(false)
    }

    private var entries: [HeyClickyAnnotationState.Entry] {
        state.entries.filter { $0.screenFrame == screenFrame }
    }

    private var accent: Color { DS.Colors.accent }

    @ViewBuilder
    private func shapeView(for entry: HeyClickyAnnotationState.Entry, in frame: CGRect) -> some View {
        let shape = entry.shape
        switch shape {
        case .line(let from, let to):
            HeyClickyAnnotationPath(
                points: [from, to],
                closed: false,
                arrow: false,
                color: accent
            )
        case .arrow(let from, let to):
            HeyClickyAnnotationPath(
                points: [from, to],
                closed: false,
                arrow: true,
                color: accent
            )
        case .circle(let center, let radius):
            Circle()
                .stroke(accent, lineWidth: 4)
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
        case .curve(let pts):
            HeyClickyAnnotationPath(
                points: pts,
                closed: false,
                arrow: false,
                color: accent
            )
        case .polygon(let pts):
            HeyClickyAnnotationPath(
                points: pts,
                closed: true,
                arrow: false,
                color: accent
            )
        case .highlight(let rect):
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(accent, lineWidth: 3)
                    )
                if let caption = entry.caption, !caption.isEmpty {
                    Text(LocalizedStringKey(caption))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent))
                        .offset(x: 0, y: -22)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

private struct HeyClickyAnnotationPath: View {
    let points: [CGPoint]
    let closed: Bool
    let arrow: Bool
    let color: Color

    var body: some View {
        Canvas { context, _ in
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for pt in points.dropFirst() { path.addLine(to: pt) }
            if closed { path.closeSubpath() }
            context.stroke(path, with: .color(color), lineWidth: 4)
            if arrow, points.count >= 2 {
                let end = points.last!
                let prev = points[points.count - 2]
                let dx = end.x - prev.x
                let dy = end.y - prev.y
                let angle = atan2(dy, dx)
                let arrowLen: CGFloat = 14
                let a1 = CGPoint(
                    x: end.x - arrowLen * cos(angle - .pi / 6),
                    y: end.y - arrowLen * sin(angle - .pi / 6)
                )
                let a2 = CGPoint(
                    x: end.x - arrowLen * cos(angle + .pi / 6),
                    y: end.y - arrowLen * sin(angle + .pi / 6)
                )
                var arrowPath = Path()
                arrowPath.move(to: end)
                arrowPath.addLine(to: a1)
                arrowPath.move(to: end)
                arrowPath.addLine(to: a2)
                context.stroke(arrowPath, with: .color(color), lineWidth: 4)
            }
        }
    }
}
