import Foundation
import Security

protocol CredentialStore: Sendable {
    func save(_ value: String) throws
    func load() throws -> String?
    func clear() throws
}

enum CredentialStoreError: Error {
    case emptyValue
    case invalidStoredValue
    case keychain(OSStatus)
}

struct KeychainCredentialStore: CredentialStore {
    private let account: String

    init(account: String = AppConfiguration.keychainAccount) {
        self.account = account
    }

    func save(_ value: String) throws {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw CredentialStoreError.emptyValue }

        try clear()
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: AppConfiguration.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(credential.utf8)
        ] as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
    }

    func load() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: AppConfiguration.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        return value
    }

    func clear() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: AppConfiguration.keychainService,
            kSecAttrAccount: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func save(_ value: String) throws {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw CredentialStoreError.emptyValue }
        lock.withLock { self.value = credential }
    }

    func load() throws -> String? {
        lock.withLock { value }
    }

    func clear() throws {
        lock.withLock { value = nil }
    }
}
