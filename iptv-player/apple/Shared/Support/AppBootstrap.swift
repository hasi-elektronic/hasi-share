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
}

/// App-wide navigation state shared by iOS and tvOS (section, player / paywall / settings presentation).
@MainActor
@Observable
final class Router {
    var playerPresented = false
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
    /// Keeps the onboarding flow (welcome → add source → summary) on screen until "Continue".
    var onboarding = false
    /// Screen opened by a debug launch argument (`-uiScreen paywall`…), UI tests & screenshots.
    var debugScreen: String?

    let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Opens the player – or the paywall when playback is locked (CONTRACT §7.4).
    func play(_ item: PlaybackRequest.Item, channels: [Channel] = [], fromStart: Bool = false) {
        env.license.evaluate()
        guard env.license.canPlay else {
            paywallPresented = true
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

    static func argument(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func makeEnvironment() -> AppEnvironment {
        let isUITest = arguments.contains("-uiTestReset")
        let suite = isUITest ? UserDefaults(suiteName: "uitest") ?? .standard : .standard
        if isUITest { suite.removePersistentDomain(forName: "uitest") }
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
                               licenseKeysJSON: licenseKeys(), platform: platform, rawDeviceId: deviceId, deviceName: deviceName)
        let database: AppDatabase
        do {
            database = isUITest ? try AppDatabase.inMemory() : try AppDatabase.onDisk()
        } catch {
            SafeLog.error("database open failed: \(error)")
            database = try! AppDatabase.inMemory()
        }
        let secure: any SecureStore = isUITest ? InMemorySecureStore() : KeychainStore(service: (Bundle.main.bundleIdentifier ?? "app") + ".secrets")
        let kv = UserDefaultsStore(suite)
        do {
            return try AppEnvironment(config: config, database: database, secureStore: secure, kv: kv,
                                      settings: AppSettings(defaults: suite), engines: .app)
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
    static func applyTesterAccess(env: AppEnvironment) async {
        guard info("TESTFLIGHT_FULL_ACCESS").uppercased() == "YES" else { return }
        // Cheap synchronous signal first (TestFlight installs carry a sandbox receipt), so the
        // UI never flashes the trial state; then confirm via AppTransaction. Verification can
        // fail on tvOS/TestFlight – the environment of an unverified payload is still the right
        // signal for this non-security-critical unlock.
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            env.license.testerFullAccess = true
        }
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

    /// Debug/UI-test hooks: `-seedM3U <url>` adds a source, `-uiScreen <name>` opens a screen,
    /// `-uiTrial` simulates an active StoreKit trial (only in DEBUG builds).
    static func applyDebugHooks(env: AppEnvironment, router: Router) async {
        await applyTesterAccess(env: env)
        #if DEBUG
        if arguments.contains("-uiTrial") {
            env.license.update(store: StoreSnapshot(trialStartMs: env.license.nowMs() - 2 * 86_400_000, trialTransactionId: nil))
        }
        if let m3u = argument("-seedM3U"), env.sources.isEmpty {
            _ = try? await env.addSource(name: argument("-seedName") ?? "Demo", secrets: .m3u(M3USecrets(url: m3u))) { _ in }
        }
        if arguments.contains("-uiSeedLibrary") { seedLibrary(env: env) }
        router.debugScreen = argument("-uiScreen")
        if router.debugScreen == "paywall" { router.paywallPresented = true }
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
        for channel in ((try? env.catalog.channels(sourceId: source.id, limit: 3)) ?? []).prefix(2)
        where !env.isFavorite(sourceId: source.id, kind: .live, itemId: channel.id) {
            env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: channel.logoUrl)
        }
    }
    #endif
}
