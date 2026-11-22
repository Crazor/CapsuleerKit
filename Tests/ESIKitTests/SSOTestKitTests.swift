import CryptoKit
import Foundation
import os
import Security
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

// Shared fixtures for the SSO, JWT and TokenManager tests. Keys are generated at test time;
// nothing here is a real secret.

let ssoLoginBase = URL(string: "https://login.eveonline.com")!
let ssoClientID = "test-client-id"
let ssoCallback = URL(string: "eveauth-overseer://callback")!
let ssoUserAgent = UserAgent(product: "Tests", version: "1.0", contact: "+https://example.com/tests")

/// Test signing keys and their JWKS representation.
enum SSOTestKeys {
    /// SecKey is an immutable CF object; sharing it between tests is fine.
    nonisolated(unsafe) static let rsaPrivate: SecKey = {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            fatalError("RSA key generation failed: \(String(describing: error?.takeRetainedValue()))")
        }
        return key
    }()

    static let ecPrivate = P256.Signing.PrivateKey()
    static let otherECPrivate = P256.Signing.PrivateKey()

    static let rsaKID = "JWT-Signature-Key"
    static let ecKID = "ec-key"

    static var rsaJWK: [String: Any] {
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(rsaPrivate)!, nil)! as Data
        let (n, e) = parsePKCS1(der)
        return ["kty": "RSA", "alg": "RS256", "use": "sig", "kid": rsaKID, "n": Base64URL.encode(n), "e": Base64URL.encode(e)]
    }

    static func ecJWK(_ key: P256.Signing.PrivateKey = ecPrivate, kid: String = ecKID) -> [String: Any] {
        let raw = key.publicKey.x963Representation.dropFirst()
        return ["kty": "EC", "alg": "ES256", "use": "sig", "crv": "P-256", "kid": kid,
                "x": Base64URL.encode(Data(raw.prefix(32))), "y": Base64URL.encode(Data(raw.suffix(32)))]
    }

    static func jwks(_ keys: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["keys": keys])
    }

    /// Splits a PKCS#1 RSAPublicKey DER into modulus and exponent.
    private static func parsePKCS1(_ der: Data) -> (Data, Data) {
        var bytes = [UInt8](der)[...]
        func readLength() -> Int {
            let first = bytes.removeFirst()
            if first < 0x80 { return Int(first) }
            var length = 0
            for _ in 0..<Int(first & 0x7F) { length = length << 8 | Int(bytes.removeFirst()) }
            return length
        }
        precondition(bytes.removeFirst() == 0x30)
        _ = readLength()
        precondition(bytes.removeFirst() == 0x02)
        let nLength = readLength()
        let n = Data(bytes.prefix(nLength)); bytes = bytes.dropFirst(nLength)
        precondition(bytes.removeFirst() == 0x02)
        let eLength = readLength()
        let e = Data(bytes.prefix(eLength))
        return (n, e)
    }
}

enum SSOTestSigner {
    case rs256
    case es256(P256.Signing.PrivateKey = SSOTestKeys.ecPrivate)
    case none
}

