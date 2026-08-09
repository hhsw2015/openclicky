//
//  OpenClickyRouterSettings.swift
//  cursor-buddy
//
//  P1 parity fix (domain 3 MEDIUM): expose the previously-hardcoded
//  router knobs to the user via Settings. Everywhere upstream ships
//  equivalent flags on its intent-classification pipeline
//  (routeTagEnabled, confidenceGate, defaultCompletionMarker).
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//
//  Contract:
//  - `routeTagEnabled` — when false, `RouteDispatcher.dispatch(_:)`
//    ignores the model-emitted `[ROUTE]` JSON tag and always falls
//    back to the context-signal classifier. Default: true.
//  - `confidenceGate` — minimum `route.confidence` required to accept
//    the model's classification. Below this, the dispatcher runs
//    `classifyFallback` and only spawns codex if that fallback yields
//    a non-chat kind. Default: 0.60.
//  - `defaultCompletionMarker` — string the F28 auto-continue
//    observer scans `progress.md` for when the model does not supply
//    an explicit `completion_marker` on a `progressDriven` route.
//    Case-sensitive. Default: "LAST_COMPLETED: DONE".
//

import Foundation
import Combine

@MainActor
public final class OpenClickyRouterSettings: ObservableObject {
    public static let shared = OpenClickyRouterSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let routeTagEnabled = "openclicky.router.routeTagEnabled"
        static let confidenceGate = "openclicky.router.confidenceGate"
        static let defaultCompletionMarker = "openclicky.router.defaultCompletionMarker"
    }

    public static let defaultConfidenceGate: Double = 0.60
    public static let defaultCompletionMarkerFallback = "LAST_COMPLETED: DONE"

    @Published public var routeTagEnabled: Bool {
        didSet { defaults.set(routeTagEnabled, forKey: Keys.routeTagEnabled) }
    }

    @Published public var confidenceGate: Double {
        didSet { defaults.set(confidenceGate, forKey: Keys.confidenceGate) }
    }

    @Published public var defaultCompletionMarker: String {
        didSet { defaults.set(defaultCompletionMarker, forKey: Keys.defaultCompletionMarker) }
    }

    private init() {
        if defaults.object(forKey: Keys.routeTagEnabled) == nil {
            self.routeTagEnabled = true
        } else {
            self.routeTagEnabled = defaults.bool(forKey: Keys.routeTagEnabled)
        }

        // `.double(forKey:)` returns 0.0 when the key is missing OR
        // when the user stored 0.0 explicitly. Treat 0.0 as "never
        // set" — a zero confidence gate would defeat the purpose.
        let storedGate = defaults.double(forKey: Keys.confidenceGate)
        self.confidenceGate = storedGate == 0 ? Self.defaultConfidenceGate : storedGate

        let storedMarker = defaults.string(forKey: Keys.defaultCompletionMarker)
        if let trimmed = storedMarker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            self.defaultCompletionMarker = trimmed
        } else {
            self.defaultCompletionMarker = Self.defaultCompletionMarkerFallback
        }
    }

    /// Returns the marker propagated to codex when the model does
    /// not supply one on a progress-driven route. Never returns an
    /// empty string; falls back to the hard-coded default.
    public var effectiveDefaultCompletionMarker: String {
        let trimmed = defaultCompletionMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultCompletionMarkerFallback : trimmed
    }
}
