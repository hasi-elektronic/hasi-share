#if os(iOS)
import AVFoundation
import AVKit
import IPTVCore
import IPTVKit
import Observation
import UIKit

/// Picture in Picture (Build 17, iOS/iPadOS, docs/SCREENS.md §3.7) for everything AVPlayer shows – the AVPlayer engine
/// and "Apple + Remux (Beta)" (AVPlayer underneath). VLCKit renders into its own GL view: no PiP there (the button is
/// hidden, Settings explains it).
///
/// * One `AVPictureInPictureController` bound to the app's single `AVPlayerLayer` (`PlayerVideoHost`).
/// * Button in the player tools: PiP starts and the player screen is dismissed (`Router.pipMinimized`) while playback
///   goes on – the app can be browsed; "restore" in the PiP window presents the player again.
/// * Automatic: `canStartPictureInPictureAutomaticallyFromInline` (Settings "Picture in Picture automatically") when
///   the app is left while a video plays; the player screen stays presented underneath.
/// * Closing the PiP window while the player screen is dismissed ends playback (`PlayerController.close()`); in the
///   background the controller applies `BackgroundPlayback` (`setPictureInPictureActive(false)`).
@MainActor
@Observable
final class PictureInPictureCoordinator: NSObject {
    static let shared = PictureInPictureCoordinator()

    /// PiP is starting or running.
    private(set) var isActive = false
    /// The current item can go into PiP now (AVPlayer content on screen).
    private(set) var isPossible = false

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var env: AppEnvironment?
    @ObservationIgnored private weak var router: Router?
    /// "Restore" was tapped: the stop that follows must not close the player.
    @ObservationIgnored private var restoring = false

    /// Device / simulator supports PiP at all (after `activate()`).
    private(set) var isSupported = false

    func install(env: AppEnvironment, router: Router) {
        self.env = env
        self.router = router
    }

    /// The shared layer got another AVPlayer (first item, AVPlayer ↔ remux engine): AVKit does not follow a player that
    /// is set on the layer after the controller was created (stays "not possible") – rebuild it while PiP is not running.
    func layerPlayerChanged() {
        guard controller != nil, !isActive else { return activate() }
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        isPossible = false
        activate()
    }

    /// Creates the controller once the app runs and the layer has its AVPlayer (at `App.init` AVKit still reports PiP
    /// as unsupported).
    func activate() {
        guard controller == nil, env != nil, PlayerVideoHost.shared.playerLayer.player != nil else { return }
        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        guard supported, let pip = AVPictureInPictureController(playerLayer: PlayerVideoHost.shared.playerLayer) else {
            SafeLog.info("pip unavailable (supported: \(supported))")
            return
        }
        pip.delegate = self
        controller = pip
        isSupported = true
        possibleObservation = Self.observePossible(pip) { [weak self] possible in self?.isPossible = possible }
        refreshAutomaticStart()
    }

    /// KVO may fire off the main thread: the handler is built outside the main actor and hops back.
    private nonisolated static func observePossible(_ pip: AVPictureInPictureController,
                                                    _ update: @escaping @MainActor @Sendable (Bool) -> Void) -> NSKeyValueObservation {
        pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in update(possible) }
        }
    }

    /// Settings toggle / launch.
    func refreshAutomaticStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = env?.player.preferences?.autoPictureInPicture ?? true
    }

    /// The PiP button is offered for this engine (AVPlayer or remux – never VLCKit).
    static func engineSupportsPiP(_ kind: PlayerEngine?) -> Bool {
        kind == .avPlayer || kind == .avRemux
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// Player state changed (`PlayerController.onPlaybackChange`): live hides PiP's skip buttons; no item / a VLCKit
    /// item ends PiP (the layer has nothing to show).
    func playbackChanged() {
        guard let env, let controller else { return }
        let player = env.player
        let live = player.request?.isLive ?? false
        if controller.requiresLinearPlayback != live { controller.requiresLinearPlayback = live }
        guard isActive else { return }
        if player.request == nil || !Self.engineSupportsPiP(player.engineKind) || player.phase == .idle {
            SafeLog.info("pip: item gone / not AVPlayer – stopping")
            controller.stopPictureInPicture()
        }
    }

    // MARK: Delegate events (main actor)

    fileprivate func willStart() {
        isActive = true
        env?.player.setPictureInPictureActive(true)
        // Started from the button (app on screen): free the app for browsing; the video keeps playing in the window.
        if UIApplication.shared.applicationState == .active { router?.minimizeForPictureInPicture() }
        SafeLog.info("pip started")
    }

    fileprivate func failedToStart() {
        isActive = false
        env?.player.setPictureInPictureActive(false)
        router?.restoreFromPictureInPicture()
        SafeLog.warning("pip failed to start")
    }

    fileprivate func restoreUserInterface(_ completion: @escaping @MainActor (Bool) -> Void) {
        restoring = true
        let wasPresented = router?.playerPresented ?? false
        router?.restoreFromPictureInPicture()
        guard !wasPresented else { return completion(true) }
        // The player screen is being presented: let the shared layer reach its window before AVKit animates into it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            completion(true)
        }
    }

    fileprivate func didStop() {
        isActive = false
        let restored = restoring
        restoring = false
        env?.player.setPictureInPictureActive(false)
        if !restored, router?.pipMinimized == true {
            // Closed from the PiP window while no player screen exists: the playback ends with it.
            SafeLog.info("pip closed – ending playback")
            router?.endMinimizedPlayback()
        }
        SafeLog.info("pip stopped")
    }
}

extension PictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { willStart() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated { failedToStart() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { didStop() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let box = CompletionBox(completionHandler)
        MainActor.assumeIsolated { restoreUserInterface { box.call($0) } }
    }
}

/// AVKit's completion handler (called once, on the main actor).
private final class CompletionBox: @unchecked Sendable {
    private let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    func call(_ value: Bool) { handler(value) }
}
#endif
