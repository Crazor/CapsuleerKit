import CapsuleerCore
import ESIKit
import Foundation
import Testing

private let env = ProcessInfo.processInfo.environment
private let isLive = env["CAPSULEER_LIVE"] == "1"
/// Authenticated tests need a character logged in with `capsuleer esi login` and:
/// CAPSULEER_LIVE_AUTH=1 CAPSULEER_CLIENT_ID=<id> CAPSULEER_CHARACTER_ID=<id>
/// CAPSULEER_TOKEN_FILE=<dir>/credentials.json (default: the CLI's data directory).
private let isLiveAuth = env["CAPSULEER_LIVE_AUTH"] == "1"

private let userAgent = UserAgent(product: "CapsuleerKit-LiveTests", version: CapsuleerKitInfo.version,
                                  contact: "+https://github.com/Crazor/CapsuleerKit")

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CapsuleerKit-ESILive-\(UUID().uuidString)", isDirectory: true)
}

@Suite("ESI public live", .enabled(if: isLive), .serialized)
struct ESIPublicLiveTests {
    let esi = ESIClient(configuration: ESIConfiguration(userAgent: userAgent, cacheDirectory: tempDirectory()))

    @Test func characterPublicInfo() async throws {
        let info = try await esi.character(2112625428).publicInfo()
        #expect(!info.value.name.isEmpty)
        #expect(info.value.corporationID > 0)
        #expect(info.expires != nil)
        let again = try await esi.character(2112625428).publicInfo()
        #expect(again.source == .cache)
    }

    @Test func stationName() async throws {
        let names = try await esi.universe.names([30000142, 60003760])
        #expect(names.contains { $0.id == 30000142 && $0.name == "Jita" && $0.category == .solarSystem })
        #expect(names.contains { $0.id == 60003760 && $0.category == .station && $0.name.hasPrefix("Jita IV - Moon 4") })
    }

    @Test func idsByName() async throws {
        let ids = try await esi.universe.ids(["Jita"])
        #expect(ids.contains { $0.id == 30000142 && $0.category == .solarSystem })
    }
}

@Suite("ESI authenticated live", .enabled(if: isLive && isLiveAuth), .serialized)
struct ESIAuthenticatedLiveTests {
    let characterID: Int64
    let esi: ESIClient
    let tokens: TokenManager

    init() throws {
        characterID = try #require(env["CAPSULEER_CHARACTER_ID"].flatMap(Int64.init), "Set CAPSULEER_CHARACTER_ID")
        let clientID = try #require(env["CAPSULEER_CLIENT_ID"], "Set CAPSULEER_CLIENT_ID")
        let tokenFile = env["CAPSULEER_TOKEN_FILE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CapsuleerKit-cli/credentials.json")
        let port = env["CAPSULEER_SSO_PORT"].flatMap(UInt16.init) ?? 8635
        let sso = SSOClient(configuration: SSOConfiguration(clientID: clientID, callbackURL: URL(string: "http://127.0.0.1:\(port)/callback")!),
                            userAgent: userAgent)
        let cache = TieredCacheStore(directory: tempDirectory())
        tokens = TokenManager(sso: sso, store: LiveFileTokenStore(url: tokenFile), cache: cache)
        esi = ESIClient(configuration: ESIConfiguration(userAgent: userAgent, cache: cache, tokenProvider: tokens))
    }

    /// Refreshes (and rotates) the stored refresh token, then reads location, ship and online.
    /// Asserts shape and etiquette only; the values depend on what the character is doing in game.
    @Test func locationShipOnline() async throws {
        let character = try #require(try await tokens.characters().first { $0.id == characterID }, "Log the character in with `capsuleer esi login`")
        #expect(character.state == .active)
        let me = esi.character(characterID)
        let location = try await me.location()
        #expect(location.value.solarSystemID > 30_000_000)
        #expect(location.expires != nil)
        let ship = try await me.ship()
        #expect(ship.value.typeID > 0)
        let online = try await me.online()
        _ = online.value.isOnline
        let repeated = try await me.location()
        #expect(repeated.source == .cache)
    }

    @Test func missingScopeIsRejectedLocally() async throws {
        await #expect(throws: CapsuleerError.self) {
            _ = try await tokens.accessToken(for: characterID, requiredScopes: ["esi-wallet.read_character_wallet.v1"])
        }
    }
}
