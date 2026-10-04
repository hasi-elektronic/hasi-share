import IPTVKit
import SwiftUI

@main
struct NovaPlayerTVApp: App {
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
            TVRootView()
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

/// Sections of the left navigation menu (SCREENS §2 TV).
enum TVSection: String, CaseIterable, Hashable {
    case search, home, live, movies, series, favorites, settings

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .live: return "tv"
        case .movies: return "film"
        case .series: return "rectangle.stack"
        case .favorites: return "star"
        case .settings: return "gearshape"
        }
    }

    var titleKey: String { "nav_\(rawValue)" }
}

/// Apple TV root: collapsible left menu + section content; predictable Menu-button rules.
struct TVRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var section: TVSection = .home
    @State private var paths: [TVSection: NavigationPath] = [:]
    @FocusState private var menuFocus: TVSection?
    @Namespace private var focusNamespace
    /// The menu becomes focusable only after the content took the initial focus
    /// (SCREENS §2: each screen's default focus is in the content, ★).
    @State private var menuFocusable = false

    private var menuExpanded: Bool { menuFocus != nil }

    var body: some View {
        @Bindable var router = router
        Group {
            if env.sources.isEmpty || router.onboarding {
                WelcomeView()
            } else {
                HStack(spacing: 0) {
                    menu
                        .prefersDefaultFocus(false, in: focusNamespace)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .prefersDefaultFocus(true, in: focusNamespace)
                }
                .focusScope(focusNamespace)
                .screenBackground()
                // Back rules 3 and 4: content → menu; menu (not Home) → Home; Home menu → system (exit).
                .onExitCommand(perform: exitHandler)
                .task {
                    try? await Task.sleep(for: .milliseconds(600))
                    menuFocusable = true
                }
                .onAppear {
                    switch router.debugScreen {
                    case "live", "player": section = .live
                    case "settings": section = .settings
                    case "movies": section = .movies
                    default: break
                    }
                    if router.debugScreen == "menu" { menuFocus = section }
                }
            }
        }
        .fullScreenCover(isPresented: $router.playerPresented, onDismiss: { env.player.close() }) {
            PlayerView().environment(env).environment(router)
        }
        .fullScreenCover(isPresented: $router.paywallPresented) {
            PaywallView().environment(env)
        }
    }

    private var exitHandler: (() -> Void)? {
        if !(paths[section]?.isEmpty ?? true) { return nil }            // NavigationStack pops itself
        if menuFocus == nil { return { menuFocus = section } }           // content → menu
        if section != .home { return { section = .home; menuFocus = .home } }
        return nil                                                       // Home + menu → leave app
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "play.tv.fill").font(.system(size: 44)).foregroundStyle(Theme.premiumGradient)
                .padding(.bottom, 30).padding(.leading, 18)
            ForEach(TVSection.allCases, id: \.self) { item in
                Button { section = item } label: {
                    HStack(spacing: 20) {
                        Image(systemName: item.icon).font(.system(size: 30)).frame(width: 44)
                        if menuExpanded { LText(item.titleKey).font(Theme.body).lineLimit(1) }
                    }
                    .foregroundStyle(section == item ? Theme.primary : Theme.textPrimary)
                    .padding(.vertical, 14).padding(.horizontal, 18)
                    .frame(width: menuExpanded ? 340 : 84, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(menuFocus == item ? Theme.surfaceElevated : .clear))
                }
                .buttonStyle(MenuItemButtonStyle())
                .disabled(!menuFocusable)
                .focused($menuFocus, equals: item)
                .accessibilityIdentifier("menu_\(item.rawValue)")
                .onChange(of: menuFocus) { _, focused in
                    if let focused, focused != section, focused != .search, focused != .settings { section = focused }
                }
            }
            Spacer()
        }
        .padding(.vertical, Theme.safeV)
        .padding(.leading, 40)
        .background(Theme.surface.opacity(menuExpanded ? 0.95 : 0.5).ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: menuExpanded)
        .focusSection()
    }

    private var content: some View {
        let binding = Binding(get: { paths[section] ?? NavigationPath() }, set: { paths[section] = $0 })
        return NavigationStack(path: binding) {
            Group {
                switch section {
                case .search: SearchView()
                case .home: HomeView()
                case .live: LiveTVView()
                case .movies: MoviesView()
                case .series: SeriesView()
                case .favorites: FavoritesView()
                case .settings: SettingsView()
                }
            }
            .catalogDestinations()
        }
        .id(section)
        .focusSection()
    }
}

/// Menu items draw their own focus background (no system platter).
private struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}
