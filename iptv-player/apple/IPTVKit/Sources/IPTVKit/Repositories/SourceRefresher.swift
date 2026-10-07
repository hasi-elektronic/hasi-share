import Foundation
import IPTVCore

/// Step reported while a source is connected/refreshed (docs/SCREENS.md §3.1).
public enum RefreshProgress: Sendable, Hashable {
    case connecting
    case authenticating
    case channels(Int)
    case movies(Int)
    case series(Int)
    case epg
}

/// Version of the way catalogs are mapped and stored. A catalog built by an older app version can lack
/// data newer code relies on (Build 6 catalogs had no `category_ids` memberships until the next manual
/// refresh), so every source whose stored version is older – or missing – is refreshed once in the
/// background on launch (`AppEnvironment.refreshDueSources`). Bump rule: docs/ARCHITECTURE.md §3.1.
public enum CatalogFormat {
    /// 1 = up to Build 6 (implicit, never stored); 2 = `item_categories` from Xtream `category_ids`;
    /// 3 = search index v6 with the `people` column (cast + director, Build 10).
    public static let current = 3

    static func key(_ sourceId: String) -> String { "catalog.format.\(sourceId)" }
}

/// Loads a source (M3U streaming or Xtream API) into the database atomically, then its EPG.
public final class SourceRefresher: Sendable {
    private let sources: SourceRepository
    private let catalog: CatalogRepository
    private let epg: EpgRepository
    private let database: AppDatabase
    private let transport: any HTTPTransport
    private let sleeper: Sleeper
    private let retryPolicy: RetryPolicy

