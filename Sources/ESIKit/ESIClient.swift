import CapsuleerCore
import Foundation

/// Configuration for `ESIClient`.
public struct ESIConfiguration: Sendable {
    public var userAgent: UserAgent
    /// HTTP cache for ESI responses (keyed by identity, so per-character data never mixes).
    public var cache: (any CacheStore)?
    /// Network transport; `ESIClient` wraps it in `ESIEtiquetteTransport`.
    public var transport: any HTTPTransport
    /// Access tokens for authenticated calls (usually a `TokenManager`). nil = public calls only.
    public var tokenProvider: (any ESITokenProvider)?
    public var etiquette: ESIEtiquetteTransport.Configuration
    public var logSink: any LogSink
    public var events: ClientEventHandler?
    public var timeSource: any TimeSource
    /// How long, after a 401 that survived the refresh-and-retry (ESI rejected a freshly minted
    /// token too), further 401s for that character are thrown at once without invalidating the
    /// token, refreshing or retrying. A successful authenticated call for the character ends it
    /// early. Bounds the error-budget and SSO cost of a locked account or an ESI auth incident.
    public var unauthorizedCooldown: Duration

    public init(userAgent: UserAgent, cache: (any CacheStore)? = nil, transport: any HTTPTransport = URLSessionTransport(),
                tokenProvider: (any ESITokenProvider)? = nil, etiquette: ESIEtiquetteTransport.Configuration? = nil,
                logSink: any LogSink = NullLogSink(), events: ClientEventHandler? = nil,
                timeSource: any TimeSource = SystemTimeSource(), unauthorizedCooldown: Duration = .seconds(300)) {
        self.userAgent = userAgent
        self.cache = cache
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.etiquette = etiquette ?? ESIEtiquetteTransport.Configuration(timeSource: timeSource, logSink: logSink, events: events)
        self.logSink = logSink
        self.events = events
        self.timeSource = timeSource
        self.unauthorizedCooldown = unauthorizedCooldown
    }

    /// Convenience: tiered HTTP cache in `cacheDirectory`.
    public init(userAgent: UserAgent, cacheDirectory: URL, tokenProvider: (any ESITokenProvider)? = nil,
                logSink: any LogSink = NullLogSink(), events: ClientEventHandler? = nil) {
        self.init(userAgent: userAgent, cache: TieredCacheStore(directory: cacheDirectory),
                  tokenProvider: tokenProvider, logSink: logSink, events: events)
    }
}

/// Client for CCP's ESI. Every request carries the User-Agent and `X-Compatibility-Date`, is
/// cached per identity, and goes through `ESIEtiquetteTransport` (rate limits, error budget, retries).
/// Authenticated calls get their token from `configuration.tokenProvider`; a 401 invalidates the
/// token and retries once. If the fresh token is rejected too, that character's 401s are thrown
/// without a refresh or retry for `configuration.unauthorizedCooldown` (default 5 minutes) or
/// until one of its calls succeeds, so a locked account or an ESI auth incident does not burn
/// two errors of the shared error budget plus an SSO refresh on every poll.
public final class ESIClient: Sendable {
    public let configuration: ESIConfiguration
    /// The pipeline every request goes through (cache, coalescing, etiquette transport).
    let http: HTTPClient
    /// Resolved names and IDs (`universe.names` / `universe.ids`).
    let lookups: LookupCache
    /// Characters whose 401s currently skip the refresh-and-retry.
    let unauthorizedCooldown = UnauthorizedCooldown()

    public convenience init(configuration: ESIConfiguration) {
        self.init(configuration: configuration, wrapTransport: true)
    }

    /// - wrapTransport: false sends straight to `configuration.transport`, without
    ///   `ESIEtiquetteTransport` (tests of the endpoint layer only).
    init(configuration: ESIConfiguration, wrapTransport: Bool) {
        self.configuration = configuration
        let transport: any HTTPTransport = wrapTransport
            ? ESIEtiquetteTransport(base: configuration.transport, configuration: configuration.etiquette)
            : configuration.transport
        http = HTTPClient(configuration: .init(
            userAgent: configuration.userAgent, transport: transport, cache: configuration.cache,
            logSink: configuration.logSink, events: configuration.events, timeSource: configuration.timeSource))
        lookups = LookupCache(store: configuration.cache, timeSource: configuration.timeSource)
    }

    /// Endpoints about one character. Authenticated ones need `tokenProvider`.
    public func character(_ characterID: Int64) -> CharacterEndpoints { CharacterEndpoints(client: self, characterID: characterID) }

    /// Universe endpoints (names, IDs, structures).
    public var universe: UniverseEndpoints { UniverseEndpoints(client: self) }
}

public struct CharacterEndpoints: Sendable {
    let client: ESIClient
    public let characterID: Int64

