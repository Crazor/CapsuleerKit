import CapsuleerCore
import CapsuleerKitTesting
import Foundation
import Testing
@testable import ESIKit

// MARK: - Support

/// Fixture body from `Tests/ESIKitTests/Fixtures`.
func esiFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Token provider that hands out numbered tokens per character and records every call.
actor RecordingTokenProvider: ESITokenProvider {
    private(set) var requests: [(characterID: Int64, scopes: Set<ESIScope>)] = []
    private(set) var invalidated: [(token: String, characterID: Int64)] = []
    private var generation: [Int64: Int] = [:]

    func accessToken(for characterID: Int64, requiredScopes: Set<ESIScope>) async throws -> String {
        requests.append((characterID, requiredScopes))
        return "token-\(characterID)-\(generation[characterID, default: 0])"
    }

    func invalidate(accessToken token: String, for characterID: Int64) async {
        invalidated.append((token, characterID))
        generation[characterID, default: 0] += 1
    }
}

/// An `ESIClient` over a `MockTransport`, a memory cache and a manual clock.
struct ESIClientHarness {
    let transport = MockTransport()
    let cache: MemoryCacheStore
    let time: ManualTimeSource
    let tokens = RecordingTokenProvider()
    let client: ESIClient

    static let userAgent = UserAgent(product: "ESIKitTests", version: "1.0", contact: "+https://example.com/tests")

    init(cache: MemoryCacheStore = MemoryCacheStore(), time: ManualTimeSource = ManualTimeSource(),
         withTokens: Bool = true, etiquette: Bool = false) {
        self.cache = cache
        self.time = time
        let configuration = ESIConfiguration(
            userAgent: Self.userAgent, cache: cache, transport: transport,
            tokenProvider: withTokens ? tokens : nil, timeSource: time)
        client = ESIClient(configuration: configuration, wrapTransport: etiquette)
    }

    /// Answers every request from `routes` (path → fixture name), 404 otherwise.
    func route(_ routes: [String: String], headers: HTTPHeaders = ["Content-Type": "application/json", "Cache-Control": "max-age=60"]) throws {
        var bodies: [String: Data] = [:]
        for (path, name) in routes { bodies[path] = try esiFixture(name) }
        let fixed = bodies
        transport.setHandler { request in
            guard let body = fixed[request.url.path] else {
                return HTTPResponse(status: 404, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"Not found"}"#.utf8), url: request.url)
            }
            return HTTPResponse(status: 200, headers: headers, body: body, url: request.url)
        }
    }
}

func capsuleerCode(_ body: () async throws -> Void) async -> CapsuleerError? {
    do { try await body(); return nil } catch let error as CapsuleerError { return error } catch {
        Issue.record("Expected CapsuleerError, got \(error)")
        return nil
    }
}

// MARK: - Requests and decoding

