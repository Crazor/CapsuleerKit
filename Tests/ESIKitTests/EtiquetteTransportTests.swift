import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

/// Collects `ClientEvent`s.
/// `@unchecked Sendable`: the only state is `stored`, always accessed under `lock`
/// (`Mutex` needs macOS 15; the package targets macOS 13).
final class EtiquetteEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClientEvent] = []

    var events: [ClientEvent] { lock.withLock { stored } }
    func kinds(_ kind: ClientEvent.Kind) -> [ClientEvent] { events.filter { $0.kind == kind } }
    func record(_ event: ClientEvent) { lock.withLock { stored.append(event) } }
}

/// A time source whose sleeps last (really) an hour, so a test can cancel a request mid-wait.
/// `@unchecked Sendable`: `sleeping` is only touched under `lock`.
final class EtiquetteHangingTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var sleeping = 0
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    var sleepCount: Int { lock.withLock { sleeping } }
    func now() -> Date { fixedNow }
    func sleep(for duration: Duration) async throws {
        lock.withLock { sleeping += 1 }
        try await Task.sleep(for: .seconds(3600))
    }
}

struct EtiquetteHarness {
    static let url = URL(string: "https://esi.evetech.net/characters/2112345678/location")!

    let mock = MockTransport()
    let clock = ManualTimeSource()
    let recorder = EtiquetteEventRecorder()
    let transport: ESIEtiquetteTransport

    init(maxWait: Duration = .seconds(60), errorLimitFloor: Int = 10, reserve: Double = 0.1, maxRetries: Int = 2,
         timeSource: (any TimeSource)? = nil) {
        let recorder = recorder
        let configuration = ESIEtiquetteTransport.Configuration(
            compatibilityDate: "2099-01-02", timeSource: timeSource ?? clock,
            events: { recorder.record($0) }, maxRetries: maxRetries, errorLimitFloor: errorLimitFloor,
            rateLimitReserve: reserve, maxWait: maxWait)
        transport = ESIEtiquetteTransport(base: mock, configuration: configuration, jitter: { 1 })
    }

    static func request(group: String? = nil, window: String? = nil, identity: String? = nil, idempotent: Bool = false,
                        extra: HTTPHeaders = [:]) -> HTTPRequest {
        var headers = extra
        if let group { headers[ESIRequestHints.rateLimitGroup] = group }
        if let window { headers[ESIRequestHints.rateLimitWindow] = window }
        if let identity { headers[ESIRequestHints.identity] = identity }
        if idempotent { headers[ESIRequestHints.idempotent] = "1" }
        return HTTPRequest(url: url, headers: headers)
    }

    func enqueue(_ status: Int, _ headers: HTTPHeaders = [:], times: Int = 1) {
        for _ in 0..<times { mock.enqueue(status: status, headers: headers, url: Self.url) }
    }

    func remaining(group: String, identity: String = "public") async -> Int? {
        await transport.rateLimiter.remaining(RateLimitKey(group: group, identity: identity), now: clock.now())
    }
}

// MARK: - Tests

private func code(_ error: (any Error)?) -> CapsuleerError.Code? { (error as? CapsuleerError)?.code }

@Suite struct EtiquetteTransportTests {
    // MARK: Headers

