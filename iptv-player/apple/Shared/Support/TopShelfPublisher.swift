#if os(tvOS)
import Foundation
import IPTVCore
import IPTVKit
import Security
import TVServices

/// Writes the Top Shelf snapshot (Build 17, docs/ARCHITECTURE.md §3.4): debounced after library / catalog / source /
/// language changes and right away when the app goes to the background. Only a changed snapshot is written; then the
/// system is told to reload the shelf (`topShelfContentDidChange`).
@MainActor
final class TopShelfPublisher {
    static let shared = TopShelfPublisher()

    /// Changes are batched (progress is saved every 10 s while a film plays).
    static let debounce: Duration = .seconds(5)

    private let store = TopShelfStore(accessGroup: TopShelfStore.bundleAccessGroup())
    private var pending: Task<Void, Never>?
    private var lastWritten: Data?
    private var warned = false

    func schedule(_ env: AppEnvironment) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.publish(env)
        }
    }

    func publish(_ env: AppEnvironment) {
        pending?.cancel()
        pending = nil
        guard store.accessGroup != nil else {
            if !warned { SafeLog.warning("top shelf: no shared keychain group in Info.plist"); warned = true }
            return
        }
        let labels = TopShelfLabels(
            continueTitle: L10n.t("home_continue"),
            recentTitle: L10n.t("home_recent_channels"),
            movieTitle: { MediaTags.clean($0).title },
            episodeTitle: { series, e in "\(series) · \(L10n.t("episode_short", String(e.season), String(e.number)))" },
            isHidden: { HiddenStore.shared.isHidden(channelId: $0.id, categoryId: $0.categoryId, sourceId: $0.sourceId) })
        let data = env.topShelfSnapshot(labels).encoded()
        guard data != lastWritten else { return }
        let status = store.write(data)
        guard status == errSecSuccess else {
            if !warned { SafeLog.warning("top shelf: keychain write failed (\(status))"); warned = true }
            return
        }
        lastWritten = data
        TVTopShelfContentProvider.topShelfContentDidChange()
        SafeLog.info("top shelf updated (\(data.count) bytes)")
    }
}
#endif
