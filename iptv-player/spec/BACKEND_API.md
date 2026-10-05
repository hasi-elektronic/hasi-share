# Backend API (normative)

Base URL: `https://<worker-host>` (env `PUBLIC_BASE_URL`). JSON in/out, UTF-8.
All errors: `{"error": "<code>", "message": "<human readable, English>"}`.
Auth: `Authorization: Bearer <sessionToken>` (account endpoints) or
`Authorization: Bearer <ADMIN_TOKEN>` (admin endpoints).

The backend never receives IPTV credentials, playlist URLs or stream URLs, except
as end-to-end-encrypted pairing ciphertext it cannot decrypt (§Pairing).

## Public

### `GET /v1/config`
```json
{
  "trialDays": 7,
  "minVersion": {"android": 1, "apple": 1},
  "products": {
    "google": "lifetime_access",
    "appleLifetime": "de.hasielektronik.novaplayer.lifetime",
    "appleTrial": "de.hasielektronik.novaplayer.trial"
  },
  "features": {"accounts": true, "pairing": true, "sync": true},
  "serverTime": 1759570000123
}
```
Cache: `Cache-Control: public, max-age=300`.

### `POST /v1/license/sync`
Auth: optional session. Body:
```json
{
  "platform": "android" | "androidtv" | "ios" | "tvos",
  "appId": "de.hasielektronik.novaplayer",
  "appVersion": "1.0.0 (1)",
  "deviceKey": "<64 hex>",
  "startTrial": false,
  "google": {"purchases": [{"productId": "lifetime_access", "purchaseToken": "…"}]},
  "apple":  {"trialTransactionId": "2000000…", "transactionIds": ["2000000…"]}
}
```
Server logic:
1. Upsert `devices(deviceKey)`; attach `account_id` if a valid session is present.
2. Verify each Google token (`purchases.products.get`): `purchaseState == 0`
   → upsert license (`store=google`, `store_ref=purchaseToken`/`orderId`), acknowledge if
   `acknowledgementState == 0`. `purchaseState == 2` (pending) → ignored.
3. Verify each Apple transaction id via App Store Server API `GET /inApps/v1/transactions/{id}`
   (decode `signedTransactionInfo`; trust = TLS to Apple). Check `bundleId`, `productId`.
   `revocationDate` set → license revoked. Trial product → device/account trial start =
   `purchaseDate`.
4. Trial: if `startTrial` and no trial for this deviceKey (Android) → `trial_start = now`,
   `trial_end = now + config.trial_days`. Apple trial comes from step 3. If the device
   belongs to an account that already has a trial, the earliest trial applies.
5. `purchased` = any non-revoked license linked to this device **or** its account.
6. Respond:
```json
{
  "token": "<JWS, see CONTRACT §7.2>",
  "license": {"purchased": false, "src": null, "trialStart": 1759570000,
              "trialEnd": 1760174800, "acct": null},
  "serverTime": 1759570000123
}
```
Errors: `400 invalid_request`; `422 store_verification_failed` (with `details` per item
– response still contains a token for the remaining state); `503 store_unavailable`.
Rate limit: 30/min per deviceKey.

## Accounts (optional feature)

### `POST /v1/auth/email/start` `{email, locale: "de"|"tr"|"en"}` → `{ok: true}`
Sends a 6-digit code (valid 10 min, 5 attempts). Rate limit 5/hour per email and
20/hour per IP. In `DEV_MODE=true` the response also contains `devCode`.

### `POST /v1/auth/email/verify` `{email, code, deviceName}` → `{sessionToken, account: {id, email}}`
Errors: `400 invalid_code`, `429 too_many_attempts`, `410 code_expired`.
Session tokens: 32 random bytes base64url; stored as SHA-256; lifetime 180 days (sliding).

### `POST /v1/auth/logout` (session) → `{ok: true}`
### `GET /v1/account` (session) → `{id, email, createdAt, licenses: [{store, status, purchasedAt}], trial: {start, end}|null}`
### `DELETE /v1/account` (session) → `{ok: true}` – deletes account, sessions, sync items;
licenses are detached (kept for store-refund bookkeeping, no personal data).

### TV / device login (device-code flow)
* `POST /v1/auth/device/start {platform, deviceName}` →
  `{deviceCode, userCode: "ABCD-EFGH", verificationUrl: "{BASE}/link",
    verificationUrlComplete: "{BASE}/link?c=ABCDEFGH", interval: 5, expiresIn: 600}`
