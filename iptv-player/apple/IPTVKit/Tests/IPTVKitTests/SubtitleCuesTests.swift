import XCTest
@testable import IPTVKit

/// Build 21: remux text subtitles (cue store + menu).
final class SubtitleCuesTests: XCTestCase {
    func testLookupAndOverlap() {
        let store = SubtitleCueStore()
        store.add(stream: 3, cue: SubtitleCue(start: 10, end: 12, text: "B"))
        store.add(stream: 3, cue: SubtitleCue(start: 1, end: 3, text: "A"))
        store.add(stream: 3, cue: SubtitleCue(start: 11, end: 14, text: "C"))
        XCTAssertEqual(store.texts(stream: 3, at: 0.5), [])
        XCTAssertEqual(store.texts(stream: 3, at: 1), ["A"])
        XCTAssertEqual(store.texts(stream: 3, at: 3), [], "end is exclusive")
        XCTAssertEqual(store.texts(stream: 3, at: 11.5), ["B", "C"])
        XCTAssertEqual(store.texts(stream: 3, at: 13), ["C"])
        XCTAssertEqual(store.texts(stream: 4, at: 11), [], "other track")
    }

    func testDuplicatesFromRegeneratedSegmentsAreIgnored() {
        let store = SubtitleCueStore()
        for _ in 0..<3 { store.add(stream: 2, cue: SubtitleCue(start: 5.0004, end: 6, text: "Hi")) }
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.texts(stream: 2, at: 5.5), ["Hi"])
    }

    func testMenuAndInitialSelection() {
        let en = Locale(identifier: "en")
        let tracks = [SourceSubtitleTrack(streamIndex: 4, language: "tur", title: "Forced", isDefault: false, isForced: true),
                      SourceSubtitleTrack(streamIndex: 5, language: "tur", title: "Full", isDefault: true, isForced: false),
                      SourceSubtitleTrack(streamIndex: 6, language: "eng", title: nil, isDefault: false, isForced: false)]
        XCTAssertEqual(SourceSubtitleTracks.options(tracks, locale: en).map(\.name), ["Turkish · Forced", "Turkish · Full", "English"])
        XCTAssertEqual(SourceSubtitleTracks.initialSelection(tracks, preferred: "tr"), 1, "full track before the forced one")
        XCTAssertEqual(SourceSubtitleTracks.initialSelection(tracks, preferred: "en"), 2)
        XCTAssertNil(SourceSubtitleTracks.initialSelection(tracks, preferred: nil), "no preference → off")
        XCTAssertNil(SourceSubtitleTracks.initialSelection(tracks, preferred: "de"))
    }
}
