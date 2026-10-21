import XCTest
@testable import IPTVKit

/// Build 31 (owner report: German series episodes always started in English): container language codes.
final class LanguageMatchTests: XCTestCase {
    func testBibliographicCodesNormalize() {
        XCTAssertEqual(TrackNaming.normalized("ger"), "de")
        XCTAssertEqual(TrackNaming.normalized("deu"), "de")
        XCTAssertEqual(TrackNaming.normalized("fre"), "fr")
        XCTAssertEqual(TrackNaming.normalized("tur"), "tr")
        XCTAssertEqual(TrackNaming.normalized("en-US"), "en")
        XCTAssertTrue(TrackNaming.matches("ger", preferred: "de"))
        XCTAssertTrue(TrackNaming.matches("tur", preferred: "tr"))
        XCTAssertFalse(TrackNaming.matches("eng", preferred: "de"))
    }

    func testVariantsCoverEverySpelling() {
        XCTAssertEqual(Set(TrackNaming.languageVariants("de")), ["de", "deu", "ger"])
        XCTAssertEqual(Set(TrackNaming.languageVariants("ger")), ["de", "deu", "ger"])
        XCTAssertEqual(Set(TrackNaming.languageVariants("tr")), ["tr", "tur"])
        XCTAssertEqual(TrackNaming.languageVariants(nil), [])
    }
}
