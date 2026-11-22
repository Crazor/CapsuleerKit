#if canImport(Security)
import CapsuleerCore
import Foundation
import Security

/// Stores each character's `StoredCredential` as JSON in a generic-password Keychain item
/// (`service`, account = character ID), accessible after first unlock on this device only.
///
/// With an `accessGroup` (or `useDataProtectionKeychain: true`) the item lives in the data
/// protection keychain, which needs a signed app with keychain entitlements. Without, the macOS
/// file-based login keychain is used, which also works for unsigned command-line tools.
/// Keychain failures throw `CapsuleerError(.storage)`.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool

    public init(service: String, accessGroup: String? = nil, useDataProtectionKeychain: Bool? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain ?? (accessGroup != nil)
    }

    public func load(characterID: Int64) async throws -> StoredCredential? {
        var query = baseQuery(account: String(characterID))
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "read")
        guard let data = result as? Data else { throw CapsuleerError(.storage, message: "Keychain item has no data") }
        do {
            return try JSONDecoder().decode(StoredCredential.self, from: data)
        } catch {
            throw CapsuleerError(.storage, message: "Keychain item is not a stored credential", underlying: error)
        }
    }

    public func loadAll() async throws -> [StoredCredential] {
        // Attributes first, then one read per item: the file-based keychain can't return data
        // together with kSecMatchLimitAll.
        var query = baseQuery(account: nil)
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "list")
        let items = (result as? [[String: Any]]) ?? []
        let ids = items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Int64.init) }.sorted()
        var credentials: [StoredCredential] = []
        for id in ids {
            if let credential = try await load(characterID: id) { credentials.append(credential) }
        }
        return credentials
    }

    public func save(_ credential: StoredCredential) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw CapsuleerError(.storage, message: "Could not encode credential", underlying: error)
        }
        let query = baseQuery(account: String(credential.character.id))
        // Update in place (never delete-then-add: a failed add would lose the only refresh token).
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel: "\(service) (\(credential.character.name))",
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            try check(SecItemAdd(add as CFDictionary, nil), "add")
        } else {
            try check(status, "update")
        }
    }

    public func delete(characterID: Int64) async throws {
        let status = SecItemDelete(baseQuery(account: String(characterID)) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "delete")
    }

    private func baseQuery(account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account { query[kSecAttrAccount] = account }
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status != errSecSuccess else { return }
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        throw CapsuleerError(.storage, message: "Keychain \(operation) failed: \(text) (\(status))")
    }
}
#endif
