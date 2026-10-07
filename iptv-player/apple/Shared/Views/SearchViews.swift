import IPTVCore
import IPTVKit
import SwiftUI

// MARK: - Search screen (SCREENS §3.6)

/// Global search: recent searches when the field is empty; while typing suggestions (iOS: rows under the
/// field, tvOS: the system row under the keyboard), filter chips, then the sections – categories, channels,
/// movies, series, people, descriptions (with excerpt), TV programmes – each with "Show all"; "Did you mean"
/// + similar results when the query found little.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var model: SearchViewModel?
    @State private var searchPresented = true

    var body: some View {
        Group {
            if let model { screen(model) } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .screenBackground()
        .navigationTitle(L10n.t("nav_search"))
        #if !os(tvOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .onAppear {
            if let model {
                // Back on the screen: recent searches may have changed (a result was opened); with an empty field
                // the search is activated again (after "Cancel" it stayed inactive).
                model.reloadRecent()
                if model.query.isEmpty { searchPresented = true }
                return
            }
            let m = SearchViewModel(env: env)
            m.hiddenLiveCategories = { HiddenStore.shared.hiddenCategories($0) }
            m.hiddenChannels = { HiddenStore.shared.hiddenChannels($0) }
            model = m
        }
        // Recent searches are saved only on "Search" and when a result is opened – not for half-typed queries.
        .onDisappear { model?.dismissSuggestions() }
    }

    @ViewBuilder
    private func screen(_ model: SearchViewModel) -> some View {
        let text = Binding(get: { model.query }, set: { model.query = $0 })
        #if os(tvOS)
        content(model)
            .searchable(text: text, prompt: L10n.t("search_hint"))
            .searchSuggestions {
                ForEach(model.suggestions) { s in
                    Label(s.text, systemImage: s.isPerson ? "person" : "magnifyingglass").searchCompletion(s.text)
                }
            }
            .onSubmit(of: .search) { model.submit() }
        #else
        content(model)
            // `.automatic`: with `.navigationBarDrawer` iOS 26 showed no search field at all after coming back
            // from a pushed result (detail, "Show all") – already in Build 10.
            .searchable(text: text, isPresented: $searchPresented, placement: .automatic,
                        prompt: L10n.t("search_hint"))
            .onSubmit(of: .search) { model.submit() }
        #endif
    }

    @ViewBuilder
    private func content(_ model: SearchViewModel) -> some View {
        if SearchText.tokens(model.query).isEmpty {
            RecentSearchesView(model: model)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.isTV ? 36 : 18) {
                    #if !os(tvOS)
                    if !model.suggestions.isEmpty { SuggestionRows(model: model) }
                    #endif
                    if let correction = model.results.correction { DidYouMeanChip(correction: correction) { model.applyCorrection() } }
                    if model.results.isEmpty, !model.isSearching {
                        LText("search_no_results", model.query).font(Theme.body).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.safeH).padding(.top, 8)
                            .accessibilityIdentifier("search_no_results")
                    }
                    if model.results.filters.count > 2 { FilterChips(model: model) }
                    if model.filter == .all {
                        SearchOverview(model: model)
                    } else if let list = model.list(for: model.filter) {
                        SearchListRows(list: list, onOpen: { model.rememberQuery() })
                    }
                }
                .padding(.vertical, Theme.isTV ? 30 : 12)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #else
            .scrollDismissesKeyboard(.immediately)
            #endif
        }
    }
}

/// Completions under the field while typing (iOS); a tap runs the suggestion.
private struct SuggestionRows: View {
    let model: SearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, s in
                Button { model.apply(s) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.isPerson ? "person" : "magnifyingglass").foregroundStyle(Theme.textSecondary).frame(width: 22)
                        Text(s.text).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search_suggestion_\(index)")
                if index < model.suggestions.count - 1 { Divider().overlay(Theme.stroke) }
            }
        }
        .padding(.horizontal, Theme.safeH)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search_suggestions")
    }
}

/// "Did you mean: <corrected>" – re-runs the search with the correction.
private struct DidYouMeanChip: View {
    let correction: String
    let action: () -> Void

