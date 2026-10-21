#if os(iOS)
import AVFoundation
import AVKit
import IPTVCore
import IPTVKit
import Observation
import SwiftUI
import UIKit

/// Player tools (iOS, Build 17): Picture in Picture and AirPlay, docs/SCREENS.md §3.7.

/// PiP button: only for AVPlayer content (AVPlayer engine, "Apple + Remux (Beta)"); VLCKit items have no PiP.
struct PictureInPictureButton: View {
    let engine: PlayerEngine?
    let action: () -> Void
    private var pip: PictureInPictureCoordinator { .shared }

    var body: some View {
        if pip.isSupported, PictureInPictureCoordinator.engineSupportsPiP(engine) {
            Button(action: action) {
                Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .disabled(!pip.isPossible && !pip.isActive)
            .accessibilityLabel(L10n.t("player_pip"))
            .accessibilityIdentifier("player_pip")
        }
    }
}

/// AirPlay route picker (`AVRoutePickerView`, video devices first). AVPlayer content streams to the receiver (AirPlay
/// video); VLCKit and remux items send only the sound (libVLC renders itself; the remux URL is a loopback address the
/// receiver cannot reach) – `AirPlayRouteMonitor` shows a short notice then.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Theme.primary)
        picker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 36),
            picker.heightAnchor.constraint(equalToConstant: 36),
        ])
        container.accessibilityIdentifier = "player_airplay"
        picker.accessibilityLabel = L10n.t("player_airplay")
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Whether the audio currently goes to an AirPlay receiver (route changes of the shared audio session).
@MainActor
@Observable
final class AirPlayRouteMonitor {
    static let shared = AirPlayRouteMonitor()

    private(set) var isAirPlayActive = false
    @ObservationIgnored private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        refresh()
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let active = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        if active != isAirPlayActive { isAirPlayActive = active }
    }

    /// AirPlay carries only the sound of this engine (VLCKit, remux).
    static func isAudioOnly(_ engine: PlayerEngine?) -> Bool {
        engine == .vlcKit || engine == .avRemux
    }
}

/// Settings (top level, iOS): background audio and automatic PiP (device-local `PlayerPreferences`).
struct BackgroundPlaybackSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let prefs = env.player.preferences {
            @Bindable var prefs = prefs
            Toggle(L10n.t("settings_background_playback"), isOn: $prefs.backgroundAudio)
                .accessibilityIdentifier("settings_background_playback")
                .onChange(of: prefs.backgroundAudio) { env.player.refreshBackgroundPlayback() }
            if AVPictureInPictureController.isPictureInPictureSupported() {
                Toggle(L10n.t("settings_auto_pip"), isOn: $prefs.autoPictureInPicture)
                    .accessibilityIdentifier("settings_auto_pip")
                    .onChange(of: prefs.autoPictureInPicture) { PictureInPictureCoordinator.shared.refreshAutomaticStart() }
            }
        }
    }
}
#endif
