import CapsuleerCore
import Foundation
import OpenAPIRuntime

extension Components.Parameters.CompatibilityDate {
    /// The case for `ESI.compatibilityDate`. The pipeline sets the header from `ESI.compatibilityDate`
    /// anyway; a test checks that the constant and the generated enum agree.
    static var pinned: Self { Self(rawValue: ESI.compatibilityDate) ?? allCases[0] }
}

extension ESIClient {
    /// The generated client's runtime configuration.
    static let openAPIConfiguration = OpenAPIRuntime.Configuration(dateTranscoder: ESIDateTranscoder(), jsonEncodingOptions: [.sortedKeys])

    /// Runs `call` on a generated `Client` whose transport carries `context`, and returns its
    /// value with the pipeline's cache metadata. Errors come out as `CapsuleerError`: pipeline
    /// errors unchanged, generated-client failures (decoding, unexpected status) mapped.
    func send<Value: Sendable>(
        _ operation: OperationMetadata, context: ESICallContext,
        _ call: (Client) async throws -> Value
    ) async throws -> Response<Value> {
        let recorder = ESIResponseRecorder()
        let api = Client(serverURL: ESI.baseURL, configuration: Self.openAPIConfiguration,
                         transport: PipelineClientTransport(http: http, context: context, recorder: recorder))
        let value: Value
        do {
            value = try await call(api)
        } catch {
            throw Self.map(error, operation: operation)
        }
        guard let response = await recorder.response else {
            throw CapsuleerError(.invalidResponse, message: "\(operation.operationID): no response recorded")
        }
        return response.map { _ in value }
    }

    /// A public call (`.public` identity, no token).
    func publicCall<Value: Sendable>(
        _ operation: OperationMetadata, policy: CachePolicy = .useProtocolCachePolicy,
        _ call: (Client) async throws -> Value
    ) async throws -> Response<Value> {
        try await send(operation, context: ESICallContext(identity: .public, policy: policy, accessToken: nil), call)
    }

    /// An authenticated call as `characterID`: token from `tokenProvider` for the operation's
    /// required scopes, `.character` identity. A 401 invalidates the token and retries once
    /// with a new one. If the new token gets a 401 too, the character cools down for
    /// `configuration.unauthorizedCooldown`: until then, or until one of its calls succeeds,
    /// 401s are thrown without invalidating, refreshing or retrying. Without a provider, throws
    /// `.notAuthenticated` before any request.
    func authenticatedCall<Value: Sendable>(
        _ operation: OperationMetadata, as characterID: Int64, policy: CachePolicy,
        _ call: (Client) async throws -> Value
    ) async throws -> Response<Value> {
        guard let provider = configuration.tokenProvider else {
            throw CapsuleerError(.notAuthenticated, message: "\(operation.operationID) needs a token provider (ESIConfiguration.tokenProvider)")
        }
        let token = try await provider.accessToken(for: characterID, requiredScopes: operation.requiredScopes)
        let context = ESICallContext(identity: .character(characterID), policy: policy, accessToken: token)
        do {
            let response = try await send(operation, context: context, call)
            await unauthorizedCooldown.clear(for: characterID)
            return response
        } catch let error as CapsuleerError where error.status == 401 {
            if await unauthorizedCooldown.isActive(for: characterID, now: configuration.timeSource.now()) { throw error }
            await provider.invalidate(accessToken: token, for: characterID)
            var retry = context
            retry.accessToken = try await provider.accessToken(for: characterID, requiredScopes: operation.requiredScopes)
            do {
                let response = try await send(operation, context: retry, call)
                await unauthorizedCooldown.clear(for: characterID)
                return response
            } catch let error as CapsuleerError where error.status == 401 {
                await unauthorizedCooldown.start(for: characterID, now: configuration.timeSource.now(),
                                                 duration: configuration.unauthorizedCooldown)
                configuration.logSink.log(.warning, .sso, "ESI rejected a freshly refreshed token; not refreshing on 401 during cooldown",
                                          metadata: ["operation": operation.operationID,
                                                     "cooldown": "\(configuration.unauthorizedCooldown.components.seconds) s"],
                                          privateMetadata: ["characterID": String(characterID)])
                throw error
            }
        }
    }

    static func map(_ error: any Error, operation: OperationMetadata) -> CapsuleerError {
        if let error = error as? CapsuleerError { return error }
        if let error = error as? ClientError {
            if let underlying = error.underlyingError as? CapsuleerError { return underlying }
            let code: CapsuleerError.Code = error.underlyingError is DecodingError ? .decoding : .invalidResponse
            return CapsuleerError(code, status: error.response?.status.code,
                                  message: "\(operation.operationID): \(error.causeDescription): \(error.underlyingError)",
                                  url: error.baseURL.flatMap { base in error.request?.path.flatMap { URL(string: base.absoluteString + $0) } },
                                  underlying: error.underlyingError)
        }
        if error is CancellationError { return CapsuleerError(.cancelled, underlying: error) }
        // E.g. the `.ok` accessor on an unexpected 2XX output.
        return CapsuleerError(.invalidResponse, message: "\(operation.operationID): \(error)", underlying: error)
    }
}

extension Array where Element: Hashable {
    /// The elements in order, without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
