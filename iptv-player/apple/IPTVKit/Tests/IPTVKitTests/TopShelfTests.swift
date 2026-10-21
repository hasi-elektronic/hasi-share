import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 17 (C6 / tvOS F-01): Top Shelf snapshot (JSON limits, no secrets), deep links and their resolution.
@MainActor
final class TopShelfTests: XCTestCase {
    // MARK: Deep links

    func testDeepLinkRoundTrip() throws {
        let links: [DeepLink] = [
            .channel(sourceId: "src-1", channelId: "u0123abcd"),
            .movie(sourceId: "src 2", movieId: "5001"),
            .episode(sourceId: "s/3", seriesId: "a&b", episodeId: "70002+1"),
        ]
        for link in links {
            XCTAssertEqual(link.url.scheme, "novaplayer")
            XCTAssertEqual(DeepLink(url: link.url), link, link.url.absoluteString)
            XCTAssertFalse(link.identifier.hasPrefix("novaplayer"))
        }
        XCTAssertEqual(DeepLink.channel(sourceId: "s", channelId: "c").url.absoluteString, "novaplayer://play/channel?source=s&id=c")
    }

    func testInvalidDeepLinks() {
        for raw in ["novaplayer://play/channel?source=s", "novaplayer://play/channel?id=c", "novaplayer://play/unknown?source=s&id=c",
                    "novaplayer://open/channel?source=s&id=c", "https://play/channel?source=s&id=c",
                    "novaplayer://play/episode?source=s&id=e", "novaplayer://play/movie?source=&id=m"] {
            XCTAssertNil(DeepLink(url: URL(string: raw)!), raw)
        }
        XCTAssertEqual(DeepLink(url: URL(string: "NovaPlayer://PLAY/Movie?source=s&id=m")!), .movie(sourceId: "s", movieId: "m"))
    }

    // MARK: Snapshot encoding

    private func item(_ n: Int, title: String = "Item", image: String? = "http://img.example.com/p.jpg") -> TopShelfSnapshot.Item {
        let link = DeepLink.movie(sourceId: "s", movieId: "\(n)")
        return TopShelfSnapshot.Item(id: link.identifier, title: "\(title) \(n)", imageURL: image, shape: .poster, progress: 0.4,
                                     link: link.url.absoluteString)
    }

    func testEncodingLimitsItemsAndRoundTrips() throws {
        let snapshot = TopShelfSnapshot(sections: [
            TopShelfSnapshot.Section(title: "Weiterschauen", items: (0..<25).map { item($0) }),
            TopShelfSnapshot.Section(title: "Leer", items: []),
        ])
        let data = snapshot.encoded()
        let decoded = try XCTUnwrap(TopShelfSnapshot.decode(data))
        XCTAssertEqual(decoded.sections.count, 1, "empty sections dropped")
        XCTAssertEqual(decoded.sections[0].items.count, TopShelfSnapshot.maxItemsPerSection)
        XCTAssertEqual(decoded.sections[0].items.first, item(0))
        XCTAssertLessThan(data.count, 8 * 1024, "compact")
    }

    func testEncodingStaysUnder64KB() throws {
        let huge = String(repeating: "x", count: 30_000)
        let sections = (0..<4).map { s in
            TopShelfSnapshot.Section(title: "S\(s)", items: (0..<10).map { item($0, title: huge, image: "http://img.example.com/" + String(repeating: "y", count: 900)) })
        }
        let data = TopShelfSnapshot(sections: sections).encoded()
        XCTAssertLessThanOrEqual(data.count, TopShelfSnapshot.maxBytes)
        let decoded = try XCTUnwrap(TopShelfSnapshot.decode(data))
        XCTAssertTrue(decoded.sections.allSatisfy { $0.items.allSatisfy { $0.title.count <= 120 } }, "titles cut")
        XCTAssertEqual(decoded.sections.flatMap(\.items).count, 40, "cut titles fit without dropping items")

        // Thousands of sections (never produced by the app): items are dropped until it fits.
        let many = (0..<400).map { TopShelfSnapshot.Section(title: "S\($0)", items: (0..<10).map { item($0) }) }
        let bounded = TopShelfSnapshot(sections: many).encoded()
        XCTAssertLessThanOrEqual(bounded.count, TopShelfSnapshot.maxBytes)
        XCTAssertNotNil(TopShelfSnapshot.decode(bounded))
    }

