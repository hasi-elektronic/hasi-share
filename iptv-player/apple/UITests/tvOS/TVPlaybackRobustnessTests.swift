import XCTest

/// Apple TV playback robustness (SCREENS §3.7, §4): live never pauses by itself; an HTTP 403
/// movie shows the AccessDenied card instead of an endless spinner.
final class TVPlaybackRobustnessTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// "Playing"/"Paused" of the live overlay (▶ on the picture shows it on live, it never pauses).
    @MainActor
    static func playState(_ app: XCUIApplication) -> String {
        let playPause = app.buttons["player_play_pause"]
        if !playPause.exists { XCUIRemote.shared.press(.right) }
        guard playPause.waitForExistence(timeout: 3) else { return "" }
        return playPause.value as? String ?? ""
    }

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
            XCTAssertNotEqual(Self.playState(app), "Paused", "live paused by itself after \(Int(Date().timeIntervalSince(start))) s")
        }
        XCTAssertEqual(Self.playState(app), "Playing", "live still playing after 60 s")
    }

    @MainActor
    func testVODHTTP403ShowsAccessDenied() throws {
        try VLCTestSupport.requireServer()
        let remote = XCUIRemote.shared
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.deniedMovieM3U, "-seedName", "Movies"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        XCTAssertTrue(play.hasFocus, "Play focused on the detail")
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Access to the stream was denied"].waitForExistence(timeout: 12), "AccessDenied card within 12 s")
        UITestSupport.snap("tv-robustness-403-access-denied", in: self)
    }
}
