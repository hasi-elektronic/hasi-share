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
    /// Live start tuning: relaxes the first-variant cap / stall waiting after the first frame.
    private var relaxTasks: [Task<Void, Never>] = []
    /// User intent: true after `load`/`play()`, false after `pause()`/`stop()`. A `.paused`
    /// status while this is true and stall-waiting is off is a stall, not a user pause.
    private var wantsToPlay = false
    private var pendingRelax: (item: AVPlayerItem, tuning: LiveStartTuning)?
    /// True once this load forwarded its first `.playing` (which waits for a ready item).
    private var firstPlayingEmitted = false
    /// Duration last sent with `.ready` (0 = unknown) – a later known length is reported again.
    private var reportedDuration: Double = 0

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
                self?.reportDurationIfKnown()
                if seconds.isFinite { self?.onEvent?(.time(seconds)) }
            }
        }
    }

    public var isPlaying: Bool { player.timeControlStatus == .playing }

    /// `indicatedBitrate` / `numberOfDroppedVideoFrames` from the newest access-log event;
    /// resolution from `presentationSize`.
    public var diagnostics: EngineDiagnostics {
        guard let item = player.currentItem else { return EngineDiagnostics() }
        var d = EngineDiagnostics()
        if let event = item.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { d.bitrate = event.indicatedBitrate }
            if event.numberOfDroppedVideoFrames >= 0 { d.droppedFrames = event.numberOfDroppedVideoFrames }
        }
        let size = item.presentationSize
        if size.width > 0, size.height > 0 { d.resolution = "\(Int(size.width))x\(Int(size.height))" }
        return d
    }

    public func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?, preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        cancelRelax()
        wantsToPlay = true
        firstPlayingEmitted = false
        reportedDuration = 0
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = tuning.forwardBufferSeconds
        player.automaticallyWaitsToMinimizeStalling = tuning.waitToMinimizeStallingAfter == 0
        if let cap = tuning.initialPeakBitRate { item.preferredPeakBitRate = cap }
        if tuning.initialPeakBitRate != nil || tuning.waitToMinimizeStallingAfter > 0 {
            pendingRelax = (item, tuning)
        }
        attach(item, container: stream.container)
        player.replaceCurrentItem(with: item)
        if let startMs, startMs > 0 {
            // Resume: never past the saved position (a keyframe seek could skip a few seconds).
            player.seek(to: CMTime(value: startMs, timescale: 1000), toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600),
                        toleranceAfter: .zero)
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
            reportedDuration = d.isFinite && d > 0 ? d : 0
            onEvent?(.ready(duration: reportedDuration))
            if player.timeControlStatus == .playing {
                scheduleRelaxIfNeeded()
                emitPlayingIfDue()
            }
        default: break
        }
    }

    /// Some VOD items (progressive MP4 over slow links, some HLS VOD) only know their length after
    /// `readyToPlay`; report it once it is known so the scrubber and "watched" work.
    private func reportDurationIfKnown() {
        guard reportedDuration == 0, let item = player.currentItem, item.status == .readyToPlay else { return }
        let d = item.duration.seconds
        guard d.isFinite, d > 0 else { return }
        reportedDuration = d
        onEvent?(.ready(duration: d))
    }

    private func timeControlChanged() {
        switch player.timeControlStatus {
        case .playing:
            scheduleRelaxIfNeeded()
            emitPlayingIfDue()
        case .paused:
            let event = Self.eventForPausedStatus(wantsToPlay: wantsToPlay,
                                                  stallWaitEnabled: player.automaticallyWaitsToMinimizeStalling)
            if event == .buffering {
                // Tuned live start: with stall-waiting off a stall drops the rate to 0. Recover
                // with the safe settings and let AVPlayer resume once it has buffered.
                cancelRelax()
                player.automaticallyWaitsToMinimizeStalling = true
                player.play()
            }
            onEvent?(event)
        case .waitingToPlayAtSpecifiedRate: onEvent?(.buffering)
        @unknown default: break
        }
    }

    /// Forwards `.playing`; the FIRST one of a load only once the item is `readyToPlay` (with
    /// stall-waiting off AVPlayer reports `.playing` right at `play()`, before any frame), until
    /// then `.buffering`. `itemStatusChanged` re-checks when the item becomes ready.
    private func emitPlayingIfDue() {
        let event = Self.eventForPlayingStatus(firstPlayingEmitted: firstPlayingEmitted,
                                               itemReady: player.currentItem?.status == .readyToPlay)
        if event == .playing { firstPlayingEmitted = true }
        onEvent?(event)
    }

    /// Event for `timeControlStatus == .playing`: `.playing` once the first one was forwarded or the
    /// item is ready, else `.buffering` (so the controller's first-frame mark is not understated).
    nonisolated static func eventForPlayingStatus(firstPlayingEmitted: Bool, itemReady: Bool) -> EngineEvent {
        firstPlayingEmitted || itemReady ? .playing : .buffering
    }

    /// On the first `.playing` of a tuned load: after the configured delays remove the bitrate cap
    /// and re-enable stall minimizing (cancelled by the next `load` / `stop`).
    private func scheduleRelaxIfNeeded() {
        // Only a real playing state counts as "first frame": with stall-waiting off AVPlayer
        // reports `.playing` right at `play()`, before the item is ready.
        guard let (item, tuning) = pendingRelax, item.status == .readyToPlay else { return }
        pendingRelax = nil
        cancelRelax()
        // Two independent timers, both measured from the first frame.
        if tuning.initialPeakBitRate != nil {
            relaxTasks.append(Task { [weak self, weak item] in
                try? await Task.sleep(for: .seconds(tuning.peakBitRateReleaseAfter))
                guard !Task.isCancelled, let self, let item, self.player.currentItem === item else { return }
                item.preferredPeakBitRate = 0
            })
        }
        if tuning.waitToMinimizeStallingAfter > 0 {
            relaxTasks.append(Task { [weak self, weak item] in
                try? await Task.sleep(for: .seconds(tuning.waitToMinimizeStallingAfter))
                guard !Task.isCancelled, let self, let item, self.player.currentItem === item else { return }
                self.player.automaticallyWaitsToMinimizeStalling = true
            })
        }
    }

    private func cancelRelax() {
        relaxTasks.forEach { $0.cancel() }
        relaxTasks.removeAll()
        pendingRelax = nil
    }

    /// True when `.paused` was not requested by the user: the engine wants to play but
    /// stall-waiting is off, so AVPlayer stopped (rate 0) instead of waiting for data.
    /// Event for `timeControlStatus == .paused`: `.buffering` for a stall (see above), else `.paused`.
    nonisolated static func eventForPausedStatus(wantsToPlay: Bool, stallWaitEnabled: Bool) -> EngineEvent {
        wantsToPlay && !stallWaitEnabled ? .buffering : .paused
    }

    public func play() { wantsToPlay = true; player.play() }
    public func pause() { wantsToPlay = false; player.pause() }

    /// ±1 s tolerance: the default (keyframe) seek can land several seconds before the target,
    /// so "+10 s" would only move +5 s on a file with sparse keyframes.
    public func seek(to seconds: Double) {
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
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
        wantsToPlay = false
        firstPlayingEmitted = false
        cancelRelax()
        player.automaticallyWaitsToMinimizeStalling = true
        optionsTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        mediaGroups = (nil, nil)
    }
}
#endif
