import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import SDEKit

@Suite struct SyncTests {
    @Test func firstSyncDownloadsManifestAndTableAndStoresThem() async throws {
        let h = try Harness()
        let table = try await h.client.solarSystems()

        #expect(table.all.count == 11)
        #expect(table.release == Fixture.release)
        #expect(table.version == Fixture.solarSystemsVersion)
        #expect(table.isStale == false)
        #expect(table.fetchedAt == h.clock.now())
        // Data comes from the pinned release URL, never from latest/.
        #expect(h.server.transport.requests.map(\.url) == [Fixture.latestURL, Fixture.solarSystemsJSONLURL])
        #expect(h.server.transport.requests.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("SDEKitTests/1") ?? false })

        let storedRelease = try #require(try await h.store.loadRelease())
        #expect(storedRelease.release.release == Fixture.release)
        #expect(storedRelease.lastChecked == h.clock.now())
        let storedTable = try #require(try await h.store.loadTable(named: "mapSolarSystems", as: SolarSystem.self))
        #expect(storedTable.version == Fixture.solarSystemsVersion)
        #expect(storedTable.records.count == 11)

        #expect(h.eventCount(.sdeReleaseChecked) == 1)
        #expect(h.eventCount(.sdeTableUpdated) == 1)
    }

    @Test func secondCallWithinTheIntervalMakesNoRequests() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        let before = h.server.totalRequests
        h.clock.advance(by: 3600)
        let table = try await h.client.solarSystems()
        let release = try await h.client.currentRelease()
        #expect(h.server.totalRequests == before)
        #expect(table.all.count == 11)
        #expect(release.source == .cache)
        #expect(release.isStale == false)
    }

    @Test func relaunchWithinTheIntervalServesTheStoreWithoutRequests() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        let before = h.server.totalRequests
        let relaunched = try h.relaunched()
        let table = try await relaunched.client.solarSystems()
        #expect(h.server.totalRequests == before)
        #expect(table.all.count == 11)
        #expect(table.isStale == false)
    }

    @Test func afterTheIntervalOnlyTheManifestIsFetchedWhenTheVersionIsUnchanged() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.clock.advance(by: 86_400)
        let table = try await h.client.solarSystems()
        #expect(h.server.manifestRequests == 2)
        #expect(h.server.jsonlRequests == 1)
        #expect(table.isStale == false)
        #expect(try await h.store.loadRelease()?.lastChecked == h.clock.now())
    }

    @Test func forceCheckFetchesTheManifestWithinTheInterval() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        _ = try await h.client.solarSystems(forceCheck: true)
        #expect(h.server.manifestRequests == 2)
        #expect(h.server.jsonlRequests == 1)
    }

    @Test func changedVersionHashDownloadsTheTableAgain() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.server.setSolarSystemsVersion("feedface")
        h.clock.advance(by: 86_401)
        let table = try await h.client.solarSystems()
        #expect(h.server.jsonlRequests == 2)
        #expect(table.version == "feedface")
        #expect(try await h.store.loadTable(named: "mapSolarSystems", as: SolarSystem.self)?.version == "feedface")
        #expect(h.eventCount(.sdeTableUpdated) == 2)
    }

    @Test func offlineWithAStoredTableServesItStale() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.server.offline = true
        h.clock.advance(by: 2 * 86_400)

        let relaunched = try h.relaunched()
        let table = try await relaunched.client.solarSystems()
        #expect(table.isStale)
        #expect(table.all.count == 11)
        #expect(table.system(named: "Jita") != nil)
        #expect(relaunched.eventCount(.servedStale) >= 1)

        let release = try await relaunched.client.currentRelease()
        #expect(release.isStale)
        #expect(release.value.release == Fixture.release)
    }

    @Test func failedDownloadWithAStoredTableServesItStale() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.server.setSolarSystemsVersion("feedface")
        h.server.state.mutate { $0.jsonl = Data("{not json}\n".utf8) }
        h.clock.advance(by: 86_400)
        let table = try await h.client.solarSystems()
        #expect(table.isStale)
        #expect(table.version == Fixture.solarSystemsVersion)
    }

    @Test func offlineWithNothingStoredThrowsReleaseUnavailable() async throws {
        let h = try Harness()
        h.server.offline = true
        let error = await #expect(throws: CapsuleerError.self) { try await h.client.solarSystems() }
        #expect(error?.code == .sdeReleaseUnavailable)
        #expect(error?.underlying != nil)
        let releaseError = await #expect(throws: CapsuleerError.self) { try await h.client.currentRelease() }
        #expect(releaseError?.code == .sdeReleaseUnavailable)
    }

    @Test func aBadLineFailsTheSync() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonl = try! Fixture.solarSystemsJSONL + Data("{\"solarSystemID\": \"oops\"}\n".utf8) }
        let error = await #expect(throws: CapsuleerError.self) { try await h.client.solarSystems() }
        #expect(error?.code == .sdeReleaseUnavailable)
        #expect((error?.underlying as? CapsuleerError)?.code == .decoding)
        #expect(try await h.store.loadTable(named: "mapSolarSystems", as: SolarSystem.self) == nil)
    }

    @Test func blankLinesAreSkipped() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonl = Data("\n  \n".utf8) + (try! Fixture.solarSystemsJSONL) + Data("\n\r\n".utf8) }
        #expect(try await h.client.solarSystems().all.count == 11)
    }

    @Test func concurrentCallsShareOneSync() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonlDelay = .milliseconds(100) }
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { try await h.client.solarSystems().all.count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 11, count: 8))
        #expect(h.server.jsonlRequests == 1)
        #expect(h.server.manifestRequests == 1)
    }

    @Test func recordURLIsBuiltFromTheTemplate() async throws {
        let h = try Harness()
        let jita = try await h.client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        #expect(jita.value.id == 30000142)
        #expect(jita.value.name.en == "Jita")
        #expect(h.server.transport.requests.last?.url.absoluteString
                == "https://sde.evetech.net/tranquility/\(Fixture.release)/mapSolarSystems/30000142.json")
    }

    @Test func repeatedRecordsComeFromTheHTTPCache() async throws {
        let h = try Harness(cache: MemoryCacheStore())
        _ = try await h.client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        let second = try await h.client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        #expect(second.source == .cache)
        #expect(h.server.transport.requests.filter { $0.url.absoluteString.hasSuffix("/30000142.json") }.count == 1)
    }

    @Test func tableDownloadsStayOutOfTheHTTPCache() async throws {
        let cache = MemoryCacheStore()
        let h = try Harness(cache: cache)
        _ = try await h.client.solarSystems()
        #expect(await cache.entry(for: CacheKey(method: .get, url: Fixture.solarSystemsJSONLURL)) == nil)
    }

    @Test func recordFromAnUnknownTableThrowsNotFound() async throws {
        let h = try Harness()
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.client.record(SolarSystem.self, table: "noSuchTable", key: 1)
        }
        #expect(error?.code == .notFound)
    }
}
