import Foundation
import Testing
@testable import CapsuleerCore
import CapsuleerKitTesting

@Suite struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func maxAge() {
        #expect(Freshness.evaluate(["Cache-Control": "public, max-age=60"], now: now) == .store(expires: now + 60))
    }

    @Test func maxAgeMinusAge() {
        #expect(Freshness.evaluate(["Cache-Control": "max-age=60", "Age": "20"], now: now) == .store(expires: now + 40))
    }

    @Test func quotedAndInvalidMaxAge() {
        #expect(Freshness.evaluate(["Cache-Control": "max-age=\"30\""], now: now) == .store(expires: now + 30))
        #expect(Freshness.evaluate(["Cache-Control": "max-age=soon"], now: now) == .store(expires: now))
    }

    @Test func immutable() {
        #expect(Freshness.evaluate(["Cache-Control": "max-age=3600, immutable"], now: now) == .store(expires: now + 3600))
    }

    @Test func maxAgeWinsOverExpires() {
        let headers: HTTPHeaders = ["Cache-Control": "max-age=10", "Expires": HTTPDate.format(now + 1000)]
        #expect(Freshness.evaluate(headers, now: now) == .store(expires: now + 10))
    }

    @Test func expires() {
        let expires = now + 300
        #expect(Freshness.evaluate(["Expires": HTTPDate.format(expires)], now: now) == .store(expires: expires))
    }

    @Test func pastOrInvalidExpiresIsStale() {
        let past = Freshness.evaluate(["Expires": HTTPDate.format(now - 300)], now: now)
        #expect(past == .store(expires: now - 300))
        let invalid = Freshness.evaluate(["Expires": "0"], now: now)
        #expect(invalid.expires.map { $0 <= now } == true)
    }

    @Test func expiresIsMeasuredAgainstServerDate() {
        // The server's clock is 1 h ahead of ours: a 5-minute lifetime must stay 5 minutes.
        let serverNow = now + 3600
        let headers: HTTPHeaders = ["Date": HTTPDate.format(serverNow), "Expires": HTTPDate.format(serverNow + 300)]
        #expect(Freshness.evaluate(headers, now: now) == .store(expires: now + 300))
        // ... and 1 h behind: still 5 minutes, not already expired.
        let behind: HTTPHeaders = ["Date": HTTPDate.format(now - 3600), "Expires": HTTPDate.format(now - 3300)]
        #expect(Freshness.evaluate(behind, now: now) == .store(expires: now + 300))
    }

    @Test func expiresLifetimeMinusAge() {
        let headers: HTTPHeaders = ["Date": HTTPDate.format(now - 7200), "Expires": HTTPDate.format(now - 6900), "Age": "100"]
        #expect(Freshness.evaluate(headers, now: now) == .store(expires: now + 200))
    }

    @Test func expiresWithoutUsableDateIsAbsolute() {
        let expires = now + 300
        #expect(Freshness.evaluate(["Expires": HTTPDate.format(expires), "Date": "garbage"], now: now) == .store(expires: expires))
        // An unparseable Expires is stale even with a Date.
        let invalid = Freshness.evaluate(["Expires": "0", "Date": HTTPDate.format(now + 3600)], now: now)
        #expect(invalid == .store(expires: now))
    }

    @Test func noStore() {
        #expect(Freshness.evaluate(["Cache-Control": "no-store, max-age=60", "ETag": "\"x\""], now: now) == .doNotStore)
    }

    @Test func noCache() {
        #expect(Freshness.evaluate(["Cache-Control": "no-cache, max-age=60"], now: now) == .store(expires: nil))
    }

    @Test func noFreshnessInfo() {
        #expect(Freshness.evaluate([:], now: now) == .doNotStore)
        #expect(Freshness.evaluate(["Content-Type": "application/json"], now: now) == .doNotStore)
        #expect(Freshness.evaluate(["ETag": "\"abc\""], now: now) == .store(expires: nil))
        #expect(Freshness.evaluate(["Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"], now: now) == .store(expires: nil))
    }
}

@Suite struct HTTPDateTests {
    let reference = Date(timeIntervalSince1970: 784_111_777)  // 1994-11-06 08:49:37 UTC

    @Test(arguments: [
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
        "sun, 06 nov 1994 08:49:37 utc",
    ])
    func parsesAllFormats(_ string: String) {
        #expect(HTTPDate.parse(string) == reference)
    }

    @Test(arguments: ["", "0", "-1", "tomorrow", "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 06 Nov 1994 25:00:00 GMT", "Sun, 06 Nov 1994 08:49:37 PST"])
    func rejectsInvalid(_ string: String) {
        #expect(HTTPDate.parse(string) == nil)
    }

    @Test func formats() {
        #expect(HTTPDate.format(reference) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(HTTPDate.format(Date(timeIntervalSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(HTTPDate.format(Date(timeIntervalSince1970: 951_782_400)) == "Tue, 29 Feb 2000 00:00:00 GMT")
    }

    @Test func roundTrips() {
        for seconds in stride(from: -2_000_000_000.0, through: 4_000_000_000, by: 123_456_789) {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(HTTPDate.parse(HTTPDate.format(date)) == date)
        }
    }

    @Test func matchesTestingHelper() {
        let date = Date(timeIntervalSince1970: 1_800_000_123)
        #expect(HTTPDate.parse(HTTPHeaders.httpDate(date)) == date)
    }
}
