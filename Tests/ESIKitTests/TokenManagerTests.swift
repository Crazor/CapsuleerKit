import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

private let characterID: Int64 = 2112345678

/// A store that can fail saves, to show the new access token is never handed out unsaved.
private actor FlakyStore: TokenStore {
    let inner = InMemoryTokenStore()
    var failSaves = false
    func setFailSaves(_ value: Bool) { failSaves = value }
    func load(characterID: Int64) async throws -> StoredCredential? { try await inner.load(characterID: characterID) }
    func loadAll() async throws -> [StoredCredential] { try await inner.loadAll() }
    func save(_ credential: StoredCredential) async throws {
        if failSaves { throw CapsuleerError(.storage, message: "disk full") }
        try await inner.save(credential)
    }
    func delete(characterID: Int64) async throws { try await inner.delete(characterID: characterID) }
}

private struct Harness {
    let server = MockLoginServer()
    let store: any TokenStore
    let events = SSOEventLog()
    let logs = SSOLogRecorder()
    let cache = MemoryCacheStore()
    let manager: TokenManager

    init(store: any TokenStore = InMemoryTokenStore(), stored: StoredCredential? = Harness.credential(),
         refreshFailureBackoff: TimeInterval = 30) async throws {
        self.store = store
        if let stored { try await store.save(stored) }
        let events = events
        manager = TokenManager(sso: server.makeClient(logSink: logs), store: store, events: { events.record($0) },
                               logSink: logs, timeSource: server.time, cache: cache, refreshFailureBackoff: refreshFailureBackoff)
    }

    static func credential(scopes: Set<ESIScope> = [.locationRead, .shipTypeRead], refreshToken: String = "refresh-1",
                           owner: String = "owner-hash-1") -> StoredCredential {
        StoredCredential(character: AuthorizedCharacter(id: characterID, name: "Test Pilot", ownerHash: owner, scopes: scopes),
                         refreshToken: refreshToken)
    }

    func token(owner: String = "owner-hash-1", scopes: [String] = ["esi-location.read_location.v1", "esi-location.read_ship_type.v1"],
               lifetime: TimeInterval = 1200) -> String {
        makeAccessToken(owner: owner, scopes: scopes, expiresAt: server.time.now().addingTimeInterval(lifetime))
    }

    /// Token endpoint answering every refresh with a new access token and `refresh-<n>` rotation.
    func serveRefreshes(owner: String = "owner-hash-1") {
        let counter = SSOLocked<Int>(1)
        server.tokenHandler.set { [server] _ in
            let n = counter.update { $0 += 1; return $0 }
            return server.tokenResponse(accessToken: token(owner: owner), refreshToken: "refresh-\(n)")
        }
    }
}

@Suite struct TokenManagerTests {
    @Test func refreshRotatesAndSavesBeforeReturning() async throws {
        let h = try await Harness()
        h.serveRefreshes()
        let token = try await h.manager.accessToken(for: characterID, requiredScopes: [.locationRead])
        #expect(!token.isEmpty)
        #expect(try await h.store.load(characterID: characterID)?.refreshToken == "refresh-2")
        #expect(MockLoginServer.form(try #require(h.server.tokenRequests.first))["refresh_token"] == "refresh-1")
        #expect(h.events.count(.tokenRefreshed) == 1)
        #expect(h.events.all.first { $0.kind == .tokenRefreshed }?.detail == String(characterID))

        // Cached until `refreshLeeway` before expiry.
        h.server.time.advance(by: 1200 - 61)
        #expect(try await h.manager.accessToken(for: characterID, requiredScopes: []) == token)
        #expect(h.server.tokenRequests.count == 1)
        h.server.time.advance(by: 2)
        let next = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(next != token)
        #expect(h.server.tokenRequests.count == 2)
        #expect(MockLoginServer.form(h.server.tokenRequests[1])["refresh_token"] == "refresh-2")
        #expect(try await h.store.load(characterID: characterID)?.refreshToken == "refresh-3")

        // Tokens never reach the logs.
        #expect(!h.logs.text.contains(token))
        #expect(!h.logs.text.contains("refresh-"))
    }

