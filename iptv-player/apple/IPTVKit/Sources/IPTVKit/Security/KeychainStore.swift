import Foundation
import Security

/// Small secure key/value store abstraction (Keychain in the app, memory in tests).
public protocol SecureStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String) throws
}

extension SecureStore {
    public func string(forKey key: String) -> String? { data(forKey: key).flatMap { String(data: $0, encoding: .utf8) } }
    public func setString(_ value: String?, forKey key: String) throws { try set(value.map { Data($0.utf8) }, forKey: key) }

    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func setValue<T: Encodable>(_ value: T?, forKey key: String) throws {
        try set(value.map { try JSONEncoder().encode($0) }, forKey: key)
    }
}

/// Keychain failure.
public struct KeychainError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// A secure store whose items can also live in iCloud Keychain (Build 17 "iCloud sync", docs/SECURITY.md §1).
///
/// `set(_:forKey:)` keeps writing device-only items. `set(_:forKey:synchronizable: true)` writes an iCloud Keychain
/// item (`kSecAttrSynchronizable`, end-to-end encrypted, `kSecAttrAccessibleAfterFirstUnlock` – synchronizable items
/// cannot be `…ThisDeviceOnly`) and removes the device-only copy; deleting that way removes the item on every
/// device. Reads prefer the device-only item.
public protocol CloudSecretStore: SecureStore {
    func set(_ data: Data?, forKey key: String, synchronizable: Bool) throws
    /// Moves the existing item of `key` into iCloud Keychain (`true`: the device-only copy is removed) or copies it
    /// back to a device-only item (`false`: the iCloud copy stays for the user's other devices). No item: no-op.
    func convert(key: String, toSynchronizable: Bool) throws
}

/// Generic-password Keychain items. Device-only items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (never migrated to other devices / backups – docs/SECURITY.md §1); source secrets of a user with iCloud sync on
/// are synchronizable (`CloudSecretStore`).
public struct KeychainStore: CloudSecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ key: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any]
    }

    private func read(_ key: String, synchronizable: Bool) -> Data? {
        var query = baseQuery(key, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func data(forKey key: String) -> Data? {
        read(key, synchronizable: false) ?? read(key, synchronizable: true)
    }

    private func write(_ data: Data, key: String, synchronizable: Bool) throws {
        let query = baseQuery(key, synchronizable: synchronizable)
        let accessible = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(_ key: String, synchronizable: Bool) throws {
        let status = SecItemDelete(baseQuery(key, synchronizable: synchronizable) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func set(_ data: Data?, forKey key: String) throws {
        try set(data, forKey: key, synchronizable: false)
    }

    public func set(_ data: Data?, forKey key: String, synchronizable sync: Bool) throws {
        guard let data else {
            try delete(key, synchronizable: false)
            if sync { try delete(key, synchronizable: true) }   // gone on every device (the source was deleted)
            return
        }
        try write(data, key: key, synchronizable: sync)
        if sync { try delete(key, synchronizable: false) }   // one item per key: the iCloud one
    }

    public func convert(key: String, toSynchronizable: Bool) throws {
        if toSynchronizable {
            guard let local = read(key, synchronizable: false) else { return }
            try write(local, key: key, synchronizable: true)
            try delete(key, synchronizable: false)
        } else {
            guard read(key, synchronizable: false) == nil, let synced = read(key, synchronizable: true) else { return }
            try write(synced, key: key, synchronizable: false)
        }
    }

    /// Removes every item of this service, device-only and iCloud ones (UI-test sandboxes).
    public func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrSynchronizable as String: kSecAttrSynchronizableAny] as CFDictionary)
    }
}

/// In-memory store for tests and previews (no iCloud: synchronizable items are ordinary items).
public final class InMemorySecureStore: CloudSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data?, forKey key: String, synchronizable: Bool) throws { try set(data, forKey: key) }
    public func convert(key: String, toSynchronizable: Bool) throws {}

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ data: Data?, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }
}

/// Plain (non-secret) key/value persistence – UserDefaults in the app, memory in tests.
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    /// Stored keys starting with `prefix` (bulk resets, e.g. all audio delays).
    func keys(withPrefix prefix: String) -> [String]
}

extension KeyValueStore {
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    public func setValue<T: Encodable>(_ value: T?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// `UserDefaults`-backed store.
public struct UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    public func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }
}

/// In-memory key/value store (tests).
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }
    public func keys(withPrefix prefix: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.filter { $0.hasPrefix(prefix) }
    }
}
