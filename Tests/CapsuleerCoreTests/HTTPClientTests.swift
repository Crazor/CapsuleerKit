import Foundation
import os
import Testing
@testable import CapsuleerCore
import CapsuleerKitTesting

private let testURL = URL(string: "https://esi.example.com/latest/status/")!
private let userAgent = UserAgent(product: "Tests", version: "1.0", contact: "+https://example.com/tests")

/// Collects events emitted by the client.
private final class EventRecorder: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [ClientEvent]())
    func record(_ event: ClientEvent) { lock.withLock { $0.append(event) } }
    var events: [ClientEvent] { lock.withLock { $0 } }
    func kinds() -> [ClientEvent.Kind] { events.map(\.kind) }
}

/// Collects log calls, to check that header values and identities don't leak.
private final class LogRecorder: LogSink {
    struct Line: Sendable {
        var category: LogCategory
        var message: String
        var metadata: [String: String]
        var privateMetadata: [String: String]
    }
    private let lock = OSAllocatedUnfairLock(initialState: [Line]())
    func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        lock.withLock { $0.append(Line(category: category, message: message, metadata: metadata, privateMetadata: privateMetadata)) }
    }
    var lines: [Line] { lock.withLock { $0 } }
    /// Everything that is logged in the clear.
    var publicText: String { lines.map { "\($0.message) \($0.metadata)" }.joined(separator: "\n") }
}

/// A one-shot gate a mock handler can wait on.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private struct Harness {
    let transport = MockTransport()
    let cache = MemoryCacheStore()
    let time = ManualTimeSource()
    let recorder = EventRecorder()
    let logs = LogRecorder()
    let client: HTTPClient

    init(cache: Bool = true) {
        let recorder = recorder
        client = HTTPClient(configuration: .init(
            userAgent: userAgent, transport: transport, cache: cache ? self.cache : nil,
            logSink: logs, events: { recorder.record($0) }, timeSource: time))
    }

    func get(_ url: URL = testURL, identity: CacheIdentity = .public, variant: [String: String] = [:],
             policy: CachePolicy = .useProtocolCachePolicy) async throws -> Response<HTTPResponse> {
        try await client.send(HTTPRequest(url: url), identity: identity, variant: variant, policy: policy)
    }

    func ok(_ body: String = "{\"players\":1}", headers: HTTPHeaders = ["Cache-Control": "max-age=60", "ETag": "\"v1\""], url: URL = testURL) {
        transport.enqueue(status: 200, headers: headers, body: Data(body.utf8), url: url)
    }

    func key(_ url: URL = testURL, identity: CacheIdentity = .public, variant: [String: String] = [:]) -> CacheKey {
        CacheKey(method: .get, url: url, identity: identity, variant: variant)
    }
}

@discardableResult
private func expectError(_ code: CapsuleerError.Code, _ body: () async throws -> Void) async -> CapsuleerError? {
    do {
        try await body()
        Issue.record("expected \(code), got success")
        return nil
    } catch let error as CapsuleerError {
        #expect(error.code == code)
        return error
    } catch {
        Issue.record("expected CapsuleerError(\(code)), got \(error)")
        return nil
    }
}

@Suite struct HTTPClientTests {
    // MARK: Request building

    @Test func setsUserAgentAndVariantHeaders() async throws {
        let h = Harness()
        h.ok()
        var request = HTTPRequest(url: testURL, headers: ["User-Agent": "spoofed", "Accept": "application/json"])
        request.headers["X-Other"] = "1"
        _ = try await h.client.send(request, variant: ["Accept-Language": "de", "X-Compatibility-Date": "2025-01-01"])
        let sent = try #require(h.transport.requests.first)
        #expect(sent.headers["User-Agent"] == userAgent.headerValue)
        #expect(sent.headers.fields.filter { $0.name.lowercased() == "user-agent" }.count == 1)
        #expect(sent.headers["Accept-Language"] == "de")
        #expect(sent.headers["X-Compatibility-Date"] == "2025-01-01")
        #expect(sent.headers["Accept"] == "application/json")
    }

    @Test func variantSeparatesCacheEntries() async throws {
        let h = Harness()
        h.ok("en"); h.ok("de")
        let en = try await h.get(variant: ["Accept-Language": "en"])
        let de = try await h.get(variant: ["Accept-Language": "de"])
        #expect(String(decoding: en.value.body, as: UTF8.self) == "en")
        #expect(String(decoding: de.value.body, as: UTF8.self) == "de")
        #expect(h.transport.requests.count == 2)
        #expect(await h.cache.entry(for: h.key(variant: ["Accept-Language": "de"])) != nil)
    }

