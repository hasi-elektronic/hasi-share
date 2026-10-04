import Foundation
import IPTVCore
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Aspect ratio modes (docs/SCREENS.md §3.7) – global preference.
public enum AspectMode: String, CaseIterable, Codable, Sendable {
    case fit, fill, stretch, ratio16x9, ratio4x3

    /// Fixed frame ratio (width/height) for 16:9 and 4:3; nil = use the full view.
    public var fixedRatio: Double? {
        switch self {
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        default: return nil
        }
    }

    /// `AVPlayerLayer.videoGravity` value.
    public var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch, .ratio16x9, .ratio4x3: return .resize
        }
    }

    public var titleKey: String {
        switch self {
        case .fit: return "aspect_fit"
        case .fill: return "aspect_fill"
        case .stretch: return "aspect_stretch"
        case .ratio16x9: return "aspect_16_9"
        case .ratio4x3: return "aspect_4_3"
        }
    }
}

/// An audio or subtitle choice.
public struct MediaOption: Identifiable, Hashable, Sendable {
    public var id: Int
    /// Display name (language name, or nil → UI shows "Track n").
    public var name: String?
    public var languageCode: String?
}

/// Playback state for the overlay.
public enum PlayerPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case reconnecting(attempt: Int, max: Int)
    case failed(PlaybackError)
    case locked
    case ended
}

/// Single AVPlayer instance reused across channel switches (docs/ARCHITECTURE.md §3.2): format
/// pre-check, reconnect policy (1-2-4-8-15 s), audio/subtitle selection via
/// `AVMediaSelectionGroup`, aspect modes, 400 ms channel-switch debounce, progress saving and
/// release when the scene leaves `.active`.
@MainActor
@Observable
public final class PlayerController {
    public let player = AVPlayer()
    public private(set) var phase: PlayerPhase = .idle
    public private(set) var request: PlaybackRequest?
    public private(set) var stream: ResolvedStream?
    public private(set) var audioOptions: [MediaOption] = []
    public private(set) var subtitleOptions: [MediaOption] = []
    public private(set) var selectedAudio: Int?
    public private(set) var selectedSubtitle: Int?
    public var aspect: AspectMode = .fit { didSet { onAspectChange?(aspect) } }
    /// Channel shown on the zap info card (immediately on key press).
    public private(set) var zapTarget: Channel?
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var previousChannel: Channel?
    /// Resume position applied at open (for the "Play from start" chip).
    public private(set) var resumedFromMs: Int64?

    @ObservationIgnored private let resolver: StreamResolver
    @ObservationIgnored private let library: LibraryRepository?
    @ObservationIgnored private let reconnectPolicy: ReconnectPolicy
    @ObservationIgnored private var reconnectState = ReconnectState()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var playerKVO: NSKeyValueObservation?
    @ObservationIgnored private var itemKVO: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var zapTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var lastProgressSave: Date = .distantPast
    @ObservationIgnored private var mediaGroups: (audio: AVMediaSelectionGroup?, legible: AVMediaSelectionGroup?) = (nil, nil)
    @ObservationIgnored public var canPlay: @MainActor () -> Bool = { true }
    @ObservationIgnored public var nowMs: @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    @ObservationIgnored public var onLibraryChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onAspectChange: (@MainActor (AspectMode) -> Void)?
    @ObservationIgnored public var preferredAudioLanguage: String?
    @ObservationIgnored public var preferredSubtitleLanguage: String?
    /// Channel-switch debounce (ms).
    public static let zapDebounceMs = 400

