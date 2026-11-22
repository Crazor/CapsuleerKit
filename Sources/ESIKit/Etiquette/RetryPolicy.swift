import Foundation

/// Retry rules for `ESIEtiquetteTransport`: which responses are retried, backoff timing and
/// `Retry-After` parsing.
struct RetryPolicy: Sendable {
    /// Retries after 5XX / transport errors (idempotent requests only).
    var maxRetries: Int
    /// First backoff; each later one is `backoffFactor` times longer (1 s, 3 s, 9 s …).
    var baseDelay: TimeInterval = 1
    var backoffFactor: Double = 3
    /// Returns a jitter multiplier, e.g. in 0.8…1.2.
    var jitter: @Sendable () -> Double

    static let defaultJitter: @Sendable () -> Double = { Double.random(in: 0.8...1.2) }

    /// Statuses retried with backoff when the request is idempotent (503 only without `Retry-After`).
    static let retriedServerErrors: Set<Int> = [500, 502, 503, 504]

    /// Backoff before retry number `retry` (0-based), with jitter.
    func backoff(forRetry retry: Int) -> TimeInterval {
        let base = baseDelay * pow(backoffFactor, Double(retry))
        return max(0, base * jitter())
    }

    /// `Retry-After` as seconds from `now`: delta-seconds or an HTTP date. nil if absent or malformed.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        guard let date = parseHTTPDate(value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the only form servers may send.
    /// (CapsuleerCore's `HTTPDate` is internal, so this rare path uses a formatter.)
    static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

/// Conversions between `Duration` and `TimeInterval` for the etiquette code.
enum EtiquetteTime {
    static func seconds(_ duration: Duration) -> TimeInterval {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Rounded up to whole milliseconds so a wait never ends early.
    static func duration(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((max(0, seconds) * 1000).rounded(.up)))
    }
}
