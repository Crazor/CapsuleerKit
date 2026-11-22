import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import SDEKit

@Suite struct SyncBackoffTests {
    // MARK: Failure backoff

    @Test func aFailedReleaseCheckIsNotRetriedUntilTheBackoffPasses() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.server.offline = true
        h.clock.advance(by: 86_400)

        let first = try await h.client.solarSystems()
        #expect(first.isStale)
        #expect(h.server.manifestRequests == 2)

        // Within the backoff: stored data, stale, no new request from any entry point.
        h.clock.advance(by: 899)
        #expect(try await h.client.solarSystems().isStale)
        let release = try await h.client.currentRelease()
        #expect(release.isStale)
        #expect(release.value.release == Fixture.release)
        _ = try? await h.client.record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)
        #expect(h.server.manifestRequests == 2)

        // forceCheck ignores the backoff.
        _ = try await h.client.currentRelease(forceCheck: true)
        #expect(h.server.manifestRequests == 3)

        // After the backoff the check runs again and recovers.
        h.server.offline = false
        h.clock.advance(by: 900)
        let recovered = try await h.client.solarSystems()
        #expect(recovered.isStale == false)
        #expect(h.server.manifestRequests == 4)
        #expect(try await h.client.currentRelease().isStale == false)
    }

    @Test func withNothingStoredEveryCallRetriesTheReleaseCheck() async throws {
        let h = try Harness()
        h.server.offline = true
        for _ in 0..<2 {
            let error = await #expect(throws: CapsuleerError.self) { try await h.client.currentRelease() }
            #expect(error?.code == .sdeReleaseUnavailable)
        }
        #expect(h.server.manifestRequests == 2)
    }

    @Test func aFailedDownloadIsNotRetriedUntilTheBackoffPasses() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        h.server.setSolarSystemsVersion("feedface")
        h.server.state.mutate { $0.jsonl = Data("{not json}\n".utf8) }
        h.clock.advance(by: 86_400)

        #expect(try await h.client.solarSystems().isStale)
        #expect(h.server.jsonlRequests == 2)

        h.clock.advance(by: 899)
        let held = try await h.client.solarSystems()
        #expect(held.isStale)
        #expect(held.version == Fixture.solarSystemsVersion)
        #expect(h.server.jsonlRequests == 2)

        h.clock.advance(by: 1)
        _ = try await h.client.solarSystems()
        #expect(h.server.jsonlRequests == 3)

        // forceCheck retries straight away.
        _ = try await h.client.solarSystems(forceCheck: true)
        #expect(h.server.jsonlRequests == 4)
    }

    @Test func aFailedDownloadIsRetriedWhenTheVersionChanges() async throws {
        // A backoff longer than the check interval, so only the version change can trigger the retry.
        let h = try Harness(failureRetryInterval: 10 * 86_400)
        _ = try await h.client.solarSystems()
        h.server.setSolarSystemsVersion("feedface")
        let good = try Fixture.solarSystemsJSONL
        h.server.state.mutate { $0.jsonl = Data("{not json}\n".utf8) }
        h.clock.advance(by: 86_400)
        #expect(try await h.client.solarSystems().isStale)
        #expect(h.server.jsonlRequests == 2)

        // The next check finds the same version: still held back.
        h.clock.advance(by: 86_400)
        #expect(try await h.client.solarSystems().isStale)
        #expect(h.server.manifestRequests == 3)
        #expect(h.server.jsonlRequests == 2)

        // The next check finds a new version: downloaded.
        h.server.state.mutate {
            $0.jsonl = good
            let text = String(decoding: $0.manifest, as: UTF8.self)
            $0.manifest = Data(text.replacingOccurrences(of: "feedface", with: "beefcafe").utf8)
        }
        h.clock.advance(by: 86_400)
        let table = try await h.client.solarSystems()
        #expect(table.isStale == false)
        #expect(table.version == "beefcafe")
        #expect(h.server.jsonlRequests == 3)
    }

    @Test func aFailedFirstDownloadIsHeldBackAndKeepsTheError() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonl = Data("{not json}\n".utf8) }
        for _ in 0..<2 {
            let error = await #expect(throws: CapsuleerError.self) { try await h.client.solarSystems() }
            #expect(error?.code == .sdeReleaseUnavailable)
            #expect((error?.underlying as? CapsuleerError)?.code == .decoding)
        }
        #expect(h.server.jsonlRequests == 1)
    }

    // MARK: Cancellation

    @Test func aCancelledCallerStopsWaitingWhileTheSharedSyncContinues() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonlDelay = .seconds(1) }
        let cancelled = Task { try await h.client.solarSystems() }
        let other = Task { try await h.client.solarSystems() }
        try await eventually { h.server.jsonlRequests == 1 }

        let start = ContinuousClock.now
        cancelled.cancel()
        let error = await #expect(throws: CapsuleerError.self) { try await cancelled.value }
        #expect(error?.code == .cancelled)
        #expect(ContinuousClock.now - start < .milliseconds(500))

        #expect(try await other.value.all.count == 11)
        #expect(h.server.jsonlRequests == 1)
        // The finished sync is kept for later callers.
        #expect(try await h.client.solarSystems().isStale == false)
        #expect(h.server.jsonlRequests == 1)
    }

    @Test func aCancelledReleaseCallerStopsWaiting() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.manifestDelay = .seconds(1) }
        let cancelled = Task { try await h.client.currentRelease() }
        try await eventually { h.server.manifestRequests == 1 }

        let start = ContinuousClock.now
        cancelled.cancel()
        let error = await #expect(throws: CapsuleerError.self) { try await cancelled.value }
        #expect(error?.code == .cancelled)
        #expect(ContinuousClock.now - start < .milliseconds(500))

        // The check still completed and was stored.
        let release = try await h.client.currentRelease()
        #expect(release.value.release == Fixture.release)
        #expect(h.server.manifestRequests == 1)
    }

    @Test func anAlreadyCancelledCallerThrowsCancelled() async throws {
        let h = try Harness()
        h.server.state.mutate { $0.jsonlDelay = .milliseconds(300) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.client.solarSystems()
        }
        let error = await #expect(throws: CapsuleerError.self) { try await task.value }
        #expect(error?.code == .cancelled)
    }

    // MARK: forceCheck while a sync is running

    @Test func aForcedCallJoiningANonForcedSyncStillChecks() async throws {
        let h = try Harness()
        _ = try await h.client.solarSystems()
        #expect(h.server.manifestRequests == 1)

        // A fresh client whose store answers slowly, so its non-forced sync is in flight (and will
        // find no check due) when the forced call arrives.
        let slow = try Harness(server: h.server, store: SlowTableStore(base: h.store, delay: .milliseconds(200)), clock: h.clock)
        async let plain = slow.client.solarSystems()
        try await Task.sleep(for: .milliseconds(50))
        async let forcedA = slow.client.solarSystems(forceCheck: true)
        async let forcedB = slow.client.solarSystems(forceCheck: true)
        let results = try await [plain, forcedA, forcedB]

        #expect(results.allSatisfy { $0.all.count == 11 && !$0.isStale })
        // The two forced callers shared one forced check.
        #expect(h.server.manifestRequests == 2)
        #expect(h.server.jsonlRequests == 1)
    }
}
