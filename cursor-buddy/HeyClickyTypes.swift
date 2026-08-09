//
//  HeyClickyTypes.swift
//  cursor-buddy
//
//  Shared HeyClicky Free Tier type declarations. See
//  docs/HEYCLICKY_FREE_TIER_INTEGRATION.md §4.
//

import Foundation

// MARK: - Notifications
//
// HeyClicky Free posts its own set of notification names. Kept under
// this file so contributors don't have to scan MenuBarPanelManager to
// discover them. Names use the `heyClicky*` prefix (not `clickyHeyClicky*`
// to avoid the double-brand stutter).
//
// Note: earlier code emitted `clickyHeyClicky*` — those names are
// preserved in MenuBarPanelManager.swift for a transition window and
// alias to the same underlying `Notification.Name` strings, so
// existing observers keep working while new call sites converge on
// the shorter form.

public extension Notification.Name {
    static let heyClickyResetCompleted = Notification.Name("clickyHeyClickyResetCompleted")
    static let heyClickyCredentialsRefreshed = Notification.Name("clickyHeyClickyCredentialsRefreshed")
    /// Fires when the codex app-server child process exits (crash or
    /// signal). Consumers should clear activeThreadID + lease so the
    /// next prompt spawns a fresh codex and re-runs preamble.
    static let heyClickyCodexProcessExited = Notification.Name("clickyHeyClickyCodexProcessExited")
    /// Fires on macOS wake-from-sleep so long-lived connections can
    /// force-reconnect without waiting for the next timer tick.
    static let heyClickyDidWakeFromSleep = Notification.Name("clickyHeyClickyDidWakeFromSleep")
    /// Emitted by CodexAgentSession when an interrupted turn should be
    /// silently resumed via "请继续". Consumers in CompanionManager
    /// call submitAgentPrompt with the resume string.
    static let heyClickyRequestAutoContinueReplay = Notification.Name("clickyHeyClickyRequestAutoContinueReplay")
    /// Emitted by `HeyClickySessionTokenClient` after a proactive
    /// codex-ephemeral refresh (every ~3.5h). CodexAgentSession
    /// observes this to push the new bearer into the live codex
    /// process via `account/login/start` — soft rekey, no restart,
    /// no interruption to an in-flight turn.
    static let heyClickyCodexEphemeralRefreshed = Notification.Name("clickyHeyClickyCodexEphemeralRefreshed")
    /// Fires after `HeyClickyPlanClient.refresh` successfully updates
    /// `latest`. Consumers should read `latest` instead of making their
    /// own /me/plan call, so free-tier accounts don't get double-polled.
    static let heyClickyPlanSnapshotChanged = Notification.Name("heyClickyPlanSnapshotChanged")
    static let heyClickyGuidedClickFollowUp = Notification.Name("clickyHeyClickyGuidedClickFollowUp")
    static let heyClickySessionExpired = Notification.Name("clickyHeyClickySessionExpired")
    /// User-facing status announcements (quota reached, refreshing, ready).
    /// UI layer subscribes and shows badges / captions.
    static let heyClickyStatusChanged = Notification.Name("heyClickyStatusChanged")
    /// Fired when a [TARGET:x,y,r] beat is armed; CompanionManager
    /// forwards the destination to `OverlayWindow.flyTo` so the buddy
    /// cursor lands on the ring instead of the ring appearing alone.
    static let heyClickyTargetArmed = Notification.Name("heyClickyTargetArmed")
}

/// User-facing HeyClicky Free status. Broadcast on
/// `.heyClickyStatusChanged`; UI can show a badge / caption for each.
public enum HeyClickyStatus: String, Sendable {
    /// Everything nominal — the assistant is chatting through the
    /// free tier and the local session is healthy.
    case ready
    /// Free quota was reached; a background reset was started.
    /// Show a spinner / "refreshing" caption.
    case refreshing
    /// Free quota was reached and no reset path is available (e.g.
    /// Chrome extension not installed). Show an actionable hint.
    case needsExtension
    /// The session (access + refresh) was invalidated by the server.
    /// UI should show "Sign in again" and stop offering HeyClicky
    /// entries until the user does.
    case signInRequired
    /// A transient network / upstream error — expect auto-retry.
    case transportError

    /// Short human-readable caption suitable for a bubble or notch.
    public var userMessage: String {
        switch self {
        case .ready:
            return ""
        case .refreshing:
            return "Free quota reached, refreshing your account…"
        case .needsExtension:
            return "Install the OpenClicky browser extension to auto-refresh HeyClicky Free."
        case .signInRequired:
            return "HeyClicky Free session expired. Sign in again in Settings."
        case .transportError:
            return "HeyClicky Free connection issue — retrying."
        }
    }
}

public extension NotificationCenter {
    /// Convenience broadcaster so call sites don't have to repeat the
    /// userInfo shape. Always emitted on the main queue.
    func postHeyClickyStatus(_ status: HeyClickyStatus, extra: [String: Any] = [:]) {
        var info: [String: Any] = ["status": status.rawValue, "message": status.userMessage]
        for (k, v) in extra { info[k] = v }
        DispatchQueue.main.async {
            self.post(name: .heyClickyStatusChanged, object: nil, userInfo: info)
        }
    }
}

public enum HeyClickyLaunchSource: String, Sendable, Codable {
    case voice
    case text
    case codex
}

public enum HeyClickyLane: String, Sendable {
    case chat
    case stt
    case agent
}

public enum HeyClickyProxyError: Error, Sendable {
    case unauthorized
    case quotaExhausted
    case upstreamUnavailable
    case transportError(Error)
    case malformedResponse
    /// Lease is paused because the turn is about to exceed HeyClicky's
    /// per-turn dollar-cost boundary. HeyClicky.app auto-approves this
    /// by POST /agent/turn-lease/{id}/continue — see
    /// `HeyClickyTurnLeaseClient.autoContinue`.
    case leaseNeedsContinue(leaseID: String, reason: String)
}

