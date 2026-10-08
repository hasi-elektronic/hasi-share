import Foundation
import IPTVCore

/// Next-episode resolution (docs/SCREENS.md §3.5 "Bölüm bitince sonraki bölüm için 10 sn geri sayım kartı").
public enum NextEpisode {
    /// The episode after `episode` in `episodes`: the next number of the same season, else the first episode of
    /// the next season that has any (gaps are skipped). Ordered by (season, number); `episode` is found by id,
    /// else by its season/number (a re-fetched list may carry new ids). nil = last episode / not in the list.
    public static func after(_ episode: Episode, in episodes: [Episode]) -> Episode? {
        let sorted = episodes.sorted { ($0.season, $0.number, $0.id) < ($1.season, $1.number, $1.id) }
        let key = (episode.season, episode.number)
        guard sorted.contains(where: { $0.id == episode.id || ($0.season, $0.number) == key }) else { return nil }
        return sorted.first { ($0.season, $0.number) > key }
    }
}

/// Loads an Xtream series' episodes (`get_series_info`); injectable for tests.
public typealias SeriesInfoLoader = @Sendable (_ sourceId: String, _ seriesId: String, _ secrets: XtreamSecrets) async throws -> [Episode]

extension AppEnvironment {
    /// Wires the Build 16 player extras: preferences (autoplay, subtitle style) and the next-episode provider.
    func installPlayerExtras(kv: any KeyValueStore) {
        player.preferences = PlayerPreferences(kv: kv)
        player.nextEpisodeProvider = { [weak self] episode in
            await self?.nextEpisode(after: episode)
        }
    }

    public static let liveSeriesInfoLoader: SeriesInfoLoader = { sourceId, seriesId, secrets in
        guard let client = XtreamClient(sourceId: sourceId, secrets: secrets) else { return [] }
        return try await client.seriesInfo(seriesId: seriesId).episodes
    }

    /// The episode after `episode`: from the stored episode list, or – for Xtream series whose episodes are loaded
    /// lazily (or a cached list without a later episode, e.g. a new one this week) – from `get_series_info`,
    /// which also refreshes the stored list.
    public func nextEpisode(after episode: Episode, loadSeriesInfo: SeriesInfoLoader = AppEnvironment.liveSeriesInfoLoader) async -> Episode? {
        let stored = (try? catalog.episodes(sourceId: episode.sourceId, seriesId: episode.seriesId)) ?? []
        if let next = NextEpisode.after(episode, in: stored) { return next }
        guard case .xtream(let secrets)? = secrets(for: episode.sourceId) else { return nil }
        do {
            let fresh = try await loadSeriesInfo(episode.sourceId, episode.seriesId, secrets)
            guard !fresh.isEmpty else { return nil }
            let sorted = fresh.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            try? catalog.replaceEpisodes(sourceId: episode.sourceId, seriesId: episode.seriesId, episodes: sorted)
            return NextEpisode.after(episode, in: sorted)
        } catch {
            SafeLog.warning("next episode: series info failed (\(type(of: error)))")
            return nil
        }
    }
}
