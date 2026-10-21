import Foundation
import Security

// Foundation + Security only: compiled into IPTVKit AND into the tvOS Top Shelf extension.

/// The shared Keychain item that carries the `TopShelfSnapshot` from the app to its Top Shelf extension (Build 17).
///
/// Why the Keychain: an App Group would need an extra App ID capability and profile changes; a Keychain access group
/// under the team prefix (`keychain-access-groups` entitlement on app + extension) is covered by the default
/// provisioning profiles. The app lists its own application identifier FIRST in `keychain-access-groups`, so every
/// other Keychain item (source secrets, account token) keeps its default group – only this item is written into the
/// shared group, explicitly.
public struct TopShelfStore: Sendable {
    /// Info.plist key holding the full access group (`$(AppIdentifierPrefix)com.hasielektronic.novaplayer.shared`).
    public static let accessGroupInfoKey = "TopShelfKeychainGroup"
    public static let service = "com.hasielektronic.novaplayer.topshelf"
    public static let account = "snapshot.v1"

    /// nil = no access group (unit tests on macOS: the login keychain of the test process).
    public let accessGroup: String?
    public let service: String

    public init(accessGroup: String?, service: String = TopShelfStore.service) {
        self.accessGroup = accessGroup
        self.service = service
    }

    /// The group named in the bundle's Info.plist (app or extension); nil when missing or unexpanded.
    public static func bundleAccessGroup(_ bundle: Bundle = .main) -> String? {
        guard let value = (bundle.object(forInfoDictionaryKey: accessGroupInfoKey) as? String)?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty, !value.contains("$(") else { return nil }
        // Simulator builds without a team expand `$(AppIdentifierPrefix)` to nothing: a leading "." is dropped.
        return value.hasPrefix(".") ? String(value.dropFirst()) : value
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: Self.account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Writes (nil deletes). Returns the Keychain status (`errSecSuccess`, or e.g. `errSecMissingEntitlement` when the
    /// build carries no `keychain-access-groups`).
    @discardableResult
    public func write(_ data: Data?) -> OSStatus {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        // tvOS has no lock screen; "after first unlock" keeps it readable for the extension after a reboot.
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }
}
