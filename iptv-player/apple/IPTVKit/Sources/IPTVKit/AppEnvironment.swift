import Foundation
import IPTVCore
import Observation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Build-time configuration (from Info.plist, which gets it from `Config/Shared.xcconfig`).
public struct AppConfig: Sendable {
    public var displayName: String
    public var bundleId: String
    public var appVersion: String
    public var backendBaseURL: URL
    public var productIDs: ProductIDs
    /// `{"kid": {kty, crv, x, y}}` – Config/license-keys.json.
    public var licenseKeysJSON: Data
    public var platform: BackendPlatform
    /// `identifierForVendor` (hashed into the device key, never sent raw).
    public var rawDeviceId: String
    public var deviceName: String
    /// Accounts, phone sign-in and QR pairing (`ACCOUNTS_ENABLED`); off until the backend is live.
    public var accountsEnabled: Bool
    /// Privacy policy / terms of use (`PRIVACY_URL`, `TERMS_URL`) – paywall, settings, about.
    public var privacyURL: URL
    public var termsURL: URL

    public static let defaultPrivacyURL = URL(string: "https://hasi-elektronic.de/datenschutz")!
    public static let defaultTermsURL = URL(string: "https://hasi-elektronic.de/agb")!

    public init(displayName: String, bundleId: String, appVersion: String, backendBaseURL: URL, productIDs: ProductIDs,
                licenseKeysJSON: Data, platform: BackendPlatform, rawDeviceId: String, deviceName: String,
                accountsEnabled: Bool = true, privacyURL: URL = AppConfig.defaultPrivacyURL, termsURL: URL = AppConfig.defaultTermsURL) {
        self.displayName = displayName
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.backendBaseURL = backendBaseURL
        self.productIDs = productIDs
        self.licenseKeysJSON = licenseKeysJSON
        self.platform = platform
        self.rawDeviceId = rawDeviceId
        self.deviceName = deviceName
        self.accountsEnabled = accountsEnabled
        self.privacyURL = privacyURL
        self.termsURL = termsURL
    }

    public var deviceKey: String { DeviceKey.make(appId: bundleId, rawDeviceId: rawDeviceId) }

    /// False for the placeholder backend of the shipped config (`*.example…`, `invalid.example`): no backend call is
    /// made then – it could only fail and show "server unreachable".
    public var backendConfigured: Bool {
        guard let host = backendBaseURL.host?.lowercased(), !host.isEmpty else { return false }
        let labels = host.split(separator: ".")
        return !labels.contains("example") && !labels.contains("invalid")
    }
}

/// Manual dependency container + app-wide state (docs/ARCHITECTURE.md §2 "AppEnvironment").
@MainActor
@Observable
public final class AppEnvironment {
    public let config: AppConfig
    @ObservationIgnored public let database: AppDatabase
    @ObservationIgnored public let sourceRepository: SourceRepository
    @ObservationIgnored public let catalog: CatalogRepository
    @ObservationIgnored public let epg: EpgRepository
    @ObservationIgnored public let library: LibraryRepository
    @ObservationIgnored public let refresher: SourceRefresher
    @ObservationIgnored public let backend: BackendClient
    @ObservationIgnored public let syncManager: SyncManager
    /// One-tap favorites: cached set, undo, device-local order, favorite categories.
    public let favorites: FavoritesController
    /// Movies/Series category navigation: country, pinned, recent, hidden (per source + kind, device-local).
    public let categoryPrefs: CategoryPreferences
    /// Last searches per source (device-local, SCREENS §3.6).
    @ObservationIgnored public let recentSearches: RecentSearchStore
    @ObservationIgnored public let secureStore: any SecureStore
    /// HTTP transport of every source request (lists, details, EPG).
    @ObservationIgnored public let transport: any HTTPTransport
    /// Persistent copy of sources + favorites/progress/recent searches (tvOS purges the database, ARCHITECTURE §3.3).
    @ObservationIgnored public let mirror: DurableStateMirror
    public let settings: AppSettings
    public let store: StoreManager
    public let license: LicenseManager
    public let account: AccountManager
    public let player: PlayerController

