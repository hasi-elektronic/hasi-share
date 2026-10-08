import AVFoundation
import IPTVCore
import IPTVKit
import SwiftUI

/// Settings → Advanced → "Calibrate audio sync" (Build 16, docs/SCREENS.md §3.9): the bundled test clip
/// (`avsync-test.mkv`, `scripts/make-avsync-clip.py`: a white flash + a 1 kHz 40 ms beep every second at the
/// same presentation time) loops through **VLCKit** while the user moves the per-device VLC calibration
/// (−500…+500 ms, 10 ms steps, applied live) until beep and flash coincide; "Save" stores it
/// (`PlayerController.setVLCCalibration`). "Reference (Apple)" plays the same clip as MP4 through AVPlayer
/// (no calibration) for comparison. Also opened from the player's Sync panel (the player is released meanwhile).
struct AVSyncCalibrationView: View {
    @Environment(AppEnvironment.self) private var env
    /// Shown over the player (Sync panel): a close button, Save closes.
    var onClose: (() -> Void)?
    @State private var model = AVSyncCalibrationModel()
    @State private var value = 0
    @State private var savedValue = 0
    @State private var savedNotice = false
    @State private var noticeTask: Task<Void, Never>?
    #if os(tvOS)
    @FocusState private var stepperFocused: Bool
    #endif

    var body: some View {
        content
            .screenBackground()
            .navigationTitle(L10n.t("avsync_calibrate"))
            .onAppear {
                value = env.player.vlcCalibrationMs
                savedValue = value
                model.start(calibration: value)
                #if os(tvOS)
                Task { @MainActor in stepperFocused = true }
                #endif
            }
            .onDisappear {
                noticeTask?.cancel()
                model.stop()
            }
            #if os(tvOS)
            .onExitCommand { onClose?() }   // over the player: Menu closes (in Settings the stack pops)
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("avsync_calibration")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.isTV ? 28 : 14) {
                if let onClose {
                    HStack {
                        Text(L10n.t("avsync_calibrate")).font(Theme.title)
                        Spacer()
                        Button(L10n.t("action_close"), action: onClose)
                            #if os(tvOS)
                            .buttonStyle(SecondaryButtonStyle())
                            #endif
                            .accessibilityIdentifier("avsync_close")
                    }
                }
                video
                Text(L10n.t("avsync_intro"))
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(tvOS)
                AudioDelayControl(title: L10n.t("avsync_calibration_value"), value: value, identifier: "avsync_value",
                                  focus: $stepperFocused, range: AudioDelayStore.calibrationRange,
                                  stepMs: AudioDelayStore.calibrationStep) { set($0) }
                #else
                AudioDelayControl(title: L10n.t("avsync_calibration_value"), value: value, identifier: "avsync_value",
                                  range: AudioDelayStore.calibrationRange, stepMs: AudioDelayStore.calibrationStep) { set($0) }
                #endif
                Text(L10n.t("avsync_calibration_hint"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .padding(.horizontal, Theme.isTV ? Theme.safeH : 16)
            .padding(.vertical, Theme.isTV ? Theme.safeV : 12)
            .frame(maxWidth: Theme.isTV ? .infinity : 700)
        }
    }

    private var video: some View {
        ZStack(alignment: .topLeading) {
            EngineVideoSurface(engine: model.engine, aspect: .fit)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: Theme.isTV ? 1100 : .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 16 : 10))
                .accessibilityHidden(true)
            Text(model.mode == .vlc ? "VLCKit" : "AVPlayer")
                .font(Theme.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(10)
                .accessibilityLabel(model.mode == .vlc ? "VLCKit" : "AVPlayer")
                .accessibilityValue(model.isPlaying ? "playing" : "loading")
                .accessibilityIdentifier("avsync_engine")
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        HStack(spacing: Theme.isTV ? 28 : 12) {
            Button {
                model.switchMode(model.mode == .vlc ? .apple : .vlc, calibration: value)
            } label: {
                Label(L10n.t(model.mode == .vlc ? "avsync_reference_apple" : "avsync_test_vlc"),
                      systemImage: model.mode == .vlc ? "applelogo" : "play.rectangle")
            }
            #if os(tvOS)
            .buttonStyle(SecondaryButtonStyle())
            #else
            .buttonStyle(.bordered)
            #endif
            .accessibilityIdentifier("avsync_reference")
            Button { save() } label: { Label(L10n.t("action_save"), systemImage: "checkmark") }
                #if os(tvOS)
                .buttonStyle(PrimaryButtonStyle())
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .accessibilityIdentifier("avsync_save")
            if savedNotice {
                Text(L10n.t("avsync_saved", AudioDelayControl.shortLabel(savedValue)))
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("avsync_saved")
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: savedNotice)
    }

    private func set(_ ms: Int) {
        value = AudioDelayStore.normalizeCalibration(ms)
        model.apply(calibration: value)
    }

    private func save() {
        env.player.setVLCCalibration(value)
        savedValue = env.player.vlcCalibrationMs
        AccessibilityNotification.Announcement(L10n.t("avsync_saved", AudioDelayControl.shortLabel(savedValue))).post()
        savedNotice = true
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            savedNotice = false
        }
    }
}

/// Settings row (top level + Advanced): "Calibrate audio sync" with the current VLC calibration.
struct AVSyncCalibrationRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationLink(value: SettingsRoute.avSyncCalibration) {
            HStack {
                Text(L10n.t("avsync_calibrate"))
                Spacer()
                Text(AudioDelayControl.shortLabel(env.player.vlcCalibrationMs))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("settings_avsync_calibration")
    }
}

/// Plays the calibration clip: VLCKit (looping, with the calibration as its audio delay) or the AVPlayer
/// reference (no delay, restarted at the end). Engines of its own – the app's player is not involved.
@MainActor
@Observable
final class AVSyncCalibrationModel {
    enum Mode { case vlc, apple }

