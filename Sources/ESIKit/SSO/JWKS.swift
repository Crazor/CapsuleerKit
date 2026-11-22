import CapsuleerCore
import CryptoKit
import Foundation
import Security

/// One key from a JSON Web Key Set (RFC 7517). Only the members CapsuleerKit uses.
struct JWK: Decodable, Sendable, Hashable {
    var kty: String
    var kid: String?
    var alg: String?
    var use: String?
    // RSA
    var n: String?
    var e: String?
    // EC
    var crv: String?
    var x: String?
    var y: String?
}

struct JWKSet: Decodable, Sendable {
    var keys: [JWK]

    private enum CodingKeys: String, CodingKey { case keys }

    /// Skips keys that fail to decode instead of rejecting the whole set.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .keys)
        var keys: [JWK] = []
        while !list.isAtEnd {
            if let key = try? list.decode(JWK.self) { keys.append(key) } else { _ = try? list.decode(Discard.self) }
        }
        self.keys = keys
    }

    init(keys: [JWK]) { self.keys = keys }

    private struct Discard: Decodable {}
}

/// JWS algorithms CapsuleerKit accepts. Everything else (including `none` and HS256) is rejected.
enum JWSAlgorithm: String, Sendable {
    case rs256 = "RS256"
    case es256 = "ES256"
}

/// Verifies a JWS signature with one public key.
protocol SignatureVerifier: Sendable {
    func verify(signature: Data, message: Data) -> Bool
}

/// RS256 (RSASSA-PKCS1-v1_5 with SHA-256) via Security.framework.
struct RSASignatureVerifier: SignatureVerifier {
    /// `SecKey` is a CF type that is immutable once created and documented as thread-safe for
    /// verification, so sharing it across concurrency domains is fine.
    nonisolated(unsafe) let key: SecKey

    /// Builds the key from the JWK's base64url modulus and exponent. Requires at least 2048 bits.
    init(modulus: Data, exponent: Data) throws {
        let n = Self.stripLeadingZeros([UInt8](modulus))
        let e = Self.stripLeadingZeros([UInt8](exponent))
        guard n.count * 8 >= 2048, !e.isEmpty else {
            throw CapsuleerError(.ssoFailed, message: "JWKS RSA key is too small or malformed")
        }
        let der = DER.sequence(DER.integer(n) + DER.integer(e))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: n.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
            let detail = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown error"
            throw CapsuleerError(.ssoFailed, message: "Could not create RSA key from JWKS: \(detail)")
        }
        self.key = key
    }

    func verify(signature: Data, message: Data) -> Bool {
        SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    private static func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        Array(bytes.drop { $0 == 0 })
    }
}

/// ES256 (ECDSA P-256 with SHA-256) via CryptoKit. JOSE signatures are raw `r || s` (64 bytes).
struct P256SignatureVerifier: SignatureVerifier {
    let key: P256.Signing.PublicKey

    init(x: Data, y: Data) throws {
        guard x.count == 32, y.count == 32 else {
            throw CapsuleerError(.ssoFailed, message: "JWKS EC key has malformed coordinates")
        }
        do {
            key = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
        } catch {
            throw CapsuleerError(.ssoFailed, message: "Could not create P-256 key from JWKS", underlying: error)
        }
    }

    func verify(signature: Data, message: Data) -> Bool {
        guard signature.count == 64, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: message)
    }
}

extension JWK {
    /// Whether this key may verify `algorithm` (matching `kty`/`crv`, and `alg`/`use` when present).
    func isUsable(for algorithm: JWSAlgorithm) -> Bool {
        if let alg, alg != algorithm.rawValue { return false }
        if let use, use != "sig" { return false }
        switch algorithm {
        case .rs256: return kty == "RSA"
        case .es256: return kty == "EC" && crv == "P-256"
        }
    }

    func verifier(for algorithm: JWSAlgorithm) throws -> any SignatureVerifier {
        switch algorithm {
        case .rs256:
            guard let n = n.flatMap(Base64URL.decode), let e = e.flatMap(Base64URL.decode) else {
                throw CapsuleerError(.ssoFailed, message: "JWKS RSA key lacks n/e")
            }
            return try RSASignatureVerifier(modulus: n, exponent: e)
        case .es256:
            guard let x = x.flatMap(Base64URL.decode), let y = y.flatMap(Base64URL.decode) else {
                throw CapsuleerError(.ssoFailed, message: "JWKS EC key lacks x/y")
            }
            return try P256SignatureVerifier(x: x, y: y)
        }
    }
}

/// Minimal DER encoding for a PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// A non-negative INTEGER from big-endian magnitude bytes (adds a 0x00 when the high bit is set).
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var content = magnitude.isEmpty ? [0] : magnitude
        if content[0] & 0x80 != 0 { content.insert(0, at: 0) }
        return [0x02] + length(content.count) + content
    }

    static func sequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + length(content.count) + content
    }
}

/// The cached JWKS. Fetches lazily, shares concurrent fetches, and refetches once when a token
/// names a `kid` the cached set doesn't have (key rotation).
actor JWKSCache {
    private let fetch: @Sendable () async throws -> JWKSet
    private var keys: [JWK]?
    private var inFlight: Task<[JWK], any Error>?

    init(fetch: @escaping @Sendable () async throws -> JWKSet) {
        self.fetch = fetch
    }

    /// The verifier for a token header's `kid` and `alg`.
    func verifier(kid: String?, algorithm: JWSAlgorithm) async throws -> any SignatureVerifier {
        if let keys, let key = Self.select(from: keys, kid: kid, algorithm: algorithm) {
            return try key.verifier(for: algorithm)
        }
        // Unknown kid (or nothing cached yet): fetch once.
        let fresh = try await load(force: keys != nil)
        guard let key = Self.select(from: fresh, kid: kid, algorithm: algorithm) else {
            throw CapsuleerError(.ssoFailed, message: "No JWKS key for kid \(kid ?? "(none)") and alg \(algorithm.rawValue)")
        }
        return try key.verifier(for: algorithm)
    }

    /// Fetches the key set unless it is already cached.
    func preload() async throws {
        _ = try await load(force: false)
    }

    private func load(force: Bool) async throws -> [JWK] {
        if !force, let keys { return keys }
        if let inFlight { return try await inFlight.value }
        let task = Task { [fetch] in try await fetch().keys }
        inFlight = task
        defer { inFlight = nil }
        let fetched = try await task.value
        keys = fetched
        return fetched
    }

    static func select(from keys: [JWK], kid: String?, algorithm: JWSAlgorithm) -> JWK? {
        let usable = keys.filter { $0.isUsable(for: algorithm) }
        if let kid { return usable.first { $0.kid == kid } }
        // No kid in the header: only unambiguous.
        return usable.count == 1 ? usable[0] : nil
    }
}