    @Test func failedSaveKeepsTheNewCredentialInMemory() async throws {
        let store = FlakyStore()
        let h = try await Harness(store: store)
        h.serveRefreshes()
        await store.setFailSaves(true)
        // The new access token is usable, so it is handed out; the failure is logged.
        let first = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(!first.isEmpty)
        #expect(try await store.load(characterID: characterID)?.refreshToken == "refresh-1")
        #expect(h.logs.text.contains("Could not save"))
        #expect(!h.logs.text.contains("refresh-"))

        // The next refresh uses the in-memory token (refresh-1 may be dead), not the stored one.
        h.server.time.advance(by: 1200)
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(MockLoginServer.form(h.server.tokenRequests[1])["refresh_token"] == "refresh-2")
        #expect(try await h.manager.characters().map(\.id) == [characterID])

        // Once the store works again, the next access saves it without another refresh.
        await store.setFailSaves(false)
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(h.server.tokenRequests.count == 2)
        #expect(try await store.load(characterID: characterID)?.refreshToken == "refresh-3")
    }

    @Test func failedSaveAndUnusableTokenThrowsStorage() async throws {
        let store = FlakyStore()
        let h = try await Harness(store: store)
        h.server.tokenHandler.set { [server = h.server] _ in
            server.tokenResponse(accessToken: h.token(lifetime: -600), refreshToken: "refresh-2")
        }
        await store.setFailSaves(true)
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .storage)
        #expect(h.events.count(.tokenRefreshed) == 0)

