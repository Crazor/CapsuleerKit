import CapsuleerCore
import Foundation

/// The app's EVE SSO registration. The library hard-codes no app identity.
public struct SSOConfiguration: Sendable, Hashable {
    /// Client ID from developers.eveonline.com. Native apps use PKCE and have no secret.
    public var clientID: String
    /// Callback URL registered for the app: a custom scheme (`overseer://sso-callback`) or a
    /// loopback URL (`http://127.0.0.1:8635/callback`). Redirects are matched against it exactly.
    public var callbackURL: URL
    /// Scopes requested when `authorize(scopes:)` is called without explicit scopes.
    public var defaultScopes: Set<ESIScope>
    /// Login host; overridable for tests.
    public var loginBaseURL: URL

    public init(clientID: String, callbackURL: URL, defaultScopes: Set<ESIScope> = [],
                loginBaseURL: URL = URL(string: "https://login.eveonline.com")!) {
        self.clientID = clientID
        self.callbackURL = callbackURL
        self.defaultScopes = defaultScopes
        self.loginBaseURL = loginBaseURL
    }
}

/// A character that has logged in.
public struct AuthorizedCharacter: Sendable, Hashable, Codable, Identifiable {
    public enum State: Sendable, Hashable, Codable {
        case active
        /// The refresh token was rejected; `reason` is the SSO error (e.g. "invalid_grant").
        case needsReauthentication(reason: String)
    }

    public var id: Int64
    public var name: String
    /// `owner` claim; changes when the character is transferred to another account.
    public var ownerHash: String
    public var scopes: Set<ESIScope>
    public var state: State

    public init(id: Int64, name: String, ownerHash: String, scopes: Set<ESIScope>, state: State = .active) {
        self.id = id
        self.name = name
        self.ownerHash = ownerHash
        self.scopes = scopes
        self.state = state
    }
}

/// What a `TokenStore` persists per character. Access tokens are never persisted.
public struct StoredCredential: Sendable, Hashable, Codable {
    public var character: AuthorizedCharacter
    public var refreshToken: String

    public init(character: AuthorizedCharacter, refreshToken: String) {
        self.character = character
        self.refreshToken = refreshToken
    }
}

/// Persists credentials. Implementations: `KeychainTokenStore` (Apple), `InMemoryTokenStore` (tests);
/// the CLI has a file store.
public protocol TokenStore: Sendable {
    func load(characterID: Int64) async throws -> StoredCredential?
    func loadAll() async throws -> [StoredCredential]
    /// Insert or replace. Must be durable before returning (the old refresh token may already be invalid).
    func save(_ credential: StoredCredential) async throws
    func delete(characterID: Int64) async throws
}

/// Delivers the SSO redirect back to the app. `start` opens `authorizeURL` and returns the full
/// callback URL (with `code` and `state`) once the user has logged in; throws `.ssoFailed` /
/// `.cancelled` otherwise.
public protocol AuthorizationSession: Sendable {
    func start(authorizeURL: URL, callbackURL: URL) async throws -> URL
}
