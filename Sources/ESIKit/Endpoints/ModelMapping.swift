import Foundation
import OpenAPIRuntime

// Mappings from the generated `Components.Schemas` types to the public models. Spec churn
// (renamed or new fields) is absorbed here and never reaches apps.

extension CharacterPublicInfo {
    init(_ schema: Components.Schemas.CharactersDetail) {
        self.init(name: schema.name, corporationID: schema.corporationId, allianceID: schema.allianceId,
                  factionID: schema.factionId, birthday: schema.birthday, securityStatus: schema.securityStatus)
    }
}

extension CharacterLocation {
    init(_ schema: Components.Schemas.CharactersLocation) {
        self.init(solarSystemID: schema.solarSystemId, stationID: schema.stationId, structureID: schema.structureId)
    }
}

extension CharacterShip {
    init(_ schema: Components.Schemas.CharactersShip) {
        self.init(typeID: schema.shipTypeId, itemID: schema.shipItemId, name: schema.shipName)
    }
}

extension CharacterOnline {
    init(_ schema: Components.Schemas.CharactersOnline) {
        self.init(isOnline: schema.online, lastLogin: schema.lastLogin, lastLogout: schema.lastLogout,
                  logins: schema.logins.map { Int(clamping: $0) })
    }
}

extension StructureInfo {
    init(_ schema: Components.Schemas.UniverseStructuresStructureIdGet) {
        self.init(name: schema.name, ownerID: schema.ownerId, solarSystemID: schema.solarSystemId, typeID: schema.typeId)
    }
}

extension ResolvedEntity {
    init(_ schema: Components.Schemas.UniverseNamesPostPayload) {
        self.init(id: schema.id, name: schema.name, category: Category(rawValue: schema.category.rawValue))
    }

    /// All entities of a `POST /universe/ids` response, per category, in category order.
    static func entities(from schema: Components.Schemas.UniverseIdsPost) -> [ResolvedEntity] {
        func map(_ items: [(id: Int64?, name: String?)]?, _ category: Category) -> [ResolvedEntity] {
            (items ?? []).compactMap { item in
                guard let id = item.id, let name = item.name else { return nil }
                return ResolvedEntity(id: id, name: name, category: category)
            }
        }
        return map(schema.agents?.map { ($0.id, $0.name) }, .agent)
            + map(schema.alliances?.map { ($0.id, $0.name) }, .alliance)
            + map(schema.characters?.map { ($0.id, $0.name) }, .character)
            + map(schema.constellations?.map { ($0.id, $0.name) }, .constellation)
            + map(schema.corporations?.map { ($0.id, $0.name) }, .corporation)
            + map(schema.factions?.map { ($0.id, $0.name) }, .faction)
            + map(schema.inventoryTypes?.map { ($0.id, $0.name) }, .inventoryType)
            + map(schema.regions?.map { ($0.id, $0.name) }, .region)
            + map(schema.stations?.map { ($0.id, $0.name) }, .station)
            + map(schema.systems?.map { ($0.id, $0.name) }, .solarSystem)
    }
}

/// ESI's `date-time` strings: ISO 8601, with or without fractional seconds.
struct ESIDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    func decode(_ string: String) throws -> Date {
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected an ISO 8601 date-time, got \(string)"))
    }
}
