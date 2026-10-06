import AVFoundation
import IPTVKit

/// App audio session (docs/ARCHITECTURE.md §3.2): `.playback` / `.moviePlayback` so video plays with the
/// iPhone's silent switch on. Background audio stays off (V10): no `UIBackgroundModes`, the player is
/// released when the scene leaves `.active`.
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
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        switch note.name {
        case AVAudioSession.interruptionNotification:
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began?:
                // "App was suspended" (raw 1; the named constant is deprecated) = the system took audio from a
                // backgrounded app – nothing was playing for the user.
                #if os(iOS)
                if (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) == 1 { return nil }
                #endif
                return .began
            case .ended?:
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
                return .ended(shouldResume: options?.contains(.shouldResume) == true)
            default: return nil
            }
        case AVAudioSession.routeChangeNotification:
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            return reason == .oldDeviceUnavailable ? .routeLost : nil
        default: return nil
        }
    }
}