    public init(database: AppDatabase, sources: SourceRepository, catalog: CatalogRepository, epg: EpgRepository,
                transport: any HTTPTransport = URLSessionTransport.shared, retryPolicy: RetryPolicy = .sourceDefault,
                sleeper: Sleeper = .live) {
        self.database = database
        self.sources = sources
        self.catalog = catalog
        self.epg = epg
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    /// Refreshes catalog + EPG of a source. Errors are returned as `SourceError` and also stored
    /// in `Source.lastRefreshResult`; the previous content stays visible on failure.
    /// - Parameter includeEpg: false → only the catalog; call `refreshEpg(sourceId:)` afterwards
    ///   (e.g. in the background so "add source" finishes as soon as the lists are there).
    @discardableResult
    public func refresh(sourceId: String, now: Date = Date(), includeEpg: Bool = true,
                        onProgress: @escaping @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> Source {
        guard var source = try sources.source(id: sourceId), let secrets = sources.secrets(id: sourceId) else {
            throw SourceError.notFound
        }
        onProgress(.connecting)
        var status: SourceStatus
        var epgURL: URL?
        do {
            switch secrets {
            case .m3u(let m3u):
                let result = try await loadM3U(sourceId: sourceId, secrets: m3u, onProgress: onProgress)
                status = result.status
                database.setValue(result.epgUrls.first, forKey: Self.headerEpgKey(sourceId))
                epgURL = (m3u.epgUrl ?? result.epgUrls.first).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            case .xtream(let xtream):
                onProgress(.authenticating)
                let result = try await loadXtream(sourceId: sourceId, secrets: xtream, now: now, onProgress: onProgress)
                status = result.0
                source.xtreamAccount = result.1
                epgURL = xtream.epgUrl.flatMap { URL(string: $0) } ?? XtreamURLBuilder(secrets: xtream)?.xmltvURL()
            }
        } catch {
            let mapped = ErrorClassifier.sourceError(from: error)
            if mapped != .cancelled {
                source.lastRefreshAt = now
                source.lastRefreshResult = SourceStatus(error: mapped)
                try? sources.save(source)
            }
            SafeLog.warning("refresh failed: \(mapped.code)")
            throw mapped
        }
        source.lastRefreshAt = now
        source.lastRefreshResult = status
        try sources.save(source)
        database.setValue(String(CatalogFormat.current), forKey: CatalogFormat.key(sourceId))

        if includeEpg, let epgURL {
            onProgress(.epg)
            do {
                status.epgProgramCount = try await loadEpg(source: source, url: epgURL, userAgent: secrets.userAgent, now: now)
            } catch {
                // EPG is optional: the catalog stays usable (UI shows "TV guide could not be loaded").
                SafeLog.warning("epg failed: \(ErrorClassifier.sourceError(from: error).code)")
            }
            source.lastRefreshResult = status
            try sources.save(source)
        }
        return source
    }

    static func headerEpgKey(_ sourceId: String) -> String { "epg.header.\(sourceId)" }

    /// Catalog format the stored catalog of a source was built with (nil: before Build 9 / never loaded).
    public func catalogFormat(sourceId: String) -> Int? {
        database.value(forKey: CatalogFormat.key(sourceId)).flatMap(Int.init)
    }

    /// True when the stored catalog predates `CatalogFormat.current` and needs one re-import.
    public func needsFormatRefresh(sourceId: String) -> Bool {
        (catalogFormat(sourceId: sourceId) ?? 1) < CatalogFormat.current
    }

    /// Forgets the stored format (source deleted).
    public func clearCatalogFormat(sourceId: String) {
        database.setValue(nil, forKey: CatalogFormat.key(sourceId))
    }

    /// EPG URL of a source: override, else playlist header (`url-tvg`) / Xtream `xmltv.php`.
    public func epgURL(sourceId: String) -> URL? {
        guard let secrets = sources.secrets(id: sourceId) else { return nil }
        switch secrets {
        case .m3u(let m3u):
            return (m3u.epgUrl ?? database.value(forKey: Self.headerEpgKey(sourceId)))
                .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        case .xtream(let x):
            return x.epgUrl.flatMap { URL(string: $0) } ?? XtreamURLBuilder(secrets: x)?.xmltvURL()
        }
    }

    /// Loads only the EPG of a source and records the programme count. Errors are logged; the
    /// catalog stays usable without a guide.
    @discardableResult
    public func refreshEpg(sourceId: String, now: Date = Date()) async -> Int? {
        guard var source = try? sources.source(id: sourceId), let url = epgURL(sourceId: sourceId) else { return nil }
        do {
            let count = try await loadEpg(source: source, url: url, userAgent: sources.secrets(id: sourceId)?.userAgent, now: now)
            var status = source.lastRefreshResult ?? SourceStatus()
            status.epgProgramCount = count
            source.lastRefreshResult = status
            try? sources.save(source)
            return count
        } catch {
            SafeLog.warning("epg failed: \(ErrorClassifier.sourceError(from: error).code)")
            return nil
        }
    }

    private func loadM3U(sourceId: String, secrets: M3USecrets,
                         onProgress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> (status: SourceStatus, epgUrls: [String]) {
        let session = try catalog.beginRefresh(sourceId: sourceId)
        var builder = M3UCatalogBuilder(sourceId: sourceId)
        let loader = M3USourceLoader(transport: transport, retryPolicy: retryPolicy, sleeper: sleeper)
        do {
            let summary = try await loader.load(secrets) { entries in
                let batch = builder.add(entries)
                try session.write(batch)
                onProgress(.channels(builder.liveCount))
            }
            let status = SourceStatus(liveCount: builder.liveCount, movieCount: builder.movieCount, seriesCount: builder.seriesCount)
            try session.commit()
            return (status, summary.epgUrls)
        } catch {
            session.abort()
            throw error
        }
    }

    private func loadXtream(sourceId: String, secrets: XtreamSecrets, now: Date,
                            onProgress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> (SourceStatus, XtreamAccountInfo) {
        guard let client = XtreamClient(sourceId: sourceId, secrets: secrets, transport: transport,
                                        retryPolicy: retryPolicy, sleeper: sleeper) else { throw SourceError.invalidFormat }
        let catalogData = try await client.fetchCatalog(now: now)
        onProgress(.channels(catalogData.channels.count))
        let session = try catalog.beginRefresh(sourceId: sourceId)
        do {
            try session.write(categories: catalogData.liveCategories + catalogData.vodCategories + catalogData.seriesCategories)
            for chunk in catalogData.channels.chunked(1000) { try session.write(channels: chunk) }
            onProgress(.movies(catalogData.movies.count))
            for chunk in catalogData.movies.chunked(1000) { try session.write(movies: chunk) }
            onProgress(.series(catalogData.series.count))
            for chunk in catalogData.series.chunked(1000) { try session.write(series: chunk) }
            try session.commit()
        } catch {
            session.abort()
            throw error
        }
        return (catalogData.status, catalogData.account)
    }

    /// Loads XMLTV for a source; returns the number of stored programmes.
    @discardableResult
    public func loadEpg(source: Source, url: URL, userAgent: String? = nil, now: Date = Date()) async throws -> Int {
        let channels = try database.db.query("SELECT id, name, epg_id, catchup_days FROM channels WHERE source_id = ?",
                                             [.text(source.id)]) { (id: $0.string(0), name: $0.string(1), epgId: $0.optString(2), days: $0.int(3)) }
        let maxCatchup = channels.map(\.days).max() ?? 0
        let options = XMLTVParseOptions(preferredLanguage: Locale.current.language.languageCode?.identifier,
                                        shiftMinutes: source.epgShiftMinutes,
                                        window: EpgRetention.window(now: now, catchupDays: maxCatchup))
        let session = try epg.beginRefresh(sourceId: source.id)
        let state = EpgMatchState(channels: channels.map { ($0.id, $0.name, $0.epgId) })
        let loader = XMLTVLoader(transport: transport, retryPolicy: retryPolicy, sleeper: sleeper, userAgent: userAgent)
        do {
            _ = try await loader.load(url: url, options: options,
                                      onChannel: { state.matcher.add($0) },
                                      onProgrammes: { programmes in
                                          state.resolveIfNeeded()
                                          let mapped = programmes.compactMap { p -> EpgProgram? in
                                              guard state.wanted.contains(p.channel.lowercased()) else { return nil }
                                              return p.toEpgProgram(sourceId: source.id)
                                          }
                                          if !mapped.isEmpty { try session.write(mapped) }
                                      })
            state.resolveIfNeeded()
            let written = session.written
            try database.db.transaction {
                try session.commit()
                // Channels matched by name get the XMLTV id as their epg id.
                for (channelId, xmltvId) in state.assignments {
                    try database.db.run("UPDATE channels SET epg_id = ? WHERE source_id = ? AND id = ?",
                                        [.text(xmltvId), .text(source.id), .text(channelId)])
                }
            }
            return written
        } catch {
            session.abort()
            throw error
        }
    }
}

/// Mutable matching state used from the (synchronous) XMLTV callbacks.
private final class EpgMatchState {
    var matcher = EpgMatcher()
    let channels: [(id: String, name: String, epgId: String?)]
    var resolved = false
    /// Lowercased XMLTV channel ids whose programmes are stored.
    var wanted: Set<String> = []
    /// Channel id → matched XMLTV id where it differs from the stored epg id.
    var assignments: [(String, String)] = []

    init(channels: [(String, String, String?)]) {
        self.channels = channels.map { (id: $0.0, name: $0.1, epgId: $0.2) }
    }

    func resolveIfNeeded() {
        guard !resolved else { return }
        resolved = true
        for channel in channels {
            guard let xmltvId = matcher.match(epgId: channel.epgId, name: channel.name) else { continue }
            wanted.insert(xmltvId.lowercased())
            if channel.epgId?.lowercased() != xmltvId.lowercased() { assignments.append((channel.id, xmltvId)) }
        }
    }
}

extension SourceSecrets {
    /// User-Agent override of an M3U source.
    public var userAgent: String? {
        if case .m3u(let s) = self { return s.userAgent }
        return nil
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