    /// All configured sources (metadata only).
    public private(set) var sources: [Source] = []
    /// Bumped whenever favorites/progress change (views reload their rows).
    public private(set) var libraryVersion = 0
    /// Bumped whenever catalog content changes (refresh/add/delete).
    public private(set) var catalogVersion = 0
    public private(set) var lastSyncedAt: Date?
    /// Source ids with a refresh in flight.
    public private(set) var refreshing: Set<String> = []
    /// Sources put back from the mirror at launch whose catalog is still being reloaded ("Reloading catalog…").
    public private(set) var restoringSourceIds: Set<String> = []
    /// True while restored sources reload (non-blocking notice).
    public var isRestoringCatalog: Bool { !restoringSourceIds.isEmpty }
    /// What the launch restored from the mirror (nothing when the database still had its sources).
    @ObservationIgnored public private(set) var restore = DurableStateMirror.Restore()
    /// The background reload of the restored sources (tests await it).
    @ObservationIgnored public private(set) var restoreRefresh: Task<Void, Never>?
    /// sourceId → fingerprint: content keys are built per card/row; the secrets live in the
    /// Keychain, so they are read once per source (cleared whenever the sources change).
    @ObservationIgnored private var fingerprintCache: [String: String] = [:]

    public init(config: AppConfig, database: AppDatabase, secureStore: any SecureStore, kv: any KeyValueStore,
                settings: AppSettings = AppSettings(), transport: any HTTPTransport = URLSessionTransport.shared,
                engines: PlaybackEngines? = nil) throws {
        self.config = config
        self.database = database
        self.secureStore = secureStore
        self.transport = transport
        self.settings = settings
        mirror = DurableStateMirror(store: kv)
        sourceRepository = SourceRepository(database: database, secureStore: secureStore, mirror: mirror)
        catalog = CatalogRepository(database: database)
        epg = EpgRepository(database: database)
        library = LibraryRepository(database: database)
        favorites = FavoritesController(library: library, kv: kv, now: { Int64(Date().timeIntervalSince1970 * 1000) })
        categoryPrefs = CategoryPreferences(kv: kv)
        recentSearches = RecentSearchStore(database: database)
        refresher = SourceRefresher(database: database, sources: sourceRepository, catalog: catalog, epg: epg, transport: transport)
        backend = BackendClient(baseURL: config.backendBaseURL, transport: transport,
                                userAgent: "\(config.displayName)/\(config.appVersion) (\(config.platform.rawValue))")
        let verifier = try LicenseTokenVerifier(jwkSetJSON: config.licenseKeysJSON, audience: config.bundleId)
        store = StoreManager(productIDs: config.productIDs, kv: kv)
        license = LicenseManager(backend: backend, verifier: verifier, kv: kv,
                                 identity: LicenseIdentity(appId: config.bundleId, appVersion: config.appVersion,
                                                           deviceKey: config.deviceKey, platform: config.platform))
        account = AccountManager(backend: backend, secureStore: secureStore, deviceName: config.deviceName, platform: config.platform)
        let tokenStore = secureStore
        syncManager = SyncManager(backend: backend, library: library, database: database,
                                  sessionToken: { tokenStore.string(forKey: AccountManager.sessionKey) })
        let repo = sourceRepository
        // AVPlayer + (iOS/tvOS app) VLCKit engines – docs/ARCHITECTURE.md §3.2, CONTRACT §6.1.
        let engines = engines ?? .avPlayerOnly
        let streamResolver = StreamResolver(secrets: { repo.secrets(id: $0) }, vlcAvailable: engines.vlcAvailable)
        player = PlayerController(resolver: streamResolver, library: library, engines: engines)
        player.audioDelayStore = AudioDelayStore(kv: kv)   // per-content + device audio delay (SCREENS §3.7)
        let controller = player
        player.prefetcher = ZapPrefetcher(resolver: { [weak controller] in
                                              try await streamResolver.resolve($0, engineOverride: controller?.engineOverride ?? .automatic)
                                          },
                                          fetcher: URLSessionPrefetchFetcher(), network: PathNetworkConditions())
        wire()
        installPlayerExtras(kv: kv)   // Build 16: next-episode autoplay, subtitle style (NextEpisode.swift)
        // A database without sources (tvOS purged it, corrupt file, new file in Caches/memory): put the mirrored
        // sources and user state back BEFORE anything reads or mirrors the empty state.
        restore = mirror.restoreIfNeeded(sources: sourceRepository, library: library, database: database)
        if let selected = restore.selectedSourceId { settings.currentSourceId = selected }
        sourceRepository.registerSecretsForRedaction()
        reloadSources()
        // First launch of a build with the mirror: seed it from the database (never with an empty list here – a
        // failed restore must not wipe the copy it could be retried from).
        if !sources.isEmpty { sourceRepository.updateMirror() }
        installUserStateMirror()
        if restore.didRestore {
            favorites.reload()
            reloadRestoredSources(restore.refreshIds)
        }
        // Build 11 kept recent searches in UserDefaults (backed up): moved once into the catalog database.
        recentSearches.migrateLegacy(from: kv, sourceIds: sources.map(\.id))
        // Search index v6/v7: older catalogs are (re-)indexed in the background, never at launch; EPG stored
        // before Build 11 gets its programme title index the same way (cheap no-op when nothing is missing).
        let catalog = self.catalog, epg = self.epg
        Task.detached(priority: .utility) {
            do { try catalog.backfillSearchIndex() } catch { SafeLog.warning("search backfill failed") }
            do { try catalog.maintainSearchIndex() } catch { SafeLog.warning("search index maintenance failed") }
            do { try epg.maintainSearchIndex() } catch { SafeLog.warning("epg search index failed") }
        }
    }

