import IPTVKit
import SwiftUI

/// Audio delay control (docs/SCREENS.md §3.7, Settings → Playback): −2000…+2000 ms in 50 ms steps,
/// value with its direction ("+150 ms · audio later"); every change is applied live through `onChange`.
/// iOS: slider plus −/+ 50 ms buttons (one line in compact height). tvOS: ONE focusable row (Form
/// rule) – ◀▶ on the remote change the value, repeated/held presses accelerate 50 → 100 → 250 ms.
struct AudioDelayControl: View {
    let title: String
    let value: Int
    /// Base accessibility identifier (iOS adds `_minus`, `_plus`, `_value`).
    let identifier: String
    #if os(tvOS)
    /// tvOS: focus driven by the container (player Sync panel); nil = the row's own focus state.
    var focus: FocusState<Bool>.Binding?
    /// tvOS: ▲ (−1) / ▼ (+1) handled by the container. In the player an ancestor `onMoveCommand`
    /// swallows unhandled moves, so the panel moves the focus itself; nil = focus engine (Settings).
    var onVerticalMove: ((Int) -> Void)?
    #endif
    let onChange: (Int) -> Void
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// "+150 ms" / "-50 ms" / "0 ms".
    static func shortLabel(_ ms: Int) -> String { ms > 0 ? "+\(ms) ms" : "\(ms) ms" }

    /// "+150 ms · audio later" / "-100 ms · audio earlier" / "0 ms" (positive = audio later).
    static func label(_ ms: Int) -> String {
        if ms > 0 { return L10n.t("audio_delay_later", shortLabel(ms)) }
        if ms < 0 { return L10n.t("audio_delay_earlier", shortLabel(ms)) }
        return shortLabel(ms)
    }

    private func set(_ delta: Int) {
        let range = AudioDelayStore.range
        onChange(min(range.upperBound, max(range.lowerBound, value + delta)))
    }

    var body: some View {
        #if os(tvOS)
        TVAudioDelayStepper(title: title, value: value, identifier: identifier, externalFocus: focus,
                            onVerticalMove: onVerticalMove, step: set)
        #else
        if verticalSizeClass == .compact {
            // Landscape iPhone: one line per control when it fits (the slider keeps ≥ 140 pt),
            // else the two-line layout – e.g. 667 pt wide phones.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(minWidth: 130, maxWidth: 200, alignment: .leading)
                    stepButton("minus", delta: -AudioDelayStore.step, id: "\(identifier)_minus")
                    slider.frame(minWidth: 140)
                    stepButton("plus", delta: AudioDelayStore.step, id: "\(identifier)_plus")
                    valueText.minimumScaleFactor(0.8).frame(minWidth: 150, maxWidth: 190, alignment: .trailing)
                }
                twoLines
            }
            .font(.subheadline)
        } else {
            twoLines
        }
        #endif
    }

    #if os(iOS)
    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                valueText
            }
            HStack(spacing: 12) {
                stepButton("minus", delta: -AudioDelayStore.step, id: "\(identifier)_minus")
                slider
                stepButton("plus", delta: AudioDelayStore.step, id: "\(identifier)_plus")
            }
        }
    }
    #endif

    #if os(iOS)
    private var valueText: some View {
        Text(Self.label(value))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("\(identifier)_value")
    }

    private var slider: some View {
        Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
               in: Double(AudioDelayStore.range.lowerBound)...Double(AudioDelayStore.range.upperBound),
               step: Double(AudioDelayStore.step))
            .accessibilityLabel(title)
            .accessibilityValue(Self.label(value))
            .accessibilityIdentifier(identifier)
    }

    private func stepButton(_ symbol: String, delta: Int, id: String) -> some View {
        Button { set(delta) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.shortLabel(delta))
        .accessibilityIdentifier(id)
    }
    #endif
}

#if os(tvOS)
/// One focusable row: title, ‹ value ›; ◀▶ adjust (live preview while the user listens). Presses less
/// than 0.4 s apart in the same direction form a run that accelerates (`AudioDelayStore.stepSize`);
/// a held ◀▶ (no `onMoveCommand` repeat on tvOS) steps every 0.3 s via `TVHoldSeek` – 100 ms, 250 ms
/// once held for 1.5 s.
private struct TVAudioDelayStepper: View {
    let title: String
    let value: Int
    let identifier: String
    let externalFocus: FocusState<Bool>.Binding?
    let onVerticalMove: ((Int) -> Void)?
    let step: (Int) -> Void
    @FocusState private var ownFocus: Bool
    private var focused: Bool { externalFocus?.wrappedValue ?? ownFocus }
    @State private var run: (direction: Int, count: Int, at: Date)?

