import IPTVKit
import SwiftUI

@main
struct NovaPlayerApp: App {
    @State private var env: AppEnvironment
    @State private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PerfTrace.shared.mark(.appLaunch)
        let env = AppBootstrap.makeEnvironment()
        let router = Router(env: env)
        _env = State(initialValue: env)
        _router = State(initialValue: router)
        // Build 17: Picture in Picture (bound to the app's AVPlayerLayer) and the AirPlay route state.
        PictureInPictureCoordinator.shared.install(env: env, router: router)
        AirPlayRouteMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
                .onOpenURL { router.open($0) }   // Build 17: novaplayer:// deep links
                .onChange(of: env.catalogVersion) { router.retryPendingDeepLink() }
        }
        .onChange(of: scenePhase) { _, phase in
            env.scenePhaseChanged(AppScenePhase(phase))   // B4: .inactive keeps the player
        }
    }
}

/// iPhone/iPad root (SCREENS §2): welcome when there is no source; otherwise one navigation stack
/// whose root is the current section under the header (app mark · text tabs · search · settings).
/// No tab bar; Settings opens as a sheet; search, details and "See all" grids are pushed.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            if env.sources.isEmpty || router.onboarding {
                WelcomeView()
            } else if router.browseDeferred {
                Color.black.ignoresSafeArea()   // IOS-06: early QuickStart – browse is built when the player closes
            } else {
                NavigationStack(path: $router.path) {
                    // The header is a top safe-area inset: screens without hero start right below
                    // it whatever its height (Dynamic Type, one/two rows); hero screens ignore the
                    // top safe area and run under the transparent header. The inset is layered
                    // above the content, so it always receives the taps in its area.
                    sectionContent
                        .safeAreaInset(edge: .top, spacing: 0) {
                            MobileTopBar(solid: router.headerSolid || !hasHero)
                        }
                        .toolbar(.hidden, for: .navigationBar)
                        // Edge swipe goes back although the bar is hidden (SCREENS §2).
                        .background(InteractivePopEnabler().frame(width: 0, height: 0))
                        .catalogDestinations()
                }
                .onAppear(perform: applyDebugScreen)
                .onChange(of: router.debugScreen) { applyDebugScreen() }   // UI tests: the browse UI may come first
                .onChange(of: router.section) { router.headerSolid = false }
            }
        }
        // ⭐ undo (4 s) over every screen; the player shows its own above the video.
        .overlay(alignment: .bottom) {
            if !router.playerPresented { UndoToast().padding(.bottom, 8) }
        }
        .overlay(alignment: .bottom) {
            if !router.playerPresented && !router.onboarding { CatalogRestoreNotice().padding(.bottom, 64) }
        }
        // Build 17: dismissed for Picture in Picture → playback goes on (the PiP window owns it).
        .fullScreenCover(isPresented: $router.playerPresented, onDismiss: { if !router.pipMinimized { env.player.close() } }) {
            PlayerView().environment(env).environment(router)
        }
        .sheet(isPresented: $router.paywallPresented) {
            PaywallView().environment(env)
        }
        .sheet(isPresented: $router.settingsPresented) {
            SettingsSheet().environment(env).environment(router)
        }
    }

    private var hasHero: Bool { [.home, .movies, .series].contains(router.section) }

    @ViewBuilder
    private var sectionContent: some View {
        switch router.section {
        case .movies: MoviesView()
        case .series: SeriesView()
        case .live: LiveTVView()
        case .guide: GuideView()
        default: HomeView()
        }
    }

    private func applyDebugScreen() {
        switch router.debugScreen {
        case "live", "player": router.section = .live
        case "guide": router.section = .guide
        case "movies": router.section = .movies
        case "series": router.section = .series
        case "favorites": router.path.append(BrowseRoute.favorites)
        case "settings": router.settingsPresented = true
        case "search": router.path.append(BrowseRoute.search)
        case "movieDetail":
            if let id = env.currentSource?.id, let movie = (try? env.catalog.movies(sourceId: id, limit: 1))?.first { router.path.append(CatalogItem.movie(movie)) }
        case "seriesDetail":
            if let id = env.currentSource?.id, let series = (try? env.catalog.series(sourceId: id, limit: 1))?.first { router.path.append(CatalogItem.series(series)) }
        default: break
        }
    }
}

/// Settings presented as a sheet from the gear button (own navigation stack, Done button).
private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("action_close")) { dismiss() }
                            .accessibilityIdentifier("settings_close")
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}
