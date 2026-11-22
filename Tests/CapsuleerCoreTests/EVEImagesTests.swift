import AppKit
import CapsuleerCore
import CapsuleerKitTesting
import Foundation
import SwiftUI
import Testing

@Suite struct EVEImagesTests {
    /// A real PNG, generated so the tests need no image fixture.
    static let pngData: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    static let userAgent = UserAgent(product: "Test", version: "1")

    @Test(arguments: EVEImages.PortraitSize.allCases)
    func portraitURL(size: EVEImages.PortraitSize) {
        #expect(EVEImages.characterPortrait(2114249386, size: size).absoluteString
                == "https://images.evetech.net/characters/2114249386/portrait?size=\(size.rawValue)")
    }

    @Test func downloadsThroughTheCacheWithUserAgent() async throws {
        let time = ManualTimeSource()
        let transport = MockTransport()
        let url = EVEImages.characterPortrait(42, size: .px128)
        transport.enqueue(status: 200, headers: ["Content-Type": "image/png", "Cache-Control": "max-age=3600", "ETag": "\"a\""],
                          body: Self.pngData, url: url)
        let client = EVEImageClient(configuration: .init(userAgent: Self.userAgent, cache: MemoryCacheStore(), transport: transport, timeSource: time))

        let first = try await client.characterPortrait(42)
        #expect(first.value == Self.pngData)
        #expect(first.source == .network)
        #expect(transport.requests.first?.headers["User-Agent"]?.hasPrefix("Test/1") == true)

        let second = try await client.characterPortrait(42)
        #expect(second.source == .cache)
        #expect(transport.requests.count == 1)

        // After expiry the network is down: the cached portrait is served stale.
        time.advance(by: 3700)
        transport.enqueue(error: CapsuleerError(.transport, message: "offline"))
        let offline = try await client.characterPortrait(42)
        #expect(offline.isStale)
        #expect(offline.value == Self.pngData)
    }

    @Test func decodesPlatformAndSwiftUIImages() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 200, headers: ["Content-Type": "image/png"], body: Self.pngData, url: EVEImages.characterPortrait(7, size: .px64))
        let client = EVEImageClient(configuration: .init(userAgent: Self.userAgent, transport: transport))
        let image = try await client.characterPortraitImage(7, size: .px64)
        #expect(image.size.width == 4)
        _ = Image(platformImage: image)
        let response = Response(value: Self.pngData, source: .network, expires: nil, lastModified: nil, etag: nil, isStale: false)
        #expect(response.platformImage != nil)
    }

    @Test func nonImageDataThrowsDecoding() async {
        let transport = MockTransport()
        transport.enqueue(status: 200, headers: ["Content-Type": "text/plain"], body: Data("nope".utf8), url: EVEImages.characterPortrait(7))
        let client = EVEImageClient(configuration: .init(userAgent: Self.userAgent, transport: transport))
        let error = await #expect(throws: CapsuleerError.self) { _ = try await client.characterPortraitImage(7) }
        #expect(error?.code == .decoding)
    }
}
