import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Settings → Player engine (CONTRACT §6.1 rule −1) and "Reset sync" (docs/SCREENS.md §3.7).
@MainActor
final class EngineOverrideTests: XCTestCase {
    private var av: FakeEngine!
    private var vlc: FakeEngine!
    private var store: AudioDelayStore!
    private var kv: InMemoryKeyValueStore!

    private func controller(_ override: PlayerEngineOverride, withVLC: Bool = true,
                            secrets: SourceSecrets? = nil, hlsProbe: StreamResolver.HLSProbe? = nil) -> PlayerController {
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        self.av = av
        self.vlc = vlc
        kv = InMemoryKeyValueStore()
        store = AudioDelayStore(kv: kv)
        var makeVLC: (@MainActor () -> any PlaybackEngine)?
        if withVLC { makeVLC = { vlc } }
        let engines = PlaybackEngines(avPlayer: { av }, vlc: makeVLC)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in secrets }, sniffer: nil, hlsProbe: hlsProbe, vlcAvailable: withVLC),
                                 library: nil, engines: engines)
        c.audioDelayStore = store
        c.setEngineOverride(override)
        return c
    }

    private func request(_ item: PlaybackRequest.Item, source: Source? = nil) -> PlaybackRequest {
        var r = PlaybackRequest(item: item, source: source)
        r.sourceFingerprint = "fp"
        return r
    }

    private func settle(_ c: PlayerController, loadsBefore: Int) async throws {
        for _ in 0..<200 where av.loads.count + vlc.loads.count == loadsBefore {
            if case .failed = c.phase { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func open(_ c: PlayerController, _ r: PlaybackRequest) async throws {
        let before = av.loads.count + vlc.loads.count
        c.open(r)
        try await settle(c, loadsBefore: before)
    }

    private func url(_ u: String) -> PlaybackRequest { request(.url(u, title: "x")) }

    // MARK: Engine choice: override × container × delay

    func testEngineForEachOverrideContainerAndDelay() async throws {
        let containers: [(String, StreamContainer)] = [
            ("http://h.example.com/live.m3u8", .hls), ("http://h.example.com/film.mp4", .mp4),
            ("http://h.example.com/film.mkv", .mkv), ("http://h.example.com/live/1.ts", .mpegts),
        ]
        for override in PlayerEngineOverride.allCases {
            for delay in [0, 200] {
                for (u, container) in containers {
                    let c = controller(override)
                    store.setVLCCalibration(delay)
                    c.audioDelayStore = store   // the controller reads the calibration when the store is set
                    try await open(c, url(u))
                    let context = "\(override.rawValue) calibration \(delay) \(container.rawValue)"
                    let avPlayable = container == .hls || container == .mp4
                    switch override {
                    case .avPlayer:
                        if avPlayable {
                            XCTAssertEqual(c.engineKind, .avPlayer, context)
                            XCTAssertTrue(vlc.loads.isEmpty, context)
                        } else {
                            XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: container.rawValue)), context)
                            XCTAssertTrue(av.loads.isEmpty && vlc.loads.isEmpty, context)
                        }
                    case .vlcKit:
                        XCTAssertEqual(c.engineKind, .vlcKit, context)
                        XCTAssertTrue(av.loads.isEmpty, context)
                        XCTAssertEqual(vlc.audioDelays.last, delay, context)
                    case .automatic, .remux:
                        // Build 16: the per-device VLC calibration never changes the engine (CONTRACT §6.1 rule 0);
                        // `.remux` without a remux engine (this controller has none) is Automatic.
                        XCTAssertEqual(c.engineKind, avPlayable ? .avPlayer : .vlcKit, context)
                        if !avPlayable { XCTAssertEqual(vlc.audioDelays.last, delay, context) }
                    }
                }
            }
        }
    }

    func testRemuxOverrideRoutesMKVToRemuxEngineAndFallsBackToVLC() async throws {
        let remux = FakeEngine(kind: .avRemux)
        let av = FakeEngine(kind: .avPlayer)
        let vlc = FakeEngine(kind: .vlcKit)
        let c = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil, hlsProbe: nil, vlcAvailable: true),
                                 library: nil, engines: PlaybackEngines(avPlayer: { av }, vlc: { vlc }, remux: { remux }))
        c.setEngineOverride(.remux)
        c.open(url("http://h.example.com/film.mkv"))
        for _ in 0..<200 where remux.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.engineKind, .avRemux)
        // MKV without cues / VP9 …: the remuxer reports UnsupportedFormat → VLCKit once.
        remux.emit(.failed(.unsupportedFormat(container: "mkv")))
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(vlc.loads.count, 1)
        // Everything else as Automatic.
        c.open(url("http://h.example.com/live.m3u8"))
        for _ in 0..<200 where av.loads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.engineKind, .avPlayer)
    }

    func testVLCOverrideWithoutVLCKitIsAVPlayerColumn() async throws {
        let c = controller(.vlcKit, withVLC: false)
        try await open(c, url("http://h.example.com/live.m3u8"))
        XCTAssertEqual(c.engineKind, .avPlayer)
        let d = controller(.vlcKit, withVLC: false)
        try await open(d, url("http://h.example.com/film.mkv"))
        XCTAssertEqual(d.phase, .failed(.unsupportedFormat(container: "mkv")))
    }

    func testAppleOverrideNeverFallsBackToVLC() async throws {
        let c = controller(.avPlayer)
        try await open(c, url("http://h.example.com/play?id=1"))
        XCTAssertEqual(c.engineKind, .avPlayer)
        av.emit(.failed(.unsupportedFormat(container: "unknown")))
        XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: "unknown")))
        XCTAssertTrue(vlc.loads.isEmpty)
        let p = PlaybackError.unsupportedFormat(container: "mkv").presentation(engineOverride: .avPlayer)
        XCTAssertEqual(p.hintKey, "perr_needs_vlc_engine")
        XCTAssertEqual(PlaybackError.unsupportedCodec(codec: nil).presentation(engineOverride: .avPlayer).hintKey, "perr_needs_vlc_engine")
        XCTAssertEqual(PlaybackError.unsupportedFormat(container: "mpegts").presentation(engineOverride: .avPlayer).hintKey,
                       "perr_format_apple_ts_override")
        XCTAssertEqual(PlaybackError.unsupportedFormat(container: "mpegts").presentation(engineOverride: .automatic).hintKey,
                       "perr_format_apple_ts")
        XCTAssertNil(PlaybackError.network(.timeout).presentation(engineOverride: .avPlayer).hintKey)
    }

    func testAppleOverrideIgnoresDelayChanges() async throws {
        let c = controller(.avPlayer)
        try await open(c, url("http://h.example.com/live.m3u8"))
        av.emit(.playing)
        c.setAudioDelay(300)
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(av.loads.count, 1, "no reload into VLCKit")
        XCTAssertTrue(vlc.loads.isEmpty)
    }

    func testChangingOverrideReopensOpenPlayer() async throws {
        let c = controller(.automatic)
        try await open(c, url("http://h.example.com/film.mp4"))
        av.emit(.ready(duration: 600))
        av.emit(.playing)
        av.emit(.time(42))
        XCTAssertEqual(c.engineKind, .avPlayer)
        c.setEngineOverride(.vlcKit)
        try await settle(c, loadsBefore: 1)
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(vlc.loads.last?.startMs, 42_000, "VOD reopened at the position")
        c.close()
        c.setEngineOverride(.avPlayer)
        XCTAssertEqual(c.phase, .idle, "closed player stays closed")
    }

    // MARK: Xtream live extension under the Apple override

    private let xtream = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "u", password: "p"))

    private func xtreamSource(_ formats: [String]) -> Source {
        var source = Source.make(name: "P", secrets: xtream, id: "s1")
        source.xtreamAccount = XtreamAccountInfo(status: "Active", expiresAt: nil, maxConnections: 1, activeConnections: 0,
                                                 allowedOutputFormats: formats, serverTimezone: "UTC")
        return source
    }

    func testXtreamLiveExtensionUnderAppleOverride() async throws {
        let resolver = StreamResolver(secrets: { [xtream] _ in xtream }, sniffer: nil, vlcAvailable: true)
        let channel = PlaybackRequest.Item.channel(Channel(sourceId: "s1", id: "42", name: "TRT"))
        for formats in [["ts"], ["ts", "m3u8"], ["m3u8"], []] {
            let r = PlaybackRequest(item: channel, source: xtreamSource(formats))
            let apple = try await resolver.resolve(r, engineOverride: .avPlayer)
            XCTAssertEqual(apple.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.m3u8", "\(formats)")
            XCTAssertEqual(apple.engine, .avPlayer, "\(formats)")
            XCTAssertEqual(apple.hlsForcedByOverride, formats == ["ts"], "\(formats)")
        }
        let auto = try await resolver.resolve(PlaybackRequest(item: channel, source: xtreamSource(["ts"])))
        XCTAssertEqual(auto.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.ts", "Automatic unchanged")
        XCTAssertEqual(auto.engine, .vlcKit)
        let forcedVLC = try await resolver.resolve(PlaybackRequest(item: channel, source: xtreamSource(["ts", "m3u8"])), engineOverride: .vlcKit)
        XCTAssertEqual(forcedVLC.engine, .vlcKit)
    }

    func testForcedHLSFailureBeforeFirstFrameShowsAskForHLS() async throws {
        let channel = Channel(sourceId: "s1", id: "42", name: "TRT")
        let c = controller(.avPlayer, secrets: xtream)
        try await open(c, request(.channel(channel), source: xtreamSource(["ts"])))
        XCTAssertEqual(c.stream?.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.m3u8")
        av.emit(.failed(.streamOffline(httpStatus: 404)))
        XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: "mpegts")))
        XCTAssertEqual(PlaybackError.unsupportedFormat(container: "mpegts").presentation(engineOverride: c.engineOverride).hintKey,
                       "perr_format_apple_ts_override")
        // Played once, then failed: the real error.
        let d = controller(.avPlayer, secrets: xtream)
        try await open(d, request(.channel(channel), source: xtreamSource(["ts"])))
        av.emit(.playing)
        av.emit(.failed(.accessDenied(httpStatus: 403)))
        XCTAssertEqual(d.phase, .failed(.accessDenied(httpStatus: 403)))
    }

    func testM3UXtreamTSUnderAppleOverride() async throws {
        let ts = "http://panel.example.com:8080/live/u/p/42.ts"
        let channel = Channel(sourceId: "s", id: "42", name: "TRT", url: ts)
        let ok = controller(.avPlayer, hlsProbe: { _, _ in true })
        try await open(ok, request(.channel(channel)))
        XCTAssertEqual(ok.stream?.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.m3u8", "HLS twin")
        XCTAssertEqual(ok.engineKind, .avPlayer)
        let no = controller(.avPlayer, hlsProbe: { _, _ in false })
        try await open(no, request(.channel(channel)))
        XCTAssertEqual(no.phase, .failed(.unsupportedFormat(container: "mpegts")))
        XCTAssertTrue(vlc.loads.isEmpty)
        // VLC override: no twin probe, the .ts plays in VLCKit.
        let forced = controller(.vlcKit, hlsProbe: { _, _ in XCTFail("no probe under the VLC override"); return true })
        try await open(forced, request(.channel(channel)))
        XCTAssertEqual(forced.stream?.url.absoluteString, ts)
        XCTAssertEqual(forced.engineKind, .vlcKit)
    }

    // MARK: Reset sync

    func testResetClearsAllDelays() async throws {
        let c = controller(.automatic)
        store.setVLCCalibration(-150)
        c.audioDelayStore = store
        store.setContentDelay(200, for: "fp:live:1")
        store.setContentDelay(-400, for: "fp:movie:9")
        kv.set(Data("x".utf8), forKey: "other.key")
        let r = request(.channel(Channel(sourceId: "s", id: "1", name: "C1", url: "http://h.example.com/live/1.m3u8")))
        try await open(c, r)
        XCTAssertEqual(c.engineKind, .vlcKit, "delay routes HLS to VLCKit")
        vlc.emit(.playing)
        XCTAssertEqual(vlc.audioDelays.last, 50, "content 200 + calibration −150")
        c.resetAudioDelays()
        XCTAssertEqual(store.contentDelay("fp:live:1"), 0)
        XCTAssertEqual(store.contentDelay("fp:movie:9"), 0)
        XCTAssertTrue(kv.keys(withPrefix: "audioDelay.").isEmpty, "every content delay key removed")
        XCTAssertNotNil(kv.data(forKey: "other.key"), "other settings kept")
        XCTAssertEqual(store.vlcCalibration, -150, "the device calibration is kept")
        XCTAssertEqual(c.currentAudioDelay, 0)
        XCTAssertEqual(c.vlcCalibrationMs, -150)
        XCTAssertEqual(c.contentAudioDelay, 0)
        XCTAssertEqual(vlc.audioDelays.last, -150, "VLCKit gets the content 0 at once (calibration stays)")
        // Automatic routing no longer forces VLCKit.
        try await open(c, request(.channel(Channel(sourceId: "s", id: "2", name: "C2", url: "http://h.example.com/live/2.m3u8"))))
        XCTAssertEqual(c.engineKind, .avPlayer)
    }

    func testResetOnUserDefaultsStore() throws {
        let name = "test.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let s = AudioDelayStore(kv: UserDefaultsStore(defaults))
        s.setVLCCalibration(100)
        s.setContentDelay(250, for: "k1")
        s.resetAll()
        XCTAssertEqual(s.vlcCalibration, 100)
        XCTAssertEqual(s.contentDelay("k1"), 0)
    }

    func testSettingPersists() throws {
        let name = "test.engine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings(defaults: defaults).playerEngine, .automatic)
        AppSettings(defaults: defaults).playerEngine = .avPlayer
        XCTAssertEqual(AppSettings(defaults: defaults).playerEngine, .avPlayer)
    }
}
