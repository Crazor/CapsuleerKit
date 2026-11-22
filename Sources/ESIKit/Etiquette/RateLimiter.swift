import CapsuleerCore
import Foundation

/// A bucket size, "<tokens>/<window>" as in the spec's `x-rate-limit` and `X-Ratelimit-Limit`
/// ("150/15m"; window units s, m, h; a bare number is seconds).
struct RateLimitWindow: Sendable, Hashable {
    var capacity: Int
    var window: TimeInterval

    init(capacity: Int, window: TimeInterval) {
        self.capacity = capacity
        self.window = window
    }

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let capacity = Int(parts[0].trimmingCharacters(in: .whitespaces)), capacity > 0 else { return nil }
        var spec = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        var unit: TimeInterval = 1
        switch spec.last {
        case "s": unit = 1; spec.removeLast()
        case "m": unit = 60; spec.removeLast()
        case "h": unit = 3600; spec.removeLast()
        default: break
        }
        guard let amount = Double(spec), amount > 0, amount.isFinite else { return nil }
        self.capacity = capacity
        self.window = amount * unit
    }
}

/// Bucket key: ESI rate-limit group plus whose bucket ("public" or "character:<id>").
struct RateLimitKey: Sendable, Hashable, CustomStringConvertible {
    var group: String
    var identity: String
    var description: String { "\(group)/\(identity)" }
}

