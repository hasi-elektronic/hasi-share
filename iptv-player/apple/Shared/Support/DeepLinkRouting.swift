import Foundation
import IPTVCore
import IPTVKit

/// `novaplayer://` deep links (Build 17, Top Shelf): the item opens directly in the player – a channel with its
/// category as zapping list, a movie / episode resumed where it was left. The link's source becomes the current one.
/// Unknown links or items that are gone are ignored (logged, nothing opens).
extension Router {
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let parsed = DeepLink(url: url) else {
            SafeLog.info("deep link ignored (not a novaplayer link)")
            return false
        }
        let link = testSourceAlias(parsed)
        guard let target = env.playbackTarget(for: link) else {
            if catalogStillLoading {
                // Cold start from the Top Shelf while sources load / a purged catalog is restored: try again later.
                pendingDeepLink = (url, Date())
                SafeLog.info("deep link: catalog still loading – pending")
            } else {
                pendingDeepLink = nil
                SafeLog.warning("deep link: item or source not found")
            }
            return false
        }
        pendingDeepLink = nil
        if env.settings.currentSourceId != link.sourceId { env.selectSource(link.sourceId) }
        paywallPresented = false
        #if !os(tvOS)
        settingsPresented = false
        #endif
        SafeLog.info("deep link → player")
        play(target.item, channels: target.channels)
        return true
    }
}

extension Router {
    /// Pending links are kept this long.
    static let pendingDeepLinkLifetime: TimeInterval = 60

    /// The catalog changed (`catalogVersion`): a link that came in too early is tried again.
    func retryPendingDeepLink(now: Date = Date()) {
        guard let pending = pendingDeepLink else { return }
        guard now.timeIntervalSince(pending.at) < Self.pendingDeepLinkLifetime else {
            pendingDeepLink = nil
            return
        }
        open(pending.url)
    }

    /// No sources yet, sources being restored or refreshed, or the launch work not done.
    var catalogStillLoading: Bool {
        env.sources.isEmpty || env.isRestoringCatalog || !env.refreshing.isEmpty || !env.hasStarted
    }
}

private extension Router {
    /// DEBUG UI tests (in-memory source with a random id): the source "uitest-current" names the current source.
    func testSourceAlias(_ link: DeepLink) -> DeepLink {
        #if DEBUG
        if AppBootstrap.arguments.contains("-uiTestReset"), link.sourceId == "uitest-current", let current = env.currentSource?.id {
            return link.withSource(current)
        }
        #endif
        return link
    }
}

#if DEBUG
private extension DeepLink {
    func withSource(_ sourceId: String) -> DeepLink {
        switch self {
        case .channel(_, let id): return .channel(sourceId: sourceId, channelId: id)
        case .movie(_, let id): return .movie(sourceId: sourceId, movieId: id)
        case .episode(_, let series, let id): return .episode(sourceId: sourceId, seriesId: series, episodeId: id)
        }
    }
}
#endif
