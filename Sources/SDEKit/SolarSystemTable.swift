import Foundation

/// The decoded `mapSolarSystems` table with lookups by ID and by localised name.
public struct SolarSystemTable: Sendable {
    /// The SDE release the data was downloaded from. When a later release leaves the table's
    /// version unchanged, the data is not downloaded again and this stays at the older release.
    public var release: String
    /// The table's version hash from the manifest.
    public var version: String
    /// True when the release check or the download failed and stored data was returned instead.
    public var isStale: Bool
    /// When the data was downloaded.
    public var fetchedAt: Date

    private var systems: [SolarSystem]
    private var indexByID: [Int64: Int]
    private var indexByName: [String: Int]

    /// Creates a table and builds its indexes. Systems are kept sorted by ID.
    public init(release: String, version: String, fetchedAt: Date, isStale: Bool = false, systems: [SolarSystem]) {
        self.release = release
        self.version = version
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        let sorted = systems.sorted { $0.id < $1.id }
        self.systems = sorted

        var byID: [Int64: Int] = [:]
        byID.reserveCapacity(sorted.count)
        for (index, system) in sorted.enumerated() { byID[system.id] = index }
        indexByID = byID

        // English names first, so they win when a localised name of another system folds to the same key.
        var byName: [String: Int] = [:]
        byName.reserveCapacity(sorted.count * 2)
        for (index, system) in sorted.enumerated() {
            let key = Self.fold(system.name.en)
            if byName[key] == nil { byName[key] = index }
        }
        for (index, system) in sorted.enumerated() {
            for language in system.name.all.keys.sorted() where language != "en" {
                guard let text = system.name.all[language] else { continue }
                let key = Self.fold(text)
                if byName[key] == nil { byName[key] = index }
            }
        }
        indexByName = byName
    }

    /// The system with this ID.
    public func system(id: Int64) -> SolarSystem? {
        indexByID[id].map { systems[$0] }
    }

    /// The system with this name in any language, ignoring case, diacritics and surrounding
    /// whitespace (locale-independent). English names win when names clash.
    public func system(named name: String) -> SolarSystem? {
        indexByName[Self.fold(name)].map { systems[$0] }
    }

    /// All systems, sorted by ID.
    public var all: [SolarSystem] { systems }

    static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
