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
/// Limits of the spike: one muxed audio track (preferred language, else the default), no subtitles,
/// no audio delay (a later step can shift the audio timestamps instead), no AirPlay video (the
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

    init() {
        inner.player.allowsExternalPlayback = false
        inner.onEvent = { [weak self] event in self?.forward(event) }
    }

    var isPlaying: Bool { inner.isPlaying }
    var canPause: Bool { true }
    var diagnostics: EngineDiagnostics { inner.diagnostics }

    func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?,
              preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        closeSession()
        inner.stop()
        generation += 1
        let generation = generation
        let started = SystemClock.monotonicMs()
        onEvent?(.buffering)
        bench = RemuxBench.enabled ? RemuxBench(engine: self, started: started) : nil
        openTask = Task { [weak self] in
            do {
                let port = try await RemuxHTTPServer.shared.start()
                let session = try await RemuxSession.open(url: stream.url, headers: stream.headers,
                                                          audioLanguage: preferredAudioLanguage.flatMap(TrackNaming.normalized))
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

    /// Source HTTP errors keep their meaning (403 → card); what the remuxer cannot handle (no cues,
    /// VP9/AV1/MPEG-2 video, broken file) is `UnsupportedFormat` → the controller retries in VLCKit.
    static func map(_ error: Error, isLive: Bool) -> PlaybackError {
        guard let remux = error as? RemuxSession.RemuxError else { return .network(.other) }
        switch remux {
        case .open(let code, _) where code >= 400 && code < 600:
            return ErrorClassifier.playbackError(httpStatus: Int(code)) ?? .network(.other)
        case .open(let code, _) where code == -1:
            return .network(.other)
        case .open:
            return .unsupportedFormat(container: StreamContainer.mkv.rawValue)
        case .segment, .cancelled:
            return .network(.other)
        }
    }

    private func forward(_ event: EngineEvent) {
        bench?.event(event)
        onEvent?(event)
    }

    func play() { inner.play() }
    func pause() { inner.pause() }

    func seek(to seconds: Double) {
        bench?.seekStarted(seconds)
        inner.seek(to: seconds)
    }

    func selectAudio(_ id: Int) { inner.selectAudio(id) }
    func selectSubtitle(_ id: Int?) { inner.selectSubtitle(id) }
    func setAspect(_ mode: AspectMode) { inner.setAspect(mode) }
    /// Not applied yet (spike); a production version shifts the audio timestamps in the remuxer.
    func setAudioDelay(ms: Int) {}
    // Build 17: background audio / PiP act on the inner AVPlayer (AirPlay stays audio-only: loopback URL).
    func setBackgroundPlayback(allowed: Bool) { inner.setBackgroundPlayback(allowed: allowed) }
    func setPictureInPictureActive(_ active: Bool) { inner.setPictureInPictureActive(active) }

    func stop() {
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
            Task { await runSeeks() }
        }
    }

    func seekStarted(_ target: Double) {
        seekStart = (target, SystemClock.monotonicMs())
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
