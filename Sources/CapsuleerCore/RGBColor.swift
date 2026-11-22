import Foundation

/// An sRGB colour with 8-bit channels. Independent of any UI framework; see the SwiftUI
/// convenience `Color(_:)` where SwiftUI is available.
public struct RGBColor: Sendable, Hashable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` or `RRGGBB` (case-insensitive). Returns nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// `#RRGGBB`, upper-case.
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// Channels as 0...1, for APIs that take floating-point components.
    public var redComponent: Double { Double(red) / 255 }
    public var greenComponent: Double { Double(green) / 255 }
    public var blueComponent: Double { Double(blue) / 255 }

    public var description: String { hex }
}

#if canImport(SwiftUI)
import SwiftUI

extension Color {
    /// The sRGB colour `rgb`, fully opaque.
    public init(_ rgb: RGBColor) {
        self.init(.sRGB, red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, opacity: 1)
    }
}
#endif