public enum HeyClickyConfigError: Error, LocalizedError {
    case proxyBaseURLMissing
    case oauthURLMissing

    public var errorDescription: String? {
        switch self {
        case .proxyBaseURLMissing:
            return "HeyClicky Free proxy base URL is not configured."
        case .oauthURLMissing:
            return "HeyClicky Free OAuth authorize URL is not configured."
        }
    }
}

public struct HeyClickyTurnLease: Sendable {
    public let leaseID: String
    public let turnID: String
    public let creditsUsed: Int
    public let includedCredits: Int
    /// Server-side lease expiry deadline. Used to decide whether a
    /// persisted lease is still steerable after an app restart. Nil
    /// when the server omits it.
    public let expiresAt: Date?

    public init(leaseID: String,
                turnID: String,
                creditsUsed: Int = 0,
                includedCredits: Int = 0,
                expiresAt: Date? = nil) {
        self.leaseID = leaseID
        self.turnID = turnID
        self.creditsUsed = creditsUsed
        self.includedCredits = includedCredits
        self.expiresAt = expiresAt
    }
}

public enum HeyClickyLeaseStatus: String, Sendable, Codable {
    case completed
    case cancelled
    case failed
}

/// Erased JSON primitive. Openclicky ships no AnyCodable; this is the
/// smallest one we need for widget payload passthrough.
public enum OpenClickyJSONValue: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([OpenClickyJSONValue])
    case object([String: OpenClickyJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([OpenClickyJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: OpenClickyJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct PointCoordinate: Sendable, Codable {
    public let x: Double
    public let y: Double
    public let label: String
    public let screen: Int?
}

/// Widget envelope. Demo/IDA use `type` as the discriminator key, not
/// `kind`, and payload is the rest of the object flattened alongside
/// (not nested under a `payload` key). We keep a typed struct here with
/// custom decoding to preserve that shape.
public struct WidgetPayload: Sendable, Codable {
    public let type: String?
    public let payload: [String: OpenClickyJSONValue]

    public init(type: String?, payload: [String: OpenClickyJSONValue]) {
        self.type = type
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var typeValue: String?
        var remaining: [String: OpenClickyJSONValue] = [:]
        for key in container.allKeys {
            if key.stringValue == "type" {
                typeValue = try? container.decode(String.self, forKey: key)
            } else {
                remaining[key.stringValue] = try container.decode(OpenClickyJSONValue.self, forKey: key)
            }
        }
        self.type = typeValue
        self.payload = remaining
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        if let type {
            try container.encode(type, forKey: DynamicKey(stringValue: "type")!)
        }
        for (key, value) in payload {
            try container.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
}

public struct WalkthroughBeat: Sendable, Codable {
    /// Server-side kind values (verified with server model dev):
    ///   point / highlight / shape / target / hover
    /// Older openclicky code also accepts `arrow`/`curve`/`type` for
    /// backward compat but they're really `shape` with shapeKind.
    public let kind: String
    public let label: String?
    public let speech: String?
    public let x: Double?
    public let y: Double?
    /// Radius for target/hover.
    public let r: Double?
    public let width: Double?
    public let height: Double?
    public let text: String?
    public let screen: Int?
    public let fromX: Double?
    public let fromY: Double?
    public let toX: Double?
    public let toY: Double?
    public let points: [[Double]]?
    /// When kind == "shape", shapeKind selects the geometry variant:
    /// line | arrow | circle | curve | polygon.
    public let shapeKind: String?
    /// Only meaningful for shape.circle / shape.polygon.
    public let filled: Bool?
}

public struct Walkthrough: Sendable, Codable {
    public let language: String?
    public let beats: [WalkthroughBeat]
}

/// Internal to HeyClickyChatToolCallClient decode path.
/// Interruption is signalled by "[interrupted: …]" text suffixes in
/// the `text` field — no separate enum.
/// Server-verified typing payload:
/// `{"x": Int, "y": Int, "text": String, "label": String}`
/// where x/y is the pixel coordinate (screenshot space) of the input
/// field the model wants us to click before typing. Older shape was
/// a bare string — accept both via a custom decoder in the chat client.
public struct TypingInstruction: Sendable {
    public let text: String
    public let x: Double?
    public let y: Double?
    public let label: String?
    public let screen: Int?
    public init(text: String, x: Double? = nil, y: Double? = nil,
                label: String? = nil, screen: Int? = nil) {
        self.text = text
        self.x = x
        self.y = y
        self.label = label
        self.screen = screen
    }
}

public struct HigherModelResponse: Sendable {
    public let text: String
    public let clipboardText: String?
    public let typing: TypingInstruction?
    public let point: PointCoordinate?
    public let widgets: [WidgetPayload]
    public let walkthrough: Walkthrough?
    /// IDA-verified sibling of `text` in the /chat-tool-call response
    /// struct (0x1012ba88a, colocated with walkthrough/typing/clipboardText).
    /// Short human-readable caption to display near screen annotations
    /// (highlight rect, arrow, etc.).
    public let annotationText: String?

    public init(
        text: String,
        clipboardText: String? = nil,
        typing: TypingInstruction? = nil,
        point: PointCoordinate? = nil,
        widgets: [WidgetPayload] = [],
        walkthrough: Walkthrough? = nil,
        annotationText: String? = nil
    ) {
        self.text = text
        self.clipboardText = clipboardText
        self.typing = typing
        self.point = point
        self.widgets = widgets
        self.walkthrough = walkthrough
        self.annotationText = annotationText
    }
}
