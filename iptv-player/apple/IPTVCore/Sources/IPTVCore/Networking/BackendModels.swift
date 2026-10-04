import Foundation

// Wire models of spec/BACKEND_API.md (JSON in/out). Times: `serverTime`, `expiresAt`,
// `createdAt` are epoch MILLISECONDS; license/trial times are epoch SECONDS (JWT convention).

/// `platform` values of the backend.
public enum BackendPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case android, androidtv, ios, tvos
}

/// `GET /v1/config`.
public struct BackendConfig: Codable, Sendable, Hashable {
    public struct MinVersion: Codable, Sendable, Hashable {
        public var android: Int
        public var apple: Int
        public init(android: Int, apple: Int) {
            self.android = android
            self.apple = apple
        }
    }

    public struct Products: Codable, Sendable, Hashable {
        public var google: String?
        public var appleLifetime: String?
        public var appleTrial: String?
        public init(google: String? = nil, appleLifetime: String? = nil, appleTrial: String? = nil) {
            self.google = google
            self.appleLifetime = appleLifetime
            self.appleTrial = appleTrial
        }
    }

    public struct Features: Codable, Sendable, Hashable {
        public var accounts: Bool
        public var pairing: Bool
        public var sync: Bool
        public init(accounts: Bool, pairing: Bool, sync: Bool) {
            self.accounts = accounts
            self.pairing = pairing
            self.sync = sync
        }
    }

    public var trialDays: Int
    public var minVersion: MinVersion
    public var products: Products
    public var features: Features
    /// Server epoch ms (feeds the trusted clock).
    public var serverTime: Int64

    public init(trialDays: Int, minVersion: MinVersion, products: Products, features: Features, serverTime: Int64) {
        self.trialDays = trialDays
        self.minVersion = minVersion
        self.products = products
        self.features = features
        self.serverTime = serverTime
    }
}

/// Body of `POST /v1/license/sync`.
public struct LicenseSyncRequest: Codable, Sendable, Hashable {
    public struct GooglePurchase: Codable, Sendable, Hashable {
        public var productId: String
        public var purchaseToken: String
        public init(productId: String, purchaseToken: String) {
            self.productId = productId
            self.purchaseToken = purchaseToken
        }
    }

    public struct Google: Codable, Sendable, Hashable {
        public var purchases: [GooglePurchase]
        public init(purchases: [GooglePurchase]) { self.purchases = purchases }
    }

    public struct Apple: Codable, Sendable, Hashable {
        public var trialTransactionId: String?
        public var transactionIds: [String]
        public init(trialTransactionId: String? = nil, transactionIds: [String] = []) {
            self.trialTransactionId = trialTransactionId
            self.transactionIds = transactionIds
        }
    }

    public var platform: BackendPlatform
    public var appId: String
    public var appVersion: String
    public var deviceKey: String
    public var startTrial: Bool
    public var google: Google?
    public var apple: Apple?

    public init(platform: BackendPlatform, appId: String, appVersion: String, deviceKey: String,
                startTrial: Bool = false, google: Google? = nil, apple: Apple? = nil) {
        self.platform = platform
        self.appId = appId
        self.appVersion = appVersion
        self.deviceKey = deviceKey
        self.startTrial = startTrial
        self.google = google
        self.apple = apple
    }
}

/// Response of `POST /v1/license/sync`. The token must still be verified with
/// `LicenseTokenVerifier` before it is trusted.
public struct LicenseSyncResponse: Sendable, Hashable {
    /// JWS (CONTRACT §7.2).
    public var token: String
    /// Unverified copy of the `lic` claim (display only; trust the verified token).
    public var license: LicenseInfo
    /// Server epoch ms.
    public var serverTime: Int64
    /// Set for `422 store_verification_failed` / `503 store_unavailable`, which still carry
    /// a token for the remaining state (BACKEND_API.md).
    public var issue: BackendError?

    public init(token: String, license: LicenseInfo, serverTime: Int64, issue: BackendError? = nil) {
        self.token = token
        self.license = license
        self.serverTime = serverTime
        self.issue = issue
    }
}

/// An account (`{id, email}`).
public struct BackendAccount: Codable, Sendable, Hashable {
    public var id: String
    public var email: String
    public init(id: String, email: String) {
        self.id = id
        self.email = email
    }
}

/// A login result (`POST /v1/auth/email/verify`, device-code approval).
public struct BackendSession: Codable, Sendable, Hashable {
    public var sessionToken: String
    public var account: BackendAccount
    public init(sessionToken: String, account: BackendAccount) {
        self.sessionToken = sessionToken
        self.account = account
    }
}

/// `GET /v1/account`.
public struct AccountDetails: Codable, Sendable, Hashable {
    public struct License: Codable, Sendable, Hashable {
        public var store: String
        public var status: String
        /// Epoch ms or nil.
        public var purchasedAt: Int64?
        public var productId: String?
    }

    public struct Trial: Codable, Sendable, Hashable {
        /// Epoch seconds.
        public var start: Int64
        /// Epoch seconds.
        public var end: Int64
    }

    public var id: String
    public var email: String
    public var createdAt: Int64?
    public var licenses: [License]
    public var trial: Trial?
}

/// `POST /v1/auth/device/start`.
public struct DeviceCodeStart: Codable, Sendable, Hashable {
    public var deviceCode: String
    /// "ABCD-EFGH".
    public var userCode: String
    public var verificationUrl: String
    public var verificationUrlComplete: String
    /// Poll interval in seconds.
    public var interval: Int
    /// Lifetime in seconds.
    public var expiresIn: Int
}

/// Result of `POST /v1/auth/device/poll`.
public enum DevicePollResult: Sendable, Hashable {
    /// `428 authorization_pending`.
    case pending
    /// `429 slow_down` – increase the poll interval.
    case slowDown
    /// `410 expired_token` – start again.
    case expired
    /// `200` – signed in.
    case approved(BackendSession)
}

/// One page of `GET /v1/sync`.
public struct SyncPage: Sendable, Hashable {
    /// Items with `seq` (malformed items are skipped).
    public var items: [SyncItem]
    public var cursor: Int64
    public var hasMore: Bool
}

/// Result of `POST /v1/sync`.
public struct SyncPushResult: Codable, Sendable, Hashable {
    public var applied: Int
    public var cursor: Int64
}

/// `POST /v1/pair/sessions` (TV side).
public struct PairSession: Codable, Sendable, Hashable {
    /// 6 characters (display with `PairCode.display`).
    public var code: String
    /// Poll secret – never shown or logged.
    public var secret: String
    /// Epoch ms.
    public var expiresAt: Int64
    /// `{BASE}/pair?c=CODE` (QR code content).
    public var pairUrl: String
}

/// Result of `GET /v1/pair/sessions/{code}?secret=` (TV polling).
public enum PairPollResult: Sendable, Hashable {
    /// `202` – nothing sent yet.
    case pending
    /// `200` – encrypted payload (deleted server-side after this response).
    case ready(PairEnvelope)
    /// `410` – code expired.
    case expired
    /// `404` – unknown code (or already consumed).
    case notFound
}
