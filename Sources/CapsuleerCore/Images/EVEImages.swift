import Foundation

/// URLs on CCP's image server (`https://images.evetech.net`).
public enum EVEImages {
    /// Portrait sizes the image server serves; any other size is a 400.
    public enum PortraitSize: Int, Sendable, Hashable, CaseIterable, Codable {
        case px32 = 32, px64 = 64, px128 = 128, px256 = 256, px512 = 512, px1024 = 1024
    }

    public static let baseURL = URL(string: "https://images.evetech.net/")!

    /// `https://images.evetech.net/characters/{id}/portrait?size={size}`. Unknown IDs get CCP's
    /// default silhouette, not an error.
    public static func characterPortrait(_ characterID: Int64, size: PortraitSize = .px128, baseURL: URL = EVEImages.baseURL) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("characters/\(characterID)/portrait"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "size", value: String(size.rawValue))]
        return components.url!
    }
}

/// Downloads images from CCP's image server through the CapsuleerKit pipeline: User-Agent,
/// HTTP cache honouring the server's `Cache-Control`/ETag (portraits: one hour, then revalidated),
/// coalescing of identical requests, and stale cached data when offline (`Response.isStale`).
public final class EVEImageClient: Sendable {
    public struct Configuration: Sendable {
        public var userAgent: UserAgent
        public var cache: (any CacheStore)?
        public var transport: any HTTPTransport
        public var baseURL: URL
        public var logSink: any LogSink
        public var events: ClientEventHandler?
        public var timeSource: any TimeSource

        public init(userAgent: UserAgent, cache: (any CacheStore)? = nil, transport: any HTTPTransport = URLSessionTransport(),
                    baseURL: URL = EVEImages.baseURL, logSink: any LogSink = NullLogSink(),
                    events: ClientEventHandler? = nil, timeSource: any TimeSource = SystemTimeSource()) {
            self.userAgent = userAgent
            self.cache = cache
            self.transport = transport
            self.baseURL = baseURL
            self.logSink = logSink
            self.events = events
            self.timeSource = timeSource
        }

        /// Convenience: tiered cache in `cacheDirectory` (use Caches; images can be fetched again).
        public init(userAgent: UserAgent, cacheDirectory: URL) {
            self.init(userAgent: userAgent, cache: TieredCacheStore(directory: cacheDirectory))
        }
    }

    public let configuration: Configuration
    private let http: HTTPClient

    public init(configuration: Configuration) {
        self.configuration = configuration
        http = HTTPClient(configuration: HTTPClient.Configuration(
            userAgent: configuration.userAgent, transport: configuration.transport, cache: configuration.cache,
            logSink: configuration.logSink, events: configuration.events, timeSource: configuration.timeSource))
    }

    /// The portrait's image data (JPEG). Throws `CapsuleerError` for network errors without a
    /// cached copy; a cached copy is returned with `isStale = true` when the network fails.
    public func characterPortrait(_ characterID: Int64, size: EVEImages.PortraitSize = .px128,
                                  policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<Data> {
        let url = EVEImages.characterPortrait(characterID, size: size, baseURL: configuration.baseURL)
        return try await http.send(HTTPRequest(url: url), policy: policy).map(\.body)
    }
}
