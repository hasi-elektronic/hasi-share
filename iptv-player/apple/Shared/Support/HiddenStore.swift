import Foundation
import Observation

/// Hidden channels / categories per source (SCREENS §3.3). Local only (UserDefaults, not synced).
@MainActor
@Observable
final class HiddenStore {
    static let shared = HiddenStore(defaults: AppBootstrap.defaults)

    private(set) var channels: [String: Set<String>] = [:]
    private(set) var categories: [String: Set<String>] = [:]
    @ObservationIgnored private let defaults: UserDefaults

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
    }

    func hideCategory(_ id: String, sourceId: String) {
        load(sourceId)
        categories[sourceId, default: []].insert(id)
        defaults.set(Array(categories[sourceId] ?? []), forKey: key("categories", sourceId))
    }

    func showAll(sourceId: String) {
        channels[sourceId] = []
        categories[sourceId] = []
        defaults.removeObject(forKey: key("channels", sourceId))
        defaults.removeObject(forKey: key("categories", sourceId))
    }

    func isHidden(channelId: String, categoryId: String?, sourceId: String) -> Bool {
        hiddenChannels(sourceId).contains(channelId) || categoryId.map { hiddenCategories(sourceId).contains($0) } ?? false
    }
}