    func testNoSecretsInImageURLs() {
        XCTAssertEqual(TopShelfSnapshot.safeImageURL("http://logo.example.com/a.png"), "http://logo.example.com/a.png")
        XCTAssertEqual(TopShelfSnapshot.safeImageURL("https://image.tmdb.org/t/p/w300/x.jpg?v=2"), "https://image.tmdb.org/t/p/w300/x.jpg?v=2")
        XCTAssertNil(TopShelfSnapshot.safeImageURL("http://user:pass@panel.example.com/logo.png"))
        XCTAssertNil(TopShelfSnapshot.safeImageURL("http://panel.example.com/img.php?username=u&password=p"))
        XCTAssertNil(TopShelfSnapshot.safeImageURL("http://cdn.example.com/a.png?token=abc"))
        XCTAssertNil(TopShelfSnapshot.safeImageURL("file:///etc/passwd"))
        XCTAssertNil(TopShelfSnapshot.safeImageURL("data:image/png;base64,AAAA"))
        XCTAssertNil(TopShelfSnapshot.safeImageURL("http://cdn.example.com/" + String(repeating: "a", count: 2000)))
        let encoded = TopShelfSnapshot(sections: [TopShelfSnapshot.Section(title: "T", items: [item(1, image: "http://u:p@h.example.com/x.png")])]).encoded()
        XCTAssertNil(TopShelfSnapshot.decode(encoded)?.sections.first?.items.first?.imageURL, "dropped when encoding")
    }

    func testVersionMismatchIsIgnored() throws {
        var snapshot = TopShelfSnapshot(sections: [TopShelfSnapshot.Section(title: "T", items: [item(1)])])
        snapshot.version = 99
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertNil(TopShelfSnapshot.decode(data))
        XCTAssertNil(TopShelfSnapshot.decode(Data("garbage".utf8)))
    }

    // MARK: Builder + resolution

    private static let m3u = """
    #EXTM3U
    #EXTINF:-1 tvg-id="a" tvg-logo="http://logo.example.com/a.png" group-title="News",Atlas News HD
    http://stream.example.com/live/u/p/1.m3u8
    #EXTINF:-1 tvg-id="b" tvg-logo="http://logo.example.com/b.png" group-title="News",Rhein 24
    http://stream.example.com/live/u/p/2.m3u8
    #EXTINF:-1 tvg-id="c" group-title="Kids",Kids Planet
    http://stream.example.com/live/u/p/3.m3u8
    #EXTINF:-1 tvg-logo="http://img.example.com/red.jpg" group-title="Action",Red Horizon (2024) HD
    http://stream.example.com/movie/u/p/10.mp4
    #EXTINF:-1 tvg-logo="http://img.example.com/lights.jpg" group-title="Crime",Harbor Lights S01E02 Low Tide
    http://stream.example.com/series/u/p/22.mp4
    """

    private func makeEnv() async throws -> AppEnvironment {
        let body = Data(Self.m3u.utf8)
        let transport = FakeTransport { _ in HTTPResponse(statusCode: 200, body: body) }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .tvos, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        _ = try await env.addSource(name: "Demo", secrets: .m3u(M3USecrets(url: "http://lists.example.com/u/p/list.m3u"))) { _ in }
        return env
    }