    // MARK: Freshness and revalidation

    @Test func freshHitDoesNotTouchNetwork() async throws {
        let h = Harness()
        h.ok(headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\"", "Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"])
        let first = try await h.get()
        #expect(first.source == .network)
        #expect(first.expires == h.time.now() + 60)
        #expect(first.etag == "\"v1\"")
        #expect(first.lastModified == Date(timeIntervalSince1970: 784_111_777))
        #expect(!first.isStale)

        h.time.advance(by: 30)
        let second = try await h.get()
        #expect(second.source == .cache)
        #expect(!second.isStale)
        #expect(second.value.body == first.value.body)
        #expect(second.value.status == 200)
        #expect(second.expires == first.expires)
        #expect(second.lastModified == first.lastModified)
        #expect(h.transport.requests.count == 1)
        #expect(h.recorder.events.map(\.source) == [.network, .cache])
    }

    @Test func staleEntryRevalidatesWith304() async throws {
        let h = Harness()
        h.ok("original", headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\"", "Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"])
        _ = try await h.get()
        h.time.advance(by: 61)

        h.transport.enqueue(status: 304, headers: ["Cache-Control": "max-age=120", "ETag": "\"v1\""], url: testURL)
        let revalidated = try await h.get()
        let conditional = h.transport.requests[1]
        #expect(conditional.headers["If-None-Match"] == "\"v1\"")
        #expect(conditional.headers["If-Modified-Since"] == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(revalidated.source == .revalidated)
        #expect(revalidated.value.status == 200)
        #expect(String(decoding: revalidated.value.body, as: UTF8.self) == "original")
        #expect(revalidated.expires == h.time.now() + 120)
        #expect(!revalidated.isStale)

        let stored = try #require(await h.cache.entry(for: h.key()))
        #expect(stored.expires == h.time.now() + 120)
        #expect(stored.headers["Cache-Control"] == "max-age=120")

        // The refreshed entry is served from cache again.
        h.time.advance(by: 100)
        #expect(try await h.get().source == .cache)
        #expect(h.transport.requests.count == 2)
    }

    @Test func revalidationWith200ReplacesEntry() async throws {
        let h = Harness()
        h.ok("v1", headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\""])
        _ = try await h.get()
        h.time.advance(by: 61)
        h.ok("v2", headers: ["Cache-Control": "max-age=60", "ETag": "\"v2\""])
        let response = try await h.get()
        #expect(response.source == .network)
        #expect(response.etag == "\"v2\"")
        #expect(await h.cache.entry(for: h.key())?.body == Data("v2".utf8))
    }

    @Test func noCacheEntryAlwaysRevalidates() async throws {
        let h = Harness()
        h.ok(headers: ["Cache-Control": "no-cache", "ETag": "\"v1\""])
        _ = try await h.get()
        h.transport.enqueue(status: 304, headers: [:], url: testURL)
        let second = try await h.get()
        #expect(second.source == .revalidated)
        #expect(second.expires == nil)
        #expect(h.transport.requests[1].headers["If-None-Match"] == "\"v1\"")
    }

    @Test func expiresHeaderDrivesFreshness() async throws {
        let h = Harness()
        let expires = h.time.now() + 300
        h.ok(headers: ["Expires": HTTPHeaders.httpDate(expires)])
        #expect(try await h.get().expires == expires)
        h.time.advance(by: 299)
        #expect(try await h.get().source == .cache)
        #expect(h.transport.requests.count == 1)
    }

    @Test func notModifiedWithoutEntryIsInvalid() async throws {
        let h = Harness()
        h.transport.enqueue(status: 304, url: testURL)
        await expectError(.invalidResponse) { _ = try await h.get() }
        #expect(h.recorder.kinds() == [.requestFailed])
    }

    // MARK: Policies

    @Test func returnCacheDataElseLoad() async throws {
        let h = Harness()
        h.ok()
        let loaded = try await h.get(policy: .returnCacheDataElseLoad)  // nothing cached: loads
        #expect(loaded.source == .network)

        let fresh = try await h.get(policy: .returnCacheDataElseLoad)
        #expect(fresh.source == .cache)
        #expect(!fresh.isStale)

        h.time.advance(by: 3600)
        let stale = try await h.get(policy: .returnCacheDataElseLoad)
        #expect(stale.source == .cache)
        #expect(stale.isStale)
        #expect(h.transport.requests.count == 1)
    }

    @Test func reloadRevalidatingCacheDataAlwaysAsks() async throws {
        let h = Harness()
        h.ok()
        _ = try await h.get()
        h.transport.enqueue(status: 304, headers: ["Cache-Control": "max-age=60"], url: testURL)
        let response = try await h.get(policy: .reloadRevalidatingCacheData)  // entry is still fresh
        #expect(response.source == .revalidated)
        #expect(h.transport.requests.count == 2)
        #expect(h.transport.requests[1].headers["If-None-Match"] == "\"v1\"")
    }

    @Test func reloadWithoutEntryIsUnconditional() async throws {
        let h = Harness()
        h.ok()
        _ = try await h.get(policy: .reloadRevalidatingCacheData)
        #expect(h.transport.requests[0].headers["If-None-Match"] == nil)
        #expect(h.transport.requests[0].headers["If-Modified-Since"] == nil)
    }

    // MARK: What gets stored

    @Test func postIsNeverCached() async throws {
        let h = Harness()
        h.ok("[1]"); h.ok("[2]")
        let post = HTTPRequest(method: .post, url: testURL, body: Data("[\"Jita\"]".utf8))
        let first = try await h.client.send(post)
        let second = try await h.client.send(post)
        #expect(first.source == .network)
        #expect(second.source == .network)
        #expect(h.transport.requests.count == 2)
        #expect(await h.cache.entry(for: CacheKey(method: .post, url: testURL, body: post.body)) == nil)
        #expect(await h.cache.byteCount == 0)
    }

    @Test func noStoreIsNotStored() async throws {
        let h = Harness()
        h.ok(headers: ["Cache-Control": "no-store", "ETag": "\"v1\""])
        h.ok(headers: ["Cache-Control": "no-store"])
        _ = try await h.get()
        #expect(await h.cache.entry(for: h.key()) == nil)
        _ = try await h.get()
        #expect(h.transport.requests.count == 2)
        #expect(h.transport.requests[1].headers["If-None-Match"] == nil)
    }

    @Test func responseWithoutFreshnessOrValidatorIsNotStored() async throws {
        let h = Harness()
        h.ok(headers: ["Content-Type": "application/json"])
        _ = try await h.get()
        #expect(await h.cache.entry(for: h.key()) == nil)
    }

    @Test func non200SuccessIsReturnedButNotStored() async throws {
        let h = Harness()
        h.transport.enqueue(status: 204, headers: ["Cache-Control": "max-age=60"], url: testURL)
        let response = try await h.get()
        #expect(response.value.status == 204)
        #expect(response.source == .network)
        #expect(await h.cache.entry(for: h.key()) == nil)
    }

    @Test func identitiesAreSeparate() async throws {
        let h = Harness()
        h.ok("public"); h.ok("private")
        let pub = try await h.get()
        let char = try await h.get(identity: .character(90_000_001))
        #expect(String(decoding: pub.value.body, as: UTF8.self) == "public")
        #expect(String(decoding: char.value.body, as: UTF8.self) == "private")
        #expect(h.transport.requests.count == 2)
        #expect(await h.cache.entry(for: h.key())?.isPrivate == false)
        #expect(await h.cache.entry(for: h.key(identity: .character(90_000_001)))?.isPrivate == true)

        // The character identity is never logged in plain metadata.
        #expect(!h.logs.publicText.contains("90000001"))
        #expect(h.logs.lines.contains { $0.privateMetadata["identity"] == "character:90000001" })
    }

    @Test func worksWithoutACache() async throws {
        let h = Harness(cache: false)
        h.ok(); h.ok()
        _ = try await h.get()
        #expect(try await h.get().source == .network)
        #expect(h.transport.requests.count == 2)
    }

    // MARK: Errors

    @Test func notFoundThrowsWithoutRetry() async throws {
        let h = Harness()
        h.transport.enqueue(status: 404, body: Data("  {\"error\":\"Type not found!\"}\n".utf8), url: testURL)
        h.ok()  // would be used by a retry
        let error = await expectError(.notFound) { _ = try await h.get() }
        #expect(error?.status == 404)
        #expect(error?.url == testURL)
        #expect(error?.message == "{\"error\":\"Type not found!\"}")
        #expect(h.transport.requests.count == 1)
        #expect(h.recorder.events.first?.error?.code == .notFound)
    }

    @Test func otherStatusThrowsHTTPWithTruncatedMessage() async throws {
        let h = Harness()
        h.transport.enqueue(status: 420, body: Data(String(repeating: "x", count: 2_000).utf8), url: testURL)
        let error = await expectError(.http) { _ = try await h.get() }
        #expect(error?.status == 420)
        #expect(error?.message?.count == 500)
        #expect(h.transport.requests.count == 1)
    }

    @Test func serverErrorWithoutEntryThrows() async throws {
        let h = Harness()
        h.transport.enqueue(status: 503, url: testURL)
        let error = await expectError(.http) { _ = try await h.get() }
        #expect(error?.status == 503)
        #expect(error?.message == nil)
        #expect(h.transport.requests.count == 1)
    }

    @Test func serverErrorServesStaleEntry() async throws {
        let h = Harness()
        h.ok("cached")
        _ = try await h.get()
        h.time.advance(by: 120)
        h.transport.enqueue(status: 500, body: Data("boom".utf8), url: testURL)
        let response = try await h.get()
        #expect(response.isStale)
        #expect(response.source == .cache)
        #expect(String(decoding: response.value.body, as: UTF8.self) == "cached")
        #expect(h.recorder.kinds() == [.requestFinished, .servedStale, .requestFinished])
        #expect(h.recorder.events[1].status == 500)
    }

    @Test func transportErrorServesStaleEntryEvenWhenFresh() async throws {
        let h = Harness()
        h.ok("cached")
        _ = try await h.get()
        h.transport.enqueue(error: CapsuleerError(.transport, message: "offline", url: testURL))
        let response = try await h.get(policy: .reloadRevalidatingCacheData)
        #expect(response.isStale)
        #expect(String(decoding: response.value.body, as: UTF8.self) == "cached")
        #expect(h.recorder.kinds().contains(.servedStale))
    }

    @Test func transportErrorWithoutEntryThrows() async throws {
        let h = Harness()
        h.transport.enqueue(error: CapsuleerError(.transport, message: "offline", url: testURL))
        await expectError(.transport) { _ = try await h.get() }
        #expect(h.recorder.kinds() == [.requestFailed])
    }

    @Test func nonCapsuleerTransportErrorsAreMapped() async throws {
        let h = Harness()
        h.transport.setHandler { _ in throw URLError(.notConnectedToInternet) }
        await expectError(.transport) { _ = try await h.get() }
        h.transport.setHandler { _ in throw URLError(.cancelled) }
        await expectError(.cancelled) { _ = try await h.get() }
        h.transport.setHandler { _ in throw CancellationError() }
        await expectError(.cancelled) { _ = try await h.get() }
    }

    @Test func cancellationDoesNotServeStale() async throws {
        let h = Harness()
        h.ok()
        _ = try await h.get()
        h.transport.setHandler { _ in throw CancellationError() }
        await expectError(.cancelled) { _ = try await h.get(policy: .reloadRevalidatingCacheData) }
    }

    // MARK: Events and logging

    @Test func requestFinishedEvent() async throws {
        let h = Harness()
        h.ok()
        _ = try await h.get()
        let event = try #require(h.recorder.events.first)
        #expect(event.kind == .requestFinished)
        #expect(event.url == testURL)
        #expect(event.status == 200)
        #expect(event.source == .network)
        #expect(event.duration != nil)
    }

    @Test func logsOnlyAllowedHeaderValues() async throws {
        let h = Harness()
        h.ok(headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\"", "Set-Cookie": "secret-cookie"])
        var request = HTTPRequest(url: testURL)
        request.headers["Authorization"] = "Bearer secret-token"
        _ = try await h.client.send(request)
        let all = h.logs.publicText
        #expect(!all.contains("secret-token"))
        #expect(!all.contains("secret-cookie"))
        #expect(!all.contains(userAgent.headerValue))
        #expect(all.contains("max-age=60"))
    }

    @Test func privateRequestURLIsNotLoggedInTheClear() async throws {
        let h = Harness()
        let url = URL(string: "https://esi.example.com/latest/characters/90000001/wallet/")!
        h.ok("1000", url: url)
        _ = try await h.get(url, identity: .character(90_000_001))
        #expect(!h.logs.publicText.contains("90000001"))
        #expect(h.logs.lines.allSatisfy { $0.metadata["url"] == nil })
        #expect(h.logs.lines.contains { $0.privateMetadata["url"] == url.absoluteString })

        // Public requests keep the URL in plain metadata.
        h.ok()
        _ = try await h.get()
        #expect(h.logs.lines.contains { $0.metadata["url"] == testURL.absoluteString && $0.privateMetadata["url"] == nil })
    }

    // MARK: Coalescing

    @Test func concurrentIdenticalRequestsShareOneNetworkRequest() async throws {
        let h = Harness()
        let gate = Gate()
        h.transport.setHandler { request in
            await gate.wait()
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60"], body: Data("shared".utf8), url: request.url)
        }
        async let a = h.get()
        async let b = h.get()
        try await waitUntil { h.client.inFlight.waiterCount == 2 }
        await gate.open()
        let (ra, rb) = try await (a, b)
        #expect(ra.value.body == Data("shared".utf8))
        #expect(rb.value.body == Data("shared".utf8))
        #expect(h.transport.requests.count == 1)
        #expect(h.client.inFlight.waiterCount == 0)
    }

    @Test func differentPoliciesShareOneNetworkFlight() async throws {
        let h = Harness()
        h.ok("v1", headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\""])
        _ = try await h.get()
        h.time.advance(by: 61)  // stale: both callers below need the network

        let gate = Gate()
        h.transport.setHandler { request in
            await gate.wait()
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60", "ETag": "\"v2\""], body: Data("v2".utf8), url: request.url)
        }
        async let a = h.get()
        async let b = h.get(policy: .reloadRevalidatingCacheData)
        try await waitUntil { h.client.inFlight.waiterCount == 2 }
        await gate.open()
        let (ra, rb) = try await (a, b)
        #expect(ra.value.body == Data("v2".utf8))
        #expect(rb.value.body == Data("v2".utf8))
        #expect(h.transport.requests.count == 2)  // the initial load plus one shared revalidation
        #expect(await h.cache.entry(for: h.key())?.etag == "\"v2\"")
    }

    @Test func cacheAnswerableCallersDoNotJoinARunningFlight() async throws {
        let h = Harness()
        h.ok()
        _ = try await h.get()  // fresh entry

        let gate = Gate()
        h.transport.setHandler { request in
            await gate.wait()
            return HTTPResponse(status: 304, headers: ["Cache-Control": "max-age=60"], url: request.url)
        }
        let reload = Task { try await h.get(policy: .reloadRevalidatingCacheData) }
        try await waitUntil { h.client.inFlight.waiterCount == 1 }

        // While the reload is out, a fresh hit and a returnCacheDataElseLoad caller are answered
        // from the cache at once, without the network.
        #expect(try await h.get().source == .cache)
        h.time.advance(by: 3600)
        let stale = try await h.get(policy: .returnCacheDataElseLoad)
        #expect(stale.source == .cache)
        #expect(stale.isStale)
        #expect(h.client.inFlight.waiterCount == 1)
        #expect(h.transport.requests.count == 2)

        await gate.open()
        #expect(try await reload.value.source == .revalidated)
    }

    @Test func notModifiedDoesNotOverwriteANewerEntry() async throws {
        let h = Harness()
        h.ok("old", headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\""])
        _ = try await h.get()
        h.time.advance(by: 61)

        // While the conditional request for v1 is out, someone else stores v2 (e.g. another
        // client sharing the cache); the late 304 for v1 must not put the old body back.
        let newer = CacheEntry(
            status: 200, headers: ["Cache-Control": "max-age=60", "ETag": "\"v2\""], body: Data("new".utf8), url: testURL,
            etag: "\"v2\"", lastModified: nil, expires: h.time.now() + 60, storedAt: h.time.now(), isPrivate: false)
        let cache = h.cache, key = h.key()
        h.transport.setHandler { request in
            await cache.store(newer, for: key)
            return HTTPResponse(status: 304, headers: ["Cache-Control": "max-age=600", "ETag": "\"v1\""], url: request.url)
        }
        let response = try await h.get()
        #expect(h.transport.requests[1].headers["If-None-Match"] == "\"v1\"")
        #expect(response.value.body == Data("new".utf8))
        #expect(response.etag == "\"v2\"")
        #expect(await h.cache.entry(for: h.key()) == newer)
    }

    @Test func notModifiedDoesNotRestoreARemovedEntry() async throws {
        let h = Harness()
        let identity = CacheIdentity.character(90_000_001)
        h.ok("old", headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\""])
        _ = try await h.get(identity: identity)
        h.time.advance(by: 61)

        let cache = h.cache
        h.transport.setHandler { request in
            await cache.removeAll(identity: identity)  // logout while the request is out
            return HTTPResponse(status: 304, headers: ["Cache-Control": "max-age=60", "ETag": "\"v1\""], url: request.url)
        }
        let response = try await h.get(identity: identity)
        #expect(response.source == .revalidated)
        #expect(response.value.body == Data("old".utf8))
        #expect(await h.cache.entry(for: h.key(identity: identity)) == nil)
    }

    @Test func cancellingOneCallerDoesNotCancelSharedRequest() async throws {
        let h = Harness()
        let gate = Gate()
        h.transport.setHandler { request in
            await gate.wait()
            try Task.checkCancellation()
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60"], body: Data("shared".utf8), url: request.url)
        }
        let first = Task { try await h.get() }
        let second = Task { try await h.get() }
        try await waitUntil { h.client.inFlight.waiterCount == 2 }

        first.cancel()
        await expectError(.cancelled) { _ = try await first.value }
        #expect(h.client.inFlight.waiterCount == 1)

        await gate.open()
        let response = try await second.value
        #expect(response.value.body == Data("shared".utf8))
        #expect(h.transport.requests.count == 1)
        #expect(await h.cache.entry(for: h.key()) != nil)  // the shared request completed and stored
    }

    @Test func cancellingTheLastCallerCancelsTheSharedRequest() async throws {
        let h = Harness()
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        h.transport.setHandler { request in
            do {
                try await Task.sleep(for: .seconds(3600))  // e.g. an etiquette wait before sending
            } catch {
                sawCancellation.withLock { $0 = true }
                throw error
            }
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60"], body: Data("unwanted".utf8), url: request.url)
        }
        let first = Task { try await h.get() }
        try await waitUntil { h.client.inFlight.waiterCount == 1 && h.transport.requests.count == 1 }

        first.cancel()
        await expectError(.cancelled) { _ = try await first.value }
        try await waitUntil { sawCancellation.withLock { $0 } }
        #expect(h.client.inFlight.flightCount == 0)

        h.ok("fresh")
        let response = try await h.get()
        #expect(response.value.body == Data("fresh".utf8))
        #expect(h.transport.requests.count == 2)
    }

    @Test func callerAfterAnAbandonedFlightStartsANewOne() async throws {
        let h = Harness()
        let oldGate = Gate(), newGate = Gate()
        h.transport.setHandler { request in
            await oldGate.wait()  // ignores cancellation, so the abandoned task outlives its waiter
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60"], body: Data("old".utf8), url: request.url)
        }
        let first = Task { try await h.get() }
        try await waitUntil { h.client.inFlight.waiterCount == 1 && h.transport.requests.count == 1 }
        first.cancel()
        await expectError(.cancelled) { _ = try await first.value }
        #expect(h.client.inFlight.flightCount == 0)

        h.transport.setHandler { request in
            await newGate.wait()
            return HTTPResponse(status: 200, headers: ["Cache-Control": "max-age=60"], body: Data("new".utf8), url: request.url)
        }
        let second = Task { try await h.get(policy: .reloadRevalidatingCacheData) }
        try await waitUntil { h.client.inFlight.waiterCount == 1 && h.transport.requests.count == 2 }

        // The abandoned flight finishing must not resume the new flight's waiter.
        await oldGate.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.client.inFlight.waiterCount == 1)

        await newGate.open()
        #expect(try await second.value.value.body == Data("new".utf8))
        #expect(h.client.inFlight.flightCount == 0)
    }

    @Test func alreadyCancelledCallerThrowsCancelled() async throws {
        let h = Harness()
        h.ok()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.get()
        }
        await expectError(.cancelled) { _ = try await task.value }
        #expect(h.transport.requests.isEmpty)
    }
}

/// Polls `condition` (yielding in between) until it holds, failing after ~5 s.
private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
