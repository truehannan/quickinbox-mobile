import Foundation
import Security

/// Synchronous Keychain wrapper. SecItem calls are blocking and thread-safe, so an actor
/// only added scheduling latency on the launch path.
final class CredentialStore: Sendable {
    private let service: String
    private let account = "mobile-session"

    init(service: String = Bundle.main.bundleIdentifier ?? "QuickInbox") {
        self.service = service
    }

    func load() throws -> Credential? {
        try load(accountID: account)
    }

    func load(accountID: String) throws -> Credential? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychain(status)
        }

        do {
            return try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            try? delete(accountID: accountID)
            throw CredentialStoreError.corruptCredential
        }
    }

    func save(_ credential: Credential) throws {
        try save(credential, accountID: account)
    }

    func save(_ credential: Credential, accountID: String) throws {
        let data = try JSONEncoder().encode(credential)
        var attributes = baseQuery(accountID: accountID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialStoreError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

    func delete() throws {
        try delete(accountID: account)
    }

    func delete(accountID: String) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID == account ? account : "\(account):\(accountID)"
        ]
    }

    func hasLegacyCredential() -> Bool {
        (try? load()) != nil
    }

    func migrateLegacyCredential(accountID: String) throws -> Credential? {
        guard let legacy = try load() else { return nil }
        try save(legacy, accountID: accountID)
        try delete()
        return legacy
    }
}

nonisolated enum CredentialStoreError: LocalizedError, Sendable {
    case keychain(OSStatus)
    case corruptCredential

    var errorDescription: String? {
        switch self {
        case .keychain: "QuickInbox could not access its secure credential storage."
        case .corruptCredential: "The saved QuickInbox session was invalid and has been removed."
        }
    }
}
