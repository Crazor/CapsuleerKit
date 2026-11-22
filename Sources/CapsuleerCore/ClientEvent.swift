import Foundation

/// Observability events for apps (metrics, debug views). A struct with an extensible `Kind`
/// so new event kinds don't break apps.
public struct ClientEvent: Sendable {
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// A request finished (from network, cache or revalidation). `source`, `status`, `duration` set.
        public static let requestFinished = Kind(rawValue: "requestFinished")
        /// A request failed. `error` set.
        public static let requestFailed = Kind(rawValue: "requestFailed")
        /// A stale cached response was served because the network failed.
        public static let servedStale = Kind(rawValue: "servedStale")
        /// SDE sync events.
        public static let sdeReleaseChecked = Kind(rawValue: "sdeReleaseChecked")
        public static let sdeTableUpdated = Kind(rawValue: "sdeTableUpdated")
        /// ESI: a request waited for the rate limiter (`duration`, `detail` = group).
        public static let rateLimitWait = Kind(rawValue: "rateLimitWait")
        /// ESI: the error budget is at or below its floor; requests pause until reset (`duration`).
        public static let errorBudgetLow = Kind(rawValue: "errorBudgetLow")
        /// ESI: a request was retried (`status`, `detail` = reason).
        public static let retried = Kind(rawValue: "retried")
        /// SSO: an access token was refreshed (`detail` = character ID, private).
        public static let tokenRefreshed = Kind(rawValue: "tokenRefreshed")
        /// SSO: a character needs to log in again (`detail` = character ID).
        public static let reauthenticationRequired = Kind(rawValue: "reauthenticationRequired")
    }

    public var kind: Kind
    public var url: URL?
    public var status: Int?
    public var source: ResponseSource?
    public var duration: Duration?
    public var error: CapsuleerError?
    public var detail: String?

    public init(kind: Kind, url: URL? = nil, status: Int? = nil, source: ResponseSource? = nil, duration: Duration? = nil, error: CapsuleerError? = nil, detail: String? = nil) {
        self.kind = kind
        self.url = url
        self.status = status
        self.source = source
        self.duration = duration
        self.error = error
        self.detail = detail
    }
}

public typealias ClientEventHandler = @Sendable (ClientEvent) -> Void
