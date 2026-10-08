import Foundation
import IPTVCore
import XCTest
@testable import IPTVKit

/// Source management (Build 16): edit + re-validation (IOS-03/U2), adding a second source keeps the current one
/// (IOS-08), reorder (IOS-23), EPG status (B6), refresh on resume (B5), no placeholder-backend calls.
@MainActor
final class SourceManagementTests: XCTestCase {
    /// M3U lists + an XMLTV endpoint that can fail; records every request.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var _epgFails = false
        var epgFails: Bool {
            get { lock.withLock { _epgFails } }
            set { lock.withLock { _epgFails = newValue } }
        }

        func transport() throws -> FakeTransport {
            let m3u = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
            let xmltv = try Data(contentsOf: vectorURL("xmltv/epg_basic.xml"))
            let auth = try Data(contentsOf: vectorURL("xtream/auth_ok.json"))
            return FakeTransport { [self] request in
                let url = request.url.absoluteString
                if url.contains("player_api.php") {   // Xtream panel "panel.example.com" with user "demo" / "renamed"
                    let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "action" })?.value
                    let password = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "password" })?.value
                    if password == "wrong" { return HTTPResponse(statusCode: 200, body: Data(#"{"user_info":{"auth":0}}"#.utf8)) }
                    if action == nil { return HTTPResponse(statusCode: 200, body: auth) }
                    if action == "get_live_streams" {
                        return HTTPResponse(statusCode: 200, body: Data(#"[{"stream_id":1,"name":"One","category_id":"1"}]"#.utf8))
                    }
                    return HTTPResponse(statusCode: 200, body: Data("[]".utf8))
                }
                if url.contains("guide") || url.contains("epg") || url.contains("xmltv") {
                    if lock.withLock({ _epgFails }) { return HTTPResponse(statusCode: 404) }
                    return HTTPResponse(statusCode: 200, body: xmltv)
                }
                if url.hasSuffix(".m3u") { return HTTPResponse(statusCode: 200, body: m3u) }
                return HTTPResponse(statusCode: 404)
            }
        }
    }

    private func makeEnvironment(_ transport: FakeTransport, backend: String = "https://iptv-backend.example.workers.dev",
                                 accounts: Bool = false) throws -> AppEnvironment {
        let config = AppConfig(displayName: "Test", bundleId: "de.hasielektronik.novaplayer", appVersion: "1.0",
                               backendBaseURL: URL(string: backend)!, productIDs: ProductIDs(lifetime: "l", trial: "t"),
                               licenseKeysJSON: TestSigner().jwkSetJSON, platform: .ios, rawDeviceId: "device", deviceName: "Test",
                               accountsEnabled: accounts)
        return try AppEnvironment(config: config, database: AppDatabase.inMemory(), secureStore: InMemorySecureStore(),
                                  kv: InMemoryKeyValueStore(), transport: transport)
    }

    private func m3u(_ name: String) -> SourceSecrets {
        .m3u(M3USecrets(url: "http://lists.example.com/\(name).m3u", epgUrl: "http://epg.example.com/\(name)-guide.xml"))
    }

    func testSecondSourceDoesNotReplaceTheCurrentOne() async throws {
        let env = try makeEnvironment(try Server().transport())
        let first = try await env.addSource(name: "First", secrets: m3u("a")) { _ in }
        XCTAssertEqual(env.currentSource?.id, first.id, "the first source becomes current")
        let second = try await env.addSource(name: "Second", secrets: m3u("b")) { _ in }
        XCTAssertEqual(env.currentSource?.id, first.id, "adding a second source keeps the one in use")
        env.selectSource(second.id)
        XCTAssertEqual(env.currentSource?.id, second.id)
    }

    func testMoveSourcesPersistsOrder() async throws {
        let env = try makeEnvironment(try Server().transport())
        let a = try await env.addSource(name: "A", secrets: m3u("a")) { _ in }
        let b = try await env.addSource(name: "B", secrets: m3u("b")) { _ in }
        let c = try await env.addSource(name: "C", secrets: m3u("c")) { _ in }
        env.moveSources(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(env.sources.map(\.id), [c.id, a.id, b.id])
        env.reloadSources()
        XCTAssertEqual(env.sources.map(\.id), [c.id, a.id, b.id], "persisted")
    }

    func testEditSourceRevalidatesAndRestoresOnFailure() async throws {
        let env = try makeEnvironment(try Server().transport())
        let panel = XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "demo", password: "demo")
        let source = try await env.addSource(name: "Panel", secrets: .xtream(panel)) { _ in }
        XCTAssertEqual(try env.catalog.channelCount(sourceId: source.id), 1)

        // Wrong password: error thrown, the old name / secrets / status / catalog stay.
        var wrong = panel
        wrong.password = "wrong"
        do {
            try await env.editSource(id: source.id, name: "Renamed", secrets: .xtream(wrong))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SourceError, .invalidCredentials)
        }
        XCTAssertEqual(env.sources.first?.name, "Panel")
        XCTAssertEqual(env.secrets(for: source.id), .xtream(panel))
        XCTAssertTrue(env.sources.first?.lastRefreshResult?.isOK ?? false)
        XCTAssertEqual(try env.catalog.channelCount(sourceId: source.id), 1)

        // New EPG URL + name: saved and reloaded.
        var withEpg = panel
        withEpg.epgUrl = "http://epg.example.com/custom.xml"
        let edited = try await env.editSource(id: source.id, name: "Renamed", secrets: .xtream(withEpg))
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertTrue(edited.epgUrlOverride)
        XCTAssertEqual(env.refresher.epgURL(sourceId: source.id)?.absoluteString, "http://epg.example.com/custom.xml")
    }

    func testEditWithNewHostMovesFavoritesAndProgressToTheNewFingerprint() async throws {
        let env = try makeEnvironment(try Server().transport())
        let panel = XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "demo", password: "demo")
        let source = try await env.addSource(name: "Panel", secrets: .xtream(panel)) { _ in }
        env.toggleFavorite(sourceId: source.id, kind: .live, itemId: "1", title: "One", posterUrl: nil)
        XCTAssertTrue(env.isFavorite(sourceId: source.id, kind: .live, itemId: "1"))
        var moved = panel
        moved.serverUrl = "http://new-dns.example.com:2095"
        try await env.editSource(id: source.id, name: "Panel", secrets: .xtream(moved))
        XCTAssertTrue(env.isFavorite(sourceId: source.id, kind: .live, itemId: "1"), "favorite follows the new host")
        let all = try env.library.all()
        XCTAssertEqual(all.filter { !$0.deleted }.count, 1)
        XCTAssertEqual(all.filter(\.deleted).count, 1, "the old key is a tombstone (synced)")
    }

    func testEpgFailureIsRecordedAndClearedBySuccess() async throws {
        let server = Server()
        let env = try makeEnvironment(try server.transport())
        let source = try await env.addSource(name: "A", secrets: m3u("a")) { _ in }
        server.epgFails = true
        let failed = await env.refresher.refreshEpg(sourceId: source.id)
        XCTAssertNil(failed)
        env.reloadSources()
        XCTAssertNotNil(env.sources.first?.lastRefreshResult?.epgError, "EPG failure is visible in source management")
        XCTAssertTrue(env.sources.first?.lastRefreshResult?.isOK ?? false, "the catalog stays OK")
        // A catalog refresh keeps the EPG state until the next EPG load reports.
        _ = try await env.refresher.refresh(sourceId: source.id, includeEpg: false)
        XCTAssertNotNil(try env.sourceRepository.source(id: source.id)?.lastRefreshResult?.epgError)
        server.epgFails = false
        let loaded = await env.refresher.refreshEpg(sourceId: source.id)
        XCTAssertNotNil(loaded)
        env.reloadSources()
        XCTAssertNil(env.sources.first?.lastRefreshResult?.epgError)
        XCTAssertNotNil(env.sources.first?.lastRefreshResult?.epgLoadedAt)
    }

    /// A settings change and an EPG result written while a catalog refresh downloads are kept (atomic
    /// read-modify-write of the stored source instead of the refresh's stale copy).
    func testChangesDuringARefreshAreNotLost() async throws {
        let gate = DispatchSemaphore(value: 0)
        let blocking = BlockingFlag()
        let playlist = try Data(contentsOf: vectorURL("m3u/valid_basic.m3u"))
        let transport = FakeTransport { request in
            let url = request.url.absoluteString
            if url.hasSuffix(".m3u") {
                if blocking.isOn { gate.wait() }
                return HTTPResponse(statusCode: 200, body: playlist)
            }
            return HTTPResponse(statusCode: 404)   // EPG fails
        }
        let env = try makeEnvironment(transport)
        let source = try await env.addSource(name: "A", secrets: m3u("a")) { _ in }
        blocking.isOn = true
        let refresher = env.refresher
        let refresh = Task.detached { try await refresher.refresh(sourceId: source.id, includeEpg: false) }
        try await Task.sleep(for: .milliseconds(100))   // the refresh is waiting for its download
        env.updateSource(id: source.id) { $0.autoRefreshHours = 6 }
        _ = await refresher.refreshEpg(sourceId: source.id)
        gate.signal()
        _ = try await refresh.value
        let stored = try XCTUnwrap(env.sourceRepository.source(id: source.id))
        XCTAssertEqual(stored.autoRefreshHours, 6, "the user's change survives the refresh")
        XCTAssertNotNil(stored.lastRefreshResult?.epgError, "the EPG result survives the refresh")
        XCTAssertTrue(stored.lastRefreshResult?.isOK ?? false)
    }

    func testResumeRefreshesDueSourcesOnly() async throws {
        let transport = try Server().transport()
        let env = try makeEnvironment(transport)
        env.resumeRefreshDelay = .zero
        let source = try await env.addSource(name: "A", secrets: m3u("a")) { _ in }
        // Not started yet: the cold start refreshes, not the activation.
        env.refreshOnResume()
        XCTAssertNil(env.resumeRefresh)
        await env.start()
        XCTAssertTrue(env.hasStarted)

        let lists = { transport.requests.filter { $0.url.absoluteString.hasSuffix(".m3u") }.count }
        let before = lists()
        env.refreshOnResume(now: Date())
        await env.resumeRefresh?.value
        XCTAssertEqual(lists(), before, "not due yet (24 h)")

        var old = try XCTUnwrap(env.sources.first)
        old.lastRefreshAt = Date().addingTimeInterval(-25 * 3600)
        env.updateSource(old)
        env.refreshOnResume(now: Date())
        await env.resumeRefresh?.value
        XCTAssertEqual(lists(), before, "debounced: within a minute of the last check")
        env.refreshOnResume(now: Date().addingTimeInterval(120))
        await env.resumeRefresh?.value
        XCTAssertEqual(lists(), before + 1, "due after a long suspension → refreshed on resume")
        XCTAssertGreaterThan(try XCTUnwrap(env.sources.first { $0.id == source.id }?.lastRefreshAt), Date().addingTimeInterval(-60))
    }

    func testEditFormIsPrefilledAndHidesCredentialsInTheDefaultEpgHint() async throws {
        let env = try makeEnvironment(try Server().transport())
        let panel = XtreamSecrets(serverUrl: "http://panel.example.com:8080", username: "demo", password: "s3cret")
        let source = try await env.addSource(name: "Panel", secrets: .xtream(panel)) { _ in }
        let form = AddSourceViewModel(env: env, editing: try XCTUnwrap(env.sources.first { $0.id == source.id }))
        XCTAssertTrue(form.isEditing)
        XCTAssertEqual(form.kind, .xtream)
        XCTAssertEqual(form.name, "Panel")
        XCTAssertEqual(form.server, "http://panel.example.com:8080")
        XCTAssertEqual(form.username, "demo")
        XCTAssertEqual(form.password, "s3cret")
        XCTAssertEqual(form.defaultEpgHint, "panel.example.com:8080/xmltv.php", "host + path only – no user / password")

        let m3u = try await env.addSource(name: "List", secrets: m3u("a")) { _ in }
        let m3uForm = AddSourceViewModel(env: env, editing: try XCTUnwrap(env.sources.first { $0.id == m3u.id }))
        XCTAssertEqual(m3uForm.epgURL, "http://epg.example.com/a-guide.xml")
        XCTAssertEqual(m3uForm.defaultEpgHint, "epg.example.com/guide.xml.gz", "the playlist's x-tvg-url")
    }

    /// IOS-21: inside the add/edit form every error offers "Edit"; "Delete source" never appears there.
    func testFormErrorActions() {
        XCTAssertEqual(AddSourceViewModel.formErrorActions([.refresh]), [.refresh, .edit])
        XCTAssertEqual(AddSourceViewModel.formErrorActions([.edit, .deleteSource]), [.edit])
        XCTAssertEqual(AddSourceViewModel.formErrorActions([.retry, .edit]), [.retry, .edit])
    }

    func testPlaceholderBackendIsNeverCalled() async throws {
        let transport = try Server().transport()
        let env = try makeEnvironment(transport, accounts: true)
        XCTAssertFalse(env.config.backendConfigured)
        XCTAssertFalse(env.accountsEnabled, "accounts need a real backend")
        await env.start()
        env.scenePhaseChanged(isActive: true)
        await env.syncLicense()
        XCTAssertFalse(transport.requests.contains { $0.url.host?.contains("iptv-backend") == true })
        XCTAssertFalse(env.license.serverUnreachable)

        let configured = try makeEnvironment(try Server().transport(), backend: "https://api.novaplayer.app", accounts: false)
        XCTAssertTrue(configured.config.backendConfigured)
        XCTAssertFalse(configured.accountsEnabled, "ACCOUNTS_ENABLED = NO hides accounts")
        XCTAssertFalse(AppConfigProbe.configured("https://invalid.example"))
        XCTAssertTrue(AppConfigProbe.configured("https://backend.hasi-elektronic.de"))
    }
}

private final class BlockingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

private enum AppConfigProbe {
    static func configured(_ url: String) -> Bool {
        AppConfig(displayName: "", bundleId: "", appVersion: "", backendBaseURL: URL(string: url)!, productIDs: ProductIDs(lifetime: "", trial: ""),
                  licenseKeysJSON: Data(), platform: .ios, rawDeviceId: "", deviceName: "").backendConfigured
    }
}
