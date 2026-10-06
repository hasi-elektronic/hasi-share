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

    public init(id: Int, name: String?, languageCode: String?) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
    }
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

/// Playback controller shared by iOS and tvOS (docs/ARCHITECTURE.md §3.2). Two engines behind
/// `PlaybackEngine`: AVPlayer for HLS/MP4/MOV, VLCKit for MKV/TS/AVI/FLV/DASH/RTSP/RTMP…
/// (`ApplePlayback.engine(for:)`, CONTRACT §6.1), each a single instance reused across channel
/// switches. One fallback per opened stream: AVPlayer format/codec error → same stream in
/// VLCKit. The controller owns the reconnect policy (1-2-4-8-15 s), 400 ms channel-switch
/// debounce, progress saving and release when the scene leaves `.active`.
@MainActor
@Observable
public final class PlayerController {
    public private(set) var phase: PlayerPhase = .idle
    public private(set) var request: PlaybackRequest?
    public private(set) var stream: ResolvedStream?
    /// Engine currently showing video (nil before the first open).
    public private(set) var engine: (any PlaybackEngine)?
    public var engineKind: PlayerEngine? { engine?.kind }
    public private(set) var audioOptions: [MediaOption] = []
    public private(set) var subtitleOptions: [MediaOption] = []
    public private(set) var selectedAudio: Int?
    public private(set) var selectedSubtitle: Int?
    public var aspect: AspectMode = .fit {
        didSet {
            engine?.setAspect(aspect)
            onAspectChange?(aspect)
        }
    }
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
    @ObservationIgnored private let engines: PlaybackEngines
    @ObservationIgnored private var avEngine: (any PlaybackEngine)?
    @ObservationIgnored private var vlcEngine: (any PlaybackEngine)?
    @ObservationIgnored private var reconnectState = ReconnectState()
    @ObservationIgnored private var zapTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    /// Time (`nowMs`) of the last progress save of the current request; nil → the next tick saves.
    @ObservationIgnored private var lastProgressSaveMs: Int64?
    /// Seek in flight: `.time` ticks far from the target are stale until the engine caught up.
    @ObservationIgnored private var pendingSeek: (target: Double, atMs: Int64)?
    /// The user paused while a reconnect was pending: play reconnects at the saved position.
    @ObservationIgnored private var pausedDuringReconnect = false
    /// Engine forced for the current stream after a fallback (survives reconnects).
    @ObservationIgnored private var fallbackEngine: PlayerEngine?
    @ObservationIgnored public var canPlay: @MainActor () -> Bool = { true }
    @ObservationIgnored public var nowMs: @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    @ObservationIgnored public var onLibraryChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onAspectChange: (@MainActor (AspectMode) -> Void)?
    /// Settings → Playback → buffer size (large = no start tuning, bigger caches); set by `AppEnvironment`.
    @ObservationIgnored public var largeBuffer = false
    /// Neighbour-channel warm-up (docs/ARCHITECTURE.md §7); nil = no prefetch. Set by `AppEnvironment`.
    @ObservationIgnored public var prefetcher: ZapPrefetcher?
    /// Channel id whose neighbours were already prefetched (a resume `.playing` does not restart it).
    @ObservationIgnored private var prefetchedFor: String?
    /// QuickStart bookkeeping (docs/SCREENS.md §3.2): called whenever the last live session changes; set by `AppEnvironment`.
    @ObservationIgnored public var onLastSessionChange: (@MainActor (LastSession?) -> Void)?
    @ObservationIgnored private var lastSession: LastSession?
    @ObservationIgnored public var preferredAudioLanguage: String?
    @ObservationIgnored public var preferredSubtitleLanguage: String?
    /// Channel-switch debounce (ms).
    public static let zapDebounceMs = 400
    /// Stall → `Network(timeout)` after this long without playback.
    public static let stallTimeoutSeconds = 12

    /// - Parameter engines: engine factories; engines are created lazily on first use.
    public init(resolver: StreamResolver, library: LibraryRepository?, reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
                engines: PlaybackEngines) {
        self.resolver = resolver
        self.library = library
        self.reconnectPolicy = reconnectPolicy
        self.engines = engines
    }

