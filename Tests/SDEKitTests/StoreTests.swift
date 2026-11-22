import Foundation
import Testing
import CapsuleerCore
@testable import SDEKit

@Suite struct StoreTests {
    static func sampleRelease() throws -> SDEStoredRelease {
        let release = try JSONDecoder().decode(SDERelease.self, from: try Fixture.manifest)
        return SDEStoredRelease(release: release, lastChecked: Date(timeIntervalSince1970: 1_800_000_123.456))
    }

    static func sampleTable() throws -> SDEStoredTable<SolarSystem> {
        let systems = try JSONLines.decode(SolarSystem.self, from: try Fixture.solarSystemsJSONL, url: nil)
        return SDEStoredTable(release: Fixture.release, version: Fixture.solarSystemsVersion,
                              fetchedAt: Date(timeIntervalSince1970: 1_800_000_000.25), records: systems)
    }

    @Test func diskStoreRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SDEKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = try Self.sampleRelease()
        let table = try Self.sampleTable()

        let empty = DiskSDEStore(directory: directory)
        #expect(try await empty.loadRelease() == nil)
        #expect(try await empty.loadTable(named: "mapSolarSystems", as: SolarSystem.self) == nil)

        try await empty.saveRelease(release)
        try await empty.saveTable(table, named: "mapSolarSystems")

        let reopened = DiskSDEStore(directory: directory)
        #expect(try await reopened.loadRelease() == release)
        let loaded = try #require(try await reopened.loadTable(named: "mapSolarSystems", as: SolarSystem.self))
        #expect(loaded.release == table.release)
        #expect(loaded.version == table.version)
        #expect(loaded.fetchedAt == table.fetchedAt)
        #expect(loaded.records == table.records)

        // Saving again replaces the file.
        var smaller = table
        smaller.records = Array(table.records.prefix(2))
        smaller.version = "v2"
        try await reopened.saveTable(smaller, named: "mapSolarSystems")
        #expect(try await DiskSDEStore(directory: directory).loadTable(named: "mapSolarSystems", as: SolarSystem.self)?.records.count == 2)
    }

    @Test func diskStoreReportsCorruptFilesAsStorageErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SDEKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("release.json"))
        let error = await #expect(throws: CapsuleerError.self) { try await DiskSDEStore(directory: directory).loadRelease() }
        #expect(error?.code == .storage)
    }

    @Test func inMemoryStoreRoundTrip() async throws {
        let store: any SDEStore = InMemorySDEStore()
        let release = try Self.sampleRelease()
        let table = try Self.sampleTable()
        try await store.saveRelease(release)
        try await store.saveTable(table, named: "mapSolarSystems")
        #expect(try await store.loadRelease() == release)
        #expect(try await store.loadTable(named: "mapSolarSystems", as: SolarSystem.self)?.records == table.records)
        #expect(try await store.loadTable(named: "other", as: SolarSystem.self) == nil)
    }
}
