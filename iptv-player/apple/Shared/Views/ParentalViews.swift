import IPTVCore
import IPTVKit
import SwiftUI

// MARK: - PIN pad

/// 4-digit PIN entry: dots + a number pad grid (1–9, 0, ⌫). tvOS: one focusable per key (remote); iOS: the same pad
/// (no system keyboard). The PIN is submitted when the 4th digit is entered; `onSubmit` returns an error message
/// (wrong PIN, cooldown, mismatch) or nil.
struct PinPadView: View {
    let title: String
    var subtitle: String? = nil
    let onSubmit: (String) -> String?
    @State private var digits = ""
    @State private var message: String?
    @State private var shake = false

    private let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: Theme.isTV ? 28 : 18) {
            Image(systemName: "lock.fill").font(.system(size: Theme.isTV ? 48 : 28)).foregroundStyle(Theme.primary)
                .accessibilityHidden(true)
            Text(title).font(Theme.isTV ? Theme.headline : .title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pin_title")
            if let subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            HStack(spacing: Theme.isTV ? 26 : 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < digits.count ? Theme.textPrimary : Color.clear)
                        .overlay(Circle().stroke(Theme.textSecondary, lineWidth: 2))
                        .frame(width: Theme.isTV ? 26 : 16, height: Theme.isTV ? 26 : 16)
                }
            }
            .offset(x: shake ? 10 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("parental_pin_entered", String(digits.count)))
            .accessibilityValue(String(digits.count))
            .accessibilityIdentifier("pin_dots")
            Text(message ?? " ").font(Theme.caption).foregroundStyle(Theme.error).multilineTextAlignment(.center)
                .frame(minHeight: Theme.isTV ? 34 : 20)
                .accessibilityIdentifier("pin_message")
            Grid(horizontalSpacing: Theme.isTV ? 24 : 16, verticalSpacing: Theme.isTV ? 20 : 12) {
                ForEach(keys, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { key in keyView(key) }
                    }
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(Theme.isTV ? 40 : 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin_pad")
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        let size: CGFloat = Theme.isTV ? 110 : 68
        if key.isEmpty {
            Color.clear.frame(width: size, height: size)
        } else {
            Button { press(key) } label: {
                Group {
                    if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                }
                .font(.system(size: Theme.isTV ? 44 : 28, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.surfaceElevated))
                .contentShape(Circle())
            }
            .buttonStyle(CardButtonStyle(radius: size / 2, scale: 1.1))
            .accessibilityLabel(key == "⌫" ? L10n.t("action_delete") : key)
            .accessibilityIdentifier(key == "⌫" ? "pin_key_delete" : "pin_key_\(key)")
        }
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 4 else { return }
        digits.append(key)
        message = nil
        guard digits.count == 4 else { return }
        let pin = digits
        digits = ""
        if let error = onSubmit(pin) {
            message = error
            withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) { shake = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                shake = false
            }
            AccessibilityNotification.Announcement(error).post()
        }
    }
}

extension PinCheck {
    /// Message under the dots; nil for `.ok`.
    @MainActor
    var message: String? {
        switch self {
        case .ok, .noPin: return nil
        case .wrong(let remaining): return L10n.t("parental_pin_wrong", String(remaining))
        case .coolingDown(let until): return L10n.t("parental_pin_cooldown", String(max(1, Int(until.timeIntervalSinceNow.rounded(.up)))))
        }
    }
}

// MARK: - Prompt + gate

/// Answers `ParentalControl.prompt` (opening locked content, a protected settings page) with the pad.
struct ParentalPromptSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PinPadView(title: L10n.t("parental_enter_pin")) { pin in
                env.parental.answerPrompt(pin).message
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground()
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("action_cancel")) { env.parental.cancelPrompt() }
                        .accessibilityIdentifier("pin_cancel")
                }
            }
            #endif
        }
        #if os(tvOS)
        .onExitCommand { env.parental.cancelPrompt() }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pin_prompt")
    }
}

/// Settings pages behind the PIN (sources / edit, engine and calibration, parental control itself): the pad until
/// the session is unlocked, then the page.
struct PinGate<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    /// true: always when a PIN exists (parental settings); false: only with "PIN for sources and player settings".
    var always = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let locked = always ? (env.parental.hasPin && !env.parental.isUnlocked) : env.parental.settingsNeedPin
        if locked {
            ScrollView {
                PinPadView(title: L10n.t("parental_enter_pin")) { pin in env.parental.unlock(pin).message }
            }
            .screenBackground()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pin_gate")
        } else {
            content()
        }
    }
}