    private var label: AttributedString {
        let full = L10n.t("search_did_you_mean", correction)
        var text = AttributedString(full)
        text.foregroundColor = Theme.textSecondary
        if let range = text.range(of: correction) {
            text[range].foregroundColor = Theme.primary
            text[range].font = (Theme.isTV ? Theme.body : Font.body).weight(.semibold).italic()
        }
        return text
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.isTV ? 14 : 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Theme.primary)
                Text(label).font(Theme.isTV ? Theme.body : .body).lineLimit(2)
            }
            .padding(.horizontal, Theme.isTV ? 28 : 16).padding(.vertical, Theme.isTV ? 16 : 10)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(CardButtonStyle(radius: 40, scale: 1.05))
        .padding(.horizontal, Theme.safeH)
        .accessibilityIdentifier("search_did_you_mean")
    }
}

/// Filter chips: All · Categories · Live · Movies · Series · TV programmes (only those with hits).
private struct FilterChips: View {
    let model: SearchViewModel

    static func title(_ filter: SearchFilter) -> String {
        switch filter {
        case .all: return L10n.t("search_filter_all")
        case .categories: return L10n.t("search_section_categories")
        case .live: return L10n.t("search_filter_live")
        case .movies: return L10n.t("search_kind_movies")
        case .series: return L10n.t("search_kind_series")
        case .programmes: return L10n.t("search_filter_programmes")
        }
    }

    var body: some View {
        ChipBar(items: model.results.filters.map { ($0, Self.title($0)) },
                selection: Binding(get: { model.filter }, set: { model.filter = $0 }),
                identifier: { "search_filter_\($0.rawValue)" })
    }
}

// MARK: - Overview ("All")

private struct SearchOverview: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let model: SearchViewModel

    private func seeAll(_ kind: SearchListKind, _ titleKey: String) -> BrowseRoute {
        .searchList(kind, query: model.results.query, title: L10n.t(titleKey))
    }

    var body: some View {
        let r = model.results
        if !r.similar.isEmpty {
            Shelf(title: L10n.t("search_section_similar"), identifier: "search_similar") {
                ForEach(r.similar) { item in SearchItemCard(item: item, channels: [], identifierPrefix: "search_similar", onOpen: model.rememberQuery) }
            }
        }
        if !r.categories.isEmpty {
            Shelf(title: L10n.t("search_section_categories"), spacing: Theme.isTV ? 30 : 10,
                  seeAll: seeAll(.categories, "search_section_categories"), seeAllTitleKey: "search_show_all", identifier: "search_categories") {
                ForEach(r.categories) { info in SearchCategoryLink(info: info, onOpen: model.rememberQuery) }
            }
        }
        if !r.channels.isEmpty {
            let channels = r.channels.compactMap(\.channel)
            Shelf(title: L10n.t("favorites_channels"), seeAll: seeAll(.scope(.titles(.live)), "favorites_channels"),
                  seeAllTitleKey: "search_show_all", identifier: "search_channels") {
                ForEach(r.channels) { item in SearchItemCard(item: item, channels: channels, identifierPrefix: "search", onOpen: model.rememberQuery) }
            }
        }
        if !r.movies.isEmpty {
            Shelf(title: L10n.t("favorites_movies"), seeAll: seeAll(.scope(.titles(.movie)), "favorites_movies"),
                  seeAllTitleKey: "search_show_all", identifier: "search_movies") {
                ForEach(r.movies) { item in SearchItemCard(item: item, channels: [], identifierPrefix: "search", onOpen: model.rememberQuery) }
            }
        }
        if !r.series.isEmpty {
            Shelf(title: L10n.t("favorites_series"), seeAll: seeAll(.scope(.titles(.series)), "favorites_series"),
                  seeAllTitleKey: "search_show_all", identifier: "search_series") {
                ForEach(r.series) { item in SearchItemCard(item: item, channels: [], identifierPrefix: "search", onOpen: model.rememberQuery) }
            }
        }
        if !r.people.isEmpty {
            // Cast / director matches whose title does not match (SCREENS §3.6).
            Shelf(title: L10n.t("search_section_people"), seeAll: seeAll(.scope(.people), "search_section_people"),
                  seeAllTitleKey: "search_show_all", identifier: "search_people") {
                ForEach(r.people) { item in SearchItemCard(item: item, channels: [], identifierPrefix: "search_person", onOpen: model.rememberQuery) }
            }
        }
        if !r.descriptions.isEmpty {
            Shelf(title: L10n.t("search_section_descriptions"), spacing: Theme.isTV ? 40 : 12,
                  seeAll: seeAll(.scope(.descriptions), "search_section_descriptions"), seeAllTitleKey: "search_show_all",
                  identifier: "search_descriptions") {
                ForEach(r.descriptions) { item in SearchSnippetLink(item: item, onOpen: model.rememberQuery) }
            }
        }
        if !r.programmes.isEmpty {
            Shelf(title: L10n.t("search_section_on_tv"), spacing: Theme.isTV ? 40 : 12,
                  seeAll: seeAll(.programmes, "search_section_on_tv"), seeAllTitleKey: "search_show_all", identifier: "search_on_tv") {
                ForEach(r.programmes) { hit in
                    Button {
                        model.rememberQuery()
                        router.open(hit)
                    } label: { SearchProgrammeCard(hit: hit) }
                    .buttonStyle(CardButtonStyle())
                    .accessibilityIdentifier("search_programme_\(hit.channel.id)")
                }
            }
        }
    }
}

