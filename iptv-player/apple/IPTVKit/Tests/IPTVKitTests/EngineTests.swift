import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Scriptable engine: records calls, events are pushed by the test.
@MainActor
final class FakeEngine: PlaybackEngine {
    let kind: PlayerEngine
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    private(set) var loads: [(url: URL, startMs: Int64?)] = []
    private(set) var tunings: [LiveStartTuning] = []
    private(set) var stops = 0
    private(set) var aspect: AspectMode?
    private(set) var selectedAudio: Int?
    private(set) var selectedSubtitle: Int??
    private(set) var seeks: [Double] = []
    var isPlaying = false
    var diagnostics = EngineDiagnostics()

    init(kind: PlayerEngine) { self.kind = kind }

    func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?, preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        loads.append((stream.url, startMs))
        tunings.append(tuning)
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { seeks.append(seconds) }
    func selectAudio(_ id: Int) { selectedAudio = id }
    func selectSubtitle(_ id: Int?) { selectedSubtitle = .some(id) }
    func setAspect(_ mode: AspectMode) { aspect = mode }
    func stop() { stops += 1; isPlaying = false }
    func emit(_ event: EngineEvent) { onEvent?(event) }
}

@MainActor
final class EngineSelectionTests: XCTestCase {
    /// Fakes + creation log of the current test (rebuilt by `controller(...)`).
    @MainActor
    private final class Harness {
        let av: FakeEngine
        let vlc: FakeEngine
        var created: [PlayerEngine] = []
        init() {
            av = FakeEngine(kind: .avPlayer)
            vlc = FakeEngine(kind: .vlcKit)
        }
        func makeAV() -> any PlaybackEngine { created.append(.avPlayer); return av }
        func makeVLC() -> any PlaybackEngine { created.append(.vlcKit); return vlc }
    }
    private var h: Harness!
    private var av: FakeEngine { h.av }
    private var vlc: FakeEngine { h.vlc }
    private var created: [PlayerEngine] { h.created }

