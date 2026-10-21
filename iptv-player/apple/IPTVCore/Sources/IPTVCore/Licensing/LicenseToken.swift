import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// License source (`lic.src`). Extensible string enum so unknown future values decode.
public struct LicenseSource: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let google = LicenseSource(rawValue: "google")
    public static let apple = LicenseSource(rawValue: "apple")
    public static let account = LicenseSource(rawValue: "account")
    public static let admin = LicenseSource(rawValue: "admin")
}

/// `lic` claim of a license token (CONTRACT §7.2). Times are epoch SECONDS.
public struct LicenseInfo: Codable, Sendable, Hashable {
    public var purchased: Bool
    public var src: LicenseSource?
    public var trialStart: Int64?
    public var trialEnd: Int64?
    public var acct: String?

    public init(purchased: Bool, src: LicenseSource? = nil, trialStart: Int64? = nil, trialEnd: Int64? = nil, acct: String? = nil) {
        self.purchased = purchased
        self.src = src
        self.trialStart = trialStart
        self.trialEnd = trialEnd
        self.acct = acct
    }

    private enum CodingKeys: String, CodingKey { case purchased, src, trialStart, trialEnd, acct }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purchased = try c.decodeIfPresent(Bool.self, forKey: .purchased) ?? false
        src = try c.decodeIfPresent(LicenseSource.self, forKey: .src)
        trialStart = try c.decodeIfPresent(Int64.self, forKey: .trialStart)
        trialEnd = try c.decodeIfPresent(Int64.self, forKey: .trialEnd)
        acct = try c.decodeIfPresent(String.self, forKey: .acct)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(purchased, forKey: .purchased)
        try c.encode(src, forKey: .src)
        try c.encode(trialStart, forKey: .trialStart)
        try c.encode(trialEnd, forKey: .trialEnd)
        try c.encode(acct, forKey: .acct)
    }
}

/// Claims of a license token (CONTRACT §7.2). `iat`/`exp` are epoch SECONDS.
public struct LicenseClaims: Codable, Sendable, Hashable {
    public var iss: String
    public var aud: String
    public var sub: String
    public var iat: Int64
    public var exp: Int64
    public var lic: LicenseInfo

    public init(iss: String, aud: String, sub: String, iat: Int64, exp: Int64, lic: LicenseInfo) {
        self.iss = iss
        self.aud = aud
        self.sub = sub
        self.iat = iat
        self.exp = exp
        self.lic = lic
    }
}

/// A token that passed verification.
public struct VerifiedLicense: Sendable, Hashable {
    public var token: String
    public var claims: LicenseClaims
    /// `exp` passed: still usable (trial times are absolute) but the client should refresh.
    public var isStale: Bool
}

/// Why a token was rejected (vector `reason` values).
public enum LicenseTokenError: String, Error, Sendable, Hashable, CaseIterable {
    case format, alg, kid, signature, iss, aud
}

/// Public EC P-256 JWK (`{kty:"EC", crv:"P-256", x, y}`), as embedded in the app.
public struct ECPublicJWK: Codable, Sendable, Hashable {
    public var kty: String
    public var crv: String
    public var x: String
    public var y: String

    public init(kty: String = "EC", crv: String = "P-256", x: String, y: String) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
    }

    /// Raw `x‖y` (64 bytes), or nil if malformed.
    public var rawRepresentation: Data? {
        guard kty == "EC", crv == "P-256", let x = Base64URL.decode(x), let y = Base64URL.decode(y),
              x.count == 32, y.count == 32 else { return nil }
        return x + y
    }
}

/// Verifies ES256 license tokens (CONTRACT §7.2): `alg == ES256`, known `kid`, valid
/// signature (raw r‖s), `iss` and `aud` match. Checks run in that order; `exp` in the past
/// only marks the token stale.
public struct LicenseTokenVerifier: Sendable {
    private let keys: [String: P256.Signing.PublicKey]
    public let issuer: String
    public let audience: String

    /// - Parameters:
    ///   - keys: `kid → JWK` set embedded at build time (invalid entries are ignored).
    ///   - audience: the app's bundle id.
    public init(keys: [String: ECPublicJWK], audience: String, issuer: String = ProtocolConstants.licenseIssuer) {
        var parsed: [String: P256.Signing.PublicKey] = [:]
        for (kid, jwk) in keys {
            if let raw = jwk.rawRepresentation, let key = try? P256.Signing.PublicKey(rawRepresentation: raw) {
                parsed[kid] = key
            }
        }
        self.keys = parsed
        self.audience = audience
        self.issuer = issuer
    }

    /// Builds a verifier from a JWK-set JSON object `{"kid": {kty, crv, x, y}, …}`.
    public init(jwkSetJSON: Data, audience: String, issuer: String = ProtocolConstants.licenseIssuer) throws {
        let keys = try JSONDecoder().decode([String: ECPublicJWK].self, from: jwkSetJSON)
        self.init(keys: keys, audience: audience, issuer: issuer)
    }

    /// Verifies `token` at `now`.
    public func verify(_ token: String, now: Date) -> Result<VerifiedLicense, LicenseTokenError> {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Base64URL.decode(String(parts[0])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let payloadData = Base64URL.decode(String(parts[1])) else { return .failure(.format) }
        guard header.alg == "ES256" else { return .failure(.alg) }
        guard let kid = header.kid, let key = keys[kid] else { return .failure(.kid) }
        guard let signatureData = Base64URL.decode(String(parts[2])), signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)) else {
            return .failure(.signature)
        }
        guard let claims = try? JSONDecoder().decode(LicenseClaims.self, from: payloadData) else { return .failure(.format) }
        guard claims.iss == issuer else { return .failure(.iss) }
        guard claims.aud == audience else { return .failure(.aud) }
        let nowSeconds = Int64(now.timeIntervalSince1970.rounded(.down))
        return .success(VerifiedLicense(token: token, claims: claims, isStale: nowSeconds >= claims.exp))
    }

    private struct Header: Decodable {
        var alg: String?
        var kid: String?
    }
}
