import XCTest

/// Build 11 "professional search" (SCREENS §3.6): description matches with an excerpt, "Did you mean",
/// TV programmes ("On TV"), filter chips + "Show all", recent searches.
final class IOSProSearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func field(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication, submit: Bool = false) {
        let field = field(app)
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.buttons.firstMatch.tap()   // clear
            field.tap()   // iPad: the toolbar field can lose focus with the clear button
        }
        field.typeText(submit ? text + "\n" : text)
    }

    @MainActor
    private func element(_ prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// Fake Xtream panel: "Seyran" is only in the description of "Yalı Çapkını"; "konuşanlr" is a typo.
    @MainActor
    func testDescriptionMatchAndDidYouMean() throws {
        let panel = "\(VLCTestSupport.base)"
        try UITestSupport.requireServed("\(panel)/player_api.php?username=demo&password=demo")
        let app = UITestSupport.launch(["-seedXtream", panel, "-seedName", "Panel"], seed: false)
        XCTAssertTrue(app.buttons["open_search"].waitForExistence(timeout: 30), "home loaded")
        app.buttons["open_search"].tap()

        search("seyran", in: app)
        let description = app.buttons["search_description_series_903"]
        XCTAssertTrue(description.waitForExistence(timeout: 10), "found by its description")
        XCTAssertTrue(description.label.contains("Seyran"), "excerpt with the matched word: \(description.label)")
        XCTAssertFalse(element("search_series_", in: app).exists, "not a title match")
        app.swipeUp()   // results scroll → keyboard goes away
        UITestSupport.snap("prosearch-ios-description", in: self)

        search("konuşanlr", in: app)
        let chip = app.buttons["search_did_you_mean"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "did-you-mean chip")
        XCTAssertTrue(chip.label.contains("konuşanlar"), chip.label)
        XCTAssertTrue(app.buttons["search_similar_series_901"].exists, "similar results")
        UITestSupport.snap("prosearch-ios-didyoumean", in: self)
        chip.tap()
        XCTAssertTrue(app.buttons["search_series_901"].waitForExistence(timeout: 10), "corrected search runs")
        XCTAssertEqual(field(app).value as? String, "konuşanlar")
    }

    /// Demo M3U + EPG: a programme title ("Derby Day") → "On TV" → plays its channel; filter chips and
    /// "Show all"; the submitted query reappears under recent searches.
    @MainActor
    func testProgrammesFiltersAndRecentSearches() throws {
        let app = UITestSupport.launch()
        XCTAssertTrue(app.buttons["open_search"].waitForExistence(timeout: 30), "home loaded")
        sleep(4)   // EPG loads in the background after the lists
        app.buttons["open_search"].tap()

        search("ha", in: app, submit: true)
        let movieChip = app.buttons["search_filter_movies"]
        XCTAssertTrue(movieChip.waitForExistence(timeout: 10), "filter chips")
        XCTAssertTrue(app.buttons["search_filter_live"].exists)
        XCTAssertTrue(app.buttons["search_filter_series"].exists)
        movieChip.tap()
        XCTAssertTrue(element("search_list_movie_", in: app).waitForExistence(timeout: 10), "full movie list")
        XCTAssertFalse(element("search_channel_", in: app).exists, "only movies")
        UITestSupport.snap("prosearch-ios-filters", in: self)
        app.buttons["search_filter_all"].tap()
        let seeAll = app.buttons["see_all_search_series"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        seeAll.tap()
        XCTAssertTrue(element("search_list_series_", in: app).waitForExistence(timeout: 10), "Show all → list")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        search("derby", in: app, submit: true)
        let programme = element("search_programme_", in: app)
        XCTAssertTrue(programme.waitForExistence(timeout: 15), "programme under On TV")
        app.swipeUp()
        UITestSupport.snap("prosearch-ios-tv", in: self)
        if !programme.isHittable { app.swipeDown() }
        programme.tap()
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "plays the channel")
        _ = app.buttons["player_close"].waitForNonExistence(timeout: 8)
        surface.tap()
        XCTAssertTrue(app.buttons["player_close"].waitForExistence(timeout: 3))
        app.buttons["player_close"].tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))

        // Empty field: recent searches, newest first ("derby" was played from, "ha" submitted).
        let field = field(app)
        field.tap()
        field.buttons.firstMatch.tap()
        let first = app.buttons["search_recent_0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "recent searches")
        XCTAssertTrue(first.label.contains("derby"), first.label)
        XCTAssertTrue(app.buttons["search_recent_1"].label.contains("ha"))
        UITestSupport.snap("prosearch-ios-recent", in: self)
        first.tap()
        XCTAssertTrue(element("search_programme_", in: app).waitForExistence(timeout: 10), "recent search runs again")
    }
}
