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
}
