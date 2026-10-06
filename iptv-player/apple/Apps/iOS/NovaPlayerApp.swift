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
        _env = State(initialValue: env)
        _router = State(initialValue: Router(env: env))
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
                    await AppBootstrap.applyDebugHooks(env: env, router: router)
                    await env.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            env.scenePhaseChanged(isActive: phase == .active)
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
            } else {
                NavigationStack(path: $router.path) {
                    ZStack(alignment: .top) {
                        // Hero sections run under the (transparent) header; the others start below it.
                        sectionContent
                            .safeAreaPadding(.top, hasHero ? 0 : 50)
                        MobileTopBar(solid: router.headerSolid || !hasHero)
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .catalogDestinations()
                }
                .onAppear(perform: applyDebugScreen)
                .onChange(of: router.section) { router.headerSolid = false }
            }
        }
        .fullScreenCover(isPresented: $router.playerPresented, onDismiss: { env.player.close() }) {
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
