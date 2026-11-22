import CapsuleerCore
import Foundation

/// Logs characters in and keeps their access tokens fresh. Refresh is single-flight per character;
/// every rotated refresh token is saved to the `TokenStore` before the new access token is used.
/// `invalid_grant` marks the character `.needsReauthentication`, deletes its refresh token and emits
/// `.reauthenticationRequired`. An `owner` hash change is treated the same way.
public actor TokenManager: ESITokenProvider {
    public init(sso: SSOClient, store: any TokenStore, events: ClientEventHandler? = nil,
                logSink: any LogSink = NullLogSink(), timeSource: any TimeSource = SystemTimeSource(),
                refreshLeeway: TimeInterval = 60) {
        fatalError("TODO(sso agent)")
    }

    /// Runs a login through `session` and stores the character. Logging in an existing character
    /// merges scopes (requested ∪ previously granted) and replaces its token.
    @discardableResult
    public func authorize(scopes: Set<ESIScope>? = nil, using session: any AuthorizationSession) async throws -> AuthorizedCharacter {
        fatalError("TODO(sso agent)")
    }

    /// All stored characters, including ones that need re-authentication.
    public func characters() async throws -> [AuthorizedCharacter] { fatalError("TODO(sso agent)") }

    /// Revokes (best effort) and deletes the character's credentials.
    public func logout(characterID: Int64) async throws { fatalError("TODO(sso agent)") }

    public func accessToken(for characterID: Int64, requiredScopes: Set<ESIScope>) async throws -> String { fatalError("TODO(sso agent)") }

    public func invalidate(accessToken token: String, for characterID: Int64) async { fatalError("TODO(sso agent)") }
}