        // The rotated token was kept in memory, is saved on the next access and used to refresh.
        await store.setFailSaves(false)
        h.serveRefreshes()
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(MockLoginServer.form(h.server.tokenRequests[1])["refresh_token"] == "refresh-2")
        #expect(try await store.load(characterID: characterID)?.refreshToken != "refresh-1")
    }

    @Test func rotatedTokenSurvivesFailedValidation() async throws {
        let h = try await Harness()
        // Expired by the local clock: validation fails after EVE has rotated the token.
        h.server.tokenHandler.set { [server = h.server] _ in
            server.tokenResponse(accessToken: h.token(lifetime: -600), refreshToken: "refresh-2")
        }
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .ssoFailed)
        // The new refresh token is stored, with the character data unchanged.
        #expect(try await h.store.load(characterID: characterID) == Harness.credential(refreshToken: "refresh-2"))

        h.serveRefreshes()
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(MockLoginServer.form(h.server.tokenRequests[1])["refresh_token"] == "refresh-2")
    }

    @Test func jwksOutageDoesNotSpendTheRefreshToken() async throws {
        let h = try await Harness()
        h.serveRefreshes()
        h.server.jwksStatus.set(503)
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .transport)
        #expect(h.server.tokenRequests.isEmpty)
        #expect(try await h.store.load(characterID: characterID) == Harness.credential())
    }

    @Test func invalidGrantNeedsReauthentication() async throws {
        let h = try await Harness()
        h.server.tokenHandler.set { _ in MockLoginServer.oauthError(400, "invalid_grant") }
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [.locationRead])
        }
        #expect(error?.code == .reauthenticationRequired)
        let stored = try #require(try await h.store.load(characterID: characterID))
        #expect(stored.refreshToken.isEmpty)
        #expect(stored.character.state == .needsReauthentication(reason: "invalid_grant"))
        #expect(try await h.manager.characters().map(\.id) == [characterID])
        #expect(h.events.count(.reauthenticationRequired) == 1)
        #expect(h.events.all.first { $0.kind == .reauthenticationRequired }?.detail == String(characterID))

        // No retry: later calls fail without touching the network.
        let again = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(again?.code == .reauthenticationRequired)
        #expect(h.server.tokenRequests.count == 1)
        #expect(h.events.count(.reauthenticationRequired) == 1)
    }

    @Test func transientFailureKeepsTheRefreshToken() async throws {
        let h = try await Harness()
        h.server.tokenHandler.set { _ in HTTPResponse(status: 503, url: ssoLoginBase) }
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .transport)
        #expect(try await h.store.load(characterID: characterID) == Harness.credential())
        h.serveRefreshes()
        h.server.time.advance(by: 30)
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
    }

    @Test func transientFailureBacksOff() async throws {
        let h = try await Harness()
        h.server.tokenHandler.set { _ in HTTPResponse(status: 503, url: ssoLoginBase) }
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(h.server.tokenRequests.count == 1)

        // Within the backoff: the cached failure, with retryAfter, and no POST.
        h.server.time.advance(by: 10)
        let cached = await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(cached?.code == .transport)
        #expect(cached?.retryAfter == .seconds(20))
        #expect(h.server.tokenRequests.count == 1)

        // After it, one more attempt; a second failure doubles the backoff.
        h.server.time.advance(by: 20)
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(h.server.tokenRequests.count == 2)
        h.server.time.advance(by: 59)
        let doubled = await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(doubled?.retryAfter == .seconds(1))
        #expect(h.server.tokenRequests.count == 2)

        // Success clears it.
        h.server.time.advance(by: 1)
        h.serveRefreshes()
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(h.server.tokenRequests.count == 3)
        h.server.tokenHandler.set { _ in HTTPResponse(status: 503, url: ssoLoginBase) }
        h.server.time.advance(by: 1200)
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        h.server.time.advance(by: 30)
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(h.server.tokenRequests.count == 5) // back to the 30 s base

        // A login clears it too.
        h.server.tokenHandler.set { [server = h.server] _ in server.tokenResponse(accessToken: h.token(), refreshToken: "refresh-new") }
        try await h.manager.authorize(using: ScriptedSession.success())
        h.server.time.advance(by: 1200)
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [])
    }

    @Test func backoffCanBeDisabled() async throws {
        let h = try await Harness(refreshFailureBackoff: 0)
        h.server.tokenHandler.set { _ in HTTPResponse(status: 503, url: ssoLoginBase) }
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        await #expect(throws: CapsuleerError.self) { try await h.manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(h.server.tokenRequests.count == 2)
    }

    @Test func ownerChangeNeedsReauthentication() async throws {
        let h = try await Harness()
        let key = CacheKey(method: .get, url: URL(string: "https://esi.evetech.net/characters/\(characterID)/location/")!,
                           body: nil, identity: .character(characterID), variant: [:])
        await h.cache.store(CacheEntry(status: 200, headers: [:], body: Data(), url: URL(string: key.url)!,
                                       etag: nil, lastModified: nil, expires: nil, storedAt: h.server.time.now(), isPrivate: true), for: key)
        h.serveRefreshes(owner: "new-owner")
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .reauthenticationRequired)
        let stored = try #require(try await h.store.load(characterID: characterID))
        #expect(stored.character.state == .needsReauthentication(reason: TokenManager.ownerChangedReason))
        #expect(stored.refreshToken.isEmpty)
        #expect(stored.character.ownerHash == "owner-hash-1")
        #expect(h.events.count(.reauthenticationRequired) == 1)
        #expect(await h.cache.entry(for: key) == nil)
        // The new owner's rotated token is revoked rather than kept.
        #expect(MockLoginServer.form(try #require(h.server.revokeRequests.first))["token"] == "refresh-2")
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let h = try await Harness()
        let gate = SSOLocked<Bool>(false)
        h.server.tokenHandler.set { [server = h.server] _ in
            // Hold the refresh open until every caller is waiting on it.
            while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
            return server.tokenResponse(accessToken: h.token(), refreshToken: "refresh-2")
        }
        let manager = h.manager
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.accessToken(for: characterID, requiredScopes: [.locationRead]) }
            }
            try await Task.sleep(for: .milliseconds(100))
            gate.set(true)
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(tokens.count == 10)
        #expect(Set(tokens).count == 1)
        #expect(h.server.tokenRequests.count == 1)
        #expect(h.events.count(.tokenRefreshed) == 1)
    }

    @Test func missingScopeFailsWithoutNetwork() async throws {
        let h = try await Harness(stored: Harness.credential(scopes: [.locationRead]))
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [.locationRead, .structuresRead])
        }
        #expect(error?.code == .missingScope)
        #expect(error?.message?.contains("esi-universe.read_structures.v1") == true)
        #expect(h.server.transport.requests.isEmpty)
    }

    @Test func unknownCharacterIsNotAuthenticated() async throws {
        let h = try await Harness(stored: nil)
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.manager.accessToken(for: characterID, requiredScopes: [])
        }
        #expect(error?.code == .notAuthenticated)
        #expect(h.server.transport.requests.isEmpty)
    }

    @Test func invalidateDropsOnlyTheMatchingToken() async throws {
        let h = try await Harness()
        h.serveRefreshes()
        let first = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        await h.manager.invalidate(accessToken: "something-else", for: characterID)
        #expect(try await h.manager.accessToken(for: characterID, requiredScopes: []) == first)
        await h.manager.invalidate(accessToken: first, for: characterID)
        h.server.time.advance(by: 1) // a distinct `iat`/`exp`, so the new JWT differs
        let second = try await h.manager.accessToken(for: characterID, requiredScopes: [])
        #expect(second != first)
        #expect(h.server.tokenRequests.count == 2)
    }

    @Test func logoutRevokesAndDeletesEvenIfRevokeFails() async throws {
        for revokeStatus in [200, 500] {
            let h = try await Harness()
            h.server.revokeStatus.set(revokeStatus)
            try await h.manager.logout(characterID: characterID)
            #expect(MockLoginServer.form(try #require(h.server.revokeRequests.first)) == [
                "token": "refresh-1", "token_type_hint": "refresh_token", "client_id": ssoClientID,
            ])
            #expect(try await h.store.load(characterID: characterID) == nil)
            #expect(try await h.manager.characters().isEmpty)
            let error = await #expect(throws: CapsuleerError.self) {
                try await h.manager.accessToken(for: characterID, requiredScopes: [])
            }
            #expect(error?.code == .notAuthenticated)
        }
    }

    @Test func logoutWaitsForARunningRefreshAndRevokesItsToken() async throws {
        let h = try await Harness()
        let gate = SSOLocked<Bool>(false)
        h.server.tokenHandler.set { [server = h.server] _ in
            while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
            return server.tokenResponse(accessToken: h.token(), refreshToken: "refresh-2")
        }
        let manager = h.manager
        let refresh = Task { try await manager.accessToken(for: characterID, requiredScopes: []) }
        try await waitUntil { h.server.tokenRequests.count == 1 }
        let logout = Task { try await manager.logout(characterID: characterID) }
        try await Task.sleep(for: .milliseconds(20))

        // No new refresh while the character is being logged out.
        let during = await #expect(throws: CapsuleerError.self) { try await manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(during?.code == .notAuthenticated)

        gate.set(true)
        _ = try? await refresh.value
        try await logout.value
        #expect(try await h.store.load(characterID: characterID) == nil)
        // The token the refresh stored is the one revoked.
        #expect(h.server.revokeRequests.map { MockLoginServer.form($0)["token"] } == ["refresh-2"])
        #expect(h.server.tokenRequests.count == 1)
        await #expect(throws: CapsuleerError.self) { try await manager.accessToken(for: characterID, requiredScopes: []) }
    }

    @Test func noRefreshWhileLogoutRevokes() async throws {
        let h = try await Harness()
        h.serveRefreshes()
        let gate = SSOLocked<Bool>(false)
        h.server.revokeHandler.set { while !gate.value { try await Task.sleep(for: .milliseconds(5)) } }
        let manager = h.manager
        let logout = Task { try await manager.logout(characterID: characterID) }
        try await waitUntil { h.server.revokeRequests.count == 1 }

        let error = await #expect(throws: CapsuleerError.self) { try await manager.accessToken(for: characterID, requiredScopes: []) }
        #expect(error?.code == .notAuthenticated)
        gate.set(true)
        try await logout.value
        #expect(h.server.tokenRequests.isEmpty)
        #expect(try await h.store.load(characterID: characterID) == nil)
    }

    @Test func reloginWaitsForARunningRefreshAndRevokesNothing() async throws {
        let h = try await Harness()
        let gate = SSOLocked<Bool>(false)
        let loginToken = h.token(scopes: ["esi-location.read_location.v1"])
        h.server.tokenHandler.set { [server = h.server] form in
            if form["grant_type"] == "authorization_code" {
                return server.tokenResponse(accessToken: loginToken, refreshToken: "refresh-login")
            }
            while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
            return server.tokenResponse(accessToken: h.token(), refreshToken: "refresh-2")
        }
        let manager = h.manager
        let refresh = Task { try await manager.accessToken(for: characterID, requiredScopes: []) }
        try await waitUntil { h.server.tokenRequests.count == 1 }
        let login = Task { try await manager.authorize(using: ScriptedSession.success()) }
        try await waitUntil { h.server.tokenRequests.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.server.revokeRequests.isEmpty)

        gate.set(true)
        _ = try await refresh.value
        _ = try await login.value
        // The login's credential wins. Nothing is revoked: EVE revocation ends the whole grant,
        // which would also invalidate the login's fresh token.
        #expect(try await h.store.load(characterID: characterID)?.refreshToken == "refresh-login")
        #expect(h.server.revokeRequests.isEmpty)
        #expect(try await manager.accessToken(for: characterID, requiredScopes: []) == loginToken)
    }

    @Test func authorizeStoresTheCharacter() async throws {
        let h = try await Harness(stored: nil)
        let token = h.token(scopes: ["esi-location.read_location.v1"])
        h.server.tokenHandler.set { [server = h.server] _ in server.tokenResponse(accessToken: token, refreshToken: "refresh-a") }
        let character = try await h.manager.authorize(using: ScriptedSession.success())
        #expect(character.id == characterID)
        #expect(character.scopes == [.locationRead])
        #expect(try await h.store.load(characterID: characterID)?.refreshToken == "refresh-a")
        // The exchanged access token is used directly.
        #expect(try await h.manager.accessToken(for: characterID, requiredScopes: [.locationRead]) == token)
        #expect(h.server.tokenRequests.count == 1)
    }

    @Test func authorizeMergesScopesForAnExistingCharacter() async throws {
        let h = try await Harness(stored: Harness.credential(scopes: [.locationRead, .shipTypeRead]))
        let requestedScopes = SSOLocked<String>("")
        let token = h.token(scopes: ["esi-location.read_location.v1", "esi-location.read_ship_type.v1", "esi-universe.read_structures.v1"])
        h.server.tokenHandler.set { [server = h.server] _ in server.tokenResponse(accessToken: token, refreshToken: "refresh-b") }
        let session = ScriptedSession { authorizeURL, callbackURL in
            requestedScopes.set(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value ?? "")
            return try ScriptedSession.success().respond(authorizeURL, callbackURL)
        }
        let character = try await h.manager.authorize(scopes: [.structuresRead], mergingWith: characterID, using: session)
        #expect(requestedScopes.value == "esi-location.read_location.v1 esi-location.read_ship_type.v1 esi-universe.read_structures.v1")
        #expect(character.scopes == [.locationRead, .shipTypeRead, .structuresRead])
        let stored = try #require(try await h.store.load(characterID: characterID))
        #expect(stored.refreshToken == "refresh-b")
        #expect(stored.character.state == .active)
        // The replaced refresh token is not revoked (revocation would end the new login's grant too).
        #expect(h.server.revokeRequests.isEmpty)
    }

    @Test func reloginRecoversFromNeedsReauthentication() async throws {
        var stale = Harness.credential(refreshToken: "")
        stale.character.state = .needsReauthentication(reason: "invalid_grant")
        let h = try await Harness(stored: stale)
        h.server.tokenHandler.set { [server = h.server] _ in server.tokenResponse(accessToken: h.token(), refreshToken: "refresh-c") }
        try await h.manager.authorize(using: ScriptedSession.success())
        #expect(try await h.store.load(characterID: characterID)?.character.state == .active)
        _ = try await h.manager.accessToken(for: characterID, requiredScopes: [.locationRead])
        #expect(h.server.revokeRequests.isEmpty)
    }

    @Test func cancelledLoginStoresNothing() async throws {
        let h = try await Harness(stored: nil)
        let session = ScriptedSession { _, callbackURL in URL(string: "\(callbackURL.absoluteString)?error=access_denied")! }
        let error = await #expect(throws: CapsuleerError.self) { try await h.manager.authorize(using: session) }
        #expect(error?.code == .cancelled)
        #expect(try await h.manager.characters().isEmpty)
    }
}
