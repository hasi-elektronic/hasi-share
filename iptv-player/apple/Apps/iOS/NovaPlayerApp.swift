import IPTVKit
import SwiftUI

@main
struct NovaPlayerApp: App {
    @State private var env: AppEnvironment
    @State private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let env = AppBootstrap.makeEnvironment()
        _env = State(initialValue: env)
        _router = State(initialValue: Router(env: env))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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

enum MobileTab: Hashable {
    case home, live, movies, series, favorites
}

/// iPhone/iPad root: welcome when there is no source, otherwise 5 tabs (SCREENS §2).
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var tab: MobileTab = .home

    var body: some View {
        @Bindable var router = router
        Group {
            if env.sources.isEmpty || router.onboarding {
                WelcomeView()
            } else {
                TabView(selection: $tab) {
                    tabStack { HomeView().navigationTitle(L10n.t("nav_home")) }
                        .tabItem { Label(L10n.t("nav_home"), systemImage: "house") }.tag(MobileTab.home)
                    tabStack { LiveTVView() }
                        .tabItem { Label(L10n.t("nav_live"), systemImage: "tv") }.tag(MobileTab.live)
                    tabStack { MoviesView() }
                        .tabItem { Label(L10n.t("nav_movies"), systemImage: "film") }.tag(MobileTab.movies)
                    tabStack { SeriesView() }
                        .tabItem { Label(L10n.t("nav_series"), systemImage: "rectangle.stack") }.tag(MobileTab.series)
                    tabStack { FavoritesView() }
                        .tabItem { Label(L10n.t("nav_favorites"), systemImage: "star") }.tag(MobileTab.favorites)
                }
                .onAppear {
                    switch router.debugScreen {
                    case "live", "player": tab = .live
                    case "movies": tab = .movies
                    case "series": tab = .series
                    case "favorites": tab = .favorites
                    default: break
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $router.playerPresented, onDismiss: { env.player.close() }) {
            PlayerView().environment(env).environment(router)
        }
        .sheet(isPresented: $router.paywallPresented) {
            PaywallView().environment(env)
        }
    }

    private func tabStack<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        TabStack(content: content)
    }
}

/// One tab's navigation stack with the search / settings toolbar.
private struct TabStack<Content: View>: View {
    @Environment(Router.self) private var router
    let content: () -> Content
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .catalogDestinations()
                .navigationDestination(for: String.self) { route in
                    if route == "search" { SearchView() } else { SettingsView() }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { path.append("search") } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel(L10n.t("action_search"))
                        Button { path.append("settings") } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel(L10n.t("action_settings"))
                            .accessibilityIdentifier("open_settings")
                    }
                }
        }
        .onAppear {
            if router.debugScreen == "settings", path.isEmpty { path.append("settings") }
        }
    }
}
