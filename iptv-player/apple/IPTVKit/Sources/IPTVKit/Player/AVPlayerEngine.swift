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
    private var sessionObservers: [NSObjectProtocol] = []
    private var playerKVO: NSKeyValueObservation?
    private var itemKVO: NSKeyValueObservation?
    private var timeObserver: Any?
    private var mediaGroups: (audio: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?) = (nil, nil)
    private var optionsTask: Task<Void, Never>?
    /// Live start tuning: relaxes the first-variant cap / stall waiting after the first frame.
    private var relaxTasks: [Task<Void, Never>] = []
    /// User intent: true after `load`/`play()`, false after `pause()`/`stop()`. A `.paused`
    /// status while this is true is a stall, not a user pause (`eventForPausedStatus`).
    private var wantsToPlay = false
    private var pendingRelax: (item: AVPlayerItem, tuning: LiveStartTuning)?
    /// True once this load forwarded its first `.playing` (which waits for a ready item).
    private var firstPlayingEmitted = false
    /// Duration last sent with `.ready` (0 = unknown) – a later known length is reported again.
    private var reportedDuration: Double = 0
    /// Pending automatic resume after an unexpected pause, and when the last one ran (monotonic ms).
    private var resumeTask: Task<Void, Never>?
    private var lastResumeMs: Int64?

    public init() {
        player.automaticallyWaitsToMinimizeStalling = true
        #if !os(macOS)
        player.preventsDisplaySleepDuringVideoPlayback = true
        #endif
        playerKVO = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        }
        observeAudioSession()
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
        cancelResume()
        lastResumeMs = nil
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
            MainActor.assumeIsolated { SafeLog.debug("avplayer playbackStalled"); self?.onEvent?(.stalled) }
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
            SafeLog.debug("avplayer item failed: \(Self.errorChain(item.error))")
            onEvent?(.failed(item.error.map { PlaybackErrorMapper.map($0, container: container) } ?? .network(.other)))
        case .readyToPlay:
            if Self.needsStartKick(wantsToPlay: wantsToPlay, stallWaitEnabled: player.automaticallyWaitsToMinimizeStalling) {
                player.play()
            }
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

    /// "domain code ← domain code" of an error and its underlying errors (debug log, no URLs).
    private static func errorChain(_ error: Error?) -> String {
        var parts: [String] = []
        var cursor = error as NSError?
        while let e = cursor, parts.count < 6 {
            parts.append("\(e.domain) \(e.code)")
            cursor = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
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
        SafeLog.debug("avplayer tcs=\(player.timeControlStatus.rawValue) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "-") rate=\(player.rate) item=\(player.currentItem?.status.rawValue ?? -1) wants=\(wantsToPlay) stallWait=\(player.automaticallyWaitsToMinimizeStalling) t=\(player.currentTime().seconds)")
        switch player.timeControlStatus {
        case .playing:
            scheduleRelaxIfNeeded()
            emitPlayingIfDue()
        case .paused:
            let event = Self.eventForPausedStatus(wantsToPlay: wantsToPlay, itemFinished: itemFinished)
            onEvent?(event)
            if event == .buffering { resumeAfterUnexpectedPause() }
        case .waitingToPlayAtSpecifiedRate: onEvent?(.buffering)
        @unknown default: break
        }
    }

    /// System pauses that count as the user's intent (AVPlayer pauses by itself): headphones /
    /// Bluetooth output gone, or an audio interruption began. Without this the engine would resume
    /// such a pause as a stall (`eventForPausedStatus`) and keep playing on the speaker.
    private func observeAudioSession() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.systemPaused() }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            MainActor.assumeIsolated { self?.systemPaused() }
        })
        #endif
    }

    private func systemPaused() {
        guard wantsToPlay, player.currentItem != nil else { return }
        SafeLog.debug("avplayer system pause (audio route / interruption)")
        pause()
        onEvent?(.paused)
    }

    /// The current item failed or played to its end (nothing to resume).
    private var itemFinished: Bool {
        guard let item = player.currentItem else { return true }
        if item.status == .failed { return true }
        let duration = item.duration.seconds
        return duration.isFinite && duration > 0 && player.currentTime().seconds >= duration - 0.5
    }

    /// AVPlayer paused although the user wants to play: resume with the safe settings (stall-waiting
    /// on, no relax timers) and report a stall so the controller's stall timeout bounds the recovery.
    /// At most one `play()` per second, so a player that keeps dropping to paused cannot spin.
    private func resumeAfterUnexpectedPause() {
        cancelRelax()
        player.automaticallyWaitsToMinimizeStalling = true
        onEvent?(.stalled)
        guard resumeTask == nil else { return }
        let now = SystemClock.monotonicMs()
        let delay = Self.resumeDelayMs(sinceLastResumeMs: lastResumeMs.map { now - $0 })
        resumeTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.resumeTask = nil
            guard self.wantsToPlay, self.player.timeControlStatus == .paused, !self.itemFinished else { return }
            SafeLog.debug("avplayer resume after unexpected pause")
            self.lastResumeMs = SystemClock.monotonicMs()
            self.player.play()
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
                SafeLog.debug("avplayer relax: stall waiting on")
                self.player.automaticallyWaitsToMinimizeStalling = true
            })
        }
    }

    private func cancelRelax() {
        relaxTasks.forEach { $0.cancel() }
        relaxTasks.removeAll()
        pendingRelax = nil
    }

    /// Event for `timeControlStatus == .paused`. Only the user (`pause()`/`stop()`) or a finished item
    /// (VOD end, failed item) may leave the player paused; any other pause – a stall with stall-waiting
    /// off, AVPlayer giving up when the relax timer re-enables stall-waiting, … – is `.buffering`
    /// and the engine resumes (bounded by the controller's stall timeout → reconnect policy).
    nonisolated static func eventForPausedStatus(wantsToPlay: Bool, itemFinished: Bool) -> EngineEvent {
        wantsToPlay && !itemFinished ? .buffering : .paused
    }

    /// With stall-waiting off, `play()` before the item is ready can leave AVPlayer at rate 1 with a
    /// clock that never starts (frozen first frame); `play()` is re-issued once the item is ready.
    nonisolated static func needsStartKick(wantsToPlay: Bool, stallWaitEnabled: Bool) -> Bool {
        wantsToPlay && !stallWaitEnabled
    }

    /// Minimum time between two automatic resumes after unexpected pauses.
    nonisolated static let resumeIntervalMs: Int64 = 1_000

    /// Delay before the next automatic resume (0 = now), `sinceLastResumeMs` after the previous one.
    nonisolated static func resumeDelayMs(sinceLastResumeMs: Int64?) -> Int64 {
        guard let since = sinceLastResumeMs else { return 0 }
        return max(0, resumeIntervalMs - since)
    }

    public func play() { wantsToPlay = true; player.play() }
    public func pause() {
        wantsToPlay = false
        cancelResume()
        player.pause()
    }

    private func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }

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
        cancelResume()
        player.automaticallyWaitsToMinimizeStalling = true
        optionsTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        mediaGroups = (nil, nil)
    }
}
#endif
