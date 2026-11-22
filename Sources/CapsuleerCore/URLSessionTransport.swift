import Foundation

/// Default transport: its own ephemeral URLSession with URLCache disabled (all caching is ours),
/// `Accept-Encoding: gzip`, redirects followed. Transport failures throw `CapsuleerError(.transport)`;
/// cancellation throws `CapsuleerError(.cancelled)`.
///
/// The session never stores cookies or credentials-derived state, and never answers from a local
/// cache. Non-2xx responses are returned, not thrown.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Creates a transport on a fresh ephemeral session.
    /// - Parameter timeout: the request timeout in seconds (the longest time without any data).
    public convenience init(timeout: TimeInterval = 30) {
        self.init(configuration: .ephemeral, timeout: timeout)
    }

    /// Creates a transport from `configuration`, for example to register `URLProtocol` classes in
    /// tests or to route through a proxy. The configuration is copied, then caching and cookies
    /// are switched off and `timeout` is applied, so the transport's guarantees hold whatever is passed.
    public init(configuration: URLSessionConfiguration, timeout: TimeInterval = 30) {
        // `copy()` on URLSessionConfiguration always returns a URLSessionConfiguration.
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if Task.isCancelled {
            throw CapsuleerError(.cancelled, url: request.url, underlying: CancellationError())
        }

        let urlRequest = Self.makeURLRequest(request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.mapError(error, url: request.url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CapsuleerError(.invalidResponse, message: "Not an HTTP response", url: response.url ?? request.url)
        }
        return HTTPResponse(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: data,
            url: http.url ?? request.url
        )
    }

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        for field in request.headers {
            urlRequest.setValue(field.value, forHTTPHeaderField: field.name)
        }
        if request.headers["Accept-Encoding"] == nil {
            urlRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    /// All header fields of `response`, sorted by name so the result is deterministic.
    static func headers(of response: HTTPURLResponse) -> HTTPHeaders {
        let pairs: [(String, String)] = response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name, (value as? String) ?? String(describing: value))
        }
        return HTTPHeaders(pairs.sorted { $0.0.lowercased() < $1.0.lowercased() })
    }

    static func mapError(_ error: any Error, url: URL) -> CapsuleerError {
        if let error = error as? CapsuleerError { return error }
        if error is CancellationError {
            return CapsuleerError(.cancelled, url: url, underlying: error)
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return CapsuleerError(.cancelled, url: url, underlying: urlError)
            }
            return CapsuleerError(.transport, message: urlError.localizedDescription, url: url, underlying: urlError)
        }
        return CapsuleerError(.transport, message: String(describing: error), url: url, underlying: error)
    }
}
