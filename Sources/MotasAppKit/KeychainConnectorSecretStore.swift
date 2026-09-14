import Foundation
import Security
import LocalAuthentication
import MotasCore

public enum KeychainConnectorSecretStoreError: Error, Equatable {
    case unexpected(OSStatus)
}

/// Concrete macOS Keychain secret store.
///
/// Generic-password items are scoped to a stable service name, this-device-only
/// and un-synchronized. Reads never trigger authentication UI, so automatic
/// refresh never presents a surprise Keychain prompt. Errors never include
/// secret values, query dictionaries or returned data.
public struct KeychainConnectorSecretStore: ConnectorSecretStore {
    public init() {}

    private var readContextual: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecUseAuthenticationContext as String: context]
    }

    public func value(for key: ConnectorSecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query.merge(readContextual) { _, new in new }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainConnectorSecretStoreError.unexpected(status)
        }
    }

    public func set(_ value: String, for key: ConnectorSecretKey) throws {
        let data = Data(value.utf8)
        let base = baseQuery(for: key)

        let updateQuery = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, updateQuery as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = base
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainConnectorSecretStoreError.unexpected(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainConnectorSecretStoreError.unexpected(updateStatus)
        }
    }

    public func removeValue(for key: ConnectorSecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainConnectorSecretStoreError.unexpected(status)
        }
    }

    public func containsValue(for key: ConnectorSecretKey) throws -> Bool {
        // Query metadata only; never request password data.
        var query = baseQuery(for: key)
        query.merge(readContextual) { _, new in new }
        query[kSecReturnData as String] = false
        query[kSecReturnAttributes as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainConnectorSecretStoreError.unexpected(status)
        }
    }

    private func baseQuery(for key: ConnectorSecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MotasConfiguration.keychainService,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}