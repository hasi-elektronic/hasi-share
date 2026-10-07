import IPTVCore
import IPTVKit
import SwiftUI

// Movies/Series category navigation (SCREENS §3.2, Build 9). Providers list hundreds of categories
// ("TR • NETFLIX DIZILER", "DE | …", "EN | …"); a horizontal chip row could not be searched.
// iPhone/iPad: sticky "Categories ▾" + country picker under the header → category sheet (search, country
// chips, Pinned, Recently opened, all categories, hidden ones). Apple TV: a left category column.

/// Country code badge ("TR") – text, not an emoji, so it reads the same everywhere.
struct CountryBadge: View {
    let code: String

    var body: some View {
        Text(code.uppercased())
            .font(Theme.isTV ? .system(size: 20, weight: .heavy) : .caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.isTV ? 8 : 5).padding(.vertical, Theme.isTV ? 3 : 2)
            .background(RoundedRectangle(cornerRadius: Theme.isTV ? 6 : 4, style: .continuous).fill(Theme.primary))
            .accessibilityHidden(true)
    }
}

/// A category listed in one section. The same category can appear in several sections (pinned, recent,
/// all); one list / lazy stack must not see the same id twice, or rows and their focus get mixed up when a
/// section appears (seen on tvOS: focus jumped to the new "Recently opened" entry).
struct KeyedCategory: Identifiable {
    let key: String
    let info: CategoryInfo
    var id: String { key }
}

func keyed(_ section: String, _ infos: [CategoryInfo]) -> [KeyedCategory] {
    infos.map { KeyedCategory(key: "\(section)_\($0.id)", info: $0) }
}

/// "🇹🇷 Türkiye (12)" – country menu / column entries.
@MainActor
func countryMenuTitle(_ code: String, count: Int) -> String {
    "\(CountryFlag.flagPrefix(code))\(CountryFlag.countryName(code)) (\(count))"
}

/// Country picker entries: "All" + every country present (selected first, then most categories first).
struct CountryMenuItems: View {
    let model: BrowseModel

    var body: some View {
        Button { model.selectCountry(nil) } label: {
            let title = "\(L10n.t("all")) (\(model.visibleInfos.count))"
            if model.country == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .accessibilityIdentifier("country_option_all")
        ForEach(model.countries, id: \.code) { entry in
            Button { model.selectCountry(entry.code) } label: {
                let title = countryMenuTitle(entry.code, count: entry.count)
                if model.country == entry.code { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            .accessibilityIdentifier("country_option_\(entry.code)")
        }
    }
}

/// Label of the country picker: "TR Türkiye" or "🌐 All".
struct CountryPickerLabel: View {
    let country: String?

    var body: some View {
        HStack(spacing: Theme.isTV ? 12 : 6) {
            if let country {
                CountryBadge(code: country)
                Text(CountryFlag.countryName(country)).lineLimit(1)
            } else {
                Image(systemName: "globe")
                Text(L10n.t("all")).lineLimit(1)
            }
        }
    }
}

/// Category menu items (long press): pin / unpin, hide / show again.
struct CategoryMenuItems: View {
    let model: BrowseModel
    let info: CategoryInfo
    var hidden = false

    var body: some View {
        if hidden {
            Button { model.setHidden(false, info) } label: { Label(L10n.t("catnav_unhide"), systemImage: "eye") }
        } else {
            let pinned = model.isPinned(info)
            Button { model.togglePin(info) } label: {
                Label(L10n.t(pinned ? "catnav_unpin" : "catnav_pin"), systemImage: pinned ? "pin.slash" : "pin")
            }
            Button { model.setHidden(true, info) } label: { Label(L10n.t("category_hide"), systemImage: "eye.slash") }
        }
    }
}

/// Category name in the navigation: the group code is shown as flag or badge, so its prefix is dropped
/// ("EN | Netflix Series" → "Netflix Series" next to an "EN" badge).
@MainActor
func categoryTitle(_ info: CategoryInfo) -> String {
    info.countryCode == nil ? info.category.name : CategoryCountry.nameWithoutPrefix(info.category.name)
}

/// Leading mark of a category entry: flag for real regions, the code badge for language groups ("EN", "AR").
struct CategoryLeadingMark: View {
    let code: String?

    var body: some View {
        if let code {
            if let flag = CategoryCountry.flagEmoji(forCode: code) {
                Text(flag).accessibilityHidden(true)
            } else {
                CountryBadge(code: code)
            }
        }
    }
}

/// Accessibility label of a category entry ("DİZİLER, Turkey, 4 titles").
@MainActor
func categoryAccessibilityLabel(_ info: CategoryInfo) -> String {
    [categoryTitle(info), info.countryCode.map(CountryFlag.countryName),
     L10n.t("catnav_items", String(info.itemCount))].compactMap { $0 }.joined(separator: ", ")
}

#if !os(tvOS)
/// Sticky row under the mobile header on Movies/Series: "Categories ▾" (wide) + country picker.
/// Transparent over the hero, black once the header turns solid.
struct CategoryNavBar: View {
    let model: BrowseModel
    var solid: Bool
    let onCategories: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCategories) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.footnote.weight(.semibold))
                    Text(L10n.t("row_categories")).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(Theme.surface.opacity(0.92)))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("category_button")

