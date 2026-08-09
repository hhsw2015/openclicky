//
//  OpenClickyConnectorCredentialStore.swift
//  cursor-buddy
//
//  Phase 7.5 F29 — Keychain-backed credential store for open-connector.
//
//  Everywhere upstream pin: 30e03e9dcfdd4247fd679828ed86e9042f32d809
//  Ports Everywhere's `Connector/JsonCredentialStore.cs` API surface to
//  Swift/macOS Keychain. Semantics parity:
//
//    * Primary key is (service, connectionName) — Everywhere's Phase 12
//      named-connections model (`service:name` composite key).
//    * `connectionName == nil` (or empty after trim) is the "default"
//      connection.
//    * `connectionName` cannot contain ':' — the storage-key separator.
//      This is enforced by callers (`OpenClickyConnectorBridgeTools`)
//      via the same `NormalizeConnection` gate Everywhere uses in
//      `ConnectorTools.NormalizeConnection`.
//    * Values are opaque JSON blobs; the store never inspects contents
//      beyond a few well-known fields (`auth_type`, `display_name`,
//      `account_id`) that surface in `list()`.
//
//  Keychain schema:
//    * Service: "com.jkneen.openclicky.connector.<providerId>"
//    * Account: "<connectionId>"   (empty string means the default)
//    * Value:   JSON-encoded credential blob
//    * Class:   kSecClassGenericPassword
//    * Access:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
//
//  The store is intentionally stateless (no in-memory cache) — Keychain
//  is the source of truth and reads are cheap. Errors bubble up as
//  `OpenClickyConnectorCredentialStoreError` so the bridge can render
//  actionable MCP responses.
//

import Foundation
import Security

/// Errors emitted by the Keychain-backed connector credential store.
enum OpenClickyConnectorCredentialStoreError: Error, LocalizedError {
    case invalidProviderId
    case serialisationFailed(String)
    case keychainStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderId:
            return "providerId must be non-empty and contain no ':' separator"
        case .serialisationFailed(let reason):
            return "connector credential JSON serialisation failed: \(reason)"
        case .keychainStatus(let status, let operation):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "keychain \(operation) failed: \(msg)"
        }
    }
}

/// Summary of a stored credential, mirroring Everywhere's
/// `ConnectorConnectionSummary` (no secret fields — labels only).
public struct OpenClickyConnectorConnectionSummary: Equatable, Sendable {
    public let providerId: String
    public let connectionId: String?    // nil == default
    public let authType: String?
    public let displayName: String?
    public let accountId: String?
}

/// Keychain-backed credential store for the open-connector runtime.
/// All methods are thread-safe (SecItem is thread-safe internally).
enum OpenClickyConnectorCredentialStore {
    /// Prefix that scopes every Keychain item this store owns. Bundle
    /// id lives elsewhere; the connector namespace is a dedicated
    /// suffix so we can list-and-purge on uninstall.
    fileprivate static let servicePrefix = "com.jkneen.openclicky.connector."

    /// Full generic-password class we use for every item.
    fileprivate static let secClass: CFString = kSecClassGenericPassword

    // MARK: - Public API

