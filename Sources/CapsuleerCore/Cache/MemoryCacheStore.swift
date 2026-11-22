import Foundation

/// In-memory LRU store bounded by total body bytes.
public actor MemoryCacheStore: CacheStore {
    private struct Slot {
        var entry: CacheEntry
        var lastUse: UInt64
    }

    private let maxBytes: Int
    private var slots: [CacheKey: Slot] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0

    public init(maxBytes: Int = 16 * 1024 * 1024) {
        self.maxBytes = max(0, maxBytes)
    }

    public func entry(for key: CacheKey) async -> CacheEntry? {
        guard var slot = slots[key] else { return nil }
        slot.lastUse = tick()
        slots[key] = slot
        return slot.entry
    }

    public func store(_ entry: CacheEntry, for key: CacheKey) async {
        removeSlot(key)
        // An entry that can never fit is not stored (and doesn't flush everything else).
        guard entry.body.count <= maxBytes else { return }
        slots[key] = Slot(entry: entry, lastUse: tick())
        totalBytes += entry.body.count
        evict(keeping: key)
    }

    public func remove(_ key: CacheKey) async {
        removeSlot(key)
    }

    public func removeAll(identity: CacheIdentity?) async {
        guard let identity else {
            slots.removeAll()
            totalBytes = 0
            return
        }
        for key in slots.keys where key.identity == identity { removeSlot(key) }
    }

    /// Total body bytes currently held (for tests and diagnostics).
    var byteCount: Int { totalBytes }

    private func tick() -> UInt64 {
        clock &+= 1
        return clock
    }

    private func removeSlot(_ key: CacheKey) {
        if let old = slots.removeValue(forKey: key) { totalBytes -= old.entry.body.count }
    }

    private func evict(keeping keep: CacheKey) {
        guard totalBytes > maxBytes else { return }
        let victims = slots.filter { $0.key != keep }.sorted { $0.value.lastUse < $1.value.lastUse }.map(\.key)
        for key in victims {
            guard totalBytes > maxBytes else { break }
            removeSlot(key)
        }
    }
}
