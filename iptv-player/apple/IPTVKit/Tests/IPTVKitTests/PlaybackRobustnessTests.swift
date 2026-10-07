import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Task 4c (SCREENS §3.7, §4): AVPlayer failures before the first frame are classified with the HTTP
/// probe (AccessDenied / StreamOffline / ServerError instead of an endless reconnect spinner), a
/// not-ready AVPlayer is probed after 8 s, and stall recovery stays bounded by the stall timeout.
@MainActor
final class PlaybackRobustnessTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!
    private var probes: [URL] = []

    private func controller(probeStatus: Int?, policy: ReconnectPolicy = ReconnectPolicy(delaysMs: [5_000, 5_000])) -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        probes = []
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, vlcAvailable: true),
                                 library: nil, reconnectPolicy: policy, engines: PlaybackEngines(avPlayer: { av }, vlc: { vlc }))
        c.probe = { [unowned self] url, _ in
            self.probes.append(url)
            return VLCFailureClassifier.Probe(httpStatus: probeStatus, transportError: nil)
        }
        return c
    }

    private func open(_ c: PlayerController, _ url: String) async throws {
        c.open(PlaybackRequest(item: .url(url, title: "x"), source: nil))
        for _ in 0..<200 where c.stream?.url.absoluteString != url { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.stream?.url.absoluteString, url)
    }

    /// Waits (≤ 1 s) until `condition` holds.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func isFailed(_ c: PlayerController) -> Bool {
        if case .failed = c.phase { return true }
        return false
    }

    // MARK: Failure before the first frame → probe

    func testAVPlayerFailureBeforeReadyIsClassifiedByProbe() async throws {
        let c = controller(probeStatus: 403)
        try await open(c, "http://h.example.com/movie.mp4")
        av.emit(.failed(.network(.other)))   // e.g. NSURLErrorResourceUnavailable without a status
        try await eventually { isFailed(c) }
        XCTAssertEqual(c.phase, .failed(.accessDenied(httpStatus: 403)))
        XCTAssertEqual(probes.map(\.absoluteString), ["http://h.example.com/movie.mp4"])
        XCTAssertEqual(av.loads.count, 1, "no reconnect for 403")
    }

    func testProbeMaps410AndServerErrors() async throws {
        var c = controller(probeStatus: 410)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.failed(.unknown(message: "x")))
        try await eventually { isFailed(c) }
        XCTAssertEqual(c.phase, .failed(.streamOffline(httpStatus: 410)))

        // 5xx stays recoverable (CONTRACT §2) – once the policy gives up the card says ServerError.
        c = controller(probeStatus: 503, policy: ReconnectPolicy(delaysMs: []))
        try await open(c, "http://h.example.com/b.mp4")
        av.emit(.failed(.network(.other)))
        try await eventually { isFailed(c) }
        XCTAssertEqual(c.phase, .failed(.serverError(httpStatus: 503)))
    }

    func testProbeWithoutHTTPErrorKeepsOriginalError() async throws {
        let c = controller(probeStatus: 206)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.failed(.network(.other)))
        try await eventually { c.phase != .loading }
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
        XCTAssertEqual(probes.count, 1)
    }

    func testFailureAfterPlayingIsNotProbed() async throws {
        let c = controller(probeStatus: 403)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.ready(duration: 600))
        av.emit(.playing)
        av.emit(.failed(.network(.other)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2), "a drop after playback reconnects at once")
        XCTAssertTrue(probes.isEmpty)
    }

    func testClassifiedErrorsAndVLCFailuresAreNotProbed() async throws {
        var c = controller(probeStatus: 500)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.failed(.accessDenied(httpStatus: 403)))
        XCTAssertEqual(c.phase, .failed(.accessDenied(httpStatus: 403)))

        // VLCKit classifies its own failures with the probe (VLCPlaybackEngine).
        c = controller(probeStatus: 500)
        try await open(c, "http://h.example.com/a.mkv")
        XCTAssertEqual(c.engineKind, .vlcKit)
        vlc.emit(.failed(.network(.other)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
        XCTAssertTrue(probes.isEmpty)
    }

    // MARK: Not ready for 8 s → probe

    func testNotReadyAVPlayerIsProbedAfterDelay() async throws {
        let c = controller(probeStatus: 403)
        c.notReadyProbeDelay = .milliseconds(50)
        try await open(c, "http://h.example.com/a.mp4")
        XCTAssertEqual(c.phase, .loading)
        try await eventually { isFailed(c) }
        XCTAssertEqual(c.phase, .failed(.accessDenied(httpStatus: 403)))
    }

    func testNotReadyProbeIsQuietWhenReadyOrServerAnswers() async throws {
        var c = controller(probeStatus: 403)
        c.notReadyProbeDelay = .milliseconds(50)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.ready(duration: 600))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(probes.isEmpty, "ready in time: no probe")
        XCTAssertFalse(isFailed(c))

        c = controller(probeStatus: 206)
        c.notReadyProbeDelay = .milliseconds(50)
        try await open(c, "http://h.example.com/b.mp4")
        try await eventually { !probes.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.phase, .loading, "server answers: keep waiting for AVPlayer")
    }

    // MARK: Stall recovery bounds

    /// The engine reports every unexpected pause as a stall; repeated stalls keep the FIRST deadline,
    /// so a player that keeps dropping to paused ends in the reconnect policy.
    func testRepeatedStallsKeepTheFirstDeadline() async throws {
        let c = controller(probeStatus: nil)
        c.stallTimeout = .milliseconds(300)
        try await open(c, "http://h.example.com/live.m3u8")
        av.emit(.ready(duration: 0))
        av.emit(.playing)
        av.emit(.buffering)
        av.emit(.stalled)
        try await Task.sleep(for: .milliseconds(200))
        av.emit(.stalled)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2), "timeout 300 ms after the first stall")
    }

    /// A real pause (engine `.paused`, or the user's pause during buffering) ends the stall timer –
    /// it must not reconnect (and thereby resume) a paused player.
    func testPauseCancelsStallTimer() async throws {
        let c = controller(probeStatus: nil)
        c.stallTimeout = .milliseconds(100)
        try await open(c, "http://h.example.com/live.m3u8")
        av.emit(.playing)
        av.emit(.stalled)
        av.emit(.paused)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(c.phase, .paused, "engine pause")

        c.togglePlayPause()   // play
        av.emit(.playing)
        av.emit(.buffering)
        av.emit(.stalled)
        c.togglePlayPause()   // user pause while buffering
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(c.phase, .paused, "user pause")
    }

    // MARK: 4c review fixes

    /// The 8 s not-ready watchdog probes VOD only: a second connection to a live panel could be refused itself.
    func testNotReadyWatchdogDoesNotProbeLive() async throws {
        let c = controller(probeStatus: 403)
        c.notReadyProbeDelay = .milliseconds(30)
        let channel = Channel(sourceId: "s1", id: "c1", name: "Live", url: "http://h.example.com/live.m3u8")
        c.open(PlaybackRequest(item: .channel(channel), source: nil))
        try await eventually { !av.loads.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(probes.isEmpty)
        XCTAssertEqual(c.phase, .loading)
    }

    /// An unreachable host (probe transport error, no HTTP status) ends the not-ready wait with its specific
    /// network reason (reconnect policy) instead of an endless spinner.
    func testProbeTransportErrorEndsNotReadyWait() async throws {
        let c = controller(probeStatus: nil)
        c.notReadyProbeDelay = .milliseconds(30)
        c.probe = { _, _ in VLCFailureClassifier.Probe(httpStatus: nil, transportError: .network(.dns)) }
        try await open(c, "http://h.example.com/a.mp4")
        try await eventually { c.phase != .loading }
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
    }

    /// The end of an item cancels a pending stall timer (no reconnect of a finished VOD).
    func testEndCancelsStallTimer() async throws {
        let c = controller(probeStatus: nil)
        c.stallTimeout = .milliseconds(80)
        try await open(c, "http://h.example.com/a.mp4")
        av.emit(.playing)
        av.emit(.stalled)
        av.emit(.ended)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(c.phase, .ended)
    }
}

