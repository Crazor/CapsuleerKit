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

    public init(userAgent: UserAgent, cache: (any CacheStore)? = nil, transport: any HTTPTransport = URLSessionTransport(),
                tokenProvider: (any ESITokenProvider)? = nil, etiquette: ESIEtiquetteTransport.Configuration? = nil,
                logSink: any LogSink = NullLogSink(), events: ClientEventHandler? = nil,
                timeSource: any TimeSource = SystemTimeSource()) {
        self.userAgent = userAgent
        self.cache = cache
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.etiquette = etiquette ?? ESIEtiquetteTransport.Configuration(timeSource: timeSource, logSink: logSink, events: events)
        self.logSink = logSink
        self.events = events
        self.timeSource = timeSource
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
/// token and retries once.
public final class ESIClient: Sendable {
    public let configuration: ESIConfiguration

    public init(configuration: ESIConfiguration) {
        self.configuration = configuration
        fatalError("TODO(endpoints agent)")
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
    public func publicInfo(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterPublicInfo> { fatalError("TODO(endpoints agent)") }
    /// `GET /characters/{id}/location` (`esi-location.read_location.v1`).
    public func location(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterLocation> { fatalError("TODO(endpoints agent)") }
    /// `GET /characters/{id}/ship` (`esi-location.read_ship_type.v1`).
    public func ship(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterShip> { fatalError("TODO(endpoints agent)") }
    /// `GET /characters/{id}/online` (`esi-location.read_online.v1`).
    public func online(policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<CharacterOnline> { fatalError("TODO(endpoints agent)") }
}

public struct UniverseEndpoints: Sendable {
    let client: ESIClient

    /// `POST /universe/names`: IDs → names and categories. Batches of ≤ 1000 IDs; results cached
    /// in-process and in the HTTP cache store with a long TTL (names of stations etc. rarely change).
    public func names(_ ids: [Int64]) async throws -> [ResolvedEntity] { fatalError("TODO(endpoints agent)") }
    /// `POST /universe/ids`: exact names → IDs. Batches of ≤ 500 names; cached 12 h.
    public func ids(_ names: [String]) async throws -> [ResolvedEntity] { fatalError("TODO(endpoints agent)") }
    /// `GET /universe/structures/{id}` as `characterID` (`esi-universe.read_structures.v1`).
    public func structure(_ structureID: Int64, as characterID: Int64, policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<StructureInfo> { fatalError("TODO(endpoints agent)") }
}
