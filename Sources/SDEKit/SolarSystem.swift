import Foundation
import CapsuleerCore

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
    /// as 0.1, so they never read as null-sec. Confirmed in game on 2026-11-22: Egbinger (0.0346)
    /// and Ennur (0.0583) show 0.1, Balle (0.4609) shows 0.5, NK-7XO (-0.0184) shows as null-sec.
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
    /// The colour the game uses for `displayValue`, e.g. in route and system displays.
    ///
    /// Measured from in-game displays on 2026-11-22, with a client after the Exordium release,
    /// which gave 1.0 its own colour. These colours are not part of the SDE and may change with
    /// future client releases. Only the regular tiers were measured: 1.0 down to 0.1, and one
    /// colour for 0.0 and below (regular null-sec and Zarzakh). Wormhole space and Pochven were
    /// not measured; they get the colour of their displayed value (in practice the 0.0 colour).
    public var displayColor: RGBColor { Self.displayColor(forTenths: Int((displayValue * 10).rounded())) }

    /// The in-game colour for a displayed value in tenths (10 = 1.0). Values above 10 use the
    /// 1.0 colour; 0 and below use the null-sec colour. See `displayColor`.
    public static func displayColor(forTenths tenths: Int) -> RGBColor {
        displayColors[min(max(tenths, 0), 10)]
    }

    /// Index = displayed tenths, 0 (0.0 and below) through 10 (1.0).
    private static let displayColors: [RGBColor] = [
        RGBColor(red: 0x95, green: 0x4C, blue: 0x75), // 0.0 and below
        RGBColor(red: 0x7E, green: 0x35, blue: 0x2E), // 0.1
        RGBColor(red: 0xBB, green: 0x3C, blue: 0x2D), // 0.2
        RGBColor(red: 0xCB, green: 0x63, blue: 0x31), // 0.3
        RGBColor(red: 0xD7, green: 0x85, blue: 0x39), // 0.4
        RGBColor(red: 0xF6, green: 0xFB, blue: 0xA3), // 0.5
        RGBColor(red: 0x9D, green: 0xE4, blue: 0x7B), // 0.6
        RGBColor(red: 0x90, green: 0xDC, blue: 0xB5), // 0.7
        RGBColor(red: 0x83, green: 0xD3, blue: 0xF4), // 0.8
        RGBColor(red: 0x65, green: 0xA9, blue: 0xE9), // 0.9
        RGBColor(red: 0x50, green: 0x89, blue: 0xE2), // 1.0
    ]

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