    func testSnapshotFromLibraryAndDeepLinksResolve() async throws {
        let env = try await makeEnv()
        let sid = try XCTUnwrap(env.currentSource?.id)
        XCTAssertTrue(env.topShelfSnapshot(TopShelfLabels(continueTitle: "C", recentTitle: "R")).isEmpty, "nothing watched yet")

        let channels = try env.catalog.channels(sourceId: sid, limit: 10)
        XCTAssertEqual(channels.count, 3)
        let movie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 5).first)
        let series = try XCTUnwrap(env.catalog.series(sourceId: sid, limit: 5).first)
        let episode = try XCTUnwrap(env.catalog.episodes(sourceId: sid, seriesId: series.id).first)
        var now: Int64 = 1_000
        func watch(_ item: PlaybackRequest.Item, position: Int64, duration: Int64) throws {
            let request = env.request(for: item)
            now += 1_000
            var seriesKey: String?
            if case .episode(let e, _) = item { seriesKey = env.contentKey(sourceId: sid, kind: .series, itemId: e.seriesId) }
            try env.library.saveProgress(contentKey: XCTUnwrap(request.contentKey), title: request.title, kind: request.contentKind,
                                         positionMs: position, durationMs: duration, posterUrl: request.posterUrl, seriesKey: seriesKey, nowMs: now)
        }
        try watch(.channel(channels[2]), position: 0, duration: 0)   // Kids Planet (hidden below)
        try watch(.channel(channels[0]), position: 0, duration: 0)   // Atlas
        try watch(.movie(movie), position: 1_800_000, duration: 5_400_000)
        try watch(.episode(episode, seriesTitle: series.name), position: 600_000, duration: 2_400_000)
        try watch(.channel(channels[1]), position: 0, duration: 0)   // Rhein – watched last

        let labels = TopShelfLabels(continueTitle: "Weiterschauen", recentTitle: "Zuletzt gesehen",
                                    movieTitle: { $0.replacingOccurrences(of: " (2024) HD", with: "") },
                                    isHidden: { $0.name == "Kids Planet" })
        let snapshot = env.topShelfSnapshot(labels)
        XCTAssertEqual(snapshot.sections.map(\.title), ["Weiterschauen", "Zuletzt gesehen"])
        let cont = snapshot.sections[0].items
        XCTAssertEqual(cont.map(\.title), ["Harbor Lights · S1 E2", "Red Horizon"], "newest first, app titles")
        XCTAssertEqual(cont[0].progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(cont[1].progress ?? 0, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(cont[1].imageURL, "http://img.example.com/red.jpg")
        XCTAssertTrue(cont.allSatisfy { $0.shape == .poster })
        let recent = snapshot.sections[1].items
        XCTAssertEqual(recent.map(\.title), ["Rhein 24", "Atlas News HD"], "newest first, hidden channel left out")
        XCTAssertEqual(recent[0].shape, .square)
        XCTAssertEqual(recent[0].imageURL, "http://logo.example.com/b.png")

        // No secrets: the stream URLs (with credentials) never reach the snapshot.
        let json = String(decoding: snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("stream.example.com"), json)
        XCTAssertFalse(json.contains("/u/p/"), json)

        // Every link plays the item it shows.
        guard case .channel(let c)? = DeepLink(url: URL(string: recent[0].link)!).flatMap(env.playbackTarget(for:))?.item else {
            return XCTFail("channel link")
        }
        XCTAssertEqual(c.name, "Rhein 24")
        let channelTarget = try XCTUnwrap(DeepLink(url: URL(string: recent[0].link)!).flatMap(env.playbackTarget(for:)))
        XCTAssertTrue(channelTarget.channels.contains { $0.id == c.id }, "zapping list = its category")
        guard case .movie(let m)? = DeepLink(url: URL(string: cont[1].link)!).flatMap(env.playbackTarget(for:))?.item else {
            return XCTFail("movie link")
        }
        XCTAssertEqual(m.id, movie.id)
        guard case .episode(let e, let title)? = DeepLink(url: URL(string: cont[0].link)!).flatMap(env.playbackTarget(for:))?.item else {
            return XCTFail("episode link")
        }
        XCTAssertEqual(e.id, episode.id)
        XCTAssertEqual(title, series.name)
        let resumed = env.request(for: .movie(m))
        XCTAssertEqual(resumed.startPositionMs, 1_800_000, "a deep-linked movie resumes")
    }

    // MARK: Parental lock (Build 18 × Top Shelf)

    private func categoryId(_ env: AppEnvironment, _ sid: String, _ kind: CategoryKind, _ name: String) throws -> String {
        try XCTUnwrap(env.catalog.allCategories(sourceId: sid, kind: kind).first { $0.name == name }?.id, name)
    }

    /// Watches the channels, the movie and the episode of the demo list (Rhein last).
    private func watchEverything(_ env: AppEnvironment, _ sid: String) throws {
        let channels = try env.catalog.channels(sourceId: sid, limit: 10)
        let movie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 5).first)
        let series = try XCTUnwrap(env.catalog.series(sourceId: sid, limit: 5).first)
        let episode = try XCTUnwrap(env.catalog.episodes(sourceId: sid, seriesId: series.id).first)
        var now: Int64 = 1_000
        for (item, position, duration) in [(PlaybackRequest.Item.channel(channels[2]), Int64(0), Int64(0)), (.channel(channels[0]), 0, 0),
                                           (.movie(movie), 1_800_000, 5_400_000),
                                           (.episode(episode, seriesTitle: series.name), 600_000, 2_400_000), (.channel(channels[1]), 0, 0)] {
            let request = env.request(for: item)
            now += 1_000
            var seriesKey: String?
            if case .episode(let e, _) = item { seriesKey = env.contentKey(sourceId: sid, kind: .series, itemId: e.seriesId) }
            try env.library.saveProgress(contentKey: XCTUnwrap(request.contentKey), title: request.title, kind: request.contentKind,
                                         positionMs: position, durationMs: duration, posterUrl: request.posterUrl, seriesKey: seriesKey, nowMs: now)
        }
    }

    private func titles(_ snapshot: TopShelfSnapshot) -> [String] { snapshot.sections.flatMap(\.items).map(\.title) }

    /// Locked titles / posters / logos never reach the home screen – also while the app's PIN session is unlocked
    /// (the active catalog filter is off then) and in show-with-lock mode; the snapshot follows lock changes (the
    /// publisher only writes a changed snapshot).
    func testTopShelfLeavesOutLockedItemsWhateverTheSession() async throws {
        let env = try await makeEnv()
        let sid = try XCTUnwrap(env.currentSource?.id)
        try watchEverything(env, sid)
        let labels = TopShelfLabels(continueTitle: "C", recentTitle: "R")
        XCTAssertEqual(titles(env.topShelfSnapshot(labels)), ["Harbor Lights · S1 E2", "Red Horizon (2024) HD", "Rhein 24", "Atlas News HD", "Kids Planet"])

        XCTAssertTrue(env.parental.setPin("1234"))
        XCTAssertTrue(env.parental.isUnlocked, "the one who set the PIN goes on unlocked")
        env.parental.hideLocked = false   // show with a lock: the app lists locked items, the shelf still must not
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .movie, "Action"), kind: .movie, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .series, "Crime"), kind: .series, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .live, "Kids"), kind: .live, sourceId: sid)
        let rhein = try XCTUnwrap(env.catalog.channels(sourceId: sid, limit: 10).first { $0.name == "Rhein 24" })
        env.parental.setChannelLocked(true, channelId: rhein.id, sourceId: sid)
        XCTAssertNil(env.parental.filter, "session unlocked: no active catalog filter")
        XCTAssertNotNil(try env.catalog.movie(sourceId: sid, id: try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 5).first).id),
                        "the app shows everything in an unlocked session")

        let unlocked = env.topShelfSnapshot(labels)
        XCTAssertEqual(titles(unlocked), ["Atlas News HD"], "locked movie, series, category channel and channel left out")
        let json = String(decoding: unlocked.encoded(), as: UTF8.self)
        for leak in ["Red Horizon", "red.jpg", "Harbor Lights", "lights.jpg", "Rhein", "b.png", "Kids Planet"] {
            XCTAssertFalse(json.contains(leak), "\(leak) in \(json)")
        }
        env.parental.relock()
        XCTAssertEqual(titles(env.topShelfSnapshot(labels)), ["Atlas News HD"], "locked session: the same")
        env.parental.hideLocked = true
        XCTAssertEqual(titles(env.topShelfSnapshot(labels)), ["Atlas News HD"], "hide mode: the same")

        // Unlocking items changes the snapshot (→ republished).
        env.parental.setChannelLocked(false, channelId: rhein.id, sourceId: sid)
        XCTAssertEqual(titles(env.topShelfSnapshot(labels)), ["Rhein 24", "Atlas News HD"])
        // Without a PIN nothing is locked anywhere (the lists stay for a new PIN).
        XCTAssertEqual(env.parental.unlock("1234"), .ok)
        XCTAssertEqual(env.parental.removePin("1234"), .ok)
        XCTAssertNil(env.topShelfLockFilter)
        XCTAssertEqual(titles(env.topShelfSnapshot(labels)).count, 5)
    }

    /// A Top Shelf / reminder link into locked content resolves (it is neither opened silently nor ignored) and
    /// playing it needs the PIN (`Router.open` → `Router.play` → PIN prompt); after the PIN it plays.
    func testDeepLinkIntoLockedContentNeedsThePin() async throws {
        let env = try await makeEnv()
        let sid = try XCTUnwrap(env.currentSource?.id)
        let movie = try XCTUnwrap(env.catalog.movies(sourceId: sid, limit: 5).first)
        let series = try XCTUnwrap(env.catalog.series(sourceId: sid, limit: 5).first)
        let episode = try XCTUnwrap(env.catalog.episodes(sourceId: sid, seriesId: series.id).first)
        let channels = try env.catalog.channels(sourceId: sid, limit: 10)
        let kids = try XCTUnwrap(channels.first { $0.name == "Kids Planet" })
        let rhein = try XCTUnwrap(channels.first { $0.name == "Rhein 24" })
        let atlas = try XCTUnwrap(channels.first { $0.name == "Atlas News HD" })
        XCTAssertTrue(env.parental.setPin("1234"))
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .movie, "Action"), kind: .movie, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .series, "Crime"), kind: .series, sourceId: sid)
        env.parental.setCategoryLocked(true, categoryId: try categoryId(env, sid, .live, "Kids"), kind: .live, sourceId: sid)
        env.parental.setChannelLocked(true, channelId: rhein.id, sourceId: sid)
        env.parental.relock()

        for hideLocked in [true, false] {
            env.parental.hideLocked = hideLocked
            let links: [DeepLink] = [.movie(sourceId: sid, movieId: movie.id), .episode(sourceId: sid, seriesId: series.id, episodeId: episode.id),
                                     .channel(sourceId: sid, channelId: kids.id), .channel(sourceId: sid, channelId: rhein.id)]
            for link in links {
                let target = try XCTUnwrap(env.playbackTarget(for: link), "\(link) resolves (hide \(hideLocked))")
                XCTAssertTrue(env.needsPinToPlay(target.item), "\(link) asks for the PIN (hide \(hideLocked))")
            }
            let open = try XCTUnwrap(env.playbackTarget(for: .channel(sourceId: sid, channelId: atlas.id)))
            XCTAssertFalse(env.needsPinToPlay(open.item), "an unlocked channel plays at once")
        }
        guard case .episode(_, let title)? = env.playbackTarget(for: .episode(sourceId: sid, seriesId: series.id, episodeId: episode.id))?.item else {
            return XCTFail("episode")
        }
        XCTAssertEqual(title, series.name, "series title found whatever the lock")
        XCTAssertEqual(env.parental.unlock("1234"), .ok)
        let target = try XCTUnwrap(env.playbackTarget(for: .movie(sourceId: sid, movieId: movie.id)))
        XCTAssertFalse(env.needsPinToPlay(target.item), "after the PIN it plays")
    }

    func testDeepLinkToGoneItemsOrSources() async throws {
        let env = try await makeEnv()
        let sid = try XCTUnwrap(env.currentSource?.id)
        XCTAssertNil(env.playbackTarget(for: .channel(sourceId: "other", channelId: "x")), "unknown source")
        XCTAssertNil(env.playbackTarget(for: .channel(sourceId: sid, channelId: "missing")))
        XCTAssertNil(env.playbackTarget(for: .movie(sourceId: sid, movieId: "missing")))
        XCTAssertNil(env.playbackTarget(for: .episode(sourceId: sid, seriesId: "s", episodeId: "missing")), "no row, no progress")

        // An episode known only from its (synced) progress entry is rebuilt from it.
        let fingerprint = try XCTUnwrap(env.fingerprint(sourceId: sid))
        try env.library.merge([SyncItem.progress(contentKey: ContentKey.make(fingerprint: fingerprint, kind: .episode, itemId: "e9"),
                                                 title: "Mountain Patrol · S2E5 Avalanche", contentKind: .episode, positionMs: 60_000,
                                                 durationMs: 600_000, posterUrl: nil,
                                                 seriesKey: ContentKey.make(fingerprint: fingerprint, kind: .series, itemId: "mp"), updatedAt: 9)])
        guard case .episode(let e, let title)? = env.playbackTarget(for: .episode(sourceId: sid, seriesId: "mp", episodeId: "e9"))?.item else {
            return XCTFail("episode from progress")
        }
        XCTAssertEqual(e.season, 2)
        XCTAssertEqual(e.number, 5)
        XCTAssertEqual(e.title, "Avalanche")
        XCTAssertEqual(title, "Mountain Patrol")
    }
}
