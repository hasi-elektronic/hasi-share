import IPTVCore
import IPTVKit
import SwiftUI

// MARK: - Day picker (SCREENS §3.4, Build 18)

/// The guide's day row: "Jetzt" (back to today + the airing programme) · Gestern · Heute · Morgen · weekday + date
/// up to +6 days (past days as deep as the source's catch-up, at least yesterday). One focusable per chip (tvOS).
struct GuideDayBar: View {
    @Environment(AppEnvironment.self) private var env
    let days: [GuideDay]
    @Binding var selection: Int
    let onJumpNow: () -> Void

    var body: some View {
        HStack(spacing: Theme.isTV ? 14 : 8) {
            // "Jetzt" stays in view (pinned left of the scrolling days).
            Button(action: onJumpNow) {
                Label(L10n.t("guide_jump_now"), systemImage: "clock.arrow.2.circlepath")
                    .font(Theme.isTV ? Theme.caption.weight(.bold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.isTV ? 24 : 12).padding(.vertical, Theme.isTV ? 10 : 7)
                    .background(Capsule().fill(Theme.live.opacity(0.85)))
            }
            .buttonStyle(CardButtonStyle(radius: 40, scale: 1.08))
            .fixedSize()
            .padding(.leading, Theme.safeH)
            .accessibilityHint(L10n.t("guide_jump_now_hint"))
            .accessibilityIdentifier("guide_jump_now")
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.isTV ? 14 : 8) {
                    ForEach(days) { day in
                        let selected = day.offset == selection
                        Button { selection = day.offset } label: {
                            Text(Self.title(day, env: env))
                                .font(Theme.isTV ? Theme.caption.weight(selected ? .bold : .medium) : .subheadline.weight(selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.black : Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.isTV ? 22 : 12).padding(.vertical, Theme.isTV ? 10 : 7)
                                .background(Capsule().fill(selected ? Color.white : Theme.surface))
                                .overlay(Capsule().stroke(selected ? Color.clear : Theme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(CardButtonStyle(radius: 40, scale: 1.08))
                        .id(day.offset)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("guide_day_\(day.offset)")
                    }
                }
                .padding(.trailing, Theme.safeH)
                .padding(.leading, 2)
                .padding(.vertical, Theme.isTV ? 10 : 2)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
        }
        }
        #if os(tvOS)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("guide_day_picker"))
        .accessibilityIdentifier("guide_day_bar")
    }

    /// "Gestern" / "Heute" / "Morgen" / "Sa., 11. Okt." in the UI language and the EPG time zone.
    @MainActor
    static func title(_ day: GuideDay, env: AppEnvironment) -> String {
        switch day.offset {
        case -1: return L10n.t("guide_day_yesterday")
        case 0: return L10n.t("epg_today")
        case 1: return L10n.t("guide_day_tomorrow")
        default:
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(L10n.locale)
            style.timeZone = day.timeZone
            return day.start.addingTimeInterval(12 * 3600).formatted(style)
        }
    }
}

extension AppEnvironment {
    /// Picker days of the current source (catch-up depth = its deepest channel archive, CONTRACT §5 retention).
    @MainActor
    func guideDays(now: Date = Date()) -> [GuideDay] {
        let depth = currentSource.flatMap { try? catalog.maxCatchupDays(sourceId: $0.id) } ?? 0
        return GuideDay.days(now: now, timeZone: settings.timeZone, catchupDays: depth)
    }
}

// MARK: - Programme detail (SCREENS §3.4)

/// The programme a detail sheet shows.
struct ProgramSelection: Identifiable, Hashable {
    let channel: Channel
    let program: EpgProgram
    var id: String { "\(channel.sourceId)|\(channel.id)|\(program.start.timeIntervalSince1970)" }
}

/// Programme detail: time, channel, description; Jetzt ansehen (live) · Von Anfang an / Aufnahme ansehen (catch-up)
/// · Erinnern. tvOS: one focusable action per row, Menu closes.
struct ProgramDetailSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let selection: ProgramSelection
    let zapList: [Channel]

    var body: some View {
        let channel = selection.channel, program = selection.program
        let now = Date()
        let actions = env.programActions(channel: channel, program: program, now: now)
        let reminded = env.reminders.contains(sourceId: channel.sourceId, channelId: channel.id, start: program.start)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.isTV ? 24 : 14) {
                    HStack(spacing: Theme.isTV ? 20 : 12) {
                        ChannelTile(channel: channel, width: Theme.isTV ? 110 : 56, height: Theme.isTV ? 110 : 56, radius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name).font(Theme.isTV ? Theme.caption.weight(.semibold) : .subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(program.title).font(Theme.isTV ? Theme.title : .title2.bold()).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("program_detail_title")
                        }
                    }
                    HStack(spacing: 10) {
                        Text(timeLine(program)).font((Theme.isTV ? Theme.body : .subheadline).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        badge(actions.timing)
                    }
                    if actions.timing == .onAir {
                        ProgressBar(value: EpgSchedule.progress(of: program, at: now)).frame(height: 4).frame(maxWidth: Theme.isTV ? 600 : .infinity)
                    }
                    Text(program.description ?? L10n.t("program_no_description"))
                        .font(Theme.isTV ? Theme.body : .body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        #if os(tvOS)
                        .focusable()   // long descriptions scroll with the remote
                        #endif
                    VStack(alignment: .leading, spacing: Theme.isTV ? 16 : 10) {
                        Button { watchLive() } label: { Label(L10n.t("program_watch_live"), systemImage: "play.fill") }
                            .buttonStyle(WhitePillButtonStyle())
                            .accessibilityIdentifier("program_watch_live")
                        if actions.canReplay {
                            Button { replay() } label: {
                                Label(L10n.t(actions.timing == .onAir ? "program_start_over" : "program_watch_recording"),
                                      systemImage: actions.timing == .onAir ? "backward.end.fill" : "clock.arrow.circlepath")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier(actions.timing == .onAir ? "program_start_over" : "program_watch_recording")
                        } else if actions.timing != .future, channel.catchup.isAvailable {
                            LText("program_no_replay").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        if actions.canRemind {
                            Button { env.reminders.toggle(channel: channel, program: program) } label: {
                                Label(L10n.t(reminded ? "program_remind_remove" : "program_remind"), systemImage: reminded ? "bell.slash" : "bell")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier(reminded ? "program_remind_remove" : "program_remind")
                            if reminded {
                                Label(L10n.t("program_reminder_set"), systemImage: "bell.fill")
                                    .font(Theme.caption).foregroundStyle(Theme.success)
                                    .accessibilityIdentifier("program_reminder_set")
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(Theme.isTV ? 60 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenBackground()
            .navigationTitle(L10n.t("program_details"))
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.t("action_close"))
                        .accessibilityIdentifier("program_detail_close")
                }
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("program_detail")
    }

    private func timeLine(_ p: EpgProgram) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).locale(L10n.locale)
        style.timeZone = env.settings.timeZone
        return "\(p.start.formatted(style)) · \(env.timeFormatter.range(start: p.start, end: p.end))"
    }

    @ViewBuilder
    private func badge(_ timing: ProgramActions.Timing) -> some View {
        switch timing {
        case .onAir:
            Text("● " + L10n.t("program_on_air_now")).font(.system(size: Theme.isTV ? 20 : 12, weight: .heavy)).foregroundStyle(Theme.live)
        case .past:
            LText("program_ended").font(.system(size: Theme.isTV ? 20 : 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        case .future:
            EmptyView()
        }
    }

    private func watchLive() {
        dismiss()
        let channel = selection.channel
        router.play(.channel(channel), channels: zapList.contains(channel) ? zapList : [channel])
    }

    private func replay() {
        guard let url = env.catchupURL(channel: selection.channel, program: selection.program) else { return }
        dismiss()
        let channel = selection.channel
        router.playGuarded(channel: channel) {
            router.play(.url(url, title: "\(channel.name) · \(selection.program.title)"))
        }
    }
}
