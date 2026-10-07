import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Build 9 category navigation (docs/SCREENS.md §3.2): country detection, category infos, country-filtered
/// rows, per source + kind preferences, and the one-time refresh after a catalog format change.
final class CategoryCountryTests: XCTestCase {
    func testCountryCodeFromProviderNames() {
        XCTAssertEqual(CategoryCountry.code(for: "TR • NETFLIX DIZILER"), "TR")
        XCTAssertEqual(CategoryCountry.code(for: "DE | Serien"), "DE")
        XCTAssertEqual(CategoryCountry.code(for: "TR | DİZİLER"), "TR")
        XCTAssertEqual(CategoryCountry.code(for: "[TR] Ulusal"), "TR")
        XCTAssertEqual(CategoryCountry.code(for: "Sport (UK)"), "GB", "alias without prefix")
        XCTAssertEqual(CategoryCountry.code(for: "UK | Sport"), "GB", "alias as prefix")
        XCTAssertEqual(CategoryCountry.code(for: "USA: Movies"), "US", "3-letter alias prefix")
        XCTAssertEqual(CategoryCountry.code(for: "TÜRKİYE"), "TR", "alias")
        XCTAssertEqual(CategoryCountry.code(for: "Germany Sport"), "DE", "country name")
        XCTAssertEqual(CategoryCountry.code(for: "Almanya Filmleri"), "DE", "Turkish alias")
        XCTAssertNil(CategoryCountry.code(for: "Türk Dizileri"))
        XCTAssertNil(CategoryCountry.code(for: "LATAM | Series"), "multi-country group")
    }

    /// Owner ruling (Build 9): a leading code with a separator is the group, language codes included.
    func testLeadingCodeWithSeparatorIsTheGroupLanguagesIncluded() {
        XCTAssertEqual(CategoryCountry.code(for: "IT | Serie TV"), "IT", "separator beats the ignored-token list")
        XCTAssertEqual(CategoryCountry.code(for: "EN • Drama"), "EN")
        XCTAssertEqual(CategoryCountry.code(for: "EN | Netflix Series"), "EN")
        XCTAssertEqual(CategoryCountry.code(for: "[EN] Drama"), "EN", "bracket form")
        XCTAssertEqual(CategoryCountry.code(for: "AR | مسلسلات"), "AR")
        XCTAssertEqual(CategoryCountry.code(for: "FR: Séries"), "FR")
        XCTAssertEqual(CategoryCountry.code(for: "NL - Series"), "NL")
        XCTAssertEqual(CategoryCountry.code(for: "ES] Series"), "ES")
        XCTAssertNil(CategoryCountry.code(for: "4K | Movies"), "a digit is no code")
        XCTAssertNil(CategoryCountry.code(for: "4K MOVIES"))
        XCTAssertNil(CategoryCountry.code(for: "NETFLIX | Series"), "longer than 3 letters")
        XCTAssertNil(CategoryCountry.code(for: "En | Drama"), "upper case only")
        XCTAssertNil(CategoryCountry.code(for: "Kids Movies"), "no separator, no country")
    }

    /// Review: tags, channels and packages are no groups; "-" separates only with a space after it.
    func testTagPrefixesAreNoGroups() {
        for tag in ["FHD | Movies", "UHD|Movies", "VIP | Sport", "PPV | Events", "UFC | Fight Night", "XXX | Adult",
                    "HD | Kanäle", "TV | Sport", "NEW | Releases", "BBC | News", "TOP: 100", "HBO • Series"] {
            XCTAssertNil(CategoryCountry.code(for: tag), tag)
        }
        XCTAssertEqual(CategoryCountry.code(for: "NL - Series"), "NL")
        XCTAssertNil(CategoryCountry.code(for: "Sci-Fi"), "hyphenated word")
        XCTAssertNil(CategoryCountry.code(for: "X-Men Series"))
        XCTAssertEqual(CategoryCountry.code(for: "BTK | Mix"), "BTK", "unknown 3-letter prefix stays a group")
        XCTAssertEqual(CategoryCountry.code(for: "ENG | Movies"), "ENG")
    }

    func testOneSeparatorSetForStrippingAndSearch() {
        XCTAssertEqual(CategoryCountry.strippedTitle("NL - Series"), "Series", "flag replaces the prefix")
        XCTAssertEqual(CategoryCountry.strippedTitle("ES] Series"), "Series")
        XCTAssertEqual(CategoryCountry.nameWithoutPrefix("[EN] | Drama"), "Drama")
        XCTAssertTrue(CategoryCountry.matches("NL - Series", query: "series"))
        XCTAssertFalse(CategoryCountry.matches("NL - Series", query: "nl"), "prefix not searchable")
        XCTAssertTrue(CategoryCountry.matches("Sci-Fi", query: "sci-fi"), "word kept whole")
        XCTAssertEqual(CategoryCountry.nameWithoutPrefix("Sci-Fi"), "Sci-Fi")
    }

