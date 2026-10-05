import XCTest

/// iPhone: MKV / MPEG-TS through VLCKit, HLS through AVPlayer, track menus, aspect, zapping.
final class IOSVLCPlaybackTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func showOverlay(_ app: XCUIApplication) {
        let close = app.buttons["player_close"]
        if close.exists { app.otherElements["video_surface"].tap() }   // hide → re-show resets the 3 s timer
        app.otherElements["video_surface"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "overlay")
    }

    /// Movies via the tab bar or the redesign's title menu (whichever the build has).
    @MainActor
    private func openMovies(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Movies"]
        let menu = app.buttons["section_menu"]
        let headerTab = app.buttons["tab_movies"]   // redesign: header text tabs
        for _ in 0..<30 where !tab.exists && !menu.exists && !headerTab.exists { usleep(500_000) }
        if headerTab.exists { headerTab.tap(); return }
        if tab.exists { tab.tap(); return }
        XCTAssertTrue(menu.exists, "navigation to Movies")
        menu.tap()
        let item = app.buttons["Movies"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    @MainActor
    func testLiveMKVTracksAspectAndZapToTSAndHLS() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-uiScreen", "player", "-seedM3U", VLCTestSupport.liveM3U, "-seedName", "VLC"], seed: false)
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30))
        sleep(7)
        VLCTestSupport.assertNoErrorCard(app, "MKV")
        UITestSupport.snap("vlc-ios-01-mkv-playing", in: self)

        showOverlay(app)
        UITestSupport.snap("vlc-ios-02-mkv-overlay", in: self)

        // The tool buttons only appear when the engine reported tracks: VLCKit found the two audio
        // tracks (tur/eng) and the two SRT subtitle tracks of the MKV. (Menu contents/language names:
        // EngineTests + TrackNamingTests; XCUITest cannot open a SwiftUI Menu inside the player's
        // full-screen cover on the iOS 26 simulator.)
        XCTAssertTrue(app.buttons["Audio"].waitForExistence(timeout: 3), "VLCKit audio tracks")
        XCTAssertTrue(app.buttons["Subtitles"].exists, "VLCKit subtitle tracks")
        XCTAssertTrue(app.buttons["Aspect ratio"].exists)

        // Zap (swipe up) → progressive MPEG-TS (MPEG-2 video + MP2 audio) via VLCKit.
        surface.swipeUp()
        sleep(9)
        VLCTestSupport.assertNoErrorCard(app, "MPEG-TS")
        UITestSupport.snap("vlc-ios-07-ts-playing", in: self)

        // Zap again → HLS via AVPlayer.
        surface.swipeUp()
        sleep(10)
        VLCTestSupport.assertNoErrorCard(app, "HLS")
        UITestSupport.snap("vlc-ios-08-hls-avplayer", in: self)
    }

    /// The real-world trigger: an MKV movie (Xtream VOD) opened from the movie detail.
    @MainActor
    func testMKVMovieFromDetail() throws {
        try VLCTestSupport.requireServer()
        let app = UITestSupport.launch(["-seedM3U", VLCTestSupport.movieM3U, "-seedName", "VLC"], seed: false)
        openMovies(app)
        // Poster: `movie_<id>` (redesign) or the poster card labelled with the title.
        let movie = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'movie_' OR label CONTAINS 'Sintel'")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 15))
        movie.tap()
        let play = app.buttons.matching(NSPredicate(format: "identifier == 'detail_play' OR label == 'Play'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        sleep(8)
        VLCTestSupport.assertNoErrorCard(app, "MKV movie")
        showOverlay(app)
        UITestSupport.snap("vlc-ios-09-mkv-movie", in: self)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        app.otherElements["video_surface"].tap()
        sleep(1)
        UITestSupport.snap("vlc-ios-10-mkv-movie-landscape", in: self)
        XCUIDevice.shared.orientation = .portrait
    }
}