    @Test func hintHeadersAreStrippedAndCompatibilityDateIsSet() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200)
        let request = EtiquetteHarness.request(group: "char-location", window: "1200/15m", identity: "character:1", idempotent: true,
                                               extra: ["Authorization": "Bearer secret", "Accept": "application/json"])
        _ = try await h.transport.send(request)

        let sent = try #require(h.mock.requests.first)
        #expect(sent.headers.allSatisfy { !$0.name.lowercased().hasPrefix("x-capsuleerkit-") })
        #expect(sent.headers["X-Compatibility-Date"] == "2099-01-02")
        #expect(sent.headers["Authorization"] == "Bearer secret")
        #expect(sent.headers["Accept"] == "application/json")
    }

    // MARK: Error budget

    @Test func errorBudgetAtTheFloorMakesRequestsWaitUntilReset() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200, ["X-Esi-Error-Limit-Remain": "10", "X-Esi-Error-Limit-Reset": "30"])
        h.enqueue(200, ["X-Esi-Error-Limit-Remain": "100", "X-Esi-Error-Limit-Reset": "60"])
        _ = try await h.transport.send(EtiquetteHarness.request())
        #expect(h.clock.sleeps.isEmpty)

        let response = try await h.transport.send(EtiquetteHarness.request())
        #expect(response.status == 200)
        #expect(h.clock.sleeps == [.seconds(30)])
        #expect(h.recorder.kinds(.errorBudgetLow).map(\.duration) == [.seconds(30)])
        #expect(h.mock.requests.count == 2)
    }

    @Test func budgetAboveTheFloorDoesNotWait() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200, ["X-Esi-Error-Limit-Remain": "11", "X-Esi-Error-Limit-Reset": "30"], times: 2)
        _ = try await h.transport.send(EtiquetteHarness.request())
        _ = try await h.transport.send(EtiquetteHarness.request())
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func a420IsReturnedOnceAndPausesLaterRequestsUntilReset() async throws {
        let h = EtiquetteHarness()
        h.enqueue(420, ["X-Esi-Error-Limit-Remain": "50", "X-Esi-Error-Limit-Reset": "45"])
        h.enqueue(200)
        let first = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(first.status == 420)
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)

        _ = try await h.transport.send(EtiquetteHarness.request())
        #expect(h.clock.sleeps == [.seconds(45)])
        #expect(h.mock.requests.count == 2)
    }

    @Test func errorBudgetWaitLongerThanMaxWaitThrowsErrorLimited() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(10))
        h.enqueue(200, ["X-Esi-Error-Limit-Remain": "5", "X-Esi-Error-Limit-Reset": "30"])
        _ = try await h.transport.send(EtiquetteHarness.request())

        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request()) }
        #expect(error?.code == .errorLimited)
        #expect(error?.retryAfter == .seconds(30))
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    // MARK: Retry-After

    @Test func a429WithRetryAfterWaitsAndRetriesOnce() async throws {
        let h = EtiquetteHarness()
        h.enqueue(429, ["Retry-After": "5"])
        h.enqueue(200)
        let response = try await h.transport.send(EtiquetteHarness.request())
        #expect(response.status == 200)
        #expect(h.clock.sleeps == [.seconds(5)])
        #expect(h.mock.requests.count == 2)
        #expect(h.recorder.kinds(.retried).map(\.status) == [429])
    }

    @Test func aSecond429ThrowsRateLimited() async throws {
        let h = EtiquetteHarness()
        h.enqueue(429, ["Retry-After": "5"], times: 2)
        h.enqueue(200)
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request()) }
        #expect(error?.code == .rateLimited)
        #expect(error?.retryAfter == .seconds(5))
        #expect(h.mock.requests.count == 2)
    }

    @Test func a429RetryAfterLongerThanMaxWaitThrowsWithoutRetry() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(60))
        h.enqueue(429, ["Retry-After": "120"])
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request()) }
        #expect(error?.code == .rateLimited)
        #expect(error?.retryAfter == .seconds(120))
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func a503WithAnHTTPDateRetryAfterWaitsAndRetriesOnceWhenIdempotent() async throws {
        let h = EtiquetteHarness()
        h.enqueue(503, ["Retry-After": HTTPHeaders.httpDate(h.clock.now().addingTimeInterval(20))])
        h.enqueue(503, ["Retry-After": "1"])
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == 503)
        #expect(h.clock.sleeps == [.seconds(20)])
        #expect(h.mock.requests.count == 2)
    }

    @Test func a503WithRetryAfterIsReturnedUnchangedWhenNotIdempotent() async throws {
        let h = EtiquetteHarness()
        h.enqueue(503, ["Retry-After": "5"])
        h.enqueue(200)
        let response = try await h.transport.send(EtiquetteHarness.request())
        #expect(response.status == 503)
        #expect(response.headers["Retry-After"] == "5")
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
        #expect(h.recorder.kinds(.retried).isEmpty)
    }

    @Test func a503RetryAfterLongerThanMaxWaitReturnsTheResponse() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(10))
        h.enqueue(503, ["Retry-After": "30"])
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == 503)
        #expect(h.mock.requests.count == 1)
    }

    // MARK: No blind 4XX retries

    @Test(arguments: [400, 401, 403, 404, 420, 422, 429])
    func clientErrorsAreNeverRetried(status: Int) async throws {
        let h = EtiquetteHarness()
        h.enqueue(status, [:], times: 3)
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == status)
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
        #expect(h.recorder.kinds(.retried).isEmpty)
    }

    // MARK: 5XX and transport errors

    @Test(arguments: [500, 502, 503, 504])
    func serverErrorsAreRetriedTwiceWithBackoffWhenIdempotent(status: Int) async throws {
        let h = EtiquetteHarness()
        h.enqueue(status, [:], times: 4)
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == status)
        #expect(h.mock.requests.count == 3)
        #expect(h.clock.sleeps == [.seconds(1), .seconds(3)])
        #expect(h.recorder.kinds(.retried).map(\.status) == [status, status])
    }

    @Test func aRetriedServerErrorCanSucceed() async throws {
        let h = EtiquetteHarness()
        h.enqueue(502)
        h.enqueue(200)
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == 200)
        #expect(h.mock.requests.count == 2)
    }

    @Test func serverErrorsAreNotRetriedWhenNotIdempotent() async throws {
        let h = EtiquetteHarness()
        h.enqueue(502, [:], times: 3)
        let response = try await h.transport.send(EtiquetteHarness.request())
        #expect(response.status == 502)
        #expect(h.mock.requests.count == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func maxRetriesIsHonoured() async throws {
        let h = EtiquetteHarness(maxRetries: 0)
        h.enqueue(502, [:], times: 3)
        _ = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(h.mock.requests.count == 1)
    }

    @Test func transportErrorsAreRetriedWhenIdempotent() async throws {
        let h = EtiquetteHarness()
        h.mock.enqueue(error: CapsuleerError(.transport, message: "offline"))
        h.enqueue(200)
        let response = try await h.transport.send(EtiquetteHarness.request(idempotent: true))
        #expect(response.status == 200)
        #expect(h.mock.requests.count == 2)
        #expect(h.clock.sleeps == [.seconds(1)])
        #expect(h.recorder.kinds(.retried).count == 1)
    }

    @Test func transportErrorsAreRethrownWhenNotIdempotent() async throws {
        let h = EtiquetteHarness()
        h.mock.enqueue(error: CapsuleerError(.transport, message: "offline"))
        h.enqueue(200)
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request()) }
        #expect(error?.code == .transport)
        #expect(h.mock.requests.count == 1)
    }

    @Test func persistentTransportErrorsGiveUpAfterMaxRetries() async throws {
        let h = EtiquetteHarness()
        for _ in 0..<4 { h.mock.enqueue(error: CapsuleerError(.transport, message: "offline")) }
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request(idempotent: true)) }
        #expect(error?.code == .transport)
        #expect(h.mock.requests.count == 3)
    }

    // MARK: Cancellation

    @Test func cancelledTransportIsNotRetried() async throws {
        let h = EtiquetteHarness()
        h.mock.enqueue(error: CapsuleerError(.cancelled))
        h.enqueue(200)
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request(idempotent: true)) }
        #expect(error?.code == .cancelled)
        #expect(h.mock.requests.count == 1)
    }

    @Test func cancellingDuringAWaitEndsWithCancelled() async throws {
        let time = EtiquetteHangingTimeSource()
        let h = EtiquetteHarness(maxWait: .seconds(7200), timeSource: time)
        h.enqueue(502)
        h.enqueue(200)
        let transport = h.transport
        let task = Task { try await transport.send(EtiquetteHarness.request(idempotent: true)) }
        while time.sleepCount == 0 { await Task.yield() }
        task.cancel()

        let result = await task.result
        #expect(code(result.error) == .cancelled)
        #expect(h.mock.requests.count == 1)
    }

    @Test func cancellingDuringAnErrorBudgetWaitEndsWithCancelled() async throws {
        let time = EtiquetteHangingTimeSource()
        let h = EtiquetteHarness(maxWait: .seconds(7200), timeSource: time)
        h.enqueue(420, ["X-Esi-Error-Limit-Reset": "60"])
        h.enqueue(200)
        _ = try await h.transport.send(EtiquetteHarness.request())
        let transport = h.transport
        let task = Task { try await transport.send(EtiquetteHarness.request()) }
        while time.sleepCount == 0 { await Task.yield() }
        task.cancel()

        #expect(code(await task.result.error) == .cancelled)
        #expect(h.mock.requests.count == 1)
    }
}

extension Result {
    fileprivate var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