    #if canImport(AVFoundation)
    /// AVPlayer-only controller (no VLCKit).
    public convenience init(resolver: StreamResolver, library: LibraryRepository?, reconnectPolicy: ReconnectPolicy = ReconnectPolicy()) {
        self.init(resolver: resolver, library: library, reconnectPolicy: reconnectPolicy, engines: .avPlayerOnly)
    }
    #endif

    /// Whether the VLCKit engine is available (resolver pre-check and fallback use it).
    public var vlcAvailable: Bool { engines.vlcAvailable }

    // MARK: Opening

    /// Opens a request (locked → `.locked`, the UI shows the paywall).
    public func open(_ request: PlaybackRequest) {
        saveProgress()
        openTask?.cancel()
        retryTask?.cancel()
        reconnectState = ReconnectState()
        fallbackEngine = nil
        lastProgressSaveMs = nil
        pendingSeek = nil
        pausedDuringReconnect = false
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
        // Resume position applied at open (not on reconnects / engine fallback).
        resumedFromMs = request.isLive ? nil : request.startPositionMs.flatMap { $0 > 0 ? $0 : nil }
        if let resumedFromMs {
            // The time label starts at the resume point; ticks from before the engine got there are stale.
            currentTime = Double(resumedFromMs) / 1000
            pendingSeek = (currentTime, nowMs())
        }
        guard canPlay() else {
            stopPlayback()
            phase = .locked
            return
        }
        phase = .loading
        PerfTrace.shared.mark(.playRequested)
        if !request.isLive { updateLastSession(nil) }   // VOD / raw URL playback: nothing to quick-start
        prefetchedFor = nil
        // A neighbour warmed up while the previous channel played: skip the resolver. Anything else
        // (not warmed, VOD) cancels the old prefetch right away so it does not compete with this start.
        var cached: ResolvedStream?
        if case .channel(let channel) = request.item {
            cached = prefetcher?.takeResolved(channelId: channel.id)
        }
        if cached == nil { prefetcher?.cancelAll() }
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: ResolvedStream
                if let cached { stream = cached } else { stream = try await resolver.resolve(request) }
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

    /// Engine kind for a resolved stream (fallback wins; VLCKit only when available).
    func engineKind(for stream: ResolvedStream) -> PlayerEngine {
        if let fallbackEngine { return fallbackEngine }
        if stream.engine == .vlcKit, engines.vlcAvailable { return .vlcKit }
        return .avPlayer
    }

    private func engineInstance(_ kind: PlayerEngine) -> any PlaybackEngine {
        if kind == .vlcKit, let make = engines.vlc {
            if let vlcEngine { return vlcEngine }
            let e = wire(make())
            vlcEngine = e
            return e
        }
        if let avEngine { return avEngine }
        let e = wire(engines.avPlayer())
        avEngine = e
        return e
    }

    /// Routes an engine's events to the controller while it is the active engine.
    private func wire(_ e: any PlaybackEngine) -> any PlaybackEngine {
        e.onEvent = { [weak self, weak e] event in
            guard let self, let e, self.engine === e else { return }
            self.handle(event)
        }
        return e
    }

    private func load(_ stream: ResolvedStream, startMs: Int64?) {
        let next = engineInstance(engineKind(for: stream))
        if let current = engine, current !== next { current.stop() }
        engine = next
        next.setAspect(aspect)
        pausedDuringReconnect = false
        if request?.isLive == false, let startMs, startMs > 0 {
            // The stale-tick window starts now: until the engine reaches the start position its
            // ticks (0, or the old item) would move the time label back.
            pendingSeek = (Double(startMs) / 1000, nowMs())
        }
        SafeLog.info("load \(stream.container.rawValue) via \(next.kind.rawValue)")
        let isLive = request?.isLive == true
        next.load(stream, isLive: isLive, startMs: startMs,
                  preferredAudioLanguage: preferredAudioLanguage, preferredSubtitleLanguage: preferredSubtitleLanguage,
                  tuning: LiveStartTuning.make(isLive: isLive, largeBuffer: largeBuffer))
    }

    // MARK: Engine events

    /// Applies an engine event (internal for tests).
    func handle(_ event: EngineEvent) {
        switch event {
        case .playing:
            PerfTrace.shared.mark(.firstFrame) // idempotent per attempt
            if let channel = currentChannel { updateLastSession(LastSession(sourceId: channel.sourceId, channelId: channel.id, endedInPlayer: true)) }
            prefetchNeighboursIfNeeded()
            stallTask?.cancel()
            reconnectState = reconnectPolicy.playing(reconnectState, nowMs: SystemClock.monotonicMs())
            if phase != .playing { phase = .playing }
        case .paused:
            if phase == .playing || phase == .buffering {
                phase = .paused
                saveProgress()
            }
        case .buffering:
            if phase == .playing { phase = .buffering }
        case .ready(let d):
            duration = d.isFinite && d > 0 ? d : 0
        case .time(let seconds):
            if let seek = pendingSeek {
                // A tick from before the seek completed would make the time label jump back.
                if abs(seconds - seek.target) > Self.seekToleranceSeconds, nowMs() - seek.atMs < Self.seekSettleMs { break }
                pendingSeek = nil
            }
            currentTime = seconds
            reconnectState = reconnectPolicy.tick(reconnectState, nowMs: SystemClock.monotonicMs())
            if let last = lastProgressSaveMs, nowMs() - last < Self.progressSaveIntervalMs { break }
            saveProgress()
        case .tracks(let audio, let subtitles, let selA, let selS):
            audioOptions = audio
            subtitleOptions = subtitles
            selectedAudio = selA
            selectedSubtitle = selS
        case .failed(let error):
            handle(error)
        case .stalled:
            handleStall()
        case .ended:
            handleEnded()
        }
    }

    // MARK: Errors & reconnect

    /// Applies the fallback and reconnect policy to a playback error (internal for tests).
    func handle(_ error: PlaybackError) {
        if case .failed = phase { return }
        if let stream, let current = engine?.kind, fallbackEngine == nil,
           let next = ApplePlayback.fallbackEngine(after: error, on: current, vlcAvailable: engines.vlcAvailable) {
            SafeLog.info("\(current.rawValue) failed (\(error)) – retrying with \(next.rawValue)")
            fallbackEngine = next
            load(stream, startMs: request?.isLive == true ? nil : (currentTime > 1 ? Int64(currentTime * 1000) : request?.startPositionMs))
            return
        }
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

    /// After the first frame of a live channel: warm the previous/next channel (once per channel).
    private func prefetchNeighboursIfNeeded() {
        guard let prefetcher, let request, case .channel(let channel) = request.item, prefetchedFor != channel.id else { return }
        prefetchedFor = channel.id
        prefetcher.prefetch(around: channel, request: request)
    }

    private func handleStall() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallTimeoutSeconds))
            guard !Task.isCancelled, let self, self.engine?.isPlaying != true else { return }
            self.handle(.network(.timeout))
        }
    }

    private func handleEnded() {
        // End of file = fully watched (the last tick can be a second or more before the end).
        if request?.isLive == false, duration > 0 { currentTime = duration }
        saveProgress()
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
        guard let engine else { return }
        if case .reconnecting = phase {
            // Pause = user intent: no further attempts until play.
            retryTask?.cancel()
            stallTask?.cancel()
            engine.pause()
            phase = .paused
            pausedDuringReconnect = true
            saveProgress()
        } else if pausedDuringReconnect, phase == .paused, let stream {
            phase = .loading
            load(stream, startMs: request?.isLive == true ? nil : Int64(currentTime * 1000))
        } else if phase == .ended {
            // Play again from the start after the end of a VOD.
            seek(to: 0)
            engine.play()
        } else if engine.isPlaying || phase == .playing || phase == .buffering {
            // Intent, not only `isPlaying`: a pause during buffering must pause too.
            engine.pause()
            phase = .paused
            saveProgress()
        } else {
            engine.play()
        }
    }

    /// ±seconds (VOD), clamped to [0, duration − 1 s] (unknown duration: no upper limit).
    /// Repeated presses accumulate from the pending target.
    public func seek(by seconds: Double) {
        guard request?.isLive == false else { return }
        let upper = duration > 0 ? max(0, duration - 1) : .greatestFiniteMagnitude
        seek(to: max(0, min(upper, currentTime + seconds)))
    }

    /// Scrubber release (0…1 of the duration; no-op while the duration is unknown).
    public func seek(toFraction fraction: Double) {
        guard request?.isLive == false, duration > 0 else { return }
        seek(to: duration * min(1, max(0, fraction)))
    }

    public func restartFromBeginning() {
        resumedFromMs = nil
        seek(to: 0)
    }

    private func seek(to target: Double) {
        currentTime = target
        pendingSeek = (target, nowMs())
        engine?.seek(to: target)
    }

    // MARK: Audio / subtitles

    public func selectAudio(_ id: Int) {
        guard audioOptions.contains(where: { $0.id == id }) else { return }
        engine?.selectAudio(id)
        selectedAudio = id
    }

    /// nil → subtitles off.
    public func selectSubtitle(_ id: Int?) {
        engine?.selectSubtitle(id)
        selectedSubtitle = id
    }

    // MARK: Lifecycle

    /// Saves the position and frees the player (scene not active / screen closed).
    public func release() {
        saveProgress()
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
        // Explicit exit (Back / close): the next launch must not quick-start this channel.
        // (`release()` – scene left .active – deliberately keeps `endedInPlayer`.)
        if let channel = currentChannel {
            updateLastSession(LastSession(sourceId: channel.sourceId, channelId: channel.id, endedInPlayer: false))
        } else if var last = lastSession, last.endedInPlayer {
            last.endedInPlayer = false
            updateLastSession(last)
        }
        release()
        request = nil
        stream = nil
        zapTarget = nil
        phase = .idle
    }

    /// Seeds the cache with the persisted record (a VOD open then clears a stale one); no callback.
    public func restoreLastSession(_ session: LastSession?) { lastSession = session }

    private func updateLastSession(_ new: LastSession?) {
        guard new != lastSession else { return }
        lastSession = new
        onLastSessionChange?(new)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func stopPlayback() {
        prefetcher?.cancelAll()
        prefetchedFor = nil
        retryTask?.cancel()
        stallTask?.cancel()
        engine?.stop()
    }

    // MARK: Progress

    private func recordLiveWatch() {
        guard let request, request.isLive, let key = request.contentKey, let library else { return }
        _ = try? library.saveProgress(contentKey: key, title: request.title, kind: .live, positionMs: 0, durationMs: 0,
                                      posterUrl: request.posterUrl, nowMs: nowMs())
        onLibraryChange?()
    }

    /// Progress save interval while playing (SCREENS §3.7: every 10 s + on pause/exit).
    public static let progressSaveIntervalMs: Int64 = 10_000
    /// Time ticks within this distance of a seek target count as "seek done".
    static let seekToleranceSeconds: Double = 3
    /// After this long the engine's ticks are trusted again even if far from the target.
    static let seekSettleMs: Int64 = 3_000

    /// Saves the VOD position. Without a reported duration the position is still saved with
    /// `durationMs` 0 (resume works; "watched" needs the duration).
    private func saveProgress() {
        guard let request, !request.isLive, let key = request.contentKey, let library, currentTime > 1 else { return }
        lastProgressSaveMs = nowMs()
        var seriesKey: String?
        if case .episode(let e, _) = request.item, let fp = request.sourceFingerprint {
            seriesKey = ContentKey.make(fingerprint: fp, kind: .series, itemId: e.seriesId)
        }
        _ = try? library.saveProgress(contentKey: key, title: request.title, kind: request.contentKind,
                                      positionMs: Int64(currentTime * 1000), durationMs: Int64(max(0, duration) * 1000),
                                      posterUrl: request.posterUrl, seriesKey: seriesKey, nowMs: nowMs())
        onLibraryChange?()
    }
}
