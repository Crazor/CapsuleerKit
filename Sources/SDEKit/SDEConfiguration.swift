import Foundation
import CapsuleerCore

/// Settings for an `SDEClient`.
public struct SDEConfiguration: Sendable {
    /// Identifies the app in every request.
    public var userAgent: UserAgent
    /// Where release metadata and decoded tables are kept.
    public var store: any SDEStore
    /// HTTP cache for the manifest and single records. nil disables HTTP caching. Whole tables
    /// never go into this cache; `store` keeps them.
    public var cache: (any CacheStore)?
    /// Sends requests. Tests inject `MockTransport`.
    public var transport: any HTTPTransport
    /// The SDE service root, ending in a slash. `latest/` and the release paths are resolved against it.
    public var baseURL: URL
    /// The manifest is checked over the network at most this often (seconds), unless a call forces it.
    public var releaseCheckInterval: TimeInterval
    /// After a failed release check or table download, the same work is not retried for this long
    /// (seconds); calls in between serve the stored data with `isStale = true` straight away instead
    /// of waiting on the network again. A failed table download is retried earlier when a later
    /// release check finds a different version. `forceCheck: true` always retries. A release check
    /// with nothing stored is never held back, since there is nothing to serve instead.
    /// Failures are remembered in memory only, so a relaunch retries.
    public var failureRetryInterval: TimeInterval
    /// Receives log messages (category `.sde`, plus `.http` / `.cache` from the HTTP pipeline).
    public var logSink: any LogSink
    /// Receives observability events such as `.sdeReleaseChecked` and `.sdeTableUpdated`.
    public var events: ClientEventHandler?
    /// The clock, controllable in tests.
    public var timeSource: any TimeSource

    /// The default SDE service root.
    public static let defaultBaseURL = URL(string: "https://sde.evetech.net/tranquility/")!

    /// Stores everything under `directory`: decoded tables in a `DiskSDEStore` at
    /// `directory/tables` and the HTTP cache in a `TieredCacheStore` at `directory/http`.
    /// Use Application Support rather than Caches so the data stays available offline.
    public init(
        userAgent: UserAgent,
        directory: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = SDEConfiguration.defaultBaseURL,
        releaseCheckInterval: TimeInterval = 86_400,
        failureRetryInterval: TimeInterval = 900,
        logSink: any LogSink = NullLogSink(),
        events: ClientEventHandler? = nil,
        timeSource: any TimeSource = SystemTimeSource()
    ) {
        self.init(
            userAgent: userAgent,
            store: DiskSDEStore(directory: directory.appendingPathComponent("tables", isDirectory: true)),
            cache: TieredCacheStore(directory: directory.appendingPathComponent("http", isDirectory: true)),
            transport: transport,
            baseURL: baseURL,
            releaseCheckInterval: releaseCheckInterval,
            failureRetryInterval: failureRetryInterval,
            logSink: logSink,
            events: events,
            timeSource: timeSource)
    }

    /// Uses the given table store and HTTP cache (nil: no HTTP caching).
    public init(
        userAgent: UserAgent,
        store: any SDEStore,
        cache: (any CacheStore)?,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = SDEConfiguration.defaultBaseURL,
        releaseCheckInterval: TimeInterval = 86_400,
        failureRetryInterval: TimeInterval = 900,
        logSink: any LogSink = NullLogSink(),
        events: ClientEventHandler? = nil,
        timeSource: any TimeSource = SystemTimeSource()
    ) {
        self.userAgent = userAgent
        self.store = store
        self.cache = cache
        self.transport = transport
        self.baseURL = baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("", isDirectory: true)
        self.releaseCheckInterval = releaseCheckInterval
        self.failureRetryInterval = failureRetryInterval
        self.logSink = logSink
        self.events = events
        self.timeSource = timeSource
    }
}
