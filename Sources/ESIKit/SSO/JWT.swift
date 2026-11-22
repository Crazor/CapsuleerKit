import CapsuleerCore
import Foundation

/// A compact-serialized JWS (header.payload.signature), parsed but not yet verified.
struct JWT: Sendable {
    struct Header: Decodable, Sendable {
        var alg: String
        var kid: String?
        var typ: String?
    }

    /// The claims EVE SSO puts in its access tokens that CapsuleerKit reads.
    struct Claims: Sendable {
        var issuer: String?
        var audience: [String]
        var subject: String?
        var expiresAt: Date?
        var name: String?
        var owner: String?
        var scopes: [String]
    }

    var header: Header
    var claims: Claims
    /// `ASCII(header) "." ASCII(payload)`: the bytes the signature covers.
    var signingInput: Data
    var signature: Data

    init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Self.invalid("not a compact JWS") }
        guard let headerData = Base64URL.decode(String(parts[0])),
              let payloadData = Base64URL.decode(String(parts[1])),
              let signature = Base64URL.decode(String(parts[2])) else {
            throw Self.invalid("bad base64url")
        }
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw Self.invalid("bad header")
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            throw Self.invalid("bad payload")
        }
        claims = Claims(
            issuer: payload["iss"] as? String,
            audience: Self.strings(payload["aud"]),
            subject: payload["sub"] as? String,
            expiresAt: (payload["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            name: payload["name"] as? String,
            owner: payload["owner"] as? String,
            scopes: Self.strings(payload["scp"]))
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        self.signature = signature
    }

    /// A claim that may be a string or an array of strings.
    private static func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return string.split(separator: " ").map(String.init) }
        if let array = value as? [Any] { return array.compactMap { $0 as? String } }
        return []
    }

    static func invalid(_ reason: String) -> CapsuleerError {
        CapsuleerError(.ssoFailed, message: "Invalid access token: \(reason)")
    }
}

/// Validates EVE SSO access tokens: signature against the JWKS (RS256 or ES256, D19), then
/// `iss`, `aud`, `exp` (with leeway), and the character claims.
struct JWTValidator: Sendable {
    static let acceptedIssuers: Set<String> = ["https://login.eveonline.com", "login.eveonline.com"]
    static let eveAudience = "EVE Online"

    var clientID: String
    /// Issuers accepted in addition to EVE's (the configured login host, for tests).
    var extraIssuers: Set<String> = []
    var jwks: JWKSCache
    var timeSource: any TimeSource
    var leeway: TimeInterval = 60

    struct Validated: Sendable {
        var character: AuthorizedCharacter
        var expiresAt: Date
    }

    func validate(_ token: String) async throws -> Validated {
        let jwt = try JWT(token)
        guard let algorithm = JWSAlgorithm(rawValue: jwt.header.alg) else {
            throw JWT.invalid("unsupported alg \(jwt.header.alg)")
        }
        let verifier = try await jwks.verifier(kid: jwt.header.kid, algorithm: algorithm)
        guard verifier.verify(signature: jwt.signature, message: jwt.signingInput) else {
            throw JWT.invalid("signature does not verify")
        }

        let claims = jwt.claims
        guard let issuer = claims.issuer, Self.acceptedIssuers.union(extraIssuers).contains(issuer) else {
            throw JWT.invalid("unexpected issuer")
        }
        guard claims.audience.contains(clientID), claims.audience.contains(Self.eveAudience) else {
            throw JWT.invalid("unexpected audience")
        }
        guard let expiresAt = claims.expiresAt else { throw JWT.invalid("no exp") }
        guard expiresAt.addingTimeInterval(leeway) > timeSource.now() else { throw JWT.invalid("expired") }

        let prefix = "CHARACTER:EVE:"
        guard let subject = claims.subject, subject.hasPrefix(prefix),
              let id = Int64(subject.dropFirst(prefix.count)), id > 0 else {
            throw JWT.invalid("unexpected sub")
        }
        guard let name = claims.name, let owner = claims.owner, !owner.isEmpty else {
            throw JWT.invalid("missing name or owner")
        }
        let character = AuthorizedCharacter(
            id: id, name: name, ownerHash: owner,
            scopes: Set(claims.scopes.map(ESIScope.init(rawValue:))))
        return Validated(character: character, expiresAt: expiresAt)
    }
}