    private(set) var mode: Mode = .vlc
    private(set) var engine: (any PlaybackEngine)?
    private(set) var isPlaying = false
    @ObservationIgnored private var running = false

    static let clipName = "avsync-test"

    static func clipURL(_ ext: String) -> URL? { Bundle.main.url(forResource: clipName, withExtension: ext) }

    func start(calibration: Int) {
        guard !running else { return }
        running = true
        AudioSessionConfigurator.activate()
        play(calibration: calibration)
    }

    func stop() {
        running = false
        engine?.stop()
        engine = nil
        isPlaying = false
        AudioSessionConfigurator.deactivate()
    }

    func switchMode(_ mode: Mode, calibration: Int) {
        guard mode != self.mode else { return }
        engine?.stop()
        self.mode = mode
        play(calibration: calibration)
    }

    /// Live: VLCKit applies it to the running input (+ its automatic output-latency term, as in playback).
    func apply(calibration: Int) {
        guard mode == .vlc else { return }
        engine?.setAudioDelay(ms: calibration)
    }

    private func play(calibration: Int) {
        isPlaying = false
        let ext = mode == .vlc ? "mkv" : "mp4"
        guard let url = Self.clipURL(ext) else {
            SafeLog.error("avsync clip missing: \(ext)")
            return
        }
        let next: any PlaybackEngine
        switch mode {
        case .vlc:
            #if canImport(MobileVLCKit) || canImport(TVVLCKit)
            let vlc = VLCPlaybackEngine()
            vlc.loops = true
            next = vlc
            #else
            next = AVPlayerEngine()
            #endif
        case .apple:
            next = AVPlayerEngine()
        }
        next.onEvent = { [weak self, weak next] event in
            guard let self, let next, self.engine === next else { return }
            switch event {
            case .playing: self.isPlaying = true
            case .ended:
                // AVPlayer reference (VLCKit loops by itself): from the start again.
                next.seek(to: 0)
                next.play()
            default: break
            }
        }
        engine = next
        next.setAudioDelay(ms: mode == .vlc ? calibration : 0)
        let container: StreamContainer = mode == .vlc ? .mkv : .mp4
        next.load(ResolvedStream(url: url, container: container, headers: [:], engine: mode == .vlc ? .vlcKit : .avPlayer),
                  isLive: false, startMs: nil, preferredAudioLanguage: nil, preferredSubtitleLanguage: nil,
                  tuning: LiveStartTuning.make(isLive: false, largeBuffer: false))
    }
}
