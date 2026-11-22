import ArgumentParser
import CapsuleerCore
import Foundation
import SDEKit

@main
struct Capsuleer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "CapsuleerKit dev CLI.",
        version: CapsuleerKitInfo.version,
        subcommands: [SDE.self, ESICommand.self])
}

struct SharedOptions: ParsableArguments {
    @Option(help: "Data directory (SDE tables and HTTP cache).")
    var dir: String = Self.defaultDirectory.path

    @Flag(help: "Check for a new SDE release now, ignoring the daily interval.")
    var force = false

    @Flag(name: .shortAndLong, help: "Log to stderr.")
    var verbose = false

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CapsuleerKit-cli", isDirectory: true)
    }

    func makeClient() -> SDEClient {
        SDEClient(configuration: SDEConfiguration(
            userAgent: UserAgent(product: "capsuleer", version: CapsuleerKitInfo.version, contact: "+https://github.com/Crazor/CapsuleerKit"),
            directory: URL(fileURLWithPath: dir, isDirectory: true),
            logSink: verbose ? StderrLogSink(minimumLevel: .debug) : NullLogSink()))
    }
}

struct SDE: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Static data from CCP's SDE over HTTP.",
        subcommands: [Release.self, System.self])

    struct Release: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the current SDE release.")
        @OptionGroup var options: SharedOptions

        func run() async throws {
            let response = try await options.makeClient().currentRelease(forceCheck: options.force)
            let r = response.value
            print("release:      \(r.release)")
            print("build:        \(r.buildNumber)")
            print("released:     \(ISO8601DateFormatter().string(from: r.releaseDate))")
            print("tables:       \(r.tables.count)")
            if let solar = r.tables["mapSolarSystems"] { print("solarSystems: \(solar.version)") }
            print("source:       \(response.source.rawValue)\(response.isStale ? " (stale)" : "")")
        }
    }

    struct System: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Look up a solar system by name or ID.")
        @OptionGroup var options: SharedOptions
        @Argument(help: "System name (any client language) or solar system ID.")
        var query: String

        func run() async throws {
            let table = try await options.makeClient().solarSystems(forceCheck: options.force)
            let found = Int64(query).flatMap { table.system(id: $0) } ?? table.system(named: query)
            guard let system = found else {
                FileHandle.standardError.write(Data("No solar system named or numbered \"\(query)\" in SDE release \(table.release).\n".utf8))
                throw ExitCode.failure
            }
            let sec = system.security
            print("\(system.name.en) (\(system.id))")
            print("security:  \(sec.formatted) [\(sec.band.rawValue)]  true \(system.securityStatus)  colour \(sec.displayColor.hex)")
            print("region:    \(system.regionID)  constellation: \(system.constellationID)")
            print("sde:       \(table.release)\(table.isStale ? " (stale)" : "")")
        }
    }
}