extension Router {
    /// True when `item` is locked now (parental lock active; channel, its categories, the movie's / series'
    /// categories – memberships included).
    static func isLocked(_ item: PlaybackRequest.Item, env: AppEnvironment) -> Bool {
        guard env.parental.isActive else { return false }
        switch item {
        case .channel(let c): return env.parental.needsPin(channel: c) || env.catalog.isLocked(sourceId: c.sourceId, kind: .live, itemId: c.id)
        case .movie(let m): return env.catalog.isLocked(sourceId: m.sourceId, kind: .movie, itemId: m.id)
        case .episode(let e, _): return env.catalog.isLocked(sourceId: e.sourceId, kind: .series, itemId: e.seriesId)
        case .url: return false
        }
    }

    /// Runs `action` (a catch-up of `channel`) after the PIN when the channel is locked.
    func playGuarded(channel: Channel, _ action: @escaping @MainActor () -> Void) {
        if Self.isLocked(.channel(channel), env: env) {
            env.parental.requestUnlock(then: action)
        } else {
            action()
        }
    }

    /// Opens a category after the PIN when it is locked (show-with-lock mode).
    func openCategory(_ categoryId: String?, kind: CategoryKind, _ action: @escaping @MainActor () -> Void) {
        guard let sid = env.currentSource?.id, env.parental.needsPin(categoryId: categoryId, kind: kind, sourceId: sid) else {
            action()
            return
        }
        env.parental.requestUnlock(then: action)
    }
}

/// 🔒 next to a locked category / channel that is listed (show-with-lock mode, still locked).
struct LockMark: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: Theme.isTV ? 18 : 11, weight: .bold))
            .foregroundStyle(Theme.warning)
            .accessibilityLabel(L10n.t("parental_locked"))
    }
}

/// Long press on a channel: lock / unlock it (only with a PIN; unlocking asks for it).
struct ChannelLockMenuItem: View {
    @Environment(AppEnvironment.self) private var env
    let channel: Channel

    var body: some View {
        if env.parental.hasPin {
            let locked = env.parental.isChannelLocked(channel.id, sourceId: channel.sourceId)
            Button {
                if locked {
                    env.parental.requestUnlock {
                        env.parental.setChannelLocked(false, channelId: channel.id, sourceId: channel.sourceId)
                    }
                } else {
                    env.parental.setChannelLocked(true, channelId: channel.id, sourceId: channel.sourceId)
                }
            } label: {
                Label(L10n.t(locked ? "parental_unlock_channel" : "parental_lock_channel"), systemImage: locked ? "lock.open" : "lock")
            }
        }
    }
}

// MARK: - Settings → Parental control

/// Top-level settings row → parental control (always behind the PIN once one is set).
struct ParentalSettingsRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationLink {
            PinGate(always: true) { ParentalSettingsView() }
        } label: {
            HStack {
                Label(L10n.t("parental_title"), systemImage: "lock.shield")
                Spacer()
                Text(env.parental.hasPin ? L10n.t("parental_status_on") : L10n.t("off")).foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("settings_parental")
    }
}

