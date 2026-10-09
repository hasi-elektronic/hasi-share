import Foundation
import IPTVKit
import Observation

/// Hidden channels / categories per source (SCREENS §3.3). UserDefaults; synced through iCloud when the user has
/// "Sync with iCloud" on (Build 17, `CloudSync`).
@MainActor
@Observable
final class HiddenStore {
    static let shared = HiddenStore(defaults: AppBootstrap.defaults)

    private(set) var channels: [String: Set<String>] = [:]
    private(set) var categories: [String: Set<String>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after a user change (iCloud sync).
    @ObservationIgnored var onChange: @MainActor () -> Void = {}

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(_ kind: String, _ sourceId: String) -> String { "hidden.\(kind).\(sourceId)" }

    private func load(_ sourceId: String) {
        if channels[sourceId] == nil {
            channels[sourceId] = Set(defaults.stringArray(forKey: key("channels", sourceId)) ?? [])
            categories[sourceId] = Set(defaults.stringArray(forKey: key("categories", sourceId)) ?? [])
        }
    }

    // Read-only (no state mutation during view updates): falls back to UserDefaults until first change.
    func hiddenChannels(_ sourceId: String) -> Set<String> {
        channels[sourceId] ?? Set(defaults.stringArray(forKey: key("channels", sourceId)) ?? [])
    }

    func hiddenCategories(_ sourceId: String) -> Set<String> {
        categories[sourceId] ?? Set(defaults.stringArray(forKey: key("categories", sourceId)) ?? [])
    }
    func count(_ sourceId: String) -> Int { hiddenChannels(sourceId).count + hiddenCategories(sourceId).count }

    func hideChannel(_ id: String, sourceId: String) {
        load(sourceId)
        channels[sourceId, default: []].insert(id)
        defaults.set(Array(channels[sourceId] ?? []), forKey: key("channels", sourceId))
        onChange()
    }

    func hideCategory(_ id: String, sourceId: String) {
        load(sourceId)
        categories[sourceId, default: []].insert(id)
        defaults.set(Array(categories[sourceId] ?? []), forKey: key("categories", sourceId))
        onChange()
    }

    func showAll(sourceId: String) {
        channels[sourceId] = []
        categories[sourceId] = []
        defaults.removeObject(forKey: key("channels", sourceId))
        defaults.removeObject(forKey: key("categories", sourceId))
        onChange()
    }

    func isHidden(channelId: String, categoryId: String?, sourceId: String) -> Bool {
        hiddenChannels(sourceId).contains(channelId) || categoryId.map { hiddenCategories(sourceId).contains($0) } ?? false
    }
}

/// iCloud sync (Build 17): hidden live channels and categories per source.
extension HiddenStore: CloudPreferenceProvider {
    private static let cloudChannels = "live.hide.ch"
    private static let cloudCategories = "live.hide.cat"

    var cloudPreferenceNames: Set<String> { [Self.cloudChannels, Self.cloudCategories] }

    func cloudPreferences() -> [CloudPreferenceKey: [String]] {
        var out: [CloudPreferenceKey: [String]] = [:]
        for name in defaults.dictionaryRepresentation().keys {
            if name.hasPrefix("hidden.channels.") {
                let sourceId = String(name.dropFirst("hidden.channels.".count))
                out[CloudPreferenceKey(Self.cloudChannels, sourceId: sourceId)] = hiddenChannels(sourceId).sorted()
            } else if name.hasPrefix("hidden.categories.") {
                let sourceId = String(name.dropFirst("hidden.categories.".count))
                out[CloudPreferenceKey(Self.cloudCategories, sourceId: sourceId)] = hiddenCategories(sourceId).sorted()
            }
        }
        return out
    }

    func applyCloudPreferences(_ values: [CloudPreferenceKey: [String]]) {
        for (key, value) in values {
            guard let sourceId = key.sourceId else { continue }
            let kind = key.name == Self.cloudChannels ? "channels" : "categories"
            if value.isEmpty { defaults.removeObject(forKey: self.key(kind, sourceId)) } else { defaults.set(value, forKey: self.key(kind, sourceId)) }
            if kind == "channels" { channels[sourceId] = Set(value) } else { categories[sourceId] = Set(value) }
        }
    }
}
