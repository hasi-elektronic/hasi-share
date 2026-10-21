import XCTest
@testable import IPTVKit
import IPTVCore

// MARK: Fakes: an iCloud key-value server shared by "devices", and iCloud Keychain

/// The iCloud key-value server. `deliver()` uploads every device's writes (in device order – the last writer of a
/// key wins, like iCloud) and then pushes the server state to every device (`.serverChange`).
final class FakeICloud: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var server: [String: Data] = [:]
    private var devices: [FakeCloudStore] = []
    let quotaBytes: Int

    init(quotaBytes: Int = CloudSyncLimits.quotaBytes) { self.quotaBytes = quotaBytes }

    func device() -> FakeCloudStore {
        let store = FakeCloudStore(cloud: self)
        lock.lock(); devices.append(store); lock.unlock()
        return store
    }

    func deliver() {
        lock.lock(); let list = devices; lock.unlock()
        for d in list {
            for (key, data) in d.takePending() {
                lock.lock(); server[key] = data; lock.unlock()
            }
        }
        lock.lock(); let snapshot = server; lock.unlock()
        for d in list { d.download(snapshot) }
    }
}

final class FakeCloudStore: CloudKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var pending: [(String, Data?)] = []
    private var handlers: [@Sendable (CloudStoreChange, [String]) -> Void] = []
    private unowned let cloud: FakeICloud
    private(set) var writes = 0

    init(cloud: FakeICloud) { self.cloud = cloud }

    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        var next = values
        next[key] = data
        guard next.reduce(0, { $0 + $1.key.utf8.count + $1.value.count }) <= cloud.quotaBytes else {
            let list = handlers
            lock.unlock()
            list.forEach { $0(.quotaViolation, [key]) }
            return
        }
        values = next
        pending.append((key, data))
        writes += 1
        lock.unlock()
    }

    func synchronize() {}

    func observe(_ handler: @escaping @Sendable (CloudStoreChange, [String]) -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }

    func takePending() -> [(String, Data?)] {
        lock.lock(); defer { pending = []; lock.unlock() }
        return pending
    }

    func download(_ server: [String: Data]) {
        lock.lock()
        let changed = Set(server.keys).union(values.keys).filter { server[$0] != values[$0] }
        values = server
        let list = handlers
        lock.unlock()
        if !changed.isEmpty { list.forEach { $0(.serverChange, Array(changed)) } }
    }
}

/// iCloud Keychain: synchronizable items reach the other devices on `deliver()`.
final class FakeICloudKeychain: @unchecked Sendable {
    let lock = NSLock()
    var synced: [String: Data] = [:]
    private var devices: [FakeDeviceKeychain] = []

    func device() -> FakeDeviceKeychain {
        let d = FakeDeviceKeychain(cloud: self)
        lock.lock(); devices.append(d); lock.unlock()
        return d
    }

    func deliver() {
        lock.lock(); let list = devices, snapshot = synced; lock.unlock()
        list.forEach { $0.setVisible(snapshot) }
    }

    func has(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return synced[key] != nil }
}

final class FakeDeviceKeychain: CloudSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var local: [String: Data] = [:]
    private var visible: [String: Data] = [:]
    private unowned let cloud: FakeICloudKeychain

    init(cloud: FakeICloudKeychain) { self.cloud = cloud }

    func setVisible(_ items: [String: Data]) { lock.lock(); visible = items; lock.unlock() }

    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return local[key] ?? visible[key] }

    func hasLocal(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return local[key] != nil }

    func set(_ data: Data?, forKey key: String) throws { try set(data, forKey: key, synchronizable: false) }

    func set(_ data: Data?, forKey key: String, synchronizable: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if synchronizable {
            cloud.lock.lock(); cloud.synced[key] = data; cloud.lock.unlock()
            visible[key] = data
            local[key] = nil
        } else {
            local[key] = data
        }
    }

    func convert(key: String, toSynchronizable: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if toSynchronizable {
            guard let item = local[key] else { return }
            cloud.lock.lock(); cloud.synced[key] = item; cloud.lock.unlock()
            visible[key] = item
            local[key] = nil
        } else if local[key] == nil, let item = visible[key] {
            local[key] = item
        }
    }
}

