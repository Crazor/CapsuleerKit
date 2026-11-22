import Foundation

/// A name in every language the SDE provides. English is always present.
///
/// Encoded as the SDE's plain object, e.g. `{"en": "Repute", "de": "Leumund", …}`.
public struct LocalizedString: Sendable, Hashable, Codable {
    /// The English name.
    public var en: String
    /// Every language code mapped to its text, including `en`.
    public var all: [String: String]

    /// Creates a localised string. `en` is added to (or replaces the `en` entry of) `translations`.
    public init(en: String, translations: [String: String] = [:]) {
        self.en = en
        var all = translations
        all["en"] = en
        self.all = all
    }

    /// The text for a language code such as `de`, `fr`, `ja`, `ko`, `ru`, `zh` or `es`.
    public subscript(language: String) -> String? { all[language] }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let all = try container.decode([String: String].self)
        guard let en = all["en"] else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Localised string has no English (\"en\") value")
        }
        self.en = en
        self.all = all
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(all)
    }
}

/// One solar system from the SDE table `mapSolarSystems`. Fields SDEKit doesn't model are ignored.
public struct SolarSystem: Sendable, Hashable, Codable, Identifiable {
    /// The solar system ID (JSON `solarSystemID`), e.g. 30000142 for Jita.
    public var id: Int64
    /// The system's name in every language.
    public var name: LocalizedString
    /// The exact security status, e.g. 0.945913. Use `security` for the in-game display.
    public var securityStatus: Double
    /// The region the system belongs to.
    public var regionID: Int64
    /// The constellation the system belongs to.
    public var constellationID: Int64
    /// The owning NPC faction, if any.
    public var factionID: Int64?
    /// The wormhole class (also set for many k-space systems).
    public var wormholeClassID: Int64?
    /// The SDE's security class letter, if any.
    public var securityClass: String?

    /// Creates a solar system.
    public init(id: Int64, name: LocalizedString, securityStatus: Double, regionID: Int64, constellationID: Int64,
                factionID: Int64? = nil, wormholeClassID: Int64? = nil, securityClass: String? = nil) {
        self.id = id
        self.name = name
        self.securityStatus = securityStatus
        self.regionID = regionID
        self.constellationID = constellationID
        self.factionID = factionID
        self.wormholeClassID = wormholeClassID
        self.securityClass = securityClass
    }

    private enum CodingKeys: String, CodingKey {
        case id = "solarSystemID"
        case name, securityStatus, regionID, constellationID, factionID, wormholeClassID, securityClass
    }

    /// The security status as shown in game, with its band.
    public var security: SecurityStatus { SecurityStatus(value: securityStatus, regionID: regionID) }
}

/// Display helper for a system's security status.
public struct SecurityStatus: Sendable, Hashable {
    /// The broad security band.
    public enum Band: String, Sendable {
        /// Displayed 0.5 and above.
        case high
        /// Displayed above 0.0 and below 0.5.
        case low
        /// Displayed 0.0 and below.
        case null
        /// Wormhole space (region IDs from 11000000).
        case wormhole
        /// Pochven (region 10000070).
        case pochven
    }

    /// The Pochven region.
    public static let pochvenRegionID: Int64 = 10000070
    /// Region IDs from here on are wormhole space.
    public static let firstWormholeRegionID: Int64 = 11000000

    /// The exact value from the SDE.
    public var value: Double
    /// The value with one decimal, as shown in game.
    ///
    /// Rounded half up to one decimal, except that values greater than 0.0 and below 0.05 display
    /// as 0.1, so they never read as null-sec. This rule matches common community understanding;
    /// to be verified in game (DESIGN.md open question 2).
    public var displayValue: Double
    /// `displayValue` formatted with one decimal, e.g. "0.5", "-0.1".
    public var formatted: String
    /// The band, from the region and `displayValue`.
    public var band: Band

    /// Computes the display value and band for `value` in `regionID`.
    public init(value: Double, regionID: Int64) {
        self.value = value
        let tenths = Self.displayTenths(value)
        displayValue = Double(tenths) / 10
        formatted = Self.format(tenths: tenths)
        if regionID == Self.pochvenRegionID {
            band = .pochven
        } else if regionID >= Self.firstWormholeRegionID {
            band = .wormhole
        } else if tenths >= 5 {
            band = .high
        } else if tenths > 0 {
            band = .low
        } else {
            band = .null
        }
    }

    /// The displayed value in tenths. See `displayValue` for the rule.
    static func displayTenths(_ value: Double) -> Int {
        if value > 0, value < 0.05 { return 1 }
        // Half up; the epsilon absorbs binary error so 0.45 (stored as 0.4499999…) still reaches 0.5.
        return Int((value * 10 + 0.5 + 1e-9).rounded(.down))
    }

    static func format(tenths: Int) -> String {
        let sign = tenths < 0 ? "-" : ""
        let magnitude = abs(tenths)
        return "\(sign)\(magnitude / 10).\(magnitude % 10)"
    }
}
