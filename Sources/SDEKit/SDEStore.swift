import Foundation
import CapsuleerCore

/// The release metadata an `SDEStore` keeps: the last manifest and when it was checked.
public struct SDEStoredRelease: Sendable, Hashable, Codable {
    /// The last manifest fetched.
    public var release: SDERelease
    /// When the manifest was last fetched successfully from the network.
    public var lastChecked: Date

    /// Creates stored release metadata.
    public init(release: SDERelease, lastChecked: Date) {
        self.release = release
        self.lastChecked = lastChecked
    }
}

/// A decoded table as kept by an `SDEStore`: records plus the release and version they came from.
public struct SDEStoredTable<Record: Codable & Sendable>: Sendable, Codable {
    /// The release the table was downloaded from.
    public var release: String
    /// The table's version hash from that release's manifest.
    public var version: String
    /// When the table was downloaded.
    public var fetchedAt: Date
    /// The decoded records.
    public var records: [Record]

    /// Creates a stored table.
    public init(release: String, version: String, fetchedAt: Date, records: [Record]) {
        self.release = release
        self.version = version
        self.fetchedAt = fetchedAt
        self.records = records
    }
}

/// Persistent storage for SDE release metadata and decoded tables. It should live somewhere that
/// survives cache purges (Application Support), so the data stays available offline.
///
/// Saving a table must replace the previous one atomically: a reader sees either the old table
/// or the new one, never a mix.
public protocol SDEStore: Sendable {
    /// The stored release metadata, or nil if none was saved.
    func loadRelease() async throws -> SDEStoredRelease?
    /// Saves release metadata, replacing the previous one.
    func saveRelease(_ release: SDEStoredRelease) async throws
    /// The stored table `name`, or nil if none was saved.
    func loadTable<Record: Codable & Sendable>(named name: String, as type: Record.Type) async throws -> SDEStoredTable<Record>?
    /// Saves table `name` atomically, replacing the previous one.
    func saveTable<Record: Codable & Sendable>(_ table: SDEStoredTable<Record>, named name: String) async throws
}

/// Keeps everything in memory. For tests and for apps that don't need offline data.
public actor InMemorySDEStore: SDEStore {
    private var release: SDEStoredRelease?
    private var tables: [String: any Sendable] = [:]

    /// Creates an empty store.
    public init() {}

    public func loadRelease() -> SDEStoredRelease? { release }

    public func saveRelease(_ release: SDEStoredRelease) { self.release = release }

    public func loadTable<Record: Codable & Sendable>(named name: String, as type: Record.Type) -> SDEStoredTable<Record>? {
        tables[name] as? SDEStoredTable<Record>
    }

    public func saveTable<Record: Codable & Sendable>(_ table: SDEStoredTable<Record>, named name: String) {
        tables[name] = table
    }
}

/// Stores JSON files in `directory`: `release.json` and one `<table>.json` per table, each
/// written atomically (write to a temporary file, then rename). Creates the directory as needed.
/// Failures throw `CapsuleerError(.storage)`.
public actor DiskSDEStore: SDEStore {
    /// The directory holding the files.
    public let directory: URL

    /// Creates a store in `directory` (created on first write).
    public init(directory: URL) {
        self.directory = directory
    }

    public func loadRelease() throws -> SDEStoredRelease? {
        try read(SDEStoredRelease.self, from: fileURL("release"))
    }

    public func saveRelease(_ release: SDEStoredRelease) throws {
        try write(release, to: fileURL("release"))
    }

    public func loadTable<Record: Codable & Sendable>(named name: String, as type: Record.Type) throws -> SDEStoredTable<Record>? {
        try read(SDEStoredTable<Record>.self, from: fileURL("table-" + name))
    }

    public func saveTable<Record: Codable & Sendable>(_ table: SDEStoredTable<Record>, named name: String) throws {
        try write(table, to: fileURL("table-" + name))
    }

    private func fileURL(_ name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent(safe + ".json", isDirectory: false)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw CapsuleerError(.storage, message: "Could not read \(url.lastPathComponent)", url: url, underlying: error)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CapsuleerError(.storage, message: "Could not decode \(url.lastPathComponent)", url: url, underlying: error)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            throw CapsuleerError(.storage, message: "Could not write \(url.lastPathComponent)", url: url, underlying: error)
        }
    }
}
