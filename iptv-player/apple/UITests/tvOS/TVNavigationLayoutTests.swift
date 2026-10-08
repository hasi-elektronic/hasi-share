import XCTest

/// Build 16 QA regressions on Apple TV (navigation, focus, layout): B-01 Menu on the tab bar over a detail page,
/// B-03 series detail after playback, B-04 Menu on the add-source error card, B-08 guide entry focus, B-12 Home
/// default focus, M-09 Discover comes back at once.
final class TVNavigationLayoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    private func focus(_ element: XCUIElement, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    /// "identifier / label" of the focused element (failure messages).
    @MainActor
    private func focusedElement(_ app: XCUIApplication) -> String {
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return f.exists ? "\(f.elementType.rawValue) id=\(f.identifier) label=\(f.label)" : "none"
    }

    /// Presses ▲ until a tab of the top tab bar has the focus.
    @MainActor
    private func focusTabBar(_ app: XCUIApplication, limit: Int = 8) -> Bool {
        let focusedTab = app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        for _ in 0..<limit {
            if focusedTab.exists { return true }
            remote.press(.up)
            usleep(500_000)
        }
        return focusedTab.exists
    }

    /// B-01: Menu with the focus on the floating tab bar over a pushed detail page popped nothing – the system
    /// left the app. It must pop the detail (never exit while the tab's stack is not at its root).
    @MainActor
    func testMenuOnTabBarOverDetailPopsTheDetail() throws {
        let app = UITestSupport.launch(["-uiScreen", "movieDetail", "-uiSeedLibrary"])
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "movie detail pushed on Home")
        sleep(2)
        XCTAssertTrue(focusTabBar(app), "▲ from the detail reaches the tab bar")
        UITestSupport.snap("b16-tvos-01-tabbar-over-detail", in: self)
        remote.press(.menu)
        XCTAssertTrue(play.waitForNonExistence(timeout: 5), "Menu pops the detail")
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "the app is still in front")
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 5), "Home root shown")
        UITestSupport.snap("b16-tvos-02-after-menu", in: self)
    }

    /// B-12: ▼ from the tab bar on Home focuses the primary ▶ pill, not "Favorite".
    @MainActor
    func testHomeDownFromTabBarFocusesPlay() throws {
        let app = UITestSupport.launch(["-uiSeedLibrary"])
        let play = app.buttons["hero_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        sleep(2)
        XCTAssertTrue(focusTabBar(app))
        remote.press(.down)
        usleep(900_000)
        XCTAssertTrue(play.hasFocus, "▶ Play / Resume has the focus, got \(focusedElement(app))")
        UITestSupport.snap("b16-tvos-03-home-play-focused", in: self)
    }

    /// B-08: the first ▼ into the guide focuses the programme airing now (first row), not the next one.
    @MainActor
    func testGuideEntryFocusesTheProgrammeOnAir() throws {
        let app = UITestSupport.launch(["-uiScreen", "guide"])
        XCTAssertTrue(app.otherElements["guide_panel"].waitForExistence(timeout: 30) || app.scrollViews["guide_panel"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(focusTabBar(app))
        let focusedBlock = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'epg_'")).firstMatch
        for _ in 0..<3 where !focusedBlock.exists {   // tab bar → (category chips) → list
            remote.press(.down)
            usleep(800_000)
        }
        XCTAssertTrue(focusedBlock.exists, "a programme block has the focus")
        XCTAssertTrue(focusedBlock.identifier.hasPrefix("epg_now_"), "the block airing now, got \(focusedBlock.identifier)")
        let firstNow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'epg_now_'")).firstMatch
        XCTAssertEqual(focusedBlock.identifier, firstNow.identifier, "in the first row")
        UITestSupport.snap("b16-tvos-04-guide-now-focused", in: self)
    }

    /// B-04: Menu on the add-source error card returns to the filled form (nothing typed is lost).
    @MainActor
    func testMenuOnAddSourceErrorKeepsTheForm() throws {
        try UITestSupport.requireServed("\(VLCTestSupport.base)/vlc-movie.m3u")
        let app = UITestSupport.launch(["-uiScreen", "addXtream"], seed: false)
        let server = app.textFields["field_server"]
        XCTAssertTrue(server.waitForExistence(timeout: 15))
        // The fixture server answers /status/404/… with HTTP 404 → "server not found" error card.
        let serverURL = "\(VLCTestSupport.base)/status/404/x"
        let fields: [(XCUIElement, String)] = [
            (server, serverURL),
            (app.textFields["field_username"], "demo"),
            (app.secureTextFields["field_password"], "secret"),
        ]
        for (field, text) in fields {
            XCTAssertTrue(focus(field, pressing: .down), "\(field.identifier) should get focus")
            remote.press(.select)
            sleep(2)
            app.typeText(text)
            sleep(1)
            remote.press(.menu)   // leave the keyboard, keep the text
            sleep(2)
        }
        // A Form button is reported as a cell (no identifier) on tvOS.
        let connect = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Connect'")).firstMatch
        XCTAssertTrue(focus(connect, pressing: .down), "Connect, focus: \(focusedElement(app))")
        remote.press(.select)
        let card = app.descendants(matching: .any)["add_source_error"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "error card")
        UITestSupport.snap("b16-tvos-05-add-source-error", in: self)
        remote.press(.menu)
        XCTAssertTrue(server.waitForExistence(timeout: 5), "back on the form")
        XCTAssertEqual(server.value as? String, serverURL, "server kept")
        XCTAssertEqual(app.textFields["field_username"].value as? String, "demo", "user kept")
        XCTAssertEqual((app.secureTextFields["field_password"].value as? String ?? "").count, 6, "password kept")
        UITestSupport.snap("b16-tvos-06-form-kept", in: self)
    }

    /// B-03: after playing an episode from the series detail, the detail offers "Continue S1E1" at once.
    @MainActor
    func testSeriesDetailFollowsPlayback() throws {
        let m3u = "\(VLCTestSupport.base)/series-local.m3u"   // copy of UITests/Fixtures/series-local.m3u
        try UITestSupport.requireServed(m3u)
        let app = UITestSupport.launch(["-seedM3U", m3u, "-seedName", "Local", "-uiScreen", "seriesDetail"], seed: false)
        let play = app.buttons["detail_play"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "series detail")
        XCTAssertTrue(play.label.contains("Play S1E1"), "nothing watched yet: \(play.label)")
        sleep(1)
        // ▼ from the tab bar lands on ▶ (not on the nearer ⭐), like the Home hero.
        XCTAssertTrue(focus(play, pressing: .down, limit: 2), "Play focused, got \(focusedElement(app))")
        remote.press(.select)
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15), "player")
        sleep(8)
        for _ in 0..<3 where surface.exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(surface.exists, "player closed")
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let resumed = NSPredicate(format: "label CONTAINS 'Continue S1E1'")
        expectation(for: resumed, evaluatedWith: play)
        waitForExpectations(timeout: 5)
        UITestSupport.snap("b16-tvos-07-series-continue", in: self)
    }

    /// M-09: OK on "Discover" while a category grid is shown brings the browse page back at once (it stays alive
    /// under the grid instead of being rebuilt).
    @MainActor
    func testDiscoverComesBackAtOnce() throws {
        try checkDiscoverComesBack(app: UITestSupport.launch(), rounds: 2)
    }

    /// The same on a big Xtream panel (35 000 movies; QA's `panel.py PORT 35000 9000`), when
    /// TEST_RUNNER_BIG_PANEL=http://localhost:PORT is set.
    @MainActor
    func testDiscoverComesBackAtOnceOnABigPanel() throws {
        guard let panel = ProcessInfo.processInfo.environment["BIG_PANEL"], !panel.isEmpty else { throw XCTSkip("BIG_PANEL not set") }
        try UITestSupport.requireServed("\(panel)/player_api.php?username=demo&password=demo")
        try checkDiscoverComesBack(app: UITestSupport.launch(["-seedXtream", panel, "-seedName", "Big"], seed: false), rounds: 3)
    }

    @MainActor
    private func checkDiscoverComesBack(app: XCUIApplication, rounds: Int) throws {
        let tab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 60))
        XCTAssertTrue(focusTabBar(app))
        XCTAssertTrue(focus(tab, pressing: .right, limit: 5), "Movies tab")
        sleep(2)
        remote.press(.down)
        usleep(800_000)
        let column = app.buttons.matching(NSPredicate(format: "hasFocus == true AND (identifier == 'country_picker' OR identifier BEGINSWITH 'category_')")).firstMatch
        XCTAssertTrue(focus(column, pressing: .left, limit: 6), "column")
        let discover = app.buttons["category_discover"]
        let hero = app.buttons["hero_play"]
        for pass in 1...rounds {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_row_'")).firstMatch
            XCTAssertTrue(focus(row, pressing: .down, limit: 4) || focus(row, pressing: .up, limit: 20), "category row")
            remote.press(.select)
            let grid = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'grid_'")).firstMatch
            XCTAssertTrue(grid.waitForExistence(timeout: 10), "grid (pass \(pass))")
            XCTAssertFalse(hero.exists, "the hidden browse page is out of the accessibility tree")
            XCTAssertTrue(focus(discover, pressing: .up, limit: 20))
            let start = Date()
            remote.press(.select)
            var elapsed = 0.0
            while !hero.exists, Date().timeIntervalSince(start) < 5 { usleep(20_000) }
            elapsed = Date().timeIntervalSince(start)
            XCTAssertTrue(hero.exists, "browse page back (pass \(pass))")
            XCTAssertTrue(grid.waitForNonExistence(timeout: 2))
            print("[b16] Discover pass \(pass): hero after \(elapsed) s")
            // A rebuilt page took 1.6 s on a 35 000-movie panel; XCUITest's press + query alone take a few 100 ms.
            XCTAssertLessThan(elapsed, 1.2, "Discover back at once (pass \(pass): \(elapsed) s)")
            XCTAssertTrue(discover.hasFocus)
        }
        UITestSupport.snap("b16-tvos-08-discover-back", in: self)
    }
}
