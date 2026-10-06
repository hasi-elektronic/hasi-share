import XCTest

/// iPhone flows + screenshots: welcome → add M3U source → home (header text tabs, no tab bar) →
/// live channel grid → player; paywall; settings sheet; redesign screens (hero, rows, detail, guide, search).
final class IOSFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Switches the section with the header text tabs (`tab_home`, `tab_movies`, `tab_series`, `tab_live`, `tab_guide`).
    @MainActor
    static func openSection(_ id: String, in app: XCUIApplication) {
        let tab = app.buttons["tab_\(id)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "header tab \(id)")
        tab.tap()
    }

    @MainActor
    func testOnboardingAddSourceLiveAndPlayer() throws {
        let app = UITestSupport.launch(seed: false)
        XCTAssertTrue(app.buttons["add_add_source_m3u"].waitForExistence(timeout: 15))
        UITestSupport.snap("ios-01-welcome", in: self)

        app.buttons["add_add_source_m3u"].tap()
        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        UITestSupport.snap("ios-02-add-source-form", in: self)
        app.textFields["field_name"].tap()
        app.textFields["field_name"].typeText("Demo TV")
        url.tap()
        url.typeText(UITestSupport.seedM3U)
        UITestSupport.snap("ios-03-add-source-filled", in: self)
        app.buttons["action_connect"].tap()

        let done = app.buttons["add_source_continue"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "source should load")
        UITestSupport.snap("ios-04-source-added", in: self)
        done.tap()

        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "redesign: no bottom tab bar")
        sleep(1)
        UITestSupport.snap("ios-05-home", in: self)
        Self.openSection("live", in: app)
        let firstChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(firstChannel.waitForExistence(timeout: 10))
        UITestSupport.snap("ios-06-live-channels", in: self)

        firstChannel.tap()
        XCTAssertTrue(app.otherElements["video_surface"].waitForExistence(timeout: 10))
        sleep(8)   // let HLS start
        app.otherElements["video_surface"].tap()
        UITestSupport.snap("ios-07-player-playing", in: self)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        UITestSupport.snap("ios-08-player-landscape", in: self)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPaywall() throws {
        let app = UITestSupport.launch(["-uiScreen", "paywall"], trial: false)
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 15))
        sleep(2)
        UITestSupport.snap("ios-09-paywall", in: self)
    }

    @MainActor
    func testSettingsSheet() throws {
        let app = UITestSupport.launch()
        let gear = app.buttons["open_settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        sleep(1)
        UITestSupport.snap("ios-10-settings", in: self)
        // Open-source licenses (LGPL-2.1 notice for VLCKit).
        let licenses = app.buttons["settings_licenses"]
        for _ in 0..<6 where !(licenses.exists && licenses.isHittable) { app.swipeUp() }
        licenses.tap()
        XCTAssertTrue(app.staticTexts["LGPL-2.1-or-later"].waitForExistence(timeout: 5), "VLCKit license entry")
        UITestSupport.snap("ios-10b-licenses", in: self)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings_close"].tap()
        XCTAssertTrue(app.buttons["tab_home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLockedPlaybackOpensPaywall() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"], trial: false)
        let firstChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(firstChannel.waitForExistence(timeout: 30))
        firstChannel.tap()
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 10), "locked → paywall")
        UITestSupport.snap("ios-11-locked-paywall", in: self)
    }

    /// ⭐ of a channel (`fav_<fingerprint>:live:<id>`).
    @MainActor
    static func favoriteButton(channelId: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fav_' AND identifier ENDSWITH %@", ":live:\(channelId)")).firstMatch
    }

    /// One-tap ⭐ on a live card (spec §2): no dialog, undo toast, the Home favorites row shows the
    /// channel; "Undo" removes it again.
    @MainActor
    func testOneTapFavoriteFromLiveCard() throws {
        let app = UITestSupport.launch(["-uiScreen", "live", "-uiUndoSeconds", "20"])
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        let channelId = String(card.identifier.dropFirst("channel_".count))
        let star = Self.favoriteButton(channelId: channelId, in: app)
        XCTAssertTrue(star.exists, "⭐ on the live card")
        XCTAssertEqual(star.label, "Add to favorites")
        XCTAssertFalse(app.descendants(matching: .any)["live_section_favorites"].exists, "no favorites section yet")

        star.tap()
        XCTAssertTrue(app.otherElements["undo_toast"].waitForExistence(timeout: 2), "undo toast")
        XCTAssertFalse(app.alerts.firstMatch.exists, "no confirmation dialog")
        XCTAssertEqual(star.label, "Remove from favorites", "state flips at once")
        let header = app.descendants(matching: .any)["live_section_favorites"]
        let favCard = app.buttons["live_favorite_\(channelId)"]
        XCTAssertTrue(favCard.waitForExistence(timeout: 3), "first section of the live grid")
        XCTAssertLessThan(header.frame.minY, favCard.frame.minY)
        UITestSupport.snap("fav-ios-01-live-card-toast", in: self)

        Self.openSection("home", in: app)
        let favRow = app.buttons["see_all_favorite_channels"]
        XCTAssertTrue(favRow.waitForExistence(timeout: 5), "Home favorite channels row")
        let inRow = app.buttons.matching(identifier: "channel_card_\(channelId)").allElementsBoundByIndex
            .contains { $0.frame.minY > favRow.frame.minY && $0.frame.minY < favRow.frame.minY + 300 }
        XCTAssertTrue(inRow, "channel in the favorites row")
        UITestSupport.snap("fav-ios-02-home-row", in: self)

        let undo = app.buttons["action_undo"]
        XCTAssertTrue(undo.exists, "toast still offered on Home")
        undo.tap()
        XCTAssertTrue(favRow.waitForNonExistence(timeout: 3), "undo removes the favorite")
        XCTAssertTrue(app.otherElements["undo_toast"].waitForNonExistence(timeout: 2))
    }

    /// ⭐ in the player overlay (live): after closing, the Live grid's first section has the channel.
    @MainActor
    func testFavoriteFromPlayerOverlay() throws {
        let app = UITestSupport.launch(["-uiScreen", "live"])
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        let channelId = String(card.identifier.dropFirst("channel_".count))
        card.tap()
        let surface = app.otherElements["video_surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let star = Self.favoriteButton(channelId: channelId, in: app)
        // Let the overlay auto-hide once playing, then show it fresh (its 3 s count must not end mid-tap).
        _ = app.buttons["player_play_pause"].waitForNonExistence(timeout: 15)
        surface.tap()
        XCTAssertTrue(star.waitForExistence(timeout: 3), "⭐ in the overlay tools")
        XCTAssertEqual(star.label, "Add to favorites")
        star.tap()
        XCTAssertTrue(app.otherElements["undo_toast"].waitForExistence(timeout: 2), "undo toast in the player")
        UITestSupport.snap("fav-ios-03-player-overlay", in: self)
        XCTAssertEqual(Self.favoriteButton(channelId: channelId, in: app).label, "Remove from favorites")

        let close = app.buttons["player_close"]
        _ = close.waitForNonExistence(timeout: 6)   // overlay auto-hides; show it fresh for the tap
        surface.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        let header = app.descendants(matching: .any)["live_section_favorites"]
        let favCard = app.buttons["live_favorite_\(channelId)"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "\"Favorites\" section")
        XCTAssertTrue(favCard.exists, "channel in the favorites section")
        XCTAssertLessThan(header.frame.minY, favCard.frame.minY)
        let rest = app.descendants(matching: .any)["live_section_all"]
        XCTAssertTrue(rest.exists, "the other channels follow")
        XCTAssertLessThan(favCard.frame.minY, rest.frame.minY, "favorites are the first section")
        UITestSupport.snap("fav-ios-04-live-favorites-first", in: self)
    }

    /// Redesign walkthrough: hero + rows, movies/series tabs, detail screens, live grid, guide, favorites, search.
    @MainActor
    func testRedesignScreens() throws {
        let dir = "redesign-ios"
        let app = UITestSupport.launch(["-uiSeedLibrary"])
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 30), "home hero")
        sleep(3)   // artwork
        UITestSupport.snap("\(dir)-01-home", in: self)
        app.swipeUp()
        sleep(1)
        UITestSupport.snap("\(dir)-02-home-rows", in: self)

        Self.openSection("movies", in: app)
        XCTAssertTrue(app.buttons["hero_play"].waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.snap("\(dir)-03-movies", in: self)
        app.swipeUp()
        sleep(1)
        UITestSupport.snap("\(dir)-04-movies-rows", in: self)
        let top = app.buttons["top10_1"]
        if top.exists && top.isHittable { top.tap() } else { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'poster_'")).firstMatch.tap() }
        XCTAssertTrue(app.buttons["detail_play"].waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.snap("\(dir)-05-movie-detail", in: self)
        app.buttons["detail_close"].tap()

        Self.openSection("series", in: app)
        XCTAssertTrue(app.buttons["hero_info"].waitForExistence(timeout: 10))
        app.buttons["hero_info"].tap()
        XCTAssertTrue(app.buttons["detail_play"].waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.snap("\(dir)-06-series-detail", in: self)
        app.swipeUp()
        sleep(1)
        UITestSupport.snap("\(dir)-07-series-episodes", in: self)
        app.buttons["detail_close"].tap()

        Self.openSection("live", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.snap("\(dir)-08-live-grid", in: self)
        app.buttons["category_menu"].tap()
        sleep(1)
        UITestSupport.snap("\(dir)-09-live-category-menu", in: self)
        app.buttons["Favorites"].firstMatch.tap()
        sleep(1)

        Self.openSection("guide", in: app)
        XCTAssertTrue(app.buttons["guide_filter_0"].waitForExistence(timeout: 10), "guide chips")
        sleep(2)
        UITestSupport.snap("\(dir)-10-guide", in: self)

        app.buttons["open_settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        sleep(1)
        UITestSupport.snap("\(dir)-11-settings", in: self)
        app.buttons["settings_close"].tap()
        Self.openSection("home", in: app)
        app.buttons["open_search"].tap()
        let field = app.searchFields.firstMatch
        let found = field.waitForExistence(timeout: 5)
        if !found { UITestSupport.snap("\(dir)-debug-search", in: self); print(app.debugDescription) }
        XCTAssertTrue(found)
        field.typeText("ha")
        sleep(2)
        UITestSupport.snap("\(dir)-12-search", in: self)

    }
}