    private func controller(withVLC: Bool = true, sniffer: StreamResolver.Sniffer? = nil,
                            policy: ReconnectPolicy = ReconnectPolicy()) -> PlayerController {
        let harness = Harness()
        h = harness
        let makeVLC: (@MainActor () -> any PlaybackEngine)? = withVLC ? harness.makeVLC : nil
        let e = PlaybackEngines(avPlayer: harness.makeAV, vlc: makeVLC)
        return PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: sniffer, vlcAvailable: e.vlcAvailable),
                                library: nil, reconnectPolicy: policy, engines: e)
    }

    private func open(_ c: PlayerController, _ url: String, start: Int64? = nil) async throws {
        c.open(PlaybackRequest(item: .url(url, title: "x"), source: nil, startPositionMs: start))
        for _ in 0..<200 where c.stream?.url.absoluteString != url {
            if case .failed = c.phase { break }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFormatToEngine() async throws {
        let cases: [(String, PlayerEngine)] = [
            ("http://h.example.com/live.m3u8", .avPlayer), ("http://h.example.com/film.mp4", .avPlayer),
            ("http://h.example.com/film.mov", .avPlayer), ("http://h.example.com/film.mkv", .vlcKit),
            ("http://h.example.com/live/1.ts", .vlcKit), ("http://h.example.com/a.avi", .vlcKit),
            ("http://h.example.com/a.flv", .vlcKit), ("http://h.example.com/a.webm", .vlcKit),
            ("http://h.example.com/a.mpd", .vlcKit), ("rtsp://cam.example.com/s", .vlcKit),
            ("rtmp://h.example.com/app/s", .vlcKit), ("http://h.example.com/play?id=1", .avPlayer),
        ]
        for (url, want) in cases {
            let c = controller()
            try await open(c, url)
            XCTAssertEqual(c.engineKind, want, url)
            XCTAssertEqual(c.stream?.engine, want, url)
        }
        // UDP multicast stays unsupported even with VLCKit.
        let c = controller()
        try await open(c, "udp://@239.0.0.1:1234")
        for _ in 0..<50 where c.phase == .loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: "udp")))
    }

    func testControllerPassesTuningToEngine() async throws {
        let c = controller()
        try await open(c, "http://h.example.com/film.mp4")
        XCTAssertEqual(av.tunings.last, LiveStartTuning.make(isLive: false, largeBuffer: false))
        c.largeBuffer = true
        try await open(c, "http://h.example.com/film2.mkv")
        XCTAssertEqual(vlc.tunings.last, LiveStartTuning.make(isLive: false, largeBuffer: true))
        XCTAssertEqual(vlc.tunings.last?.vlcNetworkCachingMs, 4000)
    }

    func testSnifferRoutesUnknownURLToVLC() async throws {
        let tsBytes: Data = { var d = Data(count: 400); d[0] = 0x47; d[188] = 0x47; d[376] = 0x47; return d }()
        let c = controller(sniffer: { _, _ in ("application/octet-stream", tsBytes, 200) })
        try await open(c, "http://h.example.com/stream?id=7")
        XCTAssertEqual(c.stream?.container, .mpegts)
        XCTAssertEqual(c.engineKind, .vlcKit)
    }

    func testWithoutVLCKeepsAVPlayerOnlyBehaviour() async throws {
        let c = controller(withVLC: false)
        try await open(c, "http://h.example.com/film.mkv")
        for _ in 0..<50 where c.phase == .loading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: "mkv")))
        XCTAssertTrue(created.isEmpty)
    }

    func testXtreamTSOnlyAccountUsesTSWithVLC() async throws {
        let secrets = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "u", password: "p"))
        var source = Source.make(name: "P", secrets: secrets, id: "s1")
        source.xtreamAccount = XtreamAccountInfo(status: "Active", expiresAt: nil, maxConnections: 1, activeConnections: 0,
                                                 allowedOutputFormats: ["ts"], serverTimezone: "UTC")
        let resolver = StreamResolver(secrets: { _ in secrets }, sniffer: nil, vlcAvailable: true)
        let stream = try await resolver.resolve(PlaybackRequest(item: .channel(Channel(sourceId: "s1", id: "42", name: "TRT")), source: source))
        XCTAssertEqual(stream.url.absoluteString, "http://panel.example.com:8080/live/u/p/42.ts")
        XCTAssertEqual(stream.engine, .vlcKit)
    }

    func testAVPlayerFormatErrorFallsBackToVLCOnce() async throws {
        let c = controller()
        try await open(c, "http://h.example.com/play?id=1", start: 30_000)
        XCTAssertEqual(c.engineKind, .avPlayer)
        av.emit(.failed(.unsupportedFormat(container: "unknown")))
        XCTAssertEqual(c.engineKind, .vlcKit, "retried with VLCKit")
        XCTAssertEqual(av.stops, 1, "AVPlayer item released")
        XCTAssertEqual(vlc.loads.count, 1)
        XCTAssertEqual(vlc.loads.first?.startMs, 30_000, "resume position kept")
        XCTAssertNotEqual(c.phase, .failed(.unsupportedFormat(container: "unknown")))
        // A second format/codec error (now from VLCKit) is final – no ping-pong.
        vlc.emit(.failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(c.phase, .failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(vlc.loads.count, 1)
    }

    func testCodecErrorFallsBackButNetworkErrorReconnects() async throws {
        let c = controller(policy: ReconnectPolicy(delaysMs: [5_000, 5_000]))
        try await open(c, "http://h.example.com/live.m3u8")
        av.emit(.failed(.network(.timeout)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 1, max: 2))
        XCTAssertEqual(c.engineKind, .avPlayer, "network errors never switch engine")
        av.emit(.failed(.unsupportedCodec(codec: nil)))
        XCTAssertEqual(c.engineKind, .vlcKit)
        // Reconnects after the fallback stay on VLCKit.
        vlc.emit(.failed(.network(.other)))
        XCTAssertEqual(c.phase, .reconnecting(attempt: 2, max: 2))
        XCTAssertEqual(c.engineKind, .vlcKit)
    }

    func testNoFallbackWithoutVLC() async throws {
        let c = controller(withVLC: false)
        try await open(c, "http://h.example.com/play?id=1")
        av.emit(.failed(.unsupportedFormat(container: "unknown")))
        XCTAssertEqual(c.phase, .failed(.unsupportedFormat(container: "unknown")))
    }

    func testEventsDriveStateAndEnginesAreReused() async throws {
        let c = controller()
        try await open(c, "http://h.example.com/film.mkv")
        XCTAssertEqual(c.engineKind, .vlcKit)
        vlc.emit(.ready(duration: 600))
        vlc.emit(.playing)
        vlc.emit(.time(42))
        let tracks = [MediaOption(id: 0, name: "Türkçe", languageCode: "tur"), MediaOption(id: 1, name: "English", languageCode: "eng")]
        vlc.emit(.tracks(audio: tracks, subtitles: [], selectedAudio: 0, selectedSubtitle: nil))
        XCTAssertEqual(c.phase, .playing)
        XCTAssertEqual(c.duration, 600)
        XCTAssertEqual(c.currentTime, 42)
        XCTAssertEqual(c.audioOptions, tracks)
        c.selectAudio(1)
        XCTAssertEqual(vlc.selectedAudio, 1)
        XCTAssertEqual(c.selectedAudio, 1)
        c.seek(by: 10)
        XCTAssertEqual(vlc.seeks.last, 52)
        c.aspect = .ratio4x3
        XCTAssertEqual(vlc.aspect, .ratio4x3)
        // Events from an inactive engine are ignored.
        av.emit(.failed(.drm))
        XCTAssertEqual(c.phase, .playing)
        // Switching to HLS stops VLCKit and reuses the same instances later.
        try await open(c, "http://h.example.com/live.m3u8")
        XCTAssertEqual(c.engineKind, .avPlayer)
        XCTAssertEqual(vlc.stops, 1)
        try await open(c, "http://h.example.com/other.mkv")
        XCTAssertEqual(c.engineKind, .vlcKit)
        XCTAssertEqual(created, [.vlcKit, .avPlayer], "one instance per engine")
        c.release()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertGreaterThanOrEqual(vlc.stops, 2)
    }

    func testZapDebounceOnVLC() async throws {
        let channels = (0..<4).map { Channel(sourceId: "s", id: "\($0)", name: "C\($0)", url: "http://h.example.com/live/\($0).ts") }
        let c = controller()
        c.open(PlaybackRequest(item: .channel(channels[0]), source: nil, channels: channels))
        for _ in 0..<100 where c.engine == nil { try await Task.sleep(for: .milliseconds(5)) }
        c.zap(by: 1); c.zap(by: 1)
        XCTAssertEqual(c.zapTarget?.id, "2")
        try await Task.sleep(for: .milliseconds(PlayerController.zapDebounceMs + 250))
        XCTAssertEqual(c.currentChannel?.id, "2")
        XCTAssertEqual(vlc.loads.map(\.url.lastPathComponent), ["0.ts", "2.ts"], "only the last target opens")
    }
}

final class VLCFailureClassifierTests: XCTestCase {
    typealias P = VLCFailureClassifier.Probe

    func testHTTPStatuses() {
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 404, transportError: nil), hadPlayed: false, ended: false, isLive: true),
                       .streamOffline(httpStatus: 404))
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 403, transportError: nil), hadPlayed: false, ended: false, isLive: false),
                       .accessDenied(httpStatus: 403))
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 503, transportError: nil), hadPlayed: true, ended: false, isLive: true),
                       .serverError(httpStatus: 503))
    }

    func testNetworkAndCodec() {
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: nil, transportError: .network(.dns)), hadPlayed: false, ended: false, isLive: true),
                       .network(.dns))
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 200, transportError: nil), hadPlayed: false, ended: false, isLive: false),
                       .unsupportedCodec(codec: nil), "served but not decodable")
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 200, transportError: nil), hadPlayed: true, ended: false, isLive: true),
                       .network(.other), "dropped after playing → reconnect")
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 206, transportError: nil), hadPlayed: true, ended: true, isLive: true),
                       .network(.other), "a live stream never ends")
    }

    func testVODEnd() {
        XCTAssertNil(VLCFailureClassifier.classify(probe: nil, hadPlayed: true, ended: true, isLive: false, remainingSeconds: 2))
        XCTAssertEqual(VLCFailureClassifier.classify(probe: P(httpStatus: 206, transportError: nil), hadPlayed: true, ended: true, isLive: false,
                                                     remainingSeconds: 1200), .network(.other), "premature end = dropped connection")
    }
}

final class TrackNamingTests: XCTestCase {
    func testLanguageNames() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(TrackNaming.displayName(forLanguage: "tur", locale: en), "Turkish")
        XCTAssertEqual(TrackNaming.displayName(forLanguage: "tr", locale: Locale(identifier: "tr")), "Türkçe")
        XCTAssertEqual(TrackNaming.displayName(forLanguage: "eng", locale: en), "English")
        XCTAssertEqual(TrackNaming.displayName(forLanguage: "ger", locale: en), "German")
        XCTAssertNil(TrackNaming.displayName(forLanguage: "und", locale: en))
        XCTAssertNil(TrackNaming.displayName(forLanguage: nil, locale: en))
        XCTAssertNil(TrackNaming.displayName(forLanguage: "", locale: en))
    }

    func testPreferenceMatching() {
        XCTAssertTrue(TrackNaming.matches("tur", preferred: "tr"))
        XCTAssertTrue(TrackNaming.matches("en-GB", preferred: "en"))
        XCTAssertTrue(TrackNaming.matches("deu", preferred: "de"))
        XCTAssertFalse(TrackNaming.matches("eng", preferred: "tr"))
        XCTAssertFalse(TrackNaming.matches(nil, preferred: "tr"))
    }
}
