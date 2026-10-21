import Foundation

/// Background playback (Build 17, iOS/iPadOS, docs/SCREENS.md §3.7, ARCHITECTURE §3.2): what happens to the player
/// when the app leaves the screen (`.background` – Home, app switcher, screen lock).
///
/// * Picture in Picture runs (or is starting) → keep playing, whatever the phase (the PiP window shows it).
/// * "Keep playing in the background" on and the player plays (or is about to: loading, buffering, reconnecting)
///   → keep playing as sound (VLCKit: video track off, AVPlayer: `audiovisualBackgroundPlaybackPolicy`).
/// * Otherwise – setting off, paused, ended, failed, or a platform without background audio (tvOS) → the existing
///   release (B4: position saved, connection freed, `resumeAfterRelease` on return).
///
/// While in the background: PiP closed without background audio (or paused) → release; the sleep timer firing →
/// release (nobody is watching, the connection is freed); a pause from the lock screen keeps the item so Play there
/// resumes it (iOS suspends the app soon after; Now Playing stays until then).
public enum BackgroundPlayback {
    public enum Decision: Equatable, Sendable {
        case keepPlaying
        case release
    }

    /// - Parameters:
    ///   - supported: the platform plays in the background (`UIBackgroundModes` audio – the iOS app only).
    ///   - audioEnabled: Settings "Keep playing in the background".
    ///   - pictureInPicture: PiP is running or starting.
    public static func decision(supported: Bool, audioEnabled: Bool, pictureInPicture: Bool, phase: PlayerPhase) -> Decision {
        guard supported else { return .release }
        if pictureInPicture { return .keepPlaying }
        guard audioEnabled else { return .release }
        switch phase {
        case .playing, .buffering, .loading, .reconnecting: return .keepPlaying
        case .idle, .paused, .ended, .failed, .locked: return .release
        }
    }
}
