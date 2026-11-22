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
