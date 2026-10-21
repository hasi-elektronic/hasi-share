import AVKit
import XCTest

/// Build 17 (IOS-10/IOS-11): Picture in Picture and AirPlay in the player tools (SCREENS §3.7). PiP only for AVPlayer
/// content; VLCKit items keep AirPlay (sound only) but have no PiP button. PiP checks need a device / simulator with
/// PiP support (iPad simulators; the iOS 26.4 iPhone simulator reports none – the button is hidden there).
final class IOSPictureInPictureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func waitPerf(_ app: XCUIApplication, contains part: String, timeout: TimeInterval = 40) -> Bool {
        let overlay = app.descendants(matching: .any)["perf_overlay"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if overlay.exists, overlay.label.contains(part) { return true }
            usleep(250_000)
        }
        return false
    }

    /// The test runner shares the simulator: AVKit answers the same as in the app.
    private var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    @MainActor
    private func waitLivePlaying(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            IOSPlayerControlsTests.freshOverlay(app)
            if app.buttons["player_play_pause"].value as? String == "Playing" { return true }
            sleep(1)
        }
        return false
    }

    @MainActor
    func testPiPButtonOnlyForAVPlayerAirPlayAlways() throws {
        let app = UITestSupport.launch(["-uiScreen", "player", "-perfOverlay"])
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitPerf(app, contains: "Engine: AVPlayer"), "HLS demo channel on AVPlayer")
        IOSPlayerControlsTests.freshOverlay(app)
        XCTAssertEqual(app.buttons["player_pip"].exists, pipSupported, "PiP offered for AVPlayer content (where supported)")
        XCTAssertTrue(app.descendants(matching: .any)["player_airplay"].exists, "AirPlay picker")
        UITestSupport.snap("pip/ios-01-tools-avplayer", in: self)
        app.terminate()

        let vlc = UITestSupport.launch(["-uiScreen", "player", "-perfOverlay", "-playerEngine", "vlc"])
        XCTAssertTrue(vlc.otherElements["video_surface"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitPerf(vlc, contains: "Engine: VLCKit"), "VLC override")
        IOSPlayerControlsTests.freshOverlay(vlc)
        XCTAssertFalse(vlc.buttons["player_pip"].exists, "no PiP for VLCKit")
        XCTAssertTrue(vlc.descendants(matching: .any)["player_airplay"].exists, "AirPlay stays (sound only)")
        UITestSupport.snap("pip/ios-02-tools-vlc", in: self)
    }

    /// The PiP button dismisses the player screen while playback goes on in the PiP window; playing another
    /// channel from the app brings the full-screen player back and ends PiP.
    @MainActor
    func testPiPButtonMinimizesPlayerAndNewItemRestoresIt() throws {
        try XCTSkipUnless(pipSupported, "no Picture in Picture on this simulator (run on an iPad simulator)")
        let app = UITestSupport.launch(["-uiScreen", "player"])
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        XCTAssertTrue(waitLivePlaying(app), "live channel plays")
        // The overlay hides after 3 s while playing: show it fresh until PiP is possible, then tap at once.
        let pip = app.buttons["player_pip"]
        var tapped = false
        for _ in 0..<15 where !tapped {
            IOSPlayerControlsTests.freshOverlay(app)
            if pip.exists, pip.isEnabled {
                pip.tap()
                tapped = true
            } else {
                sleep(1)
            }
        }
        XCTAssertTrue(tapped, "PiP button enabled once the video plays")
        XCTAssertTrue(surface.waitForNonExistence(timeout: 10), "player screen dismissed – the video is in the PiP window")
        let channel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).element(boundBy: 1)
        XCTAssertTrue(channel.waitForExistence(timeout: 10), "the app can be browsed meanwhile")
        UITestSupport.snap("pip/ios-03-minimized", in: self)

        channel.tap()
        if !surface.waitForExistence(timeout: 3) {
            // iPad: a row tap selects the channel; its panel's Play plays it.
            app.buttons.matching(NSPredicate(format: "label == 'Play'")).firstMatch.tap()
        }
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "a new item opens the full-screen player again")
        XCTAssertTrue(app.otherElements["player_pip_active"].waitForNonExistence(timeout: 10), "PiP ended")
        UITestSupport.snap("pip/ios-04-back-fullscreen", in: self)
    }
}
