import Foundation
import Testing
@testable import SDEKit

@Suite struct ManifestTests {
    @Test func decodesTheLiveManifestShape() throws {
        let release = try JSONDecoder().decode(SDERelease.self, from: try Fixture.manifest)
        #expect(release.release == Fixture.release)
        #expect(release.buildNumber == 3724492)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 58, second: 26))
        #expect(release.releaseDate == expected)
        #expect(Set(release.tables.keys) == ["_changes", "_sde", "mapSolarSystems", "npcStations", "types"])
        let systems = try #require(release.tables["mapSolarSystems"])
        #expect(systems.version == Fixture.solarSystemsVersion)
        #expect(systems.jsonlURL == Fixture.solarSystemsJSONLURL)
        #expect(systems.recordURLTemplate == "https://sde.evetech.net/tranquility/\(Fixture.release)/mapSolarSystems/{key}.json")
    }

    @Test func toleratesMissingKeys() throws {
        let json = #"{"release":"20260101T000000Z","releaseDate":"2026-01-01T00:00:00.123Z","tables":{"t":{"version":"abc"}}}"#
        let release = try JSONDecoder().decode(SDERelease.self, from: Data(json.utf8))
        #expect(release.buildNumber == 0)
        #expect(release.tables["t"] == SDETable(version: "abc", jsonlURL: nil, recordURLTemplate: nil))
    }

    @Test func roundTripsThroughItsOwnEncoding() throws {
        let release = try JSONDecoder().decode(SDERelease.self, from: try Fixture.manifest)
        let again = try JSONDecoder().decode(SDERelease.self, from: try JSONEncoder().encode(release))
        #expect(again == release)
    }
}
