import CapsuleerCore
import Foundation

/// Logs characters in and keeps their access tokens fresh. Refresh is single-flight per character;
/// every rotated refresh token is saved to the `TokenStore` as soon as the token endpoint returns
/// it (before the new access token is validated or used). `invalid_grant` marks the character
/// `.needsReauthentication`, deletes its refresh token and emits `.reauthenticationRequired`. An
/// `owner` hash change is treated the same way.
///
/// A character that needs re-authentication stays in the store (so `characters()` lists it) with
/// its state set to `.needsReauthentication(reason:)` and an **empty** `refreshToken`. Logging the
/// character in again replaces it; `logout` deletes it.
///
/// Credential changes are serialised per character: a refresh, a re-login's store update and a
/// logout never overlap, and no refresh starts while a character is being logged out.
///
/// If the store can't save a refreshed credential, the new credential is kept in memory (and used
/// for the next refresh), the failure is logged, and the save is retried on the next access.
/// `.storage` is thrown only when no usable access token can be handed out.
///
/// After a transient refresh failure (`.transport`: network, 5XX, JWKS outage) the character backs
/// off: until the backoff ends, `accessToken` rethrows that error with `retryAfter` set instead of
/// contacting the token endpoint again.
///
/// Access tokens live in memory only. Tokens are never logged; character IDs go to private log metadata.
public actor TokenManager: ESITokenProvider {
    private struct CachedAccessToken {
        var token: String
        var expiresAt: Date
    }

    private struct RefreshFlight {
        var id: UUID
        var task: Task<String, any Error>
    }

    private struct RefreshFailure {
        var error: CapsuleerError
        var count: Int
        var until: Date
    }

    /// A per-character FIFO lock, held across suspension points.
    private struct CredentialLock {
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Reason stored when the owner hash changed on refresh (character transferred).
    public static let ownerChangedReason = "owner_changed"
    /// Reason stored when the token endpoint rejected the refresh token.
    public static let invalidGrantReason = "invalid_grant"
    /// Upper bound of the exponential refresh backoff (unless `refreshFailureBackoff` is larger).
    static let maximumRefreshBackoff: TimeInterval = 300

    public nonisolated let sso: SSOClient
    private let store: any TokenStore
    private let events: ClientEventHandler?
    private let logSink: any LogSink
    private let timeSource: any TimeSource
    private let refreshLeeway: TimeInterval
    private let refreshFailureBackoff: TimeInterval
    private let cache: (any CacheStore)?

    private var accessTokens: [Int64: CachedAccessToken] = [:]
    private var refreshes: [Int64: RefreshFlight] = [:]
    /// Bumped whenever a character's credential is replaced or removed outside a refresh, so a
    /// refresh that finishes afterwards doesn't resurrect or overwrite it.
    private var generations: [Int64: Int] = [:]
    /// Held (present) while a refresh, a re-login's store update, a logout or a deferred save runs.
    private var locks: [Int64: CredentialLock] = [:]
    /// Re-logins and logouts that have started their store change but not finished it.
    private var pendingChanges: [Int64: Int] = [:]
    private var changeWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    /// Logouts in progress: `accessToken` throws `.notAuthenticated` meanwhile.
    private var loggingOut: [Int64: Int] = [:]
    /// Credentials newer than what the store holds, because saving them failed.
    private var unsavedCredentials: [Int64: StoredCredential] = [:]
    /// Set by the current refresh when saving its rotated refresh token failed.
    private var rotationSaveFailed: Set<Int64> = []
    private var refreshFailures: [Int64: RefreshFailure] = [:]

    /// - Parameters:
    ///   - refreshLeeway: how long before expiry an access token is refreshed.
    ///   - refreshFailureBackoff: after a transient refresh failure (network, 5XX, JWKS outage),
    ///     how long `accessToken` rethrows that failure (with `retryAfter`) instead of contacting the
    ///     token endpoint again. Doubles with each consecutive failure, up to 5 minutes (or this
    ///     value, if larger). A successful refresh or a login clears it; 0 disables the backoff.
    ///   - cache: the ESI cache store, if any. A character's private entries
    ///     (`CacheIdentity.character(id)`) are removed on logout and when the owner hash changes.
    public init(sso: SSOClient, store: any TokenStore, events: ClientEventHandler? = nil,
                logSink: any LogSink = NullLogSink(), timeSource: any TimeSource = SystemTimeSource(),
                refreshLeeway: TimeInterval = 60, cache: (any CacheStore)? = nil,
                refreshFailureBackoff: TimeInterval = 30) {
        self.sso = sso
        self.store = store
        self.events = events
        self.logSink = logSink
        self.timeSource = timeSource
        self.refreshLeeway = refreshLeeway
        self.refreshFailureBackoff = max(0, refreshFailureBackoff)
        self.cache = cache
    }

    /// Runs a login through `session` and stores the character. Logging in an existing character
    /// merges scopes (requested ∪ previously granted) and replaces its token.
    ///
    /// SSO grants only what the authorize URL asks for, and which character logs in is only known
    /// afterwards. So the previously granted scopes are added to the request only for
    /// `characterID` (use it for "add a scope to this character"); the stored scopes are always
    /// what the new token actually grants (its `scp` claim).
    @discardableResult
    public func authorize(scopes: Set<ESIScope>? = nil, mergingWith characterID: Int64? = nil,
                          using session: any AuthorizationSession) async throws -> AuthorizedCharacter {
        var requested = scopes ?? sso.configuration.defaultScopes
        if let characterID, let existing = try await currentCredential(characterID) {
            requested.formUnion(existing.character.scopes)
        }
        let request = try await sso.makeAuthorizationRequest(scopes: requested)
        let callback = try await session.start(authorizeURL: request.url, callbackURL: sso.configuration.callbackURL)
        let response = try await sso.exchange(callbackURL: callback, for: request)
        let character = response.character
        let id = character.id

        // Wait for any refresh on the old token to finish (it may rotate it), and keep new ones
        // out until the new credential is stored.
        beginChange(id, logout: false)
        await lock(id)
        var changeEnded = false
        defer {
            if !changeEnded { endChange(id, logout: false) }
            unlock(id)
        }

        let previous = try? await currentCredential(id)
        generations[id, default: 0] += 1
        try await store.save(StoredCredential(character: character, refreshToken: response.refreshToken))
        unsavedCredentials[id] = nil
        refreshFailures[id] = nil
        accessTokens[id] = CachedAccessToken(token: response.accessToken, expiresAt: response.expiresAt)
        endChange(id, logout: false)
        changeEnded = true

        if let previous {
            if previous.character.ownerHash != character.ownerHash {
                await cache?.removeAll(identity: .character(id))
            }
            let lost = previous.character.scopes.subtracting(character.scopes)
            if !lost.isEmpty {
                logSink.log(.notice, .sso, "Re-login granted fewer scopes than before",
                            metadata: ["dropped": lost.map(\.rawValue).sorted().joined(separator: " ")],
                            privateMetadata: ["character": String(id)])
            }
            // The replaced refresh token is deliberately NOT revoked: EVE SSO revocation ends the
            // whole grant for this character and application, which would kill the login that just
            // succeeded (verified live on 2026-11-22). The old token is simply forgotten.
        }
        logSink.log(.info, .sso, "Character authorized", privateMetadata: ["character": String(id)])
        return character
    }

    /// All stored characters, including ones that need re-authentication. Sorted by name.
    public func characters() async throws -> [AuthorizedCharacter] {
        var credentials = Dictionary(try await store.loadAll().map { ($0.character.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, unsaved) in unsavedCredentials { credentials[id] = unsaved }
        return credentials.values.map(\.character).sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Revokes (best effort) and deletes the character's credentials. Waits for a refresh that is
    /// already running; `accessToken` throws `.notAuthenticated` for the character meanwhile.
    public func logout(characterID: Int64) async throws {
        beginChange(characterID, logout: true)
        accessTokens[characterID] = nil
        await lock(characterID)
        defer {
            endChange(characterID, logout: true)
            unlock(characterID)
        }

        generations[characterID, default: 0] += 1
        accessTokens[characterID] = nil
        refreshFailures[characterID] = nil
        // Loaded under the lock, so this is the latest (possibly just rotated) refresh token.
        let credential = try? await currentCredential(characterID)
        unsavedCredentials[characterID] = nil
        if let token = credential?.refreshToken, !token.isEmpty {
            do {
                try await sso.revoke(refreshToken: token)
            } catch {
                logSink.log(.notice, .sso, "Token revocation failed; deleting locally anyway",
                            metadata: ["error": (error as? CapsuleerError)?.code.rawValue ?? "unknown"],
                            privateMetadata: ["character": String(characterID)])
            }
        }
        try await store.delete(characterID: characterID)
        accessTokens[characterID] = nil
        await cache?.removeAll(identity: .character(characterID))
        logSink.log(.info, .sso, "Character logged out", privateMetadata: ["character": String(characterID)])
    }

    public func accessToken(for characterID: Int64, requiredScopes: Set<ESIScope>) async throws -> String {
        var retriedSave = false
        while true {
            if loggingOut[characterID, default: 0] > 0 { throw Self.loggedOutError() }
            if pendingChanges[characterID, default: 0] > 0 {
                await waitForChanges(characterID)
                continue
            }
            if !retriedSave, unsavedCredentials[characterID] != nil {
                retriedSave = true
                await saveUnsavedCredential(characterID)
                continue
            }

            let credential = try await credential(for: characterID)
            // A logout or re-login may have started while the store was being read.
            if loggingOut[characterID, default: 0] > 0 || pendingChanges[characterID, default: 0] > 0 { continue }

            let missing = requiredScopes.subtracting(credential.character.scopes)
            guard missing.isEmpty else {
                throw CapsuleerError(.missingScope, message: "Missing scopes: \(missing.map(\.rawValue).sorted().joined(separator: " "))")
            }
            if case .needsReauthentication = credential.character.state { throw Self.reauthenticationError(characterID) }
            if credential.refreshToken.isEmpty { throw Self.reauthenticationError(characterID) }

            // From here to storing the flight there is no suspension point, so concurrent callers
            // either find a valid token, join the stored flight, or (exactly one of them) start it.
            if let cached = accessTokens[characterID], cached.expiresAt.addingTimeInterval(-refreshLeeway) > timeSource.now() {
                return cached.token
            }
            if let flight = refreshes[characterID] { return try await flight.task.value }
            if let failure = refreshFailures[characterID] {
                let remaining = failure.until.timeIntervalSince(timeSource.now())
                if remaining > 0 {
                    var error = failure.error
                    error.retryAfter = .milliseconds(Int64((remaining * 1000).rounded(.up)))
                    throw error
                }
            }

            let flightID = UUID()
            let task = Task { try await self.runRefresh(characterID: characterID) }
            refreshes[characterID] = RefreshFlight(id: flightID, task: task)
            defer { if refreshes[characterID]?.id == flightID { refreshes[characterID] = nil } }
            return try await task.value
        }
    }

    public func invalidate(accessToken token: String, for characterID: Int64) async {
        if accessTokens[characterID]?.token == token { accessTokens[characterID] = nil }
    }

    // MARK: - Refresh

    /// The newest credential: an unsaved one if saving it failed, else the stored one.
    private func currentCredential(_ characterID: Int64) async throws -> StoredCredential? {
        if let unsaved = unsavedCredentials[characterID] { return unsaved }
        let stored = try await store.load(characterID: characterID)
        // Saving may have failed while the store was read.
        return unsavedCredentials[characterID] ?? stored
    }

    private func credential(for characterID: Int64) async throws -> StoredCredential {
        guard let credential = try await currentCredential(characterID) else {
            throw Self.loggedOutError()
        }
        return credential
    }

    /// Runs inside the single stored flight for `characterID`, under the credential lock.
    private func runRefresh(characterID: Int64) async throws -> String {
        await lock(characterID)
        defer { unlock(characterID) }
        do {
            let token = try await performRefresh(characterID: characterID)
            refreshFailures[characterID] = nil
            return token
        } catch let error as CapsuleerError where error.code == .transport {
            recordRefreshFailure(error, for: characterID)
            throw error
        }
    }

    private func performRefresh(characterID: Int64) async throws -> String {
        // A re-login may have stored a fresh token while this flight waited for the lock.
        if let cached = accessTokens[characterID], cached.expiresAt.addingTimeInterval(-refreshLeeway) > timeSource.now() {
            return cached.token
        }
        let generation = generations[characterID, default: 0]
        let credential = try await credential(for: characterID)
        guard case .active = credential.character.state, !credential.refreshToken.isEmpty else {
            throw Self.reauthenticationError(characterID)
        }

        let response: SSOClient.TokenResponse
        rotationSaveFailed.remove(characterID)
        do {
            response = try await sso.refresh(refreshToken: credential.refreshToken) { rotated in
                await self.saveRotatedRefreshToken(rotated, replacing: credential, generation: generation)
            }
        } catch let error as CapsuleerError where error.code == .reauthenticationRequired {
            guard generations[characterID, default: 0] == generation else { return try superseded(characterID) }
            try await markNeedsReauthentication(credential, reason: Self.invalidGrantReason)
            throw Self.reauthenticationError(characterID)
        } catch {
            // The token endpoint answered (the rotated token is kept, in memory at least), but
            // there is no usable access token. A save failure matters more than the validation error.
            if rotationSaveFailed.remove(characterID) != nil {
                throw CapsuleerError(.storage, message: "Could not save the rotated refresh token, and the new access token is unusable",
                                     underlying: error)
            }
            throw error
        }
        rotationSaveFailed.remove(characterID)

        // Logged out or re-authorized meanwhile: don't overwrite. The rotated token is unused, but
        // revoking it would end the grant and with it a re-login's fresh token, so it is dropped.
        guard generations[characterID, default: 0] == generation else {
            return try superseded(characterID)
        }
        guard response.character.id == characterID else {
            throw CapsuleerError(.ssoFailed, message: "Refreshed token belongs to another character")
        }
        if response.character.ownerHash != credential.character.ownerHash {
            try? await sso.revoke(refreshToken: response.refreshToken)
            await cache?.removeAll(identity: .character(characterID))
            try await markNeedsReauthentication(credential, reason: Self.ownerChangedReason)
            throw Self.reauthenticationError(characterID)
        }

        // Keep the scopes the store knows unless the token says otherwise.
        var character = response.character
        if character.scopes.isEmpty { character.scopes = credential.character.scopes }
        character.state = .active
        let refreshed = StoredCredential(character: character, refreshToken: response.refreshToken)
        guard generations[characterID, default: 0] == generation else { return try superseded(characterID) }
        do {
            try await store.save(refreshed)
            // Under the lock nothing newer can have been remembered meanwhile.
            unsavedCredentials[characterID] = nil
        } catch {
            // The new access token is usable, so hand it out; keep the credential in memory and retry later.
            unsavedCredentials[characterID] = refreshed
            logSink.log(.error, .sso, "Could not save the refreshed credential; keeping it in memory and retrying on next use",
                        metadata: ["error": (error as? CapsuleerError)?.code.rawValue ?? "unknown"],
                        privateMetadata: ["character": String(characterID)])
        }
        accessTokens[characterID] = CachedAccessToken(token: response.accessToken, expiresAt: response.expiresAt)
        logSink.log(.info, .sso, "Access token refreshed", privateMetadata: ["character": String(characterID)])
        events?(ClientEvent(kind: .tokenRefreshed, detail: String(characterID)))
        return response.accessToken
    }

    /// Saves a rotated refresh token the moment the token endpoint returns it, keeping the stored
    /// character data until the new access token has been validated. On failure the credential is
    /// kept in memory (and used for the next refresh).
    private func saveRotatedRefreshToken(_ rotated: String, replacing credential: StoredCredential, generation: Int) async {
        let id = credential.character.id
        guard generations[id, default: 0] == generation else { return }
        var updated = credential
        updated.refreshToken = rotated
        unsavedCredentials[id] = updated
        do {
            try await store.save(updated)
            if unsavedCredentials[id] == updated { unsavedCredentials[id] = nil }
        } catch {
            rotationSaveFailed.insert(id)
            logSink.log(.error, .sso, "Could not save the rotated refresh token; keeping it in memory and retrying on next use",
                        metadata: ["error": (error as? CapsuleerError)?.code.rawValue ?? "unknown"],
                        privateMetadata: ["character": String(id)])
        }
    }

    /// Retries saving a credential whose save failed earlier.
    private func saveUnsavedCredential(_ characterID: Int64) async {
        await lock(characterID)
        defer { unlock(characterID) }
        guard let unsaved = unsavedCredentials[characterID] else { return }
        do {
            try await store.save(unsaved)
            if unsavedCredentials[characterID] == unsaved { unsavedCredentials[characterID] = nil }
            logSink.log(.notice, .sso, "Saved a credential whose earlier save had failed", privateMetadata: ["character": String(characterID)])
        } catch {
            logSink.log(.error, .sso, "Still cannot save the refreshed credential; keeping it in memory",
                        metadata: ["error": (error as? CapsuleerError)?.code.rawValue ?? "unknown"],
                        privateMetadata: ["character": String(characterID)])
        }
    }

    private func markNeedsReauthentication(_ credential: StoredCredential, reason: String) async throws {
        let id = credential.character.id
        var character = credential.character
        character.state = .needsReauthentication(reason: reason)
        accessTokens[id] = nil
        generations[id, default: 0] += 1
        let marked = StoredCredential(character: character, refreshToken: "")
        // Remembered in memory first, so a failed save can't bring the dead token back.
        unsavedCredentials[id] = marked
        do {
            try await store.save(marked)
            if unsavedCredentials[id] == marked { unsavedCredentials[id] = nil }
        } catch {
            logSink.log(.error, .sso, "Could not save the re-authentication state; keeping it in memory",
                        privateMetadata: ["character": String(id)])
        }
        logSink.log(.notice, .sso, "Character needs to log in again", metadata: ["reason": reason], privateMetadata: ["character": String(id)])
        events?(ClientEvent(kind: .reauthenticationRequired, detail: String(id)))
    }

    private func recordRefreshFailure(_ error: CapsuleerError, for characterID: Int64) {
        guard refreshFailureBackoff > 0 else { return }
        let count = (refreshFailures[characterID]?.count ?? 0) + 1
        let cap = max(Self.maximumRefreshBackoff, refreshFailureBackoff)
        let interval = min(refreshFailureBackoff * pow(2, Double(min(count - 1, 16))), cap)
        refreshFailures[characterID] = RefreshFailure(error: error, count: count, until: timeSource.now().addingTimeInterval(interval))
        logSink.log(.notice, .sso, "Token refresh failed; backing off",
                    metadata: ["seconds": String(Int(interval)), "status": error.status.map(String.init) ?? "none"],
                    privateMetadata: ["character": String(characterID)])
    }

    // MARK: - Serialising credential changes

    private func lock(_ characterID: Int64) async {
        guard locks[characterID] != nil else {
            locks[characterID] = CredentialLock()
            return
        }
        // Ownership is handed over by `unlock`, which keeps the entry in place.
        await withCheckedContinuation { locks[characterID]?.waiters.append($0) }
    }

    private func unlock(_ characterID: Int64) {
        guard var lock = locks[characterID] else { return }
        if lock.waiters.isEmpty {
            locks[characterID] = nil
        } else {
            let next = lock.waiters.removeFirst()
            locks[characterID] = lock
            next.resume()
        }
    }

    private func beginChange(_ characterID: Int64, logout: Bool) {
        pendingChanges[characterID, default: 0] += 1
        if logout { loggingOut[characterID, default: 0] += 1 }
    }

    private func endChange(_ characterID: Int64, logout: Bool) {
        if logout { loggingOut[characterID] = Self.decremented(loggingOut[characterID]) }
        pendingChanges[characterID] = Self.decremented(pendingChanges[characterID])
        if pendingChanges[characterID] == nil, let waiters = changeWaiters.removeValue(forKey: characterID) {
            waiters.forEach { $0.resume() }
        }
    }

    private func waitForChanges(_ characterID: Int64) async {
        guard pendingChanges[characterID, default: 0] > 0 else { return }
        await withCheckedContinuation { changeWaiters[characterID, default: []].append($0) }
    }

    private static func decremented(_ value: Int?) -> Int? {
        guard let value, value > 1 else { return nil }
        return value - 1
    }

    private static func loggedOutError() -> CapsuleerError {
        CapsuleerError(.notAuthenticated, message: "Character is not logged in")
    }

    private static func reauthenticationError(_ id: Int64) -> CapsuleerError {
        CapsuleerError(.reauthenticationRequired, message: "Character \(id) must log in again")
    }

    /// The credential was replaced (re-login) or removed (logout) while a refresh was out: use the
    /// re-login's access token if there is one, else the character is no longer logged in.
    private func superseded(_ id: Int64) throws -> String {
        if let cached = accessTokens[id], cached.expiresAt.addingTimeInterval(-refreshLeeway) > timeSource.now() {
            return cached.token
        }
        throw CapsuleerError(.notAuthenticated, message: "Credential changed while refreshing")
    }
}
