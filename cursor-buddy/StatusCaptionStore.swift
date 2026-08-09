//
//  StatusCaptionStore.swift
//  cursor-buddy
//
//  Narrow ObservableObject for status-caption / home-chat streaming
//  signal. Kept separate from HotPathState so per-token streaming
//  updates to `homeChatEntries` don't invalidate BlueCursorView's
//  cursor flight animation, and vice versa.
//
//  CompanionManager keeps the original @Published fields (public API
//  preserved); this class is written to via `didSet` mirrors.
//

import Foundation
import Combine

@MainActor
final class StatusCaptionStore: ObservableObject {
    /// Mirror of `CompanionManager.heyClickyStatusCaption`.
    @Published var heyClickyStatusCaption: String?

    /// Mirror of `CompanionManager.heyClickyStatusSeverity`.
    @Published var heyClickyStatusSeverity: String?

    /// Mirror of `CompanionManager.homeChatEntries`.
    @Published var homeChatEntries: [CodexTranscriptEntry] = []
}