    private func move(_ direction: Int) {
        let now = Date()
        var count = 0
        if let run, run.direction == direction, now.timeIntervalSince(run.at) < 0.4 { count = run.count + 1 }
        run = (direction, count, now)
        step(direction * AudioDelayStore.stepSize(repeatCount: count))
    }

    var body: some View {
        HStack(spacing: 24) {
            Text(title).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.left").opacity(focused ? 1 : 0.4)
            Text(AudioDelayControl.label(value))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 360)
            Image(systemName: "chevron.right").opacity(focused ? 1 : 0.4)
        }
        .font(Theme.body)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .foregroundStyle(focused ? Color.black : Theme.textPrimary)
        .background(RoundedRectangle(cornerRadius: 12).fill(focused ? Color.white : Theme.surfaceElevated))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
        .background {
            if focused {
                TVHoldSeek { direction, heldMs in step(direction * (heldMs < 1500 ? 100 : 250)) }
            }
        }
        .focusable()
        .focused(externalFocus ?? $ownFocus)
        .onMoveCommand { direction in
            switch direction {
            case .left: move(-1)
            case .right: move(1)
            case .up: onVerticalMove?(-1)
            case .down: onVerticalMove?(1)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(AudioDelayControl.label(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(AudioDelayStore.step)
            case .decrement: step(-AudioDelayStore.step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif

/// Player → Audio → Sync (docs/SCREENS.md §3.7): a non-modal panel at the bottom – the picture keeps
/// playing above it – with this content's delay and the device (TV/soundbar) delay, both applied live.
/// Notes: AVPlayer → "a delay plays through VLC"; VLCKit failed → "sync could not be applied".
struct AudioSyncPanel: View {
    let player: PlayerController
    let onClose: () -> Void
    #if os(tvOS)
    @FocusState private var contentFocused: Bool
    @FocusState private var deviceFocused: Bool
    #endif
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var maxWidth: CGFloat { verticalSizeClass == .compact ? 820 : 640 }
    #else
    private let maxWidth: CGFloat = 1300
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 20 : 8) {
            HStack {
                Text(L10n.t("audio_sync")).font(Theme.headline)
                Spacer()
                #if os(iOS)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2).frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(L10n.t("action_close"))
                .accessibilityIdentifier("audio_sync_close")
                #endif
            }
            #if os(tvOS)
            AudioDelayControl(title: L10n.t("audio_sync_content"), value: player.contentAudioDelay,
                              identifier: "player_audio_sync_delay", focus: $contentFocused,
                              onVerticalMove: { if $0 > 0 { deviceFocused = true } }) { player.setAudioDelay($0) }
            AudioDelayControl(title: L10n.t("settings_device_audio_delay"), value: player.deviceAudioDelay,
                              identifier: "player_device_audio_delay", focus: $deviceFocused,
                              onVerticalMove: { if $0 < 0 { contentFocused = true } }) { player.setDeviceAudioDelay($0) }
            #else
            AudioDelayControl(title: L10n.t("audio_sync_content"), value: player.contentAudioDelay,
                              identifier: "player_audio_sync_delay") { player.setAudioDelay($0) }
            AudioDelayControl(title: L10n.t("settings_device_audio_delay"), value: player.deviceAudioDelay,
                              identifier: "player_device_audio_delay") { player.setDeviceAudioDelay($0) }
            #endif
            Text(L10n.t("audio_sync_hint"))
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            if player.audioSyncUnavailable {
                Text(L10n.t("audio_sync_unavailable"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("audio_sync_unavailable")
            } else if player.engineKind == .avPlayer {
                Text(L10n.t("audio_sync_vlc_note"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("audio_sync_vlc_note")
            }
        }
        .padding(.horizontal, Theme.isTV ? 48 : 20)
        .padding(.vertical, Theme.isTV ? 32 : 12)
        .frame(maxWidth: maxWidth)
        .background(RoundedRectangle(cornerRadius: Theme.isTV ? 24 : 16).fill(Theme.surface.opacity(0.92)))
        .padding(.horizontal, Theme.safeH)
        .padding(.bottom, Theme.isTV ? Theme.safeV : 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio_sync_panel")
        #if os(tvOS)
        // After the panel is in the hierarchy (the overlay it replaces held the focus).
        .onAppear { Task { @MainActor in contentFocused = true } }
        #endif
    }
}
