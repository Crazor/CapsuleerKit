import Foundation

/// One file per entry under `directory`, atomic writes, LRU eviction above `maxBytes`.
/// `allowsPrivateData` false makes `store` ignore entries with `isPrivate`.
///
/// File format (named `key.digest`):
/// `"CKC1"` magic, UInt32 big-endian metadata length, metadata JSON (key + entry without body),
/// then the raw body bytes. Files are rewritten atomically; reads touch the modification date,
/// which drives LRU eviction (also across launches).
public actor DiskCacheStore: CacheStore {
    private struct Metadata: Codable {
        var key: CacheKey
        var status: Int
        var headers: HTTPHeaders
        var url: URL
        var etag: String?
        var lastModified: String?
        var expires: Date?
        var storedAt: Date
        var isPrivate: Bool
    }

    private struct IndexItem {
        var size: Int
        var lastUse: TimeInterval
    }

    private static let magic = Data("CKC1".utf8)
    private static let headerSize = 8

    private let directory: URL
    private let maxBytes: Int
    private let allowsPrivateData: Bool
    private let fileManager = FileManager()

    /// digest → size and last use; loaded from the directory on first access.
    private var index: [String: IndexItem]?
    private var totalBytes = 0
    private var lastStamp: TimeInterval = 0

    public init(directory: URL, maxBytes: Int = 64 * 1024 * 1024, allowsPrivateData: Bool = true) {
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
        self.allowsPrivateData = allowsPrivateData
    }

    public func entry(for key: CacheKey) async -> CacheEntry? {
        loadIndexIfNeeded()
        let digest = key.digest
        let url = fileURL(digest)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            forget(digest)
            return nil
        }
        guard let (metadata, body) = Self.decode(data), metadata.key == key else {
            deleteFile(digest)
            return nil
        }
        touch(digest, size: data.count)
        return CacheEntry(
            status: metadata.status, headers: metadata.headers, body: body, url: metadata.url,
            etag: metadata.etag, lastModified: metadata.lastModified, expires: metadata.expires,
            storedAt: metadata.storedAt, isPrivate: metadata.isPrivate)
    }

    public func store(_ entry: CacheEntry, for key: CacheKey) async {
        if entry.isPrivate && !allowsPrivateData { return }
        loadIndexIfNeeded()
        let digest = key.digest
        let metadata = Metadata(
            key: key, status: entry.status, headers: entry.headers, url: entry.url, etag: entry.etag,
            lastModified: entry.lastModified, expires: entry.expires, storedAt: entry.storedAt, isPrivate: entry.isPrivate)
        guard let json = try? JSONEncoder().encode(metadata) else { return }

        var data = Data(capacity: Self.headerSize + json.count + entry.body.count)
        data.append(Self.magic)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(entry.body)

        guard data.count <= maxBytes else {
            deleteFile(digest)  // never fits; drop any older version rather than serve it
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(digest), options: .atomic)
        } catch {
            return
        }
        touch(digest, size: data.count, updateFile: false)
        evict(keeping: digest)
    }

    public func remove(_ key: CacheKey) async {
        loadIndexIfNeeded()
        deleteFile(key.digest)
    }

    public func removeAll(identity: CacheIdentity?) async {
        loadIndexIfNeeded()
        for digest in Array((index ?? [:]).keys) {
            if let identity {
                // Unreadable metadata is removed too: it can't be served anyway.
                if let key = readKey(digest), key.identity != identity { continue }
            }
            deleteFile(digest)
        }
    }

    // MARK: - Files

    private func fileURL(_ digest: String) -> URL { directory.appendingPathComponent(digest, isDirectory: false) }

    private static func isEntryName(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { $0.isHexDigit }
    }

    private static func decode(_ data: Data) -> (Metadata, Data)? {
        guard data.count >= headerSize, data.prefix(4) == magic else { return nil }
        let length = data.dropFirst(4).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let start = data.startIndex + headerSize
        guard data.count - headerSize >= length else { return nil }
        let jsonRange = start..<(start + length)
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: data.subdata(in: jsonRange)) else { return nil }
        return (metadata, data.subdata(in: jsonRange.upperBound..<data.endIndex))
    }

    /// Reads just the metadata of a file (no body).
    private func readKey(_ digest: String) -> CacheKey? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL(digest)) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: Self.headerSize), header.count == Self.headerSize,
              header.prefix(4) == Self.magic
        else { return nil }
        let length = header.dropFirst(4).reduce(0) { ($0 << 8) | Int($1) }
        guard let json = try? handle.read(upToCount: length), json.count == length,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: json)
        else { return nil }
        return metadata.key
    }

    private func deleteFile(_ digest: String) {
        try? fileManager.removeItem(at: fileURL(digest))
        forget(digest)
    }

    // MARK: - Index and eviction

    private func loadIndexIfNeeded() {
        guard index == nil else { return }
        var items: [String: IndexItem] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for url in urls where Self.isEntryName(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            items[url.lastPathComponent] = IndexItem(size: values.fileSize ?? 0, lastUse: stamp)
            lastStamp = max(lastStamp, stamp)
        }
        index = items
        totalBytes = items.values.reduce(0) { $0 + $1.size }
    }

    /// A strictly increasing timestamp, so entries used in the same instant still order correctly.
    private func nextStamp() -> TimeInterval {
        lastStamp = max(Date().timeIntervalSinceReferenceDate, lastStamp.nextUp)
        return lastStamp
    }

    private func touch(_ digest: String, size: Int, updateFile: Bool = true) {
        let stamp = nextStamp()
        if updateFile {
            try? fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: stamp)], ofItemAtPath: fileURL(digest).path)
        }
        totalBytes += size - (index?[digest]?.size ?? 0)
        index?[digest] = IndexItem(size: size, lastUse: stamp)
    }

    private func forget(_ digest: String) {
        if let old = index?.removeValue(forKey: digest) { totalBytes -= old.size }
    }

    private func evict(keeping keep: String) {
        guard totalBytes > maxBytes, let index else { return }
        let victims = index.filter { $0.key != keep }.sorted { $0.value.lastUse < $1.value.lastUse }.map(\.key)
        for digest in victims {
            guard totalBytes > maxBytes else { break }
            deleteFile(digest)
        }
    }
}