    func testMeaningFlagAndDisplayName() {
        let en = Locale(identifier: "en"), tr = Locale(identifier: "tr"), de = Locale(identifier: "de")
        XCTAssertEqual(CategoryCountry.meaning(of: "TR"), .region)
        XCTAssertEqual(CategoryCountry.meaning(of: "EN"), .language)
        XCTAssertEqual(CategoryCountry.meaning(of: "AR"), .language, "AR means Arabic, not Argentina")
        XCTAssertEqual(CategoryCountry.meaning(of: "IT"), .region)
        XCTAssertEqual(CategoryCountry.meaning(of: "HD"), .tag)
        XCTAssertEqual(CategoryCountry.flagEmoji(forCode: "TR"), "🇹🇷")
        XCTAssertEqual(CategoryCountry.flagEmoji(forCode: "GB"), "🇬🇧")
        XCTAssertNil(CategoryCountry.flagEmoji(forCode: "EN"), "no flag for a language")
        XCTAssertNil(CategoryCountry.flagEmoji(forCode: "AR"), "no Argentina flag")
        XCTAssertNil(CategoryCountry.flagEmoji(forCode: "TV"), "no Tuvalu flag for a tag")
        XCTAssertEqual(CategoryCountry.displayName(of: "EN", locale: en), "English")
        XCTAssertEqual(CategoryCountry.displayName(of: "EN", locale: tr), "İngilizce")
        XCTAssertEqual(CategoryCountry.displayName(of: "AR", locale: de), "Arabisch")
        XCTAssertEqual(CategoryCountry.displayName(of: "AR", locale: tr), "Arapça")
        XCTAssertEqual(CategoryCountry.displayName(of: "DE", locale: de), "Deutschland")
        XCTAssertEqual(CategoryCountry.displayName(of: "IT", locale: de), "Italien")
        XCTAssertEqual(CategoryCountry.displayName(of: "TR", locale: tr), "Türkiye")
        XCTAssertEqual(CategoryCountry.displayName(of: "XYZ", locale: en), "XYZ", "unknown code stays raw")
        XCTAssertEqual(CategoryCountry.displayName(of: "ENG", locale: en), "English", "whitelisted 3-letter code")
        XCTAssertEqual(CategoryCountry.displayName(of: "TUR", locale: de), "Türkisch")
        XCTAssertEqual(CategoryCountry.displayName(of: "BTK", locale: en), "BTK", "no obscure ISO 639 lookup (Batak Toba)")
        XCTAssertEqual(CategoryCountry.displayName(of: "NEW", locale: en), "NEW", "tag, not Newari")
        XCTAssertNil(CategoryCountry.flagEmoji(forCode: "ENG"))
    }

    func testFlagAndStrippedTitle() {
        XCTAssertEqual(CategoryCountry.emoji(for: "DE | Serien"), "🇩🇪")
        XCTAssertEqual(CategoryCountry.emoji(for: "IT | Serie TV"), "🇮🇹")
        XCTAssertNil(CategoryCountry.emoji(for: "EN | Netflix Series"))
        XCTAssertNil(CategoryCountry.emoji(for: "AR | مسلسلات"))
        XCTAssertNil(CategoryCountry.emoji(for: "4K MOVIES"))
        XCTAssertEqual(CategoryCountry.strippedTitle("DE | Sport"), "Sport")
        XCTAssertEqual(CategoryCountry.strippedTitle("TR • NETFLIX DIZILER"), "NETFLIX DIZILER")
        XCTAssertEqual(CategoryCountry.strippedTitle("[TR] Ulusal"), "Ulusal")
        XCTAssertEqual(CategoryCountry.strippedTitle("EN | Netflix Series"), "EN | Netflix Series", "no flag → code kept")
        XCTAssertEqual(CategoryCountry.nameWithoutPrefix("EN | Netflix Series"), "Netflix Series")
        XCTAssertEqual(CategoryCountry.strippedTitle("Germany Sport"), "Germany Sport")
    }

