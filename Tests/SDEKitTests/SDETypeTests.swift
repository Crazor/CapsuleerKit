import CapsuleerCore
import CapsuleerKitTesting
import Foundation
import Testing
@testable import SDEKit

@Suite struct SDETypeTests {
    @Test func decodesTypeRecord() throws {
        let url = try #require(Bundle.module.url(forResource: "types-587", withExtension: "json", subdirectory: "Fixtures"))
        let type = try JSONDecoder().decode(SDEType.self, from: Data(contentsOf: url))
        #expect(type.id == 587)
        #expect(type.name.en == "Rifter")
        #expect(type.groupID == 25)
        #expect(type.published)
        #expect(type.factionID == 500002)
    }
}
