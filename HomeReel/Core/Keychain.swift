import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Secrets never go to UserDefaults, files, or logs.
enum Keychain {
    static let service = "com.johnloring.homereel"

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Update in place. Deleting first would lose the old value if the add then failed.
        let values: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        return SecItemAdd(base.merging(values) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    /// What reading one item found. "Missing" and "could not read" are different: the second must never be
    /// taken for a signed-out Apple TV.
    static func read(_ key: String) -> SecretRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = out as? Data, let text = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
        return .value(text)
    }

    /// The value, or nil if it is missing or could not be read. Where the difference matters, use `read`.
    static func get(_ key: String) -> String? {
        if case .value(let v) = read(key) { return v }
        return nil
    }

    /// True when the item is gone afterward: it was deleted, or was never there.
    @discardableResult
    static func remove(_ key: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
