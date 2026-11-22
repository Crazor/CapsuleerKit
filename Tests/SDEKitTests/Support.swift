import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import SDEKit

enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static var manifest: Data { get throws { try data("manifest", "json") } }
    static var solarSystemsJSONL: Data { get throws { try data("mapSolarSystems-sample", "jsonl") } }
    static var jitaRecord: Data { get throws { try data("mapSolarSystems-30000142", "json") } }

    static let release = "20261120T165826Z"
    static let solarSystemsVersion = "c9606848f70d51100dbeedd5a9006c7bee71962f389754ad9d3d929015fc4e78"
    static let latestURL = URL(string: "https://sde.evetech.net/tranquility/latest/")!
    static let releaseURL = URL(string: "https://sde.evetech.net/tranquility/\(release)/")!
    static let solarSystemsJSONLURL = URL(string: "https://sde.evetech.net/tranquility/\(release)/mapSolarSystems.jsonl")!
}

/// Mutable state shared between a test and its transport handler.
/// `@unchecked Sendable`: every access to `value` goes through `lock`.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

/// A fake sde.evetech.net behind a `MockTransport`: serves the manifest (as the redirect target of
/// `latest/`), the solar-system JSONL and single records, and can go offline.
final class FakeSDEServer: Sendable {
    struct State {
        var manifest: Data
        var jsonl: Data
        var offline = false
        var jsonlDelay: Duration = .zero
        var manifestDelay: Duration = .zero
    }

    let state: Locked<State>
    let transport: MockTransport

    init() throws {
        let state = Locked(State(manifest: try Fixture.manifest, jsonl: try Fixture.solarSystemsJSONL))
        let record = try Fixture.jitaRecord
        self.state = state
        transport = MockTransport { request in
            let current = state.value
            if current.offline {
                throw CapsuleerError(.transport, message: "offline", url: request.url)
            }
            let url = request.url.absoluteString
            if url == Fixture.latestURL.absoluteString {
                if current.manifestDelay > .zero { try await Task.sleep(for: current.manifestDelay) }
                // The transport follows the 302, so the final URL is the release URL.
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "public, max-age=86400"],
                                    body: current.manifest, url: Fixture.releaseURL)
            }
            if url.hasSuffix("/mapSolarSystems.jsonl") {
                if current.jsonlDelay > .zero { try await Task.sleep(for: current.jsonlDelay) }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/jsonl"], body: current.jsonl, url: request.url)
            }
            if url.hasSuffix("/mapSolarSystems/30000142.json") {
                return HTTPResponse(status: 200, headers: ["Cache-Control": "public, max-age=31536000, immutable", "ETag": "\"jita\""],
                                    body: record, url: request.url)
            }
            return HTTPResponse(status: 404, body: Data("not found".utf8), url: request.url)
        }
    }

    var offline: Bool {
        get { state.value.offline }
        set { state.mutate { $0.offline = newValue } }
    }

    /// Replaces the solar-system table's version hash in the served manifest.
    func setSolarSystemsVersion(_ version: String) {
        state.mutate {
            let text = String(decoding: $0.manifest, as: UTF8.self)
            $0.manifest = Data(text.replacingOccurrences(of: Fixture.solarSystemsVersion, with: version).utf8)
        }
    }

    var manifestRequests: Int { transport.requests.filter { $0.url.absoluteString.hasSuffix("/latest/") }.count }
    var jsonlRequests: Int { transport.requests.filter { $0.url.absoluteString.hasSuffix(".jsonl") }.count }
    var totalRequests: Int { transport.requests.count }
}

struct Harness {
    let server: FakeSDEServer
    let clock: ManualTimeSource
    let store: any SDEStore
    let events: Locked<[ClientEvent]>
    let client: SDEClient

    init(server: FakeSDEServer? = nil, store: any SDEStore = InMemorySDEStore(), cache: (any CacheStore)? = nil,
         clock: ManualTimeSource = ManualTimeSource(), failureRetryInterval: TimeInterval = 900) throws {
        let server = try server ?? FakeSDEServer()
        let events = Locked<[ClientEvent]>([])
        self.server = server
        self.clock = clock
        self.store = store
        self.events = events
        client = SDEClient(configuration: SDEConfiguration(
            userAgent: UserAgent(product: "SDEKitTests", version: "1"),
            store: store,
            cache: cache,
            transport: server.transport,
            failureRetryInterval: failureRetryInterval,
            events: { event in events.mutate { $0.append(event) } },
            timeSource: clock))
    }

    /// A second client on the same server, store and clock (like a relaunch).
    func relaunched() throws -> Harness {
        try Harness(server: server, store: store, clock: clock)
    }

    func eventCount(_ kind: ClientEvent.Kind) -> Int { events.value.filter { $0.kind == kind }.count }
}

/// Wraps a store and delays `loadTable`, to hold a sync in flight before its release check.
struct SlowTableStore: SDEStore {
    let base: any SDEStore
    let delay: Duration

    func loadRelease() async throws -> SDEStoredRelease? { try await base.loadRelease() }
    func saveRelease(_ release: SDEStoredRelease) async throws { try await base.saveRelease(release) }
    func loadTable<Record: Codable & Sendable>(named name: String, as type: Record.Type) async throws -> SDEStoredTable<Record>? {
        try await Task.sleep(for: delay)
        return try await base.loadTable(named: name, as: type)
    }
    func saveTable<Record: Codable & Sendable>(_ table: SDEStoredTable<Record>, named name: String) async throws {
        try await base.saveTable(table, named: name)
    }
}

/// Polls `condition` until it holds or about two seconds pass.
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}
