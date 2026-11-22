import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
/// The platform's image type: `NSImage` on macOS, `UIImage` on iOS and Mac Catalyst.
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst) || canImport(UIKit)
extension Response where Value == Data {
    /// The data decoded as an `NSImage` / `UIImage`, or nil if it isn't an image.
    public var platformImage: PlatformImage? { PlatformImage(data: value) }
}

extension EVEImageClient {
    /// The portrait as an `NSImage` (macOS) or `UIImage` (iOS). Throws `.decoding` if the server's
    /// data isn't an image. Use `characterPortrait(_:size:policy:)` for the data and cache metadata.
    public func characterPortraitImage(_ characterID: Int64, size: EVEImages.PortraitSize = .px128,
                                       policy: CachePolicy = .useProtocolCachePolicy) async throws -> sending PlatformImage {
        let response = try await characterPortrait(characterID, size: size, policy: policy)
        guard let image = PlatformImage(data: response.value) else {
            throw CapsuleerError(.decoding, message: "Portrait for character \(characterID) is not an image",
                                 url: EVEImages.characterPortrait(characterID, size: size, baseURL: configuration.baseURL))
        }
        return image
    }
}
#endif

#if canImport(SwiftUI) && (canImport(AppKit) && !targetEnvironment(macCatalyst) || canImport(UIKit))
import SwiftUI

extension Image {
    /// A SwiftUI image from an `NSImage` / `UIImage`, e.g. a portrait from `EVEImageClient`.
    public init(platformImage: PlatformImage) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
#endif
