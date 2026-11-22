import CapsuleerCore
import CapsuleerKitTesting
import Foundation
import Testing
@testable import ESIKit

@Suite struct ESIClientUniverseTests {
    struct NameItem: Encodable { var id: Int64; var name: String; var category: String }

    /// Answers `/universe/names` with a made-up name per requested ID.
    static func echoNames(_ transport: MockTransport) {
        transport.setHandler { request in
            let ids = try JSONDecoder().decode([Int64].self, from: request.body ?? Data())
            let data = try JSONEncoder().encode(ids.map { NameItem(id: $0, name: "Station \($0)", category: "station") })
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data, url: request.url)
        }
    }

    @Test func namesMapsRecordedFixture() async throws {
        let h = ESIClientHarness()
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json; charset=UTF-8"], body: try esiFixture("universe-names"),
                            url: URL(string: "https://esi.evetech.net/universe/names")!)
        let names = try await h.client.universe.names([60003760, 30000142, 60003760])
        #expect(names == [
            ResolvedEntity(id: 60003760, name: "Jita IV - Moon 4 - Caldari Navy Assembly Plant", category: .station),
            ResolvedEntity(id: 30000142, name: "Jita", category: .solarSystem),
        ])

        let request = try #require(h.transport.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://esi.evetech.net/universe/names")
        #expect(try JSONDecoder().decode([Int64].self, from: request.body ?? Data()) == [60003760, 30000142])
        #expect(request.headers["Content-Type"]?.hasPrefix("application/json") == true)
        #expect(request.headers["X-Compatibility-Date"] == ESI.compatibilityDate)
        #expect(request.headers[ESIRequestHints.identity] == "public")
        #expect(request.headers[ESIRequestHints.idempotent] == "1")
    }

    @Test func namesBatchesByThousandAndCachesInProcess() async throws {
        let h = ESIClientHarness()
        Self.echoNames(h.transport)
        let ids = (1...2500).map { Int64(60_000_000 + $0) }

        let names = try await h.client.universe.names(ids)
        #expect(names.map(\.id) == ids)
        let batches = try h.transport.requests.map { try JSONDecoder().decode([Int64].self, from: $0.body ?? Data()).count }
        #expect(batches == [1000, 1000, 500])

        _ = try await h.client.universe.names(Array(ids.prefix(10)) + [70_000_001])
        #expect(h.transport.requests.count == 4)
        #expect(try JSONDecoder().decode([Int64].self, from: h.transport.requests[3].body ?? Data()) == [70_000_001])
    }

    @Test func namesArePersistedInTheCacheStore() async throws {
        let cache = MemoryCacheStore()
        let time = ManualTimeSource()
        let first = ESIClientHarness(cache: cache, time: time)
        Self.echoNames(first.transport)
        _ = try await first.client.universe.names([60003760, 60008494])

        // A new client (fresh process) with the same store: no request, also when offline.
        let second = ESIClientHarness(cache: cache, time: time)
        second.transport.setHandler { request in throw CapsuleerError(.transport, message: "offline", url: request.url) }
        let names = try await second.client.universe.names([60008494, 60003760])
        #expect(names.map(\.name) == ["Station 60008494", "Station 60003760"])
        #expect(second.transport.requests.isEmpty)

        // After the 30-day TTL they are fetched again, but still served when offline.
        time.advance(by: 31 * 24 * 3600)
        let third = ESIClientHarness(cache: cache, time: time)
        third.transport.setHandler { request in throw CapsuleerError(.transport, message: "offline", url: request.url) }
        let stale = try await third.client.universe.names([60003760])
        #expect(stale.map(\.id) == [60003760])
        #expect(third.transport.requests.count == 1)
    }

    @Test func namesNotFoundIsThrown() async throws {
        let h = ESIClientHarness()
        h.transport.enqueue(status: 404, body: Data(#"{"error":"Ensure all IDs are valid before resolving"}"#.utf8),
                            url: URL(string: "https://esi.evetech.net/universe/names")!)
        let error = await capsuleerCode { _ = try await h.client.universe.names([1]) }
        #expect(error?.code == .notFound)
    }

    @Test func idsMapsCategoriesAndDropsInexactMatches() async throws {
        let h = ESIClientHarness()
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("universe-ids"),
                            url: URL(string: "https://esi.evetech.net/universe/ids")!)
        let entities = try await h.client.universe.ids(["Jita", "amarr", "Tritanium"])
        #expect(entities == [
            ResolvedEntity(id: 30000142, name: "Jita", category: .solarSystem),
            ResolvedEntity(id: 30002187, name: "Amarr", category: .solarSystem),
            ResolvedEntity(id: 243070982, name: "Tritanium", category: .character),
            ResolvedEntity(id: 34, name: "Tritanium", category: .inventoryType),
        ])
        let request = try #require(h.transport.requests.first)
        #expect(try JSONDecoder().decode([String].self, from: request.body ?? Data()) == ["Jita", "amarr", "Tritanium"])
        #expect(request.headers[ESIRequestHints.idempotent] == "1")
    }

    @Test func idsCachesResolvedForTwelveHoursAndUnresolvedForOne() async throws {
        let h = ESIClientHarness()
        h.transport.setHandler { request in
            let names = try JSONDecoder().decode([String].self, from: request.body ?? Data())
            let systems = names.filter { $0 == "Jita" }.map { ["id": 30000142, "name": $0] as [String: Any] }
            let body = try JSONSerialization.data(withJSONObject: (systems.isEmpty ? [:] : ["systems": systems]) as [String: Any])
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body, url: request.url)
        }
        _ = try await h.client.universe.ids(["Jita", "Nowhere"])
        #expect(try await h.client.universe.ids(["Jita", "Nowhere"]).map(\.id) == [30000142])
        #expect(h.transport.requests.count == 1)

        h.time.advance(by: 3601)
        _ = try await h.client.universe.ids(["Jita", "Nowhere"])
        #expect(h.transport.requests.count == 2)
        #expect(try JSONDecoder().decode([String].self, from: h.transport.requests[1].body ?? Data()) == ["Nowhere"])

        h.time.advance(by: 12 * 3600)
        _ = try await h.client.universe.ids(["Jita"])
        #expect(h.transport.requests.count == 3)
    }

    @Test func idsBatchesByFiveHundred() async throws {
        let h = ESIClientHarness()
        h.transport.setHandler { request in
            HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8), url: request.url)
        }
        _ = try await h.client.universe.ids((1...1200).map { "Name \($0)" })
        let batches = try h.transport.requests.map { try JSONDecoder().decode([String].self, from: $0.body ?? Data()).count }
        #expect(batches == [500, 500, 200])
    }
}
