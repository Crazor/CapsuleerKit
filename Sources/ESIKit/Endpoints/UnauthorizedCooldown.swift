import Foundation

/// Per-character record of "ESI rejected a freshly minted token too", for
/// `ESIClient.authenticatedCall`. While a character is cooling down, a 401 is thrown at once
/// instead of invalidating, refreshing and retrying, so a locked account or an ESI auth incident
/// costs one error per call rather than two errors plus an SSO refresh.
actor UnauthorizedCooldown {
    private var until: [Int64: Date] = [:]

    /// Whether 401s for `characterID` are currently thrown without a refresh and retry.
    func isActive(for characterID: Int64, now: Date) -> Bool {
        guard let end = until[characterID] else { return false }
        if now < end { return true }
        until[characterID] = nil
        return false
    }

    /// Starts (or restarts) the cooldown after the retried request also got a 401.
    func start(for characterID: Int64, now: Date, duration: Duration) {
        until[characterID] = now.addingTimeInterval(EtiquetteTime.seconds(duration))
    }

    /// Ends the cooldown after an authenticated call succeeded.
    func clear(for characterID: Int64) {
        until[characterID] = nil
    }
}
