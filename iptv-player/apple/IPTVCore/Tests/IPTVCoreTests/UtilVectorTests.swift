import Foundation
import XCTest
@testable import IPTVCore

/// CONTRACT §1.1, §7.1, §10 – `content-keys.json`, `redaction.json`.
final class UtilVectorTests: XCTestCase {
    func testContentKeys() throws {
        let cases = try XCTUnwrap(Vectors.object("content-keys.json").arr("cases"))
        XCTAssertEqual(cases.count, 7)
        for c in cases {
            let kind = try XCTUnwrap(ContentKind(rawValue: try XCTUnwrap(c.str("kind"))))
            let fingerprint = try XCTUnwrap(c.str("fingerprint"))
            switch c.str("type") {
            case "xtream":
                let host = try XCTUnwrap(c.str("host")), user = try XCTUnwrap(c.str("username"))
                XCTAssertEqual(SourceFingerprint.xtream(host: host, username: user), fingerprint, "\(c)")
                XCTAssertEqual(ContentKey.make(fingerprint: fingerprint, kind: kind, itemId: try XCTUnwrap(c.str("itemId"))),
                               c.str("contentKey"))
                // Same result when starting from a user-typed server URL / the secrets.
                XCTAssertEqual(SourceFingerprint.xtream(serverUrl: "http://\(host):8080/", username: user), fingerprint)
                XCTAssertEqual(SourceFingerprint.of(.xtream(XtreamSecrets(serverUrl: host, username: user, password: "x"))), fingerprint)
            case "m3u":
                let url = try XCTUnwrap(c.str("url"))
                XCTAssertEqual(URLNormalizer.normalize(url), c.str("normalizedUrl"))
                XCTAssertEqual(SourceFingerprint.m3u(url: url), fingerprint)
                XCTAssertEqual(SourceFingerprint.of(.m3u(M3USecrets(url: url))), fingerprint)
                let itemId = ContentKey.m3uItemId(entryUrl: try XCTUnwrap(c.str("entryUrl")))
                XCTAssertEqual(itemId, c.str("itemId"))
                XCTAssertEqual(ContentKey.make(fingerprint: fingerprint, kind: kind, itemId: itemId), c.str("contentKey"))
            default:
                XCTFail("unknown type")
            }
            let parsed = try XCTUnwrap(ContentKey.parse(try XCTUnwrap(c.str("contentKey"))))
            XCTAssertEqual(parsed.kind, kind)
            XCTAssertEqual(parsed.fingerprint, fingerprint)
        }
        XCTAssertNil(ContentKey.parse("abc:unknown:1"))
    }

    func testDeviceKeys() throws {
        let list = try XCTUnwrap(Vectors.object("content-keys.json").arr("deviceKeys"))
        XCTAssertEqual(list.count, 2)
        for c in list {
            XCTAssertEqual(DeviceKey.make(appId: try XCTUnwrap(c.str("appId")), rawDeviceId: try XCTUnwrap(c.str("rawId"))),
                           c.str("expected"))
        }
    }

    func testRedaction() throws {
        let cases = try XCTUnwrap(Vectors.object("redaction.json").arr("cases"))
        XCTAssertEqual(cases.count, 11)
        for c in cases {
            let input = try XCTUnwrap(c.str("input"))
            let secrets = try XCTUnwrap(c["secrets"] as? [String])
            XCTAssertEqual(Redactor.redact(input, secrets: secrets), c.str("expected"), "input: \(input)")
            // Same through a long-lived registry.
            let r = Redactor()
            r.register(secrets)
            XCTAssertEqual(r.redact(input), c.str("expected"))
        }
    }

    func testRedactorRegistry() {
        let r = Redactor()
        let secrets = SourceSecrets.xtream(XtreamSecrets(serverUrl: "http://h", username: "ali", password: "p@ss/w rd"))
        r.register(secrets.redactableValues + ["ab"])
        XCTAssertEqual(r.registeredCount, 3, "ali, p@ss/w rd and its encoded form; 'ab' is too short")
        XCTAssertEqual(r.redact("x p@ss/w rd y p%40ss%2Fw%20rd"), "x *** y ***")
        r.unregister(secrets.redactableValues)
        XCTAssertEqual(r.redact("x p@ss/w rd y"), "x p@ss/w rd y")
    }

    func testNormalizeUrlEdgeCases() {
        XCTAssertEqual(URLNormalizer.normalize(" HTTP://[::1]:8080/a?b#C "), "http://[::1]:8080/a?b#C")
        XCTAssertEqual(URLNormalizer.normalize("HTTPS://u:P@HOST.example:443/x"), "https://u:P@host.example/x")
        XCTAssertEqual(URLNormalizer.normalize("http://Host.Example:8443/%7Ea"), "http://host.example:8443/%7Ea")
        XCTAssertEqual(URLNormalizer.normalize(" not a url "), "not a url")
        XCTAssertEqual(URLNormalizer.host(of: "https://user:pw@Example.com:8080/x"), "example.com")
        XCTAssertNil(URLNormalizer.xtreamBase("ftp://h"))
        XCTAssertNil(URLNormalizer.xtreamBase("  "))
        XCTAssertEqual(SourceSecrets.m3u(M3USecrets(url: "https://user:pw@Lists.Example.com:8080/x.m3u")).displayHost, "lists.example.com")
    }

    func testBase64AndHex() {
        XCTAssertEqual(Base64URL.encode(Data(1...12)), "AQIDBAUGBwgJCgsM")
        XCTAssertEqual(Base64URL.decode("AQIDBAUGBwgJCgsM")?.count, 12)
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertEqual(Data(hexString: "00FF10")?.hexString, "00ff10")
        XCTAssertNil(Data(hexString: "0"))
        XCTAssertEqual(Hashing.sha256Hex("x").count, 64)
    }

    func testSourceSecretsCodableRoundTrip() throws {
        for s in [SourceSecrets.m3u(M3USecrets(url: "http://a/b.m3u", epgUrl: "http://e", userAgent: "UA")),
                  .xtream(XtreamSecrets(serverUrl: "h:8080", username: "u", password: "p"))] {
            XCTAssertEqual(try JSONDecoder().decode(SourceSecrets.self, from: JSONEncoder().encode(s)), s)
        }
    }

    func testErrorCodableRoundTripAndRetryability() throws {
        let all: [SourceError] = [.network(.dns), .invalidCredentials, .accountExpired(expiresAt: Date(timeIntervalSince1970: 5)),
                                  .accountDisabled, .notFound, .serverError(httpStatus: 503), .invalidFormat,
                                  .invalidResponse, .empty, .cancelled]
        for e in all { XCTAssertEqual(try JSONDecoder().decode(SourceError.self, from: JSONEncoder().encode(e)), e) }
        XCTAssertTrue(SourceError.network(.timeout).isRetryable)
        XCTAssertTrue(SourceError.serverError(httpStatus: 500).isRetryable)
        XCTAssertFalse(SourceError.serverError(httpStatus: 418).isRetryable)
        XCTAssertFalse(SourceError.notFound.isRetryable)
        XCTAssertEqual(ErrorClassifier.playbackError(httpStatus: 410), .streamOffline(httpStatus: 410))
        XCTAssertEqual(ErrorClassifier.playbackError(httpStatus: 403), .accessDenied(httpStatus: 403))
        XCTAssertNil(ErrorClassifier.playbackError(httpStatus: 302))
    }
}
