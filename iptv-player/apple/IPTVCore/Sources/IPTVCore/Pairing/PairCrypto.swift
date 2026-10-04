import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Private EC P-256 JWK (`d` = private scalar). Only used for tests/diagnostics – the TV keeps
/// its ephemeral key in memory.
public struct ECPrivateJWK: Codable, Sendable, Hashable {
    public var kty: String
    public var crv: String
    public var x: String
    public var y: String
    public var d: String

    public init(kty: String = "EC", crv: String = "P-256", x: String, y: String, d: String) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
        self.d = d
    }

    public var publicJWK: ECPublicJWK { ECPublicJWK(kty: kty, crv: crv, x: x, y: y) }
}

/// Wire envelope of a pairing payload (`POST …/payload`, `GET …?secret=` 200 body).
public struct PairEnvelope: Codable, Sendable, Hashable {
    /// Sender's ephemeral public key.
    public var epk: ECPublicJWK
    /// 12-byte GCM nonce, base64url.
    public var iv: String
    /// Ciphertext ‖ 16-byte tag, base64url.
    public var ct: String

    public init(epk: ECPublicJWK, iv: String, ct: String) {
        self.epk = epk
        self.iv = iv
        self.ct = ct
    }
}

public enum PairCryptoError: Error, Sendable, Hashable {
    case invalidKey
    case invalidEnvelope
    case decryptionFailed
    case invalidPayload
}

/// End-to-end encryption of TV pairing (CONTRACT §9):
/// `Z = ECDH(e.priv, tv.pub)` (32-byte x), `K = HKDF-SHA256(Z, salt: empty,
/// info: "iptvp-pair-v1", 32)`, `AES-256-GCM(K, iv: 12 bytes)`, wire `ct = ciphertext ‖ tag`.
public enum PairCrypto {
    /// Generates the TV's ephemeral key pair.
    public static func generateKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// Public JWK of a key-agreement public key.
    public static func jwk(of publicKey: P256.KeyAgreement.PublicKey) -> ECPublicJWK {
        let raw = publicKey.rawRepresentation   // x ‖ y
        return ECPublicJWK(x: Base64URL.encode(raw.prefix(32)), y: Base64URL.encode(raw.suffix(32)))
    }

    /// Private JWK of a key-agreement private key.
    public static func privateJWK(of privateKey: P256.KeyAgreement.PrivateKey) -> ECPrivateJWK {
        let pub = jwk(of: privateKey.publicKey)
        return ECPrivateJWK(x: pub.x, y: pub.y, d: Base64URL.encode(privateKey.rawRepresentation))
    }

