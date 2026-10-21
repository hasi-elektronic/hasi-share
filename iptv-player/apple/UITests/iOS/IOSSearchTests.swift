import XCTest

/// Search shows channels, movies and series for one query (user report: it only listed movies).
final class IOSSearchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Demo M3U: "ha" prefixes "Anka Haber" (channel), "The Harbor Line" (movie) and "Harbor Lights" (series).
    @MainActor
    func testSearchFindsChannelsMoviesSeries() throws {
        let app = UITestSupport.launch()
        XCTAssertTrue(app.buttons["open_search"].waitForExistence(timeout: 30), "home loaded")
        app.buttons["open_search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ha")

        func element(_ prefix: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        XCTAssertTrue(element("search_channel_").waitForExistence(timeout: 10), "a channel hit")
        XCTAssertTrue(element("search_movie_").waitForExistence(timeout: 5), "a movie hit")
        XCTAssertTrue(element("search_series_").waitForExistence(timeout: 5), "a series hit")
        // Group order: live channels above movies above series.
        XCTAssertLessThan(element("search_channel_").frame.minY, element("search_movie_").frame.minY)
        XCTAssertLessThan(element("search_movie_").frame.minY, element("search_series_").frame.minY)
        UITestSupport.snap("ios-search-all-kinds", in: self)
    }
}
