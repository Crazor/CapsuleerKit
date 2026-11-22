import Foundation
import Testing
@testable import CapsuleerCore

func makeEntry(_ body: String = "body", bodySize: Int? = nil, isPrivate: Bool = false, url: String = "https://example.com/x") -> CacheEntry {
    let data = bodySize.map { Data(repeating: 0x61, count: $0) } ?? Data(body.utf8)
    return CacheEntry(
        status: 200, headers: ["ETag": "\"e\"", "Cache-Control": "max-age=60"], body: data, url: URL(string: url)!,
        etag: "\"e\"", lastModified: "Sun, 06 Nov 1994 08:49:37 GMT",
        expires: Date(timeIntervalSince1970: 1_800_000_060), storedAt: Date(timeIntervalSince1970: 1_800_000_000),
        isPrivate: isPrivate)
}

func makeKey(_ path: String, identity: CacheIdentity = .public) -> CacheKey {
    CacheKey(method: .get, url: URL(string: "https://example.com/\(path)")!, identity: identity)
}

/// A fresh directory path (not created); call `remove()` when done.
struct TemporaryDirectory: Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapsuleerCoreTests-\(UUID().uuidString)", isDirectory: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }

    var fileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

@Suite struct MemoryCacheStoreTests {
    @Test func roundTrip() async {
        let store = MemoryCacheStore()
        let entry = makeEntry()
        await store.store(entry, for: makeKey("a"))
        #expect(await store.entry(for: makeKey("a")) == entry)
        #expect(await store.entry(for: makeKey("b")) == nil)
        await store.remove(makeKey("a"))
        #expect(await store.entry(for: makeKey("a")) == nil)
    }

    @Test func evictsLeastRecentlyUsedByBytes() async {
        let store = MemoryCacheStore(maxBytes: 250)
        await store.store(makeEntry(bodySize: 100), for: makeKey("a"))
        await store.store(makeEntry(bodySize: 100), for: makeKey("b"))
        _ = await store.entry(for: makeKey("a"))  // a is now more recent than b
        await store.store(makeEntry(bodySize: 100), for: makeKey("c"))
        #expect(await store.entry(for: makeKey("a")) != nil)
        #expect(await store.entry(for: makeKey("b")) == nil)
        #expect(await store.entry(for: makeKey("c")) != nil)
        #expect(await store.byteCount == 200)
    }

    @Test func replacingAnEntryUpdatesByteCount() async {
        let store = MemoryCacheStore(maxBytes: 1000)
        await store.store(makeEntry(bodySize: 100), for: makeKey("a"))
        await store.store(makeEntry(bodySize: 300), for: makeKey("a"))
        #expect(await store.byteCount == 300)
    }

    @Test func oversizedEntryIsNotStored() async {
        let store = MemoryCacheStore(maxBytes: 100)
        await store.store(makeEntry(bodySize: 50), for: makeKey("small"))
        await store.store(makeEntry(bodySize: 101), for: makeKey("big"))
        #expect(await store.entry(for: makeKey("big")) == nil)
        #expect(await store.entry(for: makeKey("small")) != nil)
    }

    @Test func removeAllByIdentity() async {
        let store = MemoryCacheStore()
        await store.store(makeEntry(), for: makeKey("a"))
        await store.store(makeEntry(isPrivate: true), for: makeKey("a", identity: .character(1)))
        await store.store(makeEntry(isPrivate: true), for: makeKey("a", identity: .character(2)))
        await store.removeAll(identity: .character(1))
        #expect(await store.entry(for: makeKey("a")) != nil)
        #expect(await store.entry(for: makeKey("a", identity: .character(1))) == nil)
        #expect(await store.entry(for: makeKey("a", identity: .character(2))) != nil)
        await store.removeAll(identity: nil)
        #expect(await store.entry(for: makeKey("a")) == nil)
        #expect(await store.entry(for: makeKey("a", identity: .character(2))) == nil)
    }
}

