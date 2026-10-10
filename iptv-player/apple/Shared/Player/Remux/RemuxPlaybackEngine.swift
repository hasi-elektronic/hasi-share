#if canImport(CNovaRemux)
import AVFoundation
import CNovaRemux
import Foundation
import IPTVCore
import IPTVKit

/// "Apple + Remux (Beta)" (spike, CONTRACT §6.1 rule −1 `remux`): MKV (H.264/HEVC + any audio) is
/// remuxed on the fly by FFmpeg (`RemuxSession`, no video re-encode) into HLS with fMP4 segments,
/// served from 127.0.0.1 (`RemuxHTTPServer`) and played by a private `AVPlayerEngine` – so A/V sync,
/// output-latency compensation, buffering and seeking are AVPlayer's own.
///
/// Audio (Build 20): one track is muxed (preferred language, else the default); the audio menu lists every
/// source track and a choice reopens the session with that track at the current position.
/// Subtitles (Build 21): the text tracks' cues are read while segments are generated (`SubtitleCueStore`)
/// and drawn by `RemuxSubtitleOverlay`; switching or turning them off is instant (no reopen).
/// Audio delay (Build 22): baked into the segments by the remuxer; a change reopens at the position (debounced).
/// Limits: no bitmap (PGS/VobSub) subtitles (a later step can shift the audio timestamps instead), no AirPlay video (the
/// receiver cannot reach the phone's loopback server – external playback is disabled).
@MainActor
final class RemuxPlaybackEngine: PlaybackEngine {
    let kind: PlayerEngine = .avRemux
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    /// The AVPlayer engine that plays the local HLS (the video surface shows its `player`).
    let inner = AVPlayerEngine()

    private var session: RemuxSession?
    private var openTask: Task<Void, Never>?
    private var generation = 0
    private var bench: RemuxBench?
    /// Arguments of the last `load` (an audio switch reopens with them).
    private var lastLoad: (stream: ResolvedStream, isLive: Bool, subtitle: String?, tuning: LiveStartTuning)?
    /// Source audio tracks and the muxed one (source stream index).
    private var audioTracks: [SourceAudioTrack] = []
    private var muxedAudioStream = -1
    /// Text subtitle cues of the current item (kept across an audio switch – same file).
    let cues = SubtitleCueStore()
    private(set) var subtitleTracks: [SourceSubtitleTrack] = []
    /// Menu position of the shown subtitle track (nil = off).
    private(set) var selectedSubtitleTrack: Int?
    private var preferredSubtitle: String?
    private var subtitleDelayMs = 0
    /// Content audio delay (ms, + = audio later) the open session was built with / the next one gets.
    private var audioDelayMs = 0
    private var delayTask: Task<Void, Never>?
    /// The current item showed a frame (later failures are real playback errors, earlier ones fall back to VLCKit).
    private var playedThisLoad = false
    /// The inner AVPlayer's last track report (its own legible options when the source has no text tracks).
    private var innerSubtitles: (options: [MediaOption], selected: Int?) = ([], nil)

    init() {
        inner.player.allowsExternalPlayback = false
        inner.onEvent = { [weak self] event in self?.forward(event) }
    }

    var isPlaying: Bool { inner.isPlaying }
    var canPause: Bool { true }
    var diagnostics: EngineDiagnostics { inner.diagnostics }

