import Foundation
import IPTVCore
import IPTVKit
import Observation
import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Top-level sections: text tabs of the mobile header and the Apple TV top tab bar (SCREENS §2).
enum AppSection: String, CaseIterable, Hashable {
    case search, home, movies, series, live, guide, settings

    /// Text tabs of the iPhone/iPad header (search and settings are icons on the right).
    static let mobile: [AppSection] = [.home, .movies, .series, .live, .guide]

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .live: return "tv"
        case .guide: return "calendar"
        case .movies: return "film"
        case .series: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }

    var titleKey: String { "nav_\(rawValue)" }
}

/// Pushed routes besides catalog items (movie / series detail).
enum BrowseRoute: Hashable {
    case search
    case favorites
    /// Poster grid behind a row's "See all" (category or sort).
    case grid(kind: ContentKind, categoryId: String?, title: String, sort: CatalogSort)
    /// Poster grid of every (visible) category of one country ("See all" of a country-filtered row).
    case countryGrid(kind: ContentKind, country: String, title: String, sort: CatalogSort)
    /// Full result list of one search section ("Show all", SCREENS §3.6).
    case searchList(SearchListKind, query: String, title: String)
}

/// App-wide navigation state shared by iOS and tvOS (section, player / paywall / settings presentation).
@MainActor
@Observable
final class Router {
    var playerPresented = false {
        didSet { if !playerPresented { browseDeferred = false } }
    }
    /// IOS-06: an early QuickStart covers the app with the player from the first frame – the browse screens under
    /// it are built only once the player closes (their first render competed with the stream start).
    var browseDeferred = false
    var paywallPresented = false
    /// Current section (mobile header tab / TV top tab).
    var section: AppSection = .home
    /// Mobile: settings sheet from the gear button.
    var settingsPresented = false
    /// Mobile: navigation path of the section stack (search, details).
    var path = NavigationPath()
    /// Mobile: header solid (hero scrolled away). Set by the browse screens.
    var headerSolid = false
    /// TV: detail to push onto the current tab's stack (hero "Info" without a NavigationLink).
    var tvPushRequest: CatalogItem?
    /// TV: browse route (search "Show all" → category grid) to push onto the current tab's stack.
    var tvRoutePushRequest: BrowseRoute?
    /// Live "Show in TV guide": the guide opens on this channel (its category, scrolled to, in the panel).
    var guideFocus: Channel?

    func showInGuide(_ channel: Channel) {
        guideFocus = channel
        section = .guide
    }

    /// Search → live category: Live TV opens filtered to this category.
    var liveCategory: String?

    func showLiveCategory(_ categoryId: String) {
        liveCategory = categoryId
        #if !os(tvOS)
        path = NavigationPath()   // leave the pushed search screen
        #endif
        section = .live
    }
    /// Keeps the onboarding flow (welcome → add source → summary) on screen until "Continue".
    var onboarding = false
    /// Screen opened by a debug launch argument (`-uiScreen paywall`…), UI tests & screenshots.
    var debugScreen: String?

