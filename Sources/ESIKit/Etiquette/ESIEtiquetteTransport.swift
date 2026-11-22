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

    let base: any HTTPTransport
    public let configuration: Configuration
    let rateLimiter: RateLimiter
    let errorBudget: ErrorBudget
    let retryPolicy: RetryPolicy

    public convenience init(base: any HTTPTransport, configuration: Configuration = Configuration()) {
        self.init(base: base, configuration: configuration, jitter: RetryPolicy.defaultJitter)
    }

    /// `jitter` returns the backoff multiplier (tests pass a constant).
    init(base: any HTTPTransport, configuration: Configuration, jitter: @escaping @Sendable () -> Double) {
        self.base = base
        self.configuration = configuration
        rateLimiter = RateLimiter(reserve: configuration.rateLimitReserve)
        errorBudget = ErrorBudget(floor: configuration.errorLimitFloor)
        retryPolicy = RetryPolicy(maxRetries: max(0, configuration.maxRetries), jitter: jitter)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let hints = Hints(request.headers)
        var outgoing = request
        for field in request.headers where field.name.lowercased().hasPrefix(Hints.prefix) {
            outgoing.headers[field.name] = nil
        }
        outgoing.headers["X-Compatibility-Date"] = configuration.compatibilityDate
        let context = Context(request: outgoing, hints: hints)

        var retriesUsed = 0
        var usedRetryAfter = false
        while true {
            try checkCancellation(context)
            try await waitForErrorBudget(context)
            let reservation = try await reserveRateLimit(context)

            let response: HTTPResponse
            do {
                response = try await base.send(outgoing)
            } catch {
                if let reservation { await rateLimiter.release(reservation) }
                let failure = error as? CapsuleerError
                if error is CancellationError || failure?.code == .cancelled || Task.isCancelled {
                    throw failure?.code == .cancelled ? failure! : CapsuleerError(.cancelled, url: request.url, underlying: error)
                }
                if failure?.code == .transport, hints.idempotent, retriesUsed < retryPolicy.maxRetries {
                    try await backoff(context, retry: retriesUsed, status: nil, reason: "transport error")
                    retriesUsed += 1
                    continue
                }
                throw error
            }

            let now = configuration.timeSource.now()
            await rateLimiter.record(reservation, identity: hints.identity, status: response.status, headers: response.headers, now: now)
            await errorBudget.record(status: response.status, headers: response.headers, now: now)

            // 429: ESI did not process the request, so resending is safe for any method.
            // 503: it may have been processed, so only idempotent requests are resent.
            if response.status == 429 || (response.status == 503 && hints.idempotent),
               let retryAfter = RetryPolicy.retryAfter(response.headers["Retry-After"], now: now) {
                if !usedRetryAfter, retryAfter <= EtiquetteTime.seconds(configuration.maxWait) {
                    usedRetryAfter = true
                    log(.info, "Retry-After \(response.status): waiting \(Self.format(retryAfter)) s", context, extra: ["status": String(response.status)])
                    emit(ClientEvent(kind: .retried, url: request.url, status: response.status, duration: EtiquetteTime.duration(retryAfter), detail: "Retry-After"))
                    try await sleep(retryAfter, context)
                    continue
                }
                if response.status == 429 {
                    log(.info, "Rate limited (429); Retry-After \(Self.format(retryAfter)) s exceeds patience", context)
                    throw CapsuleerError(.rateLimited, status: 429, message: "ESI rate limit exceeded", url: request.url,
                                         retryAfter: EtiquetteTime.duration(retryAfter))
                }
                return response
            }

            if RetryPolicy.retriedServerErrors.contains(response.status), hints.idempotent, retriesUsed < retryPolicy.maxRetries {
                try await backoff(context, retry: retriesUsed, status: response.status, reason: "HTTP \(response.status)")
                retriesUsed += 1
                continue
            }
            return response
        }
    }

    // MARK: - Steps

    /// What the transport needs to know about one `send` call.
    private struct Context: Sendable {
        var request: HTTPRequest
        var hints: Hints
        var url: URL { request.url }
    }

    /// The `ESIRequestHints` headers of a request.
    struct Hints: Sendable {
        static let prefix = "x-capsuleerkit-"
        var group: String?
        var window: RateLimitWindow?
        var identity: String
        var idempotent: Bool

        init(_ headers: HTTPHeaders) {
            let group = headers[ESIRequestHints.rateLimitGroup]?.trimmingCharacters(in: .whitespaces)
            self.group = group?.isEmpty == false ? group : nil
            window = headers[ESIRequestHints.rateLimitWindow].flatMap(RateLimitWindow.init)
            let identity = headers[ESIRequestHints.identity]?.trimmingCharacters(in: .whitespaces)
            self.identity = identity?.isEmpty == false ? identity! : "public"
            idempotent = headers[ESIRequestHints.idempotent]?.trimmingCharacters(in: .whitespaces) == "1"
        }
    }

    private func waitForErrorBudget(_ context: Context) async throws {
        while true {
            let wait = await errorBudget.requiredWait(now: configuration.timeSource.now())
            guard wait > 0 else { return }
            if wait > EtiquetteTime.seconds(configuration.maxWait) {
                log(.info, "Error budget exhausted; reset in \(Self.format(wait)) s exceeds patience", context)
                throw CapsuleerError(.errorLimited, message: "ESI error limit exhausted", url: context.url, retryAfter: EtiquetteTime.duration(wait))
            }
            log(.info, "Error budget low; waiting \(Self.format(wait)) s for reset", context)
            emit(ClientEvent(kind: .errorBudgetLow, url: context.url, duration: EtiquetteTime.duration(wait)))
            try await sleep(wait, context)
        }
    }

    private func reserveRateLimit(_ context: Context) async throws -> RateLimiter.Reservation? {
        guard let group = context.hints.group else { return nil }
        let key = RateLimitKey(group: group, identity: context.hints.identity)
        let patience = EtiquetteTime.seconds(configuration.maxWait)
        var waited: TimeInterval = 0
        while true {
            switch await rateLimiter.reserve(key, seed: context.hints.window, now: configuration.timeSource.now()) {
            case .unlimited:
                return nil
            case .granted(let reservation):
                return reservation
            case .wait(let wait):
                if waited + wait > patience {
                    log(.info, "Rate limit: wait of \(Self.format(wait)) s exceeds patience", context, extra: ["group": group])
                    throw CapsuleerError(.rateLimited, message: "ESI rate-limit group \(group) is exhausted", url: context.url,
                                         retryAfter: EtiquetteTime.duration(wait))
                }
                log(.debug, "Rate limit reserve reached; waiting \(Self.format(wait)) s", context, extra: ["group": group])
                emit(ClientEvent(kind: .rateLimitWait, url: context.url, duration: EtiquetteTime.duration(wait), detail: group))
                try await sleep(wait, context)
                waited += wait
            }
        }
    }

    private func backoff(_ context: Context, retry: Int, status: Int?, reason: String) async throws {
        let delay = retryPolicy.backoff(forRetry: retry)
        log(.info, "Retrying after \(reason) in \(Self.format(delay)) s (retry \(retry + 1) of \(retryPolicy.maxRetries))", context,
            extra: status.map { ["status": String($0)] } ?? [:])
        emit(ClientEvent(kind: .retried, url: context.url, status: status, duration: EtiquetteTime.duration(delay), detail: reason))
        try await sleep(delay, context)
    }

    /// Sleeps through the time source; cancellation (or any sleep failure) ends the request as `.cancelled`.
    private func sleep(_ seconds: TimeInterval, _ context: Context) async throws {
        try checkCancellation(context)
        do {
            try await configuration.timeSource.sleep(for: EtiquetteTime.duration(seconds))
        } catch {
            throw CapsuleerError(.cancelled, url: context.url, underlying: error)
        }
        try checkCancellation(context)
    }

    private func checkCancellation(_ context: Context) throws {
        if Task.isCancelled { throw CapsuleerError(.cancelled, url: context.url, underlying: CancellationError()) }
    }

    // MARK: - Events and logging

    private func emit(_ event: ClientEvent) { configuration.events?(event) }

    /// Logs method and URL (private for non-public identities, whose URLs embed character IDs).
    /// Never logs header values, so Authorization can't leak.
    private func log(_ level: LogLevel, _ message: String, _ context: Context, extra: [String: String] = [:]) {
        var metadata = extra
        metadata["method"] = context.request.method.rawValue
        var privateMetadata: [String: String] = [:]
        if context.hints.identity == "public" {
            metadata["url"] = context.url.absoluteString
        } else {
            privateMetadata["identity"] = context.hints.identity
            privateMetadata["url"] = context.url.absoluteString
        }
        configuration.logSink.log(level, .ratelimit, message, metadata: metadata, privateMetadata: privateMetadata)
    }

    private static func format(_ seconds: TimeInterval) -> String { String(format: "%.1f", seconds) }
}