    /// The mirror reads favorites/progress (pending writes included), recent searches and the sync cursors; it writes
    /// at most once per few seconds and when the app goes to the background. Nothing is written without sources
    /// (an empty database must never replace a mirror it could still be restored from).
    private func installUserStateMirror() {
        let library = library, recent = recentSearches, repo = sourceRepository, database = database
        mirror.userStateProvider = {
            guard let sources = try? repo.all(), !sources.isEmpty,
                  let favorites = try? library.favorites(),
                  let progress = try? library.progressItems(limit: DurableStateMirror.maxProgress) else { return nil }
            var searches: [String: [String]] = [:]
            for source in sources {
                let list = recent.recent(sourceId: source.id)
                if !list.isEmpty { searches[source.id] = list }
            }
            return DurableStateMirror.UserState(favorites: favorites, progress: progress, recentSearches: searches,
                                                syncCursor: database.value(forKey: SyncManager.cursorKey),
                                                syncLastPush: database.value(forKey: SyncManager.lastPushKey))
        }
        let mirror = mirror
        recentSearches.onChange = { mirror.noteUserStateChanged() }
        mirror.noteUserStateChanged()
    }

    /// Restored sources reload one after another in the background through the normal refresh pipeline (never
    /// blocking launch or QuickStart); `refreshDueSources` leaves them alone in this launch.
    private func reloadRestoredSources(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        restoringSourceIds = Set(ids)
        restoreRefresh = Task { [weak self] in
            for id in ids {
                guard let self else { return }
                await self.refreshSource(id: id)
                self.restoringSourceIds.remove(id)
            }
        }
    }

    /// Favorites/progress changed: views reload; the durable mirror schedules a write.
    private func libraryDidChange() {
        libraryVersion += 1
        mirror.noteUserStateChanged()
    }

    /// Accounts / phone sign-in / QR pairing are offered (config flag and a real backend).
    public var accountsEnabled: Bool { config.accountsEnabled && config.backendConfigured }

    /// `POST /v1/license/sync` – only against a configured backend (StoreKit alone decides otherwise).
    public func syncLicense() async {
        guard config.backendConfigured else { return }
        await license.sync()
    }

