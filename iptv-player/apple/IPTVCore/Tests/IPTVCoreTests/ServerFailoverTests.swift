import XCTest
@testable import IPTVCore

/// Build 30 (CONTRACT §1.1): backup servers of an Xtream account.
final class ServerFailoverTests: XCTestCase {
    func testServersListMainFirstValidAndUnique() {
        let s = XtreamSecrets(serverUrl: "http://main.example.com:8080", username: "u", password: "p",
                              backupServers: [" http://dns2.example.net:8080 ", "", "not a url", "http://main.example.com:8080/", "http://dns3.example.org"])
        XCTAssertEqual(s.servers, ["http://main.example.com:8080", "http://dns2.example.net:8080", "http://dns3.example.org"])
        XCTAssertEqual(s.using(server: "http://dns2.example.net:8080").serverUrl, "http://dns2.example.net:8080")
        XCTAssertEqual(s.using(server: "http://dns2.example.net:8080").backupServers, s.backupServers)
    }

    func testBackupsRoundTripAndAreOmittedWhenEmpty() throws {
        let with = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://a", username: "u", password: "p", backupServers: ["http://b"]))
        let data = try JSONEncoder().encode(with)
        XCTAssertEqual(try JSONDecoder().decode(SourceSecrets.self, from: data), with)
        let without = try JSONEncoder().encode(SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://a", username: "u", password: "p")))
        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("backupServers"), "old JSON shape (vectors, pairing, Android) unchanged")
        // A record written before Build 30 decodes with no backups.
        let old = Data(#"{"type":"xtream","serverUrl":"http://a","username":"u","password":"p"}"#.utf8)
        guard case .xtream(let s) = try JSONDecoder().decode(SourceSecrets.self, from: old) else { return XCTFail() }
        XCTAssertEqual(s.backupServers, [])
    }

    func testOnlyServerProblemsMoveToTheNextServer() {
        for e: SourceError in [.network(.dns), .network(.timeout), .network(.refused), .serverError(httpStatus: 503), .notFound, .invalidResponse] {
            XCTAssertTrue(ServerFailover.tryNextServer(after: e), "\(e)")
        }
        for e: SourceError in [.invalidCredentials, .accountExpired(expiresAt: nil), .accountDisabled, .empty, .cancelled] {
            XCTAssertFalse(ServerFailover.tryNextServer(after: e), "\(e)")
        }
    }
}