/// Final review I3: while a new `open()` resolves, the engine still plays (or fails) the previous item.
/// Its events must not count for the new request: no phase flip, no first frame, no last-session
/// record, no reconnect of the old stream.
@MainActor
final class StaleEngineEventTests: XCTestCase {
    private let a = TestData.channel(id: "a", url: "http://cdn.example.com/a.m3u8")
    /// Xtream-shaped M3U `.ts` URL: the resolver probes its HLS twin (slow probe = long resolve window).
    private let b = TestData.channel(id: "b", url: "http://panel.example.com:8080/u/p/2.ts")

    private func make() -> (PlayerController, FakeEngine, () -> [LastSession?]) {
        let av = FakeEngine(kind: .avPlayer)
        let resolver = StreamResolver(secrets: { _ in nil }, sniffer: nil, hlsProbe: { _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return true
        }, vlcAvailable: false)
        let c = PlayerController(resolver: resolver, library: nil, reconnectPolicy: ReconnectPolicy(delaysMs: [30, 30]),
                                 engines: PlaybackEngines(avPlayer: { av }, vlc: nil))
        var events: [LastSession?] = []
        c.onLastSessionChange = { events.append($0) }
        return (c, av, { events })
    }

    private func settle(_ cond: @autoclosure () -> Bool) async throws {
        for _ in 0..<200 where !cond() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Opens A, plays it, then opens B (resolve in flight).
    private func zapToBWhileResolving(_ c: PlayerController, _ av: FakeEngine) async throws {
        c.open(PlaybackRequest(item: .channel(a), source: nil, channels: [a, b]))
        try await settle(av.loads.count == 1)
        av.emit(.playing)
        XCTAssertEqual(c.phase, .playing)
        c.open(PlaybackRequest(item: .channel(b), source: nil, channels: [a, b]))
        XCTAssertEqual(c.phase, .loading)
    }

    func testStalePlayingDuringResolveIsIgnored() async throws {
        let (c, av, events) = make()
        try await zapToBWhileResolving(c, av)
        av.emit(.playing)   // A's item (re)starts playing inside B's resolve window
        XCTAssertEqual(c.phase, .loading, "spinner stays until B plays")
        XCTAssertNil(PerfTrace.shared.interval(from: .playRequested, to: .firstFrame), "no first frame for B")
        XCTAssertEqual(events(), [LastSession(sourceId: "s1", channelId: "a", endedInPlayer: true)], "no record for B")

        try await settle(av.loads.count == 2)
        XCTAssertEqual(av.loads.last?.url.absoluteString, "http://panel.example.com:8080/u/p/2.m3u8")
        XCTAssertEqual(c.phase, .loading)
        av.emit(.playing)   // B's first frame
        XCTAssertEqual(c.phase, .playing)
        XCTAssertNotNil(PerfTrace.shared.interval(from: .playRequested, to: .firstFrame))
        XCTAssertEqual(events().last, LastSession(sourceId: "s1", channelId: "b", endedInPlayer: true))
    }

    func testStaleFailureDuringResolveStartsNoReconnect() async throws {
        let (c, av, events) = make()
        try await zapToBWhileResolving(c, av)
        av.emit(.failed(.network(.timeout)))   // A's item fails inside B's resolve window
        XCTAssertEqual(c.phase, .loading, "no reconnect of the old stream")
        try await Task.sleep(for: .milliseconds(80))   // a stale retry (30 ms) would reload A here
        XCTAssertEqual(av.loads.count, 1)

        try await settle(av.loads.count == 2)
        try await Task.sleep(for: .milliseconds(120))   // …or B a second time after it loaded
        XCTAssertEqual(av.loads.count, 2, "B loaded exactly once")
        XCTAssertEqual(c.phase, .loading)
        XCTAssertEqual(events(), [LastSession(sourceId: "s1", channelId: "a", endedInPlayer: true)])
    }
}
