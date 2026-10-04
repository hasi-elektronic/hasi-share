import Foundation

/// Catalog rows produced from one batch of M3U entries, ready for persistence.
public struct M3UCatalogBatch: Sendable, Hashable {
    /// Categories first seen in this batch.
    public var categories: [Category] = []
    public var channels: [Channel] = []
    public var movies: [Movie] = []
    /// Series first seen in this batch.
    public var series: [Series] = []
    public var episodes: [Episode] = []

    public init() {}

    public var isEmpty: Bool {
        categories.isEmpty && channels.isEmpty && movies.isEmpty && series.isEmpty && episodes.isEmpty
    }
}

/// Maps M3U entries (streamed in batches) to the domain model of CONTRACT §1:
/// live → `Channel`, movie → `Movie`, episode → `Episode` (+ synthesized `Series`).
///
/// Ids are deterministic so a refresh replaces rows in place:
/// item id `u<sha16(url)>` (CONTRACT §1.1), category id `g<sha16(kind|group)>`,
/// series id `s<sha16(lowercased series name)>`. Entries without group get no category
/// (UI shows the localized "Other").
public struct M3UCatalogBuilder: Sendable {
    public let sourceId: String
    private var knownCategories: [String: String] = [:]
    private var knownSeries: Set<String> = []
    private var categorySort = [CategoryKind: Int]()
    public private(set) var liveCount = 0
    public private(set) var movieCount = 0
    public private(set) var seriesCount = 0
    public private(set) var episodeCount = 0

    public init(sourceId: String) {
        self.sourceId = sourceId
    }

    /// Category id for a group of the given kind.
    public static func categoryId(kind: CategoryKind, group: String) -> String {
        "g" + Hashing.sha256Hex("\(kind.rawValue)|\(group)").prefix(16)
    }

    /// Series id for a series name.
    public static func seriesId(name: String) -> String {
        "s" + Hashing.sha256Hex(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).prefix(16)
    }

    /// Converts a batch of entries; new categories/series are included once.
    public mutating func add(_ entries: [M3UEntry]) -> M3UCatalogBatch {
        var out = M3UCatalogBatch()
        for entry in entries {
            let itemId = entry.itemId
            switch entry.kind {
            case .live:
                let categoryId = category(for: entry.group, kind: .live, into: &out)
                out.channels.append(Channel(sourceId: sourceId, id: itemId, name: entry.name, number: entry.chno,
                                            logoUrl: entry.logo, categoryId: categoryId, epgId: entry.tvgId,
                                            catchup: entry.catchup ?? .none, url: entry.url,
                                            userAgent: entry.userAgent, referrer: entry.referrer,
                                            drm: entry.drm, sort: liveCount))
                liveCount += 1
            case .movie:
                let categoryId = category(for: entry.group, kind: .movie, into: &out)
                out.movies.append(Movie(sourceId: sourceId, id: itemId, name: entry.name, posterUrl: entry.logo,
                                        categoryId: categoryId, containerExt: Self.containerExt(of: entry.url),
                                        url: entry.url, sort: movieCount))
                movieCount += 1
            case .episode:
                let categoryId = category(for: entry.group, kind: .series, into: &out)
                var seriesName = entry.series?.name ?? ""
                if seriesName.isEmpty { seriesName = entry.group ?? entry.name }
                let seriesId = Self.seriesId(name: seriesName)
                if !knownSeries.contains(seriesId) {
                    knownSeries.insert(seriesId)
                    out.series.append(Series(sourceId: sourceId, id: seriesId, name: seriesName, posterUrl: entry.logo,
                                             categoryId: categoryId, sort: seriesCount))
                    seriesCount += 1
                }
                out.episodes.append(Episode(sourceId: sourceId, id: itemId, seriesId: seriesId,
                                            season: entry.series?.season ?? 1, number: entry.series?.episode ?? 0,
                                            title: entry.name, containerExt: Self.containerExt(of: entry.url),
                                            posterUrl: entry.logo, url: entry.url))
                episodeCount += 1
            }
        }
        return out
    }

    private mutating func category(for group: String?, kind: CategoryKind, into out: inout M3UCatalogBatch) -> String? {
        guard let group, !group.isEmpty else { return nil }
        let key = "\(kind.rawValue)|\(group)"
        if let id = knownCategories[key] { return id }
        let id = Self.categoryId(kind: kind, group: group)
        knownCategories[key] = id
        let sort = categorySort[kind, default: 0]
        categorySort[kind] = sort + 1
        out.categories.append(Category(sourceId: sourceId, id: id, kind: kind, name: group, sort: sort))
        return id
    }

    /// Lowercased file extension of a URL path, if it looks like one.
    static func containerExt(of url: String) -> String? {
        guard let parts = URLParts.parse(url) else { return nil }
        let path = parts.path
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let last = path[path.index(after: slash)...]
        guard let dot = last.lastIndex(of: ".") else { return nil }
        let ext = last[last.index(after: dot)...].lowercased()
        return (1...5).contains(ext.count) ? ext : nil
    }
}
