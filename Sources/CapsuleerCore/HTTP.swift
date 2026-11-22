import Foundation

/// HTTP request method.
public enum HTTPMethod: String, Sendable, Hashable, Codable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

/// HTTP header fields with case-insensitive names. Keeps insertion order; setting a name replaces earlier values.
public struct HTTPHeaders: Sendable, Hashable, Codable, ExpressibleByDictionaryLiteral, Sequence {
    public private(set) var fields: [(name: String, value: String)]

    public init() { fields = [] }

    public init(_ pairs: [(String, String)]) {
        fields = []
        for (name, value) in pairs { self[name] = value }
    }

    public init(dictionaryLiteral elements: (String, String)...) { self.init(elements) }

    /// The value for `name` (case-insensitive), or nil. Setting nil removes the field.
    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            fields.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let newValue { fields.append((name, newValue)) }
        }
    }

    public func makeIterator() -> IndexingIterator<[(name: String, value: String)]> { fields.makeIterator() }

    public var dictionary: [String: String] {
        Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.fields.map { "\($0.name.lowercased())\u{0}\($0.value)" } == rhs.fields.map { "\($0.name.lowercased())\u{0}\($0.value)" }
    }

    public func hash(into hasher: inout Hasher) {
        for field in fields { hasher.combine(field.name.lowercased()); hasher.combine(field.value) }
    }

    private struct Field: Codable { var name: String; var value: String }

    public init(from decoder: any Decoder) throws {
        let decoded = try [Field](from: decoder)
        self.init(decoded.map { ($0.name, $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        try fields.map { Field(name: $0.name, value: $0.value) }.encode(to: encoder)
    }
}

/// A request sent through an `HTTPTransport`.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?

    public init(method: HTTPMethod = .get, url: URL, headers: HTTPHeaders = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A complete response. `url` is the final URL after redirects.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data
    public var url: URL

    public init(status: Int, headers: HTTPHeaders = [:], body: Data = Data(), url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Sends one HTTP request and returns the complete response. Implementations follow redirects,
/// decompress gzip, and perform no caching of their own. Non-2xx statuses are returned, not thrown;
/// only transport failures throw (as `CapsuleerError` with code `.transport`).
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
