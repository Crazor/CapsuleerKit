import CapsuleerCore
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Per-call context that the facade hands to `PipelineClientTransport`, so the generated client
/// never needs to know about identities, cache policies or tokens.
struct ESICallContext: Sendable {
    /// Whose data this is: `.public`, or `.character(id)` for authenticated calls.
    var identity: CacheIdentity
    var policy: CachePolicy
    /// Bearer token for authenticated calls.
    var accessToken: String?
}

/// Receives the pipeline's `Response` (source, expiry, validators) for the one request a
/// per-call client sends, since the generated `Output` types carry only status, headers and body.
actor ESIResponseRecorder {
    private(set) var response: Response<CapsuleerCore.HTTPResponse>?

    func record(_ response: Response<CapsuleerCore.HTTPResponse>) { self.response = response }
}

/// An OpenAPIRuntime `ClientTransport` that sends the generated client's requests through the
/// CapsuleerCore pipeline (`HTTPClient`: User-Agent, cache, coalescing; below it
/// `ESIEtiquetteTransport`), so the OpenAPI runtime never sees caching or rate limits.
///
/// It adds the `ESIRequestHints` headers from `OperationMetadata`, the bearer token from the
/// context, and passes `X-Compatibility-Date` (and `Accept-Language`, when the request has one)
/// as cache variant. Pipeline errors are thrown unchanged (wrapped by the runtime in
/// `ClientError`, which the facade unwraps).
struct PipelineClientTransport: ClientTransport {
    let http: HTTPClient
    let context: ESICallContext
    let recorder: ESIResponseRecorder

    /// Upper bound for request bodies collected from the runtime (lookup POSTs are a few KB).
    static let maxRequestBodyBytes = 1 << 20

    func send(_ request: HTTPTypes.HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
        async throws -> (HTTPTypes.HTTPResponse, HTTPBody?)
    {
        let pipelineRequest = try await Self.makeRequest(request, body: body, baseURL: baseURL,
                                                         metadata: OperationMetadata[operationID], context: context)
        var variant = ["X-Compatibility-Date": ESI.compatibilityDate]
        if let language = request.headerFields[.acceptLanguage] { variant["Accept-Language"] = language }

        let response = try await http.send(pipelineRequest, identity: context.identity,
                                           variant: variant, policy: context.policy)
        await recorder.record(response)

        var fields = HTTPFields()
        for field in response.value.headers {
            guard let name = HTTPField.Name(field.name) else { continue }
            fields.append(HTTPField(name: name, value: field.value))
        }
        let status = HTTPTypes.HTTPResponse.Status(code: response.value.status)
        return (HTTPTypes.HTTPResponse(status: status, headerFields: fields), HTTPBody(response.value.body))
    }

    /// The pipeline request for one generated request. Separate from `send` for testing.
    static func makeRequest(_ request: HTTPTypes.HTTPRequest, body: HTTPBody?, baseURL: URL,
                            metadata: OperationMetadata?, context: ESICallContext) async throws -> CapsuleerCore.HTTPRequest {
        let method: CapsuleerCore.HTTPMethod
        switch request.method {
        case .get: method = .get
        case .post: method = .post
        case .head: method = .head
        default:
            throw CapsuleerError(.invalidResponse, message: "Unsupported HTTP method \(request.method.rawValue)")
        }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + (request.path ?? "")) else {
            throw CapsuleerError(.invalidResponse, message: "Invalid request path \(request.path ?? "")")
        }

        var headers = HTTPHeaders()
        for field in request.headerFields where field.name != .acceptLanguage {
            // Several values for one name are joined, as HTTP allows for list-valued fields.
            if let existing = headers[field.name.rawName] {
                headers[field.name.rawName] = existing + ", " + field.value
            } else {
                headers[field.name.rawName] = field.value
            }
        }
        headers["X-Compatibility-Date"] = ESI.compatibilityDate
        if let token = context.accessToken { headers["Authorization"] = "Bearer \(token)" }
        if let metadata {
            for (name, value) in metadata.hintHeaders(identity: context.identity) { headers[name] = value }
        }

        let data: Data? = if let body {
            try await Data(collecting: body, upTo: maxRequestBodyBytes)
        } else {
            nil
        }
        return CapsuleerCore.HTTPRequest(method: method, url: url, headers: headers, body: data)
    }
}

extension OperationMetadata {
    /// POSTs that ESI documents as lookups, safe to retry like GETs.
    static let idempotentPOSTs: Set<String> = ["PostUniverseNames", "PostUniverseIds"]

    /// True when the etiquette layer may retry the request after 5XX or network errors.
    var isIdempotent: Bool { method == .get || method == .head || Self.idempotentPOSTs.contains(operationID) }

    /// The `ESIRequestHints` headers for a request of this operation as `identity`.
    func hintHeaders(identity: CacheIdentity) -> [(String, String)] {
        var headers = [(ESIRequestHints.identity, identity.rawValue)]
        if let rateLimit {
            headers.append((ESIRequestHints.rateLimitGroup, rateLimit.group))
            headers.append((ESIRequestHints.rateLimitWindow, rateLimit.window))
        }
        if isIdempotent { headers.append((ESIRequestHints.idempotent, "1")) }
        return headers
    }
}
