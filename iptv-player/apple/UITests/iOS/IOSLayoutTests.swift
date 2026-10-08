import XCTest

/// Build 16 QA regressions on iPhone (layout, Dynamic Type, detail refresh): IOS-04 hero at accessibility sizes,
/// IOS-07 series detail after playback, IOS-14 Live rows at accessibility sizes, IOS-16 format pill,
/// IOS-26 search capsule in landscape, IOS-05 short guide blocks (screenshots).
final class IOSLayoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private static let axXL = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

    /// IOS-04: at AX sizes the hero ▶ pill is not clipped and does not overlap Favorite / Info.
    @MainActor
    func testHeroActionsAtAccessibilitySize() throws {
        let app = UITestSupport.launch(["-uiSeedLibrary"] + Self.axXL)
        let play = app.buttons["hero_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(play.frame.minX, screen.minX, "pill inside the screen")
        XCTAssertLessThanOrEqual(play.frame.maxX, screen.maxX)
        let info = app.buttons["hero_info"]
        if info.exists { XCTAssertFalse(play.frame.intersects(info.frame), "pill and Info do not overlap") }
        let fav = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_'")).firstMatch
        if fav.exists { XCTAssertFalse(play.frame.intersects(fav.frame), "pill and Favorite do not overlap") }
        UITestSupport.snap("b16-ios-01-hero-ax", in: self)
    }

    /// IOS-14: Live rows at AX sizes keep the channel name and the programme (screenshot) and are tappable rows.
    @MainActor
    func testLiveRowsAtAccessibilitySize() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"] + Self.axXL)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        sleep(3)
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(row.frame.maxX, screen.maxX + 1, "row inside the screen")
        UITestSupport.snap("b16-ios-02-live-ax", in: self)
    }

    /// IOS-16: with the restart button in the action row the format pill stays one line ("MP4", not "M / P / 4").
    @MainActor
    func testFormatPillDoesNotWrap() throws {
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-uiSeedLibrary"])
        XCTAssertTrue(app.buttons["detail_restart"].waitForExistence(timeout: 30), "movie with progress → restart button")
        let pill = app.descendants(matching: .any)["format_pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(pill.frame.width, pill.frame.height, "a wide capsule, not a wrapped column")
        UITestSupport.snap("b16-ios-03-format-pill", in: self)
    }

    /// IOS-26: in landscape the last search results scroll above the floating search capsule.
    @MainActor
    func testSearchResultsClearTheSearchFieldInLandscape() throws {
        let app = UITestSupport.launch()
        XCTAssertTrue(app.buttons["open_search"].waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        app.buttons["open_search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ha\n")
        let hits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search_movie_' OR identifier BEGINSWITH 'search_series_'"))
        XCTAssertTrue(hits.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeUp(); usleep(400_000) }
        sleep(1)
        let lowest = (0..<hits.count).map { hits.element(boundBy: $0) }.filter { $0.isHittable }.max { $0.frame.maxY < $1.frame.maxY }
        let last = try XCTUnwrap(lowest)
        XCTAssertLessThanOrEqual(last.frame.maxY, field.frame.minY + 4, "the last row ends above the search capsule")
        UITestSupport.snap("b16-ios-04-search-landscape", in: self)
    }

    /// IOS-07: after playing an episode the series detail offers "Continue S1E1" (not "Play S1E1").
    @MainActor
    func testSeriesDetailFollowsPlayback() throws {
        let m3u = "\(VLCTestSupport.base)/series-local.m3u"   // copy of UITests/Fixtures/series-local.m3u
        try UITestSupport.requireServed(m3u)
        let app = UITestSupport.launch(["-seedM3U", m3u, "-seedName", "Local", "-uiScreen", "seriesDetail"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "series detail")
        XCTAssertTrue(play.label.contains("Play S1E1"), "nothing watched yet: \(play.label)")
        play.tap()
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "player")
        sleep(8)
        surface.tap()
        let close = app.buttons["player_close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        let resumed = NSPredicate(format: "label CONTAINS 'Continue S1E1'")
        expectation(for: resumed, evaluatedWith: play)
        waitForExpectations(timeout: 5)
        UITestSupport.snap("b16-ios-05-series-continue", in: self)
    }

    /// IOS-05: short programmes in the guide rows keep their text inside the block (screenshot of the guide).
    @MainActor
    func testGuideBlocksScreenshot() throws {
        let app = UITestSupport.launch(["-uiScreen", "guide"])
        let block = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'epg_now_'")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 30))
        sleep(2)
        UITestSupport.snap("b16-ios-06-guide", in: self)
    }
}