    public static func publicKey(from jwk: ECPublicJWK) throws -> P256.KeyAgreement.PublicKey {
        guard let raw = jwk.rawRepresentation,
              let key = try? P256.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw PairCryptoError.invalidKey }
        return key
    }

    public static func privateKey(from jwk: ECPrivateJWK) throws -> P256.KeyAgreement.PrivateKey {
        guard jwk.kty == "EC", jwk.crv == "P-256", let d = Base64URL.decode(jwk.d), d.count == 32,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: d) else { throw PairCryptoError.invalidKey }
        return key
    }

    /// Raw ECDH shared secret Z (32 bytes).
    public static func sharedSecret(privateKey: P256.KeyAgreement.PrivateKey, peer: P256.KeyAgreement.PublicKey) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// AES-256 key K derived with HKDF-SHA256.
    public static func deriveKey(privateKey: P256.KeyAgreement.PrivateKey, peer: P256.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                              sharedInfo: Data(ProtocolConstants.pairHKDFInfo.utf8), outputByteCount: 32)
    }

    /// Encrypts `plaintext` for the TV's public key (what the pairing web page does).
    /// `ephemeral` and `iv` are injectable for deterministic tests.
    public static func encrypt(_ plaintext: Data, to recipient: ECPublicJWK,
                               ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
                               iv: Data? = nil) throws -> PairEnvelope {
        let key = try deriveKey(privateKey: ephemeral, peer: try publicKey(from: recipient))
        let nonce: AES.GCM.Nonce
        do { nonce = try iv.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce() } catch { throw PairCryptoError.invalidEnvelope }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return PairEnvelope(epk: jwk(of: ephemeral.publicKey), iv: Base64URL.encode(nonce.withUnsafeBytes { Data($0) }),
                            ct: Base64URL.encode(box.ciphertext + box.tag))
    }

    /// Decrypts an envelope with the TV's private key.
    public static func decrypt(_ envelope: PairEnvelope, privateKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        guard let iv = Base64URL.decode(envelope.iv), iv.count == 12,
              let combined = Base64URL.decode(envelope.ct), combined.count >= 16 else { throw PairCryptoError.invalidEnvelope }
        let key = try deriveKey(privateKey: privateKey, peer: try publicKey(from: envelope.epk))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: combined.prefix(combined.count - 16),
                                            tag: combined.suffix(16))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw PairCryptoError.decryptionFailed
        }
    }

    /// Decrypts and decodes the pairing payload.
    public static func open(_ envelope: PairEnvelope, privateKey: P256.KeyAgreement.PrivateKey) throws -> PairPayload {
        let data = try decrypt(envelope, privateKey: privateKey)
        do { return try JSONDecoder().decode(PairPayload.self, from: data) } catch { throw PairCryptoError.invalidPayload }
    }
}

/// Plaintext of a pairing payload (CONTRACT §9.5), version 1.
public enum PairPayload: Codable, Sendable, Hashable {
    case m3u(name: String, url: String, epgUrl: String?)
    case xtream(name: String, server: String, username: String, password: String)

    private enum CodingKeys: String, CodingKey { case v, type, name, url, epgUrl, server, username, password }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "Unsupported version \(version)")
        }
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        switch try c.decode(String.self, forKey: .type) {
        case "m3u":
            let epg = try c.decodeIfPresent(String.self, forKey: .epgUrl)
            self = .m3u(name: name, url: try c.decode(String.self, forKey: .url), epgUrl: epg?.isEmpty == true ? nil : epg)
        case "xtream":
            self = .xtream(name: name, server: try c.decode(String.self, forKey: .server),
                           username: try c.decode(String.self, forKey: .username),
                           password: try c.decode(String.self, forKey: .password))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .v)
        switch self {
        case let .m3u(name, url, epgUrl):
            try c.encode("m3u", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(epgUrl, forKey: .epgUrl)
        case let .xtream(name, server, username, password):
            try c.encode("xtream", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(server, forKey: .server)
            try c.encode(username, forKey: .username)
            try c.encode(password, forKey: .password)
        }
    }

    /// Source name.
    public var name: String {
        switch self {
        case .m3u(let name, _, _), .xtream(let name, _, _, _): return name
        }
    }

    /// Secrets to store in the Keychain for the new source.
    public var secrets: SourceSecrets {
        switch self {
        case let .m3u(_, url, epgUrl): return .m3u(M3USecrets(url: url, epgUrl: epgUrl))
        case let .xtream(_, server, username, password):
            return .xtream(XtreamSecrets(serverUrl: server, username: username, password: password))
        }
    }
}

/// Helpers for the pairing code (6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`).
public enum PairCode {
    public static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

    /// "ABC123" → "ABC-123".
    public static func display(_ code: String) -> String {
        let clean = normalize(code)
        guard clean.count == 6 else { return clean }
        return "\(clean.prefix(3))-\(clean.suffix(3))"
    }

    /// Uppercases and strips separators/whitespace ("abc-123" → "ABC123").
    public static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// True for a well-formed 6-character code.
    public static func isValid(_ input: String) -> Bool {
        let clean = normalize(input)
        return clean.count == 6 && clean.allSatisfy { alphabet.contains($0) }
    }
}
