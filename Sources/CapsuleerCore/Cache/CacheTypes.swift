import Foundation
import CryptoKit

/// Whose data a cache entry holds. Authenticated responses use the character; everything else `.public`.
public struct CacheIdentity: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let `public` = CacheIdentity(rawValue: "public")
    public static func character(_ id: Int64) -> CacheIdentity { CacheIdentity(rawValue: "character:\(id)") }
}

/// Identifies one cached response: method + URL + body hash (POST) + identity + variant headers
/// (e.g. compatibility date, Accept-Language), mirroring the server's `Vary`.
public struct CacheKey: Hashable, Sendable, Codable {
    public var method: HTTPMethod
    public var url: String
    public var bodyHash: String?
    public var identity: CacheIdentity
    public var variant: [String: String]

    public init(method: HTTPMethod, url: URL, body: Data? = nil, identity: CacheIdentity = .public, variant: [String: String] = [:]) {
        self.method = method
        self.url = url.absoluteString
        self.bodyHash = body.map { Self.sha256Hex($0) }
        self.identity = identity
        self.variant = variant
    }

    /// Stable string form (variant keys sorted).
    public var canonicalString: String {
        let v = variant.keys.sorted().map { "\($0.lowercased())=\(variant[$0]!)" }.joined(separator: "&")
        return [method.rawValue, url, bodyHash ?? "-", identity.rawValue, v].joined(separator: "\n")
    }

    /// SHA-256 hex of `canonicalString`; safe as a file name.
    public var digest: String { Self.sha256Hex(Data(canonicalString.utf8)) }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A stored response plus the validators and freshness needed to reuse it.
public struct CacheEntry: Sendable, Codable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data
    /// Final URL the response came from (after redirects).
    public var url: URL
    public var etag: String?
    public var lastModified: String?
    /// The entry is fresh until this date. nil = must revalidate before use.
    public var expires: Date?
    public var storedAt: Date
    /// True for authenticated (per-character) data.
    public var isPrivate: Bool

    public init(status: Int, headers: HTTPHeaders, body: Data, url: URL, etag: String?, lastModified: String?, expires: Date?, storedAt: Date, isPrivate: Bool) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
        self.expires = expires
        self.storedAt = storedAt
        self.isPrivate = isPrivate
    }

    public func isFresh(at date: Date) -> Bool { expires.map { date < $0 } ?? false }
}

/// Pluggable storage for cached responses. Implementations must be safe for concurrent use.
public protocol CacheStore: Sendable {
    func entry(for key: CacheKey) async -> CacheEntry?
    func store(_ entry: CacheEntry, for key: CacheKey) async
    func remove(_ key: CacheKey) async
    /// Removes all entries for `identity`, or everything when nil (e.g. on logout).
    func removeAll(identity: CacheIdentity?) async
}

/// How a call may use the cache.
public enum CachePolicy: Sendable, Hashable {
    /// Fresh entry: serve without network. Stale entry: revalidate with If-None-Match.
    case useProtocolCachePolicy
    /// Any cached entry, even stale, without network; load only if nothing is cached.
    case returnCacheDataElseLoad
    /// Always ask the server, conditionally if an entry exists.
    case reloadRevalidatingCacheData
}

/// Where a response came from.
public enum ResponseSource: String, Sendable, Hashable, Codable {
    case network
    case cache
    case revalidated
}

/// A value plus cache metadata, so apps can schedule the next poll for `expires`.
public struct Response<Value: Sendable>: Sendable {
    public var value: Value
    public var source: ResponseSource
    public var expires: Date?
    public var lastModified: Date?
    public var etag: String?
    /// True when a stale cached value was returned (offline / stale-if-error / returnCacheDataElseLoad).
    public var isStale: Bool

    public init(value: Value, source: ResponseSource, expires: Date?, lastModified: Date?, etag: String?, isStale: Bool) {
        self.value = value
        self.source = source
        self.expires = expires
        self.lastModified = lastModified
        self.etag = etag
        self.isStale = isStale
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> Response<T> {
        Response<T>(value: try transform(value), source: source, expires: expires, lastModified: lastModified, etag: etag, isStale: isStale)
    }
}
