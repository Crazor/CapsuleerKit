import ArgumentParser
import CapsuleerCore
import ESIKit
import Foundation
import SDEKit

struct ESIOptions: ParsableArguments {
    @OptionGroup var shared: SharedOptions

    @Option(help: "EVE SSO client ID (or env CAPSULEER_CLIENT_ID). Register an app with callback http://127.0.0.1:<port>/callback.")
    var clientID: String?

    @Option(help: "Loopback port for the SSO callback.")
    var port: UInt16 = 8635

    var directory: URL { URL(fileURLWithPath: shared.dir, isDirectory: true) }
    var userAgent: UserAgent { UserAgent(product: "capsuleer", version: CapsuleerKitInfo.version, contact: "+https://github.com/Crazor/CapsuleerKit") }
    var logSink: any LogSink { shared.verbose ? StderrLogSink(minimumLevel: .debug) : NullLogSink() }
    var callbackURL: URL { URL(string: "http://127.0.0.1:\(port)/callback")! }

    func resolvedClientID() throws -> String {
        if let clientID, !clientID.isEmpty { return clientID }
        if let env = ProcessInfo.processInfo.environment["CAPSULEER_CLIENT_ID"], !env.isEmpty { return env }
        throw ValidationError("Pass --client-id or set CAPSULEER_CLIENT_ID.")
    }

    func makeTokenManager(cache: any CacheStore) throws -> TokenManager {
        let sso = SSOClient(
            configuration: SSOConfiguration(clientID: try resolvedClientID(), callbackURL: callbackURL,
                                            defaultScopes: [.locationRead, .shipTypeRead, .onlineRead, .structuresRead]),
            userAgent: userAgent, logSink: logSink)
        return TokenManager(sso: sso, store: FileTokenStore(url: directory.appendingPathComponent("credentials.json")),
                            logSink: logSink, cache: cache)
    }

    func makeClients(authenticated: Bool) throws -> (ESIClient, TokenManager?) {
        let cache = TieredCacheStore(directory: directory.appendingPathComponent("esi-http", isDirectory: true))
        let tokens = authenticated ? try makeTokenManager(cache: cache) : nil
        let esi = ESIClient(configuration: ESIConfiguration(userAgent: userAgent, cache: cache, tokenProvider: tokens, logSink: logSink))
        return (esi, tokens)
    }
}

struct ESICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "esi", abstract: "CCP's ESI API and EVE SSO.",
        subcommands: [Login.self, Characters.self, Logout.self, Status.self, Character.self])

    struct Login: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Log a character in through EVE SSO (opens the browser).")
        @OptionGroup var options: ESIOptions

        func run() async throws {
            let (_, tokens) = try options.makeClients(authenticated: true)
            let session = LoopbackAuthorizationSession(port: options.port) { url in
                FileHandle.standardError.write(Data("Opening EVE SSO in your browser…\n\(url.absoluteString)\n".utf8))
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [url.absoluteString]
                try open.run()
            }
            let character = try await tokens!.authorize(using: session)
            print("Logged in \(character.name) (\(character.id)) with \(character.scopes.count) scopes.")
        }
    }

    struct Characters: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List stored characters.")
        @OptionGroup var options: ESIOptions

        func run() async throws {
            let (_, tokens) = try options.makeClients(authenticated: true)
            for c in try await tokens!.characters() {
                let state: String
                switch c.state {
                case .active: state = "active"
                case .needsReauthentication(let reason): state = "needs login (\(reason))"
                }
                print("\(c.id)  \(c.name)  [\(state)]  \(c.scopes.map(\.rawValue).sorted().joined(separator: " "))")
            }
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke and forget a character.")
        @OptionGroup var options: ESIOptions
        @Argument var characterID: Int64

        func run() async throws {
            let (_, tokens) = try options.makeClients(authenticated: true)
            try await tokens!.logout(characterID: characterID)
            print("Logged out \(characterID).")
        }
    }

    struct Character: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Public information about a character.")
        @OptionGroup var options: ESIOptions
        @Argument var characterID: Int64

        func run() async throws {
            let (esi, _) = try options.makeClients(authenticated: false)
            let info = try await esi.character(characterID).publicInfo()
            print("\(info.value.name)  corp \(info.value.corporationID)\(info.value.allianceID.map { "  alliance \($0)" } ?? "")  (\(info.source.rawValue))")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Location, ship and online state of a logged-in character.")
        @OptionGroup var options: ESIOptions
        @Argument var characterID: Int64

        func run() async throws {
            let (esi, _) = try options.makeClients(authenticated: true)
            let sde = options.shared.makeClient()
            let me = esi.character(characterID)
            async let location = me.location()
            async let ship = me.ship()
            async let online = me.online()
            let loc = try await location.value
            let systems = try await sde.solarSystems()
            let system = systems.system(id: loc.solarSystemID)
            let systemText = system.map { "\($0.name.en) \($0.security.formatted)" } ?? "\(loc.solarSystemID)"
            var place = "in space"
            if let station = loc.stationID {
                let name = try? await esi.universe.names([station]).first?.name
                place = "docked at \(name ?? String(station))"
            } else if let structure = loc.structureID {
                let name = try? await esi.universe.structure(structure, as: characterID).value.name
                place = "docked at \(name ?? "structure \(structure)")"
            }
            let s = try await ship.value
            let typeName = (try? await sde.type(s.typeID).value.name.en) ?? String(s.typeID)
            let on = try await online.value
            print("system:  \(systemText)  (\(place))")
            print("ship:    \(s.name)  [\(typeName)]")
            print("online:  \(on.isOnline ? "yes" : "no")")
        }
    }
}
