#if canImport(AuthenticationServices)
import AuthenticationServices
import CapsuleerCore
import Foundation

/// Runs the SSO login in `ASWebAuthenticationSession`, with an ephemeral browser session so each
/// login can pick a different character. For custom-scheme callbacks (`overseer://sso-callback`).
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
        let runner = await WebAuthenticationRunner(presentationAnchor: presentationAnchor)
        return try await withTaskCancellationHandler {
            try await runner.run(url: authorizeURL, callbackScheme: scheme)
        } onCancel: {
            Task { @MainActor in runner.cancel() }
        }
    }
}

/// Owns one `ASWebAuthenticationSession` (kept alive until it completes) and its continuation.
@MainActor
private final class WebAuthenticationRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let presentationAnchor: WebAuthenticationSession.PresentationAnchorProvider
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var isCancelled = false

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
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                // ASWebAuthenticationSession calls back on the main queue.
                MainActor.assumeIsolated { self?.complete(callback, error) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                complete(nil, CapsuleerError(.ssoFailed, message: "ASWebAuthenticationSession did not start"))
            }
        }
    }

    func cancel() {
        isCancelled = true
        session?.cancel()
        complete(nil, CapsuleerError(.cancelled, message: "Login cancelled"))
    }

    private func complete(_ callback: URL?, _ error: (any Error)?) {
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
        MainActor.assumeIsolated { presentationAnchor() }
    }
}
#endif
