import Foundation
import IPTVCore
import Observation

/// Device-local category navigation state of Movies/Series (docs/SCREENS.md §3.2), per source AND kind –
/// Xtream VOD and series category ids can collide, so nothing here is keyed by source alone:
/// selected country, pinned categories (ordered), recently opened (last 5, newest first), hidden.
/// Not synced. Live TV keeps its own hidden categories (HiddenStore) unchanged.
@MainActor
@Observable
public final class CategoryPreferences {
    /// Value of the stored country when the user chose "All".
    public nonisolated static let allCountries = "all"
    public nonisolated static let recentLimit = 5

    struct Entry: Codable, Equatable {
        /// ISO code, `allCountries`, or nil = never chosen (device-language default applies).
        var country: String?
        var pinned: [String] = []
        var recent: [String] = []
        var hidden: [String] = []
    }

    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private var entries: [String: Entry] = [:]
    /// Bumped on every change (views observe it).
    public private(set) var version = 0

    public init(kv: any KeyValueStore) {
        self.kv = kv
    }

    static func key(sourceId: String, kind: CategoryKind) -> String { "catnav.\(kind.rawValue).\(sourceId)" }

    private func entry(_ sourceId: String, _ kind: CategoryKind) -> Entry {
        _ = version   // every read registers an observation dependency (the cache itself is not observed)
        let key = Self.key(sourceId: sourceId, kind: kind)
        if let cached = entries[key] { return cached }
        let loaded = kv.value(Entry.self, forKey: key) ?? Entry()
        entries[key] = loaded
        return loaded
    }

    private func update(_ sourceId: String, _ kind: CategoryKind, _ change: (inout Entry) -> Void) {
        var e = entry(sourceId, kind)
        let before = e
        change(&e)
        guard e != before else { return }
        let key = Self.key(sourceId: sourceId, kind: kind)
        entries[key] = e
        kv.setValue(e, forKey: key)
        version += 1
    }

    // MARK: Country

    /// Stored choice: ISO code, `allCountries`, or nil when the user never picked one.
    public func storedCountry(sourceId: String, kind: CategoryKind) -> String? {
        entry(sourceId, kind).country
    }

    /// `nil` = All.
    public func setCountry(_ code: String?, sourceId: String, kind: CategoryKind) {
        update(sourceId, kind) { $0.country = code ?? Self.allCountries }
    }

    /// Country of the UI language: tr → TR, de → DE; English (and anything else) → nil = All.
    public nonisolated static func languageCountry(_ languageCode: String?) -> String? {
        switch languageCode?.lowercased() {
        case "tr": return "TR"
        case "de": return "DE"
        default: return nil
        }
    }

    /// Effective country (nil = All). `available` = countries that have visible (non-hidden) categories
    /// with content in this kind. A stored country that no longer has any falls back to All; without a
    /// stored choice the UI language's country is used when it has categories, else All.
    public func effectiveCountry(sourceId: String, kind: CategoryKind, available: Set<String>, languageCode: String?) -> String? {
        Self.resolveCountry(stored: storedCountry(sourceId: sourceId, kind: kind), available: available, languageCode: languageCode)
    }

    public nonisolated static func resolveCountry(stored: String?, available: Set<String>, languageCode: String?) -> String? {
        if let stored {
            if stored == allCountries { return nil }
            return available.contains(stored) ? stored : nil
        }
        guard let preferred = languageCountry(languageCode), available.contains(preferred) else { return nil }
        return preferred
    }

    // MARK: Pinned / recent

    public func pinned(sourceId: String, kind: CategoryKind) -> [String] { entry(sourceId, kind).pinned }

    public func isPinned(_ categoryId: String, sourceId: String, kind: CategoryKind) -> Bool {
        entry(sourceId, kind).pinned.contains(categoryId)
    }

    /// Pins at the end / unpins.
    public func togglePin(_ categoryId: String, sourceId: String, kind: CategoryKind) {
        update(sourceId, kind) { e in
            if let i = e.pinned.firstIndex(of: categoryId) { e.pinned.remove(at: i) } else { e.pinned.append(categoryId) }
        }
    }

    public func recent(sourceId: String, kind: CategoryKind) -> [String] { entry(sourceId, kind).recent }

    /// A category was opened: first in "recent", at most `recentLimit` kept.
    public func recordOpened(_ categoryId: String, sourceId: String, kind: CategoryKind) {
        update(sourceId, kind) { e in
            e.recent.removeAll { $0 == categoryId }
            e.recent.insert(categoryId, at: 0)
            if e.recent.count > Self.recentLimit { e.recent.removeLast(e.recent.count - Self.recentLimit) }
        }
    }

    // MARK: Hidden

    public func hidden(sourceId: String, kind: CategoryKind) -> Set<String> { Set(entry(sourceId, kind).hidden) }

    public func isHidden(_ categoryId: String, sourceId: String, kind: CategoryKind) -> Bool {
        entry(sourceId, kind).hidden.contains(categoryId)
    }

    /// Hiding also unpins (a hidden category is not offered anywhere until shown again).
    public func setHidden(_ hidden: Bool, categoryId: String, sourceId: String, kind: CategoryKind) {
        update(sourceId, kind) { e in
            e.hidden.removeAll { $0 == categoryId }
            if hidden {
                e.hidden.append(categoryId)
                e.pinned.removeAll { $0 == categoryId }
            }
        }
    }

    /// Forgets everything of a source (source deleted).
    public func removeAll(sourceId: String) {
        for kind in [CategoryKind.movie, .series] {
            let key = Self.key(sourceId: sourceId, kind: kind)
            entries[key] = nil
            kv.set(nil, forKey: key)
        }
        version += 1
    }
}
