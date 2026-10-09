import XCTest
@testable import IPTVKit

/// Build 20: the remux engine's audio menu (all source tracks; duplicates told apart).
final class SourceAudioTracksTests: XCTestCase {
    private let en = Locale(identifier: "en")

    func testLanguageNamesAndIds() {
        let tracks = [SourceAudioTrack(streamIndex: 1, language: "tur", codec: "ac3", channels: 6, title: nil),
                      SourceAudioTrack(streamIndex: 2, language: "ger", codec: "aac", channels: 2, title: nil)]
        let options = SourceAudioTracks.options(tracks, locale: en)
        XCTAssertEqual(options.map(\.id), [0, 1])
        XCTAssertEqual(options.map(\.name), ["Turkish", "German"])
        XCTAssertEqual(options.map(\.languageCode), ["tur", "ger"])
    }

    func testSameLanguageGetsTitleOrFormat() {
        let tracks = [SourceAudioTrack(streamIndex: 1, language: "eng", codec: "eac3", channels: 6, title: "Commentary"),
                      SourceAudioTrack(streamIndex: 2, language: "eng", codec: "ac3", channels: 6, title: nil),
                      SourceAudioTrack(streamIndex: 3, language: "eng", codec: "aac", channels: 2, title: "")]
        XCTAssertEqual(SourceAudioTracks.options(tracks, locale: en).map(\.name),
                       ["English · Commentary", "English · AC3 5.1", "English · AAC 2.0"])
    }

    func testUnknownLanguageFallsBackToTitleThenNil() {
        let tracks = [SourceAudioTrack(streamIndex: 1, language: nil, codec: "dts", channels: 6, title: "Director"),
                      SourceAudioTrack(streamIndex: 2, language: "", codec: "dts", channels: 0, title: nil)]
        XCTAssertEqual(SourceAudioTracks.options(tracks, locale: en).map(\.name), ["Director", nil])
    }

    func testIndexOfStream() {
        let tracks = [SourceAudioTrack(streamIndex: 1, language: "tur", codec: "ac3", channels: 6, title: nil),
                      SourceAudioTrack(streamIndex: 4, language: "eng", codec: "aac", channels: 2, title: nil)]
        XCTAssertEqual(SourceAudioTracks.index(of: 4, in: tracks), 1)
        XCTAssertNil(SourceAudioTracks.index(of: 9, in: tracks))
    }
}
