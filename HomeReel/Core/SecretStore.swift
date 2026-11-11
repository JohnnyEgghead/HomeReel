import Foundation

/// What reading one secret found.
enum SecretRead: Equatable, Sendable {
    case value(String)
    /// Nothing is stored under that name.
    case missing
    /// The store would not answer (the status is the Keychain's own code). The secret may well exist.
    case failed(Int32)
}

/// Where the Plex token lives. The real one is the Keychain; tests use memory.
protocol SecretStore: Sendable {
    func read(_ key: String) -> SecretRead
    @discardableResult func set(_ value: String, for key: String) -> Bool
    /// True when the secret is gone afterward: it was removed, or was never there.
    @discardableResult func remove(_ key: String) -> Bool
}

extension SecretStore {
    /// The value, or nil if it is missing OR could not be read. Where the difference matters, use `read`.
    func get(_ key: String) -> String? {
        if case .value(let v) = read(key) { return v }
        return nil
    }
}

struct KeychainSecretStore: SecretStore {
    func read(_ key: String) -> SecretRead { Keychain.read(key) }
    @discardableResult func set(_ value: String, for key: String) -> Bool { Keychain.set(value, for: key) }
    @discardableResult func remove(_ key: String) -> Bool { Keychain.remove(key) }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    init(_ initial: [String: String] = [:]) { values = initial }
    func read(_ key: String) -> SecretRead { lock.lock(); defer { lock.unlock() }; return values[key].map(SecretRead.value) ?? .missing }
    @discardableResult func set(_ value: String, for key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[key] = value; return true }
    @discardableResult func remove(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; values[key] = nil; return true }
}
