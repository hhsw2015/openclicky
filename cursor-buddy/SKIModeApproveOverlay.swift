//
//  SKIModeApproveOverlay.swift
//  cursor-buddy
//
//  Rendered inside the OpenClicky notch panel while
//  `openclicky.ski.approveBeforeSend` is on. Shows the current pending
//  utterance and Send / Cancel buttons that call the CompanionManager
//  API directly.
//

import SwiftUI

struct SKIModeApproveOverlay: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage("openclicky.ski.approveBeforeSend") private var approveOn: Bool = false

    var body: some View {
        if approveOn, let text = companionManager.pendingSKIUtteranceText, !text.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                Text(LocalizedStringKey(text))
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    companionManager.confirmPendingSKIUtterance()
                } label: {
                    Text("Send")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                Button {
                    companionManager.cancelPendingSKIUtterance()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }
}
