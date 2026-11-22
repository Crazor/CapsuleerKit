import CapsuleerCore
import Foundation

/// Results of `POST /universe/names` and `/universe/ids`, per ID or name: in process, and in the
/// configured `CacheStore` under synthetic keys (POST responses are never cached by `HTTPClient`),
/// so names resolved once also work offline later.
actor LookupCache {
    /// How long resolved IDs stay fresh (names of stations etc. rarely change).
    static let nameTTL: TimeInterval = 30 * 24 * 3600
    /// ESI's documented server cache for `/universe/ids`.
    static let idsTTL: TimeInterval = 12 * 3600
    /// Names that resolved to nothing.
    static let unresolvedIdsTTL: TimeInterval = 3600

    struct Entry<Value: Sendable>: Sendable {
        var value: Value
        var expires: Date
    }

    private let store: (any CacheStore)?
    private let timeSource: any TimeSource
    private var names: [Int64: Entry<ResolvedEntity>] = [:]
    private var ids: [String: Entry<[ResolvedEntity]>] = [:]

    init(store: (any CacheStore)?, timeSource: any TimeSource) {
        self.store = store
        self.timeSource = timeSource
    }

    // MARK: Names (ID → entity)

    /// The cached entity for `id`, fresh or (with `allowStale`) expired.
    func name(for id: Int64, allowStale: Bool = false) async -> ResolvedEntity? {
        if usable(names[id], allowStale: false) == nil, let stored: Entry<ResolvedEntity> = await loadStored(Self.nameKey(id)) { names[id] = stored }
        return usable(names[id], allowStale: allowStale)
    }

    func storeNames(_ entities: [ResolvedEntity]) async {
        let expires = timeSource.now().addingTimeInterval(Self.nameTTL)
        for entity in entities {
            names[entity.id] = Entry(value: entity, expires: expires)
            await persist(entity, key: Self.nameKey(entity.id), expires: expires)
        }
    }

    // MARK: IDs (name → entities)

    /// The cached entities for `name` (empty when it was known not to resolve), or nil if unknown.
    func ids(for name: String, allowStale: Bool = false) async -> [ResolvedEntity]? {
        if usable(ids[name], allowStale: false) == nil, let stored: Entry<[ResolvedEntity]> = await loadStored(Self.idsKey(name)) { ids[name] = stored }
        return usable(ids[name], allowStale: allowStale)
    }

    func storeIDs(_ entities: [ResolvedEntity], for name: String) async {
        let ttl = entities.isEmpty ? Self.unresolvedIdsTTL : Self.idsTTL
        let expires = timeSource.now().addingTimeInterval(ttl)
        ids[name] = Entry(value: entities, expires: expires)
        await persist(entities, key: Self.idsKey(name), expires: expires)
    }

    // MARK: Storage

    private func usable<Value>(_ entry: Entry<Value>?, allowStale: Bool) -> Value? {
        guard let entry, allowStale || timeSource.now() < entry.expires else { return nil }
        return entry.value
    }

    private func loadStored<Value: Decodable>(_ key: CacheKey) async -> Entry<Value>? {
        guard let store, let stored = await store.entry(for: key), let expires = stored.expires,
              let value = try? JSONDecoder().decode(Value.self, from: stored.body) else { return nil }
        return Entry(value: value, expires: expires)
    }

    private func persist(_ value: some Encodable, key: CacheKey, expires: Date) async {
        guard let store, let body = try? JSONEncoder().encode(value), let url = URL(string: key.url) else { return }
        let entry = CacheEntry(status: 200, headers: ["Content-Type": "application/json"], body: body, url: url,
                               etag: nil, lastModified: nil, expires: expires, storedAt: timeSource.now(), isPrivate: false)
        await store.store(entry, for: key)
    }

    /// Synthetic, GET-style keys. The scheme keeps them apart from real ESI URLs; `v1` names the
    /// stored format (JSON of `ResolvedEntity` / `[ResolvedEntity]`).
    static func nameKey(_ id: Int64) -> CacheKey {
        CacheKey(method: .get, url: URL(string: "capsuleerkit://esi/v1/universe/names/\(id)")!)
    }

    static func idsKey(_ name: String) -> CacheKey {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return CacheKey(method: .get, url: URL(string: "capsuleerkit://esi/v1/universe/ids/\(encoded)")!)
    }
}
