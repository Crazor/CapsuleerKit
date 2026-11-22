import Foundation
import CapsuleerCore

/// Reads EVE Online's Static Data Export from `sde.evetech.net`.
///
/// - The release manifest is checked over the network at most every
///   `SDEConfiguration.releaseCheckInterval`; in between, the stored manifest is used.
/// - All data URLs come from the current release's manifest (the release is pinned), never `latest/`.
/// - Whole tables are downloaded only when their version hash changes, and are kept in the
///   `SDEStore` and in memory.
/// - Offline, stored data is returned with `isStale = true`. Only when nothing is stored do calls
///   fail, with `CapsuleerError` code `.sdeReleaseUnavailable`.
/// - A failed release check or table download is not retried for
///   `SDEConfiguration.failureRetryInterval` unless a call forces it.
/// - Concurrent calls share one check or sync. A cancelled caller stops waiting at once and throws
///   `CapsuleerError` code `.cancelled`; the shared work carries on for the others.
public final class SDEClient: Sendable {
    /// The configuration the client was created with.
    public let configuration: SDEConfiguration
    private let http: HTTPClient
    private let engine: SDEEngine

    /// Creates a client. Nothing is fetched until the first call.
    public init(configuration: SDEConfiguration) {
        self.configuration = configuration
        let cached = HTTPClient(configuration: .init(
            userAgent: configuration.userAgent, transport: configuration.transport, cache: configuration.cache,
            logSink: configuration.logSink, events: configuration.events, timeSource: configuration.timeSource))
        // Whole tables (the solar-system JSONL is about 5 MB) bypass the HTTP cache: the store
        // already keeps the decoded table plus its version hash, which is a better validator than
        // an ETag, so caching the body as well would only double the disk use.
        let uncached = HTTPClient(configuration: .init(
            userAgent: configuration.userAgent, transport: configuration.transport, cache: nil,
            logSink: configuration.logSink, events: configuration.events, timeSource: configuration.timeSource))
        http = cached
        engine = SDEEngine(configuration: configuration, http: cached, downloads: uncached)
    }

    /// The current release manifest.
    ///
    /// Checked over the network (revalidating the HTTP cache) at most every
    /// `releaseCheckInterval`, unless `forceCheck`; otherwise the stored manifest is returned with
    /// source `.cache`. `expires` is the time of the next due check. If the check fails, the stored
    /// manifest is returned with `isStale = true`; with nothing stored it throws `.sdeReleaseUnavailable`.
    public func currentRelease(forceCheck: Bool = false) async throws -> Response<SDERelease> {
        try await engine.currentRelease(forceCheck: forceCheck)
    }

    /// The solar systems of the current release.
    ///
    /// Synced on first use and whenever the table's version hash changes; otherwise served from
    /// memory or the store. If the release check or download fails, stored data is returned with
    /// `isStale = true`; with nothing stored it throws `.sdeReleaseUnavailable`. Concurrent calls
    /// share one sync; a forced call that finds a non-forced sync running starts a forced one after it.
    public func solarSystems(forceCheck: Bool = false) async throws -> SolarSystemTable {
        try await engine.solarSystems(forceCheck: forceCheck)
    }

    /// One record from any table, pinned to the current release, for example
    /// `record(SolarSystem.self, table: "mapSolarSystems", key: 30000142)`.
    ///
    /// The URL comes from the table's `record.urlTemplate` in the manifest. Records are immutable
    /// per release, so the HTTP cache serves repeats. Throws `.notFound` if the release has no
    /// such table or record, `.decoding` if the record doesn't decode as `T`.
    public func record<T: Decodable & Sendable>(_ type: T.Type, table: String, key: some CustomStringConvertible & Sendable) async throws -> Response<T> {
        let release = try await engine.currentRelease(forceCheck: false).value
        let url = try SDEClient.recordURL(release: release, table: table, key: key.description, baseURL: configuration.baseURL)
        configuration.logSink.log(.debug, .sde, "Fetching record", metadata: ["table": table, "key": key.description, "release": release.release])
        return try await http.send(HTTPRequest(url: url)).decode(T.self)
    }

