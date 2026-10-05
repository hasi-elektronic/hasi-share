#if canImport(AVFoundation)
import AVFoundation
import Foundation
import IPTVCore

/// AVPlayer engine: HLS, MP4/MOV and unknown containers (CONTRACT §6.1). A single `AVPlayer`
/// is reused across items; audio/subtitles via `AVMediaSelectionGroup`, aspect via the
/// `AVPlayerLayer.videoGravity` the view applies (`aspect`).
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public let player = AVPlayer()
    public let kind: PlayerEngine = .avPlayer
    public var onEvent: (@MainActor (EngineEvent) -> Void)?
    /// Current aspect mode (read by the video surface).
    public private(set) var aspect: AspectMode = .fit

    private var observers: [NSObjectProtocol] = []
    private var playerKVO: NSKeyValueObservation?
    private var itemKVO: NSKeyValueObservation?
    private var timeObserver: Any?
    private var mediaGroups: (audio: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?) = (nil, nil)
    private var optionsTask: Task<Void, Never>?

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        #if !os(macOS)
        player.preventsDisplaySleepDuringVideoPlayback = true
        #endif
        playerKVO = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                let seconds = time.seconds
                if seconds.isFinite { self?.onEvent?(.time(seconds)) }
            }
        }
    }

    public var isPlaying: Bool { player.timeControlStatus == .playing }

    public func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?, preferredSubtitleLanguage: String?) {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = isLive ? 2 : 0
        attach(item, container: stream.container)
        player.replaceCurrentItem(with: item)
        if let startMs, startMs > 0 {
            player.seek(to: CMTime(value: startMs, timescale: 1000))
        }
        player.play()
        loadMediaOptions(asset: asset, audio: preferredAudioLanguage, subtitle: preferredSubtitleLanguage)
    }

    private func attach(_ item: AVPlayerItem, container: StreamContainer) {
        removeItemObservers()
        itemKVO = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged(container: container) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            MainActor.assumeIsolated {
                self?.onEvent?(.failed(error.map { PlaybackErrorMapper.map($0, container: container) } ?? .network(.other)))
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.stalled) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.ended) }
        })
    }

    private func removeItemObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        itemKVO = nil
    }

    private func itemStatusChanged(container: StreamContainer) {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            onEvent?(.failed(item.error.map { PlaybackErrorMapper.map($0, container: container) } ?? .network(.other)))
        case .readyToPlay:
            let d = item.duration.seconds
            onEvent?(.ready(duration: d.isFinite ? d : 0))
        default: break
        }
    }

    private func timeControlChanged() {
        switch player.timeControlStatus {
        case .playing: onEvent?(.playing)
        case .paused: onEvent?(.paused)
        case .waitingToPlayAtSpecifiedRate: onEvent?(.buffering)
        @unknown default: break
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    // MARK: Audio / subtitles

    private func loadMediaOptions(asset: AVURLAsset, audio: String?, subtitle: String?) {
        optionsTask?.cancel()
        mediaGroups = (nil, nil)
        optionsTask = Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, let item = self.player.currentItem, item.asset === asset else { return }
            self.mediaGroups = (audible, legible)
            if let audible, let match = audible.options.first(where: { TrackNaming.matches($0.extendedLanguageTag, preferred: audio) }) {
                item.select(match, in: audible)
            }
            if let legible, let match = legible.options.first(where: { TrackNaming.matches($0.extendedLanguageTag, preferred: subtitle) }) {
                item.select(match, in: legible)
            }
            self.reportTracks()
        }
    }

    private func reportTracks() {
        guard let item = player.currentItem else { return }
        let (audible, legible) = mediaGroups
        let selectedAudio = audible.flatMap { g in item.currentMediaSelection.selectedMediaOption(in: g).flatMap { g.options.firstIndex(of: $0) } }
        let selectedSubtitle = legible.flatMap { g in item.currentMediaSelection.selectedMediaOption(in: g).flatMap { g.options.firstIndex(of: $0) } }
        onEvent?(.tracks(audio: Self.options(audible), subtitles: Self.options(legible),
                         selectedAudio: selectedAudio, selectedSubtitle: selectedSubtitle))
    }

    private static func options(_ group: AVMediaSelectionGroup?) -> [MediaOption] {
        guard let group else { return [] }
        return group.options.enumerated().map { index, option in
            let tag = option.extendedLanguageTag ?? option.locale?.identifier
            let name = TrackNaming.displayName(forLanguage: tag) ?? (option.displayName.isEmpty ? nil : option.displayName)
            return MediaOption(id: index, name: name, languageCode: tag)
        }
    }

    public func selectAudio(_ id: Int) {
        guard let group = mediaGroups.audio, group.options.indices.contains(id), let item = player.currentItem else { return }
        item.select(group.options[id], in: group)
        reportTracks()
    }

    public func selectSubtitle(_ id: Int?) {
        guard let group = mediaGroups.legible, let item = player.currentItem else { return }
        if let id, group.options.indices.contains(id) {
            item.select(group.options[id], in: group)
        } else {
            item.select(nil, in: group)
        }
        reportTracks()
    }

    public func setAspect(_ mode: AspectMode) { aspect = mode }

    public func stop() {
        optionsTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        mediaGroups = (nil, nil)
    }
}
#endif
