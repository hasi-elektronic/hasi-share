import Foundation
import XCTest
@testable import IPTVCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// CONTRACT §9 – `pair-crypto.json` (decrypt, and encrypt with the fixed iv/ephemeral key).
final class PairCryptoVectorTests: XCTestCase {
    private func vector() throws -> [String: Any] { try Vectors.object("pair-crypto.json") }

    private func privateJWK(_ o: [String: Any]?) throws -> ECPrivateJWK {
        let o = try XCTUnwrap(o)
        return ECPrivateJWK(kty: try XCTUnwrap(o.str("kty")), crv: try XCTUnwrap(o.str("crv")),
                            x: try XCTUnwrap(o.str("x")), y: try XCTUnwrap(o.str("y")), d: try XCTUnwrap(o.str("d")))
    }

    private func publicJWK(_ o: [String: Any]?) throws -> ECPublicJWK {
        try JSONDecoder().decode(ECPublicJWK.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(o)))
    }

    func testSharedSecretAndKeyDerivation() throws {
        let v = try vector()
        let tv = try PairCrypto.privateKey(from: try privateJWK(v.obj("tvPrivateJwk")))
        let sender = try PairCrypto.privateKey(from: try privateJWK(v.obj("senderPrivateJwk")))
        let tvPublic = try publicJWK(v.obj("tvPublicJwk"))
        let senderPublic = try publicJWK(v.obj("senderPublicJwk"))
        XCTAssertEqual(PairCrypto.jwk(of: tv.publicKey), tvPublic)
        XCTAssertEqual(PairCrypto.jwk(of: sender.publicKey), senderPublic)

        let z = try PairCrypto.sharedSecret(privateKey: tv, peer: try PairCrypto.publicKey(from: senderPublic))
        XCTAssertEqual(z.hexString, v.str("sharedSecretHex"))
        let z2 = try PairCrypto.sharedSecret(privateKey: sender, peer: try PairCrypto.publicKey(from: tvPublic))
        XCTAssertEqual(z2, z)

        let k = try PairCrypto.deriveKey(privateKey: tv, peer: try PairCrypto.publicKey(from: senderPublic))
        XCTAssertEqual(k.withUnsafeBytes { Data($0) }.hexString, v.str("aesKeyHex"))
    }

    func testDecryptVectorPayload() throws {
        let v = try vector()
        let tv = try PairCrypto.privateKey(from: try privateJWK(v.obj("tvPrivateJwk")))
        let envelope = try JSONDecoder().decode(PairEnvelope.self,
                                                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(v["payload"])))
        let plaintext = try PairCrypto.decrypt(envelope, privateKey: tv)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), v.str("plaintext"))

        let payload = try PairCrypto.open(envelope, privateKey: tv)
        XCTAssertEqual(payload, .xtream(name: "Ev", server: "http://iptv.example.com:8080", username: "user1", password: "p@ss/w rd çğ"))
        XCTAssertEqual(payload.secrets, .xtream(XtreamSecrets(serverUrl: "http://iptv.example.com:8080", username: "user1", password: "p@ss/w rd çğ")))
    }

    func testEncryptWithFixedIvMatchesVector() throws {
        let v = try vector()
        let sender = try PairCrypto.privateKey(from: try privateJWK(v.obj("senderPrivateJwk")))
        let payload = try XCTUnwrap(v.obj("payload"))
        let iv = try XCTUnwrap(Base64URL.decode(try XCTUnwrap(payload.str("iv"))))
        XCTAssertEqual(iv, Data(1...12))
        let envelope = try PairCrypto.encrypt(Data(try XCTUnwrap(v.str("plaintext")).utf8), to: try publicJWK(v.obj("tvPublicJwk")),
                                              ephemeral: sender, iv: iv)
        XCTAssertEqual(envelope.iv, payload.str("iv"))
        XCTAssertEqual(envelope.ct, payload.str("ct"))
        XCTAssertEqual(envelope.epk, try publicJWK(payload.obj("epk")))
    }

    func testTamperingAndWrongKeyAreRejected() throws {
        let v = try vector()
        let tv = try PairCrypto.privateKey(from: try privateJWK(v.obj("tvPrivateJwk")))
        var envelope = try JSONDecoder().decode(PairEnvelope.self,
                                                from: JSONSerialization.data(withJSONObject: try XCTUnwrap(v["payload"])))
        XCTAssertThrowsError(try PairCrypto.decrypt(envelope, privateKey: PairCrypto.generateKeyPair())) {
            XCTAssertEqual($0 as? PairCryptoError, .decryptionFailed)
        }
        var ct = try XCTUnwrap(Base64URL.decode(envelope.ct))
        ct[0] ^= 0x01
        envelope.ct = Base64URL.encode(ct)
        XCTAssertThrowsError(try PairCrypto.decrypt(envelope, privateKey: tv)) {
            XCTAssertEqual($0 as? PairCryptoError, .decryptionFailed)
        }
        envelope.iv = "AQID"
        XCTAssertThrowsError(try PairCrypto.decrypt(envelope, privateKey: tv)) {
            XCTAssertEqual($0 as? PairCryptoError, .invalidEnvelope)
        }
    }

    func testRoundTripWithFreshKeysAndM3UPayload() throws {
        let tv = PairCrypto.generateKeyPair()
        let payload = PairPayload.m3u(name: "Liste", url: "http://lists.example.com/a.m3u", epgUrl: nil)
        let envelope = try PairCrypto.encrypt(try JSONEncoder().encode(payload), to: PairCrypto.jwk(of: tv.publicKey))
        XCTAssertEqual(try Base64URL.decode(envelope.iv)?.count, 12)
        XCTAssertEqual(try PairCrypto.open(envelope, privateKey: tv), payload)
        // Private JWK export/import round trip.
        let jwk = PairCrypto.privateJWK(of: tv)
        XCTAssertEqual(try PairCrypto.privateKey(from: jwk).rawRepresentation, tv.rawRepresentation)
    }

    func testPairCode() {
        XCTAssertEqual(PairCode.display("abc123"), "ABC-123")
        XCTAssertEqual(PairCode.normalize(" abc-123 "), "ABC123")
        XCTAssertTrue(PairCode.isValid("ABC-234"))
        XCTAssertFalse(PairCode.isValid("ABC-120"), "0 and 1 are not in the alphabet")
        XCTAssertFalse(PairCode.isValid("ABCD"))
    }
}