    private func wire() {
        store.onChange = { [weak self] snapshot in
            guard let self else { return }
            license.update(store: snapshot)
            Task { await self.syncLicense() }
        }
        favorites.now = { [weak self] in self?.license.nowMs() ?? Int64(Date().timeIntervalSince1970 * 1000) }
        favorites.onChange = { [weak self] in self?.libraryChanged() }
        favorites.onLocalChange = { [weak self] in self?.libraryDidChange() }   // order/categories: device-local, no sync push
        license.sessionToken = { [weak self] in self?.account.sessionToken }
        account.onSessionChange = { [weak self] signedIn in
            guard let self else { return }
            Task {
                if signedIn {
                    await self.syncManager.syncNow()
                    self.favorites.reload()
                    self.libraryDidChange()
                } else {
                    await self.syncManager.reset()
                }
                await self.syncLicense()
            }
        }
        player.canPlay = { [weak self] in self?.license.canPlay ?? false }
        player.nowMs = { [weak self] in self?.license.nowMs() ?? Int64(Date().timeIntervalSince1970 * 1000) }
        player.onLibraryChange = { [weak self] in self?.libraryChanged() }
        player.aspect = settings.aspect
        player.largeBuffer = settings.largeBuffer
        player.setEngineOverride(settings.playerEngine)
        player.restoreLastSession(settings.lastSession)
        player.onLastSessionChange = { [weak self] in self?.settings.lastSession = $0 }
        player.onAspectChange = { [weak self] mode in self?.settings.aspect = mode }
        applyLanguagePreferences()
    }

    public func applyLanguagePreferences() {
        player.preferredAudioLanguage = settings.audioLanguage.isEmpty
            ? (settings.appLanguage.isEmpty ? Locale.current.language.languageCode?.identifier : settings.appLanguage) : settings.audioLanguage
        player.preferredSubtitleLanguage = settings.subtitleLanguage.isEmpty || settings.subtitleLanguage == "off" ? nil : settings.subtitleLanguage
    }

    /// `start()` ran (later activations refresh on resume instead).
    @ObservationIgnored public private(set) var hasStarted = false
    /// Last resume check (activations closer together than `resumeRefreshMinInterval` are ignored).
    @ObservationIgnored private var lastResumeCheck: Date?
    /// EPG reloads tried on resume, by source (a failing XMLTV is not retried on every activation).
    @ObservationIgnored private var epgResumeAttempts: [String: Date] = [:]
    /// The resume refresh waits this long (a playback start – QuickStart, the player resuming – goes first).
    @ObservationIgnored public var resumeRefreshDelay: Duration = .seconds(3)
    @ObservationIgnored public var resumeRefreshMinInterval: TimeInterval = 60
    /// The running resume refresh (tests await it).
    @ObservationIgnored public private(set) var resumeRefresh: Task<Void, Never>?

    /// App start: StoreKit listener, config, license sync, account sync, due refreshes.
    public func start() async {
        hasStarted = true
        store.start()
        if config.backendConfigured {
            await license.refreshConfig()
            await license.sync()
        }
        if accountsEnabled, account.isSignedIn {
            await syncManager.syncNow()
            lastSyncedAt = await syncManager.lastSyncedAt
            favorites.reload()
            libraryDidChange()
        }
        await refreshDueSources()
    }

    /// QuickStart bookkeeping: the persisted session no longer counts as "ended in the player".
    public func clearEndedInPlayer() {
        guard var last = settings.lastSession, last.endedInPlayer else { return }
        last.endedInPlayer = false
        settings.lastSession = last
        player.restoreLastSession(last)
    }

    /// Starts StoreKit (idempotent) and waits for the first entitlement snapshot, so `license.canPlay`
    /// is real before QuickStart decides. Returns immediately when playback is already allowed.
    public func awaitEntitlements(timeout: Duration) async {
        license.evaluate()
        if license.canPlay { return }
        store.start()
        _ = await store.waitForEntitlements(timeout: timeout)
        license.evaluate()
    }

