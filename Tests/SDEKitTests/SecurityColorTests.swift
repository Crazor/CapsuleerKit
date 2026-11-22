import CapsuleerCore
import Testing
@testable import SDEKit

@Suite struct SecurityColorTests {
    @Test(arguments: [
        (1.0, "#5089E2"), (0.946, "#65A9E9"), (0.8, "#83D3F4"), (0.7, "#90DCB5"), (0.6, "#9DE47B"),
        (0.4609, "#F6FBA3"), (0.4, "#D78539"), (0.3, "#CB6331"), (0.2, "#BB3C2D"),
        (0.0346, "#7E352E"), (0.0583, "#7E352E"), (0.0, "#954C75"), (-0.0184, "#954C75"), (-1.0, "#954C75"),
    ])
    func colourPerDisplayedTenth(value: Double, hex: String) {
        #expect(SecurityStatus(value: value, regionID: 10000002).displayColor.hex == hex)
    }

    @Test func unmeasuredSpaceUsesItsDisplayedValue() {
        #expect(SecurityStatus(value: -0.99, regionID: 11000031).displayColor.hex == "#954C75")  // Thera
        #expect(SecurityStatus(value: -1.0, regionID: 10000070).displayColor.hex == "#954C75")   // Pochven
    }

    @Test func tenthsAreClamped() {
        #expect(SecurityStatus.displayColor(forTenths: 12) == SecurityStatus.displayColor(forTenths: 10))
        #expect(SecurityStatus.displayColor(forTenths: -5) == SecurityStatus.displayColor(forTenths: 0))
    }

    @Test func rgbColorHexRoundTrip() throws {
        let color = try #require(RGBColor(hex: "#f6fba3"))
        #expect(color == RGBColor(red: 0xF6, green: 0xFB, blue: 0xA3))
        #expect(color.hex == "#F6FBA3")
        #expect(RGBColor(hex: "5089E2")?.hex == "#5089E2")
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "#GG0000") == nil)
        #expect(abs(color.redComponent - 246.0 / 255) < 1e-12)
    }
}
