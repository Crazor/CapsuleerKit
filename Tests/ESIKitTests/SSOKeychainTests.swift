import Foundation
import Testing
import CapsuleerCore
@testable import ESIKit

/// Touches the real login keychain, so it only runs with `CAPSULEER_KEYCHAIN_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CAPSULEER_KEYCHAIN_TESTS"] == "1"), .serialized)
struct SSOKeychainTests {
    @Test func storesLoadsUpdatesAndDeletes() async throws {
        let store = KeychainTokenStore(service: "CapsuleerKit.tests.\(UUID().uuidString)")
        let one = StoredCredential(character: AuthorizedCharacter(id: 1, name: "One", ownerHash: "o1", scopes: [.locationRead]),
                                   refreshToken: "test-refresh-1")
        var two = StoredCredential(character: AuthorizedCharacter(id: 2, name: "Two", ownerHash: "o2", scopes: []),
                                   refreshToken: "test-refresh-2")
        do {
            #expect(try await store.load(characterID: 1) == nil)
            #expect(try await store.loadAll().isEmpty)
            try await store.save(one)
            try await store.save(two)
            #expect(try await store.load(characterID: 1) == one)
            #expect(try await store.loadAll() == [one, two])

            two.refreshToken = ""
            two.character.state = .needsReauthentication(reason: "invalid_grant")
            try await store.save(two)
            #expect(try await store.load(characterID: 2) == two)

            try await store.delete(characterID: 1)
            try await store.delete(characterID: 1)
            #expect(try await store.loadAll() == [two])
        } catch {
            Issue.record(error)
        }
        try? await store.delete(characterID: 1)
        try? await store.delete(characterID: 2)
    }
}
