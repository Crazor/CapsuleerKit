import Foundation
import CapsuleerCore

/// A clock that only moves when told to. `sleep(for:)` advances time immediately and returns,
/// so code that waits does not slow tests down.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [Duration] = []

    public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = now }

    public func now() -> Date { lock.withLock { current } }

    public func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    public func set(_ date: Date) { lock.withLock { current = date } }

    /// Durations passed to `sleep(for:)`, in order.
    public var sleeps: [Duration] { lock.withLock { _sleeps } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let c = duration.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        lock.withLock {
            _sleeps.append(duration)
            current = current.addingTimeInterval(seconds)
        }
    }
}

extension HTTPHeaders {
    /// RFC 7231 date string for headers like Expires / Date / Last-Modified.
    public static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }
}
