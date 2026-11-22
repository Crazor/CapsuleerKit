import Foundation
import os

/// Coalesces identical in-flight requests: the first caller for a key starts one shared,
/// unstructured `Task`; later callers for the same key wait for its result. A caller that is
/// cancelled stops waiting (and gets `CancellationError`); the shared work carries on while
/// other callers still wait. When the last waiter of a flight is cancelled, the flight is
/// removed and its task cancelled, so work nobody wants (e.g. a long etiquette wait followed by
/// a request) is not done; a caller that arrives after that starts a new flight.
///
/// A lock (not an actor) is used so a waiter is registered synchronously inside the
/// continuation closure; that makes the cancellation handshake race-free. Every continuation
/// is removed from the state under the lock before it is resumed, so each is resumed exactly once.
final class InFlightRequests<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private typealias Waiter = CheckedContinuation<Value, any Error>

    private struct Flight {
        /// Distinguishes this flight from a later one for the same key.
        var id: UInt64
        var waiters: [UInt64: Waiter]
        var task: Task<Void, Never>?
    }

    private struct State {
        var flights: [Key: Flight] = [:]
        var nextID: UInt64 = 0
    }

    private enum Action { case cancelled, joined, started }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Joins the flight for `key`, starting it with `operation` if none is running.
    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiterID = state.withLock { state -> UInt64 in
            state.nextID &+= 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                // `Task.isCancelled` is set before the cancellation handler runs, and both
                // sides take the lock, so a waiter is either never registered or always found.
                let action = state.withLock { state -> Action in
                    if Task.isCancelled { return .cancelled }
                    if state.flights[key] != nil {
                        state.flights[key]!.waiters[waiterID] = continuation
                        return .joined
                    }
                    // The task is created under the lock so a cancellation of the last waiter
                    // (which also takes the lock) always finds it. Its body runs later and only
                    // takes the lock in `finish`, so this cannot deadlock.
                    let flightID = waiterID
                    let task = Task {
                        let result: Result<Value, any Error>
                        do { result = .success(try await operation()) } catch { result = .failure(error) }
                        self.finish(key, flightID: flightID, with: result)
                    }
                    state.flights[key] = Flight(id: flightID, waiters: [waiterID: continuation], task: task)
                    return .started
                }
                if action == .cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let (waiter, abandoned) = state.withLock { state -> (Waiter?, Task<Void, Never>?) in
                guard let waiter = state.flights[key]?.waiters.removeValue(forKey: waiterID) else { return (nil, nil) }
                guard state.flights[key]!.waiters.isEmpty else { return (waiter, nil) }
                // Last waiter gone: drop the flight so a new caller starts afresh, and cancel it.
                return (waiter, state.flights.removeValue(forKey: key)?.task)
            }
            abandoned?.cancel()
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Number of callers currently waiting, across all keys (for tests).
    var waiterCount: Int { state.withLock { $0.flights.values.reduce(0) { $0 + $1.waiters.count } } }

    /// Number of flights currently registered (for tests).
    var flightCount: Int { state.withLock { $0.flights.count } }

    private func finish(_ key: Key, flightID: UInt64, with result: Result<Value, any Error>) {
        let waiters = state.withLock { state -> [UInt64: Waiter] in
            // A cancelled flight was already removed; a newer one for the key is not ours.
            guard state.flights[key]?.id == flightID else { return [:] }
            return state.flights.removeValue(forKey: key)?.waiters ?? [:]
        }
        for waiter in waiters.values { waiter.resume(with: result) }
    }
}
