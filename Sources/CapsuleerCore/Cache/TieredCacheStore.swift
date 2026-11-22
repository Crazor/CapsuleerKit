import Foundation

/// Memory in front of disk. Reads promote disk hits into memory; writes go to both.
///
/// Every operation that touches more than one tier (writes, removals, and a disk read plus its
/// promotion into memory) runs one at a time, in arrival order, so concurrent calls cannot
/// interleave across the `await`s between tiers: a promotion never puts back an entry that was
/// removed or replaced meanwhile, and both tiers always end up agreeing. (Actor isolation alone
/// is not enough, because an actor is reentrant at every `await`.) A memory hit needs no tier
/// coordination and is answered without waiting.
public actor TieredCacheStore: CacheStore {
    let memory: any CacheStore
    let disk: any CacheStore

    /// Whether a multi-tier operation is running, and who is waiting for it to finish (FIFO).
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(memory: MemoryCacheStore, disk: DiskCacheStore) {
        self.init(memoryTier: memory, diskTier: disk)
    }

    /// Convenience: default-sized memory store plus a disk store in `directory`.
    public init(directory: URL) {
        self.init(memory: MemoryCacheStore(), disk: DiskCacheStore(directory: directory))
    }

    /// Any two stores as tiers (tests use this to observe interleavings).
    init(memoryTier: any CacheStore, diskTier: any CacheStore) {
        self.memory = memoryTier
        self.disk = diskTier
    }

    public func entry(for key: CacheKey) async -> CacheEntry? {
        if let hit = await memory.entry(for: key) { return hit }
        return await serialized {
            // Checked again: the entry may have been stored or promoted while we waited.
            if let hit = await memory.entry(for: key) { return hit }
            guard let hit = await disk.entry(for: key) else { return nil }
            await memory.store(hit, for: key)
            return hit
        }
    }

    public func store(_ entry: CacheEntry, for key: CacheKey) async {
        await serialized {
            await memory.store(entry, for: key)
            await disk.store(entry, for: key)
        }
    }

    public func remove(_ key: CacheKey) async {
        await serialized {
            await memory.remove(key)
            await disk.remove(key)
        }
    }

    public func removeAll(identity: CacheIdentity?) async {
        await serialized {
            await memory.removeAll(identity: identity)
            await disk.removeAll(identity: identity)
        }
    }

    // MARK: - Serialisation

    private func serialized<T: Sendable>(_ operation: () async -> T) async -> T {
        await acquire()
        let result = await operation()
        release()
        return result
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // Ownership is handed over directly by `release()`, so `isBusy` stays true.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
