import Foundation
import IPTVCore

/// A small copy of what must survive a lost catalog database, kept in the persistent key/value store
/// (UserDefaults) – docs/ARCHITECTURE.md §3.3.
///
/// tvOS keeps only ~500 KB of persistent app storage (NSUserDefaults); Application Support and Caches are
/// purgeable and the system deletes them when it needs space (seen after TestFlight updates with a large
/// catalog). The database was the only place the source list lived, so a purge looked like "the app forgot my
/// Xtream code". The mirror keeps:
///
/// - **sources** (metadata only – secrets stay in the Keychain, which survives) + the selected source id,
///   written at once on every add / edit / reorder / delete (`SourceRepository`);
/// - **user state**: all favorites, the 300 most recent progress items, recent searches (10 per source) and the
///   sync cursors – compact JSON, zlib-compressed, written at most once per `interval` (leading + trailing edge)
///   and when the app goes to the background.
///
/// `restoreIfNeeded` puts it back when the database comes up without sources: same ids and order, rows with
/// their original `updatedAt` and **no** push markers (sync must not re-send them). Everything this type adds
/// to the store stays below `budgetBytes` (caps enforced on every write).
public final class DurableStateMirror: @unchecked Sendable {
    public static let sourcesKey = "durable.sources.v1"
    public static let userStateKey = "durable.userState.v1"
    /// Everything the mirror writes (both keys) stays below this.
    public static let budgetBytes = 200_000
    /// Share of the budget for the user state (the source registry is a few KB).
    public static let userStateBudgetBytes = 170_000
    public static let maxFavorites = 2_000
    public static let maxProgress = 300
    public static let maxRecentSources = 20

    /// What a user-state snapshot contains (read from the database by `userStateProvider`).
    public struct UserState: Sendable, Equatable {
        public var favorites: [SyncItem]
        public var progress: [SyncItem]
        /// sourceId → recent searches (newest first).
        public var recentSearches: [String: [String]]
        public var syncCursor: String?
        public var syncLastPush: String?

        public init(favorites: [SyncItem] = [], progress: [SyncItem] = [], recentSearches: [String: [String]] = [:],
                    syncCursor: String? = nil, syncLastPush: String? = nil) {
            self.favorites = favorites
            self.progress = progress
            self.recentSearches = recentSearches
            self.syncCursor = syncCursor
            self.syncLastPush = syncLastPush
        }
    }

    /// Result of `restoreIfNeeded`.
    public struct Restore: Sendable, Equatable {
        /// Restored sources (mirror order).
        public var sources: [Source] = []
        /// Restored sources whose secrets are in the secure store (to refresh, in order).
        public var refreshIds: [String] = []
        /// Mirrored selected source id (when it is one of the restored sources).
        public var selectedSourceId: String?
        public var libraryItems = 0
        public var didRestore: Bool { !sources.isEmpty }
    }