struct ParentalSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var flow: PinFlow?
    @State private var suggestions: [IPTVCore.Category] = []
    @State private var showSuggestions = false
    @State private var note: String?

    enum PinFlow: Identifiable {
        case set, change, remove
        var id: Self { self }
    }

    var body: some View {
        let parental = env.parental
        Form {
            Section {
                LText("parental_intro").font(Theme.caption).foregroundStyle(Theme.textSecondary).tvFocusableRow()
                if let note {
                    Text(note).font(Theme.caption).foregroundStyle(Theme.success)
                        .accessibilityIdentifier("parental_note").tvFocusableRow()
                }
            }
            if !parental.hasPin {
                Section {
                    Button(L10n.t("parental_set_pin")) { flow = .set }
                        .accessibilityIdentifier("parental_set_pin")
                }
            } else {
                Section {
                    Toggle(L10n.t("parental_hide_locked"), isOn: Binding(get: { parental.hideLocked }, set: { parental.hideLocked = $0 }))
                        .accessibilityIdentifier("parental_hide_locked")
                    Toggle(L10n.t("parental_protect_settings"), isOn: Binding(get: { parental.protectSettings }, set: { parental.protectSettings = $0 }))
                        .accessibilityIdentifier("parental_protect_settings")
                    if parental.isUnlocked {
                        Button(L10n.t("parental_lock_now")) { parental.relock() }
                            .accessibilityIdentifier("parental_lock_now")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("parental_hide_locked_hint"))
                        if parental.isUnlocked { Text(L10n.t("parental_unlocked_note")) }
                    }
                }
                if let source = env.currentSource {
                    Section(L10n.t("parental_locked_categories")) {
                        ForEach([CategoryKind.live, .movie, .series], id: \.self) { kind in
                            NavigationLink {
                                LockCategoriesView(sourceId: source.id, kind: kind)
                            } label: {
                                LabeledContent(L10n.t(Self.kindTitle(kind)),
                                               value: String(parental.lockedCategoryIds(sourceId: source.id, kind: kind).count))
                            }
                            .accessibilityIdentifier("parental_categories_\(kind.rawValue)")
                        }
                    }
                    Section(L10n.t("parental_locked_channels")) {
                        let ids = parental.lockedChannelIds(sourceId: source.id)
                        if ids.isEmpty {
                            LText("parental_no_locked_channels").font(Theme.caption).foregroundStyle(Theme.textSecondary).tvFocusableRow()
                        } else {
                            ForEach(lockedChannels(source.id, ids), id: \.id) { channel in
                                Button {
                                    parental.setChannelLocked(false, channelId: channel.id, sourceId: source.id)
                                } label: {
                                    HStack {
                                        Text(channel.name).foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                        Label(L10n.t("parental_unlock_channel"), systemImage: "lock.open").labelStyle(.iconOnly)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .accessibilityLabel("\(channel.name), \(L10n.t("parental_unlock_channel"))")
                                .accessibilityIdentifier("parental_locked_channel_\(channel.id)")
                            }
                        }
                    }
                }
                Section {
                    Button(L10n.t("parental_change_pin")) { flow = .change }
                        .accessibilityIdentifier("parental_change_pin")
                    Button(L10n.t("parental_remove_pin"), role: .destructive) { flow = .remove }
                        .accessibilityIdentifier("parental_remove_pin")
                }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("parental_title"))
        .sheet(item: $flow) { flow in
            PinFlowSheet(flow: flow) { done in
                self.flow = nil
                guard done else { return }
                switch flow {
                case .set:
                    note = L10n.t("parental_pin_set_done")
                    offerAdultSuggestions()
                case .change, .remove:
                    note = nil
                }
            }
            .environment(env)
        }
        .sheet(isPresented: $showSuggestions) {
            AdultSuggestionView(categories: suggestions) { showSuggestions = false }
                .environment(env)
        }
    }

    static func kindTitle(_ kind: CategoryKind) -> String {
        switch kind {
        case .live: return "nav_live"
        case .movie: return "nav_movies"
        case .series: return "nav_series"
        }
    }

    /// Locked channels by id (the session is unlocked here, so the catalog returns them).
    private func lockedChannels(_ sourceId: String, _ ids: [String]) -> [Channel] {
        let found = (try? env.catalog.channels(sourceId: sourceId, ids: ids)) ?? []
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.map { byId[$0] ?? Channel(sourceId: sourceId, id: $0, name: $0) }
    }

    /// First PIN: offer to lock the categories whose names look adult (every source, every kind).
    private func offerAdultSuggestions() {
        var found: [IPTVCore.Category] = []
        for source in env.sources where !env.parental.wasSuggestionOffered(sourceId: source.id) {
            let all = [CategoryKind.live, .movie, .series].flatMap { (try? env.catalog.allCategories(sourceId: source.id, kind: $0)) ?? [] }
            found += env.parental.adultSuggestions(sourceId: source.id, categories: all)
            env.parental.markSuggestionOffered(sourceId: source.id)
        }
        guard !found.isEmpty else { return }
        suggestions = found
        showSuggestions = true
    }
}

/// Set (new + repeat), change (current + new + repeat) or remove (current) the PIN.
private struct PinFlowSheet: View {
    @Environment(AppEnvironment.self) private var env
    let flow: ParentalSettingsView.PinFlow
    let onDone: (Bool) -> Void
    @State private var step = 0
    @State private var first: String?
    @State private var current: String?
    @State private var mismatch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                PinPadView(title: title, subtitle: mismatch ? L10n.t("parental_pin_mismatch") : nil) { pin in submit(pin) }
                    .id(step)   // fresh pad per step
            }
            .screenBackground()
            #if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("action_cancel")) { onDone(false) }.accessibilityIdentifier("pin_cancel")
                }
            }
            #endif
        }
        #if os(tvOS)
        .onExitCommand { onDone(false) }
        #endif
    }

    private var title: String {
        switch (flow, step) {
        case (.change, 0): return L10n.t("parental_current_pin")
        case (.set, 0), (.change, 1): return L10n.t("parental_new_pin")
        case (.set, _), (.change, _): return L10n.t("parental_confirm_pin")
        case (.remove, _): return L10n.t("parental_current_pin")
        }
    }

    private func submit(_ pin: String) -> String? {
        switch flow {
        case .remove:
            let result = env.parental.removePin(pin)
            if result == .ok { onDone(true) }
            return result.message
        case .change where step == 0:
            let result = env.parental.verify(pin)
            guard result == .ok else { return result.message }
            current = pin
            step = 1
            return nil
        case .set, .change:
            if first == nil {
                first = pin
                mismatch = false
                step += 1
                return nil
            }
            guard pin == first else {
                first = nil
                mismatch = true
                step = flow == .set ? 0 : 1
                return nil
            }
            if flow == .change, let current {
                let result = env.parental.changePin(old: current, new: pin)
                if result == .ok { onDone(true) }
                return result.message
            }
            env.parental.setPin(pin)
            onDone(true)
            return nil
        }
    }
}

