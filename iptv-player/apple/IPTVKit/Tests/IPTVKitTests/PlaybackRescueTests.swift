import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 24: before the first frame every engine / URL variant is tried before an error card (CONTRACT §6.2).
final class PlaybackRescueTests: XCTestCase {
    private func attempt(_ engine: PlayerEngine, _ url: String) -> PlaybackAttempt {
        PlaybackAttempt(engine: engine, url: URL(string: url)!, container: StreamFormatDetector.detect(url: url))
    }

    private func plan(_ first: PlaybackAttempt, live: Bool = false, override: PlayerEngineOverride = .automatic,
                      vlc: Bool = true, remux: Bool = true, remuxPreferred: Bool = false) -> [String] {
        PlaybackRescue.plan(first: first, isLive: live, override: override, vlcAvailable: vlc, remuxAvailable: remux,
                            remuxPreferred: remuxPreferred)
            .map { "\($0.engine.rawValue) \($0.url.pathExtension)" }
    }

    func testTVMKVTriesRemuxThenVLC() {
        XCTAssertEqual(plan(attempt(.avRemux, "http://h/series/u/p/1.mkv"), remuxPreferred: true), ["avremux mkv", "vlckit mkv"])
    }

    func testIOSMKVTriesVLCThenRemux() {
        XCTAssertEqual(plan(attempt(.vlcKit, "http://h/series/u/p/1.mkv")), ["vlckit mkv", "avremux mkv"])
    }

    func testVODMP4TriesAVPlayerThenVLC() {
        XCTAssertEqual(plan(attempt(.avPlayer, "http://h/movie/u/p/1.mp4")), ["avplayer mp4", "vlckit mp4"])
    }

    func testLiveHLSTriesBothEnginesThenTheTSVariant() {
        XCTAssertEqual(plan(attempt(.avPlayer, "http://h/live/u/p/7.m3u8"), live: true),
                       ["avplayer m3u8", "vlckit m3u8", "vlckit ts"])
    }

    func testLiveTSTriesVLCThenTheHLSVariantOnBothEngines() {
        XCTAssertEqual(plan(attempt(.vlcKit, "http://h/live/u/p/7.ts"), live: true),
                       ["vlckit ts", "avplayer m3u8", "vlckit m3u8"])
    }

    func testVODHasNoURLVariant() {
        XCTAssertEqual(plan(attempt(.avPlayer, "http://h/movie/u/p/1.m3u8")), ["avplayer m3u8", "vlckit m3u8"])
    }

    func testAppleOverrideStaysOnAVPlayer() {
        XCTAssertEqual(plan(attempt(.avPlayer, "http://h/live/u/p/7.m3u8"), live: true, override: .avPlayer), ["avplayer m3u8"])
    }

    func testVLCOverrideStaysOnVLCButTriesTheVariant() {
        XCTAssertEqual(plan(attempt(.vlcKit, "http://h/live/u/p/7.m3u8"), live: true, override: .vlcKit),
                       ["vlckit m3u8", "vlckit ts"])
    }

    func testWithoutVLCKit() {
        XCTAssertEqual(plan(attempt(.avPlayer, "http://h/live/u/p/7.m3u8"), live: true, vlc: false), ["avplayer m3u8"])
    }

    func testLiveAlternateOnlyForXtreamLivePaths() {
        XCTAssertEqual(PlaybackRescue.liveAlternate(URL(string: "http://h:8080/live/u/p/7.m3u8")!)?.absoluteString, "http://h:8080/live/u/p/7.ts")
        XCTAssertEqual(PlaybackRescue.liveAlternate(URL(string: "http://h/live/u/p/7.ts")!)?.absoluteString, "http://h/live/u/p/7.m3u8")
        XCTAssertNil(PlaybackRescue.liveAlternate(URL(string: "http://h/hls/channel/index.m3u8")!))
        XCTAssertNil(PlaybackRescue.liveAlternate(URL(string: "http://h/movie/u/p/1.ts")!))
    }

    func testOnlyDRMIsNotRescued() {
        XCTAssertFalse(PlaybackRescue.isRescuable(.drm))
        for error: PlaybackError in [.network(.other), .accessDenied(httpStatus: 403), .streamOffline(httpStatus: 404),
                                     .serverError(httpStatus: 503), .unsupportedFormat(container: "mkv"),
                                     .unsupportedCodec(codec: nil), .unknown(message: "x")] {
            XCTAssertTrue(PlaybackRescue.isRescuable(error), "\(error)")
        }
    }
}
