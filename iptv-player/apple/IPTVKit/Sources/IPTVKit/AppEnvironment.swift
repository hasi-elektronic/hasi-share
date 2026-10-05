import Foundation
import IPTVCore
import Observation

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

    public init(displayName: String, bundleId: String, appVersion: String, backendBaseURL: URL, productIDs: ProductIDs,
                licenseKeysJSON: Data, platform: BackendPlatform, rawDeviceId: String, deviceName: String) {
        self.displayName = displayName
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.backendBaseURL = backendBaseURL
        self.productIDs = productIDs
        self.licenseKeysJSON = licenseKeysJSON
        self.platform = platform
        self.rawDeviceId = rawDeviceId
        self.deviceName = deviceName
    }

    public var deviceKey: String { DeviceKey.make(appId: bundleId, rawDeviceId: rawDeviceId) }
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
    @ObservationIgnored public let secureStore: any SecureStore
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

    public init(config: AppConfig, database: AppDatabase, secureStore: any SecureStore, kv: any KeyValueStore,
                settings: AppSettings = AppSettings(), transport: any HTTPTransport = URLSessionTransport.shared,
                engines: PlaybackEngines? = nil) throws {
        self.config = config
        self.database = database
        self.secureStore = secureStore
        self.settings = settings
        sourceRepository = SourceRepository(database: database, secureStore: secureStore)
        catalog = CatalogRepository(database: database)
        epg = EpgRepository(database: database)
        library = LibraryRepository(database: database)
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
        player = PlayerController(resolver: StreamResolver(secrets: { repo.secrets(id: $0) }, vlcAvailable: engines.vlcAvailable),
                                  library: library, engines: engines)
        wire()
        sourceRepository.registerSecretsForRedaction()
        reloadSources()
    }

    private func wire() {
        store.onChange = { [weak self] snapshot in
            guard let self else { return }
            license.update(store: snapshot)
            Task { await self.license.sync() }
        }
        license.sessionToken = { [weak self] in self?.account.sessionToken }
        account.onSessionChange = { [weak self] signedIn in
            guard let self else { return }
            Task {
                if signedIn {
                    await self.syncManager.syncNow()
                    self.libraryVersion += 1
                } else {
                    await self.syncManager.reset()
                }
                await self.license.sync()
            }
        }
        player.canPlay = { [weak self] in self?.license.canPlay ?? false }
        player.nowMs = { [weak self] in self?.license.nowMs() ?? Int64(Date().timeIntervalSince1970 * 1000) }
        player.onLibraryChange = { [weak self] in self?.libraryChanged() }
        player.aspect = settings.aspect
        player.onAspectChange = { [weak self] mode in self?.settings.aspect = mode }
        applyLanguagePreferences()
    }

    public func applyLanguagePreferences() {
        player.preferredAudioLanguage = settings.audioLanguage.isEmpty ? Locale.current.language.languageCode?.identifier : settings.audioLanguage
        player.preferredSubtitleLanguage = settings.subtitleLanguage.isEmpty || settings.subtitleLanguage == "off" ? nil : settings.subtitleLanguage
    }

    /// App start: StoreKit listener, config, license sync, account sync, due refreshes.
    public func start() async {
        store.start()
        await license.refreshConfig()
        await license.sync()
        if account.isSignedIn {
            await syncManager.syncNow()
            lastSyncedAt = await syncManager.lastSyncedAt
            libraryVersion += 1
        }
        await refreshDueSources()
    }

    /// Scene phase handling: release the player when not active (docs/ARCHITECTURE.md §3.2).
    public func scenePhaseChanged(isActive: Bool) {
        if isActive {
            license.evaluate()
            Task {
                await license.sync()
                if account.isSignedIn {
                    await syncManager.syncNow()
                    lastSyncedAt = await syncManager.lastSyncedAt
                    libraryVersion += 1
                }
            }
            player.resumeAfterRelease()
        } else {
            player.release()
        }
    }

    // MARK: Sources

    public func reloadSources() {
        sources = (try? sourceRepository.all()) ?? []
        if let current = settings.currentSourceId, sources.contains(where: { $0.id == current }) { return }
        settings.currentSourceId = sources.first?.id
    }

    public var currentSource: Source? {
        sources.first { $0.id == settings.currentSourceId } ?? sources.first
    }

    public func selectSource(_ id: String) {
        settings.currentSourceId = id
        catalogVersion += 1
    }

    /// Adds a source and loads it; on failure nothing is kept.
    public func addSource(name: String, secrets: SourceSecrets,
                          onProgress: @escaping @Sendable (RefreshProgress) -> Void) async throws -> Source {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = Source.make(name: trimmed.isEmpty ? secrets.displayHost : trimmed, secrets: secrets)
        try sourceRepository.save(source, secrets: secrets)
        do {
            let loaded = try await refresher.refresh(sourceId: source.id, includeEpg: false, onProgress: onProgress)
            settings.currentSourceId = loaded.id
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

    /// Updates metadata/secrets of an existing source (edit form, EPG shift, auto refresh).
    public func updateSource(_ source: Source, secrets: SourceSecrets? = nil) {
        try? sourceRepository.save(source, secrets: secrets)
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
            if count != nil {
                self.reloadSources()
                self.catalogVersion += 1
            }
        }
    }

    public func refreshDueSources() async {
        let now = Date()
        for source in sources where source.isRefreshDue(now: now) {
            await refreshSource(id: source.id)
        }
    }

    public func deleteSource(id: String) {
        try? catalog.deleteContent(sourceId: id)
        try? sourceRepository.delete(id: id)
        reloadSources()
        catalogVersion += 1
    }

    public func secrets(for sourceId: String) -> SourceSecrets? {
        sourceRepository.secrets(id: sourceId)
    }

    /// Fingerprint of a source (content keys).
    public func fingerprint(sourceId: String) -> String? {
        secrets(for: sourceId).flatMap(SourceFingerprint.of)
    }

    // MARK: Library

    private func libraryChanged() {
        libraryVersion += 1
        Task { await syncManager.noteLocalChange() }
    }

    public func contentKey(sourceId: String, kind: ContentKind, itemId: String) -> String? {
        fingerprint(sourceId: sourceId).map { ContentKey.make(fingerprint: $0, kind: kind, itemId: itemId) }
    }

    public func isFavorite(sourceId: String, kind: ContentKind, itemId: String) -> Bool {
        guard let key = contentKey(sourceId: sourceId, kind: kind, itemId: itemId) else { return false }
        return (try? library.isFavorite(contentKey: key)) ?? false
    }

    public func toggleFavorite(sourceId: String, kind: ContentKind, itemId: String, title: String, posterUrl: String?) {
        guard let key = contentKey(sourceId: sourceId, kind: kind, itemId: itemId) else { return }
        let on = !((try? library.isFavorite(contentKey: key)) ?? false)
        _ = try? library.setFavorite(on, contentKey: key, title: title, kind: kind, posterUrl: posterUrl, nowMs: license.nowMs())
        libraryChanged()
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
        if !fromStart, !request.isLive, let key = request.contentKey, let progress = try? library.progress(contentKey: key),
           let position = progress.data.positionMs, let duration = progress.data.durationMs,
           !WatchHistory.isCompleted(positionMs: position, durationMs: duration), position > 5000 {
            request.startPositionMs = position
        }
        return request
    }

    // MARK: Diagnostics

    public func clearEpgCache() {
        try? epg.deleteAll()
        catalogVersion += 1
    }
}
