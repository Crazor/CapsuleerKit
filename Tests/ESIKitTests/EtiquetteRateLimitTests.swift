import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

@Suite struct EtiquetteRateLimitTests {
    // MARK: Parsing

    @Test func windowsParse() {
        #expect(RateLimitWindow("1200/15m") == RateLimitWindow(capacity: 1200, window: 900))
        #expect(RateLimitWindow("150/15m") == RateLimitWindow(capacity: 150, window: 900))
        #expect(RateLimitWindow("10/30s") == RateLimitWindow(capacity: 10, window: 30))
        #expect(RateLimitWindow("600/1h") == RateLimitWindow(capacity: 600, window: 3600))
        #expect(RateLimitWindow("5/20") == RateLimitWindow(capacity: 5, window: 20))
        #expect(RateLimitWindow("x/15m") == nil)
        #expect(RateLimitWindow("150") == nil)
        #expect(RateLimitWindow("150/0m") == nil)
    }

    // MARK: Seeding and correction

    @Test func bucketIsSeededFromTheHint() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200)
        _ = try await h.transport.send(EtiquetteHarness.request(group: "g", window: "1200/15m"))
        let bucket = try #require(await h.transport.rateLimiter.bucket(RateLimitKey(group: "g", identity: "public")))
        #expect(bucket.capacity == 1200)
        #expect(bucket.window == 900)
        #expect(await h.remaining(group: "g") == 1198)
    }

    @Test func responseHeadersCorrectTheEstimate() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200, ["X-Ratelimit-Group": "g", "X-Ratelimit-Limit": "150/15m", "X-Ratelimit-Remaining": "100", "X-Ratelimit-Used": "50"])
        _ = try await h.transport.send(EtiquetteHarness.request(group: "g", window: "1200/15m"))
        let bucket = try #require(await h.transport.rateLimiter.bucket(RateLimitKey(group: "g", identity: "public")))
        #expect(bucket.capacity == 150)
        #expect(bucket.window == 900)
        #expect(await h.remaining(group: "g") == 100)

        // Headers keep winning over the spec hint; Remaining alone also corrects.
        h.enqueue(200, ["X-Ratelimit-Group": "g", "X-Ratelimit-Remaining": "140"])
        _ = try await h.transport.send(EtiquetteHarness.request(group: "g", window: "1200/15m"))
        #expect(await h.remaining(group: "g") == 140)
        #expect(await h.transport.rateLimiter.bucket(RateLimitKey(group: "g", identity: "public"))?.capacity == 150)

        // Used wins over the estimate when it is higher, too.
        h.enqueue(200, ["X-Ratelimit-Group": "g", "X-Ratelimit-Used": "120"])
        _ = try await h.transport.send(EtiquetteHarness.request(group: "g", window: "1200/15m"))
        #expect(await h.remaining(group: "g") == 30)
    }

    @Test func costsPerStatusClass() async throws {
        let h = EtiquetteHarness()
        let request = EtiquetteHarness.request(group: "g", window: "1000/15m")
        var expected = 1000
        for (status, cost) in [(200, 2), (204, 2), (304, 1), (404, 5), (429, 5), (500, 0), (503, 0)] {
            h.enqueue(status)
            _ = try await h.transport.send(request)
            expected -= cost
            #expect(await h.remaining(group: "g") == expected, "status \(status)")
        }
    }

    @Test func transportErrorsCostNothing() async throws {
        let h = EtiquetteHarness()
        h.mock.enqueue(error: CapsuleerError(.transport))
        _ = try? await h.transport.send(EtiquetteHarness.request(group: "g", window: "100/1m"))
        #expect(await h.remaining(group: "g") == 100)
    }

    @Test func tokensAgeOutAfterTheWindow() async throws {
        let h = EtiquetteHarness()
        h.enqueue(200, [:], times: 2)
        let request = EtiquetteHarness.request(group: "g", window: "100/1m")
        _ = try await h.transport.send(request)
        h.clock.advance(by: 30)
        _ = try await h.transport.send(request)
        #expect(await h.remaining(group: "g") == 96)
        h.clock.advance(by: 30)
        #expect(await h.remaining(group: "g") == 98)
        h.clock.advance(by: 30)
        #expect(await h.remaining(group: "g") == 100)
    }

    // MARK: Spacing

    /// Capacity 20, reserve 10 % (2 tokens): a request goes out while used + 5 ≤ 18, i.e. used ≤ 13.
    /// Seven 200s (14 tokens) fill it; the eighth waits until the first ages out.
    @Test func requestsAreSpacedWhenTheReserveIsReached() async throws {
        let h = EtiquetteHarness()
        let request = EtiquetteHarness.request(group: "g", window: "20/1m")
        h.enqueue(200, [:], times: 9)
        for _ in 0..<7 {
            _ = try await h.transport.send(request)
            h.clock.advance(by: 1)
        }
        #expect(h.clock.sleeps.isEmpty)

        _ = try await h.transport.send(request)  // now = t0 + 7; first spend ages out at t0 + 60
        #expect(h.clock.sleeps == [.seconds(53)])
        #expect(h.recorder.kinds(.rateLimitWait).map(\.detail) == ["g"])
        #expect(h.recorder.kinds(.rateLimitWait).map(\.duration) == [.seconds(53)])

        _ = try await h.transport.send(request)  // t0 + 60: the second spend (t0 + 1) ages out a second later
        #expect(h.clock.sleeps == [.seconds(53), .seconds(1)])
        #expect(h.mock.requests.count == 9)
    }

    @Test func rateLimitWaitLongerThanMaxWaitThrowsWithoutSending() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(10))
        let request = EtiquetteHarness.request(group: "g", window: "20/1m")
        h.enqueue(200, [:], times: 8)
        for _ in 0..<7 { _ = try await h.transport.send(request) }

        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(request) }
        #expect(error?.code == .rateLimited)
        #expect(error?.retryAfter == .seconds(60))
        #expect(h.mock.requests.count == 7)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func headerRemainingAtZeroBlocksUntilTheWindowPasses() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(30))
        h.enqueue(200, ["X-Ratelimit-Group": "g", "X-Ratelimit-Limit": "150/15m", "X-Ratelimit-Remaining": "0"])
        let request = EtiquetteHarness.request(group: "g", window: "150/15m")
        _ = try await h.transport.send(request)
        let error = await #expect(throws: CapsuleerError.self) { try await h.transport.send(request) }
        #expect(error?.code == .rateLimited)
        #expect(error?.retryAfter == .seconds(900))
        #expect(h.mock.requests.count == 1)
    }

    // MARK: Buckets

    @Test func bucketsAreSeparatePerIdentityAndGroup() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(10))
        h.enqueue(200, [:], times: 9)
        for _ in 0..<7 { _ = try await h.transport.send(EtiquetteHarness.request(group: "a", window: "20/1m")) }
        // "a"/public is at its reserve now.
        _ = try await h.transport.send(EtiquetteHarness.request(group: "a", window: "20/1m", identity: "character:1"))
        _ = try await h.transport.send(EtiquetteHarness.request(group: "b", window: "20/1m"))
        #expect(h.clock.sleeps.isEmpty)
        #expect(await h.remaining(group: "a") == 6)
        #expect(await h.remaining(group: "a", identity: "character:1") == 18)
        #expect(await h.remaining(group: "b") == 18)
        await #expect(throws: CapsuleerError.self) { try await h.transport.send(EtiquetteHarness.request(group: "a", window: "20/1m")) }
    }

    @Test func requestsWithoutAGroupBypassTheLimiter() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(1))
        h.enqueue(200, [:], times: 30)
        for _ in 0..<30 { _ = try await h.transport.send(EtiquetteHarness.request(window: "20/1m")) }
        #expect(h.clock.sleeps.isEmpty)
        #expect(h.mock.requests.count == 30)
    }

    @Test func theGroupIsLearnedFromResponseHeadersWithoutAHint() async throws {
        let h = EtiquetteHarness(maxWait: .seconds(10))
        h.enqueue(200, ["X-Ratelimit-Group": "learned", "X-Ratelimit-Limit": "150/15m", "X-Ratelimit-Remaining": "3"])
        h.enqueue(200)
        _ = try await h.transport.send(EtiquetteHarness.request())
        #expect(await h.remaining(group: "learned") == 3)

        // Requests without a hint still go straight through …
        _ = try await h.transport.send(EtiquetteHarness.request())
        // … but hinted requests for that group see the learned state.
        let error = await #expect(throws: CapsuleerError.self) {
            try await h.transport.send(EtiquetteHarness.request(group: "learned", window: "150/15m"))
        }
        #expect(error?.code == .rateLimited)
        #expect(h.mock.requests.count == 2)
    }

    @Test func concurrentRequestsReserveTheWorstCase() async throws {
        // Capacity 20: only three in-flight reservations (15 tokens) fit above the reserve
        // without settling; the rest must wait rather than burst.
        let limiter = RateLimiter(reserve: 0.1)
        let key = RateLimitKey(group: "g", identity: "public")
        let now = Date(timeIntervalSince1970: 0)
        var granted = 0
        for _ in 0..<5 {
            if case .granted = await limiter.reserve(key, seed: RateLimitWindow(capacity: 20, window: 60), now: now) { granted += 1 }
        }
        #expect(granted == 3)
    }
}
