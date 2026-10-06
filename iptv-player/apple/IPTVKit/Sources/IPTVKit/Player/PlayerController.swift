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

/// System audio events that pause playback (docs/ARCHITECTURE.md §3.2), translated from
/// `AVAudioSession` notifications by the app (`AudioSessionObserver`).
public enum AudioSessionEvent: Equatable, Sendable {
    /// Another app / a call took the audio session.
    case began
    /// The interruption is over; `shouldResume` = the system recommends resuming.
    case ended(shouldResume: Bool)
    /// The output route was lost (headphones / Bluetooth unplugged).
    case routeLost
}

extension AudioSessionEvent {
    /// `AVAudioSessionInterruptionNotification` payload (raw values: type began 1 / ended 0, option shouldResume 1,
    /// reason appWasSuspended 1 – the app was in the background, nothing was playing for the user).
    public static func interruption(typeRaw: UInt?, optionsRaw: UInt?, reasonRaw: UInt?) -> AudioSessionEvent? {
        switch typeRaw {
        case 1: return reasonRaw == 1 ? nil : .began
        case 0: return .ended(shouldResume: (optionsRaw ?? 0) & 1 != 0)
        default: return nil
        }
    }

    /// `AVAudioSessionRouteChangeNotification` payload (reason oldDeviceUnavailable = 2).
    public static func routeChange(reasonRaw: UInt?) -> AudioSessionEvent? {
        reasonRaw == 2 ? .routeLost : nil
    }
}

/// Activates / deactivates the platform audio session (`AVAudioSession` on iOS/tvOS, set by the app).
public struct AudioSessionHooks {
    public var activate: @MainActor () -> Void
    public var deactivate: @MainActor () -> Void