    /// Scene phase handling: release the player when not active (docs/ARCHITECTURE.md §3.2).
    public func scenePhaseChanged(isActive: Bool) {
        if isActive {
            license.evaluate()
            Task {
                await syncLicense()
                if accountsEnabled, account.isSignedIn {
                    await syncManager.syncNow()
                    lastSyncedAt = await syncManager.lastSyncedAt
                    self.favorites.reload()
                    libraryDidChange()
                }
            }
            player.resumeAfterRelease()
            refreshOnResume()
        } else {
            player.release()
            flushDeferredWrites()
        }
    }

    /// Going to the background: writes still waiting for the database (the position `release()` just saved while
    /// a refresh held the writer, favorites, recent searches) are finished before the app may be suspended/killed,
    /// then the durable mirror gets the final user state.
    private func flushDeferredWrites() {
        let writes = database.deferredWrites, mirror = mirror
        let work: @Sendable () -> Void = {
            if !writes.isIdle { writes.drain(timeout: 20) }
            mirror.flushUserState()
        }
        #if canImport(UIKit) && !os(watchOS)
        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "db-flush") { task.end() }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            Task { @MainActor in task.end() }
        }
        #else
        DispatchQueue.global(qos: .userInitiated).async { work() }
        #endif
    }

    // MARK: Sources

    public func reloadSources() {
        fingerprintCache = [:]
        sources = (try? sourceRepository.all()) ?? []
        if let current = settings.currentSourceId, sources.contains(where: { $0.id == current }) {
            mirror.recordSelectedSource(current)
            return
        }
        settings.currentSourceId = sources.first?.id
        mirror.recordSelectedSource(settings.currentSourceId)
    }

    public var currentSource: Source? {
        sources.first { $0.id == settings.currentSourceId } ?? sources.first
    }

    public func selectSource(_ id: String) {
        settings.currentSourceId = id
        mirror.recordSelectedSource(id)
        catalogVersion += 1
    }

    /// Adds a source and loads it; on failure nothing is kept. The first source becomes the current one; a further
    /// source does not silently replace the one in use (IOS-08) – the UI offers to switch (`selectSource`).
    public func addSource(name: String, secrets: SourceSecrets,
                          onProgress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> Source {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = Source.make(name: trimmed.isEmpty ? secrets.displayHost : trimmed, secrets: secrets)
        let hadCurrent = currentSource != nil
        try sourceRepository.save(source, secrets: secrets)
        do {
            let loaded = try await refresher.refresh(sourceId: source.id, includeEpg: false, onProgress: onProgress)
            if !hadCurrent { settings.currentSourceId = loaded.id }
            reloadSources()
            catalogVersion += 1
            refreshEpgInBackground(sourceId: loaded.id)
            return loaded
        } catch {
            try? catalog.deleteContent(sourceId: source.id)
            try? sourceRepository.delete(id: source.id)
            reloadSources()
            throw error
        }
    }

    /// Updates metadata/secrets of an existing source.
    public func updateSource(_ source: Source, secrets: SourceSecrets? = nil) {
        try? sourceRepository.save(source, secrets: secrets)
        reloadSources()
    }

    /// Changes user settings of a source (EPG shift, auto refresh) atomically – a refresh running meanwhile keeps
    /// its result, the change is not lost to the refresh's copy either.
    public func updateSource(id: String, _ change: (inout Source) -> Void) {
        _ = try? sourceRepository.update(id: id, change)
        reloadSources()
    }

    /// Source edit (SCREENS §3.9 "Düzenle"): saves the new name / connection data and re-validates by reloading the
    /// source through the normal (atomic) refresh. On failure the previous name, connection data and status come
    /// back and the error is thrown – the catalog was never touched. When the provider's host or user name changed
    /// (new fingerprint), favorites and progress of the source move to the new content keys.
    @discardableResult
    public func editSource(id: String, name: String, secrets newSecrets: SourceSecrets,
                           onProgress: @escaping @Sendable (RefreshProgress) -> Void = { _ in }) async throws -> Source {
        guard let old = (try? sourceRepository.source(id: id)) ?? nil, let oldSecrets = secrets(for: id) else { throw SourceError.notFound }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var edited = old
        edited.name = trimmed.isEmpty ? newSecrets.displayHost : trimmed
        edited.displayHost = newSecrets.displayHost
        edited.epgUrlOverride = newSecrets.epgUrl != nil
        let oldFingerprint = fingerprint(sourceId: id)
        try sourceRepository.save(edited, secrets: newSecrets)
        fingerprintCache[id] = nil
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let loaded = try await refresher.refresh(sourceId: id, includeEpg: false, onProgress: onProgress)
            if let oldFingerprint, let newFingerprint = fingerprint(sourceId: id), newFingerprint != oldFingerprint {
                let moved = (try? library.rekey(fromFingerprint: oldFingerprint, toFingerprint: newFingerprint,
                                                nowMs: license.nowMs())) ?? []
                if !moved.isEmpty {
                    favorites.reload()
                    libraryChanged()
                }
            }
            reloadSources()
            catalogVersion += 1
            refreshEpgInBackground(sourceId: id)
            return loaded
        } catch {
            try? sourceRepository.save(old, secrets: oldSecrets)
            fingerprintCache[id] = nil
            reloadSources()
            throw ErrorClassifier.sourceError(from: error)
        }
    }

    /// Settings → Sources order (iOS drag, tvOS move up/down).
    public func moveSources(from: IndexSet, to: Int) {
        var ids = sources.map(\.id)
        ids.move(from: from, to: to)
        try? sourceRepository.reorder(ids)
        reloadSources()
    }

    @discardableResult
    public func refreshSource(id: String) async -> SourceError? {
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            try await refresher.refresh(sourceId: id, includeEpg: false)
            reloadSources()
            catalogVersion += 1
            refreshEpgInBackground(sourceId: id)
            return nil
        } catch {
            reloadSources()
            return ErrorClassifier.sourceError(from: error)
        }
    }

    /// Guide loading never blocks the lists (docs/ARCHITECTURE.md §3.1: XMLTV in the background).
    public func refreshEpgInBackground(sourceId: String) {
        let refresher = self.refresher
        Task { [weak self] in
            let count = await refresher.refreshEpg(sourceId: sourceId)
            guard let self else { return }
            self.reloadSources()   // the EPG status (programmes / error) is shown in source management
            if count != nil { self.catalogVersion += 1 }
        }
    }

    /// Launch (`start()`): sources whose auto refresh is due, and – once per launch, whatever their auto
    /// refresh setting – sources whose catalog was built with an older `CatalogFormat`. Runs through the
    /// normal refresh pipeline after QuickStart; a successful refresh stores the current format, a failed
    /// one is retried on the next launch.
    public func refreshDueSources(now: Date = Date()) async {
        for source in sources where !refreshing.contains(source.id) && !restore.sources.contains(where: { $0.id == source.id })
            && (source.isRefreshDue(now: now) || refresher.needsFormatRefresh(sourceId: source.id)) {
            await refreshSource(id: source.id)
        }
    }

    /// Back in the foreground (B5): tvOS keeps an app suspended for days, so catalog and EPG refreshes that became
    /// due meanwhile run now – after `resumeRefreshDelay` and never while a playback is starting. Catalog: the
    /// source's auto-refresh interval; EPG (between catalog refreshes): when the stored guide ends within 24 h,
    /// at most every 6 h per source.
    public func refreshOnResume(now: Date = Date()) {
        guard hasStarted else { return }   // the cold start runs `refreshDueSources` itself
        if let last = lastResumeCheck, now.timeIntervalSince(last) < resumeRefreshMinInterval { return }
        lastResumeCheck = now
        resumeRefresh?.cancel()
        let delay = resumeRefreshDelay
        resumeRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            for _ in 0..<20 {   // a playback start in progress: wait (up to ~10 s more)
                guard let self, !Task.isCancelled else { return }
                if self.player.phase != .loading { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, !Task.isCancelled else { return }
            let due = self.sources.filter { $0.isRefreshDue(now: now) }.map(\.id)
            await self.refreshDueSources(now: now)
            for source in self.sources where !due.contains(source.id) && self.epgNeedsReload(sourceId: source.id, now: now) {
                self.epgResumeAttempts[source.id] = now
                self.refreshEpgInBackground(sourceId: source.id)
            }
        }
    }

    /// The stored guide ends within 24 h (or there is none) and no reload was tried in the last 6 h.
    func epgNeedsReload(sourceId: String, now: Date) -> Bool {
        guard refresher.epgURL(sourceId: sourceId) != nil, !refreshing.contains(sourceId) else { return false }
        if let tried = epgResumeAttempts[sourceId], now.timeIntervalSince(tried) < 6 * 3600 { return false }
        if let loaded = sources.first(where: { $0.id == sourceId })?.lastRefreshResult?.epgLoadedAt,
           now.timeIntervalSince(loaded) < 6 * 3600 { return false }
        guard let end = (try? epg.latestEnd(sourceId: sourceId)) ?? nil else { return true }
        return end.timeIntervalSince(now) < 24 * 3600
    }

    public func deleteSource(id: String) {
        refresher.clearCatalogFormat(sourceId: id)
        categoryPrefs.removeAll(sourceId: id)
        try? catalog.deleteContent(sourceId: id)
        recentSearches.clear(sourceId: id)
        let catalog = catalog
        Task.detached(priority: .utility) { try? catalog.collectIndexGarbage() }
        try? sourceRepository.delete(id: id)
        reloadSources()
        catalogVersion += 1
    }

    public func secrets(for sourceId: String) -> SourceSecrets? {
        sourceRepository.secrets(id: sourceId)
    }

    /// Fingerprint of a source (content keys).
    public func fingerprint(sourceId: String) -> String? {
        if let cached = fingerprintCache[sourceId] { return cached }
        let value = secrets(for: sourceId).flatMap(SourceFingerprint.of)
        if let value { fingerprintCache[sourceId] = value }
        return value
    }

    // MARK: Library

    private func libraryChanged() {
        libraryDidChange()
        Task { await syncManager.noteLocalChange() }
    }

    public func contentKey(sourceId: String, kind: ContentKind, itemId: String) -> String? {
        fingerprint(sourceId: sourceId).map { ContentKey.make(fingerprint: $0, kind: kind, itemId: itemId) }
    }

    public func isFavorite(sourceId: String, kind: ContentKind, itemId: String) -> Bool {
        guard let key = contentKey(sourceId: sourceId, kind: kind, itemId: itemId) else { return false }
        return favorites.isFavorite(key)
    }

    /// The ⭐ target of a catalog item (nil when the source has no fingerprint).
    public func favoriteTarget(sourceId: String, kind: ContentKind, itemId: String, title: String, posterUrl: String?) -> FavoriteTarget? {
        contentKey(sourceId: sourceId, kind: kind, itemId: itemId).map { FavoriteTarget(contentKey: $0, title: title, kind: kind, posterUrl: posterUrl) }
    }

    @discardableResult
    public func toggleFavorite(sourceId: String, kind: ContentKind, itemId: String, title: String, posterUrl: String?) -> Bool {
        guard let key = contentKey(sourceId: sourceId, kind: kind, itemId: itemId) else { return false }
        return favorites.toggle(FavoriteTarget(contentKey: key, title: title, kind: kind, posterUrl: posterUrl))
    }

    // MARK: Playback

    /// Builds a playback request (adds the content-key fingerprint and resume position).
    public func request(for item: PlaybackRequest.Item, channels: [Channel] = [], fromStart: Bool = false) -> PlaybackRequest {
        var sourceId: String?
        switch item {
        case .channel(let c): sourceId = c.sourceId
        case .movie(let m): sourceId = m.sourceId
        case .episode(let e, _): sourceId = e.sourceId
        case .url: sourceId = nil
        }
        let source = sourceId.flatMap { id in sources.first { $0.id == id } }
        var request = PlaybackRequest(item: item, source: source, channels: channels)
        request.sourceFingerprint = sourceId.flatMap(fingerprint(sourceId:))
        if !fromStart, !request.isLive, let key = request.contentKey, let progress = try? library.progress(contentKey: key) {
            request.startPositionMs = ResumePolicy.startPositionMs(positionMs: progress.data.positionMs, durationMs: progress.data.durationMs)
        }
        return request
    }

    // MARK: Details (Xtream `get_vod_info` / `get_series_info`)

    private func xtreamClient(sourceId: String) -> XtreamClient? {
        guard case .xtream(let secrets)? = secrets(for: sourceId) else { return nil }
        return XtreamClient(sourceId: sourceId, secrets: secrets, transport: transport)
    }

    /// True for an Xtream source (details and episodes are fetched lazily).
    public func isXtream(sourceId: String) -> Bool {
        if case .xtream? = secrets(for: sourceId) { return true }
        return false
    }

    /// `get_series_info`: the episodes replace the cached ones of the series, the details are cached with the fetch
    /// time (revalidated after `ItemDetails.ttl`), cast/director/description become searchable. Throws `SourceError`.
    @discardableResult
    public func fetchSeriesInfo(sourceId: String, seriesId: String, now: Date = Date()) async throws -> (episodes: [Episode], details: ItemDetails) {
        guard let client = xtreamClient(sourceId: sourceId) else { throw SourceError.notFound }
        let info = try await client.seriesInfo(seriesId: seriesId)
        let episodes = info.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let details = ItemDetails(info.details)
        let catalog = catalog
        try? catalog.replaceEpisodes(sourceId: sourceId, seriesId: seriesId, episodes: episodes)
        try? catalog.saveDetails(details, sourceId: sourceId, kind: .series, itemId: seriesId, fetchedAt: now)
        Task.detached(priority: .utility) {
            try? catalog.updateDetails(sourceId: sourceId, kind: .series, itemId: seriesId, cast: details.cast,
                                       director: details.director, plot: details.plot)
        }
        return (episodes, details)
    }

    /// `get_vod_info` of an Xtream movie, cached like `fetchSeriesInfo`. Throws `SourceError`.
    @discardableResult
    public func fetchMovieDetails(_ movie: Movie, now: Date = Date()) async throws -> ItemDetails {
        guard let client = xtreamClient(sourceId: movie.sourceId) else { throw SourceError.notFound }
        let details = ItemDetails(try await client.vodInfo(vodId: movie.id))
        let catalog = catalog
        try? catalog.saveDetails(details, sourceId: movie.sourceId, kind: .movie, itemId: movie.id, fetchedAt: now)
        Task.detached(priority: .utility) {   // cast/director + description become searchable (SCREENS §3.6)
            try? catalog.updateDetails(sourceId: movie.sourceId, kind: .movie, itemId: movie.id, cast: details.cast,
                                       director: details.director, plot: details.plot)
        }
        return details
    }

    /// An episode ready to play. A "Continue watching" entry may only know the episode id (Xtream episodes are
    /// fetched per series; a progress synced from another device): the stored row, else `get_series_info` once.
    public func playableEpisode(_ episode: Episode) async -> Episode {
        if episode.url != nil || episode.containerExt != nil { return episode }
        if let stored = try? catalog.episode(sourceId: episode.sourceId, id: episode.id) { return stored }
        guard isXtream(sourceId: episode.sourceId),
              let fetched = try? await fetchSeriesInfo(sourceId: episode.sourceId, seriesId: episode.seriesId) else { return episode }
        return fetched.episodes.first { $0.id == episode.id } ?? episode
    }

    // MARK: Diagnostics

    public func clearEpgCache() {
        try? epg.deleteAll()
        catalogVersion += 1
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Background task identifier shared by the expiration handler and the drain completion.
@MainActor
final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
