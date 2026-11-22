import Foundation

/// One file per entry under `directory`, atomic writes, LRU eviction above `maxBytes`.
/// `allowsPrivateData` false makes `store` ignore entries with `isPrivate`.
public actor DiskCacheStore: CacheStore {
    public init(directory: URL, maxBytes: Int = 64 * 1024 * 1024, allowsPrivateData: Bool = true) {
        fatalError("TODO(cache agent)")
    }
    public func entry(for key: CacheKey) async -> CacheEntry? { fatalError("TODO(cache agent)") }
    public func store(_ entry: CacheEntry, for key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func remove(_ key: CacheKey) async { fatalError("TODO(cache agent)") }
    public func removeAll(identity: CacheIdentity?) async { fatalError("TODO(cache agent)") }
}
