import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Audio delay (content + device) and its engine routing (CONTRACT §6.1, docs/ARCHITECTURE.md §3.2).
final class AudioDelayTests: XCTestCase {
    func testClampRoundAndEffective() {
        let s = AudioDelayStore(kv: InMemoryKeyValueStore())
        s.setContentDelay(130, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 150)
        s.setContentDelay(9999, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 2000)
        s.setDeviceDelay(-300)
        XCTAssertEqual(s.effectiveDelay("ch:a"), 1700)
        XCTAssertEqual(s.effectiveDelay("ch:b"), -300)
        s.setContentDelay(0, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 0)
    }

    func testNegativeValuesAndEffectiveClamp() {
        let kv = InMemoryKeyValueStore()
        let s = AudioDelayStore(kv: kv)
        s.setContentDelay(-130, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), -150)
        s.setContentDelay(-5000, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), -2000)
        s.setDeviceDelay(-400)
        XCTAssertEqual(s.effectiveDelay("ch:a"), -2000, "content + device stays in range")
        XCTAssertEqual(s.deviceDelay, -400)
        s.setContentDelay(0, for: "ch:a")
        XCTAssertNil(kv.data(forKey: "audioDelay.ch:a"), "0 removes the key")
        XCTAssertEqual(AudioDelayStore(kv: kv).deviceDelay, -400, "persisted")
    }

    /// libVLC 3 (audiounit_ios) already compensates `outputLatency` up to 1 s; only the rest is added (audio earlier).
    func testVLCLatencyCompensationOnlyBeyondLibVLCCap() {
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: 0), 0)
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: 0.045), 0, "HDMI/TV speakers: handled by libVLC")
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: 1.0), 0)
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: 1.8), -800, "AirPlay: the part above the cap")
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: -1), 0)
        XCTAssertEqual(VLCLatencyCompensation.autoDelayMs(outputLatency: .nan), 0)
        XCTAssertEqual(VLCLatencyCompensation.totalDelayMs(userMs: 200, outputLatency: 1.8), -600)
        XCTAssertEqual(VLCLatencyCompensation.totalDelayMs(userMs: 200, outputLatency: 0.05), 200)
    }
}