    public init(resolver: StreamResolver, library: LibraryRepository?, reconnectPolicy: ReconnectPolicy = ReconnectPolicy()) {
        self.resolver = resolver
        self.library = library
        self.reconnectPolicy = reconnectPolicy
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        playerKVO = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    // MARK: Opening

    /// Opens a request (locked → `.locked`, the UI shows the paywall).
    public func open(_ request: PlaybackRequest) {
        saveProgress(force: true)
        openTask?.cancel()
        retryTask?.cancel()
        reconnectState = ReconnectState()
        if case .channel(let current)? = self.request?.item, case .channel(let next) = request.item, current.id != next.id {
            previousChannel = current
        }
        self.request = request
        audioOptions = []
        subtitleOptions = []
        selectedAudio = nil
        selectedSubtitle = nil
        currentTime = 0
        duration = 0
        resumedFromMs = nil
        guard canPlay() else {
            stopPlayback()
            phase = .locked
            return
        }
        phase = .loading
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await resolver.resolve(request)
                guard !Task.isCancelled else { return }
                self.stream = stream
                load(stream, startMs: request.startPositionMs)
                recordLiveWatch()
            } catch {
                guard !Task.isCancelled else { return }
                let mapped = (error as? PlaybackError) ?? ErrorClassifier.playbackError(from: error) ?? .unknown(message: "\(error)")
                SafeLog.warning("open failed: \(mapped)")
                stopPlayback()
                phase = .failed(mapped)
            }
        }
    }

    private func load(_ stream: ResolvedStream, startMs: Int64?) {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = request?.isLive == true ? 2 : 0
        attach(item)
        player.replaceCurrentItem(with: item)
        if let startMs, startMs > 0 {
            resumedFromMs = startMs
            player.seek(to: CMTime(value: startMs, timescale: 1000))
        }
        player.play()
        loadMediaOptions(asset: asset)
    }

    private func attach(_ item: AVPlayerItem) {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        itemKVO = item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            MainActor.assumeIsolated { self?.handleFailure(error) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleStall() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnded() }
        })
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .failed: handleFailure(item.error as NSError?)
        case .readyToPlay:
            let d = item.duration.seconds
            duration = d.isFinite ? d : 0
        default: break
        }
    }

    private func timeControlChanged() {
        switch player.timeControlStatus {
        case .playing:
            stallTask?.cancel()
            reconnectState = reconnectPolicy.playing(reconnectState, nowMs: SystemClock.monotonicMs())
            if phase != .playing { phase = .playing }
        case .paused:
            if phase == .playing || phase == .buffering { phase = .paused }
        case .waitingToPlayAtSpecifiedRate:
            if phase == .playing { phase = .buffering }
        @unknown default: break
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = seconds }
        reconnectState = reconnectPolicy.tick(reconnectState, nowMs: SystemClock.monotonicMs())
        if Date().timeIntervalSince(lastProgressSave) >= 10 { saveProgress(force: false) }
    }

    // MARK: Errors & reconnect

    private func handleFailure(_ error: NSError?) {
        let mapped = error.map { PlaybackErrorMapper.map($0, container: stream?.container ?? .unknown) } ?? .network(.other)
        handle(mapped)
    }

    /// Applies the reconnect policy to a playback error (internal for tests).
    func handle(_ error: PlaybackError) {
        if case .failed = phase { return }
        guard PlaybackErrorMapper.isRecoverable(error), stream != nil else {
            stopPlayback()
            phase = .failed(error)
            return
        }
        let (state, decision) = reconnectPolicy.error(reconnectState, nowMs: SystemClock.monotonicMs())
        reconnectState = state
        switch decision {
        case .retry(let attempt, let max, let delayMs):
            phase = .reconnecting(attempt: attempt, max: max)
            SafeLog.info("reconnect \(attempt)/\(max) in \(delayMs) ms")
            retryTask?.cancel()
            let resumeMs = request?.isLive == true ? nil : Int64(currentTime * 1000)
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self, let stream = self.stream else { return }
                self.load(stream, startMs: resumeMs)
            }
        case .giveUp:
            stopPlayback()
            phase = .failed(error)
        }
    }

    private func handleStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.player.timeControlStatus != .playing else { return }
            self.handle(.network(.timeout))
        }
    }

    private func handleEnded() {
        saveProgress(force: true)
        phase = .ended
    }

    /// "Retry" on the error card.
    public func retry() {
        guard let request else { return }
        open(request)
    }

    // MARK: Channel switching

    /// Zaps by ±n in the request's channel list: info card immediately, the stream opens only
    /// for the last target after 400 ms without another key press.
    public func zap(by delta: Int) {
        guard let request, !request.channels.isEmpty else { return }
        let reference: Channel? = zapTarget ?? { if case .channel(let c) = request.item { return c } else { return nil } }()
        guard let reference, let index = request.channels.firstIndex(where: { $0.id == reference.id }) else { return }
        let count = request.channels.count
        let target = request.channels[((index + delta) % count + count) % count]
        zap(to: target)
    }

    public func zap(to channel: Channel) {
        zapTarget = channel
        zapTask?.cancel()
        zapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.zapDebounceMs))
            guard !Task.isCancelled, let self, var request = self.request else { return }
            request.item = .channel(channel)
            request.startPositionMs = nil
            self.open(request)
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, self.zapTarget?.id == channel.id { self.zapTarget = nil }
        }
    }

    public func switchToPreviousChannel() {
        if let previousChannel { zap(to: previousChannel) }
    }

    /// Currently playing channel, if live.
    public var currentChannel: Channel? {
        if case .channel(let c)? = request?.item { return c }
        return nil
    }

    // MARK: Transport

    public func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
            saveProgress(force: true)
        } else {
            player.play()
        }
    }

    public func seek(by seconds: Double) {
        guard request?.isLive == false else { return }
        let target = max(0, min(duration > 0 ? duration - 1 : .greatestFiniteMagnitude, currentTime + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    public func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * min(1, max(0, fraction)), preferredTimescale: 600))
    }

    public func restartFromBeginning() {
        resumedFromMs = nil
        player.seek(to: .zero)
    }

    // MARK: Audio / subtitles

    private func loadMediaOptions(asset: AVURLAsset) {
        Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self else { return }
            self.mediaGroups = (audible, legible)
            self.audioOptions = Self.options(audible)
            self.subtitleOptions = Self.options(legible)
            if let audible, let item = self.player.currentItem {
                if let lang = self.preferredAudioLanguage,
                   let match = audible.options.first(where: { $0.extendedLanguageTag?.hasPrefix(lang) == true }) {
                    item.select(match, in: audible)
                }
                self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: audible).flatMap { audible.options.firstIndex(of: $0) }
            }
            if let legible, let item = self.player.currentItem {
                if let lang = self.preferredSubtitleLanguage,
                   let match = legible.options.first(where: { $0.extendedLanguageTag?.hasPrefix(lang) == true }) {
                    item.select(match, in: legible)
                }
                self.selectedSubtitle = item.currentMediaSelection.selectedMediaOption(in: legible).flatMap { legible.options.firstIndex(of: $0) }
            }
        }
    }

    private static func options(_ group: AVMediaSelectionGroup?) -> [MediaOption] {
        guard let group else { return [] }
        return group.options.enumerated().map { index, option in
            let tag = option.extendedLanguageTag ?? option.locale?.identifier
            let name = tag.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? (option.displayName.isEmpty ? nil : option.displayName)
            return MediaOption(id: index, name: name, languageCode: tag)
        }
    }

    public func selectAudio(_ id: Int) {
        guard let group = mediaGroups.audio, group.options.indices.contains(id), let item = player.currentItem else { return }
        item.select(group.options[id], in: group)
        selectedAudio = id
    }

    /// nil → subtitles off.
    public func selectSubtitle(_ id: Int?) {
        guard let group = mediaGroups.legible, let item = player.currentItem else { return }
        if let id, group.options.indices.contains(id) {
            item.select(group.options[id], in: group)
        } else {
            item.select(nil, in: group)
        }
        selectedSubtitle = id
    }

    // MARK: Lifecycle

    /// Saves the position and frees the player (scene not active / screen closed).
    public func release() {
        saveProgress(force: true)
        openTask?.cancel()
        zapTask?.cancel()
        stopPlayback()
        if phase != .locked, !isFailed { phase = .idle }
    }

    /// Re-opens the last request after `release()` (scene active again), resuming VOD.
    public func resumeAfterRelease() {
        guard var request, phase == .idle else { return }
        if !request.isLive, currentTime > 0 { request.startPositionMs = Int64(currentTime * 1000) }
        open(request)
    }

    /// Closes the player screen.
    public func close() {
        release()
        request = nil
        stream = nil
        zapTarget = nil
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func stopPlayback() {
        retryTask?.cancel()
        stallTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: Progress

    private func recordLiveWatch() {
        guard let request, request.isLive, let key = request.contentKey, let library else { return }
        _ = try? library.saveProgress(contentKey: key, title: request.title, kind: .live, positionMs: 0, durationMs: 0,
                                      posterUrl: request.posterUrl, nowMs: nowMs())
        onLibraryChange?()
    }

    private func saveProgress(force: Bool) {
        lastProgressSave = Date()
        guard let request, !request.isLive, let key = request.contentKey, let library,
              duration > 0, currentTime > 1 else { return }
        var seriesKey: String?
        if case .episode(let e, _) = request.item, let fp = request.sourceFingerprint {
            seriesKey = ContentKey.make(fingerprint: fp, kind: .series, itemId: e.seriesId)
        }
        _ = try? library.saveProgress(contentKey: key, title: request.title, kind: request.contentKind,
                                      positionMs: Int64(currentTime * 1000), durationMs: Int64(duration * 1000),
                                      posterUrl: request.posterUrl, seriesKey: seriesKey, nowMs: nowMs())
        onLibraryChange?()
    }
}
