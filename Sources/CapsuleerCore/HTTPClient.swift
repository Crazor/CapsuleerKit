import Foundation

/// The shared request pipeline: User-Agent, cache lookup, conditional revalidation, transport,
/// 304 handling, storing, stale-if-error, and coalescing of identical in-flight requests.
/// Non-success statuses throw `CapsuleerError` (`.notFound` for 404, `.http` otherwise; `message` = body text, truncated).
public final class HTTPClient: Sendable {
    public struct Configuration: Sendable {
        public var userAgent: UserAgent
        public var transport: any HTTPTransport
        public var cache: (any CacheStore)?
        public var logSink: any LogSink
        public var events: ClientEventHandler?
        public var timeSource: any TimeSource

        public init(
            userAgent: UserAgent,
            transport: any HTTPTransport = URLSessionTransport(),
            cache: (any CacheStore)? = nil,
            logSink: any LogSink = NullLogSink(),
            events: ClientEventHandler? = nil,
            timeSource: any TimeSource = SystemTimeSource()
        ) {
            self.userAgent = userAgent
            self.transport = transport
            self.cache = cache
            self.logSink = logSink
            self.events = events
            self.timeSource = timeSource
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
        fatalError("TODO(cache agent)")
    }

    /// Sends `request` through the pipeline. Only GET (and HEAD) responses are cached.
    /// - identity: whose data this is (part of the cache key; `.character` marks entries private).
    /// - variant: request headers that the server varies on, added to the cache key (and to the request).
    public func send(
        _ request: HTTPRequest,
        identity: CacheIdentity = .public,
        variant: [String: String] = [:],
        policy: CachePolicy = .useProtocolCachePolicy
    ) async throws -> Response<HTTPResponse> {
        fatalError("TODO(cache agent)")
    }
}

extension Response where Value == HTTPResponse {
    /// Decodes the body as JSON; throws `CapsuleerError(.decoding)` on failure.
    public func decode<T: Decodable & Sendable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> Response<T> {
        do {
            return try map { try decoder.decode(T.self, from: $0.body) }
        } catch {
            throw CapsuleerError(.decoding, message: String(describing: error), url: value.url, underlying: error)
        }
    }
}
