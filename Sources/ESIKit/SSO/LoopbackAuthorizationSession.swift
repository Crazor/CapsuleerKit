#if canImport(Network)
import CapsuleerCore
import Foundation
import Network
import os

/// Receives the SSO redirect on a one-shot HTTP listener on `127.0.0.1:<port>`, for command-line
/// tools. The callback URL must be `http://127.0.0.1:<port>/<path>` (or `localhost`) and registered
/// for the app at developers.eveonline.com.
///
/// `start` binds the port, then opens the authorize URL with `openURL` (default: prints it to
/// stderr; a CLI may run `/usr/bin/open`), waits for `GET <path>?…`, answers with a short page
/// and returns the full callback URL. Other paths (e.g. `/favicon.ico`) get a 404 and the
/// listener keeps waiting. Throws `.ssoFailed` on timeout or if the port can't be bound, and
/// `.cancelled` when the task is cancelled.
public struct LoopbackAuthorizationSession: AuthorizationSession {
    public typealias OpenURL = @Sendable (URL) async throws -> Void

    public var port: UInt16
    public var timeout: Duration
    public var openURL: OpenURL

    public init(port: UInt16, timeout: Duration = .seconds(300), openURL: @escaping OpenURL = LoopbackAuthorizationSession.printToStandardError) {
        self.port = port
        self.timeout = timeout
        self.openURL = openURL
    }

    /// Prints the authorize URL to stderr for the user to open.
    public static let printToStandardError: OpenURL = { url in
        FileHandle.standardError.write(Data("Open this URL in a browser to log in:\n\(url.absoluteString)\n".utf8))
    }

    public func start(authorizeURL: URL, callbackURL: URL) async throws -> URL {
        guard callbackURL.scheme?.lowercased() == "http",
              let host = callbackURL.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              callbackURL.port.map({ $0 == Int(port) }) ?? false else {
            throw CapsuleerError(.ssoFailed, message: "Callback URL must be http://127.0.0.1:\(port)/…")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw CapsuleerError(.ssoFailed, message: "Invalid loopback port \(port)")
        }
        let path = callbackURL.path.isEmpty ? "/" : callbackURL.path
        let server = LoopbackServer(port: nwPort, path: path, callbackBase: callbackURL)
        let timeout = self.timeout
        let openURL = self.openURL

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: URL.self) { group in
                group.addTask {
                    try await server.waitUntilReady()
                    try await openURL(authorizeURL)
                    return try await server.callback()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CapsuleerError(.ssoFailed, message: "Timed out waiting for the SSO redirect")
                }
                defer {
                    group.cancelAll()
                    server.stop()
                }
                do {
                    guard let url = try await group.next() else {
                        throw CapsuleerError(.ssoFailed, message: "Loopback session ended without a callback")
                    }
                    return url
                } catch is CancellationError {
                    throw CapsuleerError(.cancelled, message: "Login cancelled", underlying: CancellationError())
                }
            }
        } onCancel: {
            server.stop(error: CapsuleerError(.cancelled, message: "Login cancelled"))
        }
    }
}

/// The listener plus its two one-shot results (ready, callback). NWListener/NWConnection
/// callbacks run on `queue`; the mutable state is guarded by `state`'s lock.
private final class LoopbackServer: Sendable {
    private struct State {
        var started = false
        var finished = false
        var isReady = false
        var readyError: CapsuleerError?
        var readyWaiters: [CheckedContinuation<Void, any Error>] = []
        var result: Result<URL, CapsuleerError>?
        var resultWaiters: [CheckedContinuation<URL, any Error>] = []
    }

    private let port: NWEndpoint.Port
    private let path: String
    private let callbackBase: URL
    private let queue = DispatchQueue(label: "CapsuleerKit.LoopbackAuthorizationSession")
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// NWListener is only `Sendable` from macOS 14. It is created, started and cancelled through
    /// this lock and otherwise only touched by Network.framework on `queue`, so the unchecked
    /// lock state is safe on macOS 13 too.
    private let listener = OSAllocatedUnfairLock<NWListener?>(uncheckedState: nil)

    init(port: NWEndpoint.Port, path: String, callbackBase: URL) {
        self.port = port
        self.path = path
        self.callbackBase = callbackBase
    }

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let action: Result<Void, CapsuleerError>? = state.withLock { state in
                if let error = state.readyError ?? state.result?.failure { return .failure(error) }
                if state.isReady { return .success(()) }
                state.readyWaiters.append(continuation)
                return nil
            }
            if let action { continuation.resume(with: action) } else { startIfNeeded() }
        }
    }

    func callback() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let result: Result<URL, CapsuleerError>? = state.withLock { state in
                if let result = state.result { return result }
                state.resultWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func stop(error: CapsuleerError = CapsuleerError(.cancelled, message: "Loopback listener stopped")) {
        finish(.failure(error))
    }

    private func startIfNeeded() {
        let shouldStart = state.withLock { state in
            defer { state.started = true }
            return !state.started && !state.finished
        }
        guard shouldStart else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            let listener = try NWListener(using: parameters)
            self.listener.withLockUnchecked { $0 = listener }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            finish(.failure(CapsuleerError(.ssoFailed, message: "Could not listen on 127.0.0.1:\(port.rawValue)", underlying: error)))
        }
    }

    private func listenerStateChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
                state.isReady = true
                defer { state.readyWaiters = [] }
                return state.readyWaiters
            }
            waiters.forEach { $0.resume() }
        case .failed(let error), .waiting(let error):
            finish(.failure(CapsuleerError(.ssoFailed, message: "Could not listen on 127.0.0.1:\(port.rawValue): \(error)", underlying: error)))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let target = URLComponents(string: String(parts[1])), target.path == path else {
            respond(on: connection, status: "404 Not Found", body: "Not found")
            return
        }
        var components = URLComponents(url: callbackBase, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = target.percentEncodedQuery
        guard let url = components?.url else {
            respond(on: connection, status: "400 Bad Request", body: "Bad request")
            return
        }
        respond(on: connection, status: "200 OK", body: "<!doctype html><html><head><meta charset=\"utf-8\"><title>EVE SSO</title></head><body><p>Login received. You can close this window.</p></body></html>") { [weak self] in
            self?.finish(.success(url))
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String, then completion: (@Sendable () -> Void)? = nil) {
        let bytes = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func finish(_ result: Result<URL, CapsuleerError>) {
        let (readyWaiters, resultWaiters): ([CheckedContinuation<Void, any Error>], [CheckedContinuation<URL, any Error>]) = state.withLock { state in
            guard !state.finished else { return ([], []) }
            state.finished = true
            state.started = true
            state.result = result
            if case .failure(let error) = result, !state.isReady { state.readyError = error }
            defer { state.readyWaiters = []; state.resultWaiters = [] }
            return (state.readyWaiters, state.resultWaiters)
        }
        let listener = self.listener.withLockUnchecked { listener -> NWListener? in
            defer { listener = nil }
            return listener
        }
        listener?.cancel()
        for waiter in readyWaiters {
            if case .failure(let error) = result { waiter.resume(throwing: error) } else { waiter.resume() }
        }
        for waiter in resultWaiters { waiter.resume(with: result.mapError { $0 as any Error }) }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
#endif