extension SearchItem {
    var channel: Channel? {
        if case .channel(let row) = content { return row.channel }
        return nil
    }

    var catalogItem: CatalogItem? {
        switch content {
        case .movie(let m): return .movie(m)
        case .series(let s): return .series(s)
        case .channel: return nil
        }
    }

    /// Movie/series title without "(2024) HD"; channel name.
    var displayTitle: String { catalogItem?.title ?? channel?.name ?? hit.title }

    var kindLine: String {
        switch content {
        case .channel(let row): return row.nowNext?.now?.title ?? L10n.t("search_kind_channel")
        case .movie(let m): return [L10n.t("search_kind_movie"), m.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case .series(let s): return [L10n.t("search_kind_one_series"), s.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Poster (movie/series) or channel card of a shelf.
private struct SearchItemCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let item: SearchItem
    let channels: [Channel]
    let identifierPrefix: String
    let onOpen: () -> Void

    var body: some View {
        switch item.content {
        case .channel(let row):
            Button {
                onOpen()
                router.play(.channel(row.channel), channels: channels.isEmpty ? [row.channel] : channels)
            } label: {
                ChannelCard(row: row, isFavorite: env.favoriteTarget(row.channel).map { env.favorites.isFavorite($0.contentKey) } ?? false)
            }
            .buttonStyle(ArtworkButtonStyle())
            .contextMenu { ChannelMenuItems(channel: row.channel) }
            .accessibilityIdentifier("\(identifierPrefix)_channel_\(row.channel.id)")
        case .movie(let m):
            FavoritePosterButton(target: env.favoriteTarget(m), identifier: identifier("movie", m.id)) {
                onOpen()
                router.open(.movie(m))
            } label: {
                PosterCard(title: MediaTags.clean(m.name).title, url: m.posterUrl, subtitle: subtitle(m.year))
            }
        case .series(let s):
            FavoritePosterButton(target: env.favoriteTarget(s), identifier: identifier("series", s.id)) {
                onOpen()
                router.open(.series(s))
            } label: {
                PosterCard(title: MediaTags.clean(s.name).title, url: s.posterUrl, subtitle: subtitle(s.year))
            }
        }
    }

    /// Person hits keep their Build 10 ids (`search_person_m|<id>`).
    private func identifier(_ kind: String, _ id: String) -> String {
        if identifierPrefix == "search_person" { return "search_person_\(kind == "movie" ? "m" : "s")|\(id)" }
        return "\(identifierPrefix)_\(kind)_\(id)"
    }

    private func subtitle(_ year: Int?) -> String? {
        item.hit.matchedPerson ?? year.map(String.init)
    }
}

/// The excerpt of a description hit, matched words bold in the accent colour.
struct SnippetText: View {
    let snippet: SearchSnippet

    var body: some View {
        var text = AttributedString()
        for part in snippet.parts {
            var run = AttributedString(part.text)
            run.foregroundColor = part.isMatch ? Theme.textPrimary : Theme.textSecondary
            if part.isMatch { run.font = (Theme.isTV ? Font.system(size: 22) : Font.footnote).weight(.bold) }
            text += run
        }
        return Text(text)
    }
}

/// Wide card of a description hit: poster, title, kind line, 2-line excerpt.
private struct SearchSnippetCard: View {
    let item: SearchItem

    private var posterURL: String? {
        switch item.content {
        case .movie(let m): return m.posterUrl
        case .series(let s): return s.posterUrl
        case .channel(let row): return row.channel.logoUrl
        }
    }

    var body: some View {
        let width: CGFloat = Theme.isTV ? 640 : 300
        let poster: CGFloat = Theme.isTV ? 96 : 56
        HStack(alignment: .top, spacing: Theme.isTV ? 20 : 10) {
            Color.clear
                .frame(width: poster, height: poster * 1.5)
                .overlay(RemoteImage(url: posterURL, maxPixel: 300, placeholder: "film"))
                .clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 10 : 6, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.isTV ? 6 : 3) {
                Text(item.displayTitle).font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(item.kindLine).font(Theme.isTV ? .system(size: 20) : .caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let snippet = item.hit.snippet {
                    SnippetText(snippet: snippet).font(Theme.isTV ? .system(size: 22) : .footnote).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.isTV ? 18 : 10)
        .frame(width: width, height: poster * 1.5 + (Theme.isTV ? 36 : 20), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct SearchSnippetLink: View {
    @Environment(Router.self) private var router
    let item: SearchItem
    let onOpen: () -> Void

    var body: some View {
        if let catalogItem = item.catalogItem {
            Button {
                onOpen()
                router.open(catalogItem)
            } label: { SearchSnippetCard(item: item) }
                .buttonStyle(CardButtonStyle(scale: 1.05))
                .accessibilityIdentifier("search_description_\(item.hit.kind.rawValue)_\(item.hit.itemId)")
        }
    }
}

/// Category result: flag/badge + name, kind · item count. Movies/series open the category grid, live
/// categories open Live TV filtered to them.
private struct SearchCategoryLink: View {
    @Environment(Router.self) private var router
    let info: CategoryInfo
    var fullWidth = false
    var onOpen: () -> Void = {}

    var body: some View {
        Button {
            onOpen()
            if info.category.kind == .live {
                router.showLiveCategory(info.id)
            } else {
                router.open(BrowseRoute.grid(kind: info.category.kind.contentKind, categoryId: info.id,
                                             title: CountryFlag.displayTitle(info.category.name), sort: .added))
            }
        } label: { SearchCategoryCard(info: info, fullWidth: fullWidth) }
        .buttonStyle(CardButtonStyle(radius: Theme.cardRadius, scale: 1.05))
        .accessibilityIdentifier("search_category_\(info.category.kind.rawValue)_\(info.id)")
    }
}

/// A poster result: a button (the query is remembered before the detail opens) with the iOS corner ⭐ and the
/// long-press favorite menu, like `FavoritePosterLink`.
private struct FavoritePosterButton<Label: View>: View {
    let target: FavoriteTarget?
    let identifier: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(ArtworkButtonStyle())
            .contextMenu { if let target { FavoriteMenuItem(target: target) } }
            .accessibilityIdentifier(identifier)
            #if os(iOS)
            .overlay(alignment: .topTrailing) {
                if let target {
                    FavoriteButton(target: target).buttonStyle(FavoriteBadgeButtonStyle())
                }
            }
            #endif
    }
}

extension Router {
    /// Pushes a search result onto the current stack (iOS path, tvOS current tab).
    func open(_ item: CatalogItem) {
        #if os(tvOS)
        tvPushRequest = item
        #else
        path.append(item)
        #endif
    }

    func open(_ route: BrowseRoute) {
        #if os(tvOS)
        tvRoutePushRequest = route
        #else
        path.append(route)
        #endif
    }
}

/// Search result card of a category (SCREENS §3.6).
private struct SearchCategoryCard: View {
    let info: CategoryInfo
    var fullWidth = false

    private var kindLine: String {
        let kind: String
        switch info.category.kind {
        case .movie: kind = L10n.t("search_kind_movies")
        case .series: kind = L10n.t("search_kind_series")
        case .live: kind = L10n.t("search_kind_live")
        }
        let count = info.category.kind == .live ? L10n.t("search_category_channels", String(info.itemCount))
            : L10n.t("catnav_items", String(info.itemCount))
        return "\(kind) · \(count)"
    }

    var body: some View {
        HStack(spacing: Theme.isTV ? 16 : 10) {
            CategoryLeadingMark(code: info.countryCode)
            VStack(alignment: .leading, spacing: Theme.isTV ? 4 : 2) {
                Text(categoryTitle(info)).font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(kindLine).font(Theme.isTV ? .system(size: 22) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.isTV ? 24 : 14).padding(.vertical, Theme.isTV ? 18 : 10)
        .frame(width: fullWidth ? nil : (Theme.isTV ? 420 : 230), alignment: .leading)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(categoryAccessibilityLabel(info)), \(kindLine)")
    }
}

// MARK: - TV programmes

extension ProgrammeHit {
    /// "Bugün 20:45", "Yarın 18:00", "Dün 21:00", else "Sat 4 Oct 18:00" (EPG time zone / 24 h settings).
    @MainActor
    func timeText(_ env: AppEnvironment) -> String {
        let formatter = env.timeFormatter
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let time = formatter.time(program.start)
        if calendar.isDateInToday(program.start) { return L10n.t("search_time_today", time) }
        if calendar.isDateInTomorrow(program.start) { return L10n.t("search_time_tomorrow", time) }
        if calendar.isDateInYesterday(program.start) { return L10n.t("search_time_yesterday", time) }
        return "\(formatter.day(program.start)) \(time)"
    }
}

private struct ProgrammeBadge: View {
    let hit: ProgrammeHit

    var body: some View {
        switch hit.state {
        case .live:
            LText("epg_now").font((Theme.isTV ? Font.system(size: 20) : .caption2).weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.live))
        case .archive:
            Image(systemName: "clock.arrow.circlepath").font(Theme.isTV ? .system(size: 22, weight: .semibold) : .caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .accessibilityLabel(L10n.t("catchup_replay"))
        case .upcoming:
            EmptyView()
        }
    }
}

/// Shelf card of a programme: channel logo + name, title, "Now" + progress or day/time.
private struct SearchProgrammeCard: View {
    @Environment(AppEnvironment.self) private var env
    let hit: ProgrammeHit

    var body: some View {
        let width: CGFloat = Theme.isTV ? 520 : 270
        VStack(alignment: .leading, spacing: Theme.isTV ? 10 : 6) {
            HStack(spacing: Theme.isTV ? 14 : 8) {
                ChannelLogo(url: hit.channel.logoUrl, width: Theme.isTV ? 96 : 52)
                Text(hit.channel.name).font(Theme.isTV ? .system(size: 22) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                ProgrammeBadge(hit: hit)
            }
            Text(hit.program.title).font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary).lineLimit(2, reservesSpace: true)
            if hit.state == .live {
                ProgressBar(value: EpgSchedule.progress(of: hit.program, at: Date())).frame(height: Theme.isTV ? 5 : 3)
            } else {
                Text(hit.timeText(env)).font((Theme.isTV ? Font.system(size: 22) : .caption).monospacedDigit())
                    .foregroundStyle(hit.state == .archive ? Theme.primary : Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(Theme.isTV ? 20 : 12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([hit.program.title, hit.channel.name, hit.state == .live ? L10n.t("epg_now") : hit.timeText(env)].joined(separator: ", "))
    }
}

extension Router {
    /// A programme result: running / upcoming → the channel; ended with catch-up → its archive.
    func open(_ hit: ProgrammeHit) {
        if hit.state == .archive, let url = env.catchupURL(channel: hit.channel, program: hit.program) {
            play(.url(url, title: "\(hit.channel.name) · \(hit.program.title)"))
        } else {
            play(.channel(hit.channel), channels: [hit.channel])
        }
    }
}

extension AppEnvironment {
    /// Xtream timeshift URL of a past programme (CONTRACT §4); `nil` for M3U sources.
    func catchupURL(channel: Channel, program: EpgProgram) -> String? {
        guard case .xtream(let secrets)? = secrets(for: channel.sourceId), let builder = XtreamURLBuilder(secrets: secrets) else { return nil }
        let account = sources.first { $0.id == channel.sourceId }?.xtreamAccount
        let ext = (account?.allowedOutputFormats.contains("m3u8") ?? true) ? "m3u8" : "ts"
        return builder.timeshiftURL(streamId: channel.id, start: program.start, end: program.end,
                                    serverTimezone: account?.serverTimezone, ext: ext).absoluteString
    }
}

// MARK: - Full lists ("Show all", filter chips)

/// Rows of a full result list, paged (60 per page) as they scroll in.
struct SearchListRows: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    let list: SearchListModel
    var onOpen: () -> Void = {}

    var body: some View {
        Group {
            switch list.kind {
            case .categories:
                ForEach(list.categories) { info in
                    SearchCategoryLink(info: info, fullWidth: true, onOpen: onOpen).padding(.horizontal, Theme.safeH)
                }
            case .programmes:
                ForEach(list.programmes) { hit in
                    Button {
                        onOpen()
                        router.open(hit)
                    } label: { SearchProgrammeRow(hit: hit) }
                    .buttonStyle(CardButtonStyle(scale: 1.02))
                    .padding(.horizontal, Theme.safeH)
                    .accessibilityIdentifier("search_list_programme_\(hit.channel.id)_\(Int(hit.program.start.timeIntervalSince1970))")
                    .onAppear { list.loadMoreIfNeeded(hit.id) }
                }
            case .scope:
                let channels = list.items.compactMap(\.channel)
                ForEach(list.items) { item in
                    row(item, channels: channels)
                        .padding(.horizontal, Theme.safeH)
                        .onAppear { list.loadMoreIfNeeded(item.id) }
                }
            }
            if !list.reachedEnd {
                // Always present (an empty Group never appears): first page, and the next one at the bottom.
                ProgressView().frame(maxWidth: .infinity).padding()
                    .opacity(list.isLoading ? 1 : 0)
                    .onAppear { list.loadMore() }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SearchItem, channels: [Channel]) -> some View {
        let id = "search_list_\(item.hit.kind.rawValue)_\(item.hit.itemId)"
        if let channel = item.channel {
            Button {
                onOpen()
                router.play(.channel(channel), channels: channels)
            } label: { SearchResultRow(item: item) }
            .buttonStyle(CardButtonStyle(scale: 1.02))
            .contextMenu { ChannelMenuItems(channel: channel) }
            .accessibilityIdentifier(id)
        } else if let catalogItem = item.catalogItem {
            Button {
                onOpen()
                router.open(catalogItem)
            } label: { SearchResultRow(item: item) }
                .buttonStyle(CardButtonStyle(scale: 1.02))
                .contextMenu { if let target = env.favoriteTarget(catalogItem) { FavoriteMenuItem(target: target) } }
                .accessibilityIdentifier(id)
        }
    }
}

/// List row of a channel / movie / series result: artwork, title, kind line, matched person or excerpt.
private struct SearchResultRow: View {
    let item: SearchItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.isTV ? 24 : 12) {
            artwork
            VStack(alignment: .leading, spacing: Theme.isTV ? 6 : 3) {
                Text(item.displayTitle).font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(item.kindLine).font(Theme.isTV ? .system(size: 21) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let person = item.hit.matchedPerson {
                    Label(person, systemImage: "person").font(Theme.isTV ? .system(size: 21) : .caption)
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                } else if let snippet = item.hit.snippet {
                    SnippetText(snippet: snippet).font(Theme.isTV ? .system(size: 21) : .caption).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.isTV ? 14 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface.opacity(Theme.isTV ? 1 : 0.6)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var artwork: some View {
        switch item.content {
        case .channel(let row):
            ChannelTile(channel: row.channel, width: Theme.isTV ? 160 : 86, height: Theme.isTV ? 90 : 48, radius: Theme.isTV ? 10 : 6)
        case .movie(let m):
            poster(m.posterUrl)
        case .series(let s):
            poster(s.posterUrl)
        }
    }

    private func poster(_ url: String?) -> some View {
        let w: CGFloat = Theme.isTV ? 80 : 44
        return Color.clear.frame(width: w, height: w * 1.5)
            .overlay(RemoteImage(url: url, maxPixel: 240, placeholder: "film"))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// List row of a programme result.
private struct SearchProgrammeRow: View {
    @Environment(AppEnvironment.self) private var env
    let hit: ProgrammeHit

    var body: some View {
        HStack(spacing: Theme.isTV ? 24 : 12) {
            ChannelLogo(url: hit.channel.logoUrl, width: Theme.isTV ? 140 : 72)
            VStack(alignment: .leading, spacing: Theme.isTV ? 6 : 3) {
                HStack(spacing: 8) {
                    Text(hit.program.title).font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    ProgrammeBadge(hit: hit)
                }
                Text("\(hit.channel.name) · \(hit.state == .live ? env.timeFormatter.range(start: hit.program.start, end: hit.program.end) : hit.timeText(env))")
                    .font(Theme.isTV ? .system(size: 21) : .caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if hit.state == .live {
                    ProgressBar(value: EpgSchedule.progress(of: hit.program, at: Date())).frame(width: Theme.isTV ? 300 : 140, height: 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.isTV ? 14 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface.opacity(Theme.isTV ? 1 : 0.6)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Pushed "Show all" page of one section.
struct SearchListView: View {
    @Environment(AppEnvironment.self) private var env
    let kind: SearchListKind
    let query: String
    let title: String
    @State private var list: SearchListModel?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.isTV ? 24 : 10) {
                if let list {
                    SearchListRows(list: list, onOpen: { if let id = env.currentSource?.id { env.recentSearches.add(query, sourceId: id) } })
                    if list.reachedEnd, list.isEmpty {
                        LText("search_no_results", query).font(Theme.body).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.safeH)
                    }
                }
            }
            .padding(.vertical, Theme.isTV ? 30 : 12)
        }
        #if os(tvOS)
        .scrollClipDisabled()
        #endif
        .screenBackground()
        .navigationTitle("\(title) · \(query)")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard list == nil, let sourceId = env.currentSource?.id else { return }
            list = SearchListModel(env: env, kind: kind, query: query,
                                   hiddenChannels: HiddenStore.shared.hiddenChannels(sourceId),
                                   hiddenLiveCategories: HiddenStore.shared.hiddenCategories(sourceId))
        }
        .accessibilityIdentifier("search_list")
    }
}

// MARK: - Recent searches

/// Empty field: the last searches of the source (tap = search again; swipe / long press = delete; Clear).
private struct RecentSearchesView: View {
    let model: SearchViewModel

    var body: some View {
        if model.recent.isEmpty {
            VStack(spacing: Theme.isTV ? 20 : 12) {
                Image(systemName: "magnifyingglass").font(.system(size: Theme.isTV ? 60 : 40)).foregroundStyle(Theme.textSecondary)
                LText("search_recent_empty").font(Theme.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(Theme.isTV ? 60 : 32)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.isTV ? 40 : 60)
        } else {
            List {
                Section {
                    ForEach(Array(model.recent.enumerated()), id: \.element) { index, query in
                        Button { model.applyRecent(query) } label: {
                            Label(query, systemImage: "clock.arrow.circlepath").font(Theme.body).foregroundStyle(Theme.textPrimary)
                        }
                        #if !os(tvOS)
                        .swipeActions {
                            Button(role: .destructive) { model.removeRecent(query) } label: {
                                Label(L10n.t("action_delete"), systemImage: "trash")
                            }
                        }
                        #endif
                        .contextMenu {
                            Button(role: .destructive) { model.removeRecent(query) } label: {
                                Label(L10n.t("action_delete"), systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("search_recent_\(index)")
                        .listRowBackground(Theme.surface)
                    }
                    #if os(tvOS)
                    Button(role: .destructive) { model.clearRecent() } label: {
                        Label(L10n.t("search_recent_clear"), systemImage: "trash").font(Theme.body)
                    }
                    .accessibilityIdentifier("search_recent_clear")
                    #endif
                } header: {
                    HStack {
                        LText("search_recent").font((Theme.isTV ? Theme.caption : .subheadline).weight(.bold)).foregroundStyle(Theme.textPrimary)
                            .textCase(nil)
                        Spacer()
                        #if !os(tvOS)
                        Button(L10n.t("search_recent_clear")) { model.clearRecent() }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.primary).textCase(nil)
                            .accessibilityIdentifier("search_recent_clear")
                        #endif
                    }
                }
            }
            .hiddenListBackground()
            .accessibilityIdentifier("search_recent")
        }
    }
}
