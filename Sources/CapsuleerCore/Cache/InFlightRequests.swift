import Foundation
import os

/// Coalesces identical in-flight requests: the first caller for a key starts one shared,
/// unstructured `Task`; later callers for the same key wait for its result. A caller that is
/// cancelled stops waiting (and gets `CancellationError`) without cancelling the shared work.
///
/// A lock (not an actor) is used so a waiter is registered synchronously inside the
/// continuation closure; that makes the cancellation handshake race-free.
final class InFlightRequests<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private typealias Waiter = CheckedContinuation<Value, any Error>

    private struct State {
        var flights: [Key: [UInt64: Waiter]] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private enum Action { case cancelled, joined, start }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Joins the flight for `key`, starting it with `operation` if none is running.
    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiterID = state.withLock { state -> UInt64 in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                // `Task.isCancelled` is set before the cancellation handler runs, and both
                // sides take the lock, so a waiter is either never registered or always found.
                let action = state.withLock { state -> Action in
                    if Task.isCancelled { return .cancelled }
                    if state.flights[key] != nil {
                        state.flights[key]![waiterID] = continuation
                        return .joined
                    }
                    state.flights[key] = [waiterID: continuation]
                    return .start
                }
                switch action {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .joined:
                    break
                case .start:
                    Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await operation()) } catch { result = .failure(error) }
                        self.finish(key, with: result)
                    }
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in state.flights[key]?.removeValue(forKey: waiterID) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Number of callers currently waiting, across all keys (for tests).
    var waiterCount: Int { state.withLock { $0.flights.values.reduce(0) { $0 + $1.count } } }

    private func finish(_ key: Key, with result: Result<Value, any Error>) {
        let waiters = state.withLock { state in state.flights.removeValue(forKey: key) } ?? [:]
        for waiter in waiters.values { waiter.resume(with: result) }
    }
}
