import Foundation

/// Supplies the current time and sleeping, so tests can control time.
public protocol TimeSource: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

/// Wall-clock time and `Task.sleep`.
public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
