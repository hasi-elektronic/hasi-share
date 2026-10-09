import Foundation
import IPTVCore
import IPTVKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Lock screen, Control Center, headphones, the Siri Remote's system controls and the tvOS Now Playing app
/// (Build 17, docs/SCREENS.md §3.7): `MPNowPlayingInfoCenter` from `NowPlayingMapper` (title, channel / series,
/// episode, artwork, live flag, VOD duration + elapsed + rate) and `MPRemoteCommandCenter` routed through
/// `PlayerController.handleRemoteCommand` – one manual path for AVPlayer, remux and VLCKit.
@MainActor
final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()

    private weak var env: AppEnvironment?
    private var installed = false
    /// Artwork of the current item (loaded once per URL).
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    /// Live: the programme title is re-read every minute (EPG boundaries).
    private var programmeTask: Task<Void, Never>?

    func install(env: AppEnvironment) {
        self.env = env
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(handler: Self.handler { _ in .play })
        center.pauseCommand.addTarget(handler: Self.handler { _ in .pause })
        center.togglePlayPauseCommand.addTarget(handler: Self.handler { _ in .togglePlayPause })
        center.skipForwardCommand.preferredIntervals = PlayerController.remoteSkipIntervals
        center.skipBackwardCommand.preferredIntervals = PlayerController.remoteSkipIntervals
        center.skipForwardCommand.addTarget(handler: Self.handler { event in
            .skipForward(seconds: (event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
        })
        center.skipBackwardCommand.addTarget(handler: Self.handler { event in
            .skipBackward(seconds: (event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
        })
        center.changePlaybackPositionCommand.addTarget(handler: Self.handler { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .changePosition(seconds: $0.positionTime) }
        })
        center.nextTrackCommand.addTarget(handler: Self.handler { _ in .nextChannel })
        center.previousTrackCommand.addTarget(handler: Self.handler { _ in .previousChannel })
        update()
    }

    /// `MPRemoteCommandCenter` calls its handlers on the main thread; anything else is hopped there.
    private nonisolated static func handler(_ command: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteCommand?)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let command = command(event) else { return .commandFailed }
            guard Thread.isMainThread else {
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = shared.route(command) } }
                return .success
            }
            return MainActor.assumeIsolated { shared.route(command) }
        }
    }

    private func route(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard let player = env?.player else { return .noActionableNowPlayingItem }
        guard player.request != nil else { return .noActionableNowPlayingItem }
        SafeLog.debug("remote command \(command)")
        return player.handleRemoteCommand(command) ? .success : .commandFailed
    }

    /// Player changed (`PlayerController.onPlaybackChange`): info + enabled commands.
    func update() {
        guard let env else { return }
        let player = env.player
        let available = player.remoteCommandAvailability
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = available.playPause
        center.pauseCommand.isEnabled = available.playPause
        center.togglePlayPauseCommand.isEnabled = available.playPause
        center.skipForwardCommand.isEnabled = available.skip
        center.skipBackwardCommand.isEnabled = available.skip
        center.changePlaybackPositionCommand.isEnabled = available.changePosition
        center.nextTrackCommand.isEnabled = available.channelSwitch
        center.previousTrackCommand.isEnabled = available.channelSwitch

        guard let meta = NowPlayingMapper.metadata(request: player.request, phase: player.phase, currentTime: player.currentTime,
                                                   duration: player.duration, programmeTitle: programmeTitle(),
                                                   movieTitle: { MediaTags.clean($0).title },
                                                   episodeLabel: { L10n.t("episode_short", String($0.season), String($0.number)) }) else {
            clear()
            return
        }
        var info = meta.nowPlayingInfo
        if let artwork, artworkURL == meta.artworkURL { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtworkIfNeeded(meta.artworkURL)
        scheduleProgrammeRefresh(live: meta.isLive)
    }

    private func clear() {
        artworkTask?.cancel()
        programmeTask?.cancel()
        programmeTask = nil
        artworkURL = nil
        artwork = nil
        if MPNowPlayingInfoCenter.default().nowPlayingInfo != nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    /// Programme on air of the playing channel (EPG), nil without one.
    private func programmeTitle() -> String? {
        guard let env, let channel = env.player.currentChannel, let epgId = channel.epgId else { return nil }
        return (try? env.epg.nowNext(sourceId: channel.sourceId, epgIds: [epgId], at: Date()))?[epgId.lowercased()]?.now?.title
    }

    private func loadArtworkIfNeeded(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkTask?.cancel()
        artworkURL = url
        artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let cg = await ImageLoader.shared.image(for: url, maxPixel: 600), !Task.isCancelled else { return }
            let artwork = Self.artwork(cg)
            guard let self, self.artworkURL == url else { return }
            self.artwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            guard !info.isEmpty else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// MediaPlayer calls the request handler on its own queue: built outside the main actor (no isolation check).
    private nonisolated static func artwork(_ cg: CGImage) -> MPMediaItemArtwork {
        let image = UIImage(cgImage: cg)
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func scheduleProgrammeRefresh(live: Bool) {
        guard live else {
            programmeTask?.cancel()
            programmeTask = nil
            return
        }
        guard programmeTask == nil else { return }
        programmeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.programmeTask = nil   // `update` schedules the next round while the item is live
            self.update()
        }
    }
}
