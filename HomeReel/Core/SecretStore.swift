import Foundation

/// Where the Plex token lives. The real one is the Keychain; tests use memory.
protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    @discardableResult func set(_ value: String, for key: String) -> Bool
    func remove(_ key: String)
}

struct KeychainSecretStore: SecretStore {
    func get(_ key: String) -> String? { Keychain.get(key) }
    @discardableResult func set(_ value: String, for key: String) -> Bool { Keychain.set(value, for: key) }
    func remove(_ key: String) { Keychain.remove(key) }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    init(_ initial: [String: String] = [:]) { values = initial }
    func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    @discardableResult func set(_ value: String, for key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[key] = value; return true }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}
