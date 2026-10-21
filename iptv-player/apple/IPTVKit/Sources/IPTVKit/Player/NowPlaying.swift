import Foundation
import IPTVCore
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Lock screen / Control Center / tvOS Now Playing data (Build 17, docs/SCREENS.md §3.7). One manual path for all
/// three engines (`NowPlayingCoordinator` in the app writes it to `MPNowPlayingInfoCenter`): AVPlayer's automatic
/// publishing (`MPNowPlayingSession`) would cover only the AVPlayer/remux items and switch sources mid-item on an
/// engine fallback; elapsed time + rate are enough for the system to extrapolate the position.
public struct NowPlayingMetadata: Equatable, Sendable {
    /// Live: the programme on air (else the channel); VOD: the movie / episode title.
    public var title: String
    /// Live: the channel (under the programme); episode: the series.
    public var artist: String?
    /// Episode: "S1 E2".
    public var albumTitle: String?
    public var isLive: Bool
    /// VOD with a known length.
    public var duration: Double?
    public var elapsed: Double?
    /// 1 while playing or about to (loading, buffering, reconnecting – the user's intent), 0 paused / ended.
    public var rate: Double
    /// Channel logo / poster.
    public var artworkURL: URL?

    public init(title: String, artist: String? = nil, albumTitle: String? = nil, isLive: Bool, duration: Double? = nil,
                elapsed: Double? = nil, rate: Double, artworkURL: URL? = nil) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.isLive = isLive
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.artworkURL = artworkURL
    }
}

public enum NowPlayingMapper {
    /// nil = nothing to show (no item, idle, locked).
    public static func metadata(request: PlaybackRequest?, phase: PlayerPhase, currentTime: Double, duration: Double,
                                programmeTitle: String? = nil, movieTitle: (String) -> String = { $0 },
                                episodeLabel: (Episode) -> String = { "S\($0.season) E\($0.number)" }) -> NowPlayingMetadata? {
        guard let request else { return nil }
        let rate: Double
        switch phase {
        case .idle, .locked: return nil
        case .playing, .loading, .buffering, .reconnecting: rate = 1
        case .paused, .ended, .failed: rate = 0
        }
        var meta: NowPlayingMetadata
        switch request.item {
        case .channel(let channel):
            let programme = programmeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let programme, !programme.isEmpty {
                meta = NowPlayingMetadata(title: programme, artist: channel.name, isLive: true, rate: rate)
            } else {
                meta = NowPlayingMetadata(title: channel.name, isLive: true, rate: rate)
            }
        case .movie(let movie):
            meta = NowPlayingMetadata(title: movieTitle(movie.name), isLive: false, rate: rate)
        case .episode(let episode, let seriesTitle):
            let label = episodeLabel(episode)
            let title = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
            meta = NowPlayingMetadata(title: title.isEmpty ? label : title, artist: seriesTitle.isEmpty ? nil : seriesTitle,
                                      albumTitle: label, isLive: false, rate: rate)
        case .url(_, let title):
            meta = NowPlayingMetadata(title: title, isLive: false, rate: rate)
        }
        if !meta.isLive {
            if duration > 0 { meta.duration = duration }
            meta.elapsed = phase == .ended && duration > 0 ? duration : max(0, currentTime)
        }
        meta.artworkURL = request.posterUrl.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return meta
    }
}

#if canImport(MediaPlayer)
extension NowPlayingMetadata {
    /// `MPNowPlayingInfoCenter.nowPlayingInfo` without the artwork (the app adds `MPMediaItemArtwork`).
    public var nowPlayingInfo: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let albumTitle { info[MPMediaItemPropertyAlbumTitle] = albumTitle }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        return info
    }
}
#endif

/// Commands from the lock screen, Control Center, headphones, the Siri Remote outside the app's own key handling and
/// the tvOS Now Playing app (`MPRemoteCommandCenter`, routed by the app's `NowPlayingCoordinator`).
public enum RemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipForward(seconds: Double)
    case skipBackward(seconds: Double)
    /// VOD scrubber on the lock screen.
    case changePosition(seconds: Double)
    /// Live: next / previous channel of the zapping list (`nextTrack` / `previousTrack`).
    case nextChannel
    case previousChannel
}

/// Which remote commands are enabled for the current item.
public struct RemoteCommandAvailability: Equatable, Sendable {
    public var playPause: Bool
    /// ±10/30 s (VOD).
    public var skip: Bool
    /// Lock-screen scrubbing (VOD with a known length).
    public var changePosition: Bool
    /// Next / previous channel (live with a zapping list).
    public var channelSwitch: Bool

    public static let none = RemoteCommandAvailability(playPause: false, skip: false, changePosition: false, channelSwitch: false)

    public init(playPause: Bool, skip: Bool, changePosition: Bool, channelSwitch: Bool) {
        self.playPause = playPause
        self.skip = skip
        self.changePosition = changePosition
        self.channelSwitch = channelSwitch
    }
}

extension PlayerController {
    /// Skip intervals offered to the system (the handlers use the interval the command carries).
    public static let remoteSkipIntervals: [NSNumber] = [10, 30]

    public var remoteCommandAvailability: RemoteCommandAvailability {
        guard let request else { return .none }
        switch phase {
        case .idle, .locked: return .none
        default: break
        }
        if request.isLive {
            return RemoteCommandAvailability(playPause: true, skip: false, changePosition: false, channelSwitch: request.channels.count > 1)
        }
        return RemoteCommandAvailability(playPause: true, skip: true, changePosition: duration > 0, channelSwitch: false)
    }

    /// Applies a remote command; false = not applicable now (the system shows it as failed / no item).
    @discardableResult
    public func handleRemoteCommand(_ command: RemoteCommand) -> Bool {
        let available = remoteCommandAvailability
        switch command {
        case .play:
            guard available.playPause else { return false }
            switch phase {
            case .paused, .ended: togglePlayPause()
            case .playing, .buffering, .loading, .reconnecting: break   // already (about to be) playing
            default: return false
            }
            return true
        case .pause:
            guard available.playPause else { return false }
            switch phase {
            case .playing, .buffering, .reconnecting: togglePlayPause()
            case .paused, .ended: break
            default: return false   // still opening: nothing to pause yet
            }
            return true
        case .togglePlayPause:
            guard available.playPause else { return false }
            switch phase {
            case .playing, .buffering, .reconnecting, .paused, .ended: togglePlayPause()
            default: return false
            }
            return true
        case .skipForward(let seconds):
            guard available.skip else { return false }
            seek(by: abs(seconds))
            return true
        case .skipBackward(let seconds):
            guard available.skip else { return false }
            seek(by: -abs(seconds))
            return true
        case .changePosition(let seconds):
            guard available.changePosition else { return false }
            seek(toSeconds: seconds)
            return true
        case .nextChannel:
            guard available.channelSwitch else { return false }
            zap(by: 1)
            return true
        case .previousChannel:
            guard available.channelSwitch else { return false }
            zap(by: -1)
            return true
        }
    }
}