    func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?,
              preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        lastLoad = (stream, isLive, preferredSubtitleLanguage, tuning)
        delayTask?.cancel()   // a delay set just before this load belongs to this item, not to a reopen of the old one
        playedThisLoad = false
        cues.removeAll()
        subtitleTracks = []
        selectedSubtitleTrack = nil
        preferredSubtitle = preferredSubtitleLanguage
        innerSubtitles = ([], nil)
        // One bench per load (an audio switch reopens the session but keeps the measurement).
        bench = RemuxBench.enabled ? RemuxBench(engine: self, started: SystemClock.monotonicMs()) : nil
        audioTracks = []
        muxedAudioStream = -1
        open(stream, isLive: isLive, startMs: startMs, audioLanguage: preferredAudioLanguage, audioStream: nil,
             preferredSubtitleLanguage: preferredSubtitleLanguage, tuning: tuning)
    }

    private func open(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, audioLanguage preferredAudioLanguage: String?,
                      audioStream: Int?, preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        closeSession()
        inner.stop()
        generation += 1
        let generation = generation
        let started = SystemClock.monotonicMs()
        onEvent?(.buffering)
        let delayMs = audioDelayMs
        openTask = Task { [weak self] in
            do {
                let port = try await RemuxHTTPServer.shared.start()
                let session = try await RemuxSession.open(url: stream.url, headers: stream.headers,
                                                          audioLanguage: preferredAudioLanguage.flatMap(TrackNaming.normalized),
                                                          audioStream: audioStream, audioDelayMs: delayMs)
                guard let self, !Task.isCancelled, self.generation == generation else { session.close(); return }
                let info = session.info
                SafeLog.info("remux open \(SystemClock.monotonicMs() - started) ms: \(info.videoCodec) \(info.width)x\(info.height) "
                             + "\(info.codecs) \(info.videoRange), audio \(info.audioIn)→\(info.audioOut)\(info.audioTranscoded ? " (transcode)" : "") "
                             + "\(info.audioChannels) ch of \(info.audioTrackCount), \(info.segments.count) segments ≤ \(String(format: "%.1f", info.targetDuration)) s, "
                             + "index read \(info.openBytes / 1024) KiB")
                session.onSegment = { timing in
                    SafeLog.debug(String(format: "remux seg %d %@ %.1f ms (audio enc %.1f ms) %d KiB", timing.index,
                                         timing.prefetch ? "prefetch" : "request", timing.ms, timing.encodeMs, timing.bytes / 1024))
                }
                RemuxHTTPServer.shared.register(session)
                self.session = session
                self.audioTracks = info.audioTracks.map {
                    SourceAudioTrack(streamIndex: $0.streamIndex, language: $0.language, codec: $0.codec,
                                     channels: $0.channels, title: $0.title)
                }
                self.muxedAudioStream = info.audioStreamIndex
                let cues = self.cues
                session.onCue = { stream, start, end, text in cues.add(stream: stream, cue: SubtitleCue(start: start, end: end, text: text)) }
                if self.subtitleTracks.isEmpty, !info.subtitleTracks.isEmpty {
                    self.subtitleTracks = info.subtitleTracks.map {
                        SourceSubtitleTrack(streamIndex: $0.streamIndex, language: $0.language, title: $0.title,
                                            isDefault: $0.isDefault, isForced: $0.isForced)
                    }
                    self.selectedSubtitleTrack = SourceSubtitleTracks.initialSelection(self.subtitleTracks, preferred: self.preferredSubtitle)
                }
                self.bench?.opened(info: info)
                let local = ResolvedStream(url: RemuxHTTPServer.shared.url(for: session, port: port), container: .hls, headers: [:])
                self.inner.load(local, isLive: false, startMs: startMs, preferredAudioLanguage: preferredAudioLanguage,
                                preferredSubtitleLanguage: preferredSubtitleLanguage, tuning: tuning)
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                let mapped = Self.map(error, isLive: isLive)
                SafeLog.warning("remux open failed: \(error) → \(mapped)")
                self.onEvent?(.failed(mapped))
            }
        }
    }

    /// Any open failure is `UnsupportedFormat` → the controller retries once in VLCKit (Build 23); a segment error after
    /// the open is a network error (before the first frame `forward` turns it into a fallback too).
    static func map(_ error: Error, isLive: Bool) -> PlaybackError {
        guard let remux = error as? RemuxSession.RemuxError else { return .unsupportedFormat(container: StreamContainer.mkv.rawValue) }
        switch remux {
        case .open:
            // Build 23: whatever the remuxer cannot open falls back once to VLCKit, which reads the file sequentially and
            // classifies a real HTTP error itself (its own error card). Servers without byte ranges answer 200
            // (`notSeekable`) or reject the Range header (400/403/416…) – common for Xtream series; timeouts, transport
            // errors, no cues and other codecs too. Before, these counted as network errors: 5 reconnects into the same
            // remuxer, then "Connection lost" (series did not play on Apple TV, Builds 19–22).
            return .unsupportedFormat(container: StreamContainer.mkv.rawValue)
        case .segment, .cancelled:
            return .network(.other)
        }
    }

    private func forward(_ event: EngineEvent) {
        bench?.event(event)
        if case .playing = event { playedThisLoad = true }
        // Build 23: a failure before the first frame (segment generation / local HLS) → VLCKit once, like an open failure.
        if case .failed(let error) = event, !playedThisLoad {
            SafeLog.warning("remux failed before the first frame: \(error) → VLCKit")
            onEvent?(.failed(.unsupportedFormat(container: StreamContainer.mkv.rawValue)))
            return
        }
        // The local HLS carries one audio track and no subtitles: the menus show the source's tracks instead.
        if case .tracks(let audio, let subtitles, let selectedAudio, let selectedSubtitle) = event,
           !audioTracks.isEmpty || !subtitleTracks.isEmpty {
            innerSubtitles = (subtitles, selectedSubtitle)
            reportTracks(innerAudio: (audio, selectedAudio))
            return
        }
        onEvent?(event)
    }

    private var innerAudio: (options: [MediaOption], selected: Int?) = ([], nil)

    private func reportTracks(innerAudio: (options: [MediaOption], selected: Int?)? = nil) {
        if let innerAudio { self.innerAudio = innerAudio }
        let audio = audioTracks.isEmpty ? self.innerAudio.options : SourceAudioTracks.options(audioTracks)
        let selectedAudio = audioTracks.isEmpty ? self.innerAudio.selected : SourceAudioTracks.index(of: muxedAudioStream, in: audioTracks)
        let subtitles = subtitleTracks.isEmpty ? innerSubtitles.options : SourceSubtitleTracks.options(subtitleTracks)
        let selectedSubtitle = subtitleTracks.isEmpty ? innerSubtitles.selected : selectedSubtitleTrack
        onEvent?(.tracks(audio: audio, subtitles: subtitles, selectedAudio: selectedAudio, selectedSubtitle: selectedSubtitle))
    }

    // MARK: Subtitles (Build 21)

    /// Texts to show at the player's current time (overlay, main thread), shifted by the subtitle delay.
    func subtitleTexts() -> [String] {
        guard let index = selectedSubtitleTrack, subtitleTracks.indices.contains(index) else { return [] }
        let now = inner.player.currentTime().seconds
        guard now.isFinite else { return [] }
        return cues.texts(stream: subtitleTracks[index].streamIndex, at: now - Double(subtitleDelayMs) / 1000)
    }

    var supportsSubtitleDelay: Bool { true }
    func setSubtitleDelay(ms: Int) { subtitleDelayMs = ms }

    func play() { inner.play() }
    func pause() { inner.pause() }

    func seek(to seconds: Double) {
        bench?.seekStarted(seconds)
        inner.seek(to: seconds)
    }

    /// Another source track: reopen the session with it at the current position (≈ 1–2 s rebuffer).
    func selectAudio(_ id: Int) {
        guard audioTracks.indices.contains(id), lastLoad != nil else { return }
        let wanted = audioTracks[id].streamIndex
        guard wanted != muxedAudioStream else { return }
        reopenAtPosition(audioStream: wanted, reason: "audio switch → stream \(wanted)")
    }

    /// Reopens the current item at the player's position (audio track / delay change); menus stay as they are.
    private func reopenAtPosition(audioStream: Int, reason: String) {
        guard let last = lastLoad else { return }
        let seconds = inner.player.currentTime().seconds
        let startMs = seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : nil
        SafeLog.info("remux \(reason) at \(startMs ?? 0) ms")
        let tracks = audioTracks
        inner.stop()
        open(last.stream, isLive: last.isLive, startMs: startMs, audioLanguage: nil, audioStream: audioStream >= 0 ? audioStream : nil,
             preferredSubtitleLanguage: last.subtitle, tuning: last.tuning)
        // Keep the menu while the session reopens (the new one reports the same list).
        audioTracks = tracks
        muxedAudioStream = audioStream
    }
    func selectSubtitle(_ id: Int?) {
        guard !subtitleTracks.isEmpty else { inner.selectSubtitle(id); return }
        selectedSubtitleTrack = id.flatMap { subtitleTracks.indices.contains($0) ? $0 : nil }
        reportTracks()
    }
    func setAspect(_ mode: AspectMode) { inner.setAspect(mode) }
    /// Build 22: the remuxer shifts the audio in every segment; a change reopens at the position after 0.6 s without
    /// further changes (stepper presses are merged). Before a load it is just remembered for that item.
    func setAudioDelay(ms: Int) {
        let clamped = min(max(ms, -2000), 2000)
        guard clamped != audioDelayMs else { return }
        audioDelayMs = clamped
        delayTask?.cancel()
        guard session != nil, lastLoad != nil else { return }
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.lastLoad != nil else { return }
            self.reopenAtPosition(audioStream: self.muxedAudioStream, reason: "audio delay \(self.audioDelayMs) ms")
        }
    }
    // Build 17: background audio / PiP act on the inner AVPlayer (AirPlay stays audio-only: loopback URL).
    func setBackgroundPlayback(allowed: Bool) { inner.setBackgroundPlayback(allowed: allowed) }
    func setPictureInPictureActive(_ active: Bool) { inner.setPictureInPictureActive(active) }

    func stop() {
        delayTask?.cancel()
        lastLoad = nil
        cues.removeAll()
        subtitleTracks = []
        selectedSubtitleTrack = nil
        audioTracks = []
        muxedAudioStream = -1
        generation += 1
        openTask?.cancel()
        openTask = nil
        inner.stop()
        closeSession()
        bench = nil
    }

    private func closeSession() {
        guard let session else { return }
        RemuxHTTPServer.shared.unregister(session)
        session.close()
        self.session = nil
    }

    /// Segment timings (bench / diagnostics).
    var segmentTimings: [RemuxSession.SegmentTiming] { session?.segmentTimings ?? [] }
    var sourceStats: RemuxByteSource.Stats? { session?.byteStats }
}

