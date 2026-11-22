#if canImport(AuthenticationServices)
import AuthenticationServices
import CapsuleerCore
import Foundation

/// Runs the SSO login in `ASWebAuthenticationSession`, with an ephemeral browser session so each
/// login can pick a different character. For custom-scheme callbacks (`eveauth-overseer://callback`).
///
/// Create it on the main actor with a closure that returns the window to present from:
///
/// ```swift
/// @MainActor func login() async throws {
///     let session = WebAuthenticationSession { NSApp.keyWindow ?? NSWindow() }
///     try await tokens.authorize(using: session)
/// }
/// ```
///
/// `start` may be called from any isolation; it creates and starts the system session on the
/// main actor. Cancelling the calling task cancels the login (`.cancelled`).
public struct WebAuthenticationSession: AuthorizationSession {
    public typealias PresentationAnchorProvider = @MainActor @Sendable () -> ASPresentationAnchor

    private let presentationAnchor: PresentationAnchorProvider

    @MainActor
    public init(presentationAnchor: @escaping PresentationAnchorProvider) {
        self.presentationAnchor = presentationAnchor
    }

    public func start(authorizeURL: URL, callbackURL: URL) async throws -> URL {
        guard let scheme = callbackURL.scheme?.lowercased(), scheme != "http", scheme != "https" else {
            throw CapsuleerError(.ssoFailed, message: "WebAuthenticationSession needs a custom-scheme callback URL; use LoopbackAuthorizationSession for http callbacks")
        }
        guard let rawScheme = callbackURL.scheme, SSOConfiguration.isAcceptedCustomScheme(rawScheme) else {
            throw CapsuleerError(.ssoFailed, message: "EVE SSO only accepts custom callback schemes that start with \"eveauth\" (e.g. eveauth-myapp://callback); got \(callbackURL.scheme ?? "none")")
        }
        let runner = await WebAuthenticationRunner(presentationAnchor: presentationAnchor)
        return try await withTaskCancellationHandler {
            try await runner.run(url: authorizeURL, callbackScheme: scheme)
        } onCancel: {
            Task { @MainActor in runner.cancel() }
        }
    }
}

/// Owns one `ASWebAuthenticationSession` (kept alive until it completes) and its continuation.
///
/// `ASWebAuthenticationSession` does not reliably call back on the main thread: on its early
/// failure path (`_startDryRun:`) the completion arrives on an XPC reply queue (seen on macOS 15
/// in an LSUIElement app). Completions therefore hop to the main actor instead of assuming it,
/// and the presentation anchor is captured on the main actor before the session starts.
@MainActor
final class WebAuthenticationRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let presentationAnchor: WebAuthenticationSession.PresentationAnchorProvider
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var isCancelled = false
    /// Captured on the main actor in `run`; read by `presentationAnchor(for:)` from whatever
    /// thread the system calls it on. The window is only handed back to AuthenticationServices.
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    init(presentationAnchor: @escaping WebAuthenticationSession.PresentationAnchorProvider) {
        self.presentationAnchor = presentationAnchor
    }

    func run(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            guard !isCancelled else {
                continuation.resume(throwing: CapsuleerError(.cancelled, message: "Login cancelled"))
                return
            }
            self.continuation = continuation
            anchor = presentationAnchor()
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme,
                                                     completionHandler: makeCompletionHandler())
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                complete(nil, CapsuleerError(.ssoFailed, message: "ASWebAuthenticationSession did not start"))
            }
        }
    }

    /// The session's completion handler: safe to call on any thread or queue.
    nonisolated func makeCompletionHandler() -> @Sendable (URL?, (any Error)?) -> Void {
        { [weak self] callback, error in
            Task { @MainActor in self?.complete(callback, error) }
        }
    }

    func cancel() {
        isCancelled = true
        session?.cancel()
        complete(nil, CapsuleerError(.cancelled, message: "Login cancelled"))
    }

    func complete(_ callback: URL?, _ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        if let callback {
            continuation.resume(returning: callback)
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            continuation.resume(throwing: CapsuleerError(.cancelled, message: "Login cancelled", underlying: error))
        } else if let error = error as? CapsuleerError {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: CapsuleerError(.ssoFailed, message: "Web authentication failed", underlying: error))
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor }
        if Thread.isMainThread { return MainActor.assumeIsolated { presentationAnchor() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { presentationAnchor() } }
    }

    /// For tests: parks a continuation as `run` does, without starting a system session.
    func runForTesting() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// For tests: wait until a pending completion has been delivered.
    var hasPendingContinuation: Bool { continuation != nil }
}
#endif
