//
//  CGEventTapHotkeyRow.swift
//  cursor-buddy
//
//  Settings row that binds a shortcut to one
//  `OpenClickyContextHotkeyAction` via the App's existing CGEventTap
//  hotkey system. Click to arm; press a combo; release records it.
//

import SwiftUI
import AppKit

struct CGEventTapHotkeyRow: View {
    let label: String
    let action: OpenClickyContextHotkeyAction

    @ObservedObject private var settings = OpenClickyContextAwarenessSettings.shared
    @State private var armed: Bool = false

    var body: some View {
        HStack {
            Text(label).frame(width: 220, alignment: .leading)
            Button {
                armed.toggle()
            } label: {
                HStack {
                    Text(displayText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(armed ? .accentColor : .primary)
                    Spacer()
                    if armed {
                        Text("Press…").foregroundColor(.secondary).font(.caption)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(minWidth: 180)
                .background(RoundedRectangle(cornerRadius: 4)
                    .stroke(armed ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .background(HotkeyKeyCatcher(armed: $armed, onCapture: apply))

            Button {
                settings.setBinding(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear")
        }
    }

    private var displayText: String {
        let binding = settings.activeBindings.first(where: { $0.0 == action })?.1
        guard let b = binding, !b.isEmpty else { return "Unbound" }
        return format(keyCode: b.keyCode, modifiers: b.normalisedModifiers)
    }

    private func apply(keyCode: UInt16, flags: CGEventFlags) {
        let masked = flags.rawValue & OpenClickyHotkeyBinding.significantModifierMask
        let binding = OpenClickyHotkeyBinding(
            keyCode: keyCode, modifiers: masked, enabled: true)
        settings.setBinding(binding, for: action)
    }

    private func format(keyCode: UInt16, modifiers: UInt64) -> String {
        var s = ""
        if modifiers & CGEventFlags.maskControl.rawValue   != 0 { s += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue     != 0 { s += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue   != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt16) -> String {
        // Minimal keycode → glyph map. Users mostly bind letters + a few
        // arrows / space — the rest we render as `Key<n>`.
        switch keyCode {
        case 0:  return "A"; case 1:  return "S"; case 2:  return "D"
        case 3:  return "F"; case 4:  return "H"; case 5:  return "G"
        case 6:  return "Z"; case 7:  return "X"; case 8:  return "C"
        case 9:  return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"
        case 16: return "Y"; case 17: return "T"; case 31: return "O"
        case 32: return "U"; case 34: return "I"; case 35: return "P"
        case 37: return "L"; case 38: return "J"; case 40: return "K"
        case 45: return "N"; case 46: return "M"
        case 49: return "Space"
        case 36: return "↩︎"; case 48: return "⇥"; case 51: return "⌫"; case 53: return "⎋"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}

/// Invisible NSView that installs a local key monitor while `armed`.
/// Captures the first modifier+key event and clears armed.
struct HotkeyKeyCatcher: NSViewRepresentable {
    @Binding var armed: Bool
    let onCapture: (UInt16, CGEventFlags) -> Void

    func makeNSView(context: Context) -> _KeyCatcherView {
        _KeyCatcherView(onCapture: { code, flags in
            self.onCapture(code, flags)
            self.armed = false
        })
    }

    func updateNSView(_ nsView: _KeyCatcherView, context: Context) {
        nsView.armed = armed
    }

    final class _KeyCatcherView: NSView {
        let onCapture: (UInt16, CGEventFlags) -> Void
        private var monitor: Any?
        var armed: Bool = false {
            didSet {
                if armed && monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self, self.armed else { return event }
                        let code = UInt16(event.keyCode)
                        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                        // Only accept if at least one modifier is held.
                        let mask = OpenClickyHotkeyBinding.significantModifierMask
                        guard (flags.rawValue & mask) != 0 else { return event }
                        self.onCapture(code, flags)
                        return nil
                    }
                } else if !armed, let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
            }
        }

        init(onCapture: @escaping (UInt16, CGEventFlags) -> Void) {
            self.onCapture = onCapture
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
