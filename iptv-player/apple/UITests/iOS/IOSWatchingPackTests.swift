import XCTest

/// Build 16 "watching pack" on iPhone (docs/SCREENS.md §3.5/§3.7): next-episode card (autoplay + cancel), sleep
/// timer (countdown pill, stop), subtitle style / delay menu. Needs the Range media server on :8766
/// (`series-episodes.m3u` = UITests/Fixtures/series-episodes.m3u next to sintel.mp4/.mkv); skipped otherwise.
final class IOSWatchingPackTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static var seriesM3U: String { "\(VLCTestSupport.base)/series-episodes.m3u" }

    /// Series detail of the fixture → first episode plays.
    @MainActor
    private func launchEpisode(_ extra: [String] = []) throws -> XCUIApplication {
        try VLCTestSupport.requireServer()
        try UITestSupport.requireServed(Self.seriesM3U)
        let app = UITestSupport.launch(["-uiScreen", "seriesDetail", "-seedM3U", Self.seriesM3U, "-seedName", "Series",
                                        "-upNextSeconds", "4"] + extra, seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "series detail")
        play.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        XCTAssertTrue(IOSPlayerControlsTests.waitPlaying(app, after: 1), "episode plays")
        return app
    }

    /// Scrubs to `fraction` of the item (into the credits for 0.9).
    @MainActor
    private func scrub(_ app: XCUIApplication, to fraction: CGFloat) {
        IOSPlayerControlsTests.freshOverlay(app)
        let scrubber = app.descendants(matching: .any)["player_scrubber"]
        XCTAssertTrue(scrubber.exists)
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
    }

    @MainActor
    func testNextEpisodeCardPlaysTheNextEpisodeAndCancelKeepsTheCurrent() throws {
        let app = try launchEpisode()
        let title = app.staticTexts["player_title"]
        IOSPlayerControlsTests.freshOverlay(app)
        XCTAssertTrue(title.label.contains("S1E1"), title.label)

        // Credits: the card counts down and then plays S01E02.
        scrub(app, to: 0.9)
        let card = app.otherElements["player_up_next"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "next-episode card in the credits")
        let countdown = app.staticTexts["up_next_countdown"]
        XCTAssertTrue(countdown.label.hasPrefix("Next episode in"), countdown.label)
        XCTAssertTrue(app.buttons["up_next_play"].exists && app.buttons["up_next_cancel"].exists)
        UITestSupport.snap("watch-up-next-card", in: self)
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "autoplay after the countdown")
        IOSPlayerControlsTests.freshOverlay(app)
        let switched = NSPredicate(format: "label CONTAINS 'S1E2'")
        expectation(for: switched, evaluatedWith: title)
        waitForExpectations(timeout: 10)

        // Cancel: the card goes and the episode keeps playing to its end without switching.
        XCTAssertTrue(IOSPlayerControlsTests.waitPlaying(app, after: 1), "S01E02 plays")
        scrub(app, to: 0.9)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "card again")
        app.buttons["up_next_cancel"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), "cancelled")
        sleep(6)
        XCTAssertFalse(card.exists, "stays cancelled")
        IOSPlayerControlsTests.freshOverlay(app)
        XCTAssertTrue(title.label.contains("S1E2"), "no switch after cancel: \(title.label)")
    }

    @MainActor
    func testSleepTimerCountsDownAndStops() throws {
        try VLCTestSupport.requireServer()
        // One sleep-timer "minute" = 0.4 s → "15 min" fires after 6 s (fade included).
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-seedM3U", VLCTestSupport.mp4MovieM3U, "-seedName", "Movies",
                                        "-sleepTimerMinuteMs", "400"], seed: false)
        IOSPlayerControlsTests.playFromDetail(app)
        XCTAssertTrue(IOSPlayerControlsTests.waitPlaying(app, after: 1), "movie plays")
        IOSPlayerControlsTests.freshOverlay(app)
        app.buttons["Sleep timer"].tap()
        XCTAssertTrue(app.buttons["End of movie"].waitForExistence(timeout: 3), "VOD offers end of movie")
        app.buttons["15 min"].tap()
        let pill = app.descendants(matching: .any)["sleep_timer_indicator"]
        XCTAssertTrue(pill.waitForExistence(timeout: 3), "countdown pill")
        XCTAssertTrue(pill.label.hasPrefix("Sleep in"), pill.label)
        UITestSupport.snap("watch-sleep-timer-pill", in: self)
        XCTAssertTrue(app.staticTexts["sleep_timer_fired"].waitForExistence(timeout: 15), "stopped notice")
        let playPause = app.buttons["player_play_pause"]
        IOSPlayerControlsTests.showOverlay(app)
        XCTAssertEqual(playPause.value as? String, "Paused", "paused by the sleep timer")
        XCTAssertFalse(pill.exists, "timer gone")
    }

    @MainActor
    func testSubtitleMenuShowsStyleAndDelay() throws {
        let app = try IOSPlayerControlsTests.launchMovie(VLCTestSupport.movieM3U)
        IOSPlayerControlsTests.playFromDetail(app)
        XCTAssertTrue(IOSPlayerControlsTests.waitPlaying(app, after: 1), "MKV plays")
        IOSPlayerControlsTests.freshOverlay(app)
        // Paused while the menus are open: with VLCKit rendering, XCUITest waits ~60 s for "idle" per step and the
        // 3-min fixture would run out meanwhile.
        app.buttons["player_play_pause"].tap()
        // A showing track: the style change then reopens the VLCKit item in place.
        app.buttons["Subtitles"].tap()
        let turkish = app.buttons["Turkish"]
        XCTAssertTrue(turkish.waitForExistence(timeout: 3))
        turkish.tap()
        IOSPlayerControlsTests.showOverlay(app)
        app.buttons["Subtitles"].tap()
        let style = app.buttons["Style"]
        XCTAssertTrue(style.waitForExistence(timeout: 3), "style submenu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delay'")).firstMatch.exists, "delay on VLCKit")
        style.tap()
        let size = app.buttons["Size"]
        XCTAssertTrue(size.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Colour"].exists && app.buttons["Background"].exists)
        size.tap()
        let large = app.buttons["Large"]
        XCTAssertTrue(large.waitForExistence(timeout: 3))
        UITestSupport.snap("watch-subtitle-style-menu", in: self)
        large.tap()
        sleep(2)
        // The in-place reopen plays (like "Fix sync"); otherwise resume by hand.
        if IOSPlayerControlsTests.state(app).value != "Playing" { app.buttons["player_play_pause"].tap() }
        XCTAssertTrue(IOSPlayerControlsTests.waitPlaying(app, after: 1, timeout: 30), "plays on after the style change")
        VLCTestSupport.assertNoErrorCard(app, "subtitle style")
    }
}
