import Foundation
import Security

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self { case .keychain(let status): "Keychain error \(status)." }
    }
}

actor CredentialStore {
    enum Kind: String, Sendable {
        case komgaAPIKey
        case kavitaAuthKey
        case aniListToken
        case myAnimeListToken
        case myAnimeListRefreshToken
        case serverSetup
        case trackerSetup
        case homeState
        case readingStatistics
        case trackerLinks
        case trackerPromptState
    }
    private let service = Bundle.main.bundleIdentifier ?? "com.example.Tsundoku"

    func save(_ value: String, kind: Kind, account: String, synchronizable: Bool = true) throws {
        try delete(kind: kind, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    func value(kind: Kind, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    func delete(kind: Kind, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }
}
