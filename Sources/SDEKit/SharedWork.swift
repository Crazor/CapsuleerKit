import CapsuleerCore

/// One piece of work that several callers await together.
///
/// The work runs in its own unstructured task and always runs to completion. Each caller waits on
/// its own continuation, so a cancelled caller stops waiting at once (throwing
/// `CapsuleerError(.cancelled)`) while the others keep waiting. Every continuation is resumed
/// exactly once: it is removed from `waiters` (on this actor) before it is resumed, whether by the
/// result, by cancellation, or immediately when the caller was already cancelled.
actor SharedWork<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiters: [Int: CheckedContinuation<Value, any Error>] = [:]
    private var nextWaiterID = 0

    /// Starts `operation` right away.
    init(_ operation: @escaping @Sendable () async throws -> Value) {
        Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            await self.finish(result)
        }
    }

    /// Waits for the result. Throws `CapsuleerError(.cancelled)` as soon as the calling task is
    /// cancelled; the work itself carries on.
    func value() async throws -> Value {
        if let result { return try result.get() }
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    continuation.resume(throwing: Self.cancelled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            // Runs on the cancelling thread; hop onto the actor. If this arrives before the waiter
            // is registered, the `Task.isCancelled` check above handles it instead.
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: Self.cancelled)
    }

    private func finish(_ result: Result<Value, any Error>) {
        self.result = result
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(with: result) }
    }

    private static var cancelled: CapsuleerError {
        CapsuleerError(.cancelled, message: "Cancelled while waiting for shared SDE work")
    }
}
