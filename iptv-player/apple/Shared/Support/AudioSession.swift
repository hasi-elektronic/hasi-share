import AVFoundation
import IPTVKit

/// App audio session (docs/ARCHITECTURE.md §3.2): `.playback` / `.moviePlayback` so video plays with the
/// iPhone's silent switch on. Build 17 (iOS): `UIBackgroundModes` audio – the session stays active in the background
/// while background audio / Picture in Picture keep the player (`BackgroundPlayback`).
enum AudioSessionConfigurator {
    /// App launch: category only (activation waits for the first playback).
    static func configure() {
        apply { try $0.setCategory(.playback, mode: .moviePlayback, options: []) }
    }

    /// Playback starts / resumes. The category is re-applied first: VLCKit's audio output may have changed it.
    static func activate() {
        apply {
            if $0.category != .playback || $0.mode != .moviePlayback {
                try $0.setCategory(.playback, mode: .moviePlayback, options: [])
            }
            try $0.setActive(true)
        }
    }

    /// Player released / closed: other apps (music) may resume.
    static func deactivate() {
        apply { try $0.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    static var hooks: AudioSessionHooks { AudioSessionHooks(activate: { activate() }, deactivate: { deactivate() }) }

    private static func apply(_ change: (AVAudioSession) throws -> Void) {
        do { try change(AVAudioSession.sharedInstance()) } catch { SafeLog.warning("audio session: \(error)") }
    }
}

/// Forwards `AVAudioSession` interruption / route-change notifications to the player controller
/// (pause on interruption began or headphones unplugged, resume when the system says so).
@MainActor
final class AudioSessionObserver {
    private var tokens: [NSObjectProtocol] = []

    func start(player: PlayerController) {
        // `AudioSessionEvent` parses raw values (IPTVKit is unit-tested on macOS); they must match the SDK's.
        assert(AVAudioSession.InterruptionType.began.rawValue == 1 && AVAudioSession.InterruptionType.ended.rawValue == 0
               && AVAudioSession.InterruptionOptions.shouldResume.rawValue == 1
               && AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue == 2)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let event = Self.event(for: note) else { return }
            MainActor.assumeIsolated { player.handleAudioInterruption(event) }
        })
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let event = Self.event(for: note) else { return }
            MainActor.assumeIsolated { player.handleAudioInterruption(event) }
        })
    }

    nonisolated static func event(for note: Notification) -> AudioSessionEvent? {
        let info = note.userInfo
        switch note.name {
        case AVAudioSession.interruptionNotification:
            #if os(iOS)
            let reason = info?[AVAudioSessionInterruptionReasonKey] as? UInt
            #else
            let reason: UInt? = nil   // key unavailable on tvOS
            #endif
            return .interruption(typeRaw: info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                                 optionsRaw: info?[AVAudioSessionInterruptionOptionKey] as? UInt, reasonRaw: reason)
        case AVAudioSession.routeChangeNotification:
            return .routeChange(reasonRaw: info?[AVAudioSessionRouteChangeReasonKey] as? UInt)
        default: return nil
        }
    }
}
