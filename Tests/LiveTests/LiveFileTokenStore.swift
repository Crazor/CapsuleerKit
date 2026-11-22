import ESIKit
import Foundation

/// Copy of the CLI's FileTokenStore (same file format), so live tests can use `capsuleer esi login` output.
/// Not for apps.
actor LiveFileTokenStore: TokenStore {
    let url: URL

    init(url: URL) { self.url = url }

    func load(characterID: Int64) async throws -> StoredCredential? { try read()[String(characterID)] }

    func loadAll() async throws -> [StoredCredential] {
        try read().values.sorted { $0.character.name < $1.character.name }
    }

    func save(_ credential: StoredCredential) async throws {
        var all = try read()
        all[String(credential.character.id)] = credential
        try write(all)
    }

    func delete(characterID: Int64) async throws {
        var all = try read()
        all[String(characterID)] = nil
        try write(all)
    }

    private func read() throws -> [String: StoredCredential] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: StoredCredential].self, from: Data(contentsOf: url))
    }

    /// Writes a 0600 temp file next to the target and renames it over the target, so the tokens
    /// are never readable by other users, not even briefly.
    private func write(_ all: [String: StoredCredential]) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(all)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
