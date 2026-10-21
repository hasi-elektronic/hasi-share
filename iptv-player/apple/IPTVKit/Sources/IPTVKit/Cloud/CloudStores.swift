import Foundation

/// Why the iCloud key-value store changed under us (`NSUbiquitousKeyValueStore` change reasons).
public enum CloudStoreChange: Sendable, Equatable {
    /// Another device wrote values.
    case serverChange
    /// First download after the app was installed / the account was set up.
    case initialSync
    /// The app is over its 1 MB / 1024 keys: the last writes were not stored.
    case quotaViolation
    /// The iCloud account changed (values of the new account replaced the old ones).
    case accountChange
}

/// The small iCloud key/value store the sync uses (`NSUbiquitousKeyValueStore` in the app, fakes in tests).
public protocol CloudKeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    /// Asks the system to upload / download soon (never blocks).
    func synchronize()
    /// `handler` runs on any thread for every external change (keys that changed).
    func observe(_ handler: @escaping @Sendable (CloudStoreChange, [String]) -> Void)
}

/// Whether an iCloud account is signed in (`FileManager.ubiquityIdentityToken`).
public protocol CloudAccountProvider: AnyObject, Sendable {
    var isAvailable: Bool { get }
    /// `handler` runs on any thread when the account signs in / out / changes.
    func observe(_ handler: @escaping @Sendable () -> Void)
}

/// `NSUbiquitousKeyValueStore.default` – needs the `com.apple.developer.ubiquity-kvstore-identifier` entitlement
/// (without it, e.g. an unsigned simulator build, values simply stay on the device).
public final class UbiquitousKeyValueStore: CloudKeyValueStore, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    public func data(forKey key: String) -> Data? { store.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { store.set(data, forKey: key) } else { store.removeObject(forKey: key) }
    }

    public func synchronize() { store.synchronize() }

    public func observe(_ handler: @escaping @Sendable (CloudStoreChange, [String]) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                           object: store, queue: nil) { note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let change: CloudStoreChange
            switch note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
            case NSUbiquitousKeyValueStoreInitialSyncChange: change = .initialSync
            case NSUbiquitousKeyValueStoreQuotaViolationChange: change = .quotaViolation
            case NSUbiquitousKeyValueStoreAccountChange: change = .accountChange
            default: change = .serverChange
            }
            handler(change, keys)
        }
        lock.lock(); tokens.append(token); lock.unlock()
    }
}

/// iCloud account presence via `FileManager.ubiquityIdentityToken` (+ `NSUbiquityIdentityDidChange`).
public final class UbiquityAccount: CloudAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    public var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    public func observe(_ handler: @escaping @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { _ in
            handler()
        }
        lock.lock(); tokens.append(token); lock.unlock()
    }
}

/// A fixed account state (tests, UI tests, previews).
public final class StaticCloudAccount: CloudAccountProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool
    private var handlers: [@Sendable () -> Void] = []

    public init(available: Bool) { self.available = available }

    public var isAvailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return available }
        set {
            lock.lock(); available = newValue; let list = handlers; lock.unlock()
            list.forEach { $0() }
        }
    }

    public func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }
}

/// A single-device in-memory "iCloud" store (UI tests, previews, unit tests without a second device). `quotaBytes`
/// mimics the 1 MB limit: a write that would exceed it is dropped and a `.quotaViolation` is reported.
public final class InMemoryCloudKeyValueStore: CloudKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var handlers: [@Sendable (CloudStoreChange, [String]) -> Void] = []
    public let quotaBytes: Int

    public init(quotaBytes: Int = CloudSyncLimits.quotaBytes) { self.quotaBytes = quotaBytes }

    public func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        var next = values
        next[key] = data
        let total = next.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
        guard total <= quotaBytes else {
            let list = handlers
            lock.unlock()
            list.forEach { $0(.quotaViolation, [key]) }
            return
        }
        values = next
        lock.unlock()
    }

    public func synchronize() {}

    public func observe(_ handler: @escaping @Sendable (CloudStoreChange, [String]) -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }

    /// Simulates a change made by another device (tests / UI-test seeding).
    public func receive(_ data: Data?, forKey key: String) {
        lock.lock(); values[key] = data; let list = handlers; lock.unlock()
        list.forEach { $0(.serverChange, [key]) }
    }

    public var totalBytes: Int { lock.lock(); defer { lock.unlock() }; return values.reduce(0) { $0 + $1.key.utf8.count + $1.value.count } }
}

/// A Bool shared across threads (flags of `Sendable` types).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool = false) { flag = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}
