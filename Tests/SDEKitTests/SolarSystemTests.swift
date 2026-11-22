import Foundation
import Testing
@testable import SDEKit

@Suite struct SolarSystemTests {
    static let table: SolarSystemTable = {
        let systems = try! JSONLines.decode(SolarSystem.self, from: try! Fixture.solarSystemsJSONL, url: nil)
        return SolarSystemTable(release: Fixture.release, version: Fixture.solarSystemsVersion, fetchedAt: Date(), systems: systems)
    }()

    func system(_ name: String) throws -> SolarSystem {
        try #require(Self.table.system(named: name))
    }

    @Test func decodesTheSingleRecord() throws {
        let jita = try JSONDecoder().decode(SolarSystem.self, from: try Fixture.jitaRecord)
        #expect(jita.id == 30000142)
        #expect(jita.name.en == "Jita")
        #expect(jita.name["ja"] == "ジタ")
        #expect(jita.name.all.count == 8)
        #expect(jita.securityStatus == 0.945913)
        #expect(jita.regionID == 10000002)
        #expect(jita.constellationID == 20000020)
        #expect(jita.factionID == 500006)
        #expect(jita.wormholeClassID == nil)
        #expect(jita.securityClass == "B")
    }

    @Test func lookupByID() throws {
        #expect(Self.table.system(id: 30000142)?.name.en == "Jita")
        #expect(Self.table.system(id: 31000005)?.name.en == "Thera")
        #expect(Self.table.system(id: 1) == nil)
        #expect(Self.table.all.map(\.id) == Self.table.all.map(\.id).sorted())
    }

    @Test(arguments: [
        ("Jita", 30000142), ("jita", 30000142), ("JITA", 30000142), ("  Jita\n", 30000142),
        ("HED-GP", 30001161), ("hed-gp", 30001161),
        ("Théra", 31000005), ("thera", 31000005), ("Égbinger", 30002420),
        ("Leumund", 30100047), ("leumund", 30100047), ("Repute", 30100047),
        ("Reflexion", 30100040), ("Ratiocinate", 30100040),
        ("ジタ", 30000142), ("吉他", 30000142),
    ] as [(String, Int64)])
    func lookupByName(name: String, id: Int64) {
        #expect(Self.table.system(named: name)?.id == id)
    }

    @Test func unknownNameIsNil() {
        #expect(Self.table.system(named: "Nowhere") == nil)
        #expect(Self.table.system(named: "") == nil)
    }

    @Test func englishNamesWinOnClashes() {
        // System 2's German name folds to system 1's English name.
        let a = SolarSystem(id: 2, name: LocalizedString(en: "Beta", translations: ["de": "Álpha"]), securityStatus: 0.5, regionID: 1, constellationID: 1)
        let b = SolarSystem(id: 1, name: LocalizedString(en: "Alpha"), securityStatus: 0.5, regionID: 1, constellationID: 1)
        let table = SolarSystemTable(release: "r", version: "v", fetchedAt: Date(), systems: [a, b])
        #expect(table.system(named: "alpha")?.id == 1)
        #expect(table.system(named: "beta")?.id == 2)
    }

    @Test(arguments: [
        ("Jita", 0.9, "0.9", SecurityStatus.Band.high),
        ("Perimeter", 0.9, "0.9", .high),
        ("Amarr", 0.9, "0.9", .high),
        ("Ratiocinate", 1.0, "1.0", .high),
        ("HED-GP", -0.1, "-0.1", .null),
        ("Egbinger", 0.1, "0.1", .low),
        ("Tama", 0.3, "0.3", .low),
        ("Asabona", 0.3, "0.3", .low),
        ("Thera", -1.0, "-1.0", .wormhole),
        ("Kuharah", -1.0, "-1.0", .pochven),
    ] as [(String, Double, String, SecurityStatus.Band)])
    func securityDisplay(name: String, display: Double, formatted: String, band: SecurityStatus.Band) throws {
        let security = try system(name).security
        #expect(security.displayValue == display)
        #expect(security.formatted == formatted)
        #expect(security.band == band)
    }

    @Test(arguments: [
        (0.45, 0.5, "0.5", SecurityStatus.Band.high),
        (0.44, 0.4, "0.4", .low),
        (0.449999, 0.4, "0.4", .low),
        (0.05, 0.1, "0.1", .low),
        (0.0001, 0.1, "0.1", .low),
        (0.0, 0.0, "0.0", .null),
        (-0.04, 0.0, "0.0", .null),
        (-0.05, 0.0, "0.0", .null),
        (-0.06, -0.1, "-0.1", .null),
        (0.15, 0.2, "0.2", .low),
        (0.35, 0.4, "0.4", .low),
        (0.95, 1.0, "1.0", .high),
    ] as [(Double, Double, String, SecurityStatus.Band)])
    func securityRounding(value: Double, display: Double, formatted: String, band: SecurityStatus.Band) {
        let security = SecurityStatus(value: value, regionID: 10000002)
        #expect(security.displayValue == display)
        #expect(security.formatted == formatted)
        #expect(security.band == band)
    }

    @Test func wormholeBandStartsAtRegion11000000() {
        #expect(SecurityStatus(value: -1, regionID: 11000000).band == .wormhole)
        #expect(SecurityStatus(value: -1, regionID: 10999999).band == .null)
    }

    @Test func localizedStringRequiresEnglish() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LocalizedString.self, from: Data(#"{"de":"Leumund"}"#.utf8))
        }
    }
}
