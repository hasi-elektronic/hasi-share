import XCTest

/// Build 18 team E on Apple TV (Siri Remote): guide day picker + "Jetzt", reminder from the programme detail, PIN
/// pad with one focusable per key and a locked category that asks for the PIN.
final class TVGuideParentalTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private var remote: XCUIRemote { XCUIRemote.shared }

    @MainActor
    private func focused(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    /// Moves the focus to `target` with the arrows, steering by the frames (max `limit` presses).
    @MainActor
    @discardableResult
    private func focusByFrame(_ target: XCUIElement, in app: XCUIApplication, limit: Int = 16) -> Bool {
        for _ in 0..<limit {
            guard target.exists else { return false }
            if target.hasFocus { return true }
            let current = focused(app)
            guard current.exists else { remote.press(.down); usleep(500_000); continue }
            let dx = target.frame.midX - current.frame.midX
            let dy = target.frame.midY - current.frame.midY
            if abs(dy) > max(30, current.frame.height / 2) {
                remote.press(dy > 0 ? .down : .up)
            } else {
                remote.press(dx > 0 ? .right : .left)
            }
            usleep(450_000)
        }
        return target.hasFocus
    }

    @MainActor
    private func select(_ target: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target)", file: file, line: line)
        XCTAssertTrue(focusByFrame(target, in: app), "focus \(target.identifier) (focused: \(focused(app).identifier))", file: file, line: line)
        remote.press(.select)
        usleep(700_000)
    }

    @MainActor
    private func enterPin(_ pin: String, in app: XCUIApplication) {
        for digit in pin { select(app.buttons["pin_key_\(digit)"], in: app) }
    }

    @MainActor
    private func openGuide() throws -> XCUIApplication {
        try UITestSupport.requireServed(UITestSupport.seedM3U)
        let app = UITestSupport.launch(["-uiScreen", "guide"])
        XCTAssertTrue(app.buttons["guide_day_0"].waitForExistence(timeout: 30), "day picker")
        sleep(2)
        return app
    }

    @MainActor
    func testDayPickerAndJumpToNow() throws {
        let app = try openGuide()
        let title = app.staticTexts["guide_day_title"]
        XCTAssertEqual(title.label, "Today")
        select(app.buttons["guide_day_1"], in: app)
        XCTAssertTrue(app.staticTexts["Tomorrow"].waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Tomorrow")
        UITestSupport.snap("e-tvos-guide-01-tomorrow", in: self)
        select(app.buttons["guide_jump_now"], in: app)
        XCTAssertEqual(title.label, "Today")
        // ▼ into the list: the airing programme of the first row (Build 16 B-08 kept).
        let block = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'epg_'")).firstMatch
        for _ in 0..<3 where !block.exists { remote.press(.down); usleep(700_000) }
        XCTAssertTrue(block.exists, "a programme block has the focus")
        XCTAssertTrue(block.identifier.hasPrefix("epg_now_"), "the block on air, got \(block.identifier)")
        UITestSupport.snap("e-tvos-guide-02-now", in: self)
    }

    @MainActor
    func testReminderFromProgrammeDetail() throws {
        let app = try openGuide()
        let block = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'epg_'")).firstMatch
        for _ in 0..<4 where !(block.exists && block.identifier.hasPrefix("epg_now_")) { remote.press(.down); usleep(700_000) }
        XCTAssertTrue(block.identifier.hasPrefix("epg_now_"))
        remote.press(.right)   // the next programme (future)
        usleep(800_000)
        XCTAssertEqual(block.identifier, "epg_block")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["program_detail"].waitForExistence(timeout: 5), "detail opens on OK")
        UITestSupport.snap("e-tvos-guide-03-detail", in: self)
        select(app.buttons["program_remind"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["program_reminder_set"].waitForExistence(timeout: 5))
        UITestSupport.snap("e-tvos-guide-04-reminder-set", in: self)
        remote.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["program_detail"].waitForNonExistence(timeout: 5))
    }

    /// Form rows: the focus sits on the cell, found by its label.
    @MainActor
    private func moveFocus(_ app: XCUIApplication, to label: String, pressing direction: XCUIRemote.Button = .down, limit: Int = 15) -> Bool {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", label)).firstMatch
        for _ in 0..<limit where !row.exists {
            remote.press(direction)
            usleep(450_000)
        }
        // Not found that way: the other direction (where the focus lands after a sheet varies).
        for _ in 0..<(limit * 2) where !row.exists {
            remote.press(direction == .down ? .up : .down)
            usleep(450_000)
        }
        return row.exists
    }

    @MainActor
    private func openRow(_ app: XCUIApplication, _ label: String, pressing direction: XCUIRemote.Button = .down,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(moveFocus(app, to: label, pressing: direction), "row \(label)", file: file, line: line)
        remote.press(.select)
        usleep(900_000)
    }

    @MainActor
    func testPinLocksACategory() throws {
        try UITestSupport.requireServed(UITestSupport.seedM3U)
        let app = UITestSupport.launch(["-uiScreen", "settings"])
        XCTAssertTrue(app.buttons["settings_parental"].waitForExistence(timeout: 30))
        sleep(1)
        // Settings → Parental control → set PIN 1234 with the remote pad (one focusable per key).
        openRow(app, "Parental control")
        openRow(app, "Set PIN")
        XCTAssertTrue(app.buttons["pin_key_5"].waitForExistence(timeout: 5), "pad")
        UITestSupport.snap("e-tvos-parental-01-pad", in: self)
        enterPin("1234", in: app)
        enterPin("1234", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["parental_hide_locked"].waitForExistence(timeout: 5), "PIN set")
        sleep(1)
        openRow(app, "Hide locked content")   // show locked content with a lock
        openRow(app, "Live TV")
        openRow(app, "Kids")
        remote.press(.menu)
        usleep(900_000)
        openRow(app, "Lock now", pressing: .up)
        XCTAssertTrue(app.descendants(matching: .any)["pin_gate"].waitForExistence(timeout: 5), "relocked")
        UITestSupport.snap("e-tvos-parental-02-relocked", in: self)

        // TV Guide: the Kids chip asks for the PIN.
        remote.press(.menu)
        usleep(900_000)
        for _ in 0..<6 where !app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
            remote.press(.up); usleep(500_000)
        }
        XCTAssertTrue(focusByFrame(app.tabBars.buttons["TV Guide"], in: app), "guide tab")
        remote.press(.down)
        usleep(900_000)
        let kids = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide_filter_' AND label CONTAINS 'Kids'")).firstMatch
        select(kids, in: app)
        XCTAssertTrue(app.buttons["pin_key_1"].waitForExistence(timeout: 5), "PIN requested")
        UITestSupport.snap("e-tvos-parental-03-pin", in: self)
        enterPin("1234", in: app)
        XCTAssertTrue(app.buttons["pin_key_1"].waitForNonExistence(timeout: 5), "pad closes")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !kids.isSelected { usleep(200_000) }
        XCTAssertTrue(kids.isSelected, "category opened after the PIN")
        UITestSupport.snap("e-tvos-parental-04-open", in: self)
    }
}