/// First PIN: "Lock adult categories?" – every suggestion preselected.
private struct AdultSuggestionView: View {
    @Environment(AppEnvironment.self) private var env
    let categories: [IPTVCore.Category]
    let onDone: () -> Void
    @State private var selected: Set<String> = []

    private func key(_ c: IPTVCore.Category) -> String { "\(c.sourceId)|\(c.kind.rawValue)|\(c.id)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LText("parental_suggest_body").font(Theme.caption).foregroundStyle(Theme.textSecondary).tvFocusableRow()
                }
                Section {
                    ForEach(categories, id: \.self) { c in
                        let on = selected.contains(key(c))
                        Button {
                            if on { selected.remove(key(c)) } else { selected.insert(key(c)) }
                        } label: {
                            HStack {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.primary : Theme.textSecondary)
                                Text(c.name).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(L10n.t(ParentalSettingsView.kindTitle(c.kind))).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("parental_suggest_\(c.id)")
                    }
                }
                Section {
                    Button(L10n.t("parental_suggest_lock")) {
                        for c in categories where selected.contains(key(c)) {
                            env.parental.setCategoryLocked(true, categoryId: c.id, kind: c.kind, sourceId: c.sourceId)
                        }
                        onDone()
                    }
                    .accessibilityIdentifier("parental_suggest_lock")
                    Button(L10n.t("parental_suggest_skip")) { onDone() }
                        .accessibilityIdentifier("parental_suggest_skip")
                }
            }
            .hiddenListBackground()
            .screenBackground()
            .navigationTitle(L10n.t("parental_suggest_title"))
        }
        .onAppear { selected = Set(categories.map(key)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parental_suggestions")
    }
}

/// Settings → Parental control → Locked categories of one kind (all categories of the current source, toggles).
struct LockCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    let sourceId: String
    let kind: CategoryKind
    @State private var categories: [IPTVCore.Category] = []
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? categories : categories.filter { $0.name.lowercased().contains(q) }
        List {
            ForEach(shown) { category in
                let locked = env.parental.isCategoryLocked(category.id, kind: kind, sourceId: sourceId)
                Toggle(isOn: Binding(get: { locked }, set: {
                    env.parental.setCategoryLocked($0, categoryId: category.id, kind: kind, sourceId: sourceId)
                })) {
                    HStack(spacing: 8) {
                        if ParentalControl.isAdultCategoryName(category.name) { Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.warning) }
                        Text(category.name)
                    }
                }
                .accessibilityIdentifier("parental_lock_category_\(category.id)")
            }
        }
        .searchable(text: $query)
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t(ParentalSettingsView.kindTitle(kind)))
        .onAppear { categories = (try? env.catalog.allCategories(sourceId: sourceId, kind: kind)) ?? [] }
    }
}