    let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
        // IOS-06: QuickStart already opened the last channel while the app was being built – the player cover is
        // part of the very first frame (no Home first, no presentation wait).
        playerPresented = AppBootstrap.quickStartedEarly
        browseDeferred = AppBootstrap.quickStartedEarly
    }

    /// Build 17 (iOS): the player screen was dismissed for Picture in Picture; playback goes on in the PiP window.
    var pipMinimized = false
    /// Build 17: a deep link that arrived while the catalog was still loading (cold start, restore); retried when the
    /// catalog changes (`DeepLinkRouting.swift`).
    @ObservationIgnored var pendingDeepLink: (url: URL, at: Date)?

    /// PiP started from the player's button: dismiss the player screen without ending playback.
    func minimizeForPictureInPicture() {
        guard playerPresented else { return }
        pipMinimized = true
        playerPresented = false
    }

    /// "Restore" in the PiP window (or PiP could not start): the player screen again.
    func restoreFromPictureInPicture() {
        let wasMinimized = pipMinimized
        pipMinimized = false
        if wasMinimized, env.player.request != nil, !playerPresented { playerPresented = true }
    }

    /// The PiP window was closed while no player screen exists: playback ends.
    func endMinimizedPlayback() {
        pipMinimized = false
        env.player.close()
    }

    /// Opens the player – or the paywall when playback is locked (CONTRACT §7.4).
    func play(_ item: PlaybackRequest.Item, channels: [Channel] = [], fromStart: Bool = false) {
        env.license.evaluate()
        guard env.license.canPlay else {
            paywallPresented = true
            return
        }
        if pipMinimized {
            // A new item from the app while PiP shows the previous one: back to the full-screen player.
            pipMinimized = false
            #if os(iOS)
            PictureInPictureCoordinator.shared.stop()
            #endif
        }
        // "Continue watching" may know an Xtream episode only by id (no cached row): complete it first (B1).
        if case .episode(let episode, let seriesTitle) = item, episode.url == nil, episode.containerExt == nil {
            Task {
                let playable = await env.playableEpisode(episode)
                env.player.open(env.request(for: .episode(playable, seriesTitle: seriesTitle), channels: channels, fromStart: fromStart))
                playerPresented = true
            }
            return
        }
        env.player.open(env.request(for: item, channels: channels, fromStart: fromStart))
        playerPresented = true
    }

    func closePlayer() {
        env.player.close()
        playerPresented = false
    }
}

/// Builds the `AppEnvironment` from Info.plist values (set from `Config/Shared.xcconfig`).
@MainActor
enum AppBootstrap {
    static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// UserDefaults of this launch (separate suite in UI-test mode) – used by local UI state (hidden channels).
    static var defaults: UserDefaults = .standard
    /// Lives for the whole app run (interruption / route-change → player).
    private static let audioObserver = AudioSessionObserver()

