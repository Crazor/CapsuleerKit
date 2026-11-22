import Foundation

/// A `TokenStore` that keeps credentials in memory, for tests and previews.
public actor InMemoryTokenStore: TokenStore {
    private var credentials: [Int64: StoredCredential]

    public init(_ credentials: [StoredCredential] = []) {
        self.credentials = Dictionary(credentials.map { ($0.character.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func load(characterID: Int64) async throws -> StoredCredential? { credentials[characterID] }

    public func loadAll() async throws -> [StoredCredential] {
        credentials.values.sorted { $0.character.id < $1.character.id }
    }

    public func save(_ credential: StoredCredential) async throws { credentials[credential.character.id] = credential }

    public func delete(characterID: Int64) async throws { credentials[characterID] = nil }
}
