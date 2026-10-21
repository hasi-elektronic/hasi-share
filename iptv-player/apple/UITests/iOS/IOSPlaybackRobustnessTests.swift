import XCTest

/// Playback robustness (SCREENS §3.7, §4): live never pauses by itself; an HTTP 403 movie shows
/// the AccessDenied card instead of an endless spinner.
final class IOSPlaybackRobustnessTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Live HLS (demo list, AVPlayer with the tuned start) keeps playing for 60 s without user input.
    /// Before the fix AVPlayer's clock stayed at 0 after the tuned start and the phase fell to
    /// "paused" ~3 s after the first frame (stall-wait relax).
    @MainActor
    func testLiveKeepsPlayingWithoutUserInput() throws {
        let app = UITestSupport.launch(["-uiScreen", "player"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        var playing = false
        let start = Date()
        while Date().timeIntervalSince(start) < 20, !playing {
            playing = Self.playState(app) == "Playing"
            if !playing { sleep(1) }
        }
        XCTAssertTrue(playing, "live starts playing")
        let soakEnd = Date().addingTimeInterval(60)
        while Date() < soakEnd {
            sleep(10)
            let value = Self.playState(app)
            XCTAssertNotEqual(value, "Paused", "live paused by itself after \(Int(Date().timeIntervalSince(start))) s")
        }
        XCTAssertEqual(Self.playState(app), "Playing", "live still playing after 60 s")
    }

    /// "Playing"/"Paused" from a freshly shown overlay (live has no time label).
    @MainActor
    static func playState(_ app: XCUIApplication) -> String {
        IOSPlayerControlsTests.freshOverlay(app)
        return app.buttons["player_play_pause"].value as? String ?? ""
    }

    /// A movie URL answering HTTP 403 (AVPlayer, progressive MP4) shows the AccessDenied card
    /// within 12 s (SCREENS §4).
    @MainActor
    func testVODHTTP403ShowsAccessDenied() throws {
        let app = try IOSPlayerControlsTests.launchMovie(VLCTestSupport.deniedMovieM3U)
        IOSPlayerControlsTests.playFromDetail(app)
        let title = app.staticTexts["Access to the stream was denied"]
        XCTAssertTrue(title.waitForExistence(timeout: 12), "AccessDenied card within 12 s")
        UITestSupport.snap("robustness-403-access-denied", in: self)
    }
}
