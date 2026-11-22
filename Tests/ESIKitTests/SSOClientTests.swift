import CryptoKit
import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

@Suite struct SSOPKCETests {
    @Test func verifierHas43Base64URLCharacters() throws {
        for _ in 0..<20 {
            let verifier = try PKCE.makeCodeVerifier()
            #expect(verifier.count == 43)
            #expect(verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        }
        #expect(try PKCE.makeCodeVerifier() != PKCE.makeCodeVerifier())
    }

    /// RFC 7636 appendix B.
    @Test func challengeMatchesRFC7636Example() {
        #expect(PKCE.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = "abc-_123"
        #expect(PKCE.codeChallenge(for: verifier) == Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    @Test func base64URLRoundTrips() {
        let data = Data((0..<255).map { UInt8($0) })
        #expect(Base64URL.decode(Base64URL.encode(data)) == data)
        #expect(Base64URL.decode("not base64!") == nil)
    }
}

@Suite struct SSOClientTests {
    @Test func authorizationURLCarriesPKCEAndScopes() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let request = try await client.makeAuthorizationRequest(scopes: [.locationRead, .shipTypeRead])
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "login.eveonline.com")
        #expect(components.path == "/v2/oauth/authorize")
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == ssoClientID)
        #expect(items["redirect_uri"] == "eveauth-overseer://callback")
        #expect(items["scope"] == "esi-location.read_location.v1 esi-location.read_ship_type.v1")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == PKCE.codeChallenge(for: request.codeVerifier))
        #expect(items["state"] == request.state)
        #expect(request.state.count >= 22)
        #expect(request.scopes == [.locationRead, .shipTypeRead])
        // Spaces are %20, and the redirect URI's reserved characters are escaped.
        #expect(request.url.absoluteString.contains("scope=esi-location.read_location.v1%20esi-location"))
        #expect(request.url.absoluteString.contains("redirect_uri=eveauth-overseer%3A%2F%2Fcallback"))

        let other = try await client.makeAuthorizationRequest(scopes: [])
        #expect(other.state != request.state)
        #expect(other.codeVerifier != request.codeVerifier)
        // Metadata fetched once and cached.
        #expect(server.requests(path: "/.well-known/oauth-authorization-server").count == 1)
    }

    @Test func metadataFailureFallsBackToDocumentedEndpoints() async throws {
        let server = MockLoginServer()
        server.metadataStatus.set(503)
        let request = try await server.makeClient().makeAuthorizationRequest(scopes: [])
        #expect(request.url.absoluteString.hasPrefix("https://login.eveonline.com/v2/oauth/authorize?"))
    }

    @Test(arguments: ["rs256", "es256"])
    func exchangeHappyPath(algorithm: String) async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let exp = server.time.now().addingTimeInterval(1199)
        let token = makeAccessToken(scopes: ["esi-location.read_location.v1", "esi-location.read_online.v1"],
                                    expiresAt: exp, signer: algorithm == "rs256" ? .rs256 : .es256())
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: token, refreshToken: "refresh-1") }

        let request = try await client.makeAuthorizationRequest(scopes: [.locationRead, .onlineRead])
        let callback = try ScriptedSession.success(code: "the-code").respond(request.url, ssoCallback)
        let response = try await client.exchange(callbackURL: callback, for: request)

        #expect(response.accessToken == token)
        #expect(response.refreshToken == "refresh-1")
        #expect(response.expiresAt.timeIntervalSince1970 == exp.timeIntervalSince1970.rounded(.down))
        #expect(response.character == AuthorizedCharacter(id: 2112345678, name: "Test Pilot", ownerHash: "owner-hash-1",
                                                          scopes: [.locationRead, .onlineRead]))

        let post = try #require(server.tokenRequests.first)
        #expect(post.method == .post)
        #expect(post.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(post.headers["Host"] == "login.eveonline.com")
        #expect(post.headers["User-Agent"] == ssoUserAgent.headerValue)
        #expect(post.headers["Authorization"] == nil)
        #expect(MockLoginServer.form(post) == [
            "grant_type": "authorization_code", "code": "the-code", "client_id": ssoClientID, "code_verifier": request.codeVerifier,
        ])
    }

    @Test func scopeClaimMayBeASingleString() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let token = makeAccessToken(scopes: ["esi-location.read_location.v1"], scopeAsString: true,
                                    expiresAt: server.time.now().addingTimeInterval(1200))
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: token) }
        let request = try await client.makeAuthorizationRequest(scopes: [.locationRead])
        let response = try await client.exchange(callbackURL: ScriptedSession.success().respond(request.url, ssoCallback), for: request)
        #expect(response.character.scopes == [.locationRead])
    }

    @Test func stateMismatchIsRejectedWithoutTokenRequest() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let request = try await client.makeAuthorizationRequest(scopes: [])
        let error = await #expect(throws: CapsuleerError.self) {
            try await client.exchange(callbackURL: URL(string: "eveauth-overseer://callback?code=x&state=forged")!, for: request)
        }
        #expect(error?.code == .ssoFailed)
        #expect(server.tokenRequests.isEmpty)
    }

    @Test(arguments: [
        "eveauth-overseer://evil-host?code=x&state=S",
        "evil://sso-callback?code=x&state=S",
        "eveauth-overseer://callback/other?code=x&state=S",
    ])
    func wrongCallbackIsRejected(url: String) async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let request = try await client.makeAuthorizationRequest(scopes: [])
        let callback = URL(string: url.replacingOccurrences(of: "state=S", with: "state=\(request.state)"))!
        let error = await #expect(throws: CapsuleerError.self) { try await client.exchange(callbackURL: callback, for: request) }
        #expect(error?.code == .ssoFailed)
        #expect(server.tokenRequests.isEmpty)
    }

    @Test func loopbackCallbackMustMatchPort() async throws {
        let server = MockLoginServer()
        let client = server.makeClient(callbackURL: URL(string: "http://127.0.0.1:8635/callback")!)
        let request = try await client.makeAuthorizationRequest(scopes: [])
        await #expect(throws: CapsuleerError.self) {
            try await client.exchange(callbackURL: URL(string: "http://127.0.0.1:9999/callback?code=x&state=\(request.state)")!, for: request)
        }
        #expect(server.tokenRequests.isEmpty)
    }

    @Test func accessDeniedIsCancelled() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let request = try await client.makeAuthorizationRequest(scopes: [])
        let denied = await #expect(throws: CapsuleerError.self) {
            try await client.exchange(callbackURL: URL(string: "eveauth-overseer://callback?error=access_denied&state=\(request.state)")!, for: request)
        }
        #expect(denied?.code == .cancelled)
        let other = await #expect(throws: CapsuleerError.self) {
            try await client.exchange(callbackURL: URL(string: "eveauth-overseer://callback?error=server_error&state=\(request.state)")!, for: request)
        }
        #expect(other?.code == .ssoFailed)
        #expect(server.tokenRequests.isEmpty)
    }

    @Test func refreshPostsRefreshGrant() async throws {
        let server = MockLoginServer()
        let token = makeAccessToken(expiresAt: server.time.now().addingTimeInterval(1200), signer: .es256())
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: token, refreshToken: "rotated") }
        let response = try await server.makeClient().refresh(refreshToken: "old refresh/+=")
        #expect(response.refreshToken == "rotated")
        #expect(MockLoginServer.form(try #require(server.tokenRequests.first)) == [
            "grant_type": "refresh_token", "refresh_token": "old refresh/+=", "client_id": ssoClientID,
        ])
    }

    @Test func refreshLoadsTheJWKSBeforeSpendingTheRefreshToken() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let token = makeAccessToken(expiresAt: server.time.now().addingTimeInterval(1200))
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: token, refreshToken: "rotated") }
        server.jwksStatus.set(503)
        let error = await #expect(throws: CapsuleerError.self) { try await client.refresh(refreshToken: "r") }
        #expect(error?.code == .transport)
        #expect(server.jwksRequests.count == 1)
        #expect(server.tokenRequests.isEmpty)

        server.jwksStatus.set(200)
        _ = try await client.refresh(refreshToken: "r")
        #expect(server.tokenRequests.count == 1)
        // Loaded before the POST and cached: the request order is JWKS, then token.
        let paths = server.transport.requests.map(\.url.path).filter { $0 == "/oauth/jwks" || $0 == "/v2/oauth/token" }
        #expect(paths == ["/oauth/jwks", "/oauth/jwks", "/v2/oauth/token"])
    }

    @Test func rotatedTokenIsHandedOverBeforeValidation() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        // Already expired by the client's clock: validation fails after the token endpoint answered.
        let token = makeAccessToken(expiresAt: server.time.now().addingTimeInterval(-600))
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: token, refreshToken: "rotated") }
        let persisted = SSOLocked<[String]>([])
        let error = await #expect(throws: CapsuleerError.self) {
            try await client.refresh(refreshToken: "old") { rotated in persisted.update { $0.append(rotated) } }
        }
        #expect(error?.code == .ssoFailed)
        #expect(persisted.value == ["rotated"])

        // Not called when the token isn't rotated.
        let unrotated = makeAccessToken(expiresAt: server.time.now().addingTimeInterval(1200))
        server.tokenHandler.set { [server] _ in server.tokenResponse(accessToken: unrotated, refreshToken: "same") }
        let response = try await client.refresh(refreshToken: "same") { rotated in persisted.update { $0.append(rotated) } }
        #expect(response.refreshToken == "same")
        #expect(persisted.value == ["rotated"])
    }

    @Test func refreshErrorMapping() async throws {
        let server = MockLoginServer()
        let client = server.makeClient()
        let cases: [(HTTPResponse?, CapsuleerError.Code)] = [
            (MockLoginServer.oauthError(400, "invalid_grant"), .reauthenticationRequired),
            (MockLoginServer.oauthError(401, "invalid_client"), .ssoFailed),
            (MockLoginServer.oauthError(400, "invalid_request"), .ssoFailed),
            (HTTPResponse(status: 400, url: ssoLoginBase), .reauthenticationRequired),
            (HTTPResponse(status: 502, url: ssoLoginBase), .transport),
            (nil, .transport),
        ]
        for (response, expected) in cases {
            server.tokenHandler.set { _ in
                guard let response else { throw CapsuleerError(.transport, message: "offline") }
                return response
            }
            let error = await #expect(throws: CapsuleerError.self) { try await client.refresh(refreshToken: "r") }
            #expect(error?.code == expected, "\(String(describing: response?.status))")
        }
    }

    @Test func revokePostsRefreshToken() async throws {
        let server = MockLoginServer()
        try await server.makeClient().revoke(refreshToken: "refresh-x")
        let post = try #require(server.revokeRequests.first)
        #expect(post.method == .post)
        #expect(MockLoginServer.form(post) == ["token": "refresh-x", "token_type_hint": "refresh_token", "client_id": ssoClientID])
    }
}