/// DEBUG measurement driver (`-remuxBench <url>`): logs time to first frame, then seeks to 10 %, 50 %
/// and 90 % of the film and logs the time until playback runs again, plus AVPlayer's access/error log.
@MainActor
final class RemuxBench {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-remuxBench")
        #else
        false
        #endif
    }

    private weak var engine: RemuxPlaybackEngine?
    private let started: Int64
    private var openedAt: Int64?
    private var duration: Double = 0
    private var firstFrameAt: Int64?
    private var seekStart: (target: Double, at: Int64)?
    private var results: [String] = []

    init(engine: RemuxPlaybackEngine, started: Int64) {
        self.engine = engine
        self.started = started
    }

    func opened(info: RemuxSession.Info) {
        openedAt = SystemClock.monotonicMs()
        duration = info.duration
        log("open \(openedAt! - started) ms")
    }

    func event(_ event: EngineEvent) {
        guard case .playing = event else { return }
        let now = SystemClock.monotonicMs()
        if firstFrameAt == nil {
            firstFrameAt = now
            log("first frame \(now - started) ms (after open \(now - (openedAt ?? started)) ms)")
            // `-remuxBenchSubtitle <menu index>`: show that text subtitle track (Build 21 overlay checks).
            if let raw = AppBootstrap.argument("-remuxBenchSubtitle"), let id = Int(raw) {
                engine?.selectSubtitle(id)
                Task { @MainActor [weak engine] in
                    for _ in 0..<6 {
                        try? await Task.sleep(for: .seconds(1))
                        guard let engine else { return }
                        log("subtitles: \(engine.subtitleTracks.count) tracks, selected \(engine.selectedSubtitleTrack.map(String.init) ?? "off"), "
                            + "\(engine.cues.count) cues, t=\(String(format: "%.2f", engine.inner.player.currentTime().seconds)), on screen \(engine.subtitleTexts())")
                    }
                }
            }
            // `-remuxBenchAudio <menu index>`: audio switch measurement instead of the seeks (Build 20).
            if let raw = AppBootstrap.argument("-remuxBenchDelay"), let ms = Int(raw) {
                Task { await runDelayChange(to: ms) }
            } else if let raw = AppBootstrap.argument("-remuxBenchAudio"), let id = Int(raw) {
                Task { await runAudioSwitch(to: id) }
            } else {
                Task { await runSeeks() }
            }
        }
    }

    func seekStarted(_ target: Double) {
        seekStart = (target, SystemClock.monotonicMs())
    }

    private func runAudioSwitch(to id: Int) async {
        try? await Task.sleep(for: .seconds(8))
        guard let engine else { return }
        let player = engine.inner.player
        let before = player.currentTime().seconds
        let t0 = SystemClock.monotonicMs()
        engine.selectAudio(id)
        // The new session's player: playing again and time advancing.
        var resumedAt = -1.0
        while SystemClock.monotonicMs() - t0 < 20_000 {
            try? await Task.sleep(for: .milliseconds(10))
            let p = engine.inner.player
            let t = p.currentTime().seconds
            if p.timeControlStatus == .playing, t > 0.5, resumedAt < 0 { resumedAt = t }
            if resumedAt >= 0, t > resumedAt + 0.1 { break }
        }
        log(String(format: "audio switch → %d: playing after %lld ms, position %.2f → %.2f s", id,
                   SystemClock.monotonicMs() - t0, before, engine.inner.player.currentTime().seconds))
        log("done")
    }

    /// `-remuxBenchDelay <ms>` (Build 22): three quick delay steps (merged by the debounce) → one reopen at the position.
    private func runDelayChange(to ms: Int) async {
        try? await Task.sleep(for: .seconds(8))
        guard let engine else { return }
        let before = engine.inner.player.currentTime().seconds
        let t0 = SystemClock.monotonicMs()
        engine.setAudioDelay(ms: ms / 3)
        engine.setAudioDelay(ms: 2 * ms / 3)
        engine.setAudioDelay(ms: ms)
        try? await Task.sleep(for: .milliseconds(700))   // debounce fired, session reopening
        var resumedAt = -1.0
        while SystemClock.monotonicMs() - t0 < 20_000 {
            try? await Task.sleep(for: .milliseconds(10))
            let p = engine.inner.player
            let t = p.currentTime().seconds
            if p.timeControlStatus == .playing, t > 0.5, resumedAt < 0 { resumedAt = t }
            if resumedAt >= 0, t > resumedAt + 0.1 { break }
        }
        log(String(format: "audio delay → %d ms: playing after %lld ms, position %.2f → %.2f s", ms,
                   SystemClock.monotonicMs() - t0, before, engine.inner.player.currentTime().seconds))
        log("done")
    }

    private func runSeeks() async {
        try? await Task.sleep(for: .seconds(5))
        for fraction in [0.1, 0.5, 0.9] {
            guard let engine, duration > 0 else { return }
            let target = duration * fraction
            let t0 = SystemClock.monotonicMs()
            engine.seek(to: target)
            let player = engine.inner.player
            // Playing again: time advanced past the seek target's neighbourhood.
            var landed = -1.0
            while SystemClock.monotonicMs() - t0 < 20_000 {
                try? await Task.sleep(for: .milliseconds(10))
                let t = player.currentTime().seconds
                if player.timeControlStatus == .playing, abs(t - target) < 15, landed < 0 { landed = t }
                if landed >= 0, t > landed + 0.1 { break }
            }
            log(String(format: "seek %.0f%% → %.1f s: playing after %lld ms (t=%.2f)", fraction * 100, target,
                       SystemClock.monotonicMs() - t0, player.currentTime().seconds))
            try? await Task.sleep(for: .seconds(5))
        }
        guard let engine else { return }
        if let item = engine.inner.player.currentItem {
            for e in item.accessLog()?.events ?? [] {
                log(String(format: "access: stalls=%d dropped=%d startup=%.3f s indicated=%.0f b/s requests=%d",
                           e.numberOfStalls, e.numberOfDroppedVideoFrames, e.startupTime, e.indicatedBitrate, e.numberOfMediaRequests))
            }
            for e in item.errorLog()?.events ?? [] { log("errorlog: \(e.errorStatusCode) \(e.errorDomain)") }
        }
        let timings = engine.segmentTimings
        if !timings.isEmpty {
            let gen = timings.map(\.ms)
            let enc = timings.map(\.encodeMs)
            log(String(format: "segments %d: gen avg %.1f max %.1f ms, audio enc avg %.1f ms", timings.count,
                       gen.reduce(0, +) / Double(gen.count), gen.max() ?? 0, enc.reduce(0, +) / Double(enc.count)))
        }
        if let s = engine.sourceStats {
            log(String(format: "source: %d requests, %lld KiB, wait %.0f ms", s.requests, s.bytes / 1024, s.waitMs))
        }
        log("done")
    }

    private func log(_ text: String) {
        SafeLog.info("REMUXBENCH \(text)")
    }
}

extension AVPlayerEngine {
    /// The engine whose `player` a video surface shows (AVPlayer itself or the remux engine's inner one).
    @MainActor static func backing(_ engine: (any PlaybackEngine)?) -> AVPlayerEngine? {
        if let av = engine as? AVPlayerEngine { return av }
        return (engine as? RemuxPlaybackEngine)?.inner
    }
}
#endif
