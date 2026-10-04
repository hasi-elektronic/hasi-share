import Foundation
import XCTest
@testable import IPTVCore

/// Reconnect policy (ARCHITECTURE §3), EPG now/next, sync LWW + watch history (CONTRACT §8).
final class PolicyTests: XCTestCase {
    // MARK: Reconnect

    func testReconnectDelaysAndGiveUp() {
        let p = ReconnectPolicy()
        var s = ReconnectState()
        var decisions: [ReconnectDecision] = []
        for t in 0..<6 {
            let r = p.error(s, nowMs: Int64(t) * 100)
            s = r.state
            decisions.append(r.decision)
        }
        XCTAssertEqual(decisions, [
            .retry(attempt: 1, maxAttempts: 5, delayMs: 1_000), .retry(attempt: 2, maxAttempts: 5, delayMs: 2_000),
            .retry(attempt: 3, maxAttempts: 5, delayMs: 4_000), .retry(attempt: 4, maxAttempts: 5, delayMs: 8_000),
            .retry(attempt: 5, maxAttempts: 5, delayMs: 15_000), .giveUp(attempts: 5),
        ])
    }

    func testReconnectResetsAfterStablePlayback() {
        let p = ReconnectPolicy()
        var s = p.error(ReconnectState(), nowMs: 0).state
        s = p.error(s, nowMs: 1_000).state
        XCTAssertEqual(s.attempts, 2)
        // Short playback does not reset the streak.
        s = p.playing(s, nowMs: 5_000)
        XCTAssertEqual(p.playing(s, nowMs: 6_000).playingSinceMs, 5_000, "first ready time is kept")
        var r = p.error(s, nowMs: 10_000)
        XCTAssertEqual(r.decision, .retry(attempt: 3, maxAttempts: 5, delayMs: 4_000))
        // ≥ 30 s stable → the next error starts a new streak.
        s = p.playing(r.state, nowMs: 20_000)
        r = p.error(s, nowMs: 50_000)
        XCTAssertEqual(r.decision, .retry(attempt: 1, maxAttempts: 5, delayMs: 1_000))
        // tick() resets proactively.
        s = p.playing(r.state, nowMs: 60_000)
        XCTAssertEqual(p.tick(s, nowMs: 89_999).attempts, 1)
        XCTAssertEqual(p.tick(s, nowMs: 90_000).attempts, 0)
    }

    // MARK: EPG now/next

    private func program(_ start: Int, _ end: Int, _ title: String) -> EpgProgram {
        EpgProgram(sourceId: "s", channelEpgId: "c", start: Date(timeIntervalSince1970: TimeInterval(start)),
                   end: Date(timeIntervalSince1970: TimeInterval(end)), title: title)
    }

    func testNowAndNext() {
        let list = [program(0, 100, "A"), program(100, 200, "B"), program(300, 400, "C")]
        func at(_ t: Int) -> (String?, String?) {
            let r = EpgSchedule.nowAndNext(list, at: Date(timeIntervalSince1970: TimeInterval(t)))
            return (r.now?.title, r.next?.title)
        }
        XCTAssertTrue(at(-5) == (nil, "A"))
        XCTAssertTrue(at(0) == ("A", "B"))
        XCTAssertTrue(at(99) == ("A", "B"))
        XCTAssertTrue(at(100) == ("B", "C"))
        XCTAssertTrue(at(250) == (nil, "C"), "gap")
        XCTAssertTrue(at(399) == ("C", nil))
        XCTAssertTrue(at(400) == (nil, nil))
        XCTAssertTrue(EpgSchedule.nowAndNext([], at: Date()) == (nil, nil))
        XCTAssertEqual(EpgSchedule.progress(of: list[0], at: Date(timeIntervalSince1970: 25)), 0.25)
        XCTAssertEqual(EpgSchedule.progress(of: list[0], at: Date(timeIntervalSince1970: 500)), 1)
        XCTAssertEqual(EpgSchedule.programs(list, overlapping: DateInterval(start: Date(timeIntervalSince1970: 150),
                                                                           end: Date(timeIntervalSince1970: 310))).map(\.title),
                       ["B", "C"])
    }

    func testCatchupAvailability() {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        let past = program(9 * 86_400, 9 * 86_400 + 3600, "Yesterday")
        let old = program(2 * 86_400, 2 * 86_400 + 3600, "Old")
        let running = program(10 * 86_400 - 60, 10 * 86_400 + 60, "Live")
        let catchup = CatchupInfo(type: .xtream, days: 3)
        XCTAssertTrue(EpgSchedule.isCatchupAvailable(past, catchup: catchup, now: now))
        XCTAssertFalse(EpgSchedule.isCatchupAvailable(old, catchup: catchup, now: now))
        XCTAssertFalse(EpgSchedule.isCatchupAvailable(running, catchup: catchup, now: now))
        XCTAssertFalse(EpgSchedule.isCatchupAvailable(past, catchup: .none, now: now))
    }

