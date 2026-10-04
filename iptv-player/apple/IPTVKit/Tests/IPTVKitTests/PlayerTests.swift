import AVFoundation
import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

final class PlaybackErrorMapperTests: XCTestCase {
    func testURLErrors() {
        XCTAssertEqual(PlaybackErrorMapper.map(URLError(.notConnectedToInternet)), .network(.offline))
        XCTAssertEqual(PlaybackErrorMapper.map(URLError(.timedOut)), .network(.timeout))
        XCTAssertEqual(PlaybackErrorMapper.map(URLError(.cannotFindHost)), .network(.dns))
    }

    func testNestedHTTPStatusFromCoreMedia() {
        let cm404 = NSError(domain: "CoreMediaErrorDomain", code: -12938, userInfo: [NSLocalizedDescriptionKey: "HTTP 404: File Not Found"])
        let av = NSError(domain: "AVFoundationErrorDomain", code: -11850, userInfo: [NSUnderlyingErrorKey: cm404])
        XCTAssertEqual(PlaybackErrorMapper.map(av), .streamOffline(httpStatus: 404))
        let cm403 = NSError(domain: "CoreMediaErrorDomain", code: -12660, userInfo: [:])
        XCTAssertEqual(PlaybackErrorMapper.map(NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: cm403])),
                       .accessDenied(httpStatus: 403))
        let http503 = NSError(domain: "CoreMediaErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP 503: Service Unavailable"])
        XCTAssertEqual(PlaybackErrorMapper.map(http503), .serverError(httpStatus: 503))
    }

    func testAVFoundationCodes() {
        XCTAssertEqual(PlaybackErrorMapper.map(NSError(domain: "AVFoundationErrorDomain", code: -11831)), .drm)
        XCTAssertEqual(PlaybackErrorMapper.map(NSError(domain: "AVFoundationErrorDomain", code: -11833)), .unsupportedCodec(codec: nil))
        XCTAssertEqual(PlaybackErrorMapper.map(NSError(domain: "AVFoundationErrorDomain", code: -11828), container: .mkv),
                       .unsupportedFormat(container: "mkv"))
    }

    func testRecoverability() {
        XCTAssertTrue(PlaybackErrorMapper.isRecoverable(.network(.offline)))
        XCTAssertTrue(PlaybackErrorMapper.isRecoverable(.serverError(httpStatus: 502)))
        XCTAssertFalse(PlaybackErrorMapper.isRecoverable(.accessDenied(httpStatus: 403)))
        XCTAssertFalse(PlaybackErrorMapper.isRecoverable(.unsupportedFormat(container: "mpegts")))
        XCTAssertFalse(PlaybackErrorMapper.isRecoverable(.drm))
    }

    func testTSPresentationAsksForHLS() {
        let p = PlaybackError.unsupportedFormat(container: "mpegts").presentation
        XCTAssertEqual(p.hintKey, "perr_format_apple_ts")
        XCTAssertEqual(p.bodyArgs, ["MPEG-TS"])
    }
}

final class StreamResolverTests: XCTestCase {
    let xtream = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://panel.example.com:8080/", username: "u ser", password: "p@ss"))

    private func resolver(_ secrets: SourceSecrets? = nil) -> StreamResolver {
        StreamResolver(secrets: { _ in secrets }, sniffer: nil)
    }

    private func source(formats: [String]) -> Source {
        var s = Source.make(name: "P", secrets: xtream, id: "s1")
        s.xtreamAccount = XtreamAccountInfo(status: "Active", expiresAt: nil, maxConnections: 1, activeConnections: 0,
                                            allowedOutputFormats: formats, serverTimezone: "UTC")
        return s
    }

    func testXtreamLiveUsesHLSOnApple() async throws {
        let channel = Channel(sourceId: "s1", id: "42", name: "TRT")
        let stream = try await resolver(xtream).resolve(PlaybackRequest(item: .channel(channel), source: source(formats: ["ts", "m3u8"])))
        XCTAssertEqual(stream.url.absoluteString, "http://panel.example.com:8080/live/u%20ser/p%40ss/42.m3u8")
        XCTAssertEqual(stream.container, .hls)
    }

    func testXtreamTSOnlyIsRejectedBeforePlayback() async {
        let channel = Channel(sourceId: "s1", id: "42", name: "TRT")
        do {
            _ = try await resolver(xtream).resolve(PlaybackRequest(item: .channel(channel), source: source(formats: ["ts"])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .unsupportedFormat(container: "mpegts"))
        }
    }

    func testUnsupportedContainersAndDRM() async {
        for (url, container) in [("http://a.example.com/film.mkv", "mkv"), ("http://a.example.com/live.ts", "mpegts"),
                                 ("http://a.example.com/x.mpd", "dash"), ("rtmp://a.example.com/live", "rtmp")] {
            do {
                _ = try await resolver().resolve(PlaybackRequest(item: .url(url, title: "x"), source: nil))
                XCTFail("expected error for \(url)")
            } catch {
                XCTAssertEqual(error as? PlaybackError, .unsupportedFormat(container: container))
            }
        }
        let drm = Channel(sourceId: "s1", id: "1", name: "D", url: "http://a.example.com/x.m3u8", drm: true)
        do {
            _ = try await resolver().resolve(PlaybackRequest(item: .channel(drm), source: nil))
            XCTFail("expected drm")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .drm)
        }
    }