/// ESI's floating-window rate limiter. Each response costs tokens (2XX = 2, 3XX = 1, 4XX = 5,
/// 5XX = 0) for one window after it arrives. Before sending, a request reserves the worst case;
/// the reservation is settled to the real cost when the response arrives, and the bucket is
/// corrected from `X-Ratelimit-*` headers (they win over the local estimate).
actor RateLimiter {
    /// Cost of the most expensive response (any 4XX).
    static let worstCaseCost = 5

    static func cost(forStatus status: Int) -> Int {
        switch status {
        case 200..<300: return 2
        case 300..<400: return 1
        case 400..<500: return 5
        default: return 0
        }
    }

    struct Reservation: Sendable, Hashable {
        var key: RateLimitKey
        var id: Int
    }

    enum Decision: Sendable, Equatable {
        /// No known bucket: send without limiting.
        case unlimited
        case granted(Reservation)
        /// Not enough headroom; try again after this many seconds.
        case wait(TimeInterval)
    }

    struct Spend: Sendable {
        var id: Int
        var at: Date
        var tokens: Int
        /// A reservation for a request still in flight (worst-case cost, never ages out).
        var pending: Bool
    }

    struct Bucket: Sendable {
        var capacity: Int
        var window: TimeInterval
        var spends: [Spend] = []
        /// Capacity and window came from `X-Ratelimit-Limit`, so spec hints no longer override them.
        var limitFromHeaders = false

        var used: Int { spends.reduce(0) { $0 + $1.tokens } }
        var settledUsed: Int { spends.reduce(0) { $0 + ($1.pending ? 0 : $1.tokens) } }

        mutating func prune(now: Date) {
            spends.removeAll { !$0.pending && $0.at.addingTimeInterval(window) <= now }
        }

        /// Makes the settled spends add up to `serverUsed`: adds an unattributed spend at `now`
        /// (other clients, or requests we never saw) or forgets the oldest tokens.
        mutating func reconcile(serverUsed: Int, now: Date) {
            let target = max(0, serverUsed)
            var difference = target - settledUsed
            if difference > 0 {
                spends.append(Spend(id: -1, at: now, tokens: difference, pending: false))
                return
            }
            var index = 0
            while difference < 0, index < spends.count {
                if !spends[index].pending, spends[index].tokens > 0 {
                    let taken = min(spends[index].tokens, -difference)
                    spends[index].tokens -= taken
                    difference += taken
                }
                index += 1
            }
            spends.removeAll { !$0.pending && $0.tokens == 0 }
        }
    }

    let reserve: Double
    private var buckets: [RateLimitKey: Bucket] = [:]
    private var nextID = 0

    init(reserve: Double) { self.reserve = min(max(reserve, 0), 1) }

    /// Tries to reserve the worst-case cost in `key`'s bucket. A spec `seed` creates the bucket,
    /// or resizes it while no response header has said otherwise.
    func reserve(_ key: RateLimitKey, seed: RateLimitWindow?, now: Date) -> Decision {
        if let seed {
            if var bucket = buckets[key] {
                if !bucket.limitFromHeaders {
                    bucket.capacity = seed.capacity
                    bucket.window = seed.window
                    buckets[key] = bucket
                }
            } else {
                buckets[key] = Bucket(capacity: seed.capacity, window: seed.window)
            }
        }
        guard var bucket = buckets[key] else { return .unlimited }
        bucket.prune(now: now)
        defer { buckets[key] = bucket }

        let wait = Self.requiredWait(bucket, reserve: reserve, now: now)
        guard wait <= 0 else { return .wait(wait) }
        nextID += 1
        bucket.spends.append(Spend(id: nextID, at: now, tokens: Self.worstCaseCost, pending: true))
        return .granted(Reservation(key: key, id: nextID))
    }

    /// Seconds until enough settled spends age out that a worst-case response keeps the bucket
    /// at or above the reserve. 0 = send now.
    static func requiredWait(_ bucket: Bucket, reserve: Double, now: Date) -> TimeInterval {
        let used = bucket.used
        guard used > 0 else { return 0 }  // an empty bucket always admits one request
        let floor = Double(bucket.capacity) * reserve
        let allowedUsed = Double(bucket.capacity - worstCaseCost) - floor
        if Double(used) <= allowedUsed { return 0 }

        var remainingUsed = used
        for spend in bucket.spends.filter({ !$0.pending }).sorted(by: { $0.at < $1.at }) {
            remainingUsed -= spend.tokens
            if remainingUsed == 0 || Double(remainingUsed) <= allowedUsed {
                return max(0, spend.at.addingTimeInterval(bucket.window).timeIntervalSince(now))
            }
        }
        // Only in-flight reservations block; they settle (and shrink) soon.
        return 1
    }

    /// Releases a reservation without cost (transport error, cancellation).
    func release(_ reservation: Reservation) {
        buckets[reservation.key]?.spends.removeAll { $0.pending && $0.id == reservation.id }
    }

    /// Settles a reservation to the response's real cost and corrects the bucket from its headers.
    /// The `X-Ratelimit-Group` header names the real bucket, even when no reservation was made.
    func record(_ reservation: Reservation?, identity: String, status: Int, headers: HTTPHeaders, now: Date) {
        let headerGroup = headers["X-Ratelimit-Group"]?.trimmingCharacters(in: .whitespaces)
        let group = (headerGroup?.isEmpty == false ? headerGroup : nil) ?? reservation?.key.group
        guard let group else { return }
        let key = RateLimitKey(group: group, identity: identity)
        let cost = Self.cost(forStatus: status)

        if let reservation, reservation.key != key { release(reservation) }

        let limit = headers["X-Ratelimit-Limit"].flatMap(RateLimitWindow.init)
        if buckets[key] == nil {
            guard let limit else { return }  // learned a group but not its size
            buckets[key] = Bucket(capacity: limit.capacity, window: limit.window)
        }
        guard var bucket = buckets[key] else { return }
        if let limit {
            bucket.capacity = limit.capacity
            bucket.window = limit.window
            bucket.limitFromHeaders = true
        }
        if let reservation, reservation.key == key, let index = bucket.spends.firstIndex(where: { $0.pending && $0.id == reservation.id }) {
            bucket.spends[index].pending = false
            bucket.spends[index].at = now
            bucket.spends[index].tokens = cost
        } else if cost > 0 {
            nextID += 1
            bucket.spends.append(Spend(id: nextID, at: now, tokens: cost, pending: false))
        }
        bucket.prune(now: now)

        let used = headers["X-Ratelimit-Used"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let remaining = headers["X-Ratelimit-Remaining"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let serverUsed = used ?? remaining.map({ bucket.capacity - $0 }) {
            bucket.reconcile(serverUsed: serverUsed, now: now)
        }
        bucket.spends.removeAll { !$0.pending && $0.tokens == 0 }
        buckets[key] = bucket
    }

    // MARK: Inspection (tests, logging)

    func bucket(_ key: RateLimitKey) -> Bucket? { buckets[key] }

    /// Tokens left in `key`'s bucket at `now`, counting in-flight reservations as spent.
    func remaining(_ key: RateLimitKey, now: Date) -> Int? {
        guard var bucket = buckets[key] else { return nil }
        bucket.prune(now: now)
        return bucket.capacity - bucket.used
    }
}
