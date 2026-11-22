import CapsuleerCore
import Foundation

/// Platform-neutral EVE SSO v2 (OAuth 2.0 authorization code + PKCE, no client secret):
/// authorize URL, code exchange, refresh, revoke, and JWT validation against EVE's JWKS
/// (RS256 and ES256). Endpoints from `/.well-known/oauth-authorization-server`, cached.
public final class SSOClient: Sendable {
    /// Result of a token exchange or refresh.
    public struct TokenResponse: Sendable, Hashable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        /// Validated JWT claims.
        public var character: AuthorizedCharacter
    }

    /// PKCE values plus the authorize URL for one login attempt.
    public struct AuthorizationRequest: Sendable, Hashable {
        public var url: URL
        public var state: String
        public var codeVerifier: String
        public var scopes: Set<ESIScope>
    }

    public let configuration: SSOConfiguration

    let http: HTTPClient
    let metadata: SSOMetadataCache
    let jwks: JWKSCache
    let validator: JWTValidator
    let logSink: any LogSink
    let timeSource: any TimeSource

    public init(configuration: SSOConfiguration, userAgent: UserAgent, transport: any HTTPTransport = URLSessionTransport(),
                logSink: any LogSink = NullLogSink(), timeSource: any TimeSource = SystemTimeSource()) {
        self.configuration = configuration
        self.logSink = logSink
        self.timeSource = timeSource
        // No cache: token POSTs must never be stored, and the metadata/JWKS have their own caches.
        let http = HTTPClient(configuration: .init(
            userAgent: userAgent, transport: transport, cache: nil, logSink: logSink, events: nil, timeSource: timeSource))
        self.http = http
        let metadata = SSOMetadataCache(baseURL: configuration.loginBaseURL, http: http, logSink: logSink, timeSource: timeSource)
        self.metadata = metadata
        let jwks = JWKSCache { [http, metadata] in
            let url = await metadata.current().jwksURL
            let response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
            do {
                return try JSONDecoder().decode(JWKSet.self, from: response.value.body)
            } catch {
                throw CapsuleerError(.ssoFailed, message: "Malformed JWKS", url: url, underlying: error)
            }
        }
        self.jwks = jwks
        var extraIssuers: Set<String> = []
        if let host = configuration.loginBaseURL.host {
            extraIssuers.insert(host)
            extraIssuers.insert("\(configuration.loginBaseURL.scheme ?? "https")://\(host)")
        }
        validator = JWTValidator(clientID: configuration.clientID, extraIssuers: extraIssuers, jwks: jwks, timeSource: timeSource)
    }

    /// Builds a new authorize URL with fresh `state` and PKCE verifier/challenge (S256).
    public func makeAuthorizationRequest(scopes: Set<ESIScope>) async throws -> AuthorizationRequest {
        let endpoints = await metadata.current()
        let verifier = try PKCE.makeCodeVerifier()
        let state = try PKCE.makeState()
        let query = FormEncoding.encode([
            ("response_type", "code"),
            ("redirect_uri", configuration.callbackURL.absoluteString),
            ("client_id", configuration.clientID),
            ("scope", scopes.map(\.rawValue).sorted().joined(separator: " ")),
            ("code_challenge", PKCE.codeChallenge(for: verifier)),
            ("code_challenge_method", "S256"),
            ("state", state),
        ])
        guard var components = URLComponents(url: endpoints.authorizationURL, resolvingAgainstBaseURL: false) else {
            throw CapsuleerError(.ssoFailed, message: "Bad authorization endpoint", url: endpoints.authorizationURL)
        }
        components.percentEncodedQuery = query
        guard let url = components.url else {
            throw CapsuleerError(.ssoFailed, message: "Could not build the authorize URL", url: endpoints.authorizationURL)
        }
        return AuthorizationRequest(url: url, state: state, codeVerifier: verifier, scopes: scopes)
    }

    /// Validates `state` in `callbackURL` against `request`, exchanges the code, validates the JWT.
    ///
    /// Throws `.ssoFailed` when the URL isn't the configured callback, `state` doesn't match, SSO
    /// returned an `error`, or the token is invalid; `.cancelled` for `error=access_denied`.
    public func exchange(callbackURL: URL, for request: AuthorizationRequest) async throws -> TokenResponse {
        guard Self.matches(callbackURL, configuration.callbackURL) else {
            throw CapsuleerError(.ssoFailed, message: "Redirect does not match the configured callback URL")
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            let description = value("error_description").map { ": \($0)" } ?? ""
            throw CapsuleerError(error == "access_denied" ? .cancelled : .ssoFailed, message: "EVE SSO returned \(error)\(description)")
        }
        guard let state = value("state"), Self.constantTimeEquals(state, request.state) else {
            throw CapsuleerError(.ssoFailed, message: "SSO state mismatch")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw CapsuleerError(.ssoFailed, message: "Redirect has no authorization code")
        }
        let response = try await postToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", configuration.clientID),
            ("code_verifier", request.codeVerifier),
        ], isRefresh: false)
        return try await validate(response, previousRefreshToken: nil)
    }

    /// Refreshes; throws `.reauthenticationRequired` for `invalid_grant` / 400 from the token endpoint,
    /// `.transport` for network failures and 5XX (the refresh token stays valid).
    ///
    /// Callers that persist refresh tokens should use `refresh(refreshToken:persistingRotatedToken:)`:
    /// EVE may rotate the refresh token, and if validating the new access token fails, the rotated
    /// token is lost here.
    public func refresh(refreshToken: String) async throws -> TokenResponse {
        try await refresh(refreshToken: refreshToken, persistingRotatedToken: { _ in })
    }

    /// Refreshes like `refresh(refreshToken:)`, but hands a rotated refresh token to
    /// `persistRotatedToken` as soon as the token endpoint answers, before the access token is
    /// validated. Once the token endpoint has answered, the old refresh token may already be dead,
    /// so a validation failure (JWKS outage, clock skew) must not lose the new one.
    ///
    /// The JWKS and endpoint metadata are loaded before the refresh token is spent; if the JWKS
    /// can't be loaded this throws (`.transport` for network failures and 5XX) without contacting
    /// the token endpoint. `persistRotatedToken` is called at most once, only when the response
    /// carries a refresh token different from `refreshToken`; an error it throws is rethrown.
    public func refresh(refreshToken: String,
                        persistingRotatedToken persistRotatedToken: @Sendable (_ rotatedRefreshToken: String) async throws -> Void)
        async throws -> TokenResponse {
        try await prepareValidation()
        let response = try await postToken([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientID),
        ], isRefresh: true)
        if let rotated = response.refresh_token, !rotated.isEmpty, rotated != refreshToken {
            try await persistRotatedToken(rotated)
        }
        return try await validate(response, previousRefreshToken: refreshToken)
    }

    /// Best-effort revocation of a refresh token.
    public func revoke(refreshToken: String) async throws {
        let url = await metadata.current().revocationURL
        _ = try await http.send(formRequest(url: url, [
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", configuration.clientID),
        ]))
    }

    // MARK: - Internals

    struct TokenEndpointResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
        var token_type: String?
    }

    private struct TokenEndpointError: Decodable {
        var error: String
        var error_description: String?
    }

    private func formRequest(url: URL, _ pairs: [(String, String)]) -> HTTPRequest {
        var headers: HTTPHeaders = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        ]
        if let host = url.host { headers["Host"] = host }
        return HTTPRequest(method: .post, url: url, headers: headers, body: Data(FormEncoding.encode(pairs).utf8))
    }

    private func postToken(_ pairs: [(String, String)], isRefresh: Bool) async throws -> TokenEndpointResponse {
        let url = await metadata.current().tokenURL
        let body: Data
        do {
            body = try await http.send(formRequest(url: url, pairs)).value.body
        } catch let error as CapsuleerError {
            throw Self.mapTokenError(error, url: url, isRefresh: isRefresh)
        }
        do {
            return try JSONDecoder().decode(TokenEndpointResponse.self, from: body)
        } catch {
            throw CapsuleerError(.ssoFailed, message: "Malformed token response", url: url, underlying: error)
        }
    }

    /// Token endpoint failures:
    /// - `invalid_grant` (any 4XX), or a 400 without a recognisable OAuth error → `.reauthenticationRequired` (refresh only);
    /// - 5XX, 429 and network failures → `.transport` (try again later; nothing is invalidated);
    /// - other OAuth errors (`invalid_client`, `invalid_request`, …) → `.ssoFailed`. These point at
    ///   app misconfiguration, so they must not wipe the user's refresh tokens.
    static func mapTokenError(_ error: CapsuleerError, url: URL, isRefresh: Bool) -> CapsuleerError {
        guard error.code == .http || error.code == .notFound, let status = error.status else { return error }
        if status >= 500 || status == 429 {
            return CapsuleerError(.transport, status: status, message: error.message, url: url, underlying: error)
        }
        let oauthError = error.message.flatMap { try? JSONDecoder().decode(TokenEndpointError.self, from: Data($0.utf8)) }
        let message = oauthError.map { "\($0.error)\($0.error_description.map { ": \($0)" } ?? "")" } ?? error.message
        if isRefresh, oauthError?.error == "invalid_grant" || (status == 400 && oauthError == nil) {
            return CapsuleerError(.reauthenticationRequired, status: status, message: message, url: url, underlying: error)
        }
        return CapsuleerError(.ssoFailed, status: status, message: message, url: url, underlying: error)
    }

    /// Loads the endpoint metadata and the JWKS (if not cached yet), so a token can be validated
    /// right after the token endpoint answers. Network failures and 5XX/429 become `.transport`.
    func prepareValidation() async throws {
        do {
            try await jwks.preload()
        } catch let error as CapsuleerError {
            if error.code == .cancelled { throw error }
            let transient = error.code == .transport
                || (error.code == .http && (error.status.map { $0 >= 500 || $0 == 429 } ?? false))
            throw CapsuleerError(transient ? .transport : .ssoFailed, status: error.status,
                                 message: "JWKS unavailable", url: error.url, underlying: error)
        }
    }

    private func validate(_ response: TokenEndpointResponse, previousRefreshToken: String?) async throws -> TokenResponse {
        let validated = try await validator.validate(response.access_token)
        guard let refreshToken = response.refresh_token ?? previousRefreshToken, !refreshToken.isEmpty else {
            throw CapsuleerError(.ssoFailed, message: "Token response has no refresh token")
        }
        return TokenResponse(
            accessToken: response.access_token, refreshToken: refreshToken,
            expiresAt: validated.expiresAt, character: validated.character)
    }

    /// Scheme, host, port and path must match; the query is ignored. An empty path equals "/".
    static func matches(_ url: URL, _ expected: URL) -> Bool {
        guard let a = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        func path(_ c: URLComponents) -> String { c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
            && path(a) == path(b)
            && a.user == nil && a.password == nil
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The SSO endpoints, from `/.well-known/oauth-authorization-server` or the documented defaults.
struct SSOEndpoints: Sendable, Hashable {
    var authorizationURL: URL
    var tokenURL: URL
    var revocationURL: URL
    var jwksURL: URL

    static func fallback(baseURL: URL) -> SSOEndpoints {
        SSOEndpoints(
            authorizationURL: baseURL.appendingPathComponent("v2/oauth/authorize"),
            tokenURL: baseURL.appendingPathComponent("v2/oauth/token"),
            revocationURL: baseURL.appendingPathComponent("v2/oauth/revoke"),
            jwksURL: baseURL.appendingPathComponent("oauth/jwks"))
    }
}

/// Fetches the authorization server metadata once and caches it for the process. On failure the
/// documented URLs are used, and the fetch is retried after `retryInterval`.
actor SSOMetadataCache {
    private struct Document: Decodable {
        var authorization_endpoint: String?
        var token_endpoint: String?
        var revocation_endpoint: String?
        var jwks_uri: String?
    }

    let baseURL: URL
    private let http: HTTPClient
    private let logSink: any LogSink
    private let timeSource: any TimeSource
    private let retryInterval: TimeInterval = 300
    private var cached: SSOEndpoints?
    private var fallbackUntil: Date?
    private var inFlight: Task<SSOEndpoints, Never>?

    init(baseURL: URL, http: HTTPClient, logSink: any LogSink, timeSource: any TimeSource) {
        self.baseURL = baseURL
        self.http = http
        self.logSink = logSink
        self.timeSource = timeSource
    }

    func current() async -> SSOEndpoints {
        if let cached { return cached }
        let fallback = SSOEndpoints.fallback(baseURL: baseURL)
        if let fallbackUntil, timeSource.now() < fallbackUntil { return fallback }
        if let inFlight { return await inFlight.value }
        let task = Task { [baseURL, http, logSink] () -> SSOEndpoints in
            do {
                let url = baseURL.appendingPathComponent(".well-known/oauth-authorization-server")
                let response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
                let document = try JSONDecoder().decode(Document.self, from: response.value.body)
                return try Self.endpoints(from: document, baseURL: baseURL)
            } catch {
                logSink.log(.warning, .sso, "SSO metadata unavailable; using documented endpoints", metadata: ["error": String(describing: (error as? CapsuleerError)?.code ?? .decoding)])
                return fallback
            }
        }
        inFlight = task
        let endpoints = await task.value
        inFlight = nil
        if endpoints == fallback {
            fallbackUntil = timeSource.now().addingTimeInterval(retryInterval)
        } else {
            cached = endpoints
        }
        return endpoints
    }

    /// Every endpoint must be HTTPS (or the base URL's scheme, for tests) on the login host.
    /// Anything else falls back, so a tampered document can't redirect tokens elsewhere.
    private static func endpoints(from document: Document, baseURL: URL) throws -> SSOEndpoints {
        let fallback = SSOEndpoints.fallback(baseURL: baseURL)
        func url(_ string: String?, _ fallback: URL) throws -> URL {
            guard let string else { return fallback }
            guard let url = URL(string: string), url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
                  url.host?.lowercased() == baseURL.host?.lowercased() else {
                throw CapsuleerError(.ssoFailed, message: "SSO metadata endpoint on an unexpected host")
            }
            return url
        }
        return SSOEndpoints(
            authorizationURL: try url(document.authorization_endpoint, fallback.authorizationURL),
            tokenURL: try url(document.token_endpoint, fallback.tokenURL),
            revocationURL: try url(document.revocation_endpoint, fallback.revocationURL),
            jwksURL: try url(document.jwks_uri, fallback.jwksURL))
    }
}
