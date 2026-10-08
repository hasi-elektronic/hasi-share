import IPTVKit
import SwiftUI
import UIKit

@main
struct NovaPlayerTVApp: App {
    @State private var env: AppEnvironment
    @State private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerfTrace.shared.mark(.appLaunch)
        let env = AppBootstrap.makeEnvironment()
        _env = State(initialValue: env)
        _router = State(initialValue: Router(env: env))
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .id(env.settings.appLanguage) // Settings → App language: rebuild in the new language
                .environment(\.locale, L10n.locale)
                .environment(env)
                .environment(router)
                .preferredColorScheme(.dark)
                .tint(Theme.primary)
                .task {
                    // Tester access: sandbox receipt synchronously; otherwise AppTransaction confirms in the background.
                    let testerAccess = AppBootstrap.applyTesterAccess(env: env)
                    await AppBootstrap.applyDebugHooks(env: env, router: router)
                    // After tester access + first StoreKit snapshot (≤ 1.5 s in all), before env.start().
                    await AppBootstrap.quickStart(env: env, router: router, testerAccess: testerAccess)
                    await env.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            env.scenePhaseChanged(AppScenePhase(phase))   // B4: .inactive keeps the player
        }
    }
}

/// Apple TV root (SCREENS §2 TV): native top tab bar (like Apple's TV app)
/// Search · Home · Movies · Series · Live TV · TV Guide · Settings.
///
/// Back (Menu) rules: in content the system moves focus up to the tab bar; on the tab bar a
/// section other than Home switches to Home; on Home's tab the press goes to the system (exit).
/// Pushed screens (details, settings pages) pop themselves first.
struct TVRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var paths: [AppSection: NavigationPath] = [:]
    @State private var focusInTabBar = false

    var body: some View {
        @Bindable var router = router
        Group {
            if env.sources.isEmpty || router.onboarding {
                WelcomeView()
            } else if router.browseDeferred {
                Color.black.ignoresSafeArea()   // IOS-06: early QuickStart – browse is built when the player closes
            } else {
                TabView(selection: $router.section) {
                    ForEach(AppSection.allCases, id: \.self) { section in
                        stack(for: section)
                            .tabItem {
                                if section == .search || section == .settings {
                                    Image(systemName: section.icon).accessibilityLabel(L10n.t(section.titleKey))
                                } else {
                                    Text(L10n.t(section.titleKey))
                                }
                            }
                            .tag(section)
                            .accessibilityIdentifier("tab_\(section.rawValue)")
                    }
                }
                .onExitCommand(perform: exitHandler)
                .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { note in
                    guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
                    focusInTabBar = Self.isInTabBar(context.nextFocusedItem)
                }
                .onAppear(perform: applyDebugScreen)
                .onChange(of: router.tvPushRequest) { _, item in
                    guard let item else { return }
                    paths[router.section, default: NavigationPath()].append(item)
                    router.tvPushRequest = nil
                }
                .onChange(of: router.tvRoutePushRequest) { _, route in
                    guard let route else { return }
                    paths[router.section, default: NavigationPath()].append(route)
                    router.tvRoutePushRequest = nil
                }
            }
        }
        // ⭐ undo (4 s) over every screen; the player shows its own above the video.
        .overlay(alignment: .bottom) {
            if !router.playerPresented { UndoToast().padding(.bottom, Theme.safeV) }
        }
        .overlay(alignment: .bottom) {
            if !router.playerPresented && !router.onboarding { CatalogRestoreNotice().padding(.bottom, 120) }
        }
        .fullScreenCover(isPresented: $router.playerPresented, onDismiss: { env.player.close() }) {
            PlayerView().environment(env).environment(router)
        }
        .fullScreenCover(isPresented: $router.paywallPresented) {
            PaywallView().environment(env)
        }
    }

    /// `nil` lets the system act: content → tab bar, pushed page → pop, Home tab at its root → leave the app.
    /// With the focus on the tab bar over a pushed page (detail, settings page…) the system would leave the
    /// app (B-01): pop that page ourselves – never exit while the tab's stack is not at its root.
    private var exitHandler: (() -> Void)? {
        guard focusInTabBar else { return nil }
        let section = router.section
        if let path = paths[section], !path.isEmpty {
            return { paths[section]?.removeLast() }
        }
        guard section != .home else { return nil }
        return { router.section = .home }
    }

    private func stack(for section: AppSection) -> some View {
        let binding = Binding(get: { paths[section] ?? NavigationPath() }, set: { paths[section] = $0 })
        return NavigationStack(path: binding) {
            Group {
                switch section {
                case .search: SearchView()
                case .home: HomeView()
                case .live: LiveTVView()
                case .guide: GuideView()
                case .movies: MoviesView()
                case .series: SeriesView()
                case .settings: SettingsView()
                }
            }
            .catalogDestinations()
        }
    }

    private func applyDebugScreen() {
        switch router.debugScreen {
        case "live", "player": router.section = .live
        case "settings": router.section = .settings
        case "movies": router.section = .movies
        case "series": router.section = .series
        case "guide": router.section = .guide
        case "favorites": paths[.home] = { var p = NavigationPath(); p.append(BrowseRoute.favorites); return p }()
        case "search": router.section = .search
        case "movieDetail":
            if let id = env.currentSource?.id, let movie = (try? env.catalog.movies(sourceId: id, limit: 1))?.first {
                var path = NavigationPath()
                path.append(CatalogItem.movie(movie))
                paths[.home] = path
            }
        case "seriesDetail":
            if let id = env.currentSource?.id, let series = (try? env.catalog.series(sourceId: id, limit: 1))?.first {
                var path = NavigationPath()
                path.append(CatalogItem.series(series))
                paths[.home] = path
            }
        default: break
        }
    }

    /// True when the focused item lives inside the system tab bar.
    private static func isInTabBar(_ item: UIFocusItem?) -> Bool {
        var view = item as? UIView
        while let v = view {
            if v is UITabBar { return true }
            view = v.superview
        }
        return false
    }
}
