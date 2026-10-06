import IPTVKit
import SwiftUI

/// Audio delay control (docs/SCREENS.md §3.7, Settings → Playback): −2000…+2000 ms in 50 ms steps,
/// value shown as "+150 ms"; every change is applied live through `onChange`.
/// iOS: slider plus −/+ 50 ms buttons. tvOS: ONE focusable row (Form rule) – left/right on the
/// remote change the value by 50 ms.
struct AudioDelayControl: View {
    let title: String
    let value: Int
    /// Base accessibility identifier (iOS adds `_minus`, `_plus`, `_value`).
    let identifier: String
    let onChange: (Int) -> Void

    static func label(_ ms: Int) -> String { ms > 0 ? "+\(ms) ms" : "\(ms) ms" }

    private func step(_ delta: Int) {
        let range = AudioDelayStore.range
        onChange(min(range.upperBound, max(range.lowerBound, value + delta)))
    }

    var body: some View {
        #if os(tvOS)
        TVAudioDelayStepper(title: title, value: value, identifier: identifier, step: step)
        #else
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.label(value))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("\(identifier)_value")
            }
            HStack(spacing: 12) {
                stepButton("minus", delta: -AudioDelayStore.step, id: "\(identifier)_minus")
                Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                       in: Double(AudioDelayStore.range.lowerBound)...Double(AudioDelayStore.range.upperBound),
                       step: Double(AudioDelayStore.step))
                    .accessibilityLabel(title)
                    .accessibilityValue(Self.label(value))
                    .accessibilityIdentifier(identifier)
                stepButton("plus", delta: AudioDelayStore.step, id: "\(identifier)_plus")
            }
        }
        #endif
    }

    #if os(iOS)
    private func stepButton(_ symbol: String, delta: Int, id: String) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.label(delta))
        .accessibilityIdentifier(id)
    }
    #endif
}

#if os(tvOS)
/// One focusable row: title, ‹ value ›; left/right adjust (live preview while the user listens).
private struct TVAudioDelayStepper: View {
    let title: String
    let value: Int
    let identifier: String
    let step: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 24) {
            Text(title)
            Spacer()
            Image(systemName: "chevron.left").opacity(focused ? 1 : 0.4)
            Text(AudioDelayControl.label(value))
                .monospacedDigit()
                .frame(minWidth: 180)
            Image(systemName: "chevron.right").opacity(focused ? 1 : 0.4)
        }
        .font(Theme.body)
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .foregroundStyle(focused ? Color.black : Theme.textPrimary)
        .background(RoundedRectangle(cornerRadius: 12).fill(focused ? Color.white : Theme.surfaceElevated))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-AudioDelayStore.step)
            case .right: step(AudioDelayStore.step)
            default: break
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

/// Player → Audio → Sync (docs/SCREENS.md §3.7): the current content's delay, applied live while
/// the picture keeps playing behind the panel. On AVPlayer a note says a delay switches to VLC.
struct AudioSyncPanel: View {
    let player: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.isTV ? 32 : 16) {
            AudioDelayControl(title: L10n.t("audio_sync"), value: player.contentAudioDelay,
                              identifier: "player_audio_sync_delay") { player.setAudioDelay($0) }
            Text(L10n.t("audio_sync_hint"))
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
            if player.engineKind == .avPlayer {
                Text(L10n.t("audio_sync_vlc_note"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("audio_sync_vlc_note")
            }
            #if os(iOS)
            Button(L10n.t("action_close")) { dismiss() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("audio_sync_close")
            #endif
        }
        .padding(Theme.isTV ? 64 : 24)
        #if os(iOS)
        .presentationDetents([.height(300)])
        .presentationBackgroundInteraction(.enabled)
        #endif
    }
}
