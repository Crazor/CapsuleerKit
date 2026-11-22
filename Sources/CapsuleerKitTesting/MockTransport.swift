import Foundation
import CapsuleerCore

/// A scriptable transport for tests. Responses are produced by a handler or popped from a queue;
/// every request is recorded for assertions.
public final class MockTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let lock = NSLock()
    private var queue: [Result<HTTPResponse, CapsuleerError>] = []
    private var handler: Handler?
    private var _requests: [HTTPRequest] = []

    public init(handler: Handler? = nil) { self.handler = handler }

    /// All requests sent so far, in order.
    public var requests: [HTTPRequest] { lock.withLock { _requests } }

    /// Replaces the handler.
    public func setHandler(_ handler: Handler?) { lock.withLock { self.handler = handler } }

    /// Queues a response for the next request. Queued responses win over the handler.
    public func enqueue(_ response: HTTPResponse) { lock.withLock { queue.append(.success(response)) } }

    /// Queues a transport failure for the next request.
    public func enqueue(error: CapsuleerError) { lock.withLock { queue.append(.failure(error)) } }

    /// Convenience: queue a response for `url` with a status, headers and body.
    public func enqueue(status: Int = 200, headers: HTTPHeaders = [:], body: Data = Data(), url: URL) {
        enqueue(HTTPResponse(status: status, headers: headers, body: body, url: url))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (next, handler): (Result<HTTPResponse, CapsuleerError>?, Handler?) = lock.withLock {
            _requests.append(request)
            return (queue.isEmpty ? nil : queue.removeFirst(), self.handler)
        }
        if let next { return try next.get() }
        if let handler { return try await handler(request) }
        throw CapsuleerError(.transport, message: "MockTransport: no response queued for \(request.method.rawValue) \(request.url.absoluteString)", url: request.url)
    }
}