    /// Save (or overwrite) the credential for `(providerId, connectionId)`.
    /// `credentialJson` is stored as UTF-8 JSON bytes.
    static func save(
        providerId: String,
        connectionId: String?,
        credentialJson: [String: Any]
    ) throws {
        try validate(providerId: providerId)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: credentialJson, options: [.sortedKeys])
        } catch {
            throw OpenClickyConnectorCredentialStoreError.serialisationFailed("\(error)")
        }

        let service = servicePrefix + providerId
        let account = connectionId ?? ""

        // Delete-then-add gives the cleanest overwrite semantics
        // across macOS Keychain quirks (updating attributes on some
        // versions leaves stale accessibility flags).
        let deleteQuery: [String: Any] = [
            kSecClass as String: secClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: secClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OpenClickyConnectorCredentialStoreError.keychainStatus(status, operation: "SecItemAdd")
        }
    }

    /// Load the credential JSON for `(providerId, connectionId)`. Returns
    /// `nil` if the item is not present. Throws on unexpected Keychain
    /// errors (but not on `errSecItemNotFound`).
    static func load(
        providerId: String,
        connectionId: String?
    ) throws -> [String: Any]? {
        try validate(providerId: providerId)
        let service = servicePrefix + providerId
        let account = connectionId ?? ""

        let query: [String: Any] = [
            kSecClass as String: secClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw OpenClickyConnectorCredentialStoreError.keychainStatus(status, operation: "SecItemCopyMatching")
        }
        guard let data = out as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Delete `(providerId, connectionId)`. Idempotent: missing items
    /// return false instead of throwing.
    @discardableResult
    static func delete(
        providerId: String,
        connectionId: String?
    ) throws -> Bool {
        try validate(providerId: providerId)
        let service = servicePrefix + providerId
        let account = connectionId ?? ""

        let query: [String: Any] = [
            kSecClass as String: secClass,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw OpenClickyConnectorCredentialStoreError.keychainStatus(status, operation: "SecItemDelete")
        }
    }

    /// List every stored connection. Values are NOT returned — only
    /// labels + auth types + account ids (surfaces the same data
    /// `connector_list_connections` renders).
    static func listConnections(
        providerId: String? = nil
    ) throws -> [OpenClickyConnectorConnectionSummary] {
        // NOTE: `kSecReturnData: true` together with `kSecMatchLimitAll` is
        // rejected outright with errSecParam (-50) — Security will not stream
        // payloads for an unbounded match. This query used to request both,
        // so listConnections() ALWAYS threw and never returned a single
        // connection. Ask for attributes here; the payload for each hit is
        // fetched individually below.
        var query: [String: Any] = [
            kSecClass as String: secClass,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if let providerId {
            try validate(providerId: providerId)
            query[kSecAttrService as String] = servicePrefix + providerId
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw OpenClickyConnectorCredentialStoreError.keychainStatus(status, operation: "SecItemCopyMatching[all]")
        }
        guard let items = out as? [[String: Any]] else { return [] }

        var results: [OpenClickyConnectorConnectionSummary] = []
        for item in items {
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix(servicePrefix) else { continue }
            let providerId = String(service.dropFirst(servicePrefix.count))
            let rawAccount = item[kSecAttrAccount as String] as? String ?? ""
            let connectionId: String? = rawAccount.isEmpty ? nil : rawAccount

            // Second, bounded lookup per hit — the bulk query above cannot
            // carry payloads. A single-item match may return data.
            var authType: String?
            var displayName: String?
            var accountId: String?
            var dataQuery: [String: Any] = [
                kSecClass as String: secClass,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            dataQuery[kSecAttrAccount as String] = rawAccount
            var payload: CFTypeRef?
            if SecItemCopyMatching(dataQuery as CFDictionary, &payload) == errSecSuccess,
               let data = payload as? Data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                authType = obj["auth_type"] as? String
                displayName = obj["display_name"] as? String
                accountId = obj["account_id"] as? String
            }
            results.append(OpenClickyConnectorConnectionSummary(
                providerId: providerId,
                connectionId: connectionId,
                authType: authType,
                displayName: displayName,
                accountId: accountId
            ))
        }
        // Deterministic order: (providerId, connectionId).
        results.sort { lhs, rhs in
            if lhs.providerId != rhs.providerId { return lhs.providerId < rhs.providerId }
            return (lhs.connectionId ?? "") < (rhs.connectionId ?? "")
        }
        return results
    }

    /// Wipe every credential this store owns. Used by the "Reset
    /// connector state" Settings action.
    static func deleteAll() throws {
        // We can't SecItemDelete by prefix; enumerate + delete.
        let summaries = try listConnections()
        for s in summaries {
            _ = try? delete(providerId: s.providerId, connectionId: s.connectionId)
        }
    }

    // MARK: - Validation

    private static func validate(providerId: String) throws {
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(":") {
            throw OpenClickyConnectorCredentialStoreError.invalidProviderId
        }
    }

    /// Applies the same rule as Everywhere's
    /// `ConnectorTools.NormalizeConnection` — whitespace-only inputs
    /// collapse to nil (default connection), ':' is rejected as
    /// reserved. Exposed here so callers get the identical shape
    /// without duplicating the rule.
    static func normalizeConnection(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(":") {
            throw OpenClickyConnectorCredentialStoreError.invalidProviderId
        }
        return trimmed
    }
}
