import Foundation

/// Public information about a character (`GET /characters/{id}`).
public struct CharacterPublicInfo: Sendable, Hashable, Codable {
    public var name: String
    public var corporationID: Int64
    public var allianceID: Int64?
    public var factionID: Int64?
    public var birthday: Date
    public var securityStatus: Double?

    public init(name: String, corporationID: Int64, allianceID: Int64?, factionID: Int64?, birthday: Date, securityStatus: Double?) {
        self.name = name
        self.corporationID = corporationID
        self.allianceID = allianceID
        self.factionID = factionID
        self.birthday = birthday
        self.securityStatus = securityStatus
    }
}

/// Where a character is (`GET /characters/{id}/location`).
public struct CharacterLocation: Sendable, Hashable, Codable {
    public var solarSystemID: Int64
    /// NPC station the character is docked in.
    public var stationID: Int64?
    /// Player structure the character is docked in.
    public var structureID: Int64?
    public var isDocked: Bool { stationID != nil || structureID != nil }

    public init(solarSystemID: Int64, stationID: Int64?, structureID: Int64?) {
        self.solarSystemID = solarSystemID
        self.stationID = stationID
        self.structureID = structureID
    }
}

/// The character's active ship (`GET /characters/{id}/ship`).
public struct CharacterShip: Sendable, Hashable, Codable {
    /// Ship type; resolve its name with SDEKit (`types` table).
    public var typeID: Int64
    public var itemID: Int64
    public var name: String

    public init(typeID: Int64, itemID: Int64, name: String) {
        self.typeID = typeID
        self.itemID = itemID
        self.name = name
    }
}

/// Online state (`GET /characters/{id}/online`).
public struct CharacterOnline: Sendable, Hashable, Codable {
    public var isOnline: Bool
    public var lastLogin: Date?
    public var lastLogout: Date?
    public var logins: Int?

    public init(isOnline: Bool, lastLogin: Date?, lastLogout: Date?, logins: Int?) {
        self.isOnline = isOnline
        self.lastLogin = lastLogin
        self.lastLogout = lastLogout
        self.logins = logins
    }
}

/// A player structure (`GET /universe/structures/{id}`, needs `esi-universe.read_structures.v1`
/// and docking access).
public struct StructureInfo: Sendable, Hashable, Codable {
    public var name: String
    public var ownerID: Int64
    public var solarSystemID: Int64
    public var typeID: Int64?

    public init(name: String, ownerID: Int64, solarSystemID: Int64, typeID: Int64?) {
        self.name = name
        self.ownerID = ownerID
        self.solarSystemID = solarSystemID
        self.typeID = typeID
    }
}

/// One entry of `POST /universe/names` or `/universe/ids`.
public struct ResolvedEntity: Sendable, Hashable, Codable {
    public struct Category: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let agent = Category(rawValue: "agent")
        public static let alliance = Category(rawValue: "alliance")
        public static let character = Category(rawValue: "character")
        public static let constellation = Category(rawValue: "constellation")
        public static let corporation = Category(rawValue: "corporation")
        public static let faction = Category(rawValue: "faction")
        public static let inventoryType = Category(rawValue: "inventory_type")
        public static let region = Category(rawValue: "region")
        public static let solarSystem = Category(rawValue: "solar_system")
        public static let station = Category(rawValue: "station")
    }

    public var id: Int64
    public var name: String
    public var category: Category

    public init(id: Int64, name: String, category: Category) {
        self.id = id
        self.name = name
        self.category = category
    }
}
