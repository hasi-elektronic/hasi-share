import XCTest

/// Task 7c (user report: "Serien: not all categories, e.g. the Turkish ones, are missing").
/// `series-cats.m3u` (next to the seed playlist on the local media server) has 14 series categories; the
/// Turkish ones ("TR | DİZİLER", "Türk Dizileri") come last. The Series tab used to show rows for the first
/// 12 categories only – every category must be reachable from the category chips.
final class IOSSeriesCategoriesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Scrolls the chip row until the chip whose label contains `text` is hittable.
    @MainActor
    private func chip(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_chip_'"))
        let target = chips.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let y = chips.element(boundBy: 0).frame.midY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<10 where !(target.exists && target.isHittable) {
            origin.withOffset(CGVector(dx: 320, dy: y)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 60, dy: y)))
        }
        return target
    }

    @MainActor
    func testEverySeriesCategoryIsReachable() throws {
        try UITestSupport.requireServed(UITestSupport.seriesCategoriesM3U)
        let app = UITestSupport.launch(["-seedM3U", UITestSupport.seriesCategoriesM3U, "-seedName", "Series"], seed: false)
        IOSFlowTests.openSection("series", in: app)
        let anyChip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'category_chip_'")).firstMatch
        XCTAssertTrue(anyChip.waitForExistence(timeout: 20), "Series tab offers a chip for every category")
        UITestSupport.snap("series-categories-01", in: self)

        let turkish = chip("Türk Dizileri", in: app)
        XCTAssertTrue(turkish.isHittable, "13th/14th category (Turkish) reachable")
        UITestSupport.snap("series-categories-02-turkish-chip", in: self)
        turkish.tap()
        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'grid_' AND label CONTAINS 'Yalı Çapkını'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10), "category grid lists the Turkish series")
        UITestSupport.snap("series-categories-03-grid", in: self)
    }
}
