import XCTest

/// Build 16 "watching pack" on Apple TV, remote only (docs/SCREENS.md §3.5/§3.7): next-episode card ("Play now"
/// focused, autoplay, Menu cancels), sleep timer from the top row, subtitle style items. Needs :8766.
final class TVWatchingPackTests: XCTestCase {
    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUp() {
        continueAfterFailure = false
    }

    private static var seriesM3U: String { "\(VLCTestSupport.base)/series-episodes.m3u" }

    @MainActor
    private func press(_ button: XCUIRemote.Button, _ times: Int = 1, pause: UInt32 = 350_000) {
        for _ in 0..<times {
            remote.press(button)
            usleep(pause)
        }
    }

    /// Series detail of the fixture → Play (first episode).
    @MainActor
    private func launchEpisode() throws -> XCUIApplication {
        try VLCTestSupport.requireServer()
        try UITestSupport.requireServed(Self.seriesM3U)
        let app = UITestSupport.launch(["-uiScreen", "seriesDetail", "-seedM3U", Self.seriesM3U, "-seedName", "Series",
                                        "-upNextSeconds", "4", "-seekCommitMs", "400"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "series detail")
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        remote.press(.select)
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(TVPlayerControlsTests.waitPlaying(app, after: 1), "episode plays")
        return app
    }

    /// ▶ × 15 (10 s each) moves the seek target ~150 s on → the credits of the 3-min fixture.
    @MainActor
    private func seekIntoCredits() {
        press(.right, 15, pause: 150_000)
    }

    @MainActor
    func testNextEpisodeCardAutoplaysAndMenuCancels() throws {
        let app = try launchEpisode()
        seekIntoCredits()
        let card = app.otherElements["player_up_next"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "next-episode card in the credits")
        let playNow = app.buttons["up_next_play"]
        sleep(1)
        XCTAssertTrue(playNow.hasFocus, "Play now has the focus")
        UITestSupport.snap("tv-watch-up-next-card", in: self)
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "autoplay after the countdown")
        let title = app.staticTexts["player_title"]
        if !title.exists { remote.press(.up) }
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'S1E2'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(TVPlayerControlsTests.waitPlaying(app, after: 1), "S01E02 plays")
        seekIntoCredits()
        XCTAssertTrue(card.waitForExistence(timeout: 15), "card again")
        press(.menu)
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), "Menu cancels the card")
        XCTAssertTrue(app.otherElements["video_surface"].exists, "player stays open")
        sleep(6)
        XCTAssertFalse(card.exists, "stays cancelled")
    }

    @MainActor
    func testSleepTimerFromTheTopRow() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.mp4MovieM3U, "-seedName", "Movies",
                                        "-sleepTimerMinuteMs", "400"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<6 where !play.hasFocus {
            remote.press(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch.hasFocus ? .left : .down)
            sleep(1)
        }
        remote.press(.select)
        XCTAssertTrue(TVPlayerControlsTests.waitPlaying(app, after: 1), "movie plays")
        // Overlay (play/pause focused) → ▲ top row (close) → ▶ Audio · Aspect · Fix sync · Sleep timer (MP4: no subtitles).
        if !app.buttons["player_close"].exists { press(.up) }
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3))
        press(.up)
        press(.right, 4)
        press(.select)
        let fifteen = app.descendants(matching: .any).matching(NSPredicate(format: "label == '15 min'")).firstMatch
        XCTAssertTrue(fifteen.waitForExistence(timeout: 5), "sleep timer menu")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'End of movie'")).firstMatch.exists)
        press(.down)
        press(.select)
        let pill = app.descendants(matching: .any)["sleep_timer_indicator"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "countdown pill")
        UITestSupport.snap("tv-watch-sleep-timer", in: self)
        XCTAssertTrue(app.staticTexts["sleep_timer_fired"].waitForExistence(timeout: 15), "stopped")
        XCTAssertEqual(TVPlayerControlsTests.state(app).value, "Paused")
    }

    @MainActor
    func testSubtitleMenuHasStyleItems() throws {
        let app = TVPlayerControlsTests.playMovie(VLCTestSupport.movieM3U)
        if !app.buttons["player_close"].exists { press(.up) }
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3))
        press(.up)
        press(.right, 2)   // close → Audio → Subtitles
        press(.select)
        let style = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Style'")).firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 5), "style submenu in the subtitle menu")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Delay'")).firstMatch.exists,
                      "delay on VLCKit")
        UITestSupport.snap("tv-watch-subtitle-menu", in: self)
        press(.menu)
    }
}
