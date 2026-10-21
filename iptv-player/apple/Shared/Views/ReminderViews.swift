import IPTVCore
import IPTVKit
import Observation
import SwiftUI
#if os(iOS)
import UserNotifications
#endif

// MARK: - Runtime: in-app banner loop, auto-switch, notification taps

/// Drives the reminders while the app runs (SCREENS §3.4): wakes at the next reminder moment, shows the banner
/// ("<Programm> beginnt jetzt auf <Kanal> – Umschalten?") or switches by itself (setting), and opens the channel of a
/// tapped iOS notification. One instance for the app.
@MainActor
@Observable
final class ReminderRuntime {
    static let shared = ReminderRuntime()

    /// The banner on screen.
    private(set) var banner: ReminderFire?
    /// "Umgeschaltet auf …" after an automatic switch (the banner then only tells).
    private(set) var autoSwitched = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private weak var env: AppEnvironment?
    @ObservationIgnored private weak var router: Router?
    /// A notification was tapped before the UI was up (cold start): handled once it is.
    @ObservationIgnored var pendingTapId: String?

    func start(env: AppEnvironment, router: Router) {
        self.env = env
        self.router = router
        if let id = pendingTapId {
            pendingTapId = nil
            openReminder(id: id)
        }
        wake()
    }

    /// (Re)plans the sleep until the next reminder moment (new reminder, app active again).
    func wake() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let env = self.env else { return }
                env.reminders.cleanup()
                for fire in env.reminders.takeDueFires() { self.fire(fire) }
                let next = env.reminders.nextFireDate()
                let wait = min(60, max(0.5, (next ?? Date().addingTimeInterval(60)).timeIntervalSinceNow + 0.2))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func fire(_ fire: ReminderFire) {
        guard let env else { return }
        if fire.minutesBefore == 0, env.reminders.autoSwitch {
            autoSwitched = true
            show(fire)
            switchTo(fire.reminder)
        } else {
            autoSwitched = false
            show(fire)
        }
    }

    private func show(_ fire: ReminderFire) {
        banner = fire
        AccessibilityNotification.Announcement(Self.text(fire)).post()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        banner = nil
    }

    /// "Umschalten": the reminder's channel (its category as zapping list); a locked channel asks for the PIN.
    func switchTo(_ reminder: ProgramReminder) {
        dismissIfShowing(reminder)
        guard let env, let router,
              let channel = (try? env.catalog.channelIgnoringLock(sourceId: reminder.sourceId, id: reminder.channelId)) ?? nil else { return }
        if env.currentSource?.id != reminder.sourceId { env.selectSource(reminder.sourceId) }
        var zap = (try? env.catalog.channels(sourceId: channel.sourceId, categoryId: channel.categoryId, limit: 200)) ?? []
        if !zap.contains(where: { $0.id == channel.id }) { zap.insert(channel, at: 0) }
        router.play(.channel(channel), channels: zap)
    }

    private func dismissIfShowing(_ reminder: ProgramReminder) {
        if banner?.reminder.id == reminder.id, !autoSwitched { dismiss() }
    }

    /// A tapped notification (iOS): the stored reminder, else the channel from the id ("source|channel|start").
    func openReminder(id: String) {
        guard env != nil else {
            pendingTapId = id
            return
        }
        if let reminder = env?.reminders.reminders.first(where: { $0.id == id }) {
            switchTo(reminder)
            return
        }
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 3 else { return }
        switchTo(ProgramReminder(sourceId: parts[0], channelId: parts[1], channelName: "", title: "",
                                 start: Date(timeIntervalSince1970: Double(parts[2]) ?? 0), end: Date()))
    }

    static func text(_ fire: ReminderFire) -> String {
        L10n.t(fire.minutesBefore > 0 ? "reminder_banner_soon" : "reminder_banner_now", fire.reminder.title, fire.reminder.channelName)
    }
}

