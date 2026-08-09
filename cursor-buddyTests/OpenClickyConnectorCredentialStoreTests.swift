// OpenClickyConnectorCredentialStoreTests.swift
// cursor-buddyTests
//
// Phase 7.5 F29 — round-trip tests for the Keychain-backed connector
// credential store. Uses a unique providerId prefix per test so
// parallel runs (or repeated runs after crashes) can't collide.

import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyConnectorCredentialStoreTests {

    private func uniqueProviderId(_ suffix: String) -> String {
        "openclicky_test_\(UUID().uuidString.prefix(8).lowercased())_\(suffix)"
    }

    @Test func normalizeConnection_rejectsColon() throws {
        #expect((try? OpenClickyConnectorCredentialStore.normalizeConnection("work:prod")) == nil)
    }

    @Test func normalizeConnection_collapsesWhitespace() throws {
        #expect(try OpenClickyConnectorCredentialStore.normalizeConnection(nil) == nil)
        #expect(try OpenClickyConnectorCredentialStore.normalizeConnection("") == nil)
        #expect(try OpenClickyConnectorCredentialStore.normalizeConnection("   ") == nil)
        #expect(try OpenClickyConnectorCredentialStore.normalizeConnection("  work  ") == "work")
    }

    @Test func saveLoadDelete_roundTrip() throws {
        let providerId = uniqueProviderId("round_trip")
        defer {
            _ = try? OpenClickyConnectorCredentialStore.delete(providerId: providerId, connectionId: nil)
        }
        let payload: [String: Any] = [
            "auth_type": "api_key",
            "api_key": "ghp_secret_value_do_not_leak",
            "display_name": "Test PAT"
        ]
        try OpenClickyConnectorCredentialStore.save(
            providerId: providerId,
            connectionId: nil,
            credentialJson: payload
        )
        let loaded = try OpenClickyConnectorCredentialStore.load(providerId: providerId, connectionId: nil)
        #expect(loaded != nil)
        #expect((loaded?["auth_type"] as? String) == "api_key")
        #expect((loaded?["api_key"] as? String) == "ghp_secret_value_do_not_leak")
        #expect((loaded?["display_name"] as? String) == "Test PAT")

        let removed = try OpenClickyConnectorCredentialStore.delete(providerId: providerId, connectionId: nil)
        #expect(removed == true)
        // Delete again is idempotent.
        let removedAgain = try OpenClickyConnectorCredentialStore.delete(providerId: providerId, connectionId: nil)
        #expect(removedAgain == false)
        let afterDelete = try OpenClickyConnectorCredentialStore.load(providerId: providerId, connectionId: nil)
        #expect(afterDelete == nil)
    }

    @Test func multipleNamedConnections_isolatedByAccount() throws {
        let providerId = uniqueProviderId("named")
        defer {
            _ = try? OpenClickyConnectorCredentialStore.delete(providerId: providerId, connectionId: nil)
            _ = try? OpenClickyConnectorCredentialStore.delete(providerId: providerId, connectionId: "work")
        }
        try OpenClickyConnectorCredentialStore.save(providerId: providerId, connectionId: nil,
                                                     credentialJson: ["auth_type": "api_key", "api_key": "default_key"])
        try OpenClickyConnectorCredentialStore.save(providerId: providerId, connectionId: "work",
                                                     credentialJson: ["auth_type": "api_key", "api_key": "work_key"])

        let def = try OpenClickyConnectorCredentialStore.load(providerId: providerId, connectionId: nil)
        let work = try OpenClickyConnectorCredentialStore.load(providerId: providerId, connectionId: "work")
        #expect((def?["api_key"] as? String) == "default_key")
        #expect((work?["api_key"] as? String) == "work_key")

        let summaries = try OpenClickyConnectorCredentialStore.listConnections(providerId: providerId)
        #expect(summaries.count == 2)
        #expect(summaries.contains { $0.connectionId == nil })
        #expect(summaries.contains { $0.connectionId == "work" })
    }

    @Test func save_rejectsInvalidProviderIds() throws {
        #expect(throws: OpenClickyConnectorCredentialStoreError.self) {
            try OpenClickyConnectorCredentialStore.save(providerId: "",
                                                        connectionId: nil,
                                                        credentialJson: [:])
        }
        #expect(throws: OpenClickyConnectorCredentialStoreError.self) {
            try OpenClickyConnectorCredentialStore.save(providerId: "has:colon",
                                                        connectionId: nil,
                                                        credentialJson: [:])
        }
    }
}