    private let store: any KeyValueStore
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "durable-mirror", qos: .utility)
    private let lock = NSLock()
    private var scheduled = false
    private var lastWrite: Date = .distantPast
    private var lastUserState: Data?
    /// A failed library restore must not be overwritten by the (empty) database state of this launch.
    private var userStateFrozen = false
    /// Reads the current user state (nil = could not read: the mirror is left as is). Set once at start.
    public var userStateProvider: (@Sendable () -> UserState?)?

    public init(store: any KeyValueStore, interval: TimeInterval = 3) {
        self.store = store
        self.interval = interval
    }

    // MARK: Sources

    struct SourceRegistry: Codable, Equatable {
        var v = 1
        var sources: [Source]
        var selected: String?
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    func registry() -> SourceRegistry? {
        store.data(forKey: Self.sourcesKey).flatMap { try? Self.decoder.decode(SourceRegistry.self, from: $0) }
    }

    /// The mirrored sources (order = database order).
    public var mirroredSources: [Source] { registry()?.sources ?? [] }
    public var mirroredSelectedSourceId: String? { registry()?.selected }

    /// Replaces the mirrored source list (call with `SourceRepository.all()` after every change).
    public func recordSources(_ sources: [Source]) {
        lock.lock(); defer { lock.unlock() }
        var reg = registry() ?? SourceRegistry(sources: [])
        reg.sources = sources
        if let selected = reg.selected, !sources.contains(where: { $0.id == selected }) { reg.selected = sources.first?.id }
        write(reg)
    }

    public func recordSelectedSource(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var reg = registry(), reg.selected != id else { return }
        reg.selected = id
        write(reg)
    }

    private func write(_ reg: SourceRegistry) {
        guard let data = try? Self.encoder.encode(reg), data != store.data(forKey: Self.sourcesKey) else { return }
        store.set(data, forKey: Self.sourcesKey)
    }

    // MARK: User state

    /// A favorite/progress/recent-search change: written at once when the last write is older than `interval`,
    /// else once when it has passed (changes in between are coalesced).
    public func noteUserStateChanged() {
        lock.lock()
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let delay = max(0, lastWrite.addingTimeInterval(interval).timeIntervalSinceNow)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock(); scheduled = false; lock.unlock()
            writeUserState()
        }
    }

    /// Writes the current user state now (app going to the background). Call off the main thread.
    public func flushUserState() {
        queue.sync { writeUserState() }
    }

    /// Waits for a scheduled write (tests).
    func waitForPendingWrites() {
        queue.sync {}
    }

    private func writeUserState() {
        lock.lock()
        let frozen = userStateFrozen
        lock.unlock()
        guard !frozen, let state = userStateProvider?() else { return }
        lock.lock(); lastWrite = Date(); lock.unlock()   // only real writes start the interval
        recordUserState(state)
    }

    /// Encodes `state` within the budget and stores it (skipped when unchanged).
    func recordUserState(_ state: UserState) {
        guard let data = Self.encodeWithinBudget(state) else { return }
        lock.lock(); defer { lock.unlock() }
        guard data != lastUserState else { return }
        lastUserState = data
        store.set(data, forKey: Self.userStateKey)
    }

    /// The mirrored user state (nil when none / unreadable).
    public func mirroredUserState() -> UserState? {
        guard let data = store.data(forKey: Self.userStateKey) else { return nil }
        return Self.decode(data)
    }

    /// Bytes this type keeps in the store (both keys).
    public var storedBytes: Int {
        (store.data(forKey: Self.sourcesKey)?.count ?? 0) + (store.data(forKey: Self.userStateKey)?.count ?? 0)
    }

    // MARK: Restore

    /// Database without sources but a mirror with some (purged / corrupt / new file): re-inserts the sources
    /// (same ids and order; without Keychain secrets a source is kept with the "invalid credentials" state) and,
    /// when the library is empty, favorites/progress with their original `updatedAt` (no push markers), recent
    /// searches and the sync cursors. Nothing happens when the database still has sources.
    public func restoreIfNeeded(sources repo: SourceRepository, library: LibraryRepository, database: AppDatabase) -> Restore {
        var result = Restore()
        guard let reg = registry(), !reg.sources.isEmpty,
              let existing = try? repo.all(), existing.isEmpty else { return result }
        var restored: [Source] = []
        for var source in reg.sources {
            if repo.secrets(id: source.id) == nil {
                source.lastRefreshResult = SourceStatus(error: .invalidCredentials)
            } else {
                result.refreshIds.append(source.id)
            }
            restored.append(source)
        }
        do {
            try repo.restore(restored)
        } catch {
            SafeLog.error("mirror: source restore failed")
            return Restore()
        }
        result.sources = restored
        result.selectedSourceId = reg.selected.flatMap { id in restored.contains { $0.id == id } ? id : nil }
        if let state = mirroredUserState() {
            do {
                result.libraryItems = try restoreUserState(state, sourceIds: Set(restored.map(\.id)),
                                                          library: library, database: database)
            } catch {
                lock.lock(); userStateFrozen = true; lock.unlock()
                SafeLog.error("mirror: library restore failed")
            }
        }
        SafeLog.warning("catalog database restored from mirror: \(restored.count) sources, \(result.libraryItems) library items")
        return result
    }

    private func restoreUserState(_ state: UserState, sourceIds: Set<String>, library: LibraryRepository,
                                  database: AppDatabase) throws -> Int {
        try database.db.transaction {
            var count = 0
            if try database.db.scalar("SELECT COUNT(*) FROM library") == 0 {
                count = try library.restore(state.favorites + state.progress)
            }
            func setIfMissing(_ value: String?, _ key: String) {
                guard let value, database.value(forKey: key) == nil else { return }
                database.setValue(value, forKey: key)
            }
            setIfMissing(state.syncCursor, SyncManager.cursorKey)
            setIfMissing(state.syncLastPush, SyncManager.lastPushKey)
            for (sourceId, list) in state.recentSearches where sourceIds.contains(sourceId) && !list.isEmpty {
                let json = (try? JSONEncoder().encode(Array(list.prefix(RecentSearchStore.limit)))).flatMap { String(data: $0, encoding: .utf8) }
                setIfMissing(json, RecentSearchStore.key(sourceId))
            }
            return count
        }
    }

    // MARK: Encoding

    /// One library row as a positional array: `[contentKey, contentKind, title, updatedAt, posterUrl?, positionMs?,
    /// durationMs?, seriesKey?]` (trailing nils omitted).
    struct CompactItem: Encodable, Equatable {
        var item: SyncItem

        init(_ item: SyncItem) { self.item = item }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(item.contentKey)
            try c.encode(item.data.contentKind.rawValue)
            try c.encode(item.data.title)
            try c.encode(item.updatedAt)
            let d = item.data
            let present = [d.posterUrl != nil, d.positionMs != nil, d.durationMs != nil, d.seriesKey != nil]
            guard let last = present.lastIndex(of: true) else { return }
            if let v = d.posterUrl { try c.encode(v) } else { try c.encodeNil() }
            if last >= 1 { if let v = d.positionMs { try c.encode(v) } else { try c.encodeNil() } }
            if last >= 2 { if let v = d.durationMs { try c.encode(v) } else { try c.encodeNil() } }
            if last >= 3 { if let v = d.seriesKey { try c.encode(v) } else { try c.encodeNil() } }
        }

        static func decode(_ c: inout UnkeyedDecodingContainer, kind: SyncKind) throws -> SyncItem {
            var row = try c.nestedUnkeyedContainer()
            let contentKey = try row.decode(String.self)
            let contentKind = ContentKind(rawValue: try row.decode(String.self)) ?? .live
            let title = try row.decode(String.self)
            let updatedAt = try row.decode(Int64.self)
            func next<T: Decodable>(_ type: T.Type) throws -> T? {
                if row.isAtEnd { return nil }
                if try row.decodeNil() { return nil }
                return try row.decode(T.self)
            }
            let poster = try next(String.self)
            let position = try next(Int64.self)
            let duration = try next(Int64.self)
            let series = try next(String.self)
            let data = SyncItemData(title: title, contentKind: contentKind, posterUrl: poster,
                                    positionMs: position, durationMs: duration, seriesKey: series)
            let key = kind == .favorite ? SyncItem.favoriteKey(contentKey) : SyncItem.progressKey(contentKey)
            return SyncItem(key: key, kind: kind, data: data, updatedAt: updatedAt)
        }
    }

    private struct Envelope: Encodable {
        var v = 1
        var fav: [CompactItem]
        var prog: [CompactItem]
        var recent: [String: [String]]
        var cursor: String?
        var push: String?
    }

    private struct DecodedEnvelope: Decodable {
        var state: UserState

        private enum Keys: String, CodingKey { case v, fav, prog, recent, cursor, push }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func items(_ key: Keys, _ kind: SyncKind) throws -> [SyncItem] {
                var list = try c.nestedUnkeyedContainer(forKey: key)
                var out: [SyncItem] = []
                while !list.isAtEnd { out.append(try CompactItem.decode(&list, kind: kind)) }
                return out
            }
            state = UserState(favorites: try items(.fav, .favorite), progress: try items(.prog, .progress),
                              recentSearches: try c.decodeIfPresent([String: [String]].self, forKey: .recent) ?? [:],
                              syncCursor: try c.decodeIfPresent(String.self, forKey: .cursor),
                              syncLastPush: try c.decodeIfPresent(String.self, forKey: .push))
        }
    }

    static func encode(_ state: UserState) -> Data? {
        let envelope = Envelope(fav: state.favorites.map(CompactItem.init), prog: state.progress.map(CompactItem.init),
                                recent: state.recentSearches, cursor: state.syncCursor, push: state.syncLastPush)
        guard let json = try? JSONEncoder().encode(envelope) else { return nil }
        return try? (json as NSData).compressed(using: .zlib) as Data
    }

    static func decode(_ data: Data) -> UserState? {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return (try? JSONDecoder().decode(DecodedEnvelope.self, from: json))?.state
    }

    /// Caps (favorites 2000 newest, progress 300 newest, 10 searches for 20 sources), then – while the result is
    /// over `userStateBudgetBytes` – drops the oldest progress, then the oldest favorites, a quarter at a time.
    static func encodeWithinBudget(_ input: UserState) -> Data? {
        var state = input
        state.favorites = Array(state.favorites.filter { !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxFavorites))
        state.progress = Array(state.progress.filter { !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxProgress))
        state.recentSearches = Dictionary(uniqueKeysWithValues: state.recentSearches.filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }.prefix(maxRecentSources).map { ($0.key, Array($0.value.prefix(RecentSearchStore.limit))) })
        while let data = encode(state) {
            if data.count <= userStateBudgetBytes { return data }
            if !state.progress.isEmpty {
                state.progress.removeLast(max(1, state.progress.count / 4))
            } else if !state.favorites.isEmpty {
                state.favorites.removeLast(max(1, state.favorites.count / 4))
            } else if !state.recentSearches.isEmpty {
                state.recentSearches = [:]
            } else {
                return data
            }
        }
        return nil
    }
}
