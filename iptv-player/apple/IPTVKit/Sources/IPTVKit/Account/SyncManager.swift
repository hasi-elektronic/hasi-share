import Foundation
import IPTVCore

/// Backend calls needed by sync (`BackendClient` conforms; tests use fakes).
public protocol SyncBackend: Sendable {
    func syncPull(since cursor: Int64, limit: Int, sessionToken: String) async throws -> SyncPage
    func syncPush(_ items: [SyncItem], sessionToken: String) async throws -> SyncPushResult
}

extension BackendClient: SyncBackend {}

/// Favorites/progress sync (CONTRACT §8, docs/ARCHITECTURE.md §6): pull on start / when the
/// app becomes active, push local changes 5 s after the last change in batches of ≤ 500,
/// last-writer-wins merge by `updatedAt`.
public actor SyncManager {
    public static let batchLimit = 500

    private let backend: any SyncBackend
    private let library: LibraryRepository
    private let database: AppDatabase
    private let debounce: Duration
    private let sessionToken: @Sendable () -> String?
    private var pushTask: Task<Void, Never>?
    public private(set) var lastSyncedAt: Date?
    public private(set) var pushCalls = 0

    private enum Keys {
        static let cursor = SyncManager.cursorKey
        static let lastPush = SyncManager.lastPushKey
    }
    /// Database kv keys of the pull cursor / last pushed `updatedAt` (also mirrored, `DurableStateMirror`).
    static let cursorKey = "sync.cursor"
    static let lastPushKey = "sync.lastPushMs"

    public init(backend: any SyncBackend, library: LibraryRepository, database: AppDatabase,
                debounce: Duration = .seconds(5), sessionToken: @escaping @Sendable () -> String?) {
        self.backend = backend
        self.library = library
        self.database = database
        self.debounce = debounce
        self.sessionToken = sessionToken
    }

    public var cursor: Int64 { Int64(database.value(forKey: Keys.cursor) ?? "") ?? 0 }
    public var lastPushMs: Int64 { Int64(database.value(forKey: Keys.lastPush) ?? "") ?? 0 }

    /// A local favorite/progress change happened: (re)schedules a debounced push.
    public func noteLocalChange() {
        guard sessionToken() != nil else { return }
        pushTask?.cancel()
        let delay = debounce
        pushTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            try? await self?.push()
        }
    }

    /// Waits for a scheduled push (tests).
    public func waitForScheduledPush() async {
        await pushTask?.value
    }

    /// Pushes everything changed since the last push, in batches of ≤ 500.
    public func push() async throws {
        guard let token = sessionToken() else { return }
        while true {
            let since = lastPushMs
            let items = try library.changed(after: since, limit: Self.batchLimit)
            guard !items.isEmpty else { break }
            _ = try await backend.syncPush(items, sessionToken: token)
            pushCalls += 1
            // Late-written items (push markers) may be older than the cursor: never move it back.
            let maxUpdated = max(since, items.map(\.updatedAt).max() ?? since)
            database.setValue(String(maxUpdated), forKey: Keys.lastPush)
            try library.clearPushMarkers(items)
            lastSyncedAt = Date()
            if items.count < Self.batchLimit { break }
        }
    }

    /// Pulls remote changes since the cursor (all pages) and merges them (LWW).
    @discardableResult
    public func pull() async throws -> Int {
        guard let token = sessionToken() else { return 0 }
        var applied = 0
        var cursor = self.cursor
        while true {
            let page = try await backend.syncPull(since: cursor, limit: Self.batchLimit, sessionToken: token)
            applied += try library.merge(page.items).count
            cursor = page.cursor
            database.setValue(String(cursor), forKey: Keys.cursor)
            if !page.hasMore || page.items.isEmpty { break }
        }
        lastSyncedAt = Date()
        return applied
    }

    /// Pull then push (app start / foreground).
    public func syncNow() async {
        do {
            try await pull()
            try await push()
        } catch {
            SafeLog.warning("sync failed: \(error)")
        }
    }

    /// Forget sync position (sign-out): next sign-in pulls everything and re-pushes local items.
    public func reset() {
        pushTask?.cancel()
        database.setValue(nil, forKey: Keys.cursor)
        database.setValue(nil, forKey: Keys.lastPush)
        lastSyncedAt = nil
    }
}