    func testSearchIgnoresCaseDiacriticsAndCountryPrefix() {
        XCTAssertTrue(CategoryCountry.matches("TR | DİZİLER", query: "diziler"))
        XCTAssertTrue(CategoryCountry.matches("Türk Dizileri", query: "TURK"))
        XCTAssertTrue(CategoryCountry.matches("FR | Séries", query: "series"))
        XCTAssertTrue(CategoryCountry.matches("TR • NETFLIX DIZILER", query: "netflix diz"))
        XCTAssertFalse(CategoryCountry.matches("TR | DİZİLER", query: "tr"), "the country prefix is not searchable")
        XCTAssertTrue(CategoryCountry.matches("Anything", query: "  "), "empty query matches all")
    }
}

final class CategoryInfoTests: XCTestCase {
    var catalog: CatalogRepository!

    override func setUpWithError() throws {
        catalog = CatalogRepository(database: try AppDatabase.inMemory())
        let cats: [(String, String)] = [("a", "EN | Netflix Series"), ("b", "DE | Serien"), ("c", "TR | DİZİLER"),
                                        ("d", "Türk Dizileri"), ("e", "TR • Yerli"), ("empty", "TR | Leer")]
        let session = try catalog.beginRefresh(sourceId: "s")
        try session.write(categories: cats.enumerated().map { IPTVCore.Category(sourceId: "s", id: $1.0, kind: .series, name: $1.1, sort: $0) }
                          + [IPTVCore.Category(sourceId: "s", id: "a", kind: .movie, name: "TR | Filme", sort: 0)])
        // s1 in TR c + d + e (one series in several categories), s2 only DE, s3 only EN, s4 TR c.
        try session.write(series: [
            Series(sourceId: "s", id: "s1", name: "Yalı Çapkını", rating: 8.1, sort: 0, categoryIds: ["c", "d", "e"]),
            Series(sourceId: "s", id: "s2", name: "Tatort", rating: 9.0, sort: 1, categoryIds: ["b"]),
            Series(sourceId: "s", id: "s3", name: "Stranger Things", rating: 9.5, sort: 2, categoryIds: ["a"]),
            Series(sourceId: "s", id: "s4", name: "Kuruluş Osman", rating: 7.0, sort: 3, categoryIds: ["c"]),
        ], episodes: [])
        try session.write(movies: [Movie(sourceId: "s", id: "m1", name: "Film", sort: 0, categoryIds: ["a"])])
        try session.commit()
    }

    func testInfosHaveCountsCountriesAndProviderOrderWithoutEmptyCategories() throws {
        let infos = try catalog.categoryInfos(sourceId: "s", kind: .series)
        XCTAssertEqual(infos.map(\.id), ["a", "b", "c", "d", "e"], "provider order, empty category left out")
        XCTAssertEqual(infos.map(\.itemCount), [1, 1, 2, 1, 1])
        XCTAssertEqual(infos.map(\.countryCode), ["EN", "DE", "TR", nil, "TR"])
        // Same id in another kind does not leak (Xtream VOD/series ids collide).
        let movieInfos = try catalog.categoryInfos(sourceId: "s", kind: .movie)
        XCTAssertEqual(movieInfos.map(\.id), ["a"])
        XCTAssertEqual(movieInfos.first?.countryCode, "TR")
        XCTAssertEqual(movieInfos.first?.itemCount, 1)
    }

    func testCountryFilteredItemsAreDistinctAndSorted() throws {
        let tr = try catalog.categoryInfos(sourceId: "s", kind: .series).filter { $0.countryCode == "TR" }.map(\.id)
        XCTAssertEqual(try catalog.series(sourceId: "s", categoryIds: tr, sort: .added, limit: 20).map(\.id), ["s4", "s1"],
                       "newest first, s1 once although it is in two TR categories")
        XCTAssertEqual(try catalog.series(sourceId: "s", categoryIds: tr, sort: .rating, limit: 10).map(\.id), ["s1", "s4"])
        XCTAssertEqual(try catalog.series(sourceId: "s", categoryIds: tr, sort: .added, limit: 1).map(\.id), ["s4"])
        XCTAssertEqual(try catalog.series(sourceId: "s", categoryIds: [], sort: .added, limit: 20), [])
        XCTAssertEqual(try catalog.movies(sourceId: "s", categoryIds: ["a"], sort: .added, limit: 20).map(\.id), ["m1"])
        XCTAssertEqual(try catalog.movies(sourceId: "s", categoryIds: ["b"], sort: .added, limit: 20), [], "series category id ≠ movie membership")
    }
}