    static func recordURL(release: SDERelease, table: String, key: String, baseURL: URL) throws -> URL {
        guard let info = release.tables[table] else {
            throw CapsuleerError(.notFound, message: "SDE release \(release.release) has no table \(table)")
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let string = info.recordURLTemplate.map { $0.replacingOccurrences(of: "{key}", with: encodedKey) }
            ?? baseURL.appendingPathComponent("\(release.release)/\(table)/\(encodedKey).json").absoluteString
        guard let url = URL(string: string) else {
            throw CapsuleerError(.invalidResponse, message: "Invalid record URL \(string)")
        }
        return url
    }
}

/// Holds the in-memory state (stored release, decoded tables) and coalesces concurrent work.
///
/// Concurrent work is shared through `SharedWork`, so a cancelled caller stops waiting without
/// cancelling the work for the others. Each in-flight item carries a token; the work clears its
/// own slot when it finishes, and only if the slot still holds that token.
actor SDEEngine {
    static let solarSystemsTable = "mapSolarSystems"

    private struct InFlight<Value: Sendable> {
        let work: SharedWork<Value>
        let token: Int
        /// Whether this run checks the release regardless of the interval and failure backoff.
        let forced: Bool
    }

    /// A table download that failed, remembered so it isn't retried before the backoff passes.
    private struct FailedDownload {
        let release: String
        let version: String
        let at: Date
        let error: any Error
    }

    private let configuration: SDEConfiguration
    private let http: HTTPClient
    private let downloads: HTTPClient
    private var nextToken = 0

    private var storedRelease: SDEStoredRelease?
    private var storedReleaseLoaded = false
    private var releaseCheck: InFlight<Response<SDERelease>>?
    /// When the last release check failed; nil after a success. In memory only.
    private var lastFailedReleaseCheck: Date?

    private var solarTable: SolarSystemTable?
    private var solarTableLoaded = false
    private var solarSync: InFlight<SolarSystemTable>?
    private var failedDownloads: [String: FailedDownload] = [:]

    init(configuration: SDEConfiguration, http: HTTPClient, downloads: HTTPClient) {
        self.configuration = configuration
        self.http = http
        self.downloads = downloads
    }

    private var latestURL: URL { configuration.baseURL.appendingPathComponent("latest/") }

    private func makeToken() -> Int {
        nextToken += 1
        return nextToken
    }

    // MARK: Release

    func currentRelease(forceCheck: Bool) async throws -> Response<SDERelease> {
        let stored = await loadStoredRelease()
        if !forceCheck, let stored {
            if !isCheckDue(stored) {
                return response(for: stored, isStale: false)
            }
            if let retryAt = releaseRetryTime(), configuration.timeSource.now() < retryAt {
                // The last check failed recently; don't wait on the network again yet.
                return response(for: stored, isStale: true, expires: retryAt)
            }
        }
        // Every release check goes to the network, so a forced caller can join any running one.
        if let running = releaseCheck { return try await running.work.value() }
        let token = makeToken()
        let work = SharedWork { [self] in
            try await self.runReleaseCheck(stored: stored, token: token)
        }
        releaseCheck = InFlight(work: work, token: token, forced: forceCheck)
        return try await work.value()
    }

    private func runReleaseCheck(stored: SDEStoredRelease?, token: Int) async throws -> Response<SDERelease> {
        defer { if releaseCheck?.token == token { releaseCheck = nil } }
        return try await checkRelease(stored: stored)
    }

    private func checkRelease(stored: SDEStoredRelease?) async throws -> Response<SDERelease> {
        let url = latestURL
        do {
            let fetched = try await http.send(HTTPRequest(url: url), policy: .reloadRevalidatingCacheData).decode(SDERelease.self)
            if fetched.isStale {
                // The HTTP cache answered because the network failed.
                let retryAt = noteReleaseCheckFailed()
                if let stored {
                    reportStale("SDE release check failed; using stored release", release: stored.release.release, url: url, error: nil)
                    return response(for: stored, isStale: true, expires: retryAt)
                }
                reportStale("SDE release check failed; using HTTP-cached manifest", release: fetched.value.release, url: url, error: nil)
                return fetched
            }
            let now = configuration.timeSource.now()
            lastFailedReleaseCheck = nil
            let updated = SDEStoredRelease(release: fetched.value, lastChecked: now)
            storedRelease = updated
            do {
                try await configuration.store.saveRelease(updated)
            } catch {
                log(.error, "Could not save SDE release metadata", ["error": "\(error)"])
            }
            let changed = stored?.release.release != fetched.value.release
            log(.info, "SDE release checked", ["release": fetched.value.release, "changed": "\(changed)", "source": fetched.source.rawValue])
            configuration.events?(ClientEvent(kind: .sdeReleaseChecked, url: url, source: fetched.source,
                                              detail: "release \(fetched.value.release)\(changed ? " (new)" : "")"))
            return Response(value: fetched.value, source: fetched.source, expires: now.addingTimeInterval(configuration.releaseCheckInterval),
                            lastModified: fetched.lastModified, etag: fetched.etag, isStale: false)
        } catch {
            if Self.isCancellation(error) { throw error }
            let retryAt = noteReleaseCheckFailed()
            let wrapped = error as? CapsuleerError
            if let stored {
                reportStale("SDE release check failed; using stored release", release: stored.release.release, url: url, error: wrapped)
                return response(for: stored, isStale: true, expires: retryAt)
            }
            log(.error, "SDE release unavailable", ["error": "\(error)"])
            throw CapsuleerError(.sdeReleaseUnavailable, message: "Could not fetch the SDE release manifest and none is stored", url: url, underlying: error)
        }
    }

    /// Records a failed release check; returns when the next one may run.
    private func noteReleaseCheckFailed() -> Date {
        let now = configuration.timeSource.now()
        lastFailedReleaseCheck = now
        return now.addingTimeInterval(configuration.failureRetryInterval)
    }

    private func releaseRetryTime() -> Date? {
        lastFailedReleaseCheck?.addingTimeInterval(configuration.failureRetryInterval)
    }

    private func loadStoredRelease() async -> SDEStoredRelease? {
        if !storedReleaseLoaded {
            do {
                let loaded = try await configuration.store.loadRelease()
                // Another call may have checked the network while we were loading.
                if !storedReleaseLoaded { storedRelease = loaded }
            } catch {
                log(.warning, "Ignoring unreadable stored SDE release", ["error": "\(error)"])
            }
            storedReleaseLoaded = true
        }
        return storedRelease
    }

    private func isCheckDue(_ stored: SDEStoredRelease) -> Bool {
        let elapsed = configuration.timeSource.now().timeIntervalSince(stored.lastChecked)
        return elapsed < 0 || elapsed >= configuration.releaseCheckInterval
    }

    private func response(for stored: SDEStoredRelease, isStale: Bool, expires: Date? = nil) -> Response<SDERelease> {
        Response(value: stored.release, source: .cache, expires: expires ?? stored.lastChecked.addingTimeInterval(configuration.releaseCheckInterval),
                 lastModified: nil, etag: nil, isStale: isStale)
    }

    // MARK: Solar systems

    func solarSystems(forceCheck: Bool) async throws -> SolarSystemTable {
        if let running = solarSync, running.forced || !forceCheck {
            return try await running.work.value()
        }
        // Nothing running, or only a non-forced sync that may skip the check: start a forced
        // sync, chained after the running one so the two don't download side by side.
        let previous = solarSync?.work
        let token = makeToken()
        let work = SharedWork { [self] in
            if let previous { _ = try? await previous.value() }
            return try await self.runSolarSync(forceCheck: forceCheck, token: token)
        }
        solarSync = InFlight(work: work, token: token, forced: forceCheck)
        return try await work.value()
    }

    private func runSolarSync(forceCheck: Bool, token: Int) async throws -> SolarSystemTable {
        defer { if solarSync?.token == token { solarSync = nil } }
        return try await syncSolarSystems(forceCheck: forceCheck)
    }

    private func syncSolarSystems(forceCheck: Bool) async throws -> SolarSystemTable {
        let name = Self.solarSystemsTable
        if !solarTableLoaded {
            do {
                if let stored = try await configuration.store.loadTable(named: name, as: SolarSystem.self) {
                    solarTable = SolarSystemTable(stored)
                }
            } catch {
                log(.warning, "Ignoring unreadable stored SDE table", ["table": name, "error": "\(error)"])
            }
            solarTableLoaded = true
        }

        let releaseResponse: Response<SDERelease>
        do {
            releaseResponse = try await currentRelease(forceCheck: forceCheck)
        } catch {
            guard let table = solarTable, !Self.isCancellation(error) else { throw error }
            reportStale("Serving stored SDE table", release: table.release, url: nil, error: error as? CapsuleerError)
            return table.markingStale(true)
        }

        let release = releaseResponse.value
        guard let info = release.tables[name] else {
            let error = CapsuleerError(.invalidResponse, message: "SDE release \(release.release) has no table \(name)")
            if let table = solarTable {
                reportStale("Serving stored SDE table", release: table.release, url: nil, error: error)
                return table.markingStale(true)
            }
            throw CapsuleerError(.sdeReleaseUnavailable, message: error.message, underlying: error)
        }

        if let table = solarTable, table.version == info.version {
            return table.markingStale(releaseResponse.isStale)
        }

        if !forceCheck, let failed = failedDownloads[name], failed.release == release.release, failed.version == info.version,
           configuration.timeSource.now() < failed.at.addingTimeInterval(configuration.failureRetryInterval) {
            // This exact download failed recently; don't fetch the whole table again yet.
            if let table = solarTable { return table.markingStale(true) }
            throw CapsuleerError(.sdeReleaseUnavailable, message: "Could not download SDE table \(name) and none is stored",
                                 url: info.jsonlURL, underlying: failed.error)
        }

        do {
            let stored = try await download(name, info: info, release: release, as: SolarSystem.self)
            failedDownloads[name] = nil
            let table = SolarSystemTable(stored)
            solarTable = table
            return table
        } catch {
            if Self.isCancellation(error) { throw error }
            failedDownloads[name] = FailedDownload(release: release.release, version: info.version,
                                                   at: configuration.timeSource.now(), error: error)
            if let table = solarTable {
                reportStale("SDE table download failed; serving stored table", release: table.release, url: info.jsonlURL, error: error as? CapsuleerError)
                return table.markingStale(true)
            }
            log(.error, "SDE table unavailable", ["table": name, "error": "\(error)"])
            throw CapsuleerError(.sdeReleaseUnavailable, message: "Could not download SDE table \(name) and none is stored",
                                 url: info.jsonlURL, underlying: error)
        }
    }

    /// Downloads, decodes and stores one table of the pinned `release`.
    private func download<Record: Codable & Sendable>(_ name: String, info: SDETable, release: SDERelease, as type: Record.Type) async throws -> SDEStoredTable<Record> {
        let url = info.jsonlURL ?? configuration.baseURL.appendingPathComponent("\(release.release)/\(name).jsonl")
        log(.info, "Downloading SDE table", ["table": name, "release": release.release, "version": info.version])
        let response = try await downloads.send(HTTPRequest(url: url), policy: .reloadRevalidatingCacheData)
        let records = try JSONLines.decode(Record.self, from: response.value.body, url: url)
        let stored = SDEStoredTable(release: release.release, version: info.version, fetchedAt: configuration.timeSource.now(), records: records)
        do {
            try await configuration.store.saveTable(stored, named: name)
        } catch {
            // The data is still good for this session; the next launch downloads it again.
            log(.error, "Could not save SDE table", ["table": name, "error": "\(error)"])
        }
        log(.info, "SDE table updated", ["table": name, "release": release.release, "version": info.version, "records": "\(records.count)"])
        configuration.events?(ClientEvent(kind: .sdeTableUpdated, url: url, source: response.source,
                                          detail: "\(name) version \(info.version) (\(records.count) records, release \(release.release))"))
        return stored
    }

    // MARK: Helpers

    private func reportStale(_ message: String, release: String, url: URL?, error: CapsuleerError?) {
        var metadata = ["release": release]
        if let error { metadata["error"] = "\(error)" }
        log(.warning, message, metadata)
        configuration.events?(ClientEvent(kind: .servedStale, url: url, source: .cache, error: error, detail: "\(message) (release \(release))"))
    }

    private func log(_ level: LogLevel, _ message: String, _ metadata: [String: String] = [:]) {
        configuration.logSink.log(level, .sde, message, metadata: metadata)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? CapsuleerError, error.code == .cancelled { return true }
        return false
    }
}

extension SolarSystemTable {
    init(_ stored: SDEStoredTable<SolarSystem>) {
        self.init(release: stored.release, version: stored.version, fetchedAt: stored.fetchedAt, isStale: false, systems: stored.records)
    }

    func markingStale(_ isStale: Bool) -> SolarSystemTable {
        var copy = self
        copy.isStale = isStale
        return copy
    }
}
