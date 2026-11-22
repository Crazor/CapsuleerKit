import Foundation

/// One SDE release as described by its manifest (`https://sde.evetech.net/tranquility/<release>/`).
///
/// Decodes the manifest's real shape and ignores what SDEKit does not use (flatbuffers URLs,
/// schema URLs). Encoding writes the same shape back, so a stored release decodes again.
public struct SDERelease: Sendable, Hashable, Codable {
    /// The release identifier, e.g. `20261120T165826Z`. Part of every data URL.
    public var release: String
    /// The game build the release was exported from.
    public var buildNumber: Int
    /// When the release was published.
    public var releaseDate: Date
    /// The tables in this release, by name (e.g. `mapSolarSystems`).
    public var tables: [String: SDETable]

    /// Creates a release description.
    public init(release: String, buildNumber: Int, releaseDate: Date, tables: [String: SDETable]) {
        self.release = release
        self.buildNumber = buildNumber
        self.releaseDate = releaseDate
        self.tables = tables
    }

    private enum CodingKeys: String, CodingKey {
        case release, buildNumber, releaseDate, tables
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        release = try c.decode(String.self, forKey: .release)
        buildNumber = try c.decodeIfPresent(Int.self, forKey: .buildNumber) ?? 0
        let dateString = try c.decode(String.self, forKey: .releaseDate)
        guard let date = ISO8601.parse(dateString) else {
            throw DecodingError.dataCorruptedError(forKey: .releaseDate, in: c, debugDescription: "Not an ISO-8601 date: \(dateString)")
        }
        releaseDate = date
        tables = try c.decodeIfPresent([String: SDETable].self, forKey: .tables) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(release, forKey: .release)
        try c.encode(buildNumber, forKey: .buildNumber)
        try c.encode(ISO8601.format(releaseDate), forKey: .releaseDate)
        try c.encode(tables, forKey: .tables)
    }
}

/// One table entry of a release manifest.
public struct SDETable: Sendable, Hashable, Codable {
    /// Content hash of the table. It changes only when the table's data changes, so a table can be
    /// unchanged across several releases.
    public var version: String
    /// The whole table as JSON Lines (manifest key `jsonl.url`).
    public var jsonlURL: URL?
    /// URL template for one record, with a `{key}` placeholder (manifest key `record.urlTemplate`).
    public var recordURLTemplate: String?

    /// Creates a table description.
    public init(version: String, jsonlURL: URL?, recordURLTemplate: String?) {
        self.version = version
        self.jsonlURL = jsonlURL
        self.recordURLTemplate = recordURLTemplate
    }

    private enum CodingKeys: String, CodingKey { case version, jsonl, record }
    private struct JSONL: Codable { var url: URL? }
    private struct Record: Codable { var urlTemplate: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        jsonlURL = try c.decodeIfPresent(JSONL.self, forKey: .jsonl)?.url
        recordURLTemplate = try c.decodeIfPresent(Record.self, forKey: .record)?.urlTemplate
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        if let jsonlURL { try c.encode(JSONL(url: jsonlURL), forKey: .jsonl) }
        if let recordURLTemplate { try c.encode(Record(urlTemplate: recordURLTemplate), forKey: .record) }
    }
}

enum ISO8601 {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func format(_ date: Date) -> String { date.formatted(.iso8601) }
}
