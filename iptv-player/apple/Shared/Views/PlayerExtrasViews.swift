import IPTVCore
import IPTVKit
import SwiftUI

/// Build 16 "watching pack" pieces of the player (docs/SCREENS.md §3.5/§3.7): next-episode card, sleep-timer
/// menu + indicator, subtitle style / delay menu items. `PlayerView` places them.

// MARK: Next episode

/// "Next episode in 7 s" card (bottom right): episode, "Play now" (★, tvOS focus) · "Cancel" (tvOS: Menu).
struct UpNextCard: View {
    let upNext: UpNext
    let onPlay: () -> Void
    let onCancel: () -> Void
    #if os(tvOS)
    var playFocus: FocusState<Bool>.Binding
    var cancelFocus: FocusState<Bool>.Binding
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 16 : 8) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(headline)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("up_next_countdown")
            }
            Text("S\(upNext.episode.season)E\(upNext.episode.number) · \(upNext.episode.title)")
                .font(Theme.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: Theme.isTV ? 24 : 10) {
                Button(action: onPlay) { Label(L10n.t("action_play_now"), systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                    #if os(tvOS)
                    .focused(playFocus)
                    #endif
                    .accessibilityIdentifier("up_next_play")
                Button(L10n.t("action_cancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    #if os(tvOS)
                    .focused(cancelFocus)
                    #endif
                    .accessibilityIdentifier("up_next_cancel")
            }
        }
        .padding(Theme.isTV ? 32 : 16)
        .frame(maxWidth: Theme.isTV ? 760 : 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius * (Theme.isTV ? 2 : 1.5), style: .continuous)
            .fill(Theme.surfaceElevated.opacity(0.95)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player_up_next")
    }

    private var headline: String {
        guard let deadline = upNext.deadlineMs else { return L10n.t("next_episode") }
        let seconds = max(0, Int(((Double(deadline - SystemClock.monotonicMs())) / 1000).rounded(.up)))
        return L10n.t("next_episode_in", String(seconds))
    }
}

/// Settings (top level): "Play next episode automatically" (default on, device-local).
struct AutoplayNextEpisodeToggle: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let prefs = env.player.preferences {
            @Bindable var prefs = prefs
            Toggle(L10n.t("settings_autoplay_next"), isOn: $prefs.autoplayNextEpisode)
                .accessibilityIdentifier("settings_autoplay_next")
        }
    }
}

// MARK: Sleep timer

/// Menu items: Off · 15 · 30 · 60 · 90 min · End of episode/movie (VOD).
struct SleepTimerMenuItems: View {
    let player: PlayerController
    let onPick: () -> Void

    var body: some View {
        item(L10n.t("off"), selected: player.sleepTimer == nil) { player.setSleepTimer(nil) }
        ForEach(PlayerController.sleepTimerMinutes, id: \.self) { minutes in
            item(L10n.t("sleep_timer_minutes", String(minutes)), selected: player.sleepTimer?.mode == .minutes(minutes)) {
                player.setSleepTimer(.minutes(minutes))
            }
        }
        if player.request?.isLive == false {
            let key = { if case .episode? = player.request?.item { return "sleep_timer_end_episode" } else { return "sleep_timer_end_movie" } }()
            item(L10n.t(key), selected: player.sleepTimer?.mode == .endOfItem) { player.setSleepTimer(.endOfItem) }
        }
    }

    private func item(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); onPick() } label: { Label(title, systemImage: selected ? "checkmark" : "") }
    }
}

/// "Sleep in 14:32" pill (top right) while a timer runs; "Sleep at the end" for end-of-item.
struct SleepTimerIndicator: View {
    let state: SleepTimerState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label(text, systemImage: "moon.zzz.fill")
                .font(Theme.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.isTV ? 20 : 12)
                .padding(.vertical, Theme.isTV ? 10 : 6)
                .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sleep_timer_indicator")
    }

    private var text: String {
        guard let deadline = state.deadlineMs else { return L10n.t("sleep_timer_at_end") }
        let seconds = max(0, Double(deadline - SystemClock.monotonicMs()) / 1000)
        return L10n.t("sleep_timer_remaining", L10n.clock(seconds.rounded(.up)))
    }
}

// MARK: Subtitles: style + delay

/// Submenus of the player's subtitle menu: Style (size · colour · background) and – VLCKit only – Delay.
struct SubtitleOptionsMenuItems: View {
    let player: PlayerController
    let onPick: () -> Void

    /// Delay presets (s) of the delay submenu (VLCKit `currentVideoSubTitleDelay`; + = later).
    static let delayPresets: [Int] = [-2000, -1000, -500, -200, 0, 200, 500, 1000, 2000]

    var body: some View {
        let style = player.subtitleStyle
        Menu {
            Menu(L10n.t("subtitle_size")) {
                ForEach(SubtitleStyle.Size.allCases, id: \.self) { size in
                    pick(L10n.t("subtitle_size_\(size.rawValue)"), selected: style.size == size) { $0.size = size }
                }
            }
            Menu(L10n.t("subtitle_color")) {
                ForEach(SubtitleStyle.Color.allCases, id: \.self) { color in
                    pick(L10n.t("subtitle_color_\(color.rawValue)"), selected: style.color == color) { $0.color = color }
                }
            }
            Menu(L10n.t("subtitle_background")) {
                ForEach(SubtitleStyle.Background.allCases, id: \.self) { background in
                    pick(L10n.t("subtitle_background_\(background.rawValue)"), selected: style.background == background) {
                        $0.background = background
                    }
                }
            }
        } label: {
            Label(L10n.t("subtitle_style"), systemImage: "textformat.size")
        }
        .accessibilityIdentifier("player_subtitle_style")
        if player.supportsSubtitleDelay {
            Menu {
                ForEach(Self.delayPresets, id: \.self) { ms in
                    Button {
                        player.setSubtitleDelay(ms)
                        onPick()
                    } label: {
                        Label(Self.delayLabel(ms), systemImage: player.subtitleDelayMs == ms ? "checkmark" : "")
                    }
                }
            } label: {
                Label("\(L10n.t("subtitle_delay")) (\(Self.delayLabel(player.subtitleDelayMs)))", systemImage: "clock.arrow.2.circlepath")
            }
            .accessibilityIdentifier("player_subtitle_delay")
        }
    }

    private func pick(_ title: String, selected: Bool, change: @escaping (inout SubtitleStyle) -> Void) -> some View {
        Button {
            var style = player.subtitleStyle
            change(&style)
            player.setSubtitleStyle(style)
            onPick()
        } label: {
            Label(title, systemImage: selected ? "checkmark" : "")
        }
    }

    /// "+0.5 s" / "−1.0 s" / "0 s".
    static func delayLabel(_ ms: Int) -> String {
        if ms == 0 { return "0 s" }
        let value = String(format: "%.1f s", Double(abs(ms)) / 1000)
        return (ms > 0 ? "+" : "\u{2212}") + value
    }
}