@MainActor
final class AudioDelayPlayerTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!
    private var store: AudioDelayStore!

    private func controller(withVLC: Bool = true, policy: ReconnectPolicy = ReconnectPolicy()) -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        store = AudioDelayStore(kv: InMemoryKeyValueStore())
        var makeVLC: (@MainActor () -> any PlaybackEngine)?
        if withVLC { makeVLC = { vlc } }
        let engines = PlaybackEngines(avPlayer: { av }, vlc: makeVLC)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, hlsProbe: nil, vlcAvailable: withVLC),
                                 library: nil, reconnectPolicy: policy, engines: engines)
        c.audioDelayStore = store
        return c
    }

    private func channel(_ id: String, _ url: String) -> Channel { Channel(sourceId: "s", id: id, name: "C\(id)", url: url) }

    private func request(_ item: PlaybackRequest.Item, channels: [Channel] = []) -> PlaybackRequest {
        var r = PlaybackRequest(item: item, source: nil, channels: channels)
        r.sourceFingerprint = "fp"
        return r
    }

    private func key(_ r: PlaybackRequest) throws -> String { try XCTUnwrap(r.contentKey) }

    private func open(_ c: PlayerController, _ r: PlaybackRequest) async throws {
        let before = av.loads.count + vlc.loads.count
        c.open(r)
        for _ in 0..<200 where av.loads.count + vlc.loads.count == before { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(av.loads.count + vlc.loads.count, before, "loaded")
    }

    func testHLSWithoutDelayStaysOnAVPlayer() async throws {
        let c = controller()
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(c.currentAudioDelay, 0)
        XCTAssertEqual(av.audioDelays, [0])
        XCTAssertTrue(vlc.loads.isEmpty)
    }

    func testStoredContentDelayRoutesHLSToVLC() async throws {
        let c = controller()
        let r = request(.channel(channel("1", "http://h.example.com/live/1.m3u8")))
        store.setContentDelay(200, for: try key(r))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(c.currentAudioDelay, 200)
        XCTAssertEqual(vlc.audioDelays.last, 200)
        XCTAssertTrue(av.loads.isEmpty)
        // Another channel without its own delay goes back to AVPlayer.
        try await open(c, request(.channel(channel("2", "http://h.example.com/live/2.m3u8"))))
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(c.currentAudioDelay, 0)
    }

    func testDeviceDelayAppliesToEveryItem() async throws {
        let c = controller()
        store.setDeviceDelay(-100)
        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mp4")
        try await open(c, request(.movie(movie)))
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(vlc.audioDelays.last, -100)
        XCTAssertEqual(c.contentAudioDelay, 0)
    }

    func testDelayIgnoredWithoutVLC() async throws {
        let c = controller(withVLC: false)
        let r = request(.channel(channel("1", "http://h.example.com/live/1.m3u8")))
        store.setContentDelay(200, for: try key(r))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .avPlayer)
        c.setAudioDelay(300)
        XCTAssertEqual(av.loads.count, 1, "no reload: AVPlayer cannot apply it")
        XCTAssertEqual(store.contentDelay(try key(r)), 300, "still stored")
    }

    func testSetAudioDelayOnAVPlayerReloadsSamePositionInVLC() async throws {
        let c = controller()
        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mp4")
        let r = request(.movie(movie))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .avPlayer)
        av.emit(.ready(duration: 600))
        av.emit(.playing)
        av.emit(.time(42))
        c.setAudioDelay(300)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(av.stops, 1)
        XCTAssertEqual(vlc.loads.count, 1)
        XCTAssertEqual(vlc.loads.last?.startMs, 42_000)
        XCTAssertEqual(vlc.audioDelays.last, 300)
        XCTAssertEqual(store.contentDelay(try key(r)), 300)
        XCTAssertEqual(c.currentAudioDelay, 300)
        // Further changes on VLCKit apply live; back to 0 stays on VLCKit (no engine ping-pong).
        c.setAudioDelay(130)
        XCTAssertEqual(vlc.audioDelays.last, 150)
        c.setAudioDelay(0)
        XCTAssertEqual(vlc.audioDelays.last, 0)
        XCTAssertEqual(vlc.loads.count, 1)
        XCTAssertEqual(c.engineKind, .vlcKit)
    }

    func testSetAudioDelayOnLiveAVPlayerReloadsAtLiveEdge() async throws {
        let c = controller()
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        av.emit(.playing)
        c.setAudioDelay(200)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(vlc.loads.count, 1)
        XCTAssertNil(vlc.loads.last?.startMs)
    }

    func testResyncReloadsLiveAtLiveEdgeAndVODAtPosition() async throws {
        let c = controller()
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        av.emit(.playing)
        c.resync()
        XCTAssertEqual(av.loads.count, 2)
        XCTAssertNil(av.loads.last?.startMs)

        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mkv")
        try await open(c, request(.movie(movie)))
        vlc.emit(.ready(duration: 600))
        vlc.emit(.playing)
        vlc.emit(.time(90))
        c.resync()
        XCTAssertEqual(vlc.loads.count, 2)
        XCTAssertEqual(vlc.loads.last?.startMs, 90_000)
    }

    func testResyncIgnoredWithoutPlayback() async throws {
        let c = controller()
        c.resync()
        XCTAssertTrue(av.loads.isEmpty)
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        av.emit(.failed(.drm))
        c.resync()
        XCTAssertEqual(av.loads.count, 1, "no reload from the error card (Retry does that)")
    }

    /// The reconnect itself reopens the stream at the live edge (that is the resync) and starts the new
    /// item with the delay; its first frame triggers no second reload.
    func testReconnectReopensAtLiveEdgeWithTheDelay() async throws {
        let c = controller(policy: ReconnectPolicy(delaysMs: [10, 10]))
        let r = request(.channel(channel("1", "http://h.example.com/live/1.ts")))
        store.setContentDelay(200, for: try key(r))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .vlcKit)
        vlc.emit(.playing)
        let appliedBefore = vlc.audioDelays.count
        vlc.emit(.failed(.network(.other)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
        for _ in 0..<200 where vlc.loads.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(vlc.loads.count, 2)
        XCTAssertNil(vlc.loads.last?.startMs, "live edge")
        XCTAssertEqual(vlc.audioDelays.count, appliedBefore + 1, "the reconnect load starts with the delay")
        XCTAssertEqual(vlc.audioDelays.last, 200)
        vlc.emit(.playing)
        vlc.emit(.playing)
        XCTAssertEqual(c.phase, .playing)
        XCTAssertEqual(vlc.loads.count, 2, "no extra reload after the reconnect")
    }

    /// While the next request resolves, `stream` still is the previous channel: sync actions must not
    /// reopen it (single-connection Xtream accounts would refuse the new channel).
    func testSyncActionsWhileResolvingDoNotReopenThePreviousStream() async throws {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        store = AudioDelayStore(kv: InMemoryKeyValueStore())
        var makeVLC: (@MainActor () -> any PlaybackEngine)?
        makeVLC = { vlc }
        // Unknown container → the (slow) sniffer runs while the request resolves.
        let sniffer: StreamResolver.Sniffer = { _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return ("application/vnd.apple.mpegurl", Data("#EXTM3U\n".utf8), 200)
        }
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: sniffer, hlsProbe: nil, vlcAvailable: true),
                                 library: nil, engines: PlaybackEngines(avPlayer: { av }, vlc: makeVLC))
        c.audioDelayStore = store
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        av.emit(.playing)
        c.open(request(.channel(channel("2", "http://h.example.com/play?id=2"))))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.phase, .loading)
        c.resync()
        c.setAudioDelay(200)
        XCTAssertEqual(av.loads.count, 1, "previous channel not reopened")
        XCTAssertTrue(vlc.loads.isEmpty, "previous channel not reopened in VLCKit")
        for _ in 0..<200 where vlc.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(vlc.loads.map(\.url.absoluteString), ["http://h.example.com/play?id=2"], "only the new channel, with its delay")
        XCTAssertEqual(vlc.audioDelays.last, 200)
    }

    /// Delay routed an AVPlayer stream to VLCKit and VLCKit cannot play it: back to AVPlayer without
    /// the delay (+ notice), once; the stored delay is kept.
    func testVLCFailureOfDelayRoutedStreamFallsBackToAVPlayer() async throws {
        let c = controller()
        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mp4")
        let r = request(.movie(movie))
        store.setContentDelay(200, for: try key(r))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertFalse(c.audioSyncUnavailable)
        vlc.emit(.time(30))
        vlc.emit(.failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(av.loads.count, 1)
        XCTAssertEqual(av.loads.last?.startMs, 30_000)
        XCTAssertTrue(c.audioSyncUnavailable, "notice")
        XCTAssertNotEqual(c.phase, .failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(store.contentDelay(try key(r)), 200, "stored delay kept")
        // Further changes do not bounce back to VLCKit for this opened stream.
        c.setAudioDelay(300)
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(vlc.loads.count, 1)
        // AVPlayer failing too is final (no ping-pong).
        av.emit(.failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(c.phase, .failed(.unsupportedCodec(codec: nil)))
        // The next open tries the delay (VLCKit) again.
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertFalse(c.audioSyncUnavailable)
    }

    /// Same after switching live from AVPlayer to VLCKit with the Sync control.
    func testVLCFailureAfterLiveDelaySwitchFallsBackToAVPlayer() async throws {
        let c = controller()
        try await open(c, request(.channel(channel("1", "http://h.example.com/live/1.m3u8"))))
        av.emit(.playing)
        c.setAudioDelay(150)
        XCTAssertEqual(c.engineKind, .vlcKit)
        vlc.emit(.failed(.unsupportedFormat(container: "hls")))
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(av.loads.count, 2)
        XCTAssertNil(av.loads.last?.startMs)
        XCTAssertTrue(c.audioSyncUnavailable)
    }

    /// A stream that only VLCKit plays (MKV) keeps the normal rule: a VLCKit failure is final.
    func testVLCFailureOfVLCOnlyStreamStaysFinal() async throws {
        let c = controller()
        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mkv")
        let r = request(.movie(movie))
        store.setContentDelay(200, for: try key(r))
        try await open(c, r)
        vlc.emit(.failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(c.phase, .failed(.unsupportedCodec(codec: nil)))
        XCTAssertTrue(av.loads.isEmpty)
    }

    /// tvOS stepper: held/repeated ◀▶ accelerate 50 → 100 → 250 ms.
    func testStepperAcceleration() {
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 0), 50)
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 3), 50)
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 4), 100)
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 9), 100)
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 10), 250)
        XCTAssertEqual(AudioDelayStore.stepSize(repeatCount: 100), 250)
    }

    func testRawURLDelayIsKeptForTheSessionOnly() async throws {
        let c = controller()
        try await open(c, PlaybackRequest(item: .url("http://h.example.com/a.mkv", title: "x"), source: nil))
        c.setAudioDelay(100)
        XCTAssertEqual(c.contentAudioDelay, 100)
        XCTAssertEqual(vlc.audioDelays.last, 100)
        c.retry()
        XCTAssertEqual(c.contentAudioDelay, 100, "Retry keeps it")
        try await open(c, PlaybackRequest(item: .url("http://h.example.com/b.mkv", title: "y"), source: nil))
        XCTAssertEqual(c.contentAudioDelay, 0)
    }

    func testDeviceDelayChangeAppliesToVLCLive() async throws {
        let c = controller()
        let movie = Movie(sourceId: "s", id: "m1", name: "Film", url: "http://h.example.com/film.mkv")
        try await open(c, request(.movie(movie)))
        c.setDeviceAudioDelay(-250)
        XCTAssertEqual(store.deviceDelay, -250)
        XCTAssertEqual(c.deviceAudioDelay, -250)
        XCTAssertEqual(c.currentAudioDelay, -250)
        XCTAssertEqual(vlc.audioDelays.last, -250)
    }
}