    static func argument(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func makeEnvironment() -> AppEnvironment {
        let isUITest = arguments.contains("-uiTestReset")
        // DEBUG `-uiSandbox <name>`: real SQLite file + Keychain + UserDefaults under their own names (relaunch
        // and purge tests); `-uiTestReset` then wipes that sandbox instead of switching to in-memory stores.
        var sandbox: String?
        #if DEBUG
        sandbox = argument("-uiSandbox")
        #endif
        let suiteName = sandbox.map { "uisandbox.\($0)" } ?? (isUITest ? "uitest" : nil)
        let suite = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        if isUITest, let suiteName { suite.removePersistentDomain(forName: suiteName) }
        defaults = suite

        #if os(tvOS)
        let platform = BackendPlatform.tvos
        #else
        let platform = BackendPlatform.ios
        #endif
        #if canImport(UIKit)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let deviceName = UIDevice.current.model
        #else
        let deviceId = "unknown"
        let deviceName = "Mac"
        #endif
        let version = "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))"
        let backendOverride = argument("-backendURL")
        let config = AppConfig(displayName: info("CFBundleDisplayName"), bundleId: Bundle.main.bundleIdentifier ?? info("APP_BUNDLE_ID"),
                               appVersion: version,
                               backendBaseURL: URL(string: backendOverride ?? info("BACKEND_BASE_URL")) ?? URL(string: "https://invalid.example")!,
                               productIDs: ProductIDs(lifetime: info("PRODUCT_LIFETIME"), trial: info("PRODUCT_TRIAL")),
                               licenseKeysJSON: licenseKeys(), platform: platform, rawDeviceId: deviceId, deviceName: deviceName,
                               accountsEnabled: info("ACCOUNTS_ENABLED").uppercased() == "YES",
                               privacyURL: URL(string: info("PRIVACY_URL")).flatMap { $0.host == nil ? nil : $0 } ?? AppConfig.defaultPrivacyURL,
                               termsURL: URL(string: info("TERMS_URL")).flatMap { $0.host == nil ? nil : $0 } ?? AppConfig.defaultTermsURL)
        let secretsService = (Bundle.main.bundleIdentifier ?? "app") + ".secrets" + (sandbox.map { ".uisandbox.\($0)" } ?? "")
        let fileName = sandbox.map { "uisandbox-\($0).sqlite" } ?? "catalog.sqlite"
        #if DEBUG
        // `-debugDeleteCatalogDB`: simulates tvOS purging Application Support (the mirror must restore the sources).
        if arguments.contains("-debugDeleteCatalogDB") || (isUITest && sandbox != nil),
           let dir = try? AppDatabase.applicationSupportDirectory() {
            AppDatabase.deleteFiles(at: dir.appendingPathComponent(fileName))
        }
        if isUITest, sandbox != nil { KeychainStore(service: secretsService).removeAll() }
        #endif
        let database: AppDatabase
        if isUITest && sandbox == nil {
            database = try! AppDatabase.inMemory()
        } else {
            let opened = AppDatabase.open(fileName: fileName)   // never fails: corrupt → recreate, Caches, memory
            database = opened.database
            if opened.location != .applicationSupport || opened.recreatedCorruptFile {
                SafeLog.warning("database location: \(opened.location.rawValue), recreated: \(opened.recreatedCorruptFile)")
            }
        }
        let secure: any SecureStore = isUITest && sandbox == nil ? InMemorySecureStore() : KeychainStore(service: secretsService)
        let kv = UserDefaultsStore(suite)
        let settings = AppSettings(defaults: suite)
        #if DEBUG
        if arguments.contains("-perfOverlay") { settings.showPerfOverlay = true }   // UI tests read the engine label
        // UI tests: `-playerEngine apple|vlc` (Settings → Advanced → Player engine).
        if let engine = argument("-playerEngine").flatMap(PlayerEngineOverride.init(rawValue:)) { settings.playerEngine = engine }
        #endif
        L10n.setLanguage(settings.appLanguage)
        // Build 17 iCloud sync: the real iCloud key-value store / account; UI tests and sandboxes never touch iCloud
        // (`-uiCloudAccount yes` = an account is signed in, `-uiCloudSeedSource <name>` = a source from "another
        // device" whose secrets never arrive).
        let cloudStore: any CloudKeyValueStore
        let cloudAccount: any CloudAccountProvider
        if isUITest || sandbox != nil {
            let memory = InMemoryCloudKeyValueStore()
            #if DEBUG
            if let name = argument("-uiCloudSeedSource") {
                CloudSync.seedRemoteSource(in: memory, id: "cloud-seed-1", name: name, host: "panel.example.com")
            }
            #endif
            cloudStore = memory
            cloudAccount = StaticCloudAccount(available: argument("-uiCloudAccount") == "yes")
        } else {
            cloudStore = UbiquitousKeyValueStore()
            cloudAccount = UbiquityAccount()
        }
        do {
            let env = try AppEnvironment(config: config, database: database, secureStore: secure, kv: kv,
                                         settings: settings, engines: .app, cloudStore: cloudStore, cloudAccount: cloudAccount)
            // Hidden live channels/categories sync too; activation after every preference provider is registered.
            env.cloud.preferenceProviders.append(HiddenStore.shared)
            HiddenStore.shared.onChange = { [weak env] in env?.cloud.noteLocalChange() }
            env.cloud.activate()
            AudioSessionConfigurator.configure()
            env.player.audioSession = AudioSessionConfigurator.hooks
            #if canImport(UIKit)
            // B2: no auto-lock / screensaver while any engine plays (libVLC does not manage the idle timer).
            env.player.keepDisplayAwake = { UIApplication.shared.isIdleTimerDisabled = $0 }
            #endif
            #if DEBUG
            // UI tests: a longer seek-preview idle commit, so the bubble can be read before it commits.
            if let ms = argument("-seekCommitMs").flatMap(Int64.init), ms > 0 { env.player.seekCommitIdleMs = ms }
            // UI tests (Build 16): shorter next-episode countdown / sleep-timer "minute".
            if let s = argument("-upNextSeconds").flatMap(Int.init), s > 0 { env.player.upNextCountdownSeconds = s }
            if let ms = argument("-sleepTimerMinuteMs").flatMap(Int64.init), ms > 0 {
                env.player.sleepTimerMinuteMs = ms
                env.player.sleepFadeMs = min(env.player.sleepFadeMs, ms)
            }
            #endif
            audioObserver.start(player: env.player)
            // Build 17: background audio + PiP (iOS: UIBackgroundModes audio), lock screen / Now Playing (both).
            #if os(iOS)
            env.player.backgroundPlaybackSupported = true
            #endif
            NowPlayingCoordinator.shared.install(env: env)
            env.player.onPlaybackChange = {
                NowPlayingCoordinator.shared.update()
                #if os(iOS)
                PictureInPictureCoordinator.shared.playbackChanged()
                #endif
            }
            PerfTrace.shared.launchPhase("env")
            quickStartEarly(env: env)
            return env
        } catch {
            fatalError("Invalid build configuration (license keys): \(error)")
        }
    }

    /// `Config/license-keys.json`. DEBUG builds may add a local dev key set with the launch
    /// argument `-debugLicenseKeys <base64url JSON>` (never shipped, never in the repo).
    static func licenseKeys() -> Data {
        var keys: [String: ECPublicJWK] = [:]
        if let url = Bundle.main.url(forResource: "license-keys", withExtension: "json"), let data = try? Data(contentsOf: url),
           let set = try? JSONDecoder().decode([String: ECPublicJWK].self, from: data) {
            keys = set
        }
        #if DEBUG
        if let b64 = argument("-debugLicenseKeys"), let data = Base64URL.decode(b64),
           let set = try? JSONDecoder().decode([String: ECPublicJWK].self, from: data) {
            keys.merge(set) { a, _ in a }
        }
        #endif
        return (try? JSONEncoder().encode(keys)) ?? Data("{}".utf8)
    }

    /// TestFlight builds run in the StoreKit sandbox: with `TESTFLIGHT_FULL_ACCESS = YES`
    /// (Config/Shared.xcconfig) testers get full access without buying. App Store installs
    /// report `.production` and keep the normal trial/purchase flow.
    ///
    /// Synchronous and cheap: TestFlight installs carry a sandbox receipt, which grants access right
    /// away (the UI never flashes the trial state, QuickStart never waits on StoreKit). Only when that
    /// check does not grant, `AppTransaction` confirms in the background; the returned task is that
    /// confirmation (nil = nothing pending) – `quickStart` waits for it at most until its own deadline.
    /// Verification can fail on tvOS/TestFlight – the environment of an unverified payload is still the
    /// right signal for this non-security-critical unlock.
    @discardableResult
    static func applyTesterAccess(env: AppEnvironment) -> Task<Void, Never>? {
        guard info("TESTFLIGHT_FULL_ACCESS").uppercased() == "YES" else { return nil }
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            env.license.testerFullAccess = true
            SafeLog.info("TestFlight build: tester full access enabled (receipt)")
            return nil
        }
        return Task { @MainActor in
            let environment: AppStore.Environment?
            switch try? await AppTransaction.shared {
            case .verified(let t)?: environment = t.environment
            case .unverified(let t, _)?: environment = t.environment
            case nil: environment = nil
            }
            if environment == .sandbox {
                env.license.testerFullAccess = true
                SafeLog.info("TestFlight build: tester full access enabled")
            }
        }
    }