@MainActor
final class CategoryPreferencesTests: XCTestCase {
    func testDefaultCountryFollowsLanguageWhenAvailable() {
        let available: Set<String> = ["TR", "DE"]
        XCTAssertEqual(CategoryPreferences.resolveCountry(stored: nil, available: available, languageCode: "tr"), "TR")
        XCTAssertEqual(CategoryPreferences.resolveCountry(stored: nil, available: available, languageCode: "de"), "DE")
        XCTAssertNil(CategoryPreferences.resolveCountry(stored: nil, available: available, languageCode: "en"), "en without EN groups → All")
        XCTAssertEqual(CategoryPreferences.resolveCountry(stored: nil, available: ["EN", "TR"], languageCode: "en"), "EN")
        XCTAssertNil(CategoryPreferences.resolveCountry(stored: nil, available: available, languageCode: "fr"), "other languages → All")
        XCTAssertNil(CategoryPreferences.resolveCountry(stored: nil, available: ["DE"], languageCode: "tr"), "no TR categories → All")
        XCTAssertNil(CategoryPreferences.resolveCountry(stored: "all", available: available, languageCode: "tr"), "explicit All wins")
        XCTAssertEqual(CategoryPreferences.resolveCountry(stored: "DE", available: available, languageCode: "tr"), "DE")
        XCTAssertNil(CategoryPreferences.resolveCountry(stored: "FR", available: available, languageCode: "tr"), "stored country gone → All")
    }

    func testCountryPinnedRecentHiddenPerSourceAndKindAndPersisted() {
        let kv = InMemoryKeyValueStore()
        let prefs = CategoryPreferences(kv: kv)
        prefs.setCountry("TR", sourceId: "s", kind: .series)
        prefs.setCountry(nil, sourceId: "s", kind: .movie)
        XCTAssertEqual(prefs.storedCountry(sourceId: "s", kind: .series), "TR")
        XCTAssertEqual(prefs.storedCountry(sourceId: "s", kind: .movie), CategoryPreferences.allCountries)
        XCTAssertNil(prefs.storedCountry(sourceId: "other", kind: .series))

        prefs.togglePin("x", sourceId: "s", kind: .series)
        prefs.togglePin("y", sourceId: "s", kind: .series)
        XCTAssertEqual(prefs.pinned(sourceId: "s", kind: .series), ["x", "y"], "pin order kept")
        XCTAssertEqual(prefs.pinned(sourceId: "s", kind: .movie), [], "same id, other kind: separate")
        prefs.togglePin("x", sourceId: "s", kind: .series)
        XCTAssertEqual(prefs.pinned(sourceId: "s", kind: .series), ["y"])

        for id in ["1", "2", "3", "4", "5", "6", "3"] { prefs.recordOpened(id, sourceId: "s", kind: .series) }
        XCTAssertEqual(prefs.recent(sourceId: "s", kind: .series), ["3", "6", "5", "4", "2"], "last 5, newest first, no duplicates")

        prefs.setHidden(true, categoryId: "y", sourceId: "s", kind: .series)
        XCTAssertTrue(prefs.isHidden("y", sourceId: "s", kind: .series))
        XCTAssertFalse(prefs.isHidden("y", sourceId: "s", kind: .movie), "hidden per kind (Xtream id collisions)")
        XCTAssertEqual(prefs.pinned(sourceId: "s", kind: .series), [], "hiding unpins")

        let reloaded = CategoryPreferences(kv: kv)
        XCTAssertEqual(reloaded.storedCountry(sourceId: "s", kind: .series), "TR")
        XCTAssertEqual(reloaded.recent(sourceId: "s", kind: .series), ["3", "6", "5", "4", "2"])
        XCTAssertEqual(reloaded.hidden(sourceId: "s", kind: .series), ["y"])
        reloaded.setHidden(false, categoryId: "y", sourceId: "s", kind: .series)
        XCTAssertEqual(reloaded.hidden(sourceId: "s", kind: .series), [])

        reloaded.removeAll(sourceId: "s")
        XCTAssertNil(CategoryPreferences(kv: kv).storedCountry(sourceId: "s", kind: .series))
    }

    func testVersionBumpsOnlyOnChange() {
        let prefs = CategoryPreferences(kv: InMemoryKeyValueStore())
        let v0 = prefs.version
        prefs.setCountry("DE", sourceId: "s", kind: .movie)
        XCTAssertEqual(prefs.version, v0 + 1)
        prefs.setCountry("DE", sourceId: "s", kind: .movie)
        XCTAssertEqual(prefs.version, v0 + 1, "no-op does not notify")
    }
}

/// Root cause of the Build 8 report: a catalog stored by Build 6 lacked `category_ids` memberships until
/// the next manual refresh. Catalogs built with an older `CatalogFormat` get one background refresh.
@MainActor
final class CatalogFormatRefreshTests: XCTestCase {
    final class Panel: @unchecked Sendable {
        let lock = NSLock()
        var failing = false
        var requests = 0
    }

