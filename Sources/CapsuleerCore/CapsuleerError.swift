import Foundation

/// The single error type thrown by CapsuleerKit. Codes are an extensible set of static values,
/// so new codes never break exhaustive switches in apps.
public struct CapsuleerError: Error, Sendable, CustomStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        /// Network failure, timeout, TLS error and similar.
        public static let transport = Code(rawValue: "transport")
        /// Non-success HTTP status not covered by a more specific code.
        public static let http = Code(rawValue: "http")
        /// HTTP 404.
        public static let notFound = Code(rawValue: "notFound")
        /// The response body could not be decoded.
        public static let decoding = Code(rawValue: "decoding")
        /// The response was malformed (missing headers, unexpected shape).
        public static let invalidResponse = Code(rawValue: "invalidResponse")
        /// The task was cancelled.
        public static let cancelled = Code(rawValue: "cancelled")
        /// Local storage (cache or data store) failed.
        public static let storage = Code(rawValue: "storage")
        /// No SDE release could be fetched and nothing is stored locally.
        public static let sdeReleaseUnavailable = Code(rawValue: "sdeReleaseUnavailable")
    }

    public var code: Code
    /// HTTP status, when the error came from a response.
    public var status: Int?
    /// Human-readable detail, e.g. the server's error message.
    public var message: String?
    /// The URL involved, if any.
    public var url: URL?
    /// The underlying error, if any.
    public var underlying: (any Error)?

    public init(_ code: Code, status: Int? = nil, message: String? = nil, url: URL? = nil, underlying: (any Error)? = nil) {
        self.code = code
        self.status = status
        self.message = message
        self.url = url
        self.underlying = underlying
    }

    public var description: String {
        var parts = ["CapsuleerError(\(code)"]
        if let status { parts.append("status: \(status)") }
        if let message { parts.append("message: \(message)") }
        if let url { parts.append("url: \(url.absoluteString)") }
        if let underlying { parts.append("underlying: \(underlying)") }
        return parts.joined(separator: ", ") + ")"
    }
}