* `POST /v1/auth/device/poll {deviceCode}` → `428 {error:"authorization_pending"}` |
  `200 {sessionToken, account}` | `410 {error:"expired_token"}` | `429 slow_down`
* `POST /v1/auth/device/approve` (session) `{userCode}` → `{ok: true}`
* `GET /link` – HTML page: email-code login (if needed) + approve code.

## Sync (session)
### `GET /v1/sync?since=<cursor>&limit=500` → `{items: [SyncItem + seq], cursor, hasMore}`
### `POST /v1/sync` `{items: [SyncItem]}` (≤ 500) → `{applied, cursor}`
Limits: 5 000 favorites, 2 000 progress items per account (oldest progress trimmed).

## Pairing
* `POST /v1/pair/sessions {publicKey: JWK}` → `{code, secret, expiresAt, pairUrl}` (10/min/IP)
* `GET /v1/pair/sessions/{code}/key` → `{publicKey}` | `404` | `410`
* `POST /v1/pair/sessions/{code}/payload {epk, iv, ct}` → `{ok:true}` (once; `409` if already set; ct ≤ 8 KB)
* `GET /v1/pair/sessions/{code}?secret=` → `202 {status:"pending"}` | `200 {epk, iv, ct}` (deleted after) | `404` | `410`
* `GET /pair` – HTML page (DE/TR/EN by `Accept-Language`, `?lang=de|tr|en`), encrypts in the browser with WebCrypto.

## Store webhooks
* `POST /v1/webhooks/google?token=<GOOGLE_PUBSUB_TOKEN>` – Pub/Sub push. Handles
  `oneTimeProductNotification` (type 1 PURCHASED, 2 CANCELED) and
  `voidedPurchaseNotification` (→ revoke). Always re-queries Google before changing state.
  Responds 204 (so Pub/Sub does not retry) unless the token is wrong (401).
* `POST /v1/webhooks/apple` – App Store Server Notifications V2 `{signedPayload}`.
  The payload is decoded, then the referenced transaction is **re-fetched from Apple**
  (trust by re-query, no x5c chain parsing). Types: `REFUND`, `REVOKE` → revoke;
  `REFUND_REVERSED` → restore; `CONSUMPTION_REQUEST` → 200 no-op; others → 200.
* Cron (daily): Google Voided Purchases API poll (last 30 days) → revoke.

## Admin (Bearer `ADMIN_TOKEN`)
* `GET /v1/admin/config` / `PUT /v1/admin/config {trialDays (1..90), minVersion?, features?}`
* `POST /v1/admin/trials/extend {deviceKey? | accountId?, days}` (days may be negative)
* `GET /v1/admin/licenses?query=` (by store ref / account email / deviceKey)
* `POST /v1/admin/licenses/{id}/revoke` / `…/restore`
* `POST /v1/admin/licenses/grant {accountId | deviceKey, note}` (support / promo, `src: admin`)
* `GET /admin` – minimal HTML admin page (token entered in the page, kept in sessionStorage).

## Environment
| Var | Kind | Purpose |
|---|---|---|
| `PUBLIC_BASE_URL` | var | absolute base used in pairUrl / verification links |
| `APP_NAME` | var | shown on web pages / e-mails |
| `APP_IDS` | var | comma list of allowed `aud`/appId values |
| `LICENSE_SIGNING_KEY` | **secret** | ES256 private key, PKCS#8 PEM |
| `LICENSE_KID` | var | key id embedded in tokens |
| `ADMIN_TOKEN` | **secret** | admin bearer token (≥ 32 chars) |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | **secret** | Play Developer API service account |
| `GOOGLE_PACKAGE_NAME` | var | applicationId |
| `GOOGLE_PRODUCT_ID` | var | `lifetime_access` |
| `GOOGLE_PUBSUB_TOKEN` | **secret** | shared secret in the RTDN push URL |
| `APPLE_ISSUER_ID`, `APPLE_KEY_ID` | var | App Store Connect API key ids |
| `APPLE_PRIVATE_KEY` | **secret** | In-App Purchase key (.p8, PKCS#8 PEM) |
| `APPLE_BUNDLE_ID` | var | bundle id |
| `APPLE_PRODUCT_ID`, `APPLE_TRIAL_PRODUCT_ID` | var | product ids |
| `APPLE_ENVIRONMENT` | var | `Production` or `Sandbox` (server tries the other on 404) |
| `RESEND_API_KEY` | **secret** | e-mail delivery for login codes (optional) |
| `MAIL_FROM` | var | sender address |
| `DEV_MODE` | var | `true` only locally: returns `devCode`, relaxes rate limits |
