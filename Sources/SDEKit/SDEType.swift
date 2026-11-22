import CapsuleerCore
import Foundation

/// An item type from the SDE `types` table (ships, modules, …). Only the commonly needed fields
/// are decoded; use `SDEClient.record(_:table:key:)` with your own model for more.
public struct SDEType: Sendable, Hashable, Codable, Identifiable {
    /// JSON "typeID".
    public var id: Int64
    public var name: LocalizedString
    public var groupID: Int64
    public var marketGroupID: Int64?
    public var metaGroupID: Int64?
    public var raceID: Int64?
    public var factionID: Int64?
    public var published: Bool

    public init(id: Int64, name: LocalizedString, groupID: Int64, marketGroupID: Int64? = nil, metaGroupID: Int64? = nil,
                raceID: Int64? = nil, factionID: Int64? = nil, published: Bool = true) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.marketGroupID = marketGroupID
        self.metaGroupID = metaGroupID
        self.raceID = raceID
        self.factionID = factionID
        self.published = published
    }

    enum CodingKeys: String, CodingKey {
        case id = "typeID", name, groupID, marketGroupID, metaGroupID, raceID, factionID, published
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(LocalizedString.self, forKey: .name)
        groupID = try c.decode(Int64.self, forKey: .groupID)
        marketGroupID = try c.decodeIfPresent(Int64.self, forKey: .marketGroupID)
        metaGroupID = try c.decodeIfPresent(Int64.self, forKey: .metaGroupID)
        raceID = try c.decodeIfPresent(Int64.self, forKey: .raceID)
        factionID = try c.decodeIfPresent(Int64.self, forKey: .factionID)
        published = try c.decodeIfPresent(Bool.self, forKey: .published) ?? false
    }
}

extension SDEClient {
    /// One type record from the pinned release, e.g. a ship type from `CharacterShip.typeID`.
    /// Records are immutable per release, so repeats come from the HTTP cache (also offline).
    public func type(_ typeID: Int64) async throws -> Response<SDEType> {
        try await record(SDEType.self, table: "types", key: typeID)
    }
}
