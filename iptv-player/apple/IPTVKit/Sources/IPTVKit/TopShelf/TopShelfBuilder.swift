import Foundation
import IPTVCore

/// What the app adds to a Top Shelf snapshot: localized section titles, title cleaning and the channels it hides
/// (Build 17, docs/ARCHITECTURE.md §3.4).
public struct TopShelfLabels {
    public var continueTitle: String
    public var recentTitle: String
    /// Movie name as shown in the app ("Film (2024) HD" → "Film").
    public var movieTitle: (String) -> String
    /// "Series · S1 E2".
    public var episodeTitle: (_ seriesTitle: String, _ episode: Episode) -> String
    /// Channels the user hid (and, later, locked) never reach the home screen.
    public var isHidden: (Channel) -> Bool

    public init(continueTitle: String, recentTitle: String, movieTitle: @escaping (String) -> String = { $0 },
                episodeTitle: @escaping (String, Episode) -> String = { series, e in "\(series) · S\(e.season) E\(e.number)" },
                isHidden: @escaping (Channel) -> Bool = { _ in false }) {
        self.continueTitle = continueTitle
        self.recentTitle = recentTitle
        self.movieTitle = movieTitle
        self.episodeTitle = episodeTitle
        self.isHidden = isHidden
    }
}

extension AppEnvironment {
    /// Top Shelf content of the current source: "Continue watching" (≤ 10, with progress) and the channels watched last
    /// (≤ 10) – the same rules as the Home rows (`HomeViewModel`, CONTRACT §8).
    public func topShelfSnapshot(_ labels: TopShelfLabels) -> TopShelfSnapshot {
        guard let source = currentSource, let fingerprint = fingerprint(sourceId: source.id) else { return TopShelfSnapshot(sections: []) }
        let limit = TopShelfSnapshot.maxItemsPerSection
        let progress = ((try? library.progressItems()) ?? []).filter { $0.contentKey.hasPrefix(fingerprint + ":") }
        let home = HomeViewModel(env: self)

        var continueItems: [TopShelfSnapshot.Item] = []
        for entry in WatchHistory.continueWatching(progress, limit: limit * 2) where continueItems.count < limit {
            let link: DeepLink
            let title: String
            let image: String?
            switch home.item(for: entry) {
            case .movie(let movie)?:
                link = .movie(sourceId: movie.sourceId, movieId: movie.id)
                title = labels.movieTitle(movie.name)
                image = movie.posterUrl ?? entry.data.posterUrl
            case .episode(let episode, let seriesTitle)?:
                link = .episode(sourceId: episode.sourceId, seriesId: episode.seriesId, episodeId: episode.id)
                title = labels.episodeTitle(seriesTitle, episode)
                let series = (try? catalog.seriesItem(sourceId: episode.sourceId, id: episode.seriesId)) ?? nil
                image = series?.posterUrl ?? episode.posterUrl ?? entry.data.posterUrl
            default:
                continue
            }
            continueItems.append(TopShelfSnapshot.Item(id: link.identifier, title: title, imageURL: image, shape: .poster,
                                                       progress: entry.data.fraction, link: link.url.absoluteString))
        }

        let recentIds = WatchHistory.recentlyWatched(progress, kind: .live, limit: limit * 3).compactMap { ContentKey.parse($0.contentKey)?.itemId }
        let channels = ((try? catalog.channels(sourceId: source.id, ids: recentIds)) ?? []).filter { !labels.isHidden($0) }.prefix(limit)
        let recentItems = channels.map { channel -> TopShelfSnapshot.Item in
            let link = DeepLink.channel(sourceId: channel.sourceId, channelId: channel.id)
            return TopShelfSnapshot.Item(id: link.identifier, title: channel.name, imageURL: channel.logoUrl, shape: .square,
                                         progress: nil, link: link.url.absoluteString)
        }
        return TopShelfSnapshot(sections: [
            TopShelfSnapshot.Section(title: labels.continueTitle, items: continueItems),
            TopShelfSnapshot.Section(title: labels.recentTitle, items: Array(recentItems)),
        ].filter { !$0.items.isEmpty })
    }

    /// What a deep link plays: the item and (live) its zapping list – the channel's category (first 200), like
    /// QuickStart. nil when the source or the item is gone. An episode without a cached row is rebuilt from its
    /// progress entry; `Router.play` completes it (`playableEpisode`).
    public func playbackTarget(for link: DeepLink) -> (item: PlaybackRequest.Item, channels: [Channel])? {
        guard sources.contains(where: { $0.id == link.sourceId }) else { return nil }
        switch link {
        case .channel(let sid, let id):
            guard let channel = (try? catalog.channel(sourceId: sid, id: id)) ?? nil else { return nil }
            var page = (try? catalog.channels(sourceId: sid, categoryId: channel.categoryId, limit: 200)) ?? []
            if !page.contains(where: { $0.id == channel.id }) { page.insert(channel, at: 0) }
            return (.channel(channel), page)
        case .movie(let sid, let id):
            guard let movie = (try? catalog.movie(sourceId: sid, id: id)) ?? nil else { return nil }
            return (.movie(movie), [])
        case .episode(let sid, let seriesId, let id):
            let series = (try? catalog.seriesItem(sourceId: sid, id: seriesId)) ?? nil
            if let episode = (try? catalog.episode(sourceId: sid, id: id)) ?? nil {
                return (.episode(episode, seriesTitle: series?.name ?? ""), [])
            }
            guard let key = contentKey(sourceId: sid, kind: .episode, itemId: id),
                  let progress = (try? library.progress(contentKey: key)) ?? nil else { return nil }
            let stored = EpisodeTitle.parse(progress.data.title)
            let episode = Episode(sourceId: sid, id: id, seriesId: seriesId, season: stored.season ?? 0, number: stored.number ?? 0,
                                  title: stored.episodeTitle, posterUrl: progress.data.posterUrl)
            return (.episode(episode, seriesTitle: series?.name ?? stored.seriesTitle), [])
        }
    }
}