/// A signed access token with EVE's claim layout.
func makeAccessToken(
    characterID: Int64 = 2112345678, name: String = "Test Pilot", owner: String = "owner-hash-1",
    scopes: [String] = ["esi-location.read_location.v1"], scopeAsString: Bool = false,
    issuer: String = "https://login.eveonline.com", audience: [String] = [ssoClientID, "EVE Online"],
    expiresAt: Date, signer: SSOTestSigner = .rs256, kid: String? = nil, alg: String? = nil, tamper: Bool = false
) -> String {
    var header: [String: Any] = ["typ": "JWT"]
    switch signer {
    case .rs256: header["alg"] = "RS256"; header["kid"] = SSOTestKeys.rsaKID
    case .es256: header["alg"] = "ES256"; header["kid"] = SSOTestKeys.ecKID
    case .none: header["alg"] = "none"
    }
    if let kid { header["kid"] = kid }
    if let alg { header["alg"] = alg }
    let claims: [String: Any] = [
        "scp": scopeAsString ? (scopes.first ?? "") as Any : scopes as Any,
        "jti": UUID().uuidString, "kid": SSOTestKeys.rsaKID,
        "sub": "CHARACTER:EVE:\(characterID)", "azp": ssoClientID, "tenant": "tranquility", "tier": "live",
        "region": "world", "aud": audience, "name": name, "owner": owner,
        "exp": Int(expiresAt.timeIntervalSince1970), "iat": Int(expiresAt.timeIntervalSince1970) - 1200,
        "iss": issuer,
    ]
    let h = Base64URL.encode(try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
    let p = Base64URL.encode(try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
    let input = Data("\(h).\(p)".utf8)
    var signature: Data
    switch signer {
    case .rs256:
        signature = SecKeyCreateSignature(SSOTestKeys.rsaPrivate, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
    case .es256(let key):
        signature = try! key.signature(for: input).rawRepresentation
    case .none:
        signature = Data()
    }
    if tamper { signature[signature.startIndex] ^= 0xFF }
    return "\(h).\(p).\(Base64URL.encode(signature))"
}

/// Thread-safe mutable box for test state shared with mock handlers.
final class SSOLocked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
    func update<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R { lock.withLock { body(&$0) } }
}

/// Records client events.
final class SSOEventLog: Sendable {
    private let events = SSOLocked<[ClientEvent]>([])
    func record(_ event: ClientEvent) { events.update { $0.append(event) } }
    var all: [ClientEvent] { events.value }
    func count(_ kind: ClientEvent.Kind) -> Int { all.filter { $0.kind == kind }.count }
}

/// Collects log lines to check that tokens never appear.
final class SSOLogRecorder: LogSink {
    private let lines = SSOLocked<[String]>([])
    func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        lines.update { $0.append("\(message) \(metadata) \(privateMetadata)") }
    }
    var text: String { lines.value.joined(separator: "\n") }
}

/// A mock login server: metadata, JWKS and scriptable token/revoke endpoints.
final class MockLoginServer: Sendable {
    typealias TokenHandler = @Sendable (_ form: [String: String]) async throws -> HTTPResponse

    let transport = MockTransport()
    let time = ManualTimeSource()
    let jwksBody = SSOLocked<Data>(SSOTestKeys.jwks([SSOTestKeys.rsaJWK, SSOTestKeys.ecJWK()]))
    let metadataStatus = SSOLocked<Int>(200)
    let tokenHandler = SSOLocked<TokenHandler?>(nil)
    let revokeStatus = SSOLocked<Int>(200)
    let jwksStatus = SSOLocked<Int>(200)
    /// Runs before the revoke endpoint answers (to hold a revocation open).
    let revokeHandler = SSOLocked<(@Sendable () async throws -> Void)?>(nil)

    init() {
        transport.setHandler { [self] request in try await self.handle(request) }
    }

    func makeClient(callbackURL: URL = ssoCallback, logSink: any LogSink = NullLogSink()) -> SSOClient {
        SSOClient(
            configuration: SSOConfiguration(clientID: ssoClientID, callbackURL: callbackURL, defaultScopes: [.locationRead]),
            userAgent: ssoUserAgent, transport: transport, logSink: logSink, timeSource: time)
    }

    func requests(path: String) -> [HTTPRequest] { transport.requests.filter { $0.url.path == path } }
    var tokenRequests: [HTTPRequest] { requests(path: "/v2/oauth/token") }
    var revokeRequests: [HTTPRequest] { requests(path: "/v2/oauth/revoke") }
    var jwksRequests: [HTTPRequest] { requests(path: "/oauth/jwks") }

    static func form(_ request: HTTPRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: request.body ?? Data(), as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    /// Answers the token endpoint with a fresh token pair.
    func tokenResponse(accessToken: String, refreshToken: String = "refresh-2", url: URL = URL(string: "https://login.eveonline.com/v2/oauth/token")!) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: [
            "access_token": accessToken, "expires_in": 1199, "token_type": "Bearer", "refresh_token": refreshToken,
        ])
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body, url: url)
    }

    static func oauthError(_ status: Int, _ error: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data("{\"error\":\"\(error)\",\"error_description\":\"test\"}".utf8),
                     url: URL(string: "https://login.eveonline.com/v2/oauth/token")!)
    }

    private func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url
        switch url.path {
        case "/.well-known/oauth-authorization-server":
            let body = Data("""
            {"issuer":"https://login.eveonline.com","authorization_endpoint":"https://login.eveonline.com/v2/oauth/authorize",
             "token_endpoint":"https://login.eveonline.com/v2/oauth/token","revocation_endpoint":"https://login.eveonline.com/v2/oauth/revoke",
             "jwks_uri":"https://login.eveonline.com/oauth/jwks","code_challenge_methods_supported":["S256"]}
            """.utf8)
            return HTTPResponse(status: metadataStatus.value, body: body, url: url)
        case "/oauth/jwks":
            return HTTPResponse(status: jwksStatus.value, body: jwksBody.value, url: url)
        case "/v2/oauth/token":
            guard let handler = tokenHandler.value else { return HTTPResponse(status: 500, url: url) }
            return try await handler(Self.form(request))
        case "/v2/oauth/revoke":
            if let handler = revokeHandler.value { try await handler() }
            return HTTPResponse(status: revokeStatus.value, url: url)
        default:
            return HTTPResponse(status: 404, url: url)
        }
    }
}

/// Polls `condition` until it holds (or fails the wait after ~5 s).
func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for a condition")
}

/// A scripted `AuthorizationSession` that answers like EVE SSO would.
struct ScriptedSession: AuthorizationSession {
    var respond: @Sendable (_ authorizeURL: URL, _ callbackURL: URL) throws -> URL

    /// Redirects to the callback with `code` and the request's `state`.
    static func success(code: String = "auth-code") -> ScriptedSession {
        ScriptedSession { authorizeURL, callbackURL in
            let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
            return components.url!
        }
    }

    func start(authorizeURL: URL, callbackURL: URL) async throws -> URL { try respond(authorizeURL, callbackURL) }
}

@Test func testKitProducesVerifiableTokens() async throws {
    let server = MockLoginServer()
    let token = makeAccessToken(expiresAt: server.time.now().addingTimeInterval(1200))
    #expect(token.split(separator: ".").count == 3)
}
