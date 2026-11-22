import CapsuleerCore
import Foundation

/// ESI's error-limit budget, shared by every request through one `ESIEtiquetteTransport`.
/// Tracks `X-Esi-Error-Limit-Remain` / `-Reset`; at or below the floor, requests wait for the reset.
actor ErrorBudget {
    /// ESI's error window, used when a 420 or low budget arrives without a reset header.
    static let defaultWindow: TimeInterval = 60

    let floor: Int
    private(set) var remain: Int?
    private(set) var resetAt: Date?

    init(floor: Int) { self.floor = floor }

    /// Seconds to wait before sending at `now` (0 = go ahead).
    func requiredWait(now: Date) -> TimeInterval {
        if let resetAt, now >= resetAt {
            // The window has reset; the budget is unknown again until the next response.
            remain = nil
            self.resetAt = nil
        }
        guard let remain, remain <= floor, let resetAt else { return 0 }
        return max(0, resetAt.timeIntervalSince(now))
    }

    /// Records a response's error-limit headers. A 420 empties the budget until the reset.
    func record(status: Int, headers: HTTPHeaders, now: Date) {
        if let value = headers["X-Esi-Error-Limit-Remain"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            remain = value
        }
        if let seconds = headers["X-Esi-Error-Limit-Reset"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), seconds.isFinite {
            resetAt = now.addingTimeInterval(max(0, seconds))
        }
        if status == 420 { remain = 0 }
        if let remain, remain <= floor, resetAt == nil || resetAt! <= now {
            resetAt = now.addingTimeInterval(Self.defaultWindow)
        }
    }
}
