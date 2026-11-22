import Foundation

/// In-memory LRU store bounded by total body bytes.
public actor MemoryCacheStore: CacheStore {
    public init(maxBytes: Int = 16 * 1024 * 1024) {
        fatalError("TODO(cache agent)")
    }
    public func entry(for key: CacheKey) async -> CacheEntry? { fatalError("TODO(cache agent)") }
    public func store(_ entry: CacheEntry, for key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func remove(_ key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func removeAll(identity: CacheIdentity?) async { fatalError("TODO(cache agent)") }
}
