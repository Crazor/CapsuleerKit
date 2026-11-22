import CapsuleerCore
import Foundation

/// Per-request hints that ESIKit attaches as request headers for `ESIEtiquetteTransport`.
/// The transport reads and strips them; they never reach ESI.
public enum ESIRequestHints {
    /// Rate-limit group from the spec's `x-rate-limit.group`, e.g. "char-location".
    public static let rateLimitGroup = "X-CapsuleerKit-Ratelimit-Group"
    /// Bucket size from the spec, "<max-tokens>/<window>", e.g. "1200/15m".
    public static let rateLimitWindow = "X-CapsuleerKit-Ratelimit-Window"
    /// Whose bucket: "public" or "character:<id>" (`CacheIdentity.rawValue`).
    public static let identity = "X-CapsuleerKit-Identity"
    /// "1" when the request is safe to retry on 5XX/network errors (GET, documented lookup POSTs).
    public static let idempotent = "X-CapsuleerKit-Idempotent"
}

/// ESI etiquette as an `HTTPTransport` decorator, installed under `HTTPClient` (so cache hits never
/// reach it): `X-Compatibility-Date`, rate-limit buckets per (group, identity), the shared error
/// budget, `Retry-After`, bounded retries for 5XX/network errors, never retrying other 4XX.
/// Non-success responses are returned (not thrown) unless waiting is impossible, so `HTTPClient`
/// maps them to `CapsuleerError` as usual.
public final class ESIEtiquetteTransport: HTTPTransport {
    public struct Configuration: Sendable {
        public var compatibilityDate: String
        public var timeSource: any TimeSource
        public var logSink: any LogSink
        public var events: ClientEventHandler?
        /// Retries after 5XX / network errors for idempotent requests.
        public var maxRetries: Int
        /// Pause all requests when `X-Esi-Error-Limit-Remain` is at or below this.
        public var errorLimitFloor: Int
        /// Fraction of a rate-limit bucket kept in reserve; below it requests are spaced out.
        public var rateLimitReserve: Double
        /// Longest wait (rate limit, error limit, Retry-After) before throwing `.rateLimited` / `.errorLimited` instead.
        public var maxWait: Duration

        public init(compatibilityDate: String = ESI.compatibilityDate, timeSource: any TimeSource = SystemTimeSource(),
                    logSink: any LogSink = NullLogSink(), events: ClientEventHandler? = nil,
                    maxRetries: Int = 2, errorLimitFloor: Int = 10, rateLimitReserve: Double = 0.1,
                    maxWait: Duration = .seconds(60)) {
            self.compatibilityDate = compatibilityDate
            self.timeSource = timeSource
            self.logSink = logSink
            self.events = events
            self.maxRetries = maxRetries
            self.errorLimitFloor = errorLimitFloor
            self.rateLimitReserve = rateLimitReserve
            self.maxWait = maxWait
        }
    }

    public init(base: any HTTPTransport, configuration: Configuration = Configuration()) {
        fatalError("TODO(etiquette agent)")
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        fatalError("TODO(etiquette agent)")
    }
}