    /// Set when `quickStartEarly` opened the last channel during `makeEnvironment` (the router presents the player
    /// from its first frame on).
    static private(set) var quickStartedEarly = false

    /// IOS-06 (Build 16): QuickStart as early as possible – right after the environment exists, before any view is
    /// built. Only when playback is allowed without waiting (stored entitlement / trial, the TestFlight receipt);
    /// otherwise the regular `quickStart` below decides after the StoreKit snapshot. Measured: the first frame no
    /// longer waits for the Home screen, the `.task` start and the cover animation.
    static func quickStartEarly(env: AppEnvironment) {
        guard env.settings.quickStart, let last = env.settings.lastSession, last.endedInPlayer, !env.sources.isEmpty,
              let channel = (try? env.catalog.channel(sourceId: last.sourceId, id: last.channelId)) ?? nil else { return }
        #if DEBUG
        if arguments.contains("-noEarlyQuickStart") { return }   // before/after measurements (IOSQuickStartPerfTests)
        if arguments.contains("-uiTrial") {
            env.license.update(store: StoreSnapshot(trialStartMs: env.license.nowMs() - 2 * 86_400_000, trialTransactionId: nil))
        }
        #endif
        if info("TESTFLIGHT_FULL_ACCESS").uppercased() == "YES", Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            env.license.testerFullAccess = true
        }
        env.license.evaluate()
        guard env.license.canPlay else { return }
        var page = (try? env.catalog.channels(sourceId: channel.sourceId, categoryId: channel.categoryId, limit: 200)) ?? []
        if !page.contains(where: { $0.id == channel.id }) { page.insert(channel, at: 0) }
        env.player.open(env.request(for: .channel(channel), channels: page))
        quickStartedEarly = true
        PerfTrace.shared.launchPhase("quickStartEarly")
    }

    /// QuickStart (docs/SCREENS.md §3.2): when the app was left while a live channel was playing, open that
    /// channel in the player right away – before any source refresh (`env.start()`). Call AFTER
    /// `applyTesterAccess` and pass its pending `AppTransaction` confirmation (if any). `canPlay` is only
    /// trusted after the first StoreKit entitlement snapshot (`awaitEntitlements`, local read), otherwise
    /// trial/purchase users would never get quick start; while it is still false the tester confirmation
    /// gets the rest of the same window – the whole wait stays ≤ 1.5 s (`QuickStart.entitlementTimeout`).
    /// The "ended in player" flag is consumed only when it can never resume (feature off / channel gone),
    /// never because of a transient `canPlay == false`.
    static func quickStart(env: AppEnvironment, router: Router, testerAccess: Task<Void, Never>? = nil) async {
        guard !router.playerPresented, !router.onboarding, !env.sources.isEmpty,
              env.settings.lastSession?.endedInPlayer == true else { return }
        PerfTrace.shared.launchPhase("quickStart")
        let channelOf: (LastSession?) -> Channel? = { last in
            last.flatMap { (try? env.catalog.channel(sourceId: $0.sourceId, id: $0.channelId)) ?? nil }
        }
        if env.settings.quickStart, channelOf(env.settings.lastSession) != nil {
            let deadline = ContinuousClock.now + QuickStart.entitlementTimeout
            await env.awaitEntitlements(timeout: QuickStart.entitlementTimeout)
            if !env.license.canPlay, let testerAccess {
                _ = await QuickStart.wait(for: testerAccess, until: deadline)   // runs on after the deadline
            }
        }
        PerfTrace.shared.launchPhase("quickStartDecided")
        guard !router.playerPresented else { return }   // e.g. the user was faster than the wait
        let last = env.settings.lastSession
        let channel = channelOf(last)
        switch QuickStart.decide(enabled: env.settings.quickStart, last: last, canPlay: env.license.canPlay, channelExists: channel != nil) {
        case .play:
            guard let channel else { return }
            // Zapping list: the channel's category (first 200); the channel itself always belongs to it.
            var page = (try? env.catalog.channels(sourceId: channel.sourceId, categoryId: channel.categoryId, limit: 200)) ?? []
            if !page.contains(where: { $0.id == channel.id }) { page.insert(channel, at: 0) }
            router.play(.channel(channel), channels: page)
        case .none:
            if QuickStart.shouldDiscard(enabled: env.settings.quickStart, last: last, channelExists: channel != nil) {
                env.clearEndedInPlayer()
            }
        }
    }

    /// Debug/UI-test hooks: `-seedM3U <url>` adds a source, `-uiScreen <name>` opens a screen,
    /// `-uiTrial` simulates an active StoreKit trial (only in DEBUG builds).
    static func applyDebugHooks(env: AppEnvironment, router: Router) async {
        PerfTrace.shared.launchPhase("task")
        #if DEBUG
        if arguments.contains("-uiTrial") {
            env.license.update(store: StoreSnapshot(trialStartMs: env.license.nowMs() - 2 * 86_400_000, trialTransactionId: nil))
        }
        if let m3u = argument("-seedM3U"), env.sources.isEmpty {
            _ = try? await env.addSource(name: argument("-seedName") ?? "Demo", secrets: .m3u(M3USecrets(url: m3u))) { _ in }
        }
        // `-seedXtream <server>`: the fake panel of the UI tests (UITests/Fixtures/xtream, range_server.py).
        if let server = argument("-seedXtream"), env.sources.isEmpty {
            _ = try? await env.addSource(name: argument("-seedName") ?? "Panel",
                                         secrets: .xtream(XtreamSecrets(serverUrl: server, username: "demo", password: "demo"))) { _ in }
        }
        if arguments.contains("-uiSeedLibrary") { seedLibrary(env: env) }
        // UI tests: a longer ⭐ undo window, so multi-step undo checks do not race the 4 s.
        if let seconds = argument("-uiUndoSeconds").flatMap(Int.init) { env.favorites.undoWindow = .seconds(seconds) }
        router.debugScreen = argument("-uiScreen")
        if router.debugScreen == "paywall" { router.paywallPresented = true }
        // Spike measurements: `-playerEngine remux -remuxBench <url>` plays the URL and logs REMUXBENCH lines.
        if let url = argument("-remuxBench") {
            router.play(.url(url, title: "Remux bench"))
        }
        if router.debugScreen == "player" {
            let channels = (try? env.catalog.channels(sourceId: env.currentSource?.id ?? "", limit: 50)) ?? []
            if let first = channels.first { router.play(.channel(first), channels: channels) }
        }
        #endif
    }

    #if DEBUG
    /// `-uiSeedLibrary`: progress for the first movie/episode + two favorite channels, so the
    /// home rows (continue watching, favorites) can be screenshotted without playing anything.
    static func seedLibrary(env: AppEnvironment) {
        guard let source = env.currentSource else { return }
        let nowMs = env.license.nowMs()
        let movies = (try? env.catalog.movies(sourceId: source.id, limit: 3)) ?? []
        for (i, movie) in movies.prefix(2).enumerated() {
            if let key = env.contentKey(sourceId: source.id, kind: .movie, itemId: movie.id) {
                _ = try? env.library.saveProgress(contentKey: key, title: movie.name, kind: .movie, positionMs: Int64(1_800_000 + i * 900_000),
                                                  durationMs: 5_400_000, posterUrl: movie.posterUrl, nowMs: nowMs - Int64(i) * 1000)
            }
        }
        if let series = (try? env.catalog.series(sourceId: source.id, limit: 1))?.first,
           let episode = (try? env.catalog.episodes(sourceId: source.id, seriesId: series.id))?.first,
           let key = env.contentKey(sourceId: source.id, kind: .episode, itemId: episode.id) {
            _ = try? env.library.saveProgress(contentKey: key, title: episode.title, kind: .episode, positionMs: 600_000,
                                              durationMs: 2_400_000, posterUrl: episode.posterUrl ?? series.posterUrl,
                                              seriesKey: env.contentKey(sourceId: source.id, kind: .series, itemId: series.id), nowMs: nowMs - 5000)
        }
        // Written directly (no ⭐ toggle): screenshots must not show the undo toast.
        for (i, channel) in ((try? env.catalog.channels(sourceId: source.id, limit: 3)) ?? []).prefix(2).enumerated() {
            if let key = env.contentKey(sourceId: source.id, kind: .live, itemId: channel.id) {
                _ = try? env.library.setFavorite(true, contentKey: key, title: channel.name, kind: .live, posterUrl: channel.logoUrl,
                                                 nowMs: nowMs - 10_000 + Int64(i))
            }
        }
        env.favorites.reload()
        env.favorites.onLocalChange()   // views reload their rows (bumps libraryVersion, no sync push)
    }
    #endif
}