// MARK: Tests

/// Build 17: iCloud sync of sources (secrets via iCloud Keychain), favorites, progress and category settings between
/// the user's devices – no backend (docs/ARCHITECTURE.md §6.1).
@MainActor
final class CloudSyncTests: XCTestCase {
    private let urlA = "http://lists.example.com/a.m3u"
    private let urlB = "http://lists.example.com/b.m3u"

    struct Device {
        let env: AppEnvironment
        let store: FakeCloudStore
        let keychain: FakeDeviceKeychain
        let kv: InMemoryKeyValueStore
        let transport: FakeTransport
        @MainActor var cloud: CloudSync { env.cloud }
    }

    private func config() -> AppConfig {
        AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                  backendBaseURL: URL(string: "http://127.0.0.1:9")!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                  licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test",
                  accountsEnabled: false)
    }

    private func m3uTransport() throws -> FakeTransport {
        let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        return FakeTransport { request in
            request.url.path.hasSuffix(".m3u") ? HTTPResponse(statusCode: 200, body: m3u) : HTTPResponse(statusCode: 404, body: Data())
        }
    }

    private func freshDefaults() -> UserDefaults {
        let name = "cloud-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// A device with an iCloud account; `enabled: nil` = never chosen (on because the account exists).
    private func device(_ cloud: FakeICloud, _ keychain: FakeICloudKeychain, enabled: Bool? = nil, activate: Bool = true) throws -> Device {
        let kv = InMemoryKeyValueStore()
        if let enabled { kv.setValue(enabled, forKey: CloudSync.enabledKey) }
        let store = cloud.device(), secure = keychain.device(), transport = try m3uTransport()
        let env = try AppEnvironment(config: config(), database: try .inMemory(), secureStore: secure, kv: kv,
                                     settings: AppSettings(defaults: freshDefaults()), transport: transport,
                                     cloudStore: store, cloudAccount: StaticCloudAccount(available: true))
        env.cloud.pushDelay = 3600   // tests write explicitly (`syncNow`)
        env.cloud.secretPollInterval = .seconds(3600)
        if activate { env.cloud.activate() }
        return Device(env: env, store: store, keychain: secure, kv: kv, transport: transport)
    }

    /// Lets queued main-actor hops (change notifications) run, then waits for the sync queue.
    private func settle(_ devices: [Device]) async {
        for _ in 0..<4 {
            for _ in 0..<5 { await Task.yield() }
            for d in devices { await d.cloud.waitForIdle() }
        }
    }

    /// Writes, delivers through iCloud, applies – until nothing changes any more (max 6 rounds).
    private func converge(_ cloud: FakeICloud, _ devices: [Device], keychain: FakeICloudKeychain? = nil) async {
        for _ in 0..<6 {
            for d in devices { await d.cloud.syncNow() }
            let before = cloud.server
            cloud.deliver()
            keychain?.deliver()
            await settle(devices)
            cloud.deliver()
            await settle(devices)
            if cloud.server == before { return }
        }
    }

    private func firstChannel(_ env: AppEnvironment, _ sourceId: String) throws -> Channel {
        try XCTUnwrap(env.catalog.channels(sourceId: sourceId, limit: 1).first)
    }

    private func firstMovie(_ env: AppEnvironment, _ sourceId: String) throws -> Movie {
        try XCTUnwrap(env.catalog.movies(sourceId: sourceId, limit: 1).first)
    }

    // MARK: Two devices converge

    func testSourceFavoritesAndProgressReachTheOtherDeviceSecretsViaICloudKeychain() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let source = try await phone.env.addSource(name: "Wohnzimmer", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let channel = try firstChannel(phone.env, source.id)
        XCTAssertTrue(phone.env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil))
        let movie = try firstMovie(phone.env, source.id)
        let movieKey = try XCTUnwrap(phone.env.contentKey(sourceId: source.id, kind: .movie, itemId: movie.id))
        try phone.env.library.saveProgress(contentKey: movieKey, title: movie.name, kind: .movie, positionMs: 600_000,
                                           durationMs: 7_200_000, posterUrl: nil, nowMs: 1_800_000_000_000)
        XCTAssertTrue(keychain.has("source.secrets.\(source.id)"), "secrets written as iCloud Keychain items")

        // The key-value data arrives before the Keychain item: the source waits, it is no error.
        await phone.cloud.syncNow()
        cloud.deliver()
        await settle([phone, tv])
        XCTAssertEqual(tv.env.sources.map(\.id), [source.id], "same source id on the TV")
        XCTAssertEqual(tv.env.sources.first?.name, "Wohnzimmer")
        XCTAssertNil(tv.env.sources.first?.lastRefreshResult, "not an error state")
        XCTAssertEqual(tv.cloud.awaitingSecrets, [source.id], "waiting for iCloud Keychain")
        XCTAssertTrue(tv.transport.requests.isEmpty, "nothing loaded without secrets")

        keychain.deliver()
        tv.cloud.checkAwaitingSecrets()
        XCTAssertTrue(tv.cloud.awaitingSecrets.isEmpty)
        for _ in 0..<200 where tv.env.sources.first?.lastRefreshResult == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tv.env.sources.first?.lastRefreshResult?.isOK, true, "loaded once the secrets arrived")
        XCTAssertGreaterThan(try tv.env.catalog.channels(sourceId: source.id, limit: 5).count, 0)

        let favoriteKey = try XCTUnwrap(tv.env.contentKey(sourceId: source.id, kind: .live, itemId: channel.id))
        XCTAssertTrue(tv.env.favorites.isFavorite(favoriteKey), "favorite synced")
        XCTAssertEqual(try tv.env.library.progress(contentKey: movieKey)?.data.positionMs, 600_000, "progress synced")
    }

    func testProgressLastWriterWinsAndConcurrentFavoritesBothSurvive() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let key = "fp0123456789abcd:movie:42"
        try phone.env.library.saveProgress(contentKey: key, title: "Film", kind: .movie, positionMs: 100_000, durationMs: 7_200_000,
                                           posterUrl: nil, nowMs: 1_000)
        try tv.env.library.saveProgress(contentKey: key, title: "Film", kind: .movie, positionMs: 900_000, durationMs: 7_200_000,
                                        posterUrl: nil, nowMs: 2_000)
        // Both devices write the same iCloud key before either saw the other: iCloud keeps one value.
        try phone.env.library.setFavorite(true, contentKey: "fp0123456789abcd:live:1", title: "Kanal 1", kind: .live, posterUrl: nil, nowMs: 1_500)
        try tv.env.library.setFavorite(true, contentKey: "fp0123456789abcd:live:2", title: "Kanal 2", kind: .live, posterUrl: nil, nowMs: 1_600)
        await converge(cloud, [phone, tv])

        for d in [phone, tv] {
            XCTAssertEqual(try d.env.library.progress(contentKey: key)?.data.positionMs, 900_000, "newer position wins")
            XCTAssertEqual(Set(try d.env.library.favorites().map(\.contentKey)),
                           ["fp0123456789abcd:live:1", "fp0123456789abcd:live:2"], "neither favorite lost")
        }
        // Converged: a further round writes nothing.
        let writes = phone.store.writes + tv.store.writes
        await converge(cloud, [phone, tv])
        XCTAssertEqual(phone.store.writes + tv.store.writes, writes, "no ping-pong")
    }

    func testDeletionsWinAndAreNotResurrectedByAStaleDevice() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let source = try await phone.env.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let channel = try firstChannel(phone.env, source.id)
        phone.env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
        await converge(cloud, [phone, tv], keychain: keychain)
        let key = try XCTUnwrap(phone.env.contentKey(sourceId: source.id, kind: .live, itemId: channel.id))
        XCTAssertTrue(tv.env.favorites.isFavorite(key))

        // The phone removes the favorite; the TV writes its old state (it has not seen the removal yet).
        phone.env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
        await phone.cloud.syncNow()
        await tv.cloud.syncNow()
        await converge(cloud, [phone, tv])
        XCTAssertFalse(phone.env.favorites.isFavorite(key), "tombstone not overwritten")
        XCTAssertFalse(tv.env.favorites.isFavorite(key), "removed on the TV too")

        // Source deleted on the TV: gone on the phone, catalog and secrets included; no resurrection.
        tv.env.deleteSource(id: source.id)
        await converge(cloud, [phone, tv], keychain: keychain)
        XCTAssertTrue(phone.env.sources.isEmpty, "deleted everywhere")
        XCTAssertTrue(tv.env.sources.isEmpty)
        XCTAssertNil(phone.env.secrets(for: source.id), "iCloud Keychain item removed")
        XCTAssertEqual(try phone.env.catalog.channels(sourceId: source.id, limit: 1).count, 0)
    }

    func testSameListAddedOnBothDevicesBecomesOneSource() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain, enabled: false), tv = try device(cloud, keychain, enabled: false)
        let a = try await phone.env.addSource(name: "Liste", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let b = try await tv.env.addSource(name: "Liste TV", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        _ = try await tv.env.addSource(name: "Nur TV", secrets: .m3u(M3USecrets(url: urlB))) { _ in }
        XCTAssertNotEqual(a.id, b.id)

        phone.cloud.setEnabled(true)
        tv.cloud.setEnabled(true)
        await converge(cloud, [phone, tv], keychain: keychain)

        let records = try XCTUnwrap(CloudCodec.decode(CloudMapPayload<CloudSourceRecord>.self, from: cloud.server[CloudSyncLimits.sourcesKey]))
        XCTAssertEqual(records.items.values.compactMap(\.val).count, 2, "one record per list")
        XCTAssertEqual(phone.env.sources.count, 2)
        XCTAssertEqual(tv.env.sources.count, 2)
        XCTAssertEqual(tv.env.sources.filter { $0.displayHost == "lists.example.com" }.count, 2)
        XCTAssertTrue(tv.env.sources.contains { $0.id == b.id }, "the TV keeps its own (loaded) source")
        XCTAssertEqual(Set(phone.env.sources.map(\.name)), Set(tv.env.sources.map(\.name)), "same names after the merge")
    }

    // MARK: Preferences

    func testCategoryPinsHiddenCountryAndFavoriteOrderSync() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let source = try await phone.env.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        await converge(cloud, [phone, tv], keychain: keychain)
        XCTAssertEqual(tv.env.sources.map(\.id), [source.id])

        phone.env.categoryPrefs.togglePin("films", sourceId: source.id, kind: .movie)
        phone.env.categoryPrefs.setHidden(true, categoryId: "xxx", sourceId: source.id, kind: .series)
        phone.env.categoryPrefs.setCountry("TR", sourceId: source.id, kind: .movie)
        phone.env.categoryPrefs.recordOpened("films", sourceId: source.id, kind: .movie)
        phone.env.favorites.toggleCategory(sourceId: source.id, categoryId: "news")
        phone.kv.setValue(["k2", "k1"], forKey: "fav.order.live")
        phone.env.favorites.move(kind: .live, from: [], to: 0)   // a local order change (notifies)
        await converge(cloud, [phone, tv])

        XCTAssertEqual(tv.env.categoryPrefs.pinned(sourceId: source.id, kind: .movie), ["films"])
        XCTAssertTrue(tv.env.categoryPrefs.isHidden("xxx", sourceId: source.id, kind: .series))
        XCTAssertEqual(tv.env.categoryPrefs.storedCountry(sourceId: source.id, kind: .movie), "TR")
        XCTAssertTrue(tv.env.categoryPrefs.recent(sourceId: source.id, kind: .movie).isEmpty, "recently opened stays local")
        XCTAssertTrue(tv.env.favorites.isFavoriteCategory(sourceId: source.id, categoryId: "news"))

        // Unpin on the TV → unpinned on the phone (an empty value is a change too).
        tv.env.categoryPrefs.togglePin("films", sourceId: source.id, kind: .movie)
        await converge(cloud, [phone, tv])
        XCTAssertEqual(phone.env.categoryPrefs.pinned(sourceId: source.id, kind: .movie), [])
    }

    func testAudioDelaysAndSelectedSourceStayOnTheDevice() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let a = try await phone.env.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        _ = try await phone.env.addSource(name: "B", secrets: .m3u(M3USecrets(url: urlB))) { _ in }
        phone.env.player.audioDelayStore?.setVLCCalibration(240)
        phone.env.player.audioDelayStore?.setContentDelay(300, for: "fp:live:1")
        phone.env.selectSource(a.id)
        await converge(cloud, [phone, tv], keychain: keychain)
        XCTAssertEqual(tv.env.sources.count, 2)
        XCTAssertEqual(tv.env.player.audioDelayStore?.vlcCalibration ?? 0, 0, "device calibration not synced")
        XCTAssertEqual(tv.env.player.audioDelayStore?.contentDelay("fp:live:1") ?? 0, 0, "audio delays not synced")
        XCTAssertNotEqual(tv.env.currentSource?.id, nil)
        for (_, data) in cloud.server {
            let json = String(decoding: (try? (data as NSData).decompressed(using: .zlib) as Data) ?? Data(), as: UTF8.self)
            XCTAssertFalse(json.contains("a.m3u") || json.contains("b.m3u"), "no secrets in the key-value store")
        }
    }

    // MARK: Enable / disable / quota

    func testFirstEnableMovesExistingDataAndSecretsToICloud() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain, enabled: false)
        let source = try await phone.env.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        let channel = try firstChannel(phone.env, source.id)
        phone.env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
        await phone.cloud.syncNow()
        XCTAssertEqual(phone.cloud.status, .off)
        XCTAssertEqual(phone.store.writes, 0, "nothing written while off")
        let secretKey = "source.secrets.\(source.id)"
        XCTAssertTrue(phone.keychain.hasLocal(secretKey))
        XCTAssertFalse(keychain.has(secretKey), "device-only while off")

        phone.cloud.setEnabled(true)
        await phone.cloud.waitForIdle()
        XCTAssertEqual(phone.cloud.status, .upToDate)
        XCTAssertTrue(keychain.has(secretKey), "moved to iCloud Keychain")
        XCTAssertFalse(phone.keychain.hasLocal(secretKey), "one item: the iCloud one")
        XCTAssertNotNil(phone.env.secrets(for: source.id))

        let tv = try device(cloud, keychain)
        cloud.deliver()
        keychain.deliver()
        await settle([phone, tv])
        XCTAssertEqual(tv.env.sources.map(\.id), [source.id], "existing local data arrived")
        XCTAssertEqual(try tv.env.library.favorites().count, 1)
    }

    func testDisablingKeepsLocalDataAndStopsSyncInBothDirections() async throws {
        let cloud = FakeICloud(), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain), tv = try device(cloud, keychain)
        let source = try await phone.env.addSource(name: "A", secrets: .m3u(M3USecrets(url: urlA))) { _ in }
        await converge(cloud, [phone, tv], keychain: keychain)
        XCTAssertEqual(tv.env.sources.count, 1)

        tv.cloud.setEnabled(false)
        XCTAssertEqual(tv.cloud.status, .off)
        XCTAssertEqual(tv.env.sources.map(\.id), [source.id], "local data kept")
        XCTAssertTrue(tv.keychain.hasLocal("source.secrets.\(source.id)"), "device-only copy of the secrets")
        XCTAssertTrue(keychain.has("source.secrets.\(source.id)"), "iCloud copy stays for the other devices")

        // Changes no longer travel either way.
        let channel = try firstChannel(phone.env, source.id)
        phone.env.toggleFavorite(sourceId: source.id, kind: .live, itemId: channel.id, title: channel.name, posterUrl: nil)
        let writesBefore = tv.store.writes
        tv.env.updateSource(id: source.id) { $0.name = "Nur hier" }
        await converge(cloud, [phone, tv])
        XCTAssertEqual(try tv.env.library.favorites().count, 0, "remote change not applied")
        XCTAssertEqual(tv.store.writes, writesBefore, "local change not written")
        XCTAssertEqual(phone.env.sources.first?.name, "A")

        // Deleting the source on the TV now keeps the phone's iCloud Keychain item.
        tv.env.deleteSource(id: source.id)
        XCTAssertTrue(keychain.has("source.secrets.\(source.id)"))
    }

    func testQuotaViolationShrinksTheLibraryAndReportsIt() async throws {
        let cloud = FakeICloud(quotaBytes: 40_000), keychain = FakeICloudKeychain()
        let phone = try device(cloud, keychain)
        let items = (0..<300).map { i in
            SyncItem.progress(contentKey: "fp\(i)abcdef012345:episode:\(UUID().uuidString)", title: "Serie \(UUID().uuidString) \(UUID().uuidString) \(UUID().uuidString)",
                              contentKind: .episode, positionMs: Int64(i) * 1000, durationMs: 2_700_000,
                              posterUrl: "http://img.example.com/\(UUID().uuidString)/\(UUID().uuidString).jpg", updatedAt: Int64(1_000 + i))
        }
        for item in items { try phone.env.library.put(item) }
        await phone.cloud.syncNow()
        await settle([phone])
        await phone.cloud.syncNow()
        await settle([phone])
        XCTAssertTrue(phone.cloud.storageFull)
        XCTAssertEqual(phone.cloud.status, .storageFull)
        let stored = try XCTUnwrap(CloudCodec.decode(CloudLibraryPayload.self, from: phone.store.data(forKey: CloudSyncLimits.libraryKey)))
        XCTAssertGreaterThan(stored.progress.count, 0, "the newest progress still synced")
        XCTAssertLessThan(stored.progress.count, 300, "older progress left out")
        XCTAssertEqual(stored.progress.first?.updatedAt, 1_299, "newest first")
        XCTAssertEqual(try phone.env.library.progressItems(limit: 1000).count, 300, "nothing lost locally")
    }

    func testNoAccountMeansOffUntilAnAccountAppears() async throws {
        let account = StaticCloudAccount(available: false)
        let env = try AppEnvironment(config: config(), database: try .inMemory(), secureStore: InMemorySecureStore(),
                                     kv: InMemoryKeyValueStore(), settings: AppSettings(defaults: freshDefaults()),
                                     transport: try m3uTransport(), cloudStore: InMemoryCloudKeyValueStore(), cloudAccount: account)
        env.cloud.activate()
        XCTAssertFalse(env.cloud.isEnabled)
        XCTAssertEqual(env.cloud.status, .off)
        account.isAvailable = true
        for _ in 0..<10 { await Task.yield() }
        await env.cloud.waitForIdle()
        XCTAssertTrue(env.cloud.isEnabled, "default on once an iCloud account exists")
        env.cloud.setEnabled(true)
        account.isAvailable = false
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(env.cloud.isEnabled, "the user's explicit choice stays")
        XCTAssertEqual(env.cloud.status, .noAccount)
    }

    // MARK: Merge rules (pure)

    func testStampAndMergeRules() {
        var known: [String: KnownEntry] = [:]
        XCTAssertTrue(CloudMerge.stamp(current: ["a": "h1", "b": "h2"], known: &known, now: 100))
        XCTAssertFalse(CloudMerge.stamp(current: ["a": "h1", "b": "h2"], known: &known, now: 200), "unchanged: no new stamp")
        CloudMerge.stamp(current: ["a": "h1x"], known: &known, now: 100)
        XCTAssertEqual(known["a"], KnownEntry(at: 101, hash: "h1x"), "strictly after the previous version")
        XCTAssertEqual(known["b"], KnownEntry(at: 101, hash: nil), "removed → tombstone")

        // Newer remote wins, older loses (local ahead), tombstone of an unknown key is only remembered.
        let remote = CloudMapPayload<[String]>(h: 0, items: ["a": CloudEntry(at: 300, val: ["x"]), "b": CloudEntry(at: 50, val: ["old"]),
                                                             "c": CloudEntry(at: 10, val: nil)])
        let outcome = CloudMerge.merge(remote: remote, known: known)
        XCTAssertEqual(outcome.changes.map(\.key), ["a"])
        XCTAssertTrue(outcome.localAhead, "b's tombstone is newer than the remote value")
        XCTAssertEqual(outcome.known["c"], KnownEntry(at: 10, hash: nil))
    }

    func testAbsenceNeverDeletesAndExpiredTombstonesAreForgotten() {
        let day: Int64 = 86_400_000
        let now: Int64 = 1_000 * day
        let horizon = CloudMerge.horizon(now: now)
        let known = ["old": KnownEntry(at: horizon - day, hash: "h"), "fresh": KnownEntry(at: now - day, hash: "h2"),
                     "gone": KnownEntry(at: horizon - day, hash: nil)]
        // A fresh device overwrote the value before it had downloaded ours: nothing is deleted, ours is written again.
        let merged = CloudMerge.merge(remote: CloudMapPayload<[String]>(h: horizon, items: [:]), known: known)
        XCTAssertTrue(merged.changes.isEmpty, "absence never deletes")
        XCTAssertTrue(merged.localAhead)
        XCTAssertNil(merged.known["gone"], "expired tombstone forgotten")
        XCTAssertNotNil(merged.known["old"])
        let payload = CloudMerge.payload(known: known, current: ["old": ["a"], "fresh": ["b"]], now: now)
        XCTAssertEqual(Set(payload.items.keys), ["old", "fresh"], "expired tombstones are not written")
    }

    func testLibraryPayloadRoundTripAndBudget() {
        let favorites = (0..<50).map { SyncItem.favorite(contentKey: "fp:live:\($0)", title: "Kanal \($0)", contentKind: .live, posterUrl: nil, updatedAt: Int64(100 + $0)) }
        let tombstone = SyncItem.favorite(contentKey: "fp:live:gone", title: "x", contentKind: .live, posterUrl: nil,
                                          updatedAt: Int64.max / 2, deleted: true)
        let built = CloudLibrarySync.payload(from: favorites + [tombstone], now: 1_000_000, budget: CloudSyncLimits.libraryBudgetBytes)
        let decoded = CloudCodec.decode(CloudLibraryPayload.self, from: built.data)
        XCTAssertEqual(decoded?.versions, built.payload.versions)
        XCTAssertEqual(decoded?.tombstones.map(\.key), ["fav:fp:live:gone"])
        XCTAssertTrue(decoded?.full ?? false)
        let small = CloudLibrarySync.payload(from: favorites, now: 1_000_000, budget: 300)
        XCTAssertFalse(small.payload.full, "favorites dropped to fit → not full")
        XCTAssertLessThanOrEqual(small.data?.count ?? 0, 300)
    }
}
