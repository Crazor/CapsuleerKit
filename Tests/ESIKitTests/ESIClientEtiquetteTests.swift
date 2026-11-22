import CapsuleerCore
import CapsuleerKitTesting
import Foundation
import os
import Testing
@testable import ESIKit

/// `ESIClient` with the real `ESIEtiquetteTransport` between `HTTPClient` and the mock.
@Suite struct ESIClientEtiquetteTests {
    @Test func hintsAreStrippedAndRequiredHeadersReachTheNetwork() async throws {
        let h = ESIClientHarness(etiquette: true)
        try h.route(["/characters/3/location": "character-location-space", "/characters/2112625428": "characters-2112625428"])
        let location = try await h.client.character(3).location().value
        #expect(location.solarSystemID == 30002187)
        _ = try await h.client.character(2112625428).publicInfo()

        for request in h.transport.requests {
            #expect(request.headers["X-Compatibility-Date"] == ESI.compatibilityDate)
            #expect(request.headers["User-Agent"] == ESIClientHarness.userAgent.headerValue)
            #expect(!request.headers.contains { $0.name.lowercased().hasPrefix("x-capsuleerkit-") })
        }
        #expect(h.transport.requests.first?.headers["Authorization"] == "Bearer token-3-0")
    }

    @Test func cacheHitsNeverReachTheTransport() async throws {
        let h = ESIClientHarness(etiquette: true)
        try h.route(["/characters/3/ship": "character-ship"])
        _ = try await h.client.character(3).ship()
        let second = try await h.client.character(3).ship()
        #expect(second.source == .cache)
        #expect(h.transport.requests.count == 1)
    }

    @Test func unauthorizedIsRetriedOnceByTheClientNotTheTransport() async throws {
        let h = ESIClientHarness(etiquette: true)
        let url = URL(string: "https://esi.evetech.net/characters/9/online")!
        h.transport.enqueue(status: 401, url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("character-online"), url: url)
        let online = try await h.client.character(9).online().value
        #expect(online.isOnline)
        #expect(h.transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-9-0", "Bearer token-9-1"])
    }

    @Test func forbiddenStructureIsNotRetried() async throws {
        let h = ESIClientHarness(etiquette: true)
        h.transport.enqueue(status: 403, headers: ["Content-Type": "application/json"], body: try esiFixture("error-forbidden"),
                            url: URL(string: "https://esi.evetech.net/universe/structures/1")!)
        let error = await capsuleerCode { _ = try await h.client.universe.structure(1, as: 42) }
        #expect(error?.status == 403)
        #expect(h.transport.requests.count == 1)
    }

    @Test func lookupPOSTsAreRetriedAfterServerErrors() async throws {
        let h = ESIClientHarness(etiquette: true)
        let url = URL(string: "https://esi.evetech.net/universe/names")!
        h.transport.enqueue(status: 502, url: url)
        h.transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("universe-names"), url: url)
        let names = try await h.client.universe.names([30000142, 60003760])
        #expect(names.map(\.id) == [30000142, 60003760])
        #expect(h.transport.requests.count == 2)
    }

    @Test func cancellingTheOnlyCallerDuringARetryAfterWaitSendsNothingLater() async throws {
        let time = CancellationRecordingTimeSource()
        let transport = MockTransport()
        let client = ESIClient(configuration: ESIConfiguration(
            userAgent: ESIClientHarness.userAgent, transport: transport, timeSource: time), wrapTransport: true)
        let url = URL(string: "https://esi.evetech.net/characters/2112625428")!
        transport.enqueue(status: 503, headers: ["Retry-After": "30"], url: url)
        transport.enqueue(status: 200, headers: ["Content-Type": "application/json"], body: try esiFixture("characters-2112625428"), url: url)

        let task = Task { try await client.character(2112625428).publicInfo() }
        while time.counts.sleeps == 0 { await Task.yield() }
        task.cancel()
        #expect(await capsuleerCode { _ = try await task.value }?.code == .cancelled)

        // The coalesced flight was cancelled too: its Retry-After wait ends instead of running out.
        let deadline = ContinuousClock.now + .seconds(5)
        while time.counts.cancelled == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(time.counts.cancelled == 1)
        #expect(transport.requests.count == 1)
    }

    @Test func namesBatchesThroughTheTransport() async throws {
        let h = ESIClientHarness(etiquette: true)
        ESIClientUniverseTests.echoNames(h.transport)
        let names = try await h.client.universe.names((1...2500).map { Int64($0) })
        #expect(names.count == 2500)
        #expect(h.transport.requests.count == 3)
    }
}

/// A time source whose sleeps last (really) an hour and that counts sleeps and cancelled sleeps.
private final class CancellationRecordingTimeSource: TimeSource {
    private let state = OSAllocatedUnfairLock(initialState: (sleeps: 0, cancelled: 0))
    let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    var counts: (sleeps: Int, cancelled: Int) { state.withLock { $0 } }
    func now() -> Date { fixedNow }
    func sleep(for duration: Duration) async throws {
        state.withLock { $0.sleeps += 1 }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
    }
}