    func testEpgTimeFormatterUsesGivenZone() {
        let f = EpgTimeFormatter(timeZone: TimeZone(identifier: "Europe/Istanbul")!, locale: Locale(identifier: "tr_TR"), use24Hour: true)
        let start = Date(timeIntervalSince1970: 1_759_591_800)   // 15:30Z
        XCTAssertEqual(f.time(start), "18:30")
        XCTAssertEqual(f.range(start: start, end: start.addingTimeInterval(5400)), "18:30 – 20:00")
    }

    // MARK: Sync

    func testLastWriterWinsAndTiesKeepStored() {
        let a = SyncItem.favorite(contentKey: "fp:live:1", title: "A", contentKind: .live, posterUrl: nil, updatedAt: 10)
        var newer = a
        newer.updatedAt = 11
        newer.deleted = true
        var tie = a
        tie.data.title = "tie"
        let older = SyncItem.favorite(contentKey: "fp:live:1", title: "old", contentKind: .live, posterUrl: nil, updatedAt: 9)
        let (merged, applied) = SyncMerge.merge(local: [a.key: a], incoming: [tie, older, newer])
        XCTAssertEqual(applied, [newer])
        XCTAssertEqual(merged[a.key], newer)
        XCTAssertEqual(SyncMerge.pending([newer, a, older], changedAfter: 9).map(\.updatedAt), [10, 11])
        XCTAssertEqual(a.contentKey, "fp:live:1")
    }

    func testWatchHistory() {
        func prog(_ key: String, _ pos: Int64, _ dur: Int64, _ at: Int64, kind: ContentKind = .movie) -> SyncItem {
            SyncItem.progress(contentKey: key, title: key, contentKind: kind, positionMs: pos, durationMs: dur, updatedAt: at)
        }
        let items = [prog("a", 1, 100, 1), prog("b", 50, 100, 5), prog("c", 96, 100, 3), prog("d", 6, 100, 4),
                     prog("live", 999, 0, 6, kind: .live)]
        XCTAssertEqual(WatchHistory.continueWatching(items).map(\.contentKey), ["b", "d"])
        XCTAssertEqual(WatchHistory.recentlyWatched(items).map(\.contentKey), ["live", "b", "d", "c", "a"])
        XCTAssertEqual(items.last?.data.positionMs, 0, "live progress is stored as 0")
        XCTAssertTrue(WatchHistory.isCompleted(positionMs: 95, durationMs: 100))
        XCTAssertFalse(WatchHistory.isCompleted(positionMs: 94, durationMs: 100))
    }

    // MARK: Error presentation

    /// Every key used by the error presentations exists in spec/strings.json (single source).
    func testErrorPresentationKeysExistInStrings() throws {
        let stringsURL = Vectors.dir.deletingLastPathComponent().appendingPathComponent("strings.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stringsURL)) as? [String: Any])
        let keys = Set(try XCTUnwrap(root["strings"] as? [String: Any]).keys)
        let sourceErrors: [SourceError] = [.network(.offline), .network(.timeout), .network(.dns), .network(.refused), .network(.tls),
                                           .network(.other), .invalidCredentials, .accountExpired(expiresAt: nil),
                                           .accountExpired(expiresAt: Date()), .accountDisabled, .notFound,
                                           .serverError(httpStatus: 500), .invalidFormat, .invalidResponse, .empty, .cancelled]
        let playbackErrors: [PlaybackError] = [.network(.timeout), .accessDenied(httpStatus: 403), .streamOffline(httpStatus: 404),
                                               .serverError(httpStatus: 500), .unsupportedFormat(container: "mpegts"),
                                               .unsupportedCodec(codec: nil), .drm, .unknown(message: "x")]
        let presentations = sourceErrors.map { $0.presentation() } + playbackErrors.map(\.presentation)
        for p in presentations {
            for key in [p.titleKey, p.bodyKey] + [p.hintKey].compactMap({ $0 }) {
                XCTAssertTrue(keys.contains(key), "missing string key \(key)")
            }
        }
        XCTAssertEqual(PlaybackError.unsupportedFormat(container: "mpegts").presentation.bodyArgs, ["MPEG-TS"])
    }
}
