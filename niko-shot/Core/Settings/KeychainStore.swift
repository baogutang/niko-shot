// Stores translation credentials in the user's macOS Keychain without logging secret material.
import Foundation
import Security

/// A synchronous, thread-safe facade over generic-password Keychain items.
public struct KeychainStore: Sendable {
    /// The single service namespace used for every niko-shot credential.
    public static let service = "com.n1ko.niko-shot"
    private let testValues: [String: String]?

    /// Creates a store backed by the current user's Keychain.
    public init() { testValues = nil }

    // Immutable injected fixtures isolate network tests from real user credentials.
    init(testValues: [String: String]) { self.testValues = testValues }

    /// Reads a UTF-8 credential; missing or inaccessible items return nil.
    public func get(_ account: String) -> String? {
        if let testValues { return testValues[account] }
        var query = identity(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Atomically adds or updates a credential; an empty value deletes the item.
    public func set(_ value: String, account: String) throws {
        guard testValues == nil else { throw KeychainError.status(errSecReadOnly) }
        let query = identity(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        if add == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retry == errSecSuccess else { throw KeychainError.status(retry) }
        } else if add != errSecSuccess { throw KeychainError.status(add) }
    }

    private func identity(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }
}

/// A Keychain status translated into a user-readable system error.
public enum KeychainError: Error, LocalizedError, Sendable {
    /// The OSStatus returned by Security.framework.
    case status(OSStatus)
    /// Explains why the Keychain operation failed without exposing its value.
    public var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误"
            return "\(message)（\(status)）"
        }
    }
}