            Menu {
                CountryMenuItems(model: model)
            } label: {
                HStack(spacing: 6) {
                    CountryPickerLabel(country: model.country)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Capsule().fill(Theme.surface.opacity(0.92)))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("\(L10n.t("catnav_country")): \(model.country.map(CountryFlag.countryName) ?? L10n.t("all"))")
            .accessibilityIdentifier("country_picker")
        }
        .padding(.horizontal, Theme.safeH)
        .padding(.vertical, 6)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background {
            Color.black.opacity(solid ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: solid)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("category_bar")
    }
}

/// Presents the category sheet: full screen on iPhone (compact width), a large sheet on iPad. A tapped
/// category is pushed after the sheet is gone (pushing while it dismisses can be dropped).
struct CategorySheetPresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var isPresented: Bool
    @Binding var pendingRoute: BrowseRoute?
    let model: BrowseModel?

    func body(content: Content) -> some View {
        if sizeClass == .compact {
            content.fullScreenCover(isPresented: $isPresented, onDismiss: flush) { sheet }
        } else {
            content.sheet(isPresented: $isPresented, onDismiss: flush) {
                sheet.presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var sheet: some View {
        if let model {
            CategorySheet(model: model) { info in
                model.recordOpened(info)
                pendingRoute = model.gridRoute(info.category)
                isPresented = false
            }
            .environment(env)
            .environment(router)
        }
    }

    private func flush() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        router.path.append(route)
    }
}

/// Full category list of Movies/Series: search, country chips, Pinned, Recently opened, the selected
/// country's categories with item counts, hidden ones behind a toggle.
struct CategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: BrowseModel
    let onOpen: (CategoryInfo) -> Void
    @State private var query = ""
    @State private var showHidden = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // While searching, results come from every country (a category is found even when it belongs to
        // another country than the selected one); without a query the selected country's list.
        let matches = searching ? model.visibleInfos.filter { CategoryCountry.matches($0.category.name, query: query) }
            : model.infos(country: model.country)
        let pinned = model.pinnedInfos
        let recent = model.recentInfos
        let hidden = model.hiddenInfos
        NavigationStack {
            List {
                Section {
                    countryChips
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                if !searching && !pinned.isEmpty {
                    Section {
                        ForEach(keyed("pinned", pinned)) { row($0.info, identifier: "category_pinned_\($0.info.id)") }
                    } header: {
                        header(L10n.t("catnav_pinned"), icon: "pin.fill", identifier: "category_section_pinned")
                    }
                }
                if !searching && !recent.isEmpty {
                    Section {
                        ForEach(keyed("recent", recent)) { row($0.info, identifier: "category_recent_\($0.info.id)") }
                    } header: {
                        header(L10n.t("catnav_recent"), icon: "clock", identifier: "category_section_recent")
                    }
                }
                Section {
                    if matches.isEmpty {
                        Text(L10n.t("catnav_no_match")).foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("category_no_match")
                    } else {
                        ForEach(keyed("row", matches)) { row($0.info, identifier: "category_row_\($0.info.id)") }
                    }
                } header: {
                    header(searching ? L10n.t("catnav_all_categories")
                           : model.country.map { "\(CountryFlag.flagPrefix($0))\(CountryFlag.countryName($0))" } ?? L10n.t("catnav_all_categories"),
                           icon: nil, identifier: "category_section_all")
                }
                if !hidden.isEmpty {
                    Section {
                        Toggle(L10n.t("catnav_show_hidden") + " (\(hidden.count))", isOn: $showHidden)
                            .tint(Theme.primary)
                            .accessibilityIdentifier("category_show_hidden")
                        if showHidden {
                            ForEach(keyed("hidden", hidden)) { hiddenRow($0.info) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The country chips sit right under the search field (no empty first-section gap).
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.t("catnav_search"))
            .navigationTitle(L10n.t(model.kind == .movies ? "catnav_title_movies" : "catnav_title_series"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("action_close")) { dismiss() }
                        .accessibilityIdentifier("category_sheet_close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.primary)
    }

    /// "All 14" + one chip per country ("🇹🇷 TR 2"), wrapping; the selection is the page's country too.
    private var countryChips: some View {
        FlowLayout(spacing: 8) {
            chip(title: "\(L10n.t("all")) \(model.visibleInfos.count)", selected: model.country == nil, identifier: "country_chip_all") {
                model.selectCountry(nil)
            }
            ForEach(model.countries, id: \.code) { entry in
                chip(title: "\(CountryFlag.flagPrefix(entry.code))\(entry.code) \(entry.count)", selected: model.country == entry.code,
                     identifier: "country_chip_\(entry.code)") {
                    model.selectCountry(entry.code)
                }
                .accessibilityLabel("\(CountryFlag.countryName(entry.code)), \(entry.count)")
            }
        }
    }

    private func chip(title: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black : Theme.textPrimary)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(Capsule().fill(selected ? Color.white : Theme.surface))
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func header(_ title: String, icon: String?, identifier: String) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier)
    }

    private func label(_ info: CategoryInfo, pinned: Bool) -> some View {
        HStack(spacing: 10) {
            CategoryLeadingMark(code: info.countryCode)
            Text(categoryTitle(info)).foregroundStyle(Theme.textPrimary).lineLimit(2)
            Spacer(minLength: 8)
            if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.primary) }
            Text("\(info.itemCount)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private func row(_ info: CategoryInfo, identifier: String) -> some View {
        Button { onOpen(info) } label: { label(info, pinned: model.isPinned(info)) }
            .listRowBackground(Theme.surface)
            .contextMenu { CategoryMenuItems(model: model, info: info) }
            .accessibilityLabel(categoryAccessibilityLabel(info))
            .accessibilityIdentifier(identifier)
    }

    private func hiddenRow(_ info: CategoryInfo) -> some View {
        HStack(spacing: 12) {
            Button { onOpen(info) } label: { label(info, pinned: false).opacity(0.6) }
                .buttonStyle(.plain)
                .accessibilityLabel(categoryAccessibilityLabel(info))
                .accessibilityIdentifier("category_hidden_\(info.id)")
            Button { model.setHidden(false, info) } label: {
                Label(L10n.t("catnav_unhide"), systemImage: "eye").labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.t("catnav_unhide"))
            .accessibilityIdentifier("category_unhide_\(info.id)")
        }
        .listRowBackground(Theme.surface)
        .contextMenu { CategoryMenuItems(model: model, info: info, hidden: true) }
    }
}

/// Wrapping row layout (country chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
#endif

#if os(tvOS)
extension View {
    /// tvOS side columns keep `scrollClipDisabled` (focus scaling and shadows must not be cut at the sides),
    /// but rows scrolled up must not draw under / next to the floating tab bar: clip only the top edge.
    func tvTopClipped() -> some View {
        mask {
            Rectangle().padding(.horizontal, -80).padding(.bottom, -400)
        }
    }
}

/// Apple TV Movies/Series (SCREENS §3.2 TV): left category column (~360 pt; one focusable control per
/// row) | right content. The column: country picker · Discover (the browse page) · Pinned · Recently
/// opened · the country's categories with counts · hidden ones. OK on a category shows its grid on the
/// right; Menu in the right content returns focus to the column, Menu in the column goes to the tab bar.
struct TVCategoryBrowseView: View {
    @Environment(AppEnvironment.self) private var env
    let kind: BrowseKind
    @State private var model: BrowseModel?
    /// nil = Discover (browse page).
    @State private var selected: CategoryInfo?
    @State private var lastColumnKey = "discover"
    @State private var showHidden = false
    /// "Recently opened" as of the tab's appearance: updating it live would insert a row above the one
    /// just selected and push the focused row away while the user is in the column.
    @State private var recentSnapshot: [String]?
    @FocusState private var focused: String?

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            if let model {
                column(model).frame(width: 360)
                content(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .focusSection()
                    // Menu in the content → the column's selected row; if that row is gone (country changed,
                    // unpinned, hidden) → Discover, never a key no view has (focus would not move at all).
                    .onExitCommand { focused = columnKeys(model).contains(lastColumnKey) ? lastColumnKey : "discover" }
            }
        }
        .padding(.leading, Theme.safeH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .screenBackground()
        .onAppear {
            if model == nil { model = BrowseModel(env: env, kind: kind) }
            model?.reload()
            recentSnapshot = model?.recentInfos.map(\.id)
        }
        .onChange(of: env.libraryVersion) { model?.reload() }
        .onChange(of: env.catalogVersion) { model?.reload() }
        .onChange(of: env.currentSource?.id) {
            selected = nil
            model?.reload()
            recentSnapshot = model?.recentInfos.map(\.id)
        }
        .onChange(of: model?.categoryInfos.map(\.id)) { _, ids in
            // The shown category disappeared (refresh / other source): back to Discover.
            if let selected, !(ids ?? []).contains(selected.id) { showDiscover() }
        }
        // Another country: the grid of a category of the old one makes no sense any more.
        .onChange(of: model?.country) { showDiscover() }
        // Pin / unpin / hide (long OK): the selected entry may have left the column.
        .onChange(of: env.categoryPrefs.version) {
            guard let model, !columnKeys(model).contains(lastColumnKey) else { return }
            showDiscover()
        }
    }

    private func showDiscover() {
        selected = nil
        lastColumnKey = "discover"
    }

    /// Sections of the column (recent from the snapshot).
    private func sections(_ model: BrowseModel) -> (pinned: [CategoryInfo], recent: [CategoryInfo], scoped: [CategoryInfo], hidden: [CategoryInfo]) {
        let visible = Dictionary(model.visibleInfos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = recentSnapshot.map { $0.compactMap { visible[$0] } } ?? model.recentInfos
        return (model.pinnedInfos, recent, model.infos(country: model.country), model.hiddenInfos)
    }

    /// Focus keys of the rows the column shows right now.
    private func columnKeys(_ model: BrowseModel) -> Set<String> {
        let s = sections(model)
        var keys: Set<String> = ["country", "discover"]
        keys.formUnion(keyed("pinned", s.pinned).map(\.key))
        keys.formUnion(keyed("recent", s.recent).map(\.key))
        keys.formUnion(keyed("row", s.scoped).map(\.key))
        if showHidden { keys.formUnion(keyed("hidden", s.hidden).map(\.key)) }
        return keys
    }

    @ViewBuilder
    private func content(_ model: BrowseModel) -> some View {
        if let selected {
            CatalogGridView(kind: selected.category.kind.contentKind, categoryId: selected.id,
                            title: CountryFlag.displayTitle(selected.category.name), initialSort: .added, embedded: true)
                .id(selected.id)
        } else {
            BrowseView(model: model)
        }
    }

    private func column(_ model: BrowseModel) -> some View {
        let (pinned, recent, scoped, hidden) = sections(model)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Menu {
                    CountryMenuItems(model: model)
                } label: {
                    HStack(spacing: 12) {
                        CountryPickerLabel(country: model.country)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                }
                .buttonStyle(CardButtonStyle(radius: 12, scale: 1.03))
                .focused($focused, equals: "country")
                .accessibilityLabel("\(L10n.t("catnav_country")): \(model.country.map(CountryFlag.countryName) ?? L10n.t("all"))")
                .accessibilityIdentifier("country_picker")
                .padding(.bottom, 8)

                entry(key: "discover", selected: selected == nil, identifier: "category_discover", action: showDiscover) {
                    Image(systemName: "sparkles")
                    Text(L10n.t("catnav_discover")).lineLimit(1)
                    Spacer(minLength: 0)
                }

                if !pinned.isEmpty {
                    sectionHeader(L10n.t("catnav_pinned"), icon: "pin.fill")
                    ForEach(keyed("pinned", pinned)) { categoryEntry(model, $0.info, prefix: "pinned", identifier: "category_pinned_\($0.info.id)") }
                }
                if !recent.isEmpty {
                    sectionHeader(L10n.t("catnav_recent"), icon: "clock")
                    ForEach(keyed("recent", recent)) { categoryEntry(model, $0.info, prefix: "recent", identifier: "category_recent_\($0.info.id)") }
                }
                sectionHeader(model.country.map { "\(CountryFlag.flagPrefix($0))\(CountryFlag.countryName($0))" } ?? L10n.t("catnav_all_categories"), icon: nil)
                ForEach(keyed("row", scoped)) { categoryEntry(model, $0.info, prefix: "row", identifier: "category_row_\($0.info.id)") }
                if !hidden.isEmpty {
                    entry(key: "show_hidden", selected: false, identifier: "category_show_hidden", action: { showHidden.toggle() }) {
                        Image(systemName: showHidden ? "eye.slash" : "eye")
                        Text("\(L10n.t("catnav_show_hidden")) (\(hidden.count))").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 12)
                    if showHidden {
                        sectionHeader(L10n.t("catnav_hidden"), icon: "eye.slash")
                        ForEach(keyed("hidden", hidden)) { categoryEntry(model, $0.info, prefix: "hidden", identifier: "category_hidden_\($0.info.id)", hidden: true) }
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .tvTopClipped()
        .focusSection()
        .accessibilityIdentifier("category_column")
    }

    private func sectionHeader(_ title: String, icon: String?) -> some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon) }
            Text(title).lineLimit(1)
        }
        .font(Theme.caption.weight(.heavy))
        .textCase(.uppercase)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func categoryEntry(_ model: BrowseModel, _ info: CategoryInfo, prefix: String, identifier: String, hidden: Bool = false) -> some View {
        let key = "\(prefix)_\(info.id)"
        return entry(key: key, selected: selected?.id == info.id, identifier: identifier, action: {
            selected = info
            lastColumnKey = key
            model.recordOpened(info)
        }) {
            CategoryLeadingMark(code: info.countryCode)
            Text(categoryTitle(info)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(info.itemCount)").monospacedDigit().foregroundStyle(Theme.textSecondary)
        }
        .opacity(hidden ? 0.6 : 1)
        .contextMenu { CategoryMenuItems(model: model, info: info, hidden: hidden) }
        .accessibilityLabel(categoryAccessibilityLabel(info))
    }

    private func entry<Label: View>(key: String, selected: Bool, identifier: String, action: @escaping () -> Void,
                                    @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { label() }
                .font(Theme.caption.weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.surfaceElevated : Color.clear))
        }
        .buttonStyle(CardButtonStyle(radius: 12, scale: 1.03))
        .focused($focused, equals: key)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
#endif
