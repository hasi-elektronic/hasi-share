import Foundation

// Foundation only: this file is compiled into IPTVKit AND into the tvOS Top Shelf extension
// (`NovaPlayer-TopShelf` in project.yml) – no IPTVCore / IPTVKit types here.

/// What the tvOS Top Shelf shows (Build 17, docs/ARCHITECTURE.md §3.4): "Continue watching" and "Recently watched"
/// channels. The app writes it as compact JSON into a shared Keychain item (`TopShelfStore`); the extension reads it.
/// No secrets: titles, image URLs (credential-free, `safeImageURL`), progress and `novaplayer://` deep links only.
public struct TopShelfSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// Image aspect on the shelf: posters 2:3, channel logos square.
        public enum Shape: String, Codable, Sendable { case poster, square, hdtv }

        /// Stable identifier (the deep link without its scheme).
        public var id: String
        public var title: String
        public var imageURL: String?
        public var shape: Shape
        /// 0…1 for "Continue watching", nil otherwise.
        public var progress: Double?
        /// `novaplayer://…` (`DeepLink`).
        public var link: String

        public init(id: String, title: String, imageURL: String?, shape: Shape, progress: Double?, link: String) {
            self.id = id
            self.title = title
            self.imageURL = imageURL
            self.shape = shape
            self.progress = progress
            self.link = link
        }
    }

    public struct Section: Codable, Sendable, Equatable {
        /// Localized by the app (the extension has no string catalog; the app may run in its own UI language).
        public var title: String
        public var items: [Item]

        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public var version: Int
    public var sections: [Section]

    public init(sections: [Section]) {
        version = Self.currentVersion
        self.sections = sections
    }

    public static let currentVersion = 1
    /// Upper bound of the encoded snapshot (Keychain item; the shelf needs far less).
    public static let maxBytes = 64 * 1024
    /// Items per section (Top Shelf rows show ~5; 10 = the spec's limit).
    public static let maxItemsPerSection = 10
    static let maxTitleLength = 120
    static let maxURLLength = 1024

    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    /// Compact JSON within `maxBytes`: at most `maxItemsPerSection` per section, long titles cut, unsafe/long image URLs
    /// dropped; if it is still too large, the last item of the largest section goes until it fits.
    public func encoded() -> Data {
        var trimmed = self
        trimmed.sections = sections.compactMap { section in
            let items = section.items.prefix(Self.maxItemsPerSection).map { item -> Item in
                var item = item
                if item.title.count > Self.maxTitleLength { item.title = String(item.title.prefix(Self.maxTitleLength - 1)) + "…" }
                item.imageURL = item.imageURL.flatMap(Self.safeImageURL)
                item.progress = item.progress.map { min(1, max(0, $0)) }
                return item
            }
            return items.isEmpty ? nil : Section(title: section.title, items: Array(items))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while true {
            let data = (try? encoder.encode(trimmed)) ?? Data()
            if data.count <= Self.maxBytes { return data }
            // Too large: drop (proportionally many) items, always from the largest section, and measure again.
            let total = trimmed.sections.reduce(0) { $0 + $1.items.count }
            guard total > 0 else { return (try? encoder.encode(TopShelfSnapshot(sections: []))) ?? Data() }
            let keep = min(total - 1, Int(Double(total) * Double(Self.maxBytes) / Double(data.count) * 0.95))
            for _ in 0..<(total - max(0, keep)) {
                guard let largest = trimmed.sections.indices.max(by: { trimmed.sections[$0].items.count < trimmed.sections[$1].items.count })
                else { break }
                trimmed.sections[largest].items.removeLast()
                if trimmed.sections[largest].items.isEmpty { trimmed.sections.remove(at: largest) }
            }
        }
    }

    /// nil for anything that is not a snapshot of a version this build understands.
    public static func decode(_ data: Data) -> TopShelfSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data), snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    /// An image URL the shelf may show: http(s), no user info, no credential-looking query, ≤ 1 KiB. Panel logo/poster
    /// URLs normally carry no credentials – stream URLs do, and they are never put into a snapshot.
    public static func safeImageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxURLLength, let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        let sensitive = ["password", "pass", "pwd", "token", "username", "user", "auth", "key"]
        if let items = components.queryItems, items.contains(where: { sensitive.contains($0.name.lowercased()) }) { return nil }
        return trimmed
    }
}

/// `novaplayer://` deep links (Top Shelf, Build 17): open a channel / movie / episode directly in the player.
///
///     novaplayer://play/channel?source=<sourceId>&id=<channelId>
///     novaplayer://play/movie?source=<sourceId>&id=<movieId>
///     novaplayer://play/episode?source=<sourceId>&series=<seriesId>&id=<episodeId>
public enum DeepLink: Equatable, Sendable, Hashable {
    case channel(sourceId: String, channelId: String)
    case movie(sourceId: String, movieId: String)
    case episode(sourceId: String, seriesId: String, episodeId: String)

    public static let scheme = "novaplayer"
    static let host = "play"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        switch self {
        case .channel(let source, let id):
            components.path = "/channel"
            components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "id", value: id)]
        case .movie(let source, let id):
            components.path = "/movie"
            components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "id", value: id)]
        case .episode(let source, let series, let id):
            components.path = "/episode"
            components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "series", value: series),
                                     URLQueryItem(name: "id", value: id)]
        }
        // `+` and `&` inside ids must not change meaning (URLComponents leaves "+" alone).
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)")!
    }

    /// Stable id for the shelf item (the link without its scheme).
    public var identifier: String {
        let s = url.absoluteString
        return s.hasPrefix("\(Self.scheme)://") ? String(s.dropFirst(Self.scheme.count + 3)) : s
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == Self.host else { return nil }
        func value(_ name: String) -> String? {
            guard let v = components.queryItems?.first(where: { $0.name == name })?.value, !v.isEmpty else { return nil }
            return v
        }
        guard let source = value("source"), let id = value("id") else { return nil }
        switch components.path.lowercased() {
        case "/channel": self = .channel(sourceId: source, channelId: id)
        case "/movie": self = .movie(sourceId: source, movieId: id)
        case "/episode":
            guard let series = value("series") else { return nil }
            self = .episode(sourceId: source, seriesId: series, episodeId: id)
        default: return nil
        }
    }

    public var sourceId: String {
        switch self {
        case .channel(let s, _), .movie(let s, _), .episode(let s, _, _): return s
        }
    }
}