    /// `GET /characters/{id}` (public).
    public func publicInfo(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterPublicInfo> {
        let path = Operations.GetCharactersDetail.Input.Path(characterId: characterID)
        return try await client.publicCall(.getCharactersDetail, policy: policy) { api in
            try await api.getCharactersDetail(path: path, headers: .init(xCompatibilityDate: .pinned)).ok.body.json
        }.map(CharacterPublicInfo.init)
    }

    /// `GET /characters/{id}/location` (`esi-location.read_location.v1`).
    public func location(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterLocation> {
        let path = Operations.GetCharactersCharacterIdLocation.Input.Path(characterId: characterID)
        return try await client.authenticatedCall(.getCharactersCharacterIdLocation, as: characterID, policy: policy) { api in
            try await api.getCharactersCharacterIdLocation(path: path, headers: .init(xCompatibilityDate: .pinned)).ok.body.json
        }.map(CharacterLocation.init)
    }

    /// `GET /characters/{id}/ship` (`esi-location.read_ship_type.v1`).
    public func ship(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterShip> {
        let path = Operations.GetCharactersCharacterIdShip.Input.Path(characterId: characterID)
        return try await client.authenticatedCall(.getCharactersCharacterIdShip, as: characterID, policy: policy) { api in
            try await api.getCharactersCharacterIdShip(path: path, headers: .init(xCompatibilityDate: .pinned)).ok.body.json
        }.map(CharacterShip.init)
    }

    /// `GET /characters/{id}/online` (`esi-location.read_online.v1`).
    public func online(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterOnline> {
        let path = Operations.GetCharactersCharacterIdOnline.Input.Path(characterId: characterID)
        return try await client.authenticatedCall(.getCharactersCharacterIdOnline, as: characterID, policy: policy) { api in
            try await api.getCharactersCharacterIdOnline(path: path, headers: .init(xCompatibilityDate: .pinned)).ok.body.json
        }.map(CharacterOnline.init)
    }
}

public struct UniverseEndpoints: Sendable {
    let client: ESIClient

    /// Spec `maxItems` of the request bodies.
    static let namesBatchSize = 1000
    static let idsBatchSize = 500

    /// `POST /universe/names`: IDs → names and categories. Batches of ≤ 1000 IDs; results cached
    /// in-process and in the HTTP cache store with a long TTL (names of stations etc. rarely change).
    ///
    /// Returns one entity per resolved ID, in the order of `ids` (duplicates removed). ESI answers
    /// 404 for a batch that contains an ID it cannot resolve; that error is thrown unchanged.
    /// When the network fails, expired cached names are used where available.
    public func names(_ ids: [Int64]) async throws -> [ResolvedEntity] {
        let unique = ids.uniqued()
        var resolved: [Int64: ResolvedEntity] = [:]
        var missing: [Int64] = []
        for id in unique {
            if let entity = await client.lookups.name(for: id) { resolved[id] = entity } else { missing.append(id) }
        }
        for batch in missing.chunked(into: Self.namesBatchSize) {
            do {
                let entities = try await client.publicCall(.postUniverseNames, policy: .reloadRevalidatingCacheData) { api in
                    try await api.postUniverseNames(headers: .init(xCompatibilityDate: .pinned), body: .json(batch)).ok.body.json
                }.value.map(ResolvedEntity.init)
                await client.lookups.storeNames(entities)
                for entity in entities { resolved[entity.id] = entity }
            } catch let error as CapsuleerError where error.code == .transport {
                var stale: [Int64: ResolvedEntity] = [:]
                for id in batch { stale[id] = await client.lookups.name(for: id, allowStale: true) }
                guard stale.count == batch.count else { throw error }
                resolved.merge(stale) { current, _ in current }
            }
        }
        return unique.compactMap { resolved[$0] }
    }

    /// `POST /universe/ids`: exact names → IDs. Batches of ≤ 500 names; cached 12 h.
    ///
    /// Returns the entities whose name equals one of `names` (ignoring case), in the order of
    /// `names`; one name can match several entities (e.g. a character and a type). ESI also
    /// returns partial matches such as corporation tickers; those are dropped. Names that match
    /// nothing are cached for 1 h.
    public func ids(_ names: [String]) async throws -> [ResolvedEntity] {
        let unique = names.uniqued()
        var resolved: [String: [ResolvedEntity]] = [:]
        var missing: [String] = []
        for name in unique {
            if let entities = await client.lookups.ids(for: name) { resolved[name] = entities } else { missing.append(name) }
        }
        for batch in missing.chunked(into: Self.idsBatchSize) {
            do {
                let response = try await client.publicCall(.postUniverseIds, policy: .reloadRevalidatingCacheData) { api in
                    try await api.postUniverseIds(headers: .init(xCompatibilityDate: .pinned), body: .json(batch)).ok.body.json
                }
                let entities = ResolvedEntity.entities(from: response.value)
                for name in batch {
                    let matches = entities.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    resolved[name] = matches
                    await client.lookups.storeIDs(matches, for: name)
                }
            } catch let error as CapsuleerError where error.code == .transport {
                for name in batch {
                    guard let stale = await client.lookups.ids(for: name, allowStale: true) else { throw error }
                    resolved[name] = stale
                }
            }
        }
        return unique.flatMap { resolved[$0] ?? [] }
    }

    /// `GET /universe/structures/{id}` as `characterID` (`esi-universe.read_structures.v1`).
    /// Throws the 403 (`.http`, status 403) when the character has no docking access.
    public func structure(_ structureID: Int64, as characterID: Int64, policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<StructureInfo> {
        let path = Operations.GetUniverseStructuresStructureId.Input.Path(structureId: structureID)
        return try await client.authenticatedCall(.getUniverseStructuresStructureId, as: characterID, policy: policy) { api in
            try await api.getUniverseStructuresStructureId(path: path, headers: .init(xCompatibilityDate: .pinned)).ok.body.json
        }.map(StructureInfo.init)
    }
}
