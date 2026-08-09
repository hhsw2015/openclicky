//
//  HotPathState.swift
//  cursor-buddy
//
//  Narrow ObservableObject that mirrors the high-frequency @Published
//  fields on CompanionManager. Views that only care about cursor
//  overlay / voice-state signal (BlueCursorView, notch cursor bubble,
//  external proxy cursor) observe this instead of the god-object so
//  they don't re-diff on every unrelated CompanionManager mutation.
//
//  The existing `CursorOverlayState` type already isolates exactly
//  these fields (see CompanionManager.swift). Rather than duplicate
//  the storage, `HotPathState` is a typealias for that class so
//  either name works at the call site.
//

import AppKit
import Foundation
import OpenClickyCore

/// Alias so new call sites can adopt the more descriptive
/// `HotPathState` name without a rename churn on `CursorOverlayState`.
/// Both names point at the same @MainActor ObservableObject whose
/// @Published fields already back BlueCursorView's fast-path
/// observations.
typealias HotPathState = CursorOverlayState