@Suite struct DiskCacheStoreTests {
    @Test func roundTripAcrossInstances() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let directory = dir.url.appendingPathComponent("nested/cache", isDirectory: true)  // created on demand
        let key = makeKey("a")
        let entry = makeEntry("{\"players\":12345}")
        await DiskCacheStore(directory: directory).store(entry, for: key)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [key.digest])

        let reopened = DiskCacheStore(directory: directory)
        #expect(await reopened.entry(for: key) == entry)
        #expect(await reopened.entry(for: makeKey("b")) == nil)
    }

    @Test func bodyIsStoredRaw() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let key = makeKey("a")
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        var entry = makeEntry()
        entry.body = body
        await DiskCacheStore(directory: dir.url).store(entry, for: key)
        let file = try Data(contentsOf: dir.url.appendingPathComponent(key.digest))
        #expect(file.suffix(body.count) == body)
        #expect(file.prefix(4) == Data("CKC1".utf8))
    }

    @Test func remove() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let store = DiskCacheStore(directory: dir.url)
        await store.store(makeEntry(), for: makeKey("a"))
        await store.remove(makeKey("a"))
        #expect(await store.entry(for: makeKey("a")) == nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func corruptFileIsDeleted() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let key = makeKey("a")
        try Data("garbage".utf8).write(to: dir.url.appendingPathComponent(key.digest))
        let store = DiskCacheStore(directory: dir.url)
        #expect(await store.entry(for: key) == nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func truncatedFileIsDeleted() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let key = makeKey("a")
        await DiskCacheStore(directory: dir.url).store(makeEntry(), for: key)
        let path = dir.url.appendingPathComponent(key.digest)
        let data = try Data(contentsOf: path)
        try data.prefix(20).write(to: path)
        #expect(await DiskCacheStore(directory: dir.url).entry(for: key) == nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func mismatchedKeyIsRejected() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let a = makeKey("a"), b = makeKey("b")
        await DiskCacheStore(directory: dir.url).store(makeEntry(), for: a)
        try FileManager.default.moveItem(
            at: dir.url.appendingPathComponent(a.digest), to: dir.url.appendingPathComponent(b.digest))
        #expect(await DiskCacheStore(directory: dir.url).entry(for: b) == nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func evictsLeastRecentlyUsed() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        // Each file is ~2 KB of body plus a few hundred bytes of metadata: two fit, three don't.
        let store = DiskCacheStore(directory: dir.url, maxBytes: 5_500)
        await store.store(makeEntry(bodySize: 2_000), for: makeKey("a"))
        await store.store(makeEntry(bodySize: 2_000), for: makeKey("b"))
        _ = await store.entry(for: makeKey("a"))
        await store.store(makeEntry(bodySize: 2_000), for: makeKey("c"))
        #expect(await store.entry(for: makeKey("a")) != nil)
        #expect(await store.entry(for: makeKey("b")) == nil)
        #expect(await store.entry(for: makeKey("c")) != nil)
        #expect(dir.fileNames == [makeKey("a").digest, makeKey("c").digest].sorted())
    }

    @Test func evictionUsesFileDatesAcrossInstances() async throws {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let first = DiskCacheStore(directory: dir.url)
        await first.store(makeEntry(bodySize: 2_000), for: makeKey("old"))
        await first.store(makeEntry(bodySize: 2_000), for: makeKey("new"))
        // Make "old" clearly older on disk.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: dir.url.appendingPathComponent(makeKey("old").digest).path)
        let second = DiskCacheStore(directory: dir.url, maxBytes: 5_500)
        await second.store(makeEntry(bodySize: 2_000), for: makeKey("third"))
        #expect(await second.entry(for: makeKey("old")) == nil)
        #expect(await second.entry(for: makeKey("new")) != nil)
        #expect(await second.entry(for: makeKey("third")) != nil)
    }

    @Test func oversizedEntryIsNotStored() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let store = DiskCacheStore(directory: dir.url, maxBytes: 1_000)
        await store.store(makeEntry(bodySize: 2_000), for: makeKey("big"))
        #expect(await store.entry(for: makeKey("big")) == nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func removeAllByIdentity() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let store = DiskCacheStore(directory: dir.url)
        await store.store(makeEntry(), for: makeKey("a"))
        await store.store(makeEntry(isPrivate: true), for: makeKey("a", identity: .character(1)))
        await store.store(makeEntry(isPrivate: true), for: makeKey("b", identity: .character(1)))
        await store.store(makeEntry(isPrivate: true), for: makeKey("a", identity: .character(2)))

        await store.removeAll(identity: .character(1))
        #expect(await store.entry(for: makeKey("a")) != nil)
        #expect(await store.entry(for: makeKey("a", identity: .character(1))) == nil)
        #expect(await store.entry(for: makeKey("b", identity: .character(1))) == nil)
        #expect(await store.entry(for: makeKey("a", identity: .character(2))) != nil)
        #expect(dir.fileNames.count == 2)

        await store.removeAll(identity: nil)
        #expect(dir.fileNames.isEmpty)
    }

    @Test func refusesPrivateDataWhenNotAllowed() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let store = DiskCacheStore(directory: dir.url, allowsPrivateData: false)
        await store.store(makeEntry(isPrivate: true), for: makeKey("a", identity: .character(1)))
        await store.store(makeEntry(), for: makeKey("a"))
        #expect(await store.entry(for: makeKey("a", identity: .character(1))) == nil)
        #expect(await store.entry(for: makeKey("a")) != nil)
        #expect(dir.fileNames == [makeKey("a").digest])
    }
}