    private func makeEnvironment(_ panel: Panel) async throws -> AppEnvironment {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let transport = FakeTransport { _ in
            panel.lock.lock(); defer { panel.lock.unlock() }
            panel.requests += 1
            return panel.failing ? HTTPResponse(statusCode: 500) : HTTPResponse(statusCode: 200, body: m3u)
        }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        _ = try await env.addSource(name: "Test", secrets: .m3u(M3USecrets(url: "http://lists.example.com/list.m3u"))) { _ in }
        return env
    }

    private func requests(_ panel: Panel) -> Int {
        panel.lock.lock(); defer { panel.lock.unlock() }
        return panel.requests
    }

    /// Two old catalogs, one panel down: the reachable source stores the current format, the failing one
    /// keeps its old (missing) version and is retried on the next launch.
    func testFailingSourceKeepsOldVersionOtherSourceUpgrades() async throws {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let down = Panel()
        let transport = FakeTransport { request in
            down.lock.lock(); defer { down.lock.unlock() }
            if down.failing, request.url.host == "down.example.com" { return HTTPResponse(statusCode: 500) }
            return HTTPResponse(statusCode: 200, body: m3u)
        }
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test")
        let env = try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), transport: transport)
        let up = try await env.addSource(name: "Up", secrets: .m3u(M3USecrets(url: "http://up.example.com/list.m3u"))) { _ in }
        let failing = try await env.addSource(name: "Down", secrets: .m3u(M3USecrets(url: "http://down.example.com/list.m3u"))) { _ in }
        env.database.setValue(nil, forKey: CatalogFormat.key(up.id))
        env.database.setValue("1", forKey: CatalogFormat.key(failing.id))
        down.lock.withLock { down.failing = true }

        await env.refreshDueSources()
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: up.id), CatalogFormat.current, "reachable source upgraded")
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: failing.id), 1, "failing source keeps its old version")
        XCTAssertTrue(env.refresher.needsFormatRefresh(sourceId: failing.id))
        XCTAssertFalse(env.refresher.needsFormatRefresh(sourceId: up.id))

        down.lock.withLock { down.failing = false }
        await env.refreshDueSources()   // next launch
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: failing.id), CatalogFormat.current)
    }

    func testOldCatalogIsRefreshedOnceAndFailureRetriesNextLaunch() async throws {
        let panel = Panel()
        let env = try await makeEnvironment(panel)
        let id = try XCTUnwrap(env.currentSource?.id)
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: id), CatalogFormat.current, "a successful load stores the format")
        XCTAssertFalse(env.refresher.needsFormatRefresh(sourceId: id))

        // Launch with a fresh, current catalog: nothing to do (auto refresh not due either).
        var before = requests(panel)
        await env.refreshDueSources()
        XCTAssertEqual(requests(panel), before, "no refresh without a format change")

        // A catalog stored by an older build (no format recorded): one refresh on launch.
        env.database.setValue(nil, forKey: CatalogFormat.key(id))
        XCTAssertTrue(env.refresher.needsFormatRefresh(sourceId: id))
        // Failure: the format stays old, so the next launch retries.
        panel.lock.withLock { panel.failing = true }
        before = requests(panel)
        await env.refreshDueSources()
        XCTAssertGreaterThan(requests(panel), before, "refresh attempted")
        XCTAssertNil(env.refresher.catalogFormat(sourceId: id))
        XCTAssertTrue(env.refresher.needsFormatRefresh(sourceId: id))
        XCTAssertFalse(env.currentSource?.isRefreshDue(now: Date()) ?? true, "only the format triggers the retry")

        panel.lock.withLock { panel.failing = false }
        before = requests(panel)
        await env.refreshDueSources()
        XCTAssertGreaterThan(requests(panel), before, "retried on the next launch")
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: id), CatalogFormat.current)

        before = requests(panel)
        await env.refreshDueSources()
        XCTAssertEqual(requests(panel), before, "exactly one successful refresh per format change")

        // An older stored version counts as old too.
        env.database.setValue("1", forKey: CatalogFormat.key(id))
        XCTAssertTrue(env.refresher.needsFormatRefresh(sourceId: id))
        // Auto refresh disabled does not stop the format refresh.
        var source = try XCTUnwrap(env.currentSource)
        source.autoRefreshHours = 0
        env.updateSource(source)
        before = requests(panel)
        await env.refreshDueSources()
        XCTAssertGreaterThan(requests(panel), before)
        XCTAssertEqual(env.refresher.catalogFormat(sourceId: id), CatalogFormat.current)

        env.deleteSource(id: id)
        XCTAssertNil(env.refresher.catalogFormat(sourceId: id), "format forgotten with the source")
    }
}