    func testSnifferDecidesUnknownURLs() async throws {
        let tsBytes: Data = {
            var d = Data(count: 400)
            d[0] = 0x47; d[188] = 0x47; d[376] = 0x47
            return d
        }()
        let ts = StreamResolver(secrets: { _ in nil }, sniffer: { _, _ in ("application/octet-stream", tsBytes, 200) })
        do {
            _ = try await ts.resolve(PlaybackRequest(item: .url("http://a.example.com/play?id=1", title: "x"), source: nil))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .unsupportedFormat(container: "mpegts"))
        }
        let missing = StreamResolver(secrets: { _ in nil }, sniffer: { _, _ in (nil, nil, 404) })
        do {
            _ = try await missing.resolve(PlaybackRequest(item: .url("http://a.example.com/play?id=2", title: "x"), source: nil))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .streamOffline(httpStatus: 404))
        }
        let hls = StreamResolver(secrets: { _ in nil }, sniffer: { _, _ in ("application/vnd.apple.mpegurl", nil, 200) })
        let ok = try await hls.resolve(PlaybackRequest(item: .url("http://a.example.com/play?id=3", title: "x"), source: nil))
        XCTAssertEqual(ok.container, .hls)
    }
}

@MainActor
final class PlayerControllerTests: XCTestCase {
    func testLockedWhenTrialExpired() {
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil)
        controller.canPlay = { false }
        controller.open(PlaybackRequest(item: .url("http://a.example.com/x.m3u8", title: "x"), source: nil))
        XCTAssertEqual(controller.phase, .locked)
    }

    func testUnsupportedFormatFailsWithoutPlayer() async throws {
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil)
        controller.open(PlaybackRequest(item: .url("http://a.example.com/x.mkv", title: "x"), source: nil))
        for _ in 0..<50 where controller.phase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .failed(.unsupportedFormat(container: "mkv")))
        XCTAssertNil(controller.player.currentItem)
    }

    func testZapDebounceOpensOnlyLastChannel() async throws {
        let channels = (0..<5).map { Channel(sourceId: "s", id: "\($0)", name: "C\($0)", url: "http://a.example.com/\($0).mkv") }
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil)
        controller.open(PlaybackRequest(item: .channel(channels[0]), source: nil, channels: channels))
        controller.zap(by: 1)
        controller.zap(by: 1)
        controller.zap(by: 1)
        XCTAssertEqual(controller.zapTarget?.id, "3", "info card updates immediately")
        XCTAssertEqual(controller.currentChannel?.id, "0", "stream not switched before the debounce")
        try await Task.sleep(for: .milliseconds(PlayerController.zapDebounceMs + 250))
        XCTAssertEqual(controller.currentChannel?.id, "3")
        XCTAssertEqual(controller.previousChannel?.id, "0")
        controller.zap(by: -4)
        XCTAssertEqual(controller.zapTarget?.id, "4", "wraps around")
    }

    func testReconnectPolicyDrivesPhases() async throws {
        let controller = PlayerController(resolver: StreamResolver(secrets: { _ in nil }, sniffer: nil), library: nil,
                                          reconnectPolicy: ReconnectPolicy(delaysMs: [5_000, 5_000]))
        controller.open(PlaybackRequest(item: .url("http://127.0.0.1:9/x.m3u8", title: "x"), source: nil))
        for _ in 0..<50 where controller.stream == nil { try await Task.sleep(for: .milliseconds(10)) }
        controller.handle(.network(.offline))
        XCTAssertEqual(controller.phase, .reconnecting(attempt: 1, max: 2))
        controller.handle(.network(.offline))
        XCTAssertEqual(controller.phase, .reconnecting(attempt: 2, max: 2))
        controller.handle(.network(.offline))
        XCTAssertEqual(controller.phase, .failed(.network(.offline)))
    }
}

@MainActor
final class ViewModelLogicTests: XCTestCase {
    func testURLValidation() {
        XCTAssertTrue(AddSourceViewModel.isValidHTTPURL("http://example.com/list.m3u"))
        XCTAssertTrue(AddSourceViewModel.isValidHTTPURL(" https://example.com:8080/get.php?x=1 "))
        XCTAssertFalse(AddSourceViewModel.isValidHTTPURL("example.com"))
        XCTAssertFalse(AddSourceViewModel.isValidHTTPURL("ftp://example.com/a"))
    }

    func testFormatTestEvaluation() {
        XCTAssertEqual(FormatTestViewModel.evaluate(expected: "play", observed: "play"), .ok)
        XCTAssertEqual(FormatTestViewModel.evaluate(expected: "error:UnsupportedFormat", observed: "UnsupportedFormat"), .expectedError("UnsupportedFormat"))
        XCTAssertEqual(FormatTestViewModel.evaluate(expected: "play", observed: "Network"), .unexpected("Network"))
    }

    func testFormatSamplesLoadWithHostSubstitution() throws {
        let data = try Data(contentsOf: vectorURL("stream-samples.json"))
        let vm = FormatTestViewModel(samplesJSON: data, lanHost: "localhost")
        XCTAssertGreaterThan(vm.samples.count, 10)
        XCTAssertFalse(vm.samples.contains { $0.url.contains("<LAN-IP>") })
    }

    func testPaywallMessages() {
        XCTAssertNil(PaywallViewModel.message(for: .cancelled))
        XCTAssertEqual(PaywallViewModel.message(for: .pending)?.key, "purchase_pending")
        XCTAssertEqual(PaywallViewModel.message(for: .nothingToRestore)?.key, "purchase_nothing_to_restore")
    }
}