#if os(iOS)
/// iOS local notifications of reminders (no push, no capability): scheduled per reminder moment, a tap opens the
/// channel; in the foreground the in-app banner shows instead of the system banner.
@MainActor
final class ReminderNotificationCenter: NSObject, ReminderNotifier, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationCenter()

    /// Call at launch (before the first scene): the delegate must be set to receive a cold-start tap.
    static func install(env: AppEnvironment) {
        env.reminders.notifier = shared
        UNUserNotificationCenter.current().delegate = shared
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(_ fires: [ReminderFire]) {
        let center = UNUserNotificationCenter.current()
        for fire in fires {
            let content = UNMutableNotificationContent()
            content.title = fire.reminder.title
            content.body = ReminderRuntime.text(fire)
            content.sound = .default
            content.userInfo = ["reminderId": fire.reminder.id]
            content.threadIdentifier = "reminders"
            let seconds = max(1, fire.date.timeIntervalSinceNow)
            let request = UNNotificationRequest(identifier: Self.identifier(fire.reminder.id, fire.minutesBefore), content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
            center.add(request) { error in
                if error != nil { SafeLog.warning("reminder notification not scheduled") }
            }
        }
    }

    func cancel(reminderIds: [String]) {
        let ids = reminderIds.flatMap { [Self.identifier($0, 0), Self.identifier($0, ReminderStore.leadMinutesOption)] }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func identifier(_ reminderId: String, _ minutesBefore: Int) -> String { "reminder.\(reminderId)#\(minutesBefore)" }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        []   // the app is open: the in-app banner shows (ReminderRuntime)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["reminderId"] as? String else { return }
        await MainActor.run { ReminderRuntime.shared.openReminder(id: id) }
    }
}
#endif

// MARK: - Banner

/// "<Programm> beginnt jetzt auf <Kanal> – Umschalten?" (20 s). tvOS: the "Umschalten" button takes the focus.
struct ReminderBannerView: View {
    let runtime = ReminderRuntime.shared
    @FocusState private var focused: Bool

    var body: some View {
        if let fire = runtime.banner {
            HStack(spacing: Theme.isTV ? 24 : 12) {
                Image(systemName: "bell.fill").font(.system(size: Theme.isTV ? 34 : 20)).foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.autoSwitched ? L10n.t("reminder_switched", fire.reminder.channelName) : ReminderRuntime.text(fire))
                        .font(Theme.isTV ? Theme.body.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .accessibilityIdentifier("reminder_banner_text")
                    if !runtime.autoSwitched {
                        LText("reminder_switch_question").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if !runtime.autoSwitched {
                    Button { runtime.switchTo(fire.reminder) } label: { Text(L10n.t("reminder_switch")) }
                        .buttonStyle(WhitePillButtonStyle())
                        .focused($focused)
                        .accessibilityIdentifier("reminder_switch")
                }
                Button { runtime.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(RoundIconButtonStyle(size: Theme.isTV ? 64 : 34))
                    .accessibilityLabel(L10n.t("action_close"))
                    .accessibilityIdentifier("reminder_dismiss")
            }
            .padding(Theme.isTV ? 26 : 14)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surfaceElevated.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .frame(maxWidth: Theme.isTV ? 1100 : 560)
            .padding(.horizontal, Theme.safeH)
            .padding(.top, Theme.isTV ? 40 : 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            #if os(tvOS)
            .focusSection()
            #endif
            .onAppear { focused = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reminder_banner")
        }
    }
}

// MARK: - Root overlays (PIN prompt, reminder banner, relock)

/// Attached to the app roots and the player: the PIN pad for `ParentalControl.prompt`, the reminder banner, relock
/// when the app goes to the background, the reminder loop. `inPlayer`: the copy inside the player cover is the one
/// that presents while the player is up (a sheet cannot be presented from under a full-screen cover).
struct GuideParentalOverlays: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    var inPlayer = false

    private var active: Bool { router.playerPresented == inPlayer }

    func body(content: Content) -> some View {
        let prompt = Binding(get: { active ? env.parental.prompt : nil }, set: {
            // Swiped away (the prompt is still pending) = cancel; after a right PIN the prompt is already gone and the
            // approved action must survive until onDismiss.
            if $0 == nil, active, env.parental.prompt != nil { env.parental.cancelPrompt() }
        })
        content
            .overlay(alignment: .top) {
                if active { ReminderBannerView().animation(.easeOut(duration: 0.25), value: ReminderRuntime.shared.banner?.key) }
            }
            #if os(tvOS)
            .fullScreenCover(item: prompt, onDismiss: { env.parental.promptDismissed() }) { _ in
                ParentalPromptSheet().environment(env)
            }
            #else
            .sheet(item: prompt, onDismiss: { env.parental.promptDismissed() }) { _ in
                ParentalPromptSheet().environment(env).presentationDetents([.large])
            }
            #endif
            .task {
                guard !inPlayer else { return }
                ReminderRuntime.shared.start(env: env, router: router)
            }
            .onChange(of: env.reminders.reminders) { if !inPlayer { ReminderRuntime.shared.wake() } }
            .onChange(of: scenePhase) { _, phase in
                guard !inPlayer else { return }
                switch phase {
                case .background: env.parental.relock()
                case .active:
                    env.reminders.cleanup()
                    ReminderRuntime.shared.wake()
                default: break
                }
            }
    }
}

extension View {
    func guideParentalOverlays(inPlayer: Bool = false) -> some View { modifier(GuideParentalOverlays(inPlayer: inPlayer)) }
}

// MARK: - Settings → Reminders

struct RemindersSettingsRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationLink {
            RemindersView()
        } label: {
            HStack {
                Label(L10n.t("reminders_title"), systemImage: "bell")
                Spacer()
                if !env.reminders.reminders.isEmpty {
                    Text(L10n.t("reminders_count", String(env.reminders.reminders.count))).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .accessibilityIdentifier("settings_reminders")
    }
}

/// Settings → Reminders: the list (delete), "also 5 min before", "switch automatically".
struct RemindersView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var reminders = env.reminders
        Form {
            Section {
                if reminders.reminders.isEmpty {
                    LText("reminders_empty").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("reminders_empty").tvFocusableRow()
                }
                ForEach(reminders.reminders) { reminder in
                    row(reminder)
                }
                #if os(iOS)
                .onDelete { offsets in
                    for i in offsets { env.reminders.remove(id: reminders.reminders[i].id) }
                }
                #endif
            } footer: {
                Text(L10n.t(Theme.isTV ? "reminders_hint_tv" : "reminders_hint_ios"))
            }
            Section {
                Toggle(L10n.t("reminders_early"), isOn: $reminders.remindEarly)
                    .accessibilityIdentifier("reminders_early")
                Toggle(L10n.t("reminders_auto_switch"), isOn: $reminders.autoSwitch)
                    .accessibilityIdentifier("reminders_auto_switch")
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle(L10n.t("reminders_title"))
        .onAppear { env.reminders.cleanup() }
    }

    @ViewBuilder
    private func row(_ reminder: ProgramReminder) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            Text(reminder.title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text("\(reminder.channelName) · \(L10n.date(reminder.start, date: .abbreviated, time: .omitted)) · \(env.timeFormatter.range(start: reminder.start, end: reminder.end))")
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        #if os(tvOS)
        // One focusable row; OK deletes (the trash icon says so).
        Button { env.reminders.remove(id: reminder.id) } label: {
            HStack { label; Spacer(); Image(systemName: "trash").foregroundStyle(Theme.error) }
        }
        .accessibilityLabel("\(reminder.title), \(L10n.t("action_delete"))")
        .accessibilityIdentifier("reminder_row_\(reminder.channelId)")
        #else
        label
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reminder_row_\(reminder.channelId)")
            .swipeActions {
                Button(role: .destructive) { env.reminders.remove(id: reminder.id) } label: { Label(L10n.t("action_delete"), systemImage: "trash") }
                    .accessibilityIdentifier("reminder_delete")
            }
        #endif
    }
}
