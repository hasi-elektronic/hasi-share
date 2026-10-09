import Foundation

/// SwiftUI `ScenePhase` without SwiftUI (IPTVKit is UI-free).
public enum AppScenePhase: Sendable {
    case active, inactive, background
}

extension AppEnvironment {
    /// B4 (Build 16): the player is released only when the app really leaves the screen (`.background`,
    /// SCREENS §3.7 "ekran kapanınca / arka plana geçince"). `.inactive` – Control Center, the notification shade,
    /// a call banner, Siri, iPad Slide Over, tvOS Control Center – keeps it playing: releasing there restarted
    /// live and could hit `max_connections = 1`. Real audio interruptions (a call taking the audio) still pause
    /// through `AudioSessionObserver` → `PlayerController.handleAudioInterruption`.
    ///
    /// Build 17 (iOS): `.background` asks `PlayerController.enterBackground()` first – Picture in Picture or background
    /// audio keep the player (only the deferred writes / mirror are flushed); otherwise the release above.
    public func scenePhaseChanged(_ phase: AppScenePhase) {
        switch phase {
        case .active:
            player.enterForeground()
            scenePhaseChanged(isActive: true)
        case .background:
            if player.enterBackground() == .keepPlaying {
                flushDeferredWrites()
            } else {
                scenePhaseChanged(isActive: false)
            }
        case .inactive: break
        }
    }
}
