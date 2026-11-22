import Darwin
import Foundation
import Testing
import CapsuleerCore
@testable import ESIKit

/// Asks the OS for a free TCP port on 127.0.0.1.
private func freeLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CapsuleerError(.transport, message: "socket() failed") }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    guard bound else { throw CapsuleerError(.transport, message: "bind() failed: \(errno)") }
    return UInt16(bigEndian: address.sin_port)
}

@Suite(.serialized) struct SSOLoopbackSessionTests {
    @Test func receivesTheCallbackEndToEnd() async throws {
        let port = try freeLoopbackPort()
        let callbackURL = URL(string: "http://127.0.0.1:\(port)/callback")!
        let pageBody = SSOLocked<String>("")
        let favicon = SSOLocked<Int>(0)
        let session = LoopbackAuthorizationSession(port: port, timeout: .seconds(10)) { authorizeURL in
            #expect(authorizeURL.absoluteString == "https://login.eveonline.com/v2/oauth/authorize?state=abc")
            // Play the browser: a stray request first, then the redirect.
            let urlSession = URLSession(configuration: .ephemeral)
            Task {
                let (_, stray) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
                favicon.set((stray as? HTTPURLResponse)?.statusCode ?? 0)
                let (data, response) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=the%20code&state=abc")!)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                pageBody.set(String(decoding: data, as: UTF8.self))
            }
        }
        let url = try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/v2/oauth/authorize?state=abc")!,
                                          callbackURL: callbackURL)
        #expect(url.absoluteString == "http://127.0.0.1:\(port)/callback?code=the%20code&state=abc")
        #expect(SSOClient.matches(url, callbackURL))
        // Give the browser task a moment to read the page.
        for _ in 0..<100 where pageBody.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pageBody.value.contains("You can close this window"))
        #expect(favicon.value == 404)
    }

    @Test func ignoresACallbackFromAnotherLoginAttempt() async throws {
        let port = try freeLoopbackPort()
        let strayStatus = SSOLocked<Int>(0)
        let session = LoopbackAuthorizationSession(port: port, timeout: .seconds(10)) { _ in
            let urlSession = URLSession(configuration: .ephemeral)
            Task {
                // An old tab replays the previous attempt's redirect first.
                let (_, stray) = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=old&state=previous")!)
                strayStatus.set((stray as? HTTPURLResponse)?.statusCode ?? 0)
                _ = try await urlSession.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=new&state=current")!)
            }
        }
        let url = try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/v2/oauth/authorize?state=current")!,
                                          callbackURL: URL(string: "http://127.0.0.1:\(port)/callback")!)
        #expect(url.query == "code=new&state=current")
        #expect(strayStatus.value == 409)
    }

    @Test func timesOut() async throws {
        let port = try freeLoopbackPort()
        let session = LoopbackAuthorizationSession(port: port, timeout: .milliseconds(200)) { _ in }
        let error = await #expect(throws: CapsuleerError.self) {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "http://127.0.0.1:\(port)/callback")!)
        }
        #expect(error?.code == .ssoFailed)
        // The port is released afterwards: a second session can bind it and receive a callback.
        let again = LoopbackAuthorizationSession(port: port, timeout: .seconds(10)) { _ in
            Task { _ = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=c&state=s")!) }
        }
        let url = try await again.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                        callbackURL: URL(string: "http://127.0.0.1:\(port)/callback")!)
        #expect(url.query == "code=c&state=s")
    }

    @Test func rejectsANonLoopbackCallback() async {
        let session = LoopbackAuthorizationSession(port: 8635) { _ in Issue.record("must not open the browser") }
        await #expect(throws: CapsuleerError.self) {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "eveauth-overseer://callback")!)
        }
        await #expect(throws: CapsuleerError.self) {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "http://127.0.0.1:9999/callback")!)
        }
    }

    @Test func cancellationStopsTheListener() async throws {
        let port = try freeLoopbackPort()
        let session = LoopbackAuthorizationSession(port: port, timeout: .seconds(30)) { _ in }
        let task = Task {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "http://127.0.0.1:\(port)/callback")!)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CapsuleerError.self) { try result.get() }
    }
}

#if canImport(AuthenticationServices) && canImport(AppKit)
import AppKit
@Suite struct SSOWebAuthenticationSessionTests {
    @MainActor @Test func rejectsSchemesEVEDoesNotAccept() async {
        let session = WebAuthenticationSession { NSWindow() }
        let error = await #expect(throws: CapsuleerError.self) {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "overseer://sso-callback")!)
        }
        #expect(error?.code == .ssoFailed)
        #expect(error?.message?.contains("eveauth") == true)
    }

    @Test(arguments: [
        ("eveauth-overseer://callback", true), ("eveauth://callback", true), ("eveauth.my+app-2://x", true),
        ("https://example.com/callback", true), ("http://127.0.0.1:8635/callback", true), ("http://localhost:8080/cb", true),
        ("overseer://sso-callback", false), ("eveauth-://callback", false), ("eveauth-app.://callback", false),
        ("eveauthApp://callback", false), ("http://example.com/callback", false), ("myeveauth://x", false),
    ])
    func callbackURLsEVEAccepts(url: String, accepted: Bool) throws {
        #expect(SSOConfiguration.isAcceptedCallbackURL(try #require(URL(string: url))) == accepted)
    }

    @MainActor @Test func rejectsHTTPCallbacks() async {
        let session = WebAuthenticationSession { NSWindow() }
        let error = await #expect(throws: CapsuleerError.self) {
            try await session.start(authorizeURL: URL(string: "https://login.eveonline.com/")!,
                                    callbackURL: URL(string: "http://127.0.0.1:8635/callback")!)
        }
        #expect(error?.code == .ssoFailed)
    }
}
#endif
