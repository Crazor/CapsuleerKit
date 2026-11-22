import Foundation
import Testing
import os
@testable import CapsuleerCore

/// What the stub protocol does for one request.
enum StubReply: Sendable {
    case respond(status: Int, headers: [String: String], body: Data)
    case redirect(to: URL, status: Int)
    case fail(URLError.Code)
    /// Never answers, so the request only ends when it is cancelled.
    case hang
}

/// A request as the stub saw it.
struct SeenRequest: Sendable {
    var method: String?
    var url: URL?
    var headers: [String: String]
    var body: Data?
}

/// Routes requests by host, so tests running in parallel each get their own handler.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (SeenRequest) -> StubReply

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])

    /// Registers `handler` for a fresh host and returns a base URL on that host.
    static func register(_ handler: @escaping Handler) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        return URL(string: "https://\(host)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let seen = SeenRequest(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        )
        switch handler(seen) {
        case let .respond(status, headers, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target, status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Collects requests seen by a handler.
final class RequestLog: Sendable {
    private let state = OSAllocatedUnfairLock<[SeenRequest]>(initialState: [])
    func append(_ request: SeenRequest) { state.withLock { $0.append(request) } }
    var requests: [SeenRequest] { state.withLock { $0 } }
}

private func makeTransport(timeout: TimeInterval = 30) -> URLSessionTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionTransport(configuration: config, timeout: timeout)
}

@Suite struct URLSessionTransportTests {
    @Test func sendsMethodHeadersAndBody() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { seen in
            log.append(seen)
            return .respond(status: 200, headers: [:], body: Data())
        }
        let body = Data(#"["Jita"]"#.utf8)
        let request = HTTPRequest(
            method: .post,
            url: base.appending(path: "universe/ids"),
            headers: ["User-Agent": "Test/1.0", "Content-Type": "application/json", "X-Custom": "abc"],
            body: body
        )
        _ = try await makeTransport().send(request)

        let seen = try #require(log.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.url == request.url)
        #expect(seen.headers["User-Agent"] == "Test/1.0")
        #expect(seen.headers["Content-Type"] == "application/json")
        #expect(seen.headers["X-Custom"] == "abc")
        #expect(seen.body == body)
    }

    @Test func sendsGzipAcceptEncodingByDefault() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { seen in
            log.append(seen)
            return .respond(status: 200, headers: [:], body: Data())
        }
        let transport = makeTransport()
        _ = try await transport.send(HTTPRequest(url: base.appending(path: "a")))
        _ = try await transport.send(HTTPRequest(url: base.appending(path: "b"), headers: ["Accept-Encoding": "identity"]))

        let requests = log.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["Accept-Encoding"] == "gzip")
        #expect(requests[1].headers["Accept-Encoding"] == "identity")
    }

    @Test func makeURLRequestDisablesCachingAndCookies() {
        let request = URLSessionTransport.makeURLRequest(HTTPRequest(url: URL(string: "https://example.test/x")!))
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip")
        #expect(request.httpMethod == "GET")
    }

    @Test func mapsStatusHeadersBodyAndURL() async throws {
        let base = StubURLProtocol.register { _ in
            .respond(
                status: 200,
                headers: ["ETag": "\"abc\"", "Cache-Control": "public, max-age=300", "X-Ratelimit-Remaining": "149"],
                body: Data("hello".utf8)
            )
        }
        let url = base.appending(path: "record.json")
        let response = try await makeTransport().send(HTTPRequest(url: url))

        #expect(response.status == 200)
        #expect(response.isSuccess)
        #expect(response.body == Data("hello".utf8))
        #expect(response.url == url)
        #expect(response.headers["etag"] == "\"abc\"")
        #expect(response.headers["Cache-Control"] == "public, max-age=300")
        #expect(response.headers["x-ratelimit-remaining"] == "149")
    }

    @Test func followsRedirectsAndReportsFinalURL() async throws {
        let base = StubURLProtocol.register { seen in
            if seen.url?.path == "/tranquility/latest/" {
                return .redirect(to: URL(string: "https://\(seen.url!.host!)/tranquility/20261120T165826Z/")!, status: 302)
            }
            return .respond(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let response = try await makeTransport().send(HTTPRequest(url: base.appending(path: "tranquility/latest/")))
        #expect(response.status == 200)
        #expect(response.url.absoluteString.hasSuffix("/tranquility/20261120T165826Z/"))
    }

    @Test(arguments: [304, 404, 420, 503])
    func nonSuccessStatusIsReturnedNotThrown(status: Int) async throws {
        let base = StubURLProtocol.register { _ in
            .respond(status: status, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"x"}"#.utf8))
        }
        let response = try await makeTransport().send(HTTPRequest(url: base.appending(path: "x")))
        #expect(response.status == status)
        #expect(!response.isSuccess)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .secureConnectionFailed])
    func urlErrorMapsToTransport(code: URLError.Code) async throws {
        let base = StubURLProtocol.register { _ in .fail(code) }
        let url = base.appending(path: "x")
        let error = await #expect(throws: CapsuleerError.self) {
            _ = try await makeTransport().send(HTTPRequest(url: url))
        }
        #expect(error?.code == .transport)
        #expect(error?.url == url)
        #expect((error?.underlying as? URLError)?.code == code)
    }

    @Test func cancellingInFlightRequestThrowsCancelled() async throws {
        let base = StubURLProtocol.register { _ in .hang }
        let transport = makeTransport()
        let task = Task { try await transport.send(HTTPRequest(url: base.appending(path: "slow"))) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let error = await #expect(throws: CapsuleerError.self) { _ = try await task.value }
        #expect(error?.code == .cancelled)
    }

    @Test func alreadyCancelledTaskThrowsCancelledWithoutSending() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { seen in
            log.append(seen)
            return .respond(status: 200, headers: [:], body: Data())
        }
        let transport = makeTransport()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(HTTPRequest(url: base.appending(path: "x")))
        }
        let error = await #expect(throws: CapsuleerError.self) { _ = try await task.value }
        #expect(error?.code == .cancelled)
        #expect(log.requests.isEmpty)
    }

    @Test func errorMapping() {
        let url = URL(string: "https://example.test")!
        #expect(URLSessionTransport.mapError(URLError(.cancelled), url: url).code == .cancelled)
        #expect(URLSessionTransport.mapError(CancellationError(), url: url).code == .cancelled)
        #expect(URLSessionTransport.mapError(URLError(.networkConnectionLost), url: url).code == .transport)
        #expect(URLSessionTransport.mapError(CapsuleerError(.storage), url: url).code == .storage)
    }
}

@Suite struct UserAgentTests {
    @Test func headerValueWithContact() throws {
        let ua = UserAgent(product: "MyApp", version: "1.0", contact: "+https://example.com")
        let pattern = #/^MyApp/1\.0 \(\+https://example\.com\) CapsuleerKit/(\d+\.\d+\.\d+) (macOS|iOS)/\d+\.\d+$/#
        let match = try #require(ua.headerValue.wholeMatch(of: pattern))
        #expect(String(match.1) == CapsuleerKitInfo.version)
    }

    @Test(arguments: [nil, ""] as [String?])
    func headerValueWithoutContact(contact: String?) {
        let ua = UserAgent(product: "MyApp", version: "1.0", contact: contact)
        #expect(ua.headerValue.hasPrefix("MyApp/1.0 CapsuleerKit/\(CapsuleerKitInfo.version) "))
        #expect(!ua.headerValue.contains("("))
    }
}