/// CONTRACT §4.5: M3U live `.ts` entries in Xtream shape prefer their HLS twin.
final class LiveHLSPreferenceTests: XCTestCase {
    private actor Probes {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    private func resolve(_ url: String, available: Bool, vlc: Bool = true) async throws -> (ResolvedStream, [URL]) {
        let probes = Probes()
        let resolver = StreamResolver(secrets: { _ in nil }, sniffer: nil, hlsProbe: { url, _ in
            await probes.add(url)
            return available
        }, vlcAvailable: vlc)
        let channel = Channel(sourceId: "s", id: "1", name: "C", url: url)
        let stream = try await resolver.resolve(PlaybackRequest(item: .channel(channel), source: nil))
        return (stream, await probes.urls)
    }

    func testM3U8AvailableUsesHLSOnAVPlayer() async throws {
        let (stream, probes) = try await resolve("http://panel.example.com:8080/live/u/p/42.ts", available: true)
        XCTAssertEqual(stream.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.m3u8")
        XCTAssertEqual(stream.container, .hls)
        XCTAssertEqual(stream.engine, .avPlayer)
        XCTAssertEqual(probes.map(\.absoluteString), ["http://panel.example.com:8080/live/u/p/42.m3u8"])
    }

    func testM3U8MissingKeepsTSOnVLC() async throws {
        let (stream, probes) = try await resolve("http://panel.example.com:8080/u/p/42.ts", available: false)
        XCTAssertEqual(stream.url.absoluteString, "http://panel.example.com:8080/u/p/42.ts")
        XCTAssertEqual(stream.container, .mpegts)
        XCTAssertEqual(stream.engine, .vlcKit)
        XCTAssertEqual(probes.count, 1)
    }

    func testNonMatchingURLIsNotProbed() async throws {
        let (stream, probes) = try await resolve("http://h.example.com/live/7.ts", available: true)
        XCTAssertEqual(stream.container, .mpegts)
        XCTAssertTrue(probes.isEmpty)
        let (hls, hlsProbes) = try await resolve("http://panel.example.com/live/u/p/42.m3u8", available: true)
        XCTAssertEqual(hls.engine, .avPlayer)
        XCTAssertTrue(hlsProbes.isEmpty)
    }

    func testWithoutVLCTheHLSTwinAvoidsTheError() async throws {
        let (stream, _) = try await resolve("http://panel.example.com/live/u/p/42.ts", available: true, vlc: false)
        XCTAssertEqual(stream.container, .hls)
        do {
            _ = try await resolve("http://panel.example.com/live/u/p/42.ts", available: false, vlc: false)
            XCTFail("TS without VLCKit")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .unsupportedFormat(container: "mpegts"))
        }
    }

    /// The default network probe: 200 + `#EXTM3U` only.
    func testProbeAcceptsOnlyPlaylists() {
        XCTAssertTrue(StreamResolver.isHLSPlaylist(status: 200, body: Data("#EXTM3U\n#EXT-X-VERSION:3".utf8)))
        XCTAssertTrue(StreamResolver.isHLSPlaylist(status: 200, body: Data("\u{FEFF}#EXTM3U\n".utf8)))
        XCTAssertFalse(StreamResolver.isHLSPlaylist(status: 404, body: Data("#EXTM3U".utf8)))
        XCTAssertFalse(StreamResolver.isHLSPlaylist(status: 206, body: Data("#EXTM3U".utf8)))
        XCTAssertFalse(StreamResolver.isHLSPlaylist(status: 200, body: Data("<html>".utf8)))
        XCTAssertFalse(StreamResolver.isHLSPlaylist(status: 200, body: nil))
    }
}