    public init(activate: @escaping @MainActor () -> Void, deactivate: @escaping @MainActor () -> Void) {
        self.activate = activate
        self.deactivate = deactivate
    }
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
    /// Effective audio delay of the current request (content + device, ms; CONTRACT §6.1).
    public private(set) var currentAudioDelay = 0
    /// The current content's own delay (the player's "Sync" control edits it).
    public private(set) var contentAudioDelay = 0
    /// Device/soundbar delay (Settings → Playback), added to every content.
    public private(set) var deviceAudioDelay = 0
    /// The delay could not be applied to this opened stream (VLCKit failed, playing on AVPlayer without it).
    public private(set) var audioSyncUnavailable = false

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
    /// The interruption paused this playback and it may resume when the interruption ends.
    @ObservationIgnored private var pausedByInterruption = false
    /// The engine reported an interruption pause (`.pausedBySystem`) that its notification has not claimed yet.
    /// Every other `.paused` phase (user, headphones, AirPlay, interruption that ended without
    /// `shouldResume`) is sticky: only the user resumes it.
    @ObservationIgnored private var systemPauseUnclaimed = false
    /// No live item behind the paused state (paused while opening, stopped non-pausable input, scene cycle):
    /// play opens the request again (VOD at the saved position, live at the live edge).
    @ObservationIgnored private var reloadOnPlay = false
    /// Paused when the scene released the player: `resumeAfterRelease` restores the paused state, it does not play.
    @ObservationIgnored private var pausedAtRelease = false
    /// Per-content + device audio delay (docs/SCREENS.md §3.7); set by `AppEnvironment`. nil = no delays.
    @ObservationIgnored public var audioDelayStore: AudioDelayStore? { didSet { refreshAudioDelay() } }
    /// Content delay of a request without content key (raw URL): this session only.
    @ObservationIgnored private var unkeyedContentDelay = 0
    /// The open's resolve is in flight: `stream` still belongs to the previous request.
    @ObservationIgnored private var resolving = false
    /// VLCKit plays this stream only because of the audio delay (AVPlayer could play it): a VLCKit
    /// format/codec failure falls back to AVPlayer without the delay (CONTRACT §6.1).
    @ObservationIgnored private var delayRoutedToVLC = false
    /// Audio session activation (at playback start / resume) and deactivation (player released); set by the app.
    @ObservationIgnored public var audioSession = AudioSessionHooks(activate: {}, deactivate: {})
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
    /// HTTP probe of the stream (1 KiB range request) that classifies AVPlayer failures without a
    /// usable reason (docs/SCREENS.md §4); injectable for tests.
    @ObservationIgnored var probe: @MainActor (URL, [String: String]) async -> VLCFailureClassifier.Probe? = { url, headers in
        await VLCFailureClassifier.probe(url, headers: headers)
    }
    /// AVPlayer still not ready after this long → probe the stream (internal for tests).
    @ObservationIgnored var notReadyProbeDelay: Duration = .seconds(PlayerController.notReadyProbeSeconds)
    /// Stall → `Network(timeout)` after this long (internal for tests).
    @ObservationIgnored var stallTimeout: Duration = .seconds(PlayerController.stallTimeoutSeconds)
    /// The engine reported `.ready`/`.playing` for the current load.
    @ObservationIgnored private var loadReady = false
    /// Not-ready watchdog / failure probe of the current load.
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored public var preferredAudioLanguage: String?
    @ObservationIgnored public var preferredSubtitleLanguage: String?
    /// Channel-switch debounce (ms).
    public static let zapDebounceMs = 400
    /// Stall → `Network(timeout)` after this long without playback.
    public static let stallTimeoutSeconds = 12
    /// AVPlayer not ready after this long → HTTP probe (SCREENS §4: error card within a few seconds).
    public static let notReadyProbeSeconds = 8

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
        probeTask?.cancel()
        reconnectState = ReconnectState()
        pausedByInterruption = false
        systemPauseUnclaimed = false
        reloadOnPlay = false
        pausedAtRelease = false
        fallbackEngine = nil
        lastProgressSaveMs = nil
        pendingSeek = nil
        pausedDuringReconnect = false
        delayRoutedToVLC = false
        audioSyncUnavailable = false
        if self.request?.id != request.id { unkeyedContentDelay = 0 }   // retry / resume keep a raw URL's delay
        if case .channel(let current)? = self.request?.item, case .channel(let next) = request.item, current.id != next.id {
            previousChannel = current
        }
        self.request = request
        refreshAudioDelay()
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
        resolving = true
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: ResolvedStream
                if let cached { stream = cached } else { stream = try await resolver.resolve(request) }
                guard !Task.isCancelled else { return }
                self.resolving = false
                self.stream = stream
                load(stream, startMs: request.startPositionMs)
                recordLiveWatch()
            } catch {
                guard !Task.isCancelled else { return }
                self.resolving = false
                let mapped = (error as? PlaybackError) ?? ErrorClassifier.playbackError(from: error) ?? .unknown(message: "\(error)")
                SafeLog.warning("open failed: \(mapped)")
                stopPlayback()
                phase = .failed(mapped)
            }
        }
    }

    /// Engine kind for a resolved stream (fallback wins; an audio delay ≠ 0 → VLCKit; VLCKit only when available).
    func engineKind(for stream: ResolvedStream) -> PlayerEngine {
        if let fallbackEngine { return fallbackEngine }
        if currentAudioDelay != 0,
           ApplePlayback.engine(for: stream.container, vlcAvailable: engines.vlcAvailable, audioDelayMs: currentAudioDelay) == .vlcKit {
            return .vlcKit
        }
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
        let kind = engineKind(for: stream)
        if kind == .vlcKit, currentAudioDelay != 0, fallbackEngine == nil || delayRoutedToVLC,
           ApplePlayback.engine(for: stream.container, vlcAvailable: engines.vlcAvailable) == .avPlayer {
            delayRoutedToVLC = true
        }
        let next = engineInstance(kind)
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
        audioSession.activate()
        let isLive = request?.isLive == true
        loadReady = false
        probeTask?.cancel()
        cancelStallTimer()   // a new item starts without the previous item's stall deadline
        next.setAudioDelay(ms: currentAudioDelay)   // before load: VLCKit starts the item with it
        next.load(stream, isLive: isLive, startMs: startMs,
                  preferredAudioLanguage: preferredAudioLanguage, preferredSubtitleLanguage: preferredSubtitleLanguage,
                  tuning: LiveStartTuning.make(isLive: isLive, largeBuffer: largeBuffer))
        // VOD only: a second connection to a live panel (often one connection per account) could itself be refused.
        if next.kind == .avPlayer, !isLive { watchNotReady(stream) }
    }

    // MARK: AVPlayer failure classification

    /// AVPlayer can stay "not ready" (spinner) for a long time on an HTTP error; after
    /// `notReadyProbeDelay` the stream is probed and an HTTP error status ends the wait.
    private func watchNotReady(_ stream: ResolvedStream) {
        let delay = notReadyProbeDelay
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.loadReady else { return }
            let probe = await self.probe(stream.url, stream.headers)
            guard !Task.isCancelled, !self.loadReady, self.stream == stream,
                  let error = probe?.httpStatus.flatMap(ErrorClassifier.playbackError(httpStatus:)) ?? probe?.transportError else { return }
            SafeLog.warning("avplayer not ready after \(delay) – probe \(error)")
            self.handle(error)
        }
    }

    /// An AVPlayer failure before the first ready/playing whose error carries no usable reason
    /// (`Network(other)`, `Unknown`): probe the stream; an HTTP error status replaces the error.
    private func classifyAVPlayerFailure(_ error: PlaybackError) {
        guard let stream else { handle(error); return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            let probe = await self?.probe(stream.url, stream.headers)
            guard !Task.isCancelled, let self, self.stream == stream else { return }
            let mapped = probe?.httpStatus.flatMap(ErrorClassifier.playbackError(httpStatus:)) ?? probe?.transportError ?? error
            SafeLog.warning("avplayer failed before ready: \(error) – probe \(mapped)")
            self.handle(mapped)
        }
    }

    /// Errors AVPlayer reports without a cause the user can act on.
    static func needsProbe(_ error: PlaybackError) -> Bool {
        switch error {
        case .network(.other), .unknown: return true
        default: return false
        }
    }

    // MARK: Engine events

    /// Applies an engine event (internal for tests).
    func handle(_ event: EngineEvent) {
        if case .time = event {} else { SafeLog.debug("player event \(event) phase=\(phase)") }
        switch event {
        case .playing:
            loadReady = true
            PerfTrace.shared.mark(.firstFrame) // idempotent per attempt
            if let channel = currentChannel { updateLastSession(LastSession(sourceId: channel.sourceId, channelId: channel.id, endedInPlayer: true)) }
            prefetchNeighboursIfNeeded()
            cancelStallTimer()
            reconnectState = reconnectPolicy.playing(reconnectState, nowMs: SystemClock.monotonicMs())
            systemPauseUnclaimed = false
            if phase != .playing { phase = .playing }
        case .paused, .pausedBySystem:
            cancelStallTimer()   // a real pause ends any stall recovery
            if phase == .playing || phase == .buffering {
                phase = .paused
                systemPauseUnclaimed = event == .pausedBySystem
                saveProgress()
            }
        case .buffering:
            if phase == .playing { phase = .buffering }
        case .ready(let d):
            loadReady = true
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
            if engine?.kind == .avPlayer, !loadReady, Self.needsProbe(error) {
                classifyAVPlayerFailure(error)
            } else {
                handle(error)
            }
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
        if delayRoutedToVLC, let stream, engine?.kind == .vlcKit,
           ApplePlayback.fallbackEngine(after: error, on: .avPlayer, vlcAvailable: true) != nil {
            // VLCKit cannot play what AVPlayer can: play it there without the delay (once, with a notice).
            SafeLog.info("vlckit failed (\(error)) for a delay-routed stream – avplayer without audio delay")
            delayRoutedToVLC = false
            fallbackEngine = .avPlayer
            audioSyncUnavailable = true
            load(stream, startMs: request?.isLive == true ? nil : (currentTime > 1 ? Int64(currentTime * 1000) : request?.startPositionMs))
            return
        }
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

    /// Starts the stall timer; a further stall before playback resumed keeps the first deadline, so
    /// repeated stalls (or unexpected pauses the engine keeps resuming) end in the reconnect policy.
    private func handleStall() {
        guard stallTask == nil else { return }
        let timeout = stallTimeout
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.stallTask = nil
            guard self.engine?.isPlaying != true else { return }
            self.handle(.network(.timeout))
        }
    }

    private func cancelStallTimer() {
        stallTask?.cancel()
        stallTask = nil
    }

    private func handleEnded() {
        // End of file = fully watched (the last tick can be a second or more before the end).
        cancelStallTimer()
        if request?.isLive == false {
            // Unknown duration: the end position is the length, so the item is "watched" and leaves Continue watching.
            if duration > 0 { currentTime = duration } else if currentTime > 0 { duration = currentTime }
        }
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
        pausedByInterruption = false   // the user decides from here on
        systemPauseUnclaimed = false
        if reloadOnPlay, phase == .paused {
            resumePausedPlayback()
            return
        }
        guard let engine else { return }
        if case .reconnecting = phase {
            // Pause = user intent: no further attempts until play.
            retryTask?.cancel()
            cancelStallTimer()
            pauseEngine(engine)
            phase = .paused
            pausedDuringReconnect = true
            saveProgress()
        } else if pausedDuringReconnect, phase == .paused, stream != nil {
            resumePausedPlayback()
        } else if phase == .ended {
            // Play again from the start after the end of a VOD.
            audioSession.activate()
            seek(to: 0)
            engine.play()
        } else if engine.isPlaying || phase == .playing || phase == .buffering {
            // Intent, not only `isPlaying`: a pause during buffering must pause too (and must not
            // be "recovered" by the stall timer).
            cancelStallTimer()
            pauseEngine(engine)
            phase = .paused
            saveProgress()
        } else {
            audioSession.activate()
            engine.play()
        }
    }

    /// Pauses the engine (user-intent path). Input that cannot pause (live MPEG-TS in libVLC) is stopped
    /// instead – a no-op pause would keep playing – and play opens the request again.
    private func pauseEngine(_ engine: any PlaybackEngine) {
        if engine.canPause {
            engine.pause()
        } else {
            engine.stop()
            reloadOnPlay = true
        }
    }

    /// Plays again after a pause that left no live item: reopens the request (paused while opening, stopped
    /// non-pausable input, scene cycle), reloads a stream paused during a reconnect, otherwise `play()`.
    private func resumePausedPlayback() {
        if reloadOnPlay, var request {
            reloadOnPlay = false
            if !request.isLive, currentTime > 0 { request.startPositionMs = Int64(currentTime * 1000) }
            open(request)   // load() activates the audio session
        } else if pausedDuringReconnect, let stream {
            phase = .loading
            load(stream, startMs: request?.isLive == true ? nil : Int64(currentTime * 1000))
        } else {
            audioSession.activate()   // the session may have been deactivated (interruption, release)
            engine?.play()
        }
    }

    /// Audio interruption / lost output route (called by `AudioSessionObserver`; the only place that reacts to
    /// them). Every pause goes through the user-intent path (`engine.pause()`), so the engine does not treat
    /// it as a stall and resume it. An interruption that ends with `shouldResume` resumes only playback that
    /// it paused itself; a lost route (headphones unplugged) never resumes automatically. Also pauses
    /// while still loading or reconnecting (no endless spinner behind a phone call).
    public func handleAudioInterruption(_ event: AudioSessionEvent) {
        switch event {
        case .began, .routeLost:
            let resumable = pauseForSystem()
            pausedByInterruption = event == .began && resumable
            systemPauseUnclaimed = false
        case .ended(let shouldResume):
            // Anything the interruption did not pause itself (user, headphones, AirPlay) stays paused.
            let resume = shouldResume && pausedByInterruption && phase == .paused
            pausedByInterruption = false
            if resume { resumePausedPlayback() }
        }
    }

    /// Pauses for a system event; true when the playback was playing (or opening) and is now paused by the
    /// system, i.e. an interruption's end may resume it. A pause that already stood (user, headphones,
    /// AirPlay) is sticky – except an interruption pause the engine reported just before this notification.
    private func pauseForSystem() -> Bool {
        switch phase {
        case .playing, .buffering:
            guard let engine else { return false }
            cancelStallTimer()
            pauseEngine(engine)
            phase = .paused
            saveProgress()
            return true
        case .reconnecting:
            retryTask?.cancel()
            cancelStallTimer()
            if let engine { pauseEngine(engine) }
            phase = .paused
            pausedDuringReconnect = true
            saveProgress()
            return true
        case .loading:
            guard request != nil else { return false }
            // Nothing playing yet: drop the pending open (and a half-loaded item); play opens it again.
            openTask?.cancel()
            stopPlayback()
            phase = .paused
            reloadOnPlay = true
            return true
        case .paused:
            return systemPauseUnclaimed && request != nil
        default:
            return false
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

    // MARK: Audio sync

    /// Re-reads the effective delay of the current request (store or raw-URL session value).
    private func refreshAudioDelay() {
        let device = audioDelayStore?.deviceDelay ?? 0
        deviceAudioDelay = device
        if let key = request?.contentKey, let audioDelayStore {
            contentAudioDelay = audioDelayStore.contentDelay(key)
            currentAudioDelay = audioDelayStore.effectiveDelay(key)
        } else {
            contentAudioDelay = unkeyedContentDelay
            currentAudioDelay = AudioDelayStore.normalize(unkeyedContentDelay + device)
        }
    }

    /// The player's "Sync" control: stores the delay for the current content and applies it live.
    /// On AVPlayer (no audio delay) a delay ≠ 0 reloads the same position in VLCKit (CONTRACT §6.1).
    public func setAudioDelay(_ ms: Int) {
        let value = AudioDelayStore.normalize(ms)
        if let key = request?.contentKey, let audioDelayStore {
            audioDelayStore.setContentDelay(value, for: key)
        } else {
            unkeyedContentDelay = value
        }
        refreshAudioDelay()
        applyAudioDelay()
    }

    /// Settings → Playback → device/soundbar delay (added to every content).
    public func setDeviceAudioDelay(_ ms: Int) {
        audioDelayStore?.setDeviceDelay(ms)
        refreshAudioDelay()
        applyAudioDelay()
    }

    private func applyAudioDelay() {
        guard let engine, let stream, hasActiveItem else { return }
        if engine.kind == .vlcKit {
            engine.setAudioDelay(ms: currentAudioDelay)
        } else if currentAudioDelay != 0, engineKind(for: stream) == .vlcKit {
            SafeLog.info("audio delay \(currentAudioDelay) ms – reloading in vlckit")
            fallbackEngine = .vlcKit
            delayRoutedToVLC = true
            reload(stream)
        }
    }

    /// "Fix sync": reopens the stream – live at the live edge, VOD at the current position.
    public func resync() {
        guard let stream, hasActiveItem else { return }
        SafeLog.info("resync")
        reload(stream)
    }

    /// Reopens the current stream in place (sync / engine change): live at the live edge, VOD at the position.
    private func reload(_ stream: ResolvedStream) {
        retryTask?.cancel()
        reloadOnPlay = false
        pausedDuringReconnect = false
        pausedByInterruption = false
        systemPauseUnclaimed = false
        if phase == .paused || phase == .buffering { phase = .loading }
        load(stream, startMs: request?.isLive == true ? nil : Int64(currentTime * 1000))
    }

    /// A stream is loaded or playing (not idle / failed / locked / ended / paused without an item).
    private var hasActiveItem: Bool {
        switch phase {
        case .playing, .paused, .buffering, .loading, .reconnecting: return request != nil && !reloadOnPlay && !resolving
        case .idle, .failed, .locked, .ended: return false
        }
    }

    // MARK: Lifecycle

    /// Saves the position and frees the player (scene not active / screen closed).
    public func release() {
        saveProgress()
        openTask?.cancel()
        zapTask?.cancel()
        let wasPaused = phase == .paused
        stopPlayback()
        audioSession.deactivate()   // lets other apps' audio resume
        if wasPaused { pausedAtRelease = true }   // (a second release while idle keeps it)
        if phase != .locked, !isFailed { phase = .idle }
    }

    /// Re-opens the last request after `release()` (scene active again), resuming VOD.
    public func resumeAfterRelease() {
        guard var request, phase == .idle else { return }
        if pausedAtRelease {
            // Control Center, a call, Siri: the scene cycle must not undo a pause. Show the paused state;
            // play reopens at the saved position.
            pausedAtRelease = false
            reloadOnPlay = true
            phase = .paused
            return
        }
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
        pausedAtRelease = false
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
        pausedByInterruption = false
        systemPauseUnclaimed = false
        reloadOnPlay = false
        prefetcher?.cancelAll()
        prefetchedFor = nil
        retryTask?.cancel()
        probeTask?.cancel()
        cancelStallTimer()
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
