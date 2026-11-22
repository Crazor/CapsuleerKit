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

    public init(configuration: SSOConfiguration, userAgent: UserAgent, transport: any HTTPTransport = URLSessionTransport(),
                logSink: any LogSink = NullLogSink(), timeSource: any TimeSource = SystemTimeSource()) {
        self.configuration = configuration
        fatalError("TODO(sso agent)")
    }

    /// Builds a new authorize URL with fresh `state` and PKCE verifier/challenge (S256).
    public func makeAuthorizationRequest(scopes: Set<ESIScope>) async throws -> AuthorizationRequest { fatalError("TODO(sso agent)") }

    /// Validates `state` in `callbackURL` against `request`, exchanges the code, validates the JWT.
    public func exchange(callbackURL: URL, for request: AuthorizationRequest) async throws -> TokenResponse { fatalError("TODO(sso agent)") }

    /// Refreshes; throws `.reauthenticationRequired` for `invalid_grant` / 400 from the token endpoint.
    public func refresh(refreshToken: String) async throws -> TokenResponse { fatalError("TODO(sso agent)") }

    /// Best-effort revocation of a refresh token.
    public func revoke(refreshToken: String) async throws { fatalError("TODO(sso agent)") }
}
