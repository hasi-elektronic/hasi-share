import Foundation
import IPTVCore
import IPTVKit
import Observation
import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App-wide navigation state shared by iOS and tvOS (player / paywall presentation).
@MainActor
@Observable
final class Router {
    var playerPresented = false
    var paywallPresented = false
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

    static func argument(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func makeEnvironment() -> AppEnvironment {
        let isUITest = arguments.contains("-uiTestReset")
        let suite = isUITest ? UserDefaults(suiteName: "uitest") ?? .standard : .standard
        if isUITest { suite.removePersistentDomain(forName: "uitest") }

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
                                      settings: AppSettings(defaults: suite))
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
        guard case .verified(let transaction) = try? await AppTransaction.shared else { return }
        if transaction.environment == .sandbox {
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
        router.debugScreen = argument("-uiScreen")
        if router.debugScreen == "paywall" { router.paywallPresented = true }
        if router.debugScreen == "player" {
            let channels = (try? env.catalog.channels(sourceId: env.currentSource?.id ?? "", limit: 50)) ?? []
            if let first = channels.first { router.play(.channel(first), channels: channels) }
        }
        #endif
    }
}