@Suite struct TieredCacheStoreTests {
    @Test func promotesDiskHitsIntoMemory() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let memory = MemoryCacheStore(), disk = DiskCacheStore(directory: dir.url)
        let tiered = TieredCacheStore(memory: memory, disk: disk)
        let key = makeKey("a")
        await disk.store(makeEntry(), for: key)
        #expect(await memory.entry(for: key) == nil)
        #expect(await tiered.entry(for: key) == makeEntry())
        #expect(await memory.entry(for: key) == makeEntry())
    }

    @Test func writesAndRemovesGoToBoth() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let memory = MemoryCacheStore(), disk = DiskCacheStore(directory: dir.url)
        let tiered = TieredCacheStore(memory: memory, disk: disk)
        let a = makeKey("a"), b = makeKey("b", identity: .character(7))
        await tiered.store(makeEntry(), for: a)
        await tiered.store(makeEntry(isPrivate: true), for: b)
        #expect(await memory.entry(for: a) != nil)
        #expect(await disk.entry(for: a) != nil)

        await tiered.remove(a)
        #expect(await memory.entry(for: a) == nil)
        #expect(await disk.entry(for: a) == nil)

        await tiered.removeAll(identity: .character(7))
        #expect(await memory.entry(for: b) == nil)
        #expect(await disk.entry(for: b) == nil)
    }

    @Test func directoryConvenience() async {
        let dir = TemporaryDirectory()
        defer { dir.remove() }
        let tiered = TieredCacheStore(directory: dir.url)
        await tiered.store(makeEntry(), for: makeKey("a"))
        #expect(await TieredCacheStore(directory: dir.url).entry(for: makeKey("a")) == makeEntry())
    }
}

/// Wraps a store and parks one chosen operation until `release()`, to force an interleaving.
/// A gated `entry(for:)` parks after reading (so it returns what was there before); a gated
/// `store` parks before writing.
private actor GatedStore: CacheStore {
    enum Operation { case entry, store }

    let inner: any CacheStore
    private var gated: Operation?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false

    init(_ inner: any CacheStore, gating operation: Operation) {
        self.inner = inner
        self.gated = operation
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func parkIfGated(_ operation: Operation) async {
        guard gated == operation else { return }
        gated = nil
        await withCheckedContinuation {
            continuation = $0
            isParked = true
        }
        isParked = false
    }

    func entry(for key: CacheKey) async -> CacheEntry? {
        let entry = await inner.entry(for: key)
        await parkIfGated(.entry)
        return entry
    }

    func store(_ entry: CacheEntry, for key: CacheKey) async {
        await parkIfGated(.store)
        await inner.store(entry, for: key)
    }

    func remove(_ key: CacheKey) async { await inner.remove(key) }
    func removeAll(identity: CacheIdentity?) async { await inner.removeAll(identity: identity) }
}

/// Waits until `gate` has parked an operation, then gives a competing call time to run
/// (with unserialised tiers it would complete) before the parked operation goes on.
private func whileParked(_ gate: GatedStore, _ competing: @escaping @Sendable () async -> Void) async {
    while !(await gate.isParked) { await Task.yield() }
    let task = Task { await competing() }
    try? await Task.sleep(for: .milliseconds(50))
    await gate.release()
    await task.value
}

@Suite struct TieredCacheStoreInterleavingTests {
    @Test func promotionRacingRemoveAllDoesNotRestorePrivateEntry() async {
        let memory = MemoryCacheStore(), disk = MemoryCacheStore()
        let key = makeKey("wallet", identity: .character(7))
        await disk.store(makeEntry(isPrivate: true), for: key)
        let gate = GatedStore(disk, gating: .entry)
        let tiered = TieredCacheStore(memoryTier: memory, diskTier: gate)

        async let read = tiered.entry(for: key)  // reads disk, then parks before promoting
        await whileParked(gate) { await tiered.removeAll(identity: .character(7)) }
        _ = await read

        #expect(await memory.entry(for: key) == nil)
        #expect(await disk.entry(for: key) == nil)
        #expect(await tiered.entry(for: key) == nil)
    }

    @Test func promotionOfOldEntryDoesNotOverwriteNewerStore() async {
        let memory = MemoryCacheStore(), disk = MemoryCacheStore()
        let key = makeKey("a")
        await disk.store(makeEntry("old"), for: key)
        let gate = GatedStore(disk, gating: .entry)
        let tiered = TieredCacheStore(memoryTier: memory, diskTier: gate)

        async let read = tiered.entry(for: key)
        await whileParked(gate) { await tiered.store(makeEntry("new"), for: key) }
        _ = await read

        #expect(await memory.entry(for: key) == makeEntry("new"))
        #expect(await disk.entry(for: key) == makeEntry("new"))
        #expect(await tiered.entry(for: key) == makeEntry("new"))
    }

    @Test func storeAndRemoveLeaveTiersAgreeing() async {
        let memory = MemoryCacheStore(), disk = MemoryCacheStore()
        let key = makeKey("a")
        let gate = GatedStore(disk, gating: .store)
        let tiered = TieredCacheStore(memoryTier: memory, diskTier: gate)

        async let write: Void = tiered.store(makeEntry(), for: key)  // memory written, disk write parked
        await whileParked(gate) { await tiered.remove(key) }
        await write

        // The remove arrived second, so it wins in both tiers.
        #expect(await memory.entry(for: key) == nil)
        #expect(await disk.entry(for: key) == nil)
    }
}
