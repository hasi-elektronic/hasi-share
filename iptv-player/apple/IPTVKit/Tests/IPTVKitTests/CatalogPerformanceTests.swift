import XCTest
@testable import IPTVKit
import IPTVCore

/// Spec budgets at 50 000 channels (list page / FTS search ≤ 100 ms, now/next page ≤ 20 ms).
/// Budgets are for release builds; debug builds get 2× (unoptimised SQLite wrapper + Swift).
final class CatalogPerformanceTests: XCTestCase {
    static let n = 50_000
    static let words = ["Sport", "News", "Kids", "Film"]

    #if DEBUG
    let factor = 2.0
    #else
    let factor = 1.0
    #endif

    func makeCatalog() throws -> (AppDatabase, CatalogRepository) {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "s")
        let cats = (0..<50).map { IPTVCore.Category(sourceId: "s", id: "k\($0)", kind: .live, name: "Kategorie \($0)", sort: $0) }
        try session.write(categories: cats, channels: (0..<Self.n).map {
            TestData.channel(id: "c\($0)", sourceId: "s", name: "Kanal \($0) \(Self.words[$0 % 4]) HD",
                             categoryId: "k\($0 % 50)", epgId: "e\($0)", sort: $0)
        })
        try session.commit()
        return (db, repo)
    }

    /// Median wall-clock milliseconds of 5 runs (after one warm-up run).
    func median(_ block: () throws -> Void) rethrows -> Double {
        try block()
        var t: [Double] = []
        for _ in 0..<5 {
            let s = DispatchTime.now()
            try block()
            t.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6)
        }
        return t.sorted()[2]
    }

    private func report(_ name: String, _ ms: Double, budget: Double) {
        print("PERF \(name): median \(String(format: "%.2f", ms)) ms (budget \(budget) ms, factor \(factor))")
    }

    func testListPageUnderBudget() throws {
        let (_, repo) = try makeCatalog()
        var page: [Channel] = []
        let ms = try median { page = try repo.channels(sourceId: "s", categoryId: "k7", offset: 0, limit: 100) }
        report("list page (category)", ms, budget: 100)
        XCTAssertEqual(page.count, 100)
        XCTAssertLessThan(ms, 100 * factor, "list page \(ms) ms")
    }

    func testAllChannelsDeepPageUnderBudget() throws {
        let (_, repo) = try makeCatalog()
        let ms = try median { _ = try repo.channels(sourceId: "s", offset: 40_000, limit: 100) }
        report("list page (all, offset 40000)", ms, budget: 100)
        XCTAssertLessThan(ms, 100 * factor, "deep page \(ms) ms")
    }

    /// FTS search over 50 000 channels (+ 20 000 movies, 5 000 series) for a token every row matches:
    /// per-kind limits (30 each) must stay within the 100 ms budget and return all three kinds.
    func testSearchUnderBudget() throws {
        let (db, _) = try makeCatalog()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "m")
        let movies = (0..<20_000).map { Movie(sourceId: "m", id: "m\($0)", name: "Film \($0) \(Self.words[$0 % 4]) HD", sort: $0) }
        let series = (0..<5_000).map { Series(sourceId: "m", id: "t\($0)", name: "Serie \($0) \(Self.words[$0 % 4])", sort: $0) }
        try session.write(channels: (0..<Self.n).map {
            TestData.channel(id: "c\($0)", sourceId: "m", name: "Kanal \($0) \(Self.words[$0 % 4]) HD", sort: $0)
        }, movies: movies, series: series)
        try session.commit()

        var hits: [SearchHit] = []
        let ms = try median { hits = try repo.search("sport", sourceId: "m") }
        report("search (50k channels + 20k movies + 5k series)", ms, budget: 100)
        XCTAssertEqual(hits.filter { $0.kind == .live }.count, 30)
        XCTAssertEqual(hits.filter { $0.kind == .movie }.count, 30)
        XCTAssertEqual(hits.filter { $0.kind == .series }.count, 30)
        XCTAssertLessThan(ms, 100 * factor, "search \(ms) ms")

        // Channels-only catalog (the original 50k budget case).
        var chOnly: [SearchHit] = []
        let ms2 = try median { chOnly = try repo.search("sport", sourceId: "s") }
        report("search (50k channels)", ms2, budget: 100)
        XCTAssertEqual(chOnly.count, 30)
        XCTAssertLessThan(ms2, 100 * factor, "search \(ms2) ms")
    }

    /// Realistic retention window: 10 000 EPG channels x 20 programmes = 200 000 rows. Lookups must be
    /// index-driven (cost independent of the table size), not a scan of the whole source.
    func makeEpg(_ db: AppDatabase, now: Date) throws -> EpgRepository {
        let epg = EpgRepository(database: db)
        let session = try epg.beginRefresh(sourceId: "s")
        for chunk in stride(from: 0, to: 10_000, by: 500) {
            var programs: [EpgProgram] = []
            for c in chunk..<(chunk + 500) {
                for p in 0..<20 {
                    let start = now.addingTimeInterval(Double(p - 8) * 3600 + 1800)
                    programs.append(EpgProgram(sourceId: "s", channelEpgId: "e\(c)", start: start,
                                               end: start.addingTimeInterval(3600), title: "P\(c)-\(p)"))
                }
            }
            try session.write(programs)
        }
        try session.commit()
        return epg
    }

    func testNowNextUnderBudget() throws {
        let (db, repo) = try makeCatalog()
        let now = Date()
        let epg = try makeEpg(db, now: now)
        let page = try repo.channels(sourceId: "s", categoryId: nil, offset: 0, limit: 100)
        let ids = page.compactMap(\.epgId)
        XCTAssertEqual(ids.count, 100)
        var map: [String: NowNext] = [:]
        let ms = try median { map = try epg.nowNext(sourceId: "s", epgIds: ids, at: now) }
        report("now/next (100 channels)", ms, budget: 20)
        XCTAssertEqual(map.count, 100)
        XCTAssertNotNil(map["e0"]?.now)
        XCTAssertNotNil(map["e0"]?.next)
        XCTAssertLessThan(ms, 20 * factor, "now/next \(ms) ms")
    }

    /// EPG grid load (`EpgGridViewModel.load`): 200 channels x a 6 h window, one query per channel.
    /// (Budget 100 ms is this task's choice — the spec only budgets now/next and 60 fps scrolling.)
    func testEpgGridLoadUnderBudget() throws {
        let (db, repo) = try makeCatalog()
        let now = Date()
        let epg = try makeEpg(db, now: now)
        let ids = try repo.channels(sourceId: "s", categoryId: nil, offset: 0, limit: 200).compactMap(\.epgId)
        let window = DateInterval(start: now.addingTimeInterval(-1800), duration: 6 * 3600)
        var rows = 0
        let ms = try median { rows = try ids.map { try epg.programs(sourceId: "s", epgId: $0, in: window).count }.reduce(0, +) }
        report("epg grid (200 channels x 6 h)", ms, budget: 100)
        XCTAssertEqual(rows, 200 * 6)
        XCTAssertLessThan(ms, 100 * factor, "epg grid \(ms) ms")
    }

    /// Movies/Series category navigation (docs/SCREENS.md §3.2) at 50 000 movies in 400 provider categories
    /// ("TR | …", "DE | …", "EN | …", "4K …"), every movie in two categories (Xtream `category_ids`).
    func makeVodCatalog() throws -> CatalogRepository {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "v")
        let prefixes = ["TR | ", "DE | ", "EN | ", "4K "]
        try session.write(categories: (0..<400).map {
            IPTVCore.Category(sourceId: "v", id: "vc\($0)", kind: .movie, name: "\(prefixes[$0 % 4])Kategorie \($0)", sort: $0)
        })
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for chunk in stride(from: 0, to: Self.n, by: 1000) {
            try session.write(movies: (chunk..<(chunk + 1000)).map {
                Movie(sourceId: "v", id: "m\($0)", name: "Film \($0)", rating: Double($0 % 97) / 10, addedAt: base.addingTimeInterval(Double($0)),
                      sort: $0, categoryIds: ["vc\($0 % 400)", "vc\(($0 * 7 + 3) % 400)"])
            })
        }
        try session.commit()
        return repo
    }

    func testCategoryInfosUnderBudget() throws {
        let repo = try makeVodCatalog()
        var infos: [CategoryInfo] = []
        let ms = try median { infos = try repo.categoryInfos(sourceId: "v", kind: .movie) }
        report("category infos (400 categories, 50k movies)", ms, budget: 100)
        XCTAssertEqual(infos.count, 400)
        XCTAssertEqual(infos.filter { $0.countryCode == "TR" }.count, 100)
        XCTAssertEqual(infos.filter { $0.countryCode == "EN" }.count, 100, "language group")
        XCTAssertEqual(infos.filter { $0.countryCode == nil }.count, 100, "\"4K …\" has no group")
        XCTAssertEqual(infos.map(\.itemCount).reduce(0, +), 2 * Self.n - duplicateMemberships(), "every membership counted")
        XCTAssertLessThan(ms, 100 * factor, "category infos \(ms) ms")
    }

    /// Movies whose two generated categories coincide have one membership row, not two.
    private func duplicateMemberships() -> Int {
        (0..<Self.n).filter { $0 % 400 == ($0 * 7 + 3) % 400 }.count
    }

    func testCountryRowsUnderBudget() throws {
        let repo = try makeVodCatalog()
        let tr = try repo.categoryInfos(sourceId: "v", kind: .movie).filter { $0.countryCode == "TR" }.map(\.id)
        var newest: [Movie] = []
        let msNew = try median { newest = try repo.movies(sourceId: "v", categoryIds: tr, sort: .added, limit: 20) }
        report("country new (100 categories, 50k movies)", msNew, budget: 100)
        XCTAssertEqual(newest.count, 20)
        XCTAssertEqual(Set(newest.map(\.id)).count, 20, "distinct")
        var top: [Movie] = []
        let msTop = try median { top = try repo.movies(sourceId: "v", categoryIds: tr, sort: .rating, limit: 10) }
        report("country top 10 (100 categories, 50k movies)", msTop, budget: 100)
        XCTAssertEqual(top.count, 10)
        XCTAssertLessThan(msNew, 100 * factor, "country new \(msNew) ms")
        XCTAssertLessThan(msTop, 100 * factor, "country top 10 \(msTop) ms")
    }

    /// People search (Build 10): 50 000 movies + 10 000 series with cast/director; a common first name matches
    /// thousands of people rows – both FTS queries (titles, then people NOT titles) stay within 100 ms.
    func testPeopleSearchUnderBudget() throws {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "p")
        let first = ["Hasan", "Ayşe", "Mehmet", "Anna", "Thomas", "Maria", "John", "Emma"]
        let last = ["Kaya", "Yılmaz", "Müller", "Schmidt", "Smith", "Demir", "Weber", "Brown"]
        func person(_ i: Int) -> String { "\(first[i % 8]) \(last[(i / 8) % 8]) \(i % 97)" }
        for chunk in stride(from: 0, to: Self.n, by: 1000) {
            try session.write(movies: (chunk..<(chunk + 1000)).map {
                Movie(sourceId: "p", id: "m\($0)", name: "Film \($0) \(Self.words[$0 % 4])", sort: $0,
                      cast: "\(person($0)), \(person($0 + 3))", director: person($0 + 5))
            })
        }
        try session.write(series: (0..<10_000).map {
            Series(sourceId: "p", id: "t\($0)", name: "Serie \($0)", sort: $0, cast: person($0 + 1), director: nil)
        })
        try session.commit()

        var hits: [SearchHit] = []
        let ms = try median { hits = try repo.search("hasan", sourceId: "p") }
        report("people search 'hasan' (50k movies + 10k series)", ms, budget: 100)
        XCTAssertEqual(hits.filter(\.isPersonMatch).count, 30)
        XCTAssertTrue(hits.filter(\.isPersonMatch).allSatisfy { $0.matchedPerson?.hasPrefix("Hasan") == true })
        XCTAssertLessThan(ms, 100 * factor, "people search \(ms) ms")

        var two: [SearchHit] = []
        let ms2 = try median { two = try repo.search("hasan kaya", sourceId: "p") }
        report("people search 'hasan kaya'", ms2, budget: 100)
        XCTAssertFalse(two.isEmpty)
        XCTAssertLessThan(ms2, 100 * factor, "people search \(ms2) ms")

        var mixed: [SearchHit] = []
        let ms3 = try median { mixed = try repo.search("sport", sourceId: "p") }
        report("title search with people column 'sport'", ms3, budget: 100)
        XCTAssertEqual(mixed.filter { $0.kind == .movie && !$0.isPersonMatch }.count, 30)
        XCTAssertLessThan(ms3, 100 * factor, "title search \(ms3) ms")
    }

    /// Deterministic word-like vocabulary (syllables), so titles/plots/names have realistic distinct terms.
    static func vocabulary(_ count: Int, seed: UInt64) -> [String] {
        let syllables = ["ka", "ya", "ha", "san", "mer", "lin", "tor", "de", "ni", "ze", "ro", "bu", "lu", "şe", "çi",
                         "gü", "ö", "ran", "ter", "mo", "na", "vi", "es", "tan", "bul", "ar", "ken", "dı", "fe", "pa"]
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        var seen = Set<String>()
        var words: [String] = []
        while words.count < count {
            let word = (0..<(2 + next() % 3)).map { _ in syllables[next() % syllables.count] }.joined()
            if seen.insert(word).inserted { words.append(word) }
        }
        return words
    }

    /// 50 000 movies with ~150-character descriptions + 10 000 series, titles/people/plots from a 30k-word
    /// vocabulary: description search (overview: titles, people, descriptions) and the did-you-mean correction
    /// (trigram dictionary of ~30k title/person words) with the search of the corrected query.
    func testDescriptionAndFuzzySearchUnderBudget() throws {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let words = Self.vocabulary(30_000, seed: 7)
        let names = Self.vocabulary(3_000, seed: 11).map { $0.capitalized }
        func w(_ i: Int) -> String { words[(i &* 7919) % words.count] }
        func person(_ i: Int) -> String { "\(names[i % names.count]) \(names[(i / 7 + 13) % names.count])" }
        let session = try repo.beginRefresh(sourceId: "p")
        for chunk in stride(from: 0, to: Self.n, by: 1000) {
            try session.write(movies: (chunk..<(chunk + 1000)).map { i in
                let plot = (0..<18).map { w(i * 31 + $0 * 17) }.joined(separator: " ") + (i % 500 == 0 ? " Hasan Can Kaya konuk." : "") + " Film anlatıyor."
                return Movie(sourceId: "p", id: "m\(i)", name: "\(w(i).capitalized) \(w(i + 1))", plot: plot, sort: i,
                             cast: "\(person(i)), \(person(i + 3))", director: person(i + 5))
            })
        }
        try session.write(series: (0..<10_000).map { i in
            Series(sourceId: "p", id: "t\(i)", name: "\(w(i + 99).capitalized) \(w(i + 7))", plot: (0..<12).map { w(i * 13 + $0) }.joined(separator: " "),
                   sort: i, cast: person(i + 1), director: nil)
        })
        let commitStart = DispatchTime.now()
        try session.commit()
        print("PERF refresh commit incl. term dictionary (60k items, first fill): \(Double(DispatchTime.now().uptimeNanoseconds - commitStart.uptimeNanoseconds) / 1e6) ms, terms: \(try db.db.scalar("SELECT COUNT(*) FROM search_terms") as Int)")

        var hits: [SearchHit] = []
        let ms = try median { hits = try repo.search("hasan can kaya", sourceId: "p") }
        report("description phrase search 'hasan can kaya' (50k movies with plots + 10k series)", ms, budget: 100)
        XCTAssertEqual(hits.filter { $0.match == .description }.count, 30)
        XCTAssertTrue(hits.filter { $0.match == .description }.allSatisfy { $0.snippet?.matchedWords == ["Hasan", "Can", "Kaya"] })
        XCTAssertLessThan(ms, 100 * factor, "description search \(ms) ms")

        // A word of every description (50 000 description matches to rank).
        let ms2 = try median { hits = try repo.search("anlatiyor", sourceId: "p") }
        report("search 'anlatiyor' (in all 50k descriptions)", ms2, budget: 100)
        XCTAssertEqual(hits.filter { $0.match == .description }.count, 30)
        XCTAssertLessThan(ms2, 100 * factor, "search \(ms2) ms")

        guard db.db.hasTrigram else { return }
        // "Did you mean": two typos in a title word + a person name.
        let target = w(1234)
        var letters = Array(target)
        letters.swapAt(1, 2)
        let typo = String(letters) + " " + String(names[42].lowercased().dropFirst())
        var corrected: String?
        let ms3 = try median {
            corrected = try repo.correction(for: typo, sourceId: "p")
            if let corrected { hits = try repo.search(corrected, sourceId: "p", perKindLimit: 10) }
        }
        report("did-you-mean '\(typo)' → '\(corrected ?? "-")' + search (~30k dictionary words)", ms3, budget: 150)
        XCTAssertNotNil(corrected)
        XCTAssertLessThan(ms3, 150 * factor, "fuzzy \(ms3) ms")
        let ms4 = try median { _ = try repo.completions(String(target.prefix(4)), sourceId: "p") }
        report("suggestions '\(target.prefix(4))'", ms4, budget: 100)
        XCTAssertLessThan(ms4, 100 * factor, "suggestions \(ms4) ms")
    }

    /// TV programme search over ~500 000 EPG rows (10 000 channels x 50 programmes): the per-source title index
    /// + the time window stay within 100 ms for a word in every 10th programme.
    func testProgrammeSearchUnderBudget() throws {
        let (db, repo) = try makeCatalog()
        try db.db.run("INSERT INTO sources (id, sort, json) VALUES ('s', 0, '{}')")
        let now = Date()
        let epg = EpgRepository(database: db)
        let titles = ["Haberler", "Spor Merkezi", "Akşam Filmi", "Belgesel Kuşağı", "Çocuk Saati", "Derby Day", "Müzik Listesi",
                      "Hava Durumu", "Gece Haberleri", "Sabah Programı"]
        let session = try epg.beginRefresh(sourceId: "s")
        for chunk in stride(from: 0, to: 10_000, by: 500) {
            var programs: [EpgProgram] = []
            for c in chunk..<(chunk + 500) {
                for p in 0..<50 {
                    let start = now.addingTimeInterval(Double(p - 20) * 3600 + Double(c % 60) * 60)
                    programs.append(EpgProgram(sourceId: "s", channelEpgId: "e\(c)", start: start, end: start.addingTimeInterval(3600),
                                               title: "\(titles[(c + p) % titles.count]) \(p)"))
                }
            }
            try session.write(programs)
        }
        try session.commit()
        XCTAssertEqual(try epg.programCount(sourceId: "s"), 500_000)
        let engine = SearchEngine(catalog: repo, epg: epg, sourceId: "s")
        var page: (items: [ProgrammeHit], consumed: Int, end: Bool) = ([], 0, true)
        let ms = try median { page = try engine.programmes("derby", offset: 0, limit: 30, now: now) }
        report("programme search 'derby' (500k EPG rows, window -2 h…+48 h)", ms, budget: 100)
        XCTAssertEqual(page.items.count, 30)
        XCTAssertEqual(page.items.first?.state, .live)
        XCTAssertLessThan(ms, 100 * factor, "programme search \(ms) ms")
        let ms2 = try median { page = try engine.programmes("haberleri", offset: 0, limit: 30, now: now) }
        report("programme search 'haberleri' (prefix, 500k rows)", ms2, budget: 100)
        XCTAssertLessThan(ms2, 100 * factor, "programme search \(ms2) ms")
    }

    /// The repository's real EPG SQL must be served by the `epg_lookup_lc` expression index (deterministic
    /// guard that does not depend on machine speed).
    func testEpgQueriesUseChannelIndex() throws {
        let db = try AppDatabase.inMemory()
        for sql in [EpgRepository.programsSQL, EpgRepository.nowNextSQL(idCount: 3)] {
            let args = Array(repeating: SQLiteValue.text("x"), count: sql.filter { $0 == "?" }.count)
            let plan = try db.db.query("EXPLAIN QUERY PLAN " + sql, args) { $0.string(3) }.joined(separator: " | ")
            XCTAssertTrue(plan.contains("epg_lookup_lc"), "EPG query does not use the lowercased-id index: \(plan)")
        }
    }
}
