import XCTest

/// Build 18 team E: multi-day TV guide (day picker + "Jetzt"), programme detail with a reminder, parental PIN that
/// locks a category (show-with-lock mode: the chip asks for the PIN, 5 wrong → cooldown is unit-tested).
final class IOSGuideParentalTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openGuide() throws -> XCUIApplication {
        try UITestSupport.requireServed(UITestSupport.seedM3U)
        let app = UITestSupport.launch(["-uiScreen", "guide"])
        XCTAssertTrue(app.buttons["guide_day_0"].waitForExistence(timeout: 30), "day picker")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'epg_now_'")).firstMatch.waitForExistence(timeout: 20),
                      "today: a block on air")
        return app
    }

    /// Answers the iOS notification permission alert (first reminder) if it shows.
    @MainActor
    private func allowNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Erlauben", "İzin Ver"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func enterPin(_ pin: String, in app: XCUIApplication) {
        for digit in pin {
            let key = app.buttons["pin_key_\(digit)"]
            XCTAssertTrue(key.waitForExistence(timeout: 5), "key \(digit)")
            key.tap()
        }
    }

    @MainActor
    func testDayPickerAndJumpToNow() throws {
        let app = try openGuide()
        let title = app.staticTexts["guide_day_title"]
        XCTAssertEqual(title.label, "Today")
        XCTAssertTrue(app.buttons["guide_day_-1"].exists, "Yesterday offered")
        XCTAssertTrue(app.buttons["guide_day_6"].exists || app.buttons["guide_day_5"].exists, "a week ahead")
        UITestSupport.snap("e-ios-guide-01-today", in: self)

        let start = Date()
        app.buttons["guide_day_1"].tap()
        XCTAssertTrue(app.staticTexts["Tomorrow"].waitForExistence(timeout: 3), "day title follows the picker")
        print("UI day switch: \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms (incl. XCUITest round trip)")
        XCTAssertTrue(app.buttons["guide_day_1"].isSelected)
        let onAir = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'epg_now_'"))
        XCTAssertTrue(onAir.firstMatch.waitForNonExistence(timeout: 3), "nothing is on air tomorrow")
        XCTAssertTrue(app.buttons.matching(identifier: "epg_block").firstMatch.waitForExistence(timeout: 5), "tomorrow's programmes")
        UITestSupport.snap("e-ios-guide-02-tomorrow", in: self)

        app.buttons["guide_jump_now"].tap()
        XCTAssertTrue(app.staticTexts["guide_day_title"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["guide_day_title"].label, "Today")
        XCTAssertTrue(app.buttons["guide_day_0"].isSelected)
        XCTAssertTrue(onAir.firstMatch.waitForExistence(timeout: 5), "back at the programme on air")
        XCTAssertTrue(onAir.firstMatch.isHittable, "scrolled to now")
        UITestSupport.snap("e-ios-guide-03-jetzt", in: self)
    }

    @MainActor
    func testReminderFromProgrammeDetail() throws {
        let app = try openGuide()
        // Today, right of the programme on air: future programmes (the demo EPG may not reach tomorrow noon).
        let blocks = app.buttons.matching(identifier: "epg_block")
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        // A visible block of the first row (a programme from the evening before can hang over the window start).
        let width = app.windows.firstMatch.frame.width
        let block = try XCTUnwrap(blocks.allElementsBoundByIndex.first { $0.frame.minX > 300 && $0.frame.minX < width - 40 }, "a later block")
        let programme = block.label
        block.tap()
        XCTAssertTrue(app.descendants(matching: .any)["program_detail"].waitForExistence(timeout: 5), "detail sheet")
        XCTAssertTrue(app.buttons["program_watch_live"].exists, "Watch live")
        let remind = app.buttons["program_remind"]
        XCTAssertTrue(remind.exists, "Remind me on a future programme")
        UITestSupport.snap("e-ios-guide-04-detail", in: self)
        remind.tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.descendants(matching: .any)["program_reminder_set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["program_remind_remove"].exists)
        UITestSupport.snap("e-ios-guide-05-reminder-set", in: self)
        app.buttons["program_detail_close"].tap()

        // Settings → Reminders lists it.
        app.buttons["open_settings"].tap()
        let row = app.buttons["settings_reminders"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let reminder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'reminder_row_'")).firstMatch
        XCTAssertTrue(reminder.waitForExistence(timeout: 5), "reminder listed (\(programme))")
        UITestSupport.snap("e-ios-guide-06-reminders", in: self)
        reminder.swipeLeft()
        let delete = app.buttons["reminder_delete"].exists ? app.buttons["reminder_delete"] : app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reminders_empty"].waitForExistence(timeout: 3), "deleted")
    }

    @MainActor
    func testPinLocksACategory() throws {
        let app = try openGuide()
        let kids = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide_filter_' AND label CONTAINS 'Kids'")).firstMatch
        XCTAssertTrue(kids.exists, "Kids category chip")

        // Settings → Parental control → set PIN 1234 (twice).
        app.buttons["open_settings"].tap()
        let parental = app.buttons["settings_parental"]
        XCTAssertTrue(parental.waitForExistence(timeout: 5))
        parental.tap()
        let setPin = app.buttons["parental_set_pin"]
        XCTAssertTrue(setPin.waitForExistence(timeout: 5))
        setPin.tap()
        sleep(2)
        UITestSupport.snap("e-ios-parental-00-setpin", in: self)
        enterPin("1234", in: app)
        enterPin("1235", in: app)
        XCTAssertTrue(app.staticTexts["The PINs do not match. Please try again."].waitForExistence(timeout: 3), "mismatch")
        enterPin("1234", in: app)
        enterPin("1234", in: app)
        let hide = app.switches["parental_hide_locked"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "PIN set → options")
        XCTAssertNil(app.descendants(matching: .any)["parental_suggestions"].firstMatchIfExists, "no adult categories in the demo")
        // Show-with-lock mode, then lock "Kids".
        hide.switches.firstMatch.exists ? hide.switches.firstMatch.tap() : hide.tap()
        XCTAssertEqual(hide.value as? String, "0", "show locked content with a lock")
        app.buttons["parental_categories_live"].tap()
        let kidsToggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'parental_lock_category_' AND label CONTAINS 'Kids'")).firstMatch
        XCTAssertTrue(kidsToggle.waitForExistence(timeout: 5))
        kidsToggle.switches.firstMatch.exists ? kidsToggle.switches.firstMatch.tap() : kidsToggle.tap()
        XCTAssertEqual(kidsToggle.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let lockNow = app.buttons["parental_lock_now"]
        XCTAssertTrue(lockNow.waitForExistence(timeout: 5))
        UITestSupport.snap("e-ios-parental-01-settings", in: self)
        lockNow.tap()
        // Settings is now behind the PIN (the parental page shows the pad).
        XCTAssertTrue(app.descendants(matching: .any)["pin_gate"].waitForExistence(timeout: 5), "relocked: the page asks for the PIN")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings_close"].waitForExistence(timeout: 5))
        app.buttons["settings_close"].tap()

        // The guide shows the Kids chip with a lock; choosing it asks for the PIN.
        XCTAssertTrue(kids.waitForExistence(timeout: 5))
        let width = app.windows.firstMatch.frame.width
        for _ in 0..<5 where kids.frame.maxX > width - 8 { app.buttons["guide_filter_1"].swipeLeft() }
        kids.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pin_pad"].waitForExistence(timeout: 5), "PIN requested for the locked category")
        UITestSupport.snap("e-ios-parental-02-pin", in: self)
        enterPin("0000", in: app)
        XCTAssertTrue(app.staticTexts["Wrong PIN – 4 attempts left"].waitForExistence(timeout: 3))
        XCTAssertFalse(kids.isSelected, "still locked")
        enterPin("1234", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["pin_pad"].waitForNonExistence(timeout: 5), "pad closes")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !kids.isSelected { usleep(200_000) }
        XCTAssertTrue(kids.isSelected, "category opened after the right PIN")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channel_'")).firstMatch.waitForExistence(timeout: 5),
                      "its channels are listed")
        UITestSupport.snap("e-ios-parental-03-unlocked", in: self)
    }
}

private extension XCUIElement {
    var firstMatchIfExists: XCUIElement? { exists ? self : nil }
}
