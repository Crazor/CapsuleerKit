import CapsuleerCore
import Testing
@testable import ESIKit

@Suite struct OperationMetadataTests {
    @Test func tableHasTheSevenFilteredOperations() {
        #expect(Set(OperationMetadata.all.keys) == [
            "GetCharactersDetail", "GetCharactersCharacterIdLocation", "GetCharactersCharacterIdShip",
            "GetCharactersCharacterIdOnline", "GetUniverseStructuresStructureId", "PostUniverseNames", "PostUniverseIds",
        ])
        for (id, metadata) in OperationMetadata.all { #expect(metadata.operationID == id) }
    }

    @Test func locationGroupOperations() throws {
        let expected: [(OperationMetadata, String, ESIScope, Int)] = [
            (.getCharactersCharacterIdLocation, "/characters/{character_id}/location", .locationRead, 5),
            (.getCharactersCharacterIdShip, "/characters/{character_id}/ship", .shipTypeRead, 5),
            (.getCharactersCharacterIdOnline, "/characters/{character_id}/online", .onlineRead, 60),
        ]
        for (metadata, path, scope, ttl) in expected {
            #expect(metadata.method == .get)
            #expect(metadata.pathTemplate == path)
            #expect(metadata.requiredScopes == [scope])
            let rateLimit = try #require(metadata.rateLimit)
            #expect(rateLimit.group == "char-location")
            #expect(rateLimit.maxTokens == 1200)
            #expect(rateLimit.windowSize == "15m")
            #expect(rateLimit.window == "1200/15m")
            #expect(metadata.clientCacheTTL == ttl)
            #expect(metadata.isIdempotent)
        }
    }

    @Test func publicAndStructureOperations() {
        let detail = OperationMetadata.getCharactersDetail
        #expect(detail.method == .get)
        #expect(detail.pathTemplate == "/characters/{character_id}")
        #expect(detail.requiredScopes.isEmpty)
        #expect(detail.rateLimit == nil)
        #expect(detail.clientCacheTTL == 86400)

        let structure = OperationMetadata.getUniverseStructuresStructureId
        #expect(structure.pathTemplate == "/universe/structures/{structure_id}")
        #expect(structure.requiredScopes == [.structuresRead])
        #expect(structure.clientCacheTTL == 3600)

        for lookup in [OperationMetadata.postUniverseNames, .postUniverseIds] {
            #expect(lookup.method == .post)
            #expect(lookup.requiredScopes.isEmpty)
            #expect(lookup.clientCacheTTL == nil)
            #expect(lookup.isIdempotent)
        }
        #expect(OperationMetadata.postUniverseNames.pathTemplate == "/universe/names")
        #expect(OperationMetadata.postUniverseIds.pathTemplate == "/universe/ids")
        #expect(OperationMetadata["PostUniverseIds"] == .postUniverseIds)
        #expect(OperationMetadata["Nope"] == nil)
    }

    @Test func hintHeaders() {
        let location = Dictionary(uniqueKeysWithValues: OperationMetadata.getCharactersCharacterIdLocation.hintHeaders(identity: .character(7)))
        #expect(location == [
            ESIRequestHints.identity: "character:7",
            ESIRequestHints.rateLimitGroup: "char-location",
            ESIRequestHints.rateLimitWindow: "1200/15m",
            ESIRequestHints.idempotent: "1",
        ])
        let names = Dictionary(uniqueKeysWithValues: OperationMetadata.postUniverseNames.hintHeaders(identity: .public))
        #expect(names == [ESIRequestHints.identity: "public", ESIRequestHints.idempotent: "1"])
    }
}
