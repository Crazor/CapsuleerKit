import CapsuleerCore
import Foundation
import SDEKit
import Testing

/// Live tests against sde.evetech.net. Run with `CAPSULEER_LIVE=1 swift test --filter LiveTests`.
private let isLive = ProcessInfo.processInfo.environment["CAPSULEER_LIVE"] == "1"

@Suite("SDE live", .enabled(if: isLive), .serialized)
struct SDELiveTests {
    let directory: URL
    let client: SDEClient

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapsuleerKit-LiveTests-\(UUID().uuidString)", isDirectory: true)
        client = SDEClient(configuration: SDEConfiguration(
            userAgent: UserAgent(product: "CapsuleerKit-LiveTests", version: CapsuleerKitInfo.version,
                                 contact: "+https://github.com/Crazor/CapsuleerKit"),
            directory: directory))
    }

    @Test func currentReleaseHasSolarSystemTable() async throws {
        let response = try await client.currentRelease(forceCheck: true)
        #expect(!response.value.release.isEmpty)
        #expect(response.value.buildNumber > 0)
        let table = try #require(response.value.tables["mapSolarSystems"])
        #expect(!table.version.isEmpty)
        #expect(table.jsonlURL?.absoluteString.contains(response.value.release) == true)
    }

    @Test func solarSystemsSyncAndLookup() async throws {
        let table = try await client.solarSystems()
        #expect(table.all.count > 8_000)
        #expect(!table.isStale)
        let jita = try #require(table.system(named: "jita"))
        #expect(jita.id == 30000142)
        #expect(jita.security.band == .high)
        #expect(jita.security.formatted == "0.9")

        // Second call is served from the store without re-downloading.
        let again = try await client.solarSystems()
        #expect(again.version == table.version)
        #expect(again.fetchedAt == table.fetchedAt)
    }

    @Test func singleRecord() async throws {
        let jita = try await client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        #expect(jita.value.name.en == "Jita")
        let repeated = try await client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        #expect(repeated.source == .cache)
    }
}

@Suite("Image server live", .enabled(if: ProcessInfo.processInfo.environment["CAPSULEER_LIVE"] == "1"))
struct ImageServerLiveTests {
    @Test func portraitAndDefaultSilhouette() async throws {
        let client = EVEImageClient(configuration: .init(
            userAgent: UserAgent(product: "CapsuleerKit-LiveTests", version: CapsuleerKitInfo.version, contact: "+https://github.com/Crazor/CapsuleerKit"),
            cache: MemoryCacheStore()))
        let portrait = try await client.characterPortrait(2112625428, size: .px128)
        #expect(portrait.value.count > 1000)
        #expect(portrait.expires != nil)
        let image = try await client.characterPortraitImage(2112625428, size: .px128)
        #expect(image.size.width == 128)
        // Unknown IDs get CCP's default silhouette rather than an error.
        let unknown = try await client.characterPortrait(1, size: .px32)
        #expect(!unknown.value.isEmpty)
    }
}
