import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Task 4d: audio session hooks and system pauses. An audio interruption / lost output route is a
/// pause through the user-intent path (`engine.pause()`), so Task 4c's "a pause nobody asked for is
/// a stall" rule never auto-resumes it; the end of an interruption resumes only what it paused.
@MainActor
final class AudioSessionTests: XCTestCase {
    private var av: FakeEngine!
    private var activations = 0
    private var deactivations = 0

    private func controller() -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        self.av = av
        activations = 0
        deactivations = 0
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: nil, reconnectPolicy: ReconnectPolicy(delaysMs: [5_000, 5_000]),
                                 engines: PlaybackEngines(avPlayer: { av }, vlc: nil))
        c.audioSession = AudioSessionHooks(activate: { [unowned self] in activations += 1 },
                                           deactivate: { [unowned self] in deactivations += 1 })
        return c
    }

    /// Opens a stream and reports it playing.
    private func startPlaying(_ c: PlayerController, _ url: String = "http://h.example.com/live.m3u8") async throws {
        c.open(PlaybackRequest(item: .url(url, title: "x"), source: nil))
        for _ in 0..<200 where c.stream?.url.absoluteString != url || av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        av.isPlaying = true
        av.emit(.playing)
        XCTAssertEqual(c.phase, .playing)
    }

    // MARK: Interruptions

    func testInterruptionBeganPausesAndEndedWithShouldResumeResumes() async throws {
        let c = controller()
        try await startPlaying(c)
        c.handleAudioInterruption(.began)
        XCTAssertEqual(c.phase, .paused)
        XCTAssertFalse(av.isPlaying, "the engine got pause() – user-intent path")

        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertTrue(av.isPlaying, "resumed")
        av.emit(.playing)
        XCTAssertEqual(c.phase, .playing)
    }

    func testInterruptionEndedWithoutShouldResumeStaysPaused() async throws {
        let c = controller()
        try await startPlaying(c)
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.ended(shouldResume: false))
        XCTAssertEqual(c.phase, .paused)
        XCTAssertFalse(av.isPlaying)
    }

    /// The 4c rule must not fight the interruption pause: the engine's `.paused` stays paused and the
    /// 12 s stall timer (here 100 ms) never reconnects.
    func testInterruptionPauseIsNotAutoResumedOrReconnected() async throws {
        let c = controller()
        c.stallTimeout = .milliseconds(100)
        try await startPlaying(c)
        av.emit(.stalled)                        // a stall was in recovery when the call came in
        c.handleAudioInterruption(.began)
        av.emit(.paused)                         // the real engine reports the pause (wantsToPlay == false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.phase, .paused, "no stall timeout, no reconnect")
        XCTAssertFalse(av.isPlaying)
        XCTAssertEqual(av.loads.count, 1)
    }

    func testEndedDoesNotResumeAUserPause() async throws {
        let c = controller()
        try await startPlaying(c)
        c.togglePlayPause()                      // user pause
        XCTAssertEqual(c.phase, .paused)
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertEqual(c.phase, .paused)
        XCTAssertFalse(av.isPlaying, "the user's pause is not ours to undo")
    }

    func testUserPlayAfterInterruptionClearsTheAutoResume() async throws {
        let c = controller()
        try await startPlaying(c)
        c.handleAudioInterruption(.began)
        c.togglePlayPause()                      // user plays …
        av.emit(.playing)
        c.togglePlayPause()                      // … and pauses again
        XCTAssertEqual(c.phase, .paused)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertFalse(av.isPlaying, "a later user pause wins over the interruption's resume")
    }

    func testInterruptionSavesProgress() async throws {
        let library = LibraryRepository(database: try AppDatabase.inMemory())
        let engine = FakeEngine(kind: .avPlayer)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: library, engines: PlaybackEngines(avPlayer: { engine }, vlc: nil))
        let movie = Movie(sourceId: "s1", id: "m7", name: "Film", url: "http://h.example.com/film.mp4")
        var request = PlaybackRequest(item: .movie(movie), source: nil)
        request.sourceFingerprint = "fp"
        c.open(request)
        for _ in 0..<200 where engine.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        engine.isPlaying = true
        engine.emit(.playing)
        engine.emit(.ready(duration: 600))
        engine.emit(.time(120))
        c.handleAudioInterruption(.began)
        let saved = try library.progress(contentKey: ContentKey.make(fingerprint: "fp", kind: .movie, itemId: "m7"))
        XCTAssertEqual(saved?.data.positionMs, 120_000)
    }

    /// The engine reports the system's own pause first (rate change reason `audioSessionInterrupted`); the
    /// session notification arrives afterwards – the interruption must still resume it.
    func testEngineReportedSystemPauseStillResumesAfterInterruption() async throws {
        let c = controller()
        try await startPlaying(c)
        av.isPlaying = false
        av.emit(.paused)
        XCTAssertEqual(c.phase, .paused)
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertTrue(av.isPlaying)
    }

    // MARK: Loading / reconnecting

    func testInterruptionWhileLoadingPausesAndResumeReopens() async throws {
        let c = controller()
        c.open(PlaybackRequest(item: .url("http://h.example.com/live.m3u8", title: "x"), source: nil))
        XCTAssertEqual(c.phase, .loading)
        c.handleAudioInterruption(.began)
        XCTAssertEqual(c.phase, .paused, "no endless spinner behind a call")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(av.loads.isEmpty, "the pending open was dropped")
        XCTAssertEqual(c.phase, .paused)

        c.handleAudioInterruption(.ended(shouldResume: true))
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(av.loads.count, 1, "reopened")
        XCTAssertEqual(c.phase, .loading)
    }

    func testUserPlayWhilePausedDuringLoadingReopens() async throws {
        let c = controller()
        c.open(PlaybackRequest(item: .url("http://h.example.com/live.m3u8", title: "x"), source: nil))
        c.handleAudioInterruption(.routeLost)
        XCTAssertEqual(c.phase, .paused)
        c.togglePlayPause()
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(av.loads.count, 1)
    }

    func testInterruptionWhileReconnectingPausesAndResumeReloads() async throws {
        let c = controller()
        try await startPlaying(c)
        av.emit(.failed(.network(.other)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
        c.handleAudioInterruption(.began)
        XCTAssertEqual(c.phase, .paused)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(av.loads.count, 1, "no retry while paused")
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertEqual(av.loads.count, 2, "reconnect at once on resume")
        XCTAssertEqual(c.phase, .loading)
    }

    // MARK: Route change

    func testRouteLostPausesAndNeverAutoResumes() async throws {
        let c = controller()
        try await startPlaying(c)
        c.handleAudioInterruption(.routeLost)
        XCTAssertEqual(c.phase, .paused)
        XCTAssertFalse(av.isPlaying)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertEqual(c.phase, .paused, "headphones unplugged: only the user resumes")
        XCTAssertFalse(av.isPlaying)
    }

    func testRouteLostAfterInterruptionCancelsThePendingResume() async throws {
        let c = controller()
        try await startPlaying(c)
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.routeLost)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertFalse(av.isPlaying)
    }

    func testEventsWithoutPlaybackAreIgnored() {
        let c = controller()
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.ended(shouldResume: true))
        c.handleAudioInterruption(.routeLost)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(activations, 0)
    }

    // MARK: Session activation

    func testSessionIsActivatedOnLoadAndOnResumeAndDeactivatedOnRelease() async throws {
        let c = controller()
        try await startPlaying(c)
        XCTAssertEqual(activations, 1)
        c.handleAudioInterruption(.began)
        c.handleAudioInterruption(.ended(shouldResume: true))
        XCTAssertEqual(activations, 2, "the interruption deactivated the session: re-activate before play()")
        XCTAssertEqual(deactivations, 0)
        c.release()
        XCTAssertEqual(deactivations, 1)
    }

    func testCloseDeactivatesTheSession() async throws {
        let c = controller()
        try await startPlaying(c)
        c.close()
        XCTAssertEqual(deactivations, 1)
    }

    // MARK: Engine side of the rule

    #if canImport(AVFoundation)
    /// Pause cause classification (4c review): the system's reason decides, not a guess.
    func testPauseCauseClassification() {
        func cause(wants: Bool = true, finished: Bool = false, _ reason: AVPlayer.RateDidChangeReason?, external: Bool = false) -> AVPlayerEngine.PauseCause {
            AVPlayerEngine.pauseCause(wantsToPlay: wants, itemFinished: finished, rateReason: reason, externalPlayback: external)
        }
        XCTAssertEqual(cause(.audioSessionInterrupted), .system)
        XCTAssertEqual(cause(.appBackgrounded), .system)
        XCTAssertEqual(cause(nil, external: true), .system, "AirPlay receiver pause")
        XCTAssertEqual(cause(nil), .stall, "no reason: a stall")
        XCTAssertEqual(cause(.setRateFailed), .stall)
        XCTAssertEqual(cause(finished: true, .audioSessionInterrupted), .none, "finished item")
        XCTAssertEqual(cause(wants: false, .audioSessionInterrupted), .none, "the user already paused")
    }

    /// `PlayerController.handleAudioInterruption(.began)` calls `engine.pause()`; for the real engine
    /// that clears the playback intent, which is what makes AVPlayer's own interruption pause a
    /// real pause (`.paused`) instead of a stall (`.buffering` + automatic resume).
    func testAVPlayerEnginePauseClearsPlaybackIntent() {
        let engine = AVPlayerEngine()
        engine.play()
        XCTAssertTrue(engine.wantsToPlay)
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: engine.wantsToPlay, itemFinished: false), .buffering,
                       "an unrequested pause is a stall")
        engine.pause()
        XCTAssertFalse(engine.wantsToPlay)
        XCTAssertEqual(AVPlayerEngine.eventForPausedStatus(wantsToPlay: engine.wantsToPlay, itemFinished: false), .paused,
                       "after pause() the paused status stays paused (no auto-resume)")
    }
    #endif
}
