import Foundation

/// Memory in front of disk. Reads promote disk hits into memory; writes go to both.
public struct TieredCacheStore: CacheStore {
    public init(memory: MemoryCacheStore, disk: DiskCacheStore) {
        fatalError("TODO(cache agent)")
    }
    /// Convenience: default-sized memory store plus a disk store in `directory`.
    public init(directory: URL) {
        fatalError("TODO(cache agent)")
    }
    public func entry(for key: CacheKey) async -> CacheEntry? { fatalError("TODO(cache agent)") }
    public func store(_ entry: CacheEntry, for key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func remove(_ key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func removeAll(identity: CacheIdentity?) async { fatalError("TODO(cache agent)") }
}