@Suite struct ESIClientTests {
    @Test func publicRequestCarriesCompatibilityDateUserAgentAndHints() async throws {
        let h = ESIClientHarness()
        try h.route(["/characters/2112625428": "characters-2112625428"])
        _ = try await h.client.character(2112625428).publicInfo()

        let request = try #require(h.transport.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://esi.evetech.net/characters/2112625428")
        #expect(request.headers["X-Compatibility-Date"] == ESI.compatibilityDate)
        #expect(request.headers["User-Agent"] == ESIClientHarness.userAgent.headerValue)
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers[ESIRequestHints.identity] == "public")
        #expect(request.headers[ESIRequestHints.idempotent] == "1")
        #expect(request.headers[ESIRequestHints.rateLimitGroup] == nil)  // the spec gives this operation no group
        #expect(request.headers["Authorization"] == nil)
    }

    @Test func authenticatedRequestCarriesTokenIdentityAndRateLimitHints() async throws {
        let h = ESIClientHarness()
        try h.route(["/characters/90000001/location": "character-location-station"])
        _ = try await h.client.character(90000001).location()

        let request = try #require(h.transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer token-90000001-0")
        #expect(request.headers["X-Compatibility-Date"] == ESI.compatibilityDate)
        #expect(request.headers[ESIRequestHints.identity] == "character:90000001")
        #expect(request.headers[ESIRequestHints.rateLimitGroup] == "char-location")
        #expect(request.headers[ESIRequestHints.rateLimitWindow] == "1200/15m")
        #expect(request.headers[ESIRequestHints.idempotent] == "1")
        let tokenRequests = await h.tokens.requests
        #expect(tokenRequests.count == 1)
        #expect(tokenRequests.first?.scopes == [.locationRead])
    }

    @Test func publicInfoDecodesRecordedFixture() async throws {
        let h = ESIClientHarness()
        try h.route(["/characters/2112625428": "characters-2112625428"])
        let response = try await h.client.character(2112625428).publicInfo()

        let info = response.value
        #expect(info.name == "FC Zoetrope")
        #expect(info.corporationID == 109299958)
        #expect(info.allianceID == 434243723)
        #expect(info.factionID == nil)
        #expect(info.securityStatus == 0.0)
        #expect(info.birthday == Date(timeIntervalSince1970: 1_491_313_568))  // 2017-04-04T13:46:08Z
        #expect(response.source == .network)
        #expect(response.expires == h.time.now().addingTimeInterval(60))
    }

    @Test func locationDecodesAndReportsDocking() async throws {
        let h = ESIClientHarness()
        try h.route([
            "/characters/1/location": "character-location-station",
            "/characters/2/location": "character-location-structure",
            "/characters/3/location": "character-location-space",
        ])
        let station = try await h.client.character(1).location().value
        #expect(station == CharacterLocation(solarSystemID: 30000142, stationID: 60003760, structureID: nil))
        #expect(station.isDocked)

        let structure = try await h.client.character(2).location().value
        #expect(structure == CharacterLocation(solarSystemID: 30000142, stationID: nil, structureID: 1035466617946))
        #expect(structure.isDocked)

        let space = try await h.client.character(3).location().value
        #expect(space == CharacterLocation(solarSystemID: 30002187, stationID: nil, structureID: nil))
        #expect(!space.isDocked)
    }

    @Test func shipAndOnlineDecode() async throws {
        let h = ESIClientHarness()
        try h.route(["/characters/7/ship": "character-ship", "/characters/7/online": "character-online"])

        let ship = try await h.client.character(7).ship().value
        #expect(ship == CharacterShip(typeID: 32880, itemID: 1000000016991, name: "Zoetrope's Venture"))

        let online = try await h.client.character(7).online().value
        #expect(online.isOnline)
        #expect(online.logins == 9001)
        #expect(online.lastLogin == ISO8601DateFormatter().date(from: "2026-11-21T18:04:05Z"))
        #expect(online.lastLogout == ISO8601DateFormatter().date(from: "2026-11-21T20:15:30Z"))

        let scopes = await h.tokens.requests.map(\.scopes)
        #expect(scopes == [[.shipTypeRead], [.onlineRead]])
    }

    @Test func fractionalSecondDatesDecode() async throws {
        let h = ESIClientHarness()
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"],
                            body: Data(#"{"online":false,"last_login":"2026-11-21T18:04:05.250Z"}"#.utf8),
                            url: URL(string: "https://esi.evetech.net/characters/7/online")!)
        let online = try await h.client.character(7).online().value
        #expect(online.lastLogin == ISO8601DateFormatter().date(from: "2026-11-21T18:04:05Z")!.addingTimeInterval(0.25))
        #expect(online.lastLogout == nil)
        #expect(online.logins == nil)
    }

    @Test func undecodableBodyThrowsDecoding() async throws {
        let h = ESIClientHarness()
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"name":"x"}"#.utf8),
                            url: URL(string: "https://esi.evetech.net/characters/1")!)
        let error = await capsuleerCode { _ = try await h.client.character(1).publicInfo() }
        #expect(error?.code == .decoding)
    }

    @Test func httpErrorsAreRethrownUnchanged() async throws {
        let h = ESIClientHarness()
        try h.route([:])
        let error = await capsuleerCode { _ = try await h.client.character(1).publicInfo() }
        #expect(error?.code == .notFound)
        #expect(error?.status == 404)
        #expect(error?.message == #"{"error":"Not found"}"#)
    }

    // MARK: Caching and identities

    @Test func secondCallWithinExpiresIsServedFromCache() async throws {
        let h = ESIClientHarness()
        try h.route(["/characters/5/ship": "character-ship"],
                    headers: ["Content-Type": "application/json", "Cache-Control": "max-age=5", "ETag": "\"v1\""])
        let first = try await h.client.character(5).ship()
        h.time.advance(by: 4)
        let second = try await h.client.character(5).ship()
        #expect(first.source == .network)
        #expect(second.source == .cache)
        #expect(second.value == first.value)
        #expect(h.transport.requests.count == 1)

        h.time.advance(by: 2)
        _ = try await h.client.character(5).ship()
        #expect(h.transport.requests.count == 2)
        #expect(h.transport.requests.last?.headers["If-None-Match"] == "\"v1\"")
    }

    @Test func charactersGetSeparateCacheEntries() async throws {
        let h = ESIClientHarness()
        try h.route(["/universe/structures/1035466617946": "universe-structure"])
        _ = try await h.client.universe.structure(1035466617946, as: 1)
        _ = try await h.client.universe.structure(1035466617946, as: 2)
        _ = try await h.client.universe.structure(1035466617946, as: 1)
        _ = try await h.client.universe.structure(1035466617946, as: 2)

        let requests = h.transport.requests
        #expect(requests.count == 2)
        #expect(requests.map { $0.headers["Authorization"] } == ["Bearer token-1-0", "Bearer token-2-0"])
        #expect(requests.map { $0.headers[ESIRequestHints.identity] } == ["character:1", "character:2"])

        let url = URL(string: "https://esi.evetech.net/universe/structures/1035466617946")!
        let variant = ["X-Compatibility-Date": ESI.compatibilityDate]
        for id: Int64 in [1, 2] {
            let entry = await h.cache.entry(for: CacheKey(method: .get, url: url, identity: .character(id), variant: variant))
            #expect(entry?.isPrivate == true)
        }
        #expect(await h.cache.entry(for: CacheKey(method: .get, url: url, identity: .public, variant: variant)) == nil)
    }

    // MARK: Authentication

    @Test func missingProviderThrowsNotAuthenticatedWithoutRequest() async throws {
        let h = ESIClientHarness(withTokens: false)
        try h.route(["/characters/1/location": "character-location-station"])
        let location = await capsuleerCode { _ = try await h.client.character(1).location() }
        let structure = await capsuleerCode { _ = try await h.client.universe.structure(1, as: 1) }
        #expect(location?.code == .notAuthenticated)
        #expect(structure?.code == .notAuthenticated)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func unauthorizedInvalidatesTokenAndRetriesOnce() async throws {
        let h = ESIClientHarness()
        let url = URL(string: "https://esi.evetech.net/characters/9/online")!
        h.transport.enqueue(status: 401, body: Data(#"{"error":"token expired"}"#.utf8), url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("character-online"), url: url)

        let online = try await h.client.character(9).online().value
        #expect(online.isOnline)
        #expect(h.transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-9-0", "Bearer token-9-1"])
        let invalidated = await h.tokens.invalidated
        #expect(invalidated.map(\.token) == ["token-9-0"])
        #expect(invalidated.map(\.characterID) == [9])
    }

    @Test func secondUnauthorizedIsThrown() async throws {
        let h = ESIClientHarness()
        let url = URL(string: "https://esi.evetech.net/characters/9/online")!
        h.transport.enqueue(status: 401, url: url)
        h.transport.enqueue(status: 401, url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("character-online"), url: url)

        let error = await capsuleerCode { _ = try await h.client.character(9).online() }
        #expect(error?.status == 401)
        #expect(h.transport.requests.count == 2)
        #expect(await h.tokens.invalidated.count == 1)
    }

    @Test func unauthorizedAfterARejectedFreshTokenIsThrownWithoutRefreshDuringCooldown() async throws {
        let h = ESIClientHarness()
        let url = URL(string: "https://esi.evetech.net/characters/9/online")!
        for _ in 0..<3 { h.transport.enqueue(status: 401, url: url) }

        // First call: 401, refresh, 401 again → cooldown starts.
        #expect(await capsuleerCode { _ = try await h.client.character(9).online() }?.status == 401)
        #expect(h.transport.requests.count == 2)
        #expect(await h.tokens.invalidated.count == 1)

        // During the cooldown a 401 costs one request and no refresh.
        h.time.advance(by: 299)
        #expect(await capsuleerCode { _ = try await h.client.character(9).online() }?.status == 401)
        #expect(h.transport.requests.count == 3)
        #expect(h.transport.requests.last?.headers["Authorization"] == "Bearer token-9-1")
        #expect(await h.tokens.invalidated.count == 1)

        // Another character is not affected.
        let other = URL(string: "https://esi.evetech.net/characters/8/online")!
        h.transport.enqueue(status: 401, url: other)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("character-online"), url: other)
        #expect(try await h.client.character(8).online().value.isOnline)
        #expect(await h.tokens.invalidated.map(\.characterID) == [9, 8])

        // After the cooldown the refresh-and-retry is back.
        h.time.advance(by: 2)
        h.transport.enqueue(status: 401, url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("character-online"), url: url)
        #expect(try await h.client.character(9).online().value.isOnline)
        #expect(await h.tokens.invalidated.map(\.token) == ["token-9-0", "token-8-0", "token-9-1"])
    }

    @Test func successfulCallEndsTheUnauthorizedCooldown() async throws {
        let h = ESIClientHarness()
        let url = URL(string: "https://esi.evetech.net/characters/9/online")!
        let online = try esiFixture("character-online")
        for _ in 0..<2 { h.transport.enqueue(status: 401, url: url) }
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: online, url: url)
        h.transport.enqueue(status: 401, url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: online, url: url)

        #expect(await capsuleerCode { _ = try await h.client.character(9).online() }?.status == 401)  // cooldown starts
        #expect(try await h.client.character(9).online().value.isOnline)  // success clears it
        #expect(try await h.client.character(9).online().value.isOnline)  // 401 is refreshed and retried again
        #expect(h.transport.requests.count == 5)
        #expect(await h.tokens.invalidated.count == 2)
    }

    @Test func structureUsesStructureScopeAndRethrowsForbidden() async throws {
        let h = ESIClientHarness()
        try h.route(["/universe/structures/1035466617946": "universe-structure"])
        let info = try await h.client.universe.structure(1035466617946, as: 42).value
        #expect(info == StructureInfo(name: "Perimeter - Tranquility Trading Tower", ownerID: 98000001, solarSystemID: 30000144, typeID: 35834))
        #expect(await h.tokens.requests.map(\.scopes) == [[.structuresRead]])

        let url = URL(string: "https://esi.evetech.net/universe/structures/1")!
        h.transport.enqueue(status: 403, headers: ["Content-Type": "application/json"], body: try esiFixture("error-forbidden"), url: url)
        let before = h.transport.requests.count
        let error = await capsuleerCode { _ = try await h.client.universe.structure(1, as: 42) }
        #expect(error?.code == .http)
        #expect(error?.status == 403)
        #expect(h.transport.requests.count == before + 1)
        #expect(await h.tokens.invalidated.isEmpty)
    }

    // MARK: Generated layer

    @Test func compatibilityDateMatchesGeneratedSpec() {
        #expect(Components.Parameters.CompatibilityDate.allCases.map(\.rawValue) == [ESI.compatibilityDate])
        #expect(OperationMetadata.specCompatibilityDate == ESI.compatibilityDate)
    }
}
