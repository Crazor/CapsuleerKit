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
    /// Network flights, coalesced on the cache key alone: the policy only decides whether a
    /// caller may be answered from the cache before the network is involved, so every caller
    /// that does reach the network for a key shares the same (single) revalidation.
    let inFlight = InFlightRequests<CacheKey, Response<HTTPResponse>>()

    /// Upper bound for the server message copied into `CapsuleerError.message`.
    static let maxErrorMessageLength = 500

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Sends `request` through the pipeline. Only GET (and HEAD) responses are cached.
    /// - identity: whose data this is (part of the cache key; `.character` marks entries private).
    /// - variant: request headers that the server varies on, added to the cache key (and to the request).
    ///
    /// Callers that the cache can answer under their policy (a fresh hit, or any hit with
    /// `.returnCacheDataElseLoad`) never touch the network. Concurrent GET/HEAD calls with the
    /// same cache key that do need the network share one network run (and one set of events),
    /// whatever their policy. Cancelling one caller does not cancel the shared request.
    public func send(
        _ request: HTTPRequest,
        identity: CacheIdentity = .public,
        variant: [String: String] = [:],
        policy: CachePolicy = .useProtocolCachePolicy
    ) async throws -> Response<HTTPResponse> {
        var request = request
        request.headers["User-Agent"] = configuration.userAgent.headerValue
        for name in variant.keys.sorted() { request.headers[name] = variant[name] }
        let key = CacheKey(method: request.method, url: request.url, body: request.body, identity: identity, variant: variant)

        guard request.method == .get || request.method == .head else {
            // POST: no lookup, no store, no coalescing.
            return try await run(request, key: key, useCache: false)
        }
        if let hit = await cachedResponse(request, key: key, policy: policy) { return hit }
        let finalRequest = request
        do {
            return try await inFlight.value(for: key) { [self] in
                try await run(finalRequest, key: key, useCache: true)
            }
        } catch {
            let mapped = Self.map(error, url: request.url)
            if error is CancellationError {
                // This caller stopped waiting; the shared request (if any) carries on.
                emit(ClientEvent(kind: .requestFailed, url: request.url, error: mapped))
            }
            throw mapped
        }
    }

    // MARK: - Pipeline

    /// The pre-network lookup: answers from the cache when `policy` allows it, else nil.
    private func cachedResponse(_ request: HTTPRequest, key: CacheKey, policy: CachePolicy) async -> Response<HTTPResponse>? {
        guard policy != .reloadRevalidatingCacheData, let cache = configuration.cache else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        guard let entry = await cache.entry(for: key) else { return nil }
        let fresh = entry.isFresh(at: configuration.timeSource.now())
        guard fresh || policy == .returnCacheDataElseLoad else { return nil }
        log(.debug, .cache, fresh ? "Cache hit" : "Cache hit (stale)", request, key: key, entry: entry)
        return finish(Self.response(from: entry, source: .cache, isStale: !fresh), request, started, clock)
    }

    /// The network part of the pipeline: revalidates the current entry (if any) or loads.
    private func run(_ request: HTTPRequest, key: CacheKey, useCache: Bool) async throws -> Response<HTTPResponse> {
        let clock = ContinuousClock()
        let started = clock.now
        let cache = useCache ? configuration.cache : nil
        var request = request
        var cached: CacheEntry?

        if let cache, let entry = await cache.entry(for: key) {
            cached = entry
            if let etag = entry.etag { request.headers["If-None-Match"] = etag }
            if let lastModified = entry.lastModified { request.headers["If-Modified-Since"] = lastModified }
            log(.debug, .cache, "Revalidating cached entry", request, key: key, entry: entry)
        }

        let response: HTTPResponse
        do {
            log(.debug, .http, "Sending request", request, key: key)
            response = try await configuration.transport.send(request)
        } catch {
            let mapped = Self.map(error, url: request.url)
            if mapped.code == .transport, let cached {
                return serveStale(cached, request, key: key, status: nil, error: mapped, started, clock)
            }
            return try fail(mapped, request, key: key)
        }

        let now = configuration.timeSource.now()
        switch response.status {
        case 304:
            guard let cache, let cached else {
                return try fail(CapsuleerError(.invalidResponse, status: 304, message: "304 Not Modified without a cached entry", url: request.url), request, key: key)
            }
            // Someone else may have replaced the entry while this request was out. The 304 only
            // vouches for the representation whose validators were sent; never merge it into a
            // different (possibly newer) entry, and never resurrect a removed one.
            let current = await cache.entry(for: key)
            guard let current, current.etag == cached.etag, current.lastModified == cached.lastModified else {
                if let current {
                    log(.info, .http, "Revalidated (304) a superseded entry; keeping the current one", request, key: key, entry: current)
                    let fresh = current.isFresh(at: now)
                    return finish(Self.response(from: current, source: .cache, isStale: !fresh), request, started, clock)
                }
                log(.info, .http, "Revalidated (304) an entry that was removed meanwhile; not storing", request, key: key, entry: cached)
                let merged = Self.merging(response, into: cached, now: now)
                return finish(Self.response(from: merged, source: .revalidated, isStale: false), request, started, clock)
            }
            let entry = Self.merging(response, into: current, now: now)
            if Freshness.evaluate(entry.headers, now: now) == .doNotStore { await cache.remove(key) } else { await cache.store(entry, for: key) }
            log(.info, .http, "Revalidated (304)", request, key: key, entry: entry)
            return finish(Self.response(from: entry, source: .revalidated, isStale: false), request, started, clock)

        case 200..<300:
            let freshness = Freshness.evaluate(response.headers, now: now)
            if response.status == 200, let cache {
                switch freshness {
                case .doNotStore:
                    await cache.remove(key)
                case .store(let expires):
                    let entry = CacheEntry(
                        status: response.status, headers: response.headers, body: response.body, url: response.url,
                        etag: response.headers["ETag"], lastModified: response.headers["Last-Modified"],
                        expires: expires, storedAt: now, isPrivate: key.identity != .public)
                    await cache.store(entry, for: key)
                    log(.debug, .cache, "Stored response", request, key: key, entry: entry)
                }
            }
            log(.info, .http, "Response \(response.status)", request, key: key, headers: response.headers)
            let result = Response(
                value: response, source: .network, expires: freshness.expires,
                lastModified: response.headers["Last-Modified"].flatMap(HTTPDate.parse),
                etag: response.headers["ETag"], isStale: false)
            return finish(result, request, started, clock)

        default:
            if (500..<600).contains(response.status), let cached {
                let error = Self.httpError(response, url: request.url)
                return serveStale(cached, request, key: key, status: response.status, error: error, started, clock)
            }
            return try fail(Self.httpError(response, url: request.url), request, key: key)
        }
    }

    /// Headers a 304 must not overwrite in the stored entry (they describe the empty 304 body).
    private static let headersNotUpdatedBy304: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "content-range"]

    /// `entry` updated with the headers of a 304 (except those describing its empty body).
    private static func merging(_ response: HTTPResponse, into entry: CacheEntry, now: Date) -> CacheEntry {
        var headers = entry.headers
        for field in response.headers where !headersNotUpdatedBy304.contains(field.name.lowercased()) {
            headers[field.name] = field.value
        }
        var entry = entry
        entry.headers = headers
        entry.etag = headers["ETag"]
        entry.lastModified = headers["Last-Modified"]
        entry.expires = Freshness.evaluate(headers, now: now).expires
        entry.storedAt = now
        return entry
    }

    private static func response(from entry: CacheEntry, source: ResponseSource, isStale: Bool) -> Response<HTTPResponse> {
        // A revalidated entry is returned as the 200 it stands for.
        let value = HTTPResponse(status: entry.status, headers: entry.headers, body: entry.body, url: entry.url)
        return Response(
            value: value, source: source, expires: entry.expires,
            lastModified: entry.lastModified.flatMap(HTTPDate.parse), etag: entry.etag, isStale: isStale)
    }

    static func httpError(_ response: HTTPResponse, url: URL) -> CapsuleerError {
        let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text.isEmpty ? nil : String(text.prefix(maxErrorMessageLength))
        return CapsuleerError(response.status == 404 ? .notFound : .http, status: response.status, message: message, url: url)
    }

    static func map(_ error: any Error, url: URL) -> CapsuleerError {
        if let error = error as? CapsuleerError { return error }
        if error is CancellationError { return CapsuleerError(.cancelled, url: url, underlying: error) }
        if let error = error as? URLError {
            return CapsuleerError(error.code == .cancelled ? .cancelled : .transport, message: error.localizedDescription, url: url, underlying: error)
        }
        return CapsuleerError(.transport, message: String(describing: error), url: url, underlying: error)
    }

    // MARK: - Outcomes, events and logging

    private func finish(_ response: Response<HTTPResponse>, _ request: HTTPRequest, _ started: ContinuousClock.Instant, _ clock: ContinuousClock) -> Response<HTTPResponse> {
        emit(ClientEvent(kind: .requestFinished, url: request.url, status: response.value.status, source: response.source, duration: clock.now - started))
        return response
    }

    private func serveStale(_ entry: CacheEntry, _ request: HTTPRequest, key: CacheKey, status: Int?, error: CapsuleerError, _ started: ContinuousClock.Instant, _ clock: ContinuousClock) -> Response<HTTPResponse> {
        log(.info, .cache, "Serving stale entry after \(error.code)", request, key: key, entry: entry)
        emit(ClientEvent(kind: .servedStale, url: request.url, status: status, source: .cache, error: error))
        return finish(Self.response(from: entry, source: .cache, isStale: true), request, started, clock)
    }

    private func fail(_ error: CapsuleerError, _ request: HTTPRequest, key: CacheKey) throws -> Response<HTTPResponse> {
        log(.info, .http, "Request failed: \(error.code)", request, key: key, extra: error.status.map { ["status": String($0)] } ?? [:])
        emit(ClientEvent(kind: .requestFailed, url: request.url, status: error.status, error: error))
        throw error
    }

    private func emit(_ event: ClientEvent) {
        configuration.events?(event)
    }

    /// Logs method and URL plus, at most, the ETag / Cache-Control / Expires headers.
    /// Non-public identities, and the URL of non-public requests (authenticated ESI paths embed the
    /// character ID), go to private metadata. No other header values are ever logged.
    private func log(_ level: LogLevel, _ category: LogCategory, _ message: String, _ request: HTTPRequest, key: CacheKey,
                     entry: CacheEntry? = nil, headers: HTTPHeaders? = nil, extra: [String: String] = [:]) {
        var metadata = extra
        metadata["method"] = request.method.rawValue
        if let headers = headers ?? entry?.headers {
            for name in ["ETag", "Cache-Control", "Expires"] {
                if let value = headers[name] { metadata[name.lowercased()] = value }
            }
        }
        if let entry { metadata["status"] = metadata["status"] ?? String(entry.status) }
        var privateMetadata: [String: String] = [:]
        if key.identity == .public {
            metadata["url"] = request.url.absoluteString
        } else {
            privateMetadata["identity"] = key.identity.rawValue
            privateMetadata["url"] = request.url.absoluteString
        }
        configuration.logSink.log(level, category, message, metadata: metadata, privateMetadata: privateMetadata)
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
