import Foundation

/// Default transport: its own ephemeral URLSession with URLCache disabled (all caching is ours),
/// `Accept-Encoding: gzip`, redirects followed. Transport failures throw `CapsuleerError(.transport)`;
/// cancellation throws `CapsuleerError(.cancelled)`.
public final class URLSessionTransport: HTTPTransport {
    public init(timeout: TimeInterval = 30) {
        fatalError("TODO(transport agent)")
    }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        fatalError("TODO(transport agent)")
    }
}
