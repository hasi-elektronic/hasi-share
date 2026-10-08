import XCTest

/// Build 16 (team A1): source edit + EPG URL (IOS-03), a second source keeps the current one and the picker /
/// list mark the active source (IOS-08), legal links (S1/IOS-19), time-zone list (U4), EPG shift presets (IOS-24),
/// accounts hidden.
final class IOSSourceManagementTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openSources(_ app: XCUIApplication) {
        let sources = app.buttons["settings_sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 30), "Sources row")
        sources.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, max: Int = 6) {
        for _ in 0..<max where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    @MainActor
    func testEditSourceKeepsItAndShowsEpgUrl() throws {
        try UITestSupport.requireServed(UITestSupport.seedM3U)
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        openSources(app)
        let row = app.buttons["settings_source_Demo TV"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let edit = app.buttons["source_edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Edit in the source detail")
        XCTAssertTrue(app.buttons["source_epg_url"].exists, "EPG URL row")
        XCTAssertTrue(app.buttons["source_epg_url"].label.contains("localhost:8765/redesign/epg.xml"), app.buttons["source_epg_url"].label)
        XCTAssertTrue(app.buttons["source_epg_shift"].exists || app.otherElements["source_epg_shift"].exists, "EPG shift picker")
        XCTAssertEqual(app.buttons["source_epg_shift_minus"].label, "15 minutes earlier", "VoiceOver label (L3)")
        UITestSupport.snap("a1-ios-source-detail", in: self)

        edit.tap()
        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertEqual(url.value as? String, UITestSupport.seedM3U, "prefilled from the Keychain secrets")
        XCTAssertTrue(app.textFields["field_epg_url"].exists, "EPG URL field visible in edit mode")
        let name = app.textFields["field_name"]
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Demo Edited")
        UITestSupport.snap("a1-ios-source-edit", in: self)
        let save = app.buttons["action_connect"]
        scrollTo(save, in: app)
        XCTAssertEqual(save.label, "Save")
        save.tap()
        let done = app.buttons["add_source_continue"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "re-validated and reloaded")
        XCTAssertTrue(app.staticTexts["Source saved"].exists)
        done.tap()
        XCTAssertTrue(app.navigationBars["Demo Edited"].waitForExistence(timeout: 5) || app.staticTexts["Demo Edited"].waitForExistence(timeout: 5),
                      "detail shows the new name")
    }

    @MainActor
    func testSecondSourceKeepsCurrentOneAndMarksActive() throws {
        try UITestSupport.requireServed(UITestSupport.seriesCategoriesM3U)
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        openSources(app)
        let add = app.buttons["settings_add_m3u"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let url = app.textFields["field_m3u_url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(UITestSupport.seriesCategoriesM3U)
        let name = app.textFields["field_name"]
        name.tap()
        name.typeText("Second")
        let connect = app.buttons["action_connect"]
        scrollTo(connect, in: app)
        connect.tap()
        let use = app.buttons["add_source_use"]
        XCTAssertTrue(use.waitForExistence(timeout: 30), "switching is offered, not done silently")
        UITestSupport.snap("a1-ios-second-source", in: self)
        app.buttons["add_source_continue"].tap()
        XCTAssertTrue(app.buttons["settings_source_Second"].waitForExistence(timeout: 5))
        let active = app.buttons["settings_source_Demo TV"]
        XCTAssertTrue(active.label.contains("Active"), "the current source keeps the Active badge: \(active.label)")
        XCTAssertFalse(app.buttons["settings_source_Second"].label.contains("Active"))
        XCTAssertTrue(app.buttons["sources_move"].exists, "reorder with two sources (IOS-23)")
        UITestSupport.snap("a1-ios-sources-active", in: self)
    }

    @MainActor
    func testAdvancedLegalLinksTimeZoneAndNoAccount() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        let advanced = app.buttons["settings_advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 30))
        advanced.tap()
        let zone = app.buttons["settings_epg_timezone"]
        XCTAssertTrue(zone.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sign in with e-mail"].exists, "accounts hidden (ACCOUNTS_ENABLED = NO)")
        zone.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "searchable list (U4)")
        search.tap()
        search.typeText("Istanbul")
        let istanbul = app.buttons["timezone_Europe/Istanbul"]
        XCTAssertTrue(istanbul.waitForExistence(timeout: 5))
        UITestSupport.snap("a1-ios-timezones", in: self)
        istanbul.tap()
        XCTAssertTrue(zone.waitForExistence(timeout: 5))
        XCTAssertTrue(zone.label.contains("Europe/Istanbul"), zone.label)
        let privacy = app.buttons["legal_privacy"]
        scrollTo(privacy, in: app, max: 8)
        XCTAssertTrue(privacy.isHittable, "privacy policy is a tappable link (S1)")
        XCTAssertTrue(app.buttons["legal_terms"].exists)
        let reset = app.buttons["settings_reset_sync"]
        scrollTo(reset, in: app)
        reset.tap()
        XCTAssertTrue(app.staticTexts["settings_reset_sync_done"].waitForExistence(timeout: 2), "confirmation on its own line (IOS-17)")
        XCTAssertEqual(app.staticTexts["settings_reset_sync_done"].label, "All audio delays set to 0", "not truncated")
        UITestSupport.snap("a1-ios-advanced-legal", in: self)
    }

    @MainActor
    func testPaywallHasLegalLinksAndNoAccountHint() throws {
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        let advanced = app.buttons["settings_advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 30))
        advanced.tap()
        let purchase = app.buttons["settings_purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        purchase.tap()
        XCTAssertTrue(app.buttons["purchase_restore"].waitForExistence(timeout: 10))
        let terms = app.buttons["paywall_terms"], privacy = app.buttons["paywall_privacy"]
        for _ in 0..<4 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(terms.exists && privacy.exists, "terms + privacy links next to Buy")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sign in to your account'")).firstMatch.exists,
                       "no account hint while accounts are disabled")
        UITestSupport.snap("a1-ios-paywall-legal", in: self)
    }
}
