import CapsuleerCore
import Foundation

/// Constants for CCP's ESI.
public enum ESI {
    /// The compatibility date this build of ESIKit was generated against. Sent as
    /// `X-Compatibility-Date` on every request. Changing it means regenerating (Scripts/update-esi-spec.sh).
    public static let compatibilityDate = "2026-11-19"
    public static let baseURL = URL(string: "https://esi.evetech.net")!
}

/// An ESI OAuth scope.
public struct ESIScope: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let locationRead: ESIScope = "esi-location.read_location.v1"
    public static let shipTypeRead: ESIScope = "esi-location.read_ship_type.v1"
    public static let onlineRead: ESIScope = "esi-location.read_online.v1"
    public static let structuresRead: ESIScope = "esi-universe.read_structures.v1"
}

/// Supplies access tokens for authenticated ESI calls. Implemented by `TokenManager`; tests can supply their own.
public protocol ESITokenProvider: Sendable {
    /// A valid (not about to expire) access token for `characterID` that carries `requiredScopes`.
    /// Throws `.notAuthenticated`, `.missingScope` (without a network call) or `.reauthenticationRequired`.
    func accessToken(for characterID: Int64, requiredScopes: Set<ESIScope>) async throws -> String
    /// Called after ESI rejected `token` with 401: drop it so the next `accessToken` call refreshes.
    func invalidate(accessToken token: String, for characterID: Int64) async
}
